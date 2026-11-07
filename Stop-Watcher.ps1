# Ask the tray application to stop (and any legacy watcher too).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\FancyZones.Common.ps1')

[System.IO.File]::WriteAllText((Join-Path $script:LockDir 'quit.flag'), (Get-Date -Format 'o'), (New-Object System.Text.ASCIIEncoding))
[System.IO.File]::WriteAllText($script:StopFlag, (Get-Date -Format 'o'), (New-Object System.Text.ASCIIEncoding))
Write-GuardLog 'Stop requested (tray + watcher)' 'INFO'
"Stop signals written. The tray app exits within a few seconds."
