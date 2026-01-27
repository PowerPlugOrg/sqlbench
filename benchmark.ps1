# SQL Server Benchmark Script
param(
    [int]$Iterations = 500,
    [int]$Threads = 10,
    [string]$TestType = "read"  # read, write, mixed
)

$connectionString = "Server=TOMER-BOOK3\SQLEXPRESS;Database=BenchmarkTest;Integrated Security=True;"

$queries = @{
    "read" = "SELECT * FROM TestTable WHERE Id = ABS(CHECKSUM(NEWID())) % 10000 + 1;"
    "write" = "INSERT INTO TestTable (Data, Value, Category) VALUES (CAST(NEWID() AS NVARCHAR(100)), ABS(CHECKSUM(NEWID())) % 10000, (ABS(CHECKSUM(NEWID())) % 5) + 1);"
    "mixed" = "UPDATE Accounts SET Balance = Balance + 1, LastUpdated = GETDATE() WHERE Id = ABS(CHECKSUM(NEWID())) % 1000 + 1;"
}

$query = $queries[$TestType]

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "SQL Server Benchmark" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Test Type:    $TestType"
Write-Host "Iterations:   $Iterations"
Write-Host "Threads:      $Threads"
Write-Host "Query:        $query"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$scriptBlock = {
    param($connStr, $sql, $iters)

    $times = @()
    $errors = 0

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()

        for ($i = 0; $i -lt $iters; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $sql
                $null = $cmd.ExecuteNonQuery()
                $cmd.Dispose()
            } catch {
                $errors++
            }
            $sw.Stop()
            $times += $sw.Elapsed.TotalMilliseconds
        }

        $conn.Close()
        $conn.Dispose()
    } catch {
        $errors = $iters
    }

    return @{
        Times = $times
        Errors = $errors
    }
}

$iterationsPerThread = [math]::Ceiling($Iterations / $Threads)

Write-Host "Starting benchmark..." -ForegroundColor Yellow
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

$jobs = @()
for ($t = 0; $t -lt $Threads; $t++) {
    $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $connectionString, $query, $iterationsPerThread
}

$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

$totalSw.Stop()

# Aggregate results
$allTimes = @()
$totalErrors = 0

foreach ($r in $results) {
    if ($r.Times) { $allTimes += $r.Times }
    if ($r.Errors) { $totalErrors += $r.Errors }
}

$totalIterations = $allTimes.Count
$totalTimeSeconds = $totalSw.Elapsed.TotalSeconds

if ($allTimes.Count -gt 0) {
    $avgLatency = ($allTimes | Measure-Object -Average).Average
    $minLatency = ($allTimes | Measure-Object -Minimum).Minimum
    $maxLatency = ($allTimes | Measure-Object -Maximum).Maximum
    $sortedTimes = $allTimes | Sort-Object
    $p95Index = [math]::Floor($sortedTimes.Count * 0.95)
    $p95Latency = $sortedTimes[$p95Index]
    $throughput = $totalIterations / $totalTimeSeconds
} else {
    $avgLatency = 0
    $minLatency = 0
    $maxLatency = 0
    $p95Latency = 0
    $throughput = 0
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "RESULTS" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ("Total Time:      {0:N2} seconds" -f $totalTimeSeconds)
Write-Host ("Iterations:      {0}" -f $totalIterations)
Write-Host ("Errors:          {0}" -f $totalErrors)
Write-Host ""
Write-Host ("Throughput:      {0:N2} queries/sec" -f $throughput) -ForegroundColor Yellow
Write-Host ""
Write-Host "Latency (ms):" -ForegroundColor Cyan
Write-Host ("  Average:       {0:N2}" -f $avgLatency)
Write-Host ("  Min:           {0:N2}" -f $minLatency)
Write-Host ("  Max:           {0:N2}" -f $maxLatency)
Write-Host ("  P95:           {0:N2}" -f $p95Latency)
Write-Host "============================================" -ForegroundColor Green
