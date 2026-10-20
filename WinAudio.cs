using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public class AudioEndpointInfo {
    public string Id;
    public string FriendlyName;
    public string AdapterName;
}

public class MonitorRec {
    public string DeviceName;
    public string Model;
    public int Left, Top, Right, Bottom;
    public bool Primary;
    public int Width { get { return Right - Left; } }
    public int Height { get { return Bottom - Top; } }
}

public class WindowRec {
    public IntPtr Hwnd;
    public uint Pid;
    public string Title;
    public string Monitor;
}

public static class WinAudio {

    // ---------------- Core Audio ----------------
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IPropertyStore props);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        int GetCount(out int count);
        int GetAt(int index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr ptr;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    private static readonly Guid FMT_FriendlyName = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
    private static readonly Guid FMT_DeviceInterface = new Guid("026E516E-B814-414B-83CD-856D6FEF4822");

    private const int eRender = 0;
    private const int DEVICE_STATE_ACTIVE = 1;
    private const int STGM_READ = 0;

    private static IMMDeviceEnumerator Enumerator() {
        return (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
    }

    private static string PropString(IPropertyStore store, Guid fmt, int pid) {
        PROPERTYKEY key = new PROPERTYKEY();
        key.fmtid = fmt;
        key.pid = pid;
        PROPVARIANT v;
        if (store.GetValue(ref key, out v) != 0) return "";
        string s = v.ptr != IntPtr.Zero ? Marshal.PtrToStringUni(v.ptr) : "";
        PropVariantClear(ref v);
        return s;
    }

    private static AudioEndpointInfo ToInfo(IMMDevice dev) {
        AudioEndpointInfo info = new AudioEndpointInfo();
        dev.GetId(out info.Id);
        IPropertyStore store;
        dev.OpenPropertyStore(STGM_READ, out store);
        info.FriendlyName = PropString(store, FMT_FriendlyName, 14);
        info.AdapterName = PropString(store, FMT_DeviceInterface, 2);
        Marshal.ReleaseComObject(store);
        return info;
    }

    public static List<AudioEndpointInfo> GetRenderDevices() {
        List<AudioEndpointInfo> list = new List<AudioEndpointInfo>();
        IMMDeviceEnumerator en = Enumerator();
        IMMDeviceCollection col;
        int hr = en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out col);
        if (hr != 0) {
            Marshal.ReleaseComObject(en);
            throw new Exception("EnumAudioEndpoints failed 0x" + hr.ToString("X8"));
        }
        int count;
        col.GetCount(out count);
        for (int i = 0; i < count; i++) {
            IMMDevice d;
            col.Item(i, out d);
            list.Add(ToInfo(d));
            Marshal.ReleaseComObject(d);
        }
        Marshal.ReleaseComObject(col);
        Marshal.ReleaseComObject(en);
        return list;
    }

    public static string GetDefaultRenderId() {
        IMMDeviceEnumerator en = Enumerator();
        IMMDevice d;
        string id = null;
        if (en.GetDefaultAudioEndpoint(eRender, 0, out d) == 0) {
            d.GetId(out id);
            Marshal.ReleaseComObject(d);
        }
        Marshal.ReleaseComObject(en);
        return id;
    }

    // ---------------- IPolicyConfig ----------------
    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    private class CPolicyConfigClient { }

    [Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig {
        int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool bDefault, out IntPtr format);
        int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool bDefault, out long defaultPeriod, out long minimumPeriod);
        int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, long period);
        int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr mode);
        int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PROPERTYKEY key, out PROPVARIANT value);
        int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PROPERTYKEY key, ref PROPVARIANT value);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
        int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, bool visible);
    }

    public static void SetDefaultRenderDevice(string deviceId) {
        IPolicyConfig policy = (IPolicyConfig)new CPolicyConfigClient();
        try {
            for (int role = 0; role <= 2; role++) {
                int hr = policy.SetDefaultEndpoint(deviceId, role);
                if (hr != 0) throw new Exception("SetDefaultEndpoint(role=" + role + ") failed 0x" + hr.ToString("X8"));
            }
        } finally {
            Marshal.ReleaseComObject(policy);
        }
    }

    // ---------------- monitors ----------------
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX {
        public int cbSize;
        public int rcMonitorLeft, rcMonitorTop, rcMonitorRight, rcMonitorBottom;
        public int rcWorkLeft, rcWorkTop, rcWorkRight, rcWorkBottom;
        public int dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr rect, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE info, uint flags);

    public static List<MonitorRec> GetMonitors() {
        List<MonitorRec> list = new List<MonitorRec>();
        MonitorEnumProc proc = delegate(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data) {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(hMonitor, ref mi)) {
                MonitorRec rec = new MonitorRec();
                rec.DeviceName = mi.szDevice;
                rec.Left = mi.rcMonitorLeft;
                rec.Top = mi.rcMonitorTop;
                rec.Right = mi.rcMonitorRight;
                rec.Bottom = mi.rcMonitorBottom;
                rec.Primary = (mi.dwFlags & 1) != 0;
                rec.Model = MonitorModel(mi.szDevice);
                list.Add(rec);
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
        return list;
    }

    public static string MonitorModel(string displayDeviceName) {
        DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
        dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        if (EnumDisplayDevices(displayDeviceName, 0, ref dd, 1)) return dd.DeviceString;
        return "";
    }

    // ---------------- windows ----------------
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void EnableDpiAwareness() {
        try { SetProcessDPIAware(); } catch { }
    }

    public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }

    public static string MonitorOfWindowHandle(IntPtr hwnd) {
        IntPtr hMon = MonitorFromWindow(hwnd, 2);
        return MonitorName(hMon);
    }

    public static string MonitorAtPoint(int x, int y) {
        POINT p;
        p.x = x;
        p.y = y;
        IntPtr hMon = MonitorFromPoint(p, 2);
        return MonitorName(hMon);
    }

    private static string MonitorName(IntPtr hMon) {
        MONITORINFOEX mi = new MONITORINFOEX();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (GetMonitorInfo(hMon, ref mi)) return mi.szDevice;
        return "";
    }

    public static string WindowCenterMonitor(IntPtr hwnd) {
        if (IsIconic(hwnd)) return MonitorOfWindowHandle(hwnd);
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return MonitorOfWindowHandle(hwnd);
        int cx = (r.Left + r.Right) / 2;
        int cy = (r.Top + r.Bottom) / 2;
        if (cx <= -32000 || cy <= -32000) return MonitorOfWindowHandle(hwnd);
        return MonitorAtPoint(cx, cy);
    }

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    public static string ProcessNameOfWindow(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return "";
        try {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
        } catch {
            return "";
        }
    }

    public static uint ProcessIdOfWindow(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    public static string WindowTitleOf(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(300);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int CountAllWindows() {
        int n = 0;
        EnumWindowsProc proc = delegate(IntPtr hwnd, IntPtr lParam) { n++; return true; };
        EnumWindows(proc, IntPtr.Zero);
        return n;
    }

    public static List<WindowRec> VisibleWindows() {
        List<WindowRec> list = new List<WindowRec>();
        EnumWindowsProc proc = delegate(IntPtr hwnd, IntPtr lParam) {
            if (!IsWindowVisible(hwnd)) return true;
            StringBuilder sb = new StringBuilder(300);
            GetWindowText(hwnd, sb, sb.Capacity);
            if (sb.Length == 0) return true;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            WindowRec r = new WindowRec();
            r.Hwnd = hwnd;
            r.Pid = pid;
            r.Title = sb.ToString();
            r.Monitor = MonitorOfWindowHandle(hwnd);
            list.Add(r);
            return true;
        };
        EnumWindows(proc, IntPtr.Zero);
        return list;
    }

    // ---------------- audio sessions ----------------
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(ref Guid sessionGuid, uint streamFlags, out IntPtr sessionControl);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid sessionGuid, uint streamFlags, out IntPtr audioVolume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
        [PreserveSig] int RegisterSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterSessionNotification(IntPtr notification);
        [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr notification);
        [PreserveSig] int UnregisterDuckNotification(IntPtr notification);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.Interface)] out IAudioSessionControl session);
    }

    [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid grouping);
        [PreserveSig] int SetGroupingParam(ref Guid grouping, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
    }

    [Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid eventContext);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid eventContext);
        [PreserveSig] int GetGroupingParam(out Guid grouping);
        [PreserveSig] int SetGroupingParam(ref Guid grouping, ref Guid eventContext);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint processId);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference(int optOut);
    }

    /// 枚举所有活动播放设备上的音频会话（即「音量合成器」里列出的那些）
    public static List<AudioSessionRec> GetAudioSessions(bool activeOnly) {
        List<AudioSessionRec> list = new List<AudioSessionRec>();
        IMMDeviceEnumerator en = Enumerator();
        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out col) != 0) {
            Marshal.ReleaseComObject(en);
            return list;
        }
        int deviceCount;
        col.GetCount(out deviceCount);
        for (int i = 0; i < deviceCount; i++) {
            IMMDevice dev;
            col.Item(i, out dev);
            AudioEndpointInfo devInfo = ToInfo(dev);
            Guid iid = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
            object mgrObject;
            if (dev.Activate(ref iid, 1, IntPtr.Zero, out mgrObject) == 0) {
                IAudioSessionManager2 mgr = (IAudioSessionManager2)mgrObject;
                IAudioSessionEnumerator sessions;
                if (mgr.GetSessionEnumerator(out sessions) == 0) {
                    int count;
                    sessions.GetCount(out count);
                    for (int j = 0; j < count; j++) {
                        IAudioSessionControl control;
                        if (sessions.GetSession(j, out control) != 0 || control == null) continue;
                        AudioSessionRec rec = new AudioSessionRec();
                        rec.DeviceId = devInfo.Id;
                        rec.DeviceName = devInfo.FriendlyName;
                        int state;
                        control.GetState(out state);
                        rec.State = state;
                        IAudioSessionControl2 c2 = control as IAudioSessionControl2;
                        if (c2 != null) {
                            uint pid;
                            if (c2.GetProcessId(out pid) == 0) {
                                rec.Pid = pid;
                                try {
                                    rec.ProcessName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
                                } catch {
                                    rec.ProcessName = "";
                                }
                            }
                            rec.IsSystemSounds = c2.IsSystemSoundsSession() == 0;
                            string sid;
                            if (c2.GetSessionIdentifier(out sid) == 0) rec.SessionIdentifier = sid;
                        }
                        if (activeOnly && rec.State != 1) continue;
                        list.Add(rec);
                    }
                    Marshal.ReleaseComObject(sessions);
                }
                Marshal.ReleaseComObject(mgr);
            }
            Marshal.ReleaseComObject(dev);
        }
        Marshal.ReleaseComObject(col);
        Marshal.ReleaseComObject(en);
        return list;
    }

    /// 在给定的一组进程名中，找出当前拥有音频会话（优先正在发声的）进程 id；找不到返回 0
    public static uint FindAudioSessionPid(string[] processNames) {
        List<AudioSessionRec> sessions = GetAudioSessions(false);
        uint fallback = 0;
        foreach (AudioSessionRec s in sessions) {
            if (s.Pid == 0 || string.IsNullOrEmpty(s.ProcessName)) continue;
            bool match = false;
            foreach (string n in processNames) {
                if (string.Equals(n, s.ProcessName, StringComparison.OrdinalIgnoreCase)) { match = true; break; }
            }
            if (!match) continue;
            if (s.State == 1) return s.Pid;
            if (fallback == 0) fallback = s.Pid;
        }
        return fallback;
    }
}

public class AudioSessionRec {
    public uint Pid;
    public string ProcessName;
    public int State;              // 0=Inactive, 1=Active, 2=Expired
    public bool IsSystemSounds;
    public string SessionIdentifier;
    public string DeviceId;
    public string DeviceName;
}

/// 托盘图标：运行时用 GDI+ 画出来，不需要外部图标文件
public static class TrayIconFactory {

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private static Color ParseColor(string hex) {
        Color fallback = Color.FromArgb(0x2F, 0x6F, 0xEB);
        if (string.IsNullOrWhiteSpace(hex)) return fallback;
        string s = hex.Trim().TrimStart('#');
        if (s.Length == 3) s = new string(new char[] { s[0], s[0], s[1], s[1], s[2], s[2] });
        if (s.Length != 6) return fallback;
        try {
            int v = Convert.ToInt32(s, 16);
            return Color.FromArgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
        } catch {
            return fallback;
        }
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius) {
        GraphicsPath p = new GraphicsPath();
        float d = radius * 2f;
        if (d <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// style: speaker | screens | screenwave
    public static Bitmap Draw(string style, string colorHex, int size) {
        if (size < 8) size = 8;
        Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);

            float u = size;
            float pad = u * 0.04f;
            using (GraphicsPath bg = RoundedRect(new RectangleF(pad, pad, u - pad * 2f, u - pad * 2f), u * 0.22f))
            using (SolidBrush bgBrush = new SolidBrush(ParseColor(colorHex))) {
                g.FillPath(bgBrush, bg);
            }

            Color fg = Color.White;
            using (SolidBrush fgBrush = new SolidBrush(fg))
            using (Pen fgPen = new Pen(fg, Math.Max(1.1f, u * 0.085f))) {
                fgPen.StartCap = LineCap.Round;
                fgPen.EndCap = LineCap.Round;
                fgPen.LineJoin = LineJoin.Round;

                if (style == "screens") {
                    float w = u * 0.30f, h = u * 0.34f, y = u * 0.33f;
                    using (Pen p = new Pen(fg, Math.Max(1f, u * 0.075f))) {
                        p.Alignment = PenAlignment.Inset;
                        p.LineJoin = LineJoin.Round;
                        using (GraphicsPath r1 = RoundedRect(new RectangleF(u * 0.13f, y, w, h), u * 0.05f))
                            g.DrawPath(p, r1);
                    }
                    using (GraphicsPath r2 = RoundedRect(new RectangleF(u * 0.57f, y, w, h), u * 0.05f))
                        g.FillPath(fgBrush, r2);

                } else if (style == "screenwave") {
                    float y = u * 0.24f, w = u * 0.46f, h = u * 0.33f;
                    using (Pen p = new Pen(fg, Math.Max(1f, u * 0.07f))) {
                        p.Alignment = PenAlignment.Inset;
                        p.LineJoin = LineJoin.Round;
                        using (GraphicsPath scr = RoundedRect(new RectangleF(u * 0.13f, y, w, h), u * 0.05f))
                            g.DrawPath(p, scr);
                    }
                    using (Pen p = new Pen(fg, Math.Max(1f, u * 0.07f))) {
                        p.StartCap = LineCap.Round;
                        p.EndCap = LineCap.Round;
                        g.DrawLine(p, u * 0.36f, u * 0.57f, u * 0.36f, u * 0.68f);
                        g.DrawLine(p, u * 0.26f, u * 0.71f, u * 0.46f, u * 0.71f);
                    }
                    using (Pen p = new Pen(fg, Math.Max(1f, u * 0.075f))) {
                        p.StartCap = LineCap.Round;
                        p.EndCap = LineCap.Round;
                        g.DrawArc(p, u * 0.52f, u * 0.31f, u * 0.32f, u * 0.32f, -55f, 110f);
                    }

                } else {
                    using (GraphicsPath spk = new GraphicsPath()) {
                        spk.AddRectangle(new RectangleF(u * 0.21f, u * 0.40f, u * 0.13f, u * 0.20f));
                        spk.AddPolygon(new PointF[] {
                            new PointF(u * 0.32f, u * 0.40f),
                            new PointF(u * 0.50f, u * 0.22f),
                            new PointF(u * 0.50f, u * 0.78f),
                            new PointF(u * 0.32f, u * 0.60f)
                        });
                        g.FillPath(fgBrush, spk);
                    }
                    float cx = u * 0.50f, cy = u * 0.50f;
                    // 小尺寸下两条波纹会糊在一起，只画一条
                    float[] radii = size <= 20
                        ? new float[] { u * 0.22f }
                        : new float[] { u * 0.14f, u * 0.27f };
                    foreach (float r in radii) {
                        if (cx + r + fgPen.Width / 2f > u * 0.99f) continue;
                        g.DrawArc(fgPen, cx - r, cy - r, r * 2f, r * 2f, -55f, 110f);
                    }
                }
            }
        }
        return bmp;
    }

    public static Icon CreateIcon(string style, string colorHex, int size) {
        using (Bitmap bmp = Draw(style, colorHex, size)) {
            IntPtr h = bmp.GetHicon();
            try {
                using (Icon tmp = Icon.FromHandle(h)) {
                    return (Icon)tmp.Clone();
                }
            } finally {
                DestroyIcon(h);
            }
        }
    }
}

/// 按应用（进程）设置播放设备，对应 Windows 11「音量合成器」里每个应用自己的“输出设备”。
/// 接口来自 Windows.Media.Internal.AudioPolicyConfig 的激活工厂（WinRT），
/// 与 EarTrumpet 使用的方式一致：Win11 21H2+ 与更早的系统用不同 IID。
public static class PerAppAudio {

    private const string CLASS_ID = "Windows.Media.Internal.AudioPolicyConfig";
    private const string MMDEVAPI_TOKEN = @"\\?\SWD#MMDEVAPI#";
    private const string DEVINTERFACE_AUDIO_RENDER = "#{e6327cad-dcec-4949-ae8a-991e976a79d2}";

    private const int eRender = 0;
    private const int roleConsole = 0;
    private const int roleMultimedia = 1;
    private const int roleConsoleMultimedia = 3;

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern void RoGetActivationFactory(
        [MarshalAs(UnmanagedType.HString)] string activatableClassId,
        [In] ref Guid iid,
        [Out, MarshalAs(UnmanagedType.IInspectable)] out Object factory);

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern void WindowsCreateString(
        [MarshalAs(UnmanagedType.LPWStr)] string src,
        [In] uint length,
        [Out] out IntPtr hstring);

    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr hstring);

    [Guid("ab3d4648-e242-459f-b02f-541c70306324")]
    [InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
    private interface IAudioPolicyConfigFactory21H2 {
        int __incomplete__add_CtxVolumeChange();
        int __incomplete__remove_CtxVolumeChanged();
        int __incomplete__add_RingerVibrateStateChanged();
        int __incomplete__remove_RingerVibrateStateChange();
        int __incomplete__SetVolumeGroupGainForId();
        int __incomplete__GetVolumeGroupGainForId();
        int __incomplete__GetActiveVolumeGroupForEndpointId();
        int __incomplete__GetVolumeGroupsForEndpoint();
        int __incomplete__GetCurrentVolumeContext();
        int __incomplete__SetVolumeGroupMuteForId();
        int __incomplete__GetVolumeGroupMuteForId();
        int __incomplete__SetRingerVibrateState();
        int __incomplete__GetRingerVibrateState();
        int __incomplete__SetPreferredChatApplication();
        int __incomplete__ResetPreferredChatApplication();
        int __incomplete__GetPreferredChatApplication();
        int __incomplete__GetCurrentChatApplications();
        int __incomplete__add_ChatContextChanged();
        int __incomplete__remove_ChatContextChanged();
        [PreserveSig] int SetPersistedDefaultAudioEndpoint(uint processId, int flow, int role, IntPtr deviceId);
        [PreserveSig] int GetPersistedDefaultAudioEndpoint(uint processId, int flow, int role, [Out, MarshalAs(UnmanagedType.HString)] out string deviceId);
        [PreserveSig] int ClearAllPersistedApplicationDefaultEndpoints();
    }

    [Guid("2a59116d-6c4f-45e0-a74f-707e3fef9258")]
    [InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
    private interface IAudioPolicyConfigFactoryDownlevel {
        int __incomplete__add_CtxVolumeChange();
        int __incomplete__remove_CtxVolumeChanged();
        int __incomplete__add_RingerVibrateStateChanged();
        int __incomplete__remove_RingerVibrateStateChange();
        int __incomplete__SetVolumeGroupGainForId();
        int __incomplete__GetVolumeGroupGainForId();
        int __incomplete__GetActiveVolumeGroupForEndpointId();
        int __incomplete__GetVolumeGroupsForEndpoint();
        int __incomplete__GetCurrentVolumeContext();
        int __incomplete__SetVolumeGroupMuteForId();
        int __incomplete__GetVolumeGroupMuteForId();
        int __incomplete__SetRingerVibrateState();
        int __incomplete__GetRingerVibrateState();
        int __incomplete__SetPreferredChatApplication();
        int __incomplete__ResetPreferredChatApplication();
        int __incomplete__GetPreferredChatApplication();
        int __incomplete__GetCurrentChatApplications();
        int __incomplete__add_ChatContextChanged();
        int __incomplete__remove_ChatContextChanged();
        [PreserveSig] int SetPersistedDefaultAudioEndpoint(uint processId, int flow, int role, IntPtr deviceId);
        [PreserveSig] int GetPersistedDefaultAudioEndpoint(uint processId, int flow, int role, [Out, MarshalAs(UnmanagedType.HString)] out string deviceId);
        [PreserveSig] int ClearAllPersistedApplicationDefaultEndpoints();
    }

    private static object _factory;
    private static int _factoryVariant = -1;

    /// variant: 0=auto, 1=21H2, 2=downlevel
    private static object Factory(int variant) {
        if (_factory != null && _factoryVariant == variant) return _factory;
        bool is21H2 = variant == 0 ? Environment.OSVersion.Version.Build >= 22000 : variant == 1;
        object f;
        if (is21H2) {
            Guid iid = new Guid("ab3d4648-e242-459f-b02f-541c70306324");
            RoGetActivationFactory(CLASS_ID, ref iid, out f);
            _factory = (IAudioPolicyConfigFactory21H2)f;
        } else {
            Guid iid = new Guid("2a59116d-6c4f-45e0-a74f-707e3fef9258");
            RoGetActivationFactory(CLASS_ID, ref iid, out f);
            _factory = (IAudioPolicyConfigFactoryDownlevel)f;
        }
        _factoryVariant = variant;
        return _factory;
    }

    public static bool IsSupported() {
        try { Factory(0); return true; } catch { return false; }
    }

    public static string LastError = "";
    public static string LastVariant = "";

    /// 调试用：直接传 HSTRING 内容，不做任何包装；content 为 null 表示传 IntPtr.Zero
    public static int SetRaw(uint processId, string content, int role, int variant = 0) {
        LastError = "";
        LastVariant = "";
        IntPtr hstring = IntPtr.Zero;
        try {
            if (content != null) {
                WindowsCreateString(content, (uint)content.Length, out hstring);
            }
            object f = Factory(variant);
            IAudioPolicyConfigFactory21H2 f21 = f as IAudioPolicyConfigFactory21H2;
            if (f21 != null) {
                LastVariant = "21H2";
                return f21.SetPersistedDefaultAudioEndpoint(processId, eRender, role, hstring);
            }
            IAudioPolicyConfigFactoryDownlevel fd = (IAudioPolicyConfigFactoryDownlevel)f;
            LastVariant = "downlevel";
            return fd.SetPersistedDefaultAudioEndpoint(processId, eRender, role, hstring);
        } catch (Exception ex) {
            LastError = ex.Message;
            return unchecked((int)0x80004005);
        } finally {
            if (hstring != IntPtr.Zero) WindowsDeleteString(hstring);
        }
    }

    /// 调试用：读回原始字符串和 HRESULT
    public static int GetRaw(uint processId, int role, out string raw, int variant = 0) {
        LastError = "";
        LastVariant = "";
        raw = null;
        try {
            object f = Factory(variant);
            IAudioPolicyConfigFactory21H2 f21 = f as IAudioPolicyConfigFactory21H2;
            if (f21 != null) {
                LastVariant = "21H2";
                return f21.GetPersistedDefaultAudioEndpoint(processId, eRender, role, out raw);
            }
            IAudioPolicyConfigFactoryDownlevel fd = (IAudioPolicyConfigFactoryDownlevel)f;
            LastVariant = "downlevel";
            return fd.GetPersistedDefaultAudioEndpoint(processId, eRender, role, out raw);
        } catch (Exception ex) {
            LastError = ex.Message;
            return unchecked((int)0x80004005);
        }
    }

    public static string WrapDeviceId(string mmDeviceId) {
        if (string.IsNullOrEmpty(mmDeviceId)) return null;
        return MMDEVAPI_TOKEN + mmDeviceId + DEVINTERFACE_AUDIO_RENDER;
    }

    /// mmDeviceId 传 null 或空字符串 = 清除该应用的自定义，回到跟随系统默认
    public static int SetProcessDevice(uint processId, string mmDeviceId) {
        LastError = "";
        IntPtr hstring = IntPtr.Zero;
        try {
            if (!string.IsNullOrEmpty(mmDeviceId)) {
                string full = MMDEVAPI_TOKEN + mmDeviceId + DEVINTERFACE_AUDIO_RENDER;
                WindowsCreateString(full, (uint)full.Length, out hstring);
            }
            object f = Factory(0);
            int hr = 0;
            IAudioPolicyConfigFactory21H2 f21 = f as IAudioPolicyConfigFactory21H2;
            if (f21 != null) {
                int r1 = f21.SetPersistedDefaultAudioEndpoint(processId, eRender, roleMultimedia, hstring);
                int r2 = f21.SetPersistedDefaultAudioEndpoint(processId, eRender, roleConsole, hstring);
                hr = r1 != 0 ? r1 : r2;
            } else {
                IAudioPolicyConfigFactoryDownlevel fd = (IAudioPolicyConfigFactoryDownlevel)f;
                int r1 = fd.SetPersistedDefaultAudioEndpoint(processId, eRender, roleMultimedia, hstring);
                int r2 = fd.SetPersistedDefaultAudioEndpoint(processId, eRender, roleConsole, hstring);
                hr = r1 != 0 ? r1 : r2;
            }
            return hr;
        } catch (Exception ex) {
            LastError = ex.Message;
            return unchecked((int)0x80004005);
        } finally {
            if (hstring != IntPtr.Zero) WindowsDeleteString(hstring);
        }
    }

    /// 返回该应用当前的独立播放设备 id（未设置过则为空字符串）
    public static string GetProcessDevice(uint processId) {
        string raw;
        int hr = GetRaw(processId, roleConsoleMultimedia, out raw, 0);
        if (hr != 0) {
            LastError = "GetPersistedDefaultAudioEndpoint hr=0x" + hr.ToString("X8");
            return null;
        }
        if (string.IsNullOrEmpty(raw)) return "";
        string s = raw;
        if (s.StartsWith(MMDEVAPI_TOKEN)) s = s.Substring(MMDEVAPI_TOKEN.Length);
        if (s.EndsWith(DEVINTERFACE_AUDIO_RENDER)) s = s.Substring(0, s.Length - DEVINTERFACE_AUDIO_RENDER.Length);
        return s;
    }
}
