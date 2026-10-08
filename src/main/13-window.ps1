# ---------------- UI ----------------
# The screen the window opens on: where it was last time, if that's still on a screen; else the one with the mouse.
# Everything below is made at that screen's scale (a window rescaled after it's built loses the fitting further down).
$OpenAt = [System.Windows.Forms.Cursor]::Position
if ($script:WinState -match '^(-?\d+),(-?\d+),(\d+),(\d+),([01])$') {
    $r = [System.Drawing.Rectangle]::new([int]$matches[1],[int]$matches[2],[int]$matches[3],[int]$matches[4])
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $i = [System.Drawing.Rectangle]::Intersect($s.WorkingArea,$r)
        if ($i.Width -ge 160 -and $i.Height -ge 100) {
            $OpenAt = [System.Drawing.Point]::new($i.X+[int]($i.Width/2),$i.Y+[int]($i.Height/2))
            break
        }
    }
}
if ('DpiInfo' -as [type]) {
    $DpiScale = [DpiInfo]::ForPoint($OpenAt.X,$OpenAt.Y)/96.0
    $FontScale = $DpiScale*96/$SysDpi
}
$aAll = [System.Windows.Forms.AnchorStyles]'Top, Bottom, Left, Right'
$aBL = [System.Windows.Forms.AnchorStyles]'Bottom, Left'
$aBR = [System.Windows.Forms.AnchorStyles]'Bottom, Right'
$aBLR = [System.Windows.Forms.AnchorStyles]'Bottom, Left, Right'
$aTL = [System.Windows.Forms.AnchorStyles]'Top, Left'
$aTR = [System.Windows.Forms.AnchorStyles]'Top, Right'
$aTLR = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
$cOk = [System.Drawing.Color]::FromArgb(150,200,150)
$cWarn = [System.Drawing.Color]::FromArgb(220,200,120)
$cErr = [System.Drawing.Color]::FromArgb(230,120,120)
$cDim = [System.Drawing.Color]::FromArgb(170,170,180)
$cText = [System.Drawing.Color]::FromArgb(215,215,222)

# Layout in design pixels (100 %, 8.25-pt units; scaled once the window is built): a 684 px wide client area, 12 px
# margins, 8 px between the parts from top to bottom, 6 px between buttons side by side.
$DesignClientW = 684
$form = [System.Windows.Forms.Form]@{
    Text = $WindowTitle
    ClientSize = [System.Drawing.Size]::new($DesignClientW,731)
    StartPosition = 'CenterScreen'
    BackColor = [System.Drawing.Color]::FromArgb(28,28,32)
    ForeColor = [System.Drawing.Color]::White
}
# Palette. Light green is the accent (no blue anywhere). List and activity box sit in 1-px dark frames (their own
# borders and grid lines are always drawn light by Windows).
$cAccent = [System.Drawing.Color]::FromArgb(140,225,150)
$cFrame = [System.Drawing.Color]::FromArgb(70,70,78)
$cPanel = [System.Drawing.Color]::FromArgb(36,36,42)
$cAmericas = [System.Drawing.Color]::FromArgb(125,215,140)   # continent dots in the list
$cEurope = [System.Drawing.Color]::FromArgb(245,125,175)
$cAsia = [System.Drawing.Color]::FromArgb(255,170,80)
# Category colors (status card captions and each row's key value): configuration, network (also: where you landed),
# measurement, timer / clock (also the clock option).
$cCfg = $cAccent
$cNet = [System.Drawing.Color]::FromArgb(255,170,80)
$cLanded = $cNet
$cMeas = [System.Drawing.Color]::FromArgb(235,205,90)
$cClockCat = [System.Drawing.Color]::FromArgb(215,125,215)
$fSemi = New-UiFont 'Segoe UI Semibold' 10.5
$fBtn = New-UiFont 'Segoe UI' 10.5 Bold
$fCaption = New-UiFont 'Segoe UI Semibold' 9
$fTitle = New-UiFont 'Segoe UI' 9.5 Bold
# Header row: section caption and the continent legend on the left, window options on the right.
$lblRegions = [System.Windows.Forms.Label]@{
    Location = '12,8'
    Size = '70,26'
    Anchor = $aTL
    ForeColor = [System.Drawing.Color]::White
    Font = $fTitle
    Text = 'REGIONS'
    TextAlign = 'MiddleLeft'
}
$legend = @(foreach ($l in @(@(84,70,'Americas',$cAmericas),@(156,60,'Europe',$cEurope),
    @(218,86,'Asia-Pacific',$cAsia))) {
    [System.Windows.Forms.Label]@{
        Location = "$($l[0]),8"
        Size = "$($l[1]),26"
        Anchor = $aTL
        ForeColor = $l[3]
        Font = $fCaption
        Text = ([string][char]0x25CF + ' ' + $l[2])
        TextAlign = 'MiddleLeft'
    }
})
$btnOptions = [System.Windows.Forms.Button]@{
    Text = ('Options ' + [char]0x25BE)
    Location = '446,8'
    Size = '112,26'
    Anchor = $aTR
}
$btnConsole = [System.Windows.Forms.Button]@{
    Text = '>_  Console'
    Location = '564,8'
    Size = '108,26'
    Anchor = $aTR
}
$listFrame = [System.Windows.Forms.Panel]@{
    Location = '12,42'
    Size = '660,270'
    Anchor = $aAll
    BackColor = $cFrame
    Padding = [System.Windows.Forms.Padding]::new(1)
}
function Get-RowColor {
    param([int]$Index)
    if ($Index % 2) { [System.Drawing.Color]::FromArgb(44,44,49) } else { [System.Drawing.Color]::FromArgb(36,36,40) }
}
$list = [System.Windows.Forms.ListView]@{
    Dock = 'Fill'
    BorderStyle = 'None'
    View = 'Details'
    FullRowSelect = $true
    GridLines = $false
    MultiSelect = $false
    HideSelection = $false
    BackColor = [System.Drawing.Color]::FromArgb(38,38,42)
    ForeColor = [System.Drawing.Color]::White
}
[void]$list.Columns.Add('Region',240)
[void]$list.Columns.Add('Code',150)
[void]$list.Columns.Add('Ping (ms)',130)
[void]$list.Columns.Add('Queue K / S',140)
# killer / survivor queue (deadbyqueue.com) shown before Ping; Ping keeps index 2 and fills the rest
$list.Columns[3].DisplayIndex = 2
# Dark column header and rows, drawn by DarkList and its header painter (src\native\UiPainting.cs), because Windows'
# own selection is a bright white bar in this dark list. Selected = dark green with an accent stripe on the left, the
# row under the mouse a little lighter; otherwise each cell's own colors (set by Update-ListStyle).
$cHeadBack = [System.Drawing.Color]::FromArgb(48,48,54)
$cGrid = [System.Drawing.Color]::FromArgb(70,70,78)
$cSelRow = [System.Drawing.Color]::FromArgb(40,82,54)
$script:ListPaint = New-Object DarkList($list,$cSelRow,$cAccent,$cHeadBack,$cGrid)
$script:ListPaint.Scale = $DpiScale
$script:ListPaint.ShowBars = $script:ShowBars
# kept in a variable: it stays attached for the window's life
$script:ListErase = New-Object ListEraseFix($list,$script:ListPaint)
# the Ping column fills the rest of the width (DarkList.FitColumns; also on every list resize)
function Update-ListColumns {
    $script:ListPaint.RowHeight = [int]$script:ListRowH
    $script:ListPaint.HeaderHeight = [int]$script:ListHeadH
    $script:ListPaint.FitColumns()
}
$script:ListPaint.FillColumn = 2
foreach ($r in $Regions) {
    $it = [System.Windows.Forms.ListViewItem]::new($r.Name)
    [void]$it.SubItems.Add($r.Code)
    [void]$it.SubItems.Add($NoValue)
    [void]$it.SubItems.Add($NoValue)
    $it.Tag = $r
    $it.BackColor = (Get-RowColor $list.Items.Count)
    $it.UseItemStyleForSubItems = $false
    [void]$list.Items.Add($it)
}
$listFrame.Controls.Add($list)
# List styling: the steered region in green bold with "(steered)", ping values colored by speed, fastest row tinted.
$fRow = $null
$fRowBold = $null
$script:ListSteer = '?'
$fMono = New-UiFont 'Consolas' 10.5
$fMonoBold = New-UiFont 'Consolas' 10.5 Bold
function Get-AreaColor {
    param([string]$Code)
    if ($Code -match '^(us|ca|sa)-') { $cAmericas } elseif ($Code -like 'eu-*') { $cEurope } else { $cAsia }
}
foreach ($it in $list.Items) { $it.SubItems[0].Tag = Get-AreaColor $it.Tag.Code }   # the continent dot DarkList draws

# Sorting: click a column header (up, down, back to the default order) or "Sort by ping". Remembered.
$ColNames = @('Region','Code','Ping (ms)','Queue K / S')
$RegionOrder = @($Regions | ForEach-Object { $_.Code })
if ($script:SortSpec -match '^(-1|[0-3]),([01])$') {
    $script:SortCol = [int]$matches[1]
    $script:SortDesc = ($matches[2] -eq '1')
} else {
    $script:SortCol = -1
    $script:SortDesc = $false
}
function Sort-RegionList {
    $sel = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag.Code } else { $script:PickCode }
    $col = $script:SortCol
    $desc = $script:SortDesc
    # A region without a ping result (or queue time) always sorts last; ties keep the default order.
    $key = switch ($col) {
        0 { { $_.Tag.Name } }
        1 { { $_.Tag.Code } }
        2 {
            {
                $v = $script:LastPings[$_.Tag.Code]
                if ($null -ne $v) { $v } elseif ($desc) { -1 } else { [int]::MaxValue }
            }
        }
        3 {
            # by killer queue; offline / unknown last
            {
                $q = Get-QueueSec $_.Tag.Code
                if ($null -ne $q) { $q[0] } elseif ($desc) { -1 } else { [int]::MaxValue }
            }
        }
        default { { [array]::IndexOf($RegionOrder,$_.Tag.Code) } }
    }
    $items = @($list.Items | ForEach-Object { $_ })
    $byKey = @{ Expression = $key; Descending = ($desc -and $col -ge 0) }
    $byDefault = @{ Expression = { [array]::IndexOf($RegionOrder,$_.Tag.Code) } }
    $sorted = @($items | Sort-Object -Property $byKey,$byDefault)
    $list.BeginUpdate()
    $list.Items.Clear()
    $list.Items.AddRange([System.Windows.Forms.ListViewItem[]]$sorted)
    foreach ($it in $list.Items) {
        if ($it.Tag.Code -eq $sel) {
            $it.Selected = $true
            $it.EnsureVisible()
        }
    }
    $list.EndUpdate()
    for ($i = 0;$i -lt 4;$i++) {
        $arrow = if ($desc) { 0x25BC } else { 0x25B2 }
        $list.Columns[$i].Text = $ColNames[$i] + $(if ($i -eq $col) { ' ' + [char]$arrow } else { '' })
    }
    $script:SortSyncing = $true
    $miSort.Checked = ($col -eq 2 -and -not $desc)
    $script:SortSyncing = $false
    $script:SortSpec = "$col,$([int]$desc)"
    Update-ListStyle $script:ListSteer
}
$list.Add_ColumnClick({
    param($s,$e)
    # first click: up, second: down, third: back to the default order
    if ($script:SortCol -ne $e.Column) {
        $script:SortCol = $e.Column
        $script:SortDesc = $false
    } elseif (-not $script:SortDesc) {
        $script:SortDesc = $true
    } else {
        $script:SortCol = -1
        $script:SortDesc = $false
    }
    Sort-RegionList
    Save-State
})
function Get-PingColor {
    param($Ms)
    if ($null -eq $Ms) { return [System.Drawing.Color]::FromArgb(200,110,110) }
    $rgb = if ($Ms -lt 80) {
        120,215,130
    } elseif ($Ms -lt 150) {
        205,215,115
    } elseif ($Ms -lt 250) {
        235,170,90
    } else {
        235,115,110
    }
    [System.Drawing.Color]::FromArgb($rgb[0],$rgb[1],$rgb[2])
}
function Update-ListStyle {
    param([string]$SteerCode)
    if (-not $fRow) {
        $script:fRow = $list.Font
        $script:fRowBold = New-Object System.Drawing.Font($list.Font,[System.Drawing.FontStyle]::Bold)
    }
    $best = $null
    foreach ($it in $list.Items) {
        $v = $script:LastPings[$it.Tag.Code]
        if ($null -ne $v -and ($null -eq $best -or $v -lt $best)) { $best = $v }
    }
    # Only what actually changed is set: every color / font / text set repaints, and EndUpdate repaints the whole list.
    $script:ListTouched = $false
    foreach ($it in $list.Items) {
        $steered = ($SteerCode -and $it.Tag.Code -eq $SteerCode)
        $off = Test-RegionOffline $it.Tag.Code
        $name = if ($steered) { "$($it.Tag.Name)   (steered)" } else { $it.Tag.Name }
        if ($it.Text -cne $name) {
            Start-ListUpdate
            $it.Text = $name
        }
        $fc = if ($off) {
            [System.Drawing.Color]::FromArgb(205,120,115)
        } elseif ($steered) {
            [System.Drawing.Color]::FromArgb(130,220,140)
        } else {
            [System.Drawing.Color]::White
        }
        Set-SubItemStyle $it.SubItems[0] $fc $(if ($steered) { $fRowBold } else { $fRow })
        Set-SubItemStyle $it.SubItems[1] $(if ($steered) { $fc } else { $cDim }) $fMono
        $v = $script:LastPings[$it.Tag.Code]
        $pt = $it.SubItems[2].Text
        $pingColor = if ($pt -eq $NoValue -or $pt -eq $Ell) { $cDim } else { Get-PingColor $v }
        $pingFont = if ($null -ne $v -and $v -eq $best) { $fMonoBold } else { $fMono }
        Set-SubItemStyle $it.SubItems[2] $pingColor $pingFont
        $q = Get-QueueSec $it.Tag.Code
        $qt = if ($off) {
            'offline'
        } elseif ($null -ne $q) {
            "{0} / {1}" -f (Format-Queue $q[0]),(Format-Queue $q[1])
        } else {
            $NoValue
        }
        if ($it.SubItems[3].Text -cne $qt) {
            Start-ListUpdate
            $it.SubItems[3].Text = $qt
        }
        $queueColor = if ($off) {
            [System.Drawing.Color]::FromArgb(205,120,115)
        } elseif ($null -ne $q) {
            $cText
        } else {
            $cDim
        }
        Set-SubItemStyle $it.SubItems[3] $queueColor $fMono
        $bg = if ($null -ne $v -and $v -eq $best) {
            [System.Drawing.Color]::FromArgb(34,58,40)
        } else {
            Get-RowColor $it.Index
        }
        foreach ($s in $it.SubItems) {
            if ($s.BackColor -ne $bg) {
                Start-ListUpdate
                $s.BackColor = $bg
            }
        }
    }
    if ($script:ListTouched) { $list.EndUpdate() }
}
function Start-ListUpdate {
    # the first change pauses painting until Update-ListStyle is done
    if (-not $script:ListTouched) {
        $script:ListTouched = $true
        $list.BeginUpdate()
    }
}
function Set-SubItemStyle {
    param($Sub,$Fore,$Font)
    if ($Sub.ForeColor -ne $Fore) {
        Start-ListUpdate
        $Sub.ForeColor = $Fore
    }
    if (-not [object]::ReferenceEquals($Sub.Font,$Font)) {
        Start-ListUpdate
        $Sub.Font = $Font
    }
}

# Status card: caption on the left, value on the right.
$infoPanel = [System.Windows.Forms.Panel]@{ Location = '12,320'; Size = '660,90'; Anchor = $aBLR; BackColor = $cPanel }
# Thin bar at the bottom of the card: how far DBD's 10-min re-measure window has come (green = DBD can re-measure,
# amber = the PC clock is ahead right now). Hidden when there's nothing to show.
$gateBar = [System.Windows.Forms.Panel]@{
    Location = '10,85'
    Size = '640,3'
    Anchor = $aTLR
    BackColor = $cPanel
}
$script:Gate = New-Object GateBar($gateBar)   # drawn in src\native\UiPainting.cs; set by the update loop
$infoPanel.Controls.Add($gateBar)
function New-InfoRow {
    param([int]$Y,[string]$Caption,$CapColor)
    $c = [System.Windows.Forms.Label]@{
        Location = "10,$Y"
        Size = '108,20'
        ForeColor = $CapColor
        Font = $fCaption
        Text = $Caption.ToUpper()
    }
    $dot = [System.Windows.Forms.Label]@{
        Location = "118,$Y"
        Size = '16,20'
        ForeColor = $cDim
        Text = [string][char]0x25CF
    }
    # Value: a borderless read-only text field, so it can be selected and copied (right-click: Copy / Copy all).
    $v = New-Object System.Windows.Forms.RichTextBox
    $v.Location = [System.Drawing.Point]::new(134,$Y+2)
    # wider than any window: its panel cuts it off (InfoRow: a resize doesn't move it)
    $v.Size = [System.Drawing.Size]::new(3000,18)
    $v.Anchor = $aTL
    $v.ReadOnly = $true
    $v.BorderStyle = 'None'
    $v.BackColor = $cPanel
    $v.ForeColor = $cText
    $v.Multiline = $false
    $v.WordWrap = $false
    $v.ScrollBars = 'None'
    $v.DetectUrls = $false
    $v.TabStop = $false
    $v.Text = '-'
    $v.Font = New-UiFont 'Segoe UI' 10.5
    # InfoRow re-fits it on resizes
    $v.Tag = @{ Cap = $c; Dot = $dot; Key = ''; Full = '-'; Row = (New-Object InfoRow($v)) }
    # Ctrl+C with everything selected copies the whole row, also the part cut off by "..."
    $v.Add_KeyDown({
        param($s,$e)
        if ($e.Control -and $e.KeyCode -eq 'C' -and $s.SelectionLength -ge $s.TextLength) {
            Copy-Text (Get-InfoText $s)
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }
    })
    $infoPanel.Controls.Add($c)
    $infoPanel.Controls.Add($dot)
    $infoPanel.Controls.Add($v)
    return $v
}
$fInfo = New-UiFont 'Segoe UI' 10.5
$fInfoBold = New-UiFont 'Segoe UI' 10.5 Bold
function Set-Info {
    # One status row: $Parts = @( @(text, color, bold), ... ); $State = the status dot's color. Not redrawn when
    # unchanged, and not while you have text selected in it (so copying isn't interrupted).
    param($Box,[object[]]$Parts,$State = $cDim)
    if ($Box.IsDisposed) { return }
    $Box.Tag.Dot.ForeColor = $State
    if ($Box.Focused -and $Box.SelectionLength -gt 0) { return }
    $key = ($Parts | ForEach-Object { "$($_[0])|$($_[1])|$($_[2])" }) -join '#'
    if ($Box.Tag.Key -eq $key) { return }
    $Box.Tag.Key = $key
    $texts = [string[]]@($Parts | ForEach-Object { Format-UiText ([string]$_[0]) })
    $Box.Tag.Full = -join $texts
    $Box.Tag.Row.Full = $Box.Tag.Full   # its tooltip while the row ends in "..."
    Set-InfoStyle
    $colors = [System.Drawing.Color[]]@($Parts | ForEach-Object { $_[1] })
    $bold = [bool[]]@($Parts | ForEach-Object { [bool]$_[2] })
    $Box.Tag.Row.Set($texts,$colors,$bold)
}
# the status rows' fonts and spacing (InfoRow in src\native\UiPainting.cs), also after a display scale change
function Set-InfoStyle {
    [InfoRow]::Normal = $script:fInfo
    [InfoRow]::Bold = $script:fInfoBold
    [InfoRow]::Dim = $cDim
    [InfoRow]::Pad = [int](8*$UiScale)
    [InfoRow]::Margin = [int](8*$UiScale)   # room left free at the card's right edge
    [InfoRow]::Tip = $tips
}
function Show-InfoText {
    # Writes a status row again in full: when the window is too narrow for it, the row ends in "..." after the last
    # character that fits (the tooltip and Copy keep the whole row).
    param($Box)
    Set-InfoStyle
    $Box.Tag.Row.Show()
}
function Get-InfoText {
    # the whole row, also when it shows "..."
    param($Box)
    if ($Box.Tag -is [hashtable] -and $null -ne $Box.Tag.Full) { $Box.Tag.Full } else { $Box.Text }
}
function Show-RoundInfo {
    param($R)
    $open = if ($R.Open.Count -eq 0) {
        'none'
    } elseif ($R.Open.Count -le 2) {
        (@($R.Open | ForEach-Object { "$_ $(Get-PickName $_)" })) -join ', '
    } else {
        $R.Open -join ', '
    }
    $pingKind = if ($R.Http) { 'HTTP' } else { 'UDP' }
    $parts = @(
        @($R.StartUtc.ToLocalTime().ToString('HH:mm:ss'),$cText,$false),
        @('  reachable: ',$cDim,$false),
        @($open,$cMeas,$true),
        @(("   |   {0} unreachable   |   {1} pings" -f $R.Blocked.Count,$pingKind),$cDim,$false))
    if ($null -ne $R.GapSec) { $parts += ,@(("   |   {0:N0} s after the previous one" -f $R.GapSec),$cDim,$false) }
    # Dot: green = only the steered region was reachable; amber = the steering didn't hold, or nothing was reachable;
    # neutral without steering (several regions reachable is normal then).
    $steer = if ($script:CurSteer) { $script:CurSteer.Code } else { $null }
    $state = if ($R.Open.Count -eq 0 -or ($steer -and -not ($R.Open.Count -eq 1 -and $R.Open[0] -eq $steer))) {
        $cWarn
    } elseif ($steer) {
        $cOk
    } else {
        $cDim
    }
    Set-Info $lblDbd $parts $state
}
$tips = New-Object System.Windows.Forms.ToolTip
$tips.AutoPopDelay = 20000
$tips.InitialDelay = 400
# Dark tooltips (Windows draws them light), wrapped at ~460 px (at 100 %).
$tips.OwnerDraw = $true
$tipFlags = [System.Windows.Forms.TextFormatFlags]'WordBreak, NoPrefix'
$tips.Add_Popup({
    param($s,$e)
    $txt = Format-UiText $tips.GetToolTip($e.AssociatedControl)
    if (-not $txt) { return }
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($txt,$form.Font,
        [System.Drawing.Size]::new((Get-Px 460),0),$tipFlags)
    $e.ToolTipSize = [System.Drawing.Size]::new($sz.Width+(Get-Px 18),$sz.Height+(Get-Px 12))
})
$tips.Add_Draw({
    param($s,$e)
    $bb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40,40,46))
    $e.Graphics.FillRectangle($bb,$e.Bounds)
    $bb.Dispose()
    $pp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(95,95,105))
    $e.Graphics.DrawRectangle($pp,0,0,$e.Bounds.Width-1,$e.Bounds.Height-1)
    $pp.Dispose()
    $r = [System.Drawing.Rectangle]::new((Get-Px 9),(Get-Px 6),$e.Bounds.Width-(Get-Px 18),$e.Bounds.Height-(Get-Px 12))
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics,(Format-UiText $e.ToolTipText),$form.Font,
        $r,$cText,$tipFlags)
})
$lblSteer = New-InfoRow 4 'Steering' $cCfg
$lblMatch = New-InfoRow 24 'Game server' $cNet
$lblDbd = New-InfoRow 44 'DBD measured' $cMeas
$lblNext = New-InfoRow 64 'Re-measure' $cClockCat
Set-Info $lblDbd @(,@('nothing seen yet',$cDim,$false)) $cDim
# What each row means, on its caption.
$tips.SetToolTip($lblSteer.Tag.Cap,
    'The region this tool''s block in the hosts file steers DBD to, and whether DBD is running.')
$tips.SetToolTip($lblMatch.Tag.Cap,
    ('The server of your lobby, match or end game chat: its address, its traffic and the region it''s in (from ' +
    'Amazon''s list of its server addresses; Amazon EC2 = Amazon''s cloud servers).'))
$tips.SetToolTip($lblDbd.Tag.Cap,
    ('DBD pings every region to find the ones it can reach, at launch and when it reloads after a connection error. ' +
    'Only those can be picked for your lobbies.'))
$tips.SetToolTip($lblNext.Tag.Cap,
    'DBD measures again at most every 10 min. A Switch (no restart) waits for that, or uses the clock option.')

$statusFrame = [System.Windows.Forms.Panel]@{
    Location = '12,502'
    Size = '660,189'
    Anchor = $aBLR
    BackColor = $cFrame
    Padding = [System.Windows.Forms.Padding]::new(1)
}
$status = [System.Windows.Forms.RichTextBox]@{
    Dock = 'Fill'
    ReadOnly = $true
    ScrollBars = 'Vertical'
    DetectUrls = $false
    Font = (New-UiFont 'Segoe UI' 11.5)
    BackColor = [System.Drawing.Color]::FromArgb(18,18,20)
    ForeColor = $cText
    BorderStyle = 'None'
}
$statusFrame.Controls.Add($status)
# Footer: the version and the signature, bottom right - "# root" as a root shell prompt, in a small terminal-style tag.
$footer = [System.Windows.Forms.Panel]@{
    Location = '12,699'
    Size = '660,20'
    Anchor = $aBLR
    BackColor = [System.Drawing.Color]::FromArgb(28,28,32)
}
$fFootText = New-UiFont 'Segoe UI' 9.5
$fFootTag = New-UiFont 'Consolas' 10 Bold
# Drawn by FooterView (src\native\UiPainting.cs) from the right edge; a newer version on GitHub (Options > Check for
# updates) shows on the left and opens its page when clicked.
$script:Foot = New-Object FooterView($footer)
# The support links right of the signature: Ko-fi and Buy Me a Coffee, in the order of FooterView.Icons, with their own
# logos (their brand assets: storage.ko-fi.com/cdn/brandasset/kofi_s_logo_nolabel.png, and bmc-logo-yellow.png from
# Buy Me a Coffee's brand kit) - 64 px PNGs in src\ that tools\build.ps1 writes in below.
$SupportLinks = @(
    @{ Url = 'https://ko-fi.com/010root'; Tip = 'Support me' },
    @{ Url = 'https://buymeacoffee.com/010root'; Tip = 'Buy me a coffee' }
)
$LogoKofi = @'
@include-base64 logo-kofi.png
'@
$LogoBmc = @'
@include-base64 logo-bmc.png
'@
$i = 0
foreach ($b64 in $LogoKofi,$LogoBmc) {   # a copy: GDI+ keeps reading the stream of a bitmap made from one
    $ms = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String(($b64 -replace '\s','')))
    $png = New-Object System.Drawing.Bitmap($ms)
    $script:Foot.IconImages[$i++] = New-Object System.Drawing.Bitmap($png)
    $png.Dispose()
    $ms.Dispose()
}
$script:Foot.Left = "v$ToolVersion   made by"
$script:Foot.Accent = $cAccent
function Show-UpdateNotice {   # also after a display scale change: fonts and spacing
    $script:Foot.TextFont = $script:fFootText
    $script:Foot.TagFont = $script:fFootTag
    $script:Foot.Sp = [int](5*$UiScale)
    $script:Foot.Notice = $null
    if ($script:UpdateAvail) { $script:Foot.Notice = "Version $($script:UpdateAvail) is out, click to open its page" }
    $footer.Invalidate()
}
$script:FootTip = -1
$footer.Add_MouseMove({   # after FooterView's own handler: Hover is current
    $h = $script:Foot.Hover
    if ($h -eq $script:FootTip) { return }
    $script:FootTip = $h
    $tips.SetToolTip($footer,$(if ($h -ge 0) { $SupportLinks[$h].Tip } else { '' }))
})
$footer.Add_MouseClick({
    param($s,$e)
    if ($e.Button -ne 'Left') { return }
    $url = $null
    if ($script:Foot.NoticeRect.Contains($e.Location)) { $url = "https://github.com/$ReleaseRepo/releases/latest" }
    for ($i = 0;$i -lt 2;$i++) { if ($script:Foot.Icons[$i].Contains($e.Location)) { $url = $SupportLinks[$i].Url } }
    if ($url) { try { Open-AsUser $url } catch { Set-Status "Couldn't open $url`: $($_.Exception.Message)" $cErr } }
})
# Header strip of the activity box: caption left, time of the last update right.
$actHead = [System.Windows.Forms.Panel]@{
    Dock = 'Top'
    Height = 22
    BackColor = $cPanel
    Padding = [System.Windows.Forms.Padding]::new(8,0,8,0)
}
$lblAct = [System.Windows.Forms.Label]@{
    Dock = 'Left'
    Width = 200
    ForeColor = [System.Drawing.Color]::White
    Font = $fTitle
    Text = 'ACTIVITY'
    TextAlign = 'MiddleLeft'
}
$lblActTime = [System.Windows.Forms.Label]@{
    Dock = 'Right'
    Width = 200
    ForeColor = $cDim
    Font = $fCaption
    Text = ''
    TextAlign = 'MiddleRight'
}
$actHead.Controls.Add($lblAct)
$actHead.Controls.Add($lblActTime)
$statusFrame.Controls.Add($actHead)
$status.BringToFront()
# A little room around the text, so a full line doesn't look cut off at the frame: a strip above it here, left / right
# indents in Set-Status. Docking goes from the last control to the first: header, strip, then the text.
$actGap = [System.Windows.Forms.Panel]@{ Dock = 'Top'; Height = 4; BackColor = $status.BackColor }
$statusFrame.Controls.Add($actGap)
$statusFrame.Controls.SetChildIndex($actGap,1)
$StatusIndent = Get-Px 10
function Set-Status {
    # Heading line bold in the message's color, "Label:" at the start of a line bold, "=>" lines bold amber.
    # RichTextBox stores line breaks as a single \n, so positions are taken from its own Text.
    param([string]$Text,$Color = $cText)
    if ($status.IsDisposed) { return }
    # unchanged: not rewritten, so no flicker or scroll jump
    if ($Text -ceq $script:StatusText -and $Color -eq $script:StatusColor) {
        [System.Windows.Forms.Application]::DoEvents()
        return
    }
    $script:StatusText = $Text
    $script:StatusColor = $Color
    $Text = Hide-ProfilePath (Format-UiText $Text)
    $Text = [regex]::Replace($Text,'(?m)^=> ',"$WarnMark ")   # the warning lines' marker, see below
    # one bold font, not one per update
    if (-not $script:fStatusBold) {
        $script:fStatusBold = New-Object System.Drawing.Font($status.Font,[System.Drawing.FontStyle]::Bold)
    }
    $redraw = $status.IsHandleCreated
    if ($redraw) { [DarkUi]::Redraw($status.Handle,$false) }   # no blinking on frequent updates
    $status.Text = $Text
    $rt = $status.Text
    $status.SelectAll()
    $status.SelectionColor = if ($Color -eq $cText) {
        $cText
    } else {
        [System.Windows.Forms.ControlPaint]::Light($Color,0.1)
    }
    $status.SelectionFont = $status.Font
    $status.SelectionIndent = $StatusIndent
    $status.SelectionRightIndent = $StatusIndent
    # short labels only (no commas): sentences never turn bold
    foreach ($m in [regex]::Matches($rt,'(?m)^([A-Z][A-Za-z0-9 ()+/.''-]{1,24}:)(?=\s)')) {
        $status.Select($m.Index,$m.Length)
        $status.SelectionFont = $script:fStatusBold
    }
    foreach ($m in [regex]::Matches($rt,"(?m)^$WarnMark.*$")) {
        $status.Select($m.Index,$m.Length)
        $status.SelectionFont = $script:fStatusBold
        $status.SelectionColor = $cWarn
    }
    $nlAt = $rt.IndexOf("`n")
    $head = if ($nlAt -gt 0) { $nlAt } else { $rt.Length }
    if ($head -gt 0) {
        $status.Select(0,$head)
        $status.SelectionFont = $script:fStatusBold
        $status.SelectionColor = if ($Color -eq $cText) { $cAccent } else { $Color }
    }
    $status.Select(0,0)
    if ($redraw) {
        [DarkUi]::Redraw($status.Handle,$true)
        $status.Invalidate()
    }
    # real time, also while the clock option has the PC clock ahead
    if ($lblActTime -and -not $lblActTime.IsDisposed) {
        $lblActTime.Text = 'updated ' + [DbdEtw]::UtcNow.ToLocalTime().ToString('HH:mm:ss')
    }
    [System.Windows.Forms.Application]::DoEvents()
}
$RegionNames = @{}
foreach ($r in $Regions) { $RegionNames[$r.Code] = $r.Name }
function Get-PickName {
    param([string]$Code)
    if ($Code -and $RegionNames.ContainsKey($Code)) { $RegionNames[$Code] } else { $Code }
}

# Button colors = what the action does to your system:
#   neutral slate = read-only (Ping, Details, Options)   green = low-impact write (Switch, no restart)
#   steel = revert (Remove Steering)   orange = kills + relaunches a process (Switch + Restart)
#   red = destructive (Repair Hosts overwrites the whole file)   gold = execute (Apply)   dark red = abort (Cancel)
$cBtnRead = [System.Drawing.Color]::FromArgb(60,64,74)
# Read-only buttons on the left; past a divider the four actions share the rest of the row equally (EvenRow, set up
# with the window). Under them: the Switch options on the left, Cancel and Apply on the right.
$btnPing = [System.Windows.Forms.Button]@{
    Text = 'Ping'
    Location = '12,418'
    Size = '70,34'
    Anchor = $aBL
    BackColor = $cBtnRead
}
$btnSwitch = [System.Windows.Forms.Button]@{
    Text = 'Switch (no restart)'
    Location = '88,418'
    Size = '142,34'
    Anchor = $aBL
    BackColor = [System.Drawing.Color]::FromArgb(36,150,88)
}
$btnRestart = [System.Windows.Forms.Button]@{
    Text = 'Switch + Restart'
    Location = '236,418'
    Size = '142,34'
    Anchor = $aBL
    BackColor = [System.Drawing.Color]::FromArgb(196,118,34)
}
$btnClear = [System.Windows.Forms.Button]@{
    Text = 'Remove Steering'
    Location = '384,418'
    Size = '142,34'
    Anchor = $aBL
    BackColor = [System.Drawing.Color]::FromArgb(84,92,104)
}
$btnRepair = [System.Windows.Forms.Button]@{
    Text = 'Repair Hosts'
    Location = '532,418'
    Size = '140,34'
    Anchor = $aBL
    BackColor = [System.Drawing.Color]::FromArgb(158,46,46)
}
$btnDetails = [System.Windows.Forms.Button]@{
    Text = 'Details'
    Location = '12,460'
    Size = '70,34'
    Anchor = $aBL
    BackColor = $cBtnRead
}
$btnSkip = [System.Windows.Forms.Button]@{
    Text = 'Cancel'
    Location = '352,460'
    Size = '110,34'
    Anchor = $aBR
    Visible = $false
    BackColor = [System.Drawing.Color]::FromArgb(128,52,52)
}
# gold with dark text: stands apart from everything else
$btnApply = [System.Windows.Forms.Button]@{
    Text = 'Apply'
    Location = '468,460'
    Size = '204,34'
    Anchor = $aBR
    Enabled = $false
    Visible = $false
    BackColor = [System.Drawing.Color]::FromArgb(226,182,44)
}
# Switch (no restart) options: under its button, shown only while that action is selected (Update-SwitchOptions), sized
# to their text side by side once the fonts are final (Update-OptionLayout).
$chkClock = [System.Windows.Forms.CheckBox]@{
    Text = 'Skip 10-min wait (clock)'
    Location = '90,465'
    Size = '176,24'
    Anchor = $aBL
    ForeColor = $cClockCat
    FlatStyle = 'Flat'
    Checked = $script:ClockOpt
    Visible = $false
}
$chkNgen = [System.Windows.Forms.CheckBox]@{
    Text = 'Fix mouse colors (NGENUITY)'
    Location = '278,465'
    Size = '196,24'
    Anchor = $aBL
    ForeColor = $cText
    FlatStyle = 'Flat'
    Checked = $script:NgenOpt
    Visible = $false
}
foreach ($c in $chkClock,$chkNgen) { [DarkCheck]::Attach($c) }
$divider = [System.Windows.Forms.Panel]@{
    Location = '85,420'
    Size = '1,72'
    Anchor = $aBL
    BackColor = [System.Drawing.Color]::FromArgb(78,80,90)
}
$allButtons = @($btnPing,$btnSwitch,$btnRestart,$btnClear,$btnRepair,$btnDetails,$btnSkip,$btnApply,
    $btnOptions,$btnConsole)
$cBorder = [System.Drawing.Color]::FromArgb(85,85,95)
$cSelBorder = [System.Drawing.Color]::FromArgb(250,210,90)
# Flat dark buttons (the system style ignores BackColor and stays light). Coloured ones keep their colour.
foreach ($b in $allButtons) {
    if ($b.BackColor -eq [System.Windows.Forms.Control]::DefaultBackColor -or $b.BackColor -eq $form.BackColor) {
        $b.BackColor = $cBtnRead
    }
    $b.FlatStyle = 'Flat'
    $b.ForeColor = [System.Drawing.Color]::White
    $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderColor = $cBorder
    $b.Font = if ($b -eq $btnOptions -or $b -eq $btnConsole) { $fCaption } else { $fBtn }
    $b.FlatAppearance.MouseOverBackColor = [System.Windows.Forms.ControlPaint]::Light($b.BackColor,0.25)
    $b.FlatAppearance.MouseDownBackColor = [System.Windows.Forms.ControlPaint]::Dark($b.BackColor,0.05)
}
# dark text on the gold button (a bit lighter than black)
$btnApply.ForeColor = [System.Drawing.Color]::FromArgb(64,54,30)

function Open-LogFolder {
    try { Open-AsUser $LogDir } catch { Set-Status "Couldn't open the log folder: $($_.Exception.Message)" $cErr }
}
# Options menu (all remembered).
$optMenu = New-Object System.Windows.Forms.ContextMenuStrip
$optMenu.Renderer = New-Object DarkMenuRenderer
$optMenu.ShowImageMargin = $false
$optMenu.ShowCheckMargin = $true
$optMenu.Font = $fSemi
$optMenu.ShowItemToolTips = $false   # Windows' own tooltips would be light
function Add-OptItem {
    param([string]$Text,[bool]$Checked,[scriptblock]$OnChange)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $mi.CheckOnClick = $true
    $mi.Checked = $Checked
    $mi.Add_CheckedChanged($OnChange)
    [void]$optMenu.Items.Add($mi)
    return $mi
}
# Fastest region first, re-sorted after every Ping (the column headers sort too: up, down, default).
$miSort = Add-OptItem 'Sort regions by ping' $false {
    if ($script:SortSyncing) { return }
    if ($miSort.Checked) {
        $script:SortCol = 2
        $script:SortDesc = $false
    } elseif ($script:SortCol -eq 2) {
        $script:SortCol = -1
        $script:SortDesc = $false
    }
    Sort-RegionList
    Save-State
}
$miBars = Add-OptItem 'Show ping bars' $script:ShowBars {
    $script:ShowBars = $miBars.Checked
    $script:ListPaint.ShowBars = $script:ShowBars
    $list.Invalidate()
    Save-State
}
$miAuto = Add-OptItem 'Ping all regions when the tool opens' $script:AutoPing {
    $script:AutoPing = $miAuto.Checked
    Save-State
}
$miTop = Add-OptItem 'Keep window on top' $script:OnTop {
    $script:OnTop = $miTop.Checked
    $form.TopMost = $miTop.Checked
    Save-State
}
# Queue column (killer / survivor wait) and "offline" for regions BHVR has ramped down, from deadbyqueue.com.
$miStatus = Add-OptItem 'Show region status and queue times (deadbyqueue.com)' $script:ShowStatus {
    $script:ShowStatus = $miStatus.Checked
    if (-not $script:ShowStatus) {
        $script:RegionOnline = @{}
        $script:QueueTimes = @{}
        $script:StatusOfflineTxt = $null
    } else {
        $script:StatusNextUtc = [DateTime]::MinValue
    }
    Update-ListStyle $script:ListSteer
    Save-State
}
$miClose = New-Object System.Windows.Forms.ToolStripMenuItem('When closing the window')
$miClose.DropDown.Renderer = $optMenu.Renderer
foreach ($c in @(@('ask','Ask me'),@('tray','Keep running in the system tray'),@('quit','Quit'))) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($c[1])
    $mi.Tag = $c[0]
    $mi.Checked = ($script:CloseTo -eq $c[0])
    $mi.Add_Click({
        param($s,$e)
        $script:CloseTo = $s.Tag
        foreach ($x in $miClose.DropDownItems) { $x.Checked = ($x.Tag -eq $script:CloseTo) }
        Save-State
    })
    [void]$miClose.DropDownItems.Add($mi)
}
[void]$optMenu.Items.Add($miClose)
$miLife = New-Object System.Windows.Forms.ToolStripMenuItem('Steering lasts')
$miLife.DropDown.Renderer = $optMenu.Renderer
foreach ($c in @(@('keep','Until you remove it (persistent)'),@('temp','Until DBD closes (temporary)'))) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($c[1])
    $mi.Tag = $c[0]
    $mi.Checked = ($script:SteerLife -eq $c[0])
    $mi.Add_Click({
        param($s,$e)
        if ($script:SteerLife -eq $s.Tag) { return }
        $script:SteerLife = $s.Tag
        foreach ($x in $miLife.DropDownItems) { $x.Checked = ($x.Tag -eq $script:SteerLife) }
        Save-State
        # steering in place with DBD running: removed when it closes
        $script:TempArmed = ($script:SteerLife -eq 'temp' -and [bool]$script:DbdPid -and
            [bool](Get-CurrentSteering).Code)
        $life = 'until you remove it (persistent)'
        if ($script:SteerLife -eq 'temp') { $life = 'until DBD closes (temporary)' }
        Write-Log "Steering lasts: $life"
        if ($script:Selected -and -not $script:Busy) { Select-Action $script:Selected }
    })
    [void]$miLife.DropDownItems.Add($mi)
}
[void]$optMenu.Items.Add($miLife)
$miUpd = Add-OptItem 'Check for updates (GitHub)' $script:UpdateCheck {
    $script:UpdateCheck = $miUpd.Checked
    if ($script:UpdateCheck) {
        $script:UpdateNextUtc = [DateTime]::MinValue
    } else {
        $script:UpdateAvail = $null
        Show-UpdateNotice
    }
    Save-State
}
[void]$optMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miUdp = New-Object System.Windows.Forms.ToolStripMenuItem('Check UDP monitoring...')
$miUdp.Add_Click({
    if ($script:Busy) { return }
    try { Repair-UdpMonitor -Manual } catch { Write-Log "UDP check failed: $($_.Exception.Message)" }
})
[void]$optMenu.Items.Add($miUdp)
$miLogs = New-Object System.Windows.Forms.ToolStripMenuItem('Open log folder')
$miLogs.ShortcutKeyDisplayString = 'Ctrl+L'
$miLogs.Add_Click({ Open-LogFolder })
[void]$optMenu.Items.Add($miLogs)
# Clicking Options again closes the menu: that click first closes it (outside click), then would reopen it - so a
# close caused by a click on the Options button itself is remembered and the reopen is skipped.
$optMenu.Add_Closing({
    param($s,$e)
    $script:OptClosedByButton = ($e.CloseReason -eq 'AppClicked' -and
        $btnOptions.RectangleToScreen($btnOptions.ClientRectangle).Contains([System.Windows.Forms.Cursor]::Position))
    $script:OptClosedAt = [DateTime]::UtcNow
})
$btnOptions.Add_Click({
    # a note older than a second is stale (the mouse was dragged off the button): ignored
    if ($script:OptClosedByButton) {
        $script:OptClosedByButton = $false
        if (([DateTime]::UtcNow-$script:OptClosedAt).TotalMilliseconds -lt 1000) { return }
    }
    if ($optMenu.Visible) {
        $optMenu.Close()
        return
    }
    # opens leftward: it's wider than the space to the window's right edge
    $optMenu.Show($btnOptions,[System.Drawing.Point]::new($btnOptions.Width,$btnOptions.Height),
        [System.Windows.Forms.ToolStripDropDownDirection]::BelowLeft)
})
# Shortcuts: F5 = Ping, Esc = Cancel (only while a Switch waits - never "DBD shows the error"), Ctrl+L = log folder.
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq 'F5' -and -not $script:Busy) {
        $btnPing.PerformClick()
        $e.Handled = $true
    } elseif ($e.KeyCode -eq 'Escape' -and $btnSkip.Visible -and $btnSkip.Text -eq 'Cancel') {
        $btnSkip.PerformClick()
        $e.Handled = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'L') {
        Open-LogFolder
        $e.Handled = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'K') {
        Show-Console
        $e.Handled = $true
    }
})
$tips.SetToolTip($btnOptions,'Settings (all remembered) and the log folder.')
$tips.SetToolTip($btnConsole,'Live log (Ctrl+K): everything the tool does, plus DBD''s DNS lookups.')
$btnConsole.Add_Click({ Show-Console })
