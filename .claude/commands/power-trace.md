# Windows ETW Power & Activity Tracing

Comprehensive power consumption analysis for servers. Captures ETW events, performance counters, Intel RAPL, NVIDIA GPU, and IPMI data.

## Arguments

$ARGUMENTS - Action and optional trace level: [action] [level]

## Instructions

Parse arguments:
- First argument: action (detect, start, stop, read, status, cleanup, providers) - default: status
- Second argument: trace level (all, power, cpu, io, network) - default: all

**IMPORTANT:** This script requires Administrator privileges. If the command fails with permission errors, inform the user they need to run the terminal as Administrator.

### Available Actions

| Action | Description |
|--------|-------------|
| `detect` | Detect available power monitoring hardware/tools |
| `start` | Start all power trace collectors |
| `stop` | Stop all collectors |
| `read` | Analyze and display all trace results |
| `status` | Show current session status (default) |
| `cleanup` | Stop all sessions and remove trace files |
| `providers` | List all ETW providers and perf counters |

### Trace Levels

| Level | Providers Captured |
|-------|-------------------|
| `all` | Power + CPU + I/O + Network (default) |
| `power` | Power state changes, ACPI, CPU P/C-states |
| `cpu` | Processor frequency, P-states, C-states |
| `io` | Disk I/O, StorPort, storage activity |
| `network` | TCP/IP, NDIS, NIC activity |

### Data Sources Collected

| Source | Data | Availability |
|--------|------|--------------|
| **ETW** | Power events, I/O, Network, CPU states | Always |
| **PerfCounters** | CPU%, Memory, Disk I/O, Network throughput | Always |
| **Intel RAPL** | CPU Package/Core/DRAM power (Watts) | Intel CPUs |
| **NVIDIA GPU** | GPU power, utilization, temperature | NVIDIA GPUs |
| **IPMI/BMC** | System power draw from BMC | Server hardware |

### Command Execution

Run as Administrator:

```
powershell -ExecutionPolicy Bypass -File "C:\src\pp\dbcc\etw-power-trace.ps1" -Action <action> -TraceLevel <level>
```

### Typical Workflow

1. `detect` - Check what monitoring is available
2. `start` - Begin capturing all data sources
3. Run your workload (benchmark, application test, etc.)
4. `stop` - Stop capturing
5. `read` - Analyze all results

### Output Analysis

The `read` action produces summaries for each data source:

**Performance Counters:**
- CPU utilization (avg/max)
- CPU frequency
- Disk throughput (avg/max)
- Network throughput (avg/max)

**Intel RAPL (if available):**
- Package power (avg/max watts)
- DRAM power (avg/max watts)
- Total energy consumed (Wh)

**NVIDIA GPU (if available):**
- Power draw per GPU (avg/max watts)
- GPU utilization (avg/max %)
- Temperature (avg/max C)

**IPMI/BMC (if available):**
- System power readings from BMC sensors

**ETW Events:**
- Top event types by count
- Power/CPU/IO/Network event breakdown

### Examples

```
/power-trace detect             # Check available hardware
/power-trace start              # Start all tracing
/power-trace start io           # Start tracing I/O only
/power-trace stop               # Stop tracing
/power-trace read               # Analyze all data
/power-trace cleanup            # Clean up files
/power-trace providers          # List all providers
```

### Combining with SQL Server Benchmark

For comprehensive analysis:

```
/trace start                    # Start SQL XEvents
/power-trace start              # Start ETW + RAPL + GPU + IPMI
/benchmark mixed 1000 20        # Run benchmark
/power-trace stop               # Stop power tracing
/trace stop                     # Stop XEvents
/power-trace read               # Analyze power/IO/network
/trace read                     # Analyze SQL queries
```

### Output Files

All files are written to `C:\temp\`:

| File | Description |
|------|-------------|
| `PowerActivityTrace.etl` | ETW events (open in WPA) |
| `PowerActivityTrace-perfcounters.csv` | Performance counter samples |
| `PowerActivityTrace-rapl.csv` | Intel RAPL power readings |
| `PowerActivityTrace-gpu.csv` | NVIDIA GPU metrics |
| `PowerActivityTrace-ipmi.csv` | IPMI/BMC sensor readings |

### Tips

- For accurate Intel RAPL readings, install and run [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
- For IPMI readings, install `ipmitool` or vendor tools (Dell OMSA, HP iLO utilities)
- Open ETL files in Windows Performance Analyzer (WPA) for detailed timeline analysis
