# SQL Server Extended Events Tracing Script
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "start", "stop", "read", "cleanup", "status")]
    [string]$Action,

    [string]$SessionName = "BenchmarkTrace",
    [string]$OutputPath = "C:\temp",
    [int]$MaxFileSizeMB = 100,
    [int]$TopQueries = 50
)

$server = "TOMER-BOOK3\SQLEXPRESS"
$database = "BenchmarkTest"
$connectionString = "Server=$server;Database=master;Integrated Security=True;"
$traceFile = Join-Path $OutputPath "$SessionName.xel"

function Execute-Sql {
    param([string]$sql, [string]$connStr = $connectionString)

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 60
        $result = $cmd.ExecuteNonQuery()
        $cmd.Dispose()
        $conn.Close()
        $conn.Dispose()
        return $true
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Execute-SqlQuery {
    param([string]$sql, [string]$connStr = $connectionString)

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 120
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $cmd.Dispose()
        $conn.Close()
        $conn.Dispose()
        return $dataset.Tables[0]
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Show-Header {
    param([string]$title)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

switch ($Action) {
    "create" {
        Show-Header "Creating XEvents Session: $SessionName"

        # Ensure output directory exists
        if (!(Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            Write-Host "Created output directory: $OutputPath"
        }

        # Drop existing session if exists
        $dropSql = @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = '$SessionName')
BEGIN
    DROP EVENT SESSION [$SessionName] ON SERVER;
END
"@
        Execute-Sql -sql $dropSql | Out-Null

        # Create the session
        $createSql = @"
CREATE EVENT SESSION [$SessionName] ON SERVER

-- Completed SQL statements
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.session_id,
        sqlserver.username
    )
    WHERE ([database_name] = N'$database')
),

-- Completed RPC calls (parameterized queries)
ADD EVENT sqlserver.rpc_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- Wait statistics
ADD EVENT sqlos.wait_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([duration] > 1000)  -- waits > 1ms
),

-- Lock acquisitions (for contention analysis)
ADD EVENT sqlserver.lock_acquired (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database' AND [mode] > 2)  -- Exclusive locks and above
),

-- Errors
ADD EVENT sqlserver.error_reported (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([severity] >= 11)
)

-- Output to file
ADD TARGET package0.event_file (
    SET filename = N'$traceFile',
    max_file_size = ($MaxFileSizeMB)
),

-- Ring buffer for live queries
ADD TARGET package0.ring_buffer (
    SET max_events_limit = 5000
)

WITH (
    MAX_MEMORY = 8192 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE = OFF
);
"@

        if (Execute-Sql -sql $createSql) {
            Write-Host "Session '$SessionName' created successfully" -ForegroundColor Green
            Write-Host "Trace file: $traceFile"
        }
    }

    "start" {
        Show-Header "Starting XEvents Session: $SessionName"

        $sql = "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = START;"
        if (Execute-Sql -sql $sql) {
            Write-Host "Session started successfully" -ForegroundColor Green
            Write-Host "Trace file: $traceFile"
            Write-Host ""
            Write-Host "Run your benchmark now, then use -Action stop to stop tracing" -ForegroundColor Yellow
        }
    }

    "stop" {
        Show-Header "Stopping XEvents Session: $SessionName"

        $sql = "ALTER EVENT SESSION [$SessionName] ON SERVER STATE = STOP;"
        if (Execute-Sql -sql $sql) {
            Write-Host "Session stopped successfully" -ForegroundColor Green
            Write-Host "Use -Action read to analyze the trace data"
        }
    }

    "status" {
        Show-Header "XEvents Session Status"

        $sql = @"
SELECT
    es.name AS SessionName,
    CASE WHEN rs.create_time IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS Status,
    rs.create_time AS StartTime,
    rs.dropped_event_count AS DroppedEvents,
    rs.total_buffer_size / 1024 AS BufferSizeKB
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions rs ON es.name = rs.name
WHERE es.name = '$SessionName';
"@

        $result = Execute-SqlQuery -sql $sql
        if ($result -and $result.Rows.Count -gt 0) {
            $row = $result.Rows[0]
            Write-Host "Session:        $($row.SessionName)"
            Write-Host "Status:         $($row.Status)" -ForegroundColor $(if ($row.Status -eq 'RUNNING') { 'Green' } else { 'Yellow' })
            if ($row.StartTime) {
                Write-Host "Started:        $($row.StartTime)"
                Write-Host "Dropped Events: $($row.DroppedEvents)"
                Write-Host "Buffer Size:    $($row.BufferSizeKB) KB"
            }
        } else {
            Write-Host "Session '$SessionName' not found" -ForegroundColor Yellow
            Write-Host "Use -Action create to create the session"
        }
    }

    "read" {
        Show-Header "Analyzing XEvents Trace Data"

        $tracePattern = Join-Path $OutputPath "$SessionName*.xel"

        $sql = @"
;WITH EventData AS (
    SELECT
        CAST(event_data AS XML) AS event_xml
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedEvents AS (
    SELECT
        event_xml.value('(@name)[1]', 'nvarchar(100)') AS event_name,
        event_xml.value('(@timestamp)[1]', 'datetime2') AS event_time,
        event_xml.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        event_xml.value('(data[@name="cpu_time"]/value)[1]', 'bigint') AS cpu_time_us,
        event_xml.value('(data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
        event_xml.value('(data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads,
        event_xml.value('(data[@name="writes"]/value)[1]', 'bigint') AS writes,
        event_xml.value('(data[@name="row_count"]/value)[1]', 'bigint') AS row_count,
        event_xml.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
        event_xml.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
    FROM EventData
    WHERE event_xml.value('(@name)[1]', 'nvarchar(100)') IN ('sql_statement_completed', 'rpc_completed')
)
SELECT TOP $TopQueries
    event_name,
    COUNT(*) AS execution_count,
    AVG(duration_us / 1000.0) AS avg_duration_ms,
    MIN(duration_us / 1000.0) AS min_duration_ms,
    MAX(duration_us / 1000.0) AS max_duration_ms,
    SUM(duration_us / 1000.0) AS total_duration_ms,
    AVG(cpu_time_us / 1000.0) AS avg_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(physical_reads, 0)) AS total_physical_reads,
    LEFT(sql_text, 100) AS sql_text_preview
FROM ParsedEvents
WHERE sql_text IS NOT NULL
GROUP BY event_name, LEFT(sql_text, 100)
ORDER BY total_duration_ms DESC;
"@

        $result = Execute-SqlQuery -sql $sql

        if ($result -and $result.Rows.Count -gt 0) {
            Write-Host ""
            Write-Host "Top Queries by Total Duration:" -ForegroundColor Yellow
            Write-Host "-" * 120

            $format = "{0,-6} {1,-10} {2,-12} {3,-12} {4,-12} {5,-15} {6,-50}"
            Write-Host ($format -f "Count", "Avg(ms)", "Min(ms)", "Max(ms)", "Total(ms)", "Logical Reads", "Query")
            Write-Host "-" * 120

            foreach ($row in $result.Rows) {
                $query = if ($row.sql_text_preview.Length -gt 45) { $row.sql_text_preview.Substring(0, 45) + "..." } else { $row.sql_text_preview }
                Write-Host ($format -f $row.execution_count,
                    [math]::Round($row.avg_duration_ms, 2),
                    [math]::Round($row.min_duration_ms, 2),
                    [math]::Round($row.max_duration_ms, 2),
                    [math]::Round($row.total_duration_ms, 2),
                    $row.total_logical_reads,
                    $query)
            }

            # Summary statistics
            $summarySql = @"
;WITH EventData AS (
    SELECT CAST(event_data AS XML) AS event_xml
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
Stats AS (
    SELECT
        event_xml.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0 AS duration_ms
    FROM EventData
    WHERE event_xml.value('(@name)[1]', 'nvarchar(100)') IN ('sql_statement_completed', 'rpc_completed')
)
SELECT
    COUNT(*) AS total_events,
    AVG(duration_ms) AS avg_duration,
    MIN(duration_ms) AS min_duration,
    MAX(duration_ms) AS max_duration,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) OVER() AS p95_duration,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_ms) OVER() AS p99_duration
FROM Stats;
"@

            $summary = Execute-SqlQuery -sql $summarySql
            if ($summary -and $summary.Rows.Count -gt 0) {
                $s = $summary.Rows[0]
                Write-Host ""
                Write-Host "Summary Statistics:" -ForegroundColor Green
                Write-Host "-" * 40
                Write-Host "Total Events:    $($s.total_events)"
                Write-Host ("Avg Duration:    {0:N2} ms" -f $s.avg_duration)
                Write-Host ("Min Duration:    {0:N2} ms" -f $s.min_duration)
                Write-Host ("Max Duration:    {0:N2} ms" -f $s.max_duration)
                Write-Host ("P95 Duration:    {0:N2} ms" -f $s.p95_duration)
                Write-Host ("P99 Duration:    {0:N2} ms" -f $s.p99_duration)
            }
        } else {
            Write-Host "No trace data found in $tracePattern" -ForegroundColor Yellow
        }
    }

    "cleanup" {
        Show-Header "Cleaning Up XEvents Session: $SessionName"

        # Stop if running
        $stopSql = @"
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = '$SessionName')
BEGIN
    ALTER EVENT SESSION [$SessionName] ON SERVER STATE = STOP;
END
"@
        Execute-Sql -sql $stopSql | Out-Null

        # Drop the session
        $dropSql = @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = '$SessionName')
BEGIN
    DROP EVENT SESSION [$SessionName] ON SERVER;
END
"@

        if (Execute-Sql -sql $dropSql) {
            Write-Host "Session '$SessionName' dropped" -ForegroundColor Green
        }

        # Remove trace files
        $files = Get-ChildItem -Path $OutputPath -Filter "$SessionName*.xel" -ErrorAction SilentlyContinue
        if ($files) {
            $files | Remove-Item -Force
            Write-Host "Removed $($files.Count) trace file(s)" -ForegroundColor Green
        }

        Write-Host "Cleanup complete"
    }
}

Write-Host ""
