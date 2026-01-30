# SQL Server Trace Analysis Script
# Analyzes XEvents trace CSV exports for patterns and anomalies
param(
    [ValidateSet("patterns", "features")]
    [string]$Action = "patterns",

    [string]$InputFile,
    [int]$MinSequenceLength = 2,
    [int]$MaxSequenceLength = 10,
    [int]$MinOccurrences = 2,
    [string]$OutputPath = $null,
    [switch]$IncludeStringLiterals
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

function Show-Header {
    param([string]$title)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Normalize-SqlText {
    param([string]$sql)

    if ([string]::IsNullOrWhiteSpace($sql)) { return $null }

    $n = $sql.Trim()

    # Replace Unicode string literals: N'...' -> ?
    $n = [regex]::Replace($n, "N'[^']*'", '?')

    # Replace regular string literals: '...' -> ?
    $n = [regex]::Replace($n, "'[^']*'", '?')

    # Replace GUID patterns (with or without surrounding quotes already handled)
    $n = [regex]::Replace($n, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '?')

    # Replace hex literals: 0x1A2B -> ?
    $n = [regex]::Replace($n, '0x[0-9a-fA-F]+', '?')

    # Replace numeric literals (integers and decimals) that appear as values
    # Match numbers preceded by operator/keyword boundary, not part of identifiers
    $n = [regex]::Replace($n, '(?<=[\s=<>!,(+\-*/])-?\d+\.?\d*(?=[\s,);]|$)', '?')

    # Collapse whitespace
    $n = [regex]::Replace($n, '\s+', ' ')

    return $n.Trim()
}

function Parse-Numeric {
    param([string]$val)
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    $out = 0.0
    if ([double]::TryParse($val, [ref]$out)) { return $out }
    return $null
}

function Get-Percentile {
    param([double[]]$sorted, [double]$p)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count -eq 1) { return $sorted[0] }
    $rank = ($p / 100.0) * ($sorted.Count - 1)
    $lower = [Math]::Floor($rank)
    $upper = [Math]::Ceiling($rank)
    if ($lower -eq $upper) { return $sorted[$lower] }
    $frac = $rank - $lower
    return $sorted[$lower] * (1 - $frac) + $sorted[$upper] * $frac
}

function Compute-FieldStats {
    param([System.Collections.ArrayList]$values)
    $nums = @($values | Where-Object { $_ -ne $null })
    if ($nums.Count -eq 0) {
        return [ordered]@{ count = 0; min = $null; max = $null; avg = $null; p50 = $null; p95 = $null; sum = $null }
    }
    $sorted = @($nums | Sort-Object)
    return [ordered]@{
        count = $nums.Count
        min   = $sorted[0]
        max   = $sorted[-1]
        avg   = [Math]::Round(($sorted | Measure-Object -Average).Average, 2)
        p50   = [Math]::Round((Get-Percentile -sorted $sorted -p 50), 2)
        p95   = [Math]::Round((Get-Percentile -sorted $sorted -p 95), 2)
        sum   = [Math]::Round(($sorted | Measure-Object -Sum).Sum, 2)
    }
}

function Find-LatestExportCsv {
    param([string]$dir)

    $files = Get-ChildItem -Path $dir -Filter "BenchmarkTrace-export-*.csv" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($files -and $files.Count -gt 0) {
        return $files[0].FullName
    }
    return $null
}

function Extract-NumericLiterals {
    param([string]$sql)
    if ([string]::IsNullOrWhiteSpace($sql)) { return @() }
    $matches = [regex]::Matches($sql, '(?<=[\s=<>!,(+\-*/])-?\d+\.?\d*(?=[\s,);]|$)')
    $result = @()
    foreach ($m in $matches) {
        $val = 0.0
        if ([double]::TryParse($m.Value, [ref]$val)) {
            $result += $val
        }
    }
    return $result
}

function Extract-StringLiterals {
    param([string]$sql)
    if ([string]::IsNullOrWhiteSpace($sql)) { return @() }
    $matches = [regex]::Matches($sql, "N?'([^']*)'")
    $result = @()
    foreach ($m in $matches) {
        $content = $m.Groups[1].Value
        $result += @{
            content = $content
            length  = $content.Length
        }
    }
    return $result
}

switch ($Action) {
    "patterns" {
        Show-Header "SQL Sequence Pattern Detection"

        # Resolve input file
        if ([string]::IsNullOrWhiteSpace($InputFile)) {
            $InputFile = Find-LatestExportCsv -dir $OutputPath
            if (-not $InputFile) {
                Write-Host "No CSV export found in $OutputPath" -ForegroundColor Red
                Write-Host "Export trace data first: .\xevents-trace.ps1 -Action export"
                exit 1
            }
            Write-Host "Auto-detected: $InputFile"
        }
        elseif (-not (Test-Path $InputFile)) {
            Write-Host "File not found: $InputFile" -ForegroundColor Red
            exit 1
        }

        Write-Host "Loading CSV..."
        $allRows = Import-Csv -Path $InputFile

        # Filter to statement/batch completed events with sql_text
        $events = $allRows | Where-Object {
            ($_.event_name -eq 'sql_statement_completed' -or $_.event_name -eq 'sql_batch_completed') -and
            -not [string]::IsNullOrWhiteSpace($_.sql_text) -and
            -not [string]::IsNullOrWhiteSpace($_.session_id)
        }

        $totalFiltered = @($events).Count
        Write-Host "Filtered to $totalFiltered statement/batch events"

        if ($totalFiltered -eq 0) {
            Write-Host "No SQL statement events found in the trace data" -ForegroundColor Yellow
            exit 0
        }

        # Group by session_id, order by timestamp within each session
        Write-Host "Grouping by session..."
        $sessions = @{}
        foreach ($ev in $events) {
            $sid = $ev.session_id
            if (-not $sessions.ContainsKey($sid)) {
                $sessions[$sid] = [System.Collections.ArrayList]::new()
            }
            $sessions[$sid].Add($ev) | Out-Null
        }

        Write-Host "Found $($sessions.Count) distinct sessions"

        # Sort each session by timestamp and build normalized fingerprint sequences
        Write-Host "Normalizing SQL and building sequences..."
        $sessionSequences = @{}
        foreach ($sid in $sessions.Keys) {
            $sorted = $sessions[$sid] | Sort-Object { [datetime]$_.event_timestamp }
            $fingerprints = [System.Collections.ArrayList]::new()
            foreach ($ev in $sorted) {
                $norm = Normalize-SqlText -sql $ev.sql_text
                if ($norm) {
                    $fingerprints.Add(@{
                        fingerprint    = $norm
                        timestamp      = $ev.event_timestamp
                        event_name     = $ev.event_name
                        sql_text       = $ev.sql_text
                        duration_us    = Parse-Numeric $ev.duration_us
                        cpu_time_us    = Parse-Numeric $ev.cpu_time_us
                        logical_reads  = Parse-Numeric $ev.logical_reads
                        physical_reads = Parse-Numeric $ev.physical_reads
                        writes         = Parse-Numeric $ev.writes
                        row_count      = Parse-Numeric $ev.row_count
                    }) | Out-Null
                }
            }
            if ($fingerprints.Count -ge $MinSequenceLength) {
                $sessionSequences[$sid] = $fingerprints
            }
        }

        Write-Host "Sessions with enough events: $($sessionSequences.Count)"

        # Build n-grams across all sessions
        Write-Host "Building n-grams (n=$MinSequenceLength..$MaxSequenceLength)..."
        # Key: fingerprint sequence joined by " ||| ", Value: list of (session_id, start_index)
        $ngramCounts = @{}

        foreach ($sid in $sessionSequences.Keys) {
            $seq = $sessionSequences[$sid]
            $seqLen = $seq.Count

            for ($n = $MinSequenceLength; $n -le [Math]::Min($MaxSequenceLength, $seqLen); $n++) {
                for ($i = 0; $i -le ($seqLen - $n); $i++) {
                    # Build the n-gram key from fingerprints
                    $parts = @()
                    for ($j = $i; $j -lt ($i + $n); $j++) {
                        $parts += $seq[$j].fingerprint
                    }
                    $key = $parts -join ' ||| '

                    if (-not $ngramCounts.ContainsKey($key)) {
                        $ngramCounts[$key] = [System.Collections.ArrayList]::new()
                    }
                    $ngramCounts[$key].Add(@{
                        session_id  = $sid
                        start_index = $i
                        n           = $n
                    }) | Out-Null
                }
            }
        }

        Write-Host "Total unique n-gram patterns: $($ngramCounts.Count)"

        # Filter by minimum occurrences
        $filtered = @{}
        foreach ($key in $ngramCounts.Keys) {
            if ($ngramCounts[$key].Count -ge $MinOccurrences) {
                $filtered[$key] = $ngramCounts[$key]
            }
        }

        Write-Host "Patterns with >= $MinOccurrences occurrences: $($filtered.Count)"

        if ($filtered.Count -eq 0) {
            Write-Host ""
            Write-Host "No repeating sequence patterns found." -ForegroundColor Yellow
            Write-Host "Try lowering -MinOccurrences or -MinSequenceLength"
            exit 0
        }

        # Remove subsumed patterns:
        # A shorter pattern is subsumed by a longer one if:
        #   1. The shorter pattern's fingerprint sequence is a contiguous sub-sequence of the longer one
        #   2. The longer pattern still meets the minimum occurrence threshold
        # This handles monotonic workloads where A→A at length 2 is subsumed by A→A→A at length 3, etc.
        Write-Host "Removing subsumed patterns..."
        $patternKeys = @($filtered.Keys)

        # Build lookup: for each pattern, store its length and count
        $patternInfo = @{}
        foreach ($key in $patternKeys) {
            $parts = $key -split ' \|\|\| '
            $patternInfo[$key] = @{
                length = $parts.Count
                count  = $filtered[$key].Count
            }
        }

        # Sort by length descending so longer patterns are checked first
        $sortedKeys = $patternKeys | Sort-Object { $patternInfo[$_].length } -Descending

        $subsumed = @{}
        foreach ($longerKey in $sortedKeys) {
            $longerLen = $patternInfo[$longerKey].length

            if ($subsumed.ContainsKey($longerKey)) { continue }

            # Check all shorter patterns to see if they are subsumed
            foreach ($shorterKey in $sortedKeys) {
                if ($shorterKey -eq $longerKey) { continue }
                if ($subsumed.ContainsKey($shorterKey)) { continue }
                if ($patternInfo[$shorterKey].length -ge $longerLen) { continue }

                # Shorter is subsumed if it is a contiguous sub-sequence of the longer pattern
                if ($longerKey.Contains($shorterKey)) {
                    $subsumed[$shorterKey] = $true
                }
            }
        }

        foreach ($key in $subsumed.Keys) {
            $filtered.Remove($key)
        }

        Write-Host "After removing subsumed: $($filtered.Count) patterns"

        # Build output structures sorted by count descending
        Write-Host "Computing performance statistics..."
        $patterns = @()
        foreach ($key in $filtered.Keys) {
            $parts = $key -split ' \|\|\| '
            $occurrences = $filtered[$key]
            $count = $occurrences.Count

            # Get sample occurrence details
            $sample = $occurrences[0]
            $sampleSid = $sample.session_id
            $sampleIdx = $sample.start_index
            $sampleSeq = $sessionSequences[$sampleSid]

            $sampleTimestamps = @()
            $sampleSqlTexts = @()
            for ($j = $sampleIdx; $j -lt ($sampleIdx + $parts.Count); $j++) {
                if ($j -lt $sampleSeq.Count) {
                    $sampleTimestamps += $sampleSeq[$j].timestamp
                    $sampleSqlTexts += $sampleSeq[$j].sql_text
                }
            }

            # Count distinct sessions that contain this pattern
            $distinctSessions = ($occurrences | ForEach-Object { $_.session_id } | Select-Object -Unique).Count

            # Aggregate performance metrics across all events in all occurrences
            $perfDuration    = [System.Collections.ArrayList]::new()
            $perfCpu         = [System.Collections.ArrayList]::new()
            $perfLogReads    = [System.Collections.ArrayList]::new()
            $perfPhysReads   = [System.Collections.ArrayList]::new()
            $perfWrites      = [System.Collections.ArrayList]::new()
            $perfRowCount    = [System.Collections.ArrayList]::new()
            # Per-sequence totals (sum of all steps in one occurrence)
            $seqDurations    = [System.Collections.ArrayList]::new()
            $seqLogReads     = [System.Collections.ArrayList]::new()

            foreach ($occ in $occurrences) {
                $seq = $sessionSequences[$occ.session_id]
                $seqDur = 0.0
                $seqLR  = 0.0
                $hasSeqDur = $false
                for ($j = $occ.start_index; $j -lt ($occ.start_index + $parts.Count); $j++) {
                    if ($j -lt $seq.Count) {
                        $ev = $seq[$j]
                        if ($ev.duration_us -ne $null)    { $perfDuration.Add($ev.duration_us) | Out-Null; $seqDur += $ev.duration_us; $hasSeqDur = $true }
                        if ($ev.cpu_time_us -ne $null)    { $perfCpu.Add($ev.cpu_time_us) | Out-Null }
                        if ($ev.logical_reads -ne $null)  { $perfLogReads.Add($ev.logical_reads) | Out-Null; $seqLR += $ev.logical_reads }
                        if ($ev.physical_reads -ne $null) { $perfPhysReads.Add($ev.physical_reads) | Out-Null }
                        if ($ev.writes -ne $null)         { $perfWrites.Add($ev.writes) | Out-Null }
                        if ($ev.row_count -ne $null)      { $perfRowCount.Add($ev.row_count) | Out-Null }
                    }
                }
                if ($hasSeqDur) {
                    $seqDurations.Add($seqDur) | Out-Null
                    $seqLogReads.Add($seqLR) | Out-Null
                }
            }

            $perfStats = [ordered]@{
                per_statement = [ordered]@{
                    duration_us    = Compute-FieldStats $perfDuration
                    cpu_time_us    = Compute-FieldStats $perfCpu
                    logical_reads  = Compute-FieldStats $perfLogReads
                    physical_reads = Compute-FieldStats $perfPhysReads
                    writes         = Compute-FieldStats $perfWrites
                    row_count      = Compute-FieldStats $perfRowCount
                }
                per_sequence = [ordered]@{
                    total_duration_us  = Compute-FieldStats $seqDurations
                    total_logical_reads = Compute-FieldStats $seqLogReads
                }
            }

            $patterns += @{
                sequence_length   = $parts.Count
                occurrence_count  = $count
                distinct_sessions = $distinctSessions
                normalized_sql    = $parts
                perf              = $perfStats
                sample = @{
                    session_id = $sampleSid
                    timestamps = $sampleTimestamps
                    sql_texts  = $sampleSqlTexts
                }
            }
        }

        $patterns = @($patterns | Sort-Object { $_.occurrence_count } -Descending)

        # Console report
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "SEQUENCE PATTERNS FOUND" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host ""

        $patternNum = 0
        foreach ($p in $patterns) {
            $patternNum++
            Write-Host ("Pattern #{0}  (length: {1}, occurrences: {2}, sessions: {3})" -f $patternNum, $p.sequence_length, $p.occurrence_count, $p.distinct_sessions) -ForegroundColor Yellow
            Write-Host ("-" * 60)

            for ($i = 0; $i -lt $p.normalized_sql.Count; $i++) {
                $sqlPreview = $p.normalized_sql[$i]
                if ($sqlPreview.Length -gt 120) {
                    $sqlPreview = $sqlPreview.Substring(0, 117) + "..."
                }
                Write-Host ("  [{0}] {1}" -f ($i + 1), $sqlPreview)
            }

            # Performance stats table
            $ps = $p.perf.per_statement
            $sq = $p.perf.per_sequence
            Write-Host ""
            Write-Host "  Per-Statement Performance:" -ForegroundColor DarkCyan
            $hdr = "    {0,-18} {1,10} {2,10} {3,10} {4,10} {5,10}" -f "Metric", "Avg", "P50", "P95", "Min", "Max"
            Write-Host $hdr
            Write-Host ("    " + "-" * 68)
            $metrics = @(
                @{ name = "duration (us)";    s = $ps.duration_us },
                @{ name = "cpu_time (us)";    s = $ps.cpu_time_us },
                @{ name = "logical_reads";    s = $ps.logical_reads },
                @{ name = "physical_reads";   s = $ps.physical_reads },
                @{ name = "writes";           s = $ps.writes },
                @{ name = "row_count";        s = $ps.row_count }
            )
            foreach ($m in $metrics) {
                $s = $m.s
                if ($s.count -gt 0) {
                    Write-Host ("    {0,-18} {1,10} {2,10} {3,10} {4,10} {5,10}" -f $m.name, $s.avg, $s.p50, $s.p95, $s.min, $s.max)
                }
            }

            if ($sq.total_duration_us.count -gt 0) {
                Write-Host ""
                Write-Host "  Per-Sequence Totals (sum of all steps per occurrence):" -ForegroundColor DarkCyan
                Write-Host ("    {0,-18} {1,10} {2,10} {3,10} {4,10} {5,10}" -f "Metric", "Avg", "P50", "P95", "Min", "Max")
                Write-Host ("    " + "-" * 68)
                $ds = $sq.total_duration_us
                Write-Host ("    {0,-18} {1,10} {2,10} {3,10} {4,10} {5,10}" -f "duration (us)", $ds.avg, $ds.p50, $ds.p95, $ds.min, $ds.max)
                $lr = $sq.total_logical_reads
                Write-Host ("    {0,-18} {1,10} {2,10} {3,10} {4,10} {5,10}" -f "logical_reads", $lr.avg, $lr.p50, $lr.p95, $lr.min, $lr.max)
            }

            Write-Host ""
            Write-Host "  Sample (session $($p.sample.session_id)):" -ForegroundColor DarkGray
            if ($p.sample.timestamps.Count -gt 0) {
                Write-Host "    Time range: $($p.sample.timestamps[0]) - $($p.sample.timestamps[-1])" -ForegroundColor DarkGray
            }
            Write-Host ""
        }

        # Summary
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "SUMMARY" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "  Total patterns found:    $($patterns.Count)"
        Write-Host "  Input file:              $InputFile"
        Write-Host "  Sequence length range:   $MinSequenceLength - $MaxSequenceLength"
        Write-Host "  Min occurrences filter:  $MinOccurrences"

        # JSON output
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $jsonFile = Join-Path $OutputPath "BenchmarkTrace-patterns-$timestamp.json"

        $jsonOutput = @{
            metadata = [ordered]@{
                analysis_type       = "sequence_patterns"
                input_file          = $InputFile
                analysis_time       = (Get-Date).ToString("o")
                min_sequence_length = $MinSequenceLength
                max_sequence_length = $MaxSequenceLength
                min_occurrences     = $MinOccurrences
                total_events        = $totalFiltered
                sessions_analyzed   = $sessionSequences.Count
                patterns_found      = $patterns.Count
            }
            patterns = @(
                foreach ($p in $patterns) {
                    [ordered]@{
                        sequence_length   = $p.sequence_length
                        occurrence_count  = $p.occurrence_count
                        distinct_sessions = $p.distinct_sessions
                        normalized_sql    = $p.normalized_sql
                        perf              = $p.perf
                        sample = [ordered]@{
                            session_id = $p.sample.session_id
                            timestamps = $p.sample.timestamps
                            sql_texts  = $p.sample.sql_texts
                        }
                    }
                }
            )
        }

        $jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8

        Write-Host ""
        Write-Host "Output: $jsonFile" -ForegroundColor Green
        $fileInfo = Get-Item $jsonFile
        Write-Host "File size: $([math]::Round($fileInfo.Length / 1KB, 1)) KB"
    }

    "features" {
        Show-Header "ML Feature Export"

        # Resolve input file
        if ([string]::IsNullOrWhiteSpace($InputFile)) {
            $InputFile = Find-LatestExportCsv -dir $OutputPath
            if (-not $InputFile) {
                Write-Host "No CSV export found in $OutputPath" -ForegroundColor Red
                Write-Host "Export trace data first: .\xevents-trace.ps1 -Action export"
                exit 1
            }
            Write-Host "Auto-detected: $InputFile"
        }
        elseif (-not (Test-Path $InputFile)) {
            Write-Host "File not found: $InputFile" -ForegroundColor Red
            exit 1
        }

        Write-Host "Loading CSV..."
        $allRows = Import-Csv -Path $InputFile

        # Separate event types
        $statements = @($allRows | Where-Object {
            $_.event_name -eq 'sql_statement_completed' -and
            -not [string]::IsNullOrWhiteSpace($_.sql_text) -and
            -not [string]::IsNullOrWhiteSpace($_.session_id)
        })

        $nonStmtEventNames = @('wait_completed', 'latch_suspend_end', 'page_split')
        $nonStmtEvents = @($allRows | Where-Object {
            $nonStmtEventNames -contains $_.event_name -and
            -not [string]::IsNullOrWhiteSpace($_.session_id)
        })

        Write-Host "Statements: $($statements.Count), Non-statement events: $($nonStmtEvents.Count)"

        if ($statements.Count -eq 0) {
            Write-Host "No sql_statement_completed events found in the trace data" -ForegroundColor Yellow
            exit 0
        }

        # Index non-statement events by session_id, sorted by timestamp
        Write-Host "Indexing non-statement events..."
        $nonStmtBySession = @{}
        foreach ($ev in $nonStmtEvents) {
            $sid = $ev.session_id
            if (-not $nonStmtBySession.ContainsKey($sid)) {
                $nonStmtBySession[$sid] = [System.Collections.ArrayList]::new()
            }
            $nonStmtBySession[$sid].Add($ev) | Out-Null
        }
        foreach ($sid in @($nonStmtBySession.Keys)) {
            $sorted = @($nonStmtBySession[$sid] | Sort-Object { [datetime]$_.event_timestamp })
            $nonStmtBySession[$sid] = $sorted
        }

        # Group statements by session_id
        $stmtBySession = @{}
        foreach ($ev in $statements) {
            $sid = $ev.session_id
            if (-not $stmtBySession.ContainsKey($sid)) {
                $stmtBySession[$sid] = [System.Collections.ArrayList]::new()
            }
            $stmtBySession[$sid].Add($ev) | Out-Null
        }

        $sessionCount = $stmtBySession.Count
        Write-Host "Processing $sessionCount sessions..."
        Write-Host "Correlating events..."

        # Process statements per session
        $outputRows = [System.Collections.ArrayList]::new()
        $rowId = 0
        $waitCorrelatedCount = 0
        $latchCorrelatedCount = 0
        $pageSplitCorrelatedCount = 0

        foreach ($sid in $stmtBySession.Keys) {
            $sessionStmts = @($stmtBySession[$sid] | Sort-Object { [datetime]$_.event_timestamp })
            $sessionNonStmt = if ($nonStmtBySession.ContainsKey($sid)) { $nonStmtBySession[$sid] } else { @() }

            $prevTimestamp = $null

            for ($i = 0; $i -lt $sessionStmts.Count; $i++) {
                $stmt = $sessionStmts[$i]
                $rowId++
                $ordinal = $i + 1
                $thisTs = [datetime]$stmt.event_timestamp

                # Compute inter-arrival time
                $interArrival = $null
                if ($prevTimestamp -ne $null) {
                    $interArrival = [long](($thisTs - $prevTimestamp).TotalMilliseconds * 1000)
                }

                # Extract literals from original SQL text
                $numLiterals = Extract-NumericLiterals -sql $stmt.sql_text
                $strLiterals = Extract-StringLiterals -sql $stmt.sql_text

                # Normalize SQL
                $normalizedSql = Normalize-SqlText -sql $stmt.sql_text

                # Correlate non-statement events in window [prevTs, thisTs]
                $waitCount = 0
                $waitTotalUs = 0
                $waitTypes = @()
                $latchCount = 0
                $latchTotalUs = 0
                $pageSplitCount = 0

                if ($sessionNonStmt.Count -gt 0) {
                    $windowStart = if ($prevTimestamp -ne $null) { $prevTimestamp } else { [datetime]::MinValue }
                    $windowEnd = $thisTs

                    foreach ($nse in $sessionNonStmt) {
                        $nseTs = [datetime]$nse.event_timestamp
                        if ($nseTs -lt $windowStart -or $nseTs -gt $windowEnd) { continue }

                        switch ($nse.event_name) {
                            'wait_completed' {
                                $waitCount++
                                $dur = Parse-Numeric $nse.duration_us
                                if ($dur -ne $null) { $waitTotalUs += $dur }
                                if (-not [string]::IsNullOrWhiteSpace($nse.wait_type)) {
                                    $waitTypes += $nse.wait_type
                                }
                            }
                            'latch_suspend_end' {
                                $latchCount++
                                $dur = Parse-Numeric $nse.duration_us
                                if ($dur -ne $null) { $latchTotalUs += $dur }
                            }
                            'page_split' {
                                $pageSplitCount++
                            }
                        }
                    }
                }

                if ($waitCount -gt 0) { $waitCorrelatedCount++ }
                if ($latchCount -gt 0) { $latchCorrelatedCount++ }
                if ($pageSplitCount -gt 0) { $pageSplitCorrelatedCount++ }

                # Build output row
                $row = [ordered]@{
                    row_id                 = $rowId
                    session_id             = $sid
                    event_timestamp        = $stmt.event_timestamp
                    normalized_sql         = $normalizedSql
                    query_hash             = $stmt.query_hash
                    query_plan_hash        = $stmt.query_plan_hash
                    ordinal                = $ordinal
                    duration_us            = $stmt.duration_us
                    cpu_time_us            = $stmt.cpu_time_us
                    logical_reads          = $stmt.logical_reads
                    physical_reads         = $stmt.physical_reads
                    writes                 = $stmt.writes
                    row_count              = $stmt.row_count
                    inter_arrival_us       = $interArrival
                    numeric_literals       = ($numLiterals | ConvertTo-Json -Compress)
                    string_literal_count   = $strLiterals.Count
                    string_literal_lengths = (($strLiterals | ForEach-Object { $_.length }) | ConvertTo-Json -Compress)
                    wait_count             = $waitCount
                    wait_total_us          = $waitTotalUs
                    wait_types             = ($waitTypes | ConvertTo-Json -Compress)
                    latch_count            = $latchCount
                    latch_total_us         = $latchTotalUs
                    page_split_count       = $pageSplitCount
                }

                if ($IncludeStringLiterals) {
                    $row['string_literals'] = (($strLiterals | ForEach-Object { $_.content }) | ConvertTo-Json -Compress)
                }

                $outputRows.Add([PSCustomObject]$row) | Out-Null
                $prevTimestamp = $thisTs
            }
        }

        # Export CSV
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $csvFile = Join-Path $OutputPath "BenchmarkTrace-features-$timestamp.csv"
        $outputRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

        # Console summary
        $columnCount = if ($IncludeStringLiterals) { 24 } else { 23 }
        $totalRows = $outputRows.Count

        Write-Host ""
        Write-Host "FEATURE SUMMARY" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green

        $waitPct = if ($totalRows -gt 0) { [math]::Round($waitCorrelatedCount / $totalRows * 100, 1) } else { 0 }
        $latchPct = if ($totalRows -gt 0) { [math]::Round($latchCorrelatedCount / $totalRows * 100, 1) } else { 0 }
        $splitPct = if ($totalRows -gt 0) { [math]::Round($pageSplitCorrelatedCount / $totalRows * 100, 1) } else { 0 }

        Write-Host "  Rows:              $totalRows"
        Write-Host "  Columns:           $columnCount"
        Write-Host "  Sessions:          $sessionCount"
        Write-Host "  Statements with correlated waits:     $waitCorrelatedCount ($waitPct%)"
        Write-Host "  Statements with correlated latches:   $latchCorrelatedCount ($latchPct%)"
        Write-Host "  Statements with page splits:          $pageSplitCorrelatedCount ($splitPct%)"
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
    }
}

Write-Host ""
