# ---------------- console window (live log) ----------------
# Everything the session log gets, colored by kind, plus (optional) every DNS lookup DBD makes, live.
$script:ConBox = $null
$script:ConForm = $null
$script:ConDns = $true
$script:ConAuto = $true
$fCon = New-UiFont 'Consolas' 10.5
function Get-ConsoleColor {
    param([string]$L)
    if ($L -match '(?i)\berror\b|failed|refused|NOT received') { return [System.Drawing.Color]::FromArgb(240,110,105) }
    if ($L -match '\[dns\]')                       { return [System.Drawing.Color]::FromArgb(125,128,140) }
    if ($L -match 'APPLY ')                        { return [System.Drawing.Color]::FromArgb(230,190,60) }
    if ($L -match 'VERIFY:|region ping round')      { return [System.Drawing.Color]::FromArgb(140,225,150) }
    if ($L -match '(?i)clock')                     { return $cClockCat }
    if ($L -match '(?i)\bcut\b|hold|Cut DBD')       { return [System.Drawing.Color]::FromArgb(255,165,75) }
    if ($L -match 'Game server')                   { return $cNet }
    return [System.Drawing.Color]::FromArgb(205,208,214)
}
function Add-ConsoleLine {
    param([string]$Line)
    $rt = $script:ConBox
    if (-not $rt -or $rt.IsDisposed) { return }
    # keep it light: the oldest quarter goes
    if ($rt.TextLength -gt 400000) {
        $rt.Select(0,100000)
        $rt.SelectedText = ''
    }
    $rt.Select($rt.TextLength,0)
    $rt.SelectionColor = (Get-ConsoleColor $Line)
    $rt.SelectionIndent = $StatusIndent
    $rt.SelectionHangingIndent = $script:ConHang
    # Lines wrap at the window's edge, under the text after the time stamp; a message's own line breaks become line
    # breaks inside its paragraph (vertical tab), so its later lines are indented the same way.
    $rt.AppendText(($Line -replace "`r?`n","`v") + "`n")
    if ($script:ConAuto) {
        $rt.Select($rt.TextLength,0)
        $rt.ScrollToCaret()
    }
}
$script:ConHang = 0
function Set-ConsoleHang {   # the width of a line's time stamp: where wrapped lines continue (new lines use it)
    $g = $script:ConBox.CreateGraphics()
    try {
        $script:ConHang = [System.Windows.Forms.TextRenderer]::MeasureText($g,'0000-00-00 00:00:00.000  ',
            $script:ConBox.Font,
            [System.Drawing.Size]::Empty,[System.Windows.Forms.TextFormatFlags]::NoPadding).Width
    } finally { $g.Dispose() }
}
function Show-Console {
    if ($script:ConForm -and -not $script:ConForm.IsDisposed) {
        # a maximized one stays so
        if ($script:ConForm.WindowState -eq 'Minimized') { $script:ConForm.WindowState = 'Normal' }
        $script:ConForm.Activate()
        return
    }
    $cf = [System.Windows.Forms.Form]@{
        Text = "DBD Region Switcher $Dash Console"
        Size = [System.Drawing.Size]::new(1000,460)
        StartPosition = 'Manual'
        BackColor = [System.Drawing.Color]::FromArgb(14,14,16)
        ForeColor = $cText
        Font = $fCaption
        TopMost = $script:OnTop
    }
    # on the window's own screen, whichever it is
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = [Math]::Max($wa.Left,[Math]::Min($form.Left+(Get-Px 40),$wa.Right-(Get-Px 1000)))
    $y = [Math]::Max($wa.Top,[Math]::Min($form.Bottom-(Get-Px 500),$wa.Bottom-(Get-Px 460)))
    $cf.Location = [System.Drawing.Point]::new($x,$y)
    $cf.Icon = $form.Icon
    $bar = [System.Windows.Forms.Panel]@{ Dock = 'Top'; Height = 34; BackColor = $cPanel }
    $cbDns = [System.Windows.Forms.CheckBox]@{
        Text = 'Show DBD DNS lookups'
        Location = '10,7'
        Size = '190,22'
        ForeColor = $cText
        FlatStyle = 'Flat'
        Checked = $script:ConDns
    }
    $cbAuto = [System.Windows.Forms.CheckBox]@{
        Text = 'Auto-scroll'
        Location = '210,7'
        Size = '110,22'
        ForeColor = $cText
        FlatStyle = 'Flat'
        Checked = $script:ConAuto
    }
    $bCopy = [System.Windows.Forms.Button]@{
        Text = 'Copy all'
        Location = '330,5'
        Size = '90,24'
        FlatStyle = 'Flat'
        BackColor = $cBtnRead
        ForeColor = [System.Drawing.Color]::White
    }
    $bClear = [System.Windows.Forms.Button]@{
        Text = 'Clear'
        Location = '426,5'
        Size = '70,24'
        FlatStyle = 'Flat'
        BackColor = $cBtnRead
        ForeColor = [System.Drawing.Color]::White
    }
    foreach ($b in $bCopy,$bClear) { $b.FlatAppearance.BorderColor = $cBorder }
    foreach ($c in $cbDns,$cbAuto) { [DarkCheck]::Attach($c) }
    $rt = [System.Windows.Forms.RichTextBox]@{
        Dock = 'Fill'
        ReadOnly = $true
        BorderStyle = 'None'
        WordWrap = $true
        ScrollBars = 'Vertical'
        DetectUrls = $false
        HideSelection = $false
        BackColor = [System.Drawing.Color]::FromArgb(14,14,16)
        ForeColor = [System.Drawing.Color]::FromArgb(205,208,214)
        Font = $fCon
    }
    $cbDns.Add_CheckedChanged({ $script:ConDns = $this.Checked })
    $cbAuto.Add_CheckedChanged({ $script:ConAuto = $this.Checked })
    $bCopy.Add_Click({
        if ($script:ConBox) { Copy-Text (($script:ConBox.Text -replace "`n","`r`n") -replace "`v","`r`n") }
    })
    $bClear.Add_Click({
        if ($script:ConBox) {
            $script:ConBox.Clear()
            $script:ConBox.SelectionIndent = $StatusIndent
        }
    })
    $bar.Controls.AddRange(@($cbDns,$cbAuto,$bCopy,$bClear))
    $cf.Controls.Add($rt)
    $cf.Controls.Add($bar)
    $rt.BringToFront()
    $at = $cf.Location
    # its layout is in 100 % pixels (its fonts scale by themselves)
    $cf.Scale([System.Drawing.SizeF]::new($DpiScale,$DpiScale))
    $cf.Location = $at
    $cf.Add_HandleCreated({ [DarkUi]::TitleBar($this.Handle) })
    # Its own screen scale: dragged to a screen with another scale, it rescales itself (Set-FormDpiScale).
    $script:ConDpi = [int][Math]::Round($DpiScale*96)
    if ('DpiWatcher' -as [type]) {
        $script:ConWatch = New-Object DpiWatcher($cf)
        $script:ConWatch.Add_Changed({
            param($s,$e)
            if ($e.Dpi -le 0 -or $e.Dpi -eq $script:ConDpi -or -not $script:ConForm) { return }
            $k = $e.Dpi/$script:ConDpi
            $script:ConDpi = $e.Dpi
            try {
                Set-FormDpiScale $script:ConForm $k @{}
                $script:ConForm.Bounds = $e.Suggested
                Set-ConsoleHang
            } catch { Write-Log "Console scale change failed: $($_.Exception.Message)" }
        })
    }
    $cf.Add_Shown({ [DarkUi]::Theme($script:ConBox.Handle,'DarkMode_Explorer') })
    $cf.Add_FormClosed({
        $script:ConBox = $null
        $script:ConForm = $null
    })
    $script:ConForm = $cf
    $script:ConBox = $rt
    Set-ConsoleHang
    $script:ConNoCaret = New-Object NoCaret($rt)
    $rt.SelectionIndent = $StatusIndent   # same room on the left as the activity box (new lines keep it)
    foreach ($l in @($script:ConBuf)) { Add-ConsoleLine $l }
    Add-ConsoleLine ("{0}  --- console opened ---" -f
        [DbdEtw]::UtcNow.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff'))
    $cf.Show($form)
}

# ---------------- copy from the status rows / activity ----------------
function Copy-Text {
    param([string]$T)
    if ($T) { try { [System.Windows.Forms.Clipboard]::SetText($T) } catch {} }
}
function Get-StatusRowsText {
    ("STEERING:      $(Get-InfoText $lblSteer)`r`nGAME SERVER:   $(Get-InfoText $lblMatch)`r`nDBD MEASURED:  " +
        "$(Get-InfoText $lblDbd)`r`nRE-MEASURE:    $(Get-InfoText $lblNext)")
}
$copyMenu = New-Object System.Windows.Forms.ContextMenuStrip
$copyMenu.Renderer = New-Object DarkMenuRenderer
$copyMenu.ShowImageMargin = $false
$copyMenu.Font = $fSemi
# Copy = the selection, or the whole row / activity when nothing (or everything, "..." included) is selected.
$miC1 = $copyMenu.Items.Add('Copy')
$miC1.Add_Click({
    $b = $copyMenu.SourceControl
    if ($b) {
        $partly = $b.SelectionLength -gt 0 -and $b.SelectionLength -lt $b.TextLength
        Copy-Text $(if ($partly) { $b.SelectedText } else { (Get-InfoText $b) -replace "`r?`n","`r`n" })
    }
})
$miC2 = $copyMenu.Items.Add('Copy all status rows')
$miC2.Add_Click({ Copy-Text (Get-StatusRowsText) })
$miC3 = $copyMenu.Items.Add('Copy activity')
$miC3.Add_Click({ Copy-Text ($status.Text -replace "`n","`r`n") })
[void]$copyMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miC4 = $copyMenu.Items.Add('Select all')
$miC4.Add_Click({
    $b = $copyMenu.SourceControl
    if ($b) {
        $b.Focus()
        $b.SelectAll()
    }
})
foreach ($b in $lblSteer,$lblMatch,$lblDbd,$lblNext,$status) { $b.ContextMenuStrip = $copyMenu }
# kept in a variable: they stay attached for the window's life
$script:NoCarets = @(foreach ($b in $lblSteer,$lblMatch,$lblDbd,$lblNext,$status) { New-Object NoCaret($b) })

# Right-click a region: the same actions as the buttons (they still show what they'll do first, then Apply).
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.Renderer = New-Object DarkMenuRenderer
$menu.BackColor = [System.Drawing.Color]::FromArgb(40,40,46)
$menu.ForeColor = [System.Drawing.Color]::White
$menu.Font = $fSemi
function Add-MenuItem {
    param([string]$Text,[scriptblock]$Do)
    $mi = $menu.Items.Add($Text)
    $mi.ForeColor = [System.Drawing.Color]::White
    $mi.Add_Click($Do)
    return $mi
}
# Update-DbdActions shows / hides the first one and renames the second, depending on whether DBD runs.
$miSwitch = Add-MenuItem 'Switch (no restart) to this region' { Select-Action 'Switch' }
$miRestart = Add-MenuItem 'Switch + Restart to this region' { Select-Action 'Restart' }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem 'Ping all regions' { $btnPing.PerformClick() })
[void](Add-MenuItem 'Copy region code' { Copy-Text $script:PickCode })
$menu.Add_Opening({
    param($s,$e)
    if ($script:Busy -or $list.SelectedItems.Count -ne 1) { $e.Cancel = $true }
})
$list.ContextMenuStrip = $menu
# Double-click / Enter: selects Switch (no restart), or Switch + Start while DBD isn't running;
# nothing runs before Apply.
function Select-DefaultSwitch { Select-Action $(if ($script:SwitchShown) { 'Switch' } else { 'Restart' }) }
$list.Add_DoubleClick({ if (-not $script:Busy -and $list.SelectedItems.Count -eq 1) { Select-DefaultSwitch } })
# Keyboard: Enter = the same as a double-click, Ctrl+C = the region code.
$list.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq 'Enter' -and -not $script:Busy -and $list.SelectedItems.Count -eq 1) {
        Select-DefaultSwitch
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'C' -and $script:PickCode) {
        Copy-Text $script:PickCode
        $e.Handled = $true
    }
})
$tips.SetToolTip($btnPing,'Read-only (F5): this PC''s connect time to every region.')
$tips.SetToolTip($btnSwitch,'Steer to the picked region and make DBD re-measure, without a restart.')
$tips.SetToolTip($btnClear,'Delete only this tool''s block from hosts.')
$tips.SetToolTip($btnRepair,'Replace the whole hosts file with the Windows default.')
$tips.SetToolTip($btnDetails,'Read-only: DBD''s lookups, its last measurement, the session log.')
$tips.SetToolTip($btnSkip,'While waiting: cancel and put hosts back. After the cut: DBD shows its connection error.')
$tips.SetToolTip($btnApply,'Run the selected action.')
$tips.SetToolTip($chkClock,'Move the PC clock ahead for the cut instead of waiting; it goes back the moment ' +
    'DBD starts measuring.')
$tips.SetToolTip($chkNgen,'HyperX NGENUITY loses your mouse colors when the clock changes: restart it afterwards ' +
    '(about a second, no window).')
$chkNgen.Add_CheckedChanged({
    $script:NgenOpt = $chkNgen.Checked
    Save-State
    Write-Log ("NGENUITY restart option: " + $(if ($script:NgenOpt) {'on'} else {'off'}))
    if ($script:Selected -eq 'Switch' -and -not $script:Busy) { Select-Action 'Switch' }
})
$chkClock.Add_CheckedChanged({
    $script:ClockOpt = $chkClock.Checked
    Update-SwitchOptions
    Save-State
    Write-Log ("Clock option: " + $(if ($script:ClockOpt) {'on'} else {'off'}))
    if ($script:Selected -eq 'Switch' -and -not $script:Busy) { Select-Action 'Switch' }
})

$form.Add_HandleCreated({ [DarkUi]::TitleBar($form.Handle) })
# The tool's own icon (window, taskbar, tray, dialogs).
if ($script:AppIcon) { $form.Icon = $script:AppIcon }
$script:FocusOk = $false   # read by the smoke test (run-elevated.ps1)
$form.Add_Shown({
    # Opened on a screen other than the one the layout was made for (e.g. a remembered position): rescaled first.
    try {
        if ('DpiInfo' -as [type]) { Update-UiDpi ([DpiInfo]::ForWindow($form.Handle)) }
    } catch { Write-Log "Display scale check failed: $($_.Exception.Message)" }
    $form.TopMost = $true
    $form.TopMost = $script:OnTop
    $script:FocusOk = [WinHelp]::Focus($form.Handle)
    $form.Activate()
    [DarkUi]::Theme($list.Handle,'DarkMode_Explorer')
    [DarkUi]::Theme([DarkUi]::ListViewHeader($list.Handle),'DarkMode_ItemsView')
    [DarkUi]::Theme($status.Handle,'DarkMode_Explorer')
    # If any of this fails the window still opens, just not fully drawn: better than no window.
    try {
        Update-ListColumns
        $list.Invalidate()
        Sort-RegionList
        # the start text again: its bold labels need the box on screen
        if ($script:StatusText -ceq $Status0) {
            $script:StatusText = $null
            Set-Status $Status0 $cText
        }
        # "..." needs the rows on screen too
        foreach ($b in $lblSteer,$lblMatch,$lblDbd,$lblNext) { Show-InfoText $b }
        # the footer's fonts and spacing at this scale
        Show-UpdateNotice
    } catch {
        Write-Log "Window setup failed: $($_.Exception.Message)"
    }
    # The window opens fully transparent (see Application.Run below): shown only once every part is painted dark.
    $form.Refresh()
    $form.Opacity = 1
})
$script:Busy = $false
$script:SkipWait = $false
$script:Verify = $null
$script:Selected = $null
$script:Closing = $false

