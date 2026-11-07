# Stop the watcher, remove the Startup shortcut, clean up any legacy scheduled
# task. -RestoreOriginal additionally restores the raw pre-change JSON files.
param([switch]$RestoreOriginal)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

# 1. Ask the resident tray app (and any legacy watcher) to exit.
try {
    [System.IO.File]::WriteAllText($script:StopFlag, (Get-Date -Format 'o'), (New-Object System.Text.ASCIIEncoding))
    [System.IO.File]::WriteAllText((Join-Path $script:LockDir 'quit.flag'), (Get-Date -Format 'o'), (New-Object System.Text.ASCIIEncoding))
    "Tray / watcher stop signals written."
} catch {
    "Could not signal the tray app: $($_.Exception.Message)"
}

# 2. Remove the per-user Startup shortcut (NOT a scheduled task).
$startup = [Environment]::GetFolderPath('Startup')
$auto = Join-Path $startup 'FancyZoneFix-AutoWatch.vbs'
if (Test-Path -LiteralPath $auto) {
    Remove-Item -LiteralPath $auto -Force
    "Startup shortcut removed: $auto"
} else {
    "Startup shortcut not found (already removed)."
}

# 3. Remove the legacy scheduled task if it somehow still exists.
try {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -ne $t) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        "Legacy scheduled task removed: $($script:TaskName)"
    } else {
        "Legacy scheduled task not present."
    }
} catch {
    "Could not check the legacy scheduled task: $($_.Exception.Message)"
}

if ($RestoreOriginal) {
    $snapRoot = Join-Path $script:LockDir 'baseline'
    $snap = Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($null -ne $snap) {
        Get-ChildItem -LiteralPath $snap.FullName -File -Filter '*.json' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:FZDir $_.Name) -Force
        }
        "Original configuration restored from $($snap.Name)"
    } else {
        "No snapshot to restore."
    }
}

"Program files kept at $($script:LockDir) (baseline, snapshots and scripts are preserved)."
