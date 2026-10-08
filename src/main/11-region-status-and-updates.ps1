# ---------------- region status (deadbyqueue.com) ----------------
# Ping reaches AWS's ping beacons, which stay up all day. What goes away is BHVR's own capacity: regions are ramped
# down for hours when few people play (listed "offline" while their pings still answer). deadbyqueue.com, a community
# site (not BHVR), publishes which regions are online plus queue times. Public data, read-only GETs every 3 min while
# the option is on; nothing about you is sent. Its region list only gets a new timestamp when it changes; the queue
# data updates every few minutes, so that shows the site is still current.
# Trusted while our last fetch is < 10 min old and the site's queue data < 30 min (else its region list < 3 h).
$script:RegionOnline = @{}
$script:QueueTimes = @{}
$script:StatusAtUtc = [DateTime]::MinValue
$script:QueuesAtUtc = [DateTime]::MinValue
$script:StatusFetchedUtc = [DateTime]::MinValue
$script:StatusDl = @()
$script:StatusNextUtc = [DateTime]::MinValue
$script:StatusOfflineTxt = $null
$script:StatusErr = @{}   # per request (regions / queues): what failed last time
function Update-RegionStatus {
    if (-not $script:ShowStatus) { return $false }
    $changed = $false
    # A request that hangs (connection open, no answer) would hold up every later check: given up after 30 s.
    foreach ($d in @($script:StatusDl |
        Where-Object { -not $_.Task.IsCompleted -and ([DbdEtw]::UtcNow-$_.Started).TotalSeconds -gt 30 })) {
        $d.Client.CancelAsync()
    }
    foreach ($d in @($script:StatusDl | Where-Object { $_.Task.IsCompleted })) {
        $d.Client.Dispose()
        $err = Get-DownloadError $d.Task
        if (-not $err -and $d.Task.Result.Length -ge 65536) { $err = 'answer too large' }
        # Third-party data: only small answers are read, only real JSON true/false counts, only whole numbers as times.
        try {
            if (-not $err) {
                $j = $d.Task.Result | ConvertFrom-Json
                if ($d.Kind -eq 'regions') {
                    $m = @{}
                    foreach ($pr in $j.regions.PSObject.Properties) {
                        if ($pr.Value -is [bool]) { $m[$pr.Name] = $pr.Value }
                    }
                    $script:RegionOnline = $m
                    $script:StatusAtUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.lastupdated2).UtcDateTime
                    $script:StatusFetchedUtc = [DbdEtw]::UtcNow
                    $changed = $true
                } else {
                    $q = @{}
                    foreach ($pr in $j.queues.live.PSObject.Properties) {
                        $k = 0
                        $sv = 0
                        if ([int]::TryParse([string]$pr.Value.killer.time,[ref]$k) -and
                            [int]::TryParse([string]$pr.Value.survivor.time,[ref]$sv)) {
                            $q[$pr.Name] = @($k,$sv)
                        }
                    }
                    $script:QueueTimes = $q
                    $script:QueuesAtUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.lastupdated2).UtcDateTime
                    $changed = $true
                }
            }
        } catch {
            $err = $_.Exception.Message
        }
        # Logged when it starts failing and when it works again, not every 3 minutes.
        if ($err -and -not $script:StatusErr[$d.Kind]) {
            Write-Log "Region status: deadbyqueue.com didn't answer properly ($($d.Kind): $err)"
        } elseif (-not $err -and $script:StatusErr[$d.Kind]) {
            Write-Log "Region status: deadbyqueue.com answers again ($($d.Kind))"
        }
        $script:StatusErr[$d.Kind] = $err
    }
    $script:StatusDl = @($script:StatusDl | Where-Object { -not $_.Task.IsCompleted })
    if (-not $script:StatusDl.Count -and [DbdEtw]::UtcNow -ge $script:StatusNextUtc) {
        $script:StatusNextUtc = [DbdEtw]::UtcNow.AddMinutes(3)
        foreach ($k in 'regions','queues') {
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'DBD-RegionSwitcher'
            $script:StatusDl += @{
                Kind = $k
                Client = $wc
                Started = [DbdEtw]::UtcNow
                Task = $wc.DownloadStringTaskAsync([Uri]"https://api2.deadbyqueue.com/$k")
            }
        }
    }
    if ($changed) {
        $off = (@(Get-OfflineRegions) -join ', ')
        if ($off -ne $script:StatusOfflineTxt) {
            $script:OfflineChanged = $true
            $script:StatusOfflineTxt = $off
            $offText = if ($off) { "offline = $off" } else { 'all online' }
            Write-Log ("Region status (deadbyqueue.com, list last changed {0}): {1}" -f
                $script:StatusAtUtc.ToLocalTime().ToString('HH:mm'),$offText)
        }
    }
    return $changed   # new data: the list is redrawn (queue column); the open description is refreshed by the caller
}
# Killer / survivor queue in seconds for a region, or $null (no data, too old, or the option is off).
function Get-QueueSec {
    param([string]$Code)
    if (-not $script:ShowStatus -or ([DbdEtw]::UtcNow-$script:QueuesAtUtc).TotalMinutes -gt 30) { return $null }
    $q = $script:QueueTimes[$Code]
    if ($q) { return ,$q }
    return $null
}
function Format-Queue {
    param([int]$Sec)
    if ($Sec -ge 60) { "{0}:{1:00}" -f [Math]::Floor($Sec/60),($Sec%60) } else { "0:{0:00}" -f $Sec }
}
function Test-StatusFresh {
    $n = [DbdEtw]::UtcNow
    return ($script:ShowStatus -and ($n-$script:StatusFetchedUtc).TotalMinutes -le 10 -and
        (($n-$script:QueuesAtUtc).TotalMinutes -le 30 -or ($n-$script:StatusAtUtc).TotalMinutes -le 180))
}
function Get-OfflineRegions {
    if (-not (Test-StatusFresh)) { return @() }
    return @($Regions | Where-Object { $script:RegionOnline.ContainsKey($_.Code) -and
        -not $script:RegionOnline[$_.Code] } | ForEach-Object {
        $_.Code
    })
}
function Test-RegionOffline {
    param([string]$Code)
    return ((Test-StatusFresh) -and $script:RegionOnline.ContainsKey($Code) -and -not $script:RegionOnline[$Code])
}
function Get-PickStatusWarning {
    param([string]$Code)
    if (-not (Test-RegionOffline $Code)) { return '' }
    return "=> deadbyqueue.com lists $(Get-PickName $Code) as offline right now: you'd most likely be put elsewhere.$nl"
}

# ---------------- update check (GitHub releases) ----------------
# At start and then once a day while Options > Check for updates is on: one GET of this project's latest release on
# GitHub (public data; like any web request it shows GitHub your IP address). Nothing is downloaded or installed: the
# footer says a newer version is out and opens its release page when clicked. Drafts and pre-releases don't count.
$ReleaseRepo = '010root/DBD-RegionSwitcher'   # "owner/repo" on GitHub; empty = no check
$script:UpdateDl = $null
$script:UpdateNextUtc = [DateTime]::MinValue
$script:UpdateAvail = $null
function Update-UpdateCheck {
    if (-not $script:UpdateCheck -or $ReleaseRepo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { return }
    $d = $script:UpdateDl
    if ($d) {
        if (-not $d.Task.IsCompleted) {
            # hung request
            if (([DbdEtw]::UtcNow-$d.Started).TotalSeconds -gt 30) { $d.Client.CancelAsync() }
            return
        }
        $script:UpdateDl = $null
        $d.Client.Dispose()
        $err = Get-DownloadError $d.Task
        if (-not $err -and $d.Task.Result.Length -ge 262144) { $err = 'answer too large' }
        # Third-party data: a small answer, and only a plain version number counts.
        try {
            if (-not $err) {
                $tag = [string]($d.Task.Result | ConvertFrom-Json).tag_name
                if ($tag -match '^v?(\d{1,4}(\.\d{1,4}){1,3})$' -and [version]$matches[1] -gt [version]$ToolVersion) {
                    if ($script:UpdateAvail -ne $matches[1]) {
                        $script:UpdateAvail = $matches[1]
                        Write-Log ("Update: version $($matches[1]) is out (this is $ToolVersion) - " +
                            "github.com/$ReleaseRepo/releases")
                        Show-UpdateNotice
                    }
                }
            }
        } catch {
            $err = $_.Exception.Message
        }
        if ($err) { Write-Log "Update check failed ($err), tried again in a day" }
        return
    }
    if ([DbdEtw]::UtcNow -lt $script:UpdateNextUtc) { return }
    $script:UpdateNextUtc = [DbdEtw]::UtcNow.AddHours(24)
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'DBD-RegionSwitcher'   # GitHub's API refuses requests without one
    $wc.Headers['Accept'] = 'application/vnd.github+json'
    $script:UpdateDl = @{
        Client = $wc
        Started = [DbdEtw]::UtcNow
        Task = $wc.DownloadStringTaskAsync([Uri]"https://api.github.com/repos/$ReleaseRepo/releases/latest")
    }
}