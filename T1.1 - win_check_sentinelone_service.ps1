# T1.1 - Check SentinelOne services and summarize resource usage
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
Write-Host "[$timestamp] [*] Checking SentinelOne services..." -ForegroundColor Cyan

# Check services
$services = Get-Service | Where-Object {
    $_.DisplayName -like "*sentinel*" -or $_.Name -like "*sentinel*"
}

if ($services) {
    Write-Host "[+] Found $($services.Count) SentinelOne service(s)." -ForegroundColor Green
    $services | Format-Table Name, DisplayName, Status -AutoSize
} else {
    Write-Host "[X] No SentinelOne services found." -ForegroundColor Red
}

# Fetch processes related to SentinelOne
$processes = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match "s1agent|sentinel"
}

# Get real-time CPU usage
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

# Save JSON with timestamp in filename
$jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "sentinelone_summary_$timestamp.json"
$export = [PSCustomObject]@{
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Services  = $services
    ProcessSummary = $summary
}
$export | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host "`n[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] [INFO] JSON saved to: $jsonPath" -ForegroundColor Cyan