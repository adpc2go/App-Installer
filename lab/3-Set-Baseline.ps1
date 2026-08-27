#requires -Version 5.1
<#
  Step 3. Run ELEVATED on the HOST, once, with the guest sitting at its desktop.

  Prepares the guest, stores its credential for PowerShell Direct, and takes the one
  checkpoint you will ever take. After this, Test.ps1 is the only script you run.
#>
[CmdletBinding()]
param(
    [string]$VMName     = 'AppLab',
    [string]$Checkpoint = 'CLEAN',
    [string]$CredPath   = "$env:LOCALAPPDATA\AppLab\guest.cred.xml"
)

$ErrorActionPreference = 'Stop'
if ((Get-VM $VMName).State -ne 'Running') { throw "Start $VMName and log in first." }

Write-Host 'Guest credential (the LOCAL account you made during setup, e.g. lab):' -ForegroundColor Cyan
$cred = Get-Credential -Message "Local account inside $VMName"

# PowerShell Direct needs no network - it rides the VMBus. If this fails the account is
# almost certainly a Microsoft account rather than a local one.
Write-Host 'Testing PowerShell Direct ...'
$s = New-PSSession -VMName $VMName -Credential $cred
Write-Host ("  connected: " + (Invoke-Command $s { $env:COMPUTERNAME })) -ForegroundColor Green

Invoke-Command -Session $s {
    Set-ExecutionPolicy Bypass -Scope LocalMachine -Force
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null

    # A sleeping guest cannot be reached over PowerShell Direct, and the revert would then
    # look like a hang rather than a sleeping machine.
    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    # Baked into the baseline so every reverted run starts from the same footing.
    Set-MpPreference -SubmitSamplesConsent 2 -MAPSReporting 0 -ErrorAction SilentlyContinue
}

# The installer ISO has done its job; leaving it attached means a stray boot can land back
# in Windows setup and quietly overwrite the baseline.
Get-VMDvdDrive $VMName | Where-Object Path | Remove-VMDvdDrive
Remove-PSSession $s

New-Item -ItemType Directory -Force -Path (Split-Path $CredPath) | Out-Null
$cred | Export-Clixml -Path $CredPath   # DPAPI: only this Windows account can read it back
Write-Host "Credential saved to $CredPath"

Get-VMCheckpoint -VMName $VMName -Name $Checkpoint -ErrorAction SilentlyContinue |
    Remove-VMCheckpoint -Confirm:$false

# Taken while running, so it captures memory state - that is what makes the revert resume
# at a live desktop in seconds instead of cold-booting.
Write-Host "Taking checkpoint '$Checkpoint' ..."
Checkpoint-VM -Name $VMName -SnapshotName $Checkpoint

Write-Host ''
Write-Host "Baseline set. From now on: .\Test.ps1" -ForegroundColor Green
