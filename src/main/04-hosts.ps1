# ---------------- hosts: raw-text block surgery ----------------
function Read-HostsText {
    param([string]$Path = $HostsPath)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Strict UTF-8: a valid file decodes and re-encodes to the same bytes (a BOM survives as U+FEFF).
    try { return $Utf8Strict.GetString($bytes) } catch {
        throw ("The hosts file is not valid UTF-8 (e.g. ANSI accented characters), so it can't be edited without " +
            "changing other bytes. Use Repair Hosts, or re-save it as UTF-8.")
    }
}
function Write-HostsText {
    param([string]$Text,[string]$Path = $HostsPath)
    if ($Path -eq $HostsPath -and -not (Test-Admin)) {
        throw 'Not elevated. Start the tool again and accept the Windows admin prompt (UAC).'
    }
    $want = [Convert]::ToBase64String($Utf8NoBom.GetBytes($Text))
    $err = ''
    $denied = $false   # by exception type: the message text is in Windows' language
    $wasRO = $false
    for ($try = 1;$try -le 12;$try++) {
        try {
            # A read-only hosts file (for protection) is unlocked for the write, then locked again.
            $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($fi -and $fi.IsReadOnly) {
                $fi.IsReadOnly = $false
                $wasRO = $true
            }
            [System.IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) -eq $want) {
                if ($wasRO) { try { (Get-Item -LiteralPath $Path).IsReadOnly = $true } catch {} }
                return
            }
            $err = 'read-back did not match'
            $denied = $false
        } catch {
            $err = $_.Exception.Message
            $denied = ($_.Exception.GetBaseException() -is [System.UnauthorizedAccessException])
        }
        # 12 x 250 ms = 3 s when an antivirus blocks it: the window stays responsive (the tests have no window)
        for ($w = 0;$w -lt 5;$w++) {
            Start-Sleep -Milliseconds 50
            if ($form) { [System.Windows.Forms.Application]::DoEvents() }
        }
    }
    # Access is denied even with admin rights while an antivirus protects hosts: pausing its protection, or marking
    # this program trusted in its intrusion-prevention settings, lets the write through (a plain scan exclusion may
    # not). No antivirus is named in the message: it could be any of them.
    if ($wasRO) { try { (Get-Item -LiteralPath $Path).IsReadOnly = $true } catch {} }
    $me = try { (Get-Process -Id $PID).Path } catch { 'this program' }
    $state = if ($denied) { 'Hosts is unchanged.' } else { 'Something changed it back right after the write.' }
    throw ("Hosts write was refused 12 times ($err). $state${nl}Your antivirus most likely protects the hosts file." +
        "${nl}Quick fix: pause its protection, press Apply again, then turn it back on." +
        "${nl}Permanent fix: mark this program as trusted, or allow it to change the hosts file (often under " +
        "intrusion prevention; a scan exclusion alone may not be enough): $me")
}
function Find-OurBlock {
    # Returns @(start,end) of our block in $Text (end exclusive, includes the END line's line break), or $null.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $i = 0
    while ($true) {
        $b = $Text.IndexOf($MarkBeginPrefix,$i,[StringComparison]::Ordinal)
        if ($b -lt 0) { return $null }
        if ($b -eq 0 -or $Text[$b-1] -eq [char]10) { break }
        $i = $b+1
    }
    $e = $Text.IndexOf($MarkEnd,$b,[StringComparison]::Ordinal)
    if ($e -lt 0) { throw "Hosts has a DBD-RegionSwitcher BEGIN line without its END line. Use Repair Hosts." }
    $end = $e+$MarkEnd.Length
    if ($end -lt $Text.Length -and $Text[$end] -eq [char]13) { $end++ }
    if ($end -lt $Text.Length -and $Text[$end] -eq [char]10) { $end++ }
    $start = $b
    if ($Text.Substring($b,$end-$b).Contains($MarkSepFlag) -and $start -ge 2 -and
        $Text.Substring($start-2,2) -eq "`r`n") {
        $start -= 2
    }
    return @($start,$end)
}
function Get-OurBlockBody {
    # The lines between our BEGIN and END lines (not the line-break note), as Set-OurBlockText takes them.
    param([string]$Text)
    $r = Find-OurBlock $Text
    if (-not $r) { return $null }
    $lines = $Text.Substring($r[0],$r[1]-$r[0]) -split "`r?`n"
    return ,@($lines | Where-Object {
        $_ -and -not $_.StartsWith($MarkBeginPrefix,[StringComparison]::Ordinal) -and
            $_ -ne $MarkEnd -and $_ -ne $MarkSepFlag
    })
}
function New-SteeringLines {
    param([string]$PickCode)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("# pick: $PickCode - every other region's latency endpoints are blackholed (IPv4 0.0.0.0 and IPv6 ::)")
    foreach ($r in $Regions) {
        if ($r.Code -eq $PickCode) {continue}
        foreach ($h in $r.Hosts) {
            $l.Add("0.0.0.0 $h")
            $l.Add(":: $h")
        }
    }
    return ,$l.ToArray()
}
function Set-OurBlockText {
    # Replace our block in place (or append it), or remove it when $BodyLines is $null.
    # Everything outside the block is kept byte-for-byte; no line is split or rejoined.
    param([string]$Text,[string[]]$BodyLines)
    if ($null -eq $Text) { $Text = '' }
    $r = Find-OurBlock $Text
    if ($r) {
        $before = $Text.Substring(0,$r[0])
        $after = $Text.Substring($r[1])
    } else {
        $before = $Text
        $after = ''
    }
    while ($true) {
        $r2 = Find-OurBlock $after
        if (-not $r2) { break }
        $after = $after.Substring(0,$r2[0])+$after.Substring($r2[1])
    }
    if ($null -eq $BodyLines) { return $before+$after }
    $needSep = ($before.Length -gt 0 -and -not $before.EndsWith("`n"))
    $sb = [System.Text.StringBuilder]::new()
    if ($needSep) { [void]$sb.Append("`r`n") }
    [void]$sb.Append("$MarkBegin`r`n")
    if ($needSep) { [void]$sb.Append("$MarkSepFlag`r`n") }
    foreach ($x in $BodyLines) { [void]$sb.Append("$x`r`n") }
    [void]$sb.Append("$MarkEnd`r`n")
    return $before+$sb.ToString()+$after
}
function Restore-OurBlock {
    # Put our block back to exactly how it was in $Before (or remove it if $Before had none). Only the block's range is
    # replaced; everything else in the current hosts stays byte-for-byte.
    param([string]$Before)
    $cur = Read-HostsText
    if ($null -eq $cur) { $cur = '' }
    $rb = if ($Before) { Find-OurBlock $Before } else { $null }
    $rc = Find-OurBlock $cur
    if ($rb -and $rc) {
        $new = $cur.Substring(0,$rc[0])+$Before.Substring($rb[0],$rb[1]-$rb[0])+$cur.Substring($rc[1])
    } elseif ($rb) {
        # The block was removed meanwhile, so it's written again the usual way. Copied as it was, it could land after a
        # last line without a line break: its BEGIN line would join that line, and the block couldn't be found again.
        $new = Set-OurBlockText $cur (Get-OurBlockBody $Before)
    } else {
        $new = Set-OurBlockText $cur $null
    }
    if ($new -cne $cur) { Write-HostsText $new }
    Invoke-DnsFlush
}
function Invoke-DnsFlush {
    if (-not [TcpKill]::FlushDns()) { & (Join-Path $Sys32 'ipconfig.exe') /flushdns | Out-Null }
}
function Set-Steering {
    param([string]$PickCode)
    Reset-TempArm   # temporary steering: kept until DBD has used this one
    $raw = Read-HostsText
    if ($null -eq $raw) { $raw = ($DefaultHosts -replace "`r?`n","`r`n")+"`r`n" }
    Write-HostsText (Set-OurBlockText $raw (New-SteeringLines $PickCode))
    Invoke-DnsFlush
}
function Clear-Steering {
    $raw = Read-HostsText
    if ($null -ne $raw) {
        $new = Set-OurBlockText $raw $null
        if ($new -cne $raw) { Write-HostsText $new }
    }
    Invoke-DnsFlush
}
function Repair-Hosts {
    Write-HostsText (($DefaultHosts -replace "`r?`n","`r`n")+"`r`n")
    Invoke-DnsFlush
}

