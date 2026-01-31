# ETW Feature Extraction -- Aligns perf counters & ETL events to SQL statements
param(
    [ValidateSet("features", "power-model")]
    [string]$Action = "features",

    [string]$SqlFeaturesFile,    # auto-detect: BenchmarkTrace-features-*.csv
    [string]$PerfCountersFile,   # auto-detect: PowerActivityTrace-perfcounters.csv
    [string]$EtlFile,            # auto-detect: PowerActivityTrace.etl (optional)
    [string]$RaplFile,           # auto-detect: PowerActivityTrace-rapl.csv (optional, power-model label)
    [int]$WindowMs = 500,        # ±ms window for ETL event aggregation
    [int]$MinEventCount = 5,     # min total occurrences for an ETW event type to get its own column
    [string]$OutputPath = $null  # standard resolution chain
)

# Resolve OutputPath: -OutputPath arg > $env:DBCC_TEMP > ./tmp
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:DBCC_TEMP)) {
        $OutputPath = $env:DBCC_TEMP
    } else {
        $OutputPath = Join-Path $PSScriptRoot "tmp"
    }
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

#region Helper Functions

function Show-Header {
    param([string]$title)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Find-LatestFile {
    param([string]$dir, [string]$pattern)
    $files = Get-ChildItem -Path $dir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($files -and $files.Count -gt 0) {
        return $files[0].FullName
    }
    return $null
}

function Parse-PdhTimestamp {
    param([string]$str)
    if ([string]::IsNullOrWhiteSpace($str)) { return $null }
    $s = $str.Trim('"', ' ')
    $dt = [datetime]::MinValue
    # PDH timestamps: "01/29/2026 12:21:01.060"
    if ([datetime]::TryParse($s, [ref]$dt)) { return $dt }
    return $null
}

function Import-PerfCountersCsv {
    param([string]$path)

    $raw = Import-Csv -Path $path

    if (-not $raw -or $raw.Count -eq 0) {
        Write-Host "  Perf counters CSV is empty" -ForegroundColor Yellow
        return @()
    }

    # Identify columns
    $allCols = $raw[0].PSObject.Properties.Name

    # First column is the timestamp (contains "PDH-CSV 4.0")
    $tsCol = $allCols | Where-Object { $_ -match 'PDH-CSV' } | Select-Object -First 1
    if (-not $tsCol) {
        # Fallback: use the first column
        $tsCol = $allCols[0]
    }

    # Build column name mapping: counter path suffix → short name
    $counterMap = @{
        'Processor(_Total)\% Processor Time'                      = 'cpu_pct'
        'Processor(_Total)\% Idle Time'                           = 'cpu_idle_pct'
        'Processor(_Total)\% Privileged Time'                     = 'cpu_privileged_pct'
        'Processor(_Total)\% User Time'                           = 'cpu_user_pct'
        'Processor(_Total)\% C1 Time'                             = 'cpu_c1_pct'
        'Processor(_Total)\% C2 Time'                             = 'cpu_c2_pct'
        'Processor(_Total)\% C3 Time'                             = 'cpu_c3_pct'
        'Processor Information(_Total)\Processor Frequency'       = 'cpu_freq_mhz'
        'Processor Information(_Total)\% of Maximum Frequency'    = 'cpu_freq_max_pct'
        'Memory\Available MBytes'                                 = 'mem_available_mb'
        'Memory\Pages/sec'                                        = 'mem_pages_sec'
        'Memory\Cache Faults/sec'                                 = 'mem_cache_faults_sec'
        'PhysicalDisk(_Total)\Disk Reads/sec'                     = 'disk_reads_sec'
        'PhysicalDisk(_Total)\Disk Writes/sec'                    = 'disk_writes_sec'
        'PhysicalDisk(_Total)\Disk Bytes/sec'                     = 'disk_bytes_sec'
        'PhysicalDisk(_Total)\Avg. Disk Queue Length'             = 'disk_queue_len'
        'PhysicalDisk(_Total)\% Idle Time'                        = 'disk_idle_pct'
        'System\Context Switches/sec'                             = 'ctx_switches_sec'
        'System\Processor Queue Length'                            = 'proc_queue_len'
    }

    # Network counters need special handling (sum across all NICs)
    # Identify all Network Interface columns
    $netBytesCols = @()
    $netPacketsCols = @()

    # Map actual CSV columns to short names
    $colMapping = @{}  # actual column name → short name
    foreach ($col in $allCols) {
        if ($col -eq $tsCol) { continue }

        # Strip leading \\MACHINENAME\ prefix
        $suffix = $col -replace '^\\\\[^\\]+\\', ''

        # Check against known counters
        foreach ($key in $counterMap.Keys) {
            if ($suffix -eq $key) {
                $colMapping[$col] = $counterMap[$key]
                break
            }
        }

        # Network Interface -- match any NIC instance
        if ($col -match 'Network Interface\(.*\)\\Bytes Total/sec') {
            $netBytesCols += $col
        }
        if ($col -match 'Network Interface\(.*\)\\Packets/sec') {
            $netPacketsCols += $col
        }
    }

    # Parse rows into structured samples
    $samples = [System.Collections.ArrayList]::new()
    foreach ($row in $raw) {
        $ts = Parse-PdhTimestamp $row.$tsCol
        if (-not $ts) { continue }

        $sample = [ordered]@{ timestamp = $ts }

        # Mapped scalar counters
        foreach ($col in $colMapping.Keys) {
            $shortName = $colMapping[$col]
            $val = $row.$col
            if ([string]::IsNullOrWhiteSpace($val) -or $val -eq ' ') {
                $sample[$shortName] = $null
            } else {
                $parsed = 0.0
                if ([double]::TryParse($val, [ref]$parsed)) {
                    $sample[$shortName] = [Math]::Round($parsed, 4)
                } else {
                    $sample[$shortName] = $null
                }
            }
        }

        # Sum network counters across NICs
        $netBytesSum = 0.0
        $netBytesHasValue = $false
        foreach ($col in $netBytesCols) {
            $val = $row.$col
            if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne ' ') {
                $parsed = 0.0
                if ([double]::TryParse($val, [ref]$parsed)) {
                    $netBytesSum += $parsed
                    $netBytesHasValue = $true
                }
            }
        }
        $sample['net_bytes_sec'] = if ($netBytesHasValue) { [Math]::Round($netBytesSum, 4) } else { $null }

        $netPacketsSum = 0.0
        $netPacketsHasValue = $false
        foreach ($col in $netPacketsCols) {
            $val = $row.$col
            if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne ' ') {
                $parsed = 0.0
                if ([double]::TryParse($val, [ref]$parsed)) {
                    $netPacketsSum += $parsed
                    $netPacketsHasValue = $true
                }
            }
        }
        $sample['net_packets_sec'] = if ($netPacketsHasValue) { [Math]::Round($netPacketsSum, 4) } else { $null }

        $samples.Add($sample) | Out-Null
    }

    # Sort by timestamp
    $sorted = @($samples | Sort-Object { $_.timestamp })
    return $sorted
}

function Find-NearestSample {
    param(
        [datetime]$target,
        [array]$sorted  # array of ordered hashtables with .timestamp
    )

    if ($sorted.Count -eq 0) { return $null }

    # Binary search for closest timestamp
    $lo = 0
    $hi = $sorted.Count - 1

    while ($lo -lt $hi) {
        $mid = [Math]::Floor(($lo + $hi) / 2)
        if ($sorted[$mid].timestamp -lt $target) {
            $lo = $mid + 1
        } else {
            $hi = $mid
        }
    }

    # $lo is insertion point; check $lo and $lo-1 for closest
    $bestIdx = $lo
    if ($lo -gt 0) {
        $diffLo = [Math]::Abs(($sorted[$lo].timestamp - $target).TotalMilliseconds)
        $diffPrev = [Math]::Abs(($sorted[$lo - 1].timestamp - $target).TotalMilliseconds)
        if ($diffPrev -lt $diffLo) {
            $bestIdx = $lo - 1
        }
    }

    $offsetMs = ($sorted[$bestIdx].timestamp - $target).TotalMilliseconds
    return @{
        index     = $bestIdx
        offset_ms = [Math]::Round($offsetMs, 1)
    }
}

function Aggregate-EtwWindow {
    param(
        [datetime]$center,
        [int]$windowMs,
        [array]$sorted  # array of hashtables with .timestamp and .category
    )

    if ($sorted.Count -eq 0) {
        return @{ total = 0; process = 0; thread = 0; power = 0 }
    }

    $windowStart = $center.AddMilliseconds(-$windowMs)
    $windowEnd   = $center.AddMilliseconds($windowMs)

    # Binary search for window start
    $lo = 0
    $hi = $sorted.Count - 1
    while ($lo -lt $hi) {
        $mid = [Math]::Floor(($lo + $hi) / 2)
        if ($sorted[$mid].timestamp -lt $windowStart) {
            $lo = $mid + 1
        } else {
            $hi = $mid
        }
    }

    $total = 0
    $process = 0
    $thread = 0
    $power = 0

    for ($i = $lo; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].timestamp -gt $windowEnd) { break }
        $total++
        switch ($sorted[$i].category) {
            'process' { $process++ }
            'thread'  { $thread++ }
            'power'   { $power++ }
        }
    }

    return @{ total = $total; process = $process; thread = $thread; power = $power }
}

#endregion

switch ($Action) {
    "features" {
        Show-Header "ETW Feature Extraction"

        # --- Resolve input files ---

        # SQL features CSV (required)
        if ([string]::IsNullOrWhiteSpace($SqlFeaturesFile)) {
            $SqlFeaturesFile = Find-LatestFile -dir $OutputPath -pattern "BenchmarkTrace-features-*.csv"
        }
        if (-not $SqlFeaturesFile -or -not (Test-Path $SqlFeaturesFile)) {
            Write-Host "No SQL features CSV found in $OutputPath" -ForegroundColor Red
            Write-Host "Run trace-analyze.ps1 -Action features first"
            exit 1
        }

        # Perf counters CSV (required)
        if ([string]::IsNullOrWhiteSpace($PerfCountersFile)) {
            # Try exact name first, then wildcard
            $candidate = Join-Path $OutputPath "PowerActivityTrace-perfcounters.csv"
            if (Test-Path $candidate) {
                $PerfCountersFile = $candidate
            } else {
                $PerfCountersFile = Find-LatestFile -dir $OutputPath -pattern "PowerActivityTrace-perfcounters*.csv"
            }
        }
        if (-not $PerfCountersFile -or -not (Test-Path $PerfCountersFile)) {
            Write-Host "No perf counters CSV found in $OutputPath" -ForegroundColor Red
            Write-Host "Run /power-trace start, then /power-trace stop to collect performance counters"
            exit 1
        }

        # ETL file (optional)
        $hasEtl = $false
        if ([string]::IsNullOrWhiteSpace($EtlFile)) {
            $candidate = Join-Path $OutputPath "PowerActivityTrace.etl"
            if (Test-Path $candidate) {
                $EtlFile = $candidate
                $hasEtl = $true
            }
        } elseif (Test-Path $EtlFile) {
            $hasEtl = $true
        }

        Write-Host "  SQL Features:    $SqlFeaturesFile"
        Write-Host "  Perf Counters:   $PerfCountersFile"
        if ($hasEtl) {
            Write-Host "  ETL File:        $EtlFile"
        } else {
            Write-Host "  ETL File:        (not found, skipping ETW events)"
        }

        # --- Load SQL features CSV ---
        Write-Host ""
        Write-Host "Loading SQL features..."
        $sqlRows = Import-Csv -Path $SqlFeaturesFile
        $sqlCount = @($sqlRows).Count
        Write-Host "  Loaded $sqlCount SQL statements"

        if ($sqlCount -eq 0) {
            Write-Host "SQL features CSV is empty" -ForegroundColor Red
            exit 1
        }

        # --- Load perf counters CSV ---
        Write-Host ""
        Write-Host "Loading performance counters..."
        $perfSamples = Import-PerfCountersCsv -path $PerfCountersFile
        $perfCount = $perfSamples.Count
        Write-Host "  Loaded $perfCount samples"

        if ($perfCount -eq 0) {
            Write-Host "Performance counters CSV is empty or could not be parsed" -ForegroundColor Red
            exit 1
        }

        $firstTs = $perfSamples[0].timestamp
        $lastTs = $perfSamples[-1].timestamp
        Write-Host "  Time range: $($firstTs.ToString('MM/dd/yyyy HH:mm:ss')) - $($lastTs.ToString('MM/dd/yyyy HH:mm:ss'))"

        # --- Convert ETL (optional) ---
        $etwEvents = @()
        if ($hasEtl) {
            Write-Host ""
            Write-Host "Converting ETL to CSV..."
            $etwCsvFile = Join-Path $OutputPath "PowerActivityTrace-etw-temp.csv"

            $traceResult = tracerpt $EtlFile -o $etwCsvFile -of CSV -y 2>&1

            if (Test-Path $etwCsvFile) {
                $etwRaw = Import-Csv -Path $etwCsvFile -ErrorAction SilentlyContinue

                if ($etwRaw -and $etwRaw.Count -gt 0) {
                    Write-Host "  Loaded $($etwRaw.Count) ETW events"

                    # Parse and classify events
                    $parsed = [System.Collections.ArrayList]::new()
                    foreach ($ev in $etwRaw) {
                        $clockTime = $ev.'Clock-Time'
                        if ([string]::IsNullOrWhiteSpace($clockTime)) { continue }

                        # Clock-Time is Windows file time (100ns ticks since 1601)
                        $ticks = 0L
                        if (-not [long]::TryParse($clockTime, [ref]$ticks)) { continue }
                        if ($ticks -le 0) { continue }

                        try {
                            $dt = [datetime]::FromFileTimeUtc($ticks)
                        } catch {
                            continue
                        }

                        # Classify by Event Name
                        $eventName = $ev.'Event Name'
                        $category = 'other'
                        if ($eventName -match 'Process') { $category = 'process' }
                        elseif ($eventName -match 'Thread') { $category = 'thread' }
                        elseif ($eventName -match 'Power|Acpi|Pep|PDC|Processor') { $category = 'power' }

                        $parsed.Add(@{
                            timestamp = $dt
                            category  = $category
                        }) | Out-Null
                    }

                    $etwEvents = @($parsed | Sort-Object { $_.timestamp })
                    Write-Host "  Classified $($etwEvents.Count) events (Process/Thread/Power/Other)"
                }

                # Clean up temp file
                Remove-Item $etwCsvFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "  ETL conversion failed, skipping ETW events" -ForegroundColor Yellow
            }
        }

        # --- Align SQL statements to perf counter samples ---
        Write-Host ""
        Write-Host "Aligning $sqlCount statements to perf counter samples..."

        $outputRows = [System.Collections.ArrayList]::new()
        $offsets = [System.Collections.ArrayList]::new()

        # Short names for perf columns (order matters for output)
        $perfColNames = @(
            'cpu_pct', 'cpu_idle_pct', 'cpu_privileged_pct', 'cpu_user_pct',
            'cpu_c1_pct', 'cpu_c2_pct', 'cpu_c3_pct',
            'cpu_freq_mhz', 'cpu_freq_max_pct',
            'mem_available_mb', 'mem_pages_sec', 'mem_cache_faults_sec',
            'disk_reads_sec', 'disk_writes_sec', 'disk_bytes_sec', 'disk_queue_len', 'disk_idle_pct',
            'net_bytes_sec', 'net_packets_sec',
            'ctx_switches_sec', 'proc_queue_len'
        )

        foreach ($sqlRow in $sqlRows) {
            $stmtTs = [datetime]::MinValue
            if (-not [datetime]::TryParse($sqlRow.event_timestamp, [ref]$stmtTs)) { continue }

            # Find nearest perf sample
            $nearest = Find-NearestSample -target $stmtTs -sorted $perfSamples
            $sample = $perfSamples[$nearest.index]
            $offsetMs = $nearest.offset_ms
            $offsets.Add([Math]::Abs($offsetMs)) | Out-Null

            # Build output row
            $row = [ordered]@{
                row_id             = $sqlRow.row_id
                session_id         = $sqlRow.session_id
                event_timestamp    = $sqlRow.event_timestamp
                sample_offset_ms   = $offsetMs
            }

            # Perf counter columns
            foreach ($col in $perfColNames) {
                $row[$col] = $sample[$col]
            }

            # Derived columns
            $cpuIdle = $sample['cpu_idle_pct']
            $row['cpu_busy_pct'] = if ($null -ne $cpuIdle) { [Math]::Round(100 - $cpuIdle, 4) } else { $null }

            $diskReads = $sample['disk_reads_sec']
            $diskWrites = $sample['disk_writes_sec']
            $row['disk_iops'] = if ($null -ne $diskReads -and $null -ne $diskWrites) { [Math]::Round($diskReads + $diskWrites, 4) } else { $null }

            # ETW event aggregation
            if ($etwEvents.Count -gt 0) {
                $agg = Aggregate-EtwWindow -center $stmtTs -windowMs $WindowMs -sorted $etwEvents
                $row['etw_event_count']   = $agg.total
                $row['etw_process_events'] = $agg.process
                $row['etw_thread_events']  = $agg.thread
                $row['etw_power_events']   = $agg.power
            } else {
                $row['etw_event_count']   = $null
                $row['etw_process_events'] = $null
                $row['etw_thread_events']  = $null
                $row['etw_power_events']   = $null
            }

            $outputRows.Add([PSCustomObject]$row) | Out-Null
        }

        # --- Export CSV ---
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $csvFile = Join-Path $OutputPath "PowerActivityTrace-features-$timestamp.csv"
        $outputRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

        # --- Console summary ---
        $totalRows = $outputRows.Count
        $totalCols = if ($totalRows -gt 0) { $outputRows[0].PSObject.Properties.Name.Count } else { 0 }

        $avgOffset = 0.0
        $maxOffset = 0.0
        if ($offsets.Count -gt 0) {
            $avgOffset = [Math]::Round(($offsets | Measure-Object -Average).Average, 1)
            $maxOffset = [Math]::Round(($offsets | Measure-Object -Maximum).Maximum, 1)
        }

        Write-Host ""
        Write-Host "FEATURE SUMMARY" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "  Input:"
        Write-Host "    SQL statements:        $sqlCount"
        Write-Host "    Perf counter samples:  $perfCount"
        if ($etwEvents.Count -gt 0) {
            Write-Host "    ETW events:            $($etwEvents.Count)"
        }
        Write-Host ""
        Write-Host "  Output:"
        Write-Host "    Rows:                  $totalRows"
        Write-Host "    Columns:               $totalCols"
        Write-Host ""
        Write-Host "  Timestamp alignment:"
        Write-Host "    Avg offset:            $avgOffset ms"
        Write-Host "    Max offset:            $maxOffset ms"

        Write-Host ""
        Write-Host "Output: $csvFile" -ForegroundColor Green
        $fileInfo = Get-Item $csvFile
        $sizeMB = [math]::Round($fileInfo.Length / 1MB, 1)
        $sizeKB = [math]::Round($fileInfo.Length / 1KB, 1)
        if ($sizeMB -ge 1) {
            Write-Host "File size: $sizeMB MB"
        } else {
            Write-Host "File size: $sizeKB KB"
        }

        Write-Host ""
        Write-Host "TIP: Join with SQL features on row_id for combined ML dataset" -ForegroundColor Yellow
    }

    "power-model" {
        Show-Header "ETW Power Model Features"

        # --- Resolve input files ---

        # Perf counters CSV (required)
        if ([string]::IsNullOrWhiteSpace($PerfCountersFile)) {
            $candidate = Join-Path $OutputPath "PowerActivityTrace-perfcounters.csv"
            if (Test-Path $candidate) {
                $PerfCountersFile = $candidate
            } else {
                $PerfCountersFile = Find-LatestFile -dir $OutputPath -pattern "PowerActivityTrace-perfcounters*.csv"
            }
        }
        if (-not $PerfCountersFile -or -not (Test-Path $PerfCountersFile)) {
            Write-Host "No perf counters CSV found in $OutputPath" -ForegroundColor Red
            Write-Host "Run /power-trace start, then /power-trace stop to collect performance counters"
            exit 1
        }

        # ETL file (optional)
        $hasEtl = $false
        if ([string]::IsNullOrWhiteSpace($EtlFile)) {
            $candidate = Join-Path $OutputPath "PowerActivityTrace.etl"
            if (Test-Path $candidate) {
                $EtlFile = $candidate
                $hasEtl = $true
            }
        } elseif (Test-Path $EtlFile) {
            $hasEtl = $true
        }

        # RAPL file (optional -- label source)
        $hasRapl = $false
        if ([string]::IsNullOrWhiteSpace($RaplFile)) {
            $candidate = Join-Path $OutputPath "PowerActivityTrace-rapl.csv"
            if (Test-Path $candidate) {
                $RaplFile = $candidate
                $hasRapl = $true
            }
        } elseif (Test-Path $RaplFile) {
            $hasRapl = $true
        }

        Write-Host "  Perf Counters:   $PerfCountersFile"
        if ($hasEtl) {
            Write-Host "  ETL File:        $EtlFile"
        } else {
            Write-Host "  ETL File:        (not found, skipping ETW events)"
        }
        if ($hasRapl) {
            Write-Host "  RAPL File:       $RaplFile"
        } else {
            Write-Host "  RAPL File:       (not found, no label columns)"
        }

        # --- Load perf counters CSV ---
        Write-Host ""
        Write-Host "Loading performance counters..."
        $perfSamples = Import-PerfCountersCsv -path $PerfCountersFile
        $perfCount = $perfSamples.Count

        if ($perfCount -eq 0) {
            Write-Host "Performance counters CSV is empty or could not be parsed" -ForegroundColor Red
            exit 1
        }

        $firstTs = $perfSamples[0].timestamp
        $lastTs  = $perfSamples[-1].timestamp
        Write-Host "  Loaded $perfCount samples"

        # Compute sample interval from first two samples (fallback 1s)
        $sampleIntervalMs = 1000.0
        if ($perfCount -ge 2) {
            $sampleIntervalMs = ($perfSamples[1].timestamp - $perfSamples[0].timestamp).TotalMilliseconds
            if ($sampleIntervalMs -le 0) { $sampleIntervalMs = 1000.0 }
        }
        $intervalSec = [Math]::Round($sampleIntervalMs / 1000, 1)
        Write-Host "  Sample interval: ${intervalSec}s"
        Write-Host "  Time range: $($firstTs.ToString('MM/dd/yyyy HH:mm:ss')) - $($lastTs.ToString('MM/dd/yyyy HH:mm:ss'))"

        # --- Convert ETL (optional) ---
        $etwEventsSorted = @()   # array of hashtables with .timestamp and .event_name
        $etwColumnNames = @()    # sanitized column names for events above threshold
        $etwEventNameToCol = @{} # event_name → column name (for events above threshold)
        $etwDiscoveredCount = 0
        $etwKeptCount = 0
        $etwMergedCount = 0

        if ($hasEtl) {
            Write-Host ""
            Write-Host "Converting ETL to CSV..."
            $etwCsvFile = Join-Path $OutputPath "PowerActivityTrace-etw-temp.csv"

            $traceResult = tracerpt $EtlFile -o $etwCsvFile -of CSV -y 2>&1

            if (Test-Path $etwCsvFile) {
                $etwRaw = Import-Csv -Path $etwCsvFile -ErrorAction SilentlyContinue

                if ($etwRaw -and $etwRaw.Count -gt 0) {
                    Write-Host "  Loaded $($etwRaw.Count) ETW events"

                    # Parse events -- keep event name and timestamp
                    $parsed = [System.Collections.ArrayList]::new()
                    $eventCounts = @{} # event_name → total count
                    foreach ($ev in $etwRaw) {
                        $clockTime = $ev.'Clock-Time'
                        if ([string]::IsNullOrWhiteSpace($clockTime)) { continue }

                        $ticks = 0L
                        if (-not [long]::TryParse($clockTime, [ref]$ticks)) { continue }
                        if ($ticks -le 0) { continue }

                        try {
                            $dt = [datetime]::FromFileTimeUtc($ticks)
                        } catch {
                            continue
                        }

                        $eventName = $ev.'Event Name'
                        if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Unknown' }

                        $parsed.Add(@{
                            timestamp  = $dt
                            event_name = $eventName
                        }) | Out-Null

                        if ($eventCounts.ContainsKey($eventName)) {
                            $eventCounts[$eventName]++
                        } else {
                            $eventCounts[$eventName] = 1
                        }
                    }

                    $etwEventsSorted = @($parsed | Sort-Object { $_.timestamp })

                    # Discover event types and decide which get their own column
                    $etwDiscoveredCount = $eventCounts.Count

                    foreach ($kvp in $eventCounts.GetEnumerator()) {
                        if ($kvp.Value -ge $MinEventCount) {
                            # Sanitize: lowercase, spaces → _, remove non-alphanumeric/underscore
                            $sanitized = $kvp.Key.ToLower() -replace '\s+', '_'
                            $sanitized = $sanitized -replace '[^a-z0-9_]', ''
                            $colName = "etw_$sanitized"
                            $etwEventNameToCol[$kvp.Key] = $colName
                        }
                    }

                    # Sort column names for deterministic output
                    $etwColumnNames = @($etwEventNameToCol.Values | Sort-Object)
                    $etwKeptCount = $etwColumnNames.Count
                    $etwMergedCount = $etwDiscoveredCount - $etwKeptCount

                    Write-Host "  Discovered $etwDiscoveredCount distinct event types"
                    Write-Host "  Kept $etwKeptCount event types (>= $MinEventCount occurrences), $etwMergedCount merged into etw_other"
                }

                # Clean up temp file
                Remove-Item $etwCsvFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "  ETL conversion failed, skipping ETW events" -ForegroundColor Yellow
                $hasEtl = $false
            }
        }

        # --- Load RAPL data (optional) ---
        $raplSamples = @()
        if ($hasRapl) {
            Write-Host ""
            Write-Host "Loading RAPL data..."
            $raplRaw = Import-Csv -Path $RaplFile -ErrorAction SilentlyContinue

            if ($raplRaw -and $raplRaw.Count -gt 0) {
                $raplParsed = [System.Collections.ArrayList]::new()
                foreach ($row in $raplRaw) {
                    $ts = $null
                    # Try Timestamp column first, then common variants
                    $tsStr = $row.Timestamp
                    if ([string]::IsNullOrWhiteSpace($tsStr)) { $tsStr = $row.timestamp }
                    if ([string]::IsNullOrWhiteSpace($tsStr)) { $tsStr = $row.Time }
                    if ([string]::IsNullOrWhiteSpace($tsStr)) { continue }

                    $dt = [datetime]::MinValue
                    if (-not [datetime]::TryParse($tsStr, [ref]$dt)) { continue }

                    $pkg = 0.0; $core = 0.0; $dram = 0.0; $est = 0.0
                    [double]::TryParse($row.PackagePower_W,    [ref]$pkg)  | Out-Null
                    [double]::TryParse($row.CorePower_W,       [ref]$core) | Out-Null
                    [double]::TryParse($row.DRAMPower_W,       [ref]$dram) | Out-Null
                    [double]::TryParse($row.EstimatedTotal_W,  [ref]$est)  | Out-Null

                    $raplParsed.Add([ordered]@{
                        timestamp      = $dt
                        package_w      = [Math]::Round($pkg, 4)
                        core_w         = [Math]::Round($core, 4)
                        dram_w         = [Math]::Round($dram, 4)
                        estimated_w    = [Math]::Round($est, 4)
                    }) | Out-Null
                }

                $raplSamples = @($raplParsed | Sort-Object { $_.timestamp })
                Write-Host "  Loaded $($raplSamples.Count) RAPL samples"

                if ($raplSamples.Count -eq 0) {
                    Write-Host "  RAPL CSV has no parseable rows, skipping labels" -ForegroundColor Yellow
                    $hasRapl = $false
                }
            } else {
                Write-Host "  RAPL CSV is empty, skipping labels" -ForegroundColor Yellow
                $hasRapl = $false
            }
        }

        # --- Build feature rows (one per perf counter sample) ---
        Write-Host ""
        Write-Host "Building feature matrix..."

        $perfColNames = @(
            'cpu_pct', 'cpu_idle_pct', 'cpu_privileged_pct', 'cpu_user_pct',
            'cpu_c1_pct', 'cpu_c2_pct', 'cpu_c3_pct',
            'cpu_freq_mhz', 'cpu_freq_max_pct',
            'mem_available_mb', 'mem_pages_sec', 'mem_cache_faults_sec',
            'disk_reads_sec', 'disk_writes_sec', 'disk_bytes_sec', 'disk_queue_len', 'disk_idle_pct',
            'net_bytes_sec', 'net_packets_sec',
            'ctx_switches_sec', 'proc_queue_len'
        )

        $outputRows = [System.Collections.ArrayList]::new()
        $raplOffsets = [System.Collections.ArrayList]::new()

        # Precompute ETW search pointer (scan forward through sorted events)
        $etwScanIdx = 0

        for ($i = 0; $i -lt $perfCount; $i++) {
            $sample = $perfSamples[$i]
            $sampleTs = $sample.timestamp

            # Window: [sample[i].timestamp, sample[i+1].timestamp)
            # Last sample: use sample interval
            if ($i -lt $perfCount - 1) {
                $windowEnd = $perfSamples[$i + 1].timestamp
            } else {
                $windowEnd = $sampleTs.AddMilliseconds($sampleIntervalMs)
            }

            # Build row
            $row = [ordered]@{
                sample_idx = $i
                timestamp  = $sampleTs.ToString('MM/dd/yyyy HH:mm:ss.fff')
            }

            # Perf counter columns
            foreach ($col in $perfColNames) {
                $row[$col] = $sample[$col]
            }

            # Derived columns
            $cpuIdle = $sample['cpu_idle_pct']
            $row['cpu_busy_pct'] = if ($null -ne $cpuIdle) { [Math]::Round(100 - $cpuIdle, 4) } else { $null }

            $diskReads  = $sample['disk_reads_sec']
            $diskWrites = $sample['disk_writes_sec']
            $row['disk_iops'] = if ($null -ne $diskReads -and $null -ne $diskWrites) { [Math]::Round($diskReads + $diskWrites, 4) } else { $null }

            # ETW event aggregation (per event type)
            if ($etwEventsSorted.Count -gt 0) {
                # Initialize counters
                $etwCounts = @{}
                foreach ($colName in $etwColumnNames) {
                    $etwCounts[$colName] = 0
                }
                $etwOther = 0
                $etwTotal = 0

                # Advance scan pointer to window start
                while ($etwScanIdx -lt $etwEventsSorted.Count -and $etwEventsSorted[$etwScanIdx].timestamp -lt $sampleTs) {
                    $etwScanIdx++
                }

                # Count events in [sampleTs, windowEnd)
                $j = $etwScanIdx
                while ($j -lt $etwEventsSorted.Count -and $etwEventsSorted[$j].timestamp -lt $windowEnd) {
                    $evName = $etwEventsSorted[$j].event_name
                    $etwTotal++

                    if ($etwEventNameToCol.ContainsKey($evName)) {
                        $mappedCol = $etwEventNameToCol[$evName]
                        $etwCounts[$mappedCol]++
                    } else {
                        $etwOther++
                    }
                    $j++
                }

                # Write ETW columns
                foreach ($colName in $etwColumnNames) {
                    $row[$colName] = $etwCounts[$colName]
                }
                $row['etw_other'] = $etwOther
                $row['etw_total'] = $etwTotal
            }

            # RAPL label columns
            if ($hasRapl) {
                $nearest = Find-NearestSample -target $sampleTs -sorted $raplSamples
                $raplRow = $raplSamples[$nearest.index]
                $row['rapl_package_w']   = $raplRow.package_w
                $row['rapl_core_w']      = $raplRow.core_w
                $row['rapl_dram_w']      = $raplRow.dram_w
                $row['rapl_estimated_w'] = $raplRow.estimated_w
                $row['rapl_offset_ms']   = $nearest.offset_ms
                $raplOffsets.Add([Math]::Abs($nearest.offset_ms)) | Out-Null
            }

            $outputRows.Add([PSCustomObject]$row) | Out-Null
        }

        # --- Export CSV ---
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $csvFile = Join-Path $OutputPath "PowerModel-features-$timestamp.csv"
        $outputRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

        # --- Console summary ---
        $totalRows = $outputRows.Count
        $totalCols = if ($totalRows -gt 0) { $outputRows[0].PSObject.Properties.Name.Count } else { 0 }

        # Count column categories
        $identityCols = 2
        $perfCols = $perfColNames.Count + 2  # +2 for derived (cpu_busy_pct, disk_iops)
        $etwColCount = 0
        $labelColCount = 0

        if ($etwEventsSorted.Count -gt 0) {
            $etwColCount = $etwColumnNames.Count + 2  # + etw_other + etw_total
        }
        if ($hasRapl) {
            $labelColCount = 5  # package, core, dram, estimated, offset
        }

        Write-Host ""
        Write-Host "FEATURE SUMMARY" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "  Rows:              $totalRows"
        Write-Host "  Columns:           $totalCols  ($perfCols perf + $etwColCount etw + $identityCols identity)"
        if ($hasRapl) {
            Write-Host "  Label columns:     $labelColCount   (RAPL present)"
        } else {
            Write-Host "  Label columns:     0   (RAPL not found -- inference mode)"
        }
        if ($etwEventsSorted.Count -gt 0) {
            Write-Host "  ETW event types:   $etwKeptCount  (+ etw_other + etw_total)"
        }

        if ($hasRapl -and $raplOffsets.Count -gt 0) {
            $avgRaplOffset = [Math]::Round(($raplOffsets | Measure-Object -Average).Average, 1)
            $maxRaplOffset = [Math]::Round(($raplOffsets | Measure-Object -Maximum).Maximum, 1)
            Write-Host ""
            Write-Host "  RAPL alignment:"
            Write-Host "    Avg offset:      $avgRaplOffset ms"
            Write-Host "    Max offset:      $maxRaplOffset ms"
        }

        Write-Host ""
        Write-Host "Output: $csvFile" -ForegroundColor Green
        $fileInfo = Get-Item $csvFile
        $sizeMB = [math]::Round($fileInfo.Length / 1MB, 1)
        $sizeKB = [math]::Round($fileInfo.Length / 1KB, 1)
        if ($sizeMB -ge 1) {
            Write-Host "File size: $sizeMB MB"
        } else {
            Write-Host "File size: $sizeKB KB"
        }

        Write-Host ""
        if ($hasRapl) {
            Write-Host "TIP: Use rapl_package_w or rapl_estimated_w as training label" -ForegroundColor Yellow
        } else {
            Write-Host "TIP: Re-run with RAPL data to add power labels for training" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
