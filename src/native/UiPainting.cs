using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DarkMenuColors : ProfessionalColorTable {
    static readonly Color Back = Color.FromArgb(40, 40, 46), Edge = Color.FromArgb(80, 80, 90),
        Hover = Color.FromArgb(46, 92, 60);
    public override Color ToolStripDropDownBackground { get { return Back; } }
    public override Color ImageMarginGradientBegin { get { return Back; } }
    public override Color ImageMarginGradientMiddle { get { return Back; } }
    public override Color ImageMarginGradientEnd { get { return Back; } }
    public override Color MenuBorder { get { return Edge; } }
    public override Color MenuItemBorder { get { return Hover; } }
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
    public override Color MenuItemPressedGradientBegin { get { return Hover; } }
    public override Color MenuItemPressedGradientEnd { get { return Hover; } }
    public override Color ButtonSelectedHighlight { get { return Hover; } }
    public override Color ButtonSelectedBorder { get { return Hover; } }
    public override Color SeparatorDark { get { return Edge; } }
    public override Color SeparatorLight { get { return Back; } }
    public override Color CheckBackground { get { return Back; } }
    public override Color CheckSelectedBackground { get { return Hover; } }
    public override Color CheckPressedBackground { get { return Hover; } }
}
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    public DarkMenuRenderer() : base(new DarkMenuColors()) { RoundedEdges = false; }
    // hover = dark green, never system blue
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Rectangle r = new Rectangle(2, 0, e.Item.Width - 4, e.Item.Height);
        using (SolidBrush b = new SolidBrush((e.Item.Selected && e.Item.Enabled) ? Color.FromArgb(46, 92, 60) :
            Color.FromArgb(40, 40, 46)))
            e.Graphics.FillRectangle(b, r);
    }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        using (SolidBrush b = new SolidBrush(Color.FromArgb(40, 40, 46))) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) {
        using (SolidBrush b = new SolidBrush(Color.FromArgb(40, 40, 46))) e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(235, 235, 240) : Color.FromArgb(120, 120, 128);
        base.OnRenderItemText(e);
    }
    // submenu arrow: light, not the default dark gray
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = Color.FromArgb(200, 200, 208);
        base.OnRenderArrow(e);
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {   // light-green tick
        Rectangle r = e.ImageRectangle;
        if (r.Width == 0) r = new Rectangle(4, 2, e.Item.Height - 4, e.Item.Height - 4);
        Tick.Draw(e.Graphics, r, Color.FromArgb(140, 225, 150), 2f);
    }
}
// The tick of the menus and the checkboxes, inside the square r.
static class Tick {
    public static void Draw(Graphics g, Rectangle r, Color c, float width) {
        Point[] pts = {
            new Point(r.Left + r.Width / 5, r.Top + r.Height / 2),
            new Point(r.Left + r.Width * 2 / 5, r.Bottom - r.Height / 4),
            new Point(r.Right - r.Width / 6, r.Top + r.Height / 4) };
        SmoothingMode old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(c, width)) g.DrawLines(p, pts);
        g.SmoothingMode = old;
    }
}
// The list's background erase clears only what no row covers (rows cover themselves), so rows never flash blank.
// Space the list grows into is asked to be repainted, and a repaint during FitColumns is left for the next one.
public class ListEraseFix : NativeWindow {
    readonly ListView _lv;
    readonly DarkList _dl;
    Size _last;
    [DllImport("user32.dll")]
    static extern int FillRect(IntPtr dc, ref DarkList.RECT r, IntPtr brush);
    [DllImport("gdi32.dll")]
    static extern int ExcludeClipRect(IntPtr dc, int l, int t, int r, int b);
    [DllImport("gdi32.dll")]
    static extern int SaveDC(IntPtr dc);
    [DllImport("gdi32.dll")]
    static extern bool RestoreDC(IntPtr dc, int saved);
    [DllImport("gdi32.dll")]
    static extern IntPtr CreateSolidBrush(int color);
    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr o);
    public ListEraseFix(ListView lv, DarkList dl) {
        _lv = lv;
        _dl = dl;
        lv.HandleCreated += delegate { AssignHandle(lv.Handle); };
        lv.HandleDestroyed += delegate { ReleaseHandle(); };
        if (lv.IsHandleCreated) AssignHandle(lv.Handle);
        lv.ClientSizeChanged += delegate {
            Size n = lv.ClientSize;
            if (lv.IsHandleCreated) {
                if (n.Height > _last.Height)
                    lv.Invalidate(new Rectangle(0, Math.Max(0, _last.Height - 1), n.Width,
                        n.Height - _last.Height + 1));
                if (n.Width > _last.Width)
                    lv.Invalidate(new Rectangle(Math.Max(0, _last.Width - 1), 0, n.Width - _last.Width + 1, n.Height));
            }
            _last = n;
        };
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x000F && _dl != null && _dl.Fitting) return;   // WM_PAINT mid-fit: left for the next paint
        if (m.Msg == 0x0014 && m.WParam != IntPtr.Zero) {   // WM_ERASEBKGND
            Rectangle c = _lv.ClientRectangle;
            int right = 0;
            foreach (ColumnHeader h in _lv.Columns) right += h.Width;
            // Windows' own drawing: GDI+ straight on a window makes Windows read its pixels back first
            int saved = SaveDC(m.WParam);
            ListViewItem top = _lv.TopItem;
            // the rows on screen: first visible row to the last row
            if (top != null) {
                int y0 = _lv.GetItemRect(top.Index).Top, y1 = _lv.GetItemRect(_lv.Items.Count - 1).Bottom;
                ExcludeClipRect(m.WParam, 0, y0, right, y1);
            }
            IntPtr br = CreateSolidBrush(ColorTranslator.ToWin32(_lv.BackColor));
            DarkList.RECT r = new DarkList.RECT { L = 0, T = 0, R = c.Width, B = c.Height };
            FillRect(m.WParam, ref r, br);
            DeleteObject(br);
            RestoreDC(m.WParam, saved);
            m.Result = (IntPtr)1;
            return;
        }
        base.WndProc(ref m);
    }
}
// Read-only text boxes with the text cursor hidden: it can be selected and copied, but nothing can be typed.
// The box shows its cursor again after focus, clicks, keys and new text, so it's hidden after every message.
public class NoCaret : NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct GuiInfo {
        public int Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }
    [DllImport("user32.dll")]
    static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    static extern bool HideCaret(IntPtr h);
    public NoCaret(Control c) {
        c.HandleCreated += delegate { AssignHandle(c.Handle); };
        c.HandleDestroyed += delegate { ReleaseHandle(); };
        if (c.IsHandleCreated) AssignHandle(c.Handle);
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (Handle == IntPtr.Zero) return;
        GuiInfo g = new GuiInfo();
        g.Size = Marshal.SizeOf(typeof(GuiInfo));
        // GUI_CARETBLINKING = showing
        if (GetGUIThreadInfo(GetCurrentThreadId(), ref g) && g.Caret == Handle && (g.Flags & 1) != 0) HideCaret(Handle);
    }
}
// The region list's rows and header, drawn here: drawn by the script a cell takes ~0.45 ms, and a resize redraws
// the list many times a second. Each row goes off-screen first, then on screen at once. Pixel sizes x Scale.
public class DarkList {
    internal readonly ListView _lv;
    readonly BufferedGraphicsContext _ctx = new BufferedGraphicsContext();
    readonly HeaderPaint _head;
    readonly RowPaint _rows;
    public int HoverIndex = -1;
    public bool ShowBars = true;
    public float Scale = 1f;
    public Color SelRow, Accent, HeadBack, Grid, BarTrack = Color.FromArgb(56, 56, 64);

    // The column that fills the rest of the width (-1: none), and the row / header heights the script measured.
    public int FillColumn = -1, RowHeight, HeaderHeight;
    bool _fitting;
    public bool Fitting { get { return _fitting; } }   // its own and the header's paints wait meanwhile
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, ref RECT l);
    [DllImport("user32.dll")]
    static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("gdi32.dll")]
    static extern int GetClipBox(IntPtr dc, out RECT r);
    public DarkList(ListView lv, Color selRow, Color accent, Color headBack, Color grid) {
        _lv = lv;
        SelRow = selRow;
        Accent = accent;
        HeadBack = headBack;
        Grid = grid;
        // one off-screen buffer reused for every row (by default only buffers up to 225 x 96 px are kept)
        _ctx.MaximumBuffer = new Size(4096, 512);
        lv.OwnerDraw = true;
        _rows = new RowPaint(this);
        _head = new HeaderPaint(this);
        lv.MouseMove += delegate(object s, MouseEventArgs e) {
            ListViewItem it = _lv.GetItemAt(e.X, e.Y);
            SetHover(it != null ? it.Index : -1);
        };
        lv.MouseLeave += delegate { SetHover(-1); };
        lv.ClientSizeChanged += delegate { FitColumns(); };   // also when only a scrollbar comes or goes
        LayoutEventHandler before = delegate { BeforeLayout(); };
        Control parent = null;
        lv.ParentChanged += delegate {
            if (parent != null) parent.Layout -= before;
            parent = lv.Parent;
            if (parent != null) parent.Layout += before;
        };
    }
    // The columns in screen order (Region, Code, Queue, Ping).
    ColumnHeader[] Ordered() {
        ColumnHeader[] cols = new ColumnHeader[_lv.Columns.Count];
        foreach (ColumnHeader c in _lv.Columns) cols[c.DisplayIndex] = c;
        return cols;
    }
        // The fill column takes the rest. Room for a vertical scrollbar is kept up front, plus 1 px: otherwise a
        // horizontal scrollbar shows up as well.
    public void FitColumns() {
        if (FillColumn < 0 || FillColumn >= _lv.Columns.Count || _fitting) return;
        int cw = _lv.ClientSize.Width;
        if (RowHeight > 0 && cw == _lv.Width && HeaderHeight + _lv.Items.Count * RowHeight > _lv.ClientSize.Height) {
            // SM_CXVSCROLL at this DPI
            int sb = 0;
            try { sb = GetSystemMetricsForDpi(2, (uint)Math.Round(96 * Scale)); } catch { }
            cw -= sb > 0 ? sb : SystemInformation.VerticalScrollBarWidth;
        }
        int w = cw - 1;
        foreach (ColumnHeader c in _lv.Columns) if (c.Index != FillColumn) w -= c.Width;
        if (w <= 60) return;
        ColumnHeader fill = _lv.Columns[FillColumn];
        // A horizontal scrollbar that came up mid-resize stays until a column changes (borderless list: the height it
        // takes is the only difference between Height and ClientSize): one pixel off and back makes the list drop it.
        bool bar = fill.Width == w && _lv.Height - _lv.ClientSize.Height > 2;
        if (fill.Width == w && !bar) return;
        SetFill(fill, w, bar);
    }
        // Narrower: the fill column shrinks first, so the columns never stick out past the list mid-resize.
    void BeforeLayout() {
        Control p = _lv.Parent;
        if (p == null || !_lv.IsHandleCreated || _fitting || _lv.Dock != DockStyle.Fill || FillColumn < 0 ||
            FillColumn >= _lv.Columns.Count)
            return;
        int d = (p.ClientSize.Width - p.Padding.Horizontal) - _lv.Width;
        if (d >= 0) return;
        ColumnHeader fill = _lv.Columns[FillColumn];
        int w = Math.Max(61, fill.Width + d);
        if (w < fill.Width) SetFill(fill, w, false);
    }
    void SetFill(ColumnHeader fill, int w, bool bar) {
        // The list control redraws all of itself for a width change (a resize changes it many times a second): its
        // painting is paused meanwhile, and only what changed is redrawn - the fill column and what's right of it.
        int left = 0;
        foreach (ColumnHeader c in Ordered()) { if (c == fill) break; left += c.Width; }
        _fitting = true;
        bool live = _lv.IsHandleCreated;
        if (live) SendMessage(_lv.Handle, 0x000B, IntPtr.Zero, IntPtr.Zero);   // WM_SETREDRAW off
        try { if (bar) fill.Width = w - 1; fill.Width = w; }
        finally {
            if (live) {
                SendMessage(_lv.Handle, 0x000B, (IntPtr)1, IntPtr.Zero);
                Rectangle cr = _lv.ClientRectangle;
                _lv.Invalidate(bar ? cr : new Rectangle(left, 0, cr.Width - left, cr.Height));
                _head.Invalidate(bar ? 0 : left);
            }
            _fitting = false;
        }
    }
    int Px(double v) { return (int)Math.Round(v * Scale); }
    static int R(double v) { return (int)Math.Round(v); }   // the same rounding as PowerShell's [int] (to even on .5)
    public void SetHover(int i) {
        int old = HoverIndex;
        if (i == old) return;
        HoverIndex = i;
        foreach (int k in new int[] { old, i }) if (k >= 0 && k < _lv.Items.Count) _lv.Invalidate(_lv.Items[k].Bounds);
    }
    // The column header (see HeaderPaint): dark, a grid line right of each column and along the bottom, white titles.
    internal void PaintHeader(IntPtr dc, IntPtr hdr, Rectangle client) {
        if (client.Width <= 0 || client.Height <= 0) return;
        using (BufferedGraphics bg = _ctx.Allocate(dc, client)) {
            Graphics g = bg.Graphics;
            int n = _lv.Columns.Count;
            Rectangle[] tr = new Rectangle[n];
            string[] tx = new string[n];
            using (SolidBrush br = new SolidBrush(HeadBack)) g.FillRectangle(br, client);
            using (Pen p = new Pen(Grid)) {
                for (int i = 0; i < n; i++) {
                    RECT r = new RECT();
                    if (SendMessage(hdr, 0x1207, (IntPtr)i, ref r) == IntPtr.Zero) continue;   // HDM_GETITEMRECT
                    g.DrawLine(p, r.R - 1, 0, r.R - 1, client.Height);
                    tr[i] = new Rectangle(r.L + Px(6), 0, r.R - r.L - Px(8), client.Height);
                    tx[i] = _lv.Columns[i].Text;
                }
                g.DrawLine(p, 0, client.Height - 1, client.Width, client.Height - 1);
            }
            IntPtr bdc = g.GetHdc();
            try {
                for (int i = 0; i < n; i++)
                    if (tx[i] != null && tr[i].Width > 0) GdiText.Draw(bdc, tx[i], _lv.Font, tr[i], Color.White, true);
            }
            finally { g.ReleaseHdc(bdc); }
            bg.Render(dc);
        }
    }
    // One row (see RowPaint): the cells in the part Windows asks to be redrawn (a resize mostly
    // changes the last column).
    internal void PaintRow(IntPtr dc, int index) {
        if (index < 0 || index >= _lv.Items.Count) return;
        RECT br = new RECT { L = 0 };   // LVIR_BOUNDS: the whole row
        if (SendMessage(_lv.Handle, 0x100E, (IntPtr)index, ref br) == IntPtr.Zero) return;   // LVM_GETITEMRECT
        Rectangle b = new Rectangle(br.L, br.T, br.R - br.L, br.B - br.T);
        if (b.Width <= 0 || b.Height <= 0) return;
        RECT clip;
        if (GetClipBox(dc, out clip) <= 1) clip = br;   // no clip: the whole row
        if (clip.B <= b.Top || clip.T >= b.Bottom) return;
        ColumnHeader[] cols = Ordered();
        int n = cols.Length;
        int[] w = new int[n];
        int x = b.X, x0 = int.MaxValue, x1 = int.MinValue;
        for (int i = 0; i < n; i++) {
            w[i] = cols[i].Width;
            if (x < clip.R && x + w[i] > clip.L) {
                x0 = Math.Min(x0, x);
                x1 = Math.Max(x1, x + w[i]);
            }
            x += w[i];
        }
        if (x0 >= x1) return;
        ListViewItem item = _lv.Items[index];
        // Off-screen first (Windows' own memory surface), then on screen at once. The shapes with GDI+, then all the
        // text with Windows' text drawing straight on that surface (through WinForms it cost twice as much).
        using (BufferedGraphics bg = _ctx.Allocate(dc, new Rectangle(x0, b.Y, x1 - x0, b.Height))) {
            CellText[] texts = new CellText[n];
            int nt = 0;
            x = b.X;
            for (int i = 0; i < n; i++) {
                if (x >= x0 && x < x1) {
                    texts[nt++] = Cell(bg.Graphics, item, cols[i].Index, new Rectangle(x, b.Y, w[i], b.Height));
                }
                x += w[i];
            }
            IntPtr bdc = bg.Graphics.GetHdc();
            try {
                // the surface starts at the painted part's corner; the shapes went through a transform for that
                for (int i = 0; i < nt; i++) {
                    Rectangle r = texts[i].R;
                    r.Offset(-x0, -b.Y);
                    GdiText.Draw(bdc, texts[i].S, texts[i].F, r, texts[i].C, true);
                }
            }
            finally { bg.Graphics.ReleaseHdc(bdc); }
            bg.Render(dc);
        }
    }
    struct CellText { public string S; public Font F; public Rectangle R; public Color C; }
    // One cell's background, selection stripe, continent dot and ping bar; returns its text, drawn afterwards.
    CellText Cell(Graphics g, ListViewItem item, int col, Rectangle r) {
        ListViewItem.ListViewSubItem sub = item.SubItems[col];
        bool sel = item.Selected;
        Color bg = sel ? SelRow : item.Index == HoverIndex
            ? Color.FromArgb(Math.Min(255, sub.BackColor.R + 14), Math.Min(255, sub.BackColor.G + 16),
                Math.Min(255, sub.BackColor.B + 14))
            : sub.BackColor;   // hover = a bit lighter
        using (SolidBrush br = new SolidBrush(bg)) g.FillRectangle(br, r);
        if (sel && col == 0)
            using (SolidBrush ab = new SolidBrush(Accent)) g.FillRectangle(ab, r.X, r.Y, Px(3), r.Height);
        Color fc = (sel && col != 2) ? Color.White : sub.ForeColor;
        int x = r.X + Px(8);
        if (col == 0 && item.SubItems[0].Tag is Color) {   // continent dot
            int d = R(r.Height * 0.36);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush db = new SolidBrush((Color)item.SubItems[0].Tag))
                g.FillEllipse(db, x, r.Y + R((r.Height - d) / 2.0), d, d);
            g.SmoothingMode = SmoothingMode.Default;
            x += d + Px(8);
        }
        int ms;
        if (col == 2 && ShowBars && int.TryParse(sub.Text, out ms)) {   // ping bar after the number: full at 300 ms
            int tx = x + R(r.Height * 2.2), tw = r.Right - Px(12) - tx;
            if (tw > Px(20)) {
                int th = Math.Max(4, R(r.Height * 0.24)), ty = r.Y + R((r.Height - th) / 2.0);
                using (SolidBrush tb = new SolidBrush(BarTrack)) g.FillRectangle(tb, tx, ty, tw, th);
                using (SolidBrush fb = new SolidBrush(sub.ForeColor))
                    g.FillRectangle(fb, tx, ty, Math.Max(2, R(tw * Math.Min(1.0, ms / 300.0))), th);
            }
        }
        CellText t;
        t.S = sub.Text;
        t.F = sub.Font ?? _lv.Font;
        t.R = new Rectangle(x, r.Y, r.Right - x - Px(2), r.Height);
        t.C = fc;
        return t;
    }
}
// Text drawn with Windows' own DrawText: the same pixels as TextRenderer at half the cost. Pad = TextRenderer's
// default margins (a sixth of the font height).
public static class GdiText {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct DTP { public int Size, Tab, Left, Right, Drawn; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int DrawTextExW(IntPtr dc, string s, int n, ref RECT r, int f, ref DTP p);
    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")]
    static extern int SetBkMode(IntPtr dc, int m);
    [DllImport("gdi32.dll")]
    static extern int SetTextColor(IntPtr dc, int c);
    static readonly Dictionary<Font, IntPtr> Fonts = new Dictionary<Font, IntPtr>();
    static IntPtr HFont(Font f) {
        IntPtr h;
        if (Fonts.TryGetValue(f, out h)) return h;
        // fonts pile up over display scale changes: the cache starts over past 32
        if (Fonts.Count >= 32) { foreach (IntPtr o in Fonts.Values) DeleteObject(o); Fonts.Clear(); }
        h = f.ToHfont();
        Fonts[f] = h;
        return h;
    }
    // Left aligned, vertically centered, one line, "..." when it doesn't fit, "&" shown as is.
    public static void Draw(IntPtr dc, string s, Font f, Rectangle r, Color c, bool pad) {
        if (string.IsNullOrEmpty(s) || r.Width <= 0) return;
        SetBkMode(dc, 1);   // TRANSPARENT
        IntPtr old = SelectObject(dc, HFont(f));
        SetTextColor(dc, ColorTranslator.ToWin32(c));
        int m = pad ? (int)Math.Ceiling(f.Height / 6f) : 0;
        RECT rr = new RECT { L = r.Left, T = r.Top, R = r.Right, B = r.Bottom };
        DTP p = new DTP { Size = 20, Left = m, Right = m };
        // VCENTER SINGLELINE NOPREFIX (END_ELLIPSIS)
        DrawTextExW(dc, s, s.Length, ref rr, 0x4 | 0x20 | 0x800 | (pad ? 0x8000 : 0), ref p);
        SelectObject(dc, old);
    }
}
// Checkboxes drawn here: WinForms draws a flat checkbox's square at 100 % whatever the screen's scale.
public static class DarkCheck {
    static readonly Color Box = Color.FromArgb(40, 40, 46), Edge = Color.FromArgb(120, 120, 130),
        TickColor = Color.FromArgb(140, 225, 150);
    public static void Attach(CheckBox c) {
        const ControlStyles styles =
            ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint;
        typeof(Control).GetMethod("SetStyle",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            .Invoke(c, new object[] { styles, true });
        c.Paint += OnPaint;
        if (c.AutoSize) {   // room for the bigger square
            c.AutoSize = false;
            Fit(c);
            c.Height = Math.Max(c.Height, c.Font.Height + 4);
        }
    }
    // Width to fit its text in its current font (after a font or display scale change).
    public static void Fit(CheckBox c) {
        int h = c.Font.Height;
        c.Width = TextRenderer.MeasureText(c.Text, c.Font).Width + Square(h) * 3 / 2 + 6;
    }
    static int Square(int fontHeight) { return (int)Math.Round(fontHeight * 0.7); }
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    // Focus marks only after keyboard use (what Windows shows on its own controls): WM_QUERYUISTATE, UISF_HIDEFOCUS
    static bool FocusCues(Control c) {
        return ((long)SendMessage(c.Handle, 0x0129, IntPtr.Zero, IntPtr.Zero) & 1) == 0;
    }
    static void OnPaint(object s, PaintEventArgs e) {
        CheckBox c = (CheckBox)s;
        Graphics g = e.Graphics;
        using (SolidBrush bb = new SolidBrush(c.BackColor)) g.FillRectangle(bb, c.ClientRectangle);
        int box = Square(c.Font.Height);
        Rectangle r = new Rectangle(1, (c.Height - box) / 2, box, box);
        using (SolidBrush b = new SolidBrush(Box)) g.FillRectangle(b, r);
        using (Pen p = new Pen(c.Enabled ? Edge : Color.FromArgb(80, 80, 88))) g.DrawRectangle(p, r);
        if (c.Checked) Tick.Draw(g, r, TickColor, Math.Max(1.5f, box / 7f));
        Rectangle tr = new Rectangle(r.Right + box / 2, 0, Math.Max(0, c.Width - r.Right - box / 2), c.Height);
        const TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.Left |
            TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        TextRenderer.DrawText(g, c.Text, c.Font, tr, c.Enabled ? c.ForeColor : Color.FromArgb(120, 120, 128), flags);
        if (c.Focused && FocusCues(c))
            using (Pen p = new Pen(Color.FromArgb(90, 160, 105)) { DashStyle = DashStyle.Dot })
                g.DrawRectangle(p, 0, 0, c.Width - 1, c.Height - 1);
    }
}
// The list's rows painted from its custom-draw notices, before WinForms makes a GDI+ surface for every cell.
class RowPaint : NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    struct NMHDR { public IntPtr From; public IntPtr Id; public int Code; }
    [StructLayout(LayoutKind.Sequential)]
    struct NMCUSTOMDRAW {
        public NMHDR Hdr;
        public int Stage;
        public IntPtr Dc;
        public DarkList.RECT Rc;
        public IntPtr Item;
        public int State;
        public IntPtr Param;
    }
    readonly DarkList _o;
    public RowPaint(DarkList o) {
        _o = o;
        o._lv.HandleCreated += delegate { AssignHandle(o._lv.Handle); };
        o._lv.HandleDestroyed += delegate { ReleaseHandle(); };
        if (o._lv.IsHandleCreated) AssignHandle(o._lv.Handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x204E && m.LParam != IntPtr.Zero) {   // WM_NOTIFY, reflected back to the list by WinForms
            NMHDR h = (NMHDR)Marshal.PtrToStructure(m.LParam, typeof(NMHDR));
            if (h.Code == -12 && h.From == Handle) {                  // NM_CUSTOMDRAW from the list itself
                NMCUSTOMDRAW cd = (NMCUSTOMDRAW)Marshal.PtrToStructure(m.LParam, typeof(NMCUSTOMDRAW));
                // PREPAINT: tell me about each row (NOTIFYITEMDRAW)
                if (cd.Stage == 0x1) { m.Result = (IntPtr)0x20; return; }
                // ITEMPREPAINT: drawn here, the control draws nothing (SKIPDEFAULT)
                if (cd.Stage == 0x10001) {
                    try { _o.PaintRow(cd.Dc, (int)(long)cd.Item); } catch { }
                    m.Result = (IntPtr)0x4;
                    return;
                }
                m.Result = IntPtr.Zero;
                return;
            }
        }
        base.WndProc(ref m);
    }
}
// The list's column header painted here in one piece, the space past the last column included. Windows paints it light,
// and drawn per column through WinForms it costs ~2 ms a paint, several times a resize step.
class HeaderPaint : NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    struct PAINTSTRUCT {
        public IntPtr Dc;
        public int Erase;
        public DarkList.RECT Paint;
        public int Restore, IncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] Reserved;
    }
    [DllImport("user32.dll")]
    static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT ps);
    [DllImport("user32.dll")]
    static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT ps);
    [DllImport("user32.dll")]
    static extern bool GetClientRect(IntPtr h, out DarkList.RECT r);
    [DllImport("user32.dll")]
    static extern bool InvalidateRect(IntPtr h, ref DarkList.RECT r, bool erase);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    readonly DarkList _o;
    public HeaderPaint(DarkList o) {
        _o = o;
        o._lv.HandleCreated += delegate { Attach(); };
        o._lv.HandleDestroyed += delegate { ReleaseHandle(); };
        if (o._lv.IsHandleCreated) Attach();
    }
    void Attach() {
        IntPtr h = SendMessage(_o._lv.Handle, 0x101F, IntPtr.Zero, IntPtr.Zero);   // LVM_GETHEADER
        if (h != IntPtr.Zero && Handle == IntPtr.Zero) AssignHandle(h);
    }
    public void Invalidate(int fromX) {
        if (Handle == IntPtr.Zero) return;
        DarkList.RECT r;
        GetClientRect(Handle, out r);
        r.L = Math.Max(0, fromX - 1);
        InvalidateRect(Handle, ref r, false);
    }
    Rectangle Client() {
        DarkList.RECT r;
        GetClientRect(Handle, out r);
        return new Rectangle(0, 0, r.R - r.L, r.B - r.T);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0014) { m.Result = (IntPtr)1; return; }   // WM_ERASEBKGND: the paint covers everything
        if (m.Msg == 0x000F && _o.Fitting) return;                      // WM_PAINT mid-fit: left for the next paint
        if (m.Msg == 0x000F) {                                          // WM_PAINT
            PAINTSTRUCT ps;
            IntPtr dc = BeginPaint(Handle, out ps);
            try { _o.PaintHeader(dc, Handle, Client()); } finally { EndPaint(Handle, ref ps); }
            m.Result = IntPtr.Zero;
            return;
        }
        // WM_PRINTCLIENT
        if (m.Msg == 0x0318 && m.WParam != IntPtr.Zero) { _o.PaintHeader(m.WParam, Handle, Client()); return; }
        base.WndProc(ref m);
    }
}
// A status row in its colors; too narrow, it ends in "..." after the last character that fits. Returns whether it
// was cut. Resize: only re-fit a row that was cut or no longer fits.
public static class InfoText {
    static readonly string Ell = ((char)0x2026).ToString();
    public static bool Show(RichTextBox box, string[] text, Color[] color, bool[] bold, Font f, Font fb, Color dim,
        int room, bool resize) {
        if (box.IsDisposed) return false;
        bool lastBold = false;   // the last character's font: the last part with text
        for (int i = 0; i < text.Length; i++) if (text[i].Length > 0) lastBold = bold[i];
        if (resize && Fits(box, lastBold ? fb : f, room)) return false;
        box.Text = string.Concat(text);
        int pos = 0;
        for (int i = 0; i < text.Length; i++) {
            int len = text[i].Length;
            if (len > 0) { box.Select(pos, len); box.SelectionColor = color[i]; box.SelectionFont = bold[i] ? fb : f; }
            pos += len;
        }
        // scrolled to the start: positions count from there
        box.Select(0, 0);
        if (!box.IsHandleCreated || box.TextLength < 2 || Fits(box, lastBold ? fb : f, room)) return false;
        int n = box.TextLength;
        int ellW = TextRenderer.MeasureText(Ell, fb, Size.Empty, TextFormatFlags.NoPadding).Width;
        // how many characters still fit before the "..."
        int lo = 0, hi = n - 1;
        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            if (box.GetPositionFromCharIndex(mid).X + ellW <= room) lo = mid;
            else hi = mid - 1;
        }
        int keep = lo;
        string t = box.Text;
        // not after a separator, dash or arrow
        while (keep > 0 && " |-\u2013\u2192".IndexOf(t[keep - 1]) >= 0) keep--;
        box.Select(keep, n - keep);
        box.SelectedText = Ell;
        box.Select(keep, 1);
        box.SelectionColor = dim;
        box.SelectionFont = f;
        box.Select(0, 0);
        return true;
    }
    static bool Fits(RichTextBox box, Font last, int room) {
        int n = box.TextLength;
        if (n < 2 || !box.IsHandleCreated) return true;
        int lastW = TextRenderer.MeasureText(box.Text.Substring(n - 1), last, Size.Empty,
            TextFormatFlags.NoPadding).Width;
        return box.GetPositionFromCharIndex(n - 1).X + lastW <= room;
    }
}
// The footer (version, "made by", the update notice), drawn here because a resize repaints it many times a second
// and each call into the script costs ~1.5 ms. NoticeRect is where the notice is, for the click.
public class FooterView {
    readonly Panel _p;
    public Font TextFont, TagFont;
    public string Left = "", Notice;
    public Color Accent;
    public int Sp = 4;
    public Rectangle NoticeRect;
    // Right of the tag: the Ko-fi and Buy Me a Coffee logos (the script sets them and opens their pages); Hover = the
    // one under the mouse (-1: none), drawn on a lighter tile.
    public Rectangle[] Icons = new Rectangle[2];
    public int Hover = -1;
    public Image[] IconImages = new Image[2];

    Font _mText, _mTag;
    string _mLeft, _mNotice;
    int _wHash, _wRoot, _wLeft, _wNotice;   // text widths, measured once
    public FooterView(Panel p) {
        _p = p;
        p.Paint += delegate(object s, PaintEventArgs e) {
            // off-screen: see OffScreen
            if (TextFont != null && TagFont != null && _p.ClientSize.Width > 0 && _p.ClientSize.Height > 0)
                using (BufferedGraphics bg = BufferedGraphicsManager.Current.Allocate(e.Graphics, _p.ClientRectangle)) {
                    using (SolidBrush b = new SolidBrush(_p.BackColor))
                        bg.Graphics.FillRectangle(b, _p.ClientRectangle);
                    Paint(bg.Graphics);
                    bg.Render(e.Graphics);
                }
        };
        p.Resize += delegate { _p.Invalidate(); };
        p.MouseMove += delegate(object s, MouseEventArgs e) {
            int h = Icons[0].Contains(e.Location) ? 0 : Icons[1].Contains(e.Location) ? 1 : -1;
            if (h != Hover) { Hover = h; _p.Invalidate(); }
            Cursor want = (h >= 0 || NoticeRect.Contains(e.Location)) ? Cursors.Hand : Cursors.Default;
            if (_p.Cursor != want) _p.Cursor = want;
        };
        p.MouseLeave += delegate { if (Hover != -1) { Hover = -1; _p.Invalidate(); } };
    }
    static int W(string s, Font f) {
        return string.IsNullOrEmpty(s) ? 0 :
            TextRenderer.MeasureText(s, f, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Width;
    }
    void Paint(Graphics g) {
        if (_mText != TextFont || _mTag != TagFont || _mLeft != Left || _mNotice != Notice) {
            _mText = TextFont;
            _mTag = TagFont;
            _mLeft = Left;
            _mNotice = Notice;
            _wHash = W("#", TagFont);
            _wRoot = W("root", TagFont);
            _wLeft = W(Left, TextFont);
            _wNotice = W(Notice, TextFont);
        }
        Size s = _p.ClientSize;
        int ic = s.Height;   // square icons, the footer's height
        Icons[1] = new Rectangle(s.Width - ic, 0, ic, ic);
        Icons[0] = new Rectangle(Icons[1].X - Sp - ic, 0, ic, ic);
        DrawIcons(g);
        int tagW = Sp + _wHash + Sp + _wRoot + Sp;
        Rectangle t = new Rectangle(Icons[0].X - 2 * Sp - tagW - 1, 0, tagW, s.Height - 1);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(24, 40, 30))) g.FillRectangle(b, t);
        using (Pen p = new Pen(Color.FromArgb(62, 120, 78))) g.DrawRectangle(p, t);
        NoticeRect = (!string.IsNullOrEmpty(Notice) && _wNotice < t.X - _wLeft - 4 * Sp) ?
            new Rectangle(0, 0, _wNotice + 2, s.Height) : Rectangle.Empty;
        IntPtr dc = g.GetHdc();
        try {
            int x = t.X + Sp;
            GdiText.Draw(dc, "#", TagFont, new Rectangle(x, 0, _wHash + 2, s.Height),
                Color.FromArgb(90, 160, 105), false);
            GdiText.Draw(dc, "root", TagFont, new Rectangle(x + _wHash + Sp, 0, _wRoot + 2, s.Height), Accent, false);
            GdiText.Draw(dc, Left, TextFont, new Rectangle(t.X - _wLeft - Sp - 2, 0, _wLeft + 2, s.Height),
                Color.FromArgb(120, 122, 132), false);
            if (!NoticeRect.IsEmpty) GdiText.Draw(dc, Notice, TextFont, NoticeRect, Accent, false);
        }
        finally { g.ReleaseHdc(dc); }
    }
    void DrawIcons(Graphics g) {   // the official logos (set by the script), scaled smoothly
        InterpolationMode im = g.InterpolationMode;
        PixelOffsetMode pm = g.PixelOffsetMode;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        for (int i = 0; i < 2; i++) {
            if (i == Hover)
                using (SolidBrush b = new SolidBrush(Color.FromArgb(48, 48, 56))) g.FillRectangle(b, Icons[i]);
            int pad = Math.Max(1, Icons[i].Height / 10);
            if (IconImages[i] != null) g.DrawImage(IconImages[i], Rectangle.Inflate(Icons[i], -pad, -pad));
        }
        g.InterpolationMode = im;
        g.PixelOffsetMode = pm;
    }
}
// A status row's text and its re-fit on resize, without the script. The text box stays wider than any window and
// its panel cuts it off. The tooltip shows the whole row only while it's cut, and isn't rewritten under the mouse.
public class InfoRow {
    public static Font Normal, Bold;
    public static Color Dim;
    public static int Pad, Margin;
    public static ToolTip Tip;
    readonly RichTextBox _b;
    string[] _t = new string[0];
    Color[] _c = new Color[0];
    bool[] _bo = new bool[0];
    bool _cut, _hover;
    int _w = -1;
    string _tip = "";
    public string Full = "";
    public InfoRow(RichTextBox b) {
        _b = b;
        EventHandler refit = delegate { if (Room() != _w) Fit(true); };   // narrower / wider window: fitted again
        Control parent = null;
        b.ParentChanged += delegate {
            if (parent != null) parent.Resize -= refit;
            parent = b.Parent;
            if (parent != null) parent.Resize += refit;
        };
        b.MouseEnter += delegate { _hover = true; };
        b.MouseLeave += delegate { _hover = false; SetTip(); };
    }
    void SetTip() {
        string want = _cut ? Full : "";
        if (want == _tip || Tip == null || (_hover && want.Length > 0 && _tip.Length > 0)) return;
        Tip.SetToolTip(_b, want);
        _tip = want;
    }
    int Room() {
        return _b.Parent == null ? _b.ClientSize.Width :
            Math.Min(_b.ClientSize.Width, _b.Parent.ClientSize.Width - _b.Left - Margin);
    }
    public void Set(string[] text, Color[] color, bool[] bold) { _t = text; _c = color; _bo = bold; Fit(false); }
    public void Show() { Fit(false); }   // again in full (new fonts, the box now on screen)
    void Fit(bool resize) {
        if (_t.Length == 0 || Normal == null || Bold == null) return;
        int room = Room();
        _cut = InfoText.Show(_b, _t, _c, _bo, Normal, Bold, Dim, room - Pad, resize && !_cut);
        _w = room;
        SetTip();
    }
}
// Buttons and labels painted off-screen first: drawn straight on the window, Windows reads its pixels back first,
// about 1 ms a paint. Panels, text boxes and the list are left to Windows.
public static class OffScreen {
    static readonly System.Reflection.MethodInfo SetStyle = typeof(Control).GetMethod("SetStyle",
        System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
    const ControlStyles Buffered = ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint;
    public static void Apply(Control root) {
        foreach (Control c in root.Controls) {
            if (c is ButtonBase || c is Label)
                SetStyle.Invoke(c, new object[] { Buffered, true });
            Apply(c);
        }
    }
}
// The thin bar under the status rows (how far DBD's 10-min re-measure window has come): Frac 0..1 in Fill over the
// Track color, nothing when below 0. Drawn here: a resize repaints it with the window.
public class GateBar {
    readonly Panel _p;
    public double Frac = -1;
    public Color Fill = Color.Empty, Track = Color.FromArgb(56, 56, 64);
    public GateBar(Panel p) {
        _p = p;
        p.Paint += delegate(object s, PaintEventArgs e) {
            if (Frac < 0) return;
            using (SolidBrush t = new SolidBrush(Track)) e.Graphics.FillRectangle(t, 0, 0, _p.Width, _p.Height);
            using (SolidBrush f = new SolidBrush(Fill))
                e.Graphics.FillRectangle(f, 0, 0, (int)(_p.Width * Math.Min(1.0, Frac)), _p.Height);
        };
        p.Resize += delegate { _p.Invalidate(); };
    }
    public void Set(double frac, Color fill) {
        if (Math.Abs(frac - Frac) <= 0.0005 && fill == Fill) return;
        Frac = frac;
        Fill = fill;
        _p.Invalidate();
    }
}
// Keeps a container's right- or bottom-anchored children in place on resize, all moved in one DeferWindowPos batch
// instead of one layout pass each. Capture() records the current layout.
public class EdgeLayout {
    class Rule { public Control C; public AnchorStyles A; public int X, Y, W, H; }
    readonly Control _p;
    readonly List<Rule> _rules = new List<Rule>();
    public bool Paused;   // while the script rescales the window (its offsets are in the old scale's pixels)
    bool _applying;
    [DllImport("user32.dll")]
    static extern IntPtr BeginDeferWindowPos(int n);
    [DllImport("user32.dll")]
    static extern IntPtr DeferWindowPos(IntPtr info, IntPtr h, IntPtr after, int x, int y, int w, int ht, int flags);
    [DllImport("user32.dll")]
    static extern bool EndDeferWindowPos(IntPtr info);
    public EdgeLayout(Control parent) { _p = parent; parent.SizeChanged += delegate { Apply(); }; }
    public void Follow(Control c, AnchorStyles a) {
        c.Anchor = AnchorStyles.Top | AnchorStyles.Left;
        Rule r = new Rule { C = c, A = a };
        _rules.Add(r);
        Take(r);
        // Moved or resized by the script (not by this): kept from there on, as WinForms does with an anchored control.
        EventHandler moved = delegate { if (!_applying && !Paused) Take(r); };
        c.LocationChanged += moved;
        c.SizeChanged += moved;
    }
    // Offsets from the edges each part follows: left / top = its position; right only = from the right edge; left and
    // right = its width's difference to the container's (same for top / bottom).
    public void Capture() { foreach (Rule r in _rules) Take(r); }
    void Take(Rule r) {
        Size s = _p.ClientSize;
        Rectangle b = r.C.Bounds;
        bool L = (r.A & AnchorStyles.Left) != 0, R = (r.A & AnchorStyles.Right) != 0, T = (r.A & AnchorStyles.Top) != 0,
            B = (r.A & AnchorStyles.Bottom) != 0;
        r.X = (R && !L) ? s.Width - b.X : b.X;
        r.W = (L && R) ? s.Width - b.Width : b.Width;
        r.Y = (B && !T) ? s.Height - b.Y : b.Y;
        r.H = (T && B) ? s.Height - b.Height : b.Height;
    }
    void Apply() {
        Size s = _p.ClientSize;
        if (Paused || s.Width <= 0 || s.Height <= 0 || _rules.Count == 0) return;   // minimized
        _applying = true;
        try { Place(s); } finally { _applying = false; }
    }
    void Place(Size s) {
        IntPtr info = IntPtr.Zero;
        foreach (Rule r in _rules) {
            bool L = (r.A & AnchorStyles.Left) != 0, R = (r.A & AnchorStyles.Right) != 0,
                T = (r.A & AnchorStyles.Top) != 0, B = (r.A & AnchorStyles.Bottom) != 0;
            int x = (R && !L) ? s.Width - r.X : r.X, w = (L && R) ? Math.Max(0, s.Width - r.W) : r.W;
            int y = (B && !T) ? s.Height - r.Y : r.Y, h = (T && B) ? Math.Max(0, s.Height - r.H) : r.H;
            Control c = r.C;
            if (c.Left == x && c.Top == y && c.Width == w && c.Height == h) continue;
            if (!c.IsHandleCreated) { c.SetBounds(x, y, w, h); continue; }
            if (info == IntPtr.Zero) info = BeginDeferWindowPos(_rules.Count);
            // NOZORDER, NOACTIVATE
            if (info != IntPtr.Zero) info = DeferWindowPos(info, c.Handle, IntPtr.Zero, x, y, w, h, 0x4 | 0x10);
            if (info == IntPtr.Zero) c.SetBounds(x, y, w, h);
        }
        if (info != IntPtr.Zero) EndDeferWindowPos(info);
    }
}
// Buttons that share a row's width equally: from the first one's left edge to the right edge of a reference control
// (the status card above them), so the row lines up with the rest of the window at any width. Gap in screen pixels.
public class EvenRow {
    // The shown items share the room from the first item's left edge to the edge control's right edge.
    readonly Control[] _items;
    readonly Control _edge;
    readonly HashSet<Control> _off = new HashSet<Control>();
    public int Gap;
    public EvenRow(Control edge, Control[] items, int gap) {
        _edge = edge;
        _items = items;
        Gap = gap;
        edge.SizeChanged += delegate { Layout(); };   // after the anchors have moved it
    }
    [DllImport("user32.dll")]
    static extern IntPtr BeginDeferWindowPos(int n);
    [DllImport("user32.dll")]
    static extern IntPtr DeferWindowPos(IntPtr info, IntPtr h, IntPtr after, int x, int y, int w, int ht, int flags);
    [DllImport("user32.dll")]
    static extern bool EndDeferWindowPos(IntPtr info);
    // its own flag: Visible reads false for every control until the window shows
    public void Show(Control c, bool on) {
        if (on) _off.Remove(c);
        else _off.Add(c);
        c.Visible = on;
        Layout();
    }
    public void Layout() {
        List<Control> shown = new List<Control>();
        foreach (Control c in _items) if (!_off.Contains(c)) shown.Add(c);
        int n = shown.Count, x0 = _items[0].Left;   // the first item's place, also while it's hidden
        if (n == 0) return;
        int room = _edge.Right - x0 - Gap * (n - 1);
        if (room < n) return;
        // All moved in one go (a resize does this many times a second): one batch for Windows instead of one each.
        bool live = true;
        foreach (Control c in shown) live &= c.IsHandleCreated;
        IntPtr info = live ? BeginDeferWindowPos(n) : IntPtr.Zero;
        for (int i = 0; i < n; i++) {
            int a = x0 + room * i / n + Gap * i, b = x0 + room * (i + 1) / n + Gap * i;
            Control c = shown[i];
            if (c.Left == a && c.Width == b - a) continue;
            // NOZORDER, NOACTIVATE
            if (info != IntPtr.Zero)
                info = DeferWindowPos(info, c.Handle, IntPtr.Zero, a, c.Top, b - a, c.Height, 0x4 | 0x10);
            else c.SetBounds(a, 0, b - a, 0, BoundsSpecified.X | BoundsSpecified.Width);
        }
        if (info != IntPtr.Zero) EndDeferWindowPos(info);
    }
}
