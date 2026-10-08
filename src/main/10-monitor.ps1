# ---------------- ETW-backed state ----------------
$script:EtwOk = $false
$script:EtwStartUtc = [DbdEtw]::UtcNow
$script:EtwErr = ''
try {
    [DbdEtw]::OwnPid = $PID
    [DbdEtw]::SteerRx = New-Object System.Text.RegularExpressions.Regex($SteerHostRx,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $script:EtwOk = [DbdEtw]::Start()
    $script:EtwErr = [DbdEtw]::LastError
    $script:EtwStartUtc = [DbdEtw]::UtcNow
} catch {
    $script:EtwOk = $false
    $script:EtwErr = $_.Exception.Message
}

# ---------------- monitor self-test ----------------
# Sends 3 UDP packets to 192.0.2.1 (TEST-NET-1: reserved for documentation, never routed or answered) and makes one DNS
# lookup of "localhost" (answered inside Windows' DNS client: same events, nothing sent to your DNS server), then checks
# this ETW session saw both. Answers "does Windows deliver the events this tool depends on?" - e.g. while another
# program's ETW session is running.
#   UDP events: lobby/match/end-game-chat detection before the cut, the Game server line, the clock option's check.
#   DNS events: seeing DBD measure (verification, and putting the clock back at the right moment).
$script:EtwHealth = $null
function Send-EtwProbe {   # the self-test's traffic; -Async: the lookup doesn't wait for its answer
    param([switch]$Async)
    [DbdEtw]::ProbeUdp = 0
    [DbdEtw]::ProbeDns = 0
    [DbdEtw]::ProbePid = $PID
    try {
        $u = New-Object System.Net.Sockets.UdpClient
        $b = [byte[]](1..8)
        for ($i = 0;$i -lt 3;$i++) { [void]$u.Send($b,$b.Length,'192.0.2.1',9) }
        $u.Close()
    } catch {}
    try {
        if ($Async) {
            [void][System.Net.Dns]::BeginGetHostAddresses('localhost',$null,$null)
        } else {
            [void][System.Net.Dns]::GetHostAddresses('localhost')
        }
    } catch {}
}
function Test-EtwHealth {
    if (-not $script:EtwOk) {
        $script:EtwHealth = @{ Udp = $false; Dns = $false; Text = 'ETW monitor off' }
        return $script:EtwHealth
    }
    Send-EtwProbe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 1000 -and ([DbdEtw]::ProbeUdp -lt 1 -or [DbdEtw]::ProbeDns -lt 1)) {
        Start-Sleep -Milliseconds 20
    }
    return (Complete-EtwProbe $sw.ElapsedMilliseconds)
}
# Background version (no freeze while waiting for events that may never come): send now, the tick finishes it.
$script:ProbeStarted = $null
function Start-EtwProbe {
    if (-not $script:EtwOk -or $script:ProbeStarted -or $script:UdpCheckRunning) { return }
    Send-EtwProbe -Async
    $script:ProbeStarted = [System.Diagnostics.Stopwatch]::StartNew()
}
function Step-EtwProbe {   # called every second
    $p = $script:ProbeStarted
    if (-not $p) { return }
    if (([DbdEtw]::ProbeUdp -gt 0 -and [DbdEtw]::ProbeDns -gt 0) -or $p.ElapsedMilliseconds -ge 1500) {
        $script:ProbeStarted = $null
        [void](Complete-EtwProbe $p.ElapsedMilliseconds)
    }
}
function Complete-EtwProbe {
    param([long]$Ms)
    [DbdEtw]::ProbePid = 0
    $r = @{ Udp = ([DbdEtw]::ProbeUdp -gt 0); Dns = ([DbdEtw]::ProbeDns -gt 0); Ms = $Ms; At = [DbdEtw]::UtcNow }
    $udpText = if ($r.Udp) { 'OK' } else { 'not received' }
    $dnsText = if ($r.Dns) { 'OK' } else { 'not received' }
    $r.Text = "UDP events $udpText, DNS events $dnsText"
    $old = $script:EtwHealth
    $script:EtwHealth = $r
    # log changes only (it repeats every minute)
    if (-not $old -or $old.Text -ne $r.Text) { Write-Log "Monitor self-test: $($r.Text)" }
    # UDP just stopped arriving: the tick runs the check (not mid-action)
    if ($old -and $old.Udp -and -not $r.Udp -and -not $script:UdpCheckRunning) { $script:UdpFixDue = $true }
    return $r
}
[void](Test-EtwHealth)

# ---------------- when UDP events stop arriving: find out why, offer the fix ----------------
# UDP events come from Windows' Kernel-Network provider, which other programs can run their own ETW sessions on too.
# Windows sometimes stops delivering them to a session; a change to the provider from any session can bring them back.
# The check tries, re-testing after each step so the log says what fixed it:
#   1) a second session of this tool briefly enables the provider (harmless, so it doesn't ask),
#   2) this tool's own session is restarted,
#   3) other programs' sessions are offered for stopping, one at a time, each only if you say yes.
$KernelNetGuid = [Guid]'7DD42A49-5329-4832-8DFD-43D979153A88'
# Sessions Windows runs itself: never offered for stopping.
$WindowsSessionRx = ('^(EventLog-|NT Kernel Logger$|Circular Kernel Context Logger$|DiagLog$|DiagTrack|Diagtrack|' +
    'LwtNetLog$|NetCore$|WiFiSession$|RadioMgr$|UBPM$|SgrmEtwSession$|Microsoft|MSDTC|WdiContextLog$|ReFSLog$|' +
    'SleepStudy|Audio$|PerfDiag)')
$script:NetListenersUtc = [DateTime]::MinValue
$script:NetListeners = @()
function Get-NetListeners {
    # Other ETW sessions receiving Kernel-Network events: @{ Name; Windows; RealTime; Lost }. Cached 30 s (a few ms; no
    # process is started). Callers wrap the result in @().
    param([switch]$Fresh)
    if (-not $Fresh -and ([DbdEtw]::UtcNow-$script:NetListenersUtc).TotalSeconds -lt 30) { return $script:NetListeners }
    $o = @()
    try {
        foreach ($s in [EtwSessions]::ForProvider($KernelNetGuid)) {
            $f = $s.Split('|')
            if ($f[0] -eq [DbdEtw]::SessionName) { continue }
            $o += @{
                Name = $f[0]
                Keywords = $f[1]
                RealTime = ($f[2] -eq '1')
                Lost = [int64]$f[3]
                Windows = ($f[0] -match $WindowsSessionRx)
            }
        }
    } catch {}
    $script:NetListeners = $o
    $script:NetListenersUtc = [DbdEtw]::UtcNow
    return $o
}
function Get-NetListenersText {
    param($L)
    $L = @($L | Where-Object { $_ })
    if (-not $L.Count) { return 'none' }
    $names = foreach ($x in @($L)) {
        $who = if ($x.Windows) { ' (Windows)' } else { '' }
        $x.Name + $who
    }
    return (@($names) -join '; ')
}
function Get-EtwImpactText {
    param($H)
    if ($H.Udp -and $H.Dns) { return 'Self-test: UDP and DNS events both arrive.' }
    if (-not $H.Udp -and -not $H.Dns) {
        return "Self-test: no UDP or DNS events arrive, so the tool can't see a lobby, match or end game " +
            "chat, or DBD measure."
    }
    if (-not $H.Udp) {
        return "Self-test: no UDP events arrive, so the tool can't tell when you're in a lobby, match or end game " +
            "chat, or see the game server."
    }
    return "Self-test: no DNS events arrive, so the tool can't see DBD measure (to check a switch or " +
        "time the clock option)."
}
function Restart-EtwMonitor {
    # Stop and start this tool's own ETW session (what it has recorded so far is kept). Not while an action runs or
    # while the clock is ahead: the clock option needs the session to put the clock back.
    if ($script:Busy -or [DbdEtw]::ClockAhead) { return $false }
    [DbdEtw]::Stop()
    Start-Sleep -Milliseconds 300
    $script:EtwOk = [DbdEtw]::Start()
    $script:EtwErr = [DbdEtw]::LastError
    $result = if ($script:EtwOk) { 'running' } else { "failed: $($script:EtwErr)" }
    Write-Log "UDP check: restarted this tool's ETW session - $result"
    Start-Sleep -Milliseconds 500
    return $script:EtwOk
}
$script:FixDeclined = @{}
$script:UdpFixDue = $false
$script:LastSelfRestartUtc = [DateTime]::MinValue
$script:UdpCheckRunning = $false
function Repair-UdpMonitor {
    # -Manual: started from Options (always reports, also when nothing is wrong). Otherwise it only acts when UDP fails.
    # Never twice at once: its own self-tests would flag "UDP just stopped" and stack a second check behind the first
    # one's question.
    param([switch]$Manual)
    if ($script:UdpCheckRunning) { return }
    $script:UdpCheckRunning = $true
    if ($form) { $form.UseWaitCursor = $true }
    try {
        $h = Test-EtwHealth
        $L = @(Get-NetListeners -Fresh)
        if ($h.Udp) {
            if ($Manual) {
                [void](Show-Msg ("UDP monitoring works. Self-test: $($h.Text).`r`n`r`nOther programs' monitoring " +
                    "sessions on the same events: $(Get-NetListenersText $L)"))
            }
            return
        }
        $sessions = Get-NetListenersText $L
        Write-Log "UDP check: UDP events not received. Other sessions on the network provider: $sessions"
        # Order (see the block comment above): nudge, this tool's own session, other programs' sessions.
        $cands = @(@($L) | Where-Object {
            -not $_.Windows -and ($Manual -or -not $script:FixDeclined.ContainsKey($_.Name))
        })
        $selfDone = $false
        # 1) the nudge
        $rc = [EtwSessions]::Nudge('DBD-RegionSwitcher-Nudge',$KernelNetGuid,0x10,300)
        $h = Test-EtwHealth
        Write-Log ("UDP check: briefly enabled the network provider from a second session of this tool (result $rc) " +
            "- self-test now: $($h.Text)")
        if ($h.Udp) {
            Write-Log 'UDP check: fixed by the nudge'
            if ($Manual) {
                [void](Show-Msg ("UDP monitoring was not working. Briefly enabling Windows' network events from a " +
                    "second session fixed it."))
            }
            return
        }
        # $null stands for this tool's own session
        foreach ($c in @($null) + $cands) {
            if ($null -eq $c) {
                # This tool's own session: harmless, so no question (at most every 5 min unless you asked).
                if ($Manual -or ([DbdEtw]::UtcNow-$script:LastSelfRestartUtc).TotalMinutes -ge 5) {
                    $script:LastSelfRestartUtc = [DbdEtw]::UtcNow
                    $selfDone = $true
                    if (Restart-EtwMonitor) {
                        $h = Test-EtwHealth
                        if ($h.Udp) {
                            Write-Log "UDP check: fixed by restarting this tool's own session"
                            if ($Manual) {
                                [void](Show-Msg ("UDP monitoring was not working. Restarting the tool's " +
                                    "own session fixed it."))
                            }
                            return
                        }
                    }
                }
                continue
            }
            if ($form) { $form.UseWaitCursor = $false }
            $ans = Show-Msg ("UDP monitoring isn't working.`r`n`r`n$(Get-EtwImpactText $h)`r`n`r`nAnother program's " +
                "monitoring session gets the same events:`r`n   $($c.Name)`r`n`r`nStopping it only ends " +
                "that session; its program starts a new one when needed (a session outlives its program, so closing " +
                "the program wouldn't help).") 'YesNoCancel' 'Question' @{
                Yes = 'Stop it and test again'
                No = 'Skip it'
                Cancel = 'Stop checking'
            }
            if ($form) { $form.UseWaitCursor = $true }
            if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) {
                Write-Log 'UDP check: cancelled by you'
                return
            }
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
                $script:FixDeclined[$c.Name] = $true
                Write-Log "UDP check: you kept $($c.Name)"
                continue
            }
            # through Windows' API, not logman: no process is started and the session's name shows on no command line
            $rc = [EtwSessions]::StopByName($c.Name)
            Start-Sleep -Milliseconds 300
            $script:NetListenersUtc = [DateTime]::MinValue
            $gone = switch ($rc) {
                0 {'stopped'}
                4201 {'it was already gone'}
                default {"Windows error $rc"}
            }
            $h = Test-EtwHealth
            Write-Log ("UDP check: stop $($c.Name): $gone - self-test now: $($h.Text)")
            if ($h.Udp) {
                [void](Show-Msg "Fixed: after stopping '$($c.Name)', UDP events arrive again.")
                return
            }
        }
        $sys = @($L | Where-Object { $_.Windows })
        $none = if (-not $cands.Count) {
            $tried = if ($selfDone) {
                'neither the nudge nor restarting the tool''s own session helped'
            } else {
                'the nudge didn''t help'
            }
            " No other program's monitoring session uses these events, and $tried."
        } else {
            ''
        }
        $win = if ($sys.Count) {
            " (Windows' own sessions on it, not touched: $((@($sys | ForEach-Object { $_.Name })) -join ', ').)"
        } else {
            ''
        }
        Write-Log 'UDP check: still not received'
        if ($form) { $form.UseWaitCursor = $false }
        [void](Show-Msg ("UDP events still don't arrive.$none$win`r`n`r`nSomething else (security software, for " +
            "example) may be blocking them; a reboot clears every monitoring session. Steering, the cut and the " +
            "check of DBD's measurement still work; only lobby / match detection and the GAME SERVER " +
            "line need UDP events.") 'OK' 'Warning')
    } finally {
        $script:UdpCheckRunning = $false
        $script:UdpFixDue = $false
        if ($form) { $form.UseWaitCursor = $false }
    }
}
if ($script:EtwOk -and $script:EtwHealth -and -not $script:EtwHealth.Udp) {
    try { Repair-UdpMonitor } catch { Write-Log "UDP check failed: $($_.Exception.Message)" }
}
# Was the current DBD process started while we were already watching? Then every lookup it made is in the ETW record.
# If DBD was already running when the tool opened, lookups made before that are unknown.
$script:DbdPid = 0
$script:DbdSeenStart = $false
function Update-DbdPid {
    $p = Get-DbdProcess
    $id = if ($p) { $p.Id } else { 0 }
    if ($id -ne $script:DbdPid) {
        $script:DbdSeenStart = ($id -ne 0 -and $script:EtwOk -and $script:DbdPollCount -gt 0)
        $script:LastRoundEndUtc = $null          # new process = new measurer; its launch round sets this
        $st = if ($p) { Get-DbdStore $p } else { '' }
        $line = 'DBD not running'
        if ($id) {
            $line = "DBD running, pid $id"
            if ($st -ne 'Steam') { $line += " ($st version)" }
            if ($script:DbdSeenStart) { $line += ' (started while the tool was open)' }
        }
        Write-Log $line
        # remembered: Switch + Restart needs to know while DBD is closed
        if ($st -and $st -ne $script:DbdStore) {
            $script:DbdStore = $st
            Save-State
        }
        $script:DbdPid = $id
    }
    $script:DbdPollCount++
    [DbdEtw]::Pid = $id
}
$script:DbdPollCount = 0
Update-DbdPid

function Get-CurlSafeUtc {
    # Only relevant when DBD measures over HTTP (libcurl keeps its own 60 s DNS cache). In UDP-beacon mode every ping is
    # resolved through Windows, so no wait is needed beyond the gap between the two DNS flushes.
    # HTTP or unknown: 60 s after the last HTTP-endpoint lookup; if DBD was already running when we started watching,
    # also 60 s after we started (lookups before that are invisible to us).
    param([DateTime]$ClickUtc)
    if ($script:PingMode -eq 'UDP') { return [DateTime]::MinValue }
    $ttl = $CurlDnsTtlSec+$CurlSafetySec
    if (-not $script:EtwOk) { return $ClickUtc.AddSeconds($ttl) }
    $t = if ($script:DbdSeenStart) { [DateTime]::MinValue } else { $script:EtwStartUtc.AddSeconds($ttl) }
    $last = [DbdEtw]::LastSteerHttpUtc
    if ($last -ne [DateTime]::MinValue -and $last.AddSeconds($ttl) -gt $t) { $t = $last.AddSeconds($ttl) }
    return $t
}

$script:AwsMapTried = $false
$script:RegionCache = @{}
$script:AwsDl = $null
$script:AwsParse = $null
function Get-DownloadError {
    # '' when the task worked, otherwise why not. Cancelled means the tool gave up on a request that hung.
    param($Task)
    if ($Task.IsCanceled) { return 'no answer in time' }
    if ($Task.IsFaulted) { return $Task.Exception.GetBaseException().Message }
    return ''
}
function Initialize-AwsIpMap {
    # AWS ip-ranges.json (game-server region readout). Parsed on a worker thread (~150 ms); a stale/missing copy is
    # refreshed in the background (weekly), never on the window's thread. Called by the tick while either is pending.
    $f = Join-Path $AppDir 'ip-ranges.json'
    if ($script:AwsParse -and $script:AwsParse.Task.IsCompleted) {
        $P = $script:AwsParse
        $script:AwsParse = $null
        $err = Get-DownloadError $P.Task
        $n = if ($err) { 0 } else { $P.Task.Result }
        # A fresh download is kept only if it parsed to a full list (the real one has thousands of entries).
        if ($P.Fresh -and (Test-NoLink $AppDir,$f,"$f.tmp")) {
            try {
                if ($n -gt 1000) {
                    Move-Item -LiteralPath "$f.tmp" -Destination $f -Force
                } else {
                    if (-not $err) { $err = "only $n entries" }
                    Write-Log "AWS address list: the download didn't parse ($err), the previous copy stays in use"
                    [System.IO.File]::Delete("$f.tmp")
                }
            } catch {
                Write-Log "AWS address list: couldn't replace ip-ranges.json ($($_.Exception.Message))"
            }
        } elseif ($err) {
            Write-Log "AWS address list: ip-ranges.json couldn't be read ($err)"
        }
        $script:RegionCache = @{}
    }
    $dl = $script:AwsDl
    if ($dl -and -not $dl.Task.IsCompleted -and ([DbdEtw]::UtcNow-$dl.Started).TotalSeconds -gt 120) {   # hung download
        $dl.Client.CancelAsync()
    }
    if ($script:AwsDl -and $script:AwsDl.Task.IsCompleted -and -not $script:AwsParse) {
        $err = Get-DownloadError $script:AwsDl.Task
        $script:AwsDl.Client.Dispose()
        if ($err) { Write-Log "AWS address list: download failed ($err), tried again in 6 hours" }
        # Downloaded into memory, written here right after the link check (written by the download itself, the file
        # would land wherever the folder pointed by the time it finished).
        if (-not $err -and $script:AwsDl.Task.Result.Length -lt 64MB -and (Test-NoLink $AppDir,$f,"$f.tmp")) {
            try {
                [System.IO.File]::WriteAllBytes("$f.tmp",$script:AwsDl.Task.Result)
                $script:AwsParse = @{ Task = [AwsIpMap]::LoadFileAsync("$f.tmp",1001); Fresh = $true }
            } catch {
                Write-Log "AWS address list: couldn't save the download ($($_.Exception.Message))"
            }
        }
        $script:AwsDl = $null
    }
    if (-not $script:AwsMapTried -and -not $script:AwsDl -and -not $script:AwsParse) {
        $script:AwsMapTried = $true
        $old = (-not (Test-Path $f)) -or (((Get-Date)-(Get-Item $f).LastWriteTime).TotalDays -gt 7)
        if ((Test-Path $f) -and [AwsIpMap]::Count -eq 0) {
            $script:AwsParse = @{ Task = [AwsIpMap]::LoadFileAsync($f,1); Fresh = $false }
        }
        if ($old) {
            $wc = New-Object System.Net.WebClient
            $script:AwsDl = @{
                Client = $wc
                Started = [DbdEtw]::UtcNow
                Task = $wc.DownloadDataTaskAsync([Uri]'https://ip-ranges.amazonaws.com/ip-ranges.json')
            }
        }
    }
    return ([AwsIpMap]::Count -gt 0)
}
function Get-IpRegion {
    param([string]$Ip)
    if ($script:RegionCache.ContainsKey($Ip)) { return $script:RegionCache[$Ip] }
    if (-not (Initialize-AwsIpMap)) { return $null }
    $r = [AwsIpMap]::Lookup($Ip)
    $script:RegionCache[$Ip] = $r
    return $r
}

