# Builds DBD-RegionSwitcher.exe: tools\exe\Launcher.cs with the script embedded as a resource, compiled by Windows'
# own .NET 4 compiler.
param(
    [string]$Script = "$PSScriptRoot\..\tool\DBD-RegionSwitcher.ps1",
    [string]$Out = "$PSScriptRoot\..\DBD-RegionSwitcher.exe"
)
$ErrorActionPreference = 'Stop'
$csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$gac = "$env:windir\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation"
$sma = (Get-ChildItem $gac -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1).FullName
$Script = (Resolve-Path $Script).Path
# Refuse to build a script that does not parse.
$pe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script,[ref]$null,[ref]$pe)
if ($pe.Count) {
    throw ("{0} parse error(s) in {1}: line {2}: {3}" -f $pe.Count,$Script,$pe[0].Extent.StartLineNumber,$pe[0].Message)
}
# The script's C# parts (every "Add-Type -TypeDefinition @'...'@") are compiled into the .exe too. The script only
# compiles a type that isn't loaded yet, so the .exe skips the compiler at every start (~0.45 s, and no compiler
# process or temporary DLL); a direct run of the .ps1 still compiles them. Same source text, taken from the script.
$gen = Join-Path ([IO.Path]::GetTempPath()) ('dbdrs-build-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $gen | Out-Null
try {
    $cs = @()
    $addTypes = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type'
    },$true)
    foreach ($c in $addTypes) {
        $el = $c.CommandElements
        for ($i = 1; $i -lt $el.Count - 1; $i++) {
            if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                $el[$i].ParameterName -eq 'TypeDefinition') {
                $f = Join-Path $gen ("part{0}.cs" -f $cs.Count)
                [IO.File]::WriteAllText($f,$el[$i + 1].Value)
                $cs += $f
            }
        }
    }
    if ($cs.Count -lt 6) { throw "expected the script's 6 C# parts, found $($cs.Count)" }
    # The .exe icon and the window icon are drawn from the script's own icon code, so all of them always match.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\make-icon.ps1" -Script $Script | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'make-icon failed' }
    $exe = "$PSScriptRoot\exe"
    $cscArgs = @(
        '/nologo','/target:winexe','/optimize+','/platform:anycpu',"/out:$Out",
        "/win32manifest:$exe\app.manifest","/win32icon:$exe\app.ico",
        "/reference:$sma",'/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll',
        "/resource:$Script,DBD-RegionSwitcher.ps1","/resource:$exe\window.ico,window.ico",
        "$exe\Launcher.cs"
    ) + $cs
    & $csc @cscArgs
    if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
} finally {
    Remove-Item -LiteralPath $gen -Recurse -Force -ErrorAction SilentlyContinue
}
Get-Item $Out | Select-Object FullName,Length,LastWriteTime
