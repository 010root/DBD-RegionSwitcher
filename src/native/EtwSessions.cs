using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class EtwSessions {
    [DllImport("advapi32.dll")]
    static extern int EnumerateTraceGuidsEx(int infoClass, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize,
        out int returned);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int QueryAllTracesW(IntPtr[] props, int count, out int returned);
    const int NameRoom = 1024, PropSize = 120 + 2 * NameRoom;

    // "name|keywords|realtime 0/1|events lost" for every running session that has `provider` enabled.
    public static string[] ForProvider(Guid provider) {
        Dictionary<int, string> sessions = Sessions();
        List<string> o = new List<string>();
        HashSet<int> seen = new HashSet<int>();
        IntPtr g = Marshal.AllocHGlobal(16);
        IntPtr b = IntPtr.Zero;
        try {
            Marshal.Copy(provider.ToByteArray(), 0, g, 16);
            int need;
            EnumerateTraceGuidsEx(1, g, 16, IntPtr.Zero, 0, out need);          // TraceGuidQueryInfo
            if (need <= 0) return o.ToArray();                                               // nobody enables it
            b = Marshal.AllocHGlobal(need);
            if (EnumerateTraceGuidsEx(1, g, 16, b, need, out need) != 0) return o.ToArray();
            // TRACE_GUID_INFO, then per registration TRACE_PROVIDER_INSTANCE_INFO + TRACE_ENABLE_INFO[] (32 bytes each)
            int instances = Marshal.ReadInt32(b), at = 8;
            for (int i = 0; i < instances; i++) {
                int next = Marshal.ReadInt32(b, at), enables = Marshal.ReadInt32(b, at + 4);
                for (int k = 0; k < enables; k++) {
                    int e = at + 16 + k * 32;
                    if (Marshal.ReadInt32(b, e) == 0) continue;                                // IsEnabled
                    int logger = (ushort)Marshal.ReadInt16(b, e + 6);
                    if (!seen.Add(logger)) continue;
                    string info;
                    if (!sessions.TryGetValue(logger, out info)) info = "logger " + logger + "|\u0001|0|0";
                    // MatchAnyKeyword
                    o.Add(info.Replace("\u0001", "0x" + ((ulong)Marshal.ReadInt64(b, e + 16)).ToString("X")));
                }
                if (next == 0) break;
                at += next;
            }
        } finally { Marshal.FreeHGlobal(g); if (b != IntPtr.Zero) Marshal.FreeHGlobal(b); }
        return o.ToArray();
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int StartTraceW(out ulong handle, string name, IntPtr props);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int ControlTraceW(ulong handle, string name, IntPtr props, int code);
    [DllImport("advapi32.dll")]
    static extern int EnableTraceEx2(ulong handle, ref Guid provider, int control, byte level, ulong any, ulong all,
        int timeout, IntPtr parms);
    static IntPtr Props() {
        IntPtr p = Marshal.AllocHGlobal(PropSize);
        for (int j = 0; j < PropSize; j += 4) Marshal.WriteInt32(p, j, 0);
        Marshal.WriteInt32(p, 0, PropSize);
        Marshal.WriteInt32(p, 44, 0x00020000);        // WNODE_FLAG_TRACED_GUID
        Marshal.WriteInt32(p, 64, 0x100);
        Marshal.WriteInt32(p, 68, 1);                    // real-time, 1 s flush
        Marshal.WriteInt32(p, 112, 120 + NameRoom);
        Marshal.WriteInt32(p, 116, 120);
        return p;
    }
    // Stop a session by name (what "logman stop <name> -ets" does, without starting a process). 0 = stopped,
    // 4201 = no such session (already gone).
    public static int StopByName(string name) {
        IntPtr p = Props();
        try { return ControlTraceW(0, name, p, 1); } finally { Marshal.FreeHGlobal(p); }   // EVENT_TRACE_CONTROL_STOP
    }
    // Briefly enable `provider` from a throwaway session, then stop it: when a session stops getting Kernel-Network UDP
    // events, another session enabling or disabling that provider can bring them back.
    public static int Nudge(string name, Guid provider, ulong keywords, int holdMs) {
        StopByName(name);
        IntPtr p = Props();
        ulong h;
        try { int rc = StartTraceW(out h, name, p); if (rc != 0) return rc; } finally { Marshal.FreeHGlobal(p); }
        int e = EnableTraceEx2(h, ref provider, 1, 5, keywords, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(holdMs);
        StopByName(name);
        return e;
    }

    // logger id -> "name|\u0001|realtime|events lost" (\u0001 is replaced by the keywords above)
    static Dictionary<int, string> Sessions() {
        Dictionary<int, string> d = new Dictionary<int, string>();
        IntPtr[] p = new IntPtr[64];
        try {
            for (int i = 0; i < p.Length; i++) {
                p[i] = Marshal.AllocHGlobal(PropSize);
                for (int j = 0; j < PropSize; j += 4) Marshal.WriteInt32(p[i], j, 0);
                Marshal.WriteInt32(p[i], 0, PropSize);                // Wnode.BufferSize
                Marshal.WriteInt32(p[i], 112, 120 + NameRoom);        // LogFileNameOffset
                Marshal.WriteInt32(p[i], 116, 120);                   // LoggerNameOffset
            }
            int got;
            if (QueryAllTracesW(p, p.Length, out got) != 0) return d;
            for (int i = 0; i < got; i++) {
                // Wnode.HistoricalContext = logger id
                int id = (int)(Marshal.ReadInt64(p[i], 8) & 0xFFFF);
                string name = Marshal.PtrToStringUni(IntPtr.Add(p[i], Marshal.ReadInt32(p[i], 116)));
                bool rt = (Marshal.ReadInt32(p[i], 64) & 0x100) != 0;                // EVENT_TRACE_REAL_TIME_MODE
                int lost = Marshal.ReadInt32(p[i], 88);                               // EventsLost
                d[id] = name + "|\u0001|" + (rt ? 1 : 0) + "|" + lost;
            }
        } finally { foreach (IntPtr x in p) if (x != IntPtr.Zero) Marshal.FreeHGlobal(x); }
        return d;
    }
}
