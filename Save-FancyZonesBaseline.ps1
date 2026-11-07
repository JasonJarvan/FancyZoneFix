# Capture the CURRENT (correct) FancyZones layout assignments as the locked
# baseline, then expand them into a reconnection-proof applied-layouts.json.
# Run this again after you intentionally change a layout in the FancyZones editor.

param([switch]$NoSnapshot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

$current = Get-JsonFile $script:Applied
if ($null -eq $current -or $null -eq $current.'applied-layouts') {
    throw 'applied-layouts.json is unreadable. Aborting.'
}

# De-duplicate by (monitor, instance). A hardened file contains many rows per
# physical monitor; they must collapse back into one baseline monitor.
$valid = @()
$seen = @{}
foreach ($e in @($current.'applied-layouts')) {
    if (Test-GarbageEntry $e) { continue }
    $k = ('{0}|{1}' -f $e.device.monitor, $e.device.'monitor-instance')
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    $valid += $e
}
if ($valid.Count -eq 0) { throw 'No valid layout bindings found. Aborting.' }

$live = Get-LiveWorkAreas
$reg  = Get-RegistryMonitorInstances

$baseline = Read-Baseline
if ($null -eq $baseline -or $null -eq $baseline.monitors -or @($baseline.monitors).Count -eq 0) {
    # ---- First run: build baseline from scratch ----
    $modelCounts = @{}
    foreach ($v in $valid) {
        $mn = [string]$v.device.monitor
        if (-not $modelCounts.ContainsKey($mn)) { $modelCounts[$mn] = 0 }
        $modelCounts[$mn]++
    }
    $mons = New-Object System.Collections.ArrayList
    foreach ($v in $valid) {
        $mon  = [string]$v.device.monitor
        $inst = [string]$v.device.'monitor-instance'
        $wa = $live | Where-Object { $_.monitor -eq $mon -and $_.instance -eq $inst } | Select-Object -First 1
        if ($null -eq $wa) { $wa = $live | Where-Object { $_.monitor -eq $mon } | Select-Object -First 1 }
        $w = 0
        $h = 0
        if ($null -ne $wa) { $w = [int]$wa.width; $h = [int]$wa.height }
        $orient = 'landscape'
        if ($h -gt $w -and $w -gt 0) { $orient = 'portrait' }

        $instances = New-Object System.Collections.ArrayList
        [void]$instances.Add($inst)
        # Only a single physical screen of this model: safe to register every
        # historical PnP instance as an alias (protects against UID changes).
        if ($modelCounts[$mon] -eq 1 -and $reg.ContainsKey($mon)) {
            foreach ($ri in @($reg[$mon])) {
                if ($instances -notcontains $ri) { [void]$instances.Add($ri) }
            }
        }
        $m = [ordered]@{
            'id'             = ('{0}-{1}-{2}' -f $mon, $w, $orient)
            'monitor'        = $mon
            'instances'      = @($instances.ToArray())
            'width'          = $w
            'orientation'    = $orient
            'serial'         = [string]$v.device.'serial-number'
            'virtualDesktop' = [string]$v.device.'virtual-desktop'
            'layout'         = [ordered]@{
                'uuid'               = [string]$v.'applied-layout'.uuid
                'type'               = [string]$v.'applied-layout'.type
                'show-spacing'       = [bool]$v.'applied-layout'.'show-spacing'
                'spacing'            = [int]$v.'applied-layout'.spacing
                'zone-count'         = [int]$v.'applied-layout'.'zone-count'
                'sensitivity-radius' = [int]$v.'applied-layout'.'sensitivity-radius'
            }
        }
        [void]$mons.Add([pscustomobject]$m)
    }
    $ptVer = ''
    try {
        $pt = Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'
        if (Test-Path -LiteralPath $pt) { $ptVer = (Get-Item -LiteralPath $pt).VersionInfo.ProductVersion }
    } catch { }
    $baseline = [pscustomobject]([ordered]@{
        'capturedAt'       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        'powerToysVersion' = $ptVer
        'monitorNumbers'   = @($script:NumberRange)
        'monitors'         = @($mons.ToArray())
    })
} else {
    # ---- Subsequent run: keep the structure, refresh layouts + learn UIDs ----
    foreach ($m in $baseline.monitors) {
        $hit = $valid | Where-Object {
            ([string]$_.device.monitor -eq [string]$m.monitor) -and
            (@($m.instances) -contains [string]$_.device.'monitor-instance')
        } | Select-Object -First 1
        if ($null -ne $hit) {
            $m.layout = [pscustomobject]([ordered]@{
                'uuid'               = [string]$hit.'applied-layout'.uuid
                'type'               = [string]$hit.'applied-layout'.type
                'show-spacing'       = [bool]$hit.'applied-layout'.'show-spacing'
                'spacing'            = [int]$hit.'applied-layout'.spacing
                'zone-count'         = [int]$hit.'applied-layout'.'zone-count'
                'sensitivity-radius' = [int]$hit.'applied-layout'.'sensitivity-radius'
            })
        }
    }
    foreach ($wa in $live) {
        $m = Find-BaselineMonitor $baseline $wa.width $wa.height -Monitor $wa.monitor
        if ($null -eq $m -or [string]$m.monitor -ne $wa.monitor) { continue }
        if (@($m.instances) -notcontains $wa.instance) {
            $m.instances = @(@($m.instances) + $wa.instance)
        }
    }
    $baseline.capturedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    if ($null -eq $baseline.monitorNumbers -or @($baseline.monitorNumbers).Count -eq 0) {
        $baseline.monitorNumbers = @($script:NumberRange)
    }
}

# Snapshot the pre-rewrite state.
if (-not $NoSnapshot) {
    $snapRoot = Join-Path $script:LockDir 'baseline'
    if (-not (Test-Path -LiteralPath $snapRoot)) {
        New-Item -ItemType Directory -Force -Path $snapRoot | Out-Null
    }
    $snap = Join-Path $snapRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Force -Path $snap | Out-Null
    Get-ChildItem -LiteralPath $script:FZDir -File -Filter '*.json' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $snap -Force
    }
    Write-GuardLog ("Snapshot saved: {0}" -f $snap)
}

if (-not (Write-BaselineFile $baseline)) { throw 'Failed to write baseline.json' }

$expected = Expand-ExpectedEntries $baseline
$obj = [pscustomobject]([ordered]@{ 'applied-layouts' = @($expected) })
if (-not (Set-JsonFileAtomic -Path $script:Applied -Content (ConvertTo-JsonText $obj))) {
    throw 'Failed to write applied-layouts.json'
}
$reload = Invoke-FZReload
Write-GuardLog ("Baseline captured: {0} monitor(s), {1} hardened bindings, reload={2}" -f @($baseline.monitors).Count, $expected.Count, $reload)

"Baseline : $($script:Baseline)"
"Monitors : $(@($baseline.monitors).Count)   Hardened bindings: $($expected.Count)"
foreach ($m in $baseline.monitors) {
    "  {0}  width={1} {2}  instances=[{3}]  layout={4} ({5})" -f $m.id, $m.width, $m.orientation, (@($m.instances) -join ', '), $m.layout.uuid, $m.layout.type
}
