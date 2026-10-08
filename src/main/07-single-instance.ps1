# ---------------- single instance ----------------
# A second copy would restart the ETW session (freezing the first one's readouts) and could race it on hosts.
# The tool always runs as admin; only a test copy runs without, and its title says so.
$WindowTitle = 'DBD Region Switcher' + $(if (Test-Admin) { '' } else { ' (not admin)' })
$script:Mutex = New-Object System.Threading.Mutex($false,'Global\DBD-RegionSwitcher')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) } catch { $owned = $true }   # abandoned by a crashed copy -> ours now
if ($owned) {
    try {
        $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false,
            [System.Threading.EventResetMode]::AutoReset,'Global\DBD-RegionSwitcher-Show')
    } catch { $script:ShowEvent = $null }
}
if (-not $owned) {
    # The open copy may be hidden in the tray: signal it (its timer shows the window within a second).
    $shown = $false
    try { $shown = [System.Threading.EventWaitHandle]::OpenExisting('Global\DBD-RegionSwitcher-Show').Set() } catch {}
    if (-not $shown) { $shown = [WinHelp]::Activate($WindowTitle) }
    # The open window's title also shows the steering ("... - steered to X"), so find it by its start too
    # (StartsWith, not -like: brackets in a title would be wildcards).
    if (-not $shown) {
        try {
            $o = Get-Process | Where-Object {
                $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and
                    $_.MainWindowTitle.StartsWith($WindowTitle,[StringComparison]::Ordinal)
            } | Select-Object -First 1
            if ($o) { $shown = [WinHelp]::ActivateHandle($o.MainWindowHandle) }
        } catch {}
    }
    if (-not $shown) { [void](Show-Msg 'DBD Region Switcher is already open.') }
    exit
}

