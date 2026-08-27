#requires -Version 5.1
<#
  Step 1 of the lab build. Run ELEVATED. Reboots when done (asks first).

  Enables the Hyper-V role. This turns the hypervisor on at boot for good - which is the
  point: the lab VM runs in a window beside your editor, so the host is never rebooted to
  switch between "writing code" and "testing code".
#>
[CmdletBinding()]
param([switch]$NoReboot)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an elevated PowerShell window.'
}

# Hyper-V needs SLAT + VT-x. On a 13900KF the only realistic failure is VT-x switched off
# in BIOS, which surfaces here as a feature that enables but never produces a hypervisor.
$cs = Get-CimInstance Win32_ComputerSystem
if (-not (Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled -and -not $cs.HypervisorPresent) {
    Write-Host 'VT-x appears disabled in BIOS. Enable Intel Virtualization Technology first.' -ForegroundColor Yellow
}

$features = @(
    'Microsoft-Hyper-V-All'          # hypervisor + management + PowerShell module
    'HypervisorPlatform'             # lets other VMMs coexist instead of breaking
)

foreach ($f in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    if ($state -eq 'Enabled') { Write-Host "$f already enabled"; continue }
    Write-Host "Enabling $f ..."
    Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart | Out-Null
}

Write-Host ''
Write-Host 'Hyper-V staged. A reboot is required before the VM can be created.' -ForegroundColor Green
Write-Host 'After the reboot, run 2-New-LabVM.ps1 (also elevated).'

if ($NoReboot) { return }
if ((Read-Host 'Reboot now? (y/N)') -eq 'y') { Restart-Computer -Force }
