# ---------------- session log + remembered state ----------------
# DBDRS_APPDIR: the verification scripts point this at their own folder, so tests never touch your logs or settings.
# Only honored inside the user's own profile: this process runs as admin and the variable can be set without admin,
# so it must not be able to aim the tool's writes at system folders. The profile folder itself comes from the account.
$prof = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\')+'\'
$AppDir = Join-Path $prof 'AppData\Local\DBD-RegionSwitcher'
foreach ($cand in @($env:DBDRS_APPDIR,$(if ($env:LOCALAPPDATA) {Join-Path $env:LOCALAPPDATA 'DBD-RegionSwitcher'}))) {
    if (-not $cand) { continue }
    try {
        $full = [IO.Path]::GetFullPath($cand)
        if ($full.StartsWith($prof,[StringComparison]::OrdinalIgnoreCase)) {
            $AppDir = $full
            break
        }
    } catch {}
}
$LogDir = Join-Path $AppDir 'logs'
# This folder is yours (any program running as you can change it), but the tool writes there as admin. A junction or
# symbolic link put in place of the folder or one of its files would send those writes - and the log clean-up -
# somewhere else, e.g. into a system folder. So nothing is written through a link: checked right before every write.
# The folders between the profile and the tool's folder count too (DBDRS_APPDIR / LOCALAPPDATA can point anywhere in
# the profile, e.g. under a junction made there).
function Test-NoLink {
    param([string[]]$Paths)   # $true if none of them is a junction / symbolic link (missing = fine)
    foreach ($x in @($Paths)+@($script:AppDirParents)) {
        if (-not $x) { continue }
        try {
            if ([System.IO.File]::GetAttributes($x) -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
        } catch {}
    }
    return $true
}
$script:AppDirParents = @()
$pd = [IO.Path]::GetDirectoryName($AppDir)
while ($pd -and $pd.Length -ge $prof.Length -and
    $pd.StartsWith($prof.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
    $script:AppDirParents += $pd
    $pd = [IO.Path]::GetDirectoryName($pd)
}
$script:LinkRefused = $false
# Logs are kept 60 days. Sessions that only opened and closed (nothing happened) go after a day.
try {
    if (Test-NoLink $AppDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    if (Test-NoLink $AppDir,$LogDir) {
        Get-ChildItem $LogDir -Filter 'session-*.log' -File | Where-Object {
            $expired = $_.LastWriteTime -lt (Get-Date).AddDays(-60)
            # a session where nothing happened
            $blank = $_.Length -lt 200 -and $_.LastWriteTime -lt (Get-Date).AddDays(-1)
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and ($expired -or $blank)
        } | Remove-Item -Force
    }
} catch {}
$script:LogPath = Join-Path $LogDir ('session-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:ConBuf = New-Object System.Collections.Generic.List[string]
# Logs, the activity box and screenshots of it end up in bug reports: a path in your profile folder (it has your
# Windows user name in it) is shown as %USERPROFILE%\..., e.g. the session log's path or an error that names the .exe.
$ProfileRx = '(?i)' + [regex]::Escape($prof.TrimEnd('\')) + '(?!\w)'
function Hide-ProfilePath {
    param([string]$Text)
    if ($ProfileRx) { return ($Text -replace $ProfileRx,'%USERPROFILE%') }
    return $Text
}
function Write-Log {
    param([string]$Msg)
    $Msg = Hide-ProfilePath $Msg
    $line = "{0}  {1}" -f [DbdEtw]::UtcNow.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff'),$Msg
    if (Test-NoLink $AppDir,$LogDir,$script:LogPath) {
        try { [System.IO.File]::AppendAllText($script:LogPath,"$line`r`n",$Utf8NoBom) } catch {}
    } elseif (-not $script:LinkRefused) {
        $script:LinkRefused = $true
        $where = Hide-ProfilePath $AppDir
        $line += "   [not written to disk: the tool's folder $where (or its logs folder) is a link]"
    }
    # not "if ($script:ConBuf)": an empty list counts as false
    if ($null -ne $script:ConBuf) {
        $script:ConBuf.Add($line)
        if ($script:ConBuf.Count -gt 3000) { $script:ConBuf.RemoveRange(0,1000) }
    }
    if ($script:ConBox) { try { Add-ConsoleLine $line } catch {} }
}

# How DBD measures regions (BHVR's remote config decides): 'UDP' = gamelift-ping beacons, resolved through Windows on
# every ping, so a DNS flush is enough. 'HTTP' = gamelift.* via libcurl, whose own 60 s DNS cache needs waiting out.
# Remembered across runs; refreshed every time a measurement round is observed.
$StatePath = Join-Path $AppDir 'state.txt'
$script:PingMode = 'unknown'
$script:PingModeUtc = [DateTime]::MinValue
$script:ClockOpt = $false
$script:NgenOpt = $false
$script:NgenQuickFailUtc = [DateTime]::MinValue   # when NGENUITY's quick restart last failed
$script:OnTop = $false
$script:WinState = ''
$script:SortSpec = ''
$script:LastPick = ''
$script:ShowBars = $true
$script:AutoPing = $false
$script:ShowStatus = $true
$script:CloseTo = 'ask'
$script:DbdStore = ''
$script:SteerLife = 'keep'
$script:UpdateCheck = $true
$script:WinDpi = 0   # display scale the saved window size was measured at (96 = 100 %); set with WinState
try {
    if (Test-Path $StatePath) {
        $kv = @{}
        foreach ($l in [System.IO.File]::ReadAllLines($StatePath)) {
            $i = $l.IndexOf('=')
            if ($i -gt 0) { $kv[$l.Substring(0,$i)] = $l.Substring($i+1) }
        }
        $script:ClockOpt = ($kv['clockjump'] -eq '1')
        $script:NgenOpt = ($kv['ngenuity'] -eq '1')
        # a damaged value must not stop the settings after it
        if ($kv['ngenquickfail']) {
            try {
                $script:NgenQuickFailUtc = [DateTime]::Parse($kv['ngenquickfail'],
                    [Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            } catch {}
        }
        $script:OnTop = ($kv['ontop'] -eq '1')
        if ($kv['window']) { $script:WinState = $kv['window'] }
        if ($kv['dpi'] -match '^\d{2,3}$') { $script:WinDpi = [int]$kv['dpi'] }
        if ($kv['sort']) { $script:SortSpec = $kv['sort'] }
        $script:ShowBars = ($kv['bars'] -ne '0')
        $script:AutoPing = ($kv['autoping'] -eq '1')
        if ($kv['pick'] -match '^[a-z]{2}-[a-z]+-\d$') { $script:LastPick = $kv['pick'] }
        $script:ShowStatus = ($kv['status'] -ne '0')
        $script:UpdateCheck = ($kv['updates'] -ne '0')
        if (@('ask','tray','quit') -contains $kv['closeto']) { $script:CloseTo = $kv['closeto'] }
        if (@('Steam','Epic Games','Xbox / Game Pass') -contains $kv['store']) { $script:DbdStore = $kv['store'] }
        if ($kv['steering'] -eq 'temp') { $script:SteerLife = 'temp' }
        if ($kv['mode'] -eq 'UDP' -or $kv['mode'] -eq 'HTTP') {
            $u = [DateTime]::Parse($kv['utc'],[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
            if (([DbdEtw]::UtcNow-$u).TotalDays -le 30) {
                $script:PingMode = $kv['mode']
                $script:PingModeUtc = $u
            }
        }
    }
} catch {
    Write-Log "Settings couldn't be read completely ($($_.Exception.Message)), the rest are defaults."
}
function Save-State {
    $ngenFail = ''
    if ($script:NgenQuickFailUtc -gt [DateTime]::MinValue) { $ngenFail = $script:NgenQuickFailUtc.ToString('o') }
    $v = [ordered]@{
        mode = $script:PingMode
        utc = $script:PingModeUtc.ToString('o')
        clockjump = [int]$script:ClockOpt
        ngenuity = [int]$script:NgenOpt
        ngenquickfail = $ngenFail
        ontop = [int]$script:OnTop
        window = $script:WinState
        dpi = $script:WinDpi
        sort = $script:SortSpec
        pick = $script:LastPick
        bars = [int]$script:ShowBars
        autoping = [int]$script:AutoPing
        status = [int]$script:ShowStatus
        closeto = $script:CloseTo
        store = $script:DbdStore
        steering = $script:SteerLife
        updates = [int]$script:UpdateCheck
    }
    try {
        if (-not (Test-NoLink $AppDir,$StatePath)) {
            throw "the tool's folder or state.txt is a link (junction / symbolic link)"
        }
        $lines = @($v.Keys | ForEach-Object { "$_=$($v[$_])" })
        [System.IO.File]::WriteAllText($StatePath,(($lines -join "`r`n") + "`r`n"),$Utf8NoBom)
    } catch {
        if (-not $script:StateSaveWarned) {
            $script:StateSaveWarned = $true
            Write-Log "Settings couldn't be saved ($($_.Exception.Message))."
        }
    }
}
function Set-PingMode {
    param([string]$Mode)
    if ($Mode -ne $script:PingMode) { Write-Log "Region measurement mode: $Mode (was $($script:PingMode))" }
    $script:PingMode = $Mode
    $script:PingModeUtc = [DbdEtw]::UtcNow
    Save-State
}

