# ---------------- what is in hosts right now ----------------
$script:SteerCache = $null
function Get-CurrentSteering {
    # -Cached (the every-3-s readout): the last result while hosts is unchanged (same write time and size). An
    # ad-blocking hosts file of a few MB takes ~35 ms to check, a stutter every 3 s otherwise.
    param([switch]$Cached)
    $fi = New-Object System.IO.FileInfo($HostsPath)
    $key = if ($fi.Exists) { "$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)" } else { 'none' }
    if ($Cached -and $key -and $script:SteerCache -and $script:SteerCache.Key -eq $key) {
        return $script:SteerCache.Value
    }
    $v = Read-Steering
    # an error is checked again next time
    $script:SteerCache = if ($key -and -not $v.Error) { @{ Key = $key; Value = $v } } else { $null }
    return $v
}
function Read-Steering {
    # @{ Code = picked region or $null; Exact = block is byte-identical to what this version would write; Error = text }
    try {
        $raw = Read-HostsText
        if ($null -eq $raw) { return @{ Code = $null; Exact = $false; Error = $null } }
        $r = Find-OurBlock $raw
        if (-not $r) { return @{ Code = $null; Exact = $false; Error = $null } }
        $m = [regex]::Match($raw.Substring($r[0],$r[1]-$r[0]),'(?m)^# pick: (\S+)')
        $code = if ($m.Success) { $m.Groups[1].Value } else { '?' }
        $exact = $m.Success -and ((Set-OurBlockText $raw (New-SteeringLines $code)) -ceq $raw)
        return @{ Code = $code; Exact = $exact; Error = $null }
    } catch { return @{ Code = $null; Exact = $false; Error = $_.Exception.Message } }
}

# ---------------- region measurement rounds (what DBD actually pinged) ----------------
function Get-RegionOfHost {
    param([string]$Name)
    foreach ($r in $Regions) { if ($r.Hosts -contains $Name) { return $r } }
    return $null
}
function Get-ResultAddresses {
    # The addresses in a DNS-Client 3008 event's QueryResults. Examples: "0.0.0.0;", "::ffff:52.1.2.3;", and with a
    # CNAME first: "type:  5 x.cloudfront.net;1.2.3.4;".
    param([string]$Results)
    $o = @()
    foreach ($tok in ($Results -split ';')) {
        $t = $tok.Trim() -replace '^::ffff:',''
        $ip = $null
        if ($t -match '^[0-9a-fA-F.:]+$' -and $t -match '[.:]' -and [System.Net.IPAddress]::TryParse($t,[ref]$ip)) {
            $o += $ip.ToString()
        }
    }
    return ,$o
}
$script:RoundDone = [DateTime]::MinValue
$script:LastRound = $null
$script:LastRoundEndUtc = $null
function Get-RemeasureUtc {
    # Earliest time DBD's gate allows a new measurement: last observed round + cooldown. $null = unknown (no round
    # seen for the running DBD, e.g. the tool was opened after DBD measured).
    if ($script:LastRoundEndUtc) {
        return $script:LastRoundEndUtc.AddSeconds($RemeasureCooldownSec+$RemeasureMarginSec)
    }
    return $null
}
function Update-MeasurementRound {
    # A round = a burst of region-endpoint lookups. Summarised 6 s after its last lookup.
    $last = [DbdEtw]::LastSteerUtc
    if ($last -eq [DateTime]::MinValue -or $last -le $script:RoundDone) { return $false }
    if (([DbdEtw]::UtcNow-$last).TotalSeconds -lt 6) { return $false }
    $script:RoundDone = $last
    $start = [DbdEtw]::RoundStartUtc(8)
    $res = [DbdEtw]::SteerResults($start.AddSeconds(-1),$last.AddSeconds(1))
    $udp = [DbdEtw]::UdpCounts($start.AddSeconds(-1),$last.AddSeconds(8))
    $state = @{}
    $ipsOf = @{}
    $http = $false
    foreach ($line in $res) {
        $p = $line.Split([char[]]'|',4)
        $name = $p[1]
        if ($name -notlike 'gamelift-ping.*') { $http = $true }
        $reg = Get-RegionOfHost $name
        if (-not $reg) { continue }
        $addrs = Get-ResultAddresses $p[3]
        $real = @($addrs | Where-Object { $_ -ne '0.0.0.0' -and $_ -ne '::' })
        # Blackholed names come back as 0.0.0.0 / :: from the resolver, and as "no data" from getaddrinfo, which drops
        # unspecified addresses. Either way DBD can't ping that region: unreachable.
        if ($real.Count) {
            $state[$reg.Code] = 'open'
            if (-not $ipsOf[$reg.Code]) { $ipsOf[$reg.Code] = @() }
            $ipsOf[$reg.Code] += $real
        } elseif ($state[$reg.Code] -ne 'open') {
            $state[$reg.Code] = 'blocked'
        }
    }
    if ($res.Count) { Set-PingMode $(if ($http) {'HTTP'} else {'UDP'}) }
    $open = @()
    $blocked = @()
    $failed = @()
    $detail = @()
    $replies = @{}
    foreach ($r in $Regions) {
        $s = $state[$r.Code]
        if (-not $s) { continue }
        if ($s -eq 'open') {
            $sent = 0
            $recv = 0
            $ips = @($ipsOf[$r.Code] | Select-Object -Unique)
            foreach ($u in $udp) {
                $q = $u.Split('|')
                if ($ips -contains $q[0].Substring(0,$q[0].LastIndexOf(':'))) {
                    $sent += [int]$q[1]
                    $recv += [int]$q[2]
                }
            }
            $open += $r.Code
            $replies[$r.Code] = @($sent,$recv)
            $detail += ("{0}: open {1} - UDP sent {2} / replies {3}" -f $r.Code,($ips -join ','),$sent,$recv)
        } elseif ($s -eq 'blocked') {
            $blocked += $r.Code
        } else {
            $failed += $r.Code
            $detail += "$($r.Code): lookup failed"
        }
    }
    $when = $start.ToLocalTime().ToString('HH:mm:ss')
    $openText = if ($open.Count) { $open -join ', ' } else { 'none' }
    $modeText = if ($http) { 'HTTP' } else { 'UDP beacons' }
    $txt = ("DBD region ping round {0}: reachable = {1} | unreachable = {2} | mode {3}" -f $when,$openText,
        $blocked.Count,$modeText)
    # Region endpoints DBD looked up that the block doesn't cover (a new region): the steering can't hide them.
    $unknown = @([DbdEtw]::DbdNamesSince($start.AddSeconds(-1)) |
        Where-Object { $_ -match $RegionHostRx -and $_ -notmatch $SteerHostRx } | Sort-Object -Unique)
    if ($unknown.Count) { $txt += " | not in the steering block: $($unknown -join ', ')" }
    $gapSec = $null
    if ($script:LastRoundEndUtc) {
        $gapSec = ($start-$script:LastRoundEndUtc).TotalSeconds
        $txt += (" | {0:N0} s after the previous round" -f $gapSec)
    }
    $script:LastRoundEndUtc = $last
    # First round after a clock jump: did DBD save the real time or the jumped one? If unsure, assume the jumped one,
    # so the next window (and the next jump) is computed from the later time.
    $clockTxt = ''
    $J = $script:ClockJump
    if ($J -and -not $J.Classified -and $start -ge $J.JumpUtc.AddSeconds(-2)) {
        $J.Classified = $true
        $v = Get-ClockJumpVerdict
        if ($v.Real) {
            $clockTxt = "clock: $($v.Text) - DBD saved the real time"
        } else {
            $script:LastRoundEndUtc = $last.AddSeconds($J.Sec)
            $from = $script:LastRoundEndUtc.ToLocalTime().ToString('HH:mm:ss')
            $clockTxt = "clock: $($v.Text) - DBD may have saved the jumped time; its next window is counted from $from"
        }
        $detail += $clockTxt
    }
    $script:LastRound = @{
        StartUtc = $start
        EndUtc = $last
        Open = $open
        Blocked = $blocked
        Failed = $failed
        Text = $txt
        Detail = $detail
        ClockText = $clockTxt
        Http = $http
        GapSec = $gapSec
        Replies = $replies
        Unknown = $unknown
    }
    Write-Log ($txt + $(if ($detail.Count) {"`r`n      " + ($detail -join "`r`n      ")} else {''}))
    return $true
}
function Get-UnknownRegionText {
    param([string[]]$Names)
    ("=> DBD also measured $($Names -join ', '): a region this version doesn't know (BHVR may have added it). The " +
        "steering can't block it, so DBD may place you there; a newer version of the tool is needed.")
}
$script:UnknownWarned = @{}

