# Unit test of the re-measure gate (Get-RemeasureUtc / Get-CutGate) using the script's own functions.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$m = [regex]::Match([IO.File]::ReadAllText($src),
    "(?s)PSTypeName\]'DbdEtw'\)\.Type\)\s*\{\s*Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Add-Type -TypeDefinition $m.Groups[1].Value          # the gate functions read time through [DbdEtw]::UtcNow
$t = $null
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
foreach ($s in $ast.EndBlock.Statements) {
    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $s.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        @('RemeasureCooldownSec','RemeasureMarginSec','FlowGapSec') -contains $s.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($s.Extent.Text))
    }
}
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if (@('Get-RemeasureUtc','Get-CutGate','Get-PendingCut','Get-DbdStore','Get-RestartStore','Get-EpicDbdLink',
        'Get-XboxDbdApp','Get-DbdLauncher','Start-Dbd','Reset-TempArm','Update-TempSteering','Remove-TempSteering',
        'Get-TempQuitPlan','Get-DownloadError','Update-UpdateCheck','Format-UiText','Update-MatchFlow',
        'Test-LauncherStarting') -contains $f.Name) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
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

Check 'cooldown constant is 600 s (binary default)' ($RemeasureCooldownSec -eq 600)

# Lobby / match link (what a waiting Switch holds on): a stand-in for the server DBD talks to, quiet times set by hand
function Write-Log { param($t) $script:FlowLog += ,$t }
$script:FlowLog = @()
$script:Srv = $null
function Get-MatchServer { if ($script:Srv) { @{ Ep = $script:Srv; Ip = $script:Srv.Split(':')[0]; PerSec = 30 } } }
$script:Flow = $null
Check 'link: no server = none' (-not (Update-MatchFlow))
$script:Srv = '3.69.241.30:7783'
Check 'link: server talking = link' ([bool](Update-MatchFlow))
$script:Srv = $null
Check 'link: server quiet = none, logged once' (-not (Update-MatchFlow) -and -not (Update-MatchFlow) -and
    @($script:FlowLog -match 'traffic stopped').Count -eq 1) ($script:FlowLog -join ' / ')
$script:Srv = '3.69.241.30:7783'
$script:Flow.LastUtc = [DbdEtw]::UtcNow.AddSeconds(-40)
Check 'link: same server back after 40 s = link, logged' ([bool](Update-MatchFlow) -and
    @($script:FlowLog -match 'back after 40 s').Count -eq 1) ($script:FlowLog -join ' / ')
$script:Srv = '18.185.103.25:7783'
Check 'link: another server = a new record' ([bool](Update-MatchFlow) -and $script:Flow.Ep -eq '18.185.103.25:7783')
Remove-Item Function:\Get-MatchServer, Function:\Write-Log

$now = [DateTime]::UtcNow
# 1) last measurement known
$script:LastRoundEndUtc = $now.AddSeconds(-100)
$script:DbdSeenStart = $true
$script:EtwStartUtc = $now.AddSeconds(-500)
$g = Get-CutGate
Check 'known round: gate = round + 600 + margin' ([Math]::Abs(($g.Utc-$now.AddSeconds(505)).TotalSeconds) -lt 1) $g.Why
$script:LastRoundEndUtc = $now.AddSeconds(-700)
$g = Get-CutGate
Check 'known round > 10 min ago: gate already open' ($g.Utc -le [DateTime]::UtcNow) $g.Why
Check 'known round > 10 min ago: text says open, no "opens at"' ($g.Why -like 'open (*' -and
    $g.Why -notmatch 'opens at') $g.Why
Check 'known round < 10 min ago: text says when' ($($script:LastRoundEndUtc = $now.AddSeconds(-100)
    (Get-CutGate).Why) -match 'opens at') ''
# 2) DBD started while watching, launch round not seen yet -> keep waiting
$script:LastRoundEndUtc = $null
$script:DbdSeenStart = $true
$g = Get-CutGate
Check 'no round yet (DBD launched while watching): keeps waiting' ($g.Utc -gt [DateTime]::UtcNow) $g.Why
# 3) tool opened after DBD -> worst case from tool start
$script:DbdSeenStart = $false
$script:EtwStartUtc = $now.AddSeconds(-60)
$g = Get-CutGate
$off = ($g.Utc - $now.AddSeconds(545)).TotalSeconds
Check 'tool opened after DBD: worst case = tool start + 600 + margin' ([Math]::Abs($off) -lt 1) $g.Why
$script:EtwStartUtc = $now.AddSeconds(-700)
$g = Get-CutGate
Check 'tool opened after DBD over 10 min ago: open, no "opens at"' ($g.Utc -le [DateTime]::UtcNow -and
    $g.Why -like 'open (*' -and $g.Why -notmatch 'opens at') $g.Why
# 4) a Switch cut DBD and DBD hasn't measured yet: a new Switch only rewrites hosts (Get-PendingCut)
$script:EtwOk = $true
$script:EtwHealth = @{ Udp = $true; Dns = $true }
$script:PingMode = 'UDP'
$script:DbdPid = 4242
$script:Verify = @{
    CutUtc = [DateTime]::UtcNow.AddSeconds(-30)
    HoldEndUtc = [DateTime]::UtcNow.AddSeconds(-20)
    Name = 'Asia (Tokyo)'
    Code = 'ap-northeast-1'
    Pid = 4242
    Done = $false
}
Check 'pending: cut done, no DBD lookup since' ([bool](Get-PendingCut)) ''
Check 'pending: other DBD process (restarted) = not pending' (-not (Get-PendingCut 999)) ''
$script:PingMode = 'HTTP'
Check 'pending: HTTP mode (libcurl caches lookups) = not pending' (-not (Get-PendingCut)) ''
$script:PingMode = 'UDP'
$script:EtwHealth = @{ Udp = $true; Dns = $false }
Check 'pending: no DNS events (a measurement could go unseen) = not pending' (-not (Get-PendingCut)) ''
$script:EtwHealth = @{ Udp = $true; Dns = $true }
$script:Verify.Done = $true
Check 'pending: DBD measured / verification over = not pending' (-not (Get-PendingCut)) ''
$script:Verify.Done = $false
$script:DbdPid = 0
Check 'pending: DBD not running = not pending' (-not (Get-PendingCut)) ''
$script:DbdPid = 4242
# a cut that used the clock option, clock back before DBD measured: its 10-min rule blocks the measurement now
$script:Verify.Jump = $true
$script:LastRoundEndUtc = [DateTime]::UtcNow.AddSeconds(-120)
Check 'pending: clock-jump cut, clock back, window still closed = not pending' (-not (Get-PendingCut)) ''
$script:LastRoundEndUtc = [DateTime]::UtcNow.AddSeconds(-700)
Check 'pending: clock-jump cut, clock back, window open by real time = pending' ([bool](Get-PendingCut)) ''
$script:Verify.Jump = $false
$script:LastRoundEndUtc = [DateTime]::UtcNow.AddSeconds(-120)
Check 'pending: cut without the clock, window closed = still pending' ([bool](Get-PendingCut)) ''
# a DBD region lookup 5 s ago (after the cut 30 s ago) = its measurement has started
[DbdEtw].GetField('_lastSteerTicks',[Reflection.BindingFlags]'NonPublic,Static').SetValue($null,
    [DateTime]::UtcNow.AddSeconds(-5).Ticks)
Check 'pending: DBD started measuring after the cut = not pending' (-not (Get-PendingCut)) ''
# DBD from other stores: everything works by process; Switch + Restart needs to know which store starts it again
foreach ($c in @(@('DeadByDaylight-Win64-Shipping','Steam'),@('DeadByDaylight-EGS-Shipping','Epic Games'),
    @('DeadByDaylight-WinGDK-Shipping','Xbox / Game Pass'))) {
    Check "store of $($c[0]) = $($c[1])" ((Get-DbdStore ([pscustomobject]@{ ProcessName = $c[0] })) -eq $c[1])
}
function Get-DbdProcess { $script:FakeDbd }
$script:FakeDbd = [pscustomobject]@{ ProcessName = 'DeadByDaylight-EGS-Shipping' }
$script:DbdStore = 'Steam'
Check 'restart store: the running DBD decides' ((Get-RestartStore) -eq 'Epic Games')
$script:FakeDbd = $null
$script:DbdStore = 'Xbox / Game Pass'
Check 'restart store: not running = the one seen last time' ((Get-RestartStore) -eq 'Xbox / Game Pass')
$script:DbdStore = ''
$realLauncher = ${function:Get-DbdLauncher}
$script:SteamDbd = $true
$script:Found = @()
function Test-SteamDbdInstalled { $script:SteamDbd }
function Get-DbdLauncher { param($Store) if ($script:Found -contains $Store) { @{ Target = 'x'; How = 'y' } } }
Check 'restart store: never seen, Steam has DBD = Steam' ((Get-RestartStore) -eq 'Steam')
$script:SteamDbd = $false
$script:Found = @('Epic Games')
Check 'restart store: never seen, only the Epic version here = Epic Games' ((Get-RestartStore) -eq 'Epic Games')
$script:Found = @('Xbox / Game Pass')
Check 'restart store: never seen, only the Xbox version here = Xbox' ((Get-RestartStore) -eq 'Xbox / Game Pass')
$script:Found = @()
Check 'restart store: never seen, nothing found = Steam' ((Get-RestartStore) -eq 'Steam')
${function:Get-DbdLauncher} = $realLauncher
# DBD's launcher without the game: just opened = a start under way (left alone), older = left open (closed first)
$young = [pscustomobject]@{ StartTime = (Get-Date).AddSeconds(-5) }
$old = [pscustomobject]@{ StartTime = (Get-Date).AddMinutes(-5) }
Check 'launcher opened 5 s ago = DBD is starting' (Test-LauncherStarting @($young))
Check 'launcher opened 5 min ago = left open' (-not (Test-LauncherStarting @($old)))
Check 'no launcher = not starting' (-not (Test-LauncherStarting @()))
Check 'start time unreadable = left open' (-not (Test-LauncherStarting @([pscustomobject]@{ Id = 1 })))
# Starting DBD again per store. Epic: the launcher link from its install manifest (stand-in manifests here).
$md = Join-Path $env:TEMP ('dbdrs-epic-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($md)
function New-Item2($n,$h) { [IO.File]::WriteAllText((Join-Path $md "$n.item"),($h | ConvertTo-Json)) }
New-Item2 'a-other' @{
    DisplayName = 'Other Game'
    AppName = 'Other'
    CatalogNamespace = 'ns0'
    CatalogItemId = 'id0'
    LaunchExecutable = 'Other/Other.exe'
    ProcessNames = @('Other.exe')
}
New-Item2 'b-dlc' @{
    DisplayName = 'DBD add-on'
    AppName = 'DbdDlc'
    MainGameAppName = 'Brill'
    CatalogNamespace = 'ns9'
    CatalogItemId = 'id9'
    LaunchExecutable = 'DeadByDaylight.exe'
}
New-Item2 'c-half' @{
    DisplayName = 'Dead by Daylight'
    AppName = 'Brill'
    bIsIncompleteInstall = $true
    CatalogNamespace = 'ns8'
    CatalogItemId = 'id8'
    LaunchExecutable = 'DeadByDaylight.exe'
}
New-Item2 'd-bad' @{
    DisplayName = 'Dead by Daylight'
    AppName = 'Brill?x=1&y'
    CatalogNamespace = 'ns7'
    CatalogItemId = 'id7'
    LaunchExecutable = 'DeadByDaylight.exe'
}
[IO.File]::WriteAllText((Join-Path $md 'e-broken.item'),'{ not json')
Check 'epic: no DBD installed = no link' ($null -eq (Get-EpicDbdLink $md))
New-Item2 'f-dbd' @{
    DisplayName = 'Dead by Daylight'
    AppName = 'Brill'
    CatalogNamespace = '611482b8586142cda48a0786eb8a127c'
    CatalogItemId = 'a3bd2fa0b6af4c9b8ea64e3a1b4bc1ed'
    LaunchExecutable = 'DeadByDaylight.exe'
    ProcessNames = @('DeadByDaylight-EGS-Shipping.exe')
}
$want = ('com.epicgames.launcher://apps/611482b8586142cda48a0786eb8a127c%3Aa3bd2fa0b6af4c9b8ea64e3a1b4bc1ed%3ABrill' +
    '?action=launch&silent=true')
$got = Get-EpicDbdLink $md
# an add-on, a half-installed game, odd ids and a broken file are skipped
Check 'epic: DBD''s link is namespace:item:app' ($got -ceq $want) $got
[IO.Directory]::Delete($md,$true)
Check 'epic: missing manifest folder = no link' ($null -eq (Get-EpicDbdLink (Join-Path $env:TEMP 'dbdrs-no-folder')))
# Xbox / Game Pass: a packaged app's Start-menu ID (checked with NGENUITY, a packaged app, when it's installed)
$ng = Get-XboxDbdApp '(?i)NGENUITY'
$ngInstalled = [bool](Get-AppxPackage -Name '33C30B79.NGENUITY' -ErrorAction SilentlyContinue)
Check 'xbox lookup: a packaged app is found by name' (-not $ngInstalled -or
    $ng -eq 'shell:AppsFolder\33C30B79.NGENUITY_922sw8z9z7n5w!App') $ng
$x = Get-XboxDbdApp
Check 'xbox lookup: never Steam''s own "Dead by Daylight" shortcut (steam://), only a packaged app' ($null -eq $x -or
    $x -like 'shell:AppsFolder\*_*!*') "$x"
$sl = Get-DbdLauncher 'Steam'
$steamOk = if (Test-Path 'Registry::HKEY_CLASSES_ROOT\steam') {
    $sl.Target -eq 'steam://rungameid/381210'
} else {
    $null -eq $sl
}
Check 'steam launcher = steam://rungameid/381210 (none without Steam''s link type: no "Pick an app")' $steamOk
$script:LauncherCache = @{}
$script:XboxCalls = 0
function Get-XboxDbdApp {
    $script:XboxCalls++
    'shell:AppsFolder\BHVR.DBD_abcdefghijklm!Game'
}
$a1 = Get-DbdLauncher 'Xbox / Game Pass'
$a2 = Get-DbdLauncher 'Xbox / Game Pass'
$a3 = Get-DbdLauncher 'Xbox / Game Pass' -Fresh
# the Start-menu list takes ~0.4 s
$ok = $script:XboxCalls -eq 2 -and $a2.Target -eq $a1.Target -and $a3.Target -eq $a1.Target
Check 'launcher lookup: reused between clicks, fresh on Apply' $ok "$script:XboxCalls lookups"
# Start-Dbd opens what the lookup found, as you (Open-AsUser records here instead of opening anything)
function Write-Log {}
function Open-AsUser {
    param($T)
    $script:Opened = $T
}
function Get-DbdLauncher {
    param($Store)
    if ($Store -eq 'Xbox / Game Pass') {
        @{ Target = 'shell:AppsFolder\BHVR.DBD_abcdefghijklm!Game'; How = 'the Xbox app''s Start menu entry' }
    } else {
        $null
    }
}
$script:Opened = $null
$ok = Start-Dbd 'Xbox / Game Pass'
Check 'start: opens the found entry through the desktop and watches for DBD' ($ok -and
    $script:Opened -eq 'shell:AppsFolder\BHVR.DBD_abcdefghijklm!Game' -and
    $script:LaunchWatch.How -like '*Xbox*') "$script:Opened"
$script:Opened = $null
Check 'start: entry not found = nothing opened' (-not (Start-Dbd 'Epic Games') -and -not $script:Opened)

# Temporary steering (Options > Steering lasts): removed once DBD has used it (a DBD started after it was written, or a
# measurement since) and closed
$script:Removed = 0
function Clear-Steering { $script:Removed++ }
function Set-VerifyUnsteered {}
$st = @{ Code = 'eu-west-2' }
$none = @{ Code = $null }
$script:SteerLife = 'temp'
$script:Busy = $false
$script:LaunchWatch = $null
$script:LastRoundEndUtc = $null
$script:DbdPid = 0
Reset-TempArm
[void](Update-TempSteering $st)
Check 'temporary: steered while DBD is closed = kept (Switch + Restart, or before starting DBD)' (
    $script:Removed -eq 0 -and -not $script:TempArmed)
$script:DbdPid = 4242
[void](Update-TempSteering $st)
Check 'temporary: a DBD started after it was written = armed, kept' ($script:Removed -eq 0 -and $script:TempArmed)
$script:DbdPid = 0
$script:Busy = $true
[void](Update-TempSteering $st)
Check 'temporary: DBD gone during an action (Switch + Restart closes it) = kept' ($script:Removed -eq 0)
$script:Busy = $false
$script:LaunchWatch = @{ Utc = [DateTime]::UtcNow }
[void](Update-TempSteering $st)
Check 'temporary: DBD being started again = kept' ($script:Removed -eq 0)
$script:LaunchWatch = $null
$r = Update-TempSteering $st
Check 'temporary: DBD closed = removed, once, and says which region' ($script:Removed -eq 1 -and
    -not $script:TempArmed -and $r -eq 'eu-west-2')
$r = Update-TempSteering $none
Check 'temporary: nothing left to remove = nothing done' ($script:Removed -eq 1 -and -not $r)
# written while DBD runs: only used once DBD measured with it, or a new DBD started
$script:DbdPid = 5151
$script:LastRoundEndUtc = [DbdEtw]::UtcNow.AddSeconds(-30)
Reset-TempArm
[void](Update-TempSteering $st)
Check 'temporary: written while DBD runs, not measured yet = not armed' (-not $script:TempArmed)
$script:DbdPid = 0
[void](Update-TempSteering $st)
Check 'temporary: ...and DBD closes before measuring = kept for the next DBD' ($script:Removed -eq 1)
$script:DbdPid = 5151
Reset-TempArm
$script:LastRoundEndUtc = [DbdEtw]::UtcNow.AddSeconds(1)
[void](Update-TempSteering $st)
Check 'temporary: DBD measured after it was written = armed' ($script:TempArmed)
$script:DbdPid = 5151
Reset-TempArm
$script:LastRoundEndUtc = $null
$script:DbdPid = 6262
[void](Update-TempSteering $st)
Check 'temporary: same steering, DBD restarted (new process) = armed' ($script:TempArmed)
$script:SteerLife = 'keep'
$script:TempArmed = $true
$script:DbdPid = 0
[void](Update-TempSteering $st)
Check 'persistent: never removed' ($script:Removed -eq 1)
function Get-CurrentSteering { $script:FakeSteer }
$script:SteerLife = 'temp'
$script:FakeSteer = $st
$script:FakeDbd = [pscustomobject]@{ ProcessName = 'DeadByDaylight-Win64-Shipping' }
Check 'closing the tool: temporary + DBD running = ask (stay in the tray / remove now)' ((Get-TempQuitPlan) -eq 'ask')
$script:FakeDbd = $null
Check 'closing the tool: temporary + DBD closed = remove' ((Get-TempQuitPlan) -eq 'remove')
$script:FakeSteer = $none
Check 'closing the tool: temporary, no steering = nothing' ((Get-TempQuitPlan) -eq 'none')
$script:SteerLife = 'keep'
$script:FakeSteer = $st
Check 'closing the tool: persistent = nothing' ((Get-TempQuitPlan) -eq 'none')

# Update check (Options > Check for updates): only a newer plain version number counts; no repository = no request
$ToolVersion = '1.0'
$script:UpdateCheck = $true
$script:UpdateNextUtc = [DateTime]::MinValue
function Show-UpdateNotice {}
function Test-UpdateAnswer([string]$Json) {
    $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
    $tcs.SetResult($Json)
    $script:UpdateDl = @{ Task = $tcs.Task; Client = (New-Object System.Net.WebClient); Started = [DbdEtw]::UtcNow }
    $script:UpdateAvail = $null
    Update-UpdateCheck
    $script:UpdateAvail
}
$ReleaseRepo = 'root/DBD-RegionSwitcher'
Check 'update: a newer release is noticed' ((Test-UpdateAnswer '{"tag_name":"v1.1","name":"x"}') -eq '1.1')
Check 'update: same version = nothing' ($null -eq (Test-UpdateAnswer '{"tag_name":"v1.0"}'))
Check 'update: older version = nothing' ($null -eq (Test-UpdateAnswer '{"tag_name":"v0.9"}'))
Check 'update: 1.10 is newer than 1.9 (numbers, not text)' ((Test-UpdateAnswer '{"tag_name":"1.10"}') -eq '1.10')
$odd = '{"tag_name":"v2.0-beta; rm -rf"}'
Check 'update: a tag that isn''t a plain version = nothing' ($null -eq (Test-UpdateAnswer $odd))
Check 'update: not JSON = nothing' ($null -eq (Test-UpdateAnswer '<html>rate limited</html>'))
$tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
$tcs.SetException((New-Object System.Net.WebException 'offline'))
$script:UpdateDl = @{ Task = $tcs.Task; Client = (New-Object System.Net.WebClient); Started = [DbdEtw]::UtcNow }
Update-UpdateCheck
Check 'update: a failed request = nothing' ($null -eq $script:UpdateDl -and -not $script:UpdateAvail)
$script:UpdateDl = $null
$ReleaseRepo = ''
$script:UpdateNextUtc = [DateTime]::MinValue
Update-UpdateCheck
Check 'update: no repository set = no request' ($null -eq $script:UpdateDl)

# The window's typography: dashes and arrows, but a line with a path in it as it is (a path can contain " - ").
$nl = "`r`n"
$Dash = [string][char]0x2013
$Arrow = [string][char]0x2192
$ft = @((Format-UiText ("none - DBD picks freely${nl}Session log: C:\Users\Bob - PC\x.log${nl}" +
    "share \\nas\a - b${nl}a -> b")) -split "`r`n")
Check 'typography: " - " shown as a dash' ($ft[0] -ceq "none $Dash DBD picks freely") $ft[0]
Check 'typography: a line with a path stays as it is' ($ft[1] -ceq 'Session log: C:\Users\Bob - PC\x.log' -and
    $ft[2] -ceq 'share \\nas\a - b') "$($ft[1]) / $($ft[2])"
Check 'typography: arrow, line breaks kept' ($ft[3] -ceq "a $Arrow b" -and $ft.Count -eq 4) $ft[3]
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
