' Start the resident monitor watcher with no visible console window.
' 0 = hidden window; False = do not wait (the watcher stays resident).
Dim sh, fso, here, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\Monitor-Watcher.ps1"""
sh.Run cmd, 0, False
