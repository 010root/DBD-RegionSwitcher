using System;
using System.Runtime.InteropServices;
public static class TcpKill {
    [StructLayout(LayoutKind.Sequential)]
    public struct Row { public int State; public uint La; public uint Lp; public uint Ra; public uint Rp; }
    [DllImport("iphlpapi.dll")]
    public static extern int SetTcpEntry(ref Row r);
    // DELETE_TCB one connection (addresses and ports in network byte order, as the TCP table has them).
    public static int Kill(uint la, uint lp, uint ra, uint rp) {
        Row r = new Row();
        r.State = 12;
        r.La = la;
        r.Lp = lp;
        r.Ra = ra;
        r.Rp = rp;
        return SetTcpEntry(ref r);
    }

    // The IPv4 TCP table with owning pids (MIB_TCPTABLE_OWNER_PID), read directly: microseconds, vs ~50 ms per
    // Get-NetTCPConnection. Connections opened between sizing and reading make it too small, so it retries.
    [DllImport("iphlpapi.dll")]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass,
        uint reserved);
    static IntPtr ReadTable() {
        int size = 0;
        for (int attempt = 0; attempt < 4; attempt++) {
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 5, 0);   // AF_INET, TCP_TABLE_OWNER_PID_ALL
            size += 4096;
            IntPtr buf = Marshal.AllocHGlobal(size);
            if (GetExtendedTcpTable(buf, ref size, false, 2, 5, 0) == 0) return buf;
            Marshal.FreeHGlobal(buf);
        }
        return IntPtr.Zero;
    }
    static string Endpoint(uint ra, uint rp) {   // network byte order -> "a.b.c.d:port"
        return (ra & 0xFF) + "." + ((ra >> 8) & 0xFF) + "." + ((ra >> 16) & 0xFF) + "." + (ra >> 24) + ":" +
            (((rp & 0xFF) << 8) | ((rp >> 8) & 0xFF));
    }

    // Holding a cut: DELETE_TCB every connection of `pid` whose remote address is in `remotes`. `others` lists
    // what was left alone.
    public static int KillPidRemotes(uint pid, uint[] remotes, out string others) {
        others = "";
        IntPtr buf = ReadTable();
        if (buf == IntPtr.Zero) return 0;
        int n = 0;
        try {
            int count = Marshal.ReadInt32(buf);
            System.Text.StringBuilder sb = new System.Text.StringBuilder();
            for (int i = 0; i < count; i++) {
                // MIB_TCPROW_OWNER_PID: state, la, lp, ra, rp, pid
                IntPtr row = new IntPtr(buf.ToInt64() + 4 + i * 24);
                if ((uint)Marshal.ReadInt32(row, 20) != pid) continue;
                uint ra = (uint)Marshal.ReadInt32(row, 12), rp = (uint)Marshal.ReadInt32(row, 16);
                if (Marshal.ReadInt32(row, 0) == 2 || ra == 0) continue;   // LISTEN / no remote
                // the rest is listed, except what's inside this PC (127.x: never BHVR)
                if (Array.IndexOf(remotes, ra) >= 0) {
                    if (Kill((uint)Marshal.ReadInt32(row, 4), (uint)Marshal.ReadInt32(row, 8), ra, rp) == 0) n++;
                } else if ((ra & 0xFF) != 127) {
                    sb.Append(Endpoint(ra, rp) + " ");
                }
            }
            others = sb.ToString().Trim();
        } finally { Marshal.FreeHGlobal(buf); }
        return n;
    }

    // One sweep of the cut: DELETE_TCB every IPv4 connection of `pid` to another machine (127.x stays: it's inside this
    // PC, e.g. the Steam / Epic overlay - never BHVR). `killed` = "ip:port ..." that went.
    public static int KillPidAll(uint pid, out string killed) {
        killed = "";
        IntPtr buf = ReadTable();
        if (buf == IntPtr.Zero) return 0;
        int n = 0;
        try {
            int count = Marshal.ReadInt32(buf);
            System.Text.StringBuilder sb = new System.Text.StringBuilder();
            for (int i = 0; i < count; i++) {
                IntPtr row = new IntPtr(buf.ToInt64() + 4 + i * 24);
                if ((uint)Marshal.ReadInt32(row, 20) != pid) continue;
                uint ra = (uint)Marshal.ReadInt32(row, 12), rp = (uint)Marshal.ReadInt32(row, 16);
                // LISTEN / no remote / inside this PC
                if (Marshal.ReadInt32(row, 0) == 2 || ra == 0 || (ra & 0xFF) == 127) continue;
                if (Kill((uint)Marshal.ReadInt32(row, 4), (uint)Marshal.ReadInt32(row, 8), ra, rp) != 0) continue;
                n++;
                sb.Append(Endpoint(ra, rp) + " ");
            }
            killed = sb.ToString().Trim();
        } finally { Marshal.FreeHGlobal(buf); }
        return n;
    }

    // Same as "ipconfig /flushdns" without starting a process each time (the cut flushes every ~150 ms).
    [DllImport("dnsapi.dll")]
    static extern bool DnsFlushResolverCache();
    public static bool FlushDns() { try { return DnsFlushResolverCache(); } catch { return false; } }
}
