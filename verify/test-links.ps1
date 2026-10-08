# The tool runs as admin but its folder (%LOCALAPPDATA%\DBD-RegionSwitcher) belongs to the user: a junction in its
# place must not redirect the tool's writes. Runs a copy of the tool (no admin needed, no ETW, own single-instance
# names) whose app folder is a junction to an empty folder, lets it log, save its settings and close, then checks
# that nothing arrived in the junction's target. Also unit-checks Test-NoLink. Never touches hosts or DBD.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$w = Join-Path $PSScriptRoot 'work'
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
# Inside your profile: the tool only takes DBDRS_APPDIR there, and the repository may be anywhere (D:\ on GitHub's
# machine).
$appRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DBD-RegionSwitcher-tests'
[void][IO.Directory]::CreateDirectory($appRoot)
$target = Join-Path $appRoot 'link-target'
$link = Join-Path $appRoot 'link-appdir'
$plain = Join-Path $w 'link-plain'
# a junction is removed as a link, not followed
foreach ($d in $link,$target,$plain) { if ([IO.Directory]::Exists($d)) { [IO.Directory]::Delete($d,$true) } }
[void][IO.Directory]::CreateDirectory($target)
[void][IO.Directory]::CreateDirectory($plain)
& cmd.exe /c mklink /J "$link" "$target" | Out-Null
$isJunction = [bool]([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)
Check 'junction made (no admin needed - which is the point)' $isJunction ''

$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$s = [IO.File]::ReadAllText($src)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$null,[ref]$null)
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($f.Name -eq 'Test-NoLink') { . ([scriptblock]::Create($f.Extent.Text)) }
}
Check 'Test-NoLink: junction refused' (-not (Test-NoLink $link)) ''
Check 'Test-NoLink: plain folder and missing file allowed' (Test-NoLink $plain,(Join-Path $plain 'none.txt')) ''

$rep = [ordered]@{
    'if (-not (Test-Admin)) {' = 'if ($false) {'
    "'Global\DBD-RegionSwitcher'" = "'Global\DBD-RegionSwitcher-linktest'"
    "'Global\DBD-RegionSwitcher-Show'" = "'Global\DBD-RegionSwitcher-linktest-Show'"
    'public static string SessionName = "DBD-RegionSwitcher-ETW";' = 'public static string SessionName = ' +
        '"DBD-RegionSwitcher-linktest";'
    '$script:EtwOk = [DbdEtw]::Start()' = '$script:EtwOk = $false'
    '[void](Show-Msg $why ''' = '[void](Write-StartupError $why '''   # see Write-StartupError
}
foreach ($k in $rep.Keys) {
    if (-not $s.Contains($k)) { throw "test-links: '$k' not found in the script" }
    $s = $s.Replace($k,$rep[$k])
}
$res = Join-Path $w 'link-result.txt'
$se = Join-Path $w 'link-startup-error.txt'
foreach ($f in $res,$se) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
# The copy writes what it saw, then closes. Its window opens on the test screen, not the main one.
$screen = if ($env:DBDRS_TEST_SCREEN) { $env:DBDRS_TEST_SCREEN } else { 'DISPLAY2' }
$hook = "`$LinkScreen = '$screen'`n`$LinkResult = '$res'`n" + @'
$tsc = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like "*$LinkScreen" })[0]
if ($tsc) {
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new($tsc.WorkingArea.X + 30,$tsc.WorkingArea.Y + 10)
}
$linkTimer = New-Object System.Windows.Forms.Timer
$linkTimer.Interval = 2500
$linkTimer.Add_Tick({
    $linkTimer.Stop()
    $script:CloseTo = 'quit'
    Write-Log 'link test line'
    Save-State
    $logged = @($script:ConBuf | Where-Object { $_ -match 'link test line' }).Count -gt 0
    $lines = @("appdir=$AppDir","refused=$($script:LinkRefused)","console has the line=$logged")
    [IO.File]::WriteAllLines($LinkResult,$lines)
    $form.Close()
})
$form.Add_Shown({ $linkTimer.Start() })
'@
$runLine = [regex]::Match($s,'(?m)^\[System\.Windows\.Forms\.Application\]::Run\(\$form\).*$')
if (-not $runLine.Success) { throw 'test-links: the Application.Run line was not found in the tool script' }
$s = $s.Insert($runLine.Index,$hook + "`n")
# a start-up error goes to a file (not into the junction folder), not to a dialog that could open on the main screen
$s = ("function Write-StartupError { param(`$Text,`$Buttons,`$Icon) " +
    "[IO.File]::WriteAllText('$se',[string]`$Text) }`n" + $s)
$copy = Join-Path $w 'link-run.ps1'
[IO.File]::WriteAllText($copy,$s,[Text.Encoding]::ASCII)
$env:DBDRS_APPDIR = $link
$psi = [Diagnostics.ProcessStartInfo]::new('powershell.exe',"-NoProfile -ExecutionPolicy Bypass -File `"$copy`"")
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true   # no console window: it would open on the main screen
$p = [Diagnostics.Process]::Start($psi)
if (-not $p.WaitForExit(60000)) {
    Stop-Process -Id $p.Id -Force
    Check 'tool copy closed by itself' $false 'timed out'
}
$r = if ([IO.File]::Exists($res)) { Get-Content $res } else { @() }
if ([IO.File]::Exists($se)) { Check 'the tool copy started' $false ([IO.File]::ReadAllText($se)) }
$rText = $r -join ' '
Check 'the tool ran with the junction as its folder' ($rText -match [regex]::Escape("appdir=$link")) ($r -join ' | ')
Check 'it noticed and kept its log in memory only' ($rText -match 'refused=True' -and
    $rText -match 'console has the line=True') ''
$got = @(Get-ChildItem $target -Recurse -Force -ErrorAction SilentlyContinue)
Check 'nothing written through the junction (no logs, no state.txt)' (-not $got.Count) (($got |
    ForEach-Object { $_.Name }) -join ', ')
foreach ($d in $link,$target,$plain) { if ([IO.Directory]::Exists($d)) { [IO.Directory]::Delete($d,$true) } }
foreach ($x in $copy,$res) { if ([IO.File]::Exists($x)) { [IO.File]::Delete($x) } }
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
