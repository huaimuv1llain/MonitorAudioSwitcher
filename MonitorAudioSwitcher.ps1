<#
    MonitorAudioSwitcher.ps1
    ------------------------------------------------------------------
    只要是"能出声的应用"，它的窗口在哪块显示器上，就把「这个应用自己的」输出设备
    切成那块显示器对应的设备（默认模式 trackMode = anyAudioApp）。

    - 浏览器、音乐播放器、游戏、Discord 都算，判定条件是"当前有没有音频会话"
      （也就是音量合成器里能不能看到它）
    - 只改这一个应用的音频路由，系统全局默认播放设备全程不动
    - 想只管某几个进程：trackMode 改成 "list"，在 trackedProcesses 里列出来
    - 想排除某些进程：加进 excludeProcesses

    常用命令：
      MonitorAudioSwitcher.ps1            常驻监视
      MonitorAudioSwitcher.ps1 -Status    查看映射、音频会话、当前状态
      MonitorAudioSwitcher.ps1 -SelfTest  真机实测一次切换（自动还原）
      MonitorAudioSwitcher.ps1 -DryRun    只判断不切换
      MonitorAudioSwitcher.ps1 -Simulate "\\.\DISPLAY2"     假装窗口在 2 号屏
      MonitorAudioSwitcher.ps1 -Simulate "\\.\DISPLAY2" -Process msedge    指定应用来测
      MonitorAudioSwitcher.ps1 -InstallStartup / -UninstallStartup

    配置：同目录 config.json（首次运行自动生成）
    依赖：同目录 WinAudio.cs
#>

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$SelfTest,
    [switch]$DryRun,
    [string]$Simulate = '',
    [string]$Process = '',
    [int]$RunForSeconds = 0,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [string]$StartupFolder = '',
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogPath = Join-Path $ScriptDir 'MonitorAudioSwitcher.log'
$CsPath = Join-Path $ScriptDir 'WinAudio.cs'

# ---------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1048576)) {
            Set-Content -LiteralPath $LogPath -Value '' -Encoding UTF8
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Explain-Hr {
    param([int]$Hr)
    switch ('{0:X8}' -f $Hr) {
        '00000000' { return '' }
        '80070005' { return '拒绝访问 —— 通常是运行环境的权限被限制，请在你自己的 PowerShell 窗口里跑。' }
        '80070057' { return '参数无效 —— 一般是该进程此刻还没有音频会话（没在播放声音），或进程已经退出。' }
        '80004005' { return '接口调用失败，具体见日志里的 LastError。' }
        default { return '' }
    }
}

# ---------------------------------------------------------------- core api
if (-not ('WinAudio' -as [type])) {
    if (-not (Test-Path -LiteralPath $CsPath)) {
        Write-Log ("找不到核心文件：{0}" -f $CsPath) 'ERROR'
        exit 1
    }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($CsPath)) -Language CSharp -ReferencedAssemblies 'System.Drawing', 'System.Core'
}
[WinAudio]::EnableDpiAwareness()

# ---------------------------------------------------------------- config
function Get-Defaults {
    @{
        trackMode         = 'anyAudioApp'
        trackedProcesses  = @('msedge', 'chrome', 'firefox', 'brave', 'vivaldi', 'opera', 'chromium')
        excludeProcesses  = @()
        pollIntervalMs    = 300
        retrySeconds      = 5
        syncOnNewSession  = $true
        defaultHandling   = 'pin'
        notifyOnSwitch    = $true
        showTrayIcon      = $true
        trayIconStyle     = 'speaker'
        trayIconColor     = '#2F6FEB'
        applyOnStart      = $true
        monitorDevices    = @{}
    }
}

function ConvertTo-PlainHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-PlainHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-PlainHashtable $item)) }
        return $list.ToArray()
    }
    return $InputObject
}

function New-ConfigFile {
    $monitors = [WinAudio]::GetMonitors()
    $map = [ordered]@{}
    foreach ($m in ($monitors | Sort-Object DeviceName)) {
        $suffix = if ($m.Primary) { '（主屏）' } else { '' }
        $map[$m.DeviceName] = [ordered]@{
            label  = ('{0}x{1}{2}' -f $m.Width, $m.Height, $suffix)
            device = 'default'
        }
    }
    $defaults = Get-Defaults
    $cfg = [ordered]@{
        trackMode        = $defaults.trackMode
        trackedProcesses = $defaults.trackedProcesses
        excludeProcesses = $defaults.excludeProcesses
        pollIntervalMs   = $defaults.pollIntervalMs
        retrySeconds     = $defaults.retrySeconds
        syncOnNewSession = $defaults.syncOnNewSession
        defaultHandling  = $defaults.defaultHandling
        notifyOnSwitch   = $defaults.notifyOnSwitch
        showTrayIcon     = $defaults.showTrayIcon
        trayIconStyle    = $defaults.trayIconStyle
        trayIconColor    = $defaults.trayIconColor
        applyOnStart     = $defaults.applyOnStart
        monitorDevices   = $map
    }
    ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Log ("已生成配置文件：{0}" -f $ConfigPath)
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { New-ConfigFile }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { New-ConfigFile; $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 }
    $obj = ConvertTo-PlainHashtable ($raw | ConvertFrom-Json)
    $defaults = Get-Defaults
    foreach ($k in $defaults.Keys) {
        if (-not $obj.ContainsKey($k) -or $null -eq $obj[$k]) { $obj[$k] = $defaults[$k] }
    }
    $obj['trackedProcesses'] = @($obj['trackedProcesses'] | ForEach-Object { $_.ToString().ToLower() })
    $obj['excludeProcesses'] = @($obj['excludeProcesses'] | ForEach-Object { $_.ToString().ToLower() })
    $trackMode = [string]$obj['trackMode']
    if ($trackMode -ne 'list' -and $trackMode -ne 'anyAudioApp') { $obj['trackMode'] = 'anyAudioApp' }
    if (-not $obj['monitorDevices']) { $obj['monitorDevices'] = @{} }
    return $obj
}

$script:Config = Get-Config

# ---------------------------------------------------------------- helpers
function Get-MappingEntry {
    param([string]$Display)
    if ($script:Config['monitorDevices'].ContainsKey($Display)) { return $script:Config['monitorDevices'][$Display] }
    return $null
}

function Format-DeviceId {
    param($Id)
    if ($null -eq $Id) { return '(读取失败)' }
    if ($Id -eq '') { return '(未设置，跟随系统默认)' }
    $dev = [WinAudio]::GetRenderDevices() | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($dev) { return $dev.FriendlyName }
    return ('(已不在线的设备) ' + $Id)
}

function Get-ProcessNameForPid {
    param([int]$ProcessId)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) { return $p.ProcessName }
    return '未知进程'
}

function Resolve-OutputDevice {
    param([string]$Match)
    if ([string]::IsNullOrWhiteSpace($Match)) { return $null }
    $devices = [WinAudio]::GetRenderDevices()
    foreach ($d in $devices) {
        if ($d.FriendlyName -eq $Match -or $d.Id -eq $Match) { return $d }
    }
    $partial = @($devices | Where-Object { $_.FriendlyName.IndexOf($Match, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) {
        $names = ($partial | ForEach-Object { $_.FriendlyName }) -join ' / '
        Write-Log ("'{0}' 同时匹配到多个设备：{1}；请在 config.json 里写完整名称" -f $Match, $names) 'ERROR'
        return $null
    }
    Write-Log ("找不到播放设备：'{0}'（被拔掉了，或者名字写错了）" -f $Match) 'ERROR'
    return $null
}

function Test-WarnOnce {
    param([string]$Key, [int]$Seconds = 60)
    $now = Get-Date
    if ($script:WarnedAt.ContainsKey($Key) -and ($now - $script:WarnedAt[$Key]).TotalSeconds -lt $Seconds) { return $false }
    $script:WarnedAt[$Key] = $now
    return $true
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    if ($script:Tray) {
        try { $script:Tray.ShowBalloonTip(2500, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}

# ---------------------------------------------------------------- audio sessions
function Get-AllAudioSessions {
    # 所有"能出声"的应用会话：排除系统音效（pid 0）和没有进程名的条目
    @([WinAudio]::GetAudioSessions($false) | Where-Object {
            $_.Pid -ne 0 -and -not $_.IsSystemSounds -and -not [string]::IsNullOrEmpty($_.ProcessName)
        })
}

function Get-SessionIndex {
    # 进程名(小写) -> 会话列表。每个 tick 只枚举一次，后面都复用
    $index = @{}
    foreach ($s in (Get-AllAudioSessions)) {
        $n = $s.ProcessName.ToLower()
        if (-not $index.ContainsKey($n)) { $index[$n] = New-Object System.Collections.ArrayList }
        [void]$index[$n].Add($s)
    }
    return $index
}

function Get-SessionsForProcess {
    param([string]$ProcessName, $Index)
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return @() }
    if (-not $Index) { $Index = Get-SessionIndex }
    $n = $ProcessName.ToLower()
    if ($Index.ContainsKey($n)) { return @($Index[$n]) }
    return @()
}

function Get-SessionPidForProcess {
    param([string]$ProcessName, [int]$PreferPid = 0, $Index)
    $sessions = Get-SessionsForProcess -ProcessName $ProcessName -Index $Index
    if (@($sessions).Count -eq 0) { return 0 }
    $pids = @($sessions | Group-Object Pid | ForEach-Object {
            [pscustomobject]@{
                Pid    = [int]$_.Name
                Active = [bool]($_.Group | Where-Object { $_.State -eq 1 })
            }
        })
    if ($PreferPid -gt 0 -and ($pids | Where-Object { $_.Pid -eq $PreferPid })) { return $PreferPid }
    $active = $pids | Where-Object { $_.Active } | Select-Object -First 1
    if ($active) { return $active.Pid }
    return $pids[0].Pid
}

function Test-TrackedProcess {
    param([string]$ProcessName, $Index)
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $false }
    $name = $ProcessName.ToLower()
    if (@($script:Config['excludeProcesses']) -contains $name) { return $false }
    if ([string]$script:Config['trackMode'] -eq 'list') {
        return (@($script:Config['trackedProcesses']) -contains $name)
    }
    # anyAudioApp：只要这个名字的进程当前有音频会话，就算"能出声的软件"
    return (@(Get-SessionsForProcess -ProcessName $name -Index $Index).Count -gt 0)
}

# ---------------------------------------------------------------- the actual switch
function Sync-AppOutput {
    param([string]$Display, [string]$ProcessName, [int]$PreferPid = 0, [switch]$Apply, [switch]$Chatty, $Index)

    $entry = Get-MappingEntry $Display
    if (-not $entry) {
        if (Test-WarnOnce "map:$Display") { Write-Log ("config.json 里没有 {0} 这一项。" -f $Display) 'WARN' }
        return 'nomap'
    }
    $label = if ($entry['label']) { $entry['label'] } else { $Display }
    $want = [string]$entry['device']
    $wantsDefault = [string]::IsNullOrWhiteSpace($want) -or $want -eq 'default'

    $mode = [string]$script:Config['defaultHandling']
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'pin' }

    $targetId = ''
    $targetName = ''
    if ($wantsDefault) {
        if ($mode -eq 'clear') {
            # 只清除自定义，交给系统默认。注意：在部分系统上这不会让正在播放的声音立刻搬回去
            $targetId = ''
            $targetName = '清除自定义（跟随系统默认）'
        } else {
            # 明确指定为「当前系统默认设备」，这样正在播放的流一定会搬回来
            $targetId = [WinAudio]::GetDefaultRenderId()
            if ([string]::IsNullOrWhiteSpace($targetId)) {
                if (Test-WarnOnce 'nodefault') { Write-Log '读不到当前系统默认播放设备，这次跳过。' 'WARN' }
                return 'pending'
            }
            $targetName = '跟随系统默认（{0}）' -f (Format-DeviceId $targetId)
        }
    } else {
        $device = Resolve-OutputDevice $want
        if (-not $device) { return 'nomap' }
        $targetId = $device.Id
        $targetName = $device.FriendlyName
    }

    $targetPid = Get-SessionPidForProcess -ProcessName $ProcessName -PreferPid $PreferPid -Index $Index
    if ($targetPid -le 0) {
        if (Test-WarnOnce "nosession:$ProcessName") {
            Write-Log ("{0} 现在没有音频会话（没在放声音），等它开始出声会自动对齐。" -f $ProcessName)
        }
        return 'pending'
    }

    $current = [PerAppAudio]::GetProcessDevice([uint32]$targetPid)
    if ($null -ne $current -and $current -eq $targetId) {
        if ($Chatty) { Write-Log ("{0}：应用输出已经是「{1}」，不用动。" -f $label, $targetName) }
        return 'ok'
    }

    if (-not $Apply) {
        Write-Log ("[试运行] {0} 上的 {1}（pid {2}）：应用输出应为「{3}」，当前是「{4}」" -f $label, $ProcessName, $targetPid, $targetName, (Format-DeviceId $current))
        return 'ok'
    }

    $hr = [PerAppAudio]::SetProcessDevice([uint32]$targetPid, $targetId)
    if ($hr -ne 0) {
        Write-Log ("设置失败：{0}（HRESULT 0x{1:X8}，pid {2}）{3}" -f $label, $hr, $targetPid, [PerAppAudio]::LastError) 'ERROR'
        $hint = Explain-Hr $hr
        if ($hint -and (Test-WarnOnce "hr:$hr")) { Write-Log ("  提示：{0}" -f $hint) 'WARN' }
        return 'pending'
    }

    Write-Log ("{0} 上的 {1}（pid {2}）-> 应用输出切到「{3}」；系统默认设备不变" -f $label, $ProcessName, $targetPid, $targetName)
    if ($script:Config['notifyOnSwitch']) { Show-Balloon '应用输出已切换' ('{0}：{1} → {2}' -f $ProcessName, $label, $targetName) }

    Start-Sleep -Milliseconds 250
    $readBack = [PerAppAudio]::GetProcessDevice([uint32]$targetPid)
    # 有的系统上即使设置成功，读回也常常是空的（接口行为），所以只在读到"别的设备"时才提醒
    if ($null -ne $readBack -and $readBack -ne '' -and $readBack -ne $targetId) {
        Write-Log ("  注意：写入后读回的是「{0}」，和期望的「{1}」不一样 —— 如果声音没跟着走，把这条日志发我。" -f (Format-DeviceId $readBack), (Format-DeviceId $targetId)) 'WARN'
    }
    return 'ok'
}

# ---------------------------------------------------------------- tray
function New-AppIcon {
    param([switch]$Paused)
    try {
        $style = [string]$script:Config['trayIconStyle']
        if ([string]::IsNullOrWhiteSpace($style)) { $style = 'speaker' }
        $color = if ($Paused) { '#9AA0A6' } else { [string]$script:Config['trayIconColor'] }
        if ([string]::IsNullOrWhiteSpace($color)) { $color = '#2F6FEB' }
        $size = [Math]::Max(16, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
        return [TrayIconFactory]::CreateIcon($style, $color, $size)
    } catch {
        Write-Log ("生成托盘图标失败，先用系统默认图标顶上：{0}" -f $_.Exception.Message) 'WARN'
        return [System.Drawing.SystemIcons]::Application
    }
}

function Set-TrayIconState {
    param([bool]$Paused)
    if (-not $script:Tray) { return }
    try {
        $new = New-AppIcon -Paused:$Paused
        $old = $script:Tray.Icon
        $script:Tray.Icon = $new
        if ($old) { $old.Dispose() }
    } catch {
        Write-Log ("更新托盘图标失败：{0}" -f $_.Exception.Message) 'WARN'
    }
}

function Set-StatusText {
    param([string]$Text)
    if ($Text -eq $script:StatusText) { return }
    $script:StatusText = $Text
    if ($script:ItemStatus) { $script:ItemStatus.Text = $Text }
    if ($script:Tray) { $script:Tray.Text = ('MonitorAudioSwitcher - ' + $Text) }
}

function Initialize-Tray {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = (New-AppIcon)
        $tray.Text = 'MonitorAudioSwitcher'

        $menu = New-Object System.Windows.Forms.ContextMenuStrip

        $itemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemStatus.Text = '状态：启动中…'
        $itemStatus.Enabled = $false
        [void]$menu.Items.Add($itemStatus)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $itemPause = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemPause.Text = '暂停自动切换'
        $itemPause.CheckOnClick = $true
        $itemPause.add_CheckedChanged({
                $script:Paused = [bool]$this.Checked
                if ($script:Paused) { Write-Log '已暂停自动切换（图标转灰）' } else { Write-Log '已恢复自动切换' }
                Set-TrayIconState -Paused $script:Paused
            })
        [void]$menu.Items.Add($itemPause)

        $itemStartup = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemStartup.Text = '开机自启动'
        $itemStartup.CheckOnClick = $true
        $itemStartup.Checked = Test-StartupInstalled
        $itemStartup.add_CheckedChanged({
                if ($script:SuppressStartupToggle) { return }
                $script:SuppressStartupToggle = $true
                try {
                    if ($this.Checked) {
                        if (Install-Startup) {
                            Show-Balloon '已加入开机启动' '下次登录会自动运行'
                        } else {
                            Show-Balloon '加入开机启动失败' '见日志，通常是被安全软件拦了'
                            $this.Checked = $false
                        }
                    } else {
                        if (Uninstall-Startup) {
                            Show-Balloon '已取消开机启动' '下次登录不会自动运行'
                        } else {
                            $this.Checked = $true
                        }
                    }
                } finally {
                    $script:SuppressStartupToggle = $false
                }
            })
        [void]$menu.Items.Add($itemStartup)

        $itemNow = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemNow.Text = '立即按当前窗口判断一次'
        $itemNow.add_Click({
                $script:DesiredDisplay = ''
                $script:Applied = $false
                $script:LastAttempt = [datetime]::MinValue
            })
        [void]$menu.Items.Add($itemNow)

        $itemReload = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemReload.Text = '重新载入 config.json'
        $itemReload.add_Click({
                try {
                    $script:Config = Get-Config
                    $script:Applied = $false
                    $script:LastAttempt = [datetime]::MinValue
                    Write-Log '配置已重新载入'
                } catch {
                    Write-Log ("重新载入配置失败：{0}" -f $_.Exception.Message) 'ERROR'
                }
            })
        [void]$menu.Items.Add($itemReload)

        $itemFolder = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemFolder.Text = '打开所在文件夹'
        $itemFolder.add_Click({ Start-Process explorer.exe $ScriptDir })
        [void]$menu.Items.Add($itemFolder)

        $itemLog = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemLog.Text = '查看日志'
        $itemLog.add_Click({ Start-Process notepad.exe $LogPath })
        [void]$menu.Items.Add($itemLog)

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem
        $itemExit.Text = '退出'
        $itemExit.add_Click({ $script:Quit = $true })
        [void]$menu.Items.Add($itemExit)

        $tray.ContextMenuStrip = $menu
        $tray.Visible = $true
        $script:Tray = $tray
        $script:ItemStatus = $itemStatus
        Write-Log '托盘图标已创建（右键图标有菜单；勾选「暂停自动切换」可临时关掉）'
    } catch {
        Write-Log ("创建托盘图标失败，改为无界面运行：{0}" -f $_.Exception.Message) 'WARN'
        $script:Tray = $null
    }
}

# ---------------------------------------------------------------- loops
function Invoke-Tick {
    param([int]$RetrySeconds = 5, [switch]$Apply)

    # 本轮只枚举一次音频会话，后面都复用
    $index = Get-SessionIndex

    # 1) 前台窗口是谁、在哪块屏（只要"这个名字的进程"当前有音频会话就接管）
    $foregroundPid = 0
    $hwnd = [WinAudio]::ForegroundWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        $proc = [WinAudio]::ProcessNameOfWindow($hwnd)
        if (Test-TrackedProcess -ProcessName $proc -Index $index) {
            $display = [WinAudio]::WindowCenterMonitor($hwnd)
            if ($display) {
                $name = $proc.ToLower()
                if ($display -ne $script:DesiredDisplay -or $name -ne $script:DesiredProcess) {
                    $script:DesiredDisplay = $display
                    $script:DesiredProcess = $name
                    $script:Applied = $false
                    $script:LastAttempt = [datetime]::MinValue
                }
                $foregroundPid = [int][WinAudio]::ProcessIdOfWindow($hwnd)
            }
        }
    }

    if (-not $script:DesiredDisplay -or -not $script:DesiredProcess) {
        Set-StatusText '状态：等待能出声的应用窗口'
        return
    }

    # 2) 这个应用自己的会话变了（重启 / 开始出声）就重新对齐一次
    $sessionKey = (@(Get-SessionsForProcess -ProcessName $script:DesiredProcess -Index $index | ForEach-Object { $_.Pid }) | Sort-Object -Unique) -join ','
    if ($script:Config['syncOnNewSession'] -and $script:LastSessionKey -ne '' -and $sessionKey -ne $script:LastSessionKey) {
        $script:Applied = $false
        $script:LastAttempt = [datetime]::MinValue
    }
    $script:LastSessionKey = $sessionKey

    # 2b) 系统默认设备变了，而当前屏幕是「跟随默认」的配置 -> 重新对齐（这样"跟随"才真的跟着走）
    $globalId = [WinAudio]::GetDefaultRenderId()
    if ($globalId -ne $script:LastGlobalDefault) {
        $firstTime = ($script:LastGlobalDefault -eq '')
        $entryDefault = Get-MappingEntry $script:DesiredDisplay
        $wantDefault = if ($entryDefault) { [string]$entryDefault['device'] } else { '' }
        $isDefaultEntry = [string]::IsNullOrWhiteSpace($wantDefault) -or $wantDefault -eq 'default'
        $mode = [string]$script:Config['defaultHandling']
        if ($isDefaultEntry -and $mode -ne 'clear') {
            # 第一次（工具刚启动）也重新对齐一次：这样上次运行期间改过默认设备也能被纠正
            if (-not $firstTime) { Write-Log ('系统默认播放设备变成了「{0}」，当前屏幕配的是跟随默认，重新对齐一次。' -f (Format-DeviceId $globalId)) }
            $script:Applied = $false
            $script:LastAttempt = [datetime]::MinValue
        }
        $script:LastGlobalDefault = $globalId
    }

    # 3) 需要时同步（失败会按 retrySeconds 重试）
    if (-not $script:Applied) {
        if (((Get-Date) - $script:LastAttempt).TotalSeconds -ge $RetrySeconds) {
            $script:LastAttempt = Get-Date
            $script:Applied = (Sync-AppOutput -Display $script:DesiredDisplay -ProcessName $script:DesiredProcess -PreferPid $foregroundPid -Apply:$Apply -Index $index) -eq 'ok'
        }
    }

    # 4) 托盘文字
    $entry = Get-MappingEntry $script:DesiredDisplay
    $label = if ($entry -and $entry['label']) { $entry['label'] } else { $script:DesiredDisplay }
    Set-StatusText ('状态：{0} 在 {1}（{2}）' -f $script:DesiredProcess, $label, $(if ($script:Applied) { '已对齐' } else { '待重试' }))
}

function Start-Watcher {
    $script:WarnedAt = @{}
    $script:Paused = $false
    $script:Quit = $false
    $script:Tray = $null
    $script:StatusText = ''
    $script:DesiredDisplay = ''
    $script:DesiredProcess = ''
    $script:Applied = $false
    $script:LastAttempt = [datetime]::MinValue
    $script:LastSessionKey = ''
    $script:LastGlobalDefault = ''

    $mutex = New-Object System.Threading.Mutex($false, 'Local\MonitorAudioSwitcher_SingleInstance')
    if (-not $mutex.WaitOne(0)) {
        Write-Log '已经有一个 MonitorAudioSwitcher 在跑了，本次启动直接退出。' 'WARN'
        return
    }
    $script:Mutex = $mutex

    if (-not [PerAppAudio]::IsSupported()) {
        Write-Log '这个 Windows 版本不支持按应用设置输出设备（需要 Windows 10 1803 或更新）。' 'ERROR'
    }
    if ($script:Config['showTrayIcon'] -and -not $NoTray) { Initialize-Tray }

    Write-Log ('开始监视：跟踪进程 {0}；每 {1} ms 检查一次' -f ((@($script:Config['trackedProcesses'])) -join ', '), $script:Config['pollIntervalMs'])

    $retrySeconds = [Math]::Max(2, [int]$script:Config['retrySeconds'])
    $deadline = if ($RunForSeconds -gt 0) { (Get-Date).AddSeconds($RunForSeconds) } else { $null }
    $interval = [Math]::Max(100, [int]$script:Config['pollIntervalMs'])

    while (-not $script:Quit) {
        if ($script:Tray) { [System.Windows.Forms.Application]::DoEvents() }

        if ($script:Paused) {
            Set-StatusText '状态：已暂停'
        } else {
            try {
                Invoke-Tick -RetrySeconds $retrySeconds -Apply $true
            } catch {
                Write-Log ("处理出错：{0}" -f $_.Exception.Message) 'ERROR'
            }
        }

        if ($deadline -and ((Get-Date) -gt $deadline)) {
            Write-Log ('已到达 -RunForSeconds 的时限（{0} 秒），退出。' -f $RunForSeconds)
            break
        }
        Start-Sleep -Milliseconds $interval
    }

    if ($script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
    Write-Log '已停止监视。'
}

# ---------------------------------------------------------------- status / self test
function Show-Status {
    $monitors = [WinAudio]::GetMonitors() | Sort-Object DeviceName

    Write-Host ''
    Write-Host '显示器 -> 应用输出设备'
    Write-Host '--------------------------------------------------------------------------'
    foreach ($m in $monitors) {
        $entry = Get-MappingEntry $m.DeviceName
        $want = if ($entry) { [string]$entry['device'] } else { '' }
        $tag = if ($m.Primary) { ' [主屏]' } else { '' }
        if ([string]::IsNullOrWhiteSpace($want) -or $want -eq 'default') {
            $modeText = if ([string]$script:Config['defaultHandling'] -eq 'clear') { '清除自定义' } else { '跟随系统默认' }
            Write-Host ('  {0}  {1}x{2}{3}  ->  {4}（当前系统默认设备 = {5}）' -f $m.DeviceName, $m.Width, $m.Height, $tag, $modeText, (Format-DeviceId ([WinAudio]::GetDefaultRenderId())))
        } else {
            $dev = [WinAudio]::GetRenderDevices() | Where-Object { $_.FriendlyName -eq $want -or $_.Id -eq $want } | Select-Object -First 1
            if (-not $dev) {
                $partial = @([WinAudio]::GetRenderDevices() | Where-Object { $_.FriendlyName.IndexOf($want, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                if ($partial.Count -eq 1) { $dev = $partial[0] }
            }
            if ($dev) {
                Write-Host ('  {0}  {1}x{2}{3}  ->  {4}' -f $m.DeviceName, $m.Width, $m.Height, $tag, $dev.FriendlyName)
            } else {
                Write-Host ('  {0}  {1}x{2}{3}  ->  {4}   [找不到这个设备!]' -f $m.DeviceName, $m.Width, $m.Height, $tag, $want) -ForegroundColor Red
            }
        }
    }

    Write-Host ''
    Write-Host ('系统全局默认播放设备（本工具全程不会改它）：{0}' -f (Format-DeviceId ([WinAudio]::GetDefaultRenderId())))
    if ([string]$script:Config['trackMode'] -eq 'list') {
        Write-Host ('接管方式：只接管列表里的进程 —— {0}' -f ((@($script:Config['trackedProcesses'])) -join ', '))
    } else {
        Write-Host '接管方式：任何有音频会话（能出声）的应用'
    }
    if (@($script:Config['excludeProcesses']).Count -gt 0) {
        Write-Host ('排除的进程：{0}' -f ((@($script:Config['excludeProcesses'])) -join ', '))
    }
    Write-Host ('按应用切换接口可用：{0}' -f [PerAppAudio]::IsSupported())

    Write-Host ''
    Write-Host '当前能出声的应用（音量合成器里能看到的那些）：'
    $index = Get-SessionIndex
    $sessions = Get-AllAudioSessions
    if (@($sessions).Count -eq 0) {
        Write-Host '  （没有）—— 现在没有应用在出声'
    } else {
        $stateName = @{ 0 = '未播放'; 1 = '正在播放'; 2 = '已过期' }
        foreach ($name in ($index.Keys | Sort-Object)) {
            $take = if (Test-TrackedProcess -ProcessName $name -Index $index) { '会接管' } else { '已排除' }
            foreach ($s in $index[$name]) {
                Write-Host ('  pid {0,-8} {1,-16} {2,-8} {3,-6} 会话所在设备：{4}' -f $s.Pid, $s.ProcessName, $stateName[$s.State], $take, $s.DeviceName)
            }
        }
        $probe = ''
        $fgWin = [WinAudio]::ForegroundWindow()
        if ($fgWin -ne [IntPtr]::Zero) {
            $fgProc = [WinAudio]::ProcessNameOfWindow($fgWin)
            if (Test-TrackedProcess -ProcessName $fgProc -Index $index) { $probe = $fgProc.ToLower() }
        }
        if (-not $probe -and $index.Keys.Count -gt 0) { $probe = ($index.Keys | Sort-Object)[0] }
        if ($probe) {
            $probePid = Get-SessionPidForProcess -ProcessName $probe -Index $index
            Write-Host ''
            Write-Host ('以「{0}」为例：设置对象 pid {1}，该应用当前的独立输出 = {2}' -f $probe, $probePid, (Format-DeviceId ([PerAppAudio]::GetProcessDevice([uint32]$probePid))))
        }
    }

    $fg = [WinAudio]::ForegroundWindow()
    Write-Host ''
    if ($fg -eq [IntPtr]::Zero) {
        Write-Host '前台窗口：读不到（当前运行环境看不到桌面，属正常现象）' -ForegroundColor Yellow
    } else {
        Write-Host ('前台窗口：{0} 「{1}」在 {2}' -f [WinAudio]::ProcessNameOfWindow($fg), [WinAudio]::WindowTitleOf($fg), [WinAudio]::WindowCenterMonitor($fg))
    }
    Write-Host ''
    Write-Host ('配置文件：{0}' -f $ConfigPath)
    Write-Host ('日志文件：{0}' -f $LogPath)
}

function Invoke-SelfTest {
    Write-Host ''
    Write-Host '实测「只切换这个应用的输出设备」（结束会自动还原）'
    Write-Host '--------------------------------------------------------------------------'

    if (-not [PerAppAudio]::IsSupported()) {
        Write-Host '这个 Windows 版本不支持该接口（需要 Windows 10 1803 或更新）。' -ForegroundColor Red
        exit 1
    }

    $index = Get-SessionIndex
    if ($index.Keys.Count -eq 0) {
        Write-Host '现在没有任何应用在出声。先在某个应用里播放点声音，再跑一次。' -ForegroundColor Yellow
        exit 1
    }

    $probe = ($index.Keys | Sort-Object)[0]
    $targetPid = Get-SessionPidForProcess -ProcessName $probe -Index $index
    Write-Host ('测试对象：{0}（pid {1}）' -f $probe, $targetPid)
    $before = [PerAppAudio]::GetProcessDevice([uint32]$targetPid)
    Write-Host ('当前该应用的独立输出：{0}' -f (Format-DeviceId $before))
    Write-Host ('系统全局默认设备  ：{0}' -f (Format-DeviceId ([WinAudio]::GetDefaultRenderId())))

    $candidate = $null
    foreach ($m in ([WinAudio]::GetMonitors() | Sort-Object DeviceName)) {
        $entry = Get-MappingEntry $m.DeviceName
        if (-not $entry) { continue }
        $want = [string]$entry['device']
        if ([string]::IsNullOrWhiteSpace($want) -or $want -eq 'default') { continue }
        $dev = Resolve-OutputDevice $want
        if ($dev) { $candidate = $dev; break }
    }
    if (-not $candidate) {
        Write-Host 'config.json 里没有可用的目标设备（都是 default）。' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host ('1) 切到「{0}」' -f $candidate.FriendlyName)
    $hr1 = [PerAppAudio]::SetProcessDevice([uint32]$targetPid, $candidate.Id)
    Start-Sleep -Milliseconds 800
    Write-Host ('   HRESULT = 0x{0:X8} {1}' -f $hr1, (Explain-Hr $hr1))
    Write-Host ('   读回    = {0}' -f (Format-DeviceId ([PerAppAudio]::GetProcessDevice([uint32]$targetPid))))
    Write-Host ('   系统默认 = {0}' -f (Format-DeviceId ([WinAudio]::GetDefaultRenderId())))

    Write-Host ''
    Write-Host '2) 还原'
    $hr2 = [PerAppAudio]::SetProcessDevice([uint32]$targetPid, $before)
    Start-Sleep -Milliseconds 800
    Write-Host ('   HRESULT = 0x{0:X8} {1}' -f $hr2, (Explain-Hr $hr2))
    Write-Host ('   读回    = {0}' -f (Format-DeviceId ([PerAppAudio]::GetProcessDevice([uint32]$targetPid))))
    Write-Host ('   系统默认 = {0}' -f (Format-DeviceId ([WinAudio]::GetDefaultRenderId())))

    Write-Host ''
    if ($hr1 -eq 0 -and $hr2 -eq 0) {
        Write-Host '结果：成功。按应用切换在这个环境里可以正常工作。' -ForegroundColor Green
    } else {
        Write-Host ('结果：失败。HRESULT 见上；LastError = {0}' -f [PerAppAudio]::LastError) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- startup entry
function Get-StartupFolder { [Environment]::GetFolderPath('Startup') }

function Get-StartupVbsPath {
    param([string]$Folder)
    if (-not $Folder) { $Folder = Get-StartupFolder }
    return (Join-Path $Folder 'MonitorAudioSwitcher.vbs')
}

function Test-StartupInstalled {
    param([string]$Folder)
    return (Test-Path -LiteralPath (Get-StartupVbsPath -Folder $Folder))
}

function Install-Startup {
    param([string]$Folder)
    if (-not $Folder) { $Folder = Get-StartupFolder }
    try {
        if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    } catch {
        Write-Log ("创建启动文件夹失败：{0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
    $target = Get-StartupVbsPath -Folder $Folder
    $vbs = @"
' Auto-generated by MonitorAudioSwitcher.ps1 -InstallStartup
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
base = "$ScriptDir"
If Not fso.FileExists(base & "\MonitorAudioSwitcher.ps1") Then
    base = fso.GetParentFolderName(WScript.ScriptFullName)
End If
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\MonitorAudioSwitcher.ps1""", 0, False
"@
    try {
        Set-Content -LiteralPath $target -Value $vbs -Encoding Default
    } catch {
        Write-Log ("写入开机启动失败：{0}（可能是安全软件拦截或权限不足）" -f $_.Exception.Message) 'ERROR'
        return $false
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Log '写入开机启动后找不到那个文件，多半是被安全软件拦下了。' 'ERROR'
        return $false
    }
    Write-Log ("已加入开机启动：{0}" -f $target)
    return $true
}

function Uninstall-Startup {
    param([string]$Folder)
    $target = Get-StartupVbsPath -Folder $Folder
    if (Test-Path -LiteralPath $target) {
        try {
            Remove-Item -LiteralPath $target -Force
        } catch {
            Write-Log ("移除开机启动失败：{0}" -f $_.Exception.Message) 'ERROR'
            return $false
        }
        Write-Log ("已移除开机启动：{0}" -f $target)
    } else {
        Write-Log '本来就没有开机启动项。'
    }
    return $true
}

# ---------------------------------------------------------------- dispatch
if ($InstallStartup) {
    if (Install-Startup -Folder $StartupFolder) { exit 0 } else { exit 1 }
}
if ($UninstallStartup) {
    if (Uninstall-Startup -Folder $StartupFolder) { exit 0 } else { exit 1 }
}
if ($Status) { Show-Status; exit 0 }
if ($SelfTest) { Invoke-SelfTest; exit 0 }

if ($Simulate -ne '') {
    $script:WarnedAt = @{}
    if (-not (Get-MappingEntry $Simulate)) {
        Write-Log ("config.json 里没有 {0} 这一项，可用 -Status 查看有哪些显示器。" -f $Simulate) 'ERROR'
        exit 1
    }
    $index = Get-SessionIndex
    $targetProcess = ''
    if ($Process -ne '') {
        $targetProcess = $Process.ToLower()
        if (@(Get-SessionsForProcess -ProcessName $targetProcess -Index $index).Count -eq 0) {
            Write-Log ("「{0}」现在没有音频会话，先让它在后台出点声再测。" -f $targetProcess) 'ERROR'
            exit 1
        }
    } else {
        $fgWin = [WinAudio]::ForegroundWindow()
        if ($fgWin -ne [IntPtr]::Zero) {
            $fgProc = [WinAudio]::ProcessNameOfWindow($fgWin)
            if (@(Get-SessionsForProcess -ProcessName $fgProc -Index $index).Count -gt 0) { $targetProcess = $fgProc.ToLower() }
        }
        if (-not $targetProcess -and $index.Keys.Count -gt 0) {
            $targetProcess = ($index.Keys | Sort-Object)[0]
            Write-Log ("没指定进程，用「{0}」来测（加 -Process 名字 可以指定）。" -f $targetProcess)
        }
    }
    if (-not $targetProcess) {
        Write-Log '现在没有任何应用在出声，先播放点声音再试。' 'ERROR'
        exit 1
    }
    $result = Sync-AppOutput -Display $Simulate -ProcessName $targetProcess -Apply:(-not $DryRun) -Chatty -Index $index
    Write-Log ("模拟结果：{0}" -f $result)
    exit $(if ($result -eq 'ok') { 0 } else { 1 })
}

if ($DryRun) {
    $script:WarnedAt = @{}
    $script:DesiredDisplay = ''
    $script:DesiredProcess = ''
    $script:Applied = $false
    $script:LastAttempt = [datetime]::MinValue
    $script:LastSessionKey = ''
    $script:LastGlobalDefault = ''
    Invoke-Tick -RetrySeconds 0 -Apply:$false
    exit 0
}

Start-Watcher
