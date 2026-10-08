# Writes tools\exe\app.ico (the .exe icon) and tools\exe\window.ico (the window icon the .exe carries) from the icon
# drawing in tool\DBD-RegionSwitcher.ps1 (New-AppIconBitmap), so the .exe, the window and the tray always show the
# same icon. Also a preview: verify\work\icon-preview.png.
param([string]$Script = "$PSScriptRoot\..\tool\DBD-RegionSwitcher.ps1",[string]$Out = "$PSScriptRoot\exe\app.ico")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script).Path,[ref]$null,[ref]$null)
# the icon picture ($IconArt, a here-string the drawing reads) and the two functions
foreach ($s in $ast.EndBlock.Statements) {
    if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and $s.Left.Extent.Text -eq '$IconArt') {
        . ([scriptblock]::Create($s.Extent.Text))
    }
}
foreach ($f in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if (@('New-AppIconBitmap','New-AppIconBytes') -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
[System.IO.File]::WriteAllBytes($Out,(New-AppIconBytes @(16,20,24,32,40,48,64,128,256)))
# The window / tray / dialog icon the .exe carries (the sizes a window uses; the script draws these itself otherwise).
[System.IO.File]::WriteAllBytes((Join-Path (Split-Path $Out) 'window.ico'),(New-AppIconBytes))
# preview strip on a light and a dark background
$sizes = @(16,24,32,48,64,128)
$wd = ($sizes | Measure-Object -Sum).Sum+10*($sizes.Count+1)
$prev = [System.Drawing.Bitmap]::new([int]$wd,296)
$g = [System.Drawing.Graphics]::FromImage($prev)
$g.FillRectangle([System.Drawing.Brushes]::WhiteSmoke,0,0,$wd,148)
$g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(32,32,32))),0,148,$wd,148)
$x = 10
foreach ($s in $sizes) {
    $b = New-AppIconBitmap $s
    $g.DrawImage($b,$x,10)
    $g.DrawImage($b,$x,158)
    $b.Dispose()
    $x += $s+10
}
$g.Dispose()
$pv = Join-Path $PSScriptRoot '..\verify\work\icon-preview.png'
# verify\work isn't in a fresh clone
[void][IO.Directory]::CreateDirectory((Split-Path $pv))
$prev.Save($pv)
$prev.Dispose()
Get-Item $Out | Select-Object FullName,Length
