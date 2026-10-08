# Static checks of tool\DBD-RegionSwitcher.ps1 (no admin, nothing runs):
#  - it parses; pure ASCII, no control characters, LF only
#  - every called command is defined, and every defined function is called
#  - every -f template gets enough values
#  - no Windows MessageBox (always light), no blue color, no personal path or e-mail address
#  - no "# comment" inside a one-line { } block (it would hide the rest of the line)
#  - every C# part the .exe build needs is there, and the built script is up to date with src\
# -Src checks another file instead, to test the checks themselves.
param([string]$Src = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tool\DBD-RegionSwitcher.ps1'))
$ErrorActionPreference = 'Stop'
$src = $Src
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
$e = $null
$tok = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$tok,[ref]$e)
$bytes = [IO.File]::ReadAllBytes($src)
$text = [IO.File]::ReadAllText($src)
Check 'parses' ($e.Count -eq 0) "$($e.Count) error(s), first: $($e[0].Message) line $($e[0].Extent.StartLineNumber)"
Check 'pure ASCII' (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)) ''
# tabs are allowed (Windows' own default hosts text has two); any other control character is an editing accident
$ctl = @($bytes | Where-Object { $_ -lt 32 -and $_ -ne 10 -and $_ -ne 9 })
$first = if ($ctl.Count) { "first: byte $($ctl[0])" } else { '' }
Check 'no control characters but line breaks and tabs' ($ctl.Count -eq 0) $first
Check 'LF line ends only' (-not ($bytes -contains 13)) ''

$defs = @{}
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    $defs[$f.Name] = 1
}
$calls = @($ast.FindAll({$args[0] -is [System.Management.Automation.Language.CommandAst]},$true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
$undef = @($calls | Where-Object {
    -not $defs.ContainsKey($_) -and -not (Get-Command $_ -ErrorAction SilentlyContinue)
})
Check 'every called command is defined' (-not $undef.Count) ($undef -join ', ')
$unused = @($defs.Keys | Where-Object { $calls -notcontains $_ })
Check 'no function defined but never called' (-not $unused.Count) ($unused -join ', ')

# A call passes no more plain (positional) values than the function has parameters: a parameter removed from a function
# while a caller still passes it is silently ignored.
$fn = @{}
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    $ps = if ($f.Body.ParamBlock) {
        @($f.Body.ParamBlock.Parameters)
    } elseif ($f.Parameters) {
        @($f.Parameters)
    } else {
        @()
    }
    $usesArgs = [bool]$f.Body.Find({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $args[0].VariablePath.UserPath -eq 'args' },$true)
    $sw = @($ps | Where-Object { $_.StaticType -eq [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath })
    $fn[$f.Name] = @{
        Count = @($ps | Where-Object { $_.StaticType -ne [switch] }).Count
        Args = $usesArgs
        Switches = $sw
    }
}
$over = @()
foreach ($c in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.CommandAst]},$true)) {
    $cn = $c.GetCommandName()
    $d = if ($cn) { $fn[$cn] } else { $null }
    if (-not $d -or $d.Args) { continue }
    $el = @($c.CommandElements | Select-Object -Skip 1)
    $pos = 0
    for ($i = 0;$i -lt $el.Count;$i++) {
        if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
            $named = $el[$i].ParameterName
            if (-not $el[$i].Argument -and $d.Switches -notcontains $named) { $i++ }   # its value is the next element
            continue
        }
        $pos++
    }
    if ($pos -gt $d.Count) { $over += "$($c.GetCommandName()) line $($c.Extent.StartLineNumber)" }
}
Check 'no call passes more values than its function takes' (-not $over.Count) ($over -join ', ')

# -f: highest {n} in the template must be below the number of values given
$bad = @()
foreach ($b in $ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] -and $args[0].Operator -eq 'Format'
    },$true)) {
    $l = $b.Left
    while ($l -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $l = $l.Pipeline.PipelineElements[0].Expression
    }
    if ($l -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $l -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        continue
    }
    $idx = @([regex]::Matches(($l.Value -replace '\{\{|\}\}',''),'\{(\d+)') | ForEach-Object {
        [int]$_.Groups[1].Value
    })
    if (-not $idx.Count) { continue }
    $n = if ($b.Right -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $b.Right.Elements.Count
    } else {
        1
    }
    if (($idx | Measure-Object -Maximum).Maximum -ge $n) { $bad += "line $($b.Extent.StartLineNumber)" }
}
$nf = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] -and $args[0].Operator -eq 'Format'
    },$true)).Count
Check "all $nf -f templates have enough values" (-not $bad.Count) ($bad -join ', ')

$msgBox = '\[System\.Windows\.Forms\.MessageBox\]|\[Windows\.Forms\.MessageBox\]|MessageBox\]::Show'
Check 'no Windows MessageBox (always light)' ($text -notmatch $msgBox) ''
$blue = @()
$nc = 0
foreach ($m in [regex]::Matches($text,'FromArgb\(\s*(?:(\d+)\s*,\s*)?(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)')) {
    $nc++
    $r = [int]$m.Groups[2].Value
    $g = [int]$m.Groups[3].Value
    $bl = [int]$m.Groups[4].Value
    if ($bl -gt $r+35 -and $bl -gt $g+20) {
        $blue += "$($m.Value) at line $(($text.Substring(0,$m.Index) -split "`n").Count)"
    }
}
foreach ($m in [regex]::Matches($text,'Color\]::(\w*Blue\w*|Navy|Highlight)|SystemColors')) { $blue += $m.Value }
Check "no blue among $nc colors" (-not $blue.Count) ($blue -join '; ')
$me = [Environment]::UserName
Check 'no personal path or e-mail' ($text -notmatch [regex]::Escape("Users\$me") -and
    $text -notmatch '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|net|org|de|io)\b') ''
# a "#" comment inside a one-line { ... } block hides the rest of the line, closing brace included
$sw = @()
$i = 0
foreach ($line in ($text -split "`n")) {
    $i++
    $code = ($line -replace "'[^']*'",'' -replace '"[^"]*"','')
    $h = $code.IndexOf(' #')
    if ($h -gt 0 -and $code.Substring(0,$h).Split('{').Count -gt $code.Substring(0,$h).Split('}').Count -and
        $code.Substring($h).Contains('}')) {
        $sw += "line $i"
    }
}
Check 'no "# comment" swallowing code inside a one-line block' (-not $sw.Count) ($sw -join ', ')
$parts = @($ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and
        $n.Extent.Text -match '-TypeDefinition'
    },$true)).Count
Check "C# parts for the .exe build: $parts (build-exe wants at least 6)" ($parts -ge 6) ''
# The script is built from src\: an edit made in src\ but not built yet (or made to the built file) shows here.
$root = Split-Path -Parent $PSScriptRoot
if ([IO.Path]::GetFullPath($src) -eq [IO.Path]::GetFullPath((Join-Path $root 'tool\DBD-RegionSwitcher.ps1'))) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dbdrs-buildcheck-' +
        [Guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
    try {
        $build = Join-Path $root 'tools\build.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build -Out $tmp | Out-Null
        $same = ([IO.File]::Exists($tmp) -and [IO.File]::ReadAllText($tmp) -ceq [IO.File]::ReadAllText($src))
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
    Check 'the built script is up to date with src\ (tools\build.ps1)' $same ''
}
"`r`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
