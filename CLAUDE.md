# Project Context

## Environment

- **Machine:** TOMER-BOOK3
- **Platform:** Windows

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
- `cleanup` - Stop session and remove trace files
- `auto` - Full workflow: create, start, prompt for benchmark, stop, read

**Examples:**
```
/trace                    # show status
/trace create             # create new session
/trace start              # start tracing
/trace stop               # stop tracing
/trace read               # analyze captured events
/trace cleanup            # clean up session and files
/trace auto               # full automated workflow with benchmark
```

**Captured Events:**
- `sql_statement_completed` - Query execution with duration, CPU, reads
- `rpc_completed` - Parameterized query execution
- `wait_completed` - Wait statistics (>1ms)
- `lock_acquired` - Lock contention (exclusive+)
- `error_reported` - Errors (severity >= 11)

**Script location:** `C:\src\pp\dbcc\xevents-trace.ps1`
**Trace output:** `C:\temp\BenchmarkTrace.xel`

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
- `C:\temp\PowerActivityTrace.etl` - ETW events (open in WPA)
- `C:\temp\PowerActivityTrace-perfcounters.csv` - Performance counter samples
- `C:\temp\PowerActivityTrace-rapl.csv` - Intel RAPL power readings
- `C:\temp\PowerActivityTrace-gpu.csv` - NVIDIA GPU metrics
- `C:\temp\PowerActivityTrace-ipmi.csv` - IPMI/BMC sensor readings

**Script location:** `C:\src\pp\dbcc\etw-power-trace.ps1`

**Tips:**
- For accurate Intel RAPL, run LibreHardwareMonitor
- For IPMI readings, install ipmitool or vendor tools (Dell OMSA, HP iLO)
- Open ETL files in Windows Performance Analyzer (WPA) for timeline analysis
- Requires Administrator privileges
