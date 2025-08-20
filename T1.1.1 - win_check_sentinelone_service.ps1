# SentinelOne Windows Audit Script
# Author: ChatGPT
# Description: Auto-detects SentinelCtl.exe, checks services, summarizes resource usage, and outputs JSON.

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
Write-Host "[$timestamp] [*] Checking SentinelOne on Windows..." -ForegroundColor Cyan

# Auto-detect SentinelCtl.exe
$SentinelCtl = Get-ChildItem "C:\Program Files\SentinelOne\" -Recurse -Filter SentinelCtl.exe -ErrorAction SilentlyContinue | Select-Object -First 1

if ($SentinelCtl) {
    $SentinelPath = $SentinelCtl.FullName
    Write-Host "[+] Found SentinelCtl at: $SentinelPath" -ForegroundColor Green

    try {
        Write-Host "[*] Running SentinelCtl status..." -ForegroundColor Cyan
        & "$SentinelPath" status
    } catch {
        Write-Host "[!] Error executing SentinelCtl." -ForegroundColor Red
    }
} else {
    Write-Host "[!] SentinelCtl.exe not found." -ForegroundColor Red
}

# Check SentinelOne-related services
$services = Get-Service | Where-Object {
    $_.DisplayName -like "*sentinel*" -or $_.Name -like "*sentinel*"
}

if ($services) {
    Write-Host "`n[+] Found $($services.Count) SentinelOne service(s):" -ForegroundColor Green
    $services | Format-Table Name, DisplayName, Status -AutoSize
} else {
    Write-Host "[!] No SentinelOne-related services found." -ForegroundColor DarkYellow
}

# Check processes
$processes = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match "s1agent|sentinel"
}

# CPU usage
$cpuCounters = Get-Counter '\Process(*)\% Processor Time'
$cpuUsage = @{}
foreach ($c in $cpuCounters.CounterSamples) {
    $pname = $c.InstanceName
    if ($cpuUsage.ContainsKey($pname)) {
        $cpuUsage[$pname] += $c.CookedValue
    } else {
        $cpuUsage[$pname] = $c.CookedValue
    }
}

# Build process summary
if ($processes) {
    $summary = $processes | Group-Object Name | ForEach-Object {
        $name = $_.Name
        $instances = $_.Count
        $avgMemMB = [math]::Round(($_.Group | Measure-Object WorkingSetSize -Average).Average / 1MB, 2)
        $cpu = 0

        $normName = $name -replace '.exe$', ''
        if ($cpuUsage.ContainsKey($normName)) {
            $cpu = [math]::Round($cpuUsage[$normName], 2)
        }

        [PSCustomObject]@{
            ProcessName   = $name
            Instances     = $instances
            AvgMemMB      = $avgMemMB
            AvgCPUPercent = $cpu
        }
    }

    Write-Host "`n[+] Process Resource Usage Summary:`n" -ForegroundColor Yellow
    $summary |
        Sort-Object -Property AvgMemMB -Descending |
        Format-Table ProcessName, Instances, AvgMemMB, AvgCPUPercent -AutoSize
} else {
    Write-Host "[!] No SentinelOne-related processes found." -ForegroundColor DarkYellow
    $summary = @()
}

# === Detect Console URL from Logs ===
$logPath = "C:\ProgramData\Sentinel\Logs\sentinel-agent.log"
$consoleUrl = "https://console.sentinelone.net"  # fallback

if (Test-Path $logPath) {
    $match = Select-String -Path $logPath -Pattern "Update console URL to new value" | Select-Object -Last 1
    if ($match -and $match.Line -match "https://[a-zA-Z0-9\.\-]+\.sentinelone\.net") {
        $consoleUrl = $matches[0]
    }
}

Write-Host "`n[+] Detected SentinelOne Console URL: $consoleUrl" -ForegroundColor Cyan

# === Check Connectivity ===
$reachable = $false
try {
    $response = Invoke-WebRequest -Uri $consoleUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $reachable = $response.StatusCode -eq 200
    Write-Host "  - Connectivity Test: [OK]" -ForegroundColor Green
} catch {
    Write-Host "  - Connectivity Test: [FAIL]" -ForegroundColor Red
}

# Save results to JSON
$output = [PSCustomObject]@{
    Timestamp           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SentinelCtl         = $SentinelPath
    Services            = $services
    ProcessSummary      = $summary
    ConsoleConnectivity = @{
        Portal = $consoleUrl
        Status = if ($reachable) { "reachable" } else { "unreachable" }
    }
}

$jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "sentinelone_summary_$timestamp.json"
$output | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host "`n[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] [INFO] JSON saved to: $jsonPath" -ForegroundColor Cyan