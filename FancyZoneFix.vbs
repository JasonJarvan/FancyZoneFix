' FancyZoneFix launcher.
' Starts the tray application with the console window hidden from the very
' first moment (SW_HIDE), so nothing ever flashes or steals focus.
Option Explicit

Dim sh, fso, root, ps1, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = root & "\FancyZoneFix.Tray.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "FancyZoneFix.Tray.ps1 not found next to this launcher:" & vbCrLf & root, 16, "FancyZoneFix"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
