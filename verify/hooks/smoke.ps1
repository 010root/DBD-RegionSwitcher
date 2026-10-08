# Smoke test of the .exe build, spliced into a copy of the tool by verify\run-elevated.ps1 in place of its
# Application.Run line. Set before it: $SmokeDir (pictures and the hosts copy), $SmokeScreen, $SmokeToasts and
# $SmokeResult.
# A timer walks through the window every 2.5 s, then writes what it saw to $SmokeResult and closes the window.

function Save-Shot([string]$Name) {
    $bmp = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
    $form.TopMost = $true
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($form.Location,[System.Drawing.Point]::Empty,$form.Size)
    $g.Dispose()
    $form.TopMost = $script:OnTop
    $bmp.Save("$SmokeDir\$Name.png")
    $bmp.Dispose()
}
function Save-ToastShot([string]$Name) {
    # the bottom-right corner of the main screen, where Windows shows notifications
    $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tw = [int]($sb.Width * 0.32)
    $th = [int]($sb.Height * 0.3)
    $tb = New-Object System.Drawing.Bitmap($tw,$th)
    $tg = [System.Drawing.Graphics]::FromImage($tb)
    $tg.CopyFromScreen($sb.Right - $tw,$sb.Bottom - $th,0,0,$tb.Size)
    $tg.Dispose()
    if ($SmokeToasts) { $tb.Save("$SmokeDir\$Name.png") }
    $tb.Dispose()
}
function Wait-Ui([int]$Times,[int]$Ms) {
    for ($q = 0; $q -lt $Times; $q++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $Ms
    }
}

# The window opens on the test screen, not the main one.
$tsc = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like "*$SmokeScreen" })[0]
if ($tsc) {
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new($tsc.WorkingArea.X + 30,$tsc.WorkingArea.Y + 10)
}
if (-not $SmokeToasts) {
    # notifications not shown (Windows would show them on the main screen); their text is kept for the result
    function script:Show-TrayNote {
        param([string]$Text)
        $script:TrayNoteText = $Text
        if (-not $script:NoteIcon) { $script:NoteIcon = New-Object System.Drawing.Icon($script:AppIcon,64,64) }
    }
}
Add-Type @'
public static class KeyPost {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool PostMessage(System.IntPtr h, int m, System.IntPtr w, System.IntPtr l);
}
'@
function Send-TestKey([int]$Vk) {
    # straight to the window, not through the keyboard
    $h = if ($form.ActiveControl) { $form.ActiveControl.Handle } else { $form.Handle }
    [void][KeyPost]::PostMessage($h,0x100,[IntPtr]$Vk,[IntPtr]1)
    [void][KeyPost]::PostMessage($h,0x101,[IntPtr]$Vk,[IntPtr]0xC0000001)
}

function Step-Start {
    $script:CloseTo = 'quit'
    $script:FgAtStart = [WinHelp]::IsForeground($form.Handle)
    Save-Shot 'exe-start'
    $script:ApplyAtStart = $btnApply.Visible
    $script:OptsAtStart = $chkClock.Visible
    $list.Items[2].Selected = $true
    Select-Action 'Switch'
}
function Step-SwitchSelected {
    Save-Shot 'exe-switch-selected'
    $script:ApplyAfterSelect = $btnApply.Visible
    $script:OptsSwitch = "clock=$($chkClock.Visible) ngenuity=$($chkNgen.Visible) (installed=$NgenInstalled)"
    $btnDetails.PerformClick()
}
function Step-OptionsMenu {
    Save-Shot 'exe-details-after-switch'
    $script:ApplyAfterDetails = $btnApply.Visible
    $script:OptsDetails = $chkClock.Visible
    $btnOptions.PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    $miBars.Select()
    [System.Windows.Forms.Application]::DoEvents()
    Save-Shot 'exe-options-menu'
    $script:OptOpen = $optMenu.Visible
    $btnOptions.PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    $script:OptClosed = -not $optMenu.Visible
    $script:SelAfterDetails = "[$($script:Selected)] border=$($btnSwitch.FlatAppearance.BorderSize)"
}
function Step-SortAndConsole {
    # sample pings, sorted by ping; the Switch description with the clock option; the console
    $p = @{
        'us-east-1' = 58; 'us-east-2' = 74; 'us-west-1' = 121; 'us-west-2' = 133; 'ca-central-1' = 96
        'sa-east-1' = 148; 'eu-west-2' = 172; 'eu-west-1' = 165; 'eu-central-1' = 181; 'ap-northeast-1' = 241
        'ap-northeast-2' = 262; 'ap-south-1' = 301; 'ap-east-1' = 289; 'ap-southeast-1' = 318; 'ap-southeast-2' = $null
    }
    $script:LastPings = $p
    foreach ($it in $list.Items) {
        $v = $p[$it.Tag.Code]
        $it.SubItems[2].Text = if ($null -ne $v) { "$v" } else { 'timeout' }
    }
    $script:ListSteer = 'eu-central-1'
    Update-ListStyle 'eu-central-1'
    $script:SortCol = 2
    $script:SortDesc = $false
    Sort-RegionList
    $script:SortCheck = ("first=$($list.Items[0].Tag.Code) last=$($list.Items[$list.Items.Count-1].Tag.Code) " +
        "header=$($list.Columns[2].Text) option checked=$($miSort.Checked) menu " +
        "items=$($list.ContextMenuStrip.Items.Count)")
    $script:ClockOpt = $true
    Select-Action 'Switch'
    Set-Info $lblMatch @(
        @('63.178.121.87:7777',$cText,$false),
        @('  ~60 packets/s  ->  ',$cDim,$false),
        @('eu-central-1  EU (Frankfurt)',$cLanded,$true),
        @('  Amazon EC2',$cDim,$false),
        @('  = steered region',$cOk,$true)) $cOk
    $round = @{
        StartUtc = [DateTime]::UtcNow
        Open = @('eu-central-1')
        Blocked = @(1..14)
        Http = $false
        GapSec = 72
    }
    Show-RoundInfo $round
    Save-Shot 'exe-clock-describe'
    Show-Console
    Write-Log 'APPLY console test line'
    Wait-Ui 20 40
    $script:ConOk = ($script:ConBox -and $script:ConBox.Text -match 'APPLY console test line' -and
        $script:ConBox.Text -match 'Monitor self-test')
    $cb = $script:ConForm.Bounds
    $cbm = New-Object System.Drawing.Bitmap($cb.Width,$cb.Height)
    $cg = [System.Drawing.Graphics]::FromImage($cbm)
    $cg.CopyFromScreen($cb.Location,[System.Drawing.Point]::Empty,$cb.Size)
    $cg.Dispose()
    $cbm.Save("$SmokeDir\exe-console.png")
    $cbm.Dispose()
    $script:ConForm.Close()
    $script:ClockDescribe = ($status.Text -match 'clock on')
    $script:ClockOpt = $false
    Select-Action $null
}
function Step-TrayAndWait {
    $script:SortCol = -1
    Sort-RegionList
    Hide-ToTray
    Wait-Ui 10 30
    $script:TrayHid = (-not $form.Visible -and $tray.Visible)
    # The result notification, shown by the .exe itself (so Windows names it "DBD Region Switcher").
    Request-Attention 'Admin test run: a result notification - please ignore'
    Wait-Ui 60 30
    Save-ToastShot 'exe-toast'
    $script:NoteOk = ($null -ne $script:NoteIcon)
    Show-FromTray
    [System.Windows.Forms.Application]::DoEvents()
    $script:TrayBack = ($form.Visible -and -not $tray.Visible)
    # Close while waiting: a real Switch against a COPY of hosts and a stand-in DBD (this process). Apply blocks in its
    # wait loop; the next ticks press Esc, wait again and close the window from inside that loop.
    $global:HostsPath = "$SmokeDir\hosts-copy-smoke"
    $script:HostsPath = $global:HostsPath
    [IO.File]::Copy("$env:windir\System32\drivers\etc\hosts",$global:HostsPath,$true)
    function global:Get-DbdProcess { Get-Process -Id $PID }
    function script:Get-DbdProcess { Get-Process -Id $PID }
    Update-DbdPid
    Update-DbdActions
    $script:ClockOpt = $false
    $list.Items[5].Selected = $true
    Select-Action 'Switch'
    $btnApply.PerformClick()
}
function Step-CloseToTray {
    $script:CloseTo = 'tray'
    $form.Close()
    Wait-Ui 60 30
    # closing to the tray shows the "still running" notification
    Save-ToastShot 'exe-toast-tray'
    $script:ClosedToTray = (-not $form.Visible -and $tray.Visible)
    Show-FromTray
    $script:CloseTo = 'quit'
}
function Get-SmokeResult {
    $sw0 = [Diagnostics.Stopwatch]::StartNew()
    $xa = Get-XboxDbdApp '(?i)NGENUITY'
    $xaMs = $sw0.ElapsedMilliseconds
    @(
        "title=$($form.Text)"
        ("tray: hidden to tray=$($script:TrayHid) shown again=$($script:TrayBack) closed to tray with its " +
            "notification=$($script:ClosedToTray) close mode=$($script:CloseTo) notification with own " +
            "icon=$($script:NoteOk) (shown: $SmokeToasts; picture: exe-toast.png; text when not shown: " +
            "$($script:TrayNoteText))")
        ("region status (deadbyqueue.com): regions=$($script:RegionOnline.Count) " +
            "offline=$(@(Get-OfflineRegions) -join ' ') fresh=$(Test-StatusFresh) queues=$($script:QueueTimes.Count)")
        ("header: Options before Console=$($btnOptions.Left -lt $btnConsole.Left) (x $($btnOptions.Left) / " +
            "$($btnConsole.Left))")
        "self-test=$($script:EtwHealth.Text) ($($script:EtwHealth.Ms) ms)"
        ("status rows copyable=$($lblSteer -is [System.Windows.Forms.RichTextBox]) copy menu " +
            "items=$($copyMenu.Items.Count) console showed the line=$($script:ConOk)")
        ("Options menu: opened=$($script:OptOpen) second click closed it=$($script:OptClosed) " +
            "items=$($optMenu.Items.Count)")
        "Esc cancelled the waiting Switch=$($script:EscCancelled)"
        "options menu items=$($optMenu.Items.Count) bars=$($script:ShowBars) autoping=$($script:AutoPing)"
        "activity header=$($lblAct.Text.Trim()) / $($lblActTime.Text)"
        "apply text=$($btnApply.Text)"
        "sorted by ping: $($script:SortCheck)"
        "busy (Switch waiting) when the window was closed=$($script:Busy)"
        "focus taken on open=$($script:FocusOk) still in front 2.5 s later=$($script:FgAtStart)"
        "app folder=$AppDir"
        "icon set=$($null -ne $form.Icon)"
        "apply visible at start=$($script:ApplyAtStart)"
        "apply visible after selecting Switch=$($script:ApplyAfterSelect)"
        "apply visible after Details=$($script:ApplyAfterDetails)"
        "selection after Details=$($script:SelAfterDetails)"
        ("switch options visible: at start=$($script:OptsAtStart) / Switch selected: $($script:OptsSwitch) / after " +
            "Details=$($script:OptsDetails)")
        "form size=$($form.Size) min=$($form.MinimumSize)"
        "Switch text with clock option=$($script:ClockDescribe)"
        "clock ahead=$([DbdEtw]::ClockAhead) flushMs=$([DbdEtw]::FlushMs) msflush=$([DbdEtw]::MsFlush)"
        "steer=$($lblSteer.Text)"
        "dns=$($lblNext.Text)"
        "buttons=$(@($allButtons | ForEach-Object { $_.Text }) -join ' | ')"
        "etw=$($script:EtwOk) $($script:EtwErr)"
        "process=$((Get-Process -Id $PID).ProcessName)"
        ("store lookups in the .exe: Start menu (NGENUITY)=$xa in $xaMs ms; epic link for " +
            "DBD=$([bool](Get-EpicDbdLink)); steam=$((Get-DbdLauncher 'Steam').Target)")
    )
}

$script:Step = 0
$smokeTimer = New-Object System.Windows.Forms.Timer
$smokeTimer.Interval = 2500
$smokeTimer.Add_Tick({
    $script:Step++
    switch ($script:Step) {
        1 { Step-Start }
        2 { Step-SwitchSelected }
        3 { Step-OptionsMenu }
        4 { Step-SortAndConsole }
        5 { Step-TrayAndWait }
        6 { Send-TestKey 0x1B }   # Esc while the Switch waits = Cancel
        7 {
            # wait again; the next tick closes the window while it waits
            $script:EscCancelled = -not $script:Busy
            Select-Action 'Switch'
            $btnApply.PerformClick()
        }
        8 { Step-CloseToTray }
        default {
            $smokeTimer.Stop()
            Get-SmokeResult | Out-File -Encoding utf8 $SmokeResult
            $form.Close()
        }
    }
})
$form.Add_Shown({ $smokeTimer.Start() })
[System.Windows.Forms.Application]::Run($form)
