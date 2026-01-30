# SQL Server XEvents Trace Control

Comprehensive Extended Events tracing for SQL Server performance and power analysis.

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
| `export` | Export raw trace data to CSV or JSON |
| `status` | Show current session status |
| `cleanup` | Stop session and remove trace files |
| `auto` | Full workflow: create, start, run benchmark, stop, read |

### Command Execution

For single actions (create, start, stop, read, status, cleanup), run:

```
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action <action>
```

For export action with format:

```
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action export -Format csv
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\xevents-trace.ps1" -Action export -Format json
```

### Events Captured

**Query Execution:**
- `sql_statement_completed` - Ad-hoc queries with duration, CPU, reads, writes
- `rpc_completed` - Parameterized queries and stored procedures
- `sql_batch_completed` - Batch-level timing
- `sp_statement_completed` - Individual statements in stored procedures (>1ms)

**CPU Events (for power correlation):**
- `query_post_compilation_showplan` - Query compilations (CPU intensive)
- `sql_statement_recompile` - Recompilations causing CPU spikes
- `degree_of_parallelism` - Parallel query execution (DOP > 1)
- `auto_stats` - Statistics updates triggering CPU

**I/O Events (for storage power correlation):**
- `page_split` - Index fragmentation causing extra I/O
- `checkpoint_begin/end` - Checkpoint I/O activity
- `log_flush_start` - Transaction log writes
- `file_read/write_completed` - File I/O operations (>10ms)

**Memory Events:**
- `sort_warning` - Sorts spilling to tempdb
- `hash_warning` - Hash operations spilling to tempdb
- `exchange_spill` - Parallel query memory spills
- `memory_grant_updated` - Memory grant changes

**Wait & Contention:**
- `wait_completed` - Wait statistics (>1ms)
- `lock_acquired` - Exclusive+ lock acquisitions
- `lock_escalation` - Lock escalation events
- `latch_suspend_end` - Buffer pool/memory contention
- `blocked_process_report` - Long blocking events

**Errors:**
- `error_reported` - Errors severity >= 11
- `attention` - Query cancellation/timeout

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
   - XEvents analysis (all categories)
   - Recommendations based on the data

### Output Format

After running read action, the analysis shows:

1. **Event Overview** - All captured event types and counts
2. **Query Execution Analysis** - Top queries by duration, CPU, I/O
3. **CPU Events** - Compilations, parallelism, stats updates
4. **I/O Events** - Page splits, checkpoints, log flushes
5. **Memory Events** - Spills to tempdb (indicates memory pressure)
6. **Wait Statistics** - Top wait types by total wait time
7. **Lock & Contention** - Lock escalations, blocking, latch contention
8. **Summary** - Total queries, CPU time, I/O totals

### Examples

```
/trace                  # Show status
/trace create           # Create new session
/trace start            # Start tracing
/trace stop             # Stop tracing
/trace read             # Analyze results (all categories)
/trace export           # Export to CSV (default)
/trace export json      # Export to JSON
/trace cleanup          # Clean up everything
/trace auto             # Full automated workflow
```

### Export Format

The export action outputs raw event data with all parsed fields:

**CSV columns / JSON fields:**
- `event_name` - Type of event (sql_statement_completed, wait_completed, etc.)
- `event_timestamp` - When the event occurred
- `duration_us` - Duration in microseconds
- `cpu_time_us` - CPU time in microseconds
- `logical_reads`, `physical_reads`, `writes` - I/O metrics
- `row_count` - Rows affected
- `wait_type` - Wait type (for wait events)
- `dop` - Degree of parallelism
- `session_id` - SQL Server session ID
- `database_name`, `client_app_name`, `username`
- `sql_text` - Full SQL text
- `query_hash`, `query_plan_hash` - For query grouping

Output files are written to `C:\temp\` with timestamp:
- CSV: `BenchmarkTrace-export-YYYYMMDD-HHmmss.csv`
- JSON: `BenchmarkTrace-export-YYYYMMDD-HHmmss.json`

### Correlating with Power Trace

For comprehensive power/performance analysis:

```
/trace start            # Start SQL XEvents
/power-trace start      # Start ETW + RAPL + counters
/benchmark mixed 1000   # Run workload
/power-trace stop
/trace stop
/trace read             # SQL performance breakdown
/power-trace read       # Power consumption breakdown
```

CPU events (compilations, parallelism) correlate with RAPL CPU power.
I/O events (checkpoints, log flushes) correlate with disk activity counters.
Network events in power-trace correlate with client query traffic.
