# SQL Server XEvents Trace Control

Control Extended Events tracing for SQL Server benchmark analysis.

## Arguments

$ARGUMENTS - Action to perform: create, start, stop, read, status, cleanup, or auto

## Instructions

Parse the first argument to determine the action. If no argument provided, default to "status".

### Available Actions

| Action | Description |
|--------|-------------|
| `create` | Create a new XEvents trace session |
| `start` | Start the trace session |
| `stop` | Stop the trace session |
| `read` | Analyze and display trace results |
| `status` | Show current session status |
| `cleanup` | Stop session and remove trace files |
| `auto` | Full workflow: create, start, run benchmark, stop, read |

### Command Execution

For single actions (create, start, stop, read, status, cleanup), run:

```
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action <action>
```

### Auto Mode Workflow

If the action is `auto`, perform these steps in sequence:

1. Run cleanup first to ensure clean state
2. Create the trace session
3. Start the trace session
4. Prompt the user: "Trace is running. What benchmark would you like to run? (read/write/mixed/all, iterations, threads)"
5. Run the benchmark with the user's parameters using the benchmark script
6. Stop the trace session
7. Read and analyze the results
8. Present a combined summary showing:
   - Benchmark results (throughput, latency)
   - XEvents analysis (top queries, wait stats)
   - Recommendations based on the data

### Output Format

After running read action, summarize the results in a formatted table showing:
- Top queries by total duration
- Execution counts and average latencies
- Logical/physical reads
- Any identified bottlenecks or recommendations

### Examples

```
/trace                  # Show status
/trace create           # Create new session
/trace start            # Start tracing
/trace stop             # Stop tracing
/trace read             # Analyze results
/trace cleanup          # Clean up everything
/trace auto             # Full automated workflow
```
