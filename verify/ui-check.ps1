# UI check without admin rights: runs a copy of the tool (own test folder, own single-instance names, no ETW) driven by
# verify\hooks\ui.ps1, which
#  - counts list repaints, and films the list from another thread while the mouse moves over it (a row must never
#    show blank for a frame), and the status rows and the activity box while they change
#  - narrows the window to its minimum: status rows must end in "..." and keep the whole text for Copy
#  - checks the layout, the Switch text while a cut waits for DBD's measurement, Switch + Restart with the Epic version
#    and temporary steering (stand-ins only)
# Never touches the real hosts file (a copy in verify\work) and never touches DBD. Results: verify\work\ui-check.txt
# -Light: the copy runs as if Windows were set to light mode (for that process only, Windows' own per-app switch; the
# system setting isn't touched); pictures and results are named ui-light-*.
# -FilmOnly: only the repaint checks and the films. The window opens on $Screen.
param(
    [switch]$FilmOnly,
    [switch]$Light,
    [string]$Screen = $(if ($env:DBDRS_TEST_SCREEN) { $env:DBDRS_TEST_SCREEN } else { 'DISPLAY2' })
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$w = Join-Path $PSScriptRoot 'work'
$prefix = if ($Light) { 'ui-light-' } else { 'ui-' }
$out = Join-Path $w "${prefix}check.txt"
if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }
# inside your profile: the tool only takes DBDRS_APPDIR there, wherever the repository is
$appd = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DBD-RegionSwitcher-tests\ui'
New-Item -ItemType Directory -Force -Path $appd | Out-Null
# Fresh settings every run: the last run closes at the minimum size with a lower region picked, and a window restored
# like that shows the list scrolled - rows 5-9 (filmed) then aren't on screen.
$st = Join-Path $appd 'state.txt'
if ([IO.File]::Exists($st)) { [IO.File]::Delete($st) }
$aws = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DBD-RegionSwitcher\ip-ranges.json'
if ((Test-Path $aws) -and -not (Test-Path (Join-Path $appd 'ip-ranges.json'))) { Copy-Item $aws $appd }

$s = [IO.File]::ReadAllText((Join-Path $root 'tool\DBD-RegionSwitcher.ps1'))
$rep = [ordered]@{
    # runs without admin (no ETW)
    'if (-not (Test-Admin)) {' = 'if ($false) {'
    # never meets a real copy
    "'Global\DBD-RegionSwitcher'" = "'Global\DBD-RegionSwitcher-uitest'"
    "'Global\DBD-RegionSwitcher-Show'" = "'Global\DBD-RegionSwitcher-uitest-Show'"
    # closing stops this name, never the real one
    'SessionName = "DBD-RegionSwitcher-ETW";' = 'SessionName = "DBD-RegionSwitcher-uitest";'
    # no ETW session (it also starts without admin, then asks about UDP events)
    '$script:EtwOk = [DbdEtw]::Start()' = '$script:EtwOk = $false'
    # a start-up error goes to a file, not to a dialog that could open on the main screen
    '[void](Show-Msg $why ''' = '[void](Write-StartupError $why '''
}
foreach ($k in $rep.Keys) {
    if (-not $s.Contains($k)) { throw "ui-check: '$k' not found in the script" }
    $s = $s.Replace($k,$rep[$k])
}
$settings = @(
    "`$UiDir = '$w'"
    "`$UiPrefix = '$prefix'"
    "`$UiScreen = '$Screen'"
    "`$UiFilmOnly = `$$([bool]$FilmOnly)"
) -join "`n"
$hook = $settings + "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hooks\ui.ps1'))
$runLine = [regex]::Match($s,'(?m)^\[System\.Windows\.Forms\.Application\]::Run\(\$form\).*$')
if (-not $runLine.Success) { throw 'ui-check: the Application.Run line was not found in the tool script' }
$s = $s.Remove($runLine.Index,$runLine.Length).Insert($runLine.Index,$hook)

$prelude = @'
function Write-StartupError {
    param($Text,$Buttons,$Icon)
    [IO.File]::WriteAllText((Join-Path $env:DBDRS_APPDIR 'startup-error.txt'),[string]$Text)
}
# Per-monitor DPI aware like the .exe (its manifest): at 125 % / 150 % the copy lays itself out the way the .exe does,
# and screen grabs line up with the window (powershell.exe itself would be stretched by Windows).
Add-Type -TypeDefinition @"
public static class UiDpi {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr c);
}
"@
[void][UiDpi]::SetProcessDpiAwarenessContext([IntPtr]-4)
'@
if ($Light) {
    # Light mode for this process only: uxtheme's SetPreferredAppMode (ordinal 135, 3 = force light) and
    # FlushMenuThemes (136).
    $prelude += "`n" + @'
Add-Type -TypeDefinition @"
public static class AppMode {
    [System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#135")]
    public static extern int Set(int m);
    [System.Runtime.InteropServices.DllImport("uxtheme.dll", EntryPoint = "#136")]
    public static extern void Flush();
}
"@
[void][AppMode]::Set(3)
[AppMode]::Flush()
'@
}
$f = Join-Path $w 'ui-check-run.ps1'
[IO.File]::WriteAllText($f,$prelude + "`n" + $s,[Text.Encoding]::ASCII)

$env:DBDRS_APPDIR = $appd
Add-Type -AssemblyName System.Windows.Forms
$mouse = [System.Windows.Forms.Cursor]::Position   # the films move the mouse: put back afterwards
$psi = [Diagnostics.ProcessStartInfo]::new('powershell.exe',"-NoProfile -ExecutionPolicy Bypass -File `"$f`"")
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true   # no console window: it would open on the main screen
$p = [Diagnostics.Process]::Start($psi)
if (-not $p.WaitForExit(120000)) {
    Stop-Process -Id $p.Id -Force
    'ui-check: timed out'
}
[System.Windows.Forms.Cursor]::Position = $mouse
$se = Join-Path $appd 'startup-error.txt'
if ([IO.File]::Exists($se)) {
    'ui-check: the copy could not start: ' + [IO.File]::ReadAllText($se)
    [IO.File]::Delete($se)
}
if (Test-Path $out) { Get-Content $out } else { 'ui-check: no results' }
