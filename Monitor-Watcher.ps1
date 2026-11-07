# FancyZoneFix resident monitor-topology watcher (no scheduled task).
# Runs Guard-FancyZones.ps1 as soon as a display is attached/removed or Windows
# re-enumerates DISPLAY numbers / PnP UIDs. Started by Start-Watcher.vbs from
# the per-user Startup folder; completely windowless.
param(
    [int]$PollSeconds = 2,
    [switch]$Once,            # print the current topology fingerprint and exit
    [switch]$SimulateChange   # self-test: run the guard once and exit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

$guard = Join-Path $PSScriptRoot 'Guard-FancyZones.ps1'

function Invoke-Guard {
    try {
        & $guard
    } catch {
        Write-GuardLog ("Watcher: guard failed: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

if ($Once) {
    "FINGERPRINT=" + (Get-TopologyFingerprint)
    return
}
if ($SimulateChange) {
    Write-GuardLog 'Watcher: simulated topology change (self-test)' 'INFO'
    Invoke-Guard
    return
}

# --- single instance -------------------------------------------------------
$created = $false
try {
    $script:WatcherMutex = [System.Threading.Mutex]::new($true, 'Local\FancyZoneFixWatcher', [ref]$created)
    if (-not $created) {
        Write-GuardLog 'Watcher: another instance is already running - exiting' 'WARN'
        return
    }
} catch {
    Write-GuardLog ("Watcher: mutex unavailable ({0}); continuing with PID guard" -f $_.Exception.Message) 'WARN'
}

try {
    [System.IO.File]::WriteAllText($script:WatcherPid, [string]$PID, (New-Object System.Text.ASCIIEncoding))
} catch { }

# A stale stop flag from a previous run must not kill this one immediately.
Remove-Item -LiteralPath $script:StopFlag -Force -ErrorAction SilentlyContinue

# --- instant WMI device-arrival trigger (best effort) ----------------------
# The 2s topology fingerprint poll below is the reliable path; this just makes
# hot-plug events land sooner. If CIM events are unavailable we degrade quietly.
$wmiOk = $false
try {
    Register-CimIndicationEvent -Query 'SELECT * FROM Win32_DeviceChangeEvent WHERE EventType = 2 OR EventType = 3' `
        -SourceIdentifier 'FZDeviceChange' `
        -Action { $global:FZDeviceChanged = $true } `
        -ErrorAction Stop | Out-Null
    $wmiOk = $true
} catch {
    Write-GuardLog ("Watcher: WMI event subscription unavailable ({0}); using poll only" -f $_.Exception.Message) 'WARN'
}

$last = Get-TopologyFingerprint
Write-GuardLog ("Watcher started (pid={0}, poll={1}s, wmiEvents={2})" -f $PID, $PollSeconds, $wmiOk) 'INFO'

try {
    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        if (Test-Path -LiteralPath $script:StopFlag) {
            Remove-Item -LiteralPath $script:StopFlag -Force -ErrorAction SilentlyContinue
            break
        }

        $eventHit = $false
        if ($global:FZDeviceChanged) { $global:FZDeviceChanged = $false; $eventHit = $true }

        $now = Get-TopologyFingerprint
        if (-not $eventHit -and $now -eq $last) { continue }

        # Let Windows finish re-enumerating monitors before repairing anything.
        Start-Sleep -Milliseconds 1500
        $last = Get-TopologyFingerprint
        Write-GuardLog ("Watcher: display change detected (event={0}) - running guard" -f $eventHit) 'INFO'
        Invoke-Guard
    }
} finally {
    try {
        Get-EventSubscriber -SourceIdentifier 'FZDeviceChange' -ErrorAction SilentlyContinue |
            Unregister-Event -ErrorAction SilentlyContinue
    } catch { }
    try { Remove-Item -LiteralPath $script:WatcherPid -Force -ErrorAction SilentlyContinue } catch { }
    Write-GuardLog 'Watcher stopped' 'INFO'
}
