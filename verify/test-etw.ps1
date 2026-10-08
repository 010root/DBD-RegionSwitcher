# Live test of the tool's ETW monitor, measurement-round summary and AWS ip-range mapper (needs admin).
# Uses its own ETW session name; never touches hosts or DBD.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$work = Join-Path $PSScriptRoot 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$text = [IO.File]::ReadAllText($src)
$m = [regex]::Match($text,"(?s)PSTypeName\]'DbdEtw'\)\.Type\)\s*\{\s*Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'could not find DbdEtw source' }
Add-Type -TypeDefinition $m.Groups[1].Value
# The script's own round-summary functions
$t = $null
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if (@('Get-RegionOfHost','Get-ResultAddresses','Update-MeasurementRound','Set-PingMode','Save-State','Write-Log',
        'Hide-ProfilePath','Test-NoLink') -contains $f.Name) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LogPath = Join-Path $work 'test-session.log'
Remove-Item $script:LogPath -ErrorAction SilentlyContinue
$StatePath = Join-Path $work 'test-state.txt'
Remove-Item $StatePath -ErrorAction SilentlyContinue
$script:PingMode = 'unknown'
$script:PingModeUtc = [DateTime]::MinValue
$script:RoundDone = [DateTime]::MinValue
$script:LastRound = $null
$Regions = @([pscustomobject]@{Code = 'rg-http';Hosts = @('example.com')},[pscustomobject]@{
    Code = 'rg-dead'
    Hosts = @('gamelift-ping.example.org')
})

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

# --- result-string parser ---
$a = Get-ResultAddresses '0.0.0.0;::;'
Check 'parse 0.0.0.0 + ::' (($a -join ',') -eq '0.0.0.0,::') ($a -join ',')
$a = Get-ResultAddresses '::ffff:0.0.0.0;'
Check 'parse mapped blackhole' (($a -join ',') -eq '0.0.0.0') ($a -join ',')
$a = Get-ResultAddresses '::ffff:52.94.1.2;'
Check 'parse IPv4-mapped' (($a -join ',') -eq '52.94.1.2') ($a -join ',')
$a = Get-ResultAddresses 'type:  5 d1.cloudfront.net;13.32.5.6;13.32.5.7;'
Check 'parse CNAME chain' (($a -join ',') -eq '13.32.5.6,13.32.5.7') ($a -join ',')
$a = Get-ResultAddresses 'type: 5;'
Check 'bare numbers ignored' ($a.Count -eq 0)

[DbdEtw]::SessionName = 'DBD-RegionSwitcher-ETW-selftest'
[DbdEtw]::OwnPid = $PID
[DbdEtw]::SteerRx = [regex]::new('^(example\.com|gamelift-ping\.example\.org)$','IgnoreCase')
$SteerHostRx = '^(example\.com|gamelift-ping\.example\.org)$'
$RegionHostRx = '^gamelift-ping\.[a-z0-9-]+\.example\.org$'   # a "new region" = gamelift-ping.<x>.example.org
$ok = [DbdEtw]::Start()
Check 'ETW session started' $ok ([DbdEtw]::LastError)
Check 'session visible in logman' ($null -ne (logman query -ets | Select-String 'DBD-RegionSwitcher-ETW-selftest'))
Start-Sleep -Seconds 2

try { [void][Net.Dns]::GetHostAddresses('example.com') } catch {}
Start-Sleep -Seconds 3
Check 'own-process lookup ignored' ([DbdEtw]::LastSteerUtc -eq [DateTime]::MinValue)
# Another program resolving the same names must not count as DBD
$other = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command',
    'try { [void][Net.Dns]::GetHostAddresses(''example.com'') } catch {}' -PassThru -WindowStyle Hidden
[DbdEtw]::Pid = 999999
$other.WaitForExit()
Start-Sleep -Seconds 3
Check 'other-process lookup ignored' ([DbdEtw]::LastSteerUtc -eq [DateTime]::MinValue)

# Child process plays "DBD": getaddrinfo lookups + a UDP stream to TEST-NET-1 (never routed)
$child = @'
Start-Sleep -Seconds 4
foreach ($n in 'gamelift-ping.example.org','gamelift-ping.zz-new-1.example.org','example.com') {
    try { [void][Net.Dns]::GetHostAddresses($n) } catch {}
}
$u = New-Object Net.Sockets.UdpClient
$buf = New-Object byte[] 40
for ($i = 0; $i -lt 300; $i++) {
    [void]$u.Send($buf,$buf.Length,'192.0.2.10',7777)
    Start-Sleep -Milliseconds 10
}
$u.Close()
Start-Sleep -Seconds 2
'@
$p = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command',$child -PassThru -WindowStyle Hidden
[DbdEtw]::Pid = $p.Id
$t0 = [DateTime]::UtcNow
$p.WaitForExit()
Start-Sleep -Seconds 3

$last = [DbdEtw]::LastSteerUtc
Check 'steered lookup timestamp recorded' ($last -gt $t0) ("last=" + $last.ToString('HH:mm:ss.fff') + " UTC")
Check 'HTTP-endpoint lookup timestamp recorded separately' ([DbdEtw]::LastSteerHttpUtc -gt $t0)
$rs = [DbdEtw]::RoundStartUtc(8)
$rsText = "start=" + $rs.ToString('HH:mm:ss.fff')
Check 'round start found (first lookup of the burst)' ($rs -gt $t0 -and $rs -le $last) $rsText
$res = [DbdEtw]::SteerResults($t0,[DateTime]::UtcNow)
Check 'query-completed results captured' ($res.Count -ge 2) ("n=$($res.Count)")
$res | Select-Object -First 4 | ForEach-Object { "   raw 3008: $_" }
$names = [DbdEtw]::DbdNames()
$childLookups = @($names | Where-Object { $_ -like 'example.com|*' }).Count
Check 'lookups attributed to the child pid' ($childLookups -eq 1) ($names -join ', ')
$pk = 0
$n = 0
$top = [DbdEtw]::ActiveUdp(30,1,30,[ref]$pk,[ref]$n)
Check 'UDP stream detected as the busiest endpoint' ($top -eq '192.0.2.10:7777') ("top=$top packets=$pk")
$ms = [DbdEtw]::ActiveUdp(60,30,10,[ref]$pk,[ref]$n)
Check 'match server: the stream, still active in the last 10 s' ($ms -eq '192.0.2.10:7777' -and
    $n -gt 0) "server=$ms recent=$n"
$ms = [DbdEtw]::ActiveUdp(60,301,10,[ref]$pk,[ref]$n)
Check 'match server: fewer packets a minute than asked for = none' ($null -eq $ms) "server=$ms"
$uc = [DbdEtw]::UdpCounts($t0,[DateTime]::UtcNow)
Check 'UDP counts split sent/received' (@($uc |
    Where-Object { $_ -eq '192.0.2.10:7777|300|0' }).Count -eq 1) ($uc -join ', ')

# Round summary with the script's own function (waits for the 6 s quiet period)
Start-Sleep -Seconds 4
$done = Update-MeasurementRound
Check 'measurement round summarised' $done
$open = @($script:LastRound.Open) -join ','
$blocked = @($script:LastRound.Blocked) -join ','
$unknown = @($script:LastRound.Unknown) -join ','
$ok = $open -eq 'rg-http' -and $blocked -eq 'rg-dead'
Check 'resolving region reachable, non-resolving region unreachable' $ok ($script:LastRound.Text)
$ok = $unknown -eq 'gamelift-ping.zz-new-1.example.org' -and $script:LastRound.Text -match 'not in the steering block'
Check 'a region endpoint not in the block is named (a region BHVR added)' $ok $unknown
Check 'mode detected as HTTP (a non-beacon name was looked up)' ($script:PingMode -eq 'HTTP')
Check 'mode persisted to state file' ((Get-Content $StatePath -Raw) -match 'mode=HTTP')
Check 'round written to session log' ((Get-Content $script:LogPath -Raw) -match 'DBD region ping round')
Check 'same round not summarised twice' (-not (Update-MeasurementRound))

[DbdEtw]::Stop()
Start-Sleep -Milliseconds 500
Check 'session stopped and removed' ($null -eq (logman query -ets | Select-String 'DBD-RegionSwitcher-ETW-selftest'))

# AwsIpMap with a synthetic ip-ranges.json (field order shuffled on purpose)
$json = @'
{"syncToken":"1","prefixes":[
 {"ip_prefix":"3.0.0.0/8","region":"us-east-1","service":"AMAZON","network_border_group":"us-east-1"},
 {"region":"us-west-1","ip_prefix":"3.101.0.0/16","service":"EC2","network_border_group":"us-west-1"},
 {"ip_prefix":"3.101.52.0/22","region":"us-west-1","service":"GAMELIFT","network_border_group":"us-west-1"},
 {"ip_prefix":"54.209.0.0/16","region":"us-east-1","service":"EC2","network_border_group":"us-east-1"},
 {"ip_prefix":"52.94.0.0/22","region":"us-east-1","service":"ROUTE53","network_border_group":"us-east-1"}
],"ipv6_prefixes":[{"ipv6_prefix":"2600:1f10::/36","region":"us-east-1","service":"EC2"}]}
'@
$n = [AwsIpMap]::Load($json)
Check 'ip map loads EC2/GAMELIFT/AMAZON v4 prefixes only' ($n -eq 4) "($n)"
Check 'longest prefix wins (GAMELIFT /22)' ([AwsIpMap]::Lookup('3.101.53.7') -eq 'us-west-1|GAMELIFT')
Check 'EC2 /16' ([AwsIpMap]::Lookup('3.101.200.1') -eq 'us-west-1|EC2')
Check 'falls back to AMAZON /8' ([AwsIpMap]::Lookup('3.5.5.5') -eq 'us-east-1|AMAZON')
Check 'unknown ip -> null' ($null -eq [AwsIpMap]::Lookup('8.8.8.8'))
# Background load (the tool's start-up path): a cut-off list never replaces a good one; a missing file changes nothing
$af = Join-Path $env:TEMP 'dbdrs-test-ranges.json'
[IO.File]::WriteAllText($af,'{"prefixes":[{"ip_prefix":"9.0.0.0/8","region":"x-1","service":"EC2"}]}')
$tk = [AwsIpMap]::LoadFileAsync($af,1001)
$null = $tk.Wait(5000)
Check 'LoadFileAsync: too-small list not swapped in' ($tk.Result -eq 1 -and
    [AwsIpMap]::Lookup('3.101.53.7') -eq 'us-west-1|GAMELIFT')
$tk = [AwsIpMap]::LoadFileAsync(($af+'.missing'),1)
try { $null = $tk.Wait(5000) } catch {}
Check 'LoadFileAsync: missing file faults, list unchanged' ($tk.IsFaulted -and
    [AwsIpMap]::Lookup('3.101.53.7') -eq 'us-west-1|GAMELIFT')
$tk = [AwsIpMap]::LoadFileAsync($af,1)
$null = $tk.Wait(5000)
Check 'LoadFileAsync: a full-enough list is swapped in' ([AwsIpMap]::Lookup('9.1.2.3') -eq 'x-1|EC2' -and
    $null -eq [AwsIpMap]::Lookup('3.101.53.7'))
[IO.File]::Delete($af)
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
