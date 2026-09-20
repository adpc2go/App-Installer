<#
.SYNOPSIS
    The Disk Management actions against a THROWAWAY virtual disk: shrink, extend, and extend past
    a recovery partition. Elevated; touches no real disk.

.DESCRIPTION
    The worker's Invoke-DiskAction is lifted out of the rendered worker (tools\Build-Client.ps1)
    and run in this process against a 6 GB VHDX laid out the way a real client machine is laid out:
    a system partition, a Windows-sized volume, the recovery partition Windows parked directly
    behind it, and free space behind that. Then:

      1. SHRINK the volume by 512 MB - the gap appears directly behind it, the byte count agrees.
      2. EXTEND it back into that gap - the volume is its old size again.
      3. The rails: a plain extend with the recovery partition in the way is refused, a shrink past
         the floor is refused naming the floor, a move on a non-volume is refused, and the recovery
         partition is still there afterwards.
      4. EXTEND PAST the recovery partition - the recovery partition is deleted, the volume grows
         into the space less 1 GB, a new 1 GB recovery partition sits at the END of the disk with
         the recovery GPT type, and a data file written before the move reads back unchanged.
      5. A second move is refused because nothing is left behind the recovery partition.

    The VHDX is not the boot disk, so the two ReAgentC steps (disable / re-enable Windows
    Recovery) are skipped by the function's own design - those run only on a machine's real
    Windows disk, and the lab VM is the place to watch them.

    Needs the Hyper-V PowerShell module (New-VHD, Mount-VHD) and elevation. Cleans up its VHDX.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-DiskTab.ps1
#>
[CmdletBinding()]
param([switch]$KeepVhd)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}" -f $What) -ForegroundColor Red
           Write-Host ("          expected [{0}]" -f $Expected) -ForegroundColor DarkGray
           Write-Host ("          actual   [{0}]" -f $Actual) -ForegroundColor DarkGray }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) { Write-Host ""; Write-Host "=== $Title" -ForegroundColor Cyan }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an elevated PowerShell: creating, partitioning and resizing a virtual disk needs it.'
}
if (-not (Get-Command New-VHD -ErrorAction SilentlyContinue)) { throw 'The Hyper-V PowerShell module (New-VHD) is not available on this machine.' }

# ---- the worker's disk functions, lifted verbatim from the rendered worker
. (Join-Path $repo 'tools\Build-Client.ps1') -NoBuild
$rendered = Get-RenderedWorker (Join-Path $repo 'server\AppDeploy.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$null)
foreach ($name in 'Get-DiskLdm', 'Format-SizeD', 'Invoke-DiskAction') {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "the rendered worker has no function $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:Statuses = New-Object Collections.ArrayList
function Write-Status { param($Id, $State, $Detail) [void]$script:Statuses.Add([pscustomobject]@{ Id = $Id; State = $State; Detail = $Detail }); Write-Host ("        {0,-9} {1}" -f $State, $Detail) -ForegroundColor DarkGray }
function Get-LastStatus { return $script:Statuses[$script:Statuses.Count - 1] }

$recoveryGpt = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$vhd = Join-Path $env:TEMP ('pc2go-disktab-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.vhdx')
$diskNo = -1
try {
    Write-Section '0. A throwaway disk laid out like a client machine'
    New-VHD -Path $vhd -SizeBytes 6GB -Dynamic | Out-Null
    $mounted = Mount-VHD -Path $vhd -PassThru
    $disk = $mounted | Get-Disk
    $diskNo = [int]$disk.Number
    Initialize-Disk -Number $diskNo -PartitionStyle GPT -Confirm:$false | Out-Null
    # system 100 MB, volume 2 GB, recovery 600 MB, ~3.3 GB free behind
    $sys = New-Partition -DiskNumber $diskNo -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $vol = New-Partition -DiskNumber $diskNo -Size 2GB -AssignDriveLetter
    Format-Volume -Partition $vol -FileSystem NTFS -NewFileSystemLabel 'ProbeOS' -Confirm:$false | Out-Null
    $rec = New-Partition -DiskNumber $diskNo -Size 600MB -GptType $recoveryGpt
    Format-Volume -Partition $rec -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false | Out-Null
    $vol = Get-Partition -DiskNumber $diskNo -PartitionNumber $vol.PartitionNumber
    $letter = ('' + $vol.DriveLetter).Trim([char]0)
    Assert-True 'the volume has a drive letter' ($letter.Length -eq 1)
    $probeFile = "${letter}:\probe.bin"
    $payload = New-Object byte[] (8MB); (New-Object Random 7).NextBytes($payload); [IO.File]::WriteAllBytes($probeFile, $payload)
    $probeHash = (Get-FileHash $probeFile -Algorithm SHA256).Hash
    $size0 = [long]$vol.Size
    Write-Host ("  disk {0}: system {1} MB, volume {2}: {3} MB, recovery {4} MB" -f $diskNo, [int]($sys.Size / 1MB), $letter, [int]($size0 / 1MB), [int]($rec.Size / 1MB))

    Write-Section '1. Shrink by 512 MB'
    Invoke-DiskAction ([pscustomobject]@{ id = 't1'; action = 'diskshrink'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]512MB })
    $st = Get-LastStatus
    Assert-Equal 'the shrink reports Applied' 'Applied' $st.State
    $vol = Get-Partition -DiskNumber $diskNo -PartitionNumber $vol.PartitionNumber
    Assert-Equal 'the volume is 512 MB smaller' ($size0 - 512MB) ([long]$vol.Size)
    Assert-True  'and says so' ($st.Detail -like "${letter}: shrunk by 512 MB - 512 MB is now unallocated behind it")
    Assert-True  'the probe file is intact' ((Get-FileHash $probeFile -Algorithm SHA256).Hash -eq $probeHash)

    Write-Section '2. Extend back into the gap'
    Invoke-DiskAction ([pscustomobject]@{ id = 't2'; action = 'diskextend'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]0 })
    $st = Get-LastStatus
    Assert-Equal 'the extend reports Applied' 'Applied' $st.State
    $vol = Get-Partition -DiskNumber $diskNo -PartitionNumber $vol.PartitionNumber
    Assert-Equal 'the volume is its old size again' $size0 ([long]$vol.Size)
    Assert-True  'the probe file is intact' ((Get-FileHash $probeFile -Algorithm SHA256).Hash -eq $probeHash)

    Write-Section '3. The rails, before anything destructive'
    Invoke-DiskAction ([pscustomobject]@{ id = 't3a'; action = 'diskextend'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]0 })
    Assert-Equal 'a plain extend with the recovery partition in the way is refused' 'Failed' (Get-LastStatus).State
    Assert-True  'saying there is nothing directly behind it' ((Get-LastStatus).Detail -like 'nothing to extend*into - there is no unallocated space directly behind it')
    Invoke-DiskAction ([pscustomobject]@{ id = 't3b'; action = 'diskshrink'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]100GB })
    Assert-Equal 'a shrink past the floor is refused' 'Failed' (Get-LastStatus).State
    Assert-True  'naming the most it can shrink' ((Get-LastStatus).Detail -like "${letter}: can shrink by at most *")
    Invoke-DiskAction ([pscustomobject]@{ id = 't3c'; action = 'diskextendmove'; disk = $diskNo; partition = $sys.PartitionNumber; bytes = [long]0 })
    Assert-Equal 'a move on the system partition is refused' 'Failed' (Get-LastStatus).State
    Assert-True  'untouched, and said so' ((Get-LastStatus).Detail -like '*only a volume with a drive letter is extended here*' -or (Get-LastStatus).Detail -like '*is not a recovery partition - it is not touched from here*')
    Assert-Equal 'the recovery partition is still there' 1 @(Get-Partition -DiskNumber $diskNo | Where-Object { ('' + $_.GptType).ToLower() -eq $recoveryGpt }).Count

    Write-Section '4. Extend past the recovery partition'
    $free0 = [long]$disk.Size - ([long]$rec.Offset + [long]$rec.Size)
    Invoke-DiskAction ([pscustomobject]@{ id = 't4'; action = 'diskextendmove'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]0 })
    $st = Get-LastStatus
    Assert-Equal 'the move-and-extend reports Applied' 'Applied' $st.State
    $vol = Get-Partition -DiskNumber $diskNo -PartitionNumber $vol.PartitionNumber
    $parts = @(Get-Partition -DiskNumber $diskNo | Sort-Object Offset)
    $newRec = @($parts | Where-Object { ('' + $_.GptType).ToLower() -eq $recoveryGpt })
    Assert-Equal 'exactly one recovery partition remains' 1 $newRec.Count
    Assert-True  'and it is the LAST partition on the disk' ($parts[-1].PartitionNumber -eq $newRec[0].PartitionNumber)
    Assert-True  'about 1 GB in size' ([long]$newRec[0].Size -ge 900MB -and [long]$newRec[0].Size -le 1100MB)
    Assert-True  'the volume grew by the old recovery partition plus the free space, less the reserve' ([long]$vol.Size -ge $size0 + $free0 + 600MB - 1100MB -and [long]$vol.Size -le $size0 + $free0 + 600MB - 900MB)
    Assert-True  'the volume now sits directly against the new recovery partition' (([long]$newRec[0].Offset - ([long]$vol.Offset + [long]$vol.Size)) -lt 2MB)
    Assert-True  'the probe file is intact after the move' ((Get-FileHash $probeFile -Algorithm SHA256).Hash -eq $probeHash)
    Assert-True  'the detail says what happened, in order' ($st.Detail -like "${letter}: extended by * to *; a new * recovery partition sits at the end of the disk")
    Assert-True  'ReAgentC was NOT touched - this is not the Windows disk' (@($script:Statuses | Where-Object { $_.Detail -like '*Windows Recovery*' }).Count -eq 0)

    Write-Section '5. Nothing left to extend into'
    Invoke-DiskAction ([pscustomobject]@{ id = 't5'; action = 'diskextendmove'; disk = $diskNo; partition = $vol.PartitionNumber; bytes = [long]0 })
    Assert-Equal 'a second move is refused' 'Failed' (Get-LastStatus).State
    Assert-True  'because the recovery partition has nothing behind it' ((Get-LastStatus).Detail -like 'there is no free space behind the recovery partition either*')
}
finally {
    if ($diskNo -ge 0) { try { Dismount-VHD -Path $vhd -ErrorAction SilentlyContinue } catch { } }
    if (-not $KeepVhd) { Remove-Item -LiteralPath $vhd -Force -ErrorAction SilentlyContinue } else { Write-Host "  VHDX kept: $vhd" }
}
Write-Host ""
Write-Host ("PASS {0}   FAIL {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
