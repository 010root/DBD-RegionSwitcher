# --- SetTcpEntry P/Invoke: kill a process's TCP connections (the cut) ---
if (-not ([System.Management.Automation.PSTypeName]'TcpKill').Type) {
    Add-Type -TypeDefinition @'
//@include native/TcpKill.cs
'@ -ErrorAction Stop
}
function ConvertTo-UintIp {
    param([string]$ip)
    $b = [Net.IPAddress]::Parse($ip).GetAddressBytes()
    [BitConverter]::ToUInt32($b,0)
}

# --- ETW: DNS-Client lookups (who resolved which GameLift host, when) + Kernel-Network UDP (game server) ---
if (-not ([System.Management.Automation.PSTypeName]'DbdEtw').Type) {
    Add-Type -TypeDefinition @'
//@include native/DbdEtw.cs
'@ -ErrorAction Stop
}

# --- Ping: TCP connect time to every region at the same time ---
if (-not ([System.Management.Automation.PSTypeName]'RegionPing').Type) {
    Add-Type -TypeDefinition @'
//@include native/RegionPing.cs
'@ -ErrorAction Stop
}

# --- Which ETW sessions receive a provider's events (to name what else listens to network events) ---
if (-not ([System.Management.Automation.PSTypeName]'EtwSessions').Type) {
    Add-Type -TypeDefinition @'
//@include native/EtwSessions.cs
'@ -ErrorAction Stop
}

# --- Dark menus (right-click + Options): WinForms' own menu highlight is light blue ---
if (-not ([System.Management.Automation.PSTypeName]'DarkMenuRenderer').Type) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
//@include native/UiPainting.cs
'@ -ErrorAction Stop
}

# --- Dark title bar / dark scrollbars (Windows 10 1809+ / 11; silently ignored elsewhere), display scale per screen ---
if (-not ([System.Management.Automation.PSTypeName]'DarkUi').Type) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
//@include native/Win32Ui.cs
'@ -ErrorAction Stop
}

