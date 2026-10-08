# UI checks, spliced into a copy of the tool by verify\ui-check.ps1 in place of its Application.Run line.
# Set before it: $UiDir (pictures, the hosts copy), $UiPrefix ('ui-' or 'ui-light-'), $UiScreen, $UiFilmOnly.
# Results: "$UiDir\${UiPrefix}check.txt".

$UiResult = "$UiDir\${UiPrefix}check.txt"
$script:R = New-Object System.Collections.Generic.List[string]

# The window opens on the test screen, not the main one.
$tsc = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like "*$UiScreen" })[0]
if ($tsc) {
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new($tsc.WorkingArea.X + 30,$tsc.WorkingArea.Y + 10)
}
$script:Draws = 0
$list.Add_DrawItem({ $script:Draws++ })   # row paints

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

// Grabs a screen rectangle on its own thread as fast as it can (the window's thread is busy painting meanwhile) and
// counts how often each distinct picture was seen.
public static class ScreenSampler {
    static Thread _t;
    static volatile bool _stop;
    public static Dictionary<string, int> Seen = new Dictionary<string, int>();
    public static Dictionary<string, Bitmap> First = new Dictionary<string, Bitmap>();
    public static int Frames;
    [DllImport("user32.dll")]
    static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")]
    static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("dwmapi.dll")]
    static extern int DwmFlush();

    public static void Start(Rectangle r) {
        Seen.Clear();
        First.Clear();
        Frames = 0;
        _stop = false;
        // what the window drew before is on the screen now (else the first grabs can show the state before the film)
        DwmFlush();
        DwmFlush();
        // the window thread's DPI mode: screen coordinates mean the same here
        IntPtr ctx = GetThreadDpiAwarenessContext();
        _t = new Thread(() => {
            SetThreadDpiAwarenessContext(ctx);
            using (Bitmap b = new Bitmap(r.Width, r.Height))
            using (Graphics g = Graphics.FromImage(b))
            using (SHA1 sha = SHA1.Create()) {
                while (!_stop) {
                    string h = Grab(b, g, sha, r);
                    int n;
                    Seen.TryGetValue(h, out n);
                    Seen[h] = n + 1;
                    Frames++;
                    if (n == 0 && First.Count < 40) First[h] = (Bitmap)b.Clone();
                }
            }
        });
        _t.IsBackground = true;
        _t.Start();
    }
    public static void Stop() {
        _stop = true;
        if (_t != null) _t.Join();
    }
    // One grab's fingerprint.
    public static string Hash(Rectangle r) {
        using (Bitmap b = new Bitmap(r.Width, r.Height))
        using (Graphics g = Graphics.FromImage(b))
        using (SHA1 sha = SHA1.Create())
            return Grab(b, g, sha, r);
    }
    static string Grab(Bitmap b, Graphics g, SHA1 sha, Rectangle r) {
        g.CopyFromScreen(r.Location, Point.Empty, r.Size);
        BitmapData d = b.LockBits(new Rectangle(0, 0, r.Width, r.Height), ImageLockMode.ReadOnly,
            PixelFormat.Format32bppArgb);
        byte[] px = new byte[d.Stride * d.Height];
        Marshal.Copy(d.Scan0, px, 0, px.Length);
        b.UnlockBits(d);
        return Convert.ToBase64String(sha.ComputeHash(px));
    }
}

// Is a text cursor (caret) showing in a window? Windows reports it per thread (GetGUIThreadInfo, GUI_CARETBLINKING =
// "set if the caret is visible").
public static class CaretInfo {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)]
    struct GTI {
        public int cb, flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public RECT rc;
    }
    [DllImport("user32.dll")]
    static extern bool GetGUIThreadInfo(uint t, ref GTI g);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);

    public static void Click(IntPtr h) {
        IntPtr p = (IntPtr)((6 << 16) | 6);
        SendMessage(h, 0x201, (IntPtr)1, p);
        SendMessage(h, 0x202, IntPtr.Zero, p);
    }
    public static bool Visible(IntPtr h) {
        GTI g = new GTI();
        g.cb = Marshal.SizeOf(typeof(GTI));
        if (!GetGUIThreadInfo(GetCurrentThreadId(), ref g)) return false;
        return g.caret == h && (g.flags & 1) != 0;
    }
}
'@

function Wait-Ui([int]$Times,[int]$Ms) {
    for ($q = 0; $q -lt $Times; $q++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $Ms
    }
}
function Wait-UiFor([int]$Ms,[int]$Step = 10) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $Step
    }
}
function Move-Mouse([System.Drawing.Rectangle]$R,[int]$X = 60) {
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($R.X + $X,$R.Y + [int]($R.Height / 2))
}
function Save-Screen([System.Drawing.Rectangle]$R,[string]$Path) {
    $bmp = New-Object System.Drawing.Bitmap($R.Width,$R.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($R.Location,[System.Drawing.Point]::Empty,$R.Size)
    $g.Dispose()
    $bmp.Save($Path)
    $bmp.Dispose()
}
function Shot([string]$Name) {
    $form.TopMost = $true
    Wait-Ui 6 40
    Save-Screen $form.Bounds "$UiDir\$UiPrefix$Name.png"
}
function Write-Results { [IO.File]::WriteAllLines($UiResult,$script:R) }

# Sample texts for the rows the films change
function Get-ServerRow([int]$Rate,[switch]$Warn) {
    $parts = @(
        @('43.203.220.197:7790',$cText,$false),
        @("  ~$Rate packets/s  ->  ",$cDim,$false),
        @('ap-northeast-2  Asia (Seoul)',$cLanded,$true),
        @('  Amazon EC2',$cDim,$false))
    if ($Warn) { $parts += ,@('  (steering is ap-northeast-1)',$cWarn,$true) }
    return ,$parts
}
function Get-WaitText([int]$Sec) {
    ("Steering -> EU (Frankfurt) written to hosts.${nl}Waiting: 4:{0:00} min - opens at 05:25:34, 10 min after DBD's " +
        "last measurement (05:15:29).${nl}Cancel (or Esc): stops here and puts hosts back as it was. DBD " +
        "hasn't been touched.") -f $Sec
}

# Layout: every part's edges in window coordinates - the same margin left and right, one right edge for the list, the
# status card, the action row, Apply, the activity box and the footer, and the same gap between the parts top to bottom.
function Get-LayoutReport([string]$Label) {
    $W = $form.ClientSize.Width
    $H = $form.ClientSize.Height
    $at = { param($c) $form.RectangleToClient($c.RectangleToScreen($c.ClientRectangle)) }
    $L = & $at $listFrame
    $I = & $at $infoPanel
    $B1 = & $at $btnRepair
    $B2 = & $at $btnDetails
    $S = & $at $statusFrame
    $F = & $at $footer
    $A = & $at $btnApply
    $C = & $at $btnConsole
    $rights = @($L.Right,$I.Right,$B1.Right,$S.Right,$F.Right,$C.Right)
    if ($btnApply.Visible) { $rights += $A.Right }
    $gaps = @(($I.Top - $L.Bottom),($B1.Top - $I.Bottom),($B2.Top - $B1.Bottom),($S.Top - $B2.Bottom),
        ($F.Top - $S.Bottom))
    $spread = ($gaps | Measure-Object -Maximum).Maximum - ($gaps | Measure-Object -Minimum).Minimum
    $ok = (@($rights | Select-Object -Unique).Count -eq 1) -and ($W - $L.Right -eq $L.Left) -and
        ([Math]::Abs($H - $F.Bottom - $L.Left) -le 1) -and ($spread -le 1)
    ("layout, $Label (client $W x $H): left margin $($L.Left), right margin $($W - $L.Right), bottom margin " +
        "$($H - $F.Bottom); right edges $($rights -join ' '); gaps top to bottom $($gaps -join ' ') - " +
        "lined up: $ok (want True)")
}

# ---- films: another thread grabs part of the screen while the window changes ----
function Start-Film($Rect) {
    # Films once the screen has settled (two grabs 60 ms apart the same, the window painting in between): a window
    # resize can take a moment to reach the screen, and its first grabs would show the state before.
    $last = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 1500) {
        [System.Windows.Forms.Application]::DoEvents()
        $h = [ScreenSampler]::Hash($Rect)
        if ($h -eq $last) { break }
        $last = $h
        Start-Sleep -Milliseconds 60
    }
    [ScreenSampler]::Start($Rect)
}
function Save-OddPictures([string]$Label) {
    # the rarely seen (in-between) pictures, to look at
    $name = $Label -replace '[^A-Za-z]',''
    $j = 0
    foreach ($kv in ([ScreenSampler]::Seen.GetEnumerator() | Sort-Object Value)) {
        if ($kv.Value -le 2 -and $j -lt 4) {
            [ScreenSampler]::First[$kv.Key].Save("$UiDir\${UiPrefix}odd-$name-$j.png")
            $j++
        }
    }
}
function Get-FilmCounts { return ,@([ScreenSampler]::Seen.Values | Sort-Object -Descending) }

function Film-List([string]$Label) {
    # The mouse moves across five rows like a hand would (a row every 120 ms) while another thread grabs rows 6-8 from
    # the screen. Clean drawing gives a handful of pictures (which row is lit); in-between states add more.
    # Five rows that are fully on screen (at 150 % on a 1080p screen only ~7 fit), from row 5 if they are.
    $vis = @(0..($list.Items.Count - 1) | Where-Object {
        $b = $list.Items[$_].Bounds
        $b.Top -ge 0 -and $b.Bottom -le $list.ClientSize.Height
    })
    $from = [Math]::Max(0,[Math]::Min(5,$vis.Count - 5))
    $timer.Stop()
    $rr = @(foreach ($i in $vis[$from..($from + 4)]) { $list.RectangleToScreen($list.Items[$i].Bounds) })
    $band = [System.Drawing.Rectangle]::Union([System.Drawing.Rectangle]::Union($rr[1],$rr[2]),$rr[3])
    Start-Film $band
    $path = @(0,1,2,3,4,3,2,1)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $next = 0
    $tick = 0
    $k = 0
    while ($sw.ElapsedMilliseconds -lt 6000) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $next += 120
            Move-Mouse $rr[$path[$k % $path.Count]]
            $k++
        }
        if ($sw.ElapsedMilliseconds -ge $tick) {
            # plus a full redraw every second, like a queue / style update
            $tick += 1000
            $list.Invalidate()
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 2
    }
    [ScreenSampler]::Stop()
    # A picture with a row that has no text in it = a row Windows had cleared and not drawn again yet.
    $blank = 0
    foreach ($kv in [ScreenSampler]::First.GetEnumerator()) {
        $bm = $kv.Value
        foreach ($row in 0..2) {
            $lit = 0
            $y0 = [int]($row * $bm.Height / 3)
            for ($y = $y0 + 2; $y -lt $y0 + [int]($bm.Height / 3) - 2; $y += 2) {
                for ($x = 0; $x -lt [Math]::Min(700,$bm.Width); $x += 3) {
                    $c = $bm.GetPixel($x,$y)
                    if ($c.R + $c.G + $c.B -gt 360) { $lit++ }
                }
            }
            if ($lit -lt 3) {
                $blank += [ScreenSampler]::Seen[$kv.Key]
                break
            }
        }
    }
    $script:R.Add((("{0}: {1} grabs from another thread while the mouse moved over five rows (and the list redrew " +
        "every second); grabs with a blank row: {2} (want 0)") -f $Label,[ScreenSampler]::Frames,$blank))
}
function Film-Row([string]$Label,$Box,[int]$Count) {
    # The row changes its text every 250 ms (GAME SERVER's packet rate changes every second in a match) while another
    # thread grabs it from the screen. Clean drawing shows only the finished texts; anything else is an in-between
    # state you'd see as a blink (the text first plain, then colored part by part).
    $timer.Stop()
    [System.Windows.Forms.Application]::DoEvents()
    # a fresh drawing of the first text: one kept from an earlier window size can differ in its anti-aliasing
    Set-Info $Box @(,@('-',$cDim,$false)) $cDim
    # one of the texts before filming (else the old one counts)
    Set-Info $Box (Get-ServerRow 88 -Warn) $cWarn
    Wait-Ui 5 20
    Start-Film ($Box.RectangleToScreen($Box.ClientRectangle))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $next = 0
    $k = 0
    while ($sw.ElapsedMilliseconds -lt 5000) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $next += 250
            $k++
            Set-Info $Box (Get-ServerRow (88 + $k % $Count) -Warn) $cWarn
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 2
    }
    [ScreenSampler]::Stop()
    $v = Get-FilmCounts
    Save-OddPictures $Label
    $script:R.Add((("{0}: {1} grabs from another thread, {2} different pictures (want {3}; more = " +
        "in-between states seen): {4}") -f $Label,[ScreenSampler]::Frames,$v.Count,$Count,($v -join ' ')))
}
function Film-RowHover([string]$Label,$Box) {
    # The mouse resting on the row (its tooltip may show) while the row changes every 250 ms, filmed from another
    # thread together with the strip below it (where a tooltip opens): every picture with the text in between = a blink.
    $timer.Stop()
    Set-Info $Box (Get-ServerRow 88) $cOk
    $r = $Box.RectangleToScreen($Box.ClientRectangle)
    $right = $infoPanel.RectangleToScreen($infoPanel.ClientRectangle).Right
    $r = [System.Drawing.Rectangle]::new($r.X,$r.Y,[Math]::Min($r.Width,$right - $r.X),$r.Height * 4)
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($r.X + 40,$r.Y + [int]($Box.Height / 2))
    Wait-UiFor 1500   # the tooltip's wait
    Start-Film $r
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $next = 0
    $k = 0
    while ($sw.ElapsedMilliseconds -lt 5000) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $next += 250
            $k++
            Set-Info $Box (Get-ServerRow (88 + $k % 2)) $cOk
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 2
    }
    [ScreenSampler]::Stop()
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($form.Right + 40,$form.Top + 40)
    $v = Get-FilmCounts
    Save-OddPictures $Label
    $script:R.Add(("{0}: {1} grabs from another thread, {2} different pictures (want 2): {3}" -f $Label,
        [ScreenSampler]::Frames,$v.Count,($v -join ' ')))
}
function Film-Activity([string]$Label) {
    # The activity box rewritten every 250 ms the way a waiting Switch does (only the seconds change), filmed from
    # another thread: 2 pictures = clean.
    $timer.Stop()
    Set-Status (Get-WaitText 11) $cWarn   # one of the two texts before filming (else the old one counts)
    Wait-Ui 5 20
    Start-Film ($status.RectangleToScreen($status.ClientRectangle))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $next = 0
    $k = 0
    while ($sw.ElapsedMilliseconds -lt 5000) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $next += 250
            $k++
            Set-Status (Get-WaitText (10 + $k % 2)) $cWarn
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 2
    }
    [ScreenSampler]::Stop()
    $v = Get-FilmCounts
    $script:R.Add(("{0}: {1} grabs from another thread, {2} different pictures (want 2): {3}" -f $Label,
        [ScreenSampler]::Frames,$v.Count,($v -join ' ')))
    Save-OddPictures $Label
}

# ---- text cursor checks: nothing that can't be typed in may show a blinking cursor ----
function Test-Caret($Box,[string]$Name) {
    # Clicked like a hand would, then watched ~1 s: the caret blinks, so it's sampled many times.
    [void]$Box.Focus()
    [CaretInfo]::Click($Box.Handle)
    $seen = 0
    for ($q = 0; $q -lt 25; $q++) {
        Wait-Ui 1 40
        if ([CaretInfo]::Visible($Box.Handle)) { $seen++ }
    }
    "$Name=$seen"
}
function Test-CaretDrawn($Rt) {
    # A bright bar where the cursor would be: the start of the empty last line.
    $pt = $Rt.PointToScreen($Rt.GetPositionFromCharIndex($Rt.TextLength))
    $h = [int]$Rt.Font.GetHeight()
    $bm = New-Object System.Drawing.Bitmap(8,$h)
    $g = [System.Drawing.Graphics]::FromImage($bm)
    $g.CopyFromScreen($pt.X - 3,$pt.Y,0,0,$bm.Size)
    $g.Dispose()
    $hot = 0
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt 8; $x++) {
            $c = $bm.GetPixel($x,$y)
            if ($c.R + $c.G + $c.B -gt 450) { $hot++ }
        }
    }
    $bm.Dispose()
    return ($hot -ge [int]($h / 2))
}
function Test-CaretAppend([string]$Name) {
    # The console focused while new lines arrive (the way it's used): watched ~1 s, a line every 200 ms. Counted two
    # ways: Windows' own caret report, and the pixels where the cursor would be drawn (the rich-text control on
    # Windows 11 can draw its own cursor, which Windows doesn't report).
    $rt = $script:ConBox
    [void]$rt.Focus()
    $seen = 0
    $drawn = 0
    $was = $false
    for ($q = 0; $q -lt 25; $q++) {
        if ($q % 5 -eq 0) { Add-ConsoleLine "caret test line $q" }
        Wait-Ui 1 40
        if ([CaretInfo]::Visible($rt.Handle)) { $seen++ }
        # a cursor stays up ~0.5 s; one picture alone is text being drawn
        $now = Test-CaretDrawn $rt
        if ($now -and $was) { $drawn++ }
        $was = $now
    }
    "$Name=$seen (drawn: $drawn)"
}

# ---- the steps, one per timer tick ----
function Step-Films {
    $script:CloseTo = 'quit'
    $form.TopMost = $true
    # idle: how often does the list repaint by itself (mouse resting on a row, the tool's own 1 s tick running)?
    Move-Mouse $list.RectangleToScreen($list.Items[3].Bounds)
    $d0 = $script:Draws
    Wait-UiFor 6000 20
    $script:R.Add(("idle 6 s, mouse resting on a row: $($script:Draws - $d0) row paints (the row the mouse arrives " +
        "on, plus any list refresh)"))
    $d0 = $script:Draws
    Update-ListStyle $script:ListSteer
    Update-ListStyle $script:ListSteer
    Wait-Ui 10 20
    $script:R.Add("Update-ListStyle twice with nothing changed: $($script:Draws - $d0) row paints (want 0)")
    Film-List 'region list'
    $form.Size = [System.Drawing.Size]::new([int]($form.MinimumSize.Width * 1.3),$form.Height)
    Wait-Ui 10 30
    Film-Row 'GAME SERVER row, wide window' $lblMatch 2
    $form.Size = $form.MinimumSize
    Wait-Ui 10 30
    Film-Row 'GAME SERVER row, narrow window (ends in ...)' $lblMatch 2
    Film-RowHover 'GAME SERVER row, mouse resting on it' $lblMatch
    Film-Activity 'activity box'
}
function Step-SampleRows {
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($form.Right + 40,$form.Top + 40)
    $round = @(
        @('05:15:29',$cText,$false),
        @('  reachable: ',$cDim,$false),
        @('ap-northeast-1 Asia (Tokyo)',$cMeas,$true),
        @('   |   14 unreachable   |   UDP pings',$cDim,$false),
        @('   |   2,329 s after the previous one',$cDim,$false))
    $timer.Stop()   # the tick would write "ETW off" into these rows
    Set-Info $lblDbd $round $cOk
    Set-Info $lblMatch (Get-ServerRow 89 -Warn) $cWarn
    Set-Info $lblNext @(,@('DBD can re-measure now',$cOk,$true)) $cOk
    Set-Status ("DBD re-measured at 05:15:29: only Asia (Tokyo) was reachable. The next lobby should be Asia " +
        "(Tokyo).${nl}Check it: ready up, and once a lobby is found the GAME SERVER line shows where you " +
        "landed.${nl}If it's elsewhere anyway, the choice was made server-side; the session log has the details.") $cOk
    $form.WindowState = 'Normal'
    $form.Size = $form.MinimumSize
}
function Step-Narrow {
    Shot 'narrow'
    $script:R.Add((Get-LayoutReport 'narrowest'))
    $script:R.Add("narrow window ($($form.Width) px): round row shows [$($lblDbd.Text)]")
    $cut = $lblDbd.Text.EndsWith([string][char]0x2026)
    $kept = (Get-InfoText $lblDbd) -match 'after the previous one$'
    $tip = $tips.GetToolTip($lblDbd) -match 'after the previous one$'
    $script:R.Add("  ends in ...: $cut; whole row kept for Copy: $kept; tooltip whole: $tip")
    $last = $lblDbd.GetPositionFromCharIndex($lblDbd.TextLength - 1).X
    $vis = $infoPanel.ClientSize.Width - $lblDbd.Left
    $gap = $last -lt $vis - [InfoRow]::Margin
    $script:R.Add("  last character at x=$last of $vis visible (want a gap before the edge: $gap)")
    $script:R.Add("  server row: [$($lblMatch.Text)]")
    # nothing light around the rows: the strip under the header, below the last row, right of the last column
    $lr = $list.RectangleToScreen($list.ClientRectangle)
    $lb = New-Object System.Drawing.Bitmap($lr.Width,$lr.Height)
    $lg = [System.Drawing.Graphics]::FromImage($lb)
    $lg.CopyFromScreen($lr.Location,[System.Drawing.Point]::Empty,$lr.Size)
    $lg.Dispose()
    $y0 = $list.GetItemRect($list.TopItem.Index).Top
    $y1 = [Math]::Min($lr.Height,$list.GetItemRect($list.Items.Count - 1).Bottom)
    $colsEnd = 0
    foreach ($c in $list.Columns) { $colsEnd += $c.Width }
    $light = 0
    for ($y = 0; $y -lt $lr.Height; $y++) {
        for ($x = 0; $x -lt $lr.Width; $x++) {
            if (-not (($y -ge $y0 - 3 -and $y -lt $y0) -or $y -ge $y1 -or $x -ge $colsEnd)) { continue }
            $c = $lb.GetPixel($x,$y)
            if ($c.R + $c.G + $c.B -le 450) { continue }
            $light++
            if ($light -le 6) {
                $script:R.Add(("    light at x=$x y=$y ($($c.R),$($c.G),$($c.B)); rows y $y0..$y1, columns end x " +
                    "$colsEnd, client $($lr.Width)x$($lr.Height)"))
            }
        }
    }
    $lb.Dispose()
    $script:R.Add("  light pixels around the list rows (under the header / below / right): $light (want 0)")
    $hBar = $list.ClientSize.Height -lt $list.Height - 2
    $script:R.Add(("  list: width $($list.Width), client $($list.ClientSize.Width) x $($list.ClientSize.Height), " +
        "columns add up to $colsEnd (want < client); horizontal scrollbar: $hBar (want False)"))
    $script:R.Add("  status rows copy: " + ((Get-StatusRowsText) -replace "`r`n",' / '))
    $form.Width = [int]($form.MinimumSize.Width * 1.45)
}
function Get-ActivityLine([int]$I) { return ($status.Text -split "`n")[$I] }
function Step-WideAndActions {
    Shot 'wide'
    $script:R.Add((Get-LayoutReport 'wide'))
    $whole = $lblDbd.Text -eq (Get-InfoText $lblDbd)
    $script:R.Add("wide window ($($form.Width) px): round row = whole row again: $whole [$($lblDbd.Text)]")
    $form.Size = $form.MinimumSize

    # Switch while a cut waits for DBD's measurement (stand-ins: this process is "DBD", a hosts copy, no cut allowed)
    $global:HostsPath = "$UiDir\hosts-copy-ui"
    $script:HostsPath = $global:HostsPath
    [IO.File]::Copy("$([Environment]::SystemDirectory)\drivers\etc\hosts",$global:HostsPath,$true)
    function script:Test-Admin { $true }
    function script:Get-DbdProcess { Get-Process -Id $PID }
    function script:Invoke-CutDbd { throw 'a cut was attempted' }
    function script:Invoke-HoldCut { throw 'a hold was attempted' }
    Set-Steering 'ap-northeast-1'
    $script:DbdPid = $PID
    $script:EtwOk = $true
    $script:EtwHealth = @{ Udp = $true; Dns = $true; Text = 'UDP events OK, DNS events OK' }
    $script:PingMode = 'UDP'
    function script:Test-EtwHealth { $script:EtwHealth }
    $script:Verify = @{
        CutUtc = [DbdEtw]::UtcNow.AddSeconds(-40)
        HoldEndUtc = [DbdEtw]::UtcNow.AddSeconds(-30)
        Name = 'Asia (Tokyo)'
        Code = 'ap-northeast-1'
        Pid = $PID
        Done = $false
    }
    $script:R.Add("pending cut seen: $([bool](Get-PendingCut))")
    foreach ($it in $list.Items) { if ($it.Tag.Code -eq 'ap-northeast-2') { $it.Selected = $true } }
    Select-Action 'Switch'
    $script:R.Add("Switch text (other region): " + (Get-ActivityLine 2))
    Shot 'pending-switch'
    $res = Invoke-SwitchNoRestart 'ap-northeast-2'
    $script:R.Add("Switch result: " + ($res.Text -replace "`r?`n",' / '))
    $script:R.Add(("hosts copy now steers to: $((Get-CurrentSteering).Code) (want ap-northeast-2); verification " +
        "follows: $($script:Verify.Code)"))
    $res = Invoke-SwitchNoRestart 'ap-northeast-2'
    $script:R.Add("same region again: " + (($res.Text -split "`n")[0]))
    $script:PingMode = 'HTTP'
    $script:R.Add("pending in HTTP mode: $([bool](Get-PendingCut)) (want False)")
    $script:PingMode = 'UDP'
    $script:EtwHealth = @{ Udp = $true; Dns = $false }
    $script:R.Add("pending without DNS events: $([bool](Get-PendingCut)) (want False)")
    $script:EtwHealth = @{ Udp = $true; Dns = $true }
    $script:Verify.Done = $true
    $script:R.Add("pending after DBD measured: $([bool](Get-PendingCut)) (want False)")
    Select-Action 'Switch'
    $script:R.Add("Switch text after DBD measured: " + (Get-ActivityLine 2))

    # Switch + Restart with the Epic version (a stand-in): writes the steering, never closes or relaunches DBD
    function script:Restart-Dbd {
        param($Store)
        $script:RestartAsked = $Store
        "(stand-in: Restart-Dbd asked for $Store)"
    }
    function script:Get-DbdProcess { [pscustomobject]@{ ProcessName = 'DeadByDaylight-EGS-Shipping'; Id = $PID } }
    foreach ($it in $list.Items) { if ($it.Tag.Code -eq 'eu-west-2') { $it.Selected = $true } }
    # 1) Epic's DBD not found in its launcher's list: steering only, DBD not closed
    function script:Get-DbdLauncher {
        param($Store)
        if ($Store -eq 'Steam') { @{ Target = 'steam://rungameid/381210'; How = 'Steam' } } else { $null }
    }
    Select-Action 'Restart'
    $script:R.Add("Restart text (Epic, not found): " + (Get-ActivityLine 2))
    $script:RestartAsked = $null
    $res = & $Actions['Restart'].Run
    $script:R.Add(("Restart result (Epic, not found): " + ($res.Text -replace "`r?`n",' / ') + " | restart asked: " +
        "$([bool]$script:RestartAsked) (want False) | hosts copy steers to: $((Get-CurrentSteering).Code) " +
        "(want eu-west-2)"))
    # 1b) the same with DBD closed (Epic remembered from last time): no "close DBD" in the texts
    function script:Get-DbdProcess { $null }
    $script:DbdStore = 'Epic Games'
    Select-Action 'Restart'
    $script:R.Add("Restart text (Epic, not found, DBD closed): " + (Get-ActivityLine 2))
    $res = & $Actions['Restart'].Run
    $script:R.Add("Restart result (Epic, not found, DBD closed): " + ($res.Text -replace "`r?`n",' / '))
    function script:Get-DbdProcess { [pscustomobject]@{ ProcessName = 'DeadByDaylight-EGS-Shipping'; Id = $PID } }
    # 2) found: closes and starts again through the Epic Games launcher
    function script:Get-DbdLauncher {
        param($Store)
        $link = 'com.epicgames.launcher://apps/x%3Ay%3Az?action=launch&silent=true'
        @{ Target = $link; How = 'the Epic Games launcher' }
    }
    Select-Action 'Restart'
    $script:R.Add("Restart text (Epic, found): " + (Get-ActivityLine 2))
    $res = & $Actions['Restart'].Run
    $script:R.Add(("Restart result (Epic, found): " + ($res.Text -replace "`r?`n",' / ') + " | restart asked for: " +
        "$($script:RestartAsked) (want Epic Games)"))

    # Temporary steering through the real once-a-second update (hosts copy): armed once a "DBD" started after it was
    # written runs, removed when it closes. It's written while DBD is closed, then "DBD" starts.
    $script:SteerLife = 'temp'
    $script:Verify = $null
    function script:Get-DbdProcess { $null }
    Update-DbdPid
    Set-Steering 'eu-central-1'
    function script:Get-DbdProcess { Get-Process -Id $PID }
    $timer.Start()
    Wait-UiFor 4000 50
    $armed = $script:TempArmed
    $row = $lblSteer.Text
    $label1 = $btnRestart.Text
    $switchShown1 = $btnSwitch.Visible
    $x1 = $btnSwitch.Left
    Select-Action 'Switch'
    function script:Get-DbdProcess { $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000 -and (Get-CurrentSteering).Code) { Wait-Ui 1 50 }
    Wait-Ui 10 30
    $script:R.Add(("temporary steering: armed while DBD ran=$armed (row: $row); removed after DBD closed=" +
        "$(-not (Get-CurrentSteering).Code); activity: " + (Get-ActivityLine 0)))
    $script:R.Add(("switch button: DBD running shown=$switchShown1 (want True), DBD closed " +
        "shown=$($btnSwitch.Visible) (want False); menu item shown=$($miSwitch.Visible) (want False); selected " +
        "Switch dropped=$(-not $script:Selected) (want True); row: Switch + Start starts at x=$($btnRestart.Left) " +
        "(want $x1), Repair ends at $($btnRepair.Right) (want $($infoPanel.Right))"))
    Select-Action 'Restart'
    $script:R.Add(("restart button: DBD running [$label1] (want Switch + Restart), DBD closed [$($btnRestart.Text)] " +
        "(want Switch + Start); menu [$($miRestart.Text)]; apply [$($btnApply.Text)]; description: " +
        (Get-ActivityLine 0)))
    $script:SteerLife = 'keep'
    function script:Get-DbdProcess { Get-Process -Id $PID }
    Select-Action $null
}
function Step-ConsoleAndTray {
    # Freshly opened, one line added, no click (what the admin run photographs): watched ~1 s.
    if ($script:ConForm) { $script:ConForm.Close() }
    Show-Console
    Write-Log 'APPLY console test line'
    $fresh = 0
    $freshSeen = 0
    $was = $false
    for ($q = 0; $q -lt 25; $q++) {
        Wait-Ui 1 40
        $now = Test-CaretDrawn $script:ConBox
        if ($now -and $was) { $fresh++ }   # seen in two pictures in a row, see Test-CaretAppend
        $was = $now
        if ([CaretInfo]::Visible($script:ConBox.Handle)) { $freshSeen++ }
    }
    # A blinking text cursor where nothing can be typed (status rows, activity, console): times it was seen showing
    $cc = @("console, just opened=$freshSeen (drawn: $fresh)",(Test-Caret $script:ConBox 'console'),
        (Test-CaretAppend 'console, new lines'))
    $script:ConForm.Activate()
    [void]$form.Activate()
    $boxes = @(@($lblSteer,'steering'),@($lblMatch,'game server'),@($lblDbd,'dbd measured'),@($lblNext,'re-measure'),
        @($status,'activity'))
    $rows = @(foreach ($b in $boxes) { Test-Caret $b[0] $b[1] })
    $script:R.Add("text cursor seen after a click (want all 0): " + (($rows + $cc) -join ', '))
    Save-Screen $script:ConForm.Bounds "$UiDir\${UiPrefix}console.png"
    $script:ConForm.Close()
    $script:R.Add("icon set: $($null -ne $form.Icon)")
    # The tray notification is tested by the admin run, from the .exe: run here, through powershell.exe, Windows would
    # name it "Windows PowerShell".
    try {
        [WinHelp]::Flash($form.Handle)
        Hide-ToTray
        Wait-Ui 10 30
        $hid = (-not $form.Visible -and $tray.Visible)
        Show-FromTray
        $script:R.Add("attention: taskbar flash ran without errors; tray: hidden=$hid shown again=$($form.Visible)")
    } catch {
        $script:R.Add("attention ERROR: $($_.Exception.Message)")
    }
}

$script:Step = 0
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 1500
$uiTimer.Add_Tick({
    $uiTimer.Stop()   # stopped while a step runs: its DoEvents would start the next one inside it
    $script:Step++
    try {
        switch ($script:Step) {
            1 { Step-Films }
            2 { Step-SampleRows }
            3 { Step-Narrow }
            4 { Step-WideAndActions }
            default { Step-ConsoleAndTray }
        }
        if ($script:Step -ge 5 -or ($script:Step -eq 1 -and $UiFilmOnly)) {
            Write-Results
            $form.Close()
        } else {
            $uiTimer.Start()
        }
    } catch {
        $script:R.Add("STEP $($script:Step) ERROR: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)")
        Write-Results
        $form.Close()
    }
})
$form.Add_Shown({ $uiTimer.Start() })
[System.Windows.Forms.Application]::Run($form)
