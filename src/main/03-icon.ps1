# ---------------- the tool's own icon ----------------
# Two of DBD's own UI icons, combined: the meat hook over the skill-check circle and its red needle, in the game's
# colors, on a dark tile. The art is BHVR's. src\icon-art.png (256 px) is included below at build time; the window and
# the tray scale it to each size, and tools\make-icon.ps1 draws the .exe's icons from it.
$IconArt = @'
@include-base64 icon-art.png
'@   # ICON-ART END
$script:IconArtBmp = $null
function New-AppIconBitmap {
    param([int]$Size)
    # decoded once; a copy, because GDI+ keeps reading the stream of a bitmap made from one
    if (-not $script:IconArtBmp) {
        $ms = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String(($IconArt -replace '\s','')))
        $png = New-Object System.Drawing.Bitmap($ms)
        $script:IconArtBmp = New-Object System.Drawing.Bitmap($png)
        $png.Dispose()
        $ms.Dispose()
    }
    $bmp = New-Object System.Drawing.Bitmap($Size,$Size,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.SmoothingMode = 'AntiAlias'
    $g.DrawImage($script:IconArtBmp,0,0,$Size,$Size)
    $g.Dispose()
    return $bmp
}
# .ico file bytes (32-bit images, one per size) from New-AppIconBitmap.
function New-AppIconBytes {
    param([int[]]$Sizes = @(16,20,24,32,40,48,64))
    $imgs = @(foreach ($s in $Sizes) {
        $bmp = New-AppIconBitmap $s
        $d = $bmp.LockBits([System.Drawing.Rectangle]::new(0,0,$s,$s),'ReadOnly',
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $px = New-Object byte[] ($s*$s*4)
        [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0,$px,0,$px.Length)
        $bmp.UnlockBits($d)
        $bmp.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([int]40)
        $bw.Write([int]$s)
        $bw.Write([int]($s*2))
        $bw.Write([int16]1)
        $bw.Write([int16]32)
        $bw.Write([int]0)
        $bw.Write([int]0)
        $bw.Write([int]0)
        $bw.Write([int]0)
        $bw.Write([int]0)
        $bw.Write([int]0)
        for ($y = $s-1;$y -ge 0;$y--) { $bw.Write($px,$y*$s*4,$s*4) }   # bottom-up rows
        $mask = [int]([Math]::Ceiling($s/32.0)*4)
        $bw.Write((New-Object byte[] ($mask*$s)))   # AND mask unused (alpha)
        $bw.Flush()
        ,@($s,$ms.ToArray())
    })
    $o = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($o)
    $w.Write([int16]0)
    $w.Write([int16]1)
    $w.Write([int16]$imgs.Count)
    $off = 6+16*$imgs.Count
    foreach ($i in $imgs) {
        $sz = $i[0]
        $w.Write([byte]$(if ($sz -ge 256) {0} else {$sz}))
        $w.Write([byte]$(if ($sz -ge 256) {0} else {$sz}))
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([int16]1)
        $w.Write([int16]32)
        $w.Write([int]$i[1].Length)
        $w.Write([int]$off)
        $off += $i[1].Length
    }
    foreach ($i in $imgs) { $w.Write($i[1]) }
    $w.Flush()
    return ,$o.ToArray()
}
function New-AppIcon {
    # The .exe carries this icon already drawn (tools\make-icon.ps1, at build time): ~150 ms less at every start.
    try {
        $s = [System.Reflection.Assembly]::GetEntryAssembly().GetManifestResourceStream('window.ico')
        if ($s) { return New-Object System.Drawing.Icon($s) }
    } catch {}
    try {
        return New-Object System.Drawing.Icon((New-Object System.IO.MemoryStream(,(New-AppIconBytes))))
    } catch {
        return $null
    } finally {
        # the 256 px picture isn't needed after this
        if ($script:IconArtBmp) {
            $script:IconArtBmp.Dispose()
            $script:IconArtBmp = $null
        }
    }
}
$script:AppIcon = New-AppIcon

$DefaultHosts = @'
# Copyright (c) 1993-2009 Microsoft Corp.
#
# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.
#
# This file contains the mappings of IP addresses to host names. Each
# entry should be kept on an individual line. The IP address should
# be placed in the first column followed by the corresponding host name.
# The IP address and the host name should be separated by at least one
# space.
#
# Additionally, comments (such as these) may be inserted on individual
# lines or following the machine name denoted by a '#' symbol.
#
# For example:
#
#      102.54.94.97     rhino.acme.com          # source server
#       38.25.63.10     x.acme.com              # x client host

# localhost name resolution is handled within DNS itself.
#	127.0.0.1       localhost
#	::1             localhost
'@

# The regions DBD measures: code and name. Each one's two latency endpoints follow from its code (Hong Kong's
# GameLift endpoint is EC2's).
$Regions = @(@(
    ,@('us-east-1',      'US East (Virginia)')
    ,@('us-east-2',      'US East (Ohio)')
    ,@('us-west-1',      'US West (California)')
    ,@('us-west-2',      'US West (Oregon)')
    ,@('ca-central-1',   'Canada (Central)')
    ,@('sa-east-1',      'S. America (Sao Paulo)')
    ,@('eu-west-2',      'EU (London)')
    ,@('eu-west-1',      'EU (Ireland)')
    ,@('eu-central-1',   'EU (Frankfurt)')
    ,@('ap-northeast-1', 'Asia (Tokyo)')
    ,@('ap-northeast-2', 'Asia (Seoul)')
    ,@('ap-south-1',     'Asia (Mumbai)')
    ,@('ap-east-1',      'Asia (Hong Kong)')
    ,@('ap-southeast-1', 'Asia (Singapore)')
    ,@('ap-southeast-2', 'Asia (Sydney)')
) | ForEach-Object {
    $c = $_[0]
    $api = if ($c -eq 'ap-east-1') { "ec2.$c.amazonaws.com" } else { "gamelift.$c.amazonaws.com" }
    [pscustomobject]@{ Code = $c; Name = $_[1]; Hosts = @($api,"gamelift-ping.$c.api.aws") }
})
# Every hostname the block can contain (recognises DBD's latency-endpoint lookups in ETW).
$SteerHostRx = '^(' + ((@($Regions | ForEach-Object { $_.Hosts }) |
    ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
# Any region's latency endpoint: a region BHVR adds later matches this but not the block, so DBD could still reach it.
$RegionHostRx = '^(gamelift-ping\.[a-z0-9-]+\.api\.aws|gamelift\.[a-z0-9-]+\.amazonaws\.com)$'

