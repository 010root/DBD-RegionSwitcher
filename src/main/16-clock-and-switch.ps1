# ---------------- opt-in clock jump ("Skip 10-min wait") ----------------
# DBD's gate compares Windows' clock (GetSystemTime) with the time it saved when its last measurement finished.
# Moving the clock ahead right before the cut makes the gate pass; the ETW thread puts it back the moment DBD's
# first measurement lookup arrives, so the time DBD saves at the end of that measurement is real (checked after
# each switch: clock back before DBD's first ping reply = DBD can't have finished yet).
$ClockJumpMarginSec = 15
$ClockJumpMaxSec = 3600
$ClockHoldMaxSec = 180
$script:ClockJump = $null
function Format-Dur {
    param([double]$Sec)
    $s = [int][Math]::Ceiling($Sec)
    if ($s -ge 60) { "{0}:{1:00} min" -f [Math]::Floor($s/60),($s%60) } else { "$s s" }
}
function Get-ClockJumpPlan {
    # How far ahead the clock must go for DBD's gate to pass at a cut now. Ok=$false: can't be used (Why says why).
    if (-not $script:EtwOk) {
        $why = "the ETW monitor is off, so the tool couldn't see DBD start measuring to put the clock back"
        return @{ Ok = $false; Sec = 0; Why = $why }
    }
    if (-not $script:LastRoundEndUtc -and $script:DbdSeenStart) {
        return @{ Ok = $false; Sec = 0; Why = "DBD's launch measurement hasn't been seen yet" }
    }
    $left = ((Get-CutGate).Utc-[DbdEtw]::UtcNow).TotalSeconds
    if ($left -le 0) {
        return @{ Ok = $true; Sec = 0; Why = "DBD's re-measure window is already open, so the clock won't be touched" }
    }
    $sec = [Math]::Ceiling($left+$ClockJumpMarginSec)
    if ($sec -gt $ClockJumpMaxSec) {
        $why = "the jump would be {0} (over the {1:N0} min limit)" -f (Format-Dur $sec),($ClockJumpMaxSec/60)
        return @{ Ok = $false; Sec = $sec; Why = $why }
    }
    return @{ Ok = $true; Sec = $sec; Why = ("the PC clock would go {0} ahead" -f (Format-Dur $sec)) }
}
function Invoke-ClockJump {
    param([double]$Sec)
    try {
        if (-not (Test-NoLink $AppDir,$ClockMarkPath)) {
            throw "the tool's folder or the marker file is a link (junction / symbolic link)"
        }
        $ahead = $Sec.ToString([Globalization.CultureInfo]::InvariantCulture)
        $mark = "aheadSec=$ahead`r`nrealUtc=$([DbdEtw]::UtcNow.ToString('o'))`r`n"
        [System.IO.File]::WriteAllText($ClockMarkPath,$mark,$Utf8NoBom)
        # the ETW thread deletes it once the clock is back (only a marker this run wrote)
        [DbdEtw]::MarkerPath = $ClockMarkPath
    } catch {
        [DbdEtw]::MarkerPath = $null
        Write-Log ("  clock: couldn't write the safety marker ($($_.Exception.Message)) - if the tool crashed now, " +
            "the next start wouldn't offer to fix the clock")
    }
    if (-not [DbdEtw]::JumpClock($Sec)) {
        Write-Log "  clock: could not move it ahead: $([DbdEtw]::ClockError)"
        Remove-ClockMark
        return $null
    }
    [DbdEtw]::RestoreOnLookup = $true
    $script:ClockJump = @{ Sec = $Sec; JumpUtc = [DbdEtw]::UtcNow; Classified = $false; Reported = $false }
    Write-Log (("  clock: moved {0:N0} s ahead; it goes back the moment DBD starts measuring (at " +
        "most {1} s from now)") -f $Sec,$ClockHoldMaxSec)
    return $script:ClockJump
}
function Update-ClockJump {
    # Every tick while a jump is active: safety restores, the readout, and one log line once the clock is back.
    $J = $script:ClockJump
    if (-not $J) { return }
    if ([DbdEtw]::ClockAhead) {
        $el = ([DbdEtw]::UtcNow-$J.JumpUtc).TotalSeconds
        $why = if (-not (Get-DbdProcess)) {
            'DBD closed'
        } elseif ($el -ge $ClockHoldMaxSec) {
            "DBD didn't start measuring within $ClockHoldMaxSec s"
        } else {
            $null
        }
        if ($why -and -not [DbdEtw]::RestoreClock($why)) {
            Write-Log "  clock: putting it back failed ($([DbdEtw]::ClockError)) - retrying"
        } elseif ($why -and $el -ge $ClockHoldMaxSec) {
            $min = $ClockHoldMaxSec/60
            Set-Status ("The PC clock went back: DBD didn't start measuring within $min min of the cut.$nl" +
                "If DBD is still on its main loading screen (error / press a key), its 10-min rule may now block the " +
                "measurement. Before you press a key, apply Switch (no restart) again or use Switch + Restart.") $cWarn
        }
    }
    if ([DbdEtw]::ClockAhead -and -not $J.DriftLogged) {
        # Something else set the clock meanwhile (e.g. Windows' internet time sync): DBD's 10-min rule may then not
        # pass. Putting it back is unaffected (real time comes from the PC's counter).
        $drift = ([DateTime]::UtcNow-[DbdEtw]::UtcNow).TotalSeconds-$J.Sec
        if ([Math]::Abs($drift) -gt 5) {
            $J.DriftLogged = $true
            Write-Log (("  clock: something else changed the PC clock while it was ahead (now {0:N0} s ahead instead " +
                "of {1:N0} s; e.g. Windows' internet time sync) - DBD's 10-min rule may not pass this time") -f
                ($J.Sec + $drift),$J.Sec)
        }
    }
    if ([DbdEtw]::ClockAhead) {
        Set-Info $lblNext @(
            @('PC clock is ',$cText,$false),
            @((Format-Dur $J.Sec),$cClockCat,$true),
            @(' ahead',$cClockCat,$false),
            @((' until DBD starts measuring (at most {0:N0} s more)' -f [Math]::Max(0,$ClockHoldMaxSec-$el)),$cDim,
                $false)) $cClockCat
        if (-not $script:Busy -and -not $btnSkip.Visible) {
            $btnSkip.Text = 'Put clock back now'
            $btnSkip.Enabled = $true
            $btnSkip.Visible = $true
            Update-SwitchOptions
        }
    } elseif (-not $J.Reported) {
        $J.Reported = $true
        Remove-ClockMark
        if (-not $script:Busy) {
            $btnSkip.Visible = $false
            Update-SwitchOptions
        }
        $lat = if ([DbdEtw]::TriggerQpc) {
            $after = [DbdEtw]::QpcMs([DbdEtw]::TriggerQpc,[DbdEtw]::RestoreQpc)
            "{0:N0} ms after DBD's lookup of {1} (events reach the tool within ~{2:N0} ms)" -f $after,
                [DbdEtw]::TriggerName,[DbdEtw]::LastDnsDelayMs
        } else {
            'no DBD measurement lookup seen before that'
        }
        $aheadSec = [DbdEtw]::QpcMs([DbdEtw]::JumpQpc,[DbdEtw]::RestoreQpc) / 1000
        Write-Log ("  clock: back to real time - {0}; {1}. It was ahead for {2:N1} s." -f [DbdEtw]::RestoreWhy,$lat,
            $aheadSec)
        if ($script:NgenOpt -and $NgenInstalled) { Start-NGenuityRestart }
    }
}
# HyperX NGENUITY resets the mouse colors when the clock changes (a manual change in Windows Settings does it too); a
# fresh start of its background part reloads the saved preset.
$NgenAumid = '33C30B79.NGENUITY_922sw8z9z7n5w!App'
# from the account, not %LOCALAPPDATA%
$NgenInstalled = Test-Path -LiteralPath (Join-Path $prof 'AppData\Local\Packages\33C30B79.NGENUITY_922sw8z9z7n5w')
# Why (NGenuity2Helper 2.33): its lighting timing uses the wall clock (DateTime.Now). A frame is only sent to the device
# when Now - last frame >= interval, and effects run on Now - start; after the clock goes back, both stall until real
# time catches up with the jump. A fresh process starts with fresh timestamps.
# How: NGenuity2Helper is the tray process that runs the lighting; NGenuity2 is the app (its window, or hidden in the
# background). Both are ended at once (a normal close request doesn't end them) and only the helper is started again -
# inside NGENUITY's package, the way Windows starts it at sign-in (Invoke-CommandInDesktopPackage), by a hidden
# PowerShell started as you through the desktop, its command in plain text. (It can't be started from here: Windows
# refuses its file outside the package, and the in-package start hangs when asked by an admin process.) The helper
# brings the app back in the background by itself: no window, ~1 s. If the helper isn't back within 8 s (security
# software can block the start, and does block an encoded command), the fallback opens the app and closes its window
# again, and the quick way isn't tried again for 30 days.
$NgenHelperCmd = ("`$p = Get-AppxPackage -Name '33C30B79.NGENUITY'; Invoke-CommandInDesktopPackage " +
    "-PackageFamilyName `$p.PackageFamilyName -AppId 'App' -Command (Join-Path `$p.InstallLocation " +
    "'Assets\Native\NGenuity2Helper.exe')")
$NgenLoadSec = 5
$NgenQuickRetryDays = 30
$script:NgenRestart = $null
function Start-NGenuityHelper {
    Open-AsUser (Join-Path $Sys32 'WindowsPowerShell\v1.0\powershell.exe') ("-NoProfile -NonInteractive -WindowStyle " +
        "Hidden -Command $NgenHelperCmd") 0
}
function Start-NGenuityRestart {
    $procs = @(Get-Process -Name 'NGenuity2Helper','NGenuity2' -ErrorAction SilentlyContinue)
    if (-not $procs.Count) {
        Write-Log '  NGENUITY: not running - nothing to do'
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    [void](Wait-Until { -not (Get-Process -Name 'NGenuity2Helper','NGenuity2' -ErrorAction SilentlyContinue) } 2000)
    $script:NgenRestart = @{ Stage = 'starting'; Since = [DbdEtw]::UtcNow; Sw = $sw }
    if (([DbdEtw]::UtcNow-$script:NgenQuickFailUtc).TotalDays -lt $NgenQuickRetryDays) {
        $script:NgenRestart.Since = [DateTime]::MinValue   # the quick way failed lately: straight to the app
        return
    }
    try { Start-NGenuityHelper } catch {
        # straight to the fallback
        Write-Log "  NGENUITY: the quick start couldn't be asked for ($($_.Exception.Message))"
        $script:NgenRestart.Since = [DateTime]::MinValue
    }
}
function Step-NGenuityRestart {   # every second while a restart runs
    $R = $script:NgenRestart
    if (-not $R) { return }
    $el = ([DbdEtw]::UtcNow-$R.Since).TotalSeconds
    $helper = @(Get-Process -Name 'NGenuity2Helper' -ErrorAction SilentlyContinue)
    $gui = @(Get-Process -Name 'NGenuity2' -ErrorAction SilentlyContinue)
    switch ($R.Stage) {
        'starting' {
            if ($helper.Count) {
                Write-Log ("  NGENUITY: restarted in {0:N1} s, no window (its helper started inside its package)" -f
                    $R.Sw.Elapsed.TotalSeconds)
                $script:NgenRestart = $null
            } elseif ($el -ge 8) {
                if ($R.Since -ne [DateTime]::MinValue) {
                    $script:NgenQuickFailUtc = [DbdEtw]::UtcNow
                    Save-State
                    Write-Log ("  NGENUITY: its helper didn't come back the quick way within 8 s (security software " +
                        "may block it) - opening the app instead, and the next $NgenQuickRetryDays days too")
                } else {
                    Write-Log '  NGENUITY: opening the app (its window shows for a few seconds)'
                }
                try { Open-AsUser "shell:AppsFolder\$NgenAumid" } catch {
                    Write-Log "  NGENUITY: starting it again failed: $($_.Exception.Message)"
                    $script:NgenRestart = $null
                    return
                }
                $R.Stage = 'app'
                $R.Since = [DbdEtw]::UtcNow
            }
        }
        'app' {
            if ($helper.Count -and $gui.Count) {
                $R.Stage = 'loading'
                $R.Since = [DbdEtw]::UtcNow
            } elseif ($el -ge 20) {
                Write-Log "  NGENUITY: started again; its window didn't show up within 20 s, so nothing was closed"
                $script:NgenRestart = $null
            }
        }
        'loading' {
            if ($el -lt $NgenLoadSec) { return }
            foreach ($p in $gui) { & (Join-Path $Sys32 'taskkill.exe') /PID $p.Id 2>&1 | Out-Null }
            $R.Stage = 'closing-window'
            $R.Since = [DbdEtw]::UtcNow
        }
        'closing-window' {
            if ($gui.Count -and $el -lt 3) { return }
            if ($gui.Count) { $gui | Stop-Process -Force -ErrorAction SilentlyContinue }
            $inTray = [bool](Get-Process -Name 'NGenuity2Helper' -ErrorAction SilentlyContinue)
            Write-Log ("  NGENUITY: restarted in {0:N1} s (the old way); window closed, still in the tray: {1}" -f
                $R.Sw.Elapsed.TotalSeconds,$inTray)
            $script:NgenRestart = $null
        }
    }
}
function Complete-NGenuityRestartNow {
    # The tool is closing while NGENUITY is closed and not back yet. A quick start already on its way gets 3 s to
    # finish; otherwise the app is started so NGENUITY isn't left off (its window stays open then; there's no tool
    # left to close it).
    $R = $script:NgenRestart
    if ($R -and $R.Stage -eq 'starting' -and $R.Since -ne [DateTime]::MinValue) {
        [void](Wait-Until { Get-Process -Name 'NGenuity2Helper' -ErrorAction SilentlyContinue } 3000)
    }
    if (Get-Process -Name 'NGenuity2Helper' -ErrorAction SilentlyContinue) {
        $script:NgenRestart = $null
        return
    }
    try {
        Open-AsUser "shell:AppsFolder\$NgenAumid"
        Write-Log '  NGENUITY: started again because the tool was closed mid-restart'
    } catch {
        Write-Log "  NGENUITY: couldn't start it again ($($_.Exception.Message))"
    }
    $script:NgenRestart = $null
}
function Get-ClockJumpVerdict {
    # Did DBD finish measuring before the clock went back? It can't finish before its first ping reply arrives, so
    # clock back before that reply = DBD saved the real time. Compared on the ETW event clock (QPC), not delivery time.
    if ([DbdEtw]::ClockAhead) {
        return @{ Real = $false; Text = 'the clock was still ahead when the measurement ended' }
    }
    if (-not [DbdEtw]::TriggerQpc) {
        return @{ Real = $true; Text = 'the clock was already back when DBD started measuring' }
    }
    $look = [DbdEtw]::FirstLookupQpc
    if (-not $look) { $look = [DbdEtw]::TriggerQpc }
    $reply = [DbdEtw]::FirstUdpAfter($look,$true)
    if (-not $reply) {
        return @{
            Real = $false
            Text = "no ping reply was visible (no UDP events), so it's unknown whether the clock was back in time"
        }
    }
    $m = [DbdEtw]::QpcMs([DbdEtw]::RestoreQpc,$reply)
    if ($m -gt 0) {
        return @{ Real = $true; Text = ("the clock was back {0:N0} ms before DBD's first ping reply arrived" -f $m) }
    }
    return @{ Real = $false; Text = ("the clock went back {0:N0} ms after DBD's first ping reply arrived" -f (-$m)) }
}

function Wait-ForCutWindow {
    # Hold the cut until (1) DBD's re-measure gate is open (cooldown since its last measurement; skipped with
    # -IgnoreGate when the clock jump handles it), (2) DBD has no match-server link for 3 s (a cut there only lands on
    # the main menu instead of the error + main loading screen), and (3) $UntilUtc.
    # Returns 'cut' when it's time, 'cancel' if the user cancelled, 'closed' if DBD exited. There is deliberately no
    # way to force an early cut: inside the window a reset leaves every region at 20000 ms -> backend default region.
    # -ForRestart: Switch + Restart uses the same wait (no gate) so it doesn't close DBD in the middle of a match.
    param([string]$Prefix,[DateTime]$UntilUtc = [DateTime]::MinValue,[switch]$IgnoreGate,[switch]$ForRestart)
    $script:SkipWait = $false
    $btnSkip.Text = 'Cancel'
    $btnSkip.Visible = $true
    $btnSkip.Enabled = $true
    $quietSince = $null
    $loggedLink = $false
    $loggedGate = $false
    try {
        while (-not $script:SkipWait) {
            if (-not (Get-DbdProcess)) { return 'closed' }
            $now = [DbdEtw]::UtcNow
            $gate = if ($IgnoreGate) {
                $why = 'the clock option skips the 10-min wait'
                if ($ForRestart) { $why = 'a restart needs no 10-min wait' }
                @{ Utc = [DateTime]::MinValue; Why = $why }
            } else {
                Get-CutGate
            }
            if (-not $loggedGate) {
                Write-Log ("  cut gate: " + $gate.Why)
                $loggedGate = $true
            }
            $link = ([DbdEtw]::UdpEvents -gt 0) -and (Test-MatchLink)
            if ($link) {
                $quietSince = $null
                if (-not $loggedLink) {
                    Write-Log '  holding the cut: match-server UDP link active'
                    $loggedLink = $true
                }
            } elseif (-not $quietSince) {
                $quietSince = $now
            }
            $quietLeft = if ($quietSince) { 1-($now-$quietSince).TotalSeconds } else { 1 }
            $untilLeft = [Math]::Max(($UntilUtc-$now).TotalSeconds,($gate.Utc-$now).TotalSeconds)
            if (-not $link -and $quietLeft -le 0 -and $untilLeft -le 0) { return 'cut' }
            $lines = @($Prefix)
            if ($untilLeft -gt 0) {
                $left = if ($untilLeft -ge 60) {
                    "{0}:{1:00} min" -f [Math]::Floor($untilLeft/60),[Math]::Floor($untilLeft%60)
                } else {
                    "{0:N0} s" -f [Math]::Ceiling($untilLeft)
                }
                $lines += ("Waiting {0}: {1}." -f $left,$gate.Why)
            }
            if ($link) {
                $lines += if ($ForRestart) {
                    ('Match server link: you''re in a lobby, match or end game chat. DBD is closed once you leave it ' +
                        '(closing it in a match is a disconnect).')
                } else {
                    ('Match server link: you''re in a lobby, match or end game chat. The cut follows a few seconds ' +
                        'after you leave it (a cut there doesn''t bring up the error).')
                }
            }
            if ($script:EtwHealth -and -not $script:EtwHealth.Udp) {
                $before = if ($ForRestart) { 'DBD is closed' } else { 'the cut' }
                $lines += "=> UDP monitoring isn't working, so the tool can't tell when you're in a lobby, match or " +
                    "end game chat: leave it before $before."
            }
            $lines += "Cancel (or Esc): stops here and puts hosts back as it was. DBD hasn't been touched."
            Set-Status ($lines -join $nl) $cWarn
            for ($k = 0;$k -lt 3;$k++) {
                Start-Sleep -Milliseconds 100
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        Write-Log '  cancelled by user while waiting'
        return 'cancel'
    } finally { $btnSkip.Visible = $false }
}
# BHVR backend hosts DBD connects to (seen in its DNS lookups), plus any other *.bhvrdbd.com name DBD resolves.
$BackendNames = @('steam.live.bhvrdbd.com','rtm.live.bhvrdbd.com','gamelogs.live.bhvrdbd.com',
    'cdn-steam.live.bhvrdbd.com')
function Get-BackendIps {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ip in [DbdEtw]::ResolvedIps('\.bhvrdbd\.com$')) { [void]$set.Add($ip) }      # what DBD itself got
    foreach ($n in $BackendNames) {
        try {
            Resolve-DnsName -Name $n -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | ForEach-Object {
                [void]$set.Add($_.IPAddress)
            }
        } catch {}
    }
    return ,@($set)
}
function Invoke-HoldCut {
    # The connection-lost reset (connection error, back to its main loading screen, OK, press a key, it re-measures
    # there) needs DBD to stay unable to reach its backend: after a one-shot cut it reconnects within moments.
    # So after the original kill, keep killing every DBD connection to BHVR's backend until the user sees the
    # error, or 120 s. DBD's other connections (addresses not on that list) are left alone during the hold.
    $p = Get-DbdProcess
    if (-not $p) { return 'DBD closed.' }
    $ips = Get-BackendIps
    $u = [uint32[]]@($ips | ForEach-Object { ConvertTo-UintIp $_ })
    Write-Log ("  hold: targeting DBD connections to {0} backend IPs: {1}" -f $ips.Count,($ips -join ', '))
    if (-not $ips.Count) {
        Write-Log '  hold: no backend IPs known - nothing to hold'
        return 'No BHVR backend addresses known, so the cut could not be held.'
    }
    $start = [DbdEtw]::UtcNow
    $kills = 0
    $lastUi = [DateTime]::MinValue
    $lastLog = $start
    $others = ''
    $seenOther = @{}
    $script:SkipWait = $false
    $btnSkip.Text = 'DBD shows the error'
    $btnSkip.Visible = $true
    $btnSkip.Enabled = $true
    try {
        while (-not $script:SkipWait) {
            $el = ([DbdEtw]::UtcNow-$start).TotalSeconds
            if ($el -ge 120) {
                Write-Log '  hold: 120 s limit reached'
                break
            }
            if ($p.HasExited) {
                Write-Log '  hold: DBD process ended'
                break
            }
            $k = [TcpKill]::KillPidRemotes([uint32]$p.Id,$u,[ref]$others)
            $kills += $k
            # one per address: DBD often has two connections to the same one
            $others = (@($others -split ' ' | Where-Object { $_ } | Select-Object -Unique) -join ' ')
            $notCut = if ($others) { $others } else { 'none' }
            foreach ($o in ($others -split ' ')) {
                if ($o -and -not $seenOther.ContainsKey($o)) {
                    $seenOther[$o] = $true
                    Write-Log "  hold: left alone (not a BHVR address): $(Get-EndpointName $o)"
                }
            }
            if ($k -gt 0 -and ([DbdEtw]::UtcNow-$lastLog).TotalSeconds -ge 5) {
                $lastLog = [DbdEtw]::UtcNow
                Write-Log (("  hold {0:N0} s: {1} kills so far; DBD connections not cut (not on the " +
                    "BHVR address list): {2}") -f $el,$kills,$notCut)
            }
            if (([DbdEtw]::UtcNow-$lastUi).TotalMilliseconds -ge 500) {
                $lastUi = [DbdEtw]::UtcNow
                Set-Status (("Holding the connection loss ({0:N0} s, {1} cuts): DBD can't reach BHVR's servers.${nl}" +
                    "When DBD shows its connection error, click the 'DBD shows the error' button, then in DBD click " +
                    "OK and press a key. Stops by itself after 120 s.${nl}${nl}Left alone: {2} (not BHVR addresses; " +
                    "named in the console)") -f $el,$kills,$notCut) $cWarn
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }
    } finally { $btnSkip.Visible = $false }
    $el = ([DbdEtw]::UtcNow-$start).TotalSeconds
    if ($script:SkipWait) {
        $why = if ($script:Closing) { 'window closed' } else { 'DBD showed the error' }
        Write-Log ("  hold: stopped after {0:N0} s ({1}), {2} kills" -f $el,$why,$kills)
    }
    Invoke-DnsFlush
    return ("Held the connection loss for {0:N0} s ({1} cuts)." -f $el,$kills)
}
function Set-Busy {
    param([bool]$On)
    $script:Busy = $On
    Update-SwitchOptions
    foreach ($b in $allButtons) {
        if ($b -ne $btnSkip -and $b -ne $btnOptions -and $b -ne $btnConsole) { $b.Enabled = (-not $On) }
    }
    if (-not $On) { $btnApply.Enabled = [bool]$script:Selected }
}

function Confirm-Apply {
    param([string]$Key)
    # Cases where Apply is most likely not what you meant: asks first, Enter = Cancel. A Switch / Restart to the region
    # already steered, Remove / Repair before DBD re-measured after a cut (it would measure unsteered), and a Repair
    # that would delete other programs' hosts entries.
    $cur = Get-CurrentSteering
    $dbd = [bool](Get-DbdProcess)
    # it would only change hosts, or nothing (see its description): no question
    $pending = ($Key -eq 'Switch' -and (Get-PendingCut))
    if (($Key -eq 'Switch' -or $Key -eq 'Restart') -and $dbd -and -not $pending -and
        $cur.Code -eq $script:PickCode -and $cur.Exact) {
        $nm = Get-PickName $script:PickCode
        $what = if ($Key -eq 'Switch') {
            ("Apply wouldn't change hosts; it would only cut DBD's connection so it re-measures. That only helps if " +
                "DBD still placed you elsewhere, e.g. after a cut that came too early.")
        } else {
            "Apply wouldn't change hosts; it would only restart DBD."
        }
        $yes = if ($Key -eq 'Switch') { 'Re-measure anyway' } else { 'Restart anyway' }
        $ask = "You're already steered to $nm.$nl$nl$what$nl${nl}Do it anyway?"
        $r = Show-Msg $ask 'YesNo' 'Question' @{ Yes = $yes; No = 'Cancel' } -SafeDefault
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log ("APPLY $($Actions[$Key].Title) -> $($script:PickCode) not run: already steered " +
                "there (you cancelled)")
            return $false
        }
    }
    if (($Key -eq 'Clear' -or $Key -eq 'Repair') -and $dbd -and $script:Verify -and
        -not $script:Verify.Done -and $cur.Code) {
        $doing = if ($Key -eq 'Clear') { 'Removing the steering' } else { 'Repairing hosts' }
        $yes = if ($Key -eq 'Clear') { 'Remove it anyway' } else { 'Repair anyway' }
        $ask = ("DBD hasn't re-measured since the cut yet.$nl$nl$doing now means it measures with every region " +
            "reachable, so you'd most likely not land on $($script:Verify.Name).$nl${nl}Do it anyway?")
        $r = Show-Msg $ask 'YesNo' 'Warning' @{ Yes = $yes; No = 'Cancel' } -SafeDefault
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log "APPLY $($Actions[$Key].Title) not run: DBD hadn't re-measured yet (you cancelled)"
            return $false
        }
    }
    if ($Key -eq 'Repair') {
        $lost = @()
        try {
            $raw = Read-HostsText
            if ($null -ne $raw) { $lost = Get-HostsOtherEntries $raw }
        } catch {}   # unreadable: the description already says so
        if ($lost.Count) {
            $what = if ($lost.Count -eq 1) { 'entry' } else { 'entries' }
            $more = if ($lost.Count -gt 5) { "$nl  ..." } else { '' }
            $sample = (($lost | Select-Object -First 5) -join "$nl  ") + $more
            $ask = ("Repair Hosts would delete $($lost.Count) $what that you or other programs added to hosts." +
                "$nl${nl}For example:$nl  $sample$nl${nl}To only stop steering, use Remove Steering." +
                "$nl${nl}Overwrite the whole hosts file anyway?")
            $r = Show-Msg $ask 'YesNo' 'Warning' @{ Yes = 'Overwrite hosts'; No = 'Cancel' } -SafeDefault
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "APPLY Repair Hosts not run: $($lost.Count) other entries would be lost (you cancelled)"
                return $false
            }
        }
    }
    return $true
}

$btnApply.Add_Click({
    if ($script:Busy -or -not $script:Selected) { return }
    $key = $script:Selected
    if ($key -eq 'Switch' -or $key -eq 'Restart') {
        # DBD started or closed since the last check (every 3 s): the buttons change first, Apply again runs it
        $was = $script:SwitchShown
        Update-DbdPid
        Update-DbdActions
        if ($script:SwitchShown -ne $was) { return }
    }
    if (-not (Confirm-Apply $key)) { return }   # cancelled: the action stays selected
    # The clock goes back before another action - except one that only changes hosts while DBD still has to measure:
    # DBD's 10-min rule would then block that measurement.
    if ([DbdEtw]::ClockAhead) {
        $hostsOnly = (($key -eq 'Switch' -or $key -eq 'Clear' -or $key -eq 'Repair') -and (Get-PendingCut))
        if (-not $hostsOnly) { [void][DbdEtw]::RestoreClock("you started another action ($($Actions[$key].Title))") }
    }
    Set-Busy $true
    $btnApply.Visible = $false
    $btnSkip.Visible = $false
    try {
        if (($key -eq 'Switch' -or $key -eq 'Restart') -and -not $script:PickCode) {
            throw "Click a region in the list first."
        }
        $to = if ($key -eq 'Switch' -or $key -eq 'Restart') { " -> $($script:PickCode)" } else { '' }
        Write-Log ("APPLY {0}{1}" -f $Actions[$key].Title,$to)
        $res = & $Actions[$key].Run
        Set-Status $res.Text $res.Color
        Write-Log ("  result: " + ($res.Text -replace "`r`n",' '))
    } catch {
        Set-Status "Error: $($_.Exception.Message)" $cErr
        Write-Log "  error: $($_.Exception.Message)"
    } finally {
        Set-Busy $false
        Select-Action $null
    }
})
$btnSkip.Add_Click({
    if (-not $script:Busy -and [DbdEtw]::ClockAhead) {
        if ([DbdEtw]::RestoreClock('put back by you')) {
            $btnSkip.Visible = $false
            Update-SwitchOptions
        }
    } else {
        $script:SkipWait = $true
    }
})

function Invoke-SwitchNoRestart {
    param([string]$Code)
    $nm = Get-PickName $Code
    $before = Read-HostsText                                # snapshot for Cancel
    $cur = Get-CurrentSteering
    $same = ($cur.Code -eq $Code -and $cur.Exact)
    $dbd = Get-DbdProcess
    if (-not $dbd) {
        return @{
            Text = "DBD isn't running, so nothing was done. Switch + Start steers to $nm and starts DBD."
            Color = $cDim
        }
    }
    # ~60 ms: are UDP/DNS events arriving right now? (the wait uses it)
    [void](Test-EtwHealth)
    $pend = Get-PendingCut $dbd.Id
    if ($pend) {
        # DBD was cut and hasn't measured yet: the new steering is enough, a second cut would only get in the way.
        $at = $pend.CutUtc.ToLocalTime().ToString('HH:mm:ss')
        if ($same) {
            return @{ Text = ("Nothing to do: hosts already steers to $nm, and DBD hasn't re-measured since the cut " +
                "at $at.${nl}In DBD: click OK on the error if it's still showing, then press a key."); Color = $cDim }
        }
        $was = $pend.Name
        Set-Steering $Code
        $pend.Code = $Code
        $pend.Name = $nm
        Write-Log "  DBD hasn't measured since the cut at ${at}: steering changed from $was to $Code, no new cut"
        $text = ("Steering -> $nm (was $was). No new cut: DBD hasn't re-measured since the cut at $at.$nl" +
            "In DBD: click OK on the error if it's still showing, then press a key. Watching for DBD's measurement...")
        return @{ Text = $text; Color = $cOk }
    }
    $clickUtc = [DbdEtw]::UtcNow
    if (-not $same) {
        Set-Steering $Code
    } else {
        Invoke-DnsFlush
        Write-Log "  hosts already steered to $Code - re-measure only"
    }
    $flush1 = [DbdEtw]::UtcNow
    $until = Get-CurlSafeUtc $clickUtc
    if ($until -lt $flush1.AddSeconds(3)) { $until = $flush1.AddSeconds(3) }
    $prefix = if ($same) { "Re-measure on $nm armed (hosts unchanged)." } else { "Steering -> $nm written to hosts." }
    $useClock = $false
    $didJump = $false
    if ($script:ClockOpt) {
        $plan = Get-ClockJumpPlan
        if ($plan.Ok) {
            $useClock = $true
            Write-Log "  clock option: on ($($plan.Why) at the cut)"
        } else {
            Write-Log "  clock option: not usable - $($plan.Why); waiting for the window instead"
            $prefix += "${nl}Clock option not used: $($plan.Why). Waiting for DBD's window instead."
        }
    }
    $w = Wait-ForCutWindow $prefix $until -IgnoreGate:$useClock
    if ($script:Closing) { $w = 'cancel' }
    if ($w -eq 'cut' -and $useClock) {
        # recomputed: time passed while waiting for you to leave the lobby/match
        $plan = Get-ClockJumpPlan
        if (-not $plan.Ok) {
            Write-Log "  clock option: not usable at the cut - $($plan.Why); waiting for the window instead"
            $w = Wait-ForCutWindow ($prefix + ("${nl}Clock option not used: $($plan.Why). Waiting for " +
                "DBD's window instead.")) $until
        } elseif ($plan.Sec -gt 0 -and -not ($didJump = [bool](Invoke-ClockJump $plan.Sec))) {
            return @{ Text = ("The PC clock couldn't be moved ($([DbdEtw]::ClockError)), so nothing was cut. Hosts " +
                "is steered to $nm. Untick the clock option and apply again, or use Switch + Restart."); Color = $cErr }
        }
    }
    if ($w -eq 'cancel') {
        if (-not $same) { Restore-OurBlock $before }
        $was = if ($cur.Code) { "steered to $(Get-PickName $cur.Code)" } else { 'no steering' }
        Write-Log "  cancelled: hosts restored ($was)"
        return @{ Text = "Cancelled. Hosts is back as it was ($was); DBD wasn't touched."; Color = $cDim }
    }
    if ($w -eq 'closed') {
        return @{
            Text = "DBD closed before the cut. Hosts is steered to $nm; DBD uses it when it starts."
            Color = $cOk
        }
    }
    Invoke-DnsFlush                                       # flush #2, right before the cut
    Write-Log ('  match-server UDP link at the cut: ' + (Get-UdpLinkText))
    # a measurement from here on counts (also one during the hold)
    $cutUtc = [DbdEtw]::UtcNow
    $k = Invoke-CutDbd
    Write-Log "  $k"
    $h = Invoke-HoldCut
    $script:Verify = @{
        CutUtc = $cutUtc
        HoldEndUtc = [DbdEtw]::UtcNow
        Name = $nm
        Code = $Code
        Pid = $dbd.Id
        Done = $false
        Jump = $didJump
    }
    $ct = if ([DbdEtw]::ClockAhead) {
        ("${nl}Clock: $(Format-Dur ([DbdEtw]::ClockAheadSec)) ahead until DBD starts measuring (at most " +
            "$ClockHoldMaxSec s, or 'Put clock back now').")
    } elseif ($didJump) {
        "${nl}Clock: already back ($([DbdEtw]::RestoreWhy))."
    } else {
        ''
    }
    $fix = if (Get-PendingCut $dbd.Id) {
        "${nl}Wrong region: pick the right one and Switch (no restart) again before you press the key; that " +
            "only rewrites hosts."
    } else {
        ''
    }
    return @{ Text = ("Steering -> $nm. $k $h${nl}In DBD: click OK on the error, then press a key. Watching for " +
        "DBD's measurement...$ct$fix"); Color = $cOk }
}

$btnPing.Add_Click({
    if ($script:Busy) { return }
    Select-Action $null
    Set-Busy $true
    try {
        Set-Status ("Ping (read-only)${nl}Measuring this PC's connect time to each region (addresses straight from " +
            "DNS, so the steering hides none). It's your network's distance, not DBD's own measurement.") $cText
        $script:LastPings = @{}
        foreach ($it in $list.Items) { $it.SubItems[2].Text = $Ell }   # clear the previous results first
        Update-ListStyle $script:ListSteer
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # Addresses straight from DNS (-DnsOnly ignores hosts, so blocked regions still get a real number), then every
        # region is pinged at the same time (3 rounds, best kept) on a background thread. Results are matched back by
        # code: the list may be re-sorted meanwhile.
        $codes = @(foreach ($it in $list.Items) { $it.Tag.Code })
        $ips = [string[]]@(foreach ($it in $list.Items) {
            $ip = ''
            try {
                $ip = (Resolve-DnsName -Name $it.Tag.Hosts[0] -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
                    Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
            } catch {}
            [System.Windows.Forms.Application]::DoEvents()
            "$ip"
        })
        $task = [RegionPing]::Start($ips,443,3,2000)
        while (-not $task.IsCompleted -and -not $script:Closing) {
            Start-Sleep -Milliseconds 30
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($script:Closing) { return }                    # window closed mid-ping: nothing left to draw on
        $res = $task.Result
        $txtOf = @{}
        for ($i = 0;$i -lt $codes.Count;$i++) {
            $ms = if ($res[$i] -ge 0) { $res[$i] } else { $null }
            $script:LastPings[$codes[$i]] = $ms
            $txtOf[$codes[$i]] = if ($null -ne $ms) { "$ms" } elseif ($ips[$i]) { 'timeout' } else { 'no address' }
        }
        foreach ($it in $list.Items) {
            if ($txtOf.ContainsKey($it.Tag.Code)) { $it.SubItems[2].Text = $txtOf[$it.Tag.Code] }
        }
        if ($script:SortCol -eq 2) { Sort-RegionList } else { Update-ListStyle $script:ListSteer }
        Write-Log ("PING (TCP connect, best of 3): " + ((@($script:LastPings.Keys | Sort-Object {
            $v = $script:LastPings[$_]
            if ($null -eq $v) { [int]::MaxValue } else { $v }
            }) | ForEach-Object {
                "$_ " + $(if ($null -ne $script:LastPings[$_]) { "$($script:LastPings[$_]) ms" } else { 'timeout' })
            }) -join ', '))
        $bestCode = $null
        foreach ($k in $script:LastPings.Keys) {
            $v = $script:LastPings[$k]
            if ($null -ne $v -and ($null -eq $bestCode -or $v -lt $script:LastPings[$bestCode])) { $bestCode = $k }
        }
        $fastest = if ($bestCode) {
            ", fastest: $(Get-PickName $bestCode) ($($script:LastPings[$bestCode]) ms)"
        } else {
            ''
        }
        Set-Status ("Ping done in {0:N1} s{1}.{2}Green under 80 ms, yellow under 150, orange under 250, red above." -f
            $sw.Elapsed.TotalSeconds,$fastest,$nl) $cOk
    } catch {   # an error in a button handler would otherwise vanish, leaving "Measuring..." on screen
        foreach ($it in $list.Items) { if ($it.SubItems[2].Text -eq $Ell) { $it.SubItems[2].Text = $NoValue } }
        Set-Status "Ping failed: $($_.Exception.Message)" $cErr
        Write-Log "PING failed: $($_.Exception.Message)"
    } finally { Set-Busy $false }
})

$btnDetails.Add_Click({
    try {
        # Details runs right away: drop any pending action + its Apply
        if (-not $script:Busy) { Select-Action $null }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("Details (read-only snapshot)$nl")
        [void]$sb.Append("Session log: $($script:LogPath)$nl")
        [void]$sb.Append("Tool: v$ToolVersion, $BuildText$nl")
        $h = $script:EtwHealth
        Start-EtwProbe                 # refreshed in the background (no freeze); the console logs changes
        if ($h) {
            $impact = if (-not $h.Udp) {
                '; no lobby / match detection, see Options > Check UDP monitoring'
            } elseif (-not $h.Dns) {
                '; DBD''s measurement can''t be seen'
            } else {
                ''
            }
            [void]$sb.Append("Monitor self-test: $($h.Text) (at $($h.At.ToLocalTime().ToString('HH:mm:ss'))$impact)$nl")
        }
        $seen = if ($script:PingModeUtc -ne [DateTime]::MinValue) {
            " (last seen $($script:PingModeUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        } else {
            ''
        }
        [void]$sb.Append("Region measurement mode: $($script:PingMode)$seen$nl")
        if ($script:LastRound) {
            [void]$sb.Append(("DBD's last measurement: " +
                ($script:LastRound.Text -replace '^DBD region ping round (\S+): ','at $1, ') + $nl))
            foreach ($d in $script:LastRound.Detail) { [void]$sb.Append("   $d$nl") }
        }
        [void]$sb.Append("${nl}Hostnames DBD resolved since the tool started ([S] = in the steering block, [?] = " +
            "AWS name not in it)$nl")
        $names = [DbdEtw]::DbdNames()
        if (-not $names.Count) { [void]$sb.Append("  (none yet: DBD looks them up at launch and reload)$nl") }
        foreach ($n in $names) {
            $p = $n.Split('|')
            $tag = if ($p[0] -match $SteerHostRx) {
                '[S]'
            } elseif ($p[0] -match 'gamelift|\.api\.aws$|amazonaws\.com$') {
                '[?]'
            } else {
                '   '
            }
            [void]$sb.Append(("{0} {1}  x{2}  last {3}$nl" -f $tag,$p[0],$p[1],$p[2]))
        }
        [void]$sb.Append("${nl}Live log: Console button or Ctrl+K.$nl")
        $etwText = if ($script:EtwOk) { 'running' } else { "off ($($script:EtwErr))" }
        [void]$sb.Append(("${nl}ETW: {0}; DNS events {1}, DBD UDP events {2}" -f $etwText,[DbdEtw]::DnsEvents,
            [DbdEtw]::UdpEvents))
        if ($script:ShowStatus) {
            $regionStatus = 'not known yet (deadbyqueue.com unreachable or out of date)'
            if (Test-StatusFresh) {
                $off = @(Get-OfflineRegions)
                $regionStatus = if ($off.Count) { "offline = $($off -join ', ')" } else { 'all online' }
                $regionStatus += (" (deadbyqueue.com, checked " +
                    "$($script:StatusFetchedUtc.ToLocalTime().ToString('HH:mm')), list changed " +
                    "$($script:StatusAtUtc.ToLocalTime().ToString('HH:mm')))")
            }
            [void]$sb.Append("${nl}Region status: $regionStatus$nl")
            $qs = @(foreach ($r in $Regions) {
                $q = Get-QueueSec $r.Code
                if ($null -ne $q) { "$($r.Code) $(Format-Queue $q[0]) / $(Format-Queue $q[1])" }
            })
            if ($qs.Count) {
                [void]$sb.Append(("Queue times (killer / survivor, as of " +
                    "$($script:QueuesAtUtc.ToLocalTime().ToString('HH:mm'))): ") + ($qs -join ', ') + $nl)
            }
        }
        [void]$sb.Append("${nl}Other network monitors: " + (Get-NetListenersText (Get-NetListeners -Fresh)) +
            " (other programs' sessions on the same network events; see Options > Check UDP monitoring)")
        Set-Status $sb.ToString() $cDim
    } catch {
        Set-Status "Details failed: $($_.Exception.Message)" $cErr
        Write-Log "Details failed: $($_.Exception.Message)"
    }
})

