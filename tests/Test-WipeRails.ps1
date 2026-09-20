<#
.SYNOPSIS
    The branches of the wipe and the uninstall that no other suite reaches, through the REAL
    elevated worker. Needs an elevated PowerShell.

.DESCRIPTION
    Test-DirtyCleanup proves the wipe removes what it is handed. Test-RealUninstall proves it
    closes a locked file first. What neither reaches is the rest of Remove-Stubborn's ladder -
    take ownership when an admin is refused, and schedule for the next boot when even that is
    not enough - nor the refusals Wipe-One makes on the elevated side, nor the bare-name and
    exit-code branches of Uninstall-One.

      1. Remove-Stubborn: a plain folder; a file held open by another process (the holder is
         closed and the folder goes); a folder an administrator is denied (ownership is taken
         and the folder goes); a folder pinned as another process's working directory, which
         no holder can be found for and ownership cannot fix (scheduled for the next restart,
         and this harness UNSCHEDULES it again).
      2. Wipe-One refusals and reasons: a protected root; a registry value outside an autostart
         key; an autostart value that IS removed; a removal tool with the wrong hash, whose
         reason must reach the activity log rather than die as "1 could not be removed".
      3. Uninstall-One: a bare command name is pinned to System32 with or without .exe;
         1641 is a removal, not a failure; a non-zero exit with the detect target gone is
         reported as removed with the code named.
      4. Test-UnRowGone, the already-removed guard on the uninstall sheet.

    Everything lives under C:\Users\Public\WipeRails-<tag> and in HKCU keys this harness owns,
    and the finally block removes all of it - including the PendingFileRenameOperations entry
    the reboot branch writes, which is filtered out by path so nothing else in that value is
    touched.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-WipeRails.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$KeepArtefacts
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
if (-not $elevated) { throw 'This harness takes ownership of files and needs an elevated PowerShell. Run it as administrator.' }

# ------------------------------------------------------------------ extraction
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
if (-not $startIdx) { throw 'Could not locate the $workerScript here-string.' }
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")

$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($name in 'ConvertTo-PSRegPath', 'Test-UnRowGone') {
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "Could not extract function $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# ------------------------------------------------------------------ sandbox
$tag     = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path 'C:\Users\Public' "WipeRails-$tag"
$work    = Join-Path $sandbox 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$workerPath = Join-Path $work 'worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sid    = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$softKey = "HKCU:\SOFTWARE\PC2GoWipeRails-$tag"
$unKey   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoWipeRails-$tag"
$runName = "PC2GoWipeRails-$tag"
$pfroKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$holder  = $null
$holder2 = $null
$script:RunNo = 0
Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray
Write-Host ("Extracted worker ({0} lines)" -f ($endIdx - $startIdx - 1)) -ForegroundColor DarkGray

# one worker run per call; returns @{ Status = id -> last record; Activity = every activity record }
function Invoke-Worker([object[]]$Entries) {
    $script:RunNo++
    $dir = Join-Path $work "run$($script:RunNo)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $queue = Join-Path $dir 'queue.jsonl'; $status = Join-Path $dir 'status.jsonl'; $cancel = Join-Path $dir 'cancel.flag'
    foreach ($e in $Entries) { Add-Content -LiteralPath $queue -Value ($e | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8 }
    Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker run {0}: exit {1} after {2:N1}s" -f $script:RunNo, $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id) { $out[[string]$r.id] = $r }
    }
    $act = @()
    foreach ($l in @(Get-Content -LiteralPath (Join-Path $dir 'activity.jsonl') -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r) { $act += $r }
    }
    return @{ Status = $out; Activity = $act }
}
function New-Wipe([string]$Id, [object[]]$Targets) {
    @{ id = $Id; action = 'wipe'; userSid = $sid; targets = @($Targets) }
}
function Get-PendingRenames {
    try { return @((Get-ItemProperty -LiteralPath $pfroKey -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations) }
    catch { return @() }
}
# drop every entry that names the sandbox (and the empty "destination" that follows each one);
# everything else in the value is somebody else's and stays exactly as it was
function Remove-SandboxPendingRenames {
    $cur = Get-PendingRenames
    if (-not $cur.Count) { return 0 }
    $keep = New-Object Collections.ArrayList
    $dropped = 0
    for ($i = 0; $i -lt $cur.Count; $i += 2) {
        $srcE = '' + $cur[$i]
        $dstE = $(if (($i + 1) -lt $cur.Count) { '' + $cur[$i + 1] } else { '' })
        if ($srcE -like "*$sandbox*" -or $dstE -like "*$sandbox*") { $dropped++; continue }
        [void]$keep.Add($srcE); [void]$keep.Add($dstE)
    }
    if ($dropped) {
        if ($keep.Count) { Set-ItemProperty -LiteralPath $pfroKey -Name PendingFileRenameOperations -Value ([string[]]$keep) -Type MultiString }
        else { Remove-ItemProperty -LiteralPath $pfroKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue }
    }
    return $dropped
}

try {
    # ================================================================== 1. Remove-Stubborn
    Write-Section '1. Remove-Stubborn: plain, locked, owner-denied, pinned-until-reboot'

    $plain = Join-Path $sandbox 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    Set-Content -LiteralPath (Join-Path $plain 'a.txt') -Value 'x' -Encoding ASCII

    $lockedDir = Join-Path $sandbox 'locked'
    New-Item -ItemType Directory -Force -Path $lockedDir | Out-Null
    $lockFile = Join-Path $lockedDir 'hold.dat'
    Set-Content -LiteralPath $lockFile -Value 'held' -Encoding ASCII
    # a separate process holds the file with FileShare.None for as long as it lives
    $holder = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-Command',
        "`$f = [IO.File]::Open('$lockFile', 'Open', 'Read', 'None'); Start-Sleep -Seconds 300")
    $locked = $false
    for ($i = 0; $i -lt 40 -and -not $locked; $i++) {
        Start-Sleep -Milliseconds 250
        try { $t = [IO.File]::Open($lockFile, 'Open', 'Read', 'None'); $t.Dispose() } catch { $locked = $true }
    }
    Assert-True 'precondition: the file is held open by another process' $locked

    $owned = Join-Path $sandbox 'owned'
    New-Item -ItemType Directory -Force -Path $owned | Out-Null
    Set-Content -LiteralPath (Join-Path $owned 'b.txt') -Value 'x' -Encoding ASCII
    # SYSTEM alone on the ACL: an administrator is simply not on it, which is what a
    # TrustedInstaller-owned or another user's folder looks like to the worker
    & "$env:SystemRoot\System32\icacls.exe" $owned /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /T /Q | Out-Null
    $adminRefused = $false
    try { Remove-Item -LiteralPath $owned -Recurse -Force -ErrorAction Stop } catch { $adminRefused = $true }
    Assert-True 'precondition: a plain delete is refused to this administrator' ($adminRefused -and (Test-Path -LiteralPath $owned))

    $held = Join-Path $sandbox 'held'
    New-Item -ItemType Directory -Force -Path $held | Out-Null
    Set-Content -LiteralPath (Join-Path $held 'c.txt') -Value 'x' -Encoding ASCII
    # A folder that is another process's WORKING DIRECTORY cannot be deleted, and Restart Manager
    # names no holder for it - it lists files, not directories. So there is nothing to close and
    # nothing ownership can fix: the only way out is the kernel at the next boot. (An explicit
    # deny ACE was tried first and is not reliable: a plain delete sometimes goes through it.)
    $holder2 = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden -WorkingDirectory $held -ArgumentList @(
        '-NoProfile', '-Command', 'Start-Sleep -Seconds 300')
    $heldRefused = $false
    for ($i = 0; $i -lt 40 -and -not $heldRefused; $i++) {
        Start-Sleep -Milliseconds 250
        try { [IO.Directory]::Delete($held) } catch { $heldRefused = $true }
    }
    Assert-True 'precondition: the folder is pinned by another process''s working directory' ($heldRefused -and (Test-Path -LiteralPath $held))
    $pendingBefore = @(Get-PendingRenames | Where-Object { $_ -like "*$sandbox*" }).Count

    $r1 = Invoke-Worker @(
        (New-Wipe 'plain'  @(@{ type = 'file'; path = $plain;     name = '' })),
        (New-Wipe 'locked' @(@{ type = 'file'; path = $lockedDir; name = '' })),
        (New-Wipe 'owned'  @(@{ type = 'file'; path = $owned;     name = '' })),
        (New-Wipe 'held'   @(@{ type = 'file'; path = $held;      name = '' }))
    )
    $s = $r1.Status
    Assert-Equal 'plain: Cleaned'                             'Cleaned' $s['plain'].state
    Assert-True  'plain: 1 trace removed'                     ($s['plain'].detail -like '1 trace(s) removed*')
    Assert-True  'plain: the folder is gone'                  (-not (Test-Path -LiteralPath $plain))

    Assert-Equal 'locked: Cleaned'                            'Cleaned' $s['locked'].state
    Assert-True  'locked: the holder process was closed'      ($holder.HasExited)
    Assert-True  'locked: and the folder is gone'             (-not (Test-Path -LiteralPath $lockedDir))

    Assert-Equal 'owner-denied: Cleaned'                      'Cleaned' $s['owned'].state
    Assert-True  'owner-denied: ownership was taken and the folder is gone' (-not (Test-Path -LiteralPath $owned))

    Assert-Equal 'held: Cleaned (a wipe it could schedule is not a failure)' 'Cleaned' $s['held'].state
    Assert-True  'held: reported as scheduled for the next restart' ($s['held'].detail -like '*1 scheduled for next restart*')
    Assert-True  'held: the folder is still there right now'  (Test-Path -LiteralPath $held)
    Assert-True  'held: the process pinning it was NOT killed - it was not a file holder' (-not $holder2.HasExited)
    $pendingAfter = @(Get-PendingRenames | Where-Object { $_ -like "*$sandbox*" }).Count
    Assert-True  'held: PendingFileRenameOperations names the sandbox' ($pendingAfter -gt $pendingBefore)
    $dropped = Remove-SandboxPendingRenames
    Assert-True  'held: and the harness unscheduled it again'  ($dropped -ge 1 -and @(Get-PendingRenames | Where-Object { $_ -like "*$sandbox*" }).Count -eq 0)
    try { Stop-Process -Id $holder2.Id -Force -ErrorAction SilentlyContinue } catch { }

    # ================================================================== 2. refusals and reasons
    Write-Section '2. Wipe-One: refusals on the elevated side, and the reason surviving'

    New-Item -Path $softKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $softKey -Name 'Keep' -Value 'do not touch'
    Set-ItemProperty -LiteralPath $runKey -Name $runName -Value "`"$sandbox\gone.exe`""
    $probeFile = Join-Path $sandbox 'probe.txt'
    Set-Content -LiteralPath $probeFile -Value 'x' -Encoding ASCII
    $fakeTool = Join-Path $sandbox 'fake-remover.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination $fakeTool -Force

    $r2 = Invoke-Worker @(
        (New-Wipe 'root'    @(@{ type = 'file'; path = $env:ProgramFiles; name = '' })),
        (New-Wipe 'regval'  @(@{ type = 'regvalue'; path = $softKey; name = 'Keep' })),
        (New-Wipe 'autorun' @(@{ type = 'regvalue'; path = $runKey; name = $runName })),
        (New-Wipe 'badhash' @(@{ type = 'run'; path = 'https://example.invalid/remover.exe'; name = 'Fake remover'
                                  args = ''; file = $fakeTool; sha256 = ('0' * 64) })),
        (New-Wipe 'hive'    @(@{ type = 'reg'; path = 'HKLM\SOFTWARE'; name = '' }))
    )
    $s = $r2.Status; $a = $r2.Activity
    Assert-True  'a protected root is refused'                    ($s['root'].detail -like '*1 could not be removed*')
    Assert-True  'and Program Files is still there'               (Test-Path -LiteralPath $env:ProgramFiles)
    Assert-True  'the refusal is logged with the reason'          (@($a | Where-Object { $_.id -eq 'root' -and $_.state -eq 'Refused' -and $_.detail -like '*protected*' }).Count -eq 1)

    Assert-True  'a value outside an autostart key is refused'    ($s['regval'].detail -like '*1 could not be removed*')
    Assert-Equal 'and the value survived'                         'do not touch' ((Get-ItemProperty -LiteralPath $softKey -Name Keep).Keep)
    Assert-True  'with the reason logged'                         (@($a | Where-Object { $_.id -eq 'regval' -and $_.state -eq 'Refused' -and $_.detail -like '*not an autostart entry*' }).Count -eq 1)

    Assert-Equal 'an autostart value is removed'                  'Cleaned' $s['autorun'].state
    Assert-True  'and is really gone from Run'                    ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue))

    Assert-True  'a removal tool with the wrong hash counts as failed' ($s['badhash'].detail -like '*1 could not be removed*')
    $why = @($a | Where-Object { $_.id -eq 'badhash' -and $_.phase -eq 'wipe' -and $_.state -eq 'Failed' })
    Assert-Equal 'and the REASON reached the activity log'        1 $why.Count
    Assert-True  'naming the integrity check'                     ($why.Count -and $why[0].detail -like '*integrity check*')
    Assert-True  'the tool itself was never run from the cache'   (Test-Path -LiteralPath $fakeTool)

    Assert-True  'a hive trunk is refused'                        ($s['hive'].detail -like '*1 could not be removed*')
    Assert-True  'and logged as such'                             (@($a | Where-Object { $_.id -eq 'hive' -and $_.state -eq 'Refused' }).Count -eq 1)

    # ================================================================== 3. Uninstall-One
    Write-Section '3. Uninstall-One: bare command names, 1641, and a non-zero exit with the product gone'

    New-Item -Path $unKey -Force | Out-Null
    $r3 = Invoke-Worker @(
        # 'cmd' has no separator and no extension: it must be pinned to System32\cmd.exe
        @{ id = 'bare';   action = 'uninstall'; command = 'cmd';     args = '/c exit 0';    detect = ''; silent = $true; userSid = $sid },
        @{ id = 'bareexe'; action = 'uninstall'; command = 'cmd.exe'; args = '/c exit 0';   detect = ''; silent = $true; userSid = $sid },
        @{ id = 'reboot'; action = 'uninstall'; command = 'cmd.exe'; args = '/c exit 1641'; detect = ''; silent = $true; userSid = $sid },
        # the uninstaller deletes the detect key and STILL returns 1 - the key is the verdict
        @{ id = 'grumpy'; action = 'uninstall'; command = 'cmd.exe'
           args = "/c reg delete `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoWipeRails-$tag`" /f >nul 2>&1 & exit 1"
           detect = $unKey; silent = $true; userSid = $sid },
        @{ id = 'still';  action = 'uninstall'; command = 'cmd.exe'; args = '/c exit 0'
           detect = $softKey; silent = $true; userSid = $sid },
        @{ id = 'missing'; action = 'uninstall'; command = "$sandbox\nope\uninstall.exe"; args = ''; detect = ''; silent = $true; userSid = $sid },
        @{ id = 'nocmd';  action = 'uninstall'; command = ''; args = ''; detect = ''; silent = $true; userSid = $sid }
    )
    $s = $r3.Status; $a = $r3.Activity
    $started = @($a | Where-Object { $_.id -eq 'bare' -and $_.phase -eq 'uninstall' -and $_.state -eq 'Started' })
    Assert-Equal 'a bare name is Uninstalled'                     'Uninstalled' $s['bare'].state
    Assert-True  'and was pinned to System32\cmd.exe'             ($started.Count -and $started[0].detail -like "*\System32\cmd.exe /c exit 0*")
    Assert-Equal 'a bare name with .exe is Uninstalled too'       'Uninstalled' $s['bareexe'].state
    Assert-Equal '1641 (reboot initiated) is a removal'           'Uninstalled' $s['reboot'].state
    Assert-Equal 'exit 1 with the detect key gone is a removal'   'Uninstalled' $s['grumpy'].state
    Assert-True  'that names the code it returned'                ($s['grumpy'].detail -like '*exit code 1*')
    Assert-True  'and the key really is gone'                     (-not (Test-Path -LiteralPath $unKey))
    Assert-Equal 'exit 0 with the product still detected fails'   'Failed' $s['still'].state
    Assert-True  'saying it is still there'                       ($s['still'].detail -like '*still detected*')
    Assert-Equal 'a missing uninstaller fails'                    'Failed' $s['missing'].state
    Assert-True  'and says so'                                    ($s['missing'].detail -like '*not found*')
    Assert-Equal 'an entry with no command fails cleanly'         'Failed' $s['nocmd'].state
    Assert-True  'without a thrown exception as its text'         ($s['nocmd'].detail -notlike '*Exception*' -and $s['nocmd'].detail -like '*no uninstall command*')

    # ================================================================== 4. Test-UnRowGone
    Write-Section '4. Test-UnRowGone: the already-removed guard'

    $row = [pscustomobject]@{ DetectPath = $softKey }
    Assert-Equal 'a registry detect key that exists is not gone'   $false (Test-UnRowGone $row)
    $row.DetectPath = "$softKey-nope"
    Assert-Equal 'one that does not exist is gone'                 $true  (Test-UnRowGone $row)
    $row.DetectPath = ($softKey -replace '^HKCU:', 'HKEY_CURRENT_USER')
    Assert-Equal 'the HKEY_CURRENT_USER spelling is read the same' $false (Test-UnRowGone $row)
    $row.DetectPath = $probeFile
    Assert-Equal 'a file detect path that exists is not gone'     $false (Test-UnRowGone $row)
    $row.DetectPath = "$sandbox\never.exe"
    Assert-Equal 'a file that is missing is gone'                  $true  (Test-UnRowGone $row)
    $row.DetectPath = ''
    Assert-Equal 'no detect target is never called gone'           $false (Test-UnRowGone $row)

    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    foreach ($h in @($holder, $holder2)) {
        try { if ($h -and -not $h.HasExited) { Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    Start-Sleep -Milliseconds 500
    $left = @()
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $sandbox" -ForegroundColor Yellow
    } else {
        try { [void](Remove-SandboxPendingRenames) } catch { $left += 'PendingFileRenameOperations' }
        foreach ($k in @($softKey, $unKey)) { try { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        try { Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue } catch { }
        if (Test-Path -LiteralPath $sandbox) {
            # lift the deny and give ourselves the folders back before deleting them
            & "$env:SystemRoot\System32\icacls.exe" $sandbox /remove:d Everyone /T /C /Q 2>&1 | Out-Null
            & "$env:SystemRoot\System32\takeown.exe" /F $sandbox /R /D Y 2>&1 | Out-Null
            & "$env:SystemRoot\System32\icacls.exe" $sandbox /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
            try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop } catch { }
        }
        foreach ($p in @($sandbox, $softKey, $unKey)) { if (Test-Path -LiteralPath $p) { $left += $p } }
        if ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue)) { $left += "$runKey\$runName" }
        if (@(Get-PendingRenames | Where-Object { $_ -like "*$sandbox*" }).Count) { $left += 'PendingFileRenameOperations still names the sandbox' }
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($left -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
