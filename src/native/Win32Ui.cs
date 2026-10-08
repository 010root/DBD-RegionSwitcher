using System;
using System.Runtime.InteropServices;
public static class DarkUi {
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    public static void TitleBar(IntPtr hwnd) {
        int on = 1;
        // DWMWA_USE_IMMERSIVE_DARK_MODE
        if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
        // Windows 11: title bar the same dark as the window, bright title text (the default is a dim gray),
        // no colored outline (DWMWA_COLOR_NONE). COLORREF = 0x00BBGGRR. Ignored on Windows 10.
        int caption = 0x00201C1C, text = 0x00F0F0F0, border = unchecked((int)0xFFFFFFFE);
        DwmSetWindowAttribute(hwnd, 35, ref caption, 4);
        DwmSetWindowAttribute(hwnd, 36, ref text, 4);
        DwmSetWindowAttribute(hwnd, 34, ref border, 4);
    }
    public static void Theme(IntPtr hwnd, string name) { if (hwnd != IntPtr.Zero) SetWindowTheme(hwnd, name, null); }
    // LVM_GETHEADER
    public static IntPtr ListViewHeader(IntPtr listView) {
        return SendMessage(listView, 0x101F, IntPtr.Zero, IntPtr.Zero);
    }
    // Pause / resume painting while a text box is rewritten (WM_SETREDRAW): no blinking on frequent updates.
    public static void Redraw(IntPtr hwnd, bool on) {
        if (hwnd != IntPtr.Zero) SendMessage(hwnd, 0x000B, (IntPtr)(on ? 1 : 0), IntPtr.Zero);
    }
}
public static class WinHelp {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")]
    static extern bool BringWindowToTop(IntPtr hwnd);
    // Windows only lets the program the user is using hand out focus. A window opened after a UAC prompt often isn't
    // allowed to take it, so it opens behind. Sharing input with the current foreground thread for a moment lets it.
    public static bool Focus(IntPtr hwnd) {
        IntPtr fg = GetForegroundWindow();
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero), me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        try { BringWindowToTop(hwnd); ShowWindow(hwnd, 5); SetForegroundWindow(hwnd); }   // SW_SHOW
        finally { if (attached) AttachThreadInput(me, fgThread, false); }
        return GetForegroundWindow() == hwnd;
    }
    public static bool IsForeground(IntPtr hwnd) { return GetForegroundWindow() == hwnd; }
    // Taskbar button flashes until the window is brought to the front (FLASHW_TRAY | FLASHW_TIMERNOFG).
    [StructLayout(LayoutKind.Sequential)]
    struct FlashInfo { public uint Size; public IntPtr Hwnd; public uint Flags, Count, Timeout; }
    [DllImport("user32.dll")]
    static extern bool FlashWindowEx(ref FlashInfo fi);
    public static void Flash(IntPtr hwnd) {
        FlashInfo fi = new FlashInfo();
        fi.Size = (uint)Marshal.SizeOf(typeof(FlashInfo));
        fi.Hwnd = hwnd;
        fi.Flags = 2 | 12;
        FlashWindowEx(ref fi);
    }
    // A tray notification with the tool's own picture (NIIF_USER | NIIF_LARGE_ICON); WinForms only offers Windows' blue
    // info icon. hwnd/id are the NotifyIcon's own, so a click still reaches its BalloonTipClicked.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NotifyData {
        public int Size;
        public IntPtr Hwnd;
        public int Id, Flags, CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
        public int State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public int Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public int InfoFlags;
        public Guid Item;
        public IntPtr BalloonIcon;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern bool Shell_NotifyIcon(int msg, ref NotifyData d);
    public static bool Balloon(IntPtr hwnd, int id, string title, string text, IntPtr icon) {
        // NIF_INFO
        NotifyData d = new NotifyData();
        d.Size = Marshal.SizeOf(typeof(NotifyData));
        d.Hwnd = hwnd;
        d.Id = id;
        d.Flags = 0x10;
        d.InfoTitle = title.Length > 63 ? title.Substring(0, 63) : title;
        d.Info = text.Length > 255 ? text.Substring(0, 255) : text;
        d.InfoFlags = 0x4 | 0x20;
        d.BalloonIcon = icon;
        return Shell_NotifyIcon(1, ref d);   // NIM_MODIFY
    }
    public static bool ActivateHandle(IntPtr h) {
        if (h == IntPtr.Zero) return false;
        ShowWindow(h, 9);
        SetForegroundWindow(h);
        return true;
    }
    public static bool Activate(string title) {
        IntPtr h = FindWindow(null, title);
        if (h == IntPtr.Zero) return false;
        ShowWindow(h, 9);          // SW_RESTORE
        SetForegroundWindow(h);    // Windows may refuse focus (another app in front); the window exists either way
        return true;
    }
}
// Display scale (DPI) per screen: the .exe is per-monitor DPI aware (its manifest), so each window is drawn at the
// scale of the screen it's on. 96 = 100 %. (Windows 10 1607+; older: the system scale. A process that isn't
// per-monitor aware - powershell.exe running the .ps1 - gets the system scale or 96 here.)
public static class DpiInfo {
    [DllImport("user32.dll")]
    static extern uint GetDpiForSystem();
    [DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("shcore.dll")]
    static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [StructLayout(LayoutKind.Sequential)]
    struct Pt { public int X, Y; }
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(Pt p, int flags);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out Pt p);
    // what fonts in points are drawn at
    public static int SystemDpi() { try { return (int)GetDpiForSystem(); } catch { return 96; } }
    public static int ForWindow(IntPtr h) {
        try { int d = (int)GetDpiForWindow(h); return d > 0 ? d : SystemDpi(); } catch { return SystemDpi(); }
    }
    public static int ForPoint(int x, int y) {
        try {
            Pt p;
            p.X = x;
            p.Y = y;
            uint dx, dy;
            if (GetDpiForMonitor(MonitorFromPoint(p, 2), 0, out dx, out dy) == 0 && dx > 0) return (int)dx;
        } catch { }
        return SystemDpi();
    }
    public static int AtCursor() { Pt p; return GetCursorPos(out p) ? ForPoint(p.X, p.Y) : SystemDpi(); }
}
public class DpiChangeArgs : EventArgs { public int Dpi; public System.Drawing.Rectangle Suggested; }
// A window moved to a screen with another scale: Windows sends WM_DPICHANGED with the new DPI and a suggested size
// (WinForms in .NET Framework does nothing with it without a config file). Raised to the script, which rescales.
// Also says whether the window is being moved or resized with the mouse right now (Sizing; since when: SizingSince).
public class DpiWatcher : System.Windows.Forms.NativeWindow {
    public event EventHandler<DpiChangeArgs> Changed;
    public bool Sizing;
    public DateTime SizingSince;
    [StructLayout(LayoutKind.Sequential)]
    struct Rc { public int L, T, R, B; }
    public DpiWatcher(System.Windows.Forms.Form f) {
        f.HandleCreated += delegate { AssignHandle(f.Handle); };
        f.HandleDestroyed += delegate { ReleaseHandle(); };
        if (f.IsHandleCreated) AssignHandle(f.Handle);
    }
    protected override void WndProc(ref System.Windows.Forms.Message m) {
        if (m.Msg == 0x0231) { Sizing = true; SizingSince = DateTime.UtcNow; }   // WM_ENTERSIZEMOVE
        else if (m.Msg == 0x0232) Sizing = false;                               // WM_EXITSIZEMOVE
        if (m.Msg == 0x02E0 && Changed != null) {   // WM_DPICHANGED
            Rc r = (Rc)Marshal.PtrToStructure(m.LParam, typeof(Rc));
            DpiChangeArgs a = new DpiChangeArgs();
            a.Dpi = (int)((long)m.WParam & 0xFFFF);
            a.Suggested = System.Drawing.Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
            Changed(this, a);
            m.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref m);
    }
}