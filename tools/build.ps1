# Builds tool\DBD-RegionSwitcher.ps1 from src\: the parts in src\main in name order, with the C# files (src\native) and
# the icon picture (src\icon-art.png, as base64) put back where a part names them. That single script is what the .exe
# embeds and what the tests read. -Exe also builds DBD-RegionSwitcher.exe (tools\build-exe.ps1).
param([switch]$Exe,[switch]$NoHeader,[string]$Out)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
$out = if ($Out) { $Out } else { Join-Path $root 'tool\DBD-RegionSwitcher.ps1' }

function Read-Lf([string]$Path) {
    $t = [IO.File]::ReadAllText($Path)
    if ($t.Contains("`r")) { throw "$Path has CR line endings - the sources are LF only" }
    if (-not $t.EndsWith("`n")) { $t += "`n" }
    return $t
}
$include = [Text.RegularExpressions.MatchEvaluator]{
    param($m)
    Read-Lf (Join-Path $src $m.Groups[1].Value)
}
$base64 = [Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $b = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $src $m.Groups[1].Value)))
    $rows = for ($i = 0; $i -lt $b.Length; $i += 120) { $b.Substring($i,[Math]::Min(120,$b.Length-$i)) }
    ($rows -join "`n") + "`n"
}

$sb = New-Object Text.StringBuilder
if (-not $NoHeader) { [void]$sb.Append("# Built by tools\build.ps1 from src\ - edit the files there, not this one.`n") }
$parts = @(Get-ChildItem (Join-Path $src 'main') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $parts.Count) { throw "no parts in $src\main - nothing built (the script was left as it is)" }
foreach ($f in $parts) {
    $t = Read-Lf $f.FullName
    $t = [regex]::Replace($t,'(?m)^//@include (native/[A-Za-z0-9]+\.cs)\n',$include)
    $t = [regex]::Replace($t,'(?m)^@include-base64 ([A-Za-z0-9-]+\.png)\n',$base64)
    [void]$sb.Append($t)
}
$all = $sb.ToString()
if ($all -match '[^\x00-\x7F]') { throw 'non-ASCII character in the sources (the script is kept ASCII)' }
$pe = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($all,[ref]$null,[ref]$pe)
if ($pe.Count) {
    throw ("built script doesn't parse: line {0}: {1}" -f $pe[0].Extent.StartLineNumber,$pe[0].Message)
}
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $out))
[IO.File]::WriteAllText($out,$all,(New-Object Text.UTF8Encoding($false)))
"built $out ($($all.Length) chars)"
if ($Exe) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-exe.ps1')
    if ($LASTEXITCODE) { throw 'build-exe failed' }
}
