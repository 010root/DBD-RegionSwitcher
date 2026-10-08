# ---------------- system tray ----------------
# Closing can hide the window to the tray instead (asked, or chosen under Options > When closing the window). Everything
# keeps running there: a waiting Switch, the clock option's restore, verification, monitoring.
$script:ReallyQuit = $false
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = $WindowTitle
$tray.Visible = $false
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Renderer = New-Object DarkMenuRenderer
$trayMenu.ShowImageMargin = $false
$trayMenu.Font = $fSemi
$miTrayOpen = $trayMenu.Items.Add('Open DBD Region Switcher')
$miTrayOpen.Font = New-Object System.Drawing.Font($fSemi,[System.Drawing.FontStyle]::Bold)
$miTrayOpen.Add_Click({ Show-FromTray })
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miTrayQuit = $trayMenu.Items.Add('Quit')
$miTrayQuit.Add_Click({
    $script:ReallyQuit = $true
    $form.Close()
})
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseClick({
    param($s,$e)
    if ($e.Button -eq 'Left') { Show-FromTray }
})
$tray.Add_BalloonTipClicked({ Show-FromTray })   # the notification of a result (Request-Attention) opens the window
$script:NoteIcon = $null
function Show-TrayNote {
    param([string]$Text)
    # With the tool's icon (the 64 px image of the window icon); if that fails, with no icon rather than Windows' blue
    # one. Windows names the sender after the program running the tool: "DBD Region Switcher" for the .exe, "Windows
    # PowerShell" when the .ps1 runs directly (tests).
    try {
        if (-not $script:NoteIcon) { $script:NoteIcon = New-Object System.Drawing.Icon($script:AppIcon,64,64) }
        $f = [System.Reflection.BindingFlags]'NonPublic,Instance'
        $t = [System.Windows.Forms.NotifyIcon]
        if ([WinHelp]::Balloon($t.GetField('window',$f).GetValue($tray).Handle,
            [int]$t.GetField('id',$f).GetValue($tray),'DBD Region Switcher',$Text,$script:NoteIcon.Handle)) {
            return
        }
    } catch {}
    $tray.ShowBalloonTip(8000,'DBD Region Switcher',$Text,'None')
}
function Request-Attention {
    param([string]$Text)
    # A result you'd otherwise only see in this window (you're usually in DBD by then): the taskbar button flashes, or,
    # hidden in the tray, a notification shows its first line.
    try {
        if (-not $form.Visible -and $tray.Visible) {
            $first = ($Text -split "`r?`n")[0]
            Show-TrayNote $(if ($first.Length -gt 240) { $first.Substring(0,237)+'...' } else { $first })
        } elseif ($form.Visible -and -not [WinHelp]::IsForeground($form.Handle)) {
            [WinHelp]::Flash($form.Handle)
        }
    } catch {}
}
function Hide-ToTray {
    $tray.Icon = $form.Icon
    $tray.Visible = $true
    $form.Hide()
    Write-Log 'Window hidden to the system tray (double-click or left-click the tray icon to open it again).'
}
function Show-FromTray {
    if (-not $form.Visible) {
        $form.Show()
        $tray.Visible = $false
        Write-Log 'Window shown again from the system tray.'
    }
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    [void][WinHelp]::Focus($form.Handle)
    $form.Activate()
}
$form.Add_FormClosing({
    param($s,$e)
    if (-not $script:ReallyQuit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $mode = $script:CloseTo
        if ($mode -eq 'ask') {
            $ask = ("Keep DBD Region Switcher running in the system tray?`r`n`r`nEverything keeps working there, " +
                "including a Switch that's waiting. Click the tray icon to open the window, right-click it to quit.")
            $r = Show-Msg $ask 'YesNoCancel' 'Question' @{
                Yes = 'Run in the tray'
                No = 'Quit'
                Cancel = 'Back'
            } 'Remember my choice (Options > When closing the window)'
            if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $e.Cancel = $true
                return
            }
            $mode = if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { 'tray' } else { 'quit' }
            if ($script:MsgChecked) {
                $script:CloseTo = $mode
                foreach ($x in $miClose.DropDownItems) { $x.Checked = ($x.Tag -eq $mode) }
                Save-State
            }
        }
        if ($mode -eq 'tray') {
            $e.Cancel = $true
            Hide-ToTray
            Show-TrayNote 'Still running in the system tray. Click its icon to open the window.'
            return
        }
    }
    # Temporary steering while DBD still runs: the tool can stay in the tray and remove it once DBD closes.
    if (-not $e.Cancel -and ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -or
        $script:ReallyQuit) -and (Get-TempQuitPlan) -eq 'ask') {
        $r = Show-Msg ("Your steering is temporary and DBD is still running.`r`n`r`nKeep the tool in the system tray " +
            "until DBD closes, then remove the steering? Removed now, DBD keeps its region until its next " +
            "measurement, which would then be unsteered.") 'YesNoCancel' 'Question' @{
            Yes = 'Stay in the tray'
            No = 'Remove it now and quit'
            Cancel = 'Back'
        }
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $e.Cancel = $true
            $script:ReallyQuit = $false
            return
        }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            $script:ReallyQuit = $false
            Hide-ToTray
            Show-TrayNote 'Running in the tray until DBD closes; then the temporary steering is removed.'
            return
        }
        [void](Remove-TempSteering 'you chose to remove it when closing the tool')
    }
})
$form.Add_FormClosing({
    param($s,$e)
    if ($e.Cancel) { return }   # hidden to the tray, not closing
    # Closing while an action waits or holds the cut = Cancel: its loop sees SkipWait and puts hosts back (it would
    # otherwise go on with no window, could still cut DBD or move the clock, and keep the single-instance lock).
    if ($script:Busy) {
        $script:Closing = $true
        $script:SkipWait = $true
        Write-Log 'Window closed while an action was running - cancelling it.'
    }
    # Remember position/size (the normal-size bounds when maximized or minimized).
    $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    if ($script:PickCode) { $script:LastPick = $script:PickCode }
    $maxed = if ($form.WindowState -eq 'Maximized') { '1' } else { '0' }
    $script:WinState = "{0},{1},{2},{3},{4}" -f $b.X,$b.Y,$b.Width,$b.Height,$maxed
    $script:WinDpi = [int][Math]::Round(96*$DpiScale)
    Save-State
})
$form.Add_FormClosed({
    # The clock first: nothing before it may get in its way.
    try {
        if ([DbdEtw]::ClockAhead) {
            [void][DbdEtw]::RestoreClock('tool closed')
            Write-Log "Clock put back (tool closed): $([DbdEtw]::RestoreWhy)"
        }
    } catch { Write-Log "Putting the clock back on close failed: $($_.Exception.Message)" }
    $tray.Visible = $false
    $tray.Dispose()
    $timer.Stop()
    if ($script:NgenRestart) { Complete-NGenuityRestartNow }
    try {
        if ((Get-TempQuitPlan) -eq 'remove') { [void](Remove-TempSteering 'tool closed while DBD wasn''t running') }
    } catch { Write-Log "Removing the temporary steering on close failed: $($_.Exception.Message)" }
    [DbdEtw]::Stop()
    Write-Log 'Tool closed.'
})
# Bigger text than WinForms' 8.25 pt: every control inherits the form's font; the layout above is in 8.25-pt units, so
# it is scaled by the same factor (columns by hand - Scale() doesn't touch them), and by the display scale, since the
# layout is in 100 % pixels.
$UiScale = 1.27*$DpiScale
function Set-WindowFit {
    # Too tall for its screen (e.g. 1080p at 150 %, like a 1280 x 720 screen): the activity box gives up height first,
    # down to a few lines (it scrolls), so the region list keeps its rows; then the window is fitted to the screen.
    param([System.Drawing.Rectangle]$Wa,[switch]$SetMinimum)
    $d = [Math]::Min($form.Height-$Wa.Height,$statusFrame.Height-[int](100*$UiScale))
    if ($d -gt 0) {
        $bottom.Top += $d   # the activity box stretches with it; the rest of the bottom part keeps its place in it
        $bottom.Height -= $d
        $listFrame.Height += $d
    }
    # The smallest window: the layout's own width (the button row needs it all), and the list down to 4 rows
    # (everything else as it is now). From the client area: the window frame is wider at a higher display scale.
    if ($SetMinimum) {
        $minW = $form.Width-$form.ClientSize.Width+[int]($DesignClientW*$UiScale)
        $minH = $form.Height-($listFrame.Height-($script:ListHeadH+4*$script:ListRowH+$listFrame.Padding.Vertical))
        $form.MinimumSize = [System.Drawing.Size]::new($minW,$minH)
    }
    $m = $form.MinimumSize
    if ($m.Width -gt $Wa.Width -or $m.Height -gt $Wa.Height) {
        $form.MinimumSize = [System.Drawing.Size]::new([Math]::Min($m.Width,$Wa.Width),
            [Math]::Min($m.Height,$Wa.Height))
    }
    if ($form.Height -gt $Wa.Height) { $form.Height = $Wa.Height }
    if ($form.Width -gt $Wa.Width) { $form.Width = $Wa.Width }
}
$form.Font = New-UiFont 'Segoe UI' 10.5
$form.Controls.AddRange([System.Windows.Forms.Control[]]$legend)
# Everything below the list in one panel: a window resized in height then moves that one panel (Windows moves its
# picture along) instead of each control in it, each repainting, which makes resizing lag. In it, the status
# card, the buttons and their options keep their place from its top, the activity box stretches, the footer stays at
# its bottom (a display scale change or Set-WindowFit can change the panel's height).
$bTop = 312   # the list's bottom edge
$bottom = [System.Windows.Forms.Panel]@{
    Location = [System.Drawing.Point]::new(0,$bTop)
    Size = [System.Drawing.Size]::new($form.ClientSize.Width,$form.ClientSize.Height-$bTop)
    Anchor = $aBLR
    BackColor = $form.BackColor
}
foreach ($c in @($infoPanel,$btnPing,$btnSwitch,$btnRestart,$btnClear,$btnRepair,$btnDetails,$chkClock,$chkNgen,
    $btnSkip,$btnApply,$divider,$statusFrame,$footer)) {
    $c.Top -= $bTop
    $c.Anchor = if ($c -eq $statusFrame) {
        $aAll
    } elseif ($c -eq $footer) {
        $aBLR
    } elseif ($c -eq $infoPanel) {
        $aTLR
    } elseif ($c.Anchor -band [System.Windows.Forms.AnchorStyles]::Right) {
        $aTR
    } else {
        $aTL
    }
    $bottom.Controls.Add($c)
}
$form.Controls.AddRange([System.Windows.Forms.Control[]]@($lblRegions,$btnOptions,$btnConsole,$listFrame,$bottom))
[OffScreen]::Apply($form)   # buttons and labels: off-screen first (src\native\UiPainting.cs)
$form.Scale([System.Drawing.SizeF]::new($UiScale,$UiScale))
$form.MinimumSize = [System.Drawing.Size]::new($form.Width,[int](620*$UiScale))   # refined by Set-WindowFit below
$script:ActionRow = New-Object EvenRow($infoPanel,
    [System.Windows.Forms.Control[]]@($btnSwitch,$btnRestart,$btnClear,$btnRepair),[int](6*$UiScale))
# Switch is hidden while DBD isn't running (Update-DbdActions keeps that current)
$script:ActionRow.Show($btnSwitch,$script:SwitchShown)
# The parts that follow the right / bottom edge, moved in one batch per container (EdgeLayout), not by their anchors.
$script:FormEdges = New-Object EdgeLayout($form)
$script:BottomEdges = New-Object EdgeLayout($bottom)
foreach ($c in $btnOptions,$btnConsole,$listFrame,$bottom) { $script:FormEdges.Follow($c,$c.Anchor) }
foreach ($c in $infoPanel,$btnSkip,$btnApply,$statusFrame,$footer) { $script:BottomEdges.Follow($c,$c.Anchor) }
function Update-OptionLayout {
    # The Switch options sized to their text, the first one lined up with Switch's text column, the second after it.
    [DarkCheck]::Fit($chkClock)
    [DarkCheck]::Fit($chkNgen)
    $chkClock.Left = $btnSwitch.Left+[int](2*$UiScale)
    $chkNgen.Left = $chkClock.Right+[int](12*$UiScale)
}
function Set-WindowLayout {
    # Every part's place from the design layout (13-window.ps1) at the current scale, for the current client size; the
    # anchors keep it while the window is resized. WinForms' own rescaling (Scale) rounds each part on its own, and
    # over a few display scale changes that adds up to edges a few pixels off. Each size and gap is rounded once and
    # the parts are stacked from them, so equal gaps stay equal.
    $k = $script:UiScale
    $px = { param([double]$V) [int][Math]::Round($V*$k) }
    $W = $form.ClientSize.Width
    $H = $form.ClientSize.Height
    $m = & $px 12        # margin
    $g = & $px 8         # gap between the parts, top to bottom
    $gx = & $px 6        # gap between buttons side by side
    $hHead = & $px 26
    $hBtn = & $px 34
    # header row
    $lblRegions.SetBounds($m,$g,(& $px 70),$hHead)
    foreach ($i in 0..2) { $legend[$i].SetBounds((& $px @(84,156,218)[$i]),$g,(& $px @(70,60,86)[$i]),$hHead) }
    $btnConsole.SetBounds($W-$m-(& $px 108),$g,(& $px 108),$hHead)
    $btnOptions.SetBounds($btnConsole.Left-$gx-(& $px 112),$g,(& $px 112),$hHead)
    # the list down to the bottom part (Set-WindowFit may have moved its top: the list keeps its height)
    $top = $bottom.Top
    $listFrame.SetBounds($m,$g+$hHead+$g,$W-2*$m,[Math]::Max(0,$top-($g+$hHead+$g)))
    $bottom.SetBounds(0,$top,$W,[Math]::Max(0,$H-$top))
    $bh = $H-$top
    # in the bottom part: status card, two button rows, activity box, footer
    $infoPanel.SetBounds($m,$g,$W-2*$m,(& $px 90))
    $y1 = $infoPanel.Bottom+$g
    $y2 = $y1+$hBtn+$g
    $wSide = & $px 70
    $btnPing.SetBounds($m,$y1,$wSide,$hBtn)
    $btnDetails.SetBounds($m,$y2,$wSide,$hBtn)
    $divider.SetBounds($btnPing.Right+[int]($gx/2),$y1+(& $px 2),1,$y2+$hBtn-$y1-2*(& $px 2))
    $btnSwitch.SetBounds($btnPing.Right+$gx,$y1,$btnSwitch.Width,$hBtn)
    foreach ($b in $btnRestart,$btnClear,$btnRepair) { $b.SetBounds($b.Left,$y1,$b.Width,$hBtn) }
    $btnApply.SetBounds($W-$m-(& $px 204),$y2,(& $px 204),$hBtn)
    $btnSkip.SetBounds($btnApply.Left-$gx-(& $px 110),$y2,(& $px 110),$hBtn)
    $hChk = & $px 24
    foreach ($c in $chkClock,$chkNgen) { $c.SetBounds($c.Left,$y2+[int](($hBtn-$hChk)/2),$c.Width,$hChk) }
    $hFoot = & $px 20
    $footer.SetBounds($m,$bh-$m-$hFoot,$W-2*$m,$hFoot)
    $yS = $y2+$hBtn+$g
    $statusFrame.SetBounds($m,$yS,$W-2*$m,[Math]::Max(0,$footer.Top-$g-$yS))
    $script:ActionRow.Gap = $gx
    $script:ActionRow.Layout()
    Update-OptionLayout
    $script:FormEdges.Capture()
    $script:BottomEdges.Capture()
}
$list.Columns[0].Width = [int](240*$UiScale)
$list.Columns[1].Width = [int](150*$UiScale)
$list.Columns[3].Width = [int](140*$UiScale)
Update-ListColumns
# The region list gets exactly its rows + one spare (it's the only part that stretches), and the window never ends up
# bigger than the screen it opens on - whatever the resolution or Windows' scale setting.
try {
    $null = $list.Handle
    $r0 = $list.GetItemRect(0)
    $rowH = $r0.Height
    $script:ListRowH = $rowH
    $script:ListHeadH = $r0.Top   # scrolled to the top here: Top = the header
    $want = $r0.Top + ($list.Items.Count+1)*$rowH + $listFrame.Padding.Vertical
    if ($listFrame.Height -gt $want) { $form.Height -= ($listFrame.Height-$want) }
    # where it opens: last time's place, or the mouse
    $wa = [System.Windows.Forms.Screen]::FromPoint($OpenAt).WorkingArea
    Set-WindowFit $wa -SetMinimum
} catch {
    Write-Log "Fitting the window to the list failed: $($_.Exception.Message)"
}
Set-WindowLayout
# Position/size from last time - only if at least part of it is still on one of the screens (monitor unplugged,
# resolution changed...); otherwise the fitted, centered default above.
try {
    if ($script:WinState -match '^(-?\d+),(-?\d+),(\d+),(\d+),([01])$') {
        # saved at another display scale: the same size on screen (no scale saved: 100 %)
        $k = (96*$DpiScale)/$(if ($script:WinDpi) { $script:WinDpi } else { 96 })
        $rect = [System.Drawing.Rectangle]::new([int]$matches[1],[int]$matches[2],[int]([int]$matches[3]*$k),
            [int]([int]$matches[4]*$k))
        $max = ($matches[5] -eq '1')
        $on = $false
        foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
            $i = [System.Drawing.Rectangle]::Intersect($s.WorkingArea,$rect)
            if ($i.Width -ge 160 -and $i.Height -ge 100) { $on = $true }
        }
        if ($on) {
            # fit the screen it's on (resolution may have dropped)
            $sa = [System.Windows.Forms.Screen]::FromRectangle($rect).WorkingArea
            $w = [Math]::Min([Math]::Max($rect.Width,$form.MinimumSize.Width),$sa.Width)
            $h = [Math]::Min([Math]::Max($rect.Height,$form.MinimumSize.Height),$sa.Height)
            $x = [Math]::Min([Math]::Max($rect.X,$sa.Left),$sa.Right-$w)
            $y = [Math]::Min([Math]::Max($rect.Y,$sa.Top),$sa.Bottom-$h)
            $form.StartPosition = 'Manual'
            $form.Bounds = [System.Drawing.Rectangle]::new($x,$y,$w,$h)
            if ($max) { $form.WindowState = 'Maximized' }
        }
    }
} catch {
    Write-Log "The saved window position couldn't be used: $($_.Exception.Message)"
}
# ---------------- display scale changes ----------------
# Moved to a screen with another scale (Windows says so with WM_DPICHANGED), or opened on a screen other than the one
# the layout was made for: fonts, layout, list columns and the hand-drawn parts are rescaled, Windows' suggested size
# is taken. WinForms (.NET Framework) does none of this itself.
function Get-ScaledFont {
    param($Font,[double]$K,[hashtable]$Map)   # fonts that are equal stay one font
    if (-not $Font) { return $Font }
    if (-not $Map.ContainsKey($Font)) {
        $Map[$Font] = New-Object System.Drawing.Font($Font.FontFamily,[float]($Font.Size*$K),$Font.Style,$Font.Unit)
    }
    return $Map[$Font]
}
function Set-FormDpiScale {
    param($F,[double]$K,[hashtable]$Map)   # one window: every control's font and its layout, times $K
    $all = New-Object System.Collections.Generic.List[object]
    $todo = New-Object System.Collections.Stack
    $todo.Push($F)
    while ($todo.Count) {
        $c = $todo.Pop()
        $all.Add($c)
        foreach ($x in $c.Controls) { $todo.Push($x) }
    }
    $fonts = @(foreach ($c in $all) { $c.Font })   # all read first: a parent's new font would show up in its children
    for ($i = 0; $i -lt $all.Count; $i++) { $all[$i].Font = Get-ScaledFont $fonts[$i] $K $Map }
    $F.Scale([System.Drawing.SizeF]::new($K,$K))
}
function Update-UiDpi {
    param([int]$Dpi,[System.Drawing.Rectangle]$Suggested = [System.Drawing.Rectangle]::Empty)
    $old = [int][Math]::Round($DpiScale*96)
    if ($Dpi -le 0 -or $Dpi -eq $old) { return }
    $k = $Dpi/$old
    $bh0 = $bottom.Height   # the part below the list, in the old scale
    $script:DpiScale = $Dpi/96.0
    $script:FontScale = $script:DpiScale*96/$SysDpi
    $script:UiScale = 1.27*$script:DpiScale
    $map = @{}
    $min = $form.MinimumSize
    $form.MinimumSize = [System.Drawing.Size]::Empty   # scaling down would bump into it
    $form.SuspendLayout()
    foreach ($e in $script:FormEdges,$script:BottomEdges) { $e.Paused = $true }
    try {
        Set-FormDpiScale $form $k $map
        foreach ($m in @($optMenu,$copyMenu,$menu,$trayMenu,$miTrayOpen)) { $m.Font = Get-ScaledFont $m.Font $k $map }
        foreach ($v in 'fSemi','fBtn','fCaption','fMono','fMonoBold','fInfo','fInfoBold','fFootText',
            'fFootTag','fTitle','fCon') {
            $font = Get-Variable -Scope Script -Name $v -ValueOnly
            Set-Variable -Scope Script -Name $v -Value (Get-ScaledFont $font $k $map)
        }
        $script:fRow = $null   # made again from the list's new font (Update-ListStyle)
        $script:fStatusBold = $null
        foreach ($i in 0,1,3) { $list.Columns[$i].Width = [int][Math]::Round($list.Columns[$i].Width*$k) }
        $script:StatusIndent = Get-Px 10
        $script:ListRowH = [int][Math]::Round($script:ListRowH*$k)
        $script:ListHeadH = [int][Math]::Round($script:ListHeadH*$k)
    } finally {
        $form.ResumeLayout()
        # the edges are followed from the rescaled layout on
        foreach ($e in $script:FormEdges,$script:BottomEdges) {
            $e.Capture()
            $e.Paused = $false
        }
    }
    $form.MinimumSize = [System.Drawing.Size]::new([int]($min.Width*$k),[int]($min.Height*$k))
    if (-not $Suggested.IsEmpty) { $form.Bounds = $Suggested }
    # The part below the list keeps its height at the new scale and the list takes the rest (at least a row); then
    # everything is placed from the design numbers - positions WinForms rescaled one by one aren't trusted.
    $ch = $form.ClientSize.Height
    $bh = [Math]::Max(0,[Math]::Min([int][Math]::Round($bh0*$k),
        $ch-[int](42*$script:UiScale)-$script:ListHeadH-$script:ListRowH-$listFrame.Padding.Vertical))
    $bottom.Top = $ch-$bh
    Set-WindowLayout
    if ($form.WindowState -eq 'Normal') {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        Set-WindowFit $wa -SetMinimum
        # kept on the screen (the window grew or shrank around its top left corner)
        $form.Location = [System.Drawing.Point]::new([Math]::Max($wa.Left,
            [Math]::Min($form.Left,$wa.Right-$form.Width)),
            [Math]::Max($wa.Top,[Math]::Min($form.Top,$wa.Bottom-$form.Height)))
    }
    Set-WindowLayout
    $script:ListPaint.Scale = $script:DpiScale
    try { $script:ListRowH = $list.GetItemRect($list.TopItem.Index).Height } catch {}
    Update-ListColumns
    Update-ListStyle $script:ListSteer
    foreach ($b in $lblSteer,$lblMatch,$lblDbd,$lblNext) { Show-InfoText $b }
    if ($script:StatusText) {
        $st = $script:StatusText
        $script:StatusText = $null
        Set-Status $st $script:StatusColor
    }
    Show-UpdateNotice
    $list.Invalidate($true)
    Write-Log ("Display scale: {0} % (the window is on a screen with another scale)" -f [int]($script:DpiScale*100))
}
if ('DpiWatcher' -as [type]) {
    $script:DpiWatch = New-Object DpiWatcher($form)
    $script:DpiWatch.Add_Changed({
        param($s,$e)
        try {
            Update-UiDpi $e.Dpi $e.Suggested
        } catch {
            Write-Log "Display scale change failed: $($_.Exception.Message)"
        }
    })
}
# Opens invisible: Windows would otherwise show every button and box white for ~0.2 s while the start-up work above
# runs, before their first dark paint. Shown (above) makes it visible once all is painted.
$form.Opacity = 0
[System.Windows.Forms.Application]::Run($form)   # not ShowDialog: hiding a modal window ends it (tray)
[DbdEtw]::Stop()
# An error out here would reach the start-up trap and show "could not start"; Windows frees the mutex on exit anyway.
try { $script:Mutex.ReleaseMutex() } catch {}
