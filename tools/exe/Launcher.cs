// DBD Region Switcher - .exe launcher.
// Runs the embedded DBD-RegionSwitcher.ps1 inside THIS process (hosted PowerShell 5.1 runspace, STA for WinForms),
// so every hosts write comes from DBD-RegionSwitcher.exe itself. That lets an antivirus exclusion target just this
// file instead of powershell.exe. The script is embedded unchanged (tool\DBD-RegionSwitcher.ps1, tools\build-exe.ps1).
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Windows.Forms;

[assembly: AssemblyTitle("DBD Region Switcher")]
[assembly: AssemblyProduct("DBD Region Switcher")]
[assembly: AssemblyCopyright("Copyright (C) 2026 root")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0")]
// Every [DllImport] in this .exe (the script's C# parts are compiled in too) loads Windows' own DLL from System32 -
// never a same-named DLL dropped next to the .exe (e.g. in Downloads) into this admin process.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

static class Program {
    [STAThread]
    static int Main() {
        try {
            string script;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("DBD-RegionSwitcher.ps1"))
            using (StreamReader r = new StreamReader(s, new UTF8Encoding(false)))
                script = r.ReadToEnd();

            // Modules load only from Windows' own folder, before the runspace looks for any: this process runs as
            // admin, and the default module path starts with the user's Documents folder (the script does the same).
            Environment.SetEnvironmentVariable("PSModulePath",
                Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\Modules"));
            using (Runspace rs = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault())) {
                rs.ApartmentState = ApartmentState.STA;           // WinForms needs STA
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    ps.Invoke();                                  // returns when the window closes
                }
            }
            return 0;
        } catch (Exception e) {
            ShowError("DBD Region Switcher could not start:\r\n\r\n" + e.Message);
            return 1;
        }
    }

    [DllImport("user32.dll")]
    static extern uint GetDpiForSystem();
    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(System.Drawing.Point p, int flags);
    [DllImport("shcore.dll")]
    static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    // Dark like the rest of the tool (Windows' MessageBox is always light).
    static void ShowError(string text) {
        using (Form f = new Form()) {
            f.Text = "DBD Region Switcher";
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;
            f.StartPosition = FormStartPosition.CenterScreen;
            f.TopMost = true;
            f.BackColor = System.Drawing.Color.FromArgb(28, 28, 32);
            f.ForeColor = System.Drawing.Color.FromArgb(215, 215, 222);
            f.HandleCreated += delegate { int on = 1; DwmSetWindowAttribute(f.Handle, 20, ref on, 4); };
            // The scale of the screen it opens on - the one with the mouse (CenterScreen) - per-monitor DPI aware:
            // fonts in points are drawn at the system scale.
            float k = 1f, fk = 1f;
            try {
                uint d, dy, s = GetDpiForSystem();
                if (GetDpiForMonitor(MonitorFromPoint(Cursor.Position, 2), 0, out d, out dy) == 0 && d > 0 && s > 0) {
                    k = d / 96f;
                    fk = (float)d / s;
                }
            } catch { }
            f.Font = new System.Drawing.Font("Segoe UI", 10.5f * fk);
            Func<int, int> px = v => (int)Math.Round(v * k);
            Label l = new Label();
            l.AutoSize = true;
            l.MaximumSize = new System.Drawing.Size(px(560), 0);
            l.Location = new System.Drawing.Point(px(20), px(20));
            l.Text = text;
            Button ok = new Button();
            ok.Text = "OK";
            ok.DialogResult = DialogResult.OK;
            ok.FlatStyle = FlatStyle.Flat;
            ok.Size = new System.Drawing.Size(px(96), px(32));
            ok.BackColor = System.Drawing.Color.FromArgb(60, 64, 74);
            ok.ForeColor = System.Drawing.Color.White;
            f.Controls.Add(l);
            f.Controls.Add(ok);
            f.AcceptButton = ok;
            f.CancelButton = ok;
            int w = Math.Max(px(360), l.PreferredWidth + px(40)), y = l.PreferredHeight + px(40);
            ok.Location = new System.Drawing.Point(w - px(116), y);
            f.ClientSize = new System.Drawing.Size(w, y + px(50));
            f.ShowDialog();
        }
    }
}
