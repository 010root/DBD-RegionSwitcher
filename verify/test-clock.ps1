# Test of the opt-in clock jump (needs admin for the ETW part). The REAL Windows clock is never changed:
# [DbdEtw]::SetClock is swapped for a fake that only records what the tool would have set.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$work = Join-Path $PSScriptRoot 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$text = [IO.File]::ReadAllText($src)
$m = [regex]::Match($text,"(?s)PSTypeName\]'DbdEtw'\)\.Type\)\s*\{\s*Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'could not find DbdEtw source' }
Add-Type -TypeDefinition $m.Groups[1].Value
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class FakeClock {
    public static List<DateTime> Calls = new List<DateTime>();
    public static bool Fail;
    public static bool Set(DateTime utc) { lock (Calls) Calls.Add(utc); return !Fail; }
}
'@
[DbdEtw]::SetClock = [Delegate]::CreateDelegate([DbdEtw+ClockSetter],[FakeClock].GetMethod('Set'))
$t = $null
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if (@('Get-RemeasureUtc','Get-CutGate','Get-ClockJumpPlan','Get-ClockJumpVerdict','Format-Dur') -contains $f.Name) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
$RemeasureCooldownSec = 600
$RemeasureMarginSec = 5
$ClockJumpMarginSec = 15
$ClockJumpMaxSec = 3600

$script:pass = 0
$script:fail = 0
function Check($name,[bool]$ok,$detail = '') {
    if ($ok) {
        $script:pass++
        "PASS  $name  $detail"
    } else {
        $script:fail++
        "FAIL  $name  $detail"
    }
}
function Calls { [FakeClock]::Calls.ToArray() }

# --- jump / restore with the fake setter ---
$r0 = [DateTime]::UtcNow
$ok = [DbdEtw]::JumpClock(600)
$c = Calls
Check 'jump: setter asked for real time + 600 s' ($ok -and $c.Count -eq 1 -and
    [Math]::Abs(($c[0]-$r0).TotalSeconds-600) -lt 1) ("asked " + $c[0].ToString('HH:mm:ss.fff') + " UTC")
Check 'jump: ClockAhead / ClockAheadSec' ([DbdEtw]::ClockAhead -and [DbdEtw]::ClockAheadSec -eq 600)
Start-Sleep -Milliseconds 300
$d = ([DbdEtw]::UtcNow-[DateTime]::UtcNow).TotalMilliseconds
Check 'while ahead, the tool''s UtcNow stays real time (QPC based)' ([Math]::Abs($d) -lt 50) ("diff {0:N1} ms" -f $d)
Check 'second jump refused while ahead' (-not [DbdEtw]::JumpClock(60) -and [DbdEtw]::ClockError -match 'already ahead')
$ok = [DbdEtw]::RestoreClock('test restore')
$c = Calls
$d = ($c[-1]-[DateTime]::UtcNow).TotalMilliseconds
Check 'restore: setter asked for real time' ($ok -and $c.Count -eq 2 -and
    [Math]::Abs($d) -lt 50) ("diff {0:N1} ms" -f $d)
Check 'restore: no longer ahead, reason kept' (-not [DbdEtw]::ClockAhead -and [DbdEtw]::RestoreWhy -eq 'test restore')
Check 'restore when not ahead is a no-op' ([DbdEtw]::RestoreClock('again') -and (Calls).Count -eq 2)

# --- failures ---
[FakeClock]::Fail = $true
Check 'jump fails cleanly if the clock cannot be set' (-not [DbdEtw]::JumpClock(600) -and -not [DbdEtw]::ClockAhead)
[FakeClock]::Fail = $false
[void][DbdEtw]::JumpClock(600)
[FakeClock]::Fail = $true
Check 'failed restore keeps it marked ahead (tool retries)' (-not [DbdEtw]::RestoreClock('x') -and [DbdEtw]::ClockAhead)
[FakeClock]::Fail = $false
Check 'retry succeeds' ([DbdEtw]::RestoreClock('retry') -and -not [DbdEtw]::ClockAhead)

# --- marker file is deleted once the clock is back ---
$mk = Join-Path $work 'clock-ahead-test.txt'
[IO.File]::WriteAllText($mk,'aheadSec=600')
[DbdEtw]::MarkerPath = $mk
[void][DbdEtw]::JumpClock(600)
Check 'marker kept while ahead' ([IO.File]::Exists($mk))
[void][DbdEtw]::RestoreClock('marker test')
Check 'marker deleted after restore' (-not [IO.File]::Exists($mk))
[DbdEtw]::MarkerPath = $null

# --- jump size planning (the script's own functions) ---
$now = [DateTime]::UtcNow
$script:EtwOk = $false
$p = Get-ClockJumpPlan
Check 'plan: refused with ETW off' (-not $p.Ok) $p.Why
$script:EtwOk = $true
$script:DbdSeenStart = $true
$script:LastRoundEndUtc = $null
$p = Get-ClockJumpPlan
Check 'plan: refused before the launch measurement' (-not $p.Ok) $p.Why
$script:LastRoundEndUtc = $now.AddSeconds(-100)
$p = Get-ClockJumpPlan
Check 'plan: 100 s after a round -> about 520 s ahead' ($p.Ok -and $p.Sec -ge 518 -and
    $p.Sec -le 522) ("{0} s: {1}" -f $p.Sec,$p.Why)
$script:LastRoundEndUtc = $now.AddSeconds(-700)
$p = Get-ClockJumpPlan
Check 'plan: window already open -> no jump' ($p.Ok -and $p.Sec -eq 0) $p.Why
$script:LastRoundEndUtc = $now.AddSeconds(3300)
$p = Get-ClockJumpPlan
Check 'plan: over the 60 min limit -> refused' (-not $p.Ok) $p.Why
$script:DbdSeenStart = $false
$script:LastRoundEndUtc = $null
$script:EtwStartUtc = $now.AddSeconds(-60)
$p = Get-ClockJumpPlan
Check 'plan: DBD already running at tool start -> worst case (~560 s)' ($p.Ok -and $p.Sec -ge 558 -and
    $p.Sec -le 562) ("{0} s" -f $p.Sec)

# --- live ETW: a child process plays DBD (lookups, then UDP pings to a loopback echo) ---
[DbdEtw]::SessionName = 'DBD-RegionSwitcher-ETW-clocktest'
[DbdEtw]::OwnPid = $PID
[DbdEtw]::ReplyNeedsPublic = $false
[DbdEtw]::SteerRx = [regex]::new('^(example\.com|gamelift-ping\.example\.org)$','IgnoreCase')
Check 'ETW session started' ([DbdEtw]::Start()) ([DbdEtw]::LastError)
Check 'events flushed every 5 ms' ([DbdEtw]::MsFlush -and [DbdEtw]::FlushMs -eq 5)
$echo = @'
$u = New-Object Net.Sockets.UdpClient(47771)
$u.Client.ReceiveTimeout = 15000
$ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
try {
    for ($i = 0; $i -lt 6; $i++) {
        $b = $u.Receive([ref]$ep)
        [void]$u.Send($b,$b.Length,$ep)
    }
} catch {}
$u.Close()
'@
$dbd = @'
Start-Sleep -Seconds 3
foreach ($n in 'gamelift-ping.example.org','example.com') {
    try { [void][Net.Dns]::GetHostAddresses($n) } catch {}
}
Start-Sleep -Milliseconds 100   # stands in for the real region lookup + network round trip (loopback has none)
$u = New-Object Net.Sockets.UdpClient
$u.Client.ReceiveTimeout = 3000
$ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
$b = New-Object byte[] 32
for ($i = 0; $i -lt 3; $i++) {
    [void]$u.Send($b,$b.Length,'127.0.0.1',47771)
    try { [void]$u.Receive([ref]$ep) } catch {}
    Start-Sleep -Milliseconds 50
}
$u.Close()
Start-Sleep -Seconds 1
'@
function Start-Fake {
    $script:ech = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command',$echo -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    $script:fk = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command',$dbd -PassThru -WindowStyle Hidden
    [DbdEtw]::Pid = $script:fk.Id
}
# Run 1: armed - the clock must go back on the first lookup, before the first ping reply
Start-Sleep -Seconds 1
[void][DbdEtw]::JumpClock(600)
[DbdEtw]::RestoreOnLookup = $true
Start-Fake
$fk.WaitForExit()
Start-Sleep -Seconds 1
Check 'run 1: clock put back by DBD''s measurement lookup' (-not [DbdEtw]::ClockAhead -and
    [DbdEtw]::RestoreWhy -like 'DBD started measuring*') ([DbdEtw]::RestoreWhy)
$lat = [DbdEtw]::QpcMs([DbdEtw]::TriggerQpc,[DbdEtw]::RestoreQpc)
Check 'run 1: lookup event -> clock back within 250 ms' ($lat -ge 0 -and
    $lat -lt 250) ("{0:N1} ms; last DNS event delivery delay {1:N1} ms" -f $lat,[DbdEtw]::LastDnsDelayMs)
$reply = [DbdEtw]::FirstUdpAfter([DbdEtw]::FirstLookupQpc,$true)
$detail = 'no loopback UDP events'
if ($reply) { $detail = "{0:N1} ms after the first lookup" -f [DbdEtw]::QpcMs([DbdEtw]::FirstLookupQpc,$reply) }
Check 'run 1: first ping reply seen on the event clock' ($reply -gt 0) $detail
$v = Get-ClockJumpVerdict
Check 'run 1: verdict = DBD saved the real time' ($v.Real) $v.Text
# Run 2: not armed - the clock goes back only after the pings: verdict must say "maybe jumped"
Start-Sleep -Seconds 1
[void][DbdEtw]::JumpClock(600)
[DbdEtw]::RestoreOnLookup = $false
Start-Fake
$fk.WaitForExit()
Start-Sleep -Seconds 1
[DbdEtw]::TriggerQpc = [DbdEtw]::FirstLookupQpc          # as if the lookup had triggered, but the restore came late
[void][DbdEtw]::RestoreClock('late on purpose')
$v = Get-ClockJumpVerdict
Check 'run 2: late restore -> verdict = DBD may have saved the jumped time' (-not $v.Real) $v.Text
try { $ech.Kill() } catch {}
[DbdEtw]::Stop()
Start-Sleep -Milliseconds 500
Check 'session stopped and removed' ($null -eq (logman query -ets | Select-String 'DBD-RegionSwitcher-ETW-clocktest'))
"fake setter calls: " + ((Calls | ForEach-Object { $_.ToString('HH:mm:ss.fff') }) -join ', ')
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
