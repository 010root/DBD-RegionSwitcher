using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

public static class DbdEtw {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern uint StartTraceW(out ulong handle, string name, IntPtr props);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern uint ControlTraceW(ulong handle, string name, IntPtr props, uint code);
    [DllImport("advapi32.dll")]
    static extern uint EnableTraceEx2(ulong handle, ref Guid provider, uint control, byte level, ulong any, ulong all,
        uint timeout, IntPtr parms);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern ulong OpenTraceW(IntPtr logfile);
    [DllImport("advapi32.dll")]
    static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);
    [DllImport("advapi32.dll")]
    static extern uint CloseTrace(ulong handle);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void RecordCallback(IntPtr record);

    public static string SessionName = "DBD-RegionSwitcher-ETW";
    public static volatile int Pid;          // DBD's pid, 0 = not running
    public static int OwnPid;                // this tool's own lookups (Ping) are ignored
    public static Regex SteerRx;             // hostnames covered by the steering block
    public static string LastError = "";
    public static long DnsEvents, UdpEvents;
    // Self-test: this tool's own probe traffic (a few UDP packets to TEST-NET + one DNS lookup) counted separately, to
    // check that Windows actually delivers both event kinds to this session (e.g. with another tool's session running).
    public static volatile int ProbePid;
    public static long ProbeUdp, ProbeDns;

    static readonly Guid KernelNetwork = new Guid("7DD42A49-5329-4832-8DFD-43D979153A88");
    static readonly Guid DnsClient = new Guid("1C95126E-7EEA-49A9-A3FE-A378B03DDB4D");
    const int PropsSize = 120 + 2048;        // EVENT_TRACE_PROPERTIES + logger name
    const int LogfileSize = 448;             // EVENT_TRACE_LOGFILEW (x64)
    static RecordCallback _cb;               // kept alive while native code holds the pointer
    static IntPtr _logfile = IntPtr.Zero, _loggerName = IntPtr.Zero;
    static ulong _session, _trace;
    static Thread _thread;
    static bool _stopHooked;
    static readonly object _lock = new object();
    static long _lastSteerTicks, _lastSteerHttpTicks;
    static readonly List<long> _steerTicks = new List<long>();
    // "ticks|name|status|results" from query-completed events
    static readonly List<string> _steerResults = new List<string>();
    // DBD lookups: name -> IPv4s
    static readonly Dictionary<string, HashSet<string>> _dbdResolved =
        new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
    static readonly List<string> _dnsNew = new List<string>();   // not yet shown in the console
    public static string[] TakeNewDns() { lock (_lock) { string[] a = _dnsNew.ToArray(); _dnsNew.Clear(); return a; } }
    static readonly Dictionary<string, long[]> _dbdNames =
        new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
    static readonly Queue<KeyValuePair<long, string>> _udp = new Queue<KeyValuePair<long, string>>();
    public static double LastDnsDelayMs;     // how late the last DNS event reached us (event time -> callback)
    public static bool MsFlush;              // events flushed every FlushMs ms (else every 1 s)
    public static int FlushMs = 5;           // ~30 ms event delivery at 5 ms (~60 ms at 20 ms)

    // ---- Opt-in clock jump ("skip the 10-min wait", see docs\how-it-works.md) ----
    // The PC clock is put ahead right before the cut and put back the moment DBD's first measurement lookup arrives
    // here (on the ETW thread, no UI delay), so DBD saves its real measurement time. While the clock is ahead,
    // UtcNow below still returns real time (from the QPC counter): every timestamp this tool keeps stays real.
    [StructLayout(LayoutKind.Sequential)]
    struct SystemTime { public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Ms; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetSystemTime(ref SystemTime st);
    public delegate bool ClockSetter(DateTime utc);
    public static ClockSetter SetClock = RealSetClock;     // the tests swap in a fake; the tool never does
    public static bool ReplyNeedsPublic = true;            // the tests use a loopback echo as "ping beacon"
    static readonly object _clk = new object();
    static bool _ahead, _exitHooked;
    static long _baseQpc, _baseRealTicks;
    static double _aheadSec;
    public static volatile bool RestoreOnLookup;           // armed by the tool right before the cut
    public static long JumpQpc, RestoreQpc, TriggerQpc;    // QPC = the ETW event clock
    // earliest DBD measurement lookup after the jump (event time)
    public static long FirstLookupQpc;
    public static string TriggerName = "", RestoreWhy = "", ClockError = "";
    public static string MarkerPath;                       // "clock is ahead" file, deleted once it's back
    static readonly List<long> _udpQpc = new List<long>(); // DBD ping-like UDP: +qpc = received, -qpc = sent

    // First DBD UDP packet (received or sent) at or after `fromQpc` (event clock); 0 = none seen.
    public static long FirstUdpAfter(long fromQpc, bool received) {
        long best = 0;
        lock (_lock) foreach (long v in _udpQpc) {
            if ((v > 0) != received) continue;
            long q = v > 0 ? v : -v;
            if (q >= fromQpc && (best == 0 || q < best)) best = q;
        }
        return best;
    }

    static bool RealSetClock(DateTime utc) {
        SystemTime st = new SystemTime();
        st.Year = (ushort)utc.Year;
        st.Month = (ushort)utc.Month;
        st.Day = (ushort)utc.Day;
        st.Hour = (ushort)utc.Hour;
        st.Minute = (ushort)utc.Minute;
        st.Second = (ushort)utc.Second;
        st.Ms = (ushort)utc.Millisecond;
        if (SetSystemTime(ref st)) return true;
        ClockError = "SetSystemTime error " + Marshal.GetLastWin32Error();
        return false;
    }
    static DateTime RealAt(long qpc) {
        return new DateTime(_baseRealTicks + (long)((qpc - _baseQpc) * (10000000.0 / Stopwatch.Frequency)),
            DateTimeKind.Utc);
    }
    public static DateTime UtcNow {
        get { lock (_clk) return _ahead ? RealAt(Stopwatch.GetTimestamp()) : DateTime.UtcNow; }
    }
    public static bool ClockAhead { get { lock (_clk) return _ahead; } }
    public static double ClockAheadSec { get { lock (_clk) return _ahead ? _aheadSec : 0; } }
    public static double QpcMs(long fromQpc, long toQpc) { return (toQpc - fromQpc) * 1000.0 / Stopwatch.Frequency; }

    public static bool JumpClock(double seconds) {
        lock (_clk) {
            ClockError = "";
            if (_ahead) { ClockError = "the clock is already ahead"; return false; }
            long q = Stopwatch.GetTimestamp();
            DateTime real = DateTime.UtcNow;
            if (!SetClock(real.AddSeconds(seconds))) {
                if (ClockError.Length == 0) ClockError = "the clock was not set";
                return false;
            }
            _baseQpc = q;
            _baseRealTicks = real.Ticks;
            _aheadSec = seconds;
            _ahead = true;
            JumpQpc = q;
            RestoreQpc = 0;
            TriggerQpc = 0;
            FirstLookupQpc = 0;
            TriggerName = "";
            RestoreWhy = "";
            if (!_exitHooked) {
                _exitHooked = true;
                AppDomain.CurrentDomain.ProcessExit += delegate { RestoreClock("tool exiting"); };
            }
            return true;
        }
    }
    public static bool RestoreClock(string why) {
        lock (_clk) {
            if (!_ahead) return true;
            long q = Stopwatch.GetTimestamp();
            if (!SetClock(RealAt(q))) return false;            // still ahead; the tool retries every second
            _ahead = false;
            RestoreOnLookup = false;
            RestoreQpc = q;
            RestoreWhy = why;
            DeleteMarker();
            return true;
        }
    }
    // Not through a junction / symbolic link (the folder is the user's; this runs as admin), like the script's writes.
    static void DeleteMarker() {
        try {
            string m = MarkerPath;
            if (m == null || !System.IO.File.Exists(m)) return;
            const System.IO.FileAttributes link = System.IO.FileAttributes.ReparsePoint;
            if ((System.IO.File.GetAttributes(System.IO.Path.GetDirectoryName(m)) & link) != 0 ||
                (System.IO.File.GetAttributes(m) & link) != 0)
                return;
            System.IO.File.Delete(m);
        } catch { }
    }

    static IntPtr NewProps(bool msFlush) {
        IntPtr p = Marshal.AllocHGlobal(PropsSize);
        for (int i = 0; i < PropsSize; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt32(p, 0, PropsSize);        // Wnode.BufferSize
        Marshal.WriteInt32(p, 40, 1);               // Wnode.ClientContext = QPC clock
        Marshal.WriteInt32(p, 44, 0x00020000);      // Wnode.Flags = WNODE_FLAG_TRACED_GUID
        Marshal.WriteInt32(p, 48, 64);              // BufferSize (KB)
        // LogFileMode = EVENT_TRACE_REAL_TIME_MODE (+ EVENT_TRACE_USE_MS_FLUSH_TIMER); FlushTimer = FlushMs ms or 1 s
        Marshal.WriteInt32(p, 64, msFlush ? 0x00000110 : 0x00000100);
        Marshal.WriteInt32(p, 68, msFlush ? FlushMs : 1);
        Marshal.WriteInt32(p, 116, 120);            // LoggerNameOffset
        return p;
    }

    public static void StopSession() {
        IntPtr p = NewProps(false);
        try { ControlTraceW(0, SessionName, p, 1); } finally { Marshal.FreeHGlobal(p); }   // EVENT_TRACE_CONTROL_STOP
    }

    public static bool Start() {
        if (_thread != null) return true;
        // The structure offsets below are the 64-bit ones (DBD itself only exists for 64-bit Windows).
        if (IntPtr.Size != 8) { LastError = "a 64-bit process is needed (this one is 32-bit)"; return false; }
        StopSession();                              // leftover from a run that did not exit cleanly
        MsFlush = true;
        IntPtr p = NewProps(true);
        try {
            uint rc = StartTraceW(out _session, SessionName, p);
            if (rc == 87) {                         // ms flush timer not accepted: fall back to 1 s
                Marshal.FreeHGlobal(p);
                p = NewProps(false);
                MsFlush = false;
                rc = StartTraceW(out _session, SessionName, p);
            }
            if (rc != 0) { LastError = "StartTrace error " + rc; return false; }
        } finally { Marshal.FreeHGlobal(p); }
        Guid g = KernelNetwork;
        uint e1 = EnableTraceEx2(_session, ref g, 1, 5, 0x10, 0, 0, IntPtr.Zero);   // UDP keyword
        g = DnsClient;
        uint e2 = EnableTraceEx2(_session, ref g, 1, 5, 0, 0, 0, IntPtr.Zero);
        if (e1 != 0 || e2 != 0) LastError = "EnableTrace net=" + e1 + " dns=" + e2;
        // One callback for the whole run: after a restart (UDP check) the old trace can still deliver its last
        // buffered events to the old pointer, so that delegate must never be collected.
        if (_cb == null) _cb = OnRecord;
        _loggerName = Marshal.StringToHGlobalUni(SessionName);
        _logfile = Marshal.AllocHGlobal(LogfileSize);
        for (int i = 0; i < LogfileSize; i++) Marshal.WriteByte(_logfile, i, 0);
        Marshal.WriteIntPtr(_logfile, 8, _loggerName);                                   // LoggerName
        // REAL_TIME | RAW_TIMESTAMP (event times stay QPC, unaffected by clock changes) | EVENT_RECORD
        Marshal.WriteInt32(_logfile, 28, 0x00000100 | 0x00001000 | 0x10000000);
        Marshal.WriteIntPtr(_logfile, 424, Marshal.GetFunctionPointerForDelegate(_cb));  // EventRecordCallback
        _trace = OpenTraceW(_logfile);
        if (_trace == ulong.MaxValue) {
            LastError = "OpenTrace error " + Marshal.GetLastWin32Error();
            StopSession();
            return false;
        }
        // also on unusual exits
        if (!_stopHooked) { _stopHooked = true; AppDomain.CurrentDomain.ProcessExit += delegate { Stop(); }; }
        _thread = new Thread(Pump);
        _thread.IsBackground = true;
        _thread.Start();
        return true;
    }

    static void Pump() { try { ProcessTrace(new ulong[] { _trace }, 1, IntPtr.Zero, IntPtr.Zero); } catch { } }

    public static void Stop() {
        try { if (_trace != 0) CloseTrace(_trace); } catch { }
        try { StopSession(); } catch { }
        _trace = 0;
        _thread = null;
    }

    static void OnRecord(IntPtr r) {
        try {
            // EVENT_HEADER.ProviderId: this session enables only two providers, so its first 4 bytes tell them apart
            // (no allocation per event - Kernel-Network reports every UDP packet on the PC).
            uint prov = (uint)Marshal.ReadInt32(r, 24);
            int id = (ushort)Marshal.ReadInt16(r, 40);                 // EventDescriptor.Id
            int hdrPid = Marshal.ReadInt32(r, 12);                     // EVENT_HEADER.ProcessId
            int len = (ushort)Marshal.ReadInt16(r, 86);                // UserDataLength
            IntPtr ud = Marshal.ReadIntPtr(r, 96);                     // UserData
            // EVENT_HEADER.TimeStamp (QPC, ClientContext = 1)
            long evQpc = Marshal.ReadInt64(r, 16);
            if (ud == IntPtr.Zero) return;
            if (prov == 0x7DD42A49u) {             // Microsoft-Windows-Kernel-Network
                if ((id != 42 && id != 43) || len < 20) return;       // UDPv4 send / receive
                int pid = Marshal.ReadInt32(ud, 0);
                if (ProbePid != 0 && pid == ProbePid) Interlocked.Increment(ref ProbeUdp);
                if (pid == 0 || pid != Pid) return;
                Interlocked.Increment(ref UdpEvents);
                long now = UtcNow.Ticks;                               // real time, also while the clock is ahead
                bool recv = (id == 43);
                uint a = (uint)Marshal.ReadInt32(ud, recv ? 12 : 8);    // remote = saddr on receive, daddr on send
                int pt = (ushort)Marshal.ReadInt16(ud, recv ? 18 : 16);
                int port = ((pt & 0xFF) << 8) | (pt >> 8);
                string ip = (a & 0xFF) + "." + ((a >> 8) & 0xFF) + "." + ((a >> 16) & 0xFF) + "." + (a >> 24);
                long keep = now - TimeSpan.FromSeconds(120).Ticks;
                lock (_lock) {
                    _udp.Enqueue(new KeyValuePair<long, string>(now, ip + ":" + port + (recv ? "|r" : "|s")));
                    while (_udp.Count > 0 && (_udp.Count > 40000 || _udp.Peek().Key < keep)) _udp.Dequeue();
                    // Event-clock times of DBD's ping-like UDP (not DNS/NTP), for the clock-jump check. Per-CPU buffers
                    // can deliver events out of order, so the check searches this list instead of tracking live.
                    if (port != 53 && port != 123 && (!ReplyNeedsPublic || IsPublic(ip))) {
                        _udpQpc.Add(recv ? evQpc : -evQpc);
                        if (_udpQpc.Count > 20000) _udpQpc.RemoveRange(0, 10000);
                    }
                }
            } else if (prov == 0x1C95126Eu) {      // Microsoft-Windows-DNS-Client
                // query called / query completed: field 1 = QueryName
                if ((id != 3006 && id != 3008) || len < 4) return;
                long now = UtcNow.Ticks;
                if (ProbePid != 0 && hdrPid == ProbePid) Interlocked.Increment(ref ProbeDns);
                if (hdrPid == OwnPid) return;
                string all = Marshal.PtrToStringUni(ud, len / 2);
                int z = all.IndexOf('\0');
                string name = (z >= 0 ? all.Substring(0, z) : all).TrimEnd('.');
                if (name.Length == 0) return;
                // 3008 payload: QueryName, QueryType u32, QueryOptions u64, QueryStatus u32, QueryResults string
                string results = null;
                int qstatus = -1;
                if (id == 3008 && z >= 0) {
                    int off = (z + 1) * 2;
                    if (len >= off + 16) {
                        qstatus = Marshal.ReadInt32(ud, off + 12);
                        results = Marshal.PtrToStringUni(new IntPtr(ud.ToInt64() + off + 16), (len - off - 16) / 2);
                        int z2 = results.IndexOf('\0');
                        if (z2 >= 0) results = results.Substring(0, z2);
                    }
                }
                Interlocked.Increment(ref DnsEvents);
                // Only DBD's own lookups count: other programs can resolve the same GameLift names. DNS-Client
                // events carry the caller's pid.
                bool dbd = Pid != 0 && hdrPid == Pid;
                bool steer = dbd && SteerRx != null && SteerRx.IsMatch(name);
                LastDnsDelayMs = QpcMs(evQpc, Stopwatch.GetTimestamp());
                if (steer && RestoreOnLookup && TriggerQpc == 0) {     // DBD started measuring: clock back NOW
                    TriggerQpc = evQpc;
                    TriggerName = name;
                    RestoreClock("DBD started measuring (" + name + ")");
                }
                if (steer && JumpQpc != 0 && evQpc >= JumpQpc && (FirstLookupQpc == 0 || evQpc < FirstLookupQpc))
                    FirstLookupQpc = evQpc;
                lock (_lock) {
                    if (steer) {
                        _lastSteerTicks = now;
                        if (!name.StartsWith("gamelift-ping.", StringComparison.OrdinalIgnoreCase))
                            _lastSteerHttpTicks = now;
                        _steerTicks.Add(now);
                        if (_steerTicks.Count > 2000) _steerTicks.RemoveRange(0, 1000);
                        if (results != null) {
                            _steerResults.Add(now + "|" + name + "|" + qstatus + "|" + results);
                            if (_steerResults.Count > 2000) _steerResults.RemoveRange(0, 1000);
                        }
                    }
                    if (dbd && results != null) {
                        HashSet<string> set;
                        if (!_dbdResolved.TryGetValue(name, out set)) {
                            set = new HashSet<string>();
                            _dbdResolved[name] = set;
                        }
                        foreach (string tok in results.Split(';')) {
                            string t = tok.Trim();
                            if (t.StartsWith("::ffff:")) t = t.Substring(7);
                            System.Net.IPAddress ip;
                            bool v4 = t.IndexOf('.') > 0 && System.Net.IPAddress.TryParse(t, out ip) &&
                                ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork;
                            if (v4 && t != "0.0.0.0") set.Add(t);
                        }
                    }
                    if (dbd) {
                        long[] v;
                        if (!_dbdNames.TryGetValue(name, out v)) {
                            v = new long[] { now, now, 0 }; _dbdNames[name] = v;
                        }
                        v[1] = now;
                        v[2]++;
                    }
                    if (steer || dbd) {
                        // the console's own line format: time, then the kind
                        string dl = new DateTime(now,
                            DateTimeKind.Utc).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff")
                            + "  [dns] pid " + hdrPid + (dbd ? " (DBD)" : "") + "  ev " + id + "  " + name
                            + (results != null ? "  -> " + results.TrimEnd(';') : "");
                        _dnsNew.Add(dl);
                        if (_dnsNew.Count > 1000) _dnsNew.RemoveRange(0, 500);
                    }
                }
            }
        } catch { }
    }

    public static DateTime LastSteerUtc {
        get {
            long t;
            lock (_lock) t = _lastSteerTicks;
            return t == 0 ? DateTime.MinValue : new DateTime(t, DateTimeKind.Utc);
        }
    }

    // IPv4 addresses DBD itself got back for names matching `nameRx` (e.g. its BHVR backend).
    public static string[] ResolvedIps(string nameRx) {
        Regex rx = new Regex(nameRx, RegexOptions.IgnoreCase);
        HashSet<string> o = new HashSet<string>();
        lock (_lock)
            foreach (KeyValuePair<string, HashSet<string>> kv in _dbdResolved)
                if (rx.IsMatch(kv.Key)) o.UnionWith(kv.Value);
        string[] a = new string[o.Count];
        o.CopyTo(a);
        return a;
    }

    // Hostnames DBD looked up that resolved to this IPv4 (to name the connections the hold leaves alone).
    public static string NamesForIp(string ip) {
        List<string> o = new List<string>();
        lock (_lock)
            foreach (KeyValuePair<string, HashSet<string>> kv in _dbdResolved) if (kv.Value.Contains(ip)) o.Add(kv.Key);
        return string.Join(", ", o.ToArray());
    }

    public static DateTime LastSteerHttpUtc {
        get {
            long t;
            lock (_lock) t = _lastSteerHttpTicks;
            return t == 0 ? DateTime.MinValue : new DateTime(t, DateTimeKind.Utc);
        }
    }

    // Start of the latest burst of region-endpoint lookups (lookups closer together than gapSec belong to one round).
    public static DateTime RoundStartUtc(double gapSec) {
        long gap = TimeSpan.FromSeconds(gapSec).Ticks;
        lock (_lock) {
            if (_steerTicks.Count == 0) return DateTime.MinValue;
            int i = _steerTicks.Count - 1;
            while (i > 0 && _steerTicks[i] - _steerTicks[i - 1] <= gap) i--;
            return new DateTime(_steerTicks[i], DateTimeKind.Utc);
        }
    }

    // "ticks|name|status|results" for region-endpoint lookups completed in [fromUtc, toUtc].
    public static string[] SteerResults(DateTime fromUtc, DateTime toUtc) {
        List<string> o = new List<string>();
        lock (_lock) foreach (string s in _steerResults) {
            long t = long.Parse(s.Substring(0, s.IndexOf('|')));
            if (t >= fromUtc.Ticks && t <= toUtc.Ticks) o.Add(s);
        }
        return o.ToArray();
    }

    // "ip:port|sent|received" for DBD's UDP traffic in [fromUtc, toUtc] (last 120 s are kept).
    public static string[] UdpCounts(DateTime fromUtc, DateTime toUtc) {
        Dictionary<string, int[]> c = new Dictionary<string, int[]>();
        lock (_lock) foreach (KeyValuePair<long, string> kv in _udp) {
            if (kv.Key < fromUtc.Ticks || kv.Key > toUtc.Ticks) continue;
            int bar = kv.Value.LastIndexOf('|');
            string ep = kv.Value.Substring(0, bar);
            bool recv = kv.Value[bar + 1] == 'r';
            int[] v;
            if (!c.TryGetValue(ep, out v)) { v = new int[2]; c[ep] = v; }
            v[recv ? 1 : 0]++;
        }
        List<string> o = new List<string>();
        foreach (KeyValuePair<string, int[]> kv in c) o.Add(kv.Key + "|" + kv.Value[0] + "|" + kv.Value[1]);
        return o.ToArray();
    }

    // Names DBD looked up at or after `fromUtc` (last lookup time).
    public static string[] DbdNamesSince(DateTime fromUtc) {
        List<string> o = new List<string>();
        lock (_lock)
            foreach (KeyValuePair<string, long[]> kv in _dbdNames) if (kv.Value[1] >= fromUtc.Ticks) o.Add(kv.Key);
        return o.ToArray();
    }

    public static string[] DbdNames() {
        List<string> o = new List<string>();
        lock (_lock) foreach (KeyValuePair<string, long[]> kv in _dbdNames)
            o.Add(kv.Key + "|" + kv.Value[2] + "|" +
                new DateTime(kv.Value[1], DateTimeKind.Utc).ToLocalTime().ToString("HH:mm:ss"));
        o.Sort(StringComparer.OrdinalIgnoreCase);
        return o.ToArray();
    }

    // Not routable on the internet: this network, private, CGNAT, loopback, link-local, multicast and reserved.
    static readonly uint[,] NonPublic = { { 0x00000000, 8 }, { 0x0A000000, 8 }, { 0x64400000, 10 }, { 0x7F000000, 8 },
        { 0xA9FE0000, 16 }, { 0xAC100000, 12 }, { 0xC0A80000, 16 }, { 0xE0000000, 3 } };
    static bool IsPublic(string ip) {
        System.Net.IPAddress addr;
        if (!System.Net.IPAddress.TryParse(ip, out addr)) return false;
        byte[] o = addr.GetAddressBytes();
        if (o.Length != 4) return false;
        uint v = ((uint)o[0] << 24) | ((uint)o[1] << 16) | ((uint)o[2] << 8) | o[3];
        for (int i = 0; i < NonPublic.GetLength(0); i++) {
            uint mask = 0xFFFFFFFFu << (int)(32 - NonPublic[i, 1]);
            if ((v & mask) == NonPublic[i, 0]) return false;
        }
        return true;
    }

    // A public UDP peer that can be a game server ("ip:port"; not DNS, NTP, QUIC or STUN).
    static bool IsGamePeer(string ep) {
        int c = ep.LastIndexOf(':');
        int port = int.Parse(ep.Substring(c + 1));
        return !(port == 53 || port == 123 || port == 443 || port == 3478 || port == 3479) &&
            IsPublic(ep.Substring(0, c));
    }

    // The lobby / match server: of DBD's game-server-like UDP peers with at least minPackets in the last longSec
    // seconds, the one with the most packets in the last shortSec (null: none). packets = its count over longSec.
    public static string ActiveUdp(int longSec, int minPackets, int shortSec, out int packets, out int recent) {
        long lo = UtcNow.AddSeconds(-longSec).Ticks, sh = UtcNow.AddSeconds(-shortSec).Ticks;
        Dictionary<string, int[]> counts = new Dictionary<string, int[]>();
        lock (_lock) {
            foreach (KeyValuePair<long, string> kv in _udp) {
                if (kv.Key < lo) continue;
                string ep = kv.Value.Substring(0, kv.Value.LastIndexOf('|'));
                int[] n;
                if (!counts.TryGetValue(ep, out n)) { n = new int[2]; counts[ep] = n; }
                n[0]++;
                if (kv.Key >= sh) n[1]++;
            }
        }
        string best = null;
        packets = 0;
        recent = 0;
        foreach (KeyValuePair<string, int[]> kv in counts) {
            if (kv.Value[0] < minPackets || kv.Value[1] == 0 || !IsGamePeer(kv.Key)) continue;
            if (kv.Value[1] > recent || (kv.Value[1] == recent && kv.Value[0] > packets)) {
                recent = kv.Value[1];
                packets = kv.Value[0];
                best = kv.Key;
            }
        }
        return best;
    }
}

// AWS ip-ranges.json -> region, longest prefix wins (GAMELIFT > EC2 > AMAZON on equal length).
public static class AwsIpMap {
    class Entry { public uint Net, Mask; public int Len, Rank; public string Region, Service; }
    static volatile Entry[] _e = new Entry[0];   // swapped whole, never changed in place: Lookup needs no lock
    public static int Count { get { return _e.Length; } }

    public static int Load(string json) { Entry[] e = Parse(json); _e = e; return e.Length; }
    // Parsing the ~2 MB file takes ~150 ms: done on a worker thread so the window doesn't stall. The new list is used
    // only if it has at least minEntries (a cut-off download never replaces a good list). Result = entries parsed.
    public static System.Threading.Tasks.Task<int> LoadFileAsync(string path, int minEntries) {
        return System.Threading.Tasks.Task.Run(() => {
            Entry[] e = Parse(System.IO.File.ReadAllText(path));
            if (e.Length >= minEntries) _e = e;
            return e.Length;
        });
    }

    static Entry[] Parse(string json) {
        List<Entry> list = new List<Entry>();
        foreach (Match m in Regex.Matches(json, "\\{[^{}]*\"ip_prefix\"[^{}]*\\}")) {
            string s = m.Value;
            Match p = Regex.Match(s, "\"ip_prefix\"\\s*:\\s*\"([0-9.]+)/([0-9]+)\"");
            Match r = Regex.Match(s, "\"region\"\\s*:\\s*\"([^\"]+)\"");
            Match v = Regex.Match(s, "\"service\"\\s*:\\s*\"([^\"]+)\"");
            if (!p.Success || !r.Success || !v.Success) continue;
            string svc = v.Groups[1].Value;
            int rank = svc == "GAMELIFT" ? 0 : svc == "EC2" ? 1 : svc == "AMAZON" ? 2 : -1;
            if (rank < 0) continue;
            int len;
            System.Net.IPAddress a;
            // one malformed entry is skipped, not the whole list
            if (!int.TryParse(p.Groups[2].Value, out len) || len > 32 ||
                !System.Net.IPAddress.TryParse(p.Groups[1].Value, out a) || a.GetAddressBytes().Length != 4)
                continue;
            uint mask = len == 0 ? 0u : 0xFFFFFFFFu << (32 - len);
            Entry e = new Entry();
            e.Net = ToUInt(p.Groups[1].Value) & mask;
            e.Mask = mask;
            e.Len = len;
            e.Rank = rank;
            e.Region = r.Groups[1].Value;
            e.Service = svc;
            list.Add(e);
        }
        list.Sort(delegate (Entry x, Entry y) { int c = y.Len.CompareTo(x.Len); return c != 0 ? c :
            x.Rank.CompareTo(y.Rank);
        });
        return list.ToArray();
    }

    static uint ToUInt(string ip) {
        byte[] b = System.Net.IPAddress.Parse(ip).GetAddressBytes();
        return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
    }

    public static string Lookup(string ip) {
        uint a = ToUInt(ip);
        foreach (Entry e in _e) if ((a & e.Mask) == e.Net) return e.Region + "|" + e.Service;
        return null;
    }
}
