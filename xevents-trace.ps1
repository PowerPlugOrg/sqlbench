# SQL Server Extended Events Tracing Script
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "start", "stop", "read", "cleanup", "status", "export")]
    [string]$Action,

    [string]$SessionName = "BenchmarkTrace",
    [string]$OutputPath = "C:\temp",
    [int]$MaxFileSizeMB = 100,
    [int]$TopQueries = 50,

    [ValidateSet("csv", "json")]
    [string]$Format = "csv"
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

        # SET QUOTED_IDENTIFIER ON is required for XML methods
        $setCmd = $conn.CreateCommand()
        $setCmd.CommandText = "SET QUOTED_IDENTIFIER ON"
        $setCmd.ExecuteNonQuery() | Out-Null
        $setCmd.Dispose()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 120
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataTable = New-Object System.Data.DataTable
        $adapter.Fill($dataTable) | Out-Null
        $cmd.Dispose()
        $conn.Close()
        $conn.Dispose()
        # Use comma to prevent PowerShell from unrolling the DataTable
        return ,$dataTable
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

-- ============================================
-- QUERY EXECUTION EVENTS
-- ============================================

-- Completed SQL statements (ad-hoc queries)
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.session_id,
        sqlserver.username,
        sqlserver.plan_handle
    )
    WHERE ([database_name] = N'$database')
),

-- Completed RPC calls (parameterized queries, stored procedures)
ADD EVENT sqlserver.rpc_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.plan_handle
    )
    WHERE ([database_name] = N'$database')
),

-- Completed SQL batches
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.client_app_name
    )
    WHERE ([database_name] = N'$database')
),

-- Statements within stored procedures
ADD EVENT sqlserver.sp_statement_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database' AND [duration] > 1000)  -- > 1ms
),

-- ============================================
-- CPU-FOCUSED EVENTS
-- ============================================

-- Query compilation (CPU intensive)
ADD EVENT sqlserver.query_post_compilation_showplan (
    ACTION (
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- Query recompilation (CPU spikes)
ADD EVENT sqlserver.sql_statement_recompile (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- Parallel query execution
ADD EVENT sqlserver.degree_of_parallelism (
    ACTION (
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database' AND [dop] > 1)
),

-- Auto-statistics update (CPU spike)
ADD EVENT sqlserver.auto_stats (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- ============================================
-- I/O-FOCUSED EVENTS
-- ============================================

-- Page splits (causes extra I/O, index fragmentation)
ADD EVENT sqlserver.page_split (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- Checkpoint begin (major I/O event)
ADD EVENT sqlserver.checkpoint_begin (
    ACTION (
        sqlserver.database_name
    )
    WHERE ([database_name] = N'$database')
),

-- Checkpoint end
ADD EVENT sqlserver.checkpoint_end (
    ACTION (
        sqlserver.database_name
    )
    WHERE ([database_name] = N'$database')
),

-- Transaction log flush (I/O to log file)
ADD EVENT sqlserver.log_flush_start (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- File read/write completion
ADD EVENT sqlserver.file_read_completed (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database' AND [duration] > 10000)  -- > 10ms
),

ADD EVENT sqlserver.file_write_completed (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database' AND [duration] > 10000)  -- > 10ms
),

-- ============================================
-- MEMORY-FOCUSED EVENTS
-- ============================================

-- Memory grant feedback/updates
ADD EVENT sqlserver.memory_grant_updated_by_feedback (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
),

-- Sort spilling to tempdb (memory pressure)
ADD EVENT sqlserver.sort_warning (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
),

-- Hash spilling to tempdb (memory pressure)
ADD EVENT sqlserver.hash_warning (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
),

-- Exchange spill (parallel query memory issue)
ADD EVENT sqlserver.exchange_spill (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
),

-- ============================================
-- WAIT & CONTENTION EVENTS
-- ============================================

-- Wait statistics (resource contention)
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

-- Lock escalation (can cause blocking)
ADD EVENT sqlserver.lock_escalation (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
),

-- Latch contention (buffer pool / memory)
ADD EVENT sqlserver.latch_suspend_end (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([duration] > 1000)  -- > 1ms
),

-- Blocked process (long blocking)
ADD EVENT sqlserver.blocked_process_report (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
),

-- ============================================
-- ERROR EVENTS
-- ============================================

-- Errors
ADD EVENT sqlserver.error_reported (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id
    )
    WHERE ([severity] >= 11)
),

-- Attention (query cancellation/timeout)
ADD EVENT sqlserver.attention (
    ACTION (
        sqlserver.sql_text,
        sqlserver.database_name,
        sqlserver.session_id
    )
    WHERE ([database_name] = N'$database')
)

-- ============================================
-- TARGETS
-- ============================================

-- Output to file
ADD TARGET package0.event_file (
    SET filename = N'$traceFile',
    max_file_size = ($MaxFileSizeMB),
    max_rollover_files = 5
),

-- Ring buffer for live queries
ADD TARGET package0.ring_buffer (
    SET max_events_limit = 10000
)

WITH (
    MAX_MEMORY = 16384 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 3 SECONDS,
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

        # ============================================
        # EVENT OVERVIEW
        # ============================================
        Write-Host ""
        Write-Host "EVENT OVERVIEW:" -ForegroundColor Green
        Write-Host "-" * 60

        $overviewSql = @"
;WITH EventData AS (
    SELECT
        CAST(event_data AS XML).value('(event/@name)[1]', 'nvarchar(100)') AS event_name
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
)
SELECT
    event_name,
    COUNT(*) AS event_count
FROM EventData
GROUP BY event_name
ORDER BY event_count DESC;
"@

        $overview = Execute-SqlQuery -sql $overviewSql
        if ($overview -and $overview.Rows.Count -gt 0) {
            $totalEvents = ($overview.Rows | Measure-Object -Property event_count -Sum).Sum
            Write-Host "Total Events Captured: $totalEvents"
            Write-Host ""
            Write-Host ("{0,-45} {1,10}" -f "Event Type", "Count")
            Write-Host "-" * 57
            foreach ($row in $overview.Rows) {
                Write-Host ("{0,-45} {1,10}" -f $row.event_name, $row.event_count)
            }
        }

        # ============================================
        # QUERY EXECUTION ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "QUERY EXECUTION ANALYSIS:" -ForegroundColor Green
        Write-Host "-" * 60

        $sql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedEvents AS (
    SELECT
        x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name,
        x.value('(event/@timestamp)[1]', 'datetime2') AS event_time,
        x.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        x.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') AS cpu_time_us,
        x.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
        x.value('(event/data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads,
        x.value('(event/data[@name="writes"]/value)[1]', 'bigint') AS writes,
        x.value('(event/data[@name="row_count"]/value)[1]', 'bigint') AS row_count,
        x.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
        x.value('(event/action[@name="session_id"]/value)[1]', 'int') AS session_id
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN ('sql_statement_completed', 'rpc_completed', 'sp_statement_completed')
)
SELECT TOP $TopQueries
    COUNT(*) AS execution_count,
    AVG(duration_us / 1000.0) AS avg_duration_ms,
    MIN(duration_us / 1000.0) AS min_duration_ms,
    MAX(duration_us / 1000.0) AS max_duration_ms,
    SUM(duration_us / 1000.0) AS total_duration_ms,
    AVG(cpu_time_us / 1000.0) AS avg_cpu_ms,
    SUM(cpu_time_us / 1000.0) AS total_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(physical_reads, 0)) AS total_physical_reads,
    SUM(ISNULL(writes, 0)) AS total_writes,
    LEFT(sql_text, 100) AS sql_text_preview
FROM ParsedEvents
WHERE sql_text IS NOT NULL
GROUP BY LEFT(sql_text, 100)
ORDER BY total_duration_ms DESC;
"@

        $result = Execute-SqlQuery -sql $sql

        if ($result -and $result.Rows.Count -gt 0) {
            Write-Host ""
            Write-Host "Top Queries by Total Duration:" -ForegroundColor Yellow
            $format = "{0,-6} {1,-10} {2,-10} {3,-10} {4,-12} {5,-12} {6,-40}"
            Write-Host ($format -f "Count", "Avg(ms)", "CPU(ms)", "Total(ms)", "Reads", "Writes", "Query")
            Write-Host "-" * 105

            foreach ($row in $result.Rows) {
                $query = if ($row.sql_text_preview.Length -gt 37) { $row.sql_text_preview.Substring(0, 37) + "..." } else { $row.sql_text_preview }
                Write-Host ($format -f $row.execution_count,
                    [math]::Round([double]$row.avg_duration_ms, 2),
                    [math]::Round([double]$row.avg_cpu_ms, 2),
                    [math]::Round([double]$row.total_duration_ms, 0),
                    $row.total_logical_reads,
                    $row.total_writes,
                    $query)
            }
        }

        # ============================================
        # CPU EVENTS ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "CPU EVENTS (Compilation, Parallelism, Stats):" -ForegroundColor Green
        Write-Host "-" * 60

        $cpuSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedCpu AS (
    SELECT
        x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name,
        x.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_us
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN (
        'query_post_compilation_showplan',
        'sql_statement_recompile',
        'degree_of_parallelism',
        'auto_stats'
    )
)
SELECT
    event_name,
    COUNT(*) AS event_count,
    AVG(duration_us / 1000.0) AS avg_duration_ms
FROM ParsedCpu
GROUP BY event_name
ORDER BY event_count DESC;
"@

        $cpuResult = Execute-SqlQuery -sql $cpuSql
        if ($cpuResult -and $cpuResult.Rows.Count -gt 0) {
            Write-Host ("{0,-35} {1,10} {2,15}" -f "Event", "Count", "Avg Duration(ms)")
            Write-Host "-" * 62
            foreach ($row in $cpuResult.Rows) {
                $avgDur = if ($row.avg_duration_ms -ne [DBNull]::Value -and $row.avg_duration_ms -ne $null) { [math]::Round([double]$row.avg_duration_ms, 2) } else { "N/A" }
                Write-Host ("{0,-35} {1,10} {2,15}" -f $row.event_name, $row.event_count, $avgDur)
            }
        } else {
            Write-Host "No CPU events captured"
        }

        # Parallelism details
        $dopSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedDop AS (
    SELECT x.value('(event/data[@name="dop"]/value)[1]', 'int') AS dop
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') = 'degree_of_parallelism'
)
SELECT dop, COUNT(*) AS query_count
FROM ParsedDop
GROUP BY dop
ORDER BY dop;
"@

        $dopResult = Execute-SqlQuery -sql $dopSql
        if ($dopResult -and $dopResult.Rows.Count -gt 0) {
            Write-Host ""
            Write-Host "Parallelism Distribution:" -ForegroundColor Yellow
            foreach ($row in $dopResult.Rows) {
                Write-Host "  DOP $($row.dop): $($row.query_count) queries"
            }
        }

        # ============================================
        # I/O EVENTS ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "I/O EVENTS (Page Splits, Checkpoints, Log Flushes):" -ForegroundColor Green
        Write-Host "-" * 60

        $ioSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedIO AS (
    SELECT
        x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name,
        x.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        x.value('(event/data[@name="size"]/value)[1]', 'bigint') AS size_bytes
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN (
        'page_split',
        'checkpoint_begin',
        'checkpoint_end',
        'log_flush_start',
        'file_read_completed',
        'file_write_completed'
    )
)
SELECT
    event_name,
    COUNT(*) AS event_count,
    AVG(duration_us / 1000.0) AS avg_duration_ms,
    SUM(size_bytes) AS total_size_bytes
FROM ParsedIO
GROUP BY event_name
ORDER BY event_count DESC;
"@

        $ioResult = Execute-SqlQuery -sql $ioSql
        if ($ioResult -and $ioResult.Rows.Count -gt 0) {
            Write-Host ("{0,-25} {1,10} {2,15} {3,15}" -f "Event", "Count", "Avg(ms)", "Total Size")
            Write-Host "-" * 67
            foreach ($row in $ioResult.Rows) {
                $avgDur = if ($row.avg_duration_ms -ne [DBNull]::Value -and $row.avg_duration_ms -ne $null) { [math]::Round([double]$row.avg_duration_ms, 2) } else { "N/A" }
                $size = if ($row.total_size_bytes -ne [DBNull]::Value -and $row.total_size_bytes -ne $null) { "{0:N0}" -f $row.total_size_bytes } else { "N/A" }
                Write-Host ("{0,-25} {1,10} {2,15} {3,15}" -f $row.event_name, $row.event_count, $avgDur, $size)
            }
        } else {
            Write-Host "No I/O events captured"
        }

        # ============================================
        # MEMORY EVENTS ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "MEMORY EVENTS (Spills, Grants):" -ForegroundColor Green
        Write-Host "-" * 60

        $memSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedMem AS (
    SELECT x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN (
        'sort_warning',
        'hash_warning',
        'exchange_spill',
        'memory_grant_updated_by_feedback'
    )
)
SELECT event_name, COUNT(*) AS event_count
FROM ParsedMem
GROUP BY event_name
ORDER BY event_count DESC;
"@

        $memResult = Execute-SqlQuery -sql $memSql
        if ($memResult -and $memResult.Rows.Count -gt 0) {
            Write-Host ("{0,-30} {1,10}" -f "Event", "Count")
            Write-Host "-" * 42
            foreach ($row in $memResult.Rows) {
                Write-Host ("{0,-30} {1,10}" -f $row.event_name, $row.event_count)
            }
            Write-Host ""
            Write-Host "NOTE: Spill events indicate memory pressure - queries spilling to tempdb" -ForegroundColor Yellow
        } else {
            Write-Host "No memory spill events captured (good - no tempdb spills)"
        }

        # ============================================
        # WAIT STATISTICS ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "WAIT STATISTICS:" -ForegroundColor Green
        Write-Host "-" * 60

        $waitSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedWaits AS (
    SELECT
        x.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(100)') AS wait_type,
        x.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_us
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') = 'wait_completed'
)
SELECT TOP 15
    wait_type,
    COUNT(*) AS wait_count,
    SUM(duration_us / 1000.0) AS total_wait_ms,
    AVG(duration_us / 1000.0) AS avg_wait_ms
FROM ParsedWaits
GROUP BY wait_type
ORDER BY total_wait_ms DESC;
"@

        $waitResult = Execute-SqlQuery -sql $waitSql
        if ($waitResult -and $waitResult.Rows.Count -gt 0) {
            Write-Host ("{0,-35} {1,8} {2,12} {3,12}" -f "Wait Type", "Count", "Total(ms)", "Avg(ms)")
            Write-Host "-" * 70
            foreach ($row in $waitResult.Rows) {
                Write-Host ("{0,-35} {1,8} {2,12:N1} {3,12:N2}" -f $row.wait_type, $row.wait_count, $row.total_wait_ms, $row.avg_wait_ms)
            }
        } else {
            Write-Host "No significant waits captured"
        }

        # ============================================
        # LOCK/CONTENTION ANALYSIS
        # ============================================
        Write-Host ""
        Write-Host "LOCK & CONTENTION:" -ForegroundColor Green
        Write-Host "-" * 60

        $lockSql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
ParsedLocks AS (
    SELECT x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN (
        'lock_acquired',
        'lock_escalation',
        'latch_suspend_end',
        'blocked_process_report'
    )
)
SELECT event_name, COUNT(*) AS event_count
FROM ParsedLocks
GROUP BY event_name
ORDER BY event_count DESC;
"@

        $lockResult = Execute-SqlQuery -sql $lockSql
        if ($lockResult -and $lockResult.Rows.Count -gt 0) {
            Write-Host ("{0,-30} {1,10}" -f "Event", "Count")
            Write-Host "-" * 42
            foreach ($row in $lockResult.Rows) {
                Write-Host ("{0,-30} {1,10}" -f $row.event_name, $row.event_count)
            }
        } else {
            Write-Host "No lock contention events captured"
        }

        # ============================================
        # SUMMARY STATISTICS
        # ============================================
        $summarySql = @"
;WITH RawEvents AS (
    SELECT CAST(event_data AS XML) AS x
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
),
Stats AS (
    SELECT
        x.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000.0 AS duration_ms,
        x.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') / 1000.0 AS cpu_ms,
        x.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
        x.value('(event/data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads,
        x.value('(event/data[@name="writes"]/value)[1]', 'bigint') AS writes
    FROM RawEvents
    WHERE x.value('(event/@name)[1]', 'nvarchar(100)') IN ('sql_statement_completed', 'rpc_completed')
)
SELECT
    COUNT(*) AS total_queries,
    SUM(duration_ms) AS total_duration_ms,
    AVG(duration_ms) AS avg_duration_ms,
    MIN(duration_ms) AS min_duration_ms,
    MAX(duration_ms) AS max_duration_ms,
    SUM(cpu_ms) AS total_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(physical_reads, 0)) AS total_physical_reads,
    SUM(ISNULL(writes, 0)) AS total_writes
FROM Stats;
"@

        $summary = Execute-SqlQuery -sql $summarySql
        if ($summary -and $summary.Rows.Count -gt 0) {
            $s = $summary.Rows[0]
            Write-Host ""
            Write-Host "============================================" -ForegroundColor Green
            Write-Host "SUMMARY" -ForegroundColor Green
            Write-Host "============================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Query Execution:"
            Write-Host ("  Total Queries:     {0:N0}" -f $s.total_queries)
            Write-Host ("  Total Duration:    {0:N0} ms" -f $s.total_duration_ms)
            Write-Host ("  Avg Duration:      {0:N2} ms" -f $s.avg_duration_ms)
            Write-Host ("  Min Duration:      {0:N2} ms" -f $s.min_duration_ms)
            Write-Host ("  Max Duration:      {0:N2} ms" -f $s.max_duration_ms)
            Write-Host ""
            Write-Host "Resource Usage:"
            Write-Host ("  Total CPU Time:    {0:N0} ms" -f $s.total_cpu_ms)
            Write-Host ("  Logical Reads:     {0:N0}" -f $s.total_logical_reads)
            Write-Host ("  Physical Reads:    {0:N0}" -f $s.total_physical_reads)
            Write-Host ("  Writes:            {0:N0}" -f $s.total_writes)
        }

        Write-Host ""
        Write-Host "Trace file: $tracePattern" -ForegroundColor Cyan
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

    "export" {
        Show-Header "Exporting XEvents Trace Data"

        $tracePattern = Join-Path $OutputPath "$SessionName*.xel"
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        # Export all raw events with parsed fields
        $exportSql = @"
;WITH RawEvents AS (
    SELECT
        CAST(event_data AS XML) AS x,
        file_name,
        file_offset
    FROM sys.fn_xe_file_target_read_file('$tracePattern', NULL, NULL, NULL)
)
SELECT
    x.value('(event/@name)[1]', 'nvarchar(100)') AS event_name,
    x.value('(event/@timestamp)[1]', 'datetime2') AS event_timestamp,
    x.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
    x.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint') AS cpu_time_us,
    x.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
    x.value('(event/data[@name="physical_reads"]/value)[1]', 'bigint') AS physical_reads,
    x.value('(event/data[@name="writes"]/value)[1]', 'bigint') AS writes,
    x.value('(event/data[@name="row_count"]/value)[1]', 'bigint') AS row_count,
    x.value('(event/data[@name="result"]/text)[1]', 'nvarchar(50)') AS result,
    x.value('(event/data[@name="wait_type"]/text)[1]', 'nvarchar(100)') AS wait_type,
    x.value('(event/data[@name="dop"]/value)[1]', 'int') AS dop,
    x.value('(event/data[@name="mode"]/text)[1]', 'nvarchar(50)') AS lock_mode,
    x.value('(event/data[@name="severity"]/value)[1]', 'int') AS severity,
    x.value('(event/data[@name="error_number"]/value)[1]', 'int') AS error_number,
    x.value('(event/data[@name="message"]/value)[1]', 'nvarchar(max)') AS error_message,
    x.value('(event/data[@name="size"]/value)[1]', 'bigint') AS size_bytes,
    x.value('(event/action[@name="session_id"]/value)[1]', 'int') AS session_id,
    x.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)') AS database_name,
    x.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name,
    x.value('(event/action[@name="username"]/value)[1]', 'nvarchar(256)') AS username,
    x.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
    x.value('(event/action[@name="query_hash"]/value)[1]', 'nvarchar(100)') AS query_hash,
    x.value('(event/action[@name="query_plan_hash"]/value)[1]', 'nvarchar(100)') AS query_plan_hash,
    file_name,
    file_offset
FROM RawEvents
ORDER BY x.value('(event/@timestamp)[1]', 'datetime2');
"@

        Write-Host "Querying trace data..."
        $result = Execute-SqlQuery -sql $exportSql

        if ($result -and $result.Rows.Count -gt 0) {
            $rowCount = $result.Rows.Count
            Write-Host "Found $rowCount events"

            if ($Format -eq "csv") {
                $outputFile = Join-Path $OutputPath "$SessionName-export-$timestamp.csv"

                # Convert DataTable to CSV
                $result | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

                Write-Host "Exported to: $outputFile" -ForegroundColor Green
                Write-Host ""
                Write-Host "CSV columns:" -ForegroundColor Yellow
                Write-Host "  event_name, event_timestamp, duration_us, cpu_time_us,"
                Write-Host "  logical_reads, physical_reads, writes, row_count, result,"
                Write-Host "  wait_type, dop, lock_mode, severity, error_number, error_message,"
                Write-Host "  size_bytes, session_id, database_name, client_app_name,"
                Write-Host "  username, sql_text, query_hash, query_plan_hash,"
                Write-Host "  file_name, file_offset"
            }
            else {
                # JSON export
                $outputFile = Join-Path $OutputPath "$SessionName-export-$timestamp.json"

                # Convert DataTable to array of objects
                $events = @()
                foreach ($row in $result.Rows) {
                    $event = [ordered]@{
                        event_name = if ($row.event_name -ne [DBNull]::Value) { $row.event_name } else { $null }
                        event_timestamp = if ($row.event_timestamp -ne [DBNull]::Value) { $row.event_timestamp.ToString("o") } else { $null }
                        duration_us = if ($row.duration_us -ne [DBNull]::Value) { $row.duration_us } else { $null }
                        cpu_time_us = if ($row.cpu_time_us -ne [DBNull]::Value) { $row.cpu_time_us } else { $null }
                        logical_reads = if ($row.logical_reads -ne [DBNull]::Value) { $row.logical_reads } else { $null }
                        physical_reads = if ($row.physical_reads -ne [DBNull]::Value) { $row.physical_reads } else { $null }
                        writes = if ($row.writes -ne [DBNull]::Value) { $row.writes } else { $null }
                        row_count = if ($row.row_count -ne [DBNull]::Value) { $row.row_count } else { $null }
                        result = if ($row.result -ne [DBNull]::Value) { $row.result } else { $null }
                        wait_type = if ($row.wait_type -ne [DBNull]::Value) { $row.wait_type } else { $null }
                        dop = if ($row.dop -ne [DBNull]::Value) { $row.dop } else { $null }
                        lock_mode = if ($row.lock_mode -ne [DBNull]::Value) { $row.lock_mode } else { $null }
                        severity = if ($row.severity -ne [DBNull]::Value) { $row.severity } else { $null }
                        error_number = if ($row.error_number -ne [DBNull]::Value) { $row.error_number } else { $null }
                        error_message = if ($row.error_message -ne [DBNull]::Value) { $row.error_message } else { $null }
                        size_bytes = if ($row.size_bytes -ne [DBNull]::Value) { $row.size_bytes } else { $null }
                        session_id = if ($row.session_id -ne [DBNull]::Value) { $row.session_id } else { $null }
                        database_name = if ($row.database_name -ne [DBNull]::Value) { $row.database_name } else { $null }
                        client_app_name = if ($row.client_app_name -ne [DBNull]::Value) { $row.client_app_name } else { $null }
                        username = if ($row.username -ne [DBNull]::Value) { $row.username } else { $null }
                        sql_text = if ($row.sql_text -ne [DBNull]::Value) { $row.sql_text } else { $null }
                        query_hash = if ($row.query_hash -ne [DBNull]::Value) { $row.query_hash } else { $null }
                        query_plan_hash = if ($row.query_plan_hash -ne [DBNull]::Value) { $row.query_plan_hash } else { $null }
                    }
                    $events += $event
                }

                $jsonOutput = @{
                    metadata = @{
                        session_name = $SessionName
                        export_time = (Get-Date).ToString("o")
                        event_count = $rowCount
                    }
                    events = $events
                }

                $jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding UTF8

                Write-Host "Exported to: $outputFile" -ForegroundColor Green
            }

            # Show file size
            $fileInfo = Get-Item $outputFile
            $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
            Write-Host "File size: $sizeMB MB"
            Write-Host ""
            Write-Host "Event counts by type:" -ForegroundColor Yellow
            $result.Rows | Group-Object -Property event_name | Sort-Object Count -Descending | ForEach-Object {
                Write-Host ("  {0,-35} {1,8}" -f $_.Name, $_.Count)
            }
        }
        else {
            Write-Host "No trace data found" -ForegroundColor Yellow
            Write-Host "Make sure you have run a trace session first"
        }
    }
}

Write-Host ""
