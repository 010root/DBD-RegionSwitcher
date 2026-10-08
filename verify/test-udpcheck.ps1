# Unit test of the UDP-monitoring check: which other ETW sessions receive Kernel-Network events (Get-NetListeners via
# EtwSessions), how they're labelled, and the relaunch helpers (Wait-Until, Test-SteamSaysDbdRunning). Needs admin
# (creates short-lived test sessions). Never touches DBD, Steam or any session it didn't create.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$text = [IO.File]::ReadAllText($src)
Add-Type -AssemblyName System.Windows.Forms
foreach ($t in 'DbdEtw','EtwSessions') {
    $m = [regex]::Match($text,"(?s)PSTypeName\]'$t'\)\.Type\)\s*\{\s*Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "$t source not found" }
    Add-Type -TypeDefinition $m.Groups[1].Value
}
$t = $null
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
foreach ($s in $ast.EndBlock.Statements) {
    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $s.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        @('KernelNetGuid','WindowsSessionRx','SteamDbdKey') -contains $s.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($s.Extent.Text))
    }
}
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if (@('Get-NetListeners','Get-NetListenersText','Get-EtwImpactText','Wait-Until','Test-SteamSaysDbdRunning',
        'Get-SteamDbdValue','Repair-UdpMonitor') -contains $f.Name) {
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

$names = 'DBDRS-Test-Listener','EventLog-DBDRS-Test'
foreach ($n in $names) { logman stop $n -ets 2>$null | Out-Null }
$L = Get-NetListeners -Fresh
Check 'no test session yet: not listed' (-not (@($L) |
    Where-Object { $names -contains $_.Name })) (Get-NetListenersText $L)

logman create trace 'DBDRS-Test-Listener' -rt -p 'Microsoft-Windows-Kernel-Network' 0x10 -ets | Out-Null
logman create trace 'EventLog-DBDRS-Test' -rt -p 'Microsoft-Windows-Kernel-Network' 0x10 -ets | Out-Null
logman create trace 'DBDRS-Test-Other' -rt -p 'Microsoft-Windows-DNS-Client' -ets | Out-Null
try {
    $L = @(Get-NetListeners -Fresh)
    $a = $L | Where-Object { $_.Name -eq 'DBDRS-Test-Listener' }
    $w = $L | Where-Object { $_.Name -eq 'EventLog-DBDRS-Test' }
    Check 'a session on the network provider is found' ([bool]$a) (Get-NetListenersText $L)
    Check '  ...with its real-time flag' ($a -and $a.RealTime -and -not $a.Windows) "(keywords $($a.Keywords))"
    Check '  ...keywords read back (0x10 = UDP)' ($a -and $a.Keywords -eq '0x10')
    Check "Windows-style session name is marked Windows (never offered for stopping)" ($w -and $w.Windows)
    Check 'a session on another provider is not listed' (-not ($L | Where-Object { $_.Name -eq 'DBDRS-Test-Other' }))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void](Get-NetListeners -Fresh)
    Check 'query is fast (no process started)' ($sw.ElapsedMilliseconds -lt 500) "$($sw.ElapsedMilliseconds) ms"
    # this tool's own session is never listed
    [DbdEtw]::SessionName = 'DBD-RegionSwitcher-ETW-udpcheck'
    [DbdEtw]::OwnPid = $PID
    if ([DbdEtw]::Start()) {
        Start-Sleep -Milliseconds 300
        $L = @(Get-NetListeners -Fresh)
        [DbdEtw]::Stop()
        Check "this tool's own session is not listed" (-not ($L | Where-Object {
            $_.Name -eq 'DBD-RegionSwitcher-ETW-udpcheck'
        }))
    } else {
        Check 'own test session started' $false ([DbdEtw]::LastError)
    }
} finally { foreach ($n in $names+'DBDRS-Test-Other') { logman stop $n -ets 2>$null | Out-Null } }
# Nudge: a throwaway session enables the provider briefly and is gone afterwards; StopByName replaces logman.
$rc = [EtwSessions]::Nudge('DBDRS-Test-Nudge',$KernelNetGuid,0x10,200)
Check 'nudge: enabled the provider and removed its session' ($rc -eq 0 -and
    -not [bool](logman query -ets | Select-String -SimpleMatch 'DBDRS-Test-Nudge')) "(result $rc)"
logman create trace 'DBDRS-Test-Stop' -rt -ets | Out-Null
$r1 = [EtwSessions]::StopByName('DBDRS-Test-Stop')
$r2 = [EtwSessions]::StopByName('DBDRS-Test-Stop')
Check 'StopByName: 0 = stopped, 4201 = already gone' ($r1 -eq 0 -and $r2 -eq 4201) "($r1, $r2)"
Check 'test sessions removed' (-not [bool](logman query -ets | Select-String 'DBDRS-Test|udpcheck'))

# With no other sessions the list must say "none", not end blank ("...events: ")
Check 'empty list says none (not blank)' ((Get-NetListenersText @()) -eq 'none' -and
    (Get-NetListenersText $null) -eq 'none' -and
    (Get-NetListenersText @(Get-NetListeners -Fresh | Where-Object { $_.Name -eq 'no-such-session' })) -eq 'none')
# A check must not start while another one is waiting on its question
function Test-EtwHealth { throw 'second check ran' }
$script:UdpCheckRunning = $true
$ok = $true
try { Repair-UdpMonitor -Manual } catch { $ok = $false }
Check 'a check never starts while another is running' $ok
$script:UdpCheckRunning = $false
$i1 = Get-EtwImpactText @{ Udp = $true; Dns = $true }
$i2 = Get-EtwImpactText @{ Udp = $false; Dns = $true }
Check 'impact text: OK case' ($i1 -match 'both arrive') $i1
Check 'impact text: UDP blocked names UDP and its effect' ($i2 -match 'UDP events' -and
    $i2 -match 'lobby, match or end game chat' -and $i2 -notmatch 'DNS events') ($i2 -replace "`r`n",' ')

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Wait-Until { $false } 400
Check 'Wait-Until: gives up after its limit and says so' (-not $r -and $sw.ElapsedMilliseconds -ge 380 -and
    $sw.ElapsedMilliseconds -lt 1500) "$($sw.ElapsedMilliseconds) ms"
$sw.Restart()
$r = Wait-Until { $true } 5000
Check 'Wait-Until: returns at once when done' ($r -and $sw.ElapsedMilliseconds -lt 200) "$($sw.ElapsedMilliseconds) ms"
$dbdUp = [bool](Get-Process -Name 'DeadByDaylight-Win64-Shipping' -ErrorAction SilentlyContinue)
$flag = Test-SteamSaysDbdRunning
Check "Steam running flag readable and consistent with DBD's process (DBD running: $dbdUp)" ($flag -is [bool] -and
    ($dbdUp -or -not $flag)) "flag=$flag"
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
