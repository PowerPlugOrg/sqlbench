# Project Context

## Environment

- **Machine:** TOMER-BOOK3
- **Platform:** Windows
- **Temp/output directory:** `$env:DBCC_TEMP` or `./tmp` (all scripts auto-create if missing)

## Database Connections

### SQL Server (Benchmark)

- **Server:** `TOMER-BOOK3\SQLEXPRESS`
- **Database:** `BenchmarkTest`
- **Authentication:** Windows Authentication (Trusted Connection)
- **Connection String:** `Server=TOMER-BOOK3\SQLEXPRESS;Database=BenchmarkTest;Trusted_Connection=True;`

### Benchmark Database Schema

**Tables:**
- `TestTable` - Main OLTP test table (10,000 rows seeded)
  - Id (INT, PK), Data (NVARCHAR), Value (INT), Category (TINYINT), Created (DATETIME)
  - Indexes: IX_TestTable_Value, IX_TestTable_Category, IX_TestTable_Created
- `Categories` - Lookup table (5 rows)
  - Id (TINYINT, PK), Name (NVARCHAR), Description (NVARCHAR)
- `Accounts` - Transaction test table (1,000 rows seeded)
  - Id (INT, PK), AccountNumber (NVARCHAR), Balance (DECIMAL), LastUpdated (DATETIME)

### SQLCMD Usage

```bash
sqlcmd -S "TOMER-BOOK3\SQLEXPRESS" -E -d BenchmarkTest -Q "SELECT ..."
```

## Custom Commands

### /benchmark

Run SQL Server OLTP benchmark.

**Usage:**
```
/benchmark [type] [iterations] [threads]
```

**Arguments:**
- `type` - read, write, mixed, or all (default: read)
- `iterations` - number of queries (default: 500)
- `threads` - concurrent connections (default: 10)

**Examples:**
```
/benchmark                    # read test, 500 iterations, 10 threads
/benchmark write              # write test with defaults
/benchmark mixed 1000 20      # mixed test, 1000 iterations, 20 threads
/benchmark all                # run all three benchmarks
```

**Script location:** `C:\src\pp\dbcc\benchmark.ps1`

### /trace

Control SQL Server Extended Events (XEvents) tracing for performance analysis.

**Usage:**
```
/trace [action]
```

**Actions:**
- `status` - Show current trace session status (default)
- `create` - Create a new XEvents trace session
- `start` - Start the trace session
- `stop` - Stop the trace session
- `read` - Analyze and display trace results
- `export` - Export raw trace data to CSV or JSON (`-Format csv` or `-Format json`)
- `cleanup` - Stop session and remove trace files
- `auto` - Full workflow: create, start, prompt for benchmark, stop, read

**Examples:**
```
/trace                    # show status
/trace create             # create new session
/trace start              # start tracing
/trace stop               # stop tracing
/trace read               # analyze captured events
/trace export             # export raw data to CSV (default) or JSON
/trace cleanup            # clean up session and files
/trace auto               # full automated workflow with benchmark
```

**Captured Events:**

| Category | Events |
|----------|--------|
| Query Execution | sql_statement_completed, rpc_completed, sql_batch_completed, sp_statement_completed |
| CPU Events | query_post_compilation_showplan, sql_statement_recompile, degree_of_parallelism, auto_stats |
| I/O Events | page_split, checkpoint_begin/end, log_flush_start, file_read/write_completed |
| Memory Events | memory_grant_updated, sort_warning, hash_warning, exchange_spill |
| Wait/Contention | wait_completed, lock_acquired, lock_escalation, latch_suspend_end, blocked_process_report |
| Errors | error_reported, attention (timeouts) |

**Metrics Captured:**
- duration, cpu_time, logical_reads, physical_reads, writes, row_count
- query_hash, query_plan_hash, plan_handle
- wait_type, dop (parallelism degree), lock_mode

**Script location:** `C:\src\pp\dbcc\xevents-trace.ps1`
**Trace output:** `./tmp/BenchmarkTrace.xel`

### Trace Analysis

Offline analysis of exported XEvents trace CSV data. Supports pattern detection and ML feature extraction.

**Usage:**
```
powershell -ExecutionPolicy Bypass -File trace-analyze.ps1 -Action patterns
powershell -ExecutionPolicy Bypass -File trace-analyze.ps1 -Action features
```

**Parameters:**
- `-Action` - Analysis action: `patterns` (default), `features`
- `-InputFile` - Path to CSV export (default: auto-detects latest `BenchmarkTrace-export-*.csv` in output dir)
- `-MinSequenceLength` - Minimum n-gram length (default: 2) *(patterns only)*
- `-MaxSequenceLength` - Maximum n-gram length (default: 10) *(patterns only)*
- `-MinOccurrences` - Minimum times a pattern must repeat (default: 2) *(patterns only)*
- `-OutputPath` - Output directory (default: `$env:DBCC_TEMP` or `./tmp`)
- `-IncludeStringLiterals` - Include raw string literal content in features output *(features only)*

**Examples:**
```
powershell -File trace-analyze.ps1 -Action patterns                          # auto-detect latest CSV
powershell -File trace-analyze.ps1 -Action patterns -MinSequenceLength 3     # require longer sequences
powershell -File trace-analyze.ps1 -Action patterns -InputFile ./tmp/BenchmarkTrace-export-20260130-101654.csv
powershell -File trace-analyze.ps1 -Action features                          # ML feature export
powershell -File trace-analyze.ps1 -Action features -IncludeStringLiterals   # include string literal content
```

**Algorithm (`patterns` action):**
1. Import CSV, filter to `sql_statement_completed` and `sql_batch_completed` events
2. Group by `session_id`, order by timestamp within each session
3. Normalize SQL text (replace numeric/string/GUID literals with `?`, collapse whitespace)
4. Build sliding-window n-grams (size 2..MaxSequenceLength) per session
5. Aggregate n-gram frequency across all sessions
6. Remove subsumed shorter patterns that are contiguous sub-sequences of longer ones
7. Report patterns sorted by frequency

**Algorithm (`features` action):**
1. Import CSV, separate into statement events (`sql_statement_completed`) and non-statement events (`wait_completed`, `latch_suspend_end`, `page_split`)
2. Index non-statement events by `session_id`, sorted by timestamp
3. For each session, sort statements by timestamp and assign ordinal position
4. Compute `inter_arrival_us` (gap since previous statement in same session)
5. Extract numeric and string literals from original SQL text before normalization
6. Correlate non-statement events in the time window between previous and current statement
7. Export flat CSV with one row per statement, including all metrics and correlated events

**Features CSV Columns:**

| Category | Columns |
|----------|---------|
| Identity | `row_id`, `session_id`, `event_timestamp`, `normalized_sql`, `query_hash`, `query_plan_hash`, `ordinal` |
| Performance | `duration_us`, `cpu_time_us`, `logical_reads`, `physical_reads`, `writes`, `row_count` |
| Session context | `inter_arrival_us` |
| SQL literals | `numeric_literals` (JSON), `string_literal_count`, `string_literal_lengths` (JSON), `string_literals` (JSON, with `-IncludeStringLiterals`) |
| Correlated events | `wait_count`, `wait_total_us`, `wait_types` (JSON), `latch_count`, `latch_total_us`, `page_split_count` |

**Output:**
- `patterns`: Console report + `./tmp/BenchmarkTrace-patterns-YYYYMMDD-HHmmss.json`
- `features`: Console summary + `./tmp/BenchmarkTrace-features-YYYYMMDD-HHmmss.csv`

**Prerequisites:** Requires a CSV export from `/trace export`. Typical workflow:
```
/trace create    # create XEvents session
/trace start     # start tracing
/benchmark mixed # run workload
/trace stop      # stop tracing
/trace export    # export to CSV
# then run trace-analyze.ps1 -Action patterns
# or   trace-analyze.ps1 -Action features
```

**Script location:** `C:\src\pp\dbcc\trace-analyze.ps1`

### ETW Analysis

ETW feature extraction aligned to SQL statements. Produces an ML-ready CSV with one row per SQL statement, enriched with the nearest perf counter sample and aggregated ETL events. Output is joinable with the SQL features CSV on `row_id`.

**Usage:**
```
powershell -ExecutionPolicy Bypass -File etw-analyze.ps1 -Action features
```

**Parameters:**
- `-Action` - Analysis action: `features` (default)
- `-SqlFeaturesFile` - Path to SQL features CSV (default: auto-detects latest `BenchmarkTrace-features-*.csv` in output dir)
- `-PerfCountersFile` - Path to perf counters CSV (default: auto-detects `PowerActivityTrace-perfcounters.csv` in output dir)
- `-EtlFile` - Path to ETL file (default: auto-detects `PowerActivityTrace.etl`, optional)
- `-WindowMs` - ±ms window for ETL event aggregation (default: 500)
- `-OutputPath` - Output directory (default: `$env:DBCC_TEMP` or `./tmp`)

**Examples:**
```
powershell -File etw-analyze.ps1 -Action features                               # auto-detect all inputs
powershell -File etw-analyze.ps1 -Action features -WindowMs 1000                # wider ETW window
powershell -File etw-analyze.ps1 -Action features -SqlFeaturesFile ./tmp/BenchmarkTrace-features-20260130-121415.csv
```

**Algorithm:**
1. Load SQL features CSV — extract `row_id`, `session_id`, `event_timestamp`
2. Load perf counters CSV — parse PDH-CSV 4.0 format, normalize column names, sum network counters across NICs
3. Optionally convert ETL via `tracerpt` — classify events as Process/Thread/Power
4. For each SQL statement, binary-search sorted perf samples for nearest timestamp match
5. Aggregate ETW events within ±WindowMs of each statement
6. Export flat CSV with identity + perf counters + derived + ETW columns

**Output CSV Columns (31):**

| Category | Columns |
|----------|---------|
| Identity | `row_id`, `session_id`, `event_timestamp` |
| Alignment | `sample_offset_ms` |
| CPU | `cpu_pct`, `cpu_idle_pct`, `cpu_privileged_pct`, `cpu_user_pct`, `cpu_c1_pct`, `cpu_c2_pct`, `cpu_c3_pct`, `cpu_freq_mhz`, `cpu_freq_max_pct` |
| Memory | `mem_available_mb`, `mem_pages_sec`, `mem_cache_faults_sec` |
| Disk | `disk_reads_sec`, `disk_writes_sec`, `disk_bytes_sec`, `disk_queue_len`, `disk_idle_pct` |
| Network | `net_bytes_sec`, `net_packets_sec` |
| System | `ctx_switches_sec`, `proc_queue_len` |
| Derived | `cpu_busy_pct`, `disk_iops` |
| ETW events | `etw_event_count`, `etw_process_events`, `etw_thread_events`, `etw_power_events` |

**Output:** Console summary + `./tmp/PowerActivityTrace-features-YYYYMMDD-HHmmss.csv`

**Prerequisites:** Requires SQL features CSV from `trace-analyze.ps1 -Action features` and perf counters CSV from `/power-trace`. Typical workflow:
```
/trace create    # create XEvents session
/trace start     # start tracing
/power-trace start  # start power tracing
/benchmark mixed    # run workload
/power-trace stop   # stop power tracing
/trace stop         # stop tracing
/trace export       # export XEvents to CSV
# then run trace-analyze.ps1 -Action features
# then run etw-analyze.ps1 -Action features
```

**Script location:** `C:\src\pp\dbcc\etw-analyze.ps1`

### ETW Power Model

ML-ready feature extraction for power estimation. One row per perf counter sample, enriched with per-event-type ETW counts and optional RAPL labels. Designed for training on dev (RAPL available) and inference on production (perf counters only).

**Usage:**
```
powershell -ExecutionPolicy Bypass -File etw-analyze.ps1 -Action power-model
```

**Parameters:**
- `-Action power-model` - Power model feature extraction
- `-PerfCountersFile` - Path to perf counters CSV (default: auto-detects `PowerActivityTrace-perfcounters.csv` in output dir)
- `-EtlFile` - Path to ETL file (default: auto-detects `PowerActivityTrace.etl`, optional)
- `-RaplFile` - Path to RAPL CSV (default: auto-detects `PowerActivityTrace-rapl.csv`, optional — label source)
- `-MinEventCount` - Minimum total occurrences for an ETW event type to get its own column (default: 5)
- `-OutputPath` - Output directory (default: `$env:DBCC_TEMP` or `./tmp`)

**Examples:**
```
powershell -File etw-analyze.ps1 -Action power-model                             # auto-detect all inputs
powershell -File etw-analyze.ps1 -Action power-model -MinEventCount 10           # stricter ETW filtering
powershell -File etw-analyze.ps1 -Action power-model -RaplFile ./tmp/PowerActivityTrace-rapl.csv
```

**Algorithm:**
1. Load perf counters CSV — reuses `Import-PerfCountersCsv`, returns sorted samples with normalized column names
2. Optionally convert ETL via `tracerpt` — discover all distinct event names, filter by `MinEventCount`, sanitize for column names
3. Optionally load RAPL CSV — parse timestamps, sort by time
4. For each perf counter sample, define window `[sample[i], sample[i+1])` (last sample uses interval)
5. Count ETW events per event type within window; below-threshold types go to `etw_other`
6. Binary-search nearest RAPL sample for label columns
7. Export flat CSV

**Output CSV Columns (dynamic width):**

| Category | Columns |
|----------|---------|
| Identity (2) | `sample_idx`, `timestamp` |
| CPU (9) | `cpu_pct`, `cpu_idle_pct`, `cpu_privileged_pct`, `cpu_user_pct`, `cpu_c1_pct`, `cpu_c2_pct`, `cpu_c3_pct`, `cpu_freq_mhz`, `cpu_freq_max_pct` |
| Memory (3) | `mem_available_mb`, `mem_pages_sec`, `mem_cache_faults_sec` |
| Disk (5) | `disk_reads_sec`, `disk_writes_sec`, `disk_bytes_sec`, `disk_queue_len`, `disk_idle_pct` |
| Network (2) | `net_bytes_sec`, `net_packets_sec` |
| System (2) | `ctx_switches_sec`, `proc_queue_len` |
| Derived (2) | `cpu_busy_pct`, `disk_iops` |
| ETW (dynamic) | `etw_{event_name}` per event type (>= `MinEventCount`), `etw_other`, `etw_total` |
| Labels (optional) | `rapl_package_w`, `rapl_core_w`, `rapl_dram_w`, `rapl_estimated_w`, `rapl_offset_ms` |

ETW columns are omitted entirely if no ETL file is found. Label columns are omitted if no RAPL file is found (inference/production mode).

**Output:** Console summary + `./tmp/PowerModel-features-YYYYMMDD-HHmmss.csv`

**Prerequisites:** Requires perf counters CSV from `/power-trace`. Typical workflow:
```
/power-trace start    # start power tracing (includes perf counters + optional RAPL)
/benchmark mixed      # run workload
/power-trace stop     # stop tracing
# then run etw-analyze.ps1 -Action power-model
```

**Script location:** `C:\src\pp\dbcc\etw-analyze.ps1`

### /power-trace

Comprehensive power consumption analysis for servers (requires Admin). Captures ETW events, performance counters, Intel RAPL, NVIDIA GPU, and IPMI data.

**Usage:**
```
/power-trace [action] [level]
```

**Actions:**
- `detect` - Detect available power monitoring hardware/tools
- `status` - Show current trace session status (default)
- `start` - Start all power trace collectors
- `stop` - Stop all collectors
- `read` - Analyze and display all trace results
- `cleanup` - Stop all sessions and remove trace files
- `providers` - List all ETW providers and performance counters

**Trace Levels:**
- `all` - Power + CPU + I/O + Network (default)
- `power` - Power state changes, ACPI, CPU P/C-states
- `cpu` - Processor frequency, P-states, C-states
- `io` - Disk I/O, StorPort, storage activity
- `network` - TCP/IP, NDIS, NIC activity

**Examples:**
```
/power-trace detect             # check available hardware
/power-trace start              # start all tracing
/power-trace start io           # trace only I/O
/power-trace stop               # stop tracing
/power-trace read               # analyze all results
/power-trace cleanup            # clean up files
```

**Data Sources Collected:**

| Source | Data | Availability |
|--------|------|--------------|
| ETW | Power events, I/O, Network, CPU states | Always |
| PerfCounters | CPU%, Memory, Disk I/O, Network throughput | Always |
| Intel RAPL | CPU Package/Core/DRAM power (Watts) | Intel CPUs |
| NVIDIA GPU | GPU power, utilization, temperature | NVIDIA GPUs |
| IPMI/BMC | System power draw from BMC sensors | Server hardware |

**ETW Providers:**

| Category | Events |
|----------|--------|
| Power | Kernel-Power, Kernel-Acpi, PEP, PDC |
| CPU | Processor-Power (C/P-states), PerfProc |
| I/O | Kernel-Disk, StorPort, Kernel-File, IoTrace |
| Network | TCPIP, NDIS, Winsock-AFD, Kernel-Network |

**Performance Counters:**
- CPU: % Processor Time, % Idle Time, % C1/C2/C3 Time, Frequency
- Memory: Available MBytes, Pages/sec, Cache Faults/sec
- Disk: Reads/sec, Writes/sec, Bytes/sec, Queue Length, % Idle Time
- Network: Bytes Total/sec, Packets/sec, Current Bandwidth
- System: Context Switches/sec, Processor Queue Length

**Output Files:**
- `./tmp/PowerActivityTrace.etl` - ETW events (open in WPA)
- `./tmp/PowerActivityTrace-perfcounters.csv` - Performance counter samples
- `./tmp/PowerActivityTrace-rapl.csv` - Intel RAPL power readings
- `./tmp/PowerActivityTrace-gpu.csv` - NVIDIA GPU metrics
- `./tmp/PowerActivityTrace-ipmi.csv` - IPMI/BMC sensor readings

**Script location:** `C:\src\pp\dbcc\etw-power-trace.ps1`

**Tips:**
- For accurate Intel RAPL, run LibreHardwareMonitor
- For IPMI readings, install ipmitool or vendor tools (Dell OMSA, HP iLO)
- Open ETL files in Windows Performance Analyzer (WPA) for timeline analysis
- Requires Administrator privileges
