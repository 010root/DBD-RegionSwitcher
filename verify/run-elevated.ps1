# One elevated verification pass (needs admin): all test suites + a smoke run of the .exe build.
# Never writes the real hosts file and never touches DBD. Results: verify\work\elevated-results.txt
# The test window opens on DBDRS_TEST_SCREEN (default DISPLAY2) and gets its keys posted straight to it, so whatever
# runs on your main screen keeps its focus and keys. -Toasts also shows and photographs the two tray notifications
# (Windows shows them on the main screen); without it their code runs without showing them.
param(
    [switch]$Toasts,
    [string]$Screen = $(if ($env:DBDRS_TEST_SCREEN) { $env:DBDRS_TEST_SCREEN } else { 'DISPLAY2' })
)
$ErrorActionPreference = 'Continue'
$d = Split-Path -Parent $PSScriptRoot
$w = Join-Path $PSScriptRoot 'work'
[void][IO.Directory]::CreateDirectory($w)
$res = Join-Path $w 'elevated-results.txt'
$tool = Join-Path $d 'tool\DBD-RegionSwitcher.ps1'
$hostsFile = "$env:windir\System32\drivers\etc\hosts"
$log = New-Object System.Collections.Generic.List[string]
function Add([string]$s) { $log.Add($s) }

$pe = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tool,[ref]$null,[ref]$pe)
if ($pe.Count) {
    [IO.File]::WriteAllText($res,"tool script has $($pe.Count) parse error(s) - nothing run")
    throw 'tool script does not parse'
}
$hosts0 = (Get-FileHash $hostsFile).Hash
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
Add ("elevated: " + $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

$suites = 'static-check','test-hosts','test-gate','test-links','test-tcpkill','test-etw','test-clock','test-udpcheck'
foreach ($t in $suites) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$t.ps1") 2>&1
    $sum = ($out | Select-String 'passed,' | Select-Object -Last 1).Line
    if ($sum) {
        Add "--- $t : $sum"
    } else {
        $err = $out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Select-Object -First 1
        Add ("--- $t : CRASHED (no result line) - " + ("$err" -replace '\s+',' '))
    }
    $out | Where-Object { "$_" -match '^FAIL' } | ForEach-Object { Add "    $_" }
}

# Smoke run of the .exe build: the same launcher with a copy of the script whose window is driven by
# verify\hooks\smoke.ps1, which writes what the window showed.
# The windows started below use a test folder, never your logs and settings. It's inside your profile because the
# tool only takes DBDRS_APPDIR there, wherever the repository is.
$appRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DBD-RegionSwitcher-tests'
$env:DBDRS_APPDIR = Join-Path $appRoot 'elevated'
$smokeOut = Join-Path $w 'exe-smoke.txt'
$se = Join-Path $w 'exe-startup-error.txt'
foreach ($f in $smokeOut,$se) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
$s = [IO.File]::ReadAllText($tool)
# a start-up error goes to a file, not to a dialog that could open on the main screen
$s = ("function Write-StartupError { param(`$Text,`$Buttons,`$Icon) [IO.File]::WriteAllText('$se',[string]`$Text) }`n" +
    $s.Replace('[void](Show-Msg $why ''','[void](Write-StartupError $why '''))
$settings = @(
    "`$SmokeDir = '$w'"
    "`$SmokeScreen = '$Screen'"
    "`$SmokeToasts = `$$([bool]$Toasts)"
    "`$SmokeResult = '$smokeOut'"
) -join "`n"
$hook = $settings + "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hooks\smoke.ps1'))
$runLine = [regex]::Match($s,'(?m)^\[System\.Windows\.Forms\.Application\]::Run\(\$form\).*$')
if (-not $runLine.Success) { throw 'the Application.Run line was not found in the tool script' }
$s = $s.Remove($runLine.Index,$runLine.Length).Insert($runLine.Index,$hook)
[IO.File]::WriteAllText((Join-Path $w 'smoke-for-exe.ps1'),$s,[Text.Encoding]::ASCII)
$buildArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $d 'tools\build-exe.ps1'),
    '-Script',(Join-Path $w 'smoke-for-exe.ps1'),'-Out',(Join-Path $w 'smoke.exe'))
& powershell.exe @buildArgs | Out-Null
$a = Start-Process (Join-Path $w 'smoke.exe') -PassThru
Start-Sleep -Seconds 3

# single instance: the real .exe must exit quickly while the smoke one is open
$sw = [Diagnostics.Stopwatch]::StartNew()
$b = Start-Process (Join-Path $d 'DBD-RegionSwitcher.exe') -PassThru
$b.WaitForExit(15000) | Out-Null
Add ("--- second instance (real .exe) exited after {0:N1} s while the first was open: {1}" -f
    $sw.Elapsed.TotalSeconds,$b.HasExited)

$a.WaitForExit(60000) | Out-Null
Add ("--- exe smoke exit code: $($a.ExitCode)")
if (Test-Path $smokeOut) {
    Get-Content $smokeOut | ForEach-Object { Add "    $_" }
} else {
    Add '    (no smoke output - the window did not run)'
}
if ([IO.File]::Exists($se)) { Add ('    the smoke .exe could not start: ' + [IO.File]::ReadAllText($se)) }

# The smoke run's own session log: Esc and closing the window must each have cancelled a waiting Switch.
$tl = Get-ChildItem (Join-Path $env:DBDRS_APPDIR 'logs') -Filter 'session-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$tlog = if ($tl) { [IO.File]::ReadAllText($tl.FullName) } else { '' }
$nCancel = ([regex]::Matches($tlog,'cancelled: hosts restored')).Count
$nClose = ([regex]::Matches($tlog,'Window closed while an action was running')).Count
Add ("--- Esc then close: cancels logged={0} (want 2), of them by closing={1} (want 1)" -f $nCancel,$nClose)
$copy = Join-Path $w 'hosts-copy-smoke'
$copyOk = (Test-Path $copy) -and ((Get-FileHash $copy).Hash -eq (Get-FileHash $hostsFile).Hash)
$cancelledOnClose = ($nClose -gt 0) -and ($nCancel -gt 0)
Add (("--- close while a Switch waits: steering written to the copy={0}; log says cancelled on close={1}; copy " +
    "restored byte-for-byte={2}; process exited={3}") -f ($tlog -match 'APPLY Switch'),$cancelledOnClose,
    $copyOk,$a.HasExited)
Add ("--- ETW sessions left: " + [bool](logman query -ets | Select-String 'DBD-RegionSwitcher|selftest|DBDRS'))
Add ("--- real hosts unchanged: " + ($hosts0 -eq (Get-FileHash $hostsFile).Hash))
[IO.File]::WriteAllLines($res,$log)
