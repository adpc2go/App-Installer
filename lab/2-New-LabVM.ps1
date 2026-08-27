#requires -Version 5.1
<#
  Step 2. Run ELEVATED, after the reboot from step 1.

  Creates the lab VM and boots the Windows installer. You click through Windows setup once;
  everything after that is scripted. Aim for a LOCAL account named 'lab' - PowerShell Direct
  in Test.ps1 signs in with it, and a Microsoft account cannot be used that way.
#>
[CmdletBinding()]
param(
    [string]$VMName   = 'Home',
    [string]$Root     = 'C:\VMs',
    [Parameter(Mandatory)] [string]$IsoPath,
    [int]$MemoryGB    = 6,
    [int]$DiskGB      = 64,
    [int]$CPU         = 4
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Hyper-V)) { throw 'Hyper-V module missing - did step 1 reboot happen?' }
if (-not (Test-Path -LiteralPath $IsoPath))   { throw "ISO not found: $IsoPath" }
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { throw "VM '$VMName' already exists." }

New-Item -ItemType Directory -Force -Path $Root | Out-Null
$vhd = Join-Path $Root "$VMName.vhdx"

# Gen 2 is required: Win11 wants UEFI, Secure Boot and a TPM, and refuses setup without them.
$vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB*1GB) `
             -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB*1GB) -Path $Root -SwitchName 'Default Switch'

Set-VMMemory   $VMName -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes ($MemoryGB*2GB)
Set-VMProcessor $VMName -Count $CPU

# Win11 setup hard-fails without these two.
Set-VMKeyProtector $VMName -NewLocalKeyProtector
Enable-VMTPM      $VMName
Set-VMFirmware    $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

# Automatic checkpoints fire on every start and would sit on top of the CLEAN baseline,
# turning a 3-second revert into a chain walk. Standard checkpoints save memory state,
# which is what makes the revert resume at a desktop instead of booting.
Set-VM $VMName -AutomaticCheckpointsEnabled $false -CheckpointType Standard `
               -AutomaticStartAction Nothing -AutomaticStopAction TurnOff

# Lets the host push files into the guest without any network configuration.
Enable-VMIntegrationService $VMName -Name 'Guest Service Interface'

Add-VMDvdDrive  $VMName -Path $IsoPath
$dvd = Get-VMDvdDrive $VMName
Set-VMFirmware  $VMName -FirstBootDevice $dvd

Start-VM $VMName
Start-Process vmconnect.exe -ArgumentList 'localhost', $VMName

Write-Host ''
Write-Host "VM '$VMName' created and booting the installer." -ForegroundColor Green
Write-Host 'Press a key quickly at "Press any key to boot from CD" or it falls through to PXE.'
Write-Host ''
Write-Host 'During setup:' -ForegroundColor Cyan
Write-Host '  - Shift+F10 then: start ms-cxh:localonly   (forces a LOCAL account on recent builds)'
Write-Host '  - Username: lab     Password: set one and remember it'
Write-Host ''
Write-Host 'When you are at the desktop, run 3-Set-Baseline.ps1 on the HOST.'
