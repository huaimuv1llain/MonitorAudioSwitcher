# MonitorAudioSwitcher

English · [简体中文](README.md)

> **Every app's audio follows its window.**
>
> Drag a browser, a game or a music player to your second monitor — only that app moves to
> that monitor's output device. Drag it back — it returns to the system default.
> Your global default playback device is never touched.

<p align="center">
  <img src="docs/icon-speaker.png" width="520" alt="Tray icon on light/dark taskbars, 16-48 px">
</p>

---

## First time? Three steps, no command line

### 1. Download and extract

Download **[MonitorAudioSwitcher-v1.0.0.zip](https://github.com/huaimuv1llain/MonitorAudioSwitcher/releases/latest/download/MonitorAudioSwitcher-v1.0.0.zip)**
and extract it to a permanent folder, e.g. `D:\Tools\MonitorAudioSwitcher`.

Keep these three files together in the same folder — do not rename them:

```
MonitorAudioSwitcher.ps1
WinAudio.cs
Start-MonitorAudioSwitcher.vbs
```

### 2. Tell it which device your second monitor uses

1. Copy `config.example.json` to `config.json` (same folder).
2. Open `config.json` in Notepad and replace `PUT_YOUR_DEVICE_NAME_HERE` with the exact
   output device name of your second monitor, for example:

   ```json
   "\\\\.\\DISPLAY2": {
     "label": "Secondary",
     "device": "Monitor (NVIDIA High Definition Audio)"
   }
   ```

3. Save the file.

Not sure what the device is called? Right-click the speaker icon in the taskbar →
**Sound settings** → look at the output list, or press `Win+R` and run `mmsys.cpl`.
Copy the whole name, parentheses included.

Not sure which screen is `DISPLAY1` and which is `DISPLAY2`? *Settings → System → Display →
Identify*. If they are swapped, just swap the two `device` values in `config.json`.

### 3. Start it

Double-click **`Start-MonitorAudioSwitcher.vbs`**. No console window; a blue speaker icon
appears in the notification area. Now drag a window that is playing audio to the other monitor.

Right-click the tray icon → **Autostart on login** if you want it to run automatically.

---

## Why this one?

Windows already lets you choose an output device **per app** (Settings → System → Sound →
Volume mixer) — but that setting is static and doesn't know which monitor the app is on.
This tool makes it follow the window.

| Tool | What it does | Automatic | Per app |
| --- | --- | --- | --- |
| **MonitorAudioSwitcher** | Routes **each app** to the device of the monitor **its window is on** | ✅ | ✅ |
| [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher) | Switches the **global default device** based on the **focused window's** monitor | ✅ | ❌ |
| [EarTrumpet](https://eartrumpet.app) | Manual per-app volume and output device | ❌ | ✅ |
| [App Audio Router](https://github.com/Eververdants/AppAudioRouter) | Sends one app to **several** devices at once (capture + re-render) | ❌ | ✅ |

## How it works

The tool calls `Windows.Media.Internal.AudioPolicyConfig` — the same undocumented WinRT class
the Windows volume mixer uses — and sets the persisted endpoint **per process**:

1. Take the foreground window's program.
2. Accept it only if that program currently owns an audio session (it shows up in the mixer).
3. Read the monitor the window is on.
4. Find the process that **actually owns the audio session** — for Chromium-based browsers this
   is often not the process that owns the window, so using the window's PID silently fails.
5. Point that app's persisted endpoint at the device mapped to the monitor.

All processes of one executable share a single per-app entry, so one call covers all 30
`msedge.exe` processes. Different apps keep independent settings.

The tool only acts when the window **changes monitor** (or the app restarts / starts producing
sound again), so it won't fight manual changes made in the volume mixer.

### Returning to the default device

Passing NULL to the API clears the per-app override, but on current Windows builds that does
**not** move an already-playing stream back. That is why `defaultHandling` defaults to `pin`:
on a monitor mapped to `"default"` the app is explicitly pinned to the *current* system default
device. Audio moves immediately, and if you change the system default device later the tool
re-aligns when needed.

---

## Configuration

`config.json` lives next to the script and is created automatically on first run.
See [`config.example.json`](config.example.json).

| Key | Meaning |
| --- | --- |
| `trackMode` | `anyAudioApp` (default): any app with an audio session. `list`: only `trackedProcesses`. |
| `trackedProcesses` | Whitelist, used only with `trackMode: "list"`. Lowercase, no `.exe`. |
| `excludeProcesses` | Blacklist, both modes. Defaults to `wallpaper64` and `nvcontainer`. |
| `monitorDevices` | Monitor → device map. Keys are display names (`\\.\DISPLAY1`, …) — don't rename them. |
| `pollIntervalMs` | Foreground-window poll interval. Default `300`. |
| `retrySeconds` | Retry interval when the app has no session yet or a write failed. Default `5`. |
| `syncOnNewSession` | Re-align when the app restarts or starts producing sound. Default `true`. |
| `defaultHandling` | `pin` (default) or `clear` — see above. |
| `notifyOnSwitch` | Notification bubble on switch. Default `false`. |
| `showTrayIcon` | Show the tray icon. |
| `trayIconStyle` | `speaker`, `screens` or `screenwave`. |
| `trayIconColor` | Icon background color, hex. |
| `applyOnStart` | Align once at startup. |

`device` accepts a full device name, a unique substring of one, or `"default"`.
Right-click the tray icon → **Reload config.json** after editing — no restart needed.

---

## Command line

| Argument | Effect |
| --- | --- |
| *(none)* | Run in the background (tray icon) |
| `-Status` | Print monitor mapping, audio sessions and the current decision |
| `-SelfTest` | Real switch + read-back + restore, prints HRESULTs |
| `-DryRun` | Decide without changing anything |
| `-Simulate "\\.\DISPLAY2"` | Pretend the window is on that monitor and act now |
| `-Simulate "\\.\DISPLAY2" -Process firefox` | Same, for a specific app |
| `-RunForSeconds 10` | Run for 10 seconds, then exit |
| `-InstallStartup` / `-UninstallStartup` | Add / remove the startup entry |
| `-NoTray` | No tray icon |

---

## Troubleshooting

Everything is logged to `MonitorAudioSwitcher.log` next to the script.

| HRESULT | Meaning | What to do |
| --- | --- | --- |
| `0x00000000` | OK | — |
| `0x80070005` | Access denied | Run it from your own desktop PowerShell session |
| `0x80070057` | Invalid argument | The app had no audio session at that moment — play something |
| `0x80004005` | Interop failure | Check the `LastError` line in the log |

- **Dragged it, nothing changed** — let the app play a sound first; check that `-Status` lists it.
- **An app ignores it** — Chromium-based browsers can pin an output device internally
  (`chrome://settings`, or a site that picked one); WASAPI-exclusive games can't be routed.
- **An app I don't want is routed** — add its process name to `excludeProcesses` and reload.
- **Startup entry silently missing** — security software often blocks `.vbs` files written to
  the Startup folder. Check the log, or create a Task Scheduler entry that runs
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<path>\MonitorAudioSwitcher.ps1"`.
- **Moved the folder** — the startup entry stores an absolute path; enable autostart again.

### Antivirus false positives

A PowerShell script that registers a `.vbs` autostart entry will look suspicious to some AV
products. The full source is here; audit it, skip the autostart feature, or run it manually.
Nothing is downloaded at runtime.

---

## Known limitations

- Uses an **undocumented** Windows interface (`Windows.Media.Internal.AudioPolicyConfig`).
  Stable since Windows 10 1803, but a future Windows update could break it.
- Decisions are based on the **foreground window**; background apps keep their device.
- Per-app settings are **persistent** — quitting the tool leaves the last assignments in place.
- Only apps that appear in the volume mixer can be routed.
- Windows 10 1803+ / Windows 11 (64-bit), PowerShell 5.1, no admin rights, no drivers,
  no virtual audio cables, no third-party binaries.

---

## Tested on

Windows 11 (build 26200) with two monitors using different output devices, using browsers,
games, a music player and a chat client. Per-app switching, live re-routing of a playing
stream, switching back to the system default, and the startup entry were all verified.

Not yet verified: several different apps routed to different monitors at the same time
(each app's setting is independent by design, but this wasn't tested interactively).

---

## Credits

- The internal interface layout (IIDs, vtable order, HSTRING handling) was cross-checked against
  [EarTrumpet](https://github.com/File-New-Project/EarTrumpet), which uses the same Windows API.
- The "follow the focused window's monitor" idea comes from
  [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher).

## License

[MIT](LICENSE)
