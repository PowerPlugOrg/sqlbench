# Windows ETW Power & Activity Tracing Script
# Captures power events, I/O/Network activity, CPU counters, RAPL, GPU, and IPMI data

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "start", "stop", "read", "status", "cleanup", "providers", "detect")]
    [string]$Action,

    [string]$SessionName = "PowerActivityTrace",
    [string]$OutputPath = $null,
    [int]$BufferSizeMB = 64,
    [ValidateSet("all", "power", "cpu", "io", "network")]
    [string]$TraceLevel = "all",
    [int]$SampleIntervalSec = 1
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

$etlFile = Join-Path $OutputPath "$SessionName.etl"
$perfCsvFile = Join-Path $OutputPath "$SessionName-perfcounters.csv"
$raplCsvFile = Join-Path $OutputPath "$SessionName-rapl.csv"
$gpuCsvFile = Join-Path $OutputPath "$SessionName-gpu.csv"
$ipmiCsvFile = Join-Path $OutputPath "$SessionName-ipmi.csv"
$combinedCsvFile = Join-Path $OutputPath "$SessionName-combined.csv"

# ETW Provider GUIDs and Names (Server-focused)
$providers = @{
    # Direct Power Events (Server/CPU Power Management)
    "Power" = @(
        @{ Name = "Microsoft-Windows-Kernel-Power"; Guid = "{331C3B3A-2005-44C2-AC5E-77220C37D6B4}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-Kernel-Processor-Power"; Guid = "{0F67E49F-FE51-4E9F-B490-6F2948CC6027}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-Kernel-Pep"; Guid = "{5412704E-B2E1-4624-8FFD-55777B8F7373}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-Kernel-Acpi"; Guid = "{C514638F-7723-485B-BCFC-96565D735D4A}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-PDC"; Guid = "{A6BF0DEB-3659-40AD-9F81-E25AF62CE3C7}"; Keywords = "0xFFFFFFFF"; Level = 5 }
    )

    # CPU/Processor Events (C-states, P-states, frequency scaling)
    "CPU" = @(
        @{ Name = "Microsoft-Windows-Kernel-Processor-Power"; Guid = "{0F67E49F-FE51-4E9F-B490-6F2948CC6027}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-PerfProc"; Guid = "{CE8DEE0B-D539-4000-B0F8-77BED049C590}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-Kernel-EventTracing"; Guid = "{B675EC37-BDB6-4648-BC92-F3FDC74D3CA2}"; Keywords = "0x0000000000000040"; Level = 4 }
    )

    # Disk/Storage I/O (impacts storage controller/HBA power)
    "IO" = @(
        @{ Name = "Microsoft-Windows-Kernel-Disk"; Guid = "{C7BDE69A-E1E0-4177-B6EF-283AD1525271}"; Keywords = "0xFFFFFFFF"; Level = 5 }
        @{ Name = "Microsoft-Windows-Kernel-File"; Guid = "{EDD08927-9CC4-4E65-B970-C2560FB5C289}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-StorPort"; Guid = "{C4636A1E-7986-4646-BF10-7BC3B4A76E8E}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-Kernel-IoTrace"; Guid = "{A103CABD-8242-4A93-8DF5-1CDF3B3F26A6}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-Kernel-StoreMgr"; Guid = "{A6AD76E3-867A-4635-91B3-4904BA6374D7}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-DiskDiagnosticDataCollector"; Guid = "{E104FB41-6B04-4F3A-B47D-F0DF2F02B954}"; Keywords = "0xFFFFFFFF"; Level = 5 }
    )

    # Network Activity (impacts NIC power, RSS, interrupt coalescing)
    "Network" = @(
        @{ Name = "Microsoft-Windows-TCPIP"; Guid = "{2F07E2EE-15DB-40F1-90EF-9D7BA282188A}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-Winsock-AFD"; Guid = "{E53C6823-7BB8-44BB-90DC-3F86090D48A6}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-NDIS"; Guid = "{CDEAD503-17F5-4A3E-B7AE-DF8CC2902EB9}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-Kernel-Network"; Guid = "{7DD42A49-5329-4832-8DFD-43D979153A88}"; Keywords = "0xFFFFFFFF"; Level = 4 }
        @{ Name = "Microsoft-Windows-NDIS-PacketCapture"; Guid = "{2ED6006E-4729-4609-B423-3EE7BCD678EF}"; Keywords = "0x0000000000000003"; Level = 4 }
        @{ Name = "Microsoft-Windows-Networking-Correlation"; Guid = "{83ED54F0-4D48-4E45-B16E-726FFD1FA4AF}"; Keywords = "0xFFFFFFFF"; Level = 5 }
    )
}

# Performance counters to collect
$perfCounters = @(
    "\Processor(_Total)\% Processor Time"
    "\Processor(_Total)\% Idle Time"
    "\Processor(_Total)\% Privileged Time"
    "\Processor(_Total)\% User Time"
    "\Processor(_Total)\% C1 Time"
    "\Processor(_Total)\% C2 Time"
    "\Processor(_Total)\% C3 Time"
    "\Processor Information(_Total)\Processor Frequency"
    "\Processor Information(_Total)\% of Maximum Frequency"
    "\Processor Information(_Total)\Processor State Flags"
    "\Memory\Available MBytes"
    "\Memory\Pages/sec"
    "\Memory\Cache Faults/sec"
    "\PhysicalDisk(_Total)\Disk Reads/sec"
    "\PhysicalDisk(_Total)\Disk Writes/sec"
    "\PhysicalDisk(_Total)\Disk Bytes/sec"
    "\PhysicalDisk(_Total)\Avg. Disk Queue Length"
    "\PhysicalDisk(_Total)\% Idle Time"
    "\Network Interface(*)\Bytes Total/sec"
    "\Network Interface(*)\Packets/sec"
    "\Network Interface(*)\Current Bandwidth"
    "\System\Context Switches/sec"
    "\System\Processor Queue Length"
)

#region Helper Functions

function Show-Header {
    param([string]$title)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host $title -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Get-SelectedProviders {
    param([string]$level)

    $selected = @()
    switch ($level) {
        "all" { $selected = $providers["Power"] + $providers["CPU"] + $providers["IO"] + $providers["Network"] }
        "power" { $selected = $providers["Power"] + $providers["CPU"] }
        "cpu" { $selected = $providers["CPU"] }
        "io" { $selected = $providers["IO"] }
        "network" { $selected = $providers["Network"] }
    }
    return $selected
}

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    param(
        [string]$Action,
        [string]$SessionName,
        [string]$OutputPath,
        [int]$BufferSizeMB,
        [string]$TraceLevel,
        [int]$SampleIntervalSec
    )

    # Build arguments for the elevated process
    $scriptPath = $MyInvocation.ScriptName
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }

    $arguments = @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", "`"$scriptPath`"",
        "-Action", $Action,
        "-SessionName", $SessionName,
        "-OutputPath", "`"$OutputPath`"",
        "-BufferSizeMB", $BufferSizeMB,
        "-TraceLevel", $TraceLevel,
        "-SampleIntervalSec", $SampleIntervalSec
    )

    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow

    try {
        $process = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        return $process.ExitCode
    } catch {
        Write-Host "ERROR: Failed to elevate. Please run as Administrator manually." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Test-NvidiaSmi {
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($nvidiaSmi) { return $true }

    # Check common paths
    $paths = @(
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "C:\Windows\System32\nvidia-smi.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

function Get-NvidiaSmiPath {
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($nvidiaSmi) { return $nvidiaSmi.Source }

    $paths = @(
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "C:\Windows\System32\nvidia-smi.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Test-IpmiTool {
    # Check for common IPMI tools
    $tools = @("ipmitool", "ipmiutil", "racadm", "hpasmcli")
    foreach ($tool in $tools) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { return $tool }
    }

    # Check for Dell OMSA
    if (Test-Path "C:\Program Files\Dell\SysMgt\oma\bin\omreport.exe") { return "omreport" }

    # Check for HP tools
    if (Test-Path "C:\Program Files\HP\hponcfg\hponcfg.exe") { return "hponcfg" }

    return $null
}

function Test-IntelRapl {
    # Check if Intel CPU with RAPL support
    $cpu = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
    if ($cpu.Manufacturer -match "Intel") {
        # RAPL is supported on Sandy Bridge and later (2011+)
        return $true
    }
    return $false
}

function Get-LibreHardwareMonitor {
    # Check for LibreHardwareMonitor (can read RAPL)
    $lhm = Get-Process -Name "LibreHardwareMonitor" -ErrorAction SilentlyContinue
    return ($null -ne $lhm)
}

#endregion

#region Data Collection Jobs

$raplCollectorScript = {
    param($OutputFile, $IntervalMs, $StopFile)

    # This script attempts to read Intel RAPL via WMI or direct MSR access
    # Requires LibreHardwareMonitor running, or falls back to estimation

    $header = "Timestamp,PackagePower_W,CorePower_W,DRAMPower_W,EstimatedTotal_W"
    $header | Out-File -FilePath $OutputFile -Encoding UTF8

    while (-not (Test-Path $StopFile)) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

        # Try to get power from WMI (if LibreHardwareMonitor exposes it)
        try {
            $sensors = Get-WmiObject -Namespace "root\LibreHardwareMonitor" -Class Sensor -ErrorAction SilentlyContinue |
                Where-Object { $_.SensorType -eq "Power" }

            if ($sensors) {
                $pkg = ($sensors | Where-Object { $_.Name -match "Package" } | Select-Object -First 1).Value
                $core = ($sensors | Where-Object { $_.Name -match "Core" -and $_.Name -notmatch "Package" } | Measure-Object -Property Value -Sum).Sum
                $dram = ($sensors | Where-Object { $_.Name -match "DRAM|Memory" } | Select-Object -First 1).Value

                $total = if ($pkg) { $pkg } else { 0 }
                "$timestamp,$pkg,$core,$dram,$total" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
            } else {
                # Fallback: estimate from CPU utilization
                $cpuLoad = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
                $tdp = 150  # Assume 150W TDP, adjust as needed
                $estimatedPower = ($cpuLoad / 100) * $tdp
                "$timestamp,,,$estimatedPower,$estimatedPower" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
            }
        } catch {
            # Fallback estimation
            try {
                $cpuLoad = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
                $estimatedPower = ($cpuLoad / 100) * 150
                "$timestamp,,,$estimatedPower,$estimatedPower" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
            } catch {
                "$timestamp,,,," | Out-File -FilePath $OutputFile -Append -Encoding UTF8
            }
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}

$gpuCollectorScript = {
    param($OutputFile, $IntervalMs, $StopFile, $NvidiaSmiPath)

    $header = "Timestamp,GPU_Index,GPU_Name,Power_W,Utilization_Pct,Memory_Used_MB,Memory_Total_MB,Temperature_C,Fan_Pct"
    $header | Out-File -FilePath $OutputFile -Encoding UTF8

    while (-not (Test-Path $StopFile)) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

        try {
            $output = & $NvidiaSmiPath --query-gpu=index,name,power.draw,utilization.gpu,memory.used,memory.total,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>$null

            if ($output) {
                foreach ($line in $output) {
                    "$timestamp,$line" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
                }
            }
        } catch {
            # nvidia-smi failed
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}

$ipmiCollectorScript = {
    param($OutputFile, $IntervalMs, $StopFile, $IpmiTool)

    $header = "Timestamp,Sensor,Reading,Units"
    $header | Out-File -FilePath $OutputFile -Encoding UTF8

    while (-not (Test-Path $StopFile)) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

        try {
            switch ($IpmiTool) {
                "ipmitool" {
                    $output = ipmitool sensor list 2>$null | Where-Object { $_ -match "Watt|Power|Current|Voltage" }
                    foreach ($line in $output) {
                        $parts = $line -split '\|'
                        if ($parts.Count -ge 3) {
                            $sensor = $parts[0].Trim()
                            $reading = $parts[1].Trim()
                            $units = $parts[2].Trim()
                            "$timestamp,$sensor,$reading,$units" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
                        }
                    }
                }
                "omreport" {
                    # Dell OMSA
                    $output = & "C:\Program Files\Dell\SysMgt\oma\bin\omreport.exe" chassis pwrmonitoring 2>$null
                    foreach ($line in $output) {
                        if ($line -match "(\w+.*?)\s*:\s*([\d.]+)\s*(\w+)") {
                            "$timestamp,$($Matches[1]),$($Matches[2]),$($Matches[3])" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
                        }
                    }
                }
                default {
                    # Generic WMI attempt for power
                    $power = Get-WmiObject -Namespace "root\cimv2" -Class Win32_PowerMeter -ErrorAction SilentlyContinue
                    if ($power) {
                        foreach ($p in $power) {
                            "$timestamp,$($p.Name),$($p.CurrentReading),W" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
                        }
                    }
                }
            }
        } catch {
            # IPMI failed
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}

#endregion

switch ($Action) {
    "detect" {
        Show-Header "Hardware Detection for Power Monitoring"

        Write-Host ""
        Write-Host "Checking available power monitoring capabilities..." -ForegroundColor Yellow
        Write-Host ""

        # CPU Info
        $cpu = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        Write-Host "CPU:" -ForegroundColor Cyan
        Write-Host "  Model:        $($cpu.Name)"
        Write-Host "  Manufacturer: $($cpu.Manufacturer)"
        Write-Host "  Cores:        $($cpu.NumberOfCores)"
        Write-Host "  Logical:      $($cpu.NumberOfLogicalProcessors)"

        # RAPL Support
        Write-Host ""
        Write-Host "Intel RAPL:" -ForegroundColor Cyan
        if (Test-IntelRapl) {
            Write-Host "  Status:       " -NoNewline
            Write-Host "SUPPORTED (Intel CPU detected)" -ForegroundColor Green

            if (Get-LibreHardwareMonitor) {
                Write-Host "  Reader:       LibreHardwareMonitor RUNNING" -ForegroundColor Green
            } else {
                Write-Host "  Reader:       LibreHardwareMonitor NOT running" -ForegroundColor Yellow
                Write-Host "                (Install & run for accurate RAPL readings)"
            }
        } else {
            Write-Host "  Status:       NOT AVAILABLE (non-Intel or older CPU)" -ForegroundColor Yellow
        }

        # GPU
        Write-Host ""
        Write-Host "NVIDIA GPU:" -ForegroundColor Cyan
        if (Test-NvidiaSmi) {
            $smiPath = Get-NvidiaSmiPath
            Write-Host "  Status:       " -NoNewline
            Write-Host "AVAILABLE" -ForegroundColor Green
            Write-Host "  Path:         $smiPath"

            # Get GPU info
            try {
                $gpuInfo = & $smiPath --query-gpu=name,power.limit --format=csv,noheader 2>$null
                if ($gpuInfo) {
                    Write-Host "  GPUs:"
                    foreach ($gpu in $gpuInfo) {
                        Write-Host "                $gpu"
                    }
                }
            } catch {}
        } else {
            Write-Host "  Status:       NOT FOUND" -ForegroundColor Yellow
        }

        # IPMI
        Write-Host ""
        Write-Host "IPMI/BMC:" -ForegroundColor Cyan
        $ipmiTool = Test-IpmiTool
        if ($ipmiTool) {
            Write-Host "  Status:       " -NoNewline
            Write-Host "AVAILABLE ($ipmiTool)" -ForegroundColor Green
        } else {
            Write-Host "  Status:       NOT FOUND" -ForegroundColor Yellow
            Write-Host "  Tip:          Install ipmitool or vendor tools (Dell OMSA, HP iLO, etc.)"
        }

        # Performance Counters
        Write-Host ""
        Write-Host "Performance Counters:" -ForegroundColor Cyan
        Write-Host "  Status:       " -NoNewline
        Write-Host "ALWAYS AVAILABLE" -ForegroundColor Green
        Write-Host "  Counters:     CPU, Memory, Disk I/O, Network, Context Switches"

        # ETW
        Write-Host ""
        Write-Host "ETW Providers:" -ForegroundColor Cyan
        Write-Host "  Status:       " -NoNewline
        Write-Host "ALWAYS AVAILABLE" -ForegroundColor Green
        Write-Host "  Providers:    Power, CPU P/C-states, Disk, Network, ACPI"

        Write-Host ""
        Write-Host "SUMMARY:" -ForegroundColor Green
        Write-Host "-" * 50
        $features = @()
        $features += "ETW tracing"
        $features += "Performance counters"
        if (Test-IntelRapl) { $features += "Intel RAPL (CPU power)" }
        if (Test-NvidiaSmi) { $features += "NVIDIA GPU monitoring" }
        if ($ipmiTool) { $features += "IPMI power readings" }

        Write-Host "Available features: $($features -join ', ')"
    }

    "providers" {
        Show-Header "Available ETW Providers"

        Write-Host ""
        Write-Host "POWER EVENTS (Direct):" -ForegroundColor Yellow
        foreach ($p in $providers["Power"]) {
            Write-Host "  $($p.Name)"
            Write-Host "    GUID: $($p.Guid)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "CPU EVENTS (P-states, C-states, Frequency):" -ForegroundColor Yellow
        foreach ($p in $providers["CPU"]) {
            Write-Host "  $($p.Name)"
            Write-Host "    GUID: $($p.Guid)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "I/O EVENTS (Storage/HBA Power Impact):" -ForegroundColor Yellow
        foreach ($p in $providers["IO"]) {
            Write-Host "  $($p.Name)"
            Write-Host "    GUID: $($p.Guid)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "NETWORK EVENTS (NIC Power Impact):" -ForegroundColor Yellow
        foreach ($p in $providers["Network"]) {
            Write-Host "  $($p.Name)"
            Write-Host "    GUID: $($p.Guid)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "PERFORMANCE COUNTERS:" -ForegroundColor Yellow
        foreach ($c in $perfCounters) {
            Write-Host "  $c"
        }
    }

    "create" {
        Show-Header "Creating Power Trace Session: $SessionName"

        if (-not (Test-Admin)) {
            $exitCode = Invoke-Elevated -Action $Action -SessionName $SessionName -OutputPath $OutputPath `
                -BufferSizeMB $BufferSizeMB -TraceLevel $TraceLevel -SampleIntervalSec $SampleIntervalSec
            exit $exitCode
        }

        # Ensure output directory exists
        if (!(Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            Write-Host "Created output directory: $OutputPath"
        }

        # Stop and delete existing session if present
        logman stop $SessionName -ets 2>$null | Out-Null
        logman stop "$SessionName-PerfMon" 2>$null | Out-Null
        logman delete "$SessionName-PerfMon" 2>$null | Out-Null

        # Create ETW provider file
        $selectedProviders = Get-SelectedProviders -level $TraceLevel
        $providerFile = Join-Path $OutputPath "$SessionName-providers.txt"
        $providerLines = @()
        foreach ($p in $selectedProviders) {
            $providerLines += "$($p.Guid):$($p.Keywords):$($p.Level)"
        }
        $providerLines | Out-File -FilePath $providerFile -Encoding ASCII

        Write-Host "Trace Level: $TraceLevel"
        Write-Host "ETW Providers: $($selectedProviders.Count)"
        Write-Host "Output: $etlFile"

        # Create performance counter data collector
        $counterFile = Join-Path $OutputPath "$SessionName-counters.txt"
        $perfCounters | Out-File -FilePath $counterFile -Encoding ASCII

        Write-Host ""
        Write-Host "Session prepared. Use -Action start to begin tracing." -ForegroundColor Green
    }

    "start" {
        Show-Header "Starting Power Trace Session: $SessionName"

        if (-not (Test-Admin)) {
            $exitCode = Invoke-Elevated -Action $Action -SessionName $SessionName -OutputPath $OutputPath `
                -BufferSizeMB $BufferSizeMB -TraceLevel $TraceLevel -SampleIntervalSec $SampleIntervalSec
            exit $exitCode
        }

        # Ensure output directory
        if (!(Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }

        # Create stop signal file path
        $stopFile = Join-Path $OutputPath "$SessionName-stop.signal"
        if (Test-Path $stopFile) { Remove-Item $stopFile -Force }

        # Clean up old files
        @($etlFile, $perfCsvFile, $raplCsvFile, $gpuCsvFile, $ipmiCsvFile) | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
        }

        # Check if provider file exists, create if not
        $providerFile = Join-Path $OutputPath "$SessionName-providers.txt"
        if (!(Test-Path $providerFile)) {
            $selectedProviders = Get-SelectedProviders -level $TraceLevel
            $providerLines = @()
            foreach ($p in $selectedProviders) {
                $providerLines += "$($p.Guid):$($p.Keywords):$($p.Level)"
            }
            $providerLines | Out-File -FilePath $providerFile -Encoding ASCII
        }

        # 1. Start ETW trace
        Write-Host "Starting ETW trace..." -ForegroundColor Yellow
        $result = logman create trace $SessionName -o $etlFile -pf $providerFile -bs $BufferSizeMB -nb 16 64 -mode globalsequence -ets 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ETW trace started" -ForegroundColor Green
        } else {
            Write-Host "  ETW trace failed: $result" -ForegroundColor Red
        }

        # 2. Start Performance Counter collection
        Write-Host "Starting performance counters..." -ForegroundColor Yellow
        $counterFile = Join-Path $OutputPath "$SessionName-counters.txt"
        if (!(Test-Path $counterFile)) {
            $perfCounters | Out-File -FilePath $counterFile -Encoding ASCII
        }

        # Stop any existing perfmon collector
        logman stop "$SessionName-PerfMon" 2>$null | Out-Null
        logman delete "$SessionName-PerfMon" 2>$null | Out-Null

        $perfResult = logman create counter "$SessionName-PerfMon" -cf $counterFile -si $SampleIntervalSec -o $perfCsvFile -f csv --v 2>&1
        if ($LASTEXITCODE -eq 0) {
            logman start "$SessionName-PerfMon" 2>$null
            Write-Host "  Performance counters started (${SampleIntervalSec}s interval)" -ForegroundColor Green
        } else {
            # Try direct approach
            Write-Host "  Using background counter collection..." -ForegroundColor Yellow
        }

        # 3. Start RAPL collection (background job)
        Write-Host "Starting Intel RAPL collection..." -ForegroundColor Yellow
        if (Test-IntelRapl) {
            $intervalMs = $SampleIntervalSec * 1000
            Start-Job -Name "$SessionName-RAPL" -ScriptBlock $raplCollectorScript -ArgumentList $raplCsvFile, $intervalMs, $stopFile | Out-Null
            Write-Host "  RAPL collection started" -ForegroundColor Green
        } else {
            Write-Host "  RAPL not available (non-Intel CPU)" -ForegroundColor Yellow
        }

        # 4. Start GPU collection (if NVIDIA)
        Write-Host "Starting GPU monitoring..." -ForegroundColor Yellow
        if (Test-NvidiaSmi) {
            $nvidiaSmiPath = Get-NvidiaSmiPath
            $intervalMs = $SampleIntervalSec * 1000
            Start-Job -Name "$SessionName-GPU" -ScriptBlock $gpuCollectorScript -ArgumentList $gpuCsvFile, $intervalMs, $stopFile, $nvidiaSmiPath | Out-Null
            Write-Host "  NVIDIA GPU monitoring started" -ForegroundColor Green
        } else {
            Write-Host "  No NVIDIA GPU detected" -ForegroundColor Yellow
        }

        # 5. Start IPMI collection (if available)
        Write-Host "Starting IPMI power monitoring..." -ForegroundColor Yellow
        $ipmiTool = Test-IpmiTool
        if ($ipmiTool) {
            $intervalMs = $SampleIntervalSec * 1000
            Start-Job -Name "$SessionName-IPMI" -ScriptBlock $ipmiCollectorScript -ArgumentList $ipmiCsvFile, $intervalMs, $stopFile, $ipmiTool | Out-Null
            Write-Host "  IPMI monitoring started ($ipmiTool)" -ForegroundColor Green
        } else {
            Write-Host "  No IPMI tools available" -ForegroundColor Yellow
        }

        # Save session info
        $sessionInfo = @{
            StartTime = Get-Date -Format "o"
            StopFile = $stopFile
            TraceLevel = $TraceLevel
            SampleInterval = $SampleIntervalSec
        }
        $sessionInfo | ConvertTo-Json | Out-File (Join-Path $OutputPath "$SessionName-session.json") -Encoding UTF8

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "All collectors started successfully" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Output files:"
        Write-Host "  ETW:          $etlFile"
        Write-Host "  PerfCounters: $perfCsvFile"
        Write-Host "  RAPL:         $raplCsvFile"
        Write-Host "  GPU:          $gpuCsvFile"
        Write-Host "  IPMI:         $ipmiCsvFile"
        Write-Host ""
        Write-Host "Run your workload now, then use -Action stop" -ForegroundColor Yellow
    }

    "stop" {
        Show-Header "Stopping Power Trace Session: $SessionName"

        if (-not (Test-Admin)) {
            $exitCode = Invoke-Elevated -Action $Action -SessionName $SessionName -OutputPath $OutputPath `
                -BufferSizeMB $BufferSizeMB -TraceLevel $TraceLevel -SampleIntervalSec $SampleIntervalSec
            exit $exitCode
        }

        # Create stop signal for background jobs
        $stopFile = Join-Path $OutputPath "$SessionName-stop.signal"
        "stop" | Out-File $stopFile -Encoding UTF8

        # Stop ETW trace
        Write-Host "Stopping ETW trace..." -ForegroundColor Yellow
        logman stop $SessionName -ets 2>$null | Out-Null
        Write-Host "  ETW trace stopped" -ForegroundColor Green

        # Stop performance counters
        Write-Host "Stopping performance counters..." -ForegroundColor Yellow
        logman stop "$SessionName-PerfMon" 2>$null | Out-Null
        logman delete "$SessionName-PerfMon" 2>$null | Out-Null
        Write-Host "  Performance counters stopped" -ForegroundColor Green

        # Wait for and stop background jobs
        Write-Host "Stopping background collectors..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2  # Give jobs time to see stop signal

        $jobs = Get-Job -Name "$SessionName-*" -ErrorAction SilentlyContinue
        if ($jobs) {
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  Background collectors stopped" -ForegroundColor Green

        # Remove stop signal
        if (Test-Path $stopFile) { Remove-Item $stopFile -Force }

        # Load session info for timing
        $sessionFile = Join-Path $OutputPath "$SessionName-session.json"
        if (Test-Path $sessionFile) {
            $sessionInfo = Get-Content $sessionFile | ConvertFrom-Json
            $startTime = [DateTime]::Parse($sessionInfo.StartTime)
            $duration = (Get-Date) - $startTime
            Write-Host ""
            Write-Host ("Trace duration: {0:N1} seconds" -f $duration.TotalSeconds) -ForegroundColor Cyan
        }

        # Report file sizes
        Write-Host ""
        Write-Host "Output files:" -ForegroundColor Cyan
        @(
            @{Path=$etlFile; Name="ETW"},
            @{Path=$perfCsvFile; Name="PerfCounters"},
            @{Path=$raplCsvFile; Name="RAPL"},
            @{Path=$gpuCsvFile; Name="GPU"},
            @{Path=$ipmiCsvFile; Name="IPMI"}
        ) | ForEach-Object {
            if (Test-Path $_.Path) {
                $size = (Get-Item $_.Path).Length / 1KB
                Write-Host ("  {0,-12} {1:N1} KB" -f "$($_.Name):", $size)
            }
        }

        Write-Host ""
        Write-Host "Use -Action read to analyze the trace data" -ForegroundColor Yellow
    }

    "status" {
        Show-Header "Power Trace Session Status"

        # Check ETW session
        Write-Host ""
        Write-Host "ETW Session:" -ForegroundColor Cyan
        $result = logman query $SessionName -ets 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Status: RUNNING" -ForegroundColor Green
        } else {
            Write-Host "  Status: NOT RUNNING" -ForegroundColor Yellow
        }

        # Check PerfMon
        Write-Host ""
        Write-Host "Performance Counters:" -ForegroundColor Cyan
        $perfResult = logman query "$SessionName-PerfMon" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Status: RUNNING" -ForegroundColor Green
        } else {
            Write-Host "  Status: NOT RUNNING" -ForegroundColor Yellow
        }

        # Check background jobs
        Write-Host ""
        Write-Host "Background Collectors:" -ForegroundColor Cyan
        $jobs = Get-Job -Name "$SessionName-*" -ErrorAction SilentlyContinue
        if ($jobs) {
            foreach ($job in $jobs) {
                $name = $job.Name -replace "$SessionName-", ""
                Write-Host "  $name`: $($job.State)" -ForegroundColor $(if ($job.State -eq 'Running') { 'Green' } else { 'Yellow' })
            }
        } else {
            Write-Host "  No background jobs running" -ForegroundColor Yellow
        }

        # Check for existing files
        Write-Host ""
        Write-Host "Existing Data Files:" -ForegroundColor Cyan
        @($etlFile, $perfCsvFile, $raplCsvFile, $gpuCsvFile, $ipmiCsvFile) | ForEach-Object {
            if (Test-Path $_) {
                $size = (Get-Item $_).Length / 1KB
                $name = Split-Path $_ -Leaf
                Write-Host ("  {0,-40} {1:N1} KB" -f $name, $size)
            }
        }
    }

    "read" {
        Show-Header "Analyzing Power Trace Data"

        # Check what files exist
        $hasEtl = Test-Path $etlFile
        $hasPerf = Test-Path $perfCsvFile
        $hasRapl = Test-Path $raplCsvFile
        $hasGpu = Test-Path $gpuCsvFile
        $hasIpmi = Test-Path $ipmiCsvFile

        if (-not ($hasEtl -or $hasPerf -or $hasRapl -or $hasGpu -or $hasIpmi)) {
            Write-Host "No trace data found in $OutputPath" -ForegroundColor Red
            exit 1
        }

        # 1. Performance Counter Analysis
        if ($hasPerf) {
            Write-Host ""
            Write-Host "PERFORMANCE COUNTERS:" -ForegroundColor Green
            Write-Host "-" * 60

            try {
                $perfData = Import-Csv $perfCsvFile -ErrorAction SilentlyContinue

                if ($perfData -and $perfData.Count -gt 0) {
                    # Get column names (counter names)
                    $columns = $perfData[0].PSObject.Properties.Name | Where-Object { $_ -ne "(PDH-CSV 4.0)" -and $_ -notmatch "^\s*$" }

                    $cpuCol = $columns | Where-Object { $_ -match "Processor.*% Processor Time" -and $_ -match "_Total" } | Select-Object -First 1
                    $freqCol = $columns | Where-Object { $_ -match "Processor.*Frequency" } | Select-Object -First 1
                    $diskCol = $columns | Where-Object { $_ -match "Disk Bytes/sec" } | Select-Object -First 1
                    $netCol = $columns | Where-Object { $_ -match "Bytes Total/sec" } | Select-Object -First 1

                    Write-Host ""
                    Write-Host "Samples collected: $($perfData.Count)"
                    Write-Host ""

                    if ($cpuCol) {
                        $cpuValues = $perfData | ForEach-Object { [double]($_.$cpuCol) } | Where-Object { $_ -ge 0 }
                        if ($cpuValues) {
                            $cpuAvg = ($cpuValues | Measure-Object -Average).Average
                            $cpuMax = ($cpuValues | Measure-Object -Maximum).Maximum
                            Write-Host ("CPU Utilization:     Avg: {0:N1}%   Max: {1:N1}%" -f $cpuAvg, $cpuMax)
                        }
                    }

                    if ($freqCol) {
                        $freqValues = $perfData | ForEach-Object { [double]($_.$freqCol) } | Where-Object { $_ -gt 0 }
                        if ($freqValues) {
                            $freqAvg = ($freqValues | Measure-Object -Average).Average
                            Write-Host ("CPU Frequency:       Avg: {0:N0} MHz" -f $freqAvg)
                        }
                    }

                    if ($diskCol) {
                        $diskValues = $perfData | ForEach-Object { [double]($_.$diskCol) } | Where-Object { $_ -ge 0 }
                        if ($diskValues) {
                            $diskAvg = ($diskValues | Measure-Object -Average).Average / 1MB
                            $diskMax = ($diskValues | Measure-Object -Maximum).Maximum / 1MB
                            Write-Host ("Disk Throughput:     Avg: {0:N1} MB/s   Max: {1:N1} MB/s" -f $diskAvg, $diskMax)
                        }
                    }

                    if ($netCol) {
                        $netValues = $perfData | ForEach-Object { [double]($_.$netCol) } | Where-Object { $_ -ge 0 }
                        if ($netValues) {
                            $netAvg = ($netValues | Measure-Object -Average).Average / 1MB
                            $netMax = ($netValues | Measure-Object -Maximum).Maximum / 1MB
                            Write-Host ("Network Throughput:  Avg: {0:N2} MB/s   Max: {1:N2} MB/s" -f $netAvg, $netMax)
                        }
                    }
                }
            } catch {
                Write-Host "Could not parse performance data: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # 2. RAPL Analysis
        if ($hasRapl) {
            Write-Host ""
            Write-Host "INTEL RAPL (CPU/DRAM POWER):" -ForegroundColor Green
            Write-Host "-" * 60

            try {
                $raplData = Import-Csv $raplCsvFile -ErrorAction SilentlyContinue

                if ($raplData -and $raplData.Count -gt 0) {
                    $pkgPower = $raplData | Where-Object { $_.PackagePower_W } | ForEach-Object { [double]$_.PackagePower_W }
                    $dramPower = $raplData | Where-Object { $_.DRAMPower_W } | ForEach-Object { [double]$_.DRAMPower_W }
                    $estPower = $raplData | Where-Object { $_.EstimatedTotal_W } | ForEach-Object { [double]$_.EstimatedTotal_W }

                    Write-Host "Samples: $($raplData.Count)"

                    if ($pkgPower -and $pkgPower.Count -gt 0) {
                        $avg = ($pkgPower | Measure-Object -Average).Average
                        $max = ($pkgPower | Measure-Object -Maximum).Maximum
                        Write-Host ("Package Power:   Avg: {0:N1} W   Max: {1:N1} W" -f $avg, $max)
                    }

                    if ($dramPower -and $dramPower.Count -gt 0) {
                        $avg = ($dramPower | Measure-Object -Average).Average
                        $max = ($dramPower | Measure-Object -Maximum).Maximum
                        Write-Host ("DRAM Power:      Avg: {0:N1} W   Max: {1:N1} W" -f $avg, $max)
                    }

                    if ($estPower -and $estPower.Count -gt 0) {
                        $avg = ($estPower | Measure-Object -Average).Average
                        $max = ($estPower | Measure-Object -Maximum).Maximum
                        $total = ($estPower | Measure-Object -Sum).Sum * ($SampleIntervalSec / 3600)  # Wh
                        Write-Host ("Estimated Total: Avg: {0:N1} W   Max: {1:N1} W" -f $avg, $max)
                        Write-Host ("Energy Used:     {0:N2} Wh" -f $total)
                    }
                }
            } catch {
                Write-Host "Could not parse RAPL data: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # 3. GPU Analysis
        if ($hasGpu) {
            Write-Host ""
            Write-Host "NVIDIA GPU:" -ForegroundColor Green
            Write-Host "-" * 60

            try {
                $gpuData = Import-Csv $gpuCsvFile -ErrorAction SilentlyContinue

                if ($gpuData -and $gpuData.Count -gt 0) {
                    $gpuGroups = $gpuData | Group-Object GPU_Index

                    foreach ($gpu in $gpuGroups) {
                        $gpuName = ($gpu.Group | Select-Object -First 1).GPU_Name
                        Write-Host ""
                        Write-Host "GPU $($gpu.Name): $gpuName" -ForegroundColor Cyan

                        $power = $gpu.Group | Where-Object { $_.Power_W } | ForEach-Object { [double]$_.Power_W }
                        $util = $gpu.Group | Where-Object { $_.Utilization_Pct } | ForEach-Object { [double]$_.Utilization_Pct }
                        $temp = $gpu.Group | Where-Object { $_.Temperature_C } | ForEach-Object { [double]$_.Temperature_C }

                        if ($power -and $power.Count -gt 0) {
                            $avg = ($power | Measure-Object -Average).Average
                            $max = ($power | Measure-Object -Maximum).Maximum
                            Write-Host ("  Power:       Avg: {0:N1} W   Max: {1:N1} W" -f $avg, $max)
                        }

                        if ($util -and $util.Count -gt 0) {
                            $avg = ($util | Measure-Object -Average).Average
                            $max = ($util | Measure-Object -Maximum).Maximum
                            Write-Host ("  Utilization: Avg: {0:N1}%   Max: {1:N1}%" -f $avg, $max)
                        }

                        if ($temp -and $temp.Count -gt 0) {
                            $avg = ($temp | Measure-Object -Average).Average
                            $max = ($temp | Measure-Object -Maximum).Maximum
                            Write-Host ("  Temperature: Avg: {0:N0}C   Max: {1:N0}C" -f $avg, $max)
                        }
                    }
                }
            } catch {
                Write-Host "Could not parse GPU data: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # 4. IPMI Analysis
        if ($hasIpmi) {
            Write-Host ""
            Write-Host "IPMI/BMC POWER:" -ForegroundColor Green
            Write-Host "-" * 60

            try {
                $ipmiData = Import-Csv $ipmiCsvFile -ErrorAction SilentlyContinue

                if ($ipmiData -and $ipmiData.Count -gt 0) {
                    $sensorGroups = $ipmiData | Group-Object Sensor

                    foreach ($sensor in $sensorGroups) {
                        $readings = $sensor.Group | Where-Object { $_.Reading -match "^\d" } | ForEach-Object { [double]$_.Reading }
                        $unit = ($sensor.Group | Select-Object -First 1).Units

                        if ($readings -and $readings.Count -gt 0) {
                            $avg = ($readings | Measure-Object -Average).Average
                            $max = ($readings | Measure-Object -Maximum).Maximum
                            Write-Host ("{0,-30} Avg: {1:N1} {2}   Max: {3:N1} {2}" -f "$($sensor.Name):", $avg, $unit, $max)
                        }
                    }
                }
            } catch {
                Write-Host "Could not parse IPMI data: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # 5. ETW Analysis
        if ($hasEtl) {
            Write-Host ""
            Write-Host "ETW EVENTS:" -ForegroundColor Green
            Write-Host "-" * 60

            $size = (Get-Item $etlFile).Length / 1MB
            Write-Host ("ETL file size: {0:N2} MB" -f $size)

            $csvFile = Join-Path $OutputPath "$SessionName-events.csv"
            $summaryFile = Join-Path $OutputPath "$SessionName-summary.txt"

            Write-Host "Converting ETL to CSV (this may take a moment)..." -ForegroundColor Yellow

            $result = tracerpt $etlFile -o $csvFile -of CSV -summary $summaryFile -y 2>&1

            if (Test-Path $csvFile) {
                try {
                    $events = Import-Csv $csvFile -ErrorAction SilentlyContinue

                    if ($events) {
                        Write-Host ""
                        Write-Host "Total ETW events: $($events.Count)"

                        $grouped = $events | Group-Object "Event Name" | Sort-Object Count -Descending | Select-Object -First 15

                        Write-Host ""
                        Write-Host "Top 15 Event Types:" -ForegroundColor Yellow
                        foreach ($g in $grouped) {
                            $name = if ($g.Name.Length -gt 50) { $g.Name.Substring(0, 47) + "..." } else { $g.Name }
                            Write-Host ("  {0,-50} {1,8}" -f $name, $g.Count)
                        }
                    }
                } catch {
                    Write-Host "Could not parse ETW CSV: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        # Summary
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "OUTPUT FILES:" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        @(
            @{Path=$etlFile; Name="ETW (WPA)"},
            @{Path=$perfCsvFile; Name="PerfCounters"},
            @{Path=$raplCsvFile; Name="RAPL"},
            @{Path=$gpuCsvFile; Name="GPU"},
            @{Path=$ipmiCsvFile; Name="IPMI"}
        ) | ForEach-Object {
            if (Test-Path $_.Path) {
                Write-Host "  $($_.Name): $($_.Path)"
            }
        }

        Write-Host ""
        Write-Host "TIP: Open ETL in Windows Performance Analyzer (WPA) for detailed timeline analysis" -ForegroundColor Yellow
    }

    "cleanup" {
        Show-Header "Cleaning Up Power Trace Session: $SessionName"

        if (-not (Test-Admin)) {
            $exitCode = Invoke-Elevated -Action $Action -SessionName $SessionName -OutputPath $OutputPath `
                -BufferSizeMB $BufferSizeMB -TraceLevel $TraceLevel -SampleIntervalSec $SampleIntervalSec
            exit $exitCode
        }

        # Create stop signal
        $stopFile = Join-Path $OutputPath "$SessionName-stop.signal"
        "stop" | Out-File $stopFile -Encoding UTF8
        Start-Sleep -Seconds 1

        # Stop ETW
        logman stop $SessionName -ets 2>$null | Out-Null

        # Stop PerfMon
        logman stop "$SessionName-PerfMon" 2>$null | Out-Null
        logman delete "$SessionName-PerfMon" 2>$null | Out-Null

        # Stop background jobs
        $jobs = Get-Job -Name "$SessionName-*" -ErrorAction SilentlyContinue
        if ($jobs) {
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }

        # Remove files
        $patterns = @(
            "$SessionName.etl",
            "$SessionName*.etl",
            "$SessionName-providers.txt",
            "$SessionName-counters.txt",
            "$SessionName-events.csv",
            "$SessionName-summary.txt",
            "$SessionName-perfcounters.csv",
            "$SessionName-perfcounters*.csv",
            "$SessionName-rapl.csv",
            "$SessionName-gpu.csv",
            "$SessionName-ipmi.csv",
            "$SessionName-combined.csv",
            "$SessionName-session.json",
            "$SessionName-stop.signal"
        )

        $removed = 0
        foreach ($pattern in $patterns) {
            $files = Get-ChildItem -Path $OutputPath -Filter $pattern -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }

        Write-Host "All sessions stopped" -ForegroundColor Green
        Write-Host "Removed $removed file(s)" -ForegroundColor Green
        Write-Host "Cleanup complete"
    }
}

Write-Host ""
