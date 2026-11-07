# FancyZonesLock guard.
# Compares applied-layouts.json against the locked baseline and repairs any
# drift caused by Windows re-enumerating monitors (DISPLAY number / PnP UID).
# Merge-style: never deletes user-added entries, never writes when unchanged.

param([switch]$Force)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

try {
    $baseline = Read-Baseline
    if ($null -eq $baseline -or $null -eq $baseline.monitors -or @($baseline.monitors).Count -eq 0) {
        Write-GuardLog 'baseline.json missing or empty - nothing to do' 'WARN'
        return
    }
    $current = Get-JsonFile $script:Applied
    if ($null -eq $current -or $null -eq $current.'applied-layouts') {
        Write-GuardLog 'applied-layouts.json unreadable - refusing to touch it' 'WARN'
        return
    }

    # Learn any new monitor-instance UID that FancyZones has actually seen.
    $learned = $false
    foreach ($wa in (Get-LiveWorkAreas)) {
        $m = Find-BaselineMonitor $baseline $wa.width $wa.height -Monitor $wa.monitor
        if ($null -eq $m) { continue }
        if ([string]$m.monitor -ne $wa.monitor) { continue }
        if (@($m.instances) -notcontains $wa.instance) {
            $m.instances = @(@($m.instances) + $wa.instance)
            $learned = $true
            Write-GuardLog ("Learned new instance {0}/{1} -> {2}" -f $wa.monitor, $wa.instance, $m.id) 'INFO'
        }
    }
    if ($learned) {
        $baseline.capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        if (-not (Write-BaselineFile $baseline)) {
            Write-GuardLog 'Failed to persist learned instances' 'WARN'
        }
    }

    $expected = Expand-ExpectedEntries $baseline

    # Keep existing entries, drop only known garbage fallback records.
    $clean = New-Object System.Collections.ArrayList
    $hadGarbage = $false
    foreach ($e in @($current.'applied-layouts')) {
        if (Test-GarbageEntry $e) { $hadGarbage = $true; continue }
        [void]$clean.Add((Copy-Entry $e))
    }

    $targetMap = @{}
    foreach ($e in $clean) { $targetMap[(Get-DeviceKey $e.device)] = $e }

    $changed = $hadGarbage
    foreach ($exp in $expected) {
        $k = Get-DeviceKey $exp.device
        if (-not $targetMap.ContainsKey($k)) {
            $targetMap[$k] = $exp
            $changed = $true
        } elseif ((Get-LayoutValue $targetMap[$k]) -ne (Get-LayoutValue $exp)) {
            $targetMap[$k] = $exp
            $changed = $true
        }
    }

    if (-not $changed -and -not $Force) {
        Write-GuardLog 'OK - all layout bindings match the locked baseline'
        return
    }

    # FancyZones keeps the active zone set in memory. If the JSON already
    # matches the baseline (common after a reconnect fallback), skipping the
    # write means FZ never re-reads and the overlay stays on the wrong layout
    # until the editor is opened. -Force always rewrites so the file watcher
    # fires. The GUI "立即修复" and the display-change watcher pass -Force.
    $entries = @($targetMap.Keys | Sort-Object | ForEach-Object { $targetMap[$_] })
    $obj = [pscustomobject]([ordered]@{ 'applied-layouts' = @($entries) })
    if (-not (Set-JsonFileAtomic -Path $script:Applied -Content (ConvertTo-JsonText $obj))) {
        Write-GuardLog 'Failed to write applied-layouts.json (file may be locked)' 'WARN'
        return
    }
    $reload = Invoke-FZReload
    if ($changed) {
        Write-GuardLog ("Repaired bindings, total={0}, garbageRemoved={1}, reload={2}" -f $entries.Count, $hadGarbage, $reload) 'INFO'
    } else {
        Write-GuardLog ("Forced FZ reload, total={0}, reload={1}" -f $entries.Count, $reload) 'INFO'
    }
} catch {
    Write-GuardLog ("ERROR: {0}" -f $_.Exception.Message) 'ERROR'
}
