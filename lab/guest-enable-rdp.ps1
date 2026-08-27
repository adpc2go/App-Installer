# Runs INSIDE the guest, via Update-Baseline.ps1. Turns on RDP so vmconnect can use
# Enhanced Session Mode - a resizable window at proper resolution, plus clipboard sharing -
# instead of the fixed 1024x768 basic console.
#
# No firewall rule is involved: Enhanced Session rides the VMBus (Hyper-V sockets), not
# TCP/3389, so the guest firewall never sees the connection.
$ErrorActionPreference = 'Stop'

Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

# NLA stays on: the account is a local admin with a password, and nothing here is exposed
# to the LAN.
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name UserAuthentication -Value 1

foreach ($svc in 'TermService','UmRdpService') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        Set-Service $svc -StartupType Automatic
        if ($s.Status -ne 'Running') { Start-Service $svc }
    }
}

"fDenyTSConnections = $((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections)"
"TermService        = $((Get-Service TermService).Status)"
