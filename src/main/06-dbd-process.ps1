# ---------------- DBD process ----------------
function Get-DbdProcess { Get-Process -Name $DbdProcs -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Get-DbdStore {
    param($P)   # which store's DBD a process is
    switch -Wildcard ($P.ProcessName) {
        '*-EGS-*' { 'Epic Games' }
        '*-WinGDK-*' { 'Xbox / Game Pass' }
        default { 'Steam' }
    }
}

function Get-EndpointName {
    param([string]$Ep)   # "1.2.3.4:443" -> "1.2.3.4:443 (name DBD looked up)"
    $ip = $Ep.Substring(0,$Ep.LastIndexOf(':'))
    if ($ip -eq '127.0.0.1') { return "$Ep (this PC)" }
    $n = [DbdEtw]::NamesForIp($ip)
    "$Ep (" + $(if ($n) { $n } else { 'no lookup by DBD seen, name unknown' }) + ')'
}
function Invoke-CutDbd {
    # DBD's connections all belong to one process. Kill them on tight ~15 ms sweeps until they STAY gone (25 sweeps in
    # a row with nothing left, at most 10 s), AND flush DNS repeatedly during the kill - otherwise DBD re-caches the
    # real GameLift IPs while retrying, and reconnects to its old region despite the hosts file being correct.
    # The sweeps read the TCP table directly: microseconds each (Get-NetTCPConnection takes ~50-100 ms, which would
    # freeze the window for seconds).
    $p = Get-DbdProcess
    if (-not $p) { return 'DBD isn''t running. The steering applies when it starts.' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $n = 0
    $emptyStreak = 0
    $sweep = 0
    $per = [ordered]@{}
    $killed = ''
    while ($sw.ElapsedMilliseconds -lt 10000) {
        $k = [TcpKill]::KillPidAll([uint32]$p.Id,[ref]$killed)
        if ($k -gt 0) {
            $emptyStreak = 0
            $n += $k
            foreach ($ep in ($killed -split ' ')) { if ($ep) { $per[$ep] = 1+[int]$per[$ep] } }
        } else {
            $emptyStreak++
            if ($emptyStreak -ge 25) { break }
        }
        if ($sweep -eq 0 -and $k -gt 0) {
            Write-Log ("  DBD's TCP connections at the cut: " +
                ((@($killed -split ' ' | Select-Object -Unique) | ForEach-Object { Get-EndpointName $_ }) -join '; '))
        }
        $sweep++
        if ($sweep % 10 -eq 0) { Invoke-DnsFlush }   # keep the blackholed steering the only thing cached
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
    Invoke-DnsFlush                                 # final flush so reconnect uses the steering
    # Which connections DBD kept reopening during the cut (names = what DBD looked up for that address).
    if ($per.Count) {
        Write-Log ("  cut: {0} kills in {1:N1} s: {2}" -f $n,($sw.ElapsedMilliseconds/1000),
            ((@($per.Keys) | ForEach-Object { "$(Get-EndpointName $_) x$($per[$_])" }) -join '; '))
    }
    return "Cut DBD's TCP connections ($n kills)."
}

# Steam's own "is DBD running" flag (HKCU\Software\Valve\Steam\Apps\381210, value Running). A launch request sent
# while it's still 1 can be ignored by Steam ("already running"), so the relaunch waits for it to drop.
$SteamDbdKey = 'HKCU:\Software\Valve\Steam\Apps\381210'
function Get-SteamDbdValue {
    param([string]$Name)
    try { return (Get-ItemProperty $SteamDbdKey -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function Test-SteamSaysDbdRunning { return ((Get-SteamDbdValue 'Running') -eq 1) }
function Wait-Until {
    param([scriptblock]$Done,[int]$MaxMs)   # polls every 100 ms; the window stays responsive
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Done) -and $sw.ElapsedMilliseconds -lt $MaxMs) {
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.Application]::DoEvents()
    }
    return (& $Done)
}
$script:LaunchWatch = $null
function Open-AsUser {
    param([string]$Target,[string]$Arguments = '',[int]$Show = 1)   # Show 0 = hidden
    # Opened by the desktop (Explorer) - the way a double-click on Steam's own DBD shortcut opens steam://rungameid -
    # so it runs as you, not with this tool's admin rights. Opened from here directly, a Steam that wasn't running
    # would start as admin (and DBD with it), and whatever program your user account registered for steam://, https://
    # or folders would run with admin rights. So there's no fallback: without the desktop, nothing is opened.
    # (Explorer started with a link as its argument doesn't open it.)
    $h = 0
    # the desktop, SWFO_NEEDDISPATCH
    $desk = (New-Object -ComObject Shell.Application).Windows().FindWindowSW(0,$null,8,[ref]$h,1)
    $desk.Document.Application.ShellExecute($Target,$Arguments,'','open',$Show)
}
# ---- starting DBD: each store's own way, looked up on this PC ----
# All of them are opened as you, through the desktop.
#  - Steam: steam://rungameid/381210
#  - Epic Games: the link Epic's own shortcuts use, built from the game's install manifest
#    (ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item, the entry whose executable is DBD's):
#    com.epicgames.launcher://apps/<namespace>%3A<catalog item>%3A<app name>?action=launch&silent=true
#  - Xbox / Game Pass: the app's Start-menu launch ID ("<package family>!<app>", packaged apps only), opened like a
#    click in the Start menu
function Test-SteamDbdInstalled { return ((Get-SteamDbdValue 'Installed') -eq 1) }   # Steam's own per-user record
$ProgramData = [Environment]::GetFolderPath('CommonApplicationData')
$EpicManifestDir = Join-Path $ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
function Get-EpicDbdLink {
    param([string]$ManifestDir = $EpicManifestDir,[string]$Rx = '(?i)DeadByDaylight')
    foreach ($f in @(Get-ChildItem -LiteralPath $ManifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        # a damaged manifest: skipped
        try { $j = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
        # half installed / an add-on
        if ($j.bIsIncompleteInstall -or ($j.MainGameAppName -and $j.MainGameAppName -ne $j.AppName)) { continue }
        if (((@($j.LaunchExecutable,$j.MainWindowProcessName)+@($j.ProcessNames)) -join ' ') -notmatch $Rx) { continue }
        $ids = @($j.CatalogNamespace,$j.CatalogItemId,$j.AppName)
        # only plain ids go into the link
        if (@($ids | Where-Object { "$_" -notmatch '^[A-Za-z0-9_.-]{1,64}$' }).Count) { continue }
        return ('com.epicgames.launcher://apps/{0}%3A{1}%3A{2}?action=launch&silent=true' -f $ids[0],$ids[1],$ids[2])
    }
    return $null
}
function Get-XboxDbdApp {
    param([string]$NameRx = '(?i)^Dead by Daylight')
    # Steam's own Start-menu shortcut has the same name, with a steam:// link: only packaged-app IDs count
    try {
        $a = @(Get-StartApps -ErrorAction Stop | Where-Object {
            $_.Name -match $NameRx -and $_.AppID -match '^[A-Za-z0-9.-]+_[a-z0-9]{13}![A-Za-z0-9.]+$'
        })
    } catch { return $null }
    if ($a.Count) { return "shell:AppsFolder\$($a[0].AppID)" }
    return $null
}
$script:LauncherCache = @{}
function Get-DbdLauncher {
    param([string]$Store,[switch]$Fresh)   # Target (what to open) and How (for the texts); $null: not found here
    # without Steam's link type, opening it would pop Windows' "Pick an app"
    if ($Store -ne 'Epic Games' -and $Store -ne 'Xbox / Game Pass') {
        if (-not (Test-Path 'Registry::HKEY_CLASSES_ROOT\steam')) { return $null }
        return @{ Target = 'steam://rungameid/381210'; How = 'Steam' }
    }
    # Looked up at most every 5 min (the Start-menu list takes ~0.4 s, and the Switch + Restart description asks on
    # every click); -Fresh (Apply) always looks again.
    $c = $script:LauncherCache[$Store]
    if (-not $Fresh -and $c -and ([DbdEtw]::UtcNow-$c.Utc).TotalMinutes -lt 5) { return $c.Value }
    $v = $null
    # only with its link type registered - an unregistered one would pop Windows' "Pick an app"
    if ($Store -eq 'Epic Games') {
        $t = Get-EpicDbdLink
        if ($t -and (Test-Path 'Registry::HKEY_CLASSES_ROOT\com.epicgames.launcher')) {
            $v = @{ Target = $t; How = 'the Epic Games launcher' }
        }
    } else {
        $t = Get-XboxDbdApp
        if ($t) { $v = @{ Target = $t; How = 'the Xbox app''s Start menu entry' } }
    }
    $script:LauncherCache[$Store] = @{ Value = $v; Utc = [DbdEtw]::UtcNow }
    return $v
}
function Start-Dbd {
    param([string]$Store = 'Steam')
    $L = Get-DbdLauncher $Store
    if (-not $L) {
        Write-Log "  launch: DBD's $Store entry wasn't found on this PC - not started"
        return $false
    }
    try { Open-AsUser $L.Target } catch {
        Write-Log "  launch: $($L.How) couldn't be asked to start DBD: $($_.Exception.Message)"
        return $false
    }
    $script:LaunchWatch = @{ Utc = [DbdEtw]::UtcNow; How = $L.How }
    Write-Log "  launch: asked $($L.How) to start DBD ($($L.Target), as you, through the desktop)"
    return $true
}
# DBD's launcher opened in the last 30 s and the game isn't there yet: a start under way (the game follows within about
# 10 s), not a launcher left open.
function Test-LauncherStarting {
    param($Procs)
    foreach ($p in @($Procs)) {
        try {
            if (((Get-Date)-$p.StartTime).TotalSeconds -lt 30) { return $true }
        } catch {}
    }
    return $false
}
function Restart-Dbd {
    # Close DBD (and its lingering EAC process), wait until they're really gone (and, for Steam, its running flag), then
    # start DBD again the store's own way, the window staying responsive meanwhile.
    # DBD not running: nothing is closed (EasyAntiCheat may belong to another game) - it's only started.
    # DBD's own launcher (DeadByDaylight.exe, EasyAntiCheat's start-up program) normally ends with the game; left open -
    # e.g. showing an EasyAntiCheat error after the game ended - the store still counts DBD as running and ignores a
    # launch request. So it's closed too.
    param([string]$Store = 'Steam')
    $via = (Get-DbdLauncher $Store).How
    $boot = 'DeadByDaylight'
    $game = Get-Process -Name $DbdProcs -ErrorAction SilentlyContinue
    if (-not $game) {
        $left = @(Get-Process -Name $boot -ErrorAction SilentlyContinue)
        if (Test-LauncherStarting $left) {
            Write-Log "  start: DBD's launcher opened less than 30 s ago - DBD is already starting, not started again"
            return 'DBD is already starting; it loads with the steering.'
        }
        if ($left.Count) {
            $left | Stop-Process -Force -ErrorAction SilentlyContinue
            $gone = Wait-Until {
                -not (Get-Process -Name $boot -ErrorAction SilentlyContinue) -and
                    ($Store -ne 'Steam' -or -not (Test-SteamSaysDbdRunning))
            } 15000
            if ($Store -ne 'Steam') { [void](Wait-Until { $false } 2000) }
            Write-Log ("  start: DBD's launcher was open without the game (an EasyAntiCheat message?) - closed it " +
                "first$(if (-not $gone) { ', not fully gone - starting anyway' })")
        }
        if (Start-Dbd $Store) {
            return "Starting DBD through $via (it wasn't running)."
        }
        return "DBD isn't running and couldn't be started: start it from $Store yourself."
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $game | Stop-Process -Force -ErrorAction SilentlyContinue
    $eac = 'EasyAntiCheat','EasyAntiCheat_EOS','start_protected_game',$boot
    foreach ($en in $eac) {
        Get-Process -Name $en -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $gone = Wait-Until {
        -not (Get-Process -Name ($DbdProcs+$eac) -ErrorAction SilentlyContinue) -and
            ($Store -ne 'Steam' -or -not (Test-SteamSaysDbdRunning))
    } 15000
    # Epic / Xbox: no "running" flag the tool can read - a short pause lets the launcher notice the game has ended.
    if ($Store -ne 'Steam') { [void](Wait-Until { $false } 2000) }
    $state = if (-not $gone) {
        'still not fully gone - starting anyway'
    } elseif ($Store -eq 'Steam') {
        'DBD and EasyAntiCheat gone, Steam''s running flag cleared'
    } else {
        'DBD and EasyAntiCheat gone'
    }
    Write-Log ("  restart: DBD closed; {0} after {1:N1} s" -f $state,($sw.ElapsedMilliseconds/1000))
    if (Start-Dbd $Store) { return "DBD closed; starting it again through $via." }
    return "DBD closed, but it couldn't be started again: start it from $Store yourself."
}
function Update-LaunchWatch {
    # After asking the store to start DBD: log when it's up, or say so if it never came.
    $L = $script:LaunchWatch
    if (-not $L) { return }
    $el = ([DbdEtw]::UtcNow-$L.Utc).TotalSeconds
    if ($script:DbdPid) {
        Write-Log ("  launch: DBD is running {0:N0} s after the launch request (pid {1})" -f $el,$script:DbdPid)
        $script:LaunchWatch = $null
    } elseif ($el -ge 120) {
        $script:LaunchWatch = $null
        Write-Log '  launch: DBD did not start within 2 min of the launch request'
        $via = if ($L.How) { $L.How } else { 'Steam' }
        if (-not $script:Busy) {
            Set-Status ("DBD hasn't started 2 min after the tool asked $via to start it.${nl}Check it: it may be " +
                "showing an update, a sign-in or an error. The steering is already in hosts, so starting DBD " +
                "yourself works the same.") $cWarn
            Request-Attention "DBD hasn't started 2 min after the tool asked $via to start it."
        }
    }
}

