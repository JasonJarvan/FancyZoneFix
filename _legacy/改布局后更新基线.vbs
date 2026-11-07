' FancyZoneFix: update baseline. No visible console window.
Dim sh, cmd
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Programs\System\FancyZoneFix\Save-FancyZonesBaseline.ps1"""
sh.Run cmd, 0, True