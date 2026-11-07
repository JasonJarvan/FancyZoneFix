# Immediately re-apply the locked baseline to applied-layouts.json.
# -FromSnapshot also restores the raw pre-change JSON files from the newest snapshot.
param([switch]$FromSnapshot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

if ($FromSnapshot) {
    $snapRoot = Join-Path $script:LockDir 'baseline'
    $snap = Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $snap) { throw 'No snapshot found.' }
    Get-ChildItem -LiteralPath $snap.FullName -File -Filter '*.json' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:FZDir $_.Name) -Force
    }
    Write-GuardLog ("Restored raw snapshot {0}" -f $snap.Name)
    "Raw snapshot restored: $($snap.Name)"
}

& (Join-Path $PSScriptRoot 'Guard-FancyZones.ps1') -Force
"Baseline re-applied."
$ok = Invoke-FZReload
"Reload signal sent: $ok"
