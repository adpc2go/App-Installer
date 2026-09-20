<#
.SYNOPSIS
    The copy engine's rails no other suite reaches, through the real worker: junctions in the
    verify pass, extra files at the destination, the manifest across two runs, the Public
    self-copy loop, a folder backup to a network path, and a restore that must not roll back.

.DESCRIPTION
    Each case was a defect found by reading Copy-ProfileData against a real profile:

      1. JUNCTIONS. The copy skips them (/XJ); the listing that verified the copy did not, so
         every backup of Documents (My Pictures is a junction) reported files "missing".
      2. EXTRA FILES. /NC strips the *EXTRA tag, so files that exist only at the destination
         were counted as bytes just copied - a repeat backup reported the previous one's size.
      3. MANIFEST. A second backup into the same folder REPLACED the manifest, so items from the
         first run were refused at restore as "not an item of this backup".
      4. PUBLIC. The self-copy guard compared the destination with the profile root only; a
         backup folder under C:\Users\Public with Public ticked copied Public into itself.
      5. NETWORK. A folders-and-drives backup has no profile root, and '' + '\' is '\' - which
         every UNC path starts with - so a backup of picked folders to a share was refused as
         "inside the profile" every time. (Elevated only: it needs \\localhost\C$.)
      6. RESTORE. robocopy replaces a newer file at the destination with the backup's older
         copy by default; a restore into a live account rolled back a week of edits.

    Runs unelevated (case 5 is skipped, with a note, when not elevated). The one write into
    a real profile is a restore that must change NOTHING - it is asserted by hash. Everything
    else lives under %TEMP% and C:\Users\Public and is removed at the end.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-BackupRails.ps1
#>
[CmdletBinding()]
param([string]$ScriptPath, [switch]$KeepArtefacts)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
if (-not $ScriptPath) { $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) { Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray }

$elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- the worker, verbatim
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")

$tag  = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP "pc2go-bkrails-$tag"
$pub  = Join-Path $env:PUBLIC "pc2go-bkr-$tag"
foreach ($d in @($root, $pub)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$workerPath = Join-Path $root 'worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$me = (Get-Item -LiteralPath $env:USERPROFILE).FullName.TrimEnd([char]92)
$script:RunNo = 0
Write-Host "Sandbox: $root  /  $pub" -ForegroundColor DarkGray

function Invoke-Worker([object[]]$Entries) {
    $script:RunNo++
    $dir = Join-Path $root "run$($script:RunNo)"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $q = Join-Path $dir 'queue.jsonl'; $s = Join-Path $dir 'status.jsonl'
    foreach ($e in $Entries) { Add-Content -LiteralPath $q -Value ($e | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8 }
    Add-Content -LiteralPath $q -Value '{"end":true}' -Encoding UTF8
    $t0 = Get-Date
    Start-Process -FilePath $psExe -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$q`"", '-StatusFile', "`"$s`"", '-CancelFile', "`"$(Join-Path $dir 'cancel.flag')`"") | Out-Null
    Write-Host ("  worker run {0}: {1:N1}s" -f $script:RunNo, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $s -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id -and $r.state -in 'Applied', 'Failed', 'Skipped', 'Cancelled') { $out[[string]$r.id] = $r }
    }
    return $out
}
function New-Paths([string]$Id, [string[]]$Paths, [string]$Dst) {
    @{ id = $Id; action = 'migrate'; srcKind = 'paths'; paths = @($Paths); src = ''; dstUser = ''; dstPath = $Dst; dstKind = 'folder'; items = @() }
}
function Get-Manifest([string]$Dir) { try { (Get-Content -LiteralPath (Join-Path $Dir 'pc2go-backup.json') -Raw) | ConvertFrom-Json } catch { $null } }

try {
    # ================================================================== 1-3. paths backups
    Write-Section '1. A junction inside the source is skipped by the copy AND by the verify'
    $src1 = Join-Path $pub 'src1'
    New-Item -ItemType Directory -Force -Path (Join-Path $src1 'real') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $src1 'real\a.bin'), (New-Object byte[] 20480))
    [IO.File]::WriteAllBytes((Join-Path $src1 'plain.bin'), (New-Object byte[] 4096))
    New-Item -ItemType Junction -Path (Join-Path $src1 'link') -Target (Join-Path $src1 'real') | Out-Null
    Assert-True 'precondition: the junction resolves' (Test-Path -LiteralPath (Join-Path $src1 'link\a.bin'))
    $bk1 = Join-Path $pub 'bk1'; New-Item -ItemType Directory -Force -Path $bk1 | Out-Null
    $dst1 = Join-Path $bk1 'backup'
    $r = Invoke-Worker @((New-Paths 'j1' @($src1) $dst1))
    Assert-Equal 'the backup is Applied - no file reported missing'  'Applied' $r['j1'].state
    Assert-True  'and its detail says nothing about missing files'   ($r['j1'].detail -notlike '*missing*')
    Assert-True  'the real files arrived'                            ((Test-Path -LiteralPath (Join-Path $dst1 'src1\plain.bin')) -and (Test-Path -LiteralPath (Join-Path $dst1 'src1\real\a.bin')))
    Assert-True  'the junction was not copied as a second tree'      (-not (Test-Path -LiteralPath (Join-Path $dst1 'src1\link\a.bin')))
    $m1 = Get-Manifest $dst1
    Assert-True  'the manifest calls the folder verified'            ($m1 -and @($m1.items | Where-Object { $_.rel -eq 'src1' -and $_.verified }).Count -eq 1)

    Write-Section '2. Files that exist only at the destination are not counted as copied'
    [IO.File]::WriteAllBytes((Join-Path $dst1 'src1\extra.bin'), (New-Object byte[] 1048576))
    $r = Invoke-Worker @((New-Paths 'j2' @($src1) $dst1))
    Assert-Equal 'the repeat run is Applied'                          'Applied' $r['j2'].state
    Assert-True  'it reports far less than the 1 MB that was only ever at the destination' ([long]$r['j2'].bytes -lt 1048576)
    Assert-True  'the extra file is left where it was'               (Test-Path -LiteralPath (Join-Path $dst1 'src1\extra.bin'))

    Write-Section '3. A second backup into the same folder MERGES the manifest'
    $src2 = Join-Path $pub 'src2'
    New-Item -ItemType Directory -Force -Path $src2 | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $src2 'b.bin'), (New-Object byte[] 2048))
    $r = Invoke-Worker @((New-Paths 'j3' @($src2) $dst1))
    Assert-Equal 'the second backup is Applied'                       'Applied' $r['j3'].state
    $m3 = Get-Manifest $dst1
    $rels = @($m3.items | ForEach-Object { [string]$_.rel })
    Assert-True  'the manifest now names BOTH folders'                (($rels -contains 'src1') -and ($rels -contains 'src2'))
    Assert-Equal 'each exactly once'                                  2 @($rels | Where-Object { $_ -in 'src1', 'src2' }).Count
    Assert-True  'the kept item still says where it came from'       (@($m3.items | Where-Object { $_.rel -eq 'src1' -and ('' + $_.source) -eq $src1 }).Count -eq 1)

    # ================================================================== 4. Public
    Write-Section '4. Public ticked, with the backup folder under C:\Users\Public: refused, not recursed'
    $pubBk = Join-Path $pub 'pubbk'; New-Item -ItemType Directory -Force -Path $pubBk | Out-Null
    $pubDst = Join-Path $pubBk 'backup'
    $r = Invoke-Worker @(@{ id = 'pub'; action = 'migrate'; src = $me; dstUser = ''; dstPath = $pubDst; dstKind = 'folder'; items = @('Public') })
    Assert-Equal 'the job fails rather than copying Public into itself' 'Failed' $r['pub'].state
    Assert-True  'and says exactly why'                               ($r['pub'].detail -like '*Public (refused*inside it*')
    Assert-True  'nothing was written under the backup folder'       (-not (Test-Path -LiteralPath (Join-Path $pubDst 'Public')))

    # ================================================================== 5. UNC
    Write-Section '5. Folders-and-drives backup to a network path'
    if ($elevated) {
        $uncDir = Join-Path $pub 'unc'; New-Item -ItemType Directory -Force -Path $uncDir | Out-Null
        $unc = '\\localhost\C$' + ($uncDir.Substring(2)) + '\backup'
        $r = Invoke-Worker @((New-Paths 'unc' @($src2) $unc))
        Write-Host "  unc> $($r['unc'].state): $($r['unc'].detail)" -ForegroundColor DarkGray
        Assert-True  'is NOT refused as "inside the profile"'          ($r['unc'].detail -notlike '*inside the profile*')
        Assert-Equal 'and is Applied'                                  'Applied' $r['unc'].state
        Assert-True  'with the file landed through the share'         (Test-Path -LiteralPath (Join-Path $uncDir 'backup\src2\b.bin'))
    } else {
        Write-Host '  (skipped: needs an elevated session for \\localhost\C$)' -ForegroundColor Yellow
    }

    # ================================================================== 6. restore keeps newer
    Write-Section '6. A restore into a live account keeps the file the account has changed since'
    $item = 'Searches'; if (-not (Test-Path -LiteralPath (Join-Path $me $item))) { $item = 'Links' }
    $victim = @(Get-ChildItem -LiteralPath (Join-Path $me $item) -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    if (-not $victim) {
        Write-Host "  (skipped: $item holds no file to test with)" -ForegroundColor Yellow
    } else {
        $xoBk = Join-Path $pub 'xo'; New-Item -ItemType Directory -Force -Path $xoBk | Out-Null
        $xoDst = Join-Path $xoBk 'backup'
        $r = Invoke-Worker @(@{ id = 'bk'; action = 'migrate'; src = $me; dstUser = ''; dstPath = $xoDst; dstKind = 'folder'; items = @($item) })
        Assert-Equal 'the backup of the item is Applied'                'Applied' $r['bk'].state
        $inBackup = Join-Path $xoDst (Join-Path $item $victim.Name)
        Assert-True  'the file is in the backup'                        (Test-Path -LiteralPath $inBackup)
        $before = (Get-FileHash -LiteralPath $victim.FullName -Algorithm SHA256).Hash
        # the backup's copy becomes OLDER and different - the shape of a week-old backup
        # (attributes first: the copy keeps the original's hidden/read-only bits, and a write
        # through those is refused)
        (Get-Item -LiteralPath $inBackup -Force).Attributes = 'Normal'
        [IO.File]::WriteAllBytes($inBackup, [Text.Encoding]::ASCII.GetBytes('stale backup copy'))
        (Get-Item -LiteralPath $inBackup -Force).LastWriteTime = [datetime]'2000-01-01'
        $r = Invoke-Worker @(@{ id = 'rst'; action = 'migrate'; src = $xoDst; srcKind = 'folder'; dstUser = "$env:USERNAME"; dstPath = $me; dstKind = 'profile'; items = @($item) })
        Assert-True  'the restore ran'                                 ($r['rst'].state -in 'Applied', 'Skipped')
        Assert-Equal 'and the newer file in the account was NOT rolled back' $before ((Get-FileHash -LiteralPath $victim.FullName -Algorithm SHA256).Hash)
    }

    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($KeepArtefacts) { Write-Host "Artefacts kept: $root / $pub" -ForegroundColor Yellow }
    else {
        foreach ($d in @($pub, $root)) {
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
                # junctions first, so the delete never follows one into its target
                Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { try { $_.Delete() } catch { } }
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $left = @(@($pub, $root) | Where-Object { Test-Path -LiteralPath $_ })
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($left -join '; ')) -ForegroundColor Red } else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
