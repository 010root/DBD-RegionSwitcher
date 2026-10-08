# Modules load only from Windows' own folder. This process runs as admin, and the default module path starts with
# your Documents folder, where any program running as you could put a module named like one of Windows' own.
$env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Display scale (125 %, 150 %...): the .exe is per-monitor DPI aware (its manifest), so Windows draws it sharp on every
# screen instead of stretching it. Pixel sizes here are at 100 % and multiplied by $DpiScale, the scale of the screen
# the window is on (it opens on the one with the mouse). Fonts in points are drawn at the system scale, so their sizes
# are multiplied by $FontScale (screen / system). Both change when the window moves to another screen (Update-UiDpi).
$SysDpi = 96
$DpiScale = 1.0
try {
    if ('DpiInfo' -as [type]) {
        $SysDpi = [DpiInfo]::SystemDpi()
        $DpiScale = [DpiInfo]::AtCursor()/96.0
    } else {   # the .ps1 run directly: its C# parts load further down
        $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $SysDpi = [int]$g0.DpiX
        $DpiScale = $g0.DpiX/96.0
        $g0.Dispose()
    }
} catch {}
$FontScale = $DpiScale*96/$SysDpi
function Get-Px {
    param([double]$V)   # design pixels (100 %) -> screen pixels
    [int][Math]::Round($V*$DpiScale)
}
function New-UiFont {
    param([string]$Family,[double]$Pt,[System.Drawing.FontStyle]$Style = 'Regular')   # the size at 100 %
    New-Object System.Drawing.Font($Family,[float]($Pt*$FontScale),$Style)
}
function Test-Admin {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------- dark message dialog (Windows' MessageBox is always light) ----------------
# Show-Msg text [-Buttons OK|YesNo|YesNoCancel] [-Icon Information|Warning|Question|Error] [-Labels @{Yes='..'}]
# [-CheckText 'Remember my choice'] [-SafeDefault: Enter picks the last button] -> DialogResult; the checkbox state
# lands in $script:MsgChecked.
$script:MsgChecked = $false
function Show-Msg {
    param([string]$Msg,[string]$Buttons = 'OK',[string]$Icon = 'Information',[hashtable]$Labels = @{},
        [string]$CheckText = '',[switch]$SafeDefault)
    $bg = [System.Drawing.Color]::FromArgb(28,28,32)
    $fg = [System.Drawing.Color]::FromArgb(215,215,222)
    $iconCol = @{
        Information = [System.Drawing.Color]::FromArgb(140,225,150)
        Warning = [System.Drawing.Color]::FromArgb(230,190,70)
        Question = [System.Drawing.Color]::FromArgb(140,225,150)
        Error = [System.Drawing.Color]::FromArgb(230,110,105)
    }[$Icon]
    $glyph = @{ Information = 'i'; Warning = '!'; Question = '?'; Error = 'x' }[$Icon]
    $owner = if ($form -and $form.Visible) { $form } else { $null }
    # Without the window (start-up, tray), it opens on the screen with the mouse: made at that screen's scale (these
    # shadow the window's own for the sizes below).
    if (-not $owner -and ('DpiInfo' -as [type])) {
        $DpiScale = [DpiInfo]::AtCursor()/96.0
        $FontScale = $DpiScale*96/$SysDpi
    }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DBD Region Switcher'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = (-not $owner)
    $d.BackColor = $bg
    $d.ForeColor = $fg
    $d.Font = New-UiFont 'Segoe UI' 10.5
    $d.StartPosition = if ($owner) { 'CenterParent' } else { 'CenterScreen' }
    if ($owner) {
        $d.Icon = $owner.Icon
        $d.TopMost = $owner.TopMost
    } else {
        if ($script:AppIcon) { $d.Icon = $script:AppIcon }
        $d.TopMost = $true
    }
    $d.Add_HandleCreated({ [DarkUi]::TitleBar($this.Handle) })
    # icon: a colored disc with a mark
    $ic = New-Object System.Windows.Forms.Panel
    $ic.Location = [System.Drawing.Point]::new((Get-Px 18),(Get-Px 18))
    $ic.Size = [System.Drawing.Size]::new((Get-Px 30),(Get-Px 30))
    $icFont = New-UiFont 'Segoe UI' 12 Bold
    $ic.Tag = @($iconCol,$glyph,$icFont)
    $ic.Add_Paint({
        param($s,$e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $b = New-Object System.Drawing.SolidBrush($s.Tag[0])
        $g.FillEllipse($b,1,1,$s.Width-3,$s.Height-3)
        $b.Dispose()
        $r = [System.Drawing.Rectangle]::new(1,0,$s.Width-2,$s.Height-1)
        $flags = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'
        [System.Windows.Forms.TextRenderer]::DrawText($g,$s.Tag[1],$s.Tag[2],$r,
            [System.Drawing.Color]::FromArgb(28,28,32),$flags)
    })
    # dashes and arrows as the window shows them (Format-UiText doesn't exist yet when the tool fails to start)
    if ($Dash) { $Msg = Format-UiText $Msg }
    # The first paragraph is the main point (a question, a result), set apart like in Windows' own task dialogs.
    $cut = $Msg.IndexOf("`r`n`r`n")
    $head = if ($cut -gt 0) { $Msg.Substring(0,$cut) } else { $Msg }
    $body = if ($cut -gt 0) { $Msg.Substring($cut+4) } else { '' }
    # a long message without a break stays plain text: a whole paragraph in the heading font reads heavy
    $fHead = if ($cut -gt 0 -or $Msg.Length -le 120) {
        New-UiFont 'Segoe UI Semibold' 11.5
    } else {
        New-UiFont 'Segoe UI' 10.5
    }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $true
    $lbl.MaximumSize = [System.Drawing.Size]::new((Get-Px 560),0)
    $lbl.Location = [System.Drawing.Point]::new((Get-Px 62),(Get-Px 22))
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(240,240,244)
    $lbl.Font = $fHead
    $lbl.Text = $head
    $lbl.UseMnemonic = $false
    $d.Controls.AddRange(@($ic,$lbl))
    $y = $lbl.Top+$lbl.PreferredHeight
    if ($body) {
        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.AutoSize = $true
        $lbl2.MaximumSize = [System.Drawing.Size]::new((Get-Px 560),0)
        $lbl2.Location = [System.Drawing.Point]::new((Get-Px 62),$y+(Get-Px 10))
        $lbl2.ForeColor = $fg
        $lbl2.Text = $body
        $lbl2.UseMnemonic = $false
        $d.Controls.Add($lbl2)
        $y = $lbl2.Top+$lbl2.PreferredHeight
    }
    $y = [Math]::Max((Get-Px 60),$y+(Get-Px 22))
    $chk = $null
    if ($CheckText) {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $CheckText
        $chk.AutoSize = $true
        $chk.Location = [System.Drawing.Point]::new((Get-Px 62),$y)
        $chk.ForeColor = $fg
        $chk.FlatStyle = 'Flat'
        $d.Controls.Add($chk)
        if ('DarkCheck' -as [type]) { [DarkCheck]::Attach($chk) }   # after Add: sized with the dialog's font
        $y += Get-Px 34
    }
    $names = switch ($Buttons) {
        'YesNo' {@('Yes','No')}
        'YesNoCancel' {@('Yes','No','Cancel')}
        default {@('OK')}
    }
    $btns = @(foreach ($n in $names) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = if ($Labels[$n]) { $Labels[$n] } else { $n }
        $b.DialogResult = [System.Windows.Forms.DialogResult]$n
        $b.FlatStyle = 'Flat'
        $b.Height = Get-Px 32
        $b.Width = [Math]::Max((Get-Px 96),
            [System.Windows.Forms.TextRenderer]::MeasureText($b.Text,$d.Font).Width+(Get-Px 30))
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(85,85,95)
        $b.UseVisualStyleBackColor = $false
        # gold = the action (like Apply)
        if ($n -eq $names[0] -and $names.Count -gt 1) {
            $b.BackColor = [System.Drawing.Color]::FromArgb(226,182,44)
            $b.ForeColor = [System.Drawing.Color]::FromArgb(64,54,30)
        } else {
            $b.BackColor = [System.Drawing.Color]::FromArgb(60,64,74)
            $b.ForeColor = [System.Drawing.Color]::White
        }
        $b.FlatAppearance.MouseOverBackColor = [System.Windows.Forms.ControlPaint]::Light($b.BackColor,0.25)
        $b
    })
    $textW = [Math]::Max($lbl.PreferredWidth,$(if ($body) { $lbl2.PreferredWidth } else { 0 }))
    $w = [Math]::Max((Get-Px 380),[Math]::Max($textW+(Get-Px 90),
        (($btns | Measure-Object Width -Sum).Sum+(Get-Px 10)*$btns.Count+(Get-Px 40))))
    $x = $w-(Get-Px 20)
    foreach ($b in ($btns[($btns.Count-1)..0])) {
        $x -= $b.Width
        $b.Location = [System.Drawing.Point]::new($x,$y)
        $x -= Get-Px 10
    }
    $d.Controls.AddRange([System.Windows.Forms.Control[]]$btns)
    $d.ClientSize = [System.Drawing.Size]::new($w,$y+(Get-Px 50))
    $d.AcceptButton = $btns[0]
    $d.CancelButton = $btns[$btns.Count-1]
    # Enter = the harmless choice. Enter presses the FOCUSED button, and the first one gets the focus when the dialog
    # opens, so the focus moves to the last one once it's on screen.
    if ($SafeDefault) {
        $d.AcceptButton = $btns[$btns.Count-1]
        $d.Tag = $btns[$btns.Count-1]
        $d.Add_Shown({
            $this.ActiveControl = $this.Tag
            [void]$this.Tag.Focus()
        })
    }
    # Ctrl+C copies, like a MessageBox
    $d.KeyPreview = $true
    $d.Add_KeyDown({
        param($s,$e)
        if ($e.Control -and $e.KeyCode -eq 'C') {
            try { [System.Windows.Forms.Clipboard]::SetText($Msg) } catch {}
            $e.Handled = $true
        }
    })
    if (-not $owner) { $d.Add_Shown({ [void][WinHelp]::Focus($this.Handle) }) }
    $r = if ($owner) { $d.ShowDialog($owner) } else { $d.ShowDialog() }
    $script:MsgChecked = ($chk -and $chk.Checked)
    $dFont = $d.Font
    $d.Dispose()
    foreach ($x in $icFont,$fHead,$dFont) { $x.Dispose() }
    if ($r -eq [System.Windows.Forms.DialogResult]::None) {
        $r = [System.Windows.Forms.DialogResult]$names[$names.Count-1]
    }
    return $r
}
$nl = "`r`n"
# Typography for what the window shows (the sources stay ASCII; logs keep "-" and "->"): en dash, arrow, ellipsis,
# em dash for "no value", and the marker of a warning line in the activity box.
$Dash = [string][char]0x2013
$Arrow = [string][char]0x2192
$Ell = [string][char]0x2026
$NoValue = [string][char]0x2014
$WarnMark = [string][char]0x25B8
function Format-UiText {
    # Dashes and arrows as the window shows them. A line with a path in it stays as it is: a path can contain " - ".
    param([string]$Text)
    $lines = foreach ($l in $Text -split "`n") {
        if ($l -match '[A-Za-z]:\\|\\\\') { $l } else { $l.Replace(' -> '," $Arrow ").Replace(' - '," $Dash ") }
    }
    $lines -join "`n"
}
# If the tool can't start (e.g. an antivirus blocks part of it), say so instead of vanishing: the .exe has no
# console. Only start-up errors land here; an error inside a button or timer handler doesn't.
trap {
    $why = "DBD Region Switcher could not start:$nl$nl$($_.Exception.Message)$nl$nl" +
        'If this keeps happening, an antivirus may be blocking part of it.'
    try { [void](Show-Msg $why 'OK' 'Error') } catch {}
    exit 1
}

# Windows' own folder, asked from Windows itself: this process runs as admin, and environment variables such as
# %windir% can be changed without admin, so they must not decide which hosts file is written or which program runs.
$Sys32 = [Environment]::SystemDirectory

# Self-elevate (the .exe asks for admin through its manifest; this covers running the .ps1 directly, e.g. for testing).
# Saying no to the UAC prompt throws, and then there's nothing left to do.
if (-not (Test-Admin)) {
    try {
        $ps = Join-Path $Sys32 'WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$PSCommandPath+'"'))
        Start-Process -FilePath $ps -Verb RunAs -WindowStyle Hidden -ArgumentList $psArgs
    } catch {}
    exit
}

$HostsPath = Join-Path ([Environment]::SystemDirectory) 'drivers\etc\hosts'
# HTTPS downloads (AWS ip-ranges, region status) need TLS 1.2, which Windows PowerShell 5.1 doesn't always offer.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12
$MarkBegin = '# === DBD-RegionSwitcher BEGIN (do not edit) ==='
$MarkBeginPrefix = '# === DBD-RegionSwitcher BEGIN'
$MarkEnd = '# === DBD-RegionSwitcher END ==='
$MarkSepFlag = '# (a line break was added before this block; removing the block removes it too)'
$ToolVersion = '1.0'
$DbdProc = 'DeadByDaylight-Win64-Shipping'
# The same game from Epic Games and Xbox / Game Pass (the Xbox name comes from players' reports). Everything works by
# process; Switch + Restart starts DBD again through its own store (Start-Dbd).
$DbdProcs = @($DbdProc,'DeadByDaylight-EGS-Shipping','DeadByDaylight-WinGDK-Shipping')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Strict = New-Object System.Text.UTF8Encoding($false,$true)
# Only if BHVR switches DBD back to HTTP latency checks: those go through UE's libcurl, which keeps its own in-process
# DNS cache (default 60 s, never overridden - see docs\how-it-works.md) that a DNS flush cannot clear. In the current
# UDP-beacon mode every ping is looked up through Windows, so none of this waits.
$CurlDnsTtlSec = 60
$CurlSafetySec = 3
# DBD re-measures regions only if at least this many seconds have passed since its last completed measurement
# (ULatencyCalculator: 600 s by default, replaced at start-up by BHVR's remote LatencyRetryCooldownSeconds if that's
# above 0), and only if its best stored latency is above 300 ms, which a reset gives (every result back to 20000).
$RemeasureCooldownSec = 600
$RemeasureMarginSec = 5
$script:LastPings = @{}

