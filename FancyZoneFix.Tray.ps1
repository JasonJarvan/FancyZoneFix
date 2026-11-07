# ==========================================================================
#  FancyZoneFix - tray application
#  One single PowerShell process holds everything:
#    * tray icon (colour = current automatic-watch state)
#    * on-demand GUI (double-click the tray icon)
#    * display-topology watch that runs the verified repair script
#  The repair / baseline / uninstall logic stays in the original scripts so
#  the behaviour that was already validated is not reimplemented here.
# ==========================================================================
param([switch]$ShowOnStart, [switch]$PreviewMap)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-CrashNote {
    param([string]$Text)
    try {
        $d = Join-Path $root 'logs'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $d 'tray-error.log'),
            ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text + "`r`n"),
            (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

trap {
    Write-CrashNote ("UNHANDLED: " + $_.Exception.ToString() + " @ " + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber)
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-CrashNote ('THREAD EXCEPTION: ' + $e.Exception.ToString())
})

. (Join-Path $root 'lib\FancyZones.Common.ps1')

# ---------------------------------------------------------------- single instance
$script:Mutex = $null
$createdNew = $false
if (-not $PreviewMap) {
try {
    $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\FancyZoneFixTray', [ref]$createdNew)
} catch { $createdNew = $true }

if (-not $createdNew) {
    # Another copy owns the tray. Ask it to surface its GUI, then leave.
    try { [System.IO.File]::WriteAllText((Join-Path $root 'show-gui.flag'), '1') } catch { }
    return
}
}

# ---------------------------------------------------------------- state
$script:StatePath   = Join-Path $root 'state.json'
$script:AutoOn      = $true
$script:Busy        = $false
$script:BusyLabel   = ''
$script:PendingProc = $null
$script:PendingAt   = $null
$script:LastFp      = ''
$script:StatusText  = '就绪'
$script:LightState  = 'on'
$script:Form        = $null
$script:Notify      = $null
$script:Ctx         = $null
$script:MenuAuto    = $null
$script:StatusLabel = $null
$script:AutoCheck   = $null
$script:LightPanel  = $null
$script:StateLabel  = $null
$script:Suppress    = $false
$script:LastTrim    = (Get-Date).AddMinutes(-29)   # first trim ~1 min after start
$script:MemApi      = $null
$script:DisplayApi  = $null
$script:MapHost     = $null
$script:MapTips     = $null
$script:MapFp       = ''
$script:AllowClose  = $false

# ---------------------------------------------------------------- working-set trimmer
# Optional: lets the tray drop its resident set after activity. Purely a
# convenience; everything still works if the compile is unavailable.
try {
    if (-not ('FzFix.MemApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FzFix {
    public static class MemApi {
        [DllImport("psapi.dll", SetLastError = true)]
        public static extern bool EmptyWorkingSet(IntPtr hProcess);
    }
}
'@
    }
    $script:MemApi = [FzFix.MemApi]
} catch { $script:MemApi = $null }

try {
    if (-not ('FzFix.DisplayEnum' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace FzFix {
    public static class DisplayEnum {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        public static string[] GetMonitorLinks() {
            var list = new List<string>();
            for (uint i = 0; i < 16; i++) {
                var ad = new DISPLAY_DEVICE();
                ad.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref ad, 0)) break;
                if ((ad.StateFlags & 0x1) == 0) continue;
                var mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(ad.DeviceName, 0, ref mon, 1)) {
                    mon = new DISPLAY_DEVICE();
                    mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                    if (!EnumDisplayDevices(ad.DeviceName, 0, ref mon, 0)) continue;
                }
                list.Add(ad.DeviceName + "\t" + mon.DeviceString + "\t" + mon.DeviceID);
            }
            return list.ToArray();
        }
    }
}
'@
    }
    $script:DisplayApi = [FzFix.DisplayEnum]
} catch { $script:DisplayApi = $null }

function Trim-Memory {
    if ($null -eq $script:MemApi) { return }
    try {
        [void]$script:MemApi::EmptyWorkingSet([System.Diagnostics.Process]::GetCurrentProcess().Handle)
    } catch { }
}

function Load-State {
    try {
        if (Test-Path -LiteralPath $script:StatePath) {
            $j = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if ($null -ne $j.auto) { $script:AutoOn = [bool]$j.auto }
        }
    } catch { }
}

function Save-State {
    try {
        $o = [pscustomobject]@{ auto = [bool]$script:AutoOn }
        [System.IO.File]::WriteAllText($script:StatePath, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------- tray icon art
function New-LightBitmap {
    param([string]$State, [int]$Size = 32)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $c = [System.Drawing.Color]::FromArgb(150, 150, 150)
    if ($State -eq 'on')   { $c = [System.Drawing.Color]::FromArgb(46, 204, 113) }
    if ($State -eq 'off')  { $c = [System.Drawing.Color]::FromArgb(231, 76, 60) }
    if ($State -eq 'busy') { $c = [System.Drawing.Color]::FromArgb(241, 196, 15) }

    $inset = [int]([Math]::Max(1, $Size / 16))
    $d = $Size - ($inset * 2)
    $brush = New-Object System.Drawing.SolidBrush($c)
    $g.FillEllipse($brush, $inset, $inset, $d, $d)
    $brush.Dispose()

    $rimW = [single]([Math]::Max(1.1, $Size / 20))
    $rim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(230, 255, 255, 255), $rimW)
    $g.DrawEllipse($rim, $inset + 1, $inset + 1, ($d - 2), ($d - 2))
    $rim.Dispose()

    $lineW = [single]([Math]::Max(1.6, $Size / 13))
    $lp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(240, 255, 255, 255), $lineW)
    $x1 = [single]($Size * 0.38); $x2 = [single]($Size * 0.62)
    $y1 = [single]($Size * 0.27); $y2 = [single]($Size * 0.73)
    $g.DrawLine($lp, $x1, $y1, $x1, $y2)
    $g.DrawLine($lp, $x2, $y1, $x2, $y2)
    $lp.Dispose()

    $g.Dispose()
    return $bmp
}

function ConvertTo-TrayIcon {
    param([System.Drawing.Bitmap]$Bitmap)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]1)
    $bw.Write([Byte]$Bitmap.Width)
    $bw.Write([Byte]$Bitmap.Height)
    $bw.Write([Byte]0)
    $bw.Write([Byte]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]32)
    $pngMs = New-Object System.IO.MemoryStream
    $Bitmap.Save($pngMs, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $pngMs.ToArray()
    $pngMs.Dispose()
    $bw.Write([UInt32]$png.Length)
    $bw.Write([UInt32]22)
    $bw.Write($png)
    $bw.Flush()
    $ms.Position = 0
    $icon = New-Object System.Drawing.Icon($ms)
    $bw.Dispose()
    $ms.Dispose()
    return $icon
}

function Get-LightState {
    if ($script:Busy) { return 'busy' }
    if ($script:AutoOn) { return 'on' }
    return 'off'
}

function Update-Visuals {
    $st = Get-LightState
    $script:LightState = $st

    if ($null -ne $script:Notify) {
        $bmp = New-LightBitmap -State $st -Size 32
        $icon = ConvertTo-TrayIcon -Bitmap $bmp
        $bmp.Dispose()
        $old = $script:Notify.Icon
        $script:Notify.Icon = $icon
        if ($null -ne $old) { try { $old.Dispose() } catch { } }
        if ($st -eq 'on')   { $script:Notify.Text = 'FancyZoneFix - 自动监听中' }
        elseif ($st -eq 'busy') { $script:Notify.Text = 'FancyZoneFix - 正在处理' }
        else { $script:Notify.Text = 'FancyZoneFix - 自动监听已关闭' }
    }

    if ($null -ne $script:MenuAuto) {
        if ($script:AutoOn) { $script:MenuAuto.Text = '关闭自动监听' } else { $script:MenuAuto.Text = '开启自动监听' }
    }

    if ($null -ne $script:LightPanel -and -not $script:LightPanel.IsDisposed) { $script:LightPanel.Invalidate() }
    if ($null -ne $script:StateLabel -and -not $script:StateLabel.IsDisposed) {
        if ($st -eq 'on') {
            $script:StateLabel.Text = '自动监听中'
            $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
        } elseif ($st -eq 'busy') {
            $script:StateLabel.Text = '正在处理…'
            $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 150, 0)
        } else {
            $script:StateLabel.Text = '自动监听已关闭'
            $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(192, 57, 43)
        }
    }
    if ($null -ne $script:AutoCheck -and -not $script:AutoCheck.IsDisposed) {
        $script:Suppress = $true
        $script:AutoCheck.Checked = [bool]$script:AutoOn
        $script:Suppress = $false
    }
}

function Set-Status {
    param([string]$Text)
    $script:StatusText = $Text
    if ($null -ne $script:StatusLabel -and -not $script:StatusLabel.IsDisposed) {
        $script:StatusLabel.Text = $Text
    }
}

function Get-LastLogLine {
    try {
        if (Test-Path -LiteralPath $script:LogFile) {
            $l = Get-Content -LiteralPath $script:LogFile -Tail 1 -ErrorAction SilentlyContinue
            return [string]$l
        }
    } catch { }
    return ''
}

# ---------------------------------------------------------------- background jobs
function Start-BackgroundScript {
    param([string]$FileName, [string[]]$ArgList, [string]$Label)

    if ($script:Busy) {
        Set-Status '上一步还没结束，请稍候…'
        return $null
    }
    $path = Join-Path $root $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        Set-Status ("找不到脚本：{0}" -f $FileName)
        return $null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $argStr = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $path + '"'
    if ($null -ne $ArgList -and $ArgList.Count -gt 0) { $argStr += ' ' + ($ArgList -join ' ') }
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $root

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $script:Busy = $true
        $script:BusyLabel = $Label
        $script:PendingProc = $p
        Set-Status ("{0}…" -f $Label)
        Update-Visuals
        return $p
    } catch {
        Set-Status ("启动失败：{0}" -f $_.Exception.Message)
        return $null
    }
}

# ---------------------------------------------------------------- topology watch
function Get-WatchFingerprint {
    $parts = New-Object System.Collections.ArrayList
    try {
        foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
            [void]$parts.Add(('{0}/{1}/{2}' -f $s.DeviceName, $s.Bounds.ToString(), $s.Primary))
        }
    } catch { [void]$parts.Add('enum-failed') }
    $screen = (@($parts | Sort-Object) -join ';')

    $stamp = ''
    try {
        $fi = Get-Item -LiteralPath $script:Applied -ErrorAction SilentlyContinue
        if ($null -ne $fi) { $stamp = ('{0}/{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length) }
    } catch { }
    return ($screen + '|' + $stamp)
}

# ---------------------------------------------------------------- actions
function Invoke-Repair {
    [void](Start-BackgroundScript -FileName 'Guard-FancyZones.ps1' -ArgList @('-Force') -Label '正在修复布局')
}

function Invoke-SaveBaseline {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "将把「当前」的布局绑定保存为新的锁定基线。`n`n请先在 FancyZones 编辑器里调好布局、并让窗口落到正确位置后再继续。",
        '更新基线', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }
    [void](Start-BackgroundScript -FileName 'Save-FancyZonesBaseline.ps1' -Label '正在更新基线')
}

function Invoke-Uninstall {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "这会停止并移除自动监听与开机自启，程序文件保留。`n`n是否同时把 FancyZones 配置还原为最初的原始快照？`n`n是 = 移除并还原原始配置`n否 = 只移除自动监听`n取消 = 什么都不做",
        '卸载与还原', 'YesNoCancel', 'Warning')
    if ($r -eq 'Cancel') { return }
    $args = @()
    if ($r -eq 'Yes') { $args = @('-RestoreOriginal') }
    [void](Start-BackgroundScript -FileName 'Uninstall-FancyZonesLock.ps1' -ArgList $args -Label '正在卸载')
}

function Open-Log {
    try {
        if (Test-Path -LiteralPath $script:LogFile) {
            [void][System.Diagnostics.Process]::Start('notepad.exe', ('"' + $script:LogFile + '"'))
        } else {
            [void][System.Diagnostics.Process]::Start('explorer.exe', ('"' + $root + '"\logs'))
        }
    } catch { Set-Status ("打开日志失败：{0}" -f $_.Exception.Message) }
}

function Toggle-Auto {
    $script:AutoOn = -not $script:AutoOn
    Save-State
    if ($script:AutoOn) {
        $script:LastFp = Get-WatchFingerprint
        Set-Status '自动监听已开启：显示器接入或编号变化时自动修复。'
        Write-GuardLog 'Tray: automatic watch enabled' 'INFO'
    } else {
        Set-Status '自动监听已关闭。可随时用「立即修复布局」手动修复。'
        Write-GuardLog 'Tray: automatic watch disabled' 'INFO'
    }
    Update-Visuals
}

function Exit-App {
    try { if ($null -ne $script:Ctx) { $script:Ctx.ExitThread() } } catch { }
    [System.Windows.Forms.Application]::Exit()
}

# ---------------------------------------------------------------- light drawing
function New-RoundedPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-TrafficLight {
    param($Graphics, [int]$W, [int]$H, [string]$State)

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $body = New-RoundedPath -X 0 -Y 0 -W ($W - 1) -H ($H - 1) -R 12
    $bodyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(52, 54, 58))
    $Graphics.FillPath($bodyBrush, $body)
    $bodyBrush.Dispose()
    $edge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 31, 34), 1)
    $Graphics.DrawPath($edge, $body)
    $edge.Dispose()
    $body.Dispose()

    $on  = @{
        red  = [System.Drawing.Color]::FromArgb(231, 76, 60)
        amber = [System.Drawing.Color]::FromArgb(241, 196, 15)
        green = [System.Drawing.Color]::FromArgb(46, 204, 113)
    }
    $off = @{
        red  = [System.Drawing.Color]::FromArgb(74, 36, 34)
        amber = [System.Drawing.Color]::FromArgb(74, 64, 30)
        green = [System.Drawing.Color]::FromArgb(32, 62, 44)
    }

    $lit = @{ red = $false; amber = $false; green = $false }
    if ($State -eq 'on')   { $lit.green = $true }
    if ($State -eq 'off')  { $lit.red = $true }
    if ($State -eq 'busy') { $lit.amber = $true }

    $r = [int]([Math]::Min(14, ($W - 20) / 2))
    $cx = [int]($W / 2)
    $names = @('red', 'amber', 'green')
    $ys = @([int]($H * 0.19), [int]($H * 0.5), [int]($H * 0.81))

    for ($i = 0; $i -lt 3; $i++) {
        $name = $names[$i]
        $col = $off[$name]
        if ($lit[$name]) { $col = $on[$name] }
        $b = New-Object System.Drawing.SolidBrush($col)
        $Graphics.FillEllipse($b, ($cx - $r), ($ys[$i] - $r), ($r * 2), ($r * 2))
        $b.Dispose()

        if ($lit[$name]) {
            $hl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 255, 255, 255))
            $Graphics.FillEllipse($hl, ($cx - $r + 3), ($ys[$i] - $r + 3), [int]($r * 0.75), [int]($r * 0.75))
            $hl.Dispose()
        }
    }
}

# ---------------------------------------------------------------- monitor / layout map
function New-ZonePiece {
    param([int]$Zone, [int]$X, [int]$Y, [int]$W, [int]$H)
    return [pscustomobject]@{ Zone = $Zone; X = $X; Y = $Y; W = $W; H = $H }
}

function ConvertTo-CellRows {
    param($CellMap, [int]$ExpectedRows)
    $raw = @($CellMap)
    $rows = New-Object System.Collections.ArrayList
    if ($raw.Count -eq 0) { return ,@() }
    $nested = $false
    foreach ($v in $raw) {
        if ($null -eq $v) { continue }
        if ($v -is [System.Array]) { $nested = $true; break }
        if (($v -is [System.Collections.IEnumerable]) -and -not ($v -is [string]) -and -not ($v -is [ValueType])) { $nested = $true; break }
    }
    if (-not $nested) {
        [void]$rows.Add(@($raw))
    } else {
        foreach ($row in $raw) { [void]$rows.Add(@($row)) }
    }
    return ,$rows.ToArray()
}

function Get-GridPieces {
    param($RowPerc, $ColPerc, $CellMap)
    $rows = @($RowPerc | ForEach-Object { [int]$_ })
    $cols = @($ColPerc | ForEach-Object { [int]$_ })
    $mapRows = ConvertTo-CellRows -CellMap $CellMap -ExpectedRows $rows.Count
    $pieces = New-Object System.Collections.ArrayList
    $y = 0
    for ($r = 0; $r -lt $rows.Count; $r++) {
        $x = 0
        $row = @($mapRows[$r])
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $zone = 0
            if ($c -lt $row.Count -and $null -ne $row[$c]) { $zone = [int]$row[$c] }
            [void]$pieces.Add((New-ZonePiece -Zone $zone -X $x -Y $y -W ([int]$cols[$c]) -H ([int]$rows[$r])))
            $x += [int]$cols[$c]
        }
        $y += [int]$rows[$r]
    }
    return @($pieces.ToArray())
}

function Get-EqualParts {
    param([int]$Count)
    $parts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Count; $i++) {
        $a = [int]((10000 * $i) / $Count)
        $b = [int]((10000 * ($i + 1)) / $Count)
        [void]$parts.Add(($b - $a))
    }
    return @($parts.ToArray())
}

function Get-GridTemplatePieces {
    param([int]$ZoneCount)
    if ($ZoneCount -lt 1) { return @() }
    $rows = 1
    while ([int]($ZoneCount / $rows) -ge $rows) { $rows++ }
    $rows--
    if ($rows -lt 1) { $rows = 1 }
    $cols = [int]($ZoneCount / $rows)
    if (($ZoneCount % $rows) -ne 0) { $cols++ }
    $rp = @(Get-EqualParts $rows)
    $cp = @(Get-EqualParts $cols)
    $map = New-Object System.Collections.ArrayList
    $index = 0
    for ($r = 0; $r -lt $rows; $r++) {
        $row = New-Object System.Collections.ArrayList
        for ($c = 0; $c -lt $cols; $c++) {
            [void]$row.Add($index)
            if ($index -lt ($ZoneCount - 1)) { $index++ }
        }
        [void]$map.Add($row.ToArray())
    }
    return @(Get-GridPieces -RowPerc $rp -ColPerc $cp -CellMap $map.ToArray())
}

function Get-PriorityPieces {
    param([int]$ZoneCount)
    # Same byte table the FancyZones editor uses for the priority-grid template.
    $table = @(
        [byte[]](0,0,0,0,0,1,1,39,16,39,16,0),
        [byte[]](0,0,0,0,0,1,2,39,16,26,11,13,5,0,1),
        [byte[]](0,0,0,0,0,1,3,39,16,9,196,19,136,9,196,0,1,2),
        [byte[]](0,0,0,0,0,2,3,19,136,19,136,9,196,19,136,9,196,0,1,2,0,1,3),
        [byte[]](0,0,0,0,0,2,3,19,136,19,136,9,196,19,136,9,196,0,1,2,3,1,4),
        [byte[]](0,0,0,0,0,3,3,13,5,13,6,13,5,9,196,19,136,9,196,0,1,2,0,1,3,4,1,5),
        [byte[]](0,0,0,0,0,3,3,13,5,13,6,13,5,9,196,19,136,9,196,0,1,2,3,1,4,5,1,6),
        [byte[]](0,0,0,0,0,3,4,13,5,13,6,13,5,9,196,9,196,9,196,9,196,0,1,2,3,4,1,2,5,6,1,2,7),
        [byte[]](0,0,0,0,0,3,4,13,5,13,6,13,5,9,196,9,196,9,196,9,196,0,1,2,3,4,1,2,5,6,1,7,8),
        [byte[]](0,0,0,0,0,3,4,13,5,13,6,13,5,9,196,9,196,9,196,9,196,0,1,2,3,4,1,5,6,7,1,8,9),
        [byte[]](0,0,0,0,0,3,4,13,5,13,6,13,5,9,196,9,196,9,196,9,196,0,1,2,3,4,1,5,6,7,8,9,10)
    )
    if ($ZoneCount -lt 1 -or $ZoneCount -gt $table.Count) { return @(Get-GridTemplatePieces $ZoneCount) }
    $data = $table[$ZoneCount - 1]
    $i = 5
    $rows = [int]$data[$i]; $i++
    $cols = [int]$data[$i]; $i++
    $rp = New-Object System.Collections.ArrayList
    for ($r = 0; $r -lt $rows; $r++) { [void]$rp.Add([int]($data[$i] * 256 + $data[$i + 1])); $i += 2 }
    $cp = New-Object System.Collections.ArrayList
    for ($c = 0; $c -lt $cols; $c++) { [void]$cp.Add([int]($data[$i] * 256 + $data[$i + 1])); $i += 2 }
    $map = New-Object System.Collections.ArrayList
    for ($r = 0; $r -lt $rows; $r++) {
        $row = New-Object System.Collections.ArrayList
        for ($c = 0; $c -lt $cols; $c++) { [void]$row.Add([int]$data[$i]); $i++ }
        [void]$map.Add($row.ToArray())
    }
    return @(Get-GridPieces -RowPerc $rp.ToArray() -ColPerc $cp.ToArray() -CellMap $map.ToArray())
}

function Get-FocusPieces {
    param([int]$ZoneCount)
    if ($ZoneCount -le 1) { return @(New-ZonePiece -Zone 0 -X 0 -Y 0 -W 10000 -H 10000) }
    $side = $ZoneCount - 1
    $leftN = [int][Math]::Floor($side / 2)
    $rightN = $side - $leftN
    $focusW = 5000
    if ($leftN -gt 0 -and $rightN -gt 0) { $sideW = 2500; $focusX = 2500 }
    elseif ($leftN -gt 0) { $sideW = 5000; $focusX = 5000 }
    else { $sideW = 5000; $focusX = 0 }
    $pieces = New-Object System.Collections.ArrayList
    [void]$pieces.Add((New-ZonePiece -Zone 0 -X $focusX -Y 0 -W $focusW -H 10000))
    $zone = 1
    if ($leftN -gt 0) {
        for ($i = 0; $i -lt $leftN; $i++) {
            $y0 = [int]((10000 * $i) / $leftN)
            $y1 = [int]((10000 * ($i + 1)) / $leftN)
            [void]$pieces.Add((New-ZonePiece -Zone $zone -X 0 -Y $y0 -W $sideW -H ($y1 - $y0)))
            $zone++
        }
    }
    if ($rightN -gt 0) {
        $x = $focusX + $focusW
        for ($i = 0; $i -lt $rightN; $i++) {
            $y0 = [int]((10000 * $i) / $rightN)
            $y1 = [int]((10000 * ($i + 1)) / $rightN)
            [void]$pieces.Add((New-ZonePiece -Zone $zone -X $x -Y $y0 -W (10000 - $x) -H ($y1 - $y0)))
            $zone++
        }
    }
    return @($pieces.ToArray())
}

function Get-TemplatePieces {
    param([string]$Type, [int]$ZoneCount)
    $n = $ZoneCount
    if ($n -lt 1) { $n = 1 }
    switch ($Type) {
        'blank' { return @() }
        'rows' {
            $rp = @(Get-EqualParts $n)
            $map = @()
            for ($i = 0; $i -lt $n; $i++) { $map += ,([object[]]@($i)) }
            return @(Get-GridPieces -RowPerc $rp -ColPerc @(10000) -CellMap $map)
        }
        'columns' {
            $cp = @(Get-EqualParts $n)
            $row = @()
            for ($i = 0; $i -lt $n; $i++) { $row += $i }
            return @(Get-GridPieces -RowPerc @(10000) -ColPerc $cp -CellMap @(,$row))
        }
        'grid' { return @(Get-GridTemplatePieces $n) }
        'priority-grid' { return @(Get-PriorityPieces $n) }
        'focus' { return @(Get-FocusPieces $n) }
        default { return @(Get-GridTemplatePieces $n) }
    }
}

function Get-CanvasPieces {
    param($Info)
    $rw = 0.0; $rh = 0.0
    try { $rw = [double]$Info.'ref-width' } catch { $rw = 0 }
    try { $rh = [double]$Info.'ref-height' } catch { $rh = 0 }
    if ($rw -le 0) { $rw = 10000 }
    if ($rh -le 0) { $rh = 10000 }
    $pieces = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($z in @($Info.zones)) {
        $x = [int]([double]$z.X / $rw * 10000)
        $y = [int]([double]$z.Y / $rh * 10000)
        $w = [int]([double]$z.width / $rw * 10000)
        $h = [int]([double]$z.height / $rh * 10000)
        [void]$pieces.Add((New-ZonePiece -Zone $i -X $x -Y $y -W $w -H $h))
        $i++
    }
    return @($pieces.ToArray())
}

function Get-ZoneSummary {
    param($Pieces)
    $list = @($Pieces)
    if ($list.Count -eq 0) { return '无分区' }
    $ids = @($list | ForEach-Object { $_.Zone } | Select-Object -Unique)
    $n = $ids.Count
    $ys = @($list | ForEach-Object { $_.Y } | Select-Object -Unique)
    $xs = @($list | ForEach-Object { $_.X } | Select-Object -Unique)
    if ($ys.Count -eq 1 -and $n -eq $list.Count) {
        $sorted = @($list | Sort-Object X)
        $pcts = @($sorted | ForEach-Object { [int][Math]::Round($_.W / 100.0) })
        if ($n -eq 2 -and [Math]::Abs($pcts[0] - 50) -le 2 -and [Math]::Abs($pcts[1] - 50) -le 2) { return '左右对半' }
        if ($n -eq 2) { return ('左 {0}% | 右 {1}%' -f $pcts[0], $pcts[1]) }
        return (($pcts | ForEach-Object { '{0}%' -f $_ }) -join ' | ')
    }
    if ($xs.Count -eq 1 -and $n -eq $list.Count) {
        $sorted = @($list | Sort-Object Y)
        $pcts = @($sorted | ForEach-Object { [int][Math]::Round($_.H / 100.0) })
        $even = $true
        $target = 100.0 / $n
        foreach ($p in $pcts) { if ([Math]::Abs($p - $target) -gt 2) { $even = $false } }
        if ($even) { return ('{0} 行均分' -f $n) }
        return (($pcts | ForEach-Object { '{0}%' -f $_ }) -join ' / ')
    }
    return ('{0} 个区域' -f $n)
}

function Get-CustomLayoutIndex {
    $index = @{}
    $doc = Get-JsonFile (Join-Path $script:FZDir 'custom-layouts.json')
    if ($null -eq $doc) { return $index }
    foreach ($item in @($doc.'custom-layouts')) {
        $id = ([string]$item.uuid).ToUpper()
        if (-not [string]::IsNullOrWhiteSpace($id)) { $index[$id] = $item }
    }
    return $index
}

function Get-LayoutView {
    param($Layout, $Catalog)
    $type = [string]$Layout.type
    $uuid = ([string]$Layout.uuid).ToUpper()
    $count = 0
    try { $count = [int]$Layout.'zone-count' } catch { $count = 0 }
    if ($type -eq 'custom' -and $Catalog.ContainsKey($uuid)) {
        $item = $Catalog[$uuid]
        $name = [string]$item.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '未命名布局' }
        $info = $item.info
        if ([string]$item.type -eq 'canvas') { $pieces = @(Get-CanvasPieces $info) }
        else { $pieces = @(Get-GridPieces -RowPerc $info.'rows-percentage' -ColPerc $info.'columns-percentage' -CellMap $info.'cell-child-map') }
        $summary = Get-ZoneSummary $pieces
        return [pscustomobject]@{ Name = $name; Kind = '自定义'; Summary = $summary; Pieces = $pieces }
    }
    $names = @{
        'blank' = '空白'; 'focus' = '焦点'; 'columns' = '列'
        'rows' = '行'; 'grid' = '网格'; 'priority-grid' = '优先网格'
    }
    $name = $names[$type]
    if ([string]::IsNullOrWhiteSpace($name)) {
        if ([string]::IsNullOrWhiteSpace($type)) { $name = '未知布局' } else { $name = $type }
    }
    $pieces = @(Get-TemplatePieces -Type $type -ZoneCount $count)
    $summary = Get-ZoneSummary $pieces
    return [pscustomobject]@{ Name = $name; Kind = '模板'; Summary = $summary; Pieces = $pieces }
}

function Get-EdidNames {
    $map = @{}
    try {
        $rows = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)
    } catch { return $map }
    foreach ($row in $rows) {
        $name = -join @($row.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
        $inst = [string]$row.InstanceName
        if ($inst -match '^DISPLAY\\([^\\]+)\\(.+?)_\d+$') {
            $key = ($Matches[1] + '|' + $Matches[2])
            $map[$key] = $name.Trim()
        }
    }
    return $map
}

function Get-LiveScreens {
    $links = @{}
    if ($null -ne $script:DisplayApi) {
        try {
            foreach ($line in @($script:DisplayApi::GetMonitorLinks())) {
                $parts = $line -split "`t", 3
                if ($parts.Count -lt 3) { continue }
                $model = ''
                $instance = ''
                if ($parts[2] -match 'DISPLAY#([^#]+)#([^#]+)#') {
                    $model = $Matches[1]
                    $instance = $Matches[2]
                }
                $links[$parts[0]] = [pscustomobject]@{
                    DeviceString = $parts[1]
                    Model        = $model
                    Instance     = $instance
                }
            }
        } catch { }
    }
    $edid = Get-EdidNames
    $list = New-Object System.Collections.ArrayList
    try { $screens = @([System.Windows.Forms.Screen]::AllScreens) } catch { $screens = @() }
    foreach ($s in $screens) {
        $link = $links[$s.DeviceName]
        $model = ''; $instance = ''; $deviceString = ''
        if ($null -ne $link) {
            $model = [string]$link.Model
            $instance = [string]$link.Instance
            $deviceString = [string]$link.DeviceString
        }
        $edidName = ''
        $key = ($model + '|' + $instance)
        if ($edid.ContainsKey($key)) { $edidName = [string]$edid[$key] }
        [void]$list.Add([pscustomobject]@{
            DeviceName   = [string]$s.DeviceName
            Bounds       = $s.Bounds
            Primary      = [bool]$s.Primary
            Model        = $model
            Instance     = $instance
            DeviceString = $deviceString
            EdidName     = $edidName
        })
    }
    return @($list.ToArray())
}

function Test-StrictlyLeft {
    param($A, $B)
    return ($A.Bounds.Right -le ($B.Bounds.Left + 40))
}
function Test-StrictlyRight {
    param($A, $B)
    return ($A.Bounds.Left -ge ($B.Bounds.Right - 40))
}
function Test-StrictlyAbove {
    param($A, $B)
    return ($A.Bounds.Bottom -le ($B.Bounds.Top + 40))
}
function Test-StrictlyBelow {
    param($A, $B)
    return ($A.Bounds.Top -ge ($B.Bounds.Bottom - 40))
}

function Get-PlacePhrase {
    param($Screen, $All)
    $others = @($All | Where-Object { $_.DeviceName -ne $Screen.DeviceName })
    if ($others.Count -eq 0) {
        if ($Screen.Primary) { return '主屏' }
        return '当前屏幕'
    }
    $leftN = 0; $rightN = 0; $aboveN = 0; $belowN = 0
    foreach ($o in $others) {
        if (Test-StrictlyLeft $Screen $o) { $leftN++ }
        if (Test-StrictlyRight $Screen $o) { $rightN++ }
        if (Test-StrictlyAbove $Screen $o) { $aboveN++ }
        if (Test-StrictlyBelow $Screen $o) { $belowN++ }
    }
    $h = ''
    if ($leftN -gt $rightN -and $leftN -gt 0) { $h = '左' }
    elseif ($rightN -gt $leftN -and $rightN -gt 0) { $h = '右' }
    $v = ''
    if ($aboveN -gt $belowN -and $aboveN -gt 0) { $v = '上' }
    elseif ($belowN -gt $aboveN -and $belowN -gt 0) { $v = '下' }
    $place = ''
    if ($h -eq '左' -and $leftN -eq $others.Count -and -not $v) { $place = '最左' }
    elseif ($h -eq '右' -and $rightN -eq $others.Count -and -not $v) { $place = '最右' }
    elseif ($h -and $v) { $place = ($h + $v) }
    elseif ($v -eq '上') { $place = '上方' }
    elseif ($v -eq '下') { $place = '下方' }
    elseif ($h -eq '左') { $place = '偏左' }
    elseif ($h -eq '右') { $place = '偏右' }
    else { $place = '中间' }
    if ($Screen.Primary) { return ('主屏 · ' + $place) }
    return $place
}

function Get-MonitorTitle {
    param($Screen)
    $generic = @('Generic PnP Monitor', 'PnP Monitor', '通用即插即用监视器', '即插即用监视器')
    $dev = ([string]$Screen.DeviceString).Trim()
    $edid = ([string]$Screen.EdidName).Trim()
    if (-not [string]::IsNullOrWhiteSpace($dev) -and ($generic -notcontains $dev)) { return $dev }
    if (-not [string]::IsNullOrWhiteSpace($edid)) { return $edid }
    if (-not [string]::IsNullOrWhiteSpace([string]$Screen.Model)) { return [string]$Screen.Model }
    return '显示器'
}

function Get-MonitorExtra {
    param($Screen, [string]$Title)
    $model = ([string]$Screen.Model).Trim()
    if ([string]::IsNullOrWhiteSpace($model) -or $model -eq $Title) { return '' }
    return $model
}

function Get-MonitorCards {
    $baseline = Read-Baseline
    $live = @(Get-LiveScreens)
    $used = @{}
    $cards = New-Object System.Collections.ArrayList
    $monitors = @()
    if ($null -ne $baseline -and $null -ne $baseline.monitors) { $monitors = @($baseline.monitors) }
    foreach ($m in $monitors) {
        $hit = $null
        foreach ($s in $live) {
            if ($used.ContainsKey($s.DeviceName)) { continue }
            if ($s.Model -eq [string]$m.monitor -and @($m.instances) -contains $s.Instance) { $hit = $s; break }
        }
        if ($null -eq $hit) {
            foreach ($s in $live) {
                if ($used.ContainsKey($s.DeviceName)) { continue }
                if (-not [string]::IsNullOrWhiteSpace($s.Model) -and $s.Model -ne [string]$m.monitor) { continue }
                $orient = 'landscape'
                if ($s.Bounds.Height -gt $s.Bounds.Width) { $orient = 'portrait' }
                if ($orient -ne [string]$m.orientation) { continue }
                $cw = 0
                try { $cw = [int]$m.width } catch { $cw = 0 }
                if ($cw -le 0) { continue }
                $delta = [Math]::Abs($s.Bounds.Width - $cw) / [double]$cw
                if ($delta -le 0.12) { $hit = $s; break }
            }
        }
        if ($null -ne $hit) { $used[$hit.DeviceName] = $true }
        [void]$cards.Add([pscustomobject]@{ Baseline = $m; Live = $hit })
    }
    foreach ($s in $live) {
        if (-not $used.ContainsKey($s.DeviceName)) {
            [void]$cards.Add([pscustomobject]@{ Baseline = $null; Live = $s })
        }
    }
    $connected = @($cards | Where-Object { $null -ne $_.Live } | Sort-Object { $_.Live.Bounds.Y }, { $_.Live.Bounds.X })
    $missing = @($cards | Where-Object { $null -eq $_.Live })
    return @($connected + $missing)
}

function New-ArrangementBitmap {
    param($Screens, [string]$Highlight, [int]$Width, [int]$Height)
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)
    $all = @($Screens)
    if ($all.Count -eq 0) { $g.Dispose(); return $bmp }
    $minX = [int](($all | ForEach-Object { $_.Bounds.X } | Measure-Object -Minimum).Minimum)
    $minY = [int](($all | ForEach-Object { $_.Bounds.Y } | Measure-Object -Minimum).Minimum)
    $maxX = [int](($all | ForEach-Object { $_.Bounds.Right } | Measure-Object -Maximum).Maximum)
    $maxY = [int](($all | ForEach-Object { $_.Bounds.Bottom } | Measure-Object -Maximum).Maximum)
    $spanW = [Math]::Max(1, $maxX - $minX)
    $spanH = [Math]::Max(1, $maxY - $minY)
    $pad = 4
    $scale = [Math]::Min(($Width - 2 * $pad) / [double]$spanW, ($Height - 2 * $pad) / [double]$spanH)
    $dw = $spanW * $scale
    $dh = $spanH * $scale
    $ox = ($Width - $dw) / 2.0
    $oy = ($Height - $dh) / 2.0
    foreach ($s in $all) {
        $rx = [int]($ox + ($s.Bounds.X - $minX) * $scale)
        $ry = [int]($oy + ($s.Bounds.Y - $minY) * $scale)
        $rw = [Math]::Max(5, [int]($s.Bounds.Width * $scale) - 3)
        $rh = [Math]::Max(5, [int]($s.Bounds.Height * $scale) - 3)
        $on = ($s.DeviceName -eq $Highlight)
        if ($on) { $fill = [System.Drawing.Color]::FromArgb(47, 111, 237) }
        else { $fill = [System.Drawing.Color]::FromArgb(226, 229, 235) }
        $brush = New-Object System.Drawing.SolidBrush($fill)
        $g.FillRectangle($brush, $rx, $ry, $rw, $rh)
        $brush.Dispose()
        if ($on) { $edge = [System.Drawing.Color]::FromArgb(23, 78, 186) }
        else { $edge = [System.Drawing.Color]::FromArgb(150, 156, 168) }
        $pen = New-Object System.Drawing.Pen($edge, 1)
        $g.DrawRectangle($pen, $rx, $ry, $rw, $rh)
        $pen.Dispose()
    }
    $g.Dispose()
    return $bmp
}

function New-LayoutBitmap {
    param($Pieces, [int]$AspectW, [int]$AspectH, [int]$BoxW, [int]$BoxH)
    $bmp = New-Object System.Drawing.Bitmap($BoxW, $BoxH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)
    if ($AspectW -lt 1) { $AspectW = 16 }
    if ($AspectH -lt 1) { $AspectH = 9 }
    $pad = 2
    $scale = [Math]::Min(($BoxW - 2 * $pad) / [double]$AspectW, ($BoxH - 2 * $pad) / [double]$AspectH)
    $dw = [Math]::Max(8, [int]($AspectW * $scale))
    $dh = [Math]::Max(8, [int]($AspectH * $scale))
    $ox = [int](($BoxW - $dw) / 2)
    $oy = [int](($BoxH - $dh) / 2)
    $frame = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(244, 246, 248))
    $g.FillRectangle($frame, $ox, $oy, $dw, $dh)
    $frame.Dispose()
    $palette = @(
        [System.Drawing.Color]::FromArgb(47, 111, 237),
        [System.Drawing.Color]::FromArgb(96, 160, 247),
        [System.Drawing.Color]::FromArgb(28, 78, 184),
        [System.Drawing.Color]::FromArgb(150, 190, 255),
        [System.Drawing.Color]::FromArgb(62, 122, 214),
        [System.Drawing.Color]::FromArgb(18, 56, 138),
        [System.Drawing.Color]::FromArgb(186, 212, 255),
        [System.Drawing.Color]::FromArgb(40, 96, 176)
    )
    foreach ($p in @($Pieces)) {
        $x0 = $ox + [int][Math]::Round($p.X / 10000.0 * $dw)
        $y0 = $oy + [int][Math]::Round($p.Y / 10000.0 * $dh)
        $x1 = $ox + [int][Math]::Round(($p.X + $p.W) / 10000.0 * $dw)
        $y1 = $oy + [int][Math]::Round(($p.Y + $p.H) / 10000.0 * $dh)
        $zw = [Math]::Max(1, $x1 - $x0)
        $zh = [Math]::Max(1, $y1 - $y0)
        $inset = 1
        if ($zw -gt 6 -and $zh -gt 6) { $x0 += $inset; $y0 += $inset; $zw -= (2 * $inset); $zh -= (2 * $inset) }
        $color = $palette[$p.Zone % $palette.Count]
        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillRectangle($brush, $x0, $y0, $zw, $zh)
        $brush.Dispose()
    }
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(186, 192, 202), 1)
    $g.DrawRectangle($pen, $ox, $oy, ($dw - 1), ($dh - 1))
    $pen.Dispose()
    $g.Dispose()
    return $bmp
}

function Clear-MapHost {
    if ($null -eq $script:MapHost -or $script:MapHost.IsDisposed) { return }
    foreach ($card in @($script:MapHost.Controls)) {
        foreach ($inner in @($card.Controls)) {
            if ($inner -is [System.Windows.Forms.PictureBox] -and $null -ne $inner.Image) {
                $img = $inner.Image
                $inner.Image = $null
                try { $img.Dispose() } catch { }
            }
            try { $inner.Dispose() } catch { }
        }
        try { $card.Dispose() } catch { }
    }
    $script:MapHost.Controls.Clear()
}

function New-MapLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [single]$Size = 9, [bool]$Bold = $false, $Color = $null, [string]$Align = 'MiddleLeft')
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($W, $H)
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $style)
    if ($null -eq $Color) { $Color = [System.Drawing.Color]::FromArgb(40, 44, 52) }
    $lbl.ForeColor = $Color
    $lbl.TextAlign = $Align
    $lbl.AutoEllipsis = $true
    $lbl.BackColor = [System.Drawing.Color]::White
    return $lbl
}

function Refresh-MonitorMap {
    if ($null -eq $script:MapHost -or $script:MapHost.IsDisposed) { return }
    Clear-MapHost
    $muted = [System.Drawing.Color]::FromArgb(110, 114, 124)
    $blue = [System.Drawing.Color]::FromArgb(32, 92, 196)
    $noteColor = [System.Drawing.Color]::FromArgb(140, 110, 40)
    try {
        $cards = @(Get-MonitorCards)
        $live = @(Get-LiveScreens)
        $catalog = Get-CustomLayoutIndex
    } catch {
        $err = New-MapLabel -Text ('读取显示器或布局失败：' + $_.Exception.Message) -X 8 -Y 8 -W ($script:MapHost.Width - 24) -H 40
        $script:MapHost.Controls.Add($err)
        return
    }
    if ($cards.Count -eq 0) {
        $empty = New-MapLabel -Text '还没有基线。先在 FancyZones 里调好布局，再点「改布局后更新基线」。' -X 8 -Y 8 -W ($script:MapHost.Width - 24) -H 40 -Color $muted
        $script:MapHost.Controls.Add($empty)
        return
    }
    $cardW = [Math]::Max(520, $script:MapHost.ClientSize.Width - 8)
    $y = 0
    foreach ($card in $cards) {
        $m = $card.Baseline
        $screen = $card.Live
        $place = '未连接'
        $orientWord = '横屏'
        $title = ''
        $extra = ''
        $resLine = ''
        $posLine = ''
        $note = ''
        $aspectW = 16
        $aspectH = 9
        if ($null -ne $m -and [string]$m.orientation -eq 'portrait') { $orientWord = '竖屏'; $aspectW = 9; $aspectH = 16 }
        if ($null -ne $screen) {
            if ($screen.Bounds.Height -gt $screen.Bounds.Width) { $orientWord = '竖屏' } else { $orientWord = '横屏' }
            $aspectW = [Math]::Max(1, $screen.Bounds.Width)
            $aspectH = [Math]::Max(1, $screen.Bounds.Height)
            $place = Get-PlacePhrase -Screen $screen -All $live
            $title = Get-MonitorTitle $screen
            $extra = Get-MonitorExtra -Screen $screen -Title $title
            $resLine = '{0}×{1} {2}  ·  {3}' -f $screen.Bounds.Width, $screen.Bounds.Height, $orientWord, $screen.DeviceName
            $posLine = '桌面位置 ({0}, {1})' -f $screen.Bounds.X, $screen.Bounds.Y
            if ($null -ne $m) {
                $bw = 0
                try { $bw = [int]$m.width } catch { $bw = 0 }
                if ($bw -gt 0 -and [Math]::Abs($screen.Bounds.Width - $bw) -gt [Math]::Max(8, $bw * 0.02)) {
                    $baseOri = '横屏'
                    if ([string]$m.orientation -eq 'portrait') { $baseOri = '竖屏' }
                    $note = '基线按宽度 {0} {1} 锁定，当前是 {2}×{3}' -f $bw, $baseOri, $screen.Bounds.Width, $screen.Bounds.Height
                }
            }
        } elseif ($null -ne $m) {
            $title = [string]$m.monitor
            $resLine = '基线记录 宽 {0}  ·  {1}' -f $m.width, $orientWord
            $posLine = '这台屏幕当前没有接入'
        }

        $panelH = 112
        if (-not [string]::IsNullOrWhiteSpace($note)) { $panelH = 132 }
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, $y)
        $panel.Size = New-Object System.Drawing.Size($cardW, $panelH)
        $panel.BackColor = [System.Drawing.Color]::White
        $panel.add_Paint({
            param($sender, $e)
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(214, 218, 226))
            $e.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
            $pen.Dispose()
        })

        $highlight = ''
        if ($null -ne $screen) { $highlight = $screen.DeviceName }
        $mapBmp = New-ArrangementBitmap -Screens $live -Highlight $highlight -Width 96 -Height 72
        $mapBox = New-Object System.Windows.Forms.PictureBox
        $mapBox.Location = New-Object System.Drawing.Point(10, [int](($panelH - 72) / 2))
        $mapBox.Size = New-Object System.Drawing.Size(96, 72)
        $mapBox.SizeMode = 'CenterImage'
        $mapBox.BackColor = [System.Drawing.Color]::White
        $mapBox.Image = $mapBmp

        $placeLine = $place
        if ($null -ne $screen) { $placeLine = ($place + '  ·  ' + $orientWord) }
        $idLine = $title
        if (-not [string]::IsNullOrWhiteSpace($extra)) { $idLine = ($title + '  ·  ' + $extra) }

        $textW = [Math]::Max(180, $cardW - 430)
        $lblPlace = New-MapLabel -Text $placeLine -X 116 -Y 10 -W $textW -H 24 -Size 11 -Bold $true
        $lblId = New-MapLabel -Text $idLine -X 116 -Y 36 -W $textW -H 20
        $lblRes = New-MapLabel -Text $resLine -X 116 -Y 58 -W $textW -H 18 -Color $muted
        $lblPos = New-MapLabel -Text $posLine -X 116 -Y 78 -W $textW -H 18 -Color $muted
        $lblNote = $null
        if (-not [string]::IsNullOrWhiteSpace($note)) {
            $lblNote = New-MapLabel -Text $note -X 116 -Y 100 -W $textW -H 18 -Size 8 -Color $noteColor
        }

        $layoutName = '未锁定'
        $layoutSub = '还没有写入基线'
        $pieces = @()
        if ($null -ne $m -and $null -ne $m.layout) {
            $view = Get-LayoutView -Layout $m.layout -Catalog $catalog
            $layoutName = [string]$view.Name
            $layoutSub = ('{0}  ·  {1}' -f $view.Kind, $view.Summary)
            $pieces = @($view.Pieces)
        }
        $thumb = New-LayoutBitmap -Pieces $pieces -AspectW $aspectW -AspectH $aspectH -BoxW 112 -BoxH 78
        $thumbBox = New-Object System.Windows.Forms.PictureBox
        $thumbBox.Location = New-Object System.Drawing.Point(($cardW - 124), [int](($panelH - 78) / 2))
        $thumbBox.Size = New-Object System.Drawing.Size(112, 78)
        $thumbBox.SizeMode = 'CenterImage'
        $thumbBox.BackColor = [System.Drawing.Color]::White
        $thumbBox.Image = $thumb

        $layX = $cardW - 292
        $layW = 160
        $lblKind = New-MapLabel -Text '布局' -X $layX -Y ([int]($panelH / 2) - 36) -W $layW -H 16 -Size 8 -Color $muted -Align 'MiddleRight'
        $lblLay = New-MapLabel -Text $layoutName -X $layX -Y ([int]($panelH / 2) - 18) -W $layW -H 24 -Size 12 -Bold $true -Color $blue -Align 'MiddleRight'
        $lblSub = New-MapLabel -Text $layoutSub -X $layX -Y ([int]($panelH / 2) + 8) -W $layW -H 32 -Size 8 -Color $muted -Align 'TopRight'

        $tipLines = New-Object System.Collections.ArrayList
        [void]$tipLines.Add($placeLine)
        [void]$tipLines.Add($idLine)
        if ($null -ne $screen -and -not [string]::IsNullOrWhiteSpace($screen.EdidName) -and $screen.EdidName.Trim() -ne $title) {
            [void]$tipLines.Add('EDID ' + $screen.EdidName.Trim())
        }
        [void]$tipLines.Add($resLine)
        [void]$tipLines.Add($posLine)
        if (-not [string]::IsNullOrWhiteSpace($note)) { [void]$tipLines.Add($note) }
        [void]$tipLines.Add($layoutName + '  ' + $layoutSub)
        $tip = ($tipLines -join "`n")
        if ($null -ne $script:MapTips) {
            try { $script:MapTips.SetToolTip($panel, $tip) } catch { }
        }

        $panel.Controls.AddRange(@($mapBox, $lblPlace, $lblId, $lblRes, $lblPos, $lblKind, $lblLay, $lblSub, $thumbBox))
        if ($null -ne $lblNote) { $panel.Controls.Add($lblNote) }
        $script:MapHost.Controls.Add($panel)
        $y += ($panel.Height + 8)
    }
    $script:MapHost.AutoScrollMinSize = New-Object System.Drawing.Size(0, $y)
}

# ---------------------------------------------------------------- GUI
function Build-Gui {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FancyZoneFix'
    $form.ClientSize = New-Object System.Drawing.Size(760, 824)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 251)
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $iconBmp = New-LightBitmap -State (Get-LightState) -Size 32
    $form.Icon = ConvertTo-TrayIcon -Bitmap $iconBmp
    $iconBmp.Dispose()

    # --- traffic light panel -------------------------------------------------
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(18, 16)
    $panel.Size = New-Object System.Drawing.Size(58, 134)
    $panel.BackColor = [System.Drawing.Color]::Transparent
    $panel.add_Paint({
        param($s, $e)
        Draw-TrafficLight -Graphics $e.Graphics -W $s.Width -H $s.Height -State $script:LightState
    })
    $script:LightPanel = $panel

    # --- headline ------------------------------------------------------------
    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = '自动监听'
    $lblHead.Location = New-Object System.Drawing.Point(88, 16)
    $lblHead.Size = New-Object System.Drawing.Size(640, 22)
    $lblHead.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblHead.ForeColor = [System.Drawing.Color]::FromArgb(110, 112, 120)

    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Text = '自动监听中'
    $lblState.Location = New-Object System.Drawing.Point(88, 40)
    $lblState.Size = New-Object System.Drawing.Size(640, 28)
    $lblState.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblState.ForeColor = [System.Drawing.Color]::FromArgb(39, 174, 96)
    $script:StateLabel = $lblState

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = '显示器接入、DISPLAY 编号变化时自动把布局修回锁定基线。'
    $lblHint.Location = New-Object System.Drawing.Point(88, 72)
    $lblHint.Size = New-Object System.Drawing.Size(650, 32)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 122, 130)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '开启自动监听'
    $chk.Location = New-Object System.Drawing.Point(88, 112)
    $chk.Size = New-Object System.Drawing.Size(200, 24)
    $chk.Checked = [bool]$script:AutoOn
    $chk.add_CheckedChanged({
        if ($script:Suppress) { return }
        if ($chk.Checked -ne $script:AutoOn) { Toggle-Auto }
    })
    $script:AutoCheck = $chk

    # --- separator -----------------------------------------------------------
    $sep = New-Object System.Windows.Forms.Label
    $sep.Text = ''
    $sep.Location = New-Object System.Drawing.Point(18, 148)
    $sep.Size = New-Object System.Drawing.Size(724, 1)
    $sep.BorderStyle = 'FixedSingle'

    $lblMap = New-Object System.Windows.Forms.Label
    $lblMap.Text = '显示器与锁定布局'
    $lblMap.Location = New-Object System.Drawing.Point(18, 158)
    $lblMap.Size = New-Object System.Drawing.Size(360, 22)
    $lblMap.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblMap.ForeColor = [System.Drawing.Color]::FromArgb(40, 44, 52)

    $lblMapHint = New-Object System.Windows.Forms.Label
    $lblMapHint.Text = '蓝块标出这块屏幕在桌面上的位置。右边是锁定的布局名和分区形状。'
    $lblMapHint.Location = New-Object System.Drawing.Point(18, 180)
    $lblMapHint.Size = New-Object System.Drawing.Size(724, 20)
    $lblMapHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 122, 130)

    $mapHost = New-Object System.Windows.Forms.Panel
    $mapHost.Location = New-Object System.Drawing.Point(18, 206)
    $mapHost.Size = New-Object System.Drawing.Size(724, 396)
    $mapHost.AutoScroll = $true
    $mapHost.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 251)
    $script:MapHost = $mapHost
    $script:MapTips = New-Object System.Windows.Forms.ToolTip
    $script:MapTips.AutoPopDelay = 8000
    $script:MapTips.InitialDelay = 400

    $lblOps = New-Object System.Windows.Forms.Label
    $lblOps.Text = '操作'
    $lblOps.Location = New-Object System.Drawing.Point(18, 612)
    $lblOps.Size = New-Object System.Drawing.Size(120, 20)
    $lblOps.ForeColor = [System.Drawing.Color]::FromArgb(110, 112, 120)

    # --- buttons -------------------------------------------------------------
    function New-ActionButton {
        param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Primary = $false)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Location = New-Object System.Drawing.Point($X, $Y)
        $b.Size = New-Object System.Drawing.Size($W, $H)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 1
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        if ($Primary) {
            $b.BackColor = [System.Drawing.Color]::FromArgb(46, 130, 220)
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(38, 112, 195)
        } else {
            $b.BackColor = [System.Drawing.Color]::White
            $b.ForeColor = [System.Drawing.Color]::FromArgb(50, 52, 58)
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 202, 208)
        }
        return $b
    }

    $btnFix = New-ActionButton -Text '立即修复布局' -X 18 -Y 636 -W 356 -H 40 -Primary $true
    $btnFix.add_Click({ Invoke-Repair })

    $btnBase = New-ActionButton -Text '改布局后更新基线' -X 386 -Y 636 -W 356 -H 40
    $btnBase.add_Click({ Invoke-SaveBaseline })

    $btnLog = New-ActionButton -Text '打开运行日志' -X 18 -Y 682 -W 356 -H 40
    $btnLog.add_Click({ Open-Log })

    $btnUnin = New-ActionButton -Text '卸载 / 还原' -X 386 -Y 682 -W 356 -H 40
    $btnUnin.add_Click({ Invoke-Uninstall })

    # --- status box ----------------------------------------------------------
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = $script:StatusText
    $lblStatus.Location = New-Object System.Drawing.Point(18, 730)
    $lblStatus.Size = New-Object System.Drawing.Size(724, 44)
    $lblStatus.BorderStyle = 'FixedSingle'
    $lblStatus.BackColor = [System.Drawing.Color]::White
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(80, 82, 88)
    $lblStatus.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
    $lblStatus.TextAlign = 'MiddleLeft'
    $lblStatus.AutoEllipsis = $true
    $script:StatusLabel = $lblStatus

    # --- footer --------------------------------------------------------------
    $btnHide = New-ActionButton -Text '隐藏到托盘' -X 18 -Y 782 -W 150 -H 30
    $btnHide.add_Click({ $script:Form.Hide() })

    $btnQuit = New-ActionButton -Text '退出' -X 592 -Y 782 -W 150 -H 30
    $btnQuit.add_Click({ Exit-App })

    $form.Controls.AddRange(@($panel, $lblHead, $lblState, $lblHint, $chk, $sep, $lblMap, $lblMapHint, $mapHost, $lblOps,
                              $btnFix, $btnBase, $btnLog, $btnUnin, $lblStatus, $btnHide, $btnQuit))
    Refresh-MonitorMap

    $form.add_FormClosing({
        param($s, $e)
        if ($script:AllowClose) { return }
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $s.Hide()
        }
    })

    $script:Form = $form
    return $form
}

function Show-Gui {
    if ($null -eq $script:Form -or $script:Form.IsDisposed) { [void](Build-Gui) }
    try {
        $script:Form.Show()
        if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $script:Form.Activate()
        $script:Form.BringToFront()
        $script:Form.TopMost = $true
        $script:Form.TopMost = $false
    } catch { }
    $script:MapFp = ''
    Update-MapIfStale
    Update-Visuals
}

function Update-MapIfStale {
    if ($null -eq $script:Form -or $script:Form.IsDisposed -or -not $script:Form.Visible) { return }
    $fp = ''
    try { $fp = Get-WatchFingerprint } catch { $fp = '' }
    $stamp = ''
    try {
        $bi = Get-Item -LiteralPath $script:BaselinePath -ErrorAction SilentlyContinue
        if ($null -ne $bi) { $stamp = [string]$bi.LastWriteTimeUtc.Ticks }
    } catch { }
    $mfp = $fp + '|' + $stamp
    if ($mfp -eq $script:MapFp) { return }
    $script:MapFp = $mfp
    Refresh-MonitorMap
}

# ---------------------------------------------------------------- tick loop
function On-Tick {
    # external wake-up / quit signals
    $wake = Join-Path $root 'show-gui.flag'
    if (Test-Path -LiteralPath $wake) {
        Remove-Item -LiteralPath $wake -Force -ErrorAction SilentlyContinue
        Show-Gui
    }
    $quit = Join-Path $root 'quit.flag'
    if (Test-Path -LiteralPath $quit) {
        Remove-Item -LiteralPath $quit -Force -ErrorAction SilentlyContinue
        Write-GuardLog 'Tray: quit requested by another process' 'INFO'
        Exit-App
        return
    }

    # a background script finished?
    if ($null -ne $script:PendingProc) {
        $done = $false
        try { $done = $script:PendingProc.HasExited } catch { $done = $true }
        if ($done) {
            $code = -1
            try { $code = $script:PendingProc.ExitCode } catch { }
            try { $script:PendingProc.Dispose() } catch { }
            $script:PendingProc = $null
            $label = $script:BusyLabel
            $script:Busy = $false
            $line = Get-LastLogLine
            if ($code -eq 0) {
                Set-Status ("{0} 完成。`n{1}" -f $label, $line)
            } else {
                Set-Status ("{0} 结束（退出码 {1}）。`n{2}" -f $label, $code, $line)
            }
            $script:LastFp = Get-WatchFingerprint
            $script:MapFp = ''
            Update-MapIfStale
            Update-Visuals
            Trim-Memory
        }
    }

    # automatic repair
    if ($script:AutoOn -and -not $script:Busy) {
        if ($null -ne $script:PendingAt) {
            if ((Get-Date) -ge $script:PendingAt) {
                $script:PendingAt = $null
                Invoke-Repair
                return
            }
        } else {
            $fp = Get-WatchFingerprint
            if ($fp -ne $script:LastFp) {
                $script:LastFp = $fp
                $script:PendingAt = (Get-Date).AddMilliseconds(1600)
                Set-Status '检测到显示器变化，等待系统稳定后自动修复…'
            }
        }
    }

    Update-MapIfStale

    # occasional working-set trim (30 min)
    if (((Get-Date) - $script:LastTrim).TotalMinutes -ge 30) {
        $script:LastTrim = Get-Date
        Trim-Memory
    }
}

if ($PreviewMap) {
    $form = Build-Gui
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.Show()
    $form.Refresh()
    Start-Sleep -Milliseconds 250
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $out = Join-Path $env:TEMP 'fz-map-preview.png'
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $script:AllowClose = $true
    $form.Dispose()
    Write-Output $out
    return
}

# ---------------------------------------------------------------- tray
$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Visible = $false

$bmp0 = New-LightBitmap -State 'on' -Size 32
$script:Notify.Icon = ConvertTo-TrayIcon -Bitmap $bmp0
$bmp0.Dispose()
$script:Notify.Text = 'FancyZoneFix'
$script:Notify.add_DoubleClick({ Show-Gui })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpen.Text = '打开主界面'
$miOpen.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Show-Gui })
[void]$menu.Items.Add($miOpen)

$miFix = New-Object System.Windows.Forms.ToolStripMenuItem
$miFix.Text = '立即修复布局'
$miFix.add_Click({ Invoke-Repair })
[void]$menu.Items.Add($miFix)

$script:MenuAuto = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuAuto.Text = '关闭自动监听'
$script:MenuAuto.add_Click({ Toggle-Auto })
[void]$menu.Items.Add($script:MenuAuto)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = '退出'
$miExit.add_Click({ Exit-App })
[void]$menu.Items.Add($miExit)

$script:Notify.ContextMenuStrip = $menu

# ---------------------------------------------------------------- start
Load-State
Remove-Item -LiteralPath (Join-Path $root 'show-gui.flag') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $root 'quit.flag') -Force -ErrorAction SilentlyContinue
$script:LastFp = Get-WatchFingerprint
Update-Visuals
$script:Notify.Visible = $true

Write-GuardLog ("Tray started (pid={0}, auto={1})" -f $PID, $script:AutoOn) 'INFO'

$script:Ctx = New-Object System.Windows.Forms.ApplicationContext
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.add_Tick({ On-Tick })
$script:Timer.Start()

if ($ShowOnStart) { Show-Gui }

Write-CrashNote ("BOOT: entering message loop (ctx={0}, timer={1})" -f $script:Ctx.GetType().Name, $script:Timer.Enabled)
try {
    [System.Windows.Forms.Application]::Run($script:Ctx)
} finally {
    Write-CrashNote 'BOOT: message loop returned'
    try { $script:Timer.Stop(); $script:Timer.Dispose() } catch { }
    if ($null -ne $script:Notify) { try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch { } }
    if ($null -ne $script:Form) { try { $script:Form.Dispose() } catch { } }
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        try { $script:Mutex.Dispose() } catch { }
    }
    Write-GuardLog 'Tray application exited' 'INFO'
}
