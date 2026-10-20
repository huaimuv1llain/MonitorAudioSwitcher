# MonitorAudioSwitcher

**Windows: every app's audio follows its window.**

Drag a browser, a game, a music player or Discord to your second monitor and *only that app*
is re-routed to the output device you mapped to that monitor. Drag it back and it returns to
the system default. **Your global default playback device is never touched** — everything else
keeps playing where it was.

Windows already lets you pick an output device per app in *Settings → System → Sound → Volume mixer*.
The problem is that it's a static setting: it doesn't care which monitor the app is on.
This tool does exactly that, automatically.

<p align="center">
  <img src="docs/icon-speaker.png" width="520" alt="Tray icon, light and dark taskbar, 16-48 px">
</p>

---

## How is this different?

| Tool | What it does | Automatic? | Per app? |
| --- | --- | --- | --- |
| **MonitorAudioSwitcher** | Routes **each app** to the device of the monitor **its window is on** | ✅ | ✅ |
| [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher) | Switches the **global default device** based on the **focused window's** monitor | ✅ | ❌ |
| [EarTrumpet](https://eartrumpet.app) | Manual per-app volume and output device | ❌ | ✅ |
| [App Audio Router](https://github.com/Eververdants/AppAudioRouter) | Sends one app to **several** devices at once (capture + re-render) | ❌ | ✅ |

The combination *"per-app routing" + "follows the window"* is the gap this fills: you can watch
a video on the TV while a game keeps using your headset, without anything else moving.

---

## Requirements

- Windows 10 1803+ or Windows 11 (64-bit)
- Windows PowerShell 5.1 (built in — nothing to install)
- No administrator rights, no drivers, no virtual audio cables, no third-party binaries

The tool is two files: a PowerShell script and a small C# interop layer that is compiled
in memory at launch. There is no `.exe` to install.

---

## Quick start

1. Download / clone this repository somewhere permanent (e.g. `C:\Tools\MonitorAudioSwitcher`).
2. Run the status report once:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\MonitorAudioSwitcher.ps1 -Status
   ```

   The first run creates `config.json` with one entry per monitor, all mapped to `default`.
   In the same output you'll see every app that currently owns an audio session.

3. Put the **exact output device name** of your second monitor into `config.json`
   (copy it from *Settings → System → Sound*, or from the `-Status` output):

   ```json
   "\\\\.\\DISPLAY2": { "label": "Secondary", "device": "Monitor (NVIDIA High Definition Audio)" }
   ```

4. Run the built-in self test — it switches one app's device, reads it back and restores it:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\MonitorAudioSwitcher.ps1 -SelfTest
   ```

   Both `HRESULT = 0x00000000` means your machine supports it.

5. Double-click `Start-MonitorAudioSwitcher.vbs` to run it in the background (no console window).
   A tray icon appears; right-click it for the menu. Now drag any window between monitors.

Optionally enable autostart: right-click the tray icon → **Autostart on login**.

---

## How it works

Windows stores per-app routing in an audio policy store. The tool talks to
`Windows.Media.Internal.AudioPolicyConfig` — the same undocumented WinRT class the volume mixer
itself uses — and sets the persisted endpoint **per process**:

1. Take the foreground window, ask which program it belongs to.
2. Accept it only if that program currently owns an audio session (i.e. it shows up in the
   volume mixer — which is exactly "this app can produce sound").
3. Read the monitor the window is centred on (`MonitorFromWindow` / `MonitorFromPoint`).
4. Find the process that *actually owns the audio session*. This matters: for Chromium-based
   browsers the audio session often belongs to a different process than the one that owns the
   window, so picking the window's PID would silently fail.
5. Point that app's persisted endpoint at the device mapped to the monitor.

All processes of the same executable share one per-app entry, so one call covers all 30 `msedge.exe`
processes. Different apps keep independent settings.

The tool only acts when the tracked window **changes monitor** (or the app restarts / starts
producing sound again), so it won't fight you if you change something by hand in the volume mixer.

### Returning to the default device

Passing NULL to the API clears the per-app override, but on current Windows builds that does **not**
move an already-playing stream back — you'd have to restart the app. That's why `defaultHandling`
defaults to `pin`: on a monitor mapped to `"default"`, the app is explicitly pinned to the *current*
system default device instead. The audio moves immediately, and if you later change the system
default device the tool re-aligns when needed.

---

## Configuration

`config.json` lives next to the script. It is created automatically and ignored by git.
See [`config.example.json`](config.example.json) for a full example.

| Key | Meaning |
| --- | --- |
| `trackMode` | `anyAudioApp` (default): take over any app with an audio session. `list`: only the processes in `trackedProcesses`. |
| `trackedProcesses` | Whitelist, used only when `trackMode` is `list`. Process names, lowercase, without `.exe`. |
| `excludeProcesses` | Blacklist, used in both modes. Defaults include `wallpaper64` (Wallpaper Engine) and `nvcontainer`. |
| `monitorDevices` | Monitor → output device map. Keys are display names (`\\.\DISPLAY1`, …) — don't rename them. |
| `pollIntervalMs` | How often the foreground window is checked. Default `300`. |
| `retrySeconds` | Retry interval when the app has no audio session yet, or a write failed. Default `5`. |
| `syncOnNewSession` | Re-align when the app (re)starts producing sound. Default `true`. |
| `defaultHandling` | `pin` (default) or `clear` — see above. |
| `notifyOnSwitch` | Show a notification bubble on switch. Default `false`. |
| `showTrayIcon` | Show the tray icon. Default `true`. |
| `trayIconStyle` | `speaker`, `screens` or `screenwave`. |
| `trayIconColor` | Icon background, hex. |
| `applyOnStart` | Align once when the tool starts. |

`device` accepts either a full device name, a unique substring of one, or `"default"`.

Edited the config? Right-click the tray icon → **Reload config.json** — no restart needed.

---

## Command line

| Argument | Effect |
| --- | --- |
| *(none)* | Run in the background (tray icon) |
| `-Status` | Print monitor mapping, audio sessions, and the current decision |
| `-SelfTest` | Real switch + read-back + restore, prints HRESULTs |
| `-DryRun` | Decide, but don't change anything |
| `-Simulate "\\.\DISPLAY2"` | Pretend the window is on that monitor and act now |
| `-Simulate "\\.\DISPLAY2" -Process firefox` | Same, for a specific app |
| `-RunForSeconds 10` | Run for 10 seconds, then exit (testing) |
| `-InstallStartup` / `-UninstallStartup` | Add / remove the startup entry |
| `-NoTray` | No tray icon |

---

## Troubleshooting

Everything is logged to `MonitorAudioSwitcher.log` next to the script.

| HRESULT | Meaning | What to do |
| --- | --- | --- |
| `0x00000000` | OK | — |
| `0x80070005` | Access denied | Run it from your own desktop PowerShell session (restricted/sandboxed tokens are refused) |
| `0x80070057` | Invalid argument | The app had no audio session at that moment — play something; the tool retries automatically |
| `0x80004005` | Interop failure | Check the `LastError` line in the log |

Common cases:

- **Dragged it, nothing changed** — let the app play a sound first, then check that `-Status`
  lists it under audio sessions. Apps that never produced sound have no entry in Windows to change.
- **An app ignores it** — Chromium-based browsers can pin an output device internally
  (`chrome://settings`, or a site that picked one). Set it back to *Default*. Games using WASAPI
  exclusive mode can't be routed at all.
- **An app I don't want is being routed** — add its process name to `excludeProcesses`, then reload.
- **It steers too many apps** — switch `trackMode` to `list` and use the whitelist.
- **The startup entry silently doesn't appear** — security software often blocks `.vbs` files
  written into the Startup folder. Check the log for `写入开机启动失败`, or create a Task Scheduler
  entry that runs
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<path>\MonitorAudioSwitcher.ps1"`.
- **After moving the folder** — the startup entry stores an absolute path. Re-run `-InstallStartup`.

### Antivirus false positives

A PowerShell script that registers a `.vbs` autostart entry will look suspicious to some AV
products. The full source is here; you can audit it before running, skip the autostart feature,
or run it manually. Nothing is downloaded at runtime.

---

## Known limitations

- Uses an **undocumented** Windows interface (`Windows.Media.Internal.AudioPolicyConfig`).
  It has been stable since Windows 10 1803, but a future Windows update could break it.
- Decisions are based on the **foreground window**. Background apps keep whatever device they had.
- Per-app settings are **persistent**. If you quit the tool, the last assignments stay until
  something changes them (that's how the Windows feature works).
- Display names (`\\.\DISPLAY1`, …) can change if you re-plug cables. Re-check with `-Status`.
- Only apps that show up in the volume mixer can be routed.

---

## Tested on

Windows 11 (build 26200), two monitors with different output devices, using browsers, games,
a music player and a chat client. Per-app switching, live re-routing of a playing stream,
switching back to the system default, and the startup entry were all verified.

Not yet verified: several *different* apps routed to different monitors at the same time
(each app's setting is independent by design, but this wasn't tested interactively).

---

## Credits

- The internal interface layout (IIDs, vtable order, HSTRING handling) was cross-checked against
  [EarTrumpet](https://github.com/File-New-Project/EarTrumpet), which uses the same Windows API.
- The "follow the focused window's monitor" idea comes from
  [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher).

## License

[MIT](LICENSE)
