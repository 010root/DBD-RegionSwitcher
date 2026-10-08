# ---------------- once a second: readouts, measurement rounds, post-switch verification ----------------
$script:PidTick = 0
$script:LastServer = ''
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50   # first update right away (the window opens with its rows filled), then every second
$timer.Add_Tick({
    try {
        if ($timer.Interval -ne 1000) { $timer.Interval = 1000 }
        # While you drag the window's edge or title bar: the readouts wait (a tick in the middle of a resize is a
        # visible hitch), for at most 3 s at a time. (Putting the clock back doesn't wait: the ETW thread does that.)
        if ($script:DpiWatch -and $script:DpiWatch.Sizing -and
            ([DateTime]::UtcNow-$script:DpiWatch.SizingSince).TotalSeconds -lt 3) {
            return
        }
        $script:PidTick++
        # every 6 h: is the copy over a week old? (a tool left in the tray for weeks)
        if ($script:PidTick % 21600 -eq 0) { $script:AwsMapTried = $false }
        # starts, then finishes the background load / download
        if (($script:PidTick -ge 3 -and -not $script:AwsMapTried) -or $script:AwsDl -or $script:AwsParse) {
            [void](Initialize-AwsIpMap)
        }
        # new region status: the list every time, an open description only when the offline list changed
        if ($script:PidTick -ge 2 -and (Update-RegionStatus)) {
            if ($script:SortCol -eq 3) { Sort-RegionList } else { Update-ListStyle $script:ListSteer }
            if ($script:OfflineChanged) {
                $script:OfflineChanged = $false
                if ($script:Selected -and -not $script:Busy) { Select-Action $script:Selected }
            }
        }
        if ($script:PidTick -ge 5) { Update-UpdateCheck }   # a few seconds after start: not in the way of start-up
        # another copy was started: show this one
        if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) { Show-FromTray }
        Step-EtwProbe
        # self-test again every minute (3 UDP packets + 1 lookup)
        if ($script:PidTick % 60 -eq 30 -and -not $script:Busy) { Start-EtwProbe }
        if ($script:UdpFixDue -and -not $script:Busy -and -not [DbdEtw]::ClockAhead) {
            $script:UdpFixDue = $false
            Repair-UdpMonitor
        }
        # "Ping all regions when the tool opens"
        if ($script:PidTick -eq 2 -and $script:AutoPing -and -not $script:Busy) { $btnPing.PerformClick() }
        $now = [DbdEtw]::UtcNow
        if ($script:PidTick % 3 -eq 1) {
            Update-DbdPid
            Update-DbdActions
            Update-LaunchWatch
            $cur = Get-CurrentSteering -Cached
            $script:CurSteer = $cur
            $was = Update-TempSteering $cur
            if ($was) {
                $cur = Get-CurrentSteering
                $script:CurSteer = $cur
                Set-Status ("DBD closed, so the temporary steering to $(Get-PickName $was) was removed (Options > " +
                    "Steering lasts).") $cDim
            }
            $dbdTxt = if ($script:DbdPid) { "DBD running (pid $($script:DbdPid))" } else { 'DBD not running' }
            # bold = a value found (region, time), not an absence - like GAME SERVER's "none"
            if ($cur.Error) {
                Set-Info $lblSteer @(,@("hosts can't be read: $($cur.Error)",$cErr,$true)) $cErr
            } elseif ($cur.Code) {
                $offNow = if (Test-RegionOffline $cur.Code) { '  offline now (deadbyqueue.com)' } else { '' }
                Set-Info $lblSteer @(
                    @((Get-PickName $cur.Code),$cCfg,$true),
                    @(" ($($cur.Code))",$cCfg,$false),
                    @($(if (-not $cur.Exact) { '  non-standard block' } else { '' }),$cWarn,$false),
                    @($offNow,$cErr,$true),
                    @($(if ($script:SteerLife -eq 'temp') { '  until DBD closes' } else { '' }),$cDim,$false),
                    @('   |   ',$cDim,$false),
                    @($dbdTxt,$cText,$false)) $cOk
            } else {
                Set-Info $lblSteer @(
                    @('none',$cText,$false),
                    @(' (DBD picks freely)   |   ',$cDim,$false),
                    @($dbdTxt,$cText,$false)) $cDim
            }
            if ($cur.Code -ne $script:ListSteer) {
                $script:ListSteer = $cur.Code
                Update-ListStyle $cur.Code
            }
            $steerTitle = if ($cur.Code) { "steered to $(Get-PickName $cur.Code)" } else { 'no steering' }
            # the title shows the steering, in the taskbar too (a tray tip takes at most 63 characters)
            $tt = "$WindowTitle $Dash $steerTitle"
            if ($form.Text -ne $tt) {
                $form.Text = $tt
                $tray.Text = if ($tt.Length -gt 63) { $tt.Substring(0,63) } else { $tt }
            }
        }
        if (-not $script:EtwOk) {
            Set-Info $lblNext @(,@("ETW off, so a Switch waits 10 min from the tool's start and can't check the result",
                $cWarn,$false)) $cWarn
            Set-Info $lblMatch @(,@('ETW off',$cWarn,$false)) $cWarn
            Set-Info $lblDbd @(,@('ETW off',$cWarn,$false)) $cWarn
            return
        }

        # Switch-wait line (DBD's measurement method is on the DBD MEASURED row)
        if (-not [DbdEtw]::ClockAhead) {   # while the clock is ahead, Update-ClockJump writes this row
            if ($script:DbdPid -eq 0 -and $script:LaunchWatch) {
                Set-Info $lblNext @(
                    @('DBD starting',$cText,$false),
                    @(" (the tool asked $($script:LaunchWatch.How) to start it)",$cDim,$false)) $cDim
            } elseif ($script:DbdPid -eq 0) {
                Set-Info $lblNext @(
                    @('DBD not running',$cText,$false),
                    @(' (Switch + Start steers and starts it)',$cDim,$false)) $cDim
            } elseif (Get-PendingCut) {
                Set-Info $lblNext @(
                    @('DBD measures next',$cClockCat,$true),
                    @(' on its main loading screen (OK, then a key); until then a Switch only changes hosts',$cDim,
                        $false)) $cClockCat
            } else {
                $g = Get-CutGate
                $gl = [Math]::Ceiling(($g.Utc-$now).TotalSeconds)
                if ($script:LastRoundEndUtc) {
                    if ($gl -gt 0) {
                        Set-Info $lblNext @(
                            @('DBD can re-measure at ',$cText,$false),
                            @($g.Utc.ToLocalTime().ToString('HH:mm:ss'),$cClockCat,$true),
                            @((" (in {0}:{1:00})" -f [Math]::Floor($gl/60),($gl%60)),$cClockCat,$false)) $cClockCat
                    } else {
                        Set-Info $lblNext @(,@('DBD can re-measure now',$cOk,$true)) $cOk
                    }
                } elseif ($script:DbdSeenStart) {
                    Set-Info $lblNext @(,@("waiting for DBD's launch measurement",$cText,$false)) $cDim
                } elseif ($gl -le 0) {
                    Set-Info $lblNext @(
                        @('DBD can re-measure now',$cOk,$true),
                        @(' (tool opened after DBD, over 10 min ago)',$cDim,$false)) $cOk
                } else {
                    Set-Info $lblNext @(
                        @('last measurement unknown (tool opened after DBD), safe at ',$cText,$false),
                        @($g.Utc.ToLocalTime().ToString('HH:mm:ss'),$cClockCat,$true)) $cWarn
                }
            }
        }
        Update-ClockJump
        Step-NGenuityRestart
        $dn = [DbdEtw]::TakeNewDns()
        if ($script:ConBox -and $script:ConDns) {
            foreach ($d in $dn) { Add-ConsoleLine $d }
        }
        # 10-min window bar
        $gf = -1.0
        $gc = $cAccent
        if ($script:DbdPid -ne 0) {
            if ([DbdEtw]::ClockAhead) {
                $gf = 1.0
                $gc = $cWarn
            } elseif ($script:LastRoundEndUtc) {
                $tot = $RemeasureCooldownSec+$RemeasureMarginSec
                $gf = [Math]::Max(0.0,[Math]::Min(1.0,1-((Get-RemeasureUtc)-$now).TotalSeconds/$tot))
                $gc = if ($gf -ge 1) { $cOk } else { $cAccent }
            }
        }
        $script:Gate.Set($gf,$gc)   # repainted only when it changed

        # Game server: the server of your lobby, match or end game chat (the same check a waiting Switch makes)
        if ($script:DbdPid -eq 0) {
            if ($script:Flow -and -not $script:Flow.Stopped) {
                Write-Log "Game server traffic stopped (was $($script:Flow.Ep)) - DBD closed"
            }
            $script:Flow = $null
            $script:LastServer = ''
            Set-Info $lblMatch @(,@('DBD not running',$cDim,$false)) $cDim
        } elseif ($m = Update-MatchFlow) {
            $reg = Get-IpRegion $m.Ip
            $rc = if ($reg) { $reg.Split('|')[0] } else { $null }
            $cur = if ($script:CurSteer) { $script:CurSteer } else { Get-CurrentSteering }
            $match = if (-not $rc -or $rc -eq 'GLOBAL' -or -not $cur.Code) {
                ''
            } elseif ($rc -eq $cur.Code) {
                '  = steered region'
            } else {
                "  (steering is $($cur.Code))"
            }
            # Amazon lists some server addresses only as GLOBAL (no region; no reverse name or ping reply either). BHVR
            # still places the server in a region DBD could reach: with only one, that's the one.
            $only = if ($rc -eq 'GLOBAL' -and $script:LastRoundEndUtc -and $script:LastRound -and
                @($script:LastRound.Open).Count -eq 1) {
                @($script:LastRound.Open)[0]
            } else {
                $null
            }
            $landed = if ($rc -eq 'GLOBAL' -and $only) {
                "$only  $(Get-PickName $only) (the only region DBD could reach; Amazon lists this address as GLOBAL)"
            } elseif ($rc -eq 'GLOBAL') {
                'region not published (Amazon lists this address as GLOBAL)'
            } elseif ($rc) {
                "$rc  $(Get-PickName $rc)"
            } else {
                'region unknown (ip-ranges.json unavailable)'
            }
            $svc = if (-not $reg) {
                ''
            } elseif ($reg.Split('|')[1] -eq 'EC2') {
                '  Amazon EC2'
            } else {
                '  Amazon ' + $reg.Split('|')[1]
            }
            $same = ($rc -and $cur.Code -and $rc -eq $cur.Code)
            $state = if ($same) {
                $cOk
            } elseif (-not $rc -or $rc -eq 'GLOBAL' -or -not $cur.Code) {
                $cLanded
            } else {
                $cWarn
            }
            Set-Info $lblMatch @(
                @($m.Ep,$cText,$false),
                @(('  ~{0:N0} packets/s  ->  ' -f $m.PerSec),$cDim,$false),
                @($landed,$cLanded,$true),
                @($svc,$cDim,$false),
                @($match,$(if ($same) { $cOk } else { $cWarn }),$true)) $state
            # A new server is logged here; the same one coming back after a quiet spell, by Update-MatchFlow.
            if ($m.Ep -ne $script:LastServer) {
                $script:LastServer = $m.Ep
                $regionText = if ($rc) { $rc } else { 'region unknown' }
                $note = if ($only) { " (DBD could only reach $only)" } else { $match }
                Write-Log ("Game server {0} -> {1}{2}{3}" -f $m.Ep,$regionText,$svc,$note)
            }
        } elseif ($script:EtwHealth -and -not $script:EtwHealth.Udp) {
            # Only the self-test decides: DBD sending no UDP is normal on its menus.
            $why = ' (the monitor self-test failed for UDP), so no lobby / match / end game chat detection'
            Set-Info $lblMatch @(@('UDP events blocked',$cWarn,$true),@($why,$cDim,$false)) $cWarn
        } else {
            Set-Info $lblMatch @(
                @('none',$cText,$false),
                @(' (no lobby / match / end game chat link)',$cDim,$false)) $cDim
        }

        # Measurement rounds + verification after a Switch
        if (Update-MeasurementRound) {
            Show-RoundInfo $script:LastRound
            # A region the block doesn't cover: said once per name (a Switch's verification below says it too)
            $nu = @($script:LastRound.Unknown | Where-Object { $_ -and -not $script:UnknownWarned.ContainsKey($_) })
            foreach ($n in $nu) { $script:UnknownWarned[$n] = $true }
            if ($nu.Count -and -not $script:Busy -and -not ($script:Verify -and -not $script:Verify.Done)) {
                $msg = "DBD measured a region this tool doesn't know${nl}" + (Get-UnknownRegionText $nu)
                Set-Status $msg $cWarn
                Request-Attention $msg
            }
        }
        # Checked on its own: a measurement during the hold (you pressed the key before 'DBD shows the error') is
        # summarised while the Switch is still running, before its verification exists.
        $R = $script:LastRound
        if ($R -and -not $script:Busy -and $script:Verify -and -not $script:Verify.Done -and
            $R.StartUtc -ge $script:Verify.CutUtc.AddSeconds(-2)) {
            $script:Verify.Done = $true
            $V = $script:Verify
            if (-not $V.Code) {
                $reached = if ($R.Open.Count) { $R.Open -join ', ' } else { 'none' }
                $msg = "DBD re-measured with no steering: reachable = $reached."
                $col = $cOk
            } elseif ($R.Open.Count -eq 1 -and $R.Open[0] -eq $V.Code -and -not $R.Http -and $R.Replies[$V.Code] -and
                $R.Replies[$V.Code][0] -gt 0 -and $R.Replies[$V.Code][1] -eq 0) {
                # Only the pick was reachable, but its ping server never answered: DBD counts it as failed like every
                # other region, so every region reports the failure value and BHVR's server picks one (see
                # docs\how-it-works.md).
                $msg = ("DBD re-measured at $($R.StartUtc.ToLocalTime().ToString('HH:mm:ss')), but $($V.Name)'s ping " +
                    "server never answered ($($R.Replies[$V.Code][0]) pings, 0 replies).${nl}=> DBD then reports " +
                    "every region as failed, so BHVR's server picks the region, most likely not $($V.Name).$nl" +
                    "The server may be down, or the pings get dropped on the way. Try Ping; if it's unreachable, " +
                    "pick another region.")
                $col = $cWarn
            } elseif ($R.Open.Count -eq 1 -and $R.Open[0] -eq $V.Code) {
                $msg = ("DBD re-measured at $($R.StartUtc.ToLocalTime().ToString('HH:mm:ss')): only $($V.Name) was " +
                    "reachable. The next lobby should be $($V.Name).${nl}Check it: ready up, and once a lobby is " +
                    "found the GAME SERVER line shows where you landed.${nl}If it's elsewhere anyway, the choice was " +
                    "made server-side; the session log has the details.")
                $col = $cOk
            } elseif ($R.Open.Count -eq 0) {
                $msg = ("DBD re-measured, but no region was reachable, not even $($V.Name).${nl}=> DBD reports every " +
                    "region as failed, so BHVR's server picks the region.${nl}Check your connection to " +
                    "$($V.Name) with Ping.")
                $col = $cWarn
            } elseif (($hs = Get-CurrentSteering).Code -ne $V.Code) {
                # e.g. Repair Hosts between the cut and DBD's measurement
                $now2 = if ($hs.Code) { "now: $(Get-PickName $hs.Code)" } else { 'no steering' }
                $msg = ("DBD re-measured at $($R.StartUtc.ToLocalTime().ToString('HH:mm:ss')), but hosts no longer " +
                    "steered to $($V.Name) ($now2), so it reached: $($R.Open -join ', ').${nl}=> To land on " +
                    "$($V.Name), Switch (no restart) to it again.")
                $col = $cWarn
            } else {
                $msg = ("DBD re-measured, but reached: $($R.Open -join ', ') (steering is $($V.Code)). Something " +
                    "resolved outside the steering; see Details.")
                $col = $cWarn
            }
            if ($V.Code -and (Test-RegionOffline $V.Code)) {
                $msg += "${nl}=> deadbyqueue.com lists $($V.Name) as offline right now: BHVR will most " +
                    "likely put you elsewhere."
            }
            if (@($R.Unknown).Count) {
                $msg += $nl + (Get-UnknownRegionText $R.Unknown)
                $col = $cWarn
            }
            if ($R.ClockText) { $msg += "${nl}Clock: $($R.ClockText -replace '^clock: ','')." }
            Set-Status $msg $col
            Write-Log "VERIFY: $msg"
            Request-Attention $msg
        }
        if ($script:Verify -and -not $script:Verify.Done -and -not $script:Busy -and
            ($now-$script:Verify.HoldEndUtc).TotalSeconds -gt 150) {
            $script:Verify.Done = $true
            if ($script:DbdPid -ne $script:Verify.Pid) {   # DBD closed (or was restarted) before it re-measured
                $msg = if ($script:SteerLife -eq 'temp' -and -not (Get-CurrentSteering -Cached).Code) {
                    ("DBD closed after the cut, before it re-measured. The temporary steering had been used, so it " +
                        "was removed (Options > Steering lasts).")
                } else {
                    $temp = if ($script:SteerLife -eq 'temp') {
                        ' (Temporary: removed once DBD has used it and closed.)'
                    } else {
                        ''
                    }
                    ("DBD closed after the cut, before it re-measured. The steering to $($script:Verify.Name) stays " +
                        "in hosts: DBD uses it when it starts.$temp")
                }
                Set-Status $msg $cDim
                Write-Log "VERIFY: $msg"
            } else {
                $msg = ('No measurement by DBD in 150 s after the cut. If DBD went straight back to its main menu ' +
                    '(no connection error, no main loading screen), it kept its old results and the next lobby lands ' +
                    'on the old region. Back out once, or use Switch + Restart.')
                Set-Status $msg $cWarn
                Write-Log "VERIFY: $msg"
                Request-Attention $msg
            }
        }
    } catch {
        $m = $_.Exception.Message
        if ($m -ne $script:LastTickErr) {
            $script:LastTickErr = $m
            Write-Log "readout update error: $m"
        }
    }
})
$timer.Start()

# The build that's running: the .exe's build time (a direct .ps1 run says so). In the start line and in Details.
$BuildText = try {
    $ea = [System.Reflection.Assembly]::GetEntryAssembly()
    if ($ea -and $ea.GetManifestResourceInfo('DBD-RegionSwitcher.ps1')) {
        "build " + [System.IO.File]::GetLastWriteTime($ea.Location).ToString('yyyy-MM-dd HH:mm')
    } else {
        'script run directly'
    }
} catch { 'build unknown' }
$etwLine = if ($script:EtwOk) {
    "ETW monitor: running. DBD measurement mode: $($script:PingMode)."
} else {
    "ETW monitor: not running ($($script:EtwErr)). A Switch waits 10 min from the tool's start and " +
        "can't check the result."
}
$udpLine = if ($script:EtwHealth -and -not $script:EtwHealth.Udp) {
    "${nl}=> UDP monitoring isn't working (no lobby / match detection). Options > Check UDP monitoring " +
        "looks for the cause."
} else {
    ''
}
$Status0 = ("Select an action to see what it will do, then press Apply.${nl}Tip: double-click a region (or press " +
    "Enter) to select its Switch; right-click it for more.${nl}Keys: F5 = Ping, Esc = Cancel while waiting, Ctrl+K = " +
    "console, Ctrl+L = log folder.${nl}${nl}Now: ") + (Get-SteerText $cur0) + $nl + $etwLine + $udpLine +
    "${nl}Session log: $($script:LogPath)"
Set-Status $Status0 $cText
$etwTxt = if (-not $script:EtwOk) {
    "off ($($script:EtwErr))"
} elseif ($script:EtwErr) {
    "ok (warning: $($script:EtwErr))"
} else {
    'ok'
}
$steerTxt = if (-not $cur0.Code) {
    'none'
} elseif (-not $cur0.Exact) {
    "$($cur0.Code) (non-standard block)"
} else {
    $cur0.Code
}
Write-Log ("Tool started (v$ToolVersion, $BuildText). ETW: $etwTxt. Hosts steering: $steerTxt. Mode: " +
    "$($script:PingMode).")
