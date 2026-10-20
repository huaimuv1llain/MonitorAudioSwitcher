# MonitorAudioSwitcher

**简体中文** · [English](README.en.md)

> 让每个应用的输出设备，跟着它窗口所在的显示器走。
>
> 把浏览器、游戏、播放器拖到副屏 —— 声音从副屏的音响出来；
> 拖回主屏 —— 声音回到系统默认设备。
> **系统全局默认播放设备全程不动**，其它程序的声音一点都不受影响。

<p align="center">
  <img src="docs/icon-speaker.png" width="520" alt="托盘图标：浅色/深色任务栏以及不同尺寸">
</p>

---

# 第一次用？照着做就行（全程不用命令行）

## 第 1 步：下载并解压

点这里下载：**[MonitorAudioSwitcher-v1.0.0.zip](https://github.com/huaimuv1llain/MonitorAudioSwitcher/releases/latest/download/MonitorAudioSwitcher-v1.0.0.zip)**

解压到一个**固定的文件夹**，比如：

```
D:\Tools\MonitorAudioSwitcher
```

> 别放在「下载」或「桌面」里 —— 容易被清理软件或你自己误删。

解压后里面应该是这些文件：

```
MonitorAudioSwitcher.ps1          ← 主程序
WinAudio.cs                       ← 核心代码，必须和主程序放在一起
Start-MonitorAudioSwitcher.vbs    ← 双击这个启动
config.example.json               ← 配置模板
README.md  README.en.md  LICENSE
```

**前三个文件必须待在同一个文件夹里**，不要拆开、不要改名。

## 第 2 步：告诉它「副屏用哪个音响」

1. 在同一个文件夹里，把 `config.example.json` **复制一份**，改名为 `config.json`
   （如果看不到文件后缀名，先在资源管理器「查看」里打开「文件扩展名」）
2. 右键 `config.json` → **打开方式 → 记事本**
3. 找到这一段：

   ```json
   "\\\\.\\DISPLAY2": {
     "label": "Secondary",
     "device": "PUT_YOUR_DEVICE_NAME_HERE"
   }
   ```

4. 把 `PUT_YOUR_DEVICE_NAME_HERE` 换成你副屏音响的**完整名字**，例如：

   ```json
   "device": "Monitor (NVIDIA High Definition Audio)"
   ```

   名字照抄声音设置里显示的那一串，包括括号。改完保存、关掉记事本。

### 不知道自己的设备叫什么？

- 右键任务栏右下角的小喇叭 → **声音设置** → 看「输出」里列出的设备名
- 或者按 `Win + R`，输入 `mmsys.cpl`，在「播放」标签里看

名字里带括号的部分也算，比如 `扬声器 (Realtek Audio)`、`Monitor (NVIDIA High Definition Audio)` 整串都要。

### 哪块屏是 DISPLAY1、哪块是 DISPLAY2？

- 设置 → 系统 → 显示 → 点「标识」，屏幕上会显示数字；
- 如果搞反了（拖到副屏反而用主屏的设备），把 `DISPLAY1` 和 `DISPLAY2` 下面的
  `device` 值对调一下就行，其它不用动。

## 第 3 步：启动

双击 **`Start-MonitorAudioSwitcher.vbs`**。

- 不会弹黑框；
- 右下角托盘会出现一个**蓝色小喇叭**图标；
- 现在随便拖一个正在出声的窗口到副屏试试。

**想开机自动运行**：右键那个托盘图标 → 勾选 **`开机自启动`**。

### 右键托盘图标能做什么

| 菜单项 | 作用 |
| --- | --- |
| 开机自启动 | 勾上/取消，立即生效 |
| 暂停自动切换 | 暂时不管，图标会变灰 |
| 立即按当前窗口判断一次 | 不想拖窗口、想手动触发时用 |
| 重新载入 config.json | 改完配置不用重启 |
| 打开所在文件夹 | 找配置和日志 |
| 查看日志 | 出问题时看这里 |
| 退出 | 停止本次运行 |

## 新手常见问题

- **双击 `.vbs` 没反应？** 先看右下角托盘有没有蓝色小喇叭；再看同目录的
  `MonitorAudioSwitcher.log`。有些安全软件会拦截 `.vbs`，见下面的「杀软误报」。
- **拖过去了但没换设备？** 先让这个程序**出点声音**。从没出过声的程序，Windows 里根本没有
  可设置项，工具也就无从下手。
- **某个程序不听话？** Chromium 系浏览器可能在 `chrome://settings` 或某个网页里单独锁了
  输出设备，改回「默认」；用 WASAPI 独占的游戏无法被路由。
- **不想让某个程序跟着走？** 把它的进程名加进 `config.json` 的 `excludeProcesses`，
  然后托盘菜单点「重新载入 config.json」。
- **搞乱了想重来？** 删掉 `config.json`，把 `config.example.json` 再复制一份改名即可。

---

# 它到底做了什么

Windows 本身已经允许**每个应用单独选输出设备**（设置 → 系统 → 声音 → 音量合成器），
但那是静态设置，它不知道应用在哪块屏幕上。这个工具补的就是这一块：

1. 取当前前台窗口，看它属于哪个程序；
2. 这个程序当前必须有音频会话（也就是音量合成器里能看到它）；
3. 取窗口所在的显示器；
4. 从音频会话里找出**真正持有声音的那个进程**——Chromium 系浏览器的音频会话经常不在
   带窗口的那个进程上，用窗口 PID 会静默失败；
5. 把这个应用的持久化输出设备指向该显示器映射的设备。

同一个 exe 的所有进程共享一份按应用设置，所以 Edge 那几十个进程一次调用就全覆盖；
不同应用各存各的。

工具只在**窗口换屏**（或应用重启、重新开始出声）时动作，不会每隔几秒跟你在音量合成器里的
手动修改抢控制权。

## 和现成方案的区别

| 工具 | 做什么 | 自动 | 按应用 |
| --- | --- | --- | --- |
| **MonitorAudioSwitcher** | 把**每个应用**送到**它窗口所在显示器**对应的设备 | ✅ | ✅ |
| [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher) | 按**焦点窗口**所在屏切换**全局默认设备** | ✅ | ❌ |
| [EarTrumpet](https://eartrumpet.app) | 手动调每个应用的音量和输出设备 | ❌ | ✅ |
| [App Audio Router](https://github.com/Eververdants/AppAudioRouter) | 把一个应用同时送到**多个**设备（抓流重放） | ❌ | ✅ |

## 为什么「回到默认」不直接清除

给接口传 NULL 可以清除按应用的自定义，但在当前 Windows 上这**不会**把正在播放的流搬回来，
非得重启应用才行。所以 `defaultHandling` 默认是 `pin`：映射为 `"default"` 的屏幕上，
把这个应用**明确固定到当前的系统默认设备**。声音立刻搬回来；之后你若改了系统默认设备，
工具会在需要时重新对齐。

---

# 配置说明

`config.json` 和脚本放在一起，首次运行也会自动生成。完整示例见
[`config.example.json`](config.example.json)。

| 字段 | 说明 |
| --- | --- |
| `trackMode` | `anyAudioApp`（默认）任何能出声的应用都接管；`list` 只接管 `trackedProcesses` |
| `trackedProcesses` | 白名单，仅 `trackMode: "list"` 时生效；进程名小写、不带 `.exe` |
| `excludeProcesses` | 黑名单，两种模式都生效；默认排除 `wallpaper64`（Wallpaper Engine）和 `nvcontainer` |
| `monitorDevices` | 屏幕 → 设备映射；键是显示器名（`\\.\DISPLAY1` …），不要改 |
| `pollIntervalMs` | 检查前台窗口的间隔，默认 `300` ms |
| `retrySeconds` | 目标应用还没有音频会话、或写入失败时的重试间隔，默认 `5` 秒 |
| `syncOnNewSession` | 应用重启/重新出声时重新对齐，默认开 |
| `defaultHandling` | `pin`（默认）或 `clear`，见上一节 |
| `notifyOnSwitch` | 切换时是否弹通知，默认 `false` |
| `showTrayIcon` | 是否显示托盘图标 |
| `trayIconStyle` | 图标样式：`speaker` / `screens` / `screenwave` |
| `trayIconColor` | 图标底色（十六进制） |
| `applyOnStart` | 启动时先对齐一次 |

`device` 可以写完整设备名、设备名的唯一一段，或 `"default"`。

改完配置不用重启：右键托盘 → **重新载入 config.json**。

---

# 命令行（进阶）

不想用托盘、想排查问题时用：

| 参数 | 作用 |
| --- | --- |
| （无） | 后台常驻（托盘图标） |
| `-Status` | 打印显示器映射、当前音频会话、判定结果 |
| `-SelfTest` | 真机切换 + 读回 + 还原，打印 HRESULT |
| `-DryRun` | 只判断不修改 |
| `-Simulate "\\.\DISPLAY2"` | 假装窗口在 2 号屏并立即执行 |
| `-Simulate "\\.\DISPLAY2" -Process firefox` | 同上，指定应用 |
| `-RunForSeconds 10` | 跑 10 秒后退出（测试用） |
| `-InstallStartup` / `-UninstallStartup` | 安装 / 移除开机启动 |
| `-NoTray` | 不显示托盘图标 |

运行方式（在工具文件夹里按住 Shift + 右键 → 「在此处打开 PowerShell 窗口」）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MonitorAudioSwitcher.ps1 -Status
```

---

# 排查

日志就在脚本旁边：`MonitorAudioSwitcher.log`。

| HRESULT | 含义 | 处理 |
| --- | --- | --- |
| `0x00000000` | 成功 | — |
| `0x80070005` | 拒绝访问 | 用你自己的桌面 PowerShell 会话运行（受限令牌会被拒） |
| `0x80070057` | 参数无效 | 那一刻该应用还没有音频会话；先放点声音，工具会自动重试 |
| `0x80004005` | 接口异常 | 看日志里的 `LastError` |

其他常见情况：

- **开机自启没出现**：安全软件常拦截写入启动文件夹的 `.vbs`，看日志里的
  `写入开机启动失败`；或者用任务计划程序建一个「登录时」任务，运行
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<路径>\MonitorAudioSwitcher.ps1"`。
- **挪了文件夹**：启动项里存的是绝对路径，重新在托盘里勾一次开机自启动。
- **重新插拔线缆后编号变了**：`\\.\DISPLAY1/2` 可能变化，用 `-Status` 复查后调整配置。

## 杀软误报

一个会往启动文件夹写 `.vbs` 的 PowerShell 脚本，对部分杀软来说很像可疑行为。
源码全都在这份仓库里，可以先审再跑，也可以完全不用「开机自启动」、手动双击启动。
程序运行时不下载任何东西。

---

# 已知限制

- 用的是**未公开**接口（`Windows.Media.Internal.AudioPolicyConfig`），自 Windows 10 1803 起稳定，
  但未来系统更新有可能失效。
- 判定基于**前台窗口**；后台应用维持现有设备。
- 按应用设置是**持久化**的：退出工具后，最后一次的分配仍然保留（这是 Windows 特性）。
- 只有出现在音量合成器里的应用才能被路由。
- 需要 Windows 10 1803+ / Windows 11（64 位），系统自带 PowerShell 5.1 即可，
  不需要管理员权限、驱动、虚拟声卡或任何第三方程序。

---

# 实测情况

Windows 11（build 26200）、两块接不同输出设备的显示器，使用浏览器、游戏、音乐播放器、
聊天客户端测试。按应用切换、播放中实时搬运、切回系统默认、开机启动项均已验证。

尚未验证：多个**不同**应用同时分别固定在不同显示器上的交互表现
（按设计每个应用互不影响，但没有做过多应用并存的实测）。

---

# 致谢

- 内部接口的细节（IID、vtable 顺序、HSTRING 处理）参照了
  [EarTrumpet](https://github.com/File-New-Project/EarTrumpet)，它用的是同一套 Windows API。
- 「跟着焦点窗口所在显示器走」这个思路来自
  [AutoAudioSwitcher](https://github.com/maxkagamine/AutoAudioSwitcher)。

# 许可

[MIT](LICENSE)
