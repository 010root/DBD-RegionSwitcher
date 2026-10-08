# ---------------- clock left ahead by a run that didn't finish ----------------
# The clock option writes this file before moving the clock and deletes it once the clock is back. If it's still
# here, that run ended (crash / killed / power loss) while the clock was ahead.
$ClockMarkPath = Join-Path $AppDir 'clock-ahead.txt'
function Remove-ClockMark {
    # never through a link
    try {
        if ([System.IO.File]::Exists($ClockMarkPath) -and (Test-NoLink $AppDir,$ClockMarkPath)) {
            [System.IO.File]::Delete($ClockMarkPath)
        }
    } catch {
        Write-Log "clock-ahead.txt couldn't be deleted ($($_.Exception.Message))"
    }
}
try {
    if ([System.IO.File]::Exists($ClockMarkPath)) {
        $kv = @{}
        foreach ($l in [System.IO.File]::ReadAllLines($ClockMarkPath)) {
            $i = $l.IndexOf('=')
            if ($i -gt 0) { $kv[$l.Substring(0,$i)] = $l.Substring($i+1) }
        }
        try {
            $sec = [double]::Parse($kv['aheadSec'],[Globalization.CultureInfo]::InvariantCulture)
            $when = [DateTime]::Parse($kv['realUtc'],[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            # the tool never jumps more than an hour; a day is a generous sanity limit
            if (-not ($sec -gt 0 -and $sec -le 86400)) { throw "aheadSec $sec is out of range" }
        } catch {
            Write-Log ("Clock marker found but unreadable ($($_.Exception.Message)) - removed (it's written before " +
                "the clock moves, so a write cut off there means the clock never moved).")
            Remove-ClockMark
            throw 'handled'
        }
        Write-Log (("Clock marker found: a previous run moved the PC clock {0:N0} s ahead at {1} and didn't confirm " +
            "putting it back.") -f $sec,$when)
        $ask = ("The PC clock may still be {0:N0} s ahead.`r`n`r`nThe last time this tool ran, it moved the clock " +
            "ahead at {1:HH:mm:ss} and closed before putting it back. It now reads {2:HH:mm:ss}.`r`n`r`n" +
            "Sync the clock: Windows syncs it with its time server (w32tm /resync).`r`n" +
            "Leave it: nothing changes.") -f $sec,$when,(Get-Date)
        $ans = Show-Msg $ask 'YesNo' 'Warning' @{
            Yes = 'Sync the clock'
            No = 'Leave it'
        }
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            $o = (& (Join-Path $Sys32 'w32tm.exe') /resync /force 2>&1 | Out-String).Trim()
            $rc = $LASTEXITCODE
            Write-Log "  w32tm /resync: exit $rc - $o"
            if ($rc -ne 0) {
                # w32tm's own text goes in as it is: braces in it would break a -f format
                $readsNow = (Get-Date).ToString('HH:mm:ss')
                $setBack = "Set it back by {0:N0} s instead? Only if it's really ahead." -f $sec
                $syncMsg = "Windows couldn't sync the clock.`r`n`r`n$o`r`n`r`nIt reads $readsNow. $setBack"
                $a2 = Show-Msg $syncMsg 'YesNo' 'Question' @{
                    Yes = 'Set it back'
                    No = 'Leave it'
                }
                if ($a2 -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Set-Date -Adjust ([TimeSpan]::FromSeconds(-$sec)) | Out-Null
                    Write-Log "  clock set back by $sec s (you confirmed)"
                }
            }
        } else {
            Write-Log '  left as is (you chose Leave it)'
        }
        Remove-ClockMark
    }
} catch { if ("$_" -ne 'handled') { Write-Log "Clock marker check failed: $($_.Exception.Message)" } }

