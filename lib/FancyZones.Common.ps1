# FancyZonesLock common library. Target: Windows PowerShell 5.1.
# Keeps FancyZones layout-to-monitor bindings stable across display reconnects.

$script:FZDir       = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones'
# Program and data live together in one fixed directory. No scheduled task.
$script:LockDir     = 'C:\Programs\System\FancyZoneFix'
$script:Applied     = Join-Path $script:FZDir  'applied-layouts.json'
$script:Settings    = Join-Path $script:FZDir  'settings.json'
$script:BaselinePath    = Join-Path $script:LockDir 'baseline.json'
$script:LogDir      = Join-Path $script:LockDir 'logs'
$script:LogFile     = Join-Path $script:LogDir 'guard.log'
$script:NumberRange = @(1,2,3,4,5,6,7,8)
$script:TaskName    = 'FancyZonesLock-Guard'   # legacy name, removed at install
$script:StopFlag    = Join-Path $script:LockDir 'STOP-WATCHER'
$script:WatcherPid  = Join-Path $script:LockDir 'watcher.pid'

function Get-TopologyFingerprint {
    # A stable string describing the current display topology. Any change here
    # means Windows re-enumerated monitors (DISPLAY number, PnP UID, resolution).
    $screens = @()
    try {
        if (-not ('System.Windows.Forms.Screen' -as [type])) {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        }
        $screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            '{0}/{1}/{2}' -f $_.DeviceName, $_.Bounds.ToString(), $_.Primary
        } | Sort-Object)
    } catch {
        $screens = @('screen-enum-failed')
    }

    $pnp = @()
    try {
        $pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass = 'Monitor'" -ErrorAction Stop |
                 ForEach-Object { [string]$_.DeviceID } | Sort-Object)
    } catch { }

    $video = ''
    try {
        $video = (@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                  ForEach-Object { '{0}x{1}@{2}' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution, $_.CurrentRefreshRate }) -join ';')
    } catch { }

    return (($screens -join ';') + '|' + ($pnp -join ';') + '|' + $video)
}

function Write-GuardLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        $f = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($null -ne $f -and $f.Length -gt 1048576) {
            $keep = Get-Content -LiteralPath $script:LogFile -Tail 500
            Set-Content -LiteralPath $script:LogFile -Value $keep -Encoding UTF8
        }
    } catch { }
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function ConvertTo-JsonText {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 12)
}

function Set-JsonFileAtomic {
    param([string]$Path, [string]$Content)
    $dir  = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $enc  = New-Object System.Text.UTF8Encoding($false)
    for ($i = 1; $i -le 3; $i++) {
        $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f $leaf, ([guid]::NewGuid().ToString('N')))
        try {
            [System.IO.File]::WriteAllText($tmp, $Content, $enc)
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds 250
        } finally {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $false
}

function New-Entry {
    param([string]$Monitor, [string]$Instance, [int]$Number, [string]$Serial, [string]$VD, $Layout)
    $d = [ordered]@{
        'monitor'          = $Monitor
        'monitor-instance' = $Instance
        'monitor-number'   = $Number
        'serial-number'    = $Serial
        'virtual-desktop'  = $VD
    }
    $l = [ordered]@{
        'uuid'               = [string]$Layout.uuid
        'type'               = [string]$Layout.type
        'show-spacing'       = [bool]$Layout.'show-spacing'
        'spacing'            = [int]$Layout.spacing
        'zone-count'         = [int]$Layout.'zone-count'
        'sensitivity-radius' = [int]$Layout.'sensitivity-radius'
    }
    $e = [ordered]@{
        'device'         = [pscustomobject]$d
        'applied-layout' = [pscustomobject]$l
    }
    return ([pscustomobject]$e)
}

function Copy-Entry {
    param($Entry)
    $d = $Entry.device
    return (New-Entry -Monitor ([string]$d.monitor) -Instance ([string]$d.'monitor-instance') -Number ([int]$d.'monitor-number') -Serial ([string]$d.'serial-number') -VD ([string]$d.'virtual-desktop') -Layout $Entry.'applied-layout')
}

function Get-DeviceKey {
    param($Device)
    return ('{0}|{1}|{2}|{3}|{4}' -f $Device.monitor, $Device.'monitor-instance', $Device.'monitor-number', $Device.'serial-number', $Device.'virtual-desktop')
}

function Get-LayoutValue {
    param($Entry)
    $l = $Entry.'applied-layout'
    return ('{0}|{1}|{2}|{3}|{4}|{5}' -f $l.uuid, $l.type, $l.'show-spacing', $l.spacing, $l.'zone-count', $l.'sensitivity-radius')
}

function Test-GarbageEntry {
    param($Entry)
    if ($null -eq $Entry -or $null -eq $Entry.device -or $null -eq $Entry.'applied-layout') { return $true }
    $m = [string]$Entry.device.monitor
    $i = [string]$Entry.device.'monitor-instance'
    $u = [string]$Entry.'applied-layout'.uuid
    if ($m.StartsWith('\\')) { return $true }
    if ([string]::IsNullOrWhiteSpace($i)) { return $true }
    if ([string]::IsNullOrWhiteSpace($u) -or $u -eq '{00000000-0000-0000-0000-000000000000}') { return $true }
    return $false
}

function Get-RegistryMonitorInstances {
    $result = @{}
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    if (-not (Test-Path -LiteralPath $root)) { return $result }
    foreach ($vendorKey in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $list = New-Object System.Collections.ArrayList
        foreach ($instKey in Get-ChildItem -LiteralPath $vendorKey.PSPath -ErrorAction SilentlyContinue) {
            [void]$list.Add($instKey.PSChildName)
        }
        $result[$vendorKey.PSChildName] = @($list.ToArray())
    }
    return $result
}

function Get-LiveWorkAreas {
    $map = @{}
    $logRoot = Join-Path $script:FZDir 'Logs'
    if (-not (Test-Path -LiteralPath $logRoot)) { return @() }
    $rx = [regex]'Initialize layout on (\S+), work area rect = (\d+)x(\d+)'
    $files = @(Get-ChildItem -LiteralPath $logRoot -Recurse -File -Filter 'log_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | Sort-Object LastWriteTime)
    foreach ($f in $files) {
        $lines = Get-Content -LiteralPath $f.FullName -Tail 1200 -ErrorAction SilentlyContinue
        if ($null -eq $lines) { continue }
        foreach ($line in $lines) {
            $mm = $rx.Match($line)
            if (-not $mm.Success) { continue }
            $key   = $mm.Groups[1].Value
            $w     = [int]$mm.Groups[2].Value
            $h     = [int]$mm.Groups[3].Value
            $parts = $key -split '_'
            if ($parts.Count -lt 5) { continue }
            $mon    = $parts[0]
            $inst   = $parts[1]
            $num    = 0
            [void][int]::TryParse($parts[2], [ref]$num)
            $serial = $parts[3]
            $vd     = ($parts[4..($parts.Count - 1)] -join '_')
            if ($mon.StartsWith('\\') -or [string]::IsNullOrWhiteSpace($inst)) { continue }
            $map[($mon + '|' + $inst)] = [pscustomobject]@{
                monitor = $mon; instance = $inst; number = $num
                serial  = $serial; vd = $vd; width = $w; height = $h
            }
        }
    }
    return @($map.Values)
}

function Find-BaselineMonitor {
    param($Baseline, [int]$Width, [int]$Height, [string]$Monitor = '')
    $orient = 'landscape'
    if ($Height -gt $Width) { $orient = 'portrait' }
    $pool = @($Baseline.monitors)
    if (-not [string]::IsNullOrEmpty($Monitor)) {
        $filtered = @($pool | Where-Object { $_.monitor -eq $Monitor })
        if ($filtered.Count -gt 0) { $pool = $filtered }
    }
    $cands = @($pool | Where-Object { $_.orientation -eq $orient })
    if ($cands.Count -eq 0) { $cands = $pool }
    $best = $null
    $bestDelta = 1.0
    foreach ($c in $cands) {
        $cw = [int]$c.width
        if ($cw -le 0) { continue }
        $delta = [Math]::Abs($cw - $Width) / [double]$cw
        if ($delta -lt $bestDelta) { $bestDelta = $delta; $best = $c }
    }
    if ($null -ne $best -and $bestDelta -le 0.12) { return $best }
    return $null
}

function Expand-ExpectedEntries {
    param($Baseline)
    $list = New-Object System.Collections.ArrayList
    foreach ($m in $Baseline.monitors) {
        foreach ($inst in @($m.instances)) {
            if ([string]::IsNullOrWhiteSpace([string]$inst)) { continue }
            foreach ($n in @($Baseline.monitorNumbers)) {
                [void]$list.Add((New-Entry -Monitor ([string]$m.monitor) -Instance ([string]$inst) -Number ([int]$n) -Serial ([string]$m.serial) -VD ([string]$m.virtualDesktop) -Layout $m.layout))
            }
        }
    }
    return ,@($list.ToArray())
}

function Read-Baseline {
    return (Get-JsonFile $script:BaselinePath)
}

function Write-BaselineFile {
    param($Baseline)
    return (Set-JsonFileAtomic -Path $script:BaselinePath -Content (ConvertTo-JsonText $Baseline))
}

function Invoke-FZReload {
    # FancyZones watches applied-layouts.json for the active zone set, and
    # settings.json as a general "reload config" poke. Rewrite both with
    # identical content so the file watchers fire even when the lock already
    # matches on disk. Opening the FZ editor does the same read; this is the
    # headless equivalent.
    $ok = $false
    $enc = New-Object System.Text.UTF8Encoding($false)
    foreach ($pair in @(
        @{ Path = $script:Applied;  Tmp = '.applied.reload.tmp' },
        @{ Path = $script:Settings; Tmp = '.settings.reload.tmp' }
    )) {
        try {
            if (-not (Test-Path -LiteralPath $pair.Path)) { continue }
            $raw = [System.IO.File]::ReadAllText($pair.Path, [System.Text.Encoding]::UTF8)
            $tmp = Join-Path $script:FZDir $pair.Tmp
            [System.IO.File]::WriteAllText($tmp, $raw, $enc)
            Move-Item -LiteralPath $tmp -Destination $pair.Path -Force -ErrorAction Stop
            $ok = $true
        } catch { }
    }
    return $ok
}
