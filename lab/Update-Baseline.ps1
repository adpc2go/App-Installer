#requires -Version 5.1
<#
  Change what every test run starts from.

    .\Update-Baseline.ps1 -ApplyFile .\guest-enable-rdp.ps1 -To CLEAN-v2

  Reverts to the existing baseline FIRST, so the change lands on a pristine guest rather
  than baking in whatever residue the last test left behind. Writes a NEW checkpoint by
  default - the old one survives until you delete it deliberately.
#>
[CmdletBinding()]
param(
    [string]$VMName   = 'Home',
    [string]$From     = 'CLEAN',
    [Parameter(Mandatory)] [string]$To,
    [Parameter(Mandatory)] [string]$ApplyFile,
    [string]$CredPath = "$env:LOCALAPPDATA\$VMName\guest.cred.xml"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ApplyFile)) { throw "Not found: $ApplyFile" }
if (Get-VMCheckpoint -VMName $VMName -Name $To -EA SilentlyContinue) {
    throw "Checkpoint '$To' already exists - pick another name or remove it first."
}
$cred = Import-Clixml $CredPath

Write-Host "reverting to '$From' ..." -NoNewline
Stop-VM $VMName -TurnOff -Force -EA SilentlyContinue
Restore-VMCheckpoint -VMName $VMName -Name $From -Confirm:$false
Start-VM $VMName
Write-Host ' done'

Write-Host 'waiting for guest ...' -NoNewline
$deadline = (Get-Date).AddSeconds(120); $s = $null
while ((Get-Date) -lt $deadline) {
    try { $s = New-PSSession -VMName $VMName -Credential $cred -EA Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
}
if (-not $s) { throw 'Guest did not answer PowerShell Direct within 120s.' }
Write-Host ' up'

Write-Host "applying $(Split-Path $ApplyFile -Leaf) ..."
Invoke-Command -Session $s -ScriptBlock ([scriptblock]::Create((Get-Content $ApplyFile -Raw))) |
    ForEach-Object { "  $_" }
Remove-PSSession $s

# Standard, and taken while running, so the revert resumes at a live desktop.
Write-Host "checkpointing as '$To' ..." -NoNewline
Checkpoint-VM -Name $VMName -SnapshotName $To
Write-Host ' done'

Write-Host ''
Write-Host "Test it:   .\Test.ps1 -Checkpoint $To" -ForegroundColor Green
Write-Host "Keep it:   Remove-VMCheckpoint -VMName $VMName -Name $From -Confirm:`$false; Rename-VMCheckpoint -VMName $VMName -Name $To -NewName $From" -ForegroundColor Green
