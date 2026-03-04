#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Diagnostic & Repair Tool
.DESCRIPTION
    A menu-driven PowerShell script that diagnoses and repairs common Windows
    computer issues including disk, network, system files, performance, and more.
.NOTES
    Must be run as Administrator for full functionality.
#>

# ── Globals ──────────────────────────────────────────────────────────────────
$ErrorActionPreference = "SilentlyContinue"
$Script:LogFile = Join-Path $env:TEMP "DiagRepairTool_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$stamp] [$Level] $Message"
    Add-Content -Path $Script:LogFile -Value $entry
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║        Windows Diagnostic & Repair Tool                 ║" -ForegroundColor Cyan
    Write-Host "  ║        ────────────────────────────────                 ║" -ForegroundColor Cyan
    Write-Host "  ║        Run as Administrator for full access             ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Pause-ForUser {
    Write-Host ""
    Write-Host "  Press any key to return to the menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Write-Status {
    param([string]$Text, [string]$Type = "info")
    switch ($Type) {
        "info"    { Write-Host "  [*] $Text" -ForegroundColor Cyan }
        "ok"      { Write-Host "  [+] $Text" -ForegroundColor Green }
        "warn"    { Write-Host "  [!] $Text" -ForegroundColor Yellow }
        "error"   { Write-Host "  [-] $Text" -ForegroundColor Red }
        "run"     { Write-Host "  [>] $Text" -ForegroundColor White }
    }
}

# ── 1. System File Checker & DISM ────────────────────────────────────────────

function Invoke-SystemFileRepair {
    Show-Banner
    Write-Host "  === System File Checker & DISM Repair ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Running DISM health check..." "run"
    Write-Log "Starting DISM CheckHealth"
    $dismCheck = & DISM /Online /Cleanup-Image /CheckHealth 2>&1
    $dismCheck | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
    Write-Log "DISM CheckHealth complete"

    Write-Host ""
    Write-Status "Running DISM RestoreHealth (this may take several minutes)..." "run"
    Write-Log "Starting DISM RestoreHealth"
    & DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | ForEach-Object {
        Write-Host "      $_" -ForegroundColor Gray
    }
    Write-Log "DISM RestoreHealth complete"

    Write-Host ""
    Write-Status "Running System File Checker (sfc /scannow)..." "run"
    Write-Log "Starting SFC"
    & sfc /scannow 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
    Write-Log "SFC complete"

    Write-Status "System file repair sequence finished." "ok"
    Pause-ForUser
}

# ── 2. Disk Health ───────────────────────────────────────────────────────────

function Invoke-DiskDiagnostic {
    Show-Banner
    Write-Host "  === Disk Health Diagnostic ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Checking disk space on all volumes..." "run"
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $free  = [math]::Round($_.FreeSpace / 1GB, 2)
        $total = [math]::Round($_.Size / 1GB, 2)
        $pct   = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        $color = if ($pct -lt 10) { "Red" } elseif ($pct -lt 25) { "Yellow" } else { "Green" }
        Write-Host "      Drive $($_.DeviceID)  Free: ${free} GB / ${total} GB  (${pct}% free)" -ForegroundColor $color
        Write-Log "Drive $($_.DeviceID): ${free}GB free of ${total}GB (${pct}%)"
    }

    Write-Host ""
    Write-Status "Checking SMART status via CIM..." "run"
    $disks = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus 2>$null
    if ($disks) {
        foreach ($d in $disks) {
            if ($d.PredictFailure) {
                Write-Status "Disk $($d.InstanceName) is predicting FAILURE!" "error"
                Write-Log "SMART failure predicted: $($d.InstanceName)" "WARN"
            } else {
                Write-Status "Disk $($d.InstanceName): Healthy" "ok"
            }
        }
    } else {
        Write-Status "SMART data not available via WMI on this system." "warn"
    }

    Write-Host ""
    Write-Status "Running chkdsk in read-only mode on C:..." "run"
    & chkdsk C: 2>&1 | Select-Object -Last 15 | ForEach-Object {
        Write-Host "      $_" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Status "Cleaning temp files..." "run"
    $tempPaths = @($env:TEMP, "$env:WINDIR\Temp")
    $cleaned = 0
    foreach ($tp in $tempPaths) {
        $files = Get-ChildItem -Path $tp -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
        foreach ($f in $files) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            if ($?) { $cleaned++ }
        }
    }
    Write-Status "Removed $cleaned old temp files." "ok"
    Write-Log "Cleaned $cleaned temp files"

    Pause-ForUser
}

# ── 3. Network Diagnostics & Repair ─────────────────────────────────────────

function Invoke-NetworkRepair {
    Show-Banner
    Write-Host "  === Network Diagnostics & Repair ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Current IP configuration:" "info"
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback" } |
        Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Status "Testing DNS resolution (google.com)..." "run"
    $dns = Resolve-DnsName -Name "google.com" -ErrorAction SilentlyContinue
    if ($dns) {
        Write-Status "DNS resolution OK: $($dns[0].IPAddress)" "ok"
    } else {
        Write-Status "DNS resolution FAILED" "error"
    }

    Write-Status "Testing internet connectivity..." "run"
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 3 -ErrorAction SilentlyContinue
    if ($ping) {
        $avg = [math]::Round(($ping | Measure-Object -Property Latency -Average).Average, 1)
        Write-Status "Internet reachable. Average latency: ${avg}ms" "ok"
    } else {
        Write-Status "Cannot reach 8.8.8.8 - internet may be down" "error"
    }

    Write-Host ""
    Write-Host "  Select a network repair action:" -ForegroundColor Yellow
    Write-Host "    1. Reset TCP/IP stack"
    Write-Host "    2. Flush DNS cache"
    Write-Host "    3. Release & renew DHCP lease"
    Write-Host "    4. Reset Winsock catalog"
    Write-Host "    5. All of the above"
    Write-Host "    6. Skip repairs"
    Write-Host ""
    $choice = Read-Host "  Enter choice (1-6)"

    $actions = @{
        "1" = { netsh int ip reset 2>&1 | Out-Null; Write-Status "TCP/IP stack reset." "ok" }
        "2" = { ipconfig /flushdns 2>&1 | Out-Null; Write-Status "DNS cache flushed." "ok" }
        "3" = { ipconfig /release 2>&1 | Out-Null; Start-Sleep 2; ipconfig /renew 2>&1 | Out-Null; Write-Status "DHCP lease renewed." "ok" }
        "4" = { netsh winsock reset 2>&1 | Out-Null; Write-Status "Winsock catalog reset." "ok" }
    }

    if ($choice -eq "5") {
        foreach ($a in $actions.Values) { & $a }
        Write-Status "All network repairs applied. A reboot is recommended." "warn"
        Write-Log "All network repairs applied"
    } elseif ($actions.ContainsKey($choice)) {
        & $actions[$choice]
        Write-Log "Network repair action $choice applied"
    } else {
        Write-Status "No repairs performed." "info"
    }

    Pause-ForUser
}

# ── 4. Windows Update Repair ────────────────────────────────────────────────

function Invoke-WindowsUpdateRepair {
    Show-Banner
    Write-Host "  === Windows Update Repair ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Stopping Windows Update services..." "run"
    $services = @("wuauserv", "cryptSvc", "bits", "msiserver")
    foreach ($svc in $services) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Write-Host "      Stopped $svc" -ForegroundColor Gray
    }

    Write-Status "Renaming SoftwareDistribution and catroot2 folders..." "run"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $sdPath = "$env:WINDIR\SoftwareDistribution"
    $crPath = "$env:WINDIR\System32\catroot2"
    if (Test-Path $sdPath) {
        Rename-Item $sdPath "${sdPath}.bak_$timestamp" -ErrorAction SilentlyContinue
    }
    if (Test-Path $crPath) {
        Rename-Item $crPath "${crPath}.bak_$timestamp" -ErrorAction SilentlyContinue
    }

    Write-Status "Re-registering Windows Update DLLs..." "run"
    $dlls = @(
        "atl.dll","urlmon.dll","mshtml.dll","shdocvw.dll","browseui.dll",
        "jscript.dll","vbscript.dll","scrrun.dll","msxml.dll","msxml3.dll",
        "msxml6.dll","actxprxy.dll","softpub.dll","wintrust.dll","dssenh.dll",
        "rsaenh.dll","gpkcsp.dll","sccbase.dll","slbcsp.dll","cryptdlg.dll",
        "oleaut32.dll","ole32.dll","shell32.dll","initpki.dll","wuapi.dll",
        "wuaueng.dll","wuaueng1.dll","wucltui.dll","wups.dll","wups2.dll",
        "wuweb.dll","qmgr.dll","qmgrprxy.dll","wucltux.dll","muweb.dll",
        "wuwebv.dll"
    )
    foreach ($dll in $dlls) {
        regsvr32.exe /s $dll 2>$null
    }

    Write-Status "Restarting Windows Update services..." "run"
    foreach ($svc in $services) {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Write-Host "      Started $svc" -ForegroundColor Gray
    }

    Write-Status "Windows Update components have been reset." "ok"
    Write-Log "Windows Update repair completed"
    Pause-ForUser
}

# ── 5. Performance Diagnostic ────────────────────────────────────────────────

function Invoke-PerformanceDiagnostic {
    Show-Banner
    Write-Host "  === Performance Diagnostic ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "System overview:" "info"
    $os   = Get-CimInstance Win32_OperatingSystem
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeRAM  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedPct  = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)

    Write-Host "      CPU : $($cpu.Name)" -ForegroundColor Gray
    Write-Host "      RAM : ${freeRAM} GB free / ${totalRAM} GB total  (${usedPct}% used)" -ForegroundColor Gray
    Write-Host "      OS  : $($os.Caption) Build $($os.BuildNumber)" -ForegroundColor Gray
    Write-Host "      Boot: $($os.LastBootUpTime)" -ForegroundColor Gray
    Write-Host ""

    Write-Status "Top 10 processes by CPU:" "info"
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 |
        Format-Table Name, Id,
            @{N="CPU(s)";E={[math]::Round($_.CPU,1)}},
            @{N="RAM(MB)";E={[math]::Round($_.WorkingSet64/1MB,1)}} -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Status "Top 10 processes by RAM:" "info"
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 |
        Format-Table Name, Id,
            @{N="CPU(s)";E={[math]::Round($_.CPU,1)}},
            @{N="RAM(MB)";E={[math]::Round($_.WorkingSet64/1MB,1)}} -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Status "Startup programs (via CIM):" "info"
    Get-CimInstance Win32_StartupCommand |
        Format-Table Name, Command, Location -AutoSize -Wrap |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Log "Performance diagnostic completed"
    Pause-ForUser
}

# ── 6. Service Health Check ──────────────────────────────────────────────────

function Invoke-ServiceHealthCheck {
    Show-Banner
    Write-Host "  === Critical Service Health Check ===" -ForegroundColor Yellow
    Write-Host ""

    $criticalServices = @(
        @{Name="wuauserv";    Desc="Windows Update"},
        @{Name="WinDefend";   Desc="Windows Defender"},
        @{Name="Spooler";     Desc="Print Spooler"},
        @{Name="Dhcp";        Desc="DHCP Client"},
        @{Name="Dnscache";    Desc="DNS Client"},
        @{Name="EventLog";    Desc="Windows Event Log"},
        @{Name="Schedule";    Desc="Task Scheduler"},
        @{Name="W32Time";     Desc="Windows Time"},
        @{Name="LanmanServer";Desc="File Sharing (Server)"},
        @{Name="AudioSrv";    Desc="Windows Audio"},
        @{Name="BITS";        Desc="Background Intelligent Transfer"},
        @{Name="CryptSvc";    Desc="Cryptographic Services"}
    )

    $stopped = @()
    foreach ($svc in $criticalServices) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $s) {
            Write-Status "$($svc.Desc) ($($svc.Name)): NOT FOUND" "warn"
        } elseif ($s.Status -eq "Running") {
            Write-Status "$($svc.Desc) ($($svc.Name)): Running" "ok"
        } else {
            Write-Status "$($svc.Desc) ($($svc.Name)): $($s.Status)" "error"
            $stopped += $svc
        }
    }

    if ($stopped.Count -gt 0) {
        Write-Host ""
        $fix = Read-Host "  Attempt to start $($stopped.Count) stopped service(s)? (Y/N)"
        if ($fix -eq "Y" -or $fix -eq "y") {
            foreach ($svc in $stopped) {
                Write-Status "Starting $($svc.Desc)..." "run"
                Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
                $s = Get-Service -Name $svc.Name
                if ($s.Status -eq "Running") {
                    Write-Status "$($svc.Desc) started successfully." "ok"
                } else {
                    Write-Status "Failed to start $($svc.Desc)." "error"
                }
            }
            Write-Log "Attempted to start $($stopped.Count) stopped services"
        }
    } else {
        Write-Host ""
        Write-Status "All critical services are running." "ok"
    }

    Pause-ForUser
}

# ── 7. Power & Battery Diagnostics ──────────────────────────────────────────

function Invoke-PowerDiagnostic {
    Show-Banner
    Write-Host "  === Power & Battery Diagnostics ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Current power plan:" "info"
    $plan = powercfg /getactivescheme 2>&1
    Write-Host "      $plan" -ForegroundColor Gray

    Write-Host ""
    Write-Status "Generating battery report (laptops only)..." "run"
    $battReport = Join-Path $env:TEMP "battery-report.html"
    $result = powercfg /batteryreport /output $battReport 2>&1
    if (Test-Path $battReport) {
        Write-Status "Battery report saved to: $battReport" "ok"
    } else {
        Write-Status "No battery detected or report generation failed." "warn"
    }

    Write-Host ""
    Write-Status "Generating energy report (60-second trace)..." "run"
    Write-Host "      This will monitor your system for 60 seconds..." -ForegroundColor Gray
    $energyReport = Join-Path $env:TEMP "energy-report.html"
    powercfg /energy /output $energyReport /duration 60 2>&1 | ForEach-Object {
        Write-Host "      $_" -ForegroundColor Gray
    }
    if (Test-Path $energyReport) {
        Write-Status "Energy report saved to: $energyReport" "ok"
    }

    Write-Host ""
    Write-Status "Power configuration:" "info"
    Write-Host "    1. Set High Performance plan"
    Write-Host "    2. Set Balanced plan"
    Write-Host "    3. Skip"
    $choice = Read-Host "  Enter choice (1-3)"
    switch ($choice) {
        "1" {
            powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
            Write-Status "Switched to High Performance." "ok"
        }
        "2" {
            powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>$null
            Write-Status "Switched to Balanced." "ok"
        }
        default { Write-Status "No changes made." "info" }
    }

    Write-Log "Power diagnostic completed"
    Pause-ForUser
}

# ── 8. Security Quick Scan ───────────────────────────────────────────────────

function Invoke-SecurityScan {
    Show-Banner
    Write-Host "  === Security Quick Scan ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Checking Windows Firewall status..." "run"
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($fw) {
        foreach ($profile in $fw) {
            $state = if ($profile.Enabled) { "Enabled" } else { "DISABLED" }
            $type  = if ($profile.Enabled) { "ok" } else { "error" }
            Write-Status "Firewall ($($profile.Name)): $state" $type
        }
    }

    Write-Host ""
    Write-Status "Checking Windows Defender status..." "run"
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($defender) {
        Write-Status "Real-time Protection: $($defender.RealTimeProtectionEnabled)" $(if($defender.RealTimeProtectionEnabled){"ok"}else{"error"})
        Write-Status "Antivirus Signatures: $($defender.AntivirusSignatureLastUpdated)" "info"
        Write-Status "Last Quick Scan: $($defender.QuickScanEndTime)" "info"
    } else {
        Write-Status "Windows Defender status unavailable." "warn"
    }

    Write-Host ""
    Write-Status "Checking for open listening ports..." "run"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort,
            @{N="Process";E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} |
        Sort-Object LocalPort |
        Format-Table -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Host ""
    Write-Host "    1. Run Windows Defender Quick Scan"
    Write-Host "    2. Update Defender Signatures"
    Write-Host "    3. Enable Real-time Protection"
    Write-Host "    4. Skip"
    $choice = Read-Host "  Enter choice (1-4)"
    switch ($choice) {
        "1" {
            Write-Status "Starting quick scan (runs in background)..." "run"
            Start-MpScan -ScanType QuickScan -AsJob
            Write-Status "Quick scan initiated." "ok"
        }
        "2" {
            Write-Status "Updating signatures..." "run"
            Update-MpSignature
            Write-Status "Signatures updated." "ok"
        }
        "3" {
            Set-MpPreference -DisableRealtimeMonitoring $false
            Write-Status "Real-time protection enabled." "ok"
        }
    }

    Write-Log "Security scan completed"
    Pause-ForUser
}

# ── 9. Driver Verification ──────────────────────────────────────────────────

function Invoke-DriverCheck {
    Show-Banner
    Write-Host "  === Driver Verification ===" -ForegroundColor Yellow
    Write-Host ""

    Write-Status "Checking for problem devices..." "run"
    $problemDevices = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
    if ($problemDevices) {
        Write-Status "Found $($problemDevices.Count) device(s) with issues:" "warn"
        foreach ($dev in $problemDevices) {
            Write-Host "      [$($dev.ConfigManagerErrorCode)] $($dev.Name)" -ForegroundColor Yellow
            Write-Log "Problem device: $($dev.Name) - Error $($dev.ConfigManagerErrorCode)"
        }
    } else {
        Write-Status "All devices report healthy status." "ok"
    }

    Write-Host ""
    Write-Status "Recently installed/updated drivers (last 30 days):" "info"
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DriverDate -gt (Get-Date).AddDays(-30) } |
        Sort-Object DriverDate -Descending |
        Select-Object DeviceName, DriverVersion, DriverDate -First 15 |
        Format-Table -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Log "Driver check completed"
    Pause-ForUser
}

# ── 10. Event Log Analysis ───────────────────────────────────────────────────

function Invoke-EventLogAnalysis {
    Show-Banner
    Write-Host "  === Event Log Analysis (Last 24 Hours) ===" -ForegroundColor Yellow
    Write-Host ""

    $since = (Get-Date).AddHours(-24)

    Write-Status "Critical & Error events from System log:" "info"
    $sysErrors = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        Level     = 1,2
        StartTime = $since
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($sysErrors) {
        foreach ($e in $sysErrors) {
            $lvl = if ($e.Level -eq 1) { "CRIT" } else { "ERR " }
            Write-Host "      [$lvl] $($e.TimeCreated.ToString('HH:mm:ss')) - $($e.ProviderName): $($e.Message.Substring(0, [Math]::Min(100, $e.Message.Length)))..." -ForegroundColor $(if($e.Level -eq 1){"Red"}else{"Yellow"})
        }
    } else {
        Write-Status "No critical/error events in the System log." "ok"
    }

    Write-Host ""
    Write-Status "Critical & Error events from Application log:" "info"
    $appErrors = Get-WinEvent -FilterHashtable @{
        LogName   = "Application"
        Level     = 1,2
        StartTime = $since
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($appErrors) {
        foreach ($e in $appErrors) {
            $lvl = if ($e.Level -eq 1) { "CRIT" } else { "ERR " }
            Write-Host "      [$lvl] $($e.TimeCreated.ToString('HH:mm:ss')) - $($e.ProviderName): $($e.Message.Substring(0, [Math]::Min(100, $e.Message.Length)))..." -ForegroundColor $(if($e.Level -eq 1){"Red"}else{"Yellow"})
        }
    } else {
        Write-Status "No critical/error events in the Application log." "ok"
    }

    Write-Host ""
    $totalSys = ($sysErrors | Measure-Object).Count
    $totalApp = ($appErrors | Measure-Object).Count
    Write-Status "Summary: $totalSys system errors, $totalApp application errors in last 24h." "info"

    Write-Log "Event log analysis: $totalSys sys errors, $totalApp app errors"
    Pause-ForUser
}

# ── 11. Memory Diagnostic ───────────────────────────────────────────────────

function Invoke-MemoryDiagnostic {
    Show-Banner
    Write-Host "  === Memory Diagnostic ===" -ForegroundColor Yellow
    Write-Host ""

    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1KB)
    $usedMB  = $totalMB - $freeMB
    $pct     = [math]::Round($usedMB / $totalMB * 100, 1)

    Write-Status "Physical Memory: ${usedMB} MB used / ${totalMB} MB total (${pct}%)" $(if($pct -gt 90){"error"}elseif($pct -gt 75){"warn"}else{"ok"})

    Write-Host ""
    Write-Status "Memory modules installed:" "info"
    Get-CimInstance Win32_PhysicalMemory |
        Format-Table BankLabel, Capacity,
            @{N="Size(GB)";E={[math]::Round($_.Capacity/1GB,1)}},
            Speed, Manufacturer -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Host ""
    Write-Status "Page file usage:" "info"
    Get-CimInstance Win32_PageFileUsage |
        Format-Table Name,
            @{N="Allocated(MB)";E={$_.AllocatedBaseSize}},
            @{N="Current(MB)";E={$_.CurrentUsage}},
            @{N="Peak(MB)";E={$_.PeakUsage}} -AutoSize |
        Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Write-Host ""
    $run = Read-Host "  Schedule Windows Memory Diagnostic on next reboot? (Y/N)"
    if ($run -eq "Y" -or $run -eq "y") {
        & mdsched.exe
        Write-Status "Memory diagnostic scheduled." "ok"
        Write-Log "Memory diagnostic scheduled for next reboot"
    }

    Pause-ForUser
}

# ── 12. Full System Report ──────────────────────────────────────────────────

function Invoke-FullReport {
    Show-Banner
    Write-Host "  === Generating Full System Report ===" -ForegroundColor Yellow
    Write-Host ""

    $report = Join-Path $env:TEMP "SystemReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $lines  = @()

    $lines += "=== SYSTEM REPORT ==="
    $lines += "Generated: $(Get-Date)"
    $lines += ""

    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem

    $lines += "--- OS ---"
    $lines += "  $($os.Caption) Build $($os.BuildNumber)"
    $lines += "  Computer: $($cs.Name)"
    $lines += "  Domain: $($cs.Domain)"
    $lines += "  Last Boot: $($os.LastBootUpTime)"
    $lines += ""

    $lines += "--- CPU ---"
    $lines += "  $($cpu.Name)"
    $lines += "  Cores: $($cpu.NumberOfCores) / Threads: $($cpu.NumberOfLogicalProcessors)"
    $lines += ""

    $lines += "--- RAM ---"
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $lines += "  Total: ${totalGB} GB / Free: ${freeGB} GB"
    $lines += ""

    $lines += "--- DISKS ---"
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $free  = [math]::Round($_.FreeSpace / 1GB, 2)
        $total = [math]::Round($_.Size / 1GB, 2)
        $lines += "  $($_.DeviceID) Free: ${free} GB / ${total} GB"
    }
    $lines += ""

    $lines += "--- NETWORK ---"
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback" } | ForEach-Object {
        $lines += "  $($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength)"
    }
    $lines += ""

    $lines += "--- PROBLEM DEVICES ---"
    $prob = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
    if ($prob) {
        foreach ($d in $prob) { $lines += "  [$($d.ConfigManagerErrorCode)] $($d.Name)" }
    } else {
        $lines += "  None"
    }

    $lines | Out-File -FilePath $report -Encoding utf8
    Write-Status "Report saved to: $report" "ok"
    Write-Log "Full system report saved to $report"

    $open = Read-Host "  Open report in Notepad? (Y/N)"
    if ($open -eq "Y" -or $open -eq "y") { notepad $report }

    Pause-ForUser
}

# ── Main Menu ────────────────────────────────────────────────────────────────

function Show-MainMenu {
    while ($true) {
        Show-Banner
        Write-Host "  Log file: $Script:LogFile" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor White
        Write-Host "  │  1.  System File Repair  (SFC + DISM)           │" -ForegroundColor White
        Write-Host "  │  2.  Disk Health & Cleanup                      │" -ForegroundColor White
        Write-Host "  │  3.  Network Diagnostics & Repair               │" -ForegroundColor White
        Write-Host "  │  4.  Windows Update Repair                      │" -ForegroundColor White
        Write-Host "  │  5.  Performance Diagnostic                     │" -ForegroundColor White
        Write-Host "  │  6.  Critical Service Health Check              │" -ForegroundColor White
        Write-Host "  │  7.  Power & Battery Diagnostics                │" -ForegroundColor White
        Write-Host "  │  8.  Security Quick Scan                        │" -ForegroundColor White
        Write-Host "  │  9.  Driver Verification                        │" -ForegroundColor White
        Write-Host "  │ 10.  Event Log Analysis                         │" -ForegroundColor White
        Write-Host "  │ 11.  Memory Diagnostic                          │" -ForegroundColor White
        Write-Host "  │ 12.  Generate Full System Report                │" -ForegroundColor White
        Write-Host "  │                                                  │" -ForegroundColor White
        Write-Host "  │  0.  Exit                                       │" -ForegroundColor White
        Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor White
        Write-Host ""
        $selection = Read-Host "  Select an option (0-12)"

        switch ($selection) {
            "1"  { Invoke-SystemFileRepair }
            "2"  { Invoke-DiskDiagnostic }
            "3"  { Invoke-NetworkRepair }
            "4"  { Invoke-WindowsUpdateRepair }
            "5"  { Invoke-PerformanceDiagnostic }
            "6"  { Invoke-ServiceHealthCheck }
            "7"  { Invoke-PowerDiagnostic }
            "8"  { Invoke-SecurityScan }
            "9"  { Invoke-DriverCheck }
            "10" { Invoke-EventLogAnalysis }
            "11" { Invoke-MemoryDiagnostic }
            "12" { Invoke-FullReport }
            "0"  {
                Write-Host ""
                Write-Host "  Log saved to: $Script:LogFile" -ForegroundColor Green
                Write-Host "  Goodbye!" -ForegroundColor Cyan
                Write-Host ""
                return
            }
            default {
                Write-Host "  Invalid selection." -ForegroundColor Red
                Start-Sleep 1
            }
        }
    }
}

# ── Entry Point ──────────────────────────────────────────────────────────────

Write-Log "=== Diagnostic & Repair Tool Started ==="
Show-MainMenu
Write-Log "=== Diagnostic & Repair Tool Exited ==="
