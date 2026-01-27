# SQL Server Benchmark

Run the SQL Server OLTP benchmark against the BenchmarkTest database.

## Arguments

$ARGUMENTS - Optional: test type (read|write|mixed), iterations, threads. Default: "read 500 10"

## Instructions

Run the benchmark script with the provided arguments. Parse the arguments as follows:
- First argument: test type (read, write, or mixed) - default: read
- Second argument: iterations - default: 500
- Third argument: threads - default: 10

Execute this PowerShell command:

```
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\benchmark.ps1" -TestType <type> -Iterations <iterations> -Threads <threads>
```

After running, summarize the results in a table showing throughput, latency metrics, and any errors.

If the user provides "all" as the test type, run all three benchmarks (read, write, mixed) sequentially and compare the results.
