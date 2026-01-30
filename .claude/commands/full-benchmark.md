# Full Benchmark Cycle

Run a complete benchmark with SQL Server XEvents tracing and Windows power/activity tracing.

## Arguments

$ARGUMENTS - Benchmark parameters: [type] [iterations] [threads]

## Instructions

Parse arguments:
- First argument: benchmark type (read, write, mixed, all) - default: mixed
- Second argument: iterations - default: 1000
- Third argument: threads - default: 10

### Execution Strategy

**Use the Task tool to spawn a Bash agent** that will execute the full benchmark cycle. This keeps the main context clean and manageable.

Spawn a single Bash agent with the following prompt:

```
Execute the full SQL Server benchmark cycle with tracing. Parameters:
- Benchmark type: <type>
- Iterations: <iterations>
- Threads: <threads>

Run these commands in sequence:

1. Cleanup existing sessions:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action cleanup
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\etw-power-trace.ps1" -Action cleanup

2. Create and start SQL XEvents trace:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action create
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action start

3. Start power trace (may fail without admin - continue anyway):
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\etw-power-trace.ps1" -Action start

4. Run the benchmark:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\benchmark.ps1" -TestType <type> -Iterations <iterations> -Threads <threads>

5. Stop power trace:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\etw-power-trace.ps1" -Action stop

6. Stop SQL XEvents trace:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action stop

7. Read power trace results:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\etw-power-trace.ps1" -Action read

8. Read SQL XEvents results:
   powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action read

After all steps complete, provide a CONCISE summary with:
- Benchmark parameters and throughput
- Key SQL metrics (queries, latency, reads/writes)
- Top wait types
- Power consumption (if available)
- Any errors or warnings
```

### Examples

```
/full-benchmark                    # mixed, 1000 iterations, 10 threads
/full-benchmark read               # read test with defaults
/full-benchmark write 500 5        # write test, 500 iterations, 5 threads
/full-benchmark mixed 2000 20      # mixed test, 2000 iterations, 20 threads
/full-benchmark all                # run read, write, and mixed sequentially
```

### Notes

- Power tracing requires Administrator privileges
- If power tracing fails, SQL tracing and benchmark will still run
- All trace files are written to `C:\temp\`
- For "all" type, spawn separate agents for each benchmark type
