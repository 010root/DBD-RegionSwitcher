# Byte-level tests of the hosts block surgery, using the exact functions from tool\DBD-RegionSwitcher.ps1.
# Works only on copies in verify\work - the real hosts file is read once (to copy it) and never written.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'tool\DBD-RegionSwitcher.ps1'
$work = Join-Path $PSScriptRoot 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$t = $null
$e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$t,[ref]$e)
$wantVars = 'HostsPath','MarkBegin','MarkBeginPrefix','MarkEnd','MarkSepFlag','Utf8NoBom','Utf8Strict','DefaultHosts',
    'Regions','SteerHostRx'
foreach ($s in $ast.EndBlock.Statements) {
    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $s.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $wantVars -contains $s.Left.VariablePath.UserPath) {
        . ([scriptblock]::Create($s.Extent.Text))
    }
}
$wantFns = 'Test-Admin','Read-HostsText','Write-HostsText','Find-OurBlock','Get-OurBlockBody','New-SteeringLines',
    'Set-OurBlockText','Restore-OurBlock','Get-CurrentSteering','Read-Steering'
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($wantFns -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}

# Every write in this test goes to copies in verify\work. The admin check guards the REAL hosts path only, so a
# test-only stand-in lets the suite run unelevated (an unelevated process can't write the real hosts file anyway).
function Test-Admin { $true }
$script:pass = 0
$script:fail = 0
function Check($name,[bool]$ok,$detail = '') {
    if ($ok) {
        $script:pass++
        "PASS  $name"
    } else {
        $script:fail++
        "FAIL  $name  $detail"
    }
}
function B64([byte[]]$b) { [Convert]::ToBase64String($b) }
function RoundTrip($label,[byte[]]$orig,$pick1,$pick2) {
    $p = Join-Path $work ("$label.hosts")
    [IO.File]::WriteAllBytes($p,$orig)
    # Set pick1
    Write-HostsText (Set-OurBlockText (Read-HostsText $p) (New-SteeringLines $pick1)) $p
    $a = [IO.File]::ReadAllBytes($p)
    $ta = $Utf8NoBom.GetString($a)
    $r = Find-OurBlock $ta
    Check "$label set: block found" ($null -ne $r)
    $outside = $ta.Substring(0,$r[0])+$ta.Substring($r[1])
    Check "$label set: text outside block == original" ((B64 $Utf8NoBom.GetBytes($outside)) -eq (B64 $orig))
    Check "$label set: pick $pick1 not blocked" (-not ($ta.Substring($r[0],
        $r[1]-$r[0]) -match [regex]::Escape(".$pick1.")))
    # Switch to pick2 (in-place replace)
    Write-HostsText (Set-OurBlockText (Read-HostsText $p) (New-SteeringLines $pick2)) $p
    $b = [IO.File]::ReadAllBytes($p)
    $tb = $Utf8NoBom.GetString($b)
    $r2 = Find-OurBlock $tb
    Check "$label switch: block starts at same offset" ($r2[0] -eq $r[0]) "($($r2[0]) vs $($r[0]))"
    $outside = $tb.Substring(0,$r2[0]) + $tb.Substring($r2[1])
    Check "$label switch: outside unchanged" ((B64 $Utf8NoBom.GetBytes($outside)) -eq (B64 $orig))
    $open2 = -not ($tb -match [regex]::Escape(" gamelift.$pick2.amazonaws.com"))
    $blocked1 = $tb -match [regex]::Escape("0.0.0.0 gamelift-ping.$pick1.api.aws")
    Check "$label switch: $pick2 open, $pick1 blocked" ($open2 -and $blocked1)
    # Remove -> exact original bytes
    Write-HostsText (Set-OurBlockText (Read-HostsText $p) $null) $p
    Check "$label remove: bytes identical to original" ((B64 ([IO.File]::ReadAllBytes($p))) -eq (B64 $orig))
}
$crlf = "`r`n"
$real = [IO.File]::ReadAllBytes("$env:windir\System32\drivers\etc\hosts")
$realTxt = $Utf8NoBom.GetString($real)
if (Find-OurBlock $realTxt) {
    $real = $Utf8NoBom.GetBytes((Set-OurBlockText $realTxt $null))
    "Real hosts has a steering block right now - testing on a copy with it removed"
}
"Real hosts copy: $($real.Length) bytes, ends with newline: $($real[-1] -eq 10)"
RoundTrip 'real-copy' $real 'us-west-1' 'ap-east-1'
RoundTrip 'default+crlf' ($Utf8NoBom.GetBytes(($DefaultHosts -replace "`r?`n",$crlf)+$crlf)) 'us-east-1' 'sa-east-1'
RoundTrip 'lf-only' ($Utf8NoBom.GetBytes("127.0.0.1 foo`n# comment`n10.0.0.5 bar.lan`n")) 'eu-west-1' 'us-east-2'
RoundTrip 'no-trailing-nl' ($Utf8NoBom.GetBytes("1.2.3.4 a.example${crlf}5.6.7.8 b.example")) 'us-west-2' 'us-east-1'
$bom = [byte[]](@(0xEF,0xBB,0xBF) + [byte[]]$Utf8NoBom.GetBytes("# hi${crlf}1.1.1.1 x.example${crlf}"))
RoundTrip 'with-bom' $bom 'ca-central-1' 'us-west-1'
$accents = $Utf8NoBom.GetBytes("# Configuraci$([char]0xF3)n de red${crlf}192.168.1.10 nas.local${crlf}")
RoundTrip 'utf8-accents' $accents 'us-east-1' 'us-west-2'
RoundTrip 'empty' ([byte[]]@()) 'us-east-1' 'eu-central-1'

# Block in the middle with user entries after it (e.g. user added lines after a previous switch)
$mid = "# top${crlf}1.1.1.1 keep.me${crlf}$MarkBegin${crlf}0.0.0.0 " +
    "gamelift.us-east-1.amazonaws.com${crlf}$MarkEnd${crlf}2.2.2.2 after.me${crlf}# tail"
$p = Join-Path $work 'middle.hosts'
[IO.File]::WriteAllBytes($p,$Utf8NoBom.GetBytes($mid))
Write-HostsText (Set-OurBlockText (Read-HostsText $p) (New-SteeringLines 'us-west-1')) $p
$tm = Read-HostsText $p
Check 'middle: head preserved' ($tm.StartsWith("# top${crlf}1.1.1.1 keep.me${crlf}$MarkBegin${crlf}"))
Check 'middle: tail preserved byte-for-byte' ($tm.EndsWith("$MarkEnd${crlf}2.2.2.2 after.me${crlf}# tail"))
Write-HostsText (Set-OurBlockText (Read-HostsText $p) $null) $p
Check 'middle: remove leaves exactly head+tail' ((Read-HostsText $p) -eq ("# top${crlf}1.1.1.1 keep.me${crlf}2.2.2.2 " +
    "after.me${crlf}# tail"))

# Hosts written by the ORIGINAL tool (same marker text, blank line before the block)
$old = "# x${crlf}${crlf}$MarkBegin${crlf}0.0.0.0 gamelift.us-west-1.amazonaws.com${crlf}$MarkEnd${crlf}"
$o2 = Set-OurBlockText $old (New-SteeringLines 'us-east-1')
Check 'old-tool block replaced in place' ($o2.StartsWith("# x${crlf}${crlf}$MarkBegin${crlf}# pick: us-east-1") -and
    ([regex]::Matches($o2,[regex]::Escape($MarkEnd)).Count -eq 1))

# Duplicate blocks collapse to one
$dup = "a${crlf}$MarkBegin${crlf}x${crlf}$MarkEnd${crlf}b${crlf}$MarkBegin${crlf}y${crlf}$MarkEnd${crlf}c${crlf}"
$d2 = Set-OurBlockText $dup $null
Check 'duplicate blocks all removed, rest kept' ($d2 -eq "a${crlf}b${crlf}c${crlf}")

# BEGIN inside a line (not at line start) is not ours
$inl = "1.1.1.1 x # $MarkBeginPrefix${crlf}"
Check 'mid-line marker ignored' ($null -eq (Find-OurBlock $inl))

# Unterminated block -> refuses to edit
$threw = $false
try { Set-OurBlockText "a${crlf}$MarkBegin${crlf}0.0.0.0 x${crlf}" $null | Out-Null } catch { $threw = $true }
Check 'unterminated block throws (no guessing)' $threw

# Non-UTF-8 (ANSI) hosts -> refuses to edit rather than altering bytes
$p = Join-Path $work 'ansi.hosts'
[IO.File]::WriteAllBytes($p,[byte[]](@(0x23,0x20,0xF3,0x0D,0x0A)))
$threw = $false
try { Read-HostsText $p | Out-Null } catch { $threw = $true }
Check 'ANSI hosts refused' $threw

# Block content
$lines = New-SteeringLines 'us-east-1'
$entries = @($lines | Where-Object { $_ -notmatch '^#' })
Check 'block has 14 regions x 2 hosts x (v4+v6) = 56 entries' ($entries.Count -eq 56) "($($entries.Count))"
Check 'HK uses ec2.ap-east-1 host' (($entries -contains '0.0.0.0 ec2.ap-east-1.amazonaws.com') -and
    ($entries -contains ':: ec2.ap-east-1.amazonaws.com'))
Check 'picked region absent' (-not ($entries -match 'us-east-1\.'))
Check 'every entry line is "0.0.0.0 host" or ":: host"' (@($entries |
    Where-Object { $_ -notmatch '^(0\.0\.0\.0|::) [a-z0-9.-]+$' }).Count -eq 0)
Check 'steering regex covers all 30 hosts' (@($Regions | ForEach-Object { $_.Hosts } |
    Where-Object { $_ -notmatch $SteerHostRx }).Count -eq 0)

# Cancel = Restore-OurBlock, on a COPY: point $HostsPath at a work file before anything runs
$HostsPath = Join-Path $work 'restore.hosts'
function Invoke-DnsFlush {}
function B64file { [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsPath)) }
# 1) no steering before -> restore removes our block, bytes identical
[IO.File]::WriteAllBytes($HostsPath,$real)
$before = Read-HostsText
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'eu-west-1'))
Restore-OurBlock $before
Check 'cancel with no prior steering: hosts bytes identical to before' ((B64file) -eq (B64 $real))
# 2) steering A before, switched to B, cancel -> exactly A again
[IO.File]::WriteAllBytes($HostsPath,$real)
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'us-west-1'))
$beforeA = [IO.File]::ReadAllBytes($HostsPath)
$before = Read-HostsText
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'sa-east-1'))
Restore-OurBlock $before
Check 'cancel with prior steering A: bytes identical to before (A restored)' ((B64file) -eq (B64 $beforeA))
# 3) a line added OUTSIDE the block while waiting survives the cancel
[IO.File]::WriteAllBytes($HostsPath,$beforeA)
$before = Read-HostsText
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'eu-central-1'))
Write-HostsText ((Read-HostsText) + "9.9.9.9 added.while.waiting`r`n")
Restore-OurBlock $before
$after = Read-HostsText
Check 'cancel keeps a line added outside the block meanwhile' ($after -eq ($Utf8NoBom.GetString($beforeA) +
    "9.9.9.9 added.while.waiting`r`n"))
# 3b) the block removed meanwhile, from a hosts file whose last line has no line break: the restored block is still
# found (its BEGIN line didn't join that last line) and removing it gives exactly that hosts back
$noEol = "127.0.0.1 a.example`r`n10.0.0.1 last.line.without.break"
[IO.File]::WriteAllBytes($HostsPath,$Utf8NoBom.GetBytes($noEol))
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'ap-south-1'))
$before = Read-HostsText
Write-HostsText $noEol
Restore-OurBlock $before
$after = Read-HostsText
$rr = Find-OurBlock $after
$back = $null -ne $rr -and $after -match '(?m)^# pick: ap-south-1 '
Check 'cancel after the block was removed meanwhile (last line without a line break): block back and found' $back
Check '... and removing it gives that hosts back byte for byte' ((Set-OurBlockText $after $null) -ceq $noEol)
Check '... and the last line is untouched' ($after.StartsWith($noEol+"`r`n",[StringComparison]::Ordinal))
# 4) a read-only hosts file stays read-only after a write
[IO.File]::WriteAllBytes($HostsPath,$real)
(Get-Item $HostsPath).IsReadOnly = $true
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'eu-west-2'))
$roAfter = (Get-Item $HostsPath).IsReadOnly
(Get-Item $HostsPath).IsReadOnly = $false
Check 'read-only hosts: written, and read-only again afterwards' ($roAfter -and
    (Read-HostsText) -match '(?m)^# pick: eu-west-2 ') "read-only=$roAfter"
Check 'real hosts path was never used by these tests' ($HostsPath -like "$work*")
$HostsPath = "$env:windir\System32\drivers\etc\hosts"

# Show one generated file for eyeballing
$p = Join-Path $work 'sample-us-west-1.hosts'
[IO.File]::WriteAllBytes($p,$real)
Write-HostsText (Set-OurBlockText (Read-HostsText $p) (New-SteeringLines 'us-west-1')) $p
# The every-3-s readout reuses its last result only while hosts is unchanged (Get-CurrentSteering -Cached).
$HostsPath = Join-Path $work 'cache.hosts'
$script:SteerCache = $null
[IO.File]::WriteAllText($HostsPath,(Set-OurBlockText "# test`r`n" (New-SteeringLines 'eu-west-2')),$Utf8NoBom)
$c1 = Get-CurrentSteering -Cached
Check 'steering cache: first read sees the block' ($c1.Code -eq 'eu-west-2' -and $c1.Exact)
$same = [object]::ReferenceEquals((Get-CurrentSteering -Cached),$c1)
Check 'steering cache: unchanged file = same result object, not re-read' $same
Write-HostsText (Set-OurBlockText (Read-HostsText) (New-SteeringLines 'ap-south-1')) $HostsPath
Check 'steering cache: a write is seen at once' ((Get-CurrentSteering -Cached).Code -eq 'ap-south-1')
[IO.File]::WriteAllText($HostsPath,"# test`r`n",$Utf8NoBom)
[IO.File]::SetLastWriteTimeUtc($HostsPath,[DateTime]::UtcNow.AddMinutes(-5))
Check 'steering cache: another program''s edit is seen (new time)' ($null -eq (Get-CurrentSteering -Cached).Code)
Check 'steering cache: without -Cached always read' ($null -eq (Get-CurrentSteering).Code)
[IO.File]::Delete($HostsPath)
Check 'steering cache: hosts missing = no steering' ($null -eq (Get-CurrentSteering -Cached).Code)

"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
