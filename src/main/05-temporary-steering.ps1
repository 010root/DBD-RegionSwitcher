# ---------------- temporary steering (Options > Steering lasts) ----------------
# Temporary: the steering is removed once DBD has used it and closed. DBD only uses it when it measures - at launch and
# when it reloads during a session - so it isn't needed after that session, and nothing else (another game using the
# same AWS region endpoints) is affected later. "Used" = a DBD started after the steering was written, or a measurement
# seen since: steering written while DBD runs but hasn't measured with it yet (Switch + Restart whose start failed,
# "close DBD and start it yourself") stays until DBD has. Closing the tool while DBD runs offers to stay in the tray
# until DBD closes; a block left by a run that ended early (crash, power loss) is removed at the next start, if DBD
# isn't running then.
$script:TempArmed = $false
$script:TempFrom = @{ Pid = 0; Utc = [DateTime]::MinValue }   # start: a steering already in hosts counts as used
function Reset-TempArm {   # new steering, or DBD about to be restarted: it has to be used again first
    $script:TempArmed = $false
    $script:TempFrom = @{ Pid = $script:DbdPid; Utc = [DbdEtw]::UtcNow }
}
function Update-TempSteering {   # every 3 s, from the tick, with the steering just read; returns the region it removed
    param($Cur)
    # not during an action or a launch: Switch + Restart closes DBD on purpose, and the new DBD needs the steering
    if ($script:SteerLife -ne 'temp' -or $script:Busy -or $script:LaunchWatch) { return }
    if (-not $Cur -or -not $Cur.Code) {
        $script:TempArmed = $false
        return
    }
    if ($script:DbdPid) {
        $F = $script:TempFrom
        if ($script:DbdPid -ne $F.Pid -or ($script:LastRoundEndUtc -and $script:LastRoundEndUtc -ge $F.Utc)) {
            $script:TempArmed = $true
        }
        return
    }
    if ($script:TempArmed -and (Remove-TempSteering 'DBD closed')) { return $Cur.Code }
}
function Remove-TempSteering {
    param([string]$Why)
    $script:TempArmed = $false
    try {
        Clear-Steering
        Set-VerifyUnsteered
        Write-Log "Temporary steering removed ($Why)."
        return $true
    } catch {
        Write-Log "Temporary steering couldn't be removed ($Why): $($_.Exception.Message)"
        return $false
    }
}
function Get-TempQuitPlan {   # closing the tool: 'none' / 'remove' (DBD isn't running) / 'ask' (DBD is running)
    if ($script:SteerLife -ne 'temp') { return 'none' }
    $c = Get-CurrentSteering
    if (-not $c.Code) { return 'none' }
    if (Get-DbdProcess) { return 'ask' }
    return 'remove'
}
