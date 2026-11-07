' Run a PowerShell script with no visible console window.
' Default: Guard-FancyZones.ps1. A script filename may be passed as arg 0.
' 0 = hidden window; True = wait and return the child exit code.
Dim sh, fso, here, scriptName, cmd, rc
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
scriptName = "Guard-FancyZones.ps1"
If WScript.Arguments.Count > 0 Then scriptName = WScript.Arguments(0)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\" & scriptName & """"
rc = sh.Run(cmd, 0, True)
WScript.Quit rc
