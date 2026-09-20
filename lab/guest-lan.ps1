# Runs INSIDE the guest. Makes the VM a normal member of the host's LAN once its adapter
# is on the External 'LAN' switch: Private profile, answers ping, shares files, shows up
# in Network. Windows blocks all three by default on a fresh install.
#
# The switch move itself is host-side and must happen BEFORE the baseline is saved,
# because a checkpoint remembers which switch the adapter was on:
#     Connect-VMNetworkAdapter -VMName Home,Pro -SwitchName LAN
$ErrorActionPreference = 'Stop'
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'
Enable-NetFirewallRule -DisplayGroup 'Network Discovery'
"profile=" + ((Get-NetConnectionProfile).NetworkCategory -join ',')
"ip=" + ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' }).IPAddress -join ',')
