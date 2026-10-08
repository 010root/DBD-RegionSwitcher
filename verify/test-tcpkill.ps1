# Tests TcpKill.KillPidRemotes (the hold), KillPidAll (the cut) and FlushDns. Needs admin. All connections stay on
# this PC: loopback (127.x, which the cut must leave alone) and this PC's own LAN address (stands in for "another
# machine", since the cut only skips 127.x).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $PSScriptRoot 'work'
$text = [IO.File]::ReadAllText((Join-Path $root 'tool\DBD-RegionSwitcher.ps1'))
$m = [regex]::Match($text,"(?s)PSTypeName\]'TcpKill'\)\.Type\)\s*\{\s*Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'TcpKill source not found' }
Add-Type -TypeDefinition $m.Groups[1].Value
function ConvertTo-UintIp {
    param([string]$ip)
    $b = [Net.IPAddress]::Parse($ip).GetAddressBytes()
    [BitConverter]::ToUInt32($b,0)
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
$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } |
    Select-Object -First 1).IPAddress
if (-not $lan) { throw 'no LAN IPv4 address on this PC' }

# A child process opens two connections (to $A and $B), waits, then reports which ones still work.
function Start-Pair([string]$A,[string]$B,[string]$Out) {
    $la = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($A),0)
    $la.Start()
    $lb = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($B),0)
    $lb.Start()
    if ([IO.File]::Exists($Out)) { [IO.File]::Delete($Out) }
    # The child connects to both listeners, waits, then tells whether each connection still works.
    $child = "`$A = '$A'`n`$PortA = $($la.LocalEndpoint.Port)`n`$B = '$B'`n`$PortB = $($lb.LocalEndpoint.Port)`n" +
        "`$Out = '$Out'`n" + @'
$a = New-Object Net.Sockets.TcpClient($A,$PortA)
$b = New-Object Net.Sockets.TcpClient($B,$PortB)
Start-Sleep -Seconds 4
function Get-State($c) {
    try {
        $c.Client.Send([byte[]](1)) | Out-Null
        Start-Sleep -Milliseconds 300
        $c.Client.Send([byte[]](1)) | Out-Null
        'alive'
    } catch { 'reset' }
}
"a=$(Get-State $a) b=$(Get-State $b)" | Out-File -Encoding ascii $Out
'@
    $ps = $Out -replace '\.txt$','.ps1'
    [IO.File]::WriteAllText($ps,$child,[Text.Encoding]::ASCII)
    $childArgs = '-NoProfile','-ExecutionPolicy','Bypass','-File',$ps
    $p = Start-Process powershell.exe -ArgumentList $childArgs -PassThru -WindowStyle Hidden
    $sa = $la.AcceptTcpClient()
    $sb = $lb.AcceptTcpClient()
    Start-Sleep -Milliseconds 500
    return @{ P = $p; PortA = $la.LocalEndpoint.Port; PortB = $lb.LocalEndpoint.Port; Close = {
        $sa.Close()
        $sb.Close()
        $la.Stop()
        $lb.Stop()
        }.GetNewClosure() }
}

# Hold: only the targeted remote goes; the other is listed as left alone.
$out = Join-Path $work 'tcpkill-child.txt'
$t = Start-Pair '127.0.0.1' $lan $out
$others = ''
$n = [TcpKill]::KillPidRemotes([uint32]$t.P.Id,[uint32[]]@(ConvertTo-UintIp '127.0.0.1'),[ref]$others)
Check 'hold: killed exactly the targeted connection' ($n -eq 1) "(kills=$n)"
Check 'hold: the other connection is reported as left alone' ($others -eq "${lan}:$($t.PortB)") "(others='$others')"
$n2 = [TcpKill]::KillPidRemotes([uint32]$t.P.Id,[uint32[]]@(ConvertTo-UintIp '127.0.0.1'),[ref]$others)
Check 'hold: second sweep finds nothing left to kill' ($n2 -eq 0)
$n3 = [TcpKill]::KillPidRemotes([uint32]999999,[uint32[]]@(ConvertTo-UintIp $lan),[ref]$others)
Check 'hold: other pids never touched' ($n3 -eq 0)
$t.P.WaitForExit(15000) | Out-Null
$r = Get-Content $out -Raw
Check 'hold: child saw targeted socket reset, other alive' ($r -match 'a=reset b=alive') "($($r.Trim()))"
& $t.Close

# Cut: every connection to another address goes; 127.x (inside this PC) stays and isn't reported.
$out2 = Join-Path $work 'tcpkill-child2.txt'
$t2 = Start-Pair '127.0.0.1' $lan $out2
$killed = ''
$n4 = [TcpKill]::KillPidAll([uint32]$t2.P.Id,[ref]$killed)
Check 'cut: the non-loopback connection is cut' ($n4 -eq 1) "(kills=$n4)"
Check 'cut: reports what it cut' ($killed -eq "${lan}:$($t2.PortB)") "('$killed')"
$n5 = [TcpKill]::KillPidAll([uint32]$t2.P.Id,[ref]$killed)
Check 'cut: nothing left on the next sweep (loopback untouched)' ($n5 -eq 0)
$n6 = [TcpKill]::KillPidAll([uint32]999999,[ref]$killed)
Check 'cut: other pids never touched' ($n6 -eq 0)
$t2.P.WaitForExit(15000) | Out-Null
$r2 = Get-Content $out2 -Raw
Check 'cut: child saw loopback alive, the other reset' ($r2 -match 'a=alive b=reset') "($($r2.Trim()))"
& $t2.Close

$sw = [Diagnostics.Stopwatch]::StartNew()
$f = [TcpKill]::FlushDns()
Check 'FlushDns (DnsFlushResolverCache) works' $f "($($sw.ElapsedMilliseconds) ms)"
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
