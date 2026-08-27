#requires -Version 5.1
<#
  Freeze the VM's CURRENT state as a new baseline - for changes you made by hand in the
  guest, rather than through a script (Update-Baseline.ps1 covers the scripted case).

    lab                              # start from a clean VM  <-- do this first
    ...make your changes in the VM...
    .\Save-Baseline.ps1 -To CLEAN-v3           # save it, keep the old one as default
    .\Save-Baseline.ps1 -To CLEAN-v3 -Promote  # save it AND make it what Test.ps1 uses

  Runs on the HOST. Whatever is in the guest right now becomes what every future test
  starts from - so start from a clean VM and change only what you mean to.
#>
[CmdletBinding()]
param(
    [string]$VMName = 'AppLab',
    [Parameter(Mandatory)] [string]$To,
    [string]$Current = 'CLEAN',
    [switch]$Promote,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName
if ($vm.State -ne 'Running') { throw "$VMName is not running - nothing to capture." }
if (Get-VMCheckpoint -VMName $VMName -Name $To -EA SilentlyContinue) {
    throw "Checkpoint '$To' already exists - pick another name."
}

# The usual way this goes wrong is capturing after a test run, which bakes that test's
# installs and registry debris into the baseline for good.
if (-not $Force) {
    Write-Host "About to freeze the CURRENT state of $VMName as '$To'." -ForegroundColor Yellow
    Write-Host 'Everything in the guest right now - including anything a test left behind -' -ForegroundColor Yellow
    Write-Host 'becomes what every future run starts from.' -ForegroundColor Yellow
    if ((Read-Host 'Continue? (y/N)') -ne 'y') { Write-Host 'cancelled'; return }
}

Write-Host "checkpointing as '$To' ..." -NoNewline
Checkpoint-VM -Name $VMName -SnapshotName $To      # Standard: captures memory as well as disk
Write-Host ' done'

if ($Promote) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $old   = "$Current-old-$stamp"
    if (Get-VMCheckpoint -VMName $VMName -Name $Current -EA SilentlyContinue) {
        # Renamed, never deleted - a baseline costs a few GB and is expensive to rebuild.
        Rename-VMCheckpoint -VMName $VMName -Name $Current -NewName $old
        Write-Host "previous baseline kept as '$old'"
    }
    Rename-VMCheckpoint -VMName $VMName -Name $To -NewName $Current
    Write-Host "'$To' is now '$Current' - plain .\Test.ps1 uses it" -ForegroundColor Green
} else {
    Write-Host "try it:  .\Test.ps1 -VMName $VMName -Checkpoint $To" -ForegroundColor Green
}

Get-VMCheckpoint -VMName $VMName | Select-Object Name,ParentSnapshotName | Format-Table -AutoSize
