<#
.SYNOPSIS
    The Optimize > Cleanup sub-tab against a REAL machine: the five one-time rows through the
    elevated worker, with planted files that must go and planted files that must NOT.
    Elevated; run it on a lab VM.

.DESCRIPTION
    Cleanup rows delete things, so what matters is as much what they leave alone as what they
    remove. Before anything runs, the harness plants:

      - junk in the technician's %TEMP% and in Windows\Temp        -> must be gone
      - a file sent to the technician's Recycle Bin                  -> must be gone
      - a fake C:\Windows.old with files in it                       -> must SURVIVE Disk Cleanup,
                                                                        go with the Windows.old row
      - a marker file in the technician's Downloads folder           -> must survive EVERYTHING
                                                                        (cleanmgr has a Downloads
                                                                        handler on this build)

    Then: Disk Cleanup alone, and the survival of Downloads, Windows.old and the Recycle Bin item
    is asserted, plus the StateFlags it set being cleared afterwards. Then the other four rows in
    one batch, and every planted item is checked again; services the Windows.old row stops are
    checked to be back in the state they started in; Undo reports every row as one-way.

    Wrecks nothing a lab VM cares about, but it IS the real cleanmgr and the real DISM - reset
    the VM afterwards all the same. Refuses non-lab host names unless -IKnowThisWrecksTheMachine.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-CleanupTab.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string[]]$AllowHosts = @('DESKTOP-854BGVS', 'DESKTOP-RTRU0VA'),
    [switch]$IKnowThisWrecksTheMachine,
    [switch]$SkipComponentStore   # DISM can take a long time; the other four still run
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $repo) { $repo = $here }
if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and
         (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
if (-not $ScriptPath) { $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

$elevated = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'This harness runs the real cleanup rows and needs an elevated PowerShell.' }
if (($AllowHosts -notcontains $env:COMPUTERNAME) -and -not $IKnowThisWrecksTheMachine) {
    throw "$env:COMPUTERNAME is not a lab VM. Pass -IKnowThisWrecksTheMachine to run the real cleanup rows here anyway."
}

# ------------------------------------------------------------------ extraction
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
if (-not $startIdx) { throw 'Could not locate the $workerScript here-string.' }
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($var in '$script:DebloatPacks', '$script:OemBloatPatterns') {
    $as = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true) | Select-Object -First 1
    if (-not $as) { throw "Could not extract $var" }
    . ([scriptblock]::Create($as.Extent.Text))
}
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SharedTablesSource' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$workerBody = $workerBody.Replace('#__SHAREDTABLES__', (Get-SharedTablesSource))

$work = Join-Path $env:LOCALAPPDATA ("cleanuptab-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))   # NOT under %TEMP%: the tempfiles row empties that
New-Item -ItemType Directory -Force -Path $work | Out-Null
$workerPath = Join-Path $work 'worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:RunNo = 0
Write-Host ("machine {0}  build {1}  user {2}" -f $env:COMPUTERNAME, [Environment]::OSVersion.Version, $env:USERNAME) -ForegroundColor DarkGray

function Invoke-Worker([string[]]$Ids, [string]$Action = 'tweak') {
    $script:RunNo++
    $dir = Join-Path $work "run$($script:RunNo)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $queue = Join-Path $dir 'queue.jsonl'; $status = Join-Path $dir 'status.jsonl'; $cancel = Join-Path $dir 'cancel.flag'
    foreach ($id in $Ids) {
        Add-Content -LiteralPath $queue -Value (@{ id = "tweak-$id"; action = $Action; tweak = $id; userSid = $sid } | ConvertTo-Json -Compress) -Encoding UTF8
    }
    Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker run {0} ({1}): exit {2} after {3:N0}s" -f $script:RunNo, $Action, $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id) { $out[[string]$r.id] = $r }
    }
    foreach ($id in $Ids) { $r = $out["tweak-$id"]; if ($r) { Write-Host ("    {0,-15} {1,-8} {2}" -f $id, $r.state, $r.detail) -ForegroundColor DarkGray } }
    return $out
}

# ------------------------------------------------------------------ plant
Write-Section '0. Plant what must go and what must stay'
$tag = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$userTemp = Join-Path $env:LOCALAPPDATA 'Temp'
$junk = @()
foreach ($f in @("cleanup-$tag-a.tmp", "cleanup-$tag-b.log")) { $p = Join-Path $userTemp $f; Set-Content -LiteralPath $p -Value 'x'; $junk += $p }
$junkDir = Join-Path $userTemp "cleanup-$tag-dir"; New-Item -ItemType Directory -Force -Path $junkDir | Out-Null; Set-Content -LiteralPath (Join-Path $junkDir 'inner.txt') -Value 'x'; $junk += $junkDir
$winTemp = Join-Path $env:SystemRoot 'Temp'
$p = Join-Path $winTemp "cleanup-$tag-w.tmp"; Set-Content -LiteralPath $p -Value 'x'; $junk += $p
$downloads = Join-Path $env:USERPROFILE 'Downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$keep = Join-Path $downloads "keep-me-$tag.txt"; Set-Content -LiteralPath $keep -Value 'the client''s download'
$old = Join-Path $env:SystemDrive 'Windows.old'
if (-not (Test-Path -LiteralPath $old)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $old 'Windows\System32') | Out-Null
    Set-Content -LiteralPath (Join-Path $old 'Windows\System32\fake.dll') -Value 'x'
}
$binned = Join-Path $env:USERPROFILE "Desktop\binned-$tag.txt"; Set-Content -LiteralPath $binned -Value 'x'
$shell = New-Object -ComObject Shell.Application
$item = $shell.NameSpace((Split-Path $binned -Parent)).ParseName((Split-Path $binned -Leaf))
$item.InvokeVerb('delete')
Start-Sleep -Seconds 2
$bin = Join-Path $env:SystemDrive ('$Recycle.Bin\' + $sid)
function Get-BinCount { @(Get-ChildItem -LiteralPath $bin -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count }
$sd = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
$svcBefore = @{}
foreach ($s in 'wuauserv', 'bits', 'cryptsvc', 'msiserver') { $svcBefore[$s] = "$((Get-Service $s).Status)" }
Assert-True 'junk planted in the user''s temp and Windows\Temp' (@($junk | Where-Object { Test-Path -LiteralPath $_ }).Count -eq $junk.Count)
Assert-True 'a file is sitting in the user''s Recycle Bin' ((Get-BinCount) -gt 0)
Assert-True 'Windows.old exists' (Test-Path -LiteralPath $old)
Assert-True 'the Downloads marker exists' (Test-Path -LiteralPath $keep)
$vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
Write-Host ("  this build has a cleanmgr Downloads handler: {0}" -f (Test-Path -LiteralPath (Join-Path $vc 'DownloadsFolder'))) -ForegroundColor DarkGray

Write-Section '1. Disk Cleanup alone'
$r1 = Invoke-Worker @('diskcleanup')
Assert-Equal 'diskcleanup Applied' 'Applied' $r1['tweak-diskcleanup'].state
Assert-True 'the Downloads marker SURVIVED Disk Cleanup' (Test-Path -LiteralPath $keep)
Assert-True 'Windows.old SURVIVED Disk Cleanup (that is the CAUTION row''s job)' (Test-Path -LiteralPath $old)
Assert-True 'the Recycle Bin item SURVIVED Disk Cleanup (its own row)' ((Get-BinCount) -gt 0)
$flags = @(Get-ChildItem -LiteralPath $vc | Where-Object { $null -ne (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).StateFlags0064 }).Count
Assert-Equal 'every StateFlags0064 it set was cleared afterwards' 0 $flags

Write-Section ('2. Temp files, Recycle Bin, Windows.old' + $(if ($SkipComponentStore) { '' } else { ', Component Store' }))
$ids = @('tempfiles', 'recyclebin', 'windowsold') + $(if ($SkipComponentStore) { @() } else { @('componentstore') })
$runStart = Get-Date
$r2 = Invoke-Worker $ids
foreach ($id in $ids) { Assert-Equal "$id Applied" 'Applied' $r2["tweak-$id"].state }
Assert-Equal 'every planted temp item is gone' 0 @($junk | Where-Object { Test-Path -LiteralPath $_ }).Count
Assert-True 'tempfiles counted what it removed' ("$($r2['tweak-tempfiles'].detail)" -match '^\d+ temp item')
Assert-Equal 'the user''s Recycle Bin is empty' 0 (Get-BinCount)
Assert-Equal 'Windows.old is gone' $false (Test-Path -LiteralPath $old)
# Windows Update re-creates SharedFileCache seconds after its services come back, so "empty"
# means nothing that was there BEFORE the row ran is left - not that Windows has stayed idle.
# A freshly booted machine is mid-scan, and Windows Update holds the folder it is writing at that
# moment - the row cannot take that one and must not pretend it did. What is asserted is that
# every survivor is one the row REPORTED ("N could not be removed"), never a silent leftover.
$survivors = @(Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt $runStart }).Count
$reportedLeft = 0
if ("$($r2['tweak-windowsold'].detail)" -match '\((\d+) could not be removed') { $reportedLeft = [int]$Matches[1] }
Assert-Equal 'every update-cache item that survived was reported by the row' $reportedLeft $survivors
Assert-True  'and at most one was in use at the time'                        ($survivors -le 1)
# BITS is a trigger-start service that exits on its own after a couple of idle minutes, and
# the component-store row keeps DISM busy for longer than that - so it is checked for
# "not left disabled" rather than "still running"
foreach ($s in 'wuauserv', 'bits', 'cryptsvc', 'msiserver') {
    if ($s -eq 'bits') { Assert-True 'bits is startable again (not left Disabled)' ("$((Get-Service bits).StartType)" -ne 'Disabled'); continue }
    if ($svcBefore[$s] -eq 'Running') { Assert-Equal "$s is running again" 'Running' "$((Get-Service $s).Status)" }
}
Assert-True 'the Downloads marker survived everything' (Test-Path -LiteralPath $keep)
if (-not $SkipComponentStore) { Assert-True 'componentstore says completed' ("$($r2['tweak-componentstore'].detail)" -like 'component store cleanup completed*') }

Write-Section '3. Undo: every cleanup row is one-way and says so'
$all = @('diskcleanup', 'componentstore', 'tempfiles', 'recyclebin', 'windowsold')
$r3 = Invoke-Worker $all 'untweak'
foreach ($id in $all) { Assert-Equal "$id undo -> Skipped" 'Skipped' $r3["tweak-$id"].state }

Remove-Item -LiteralPath $keep -Force -ErrorAction SilentlyContinue
Write-Host ''
$colour = $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ("{0} passed, {1} failed   (work files: {2})" -f $script:Pass, $script:Fail, $work) -ForegroundColor $colour
if ($script:Fail) { exit 1 } else { exit 0 }
