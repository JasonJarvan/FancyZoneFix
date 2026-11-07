# FancyZoneFix

Stop [PowerToys FancyZones](https://learn.microsoft.com/windows/powertoys/fancyzones) from swapping layouts when a monitor reconnects, the laptop docks, or the PC wakes from sleep.

Windows reassigns `\\.\DISPLAY1` and the monitor's PnP instance ID. FancyZones looks up the layout with a five-part device key. When any part changes, the lookup misses and that screen falls back to the default template (often Priority grid or Rows). FancyZoneFix freezes the correct binding and puts it back.

A tray app for Windows. No scheduled task. Tested with PowerToys 0.102.

## Install

Requirements: Windows, Windows PowerShell 5.1, PowerToys with FancyZones enabled. No administrator rights.

1. Put this folder somewhere stable, for example `C:\Programs\System\FancyZoneFix`.
2. In the FancyZones editor, set the layout you want on each monitor.
3. Double-click `FancyZoneFix.vbs`. The console never appears. A tray icon does.
4. Double-click the tray icon and choose **改布局后更新基线** (save the current bindings as the lock).

Log on at startup (the shortcut path is fixed to `C:\Programs\System\FancyZoneFix`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Startup.ps1
```

`baseline.json` is created on that machine and is not in this repository. `baseline.example.json` shows the shape.

## Daily use

| | |
|---|---|
| Green icon | Watching. About 1.6 seconds after a display change, the lock is applied again. |
| Red icon | Watching is off. The tray and window stay. Repair is manual. |
| Double-click | Open the window. |
| Right-click | Repair now, toggle watching, or quit. |
| Close (X) | Hide to the tray. The process keeps running. |

The window lists each screen with a position map, name, model, resolution, orientation, desktop origin, and `\\.\DISPLAYn`. Beside that is the locked FancyZones layout: its name, whether it is custom or a template, and a thumbnail of the zones.

**立即修复布局** rewrites `%LOCALAPPDATA%\Microsoft\PowerToys\FancyZones\applied-layouts.json` and touches the FancyZones config files so the running module reloads them. Editing the JSON alone leaves the on-screen zones stale until the FancyZones editor is opened.

Change a layout in the editor first, then save a new baseline. The next repair puts back whatever baseline you saved.

## Why the layout jumps

FancyZones stores the active layout per device in `applied-layouts.json`. The key is:

```
monitor + monitor-instance + monitor-number + serial-number + virtual-desktop
```

`monitor` is the hardware id (`DELA0B2`, `XMI3001`, …). `monitor-instance` is the PnP UID (`4&…&UID1234`). `monitor-number` is the `\\.\DISPLAYn` index. A reconnect can change the last two. The lookup misses, FancyZones writes a fallback row whose monitor name is `\\.\DISPLAYn` and whose instance is empty, and the screen gets the default layout from `default-layouts.json`.

FancyZoneFix keeps one baseline row per physical screen (model, known instance ids, resolution, orientation, layout). It expands that into every known instance times display numbers 1–8, all pointing at the same layout, and deletes the fallback rows. Whichever number Windows picks, the key hits.

New PnP ids are learned from FancyZones logs (`Initialize layout on …, work area rect = WxH`), matched by model, orientation, then width within 12%.

## What it does not do

- It does not edit zone geometry. Build layouts in the FancyZones editor.
- It does not replace PowerToys. FancyZones must be running.
- Two monitors of the same model are told apart by width and orientation. A new panel with a similar width needs a new baseline.
- The startup shortcut expects the folder at `C:\Programs\System\FancyZoneFix`.
- It is a PowerShell process, not a single exe. Idle working set is on the order of 20 MB.

## Layout of the repo

| File | Role |
|---|---|
| `FancyZoneFix.vbs` | Hidden launcher |
| `FancyZoneFix.Tray.ps1` | Tray icon, window, display watch |
| `Guard-FancyZones.ps1` | Compare `applied-layouts.json` with the baseline and repair it |
| `Save-FancyZonesBaseline.ps1` | Snapshot the current bindings into `baseline.json` |
| `lib/FancyZones.Common.ps1` | Shared JSON, matching, and reload helpers |
| `Install-Startup.ps1` | Per-user Startup entry, and removal of a legacy scheduled task |

Logs, `state.json`, and the `baseline/` snapshots stay on the machine.

## 中文

显示器重连、笔记本插拔扩展坞、睡眠唤醒之后，FancyZones 的布局会串屏。Windows 会重分配 `\\.\DISPLAYn` 和 PnP UID，FancyZones 用五元组查 `applied-layouts.json`，对不上就退回默认的优先网格或行。

本程序把每台物理屏的正确布局锁进 `baseline.json`，展开成「所有已知 instance × DISPLAY 编号 1–8」的冗余表，并用托盘程序守着。绿灯为自动监听。双击托盘打开界面，能看到每块屏的位置、名字、分辨率，以及布局名和分区缩略图。

用法：先在 FancyZones 里调好布局，双击 `FancyZoneFix.vbs`，再在界面里点「改布局后更新基线」。之后「立即修复布局」会写回锁定并让正在运行的 FancyZones 重新读取。只改 JSON、不发重载时，屏幕上的分区要等打开编辑器才会变。

## License

[MIT](LICENSE)
