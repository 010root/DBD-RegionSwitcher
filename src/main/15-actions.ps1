# ---------------- actions: describe first, run on Apply ----------------
function Get-SteerText {
    param($Cur)
    if ($Cur.Error) { return "Hosts can't be read: $($Cur.Error)" }
    if (-not $Cur.Code) { return 'Hosts has no steering (DBD picks freely).' }
    $odd = ''
    if (-not $Cur.Exact) { $odd = ', but the block differs from what this version writes (Apply rewrites it)' }
    return "Hosts is steered to $(Get-PickName $Cur.Code) ($($Cur.Code))$odd."
}
function Get-RemeasurePendingWarning {   # a Switch cut DBD and it hasn't measured yet: changing hosts now undoes it
    if ($script:Verify -and -not $script:Verify.Done -and $script:Verify.Code -and (Get-DbdProcess)) {
        return ("=> DBD hasn't re-measured since the last cut. Changing hosts now means it measures without the " +
            "steering to $($script:Verify.Name).$nl$nl")
    }
    return ''
}
function Get-PendingCut {
    # A Switch cut DBD and DBD hasn't measured since: it will on its main loading screen (OK, then a key). Until then
    # the steering can still change without another cut - e.g. the wrong region was picked. Trusted only when the tool
    # would see that measurement start (DNS events arrive), in UDP-beacon mode (each ping is looked up through Windows,
    # so a DNS flush is enough), and for the DBD process that was cut. $Id: DBD's pid (default: the one the tick saw).
    param([int]$Id = $script:DbdPid)
    $V = $script:Verify
    if (-not $V -or $V.Done -or $Id -eq 0 -or $V.Pid -ne $Id) { return $null }
    if (-not $script:EtwOk -or -not $script:EtwHealth -or -not $script:EtwHealth.Dns -or $script:PingMode -ne 'UDP') {
        return $null
    }
    if ([DbdEtw]::LastSteerUtc -ge $V.CutUtc.AddSeconds(-2)) { return $null }   # its measurement has started already
    # A cut that relied on the clock option, with the clock back before DBD measured (the 3-min limit, 'Put clock back
    # now', DBD closed): DBD's 10-min rule now blocks that measurement, unless real time has opened its window since.
    if ($V.Jump -and -not [DbdEtw]::ClockAhead -and (Get-CutGate).Utc -gt [DbdEtw]::UtcNow) { return $null }
    return $V
}
function Get-PickPingWarning {
    param([string]$Code)
    # The last Ping couldn't reach the pick: if DBD can't either, every region reports the failure value and BHVR's
    # server chooses (the client sends all regions' results unfiltered - docs\how-it-works.md).
    if ($script:LastPings.ContainsKey($Code) -and $null -eq $script:LastPings[$Code]) {
        return ("=> Your last Ping got no answer from $(Get-PickName $Code). If DBD can't reach it either, BHVR's " +
            "server picks the region.$nl")
    }
    return ''
}
function Get-HostsOtherEntries {
    param([string]$Raw)   # hosts entries outside the steering block (what Repair would delete)
    return ,@(((Set-OurBlockText $Raw $null) -split "`r?`n") | Where-Object {
        $_.Trim() -and -not $_.Trim().StartsWith('#')
    })
}
# the running DBD's store, else the one seen last time, else the one it's installed with here
function Get-RestartStore {
    $p = Get-DbdProcess
    if ($p) { return (Get-DbdStore $p) }
    if ($script:DbdStore) { return $script:DbdStore }
    if (Test-SteamDbdInstalled) { return 'Steam' }
    foreach ($s in 'Epic Games','Xbox / Game Pass') { if (Get-DbdLauncher $s) { return $s } }
    return 'Steam'
}
function Get-SteerLifeNote {
    if ($script:SteerLife -eq 'temp') { "Steering lasts until DBD closes (Options > Steering lasts).$nl" } else { '' }
}
# steering removed before DBD measured (you confirmed): the result is checked as unsteered
function Set-VerifyUnsteered {
    if ($script:Verify -and -not $script:Verify.Done) {
        $script:Verify.Code = $null
        $script:Verify.Name = 'no steering'
    }
}
$Actions = [ordered]@{
    Switch = @{
        Button = $btnSwitch
        Title = 'Switch (no restart)'
        Describe = {
            $cur = Get-CurrentSteering
            $nm = Get-PickName $script:PickCode
            $same = ($cur.Code -eq $script:PickCode -and $cur.Exact)
            $t = "Switch (no restart) to $nm ($($script:PickCode))$nl$nl"
            $warn = (Get-PickStatusWarning $script:PickCode) + (Get-PickPingWarning $script:PickCode)
            $pend = Get-PendingCut
            if ($pend) {   # cut done, DBD hasn't measured yet: only hosts changes
                $at = $pend.CutUtc.ToLocalTime().ToString('HH:mm:ss')
                if ($same) {
                    $t += ("=> Nothing to do: hosts already steers to $nm. DBD hasn't re-measured since the cut at " +
                        "$at; it uses this steering when you press a key on its main loading screen.$nl")
                } else {
                    $t += ("=> DBD hasn't re-measured since the cut at $at (to $($pend.Name)). Apply only rewrites " +
                        "the steering to $nm, no new cut. Apply it before you press the key in DBD.$nl")
                    if ([DbdEtw]::ClockAhead) { $t += "Clock: stays ahead until DBD starts measuring.$nl" }
                }
                return ($t + "${nl}Now: " + (Get-SteerText $cur) + $nl + $warn)
            }
            if ($same) {
                $t += ("=> You're already steered to $nm. Apply only makes DBD re-measure (it asks first): for when " +
                    "DBD still placed you elsewhere.$nl")
            } else {
                $t += ("What it does: rewrites this tool's block in hosts so only $nm is reachable, then cuts DBD's " +
                    "connection so it re-measures.$nl")
            }
            # With the clock option on, but DBD's window already open: the clock isn't needed and won't be touched.
            $clockPlan = if ($script:ClockOpt -and (Get-DbdProcess)) { Get-ClockJumpPlan } else { $null }
            $clockIdle = ($clockPlan -and $clockPlan.Ok -and $clockPlan.Sec -le 0)
            if ($clockIdle) {
                $t += ("When: as soon as you're out of any lobby, match or end game chat (DBD's 10-min window is " +
                    "already open, so the clock isn't touched).$nl")
            } elseif ($script:ClockOpt) {
                $t += ("When: as soon as you're out of any lobby, match or end game chat. Right before the cut the " +
                    "PC clock goes just far enough ahead for DBD's 10-min rule, and back the moment DBD starts " +
                    "measuring (at the latest after $ClockHoldMaxSec s).$nl")
                if ($script:NgenOpt -and $NgenInstalled) {
                    $t += ("NGENUITY: restarted in the background once the clock is back, so your mouse colors " +
                        "return (about a second, no window).$nl")
                }
            } else {
                $t += ("When: once DBD's 10-min re-measure window is open and you're out of any lobby, match " +
                    "or end game chat.$nl")
            }
            $t += ("In DBD: click OK on the connection error, then press a key. DBD re-measures on its main loading " +
                "screen; don't ready up until the tool says it did.$nl")
            $t += "Cancel (or Esc): before the cut, puts hosts back as it was.$nl$nl"
            $t += "Now: " + (Get-SteerText $cur) + $nl + $warn + (Get-SteerLifeNote)
            if (-not (Get-DbdProcess)) {
                $t += "=> DBD isn't running, so Apply does nothing. Switch + Start steers and starts it.$nl"
            } else {
                $t += "Re-measure window: " + (Get-CutGate).Why + ".$nl"
                if ($script:ClockOpt) {
                    $p = Get-ClockJumpPlan
                    $t += if ($p.Ok) {
                        "Clock: if the cut happened now, $($p.Why).$nl"
                    } else {
                        "Clock: can't be used now, $($p.Why). Apply would wait for the window instead.$nl"
                    }
                }
            }
            $t
        }
        Run = { Invoke-SwitchNoRestart $script:PickCode }
    }
    Restart = @{
        Button = $btnRestart
        Title = 'Switch + Restart'
        Describe = {
            $cur = Get-CurrentSteering
            $nm = Get-PickName $script:PickCode
            $t = "$($Actions.Restart.Title) to $nm ($($script:PickCode))$nl$nl"
            $store = Get-RestartStore
            $L = Get-DbdLauncher $store
            $running = [bool](Get-DbdProcess)
            if (-not $L) {
                $where = if ($store -eq 'Epic Games') {
                    'not in the Epic Games launcher''s list'
                } elseif ($store -eq 'Steam') {
                    'Steam isn''t installed'
                } else {
                    'no Dead by Daylight app in the Start menu'
                }
                $then = if ($running) {
                    ' and leaves DBD open; then restart DBD yourself. Switch (no restart) works with every version'
                } else {
                    '; then start DBD yourself'
                }
                $t += ("=> The tool can't find how to start your DBD ($store version: $where). Apply only writes the " +
                    "steering$then.$nl$nl")
            } else {
                $via = if ($store -eq 'Steam') { 'Steam (steam://rungameid/381210)' } else { $L.How }
                if ($running) {
                    $t += ("What it does: writes the steering, closes DBD and EasyAntiCheat, and starts DBD again " +
                        "through $via. Slow, but always works.$nl")
                    $t += ("When: once you're out of any lobby, match or end game chat (closing DBD in a match " +
                        "is a disconnect).$nl")
                    $t += "Cancel (or Esc): while it waits, puts hosts back.$nl$nl"
                } else {
                    $t += "What it does: writes the steering and starts DBD through $via.$nl"
                    # The store is learned from a running DBD; before that it's the one DBD is installed with here.
                    $t += if ($script:DbdStore) {
                        ("Store: $store, the one DBD last ran from while the tool was open. For another version, " +
                            "start that one yourself once.$nl$nl")
                    } else {
                        ("Store: $store, a guess until DBD has run once while the tool is open. If yours is another " +
                            "version, start DBD yourself once and the tool remembers it.$nl$nl")
                    }
                }
            }
            $t += "Now: " + (Get-SteerText $cur) + $nl + (Get-PickStatusWarning $script:PickCode) +
                (Get-PickPingWarning $script:PickCode) + (Get-SteerLifeNote)
            if (-not $running -and $script:LaunchWatch) {
                $ago = [int]([DbdEtw]::UtcNow-$script:LaunchWatch.Utc).TotalSeconds
                $t += "=> DBD is already starting: the tool asked $($script:LaunchWatch.How) to start it $ago s ago.$nl"
            }
            if ($cur.Code -eq $script:PickCode -and $cur.Exact) {
                $t += "=> Hosts already steers to $nm; Apply only " +
                    "$(if ($running) { 'restarts' } else { 'starts' }) DBD.$nl"
            }
            $t
        }
        Run = {
            $code = $script:PickCode
            $nm = Get-PickName $code
            $before = Read-HostsText
            $cur = Get-CurrentSteering
            $same = ($cur.Code -eq $code -and $cur.Exact)
            if (-not $same) {
                Set-Steering $code
            } else {
                Invoke-DnsFlush
                Reset-TempArm   # temporary: kept for the restarted DBD, also if starting it fails
            }
            $store = Get-RestartStore
            $L = Get-DbdLauncher $store -Fresh
            if (-not $L) {
                Write-Log ("  restart: DBD is the $store version and its launch entry wasn't found - steering " +
                    "written, DBD not closed")
                $open = [bool](Get-DbdProcess)
                $todo = if ($open) { 'Close DBD and start it yourself' } else { 'Start DBD yourself' }
                return @{ Text = ("Steering -> $nm. The tool can't start your DBD ($store version)" +
                    "$(if ($open) { ', so DBD wasn''t closed' }).$nl${todo}: it loads on $nm."); Color = $cOk }
            }
            if ((Get-DbdProcess) -and (Test-MatchLink)) {
                Write-Log ('  restart: DBD has a match-server link - waiting until you leave the lobby / ' +
                    'match / end game chat')
                $w = Wait-ForCutWindow ("Steering -> $nm written. DBD is closed and started again once you're out of " +
                    "the lobby, match or end game chat.") -IgnoreGate -ForRestart
                if ($script:Closing -or $w -eq 'cancel') {
                    if (-not $same) { Restore-OurBlock $before }
                    Write-Log '  cancelled: hosts restored, DBD not closed'
                    return @{ Text = "Cancelled. Hosts is back as it was; DBD wasn't touched."; Color = $cDim }
                }
            }
            $doing = if (Get-DbdProcess) {
                "Closing DBD, then starting it through $($L.How)..."
            } else {
                "Starting DBD through $($L.How)..."
            }
            Set-Status "Steering -> $nm. $doing" $cWarn
            @{
                Text = "Steering -> $nm. " + (Restart-Dbd $store) +
                    "${nl}The STEERING line shows it once DBD is running."
                Color = $cOk
            }
        }
    }
    Clear = @{
        Button = $btnClear
        Title = 'Remove Steering'
        Describe = {
            $cur = Get-CurrentSteering
            $t = "Remove Steering$nl$nl"
            $t += ("What it does: deletes only this tool's block from hosts. DBD can reach every region again from " +
                "its next measurement (a relaunch, or a reset 10+ min after the last one).$nl$nl")
            $t += "Now: " + (Get-SteerText $cur) + $nl + (Get-RemeasurePendingWarning)
            if (-not $cur.Code -and -not $cur.Error) { $t += "=> Nothing to remove: Apply does nothing.$nl" }
            $t
        }
        Run = {
            $cur = Get-CurrentSteering
            if (-not $cur.Code -and -not $cur.Error) {
                return @{ Text = 'There was no steering in hosts; nothing changed.'; Color = $cDim }
            }
            Clear-Steering
            Set-VerifyUnsteered
            @{
                Text = 'Steering removed (only this tool''s block). DBD can reach every region from ' +
                    'its next measurement.'
                Color = $cOk
            }
        }
    }
    Repair = @{
        Button = $btnRepair
        Title = 'Repair Hosts'
        Describe = {
            $t = "Repair Hosts$nl$nl" + (Get-RemeasurePendingWarning)
            $t += ("What it does: replaces the whole hosts file with the Windows default, removing the steering and " +
                "every other entry. Only for a damaged hosts file; to stop steering, use Remove Steering.$nl$nl")
            try {
                $raw = Read-HostsText
                if ($null -ne $raw) {
                    $lost = Get-HostsOtherEntries $raw
                    if ($lost.Count) {
                        $more = if ($lost.Count -gt 15) { "$nl  ... and $($lost.Count-15) more" } else { '' }
                        $t += "Would be lost ($($lost.Count)):$nl  " +
                            (($lost | Select-Object -First 15) -join "$nl  ") + $more + $nl
                    } else {
                        $t += "Would be lost: nothing (only comments and the steering block).$nl"
                    }
                }
            } catch {
                $t += "Would be lost: unknown, because hosts isn't valid UTF-8 right now ($($_.Exception.Message)).$nl"
            }
            $t
        }
        Run = {
            Repair-Hosts
            Set-VerifyUnsteered
            @{ Text = 'Hosts reset to the Windows default (all custom entries removed).'; Color = $cOk }
        }
    }
}

function Update-SwitchOptions {
    # Under Switch (no restart) while it's selected; not while an action runs, nor while 'Put clock back now' takes
    # that row (the clock is ahead: a Switch then only changes hosts). NGENUITY's only with the clock option.
    $on = ($script:Selected -eq 'Switch' -and -not $script:Busy -and -not $btnSkip.Visible)
    $chkClock.Visible = $on
    $chkNgen.Visible = ($on -and $NgenInstalled -and $chkClock.Checked)
}
function Select-Action {
    param([string]$Key)
    $script:Selected = $Key
    Update-SwitchOptions
    foreach ($k in $Actions.Keys) {
        $b = $Actions[$k].Button
        $b.FlatAppearance.BorderSize = if ($k -eq $Key) { 2 } else { 1 }
        $b.FlatAppearance.BorderColor = if ($k -eq $Key) { $cSelBorder } else { $cBorder }
    }
    if ($Key) {
        $btnApply.Text = ([string][char]0x25B6 + "  Apply: $($Actions[$Key].Title)")
        $btnApply.Enabled = (-not $script:Busy)
        $btnApply.Visible = (-not $script:Busy)
        try {
            Set-Status ((& $Actions[$Key].Describe) + "${nl}Press Apply to run it, or pick another action.") $cText
        } catch { Set-Status "Error: $($_.Exception.Message)" $cErr }
    } else {
        $btnApply.Text = 'Apply'
        $btnApply.Enabled = $false
        $btnApply.Visible = $false
    }
}
# DBD running: Switch (no restart) and Switch + Restart. Not running: only Switch + Start, since a Switch needs a
# running DBD to cut. Kept the same on the buttons, Apply, the list's menu and the descriptions. Not changed during an
# action: Switch + Restart closes DBD itself.
$script:SwitchShown = $null
function Update-DbdActions {
    if ($script:Busy) { return }
    $run = [bool]$script:DbdPid
    if ($script:SwitchShown -eq $run) { return }
    $script:SwitchShown = $run
    $t = if ($run) { 'Switch + Restart' } else { 'Switch + Start' }
    if ($script:ActionRow) { $script:ActionRow.Show($btnSwitch,$run) } else { $btnSwitch.Visible = $run }
    $miSwitch.Visible = $run
    $Actions.Restart.Title = $t
    $btnRestart.Text = $t
    $miRestart.Text = "$t to this region"
    $tips.SetToolTip($btnRestart,"Steer to the picked region, then $(if ($run) { 'restart' } else { 'start' }) " +
        "DBD through its store.")
    if ($script:Selected -eq 'Switch' -and -not $run) {
        Select-Action $null
        Set-Status ("DBD closed, so Switch (no restart) is hidden until it runs again. Switch + Start " +
            "steers and starts it.") $cDim
    } elseif ($script:Selected -eq 'Restart') {
        Select-Action 'Restart'
    }
}
Update-DbdActions
foreach ($k in $Actions.Keys) {
    $Actions[$k].Button.Tag = $k
    $Actions[$k].Button.Add_Click({
        param($s,$e)
        if (-not $script:Busy) { Select-Action $s.Tag }
    })
}
# Changing the picked region refreshes a selected Switch description.
$list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -eq 1) {
        $script:PickCode = $list.SelectedItems[0].Tag.Code
        if (-not $script:Busy -and ($script:Selected -eq 'Switch' -or $script:Selected -eq 'Restart')) {
            Select-Action $script:Selected
        }
    }
})
$cur0 = Get-CurrentSteering
if ($script:SteerLife -eq 'temp' -and $cur0.Code) {
    if ($script:DbdPid) {
        $script:TempArmed = $true
    } elseif (Remove-TempSteering 'left from the last run, which ended before DBD closed') {
        $cur0 = Get-CurrentSteering
    }
}
# the steered region, else the one picked last time
$startPick = if ($cur0.Code) { $cur0.Code } else { $script:LastPick }
$startIdx = 0
if ($startPick) {
    for ($i = 0;$i -lt $list.Items.Count;$i++) { if ($list.Items[$i].Tag.Code -eq $startPick) { $startIdx = $i } }
}
$list.Items[$startIdx].Selected = $true
$list.Items[$startIdx].EnsureVisible()
$script:PickCode = $list.Items[$startIdx].Tag.Code

function Get-MatchServer {
    # DBD's lobby / match / end game chat server, talking right now: of its UDP peers with 30+ packets in the last
    # 2 min (DNS, NTP, STUN and private addresses aside), the busiest one with traffic in the last 3 s. (Its traffic
    # starts as you join a lobby and stops as you leave it.)
    $pk = 0
    $n = 0
    $ep = [DbdEtw]::ActiveUdp(120,30,3,[ref]$pk,[ref]$n)
    if (-not $ep) { return $null }
    return @{ Ep = $ep; Ip = $ep.Substring(0,$ep.LastIndexOf(':')); PerSec = $n/3 }
}
# Checked every second (the GAME SERVER row) and by a waiting Switch: the server DBD talks to, or $null. When its
# traffic stops, and when the same server comes back, the session log says so - a record of what DBD does between a
# lobby, its match and the end game chat.
$FlowGapSec = 5
$script:Flow = $null
function Update-MatchFlow {
    $m = Get-MatchServer
    $now = [DbdEtw]::UtcNow
    $F = $script:Flow
    if ($m) {
        if ($F -and $F.Ep -eq $m.Ep) {
            $q = ($now-$F.LastUtc).TotalSeconds
            if ($q -ge $FlowGapSec) { Write-Log ("Game server {0} back after {1:N0} s quiet" -f $m.Ep,$q) }
            $F.LastUtc = $now
            $F.Stopped = $false
        } else {
            $script:Flow = @{ Ep = $m.Ep; FirstUtc = $now; LastUtc = $now; Stopped = $false }
        }
        return $m
    }
    if ($F -and -not $F.Stopped) {
        $F.Stopped = $true
        Write-Log ("Game server traffic stopped (was {0}, from {1} to {2})" -f $F.Ep,
            $F.FirstUtc.ToLocalTime().ToString('HH:mm:ss'),$F.LastUtc.ToLocalTime().ToString('HH:mm:ss'))
    }
    if ($F -and ($now-$F.LastUtc).TotalMinutes -ge 10) { $script:Flow = $null }
    return $null
}
function Test-MatchLink { [bool](Update-MatchFlow) }
function Get-UdpLinkText {
    # Is DBD talking to a match server (UDP) right now? Logged at every cut to show what the cut did on that screen.
    $m = Get-MatchServer
    if ($m) { return ("active ({0}, ~{1:N0} packets/s)" -f $m.Ep,$m.PerSec) }
    # No DBD UDP yet is normal on the main menu (TCP only); only a failed self-test makes it unknown.
    if ($script:EtwHealth -and -not $script:EtwHealth.Udp) {
        return 'unknown (the self-test gets no UDP events from Windows)'
    }
    return 'none (TCP only)'
}
function Get-CutGate {
    # When DBD's own gate will allow a re-measure (see $RemeasureCooldownSec). Re-evaluated every tick.
    $g = Get-RemeasureUtc
    if ($g) {
        if ($g -le [DbdEtw]::UtcNow) {
            return @{
                Utc = $g
                Why = "open (DBD's last measurement: $($script:LastRoundEndUtc.ToLocalTime().ToString('HH:mm:ss')))"
            }
        }
        return @{ Utc = $g; Why = ("opens at {0}, {1:N0} min after DBD's last measurement ({2})" -f
            $g.ToLocalTime().ToString('HH:mm:ss'),
            ($RemeasureCooldownSec/60),$script:LastRoundEndUtc.ToLocalTime().ToString('HH:mm:ss')) }
    }
    if ($script:DbdSeenStart) {
        return @{ Utc = [DbdEtw]::UtcNow.AddSeconds(30); Why = "waiting for DBD's launch measurement (not seen yet)" }
    }
    $u = $script:EtwStartUtc.AddSeconds($RemeasureCooldownSec+$RemeasureMarginSec)
    if ($u -le [DbdEtw]::UtcNow) {
        return @{
            Utc = $u
            Why = ("open (DBD was already running when the tool opened, over {0:N0} min ago)" -f
                ($RemeasureCooldownSec/60))
        }
    }
    return @{ Utc = $u; Why = (("opens at {0} at the latest (DBD was already running when the tool opened, so its " +
        "last measurement is unknown)") -f $u.ToLocalTime().ToString('HH:mm:ss')) }
}
