# SQL Server Benchmark & Power Analysis Toolkit

A comprehensive toolkit for benchmarking SQL Server performance and analyzing power consumption on Windows servers.

## Overview

This toolkit provides three integrated commands for performance and power analysis:

| Command | Purpose |
|---------|---------|
| `/benchmark` | Run SQL Server OLTP benchmarks |
| `/trace` | Capture SQL Server Extended Events (XEvents) |
| `/power-trace` | Capture Windows ETW, performance counters, RAPL, GPU, and IPMI data |

## Prerequisites

- Windows 10/11 or Windows Server 2016+
- SQL Server (Express or higher)
- PowerShell 5.1+
- Administrator privileges (for tracing)

### Optional (for enhanced power monitoring)

- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) - For Intel RAPL power readings
- NVIDIA GPU drivers - For GPU power monitoring
- ipmitool or vendor BMC tools - For server power readings

## Quick Start

```powershell
# 1. Check what power monitoring is available
/power-trace detect

# 2. Run a simple benchmark
/benchmark read

# 3. Run benchmark with full tracing
/trace start
/power-trace start
/benchmark mixed 1000 20
/power-trace stop
/trace stop
/power-trace read
/trace read
```

---

## Commands Reference

### /benchmark

Run SQL Server OLTP benchmarks against the BenchmarkTest database.

#### Usage

```
/benchmark [type] [iterations] [threads]
```

#### Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `type` | Test type: `read`, `write`, `mixed`, or `all` | `read` |
| `iterations` | Number of queries to execute | `500` |
| `threads` | Concurrent database connections | `10` |

#### Examples

```powershell
/benchmark                    # Read test, 500 iterations, 10 threads
/benchmark write              # Write test with defaults
/benchmark mixed 1000 20      # Mixed test, 1000 iterations, 20 threads
/benchmark all                # Run all three benchmarks sequentially
```

#### Output Metrics

- **Throughput**: Queries per second
- **Latency**: Average, Min, Max, P95 (milliseconds)
- **Errors**: Failed query count

#### Test Queries

| Type | Query |
|------|-------|
| Read | `SELECT * FROM TestTable WHERE Id = <random>` |
| Write | `INSERT INTO TestTable (Data, Value, Category) VALUES (...)` |
| Mixed | `UPDATE Accounts SET Balance = Balance + 1 WHERE Id = <random>` |

---

### /trace

Control SQL Server Extended Events (XEvents) tracing for query performance analysis.

#### Usage

```
/trace [action]
```

#### Actions

| Action | Description |
|--------|-------------|
| `status` | Show current trace session status (default) |
| `create` | Create a new XEvents trace session |
| `start` | Start the trace session |
| `stop` | Stop the trace session |
| `read` | Analyze and display trace results |
| `cleanup` | Stop session and remove trace files |
| `auto` | Full workflow: create, start, prompt for benchmark, stop, read |

#### Examples

```powershell
/trace                    # Show status
/trace start              # Start tracing
/trace stop               # Stop tracing
/trace read               # Analyze captured events
/trace auto               # Full automated workflow
```

#### Captured Events

**Query Execution:**
| Event | Data Captured |
|-------|---------------|
| `sql_statement_completed` | Duration, CPU, reads, writes, row_count, query_hash |
| `rpc_completed` | Parameterized/stored procedure calls |
| `sql_batch_completed` | Batch-level timing |
| `sp_statement_completed` | Individual statements in stored procedures |

**CPU Events:**
| Event | Data Captured |
|-------|---------------|
| `query_post_compilation_showplan` | Query compilation (CPU intensive) |
| `sql_statement_recompile` | Recompilation events (CPU spikes) |
| `degree_of_parallelism` | Parallel query execution (DOP) |
| `auto_stats` | Statistics updates |

**I/O Events:**
| Event | Data Captured |
|-------|---------------|
| `page_split` | Index fragmentation causing extra I/O |
| `checkpoint_begin/end` | Checkpoint I/O activity |
| `log_flush_start` | Transaction log writes |
| `file_read/write_completed` | File I/O operations (>10ms) |

**Memory Events:**
| Event | Data Captured |
|-------|---------------|
| `sort_warning` | Sort spilling to tempdb |
| `hash_warning` | Hash spilling to tempdb |
| `exchange_spill` | Parallel query memory spills |
| `memory_grant_updated` | Memory grant changes |

**Wait & Contention:**
| Event | Data Captured |
|-------|---------------|
| `wait_completed` | Wait statistics (>1ms) |
| `lock_acquired` | Exclusive+ lock acquisitions |
| `lock_escalation` | Lock escalation events |
| `latch_suspend_end` | Buffer pool contention |
| `blocked_process_report` | Long blocking events |

**Errors:**
| Event | Data Captured |
|-------|---------------|
| `error_reported` | Errors severity >= 11 |
| `attention` | Query cancellation/timeout |

#### Output

- **Trace file**: `C:\temp\BenchmarkTrace.xel`
- **Analysis sections**:
  - Event overview (all event types and counts)
  - Query execution (top queries by duration, CPU, I/O)
  - CPU events (compilations, parallelism, stats updates)
  - I/O events (page splits, checkpoints, log flushes)
  - Memory events (spills to tempdb)
  - Wait statistics (top wait types)
  - Lock contention (escalations, blocking)
  - Summary (total queries, CPU, I/O)

---

### /power-trace

Comprehensive power consumption analysis for servers. Captures data from multiple sources simultaneously.

#### Usage

```
/power-trace [action] [level]
```

#### Actions

| Action | Description |
|--------|-------------|
| `detect` | Detect available power monitoring hardware/tools |
| `status` | Show current trace session status (default) |
| `start` | Start all power trace collectors |
| `stop` | Stop all collectors |
| `read` | Analyze and display all trace results |
| `cleanup` | Stop all sessions and remove trace files |
| `providers` | List all ETW providers and performance counters |

#### Trace Levels

| Level | What's Captured |
|-------|-----------------|
| `all` | Power + CPU + I/O + Network (default) |
| `power` | Power state changes, ACPI, CPU P/C-states |
| `cpu` | Processor frequency, P-states, C-states |
| `io` | Disk I/O, StorPort, storage activity |
| `network` | TCP/IP, NDIS, NIC activity |

#### Examples

```powershell
/power-trace detect         # Check available hardware
/power-trace start          # Start all tracing
/power-trace start io       # Trace only I/O activity
/power-trace stop           # Stop tracing
/power-trace read           # Analyze all results
/power-trace cleanup        # Clean up files
```

#### Data Sources

| Source | Data Captured | Availability |
|--------|---------------|--------------|
| **ETW** | Power events, I/O, Network, CPU states | Always available |
| **Performance Counters** | CPU%, Memory, Disk I/O, Network throughput | Always available |
| **Intel RAPL** | CPU Package/Core/DRAM power (Watts) | Intel Sandy Bridge+ CPUs |
| **NVIDIA GPU** | Power draw, utilization, temperature | Systems with NVIDIA GPUs |
| **IPMI/BMC** | System power from baseboard management | Servers with BMC |

#### ETW Providers

| Category | Providers |
|----------|-----------|
| Power | Kernel-Power, Kernel-Acpi, Kernel-Pep, PDC |
| CPU | Kernel-Processor-Power, PerfProc |
| I/O | Kernel-Disk, Kernel-File, StorPort, IoTrace |
| Network | TCPIP, NDIS, Winsock-AFD, Kernel-Network |

#### Performance Counters

```
CPU:     % Processor Time, % Idle Time, % C1/C2/C3 Time, Frequency
Memory:  Available MBytes, Pages/sec, Cache Faults/sec
Disk:    Reads/sec, Writes/sec, Bytes/sec, Queue Length, % Idle Time
Network: Bytes Total/sec, Packets/sec, Current Bandwidth
System:  Context Switches/sec, Processor Queue Length
```

#### Output Files

| File | Description |
|------|-------------|
| `PowerActivityTrace.etl` | ETW events (open in Windows Performance Analyzer) |
| `PowerActivityTrace-perfcounters.csv` | Performance counter time series |
| `PowerActivityTrace-rapl.csv` | Intel RAPL power readings |
| `PowerActivityTrace-gpu.csv` | NVIDIA GPU metrics |
| `PowerActivityTrace-ipmi.csv` | IPMI/BMC sensor readings |

---

## Combined Workflows

### Basic Performance Test

```powershell
/benchmark mixed 1000 20
```

### SQL Query Analysis

```powershell
/trace start
/benchmark mixed 1000 20
/trace stop
/trace read
```

### Full Power + Performance Analysis

```powershell
# Start all tracing
/trace start
/power-trace start

# Run workload
/benchmark mixed 1000 20

# Stop tracing
/power-trace stop
/trace stop

# Analyze results
/power-trace read    # Power, CPU, I/O, Network analysis
/trace read          # SQL query performance analysis
```

### Automated Workflow

```powershell
/trace auto          # Prompts for benchmark parameters, runs everything
```

---

## Database Schema

The benchmark uses the `BenchmarkTest` database with the following tables:

### TestTable (OLTP Test Table)

| Column | Type | Description |
|--------|------|-------------|
| Id | INT (PK) | Auto-increment primary key |
| Data | NVARCHAR | Random GUID string |
| Value | INT | Random integer (0-9999) |
| Category | TINYINT | Category reference (1-5) |
| Created | DATETIME | Timestamp |

**Indexes**: IX_TestTable_Value, IX_TestTable_Category, IX_TestTable_Created

### Categories (Lookup Table)

| Column | Type | Description |
|--------|------|-------------|
| Id | TINYINT (PK) | Category ID (1-5) |
| Name | NVARCHAR | Category name |
| Description | NVARCHAR | Category description |

### Accounts (Transaction Test Table)

| Column | Type | Description |
|--------|------|-------------|
| Id | INT (PK) | Account ID (1-1000) |
| AccountNumber | NVARCHAR | Account number string |
| Balance | DECIMAL | Account balance |
| LastUpdated | DATETIME | Last modification timestamp |

---

## Configuration

### SQL Server Connection

Default connection string:
```
Server=TOMER-BOOK3\SQLEXPRESS;Database=BenchmarkTest;Trusted_Connection=True;
```

To modify, edit the `$connectionString` variable in:
- `benchmark.ps1`
- `xevents-trace.ps1`

### Output Directory

All trace files are written to `C:\temp\`. Ensure this directory exists and you have write permissions.

---

## Troubleshooting

### "Access Denied" or Permission Errors

Power tracing requires Administrator privileges:
```powershell
# Run PowerShell as Administrator
Start-Process powershell -Verb RunAs
```

### No RAPL Power Data

Install and run [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) for accurate Intel RAPL readings. The script will fall back to CPU utilization-based estimation if not available.

### SQL Server Connection Failed

1. Verify SQL Server is running
2. Check the server name matches your instance
3. Ensure Windows Authentication is enabled

### ETW Session Already Exists

```powershell
/power-trace cleanup
/trace cleanup
```

### Large Trace Files

For long-running traces, monitor disk space. ETL files can grow quickly with high event volume.

---

## Files

| File | Description |
|------|-------------|
| `benchmark.ps1` | SQL Server benchmark script |
| `xevents-trace.ps1` | SQL Server XEvents tracing script |
| `etw-power-trace.ps1` | Windows ETW power tracing script |
| `.claude/commands/benchmark.md` | Claude Code /benchmark command |
| `.claude/commands/trace.md` | Claude Code /trace command |
| `.claude/commands/power-trace.md` | Claude Code /power-trace command |
| `CLAUDE.md` | Project context and instructions |

---

## Advanced Analysis

### Windows Performance Analyzer (WPA)

Open `.etl` files in WPA for detailed timeline analysis:
1. Install Windows Performance Toolkit (part of Windows SDK)
2. Open `C:\temp\PowerActivityTrace.etl`
3. Add graphs for CPU, Disk, Network activity

### Combining Data Sources

All CSV files use timestamps, allowing correlation across data sources:
- Match high CPU power (RAPL) with specific SQL queries (XEvents)
- Correlate disk I/O spikes with query execution times
- Analyze network activity during database operations

### SQLCMD Direct Queries

```bash
sqlcmd -S "TOMER-BOOK3\SQLEXPRESS" -E -d BenchmarkTest -Q "SELECT TOP 10 * FROM TestTable"
```

---

## License

Internal use only.
