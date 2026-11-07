# FancyZoneFix installer: (re)creates the windowless per-user Startup entry
# for the tray application and removes any legacy scheduled task.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

$startup = [Environment]::GetFolderPath('Startup')
$content = @'
' FancyZoneFix: auto-start on logon. No visible console window.
' Starts the tray application (tray icon + optional GUI + topology watch).
Dim sh, fso, ps1, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

ps1 = "C:\Programs\System\FancyZoneFix\FancyZoneFix.Tray.ps1"

If Not fso.FileExists(ps1) Then
    WScript.Quit 0
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
'@
[System.IO.File]::WriteAllText((Join-Path $startup 'FancyZoneFix-AutoWatch.vbs'), $content, (New-Object System.Text.ASCIIEncoding))
"Startup entry written: $(Join-Path $startup 'FancyZoneFix-AutoWatch.vbs')"

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
