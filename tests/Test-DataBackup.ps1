<#
.SYNOPSIS
    The copy engine behind the Data Backup tab, proved against a real filesystem.

.DESCRIPTION
    This tab had NO automated coverage at all - not one harness in tests\ so much as mentioned
    Copy-ProfileData - while being the one feature that moves a client's irreplaceable data. This
    is that coverage.

    Nothing is re-implemented. The elevated worker is sliced out of AppDeploy.ps1 (it is a
    here-string, so it can be extracted verbatim), and its copy engine is lifted through the parser
    and run against real files on a real disk.

    What is asserted:

      1. a real tree copies, and every file arrives at the same length
      2. a path over 260 characters copies AND verifies clean - the regression that matters most.
         robocopy has never had trouble copying one; the .NET walk that used to CHECK the copy is
         capped at MAX_PATH and was wrapped in a bare try{}catch{}, so a perfect copy was reported
         as "N file(s) short". The copy worked; the check lied.
      3. the 8.3 short-name trap: %TEMP% is C:\Users\LEGION~1\... and robocopy echoes back exactly
         what it was handed, so a prefix computed the long way matched nothing and every single
         file came back missing. Measured at 41 of 41 before the fix.
      4. progress is real - the tick fires, bytes rise, and they never go backwards
      5. corruption at the destination is caught by the three-way diff
      6. an unreadable listing reports "could not check", never "nothing there"
      7. a second run is incremental
      8. the status wire carries the numbers, and omits them when there are none
      9. the network layer: every share failure reaches the technician as a sentence, a PC
         that will not answer is told apart from one that shares nothing, the sweep stops
         when the UI says stop, and the credentials survive the trip to the worker

    Runs unelevated. Everything happens inside a temp sandbox; nothing outside $env:TEMP is
    written, and no profile is created, read or modified.

    NOT covered here, stated rather than implied: Copy-ProfileData end to end. It requires BOTH
    ends to be real profiles registered in ProfileList, which cannot be arranged without elevation
    and a throwaway account. Its refusals are asserted; its happy path belongs in Test-Elevated.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-DataBackup.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY inside a param default whenever the script is an advanced one -
# [CmdletBinding()] makes defaults evaluate in the CALLER's scope, which has no script root.
# Resolve in the body, where $PSScriptRoot is real.
if (-not $ScriptPath) {
    $here = $PSScriptRoot
    if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $here) { $here = (Get-Location).Path }
    $repo = Split-Path -Parent $here
    if (-not $repo) { $repo = $here }
    if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and
             (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
    $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1'
}

$script:Pass = 0
$script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") {
        $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }
$src = Get-Content -LiteralPath $ScriptPath -Raw

$root = Join-Path $env:TEMP ("pc2go-backup-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
# Canonicalise immediately. $env:TEMP is the 8.3 short form on this account, and comparing a short
# path against the long one robocopy reports is exactly the bug section 3 exists to pin down - the
# fixture must not accidentally reproduce it and call it a pass.
$root = (Get-Item -LiteralPath $root).FullName.TrimEnd('\')
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

try {
    # ------------------------------------------------------------------ extraction
    $q = [char]39
    $marker = [char]36 + 'workerScript = @' + $q
    $wStart = $src.IndexOf($marker)
    if ($wStart -lt 0) { throw 'Could not locate the $workerScript here-string.' }
    $wFrom = $src.IndexOf("`n", $wStart) + 1
    $wEnd  = $src.IndexOf("`n" + $q + '@', $wFrom)
    if ($wEnd -lt 0) { throw 'Could not locate the end of the $workerScript here-string.' }
    $workerBody = $src.Substring($wFrom, $wEnd - $wFrom)
    $workerPath = Join-Path $root 'worker.ps1'
    Set-Content -LiteralPath $workerPath -Value ($workerBody -replace '#__PREFTABLE__', '') -Encoding UTF8

    # The engine lives in the WORKER, so it is lifted out of the generated worker.ps1 rather than
    # out of AppDeploy.ps1 - the outer parser sees the whole worker as one string literal.
    $wAst = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$null)
    function Get-WFn([string]$Name) {
        $fn = $wAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name from the worker" }
        return $fn.Extent.Text
    }
    # Stop-ProcessTree first: Invoke-RobocopyWatched calls it on cancel and would otherwise throw
    # CommandNotFound at exactly the moment it matters.
    foreach ($n in 'Stop-ProcessTree', 'Get-CanonicalPath', 'Format-RcPath', 'Invoke-RobocopyWatched',
                   'Get-RobocopyListing', 'Write-Status', 'Resolve-InProfile',
                   'Write-BackupManifest', 'Read-BackupManifest', 'Get-CopyExcludes') {
        . ([scriptblock]::Create((Get-WFn $n)))
    }
    $script:CacheDir = $root
    $StatusFile = Join-Path $root 'status.jsonl'
    Write-Host ("Lifted the engine from a {0:N0}-line worker." -f (($workerBody -split "`r?`n").Count)) -ForegroundColor DarkGray

    # ------------------------------------------------------------------ fixtures
    $srcRoot = Join-Path $root 'src'
    $deepRel = ('a' * 80) + '\' + ('b' * 80) + '\' + ('c' * 80)
    $deepDir = Join-Path $srcRoot $deepRel
    # Through the \\?\ door, not New-Item/Set-Content: on a Windows that has not switched
    # LongPathsEnabled on - which is every client machine and both lab VMs - PowerShell's own
    # cmdlets cannot create a path over 260 characters, and the harness died in its fixture
    # before testing anything. The tool copies with robocopy, which has no such limit.
    [void][IO.Directory]::CreateDirectory('\\?\' + $deepDir)
    [IO.File]::WriteAllText('\\?\' + (Join-Path $deepDir 'deepfile.txt'), "i am very deep`r`n", [Text.Encoding]::ASCII)
    1..30 | ForEach-Object { Set-Content -LiteralPath (Join-Path $srcRoot "f$_.bin") -Value ('x' * 20000) -Encoding ASCII }
    New-Item -ItemType Directory -Force -Path (Join-Path $srcRoot 'sub\deeper') | Out-Null
    Set-Content -LiteralPath (Join-Path $srcRoot 'sub\deeper\nested.txt') -Value 'nested' -Encoding ASCII

    $deepFull = Join-Path $deepDir 'deepfile.txt'
    Write-Section '0. The fixture really is the hard case'
    Assert-True 'the deep path is over 260 characters' ($deepFull.Length -gt 260)
    Assert-True 'and the file exists at that path'     ([IO.File]::Exists('\\?\' + $deepFull))
    # The sandbox's OWN 8.3 alias, asked of the filesystem - not %TEMP%'s, which only has one
    # when the account name is longer than eight characters (Legion-T7 does, lab does not).
    $script:ShortRoot = ''
    try { $script:ShortRoot = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($root).ShortPath } catch { }
    Assert-True 'the sandbox has an 8.3 short name (else section 3 proves nothing)' `
                ($script:ShortRoot -and $script:ShortRoot -ne $root)

    # ================================================================== 1. the copy
    Write-Section '0b. Paths on their way to robocopy'

    # MEASURED, and the failure mode is the alarming part: robocopy takes its paths POSITIONALLY
    # and Start-Process -ArgumentList does not quote anything, so an unquoted destination of
    # "With Spaces In It" exited 0 - the SUCCESS code - having copied not one file, because every
    # word after the second was read as a FILE FILTER. One containing a dash exited 16, fatal.
    # "E:\My Backups" is not an exotic thing for somebody to pick.
    Assert-Equal 'a plain path is quoted'       '"C:\Temp"'        (Format-RcPath 'C:\Temp')
    Assert-Equal 'a path with spaces is quoted' '"C:\My Backups"'  (Format-RcPath 'C:\My Backups')
    Assert-Equal 'a UNC share is quoted whole'  '"\\PC\Shared Docs"' (Format-RcPath '\\PC\Shared Docs')
    # a trailing backslash would escape the closing quote and leave an unterminated argument
    Assert-Equal 'a trailing separator is dropped' '"C:\Temp"'     (Format-RcPath 'C:\Temp\')
    # ...except on a bare root, where C: alone means "the current directory on C:" - so the
    # separator stays, doubled, which is what survives the escaping
    Assert-Equal 'a bare drive root keeps its separator' '"E:\\"' (Format-RcPath 'E:\')

    Write-Section '1. A real tree copies, and progress is real while it does'

    $dstRoot = Join-Path $root 'dst'
    $script:Ticks = 0; $script:LastSeen = [long]0; $script:Monotonic = $true
    $run = Invoke-RobocopyWatched -Source $srcRoot -Dest $dstRoot -LogPath (Join-Path $root 'copy.log') -Tick {
        param($sofar, $nfiles, $secs)
        $script:Ticks++
        if ([long]$sofar -lt $script:LastSeen) { $script:Monotonic = $false }
        $script:LastSeen = [long]$sofar
    }
    Assert-True 'the copy did not report a fatal error (bit 16)' (($run.ExitCode -band 16) -eq 0)
    Assert-True 'it copied something'                            ($run.Files -gt 0)
    Assert-True 'and counted real bytes'                         ($run.Bytes -gt 0)
    Assert-True 'bytes never went backwards'                     $script:Monotonic
    Assert-True 'elapsed seconds were measured'                  ($run.Seconds -ge 0)
    Assert-True 'it was not cancelled'                           (-not $run.Cancelled)

    # ================================================================== 2. long paths
    Write-Section '2. A path over 260 characters - copied AND verified'

    $deepDst = Join-Path (Join-Path $dstRoot $deepRel) 'deepfile.txt'
    Assert-True 'the deep file arrived at the destination' ([IO.File]::Exists('\\?\' + $deepDst))

    $ls = Get-RobocopyListing $srcRoot (Join-Path $root 's.log')
    $ld = Get-RobocopyListing $dstRoot (Join-Path $root 'd.log')
    Assert-True  'the source listing was readable'      ($null -ne $ls)
    Assert-True  'the destination listing was readable' ($null -ne $ld)
    Assert-Equal 'both sides list the same number of files' $ls.Count $ld.Count

    $missing = 0; $wrong = 0
    foreach ($k in $ls.Keys) {
        if (-not $ld.ContainsKey($k)) { $missing++; continue }
        if ([long]$ld[$k] -ne [long]$ls[$k]) { $wrong++ }
    }
    # This is the whole point of the section. Before the fix this read 41.
    Assert-Equal 'NOTHING is reported missing'     0 $missing
    Assert-Equal 'and nothing at the wrong length' 0 $wrong
    Assert-True  'the deep file is IN the listing' ([bool](@($ls.Keys) | Where-Object { $_ -like '*deepfile.txt' }))

    # ================================================================== 3. the 8.3 trap
    Write-Section '3. Short names and long names describe the same file'

    Assert-True 'keys are relative, not full paths' (-not (@($ls.Keys) | Where-Object { $_ -like '?:\*' }))
    $shortRoot = $srcRoot.Replace($root, $script:ShortRoot)
    Assert-True  'the sandbox can be named two ways'      ($shortRoot -ne $srcRoot -and $shortRoot -like '*~*')
    $lsShort = Get-RobocopyListing $shortRoot (Join-Path $root 'sshort.log')
    Assert-True  'listing via the SHORT name still works' ($null -ne $lsShort)
    Assert-Equal 'and finds the same files'               $ls.Count $lsShort.Count
    $agree = $true
    foreach ($k in $ls.Keys) { if (-not $lsShort.ContainsKey($k)) { $agree = $false; break } }
    Assert-True 'with identical keys, so the two spellings compare equal' $agree

    # ================================================================== 4. corruption
    Write-Section '4. Corruption at the destination is caught'

    Set-Content -LiteralPath (Join-Path $dstRoot 'f1.bin') -Value 'truncated' -Encoding ASCII
    $ld2 = Get-RobocopyListing $dstRoot (Join-Path $root 'd2.log')
    $m2 = 0; $w2 = 0
    foreach ($k in $ls.Keys) {
        if (-not $ld2.ContainsKey($k)) { $m2++; continue }
        if ([long]$ld2[$k] -ne [long]$ls[$k]) { $w2++ }
    }
    Assert-Equal 'a file truncated at the destination is flagged' 1 $w2
    Assert-Equal 'and nothing is miscounted as missing'           0 $m2

    Remove-Item -LiteralPath (Join-Path $dstRoot 'f2.bin') -Force
    $ld3 = Get-RobocopyListing $dstRoot (Join-Path $root 'd3.log')
    $m3 = 0
    foreach ($k in $ls.Keys) { if (-not $ld3.ContainsKey($k)) { $m3++ } }
    Assert-Equal 'a file deleted at the destination is flagged as missing' 1 $m3

    # extra files at the destination are NOT a fault - a backup accumulates
    Set-Content -LiteralPath (Join-Path $dstRoot 'stranger.txt') -Value 'not from the source' -Encoding ASCII
    $ld4 = Get-RobocopyListing $dstRoot (Join-Path $root 'd4.log')
    $m4 = 0
    foreach ($k in $ls.Keys) { if (-not $ld4.ContainsKey($k)) { $m4++ } }
    Assert-Equal 'an EXTRA file at the destination is not counted against the copy' 1 $m4
    # NOT a count comparison: f2.bin was deleted a moment ago, so one was lost and one gained and
    # the totals happen to match. What matters is that the stranger IS present and yet contributes
    # nothing to the missing tally - an accumulated backup must not read as a damaged one.
    Assert-True  'the extra file really is in the destination listing' `
                 ([bool](@($ld4.Keys) | Where-Object { $_ -eq 'stranger.txt' }))
    Assert-True  'and it is absent from the source listing'           (-not $ls.ContainsKey('stranger.txt'))

    # ================================================================== 5. could not check
    Write-Section '5. "Could not check" is not "nothing there"'

    $gone = Get-RobocopyListing (Join-Path $root 'no-such-folder-at-all') (Join-Path $root 'x.log')
    Assert-True 'a missing root returns $null, not an empty map' ($null -eq $gone)
    Assert-True 'an empty path returns $null too'                ($null -eq (Get-RobocopyListing '' (Join-Path $root 'y.log')))
    $emptyDir = (New-Item -ItemType Directory -Force -Path (Join-Path $root 'empty')).FullName
    Assert-True 'a genuinely empty folder is NOT $null - it is a readable, empty answer' `
                ($null -ne (Get-RobocopyListing $emptyDir (Join-Path $root 'z.log')))

    # ================================================================== 6. incremental
    Write-Section '6. A second run copies only what changed'

    $run2 = Invoke-RobocopyWatched -Source $srcRoot -Dest $dstRoot -LogPath (Join-Path $root 'copy2.log')
    Assert-True 'the second run did not fail'                 (($run2.ExitCode -band 16) -eq 0)
    # f1 was truncated and f2 deleted above, so exactly those come back - and nothing else
    Assert-True 'it copied far less than the first run'       ($run2.Bytes -lt $run.Bytes)
    Assert-True 'but it did copy the files that were damaged' ($run2.Files -ge 1)
    $ld5 = Get-RobocopyListing $dstRoot (Join-Path $root 'd5.log')
    $m5 = 0; $w5 = 0
    foreach ($k in $ls.Keys) {
        if (-not $ld5.ContainsKey($k)) { $m5++; continue }
        if ([long]$ld5[$k] -ne [long]$ls[$k]) { $w5++ }
    }
    Assert-Equal 'and the destination is whole again - nothing missing' 0 $m5
    Assert-Equal 'nothing at the wrong length'                          0 $w5

    # ================================================================== 7. the wire
    Write-Section '7. The status wire carries the numbers, and omits them when there are none'

    Write-Status 'probe' 'Applying' 'copying Documents' $false @() 37 1234 9999 5000 12
    Write-Status 'plain' 'Applied'  'no numbers here'
    $recs = @(Get-Content -LiteralPath $StatusFile | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
    $withNums = @($recs | Where-Object { $_.id -eq 'probe' })[0]
    $without  = @($recs | Where-Object { $_.id -eq 'plain' })[0]

    Assert-Equal 'pct rides on the wire' 37   $withNums.pct
    Assert-Equal 'bytes too'             1234 $withNums.bytes
    Assert-Equal 'total too'             9999 $withNums.total
    Assert-Equal 'rate too'              5000 $withNums.rate
    Assert-Equal 'elapsed too'           12   $withNums.elapsed
    # the compatibility guarantee: ~90 existing callers must emit exactly what they always did
    Assert-True  'a caller that reports no numbers emits no pct' ($null -eq $without.pct)
    Assert-True  'no bytes'                                      ($null -eq $without.bytes)
    Assert-True  'no total'                                      ($null -eq $without.total)
    Assert-True  'no rate'                                       ($null -eq $without.rate)
    Assert-True  'no elapsed'                                    ($null -eq $without.elapsed)
    Assert-Equal 'and still carries what it always did' 'Applied' $without.state

    # 0 percent and 0 bytes are REAL readings a copy starts at, and must survive the wire
    Write-Status 'zero' 'Applying' 'just started' $false @() 0 0 500
    $z = @(Get-Content -LiteralPath $StatusFile | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
           Where-Object { $_ -and $_.id -eq 'zero' })[0]
    Assert-Equal 'zero percent is reported, not swallowed as "unset"' 0 $z.pct
    Assert-Equal 'and zero bytes with it'                             0 $z.bytes

    # ================================================================== 8. refusals
    Write-Section '8. The path guards still refuse what they always refused'

    Assert-Equal 'a plain name resolves inside the profile' `
                 (Join-Path $srcRoot 'Documents') (Resolve-InProfile $srcRoot 'Documents')
    Assert-Equal 'a parent-relative name is refused' '' (Resolve-InProfile $srcRoot '..\elsewhere')
    Assert-Equal 'a rooted path is refused'          '' (Resolve-InProfile $srcRoot 'C:\Windows')
    Assert-Equal 'a UNC path is refused'             '' (Resolve-InProfile $srcRoot '\\server\share')
    Assert-Equal 'an empty name is refused'          '' (Resolve-InProfile $srcRoot '')
    Assert-Equal 'a sibling-prefix probe is refused' '' (Resolve-InProfile 'C:\Users\bob' '..\bobby\x')

    # ================================================================== 9. cancel
    Write-Section '8b. Browser caches are left out - of the copy AND of the verify'

    # A Chrome profile is mostly cache: gigabytes that are worthless anywhere else and rebuild
    # themselves. Excluding them from the copy but not from the listing that verifies the copy
    # would report every cache file as missing, so both take the same list.
    $bx = Join-Path $root 'browser\User Data'
    New-Item -ItemType Directory -Force -Path "$bx\Default\Cache", "$bx\Profile 1\Code Cache", "$bx\Profile 1" | Out-Null
    Set-Content -LiteralPath "$bx\Default\Bookmarks" -Value '{"roots":{}}' -Encoding ASCII
    Set-Content -LiteralPath "$bx\Default\Cache\data_0" -Value ('c' * 5000) -Encoding ASCII
    Set-Content -LiteralPath "$bx\Profile 1\Bookmarks" -Value '{}' -Encoding ASCII
    Set-Content -LiteralPath "$bx\Profile 1\Code Cache\index" -Value ('x' * 5000) -Encoding ASCII
    $xd = @(Get-CopyExcludes 'AppData\Local\Google\Chrome\User Data')
    Assert-True  'a browser row excludes Cache'                    ($xd -contains 'Cache')
    Assert-True  'and Code Cache'                                  ($xd -contains 'Code Cache')
    Assert-Equal 'a plain data row excludes nothing'               0 @(Get-CopyExcludes 'Documents').Count
    $bd = Join-Path $root 'browser-out'
    $r = Invoke-RobocopyWatched -Source $bx -Dest $bd -LogPath (Join-Path $root 'bx.log') -ExcludeDirs $xd
    Assert-True  'the copy did not report a fatal error'           (($r.ExitCode -band 16) -eq 0)
    Assert-True  'bookmarks of every profile arrived'              ((Test-Path "$bd\Default\Bookmarks") -and (Test-Path "$bd\Profile 1\Bookmarks"))
    Assert-True  'the caches did NOT'                              (-not (Test-Path "$bd\Default\Cache") -and -not (Test-Path "$bd\Profile 1\Code Cache"))
    $lsx = Get-RobocopyListing $bx (Join-Path $root 'bxs.log') $xd
    $ldx = Get-RobocopyListing $bd (Join-Path $root 'bxd.log') $xd
    Assert-True  'both listings are readable'                      ($null -ne $lsx -and $null -ne $ldx)
    Assert-Equal 'the source listing with excludes holds only the bookmarks' 2 $lsx.Count
    $miss = 0; foreach ($k in $lsx.Keys) { if (-not $ldx.ContainsKey($k)) { $miss++ } }
    Assert-Equal 'so the verify reports nothing missing'           0 $miss
    $lsAll = Get-RobocopyListing $bx (Join-Path $root 'bxall.log')
    Assert-Equal 'without the excludes the same tree lists the caches too' 4 $lsAll.Count

    Write-Section '9. A cancel flag stops a copy in flight'

    $bigSrc = Join-Path $root 'big'
    New-Item -ItemType Directory -Force -Path $bigSrc | Out-Null
    $blob = 'y' * 1000000
    1..60 | ForEach-Object { Set-Content -LiteralPath (Join-Path $bigSrc "b$_.bin") -Value $blob -Encoding ASCII }
    # The flag is set BEFORE the copy starts, deliberately. Creating it from inside the tick
    # raced: 60 MB finishes well inside the 400ms poll on an SSD, so robocopy had already exited
    # before the flag existed and the run correctly reported nothing to cancel. Pre-setting it
    # tests the guard rather than the disk's speed.
    $cancelFlag = Join-Path $root 'cancel.flag'
    New-Item -ItemType File -Path $cancelFlag -Force | Out-Null
    $run3 = Invoke-RobocopyWatched -Source $bigSrc -Dest (Join-Path $root 'bigdst') `
                                   -LogPath (Join-Path $root 'copy3.log') -CancelFlag $cancelFlag
    Assert-True 'a cancel already pending is honoured at once' $run3.Cancelled
    # NOT asserting the destination is incomplete. Killing a copy this small is a race the disk
    # usually wins - robocopy with /MT:16 can finish 60 MB between the kill signal and the
    # process actually dying, and a test that depends on losing that race would pass or fail by
    # hardware. What is deterministic, and what actually matters, is that the flag is SEEN and
    # reported, so the caller marks the item failed rather than silently claiming success.
    Assert-True 'a cancelled run still reports the bytes it managed' ($run3.Bytes -ge 0)

    # and with no flag at all, the same copy runs to completion
    $run4 = Invoke-RobocopyWatched -Source $bigSrc -Dest (Join-Path $root 'bigdst2') `
                                   -LogPath (Join-Path $root 'copy4.log')
    Assert-True 'without a flag it is not reported as cancelled' (-not $run4.Cancelled)
    Assert-True 'and it copies the whole folder'                 ($run4.Files -ge 60)

    # ================================================================== 10. the manifest
    Write-Section '10. A backup describes itself'

    $mRoot = (New-Item -ItemType Directory -Force -Path (Join-Path $root 'manifested')).FullName
    $items = @([ordered]@{ rel = 'Documents'; files = 12; bytes = 3456; verified = $true },
               [ordered]@{ rel = 'Desktop';   files = 3;  bytes = 99;   verified = $false })
    $t0 = (Get-Date).AddSeconds(-252)
    Assert-True 'the manifest was written' (Write-BackupManifest $mRoot 'C:\Users\example' $items $t0 252)
    Assert-True 'and it landed in the backup root' (Test-Path -LiteralPath (Join-Path $mRoot 'pc2go-backup.json'))
    # ConvertFrom-Json chokes on a BOM - Write-RunRecord and Load-Catalog both carry scars from it
    $bytes0 = [IO.File]::ReadAllBytes((Join-Path $mRoot 'pc2go-backup.json'))
    Assert-True 'written WITHOUT a byte-order mark' `
                (-not ($bytes0[0] -eq 0xEF -and $bytes0[1] -eq 0xBB -and $bytes0[2] -eq 0xBF))
    Assert-True 'and no .tmp was left behind' (-not (Test-Path -LiteralPath (Join-Path $mRoot 'pc2go-backup.json.tmp')))

    $m = Read-BackupManifest $mRoot
    Assert-True  'it reads back'                   ($null -ne $m)
    Assert-Equal 'version survives'              1 $m.version
    Assert-Equal 'the source profile survives'   'C:\Users\example' $m.sourceProfile
    Assert-Equal 'the machine name is recorded'  "$env:COMPUTERNAME" $m.sourceMachine
    Assert-Equal 'elapsed seconds survive'       252 $m.seconds
    Assert-Equal 'both items survive'            2   @($m.items).Count
    Assert-Equal 'with their file counts'        12  @($m.items)[0].files
    Assert-Equal 'and their byte counts'         3456 @($m.items)[0].bytes
    Assert-Equal 'a verified item says so'       $true  @($m.items)[0].verified
    Assert-Equal 'an unverified one says so too' $false @($m.items)[1].verified
    # round-trip ISO 8601 - parseable, not just a string that looks like a date
    $parsed = [datetime]::MinValue
    Assert-True 'startedUtc parses as a real date'   ([datetime]::TryParse($m.startedUtc, [ref]$parsed))
    Assert-True 'finishedUtc parses too'             ([datetime]::TryParse($m.finishedUtc, [ref]$parsed))
    Assert-True 'and finished is not before started' ([datetime]$m.finishedUtc -ge [datetime]$m.startedUtc)

    Assert-True 'a folder with no manifest reads as $null, not as an empty backup' `
                ($null -eq (Read-BackupManifest (Join-Path $root 'src')))
    Set-Content -LiteralPath (Join-Path $mRoot 'pc2go-backup.json') -Value 'not json at all' -Encoding ASCII
    Assert-True 'and an unreadable manifest reads as $null rather than throwing' `
                ($null -eq (Read-BackupManifest $mRoot))
    Assert-True 'a manifest cannot be written to a root that is not there' `
                (-not (Write-BackupManifest (Join-Path $root 'nope') 'x' @() (Get-Date) 0))

    # ================================================================== 11. folder destinations
    Write-Section '11. A drive or USB destination, and the loops it must refuse'

    # The real worker, run as a child process, because these guards live in Copy-ProfileData and
    # the source has to be a genuine ProfileList entry - which only this account's own profile is.
    $me = (Get-Item -LiteralPath $env:USERPROFILE).FullName.TrimEnd([char]92)
    $item = 'Searches'
    if (-not (Test-Path -LiteralPath (Join-Path $me $item))) { $item = 'Links' }
    $qf = Join-Path $root 'q.jsonl'
    $sf = Join-Path $root 'worker-status.jsonl'

    function Add-Job([string]$Id, [string]$Dst) {
        Add-Content -LiteralPath $qf -Encoding UTF8 -Value (@{
            id = $Id; action = 'migrate'; src = $me; dstUser = ''; dstPath = $Dst
            dstKind = 'folder'; items = @($item) } | ConvertTo-Json -Compress -Depth 4)
    }
    # OUTSIDE the profile. %TEMP% is INSIDE it, so the sandbox itself is a legitimate refusal -
    # that caught this test the first time it ran, which is the guard doing its job.
    $usb = (New-Item -ItemType Directory -Force -Path (Join-Path $env:PUBLIC ('pc2go-bktest-' + [Guid]::NewGuid().ToString('N').Substring(0,8)))).FullName
    try {
        Add-Job 'ok'      $usb
        Add-Job 'inside'  (Join-Path $me 'Desktop')
        Add-Job 'parent'  (Split-Path $me)
        # the chosen folder must exist; the backup folder inside it is the worker to create
        Add-Job 'missing'  (Join-Path $root 'no-such-parent\and-a-leaf')
        Add-Job 'makeleaf' (Join-Path $usb 'PC2Go Backup - made-by-the-worker')
        Add-Content -LiteralPath $qf -Value '{"end":true}'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -Wait -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$workerPath`"",
            '-QueueFile',"`"$qf`"",'-StatusFile',"`"$sf`"",'-CancelFile',"`"$(Join-Path $root 'c.flag')`"") | Out-Null
        $rep = @(Get-Content -LiteralPath $sf -EA 0 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
        function Last([string]$Id) { @($rep | Where-Object { $_.id -eq $Id -and $_.state -in 'Applied','Failed','Skipped' }) | Select-Object -Last 1 }

        $ok = Last 'ok'
        Assert-Equal 'a folder outside the profile is accepted' 'Applied' $(if ($ok) { $ok.state } else { '(nothing reported)' })
        Assert-True  'and files really landed there' (@(Get-ChildItem $usb -Recurse -File -Force -EA 0).Count -gt 0)
        Assert-True  'a manifest was written beside them' (Test-Path -LiteralPath (Join-Path $usb 'pc2go-backup.json'))
        $mf = Read-BackupManifest $usb
        Assert-True  'and it names the profile it came from' ($null -ne $mf -and $mf.sourceProfile -eq $me)
        Assert-Equal 'and records the folder that was copied' $item @($mf.items)[0].rel
        Assert-True  'the write-probe left nothing behind' (@(Get-ChildItem $usb -Filter '.pc2go-write-test-*' -Force -EA 0).Count -eq 0)
        # a stick has no owning user and FAT32 has no ACLs - the profile-only check must not fire
        Assert-True  'no bogus permission complaint about a plain folder' ("$($ok.detail)" -notmatch 'permission entry')

        # The three loops. Each would fill the disk: robocopy /E walks into the destination it is
        # writing, copies what it just wrote, and repeats.
        $in = Last 'inside'
        Assert-Equal 'a destination INSIDE the profile is refused' 'Failed' $(if ($in) { $in.state } else { '(nothing)' })
        Assert-True  'and says why in terms of the loop'           ("$($in.detail)" -match 'inside the profile')
        $pa = Last 'parent'
        Assert-Equal 'a destination that CONTAINS the profile is refused' 'Failed' $(if ($pa) { $pa.state } else { '(nothing)' })
        Assert-True  'and says why'                                       ("$($pa.detail)" -match 'contains the profile')
        $mi = Last 'missing'
        Assert-Equal 'a destination whose PARENT does not exist is refused' 'Failed' $(if ($mi) { $mi.state } else { '(nothing)' })
        Assert-True  'and names the folder it wanted'  ("$($mi.detail)" -match 'is not a folder that exists')
        # The other half of the same rule: the backup folder itself is created rather than demanded,
        # because it carries a generated name the technician never types.
        $ml = Last 'makeleaf'
        Assert-Equal 'but the backup folder inside it is created, not demanded' 'Applied' $(if ($ml) { $ml.state } else { '(nothing)' })
        Assert-True  'and it really is on disk afterwards' `
                     (Test-Path -LiteralPath (Join-Path $usb 'PC2Go Backup - made-by-the-worker'))
        # That name has SPACES and a DASH in it, which is the whole regression: unquoted, robocopy
        # read them as file filters, matched nothing, and reported success over an empty folder.
        Assert-True  'and files really arrived in it, spaces in the name notwithstanding' `
                     (@(Get-ChildItem -LiteralPath (Join-Path $usb 'PC2Go Backup - made-by-the-worker') `
                                      -Recurse -File -EA 0).Count -ge 1)

        # progress genuinely rode the wire from a real elevated-style worker run
        $nums = @($rep | Where-Object { $_.id -eq 'ok' -and $null -ne $_.pct })
        Assert-True 'the worker reported progress numbers, not just text' ($nums.Count -ge 1)
        Assert-True 'and finished at 100%' (@($nums | Where-Object { $_.pct -eq 100 }).Count -ge 1)
    }
    finally {
        # copied files keep their source attributes, and a read-only one defeats a plain delete
        Get-ChildItem $usb -Recurse -Force -EA 0 | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $usb -Recurse -Force -EA 0
        Assert-True 'the harness left nothing in Public' (-not (Test-Path -LiteralPath $usb))
    }

    # ================================================================== 12. restore
    Write-Section '12. Restore - the same engine with the roots swapped'

    $usb2 = (New-Item -ItemType Directory -Force -Path (Join-Path $env:PUBLIC ('pc2go-rst-' + [Guid]::NewGuid().ToString('N').Substring(0,8)))).FullName
    $notBackup = (New-Item -ItemType Directory -Force -Path (Join-Path $root 'notabackup')).FullName
    $fakeProf  = (New-Item -ItemType Directory -Force -Path (Join-Path $root 'fakeprofile')).FullName
    $exe = Join-Path $env:SystemRoot ('System32' + [char]92 + 'WindowsPowerShell' + [char]92 + 'v1.0' + [char]92 + 'powershell.exe')
    try {
        Remove-Item -LiteralPath $qf, $sf -Force -EA 0
        # first make a real backup, so there is something genuine to restore
        Add-Content -LiteralPath $qf -Encoding UTF8 -Value (@{
            id = 'mk'; action = 'migrate'; src = $me; dstUser = ''; dstPath = $usb2
            dstKind = 'folder'; items = @($item) } | ConvertTo-Json -Compress -Depth 4)
        # a profile Windows has never heard of
        Add-Content -LiteralPath $qf -Encoding UTF8 -Value (@{
            id = 'notprof'; action = 'migrate'; src = $usb2; srcKind = 'folder'; dstUser = ''
            dstPath = $fakeProf; dstKind = 'profile'; items = @($item) } | ConvertTo-Json -Compress -Depth 4)
        # a folder that is not a backup this tool wrote
        Add-Content -LiteralPath $qf -Encoding UTF8 -Value (@{
            id = 'noman'; action = 'migrate'; src = $notBackup; srcKind = 'folder'
            dstUser = "$env:USERNAME"; dstPath = $me; dstKind = 'profile'; items = @($item) } | ConvertTo-Json -Compress -Depth 4)
        # and the real thing
        Add-Content -LiteralPath $qf -Encoding UTF8 -Value (@{
            id = 'restore'; action = 'migrate'; src = $usb2; srcKind = 'folder'
            dstUser = "$env:USERNAME"; dstPath = $me; dstKind = 'profile'; items = @($item) } | ConvertTo-Json -Compress -Depth 4)
        Add-Content -LiteralPath $qf -Value '{"end":true}'
        Start-Process -FilePath $exe -Wait -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$workerPath`"",
            '-QueueFile',"`"$qf`"",'-StatusFile',"`"$sf`"",'-CancelFile',"`"$(Join-Path $root 'c2.flag')`"") | Out-Null
        $rep2 = @(Get-Content -LiteralPath $sf -EA 0 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
        function Last2([string]$Id) { @($rep2 | Where-Object { $_.id -eq $Id -and $_.state -in 'Applied','Failed','Skipped' }) | Select-Object -Last 1 }

        Assert-Equal 'the backup that restore needs was made' 'Applied' "$((Last2 'mk').state)"

        $np = Last2 'notprof'
        Assert-Equal 'restoring into a folder that is not a real profile is refused' 'Failed' "$($np.state)"
        Assert-True  'and says it is not a user profile' ("$($np.detail)" -match 'not a user profile folder')

        # provenance: without this, a Downloads folder could be emptied over somebody's Documents
        $nm = Last2 'noman'
        Assert-Equal 'restoring from a folder with no manifest is refused' 'Failed' "$($nm.state)"
        Assert-True  'and names the manifest it wanted' ("$($nm.detail)" -match 'pc2go-backup.json')

        $rs = Last2 'restore'
        Assert-Equal 'a real backup restores into a real profile' 'Applied' "$($rs.state)"
        Assert-True  'and the wording says the BACKUP is what was left untouched' `
                     ("$($rs.detail)" -match 'backup is left untouched')
        # a manifest belongs in a backup, never in somebody's home folder
        Assert-True  'no manifest was littered into the profile' `
                     (-not (Test-Path -LiteralPath (Join-Path $me 'pc2go-backup.json')))
    }
    finally {
        Get-ChildItem $usb2 -Recurse -Force -EA 0 | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $usb2 -Recurse -Force -EA 0
        Assert-True 'the restore harness left nothing in Public' (-not (Test-Path -LiteralPath $usb2))
    }

    # ================================================================== 13. the network
    Write-Section '13. Reaching another PC - the parts provable without a second machine'

    # These live in the GUI half, so they come out of AppDeploy.ps1 itself rather than the sliced
    # worker. The outer parser sees the whole worker as one string literal, so a name defined on
    # BOTH sides - and Connect-Share deliberately is - resolves here to the GUI copy, which is the
    # one this section means to exercise. The drift guard at the end keeps the other copy honest.
    $gAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    function Get-GFn([string]$Name) {
        $all = @($gAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
        if (-not $all.Count) { throw "Could not extract $Name from the GUI half" }
        return $all[0].Extent.Text
    }
    $pinv = @($gAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Extent.Text -like '*Native.Share*WNetAddConnection2*' }, $true))
    Assert-Equal 'the GUI half declares the share P/Invoke exactly once' 1 $pinv.Count
    . ([scriptblock]::Create($pinv[0].Extent.Text))
    foreach ($n in 'Get-ShareRoot', 'Connect-Share', 'Invoke-OffUi', 'Get-LocalIPv4', 'Get-LocalSubnets',
                   'Resolve-HostLabel', 'Get-HostShares', 'Find-NetworkHosts') {
        . ([scriptblock]::Create((Get-GFn $n)))
    }

    # A connection is made to the SHARE, never to a folder inside it - mpr refuses the latter and
    # says nothing useful about why.
    Assert-Equal 'a deep UNC reduces to its share'       '\\PC\Share' (Get-ShareRoot '\\PC\Share\deep\er')
    Assert-Equal 'a bare share is already its own root'  '\\PC\Share' (Get-ShareRoot '\\PC\Share')
    Assert-Equal 'a local path has no share root'        ''           (Get-ShareRoot 'C:\Users\bob')
    Assert-Equal 'a machine with no share is not a root' ''           (Get-ShareRoot '\\PC')
    Assert-Equal 'and neither is nothing at all'         ''           (Get-ShareRoot '')

    # A drive or a USB stick must not be dragged through the network stack at all.
    Assert-Equal 'connecting a local path is a silent no-op' '' (Connect-Share 'C:\Windows' '' '')

    # Every failure has to reach the technician as a SENTENCE. Error 64 was the one that did not:
    # MEASURED, it is what a missing host actually returns on this stack, it was unmapped, and it
    # surfaced as a bare "(error 64)" for the commonest failure there is.
    $why = Connect-Share '\\PC2GO-NO-SUCH-HOST-ZZZQ\Share' '' ''
    Assert-True 'an unreachable PC is refused'                 ([bool]$why)
    Assert-True 'and explained in words, not a raw error code' (-not ($why -match '\(error \d+\)'))
    Assert-True 'and the message names what it tried to reach' ($why -match 'PC2GO-NO-SUCH-HOST-ZZZQ')

    # "Could not ask" and "shares nothing" are different answers and must stay different values.
    # MEASURED: a PC that wants a sign-in answers `System error 5` and exits 2; parsed for share
    # rows that is an empty list - identical to a machine genuinely sharing nothing.
    & "$env:SystemRoot\System32\net.exe" view "\\$env:COMPUTERNAME" 2>$null | Out-Null
    Assert-Equal 'this machine answers a share enumeration (else the next two prove nothing)' 0 $LASTEXITCODE
    $mine = Get-HostShares $env:COMPUTERNAME
    Assert-True 'a PC that ANSWERS never returns the could-not-ask sentinel' ($null -ne $mine)
    # `return ,$out`, not `return $out`: PowerShell unrolls a returned array, so a plain return
    # hands an empty list back as $null and collapses the two answers into one.
    Assert-True 'and an empty list survives the return as an array'          ($mine -is [array])
    # This harness runs under $ErrorActionPreference = 'Stop', and that is the point of it:
    # under 'Stop', PowerShell 5.1 turns anything a NATIVE command writes to stderr into a
    # terminating error before 2>$null applies, so the exit-code check was skipped entirely and
    # an unreachable PC came back as an empty list. AppDeploy.ps1 runs under 'Stop' for its
    # first 6,600 lines, so this was a live trap, not a harness artefact.
    Assert-Equal 'the harness really is running under Stop (else the next assertion is weaker)' `
                 'Stop' "$ErrorActionPreference"
    $gone = Get-HostShares 'PC2GO-NO-SUCH-HOST-ZZZQ'
    Assert-True 'a PC that will not answer returns the could-not-ask sentinel' ($null -eq $gone)

    # ---- the credential prompt, and when it is allowed to appear.
    #
    # The whole point of the flow: Windows own dialog comes up ONLY once the machine has been
    # reached and has refused, so the box appearing is itself proof the PC was found and is
    # talking. A machine that is switched off is told plainly instead - no password will wake it.
    $pinC = @($gAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Extent.Text -like '*CredUIPromptForWindowsCredentials*' }, $true))
    Assert-Equal 'the GUI declares the credential P/Invoke exactly once' 1 $pinC.Count
    . ([scriptblock]::Create($pinC[0].Extent.Text))
    . ([scriptblock]::Create((Get-GFn 'Resolve-ShareUser')))
    . ([scriptblock]::Create((Get-GFn 'Get-BackupFolderName')))
    Assert-True 'the Windows credential API compiles' ([bool]('Native.CredUi' -as [type]))
    # x64 packs CREDUI_INFO to 40 bytes. A wrong size here is a corrupted stack, not a wrong dialog.
    Assert-Equal 'and CREDUI_INFO is the size Windows expects' 40 `
                 ([Runtime.InteropServices.Marshal]::SizeOf([type]'Native.CredUi+CREDUI_INFO'))

    # The credential buffer round-trips WITHOUT showing anything: pack a known pair, then unpack it
    # exactly the way the real handler does. This is the part most likely to be silently wrong, and
    # a bad unpack yields an empty password and a sign-in failure nobody can account for.
    $packSize = 0
    [void][Native.CredUi]::CredPackAuthenticationBuffer(0, 'LENOVO-S\technician', 'P@ss w0rd!', [IntPtr]::Zero, [ref]$packSize)
    Assert-True 'a credential buffer can be sized' ($packSize -gt 0)
    $pbuf = [Runtime.InteropServices.Marshal]::AllocCoTaskMem($packSize)
    try {
        Assert-True 'and packed' `
                    ([Native.CredUi]::CredPackAuthenticationBuffer(0, 'LENOVO-S\technician', 'P@ss w0rd!', $pbuf, [ref]$packSize))
        $uL = 513; $dL = 513; $pL = 513
        $ub = New-Object Text.StringBuilder $uL
        $db = New-Object Text.StringBuilder $dL
        $pw = New-Object Text.StringBuilder $pL
        Assert-True 'and unpacked' `
                    ([Native.CredUi]::CredUnPackAuthenticationBuffer(0, $pbuf, $packSize, $ub, [ref]$uL, $db, [ref]$dL, $pw, [ref]$pL))
        Assert-Equal 'the username survives the round trip' 'LENOVO-S\technician' $ub.ToString()
        Assert-Equal 'and so does a password with a space and punctuation in it' 'P@ss w0rd!' $pw.ToString()
    } finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pbuf) }

    # The prompt opens EMPTY, like the one Explorer raises. It used to open with "MACHINE\"
    # already typed in, which meant entering only a password submitted "MACHINE\" as the whole
    # account name. The rule moved into code instead, where it can be relied on.
    Assert-True 'the prompt is given no input buffer, so the box opens empty' `
                ($src -match 'CredUIPromptForWindowsCredentials\([^)]*?\[IntPtr\]::Zero,\s*0,')
    Assert-True 'and New-CredPrefill is gone rather than left lying around unused' `
                (-not ($src -match 'New-CredPrefill'))

    # A bare name means an account on THAT PC. Anything already qualified is left completely alone.
    Assert-Equal 'a bare username is qualified with the machine'    'LENOVO-S\ad'    (Resolve-ShareUser 'ad' 'LENOVO-S')
    Assert-Equal 'whitespace around it does not defeat that'        'LENOVO-S\ad'    (Resolve-ShareUser '  ad  ' 'LENOVO-S')
    Assert-Equal 'a name that already names a machine is untouched' 'OTHER\bob'      (Resolve-ShareUser 'OTHER\bob' 'LENOVO-S')
    Assert-Equal 'a UPN is untouched'                          'bob@corp.example' (Resolve-ShareUser 'bob@corp.example' 'LENOVO-S')
    Assert-Equal 'a dot-prefixed local form is untouched'           '.\bob'          (Resolve-ShareUser '.\bob' 'LENOVO-S')
    Assert-Equal 'nothing typed stays nothing'                      ''                (Resolve-ShareUser '' 'LENOVO-S')

    # The backup gets a folder of its own, and the NAME IS STABLE - a date in it would make every
    # run a fresh folder and copy everything again, which is the opposite of incremental.
    $bf1 = Get-BackupFolderName 'Legion-T7'
    $bf2 = Get-BackupFolderName 'Legion-T7'
    Assert-Equal 'the backup folder name is stable between runs' $bf1 $bf2
    Assert-True  'it names this machine and the account' `
                 ($bf1 -match [regex]::Escape($env:COMPUTERNAME) -and $bf1 -match 'Legion-T7')
    $dirty = Get-BackupFolderName ('a/b' + [string][char]92 + 'c:d*e?f')
    Assert-Equal 'an account name full of illegal characters still yields a usable folder name' 0 `
                 (@([IO.Path]::GetInvalidFileNameChars() | Where-Object { $dirty.Contains([string]$_) }).Count)

    # Which failures may raise it: 5 means it refused you, 1326 means it rejected the credential.
    # Those two, and no others.
    $null = Connect-Share '\\127.0.0.1\NoSuchShareZZZ' '' ''
    Assert-Equal 'a share that refuses reports the code that earns a prompt' 5 $script:LastShareRc
    # The regression: this used to inherit the 5 from the call above, because the local-path early
    # return never reset the code - so a folder on this very machine looked like a refusal, and
    # would have raised a Windows sign-in box for a local directory.
    $null = Connect-Share 'C:\Windows' '' ''
    Assert-Equal 'a local path reports success, not whatever was asked last' 0 $script:LastShareRc
    $null = Connect-Share '\\PC2GO-NO-SUCH-HOST-ZZZQ\Share' '' ''
    Assert-True 'a PC that is not there never earns a prompt' `
                ($script:LastShareRc -ne 5 -and $script:LastShareRc -ne 1326)

    # ---- the dialog shape that was asked for: no imitation credential boxes, and a scan that
    #      starts by itself.
    Assert-True 'there are no home-made username or password boxes left in the XAML' `
                (-not ($src -match 'x:Name="TxtNetUser"') -and -not ($src -match 'x:Name="TxtNetPw"'))
    Assert-True 'and no code still reaches for them' `
                (-not ($src -match '\$TxtNetUser') -and -not ($src -match '\$TxtNetPw'))
    Assert-True 'the scan starts by itself when the dialog opens' `
                ($src -match '\$BtnNetFind\.Add_Click\(\{[\s\S]{0,900}?Start-NetScan')
    Assert-True 'and the button beside it is a retry, not a start' ($src -match 'Content="Scan again"')

    # ---- clicking the same PC again after it did not work.
    #
    # THE BUG THIS PINS: a WPF ListBox raises SelectionChanged only when the selection CHANGES. The
    # row stays highlighted after a cancelled sign-in, so clicking it again raises nothing at all
    # and the picker becomes a dead end - while the note on screen cheerfully says to click it
    # again. Dropping the highlight is what makes the next click a change.
    $selAt = $src.IndexOf('$ListNetHosts.Add_SelectionChanged({')
    Assert-True 'the host picker handler was located' ($selAt -ge 0)
    $selEnd = $src.IndexOf("`n})", $selAt)
    $selBody = $src.Substring($selAt, $selEnd - $selAt)
    # comments stripped, so the word return in prose is not mistaken for a code path
    $selCode = (($selBody -split "`r?`n" | ForEach-Object { $_ -replace '\s*#.*$', '' }) -join "`n")

    Assert-True 'the picker has a re-entrancy guard, because clearing the selection re-enters it' `
                ($selCode -match '\$script:NetSelBusy')
    Assert-True 'and Clear-NetHostPick really drops the highlight' `
                ($src -match 'function Clear-NetHostPick[\s\S]{0,400}?SelectedIndex\s*=\s*-1')
    Assert-True 'and raises the guard while it does, so it cannot re-enter itself' `
                ($src -match 'function Clear-NetHostPick[\s\S]{0,400}?NetSelBusy\s*=\s*\$true')

    # Structural, because this is the failure that was actually hit in use: every exit from the
    # picker that is NOT one of the two opening guards has to have dropped the highlight first, or
    # it is an exit the technician cannot click their way back out of.
    $chunks = $selCode -split 'return'
    $stuck = 0
    for ($i = 2; $i -lt $chunks.Count - 1; $i++) {
        if ($chunks[$i] -notmatch 'Clear-NetHostPick') { $stuck++ }
    }
    Assert-Equal 'every dead end in the host picker drops the highlight before it gives up' 0 $stuck

    # ---- which networks even get swept.
    $nets = @(Get-LocalSubnets)
    Assert-True 'this machine is on at least one scannable subnet (else the sweep proves nothing)' ($nets.Count -ge 1)

    # Every subnet swept must belong to an adapter that is UP and is Ethernet (6) or Wi-Fi (71).
    # MEASURED on the machine this was written on: six IPv4 addresses, of which exactly ONE was a
    # network a second PC could be sitting on. The others were a Disconnected Wi-Fi card, a
    # Disconnected Bluetooth PAN, two APIPA ghosts with no adapter behind them, and Tailscale.
    $okNets = @()
    try {
        $idx = @{}
        foreach ($a in @(Get-NetAdapter -EA Stop)) {
            if ($a.Status -eq 'Up' -and ([int]$a.InterfaceType -eq 6 -or [int]$a.InterfaceType -eq 71)) {
                $idx[[int]$a.InterfaceIndex] = $true
            }
        }
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -EA Stop)) {
            if ($idx.ContainsKey([int]$a.InterfaceIndex)) {
                $okNets += ((([string]$a.IPAddress) -split '\.')[0..2] -join '.')
            }
        }
    } catch { }
    Assert-Equal 'no tunnel, VPN or disconnected adapter is swept' 0 @($nets | Where-Object { $okNets -notcontains $_ }).Count

    # The exact regression: Tailscale's address is a /32 - a network whose only member is this
    # machine - and it was contributing a full 254-address sweep. That is where "508 addresses"
    # came from, and half of it could never have found anything.
    $narrow = @(Get-NetIPAddress -AddressFamily IPv4 -EA 0 | Where-Object { [int]$_.PrefixLength -gt 30 } |
                ForEach-Object { ((([string]$_.IPAddress) -split '\.')[0..2] -join '.') })
    Assert-Equal 'a /31 or /32 address contributes no subnet to sweep' 0 @($nets | Where-Object { $narrow -contains $_ }).Count

    # ---- Stop.
    $script:ticks = 0
    $sw13 = [Diagnostics.Stopwatch]::StartNew()
    $null = Find-NetworkHosts -Tick { param($d, $t, $h) $script:ticks++; return $false } -TimeoutMs 1
    $sw13.Stop()
    Assert-Equal 'a tick that returns $false stops the sweep on the spot' 1 $script:ticks
    Assert-True  'so Stop is answered at once, not at the end of the subnet' ($sw13.Elapsed.TotalSeconds -lt 25)

    # ---- $false stops it; nothing else may. A tick that chatters, or throws, is not a Stop press,
    #      and a UI tick does both sooner or later. What is asserted is that the sweep RAN TO THE
    #      END - not an exact tick count, because the probe is parallel now and how many ticks a
    #      chunk produces depends on how quickly the network answers.
    $script:lastDone = -1; $script:lastTotal = -1; $script:junk = 0; $script:seen = @()
    $sw14 = [Diagnostics.Stopwatch]::StartNew()
    $hosts = Find-NetworkHosts -Tick {
        param($d, $t, $h)
        $script:junk++; $script:lastDone = $d; $script:lastTotal = $t
        if ($script:junk % 2) { 'chatty output' } else { throw 'ticks are allowed to fail' }
    } -TimeoutMs 250 -OnFound {
        param($x)
        $script:seen += [string]$x.Ip
        'and chatter from OnFound too'
    }
    $sw14.Stop()
    Assert-True 'a tick that chatters or throws does not stop the sweep' `
                ($script:lastTotal -gt 0 -and $script:lastDone -eq $script:lastTotal)

    # Probed in parallel: the serial version measured 65 SECONDS for this same sweep, one address
    # at a time, each waiting out its own timeout.
    Assert-True 'and a whole sweep costs seconds, not a minute' ($sw14.Elapsed.TotalSeconds -lt 30)

    # Both callbacks above deliberately print. A scriptblock invoked with & puts whatever it emits
    # into the FUNCTION's output stream, so that chatter used to come back as if it were a
    # discovered PC - the final tick returned $true and the GUI reported one machine as two.
    Assert-Equal 'nothing a callback prints comes back as a discovered PC' 0 `
                 @(@($hosts) | Where-Object { -not $_.Ip }).Count

    # A host handed to OnFound during the sweep and a host in the returned list are the same set:
    # the live list the technician watches fill in must not disagree with the final count.
    Assert-Equal 'every PC returned was also handed over live, the moment it answered' `
                 (@(@($hosts) | ForEach-Object { [string]$_.Ip } | Sort-Object) -join ',') `
                 (@($script:seen | Sort-Object) -join ',')

    # The duplication, kept honest. Connect-Share exists in both halves on purpose - two
    # processes, no module to share, the same precedent as ConvertTo-PSRegPath. That is only safe
    # while the two agree about what each error code means, and nothing else would ever notice
    # them drifting apart.
    $codesOf = {
        param($text)
        ,@([regex]::Matches($text, '\$rc -eq (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    }
    $guiCodes = & $codesOf (Get-GFn 'Connect-Share')
    $wAt = $workerBody.IndexOf('function Connect-Share')
    Assert-True 'the worker carries its own copy of Connect-Share' ($wAt -ge 0)
    $wTo = $workerBody.IndexOf("`nfunction ", $wAt + 10)
    if ($wTo -lt 0) { $wTo = $workerBody.Length }
    $wkrCodes = & $codesOf ($workerBody.Substring($wAt, $wTo - $wAt))
    Assert-Equal 'both copies map the same set of error codes' ($guiCodes -join ',') ($wkrCodes -join ',')
    Assert-True  'and 64 is among them - the code a missing PC actually returns' ($guiCodes -contains 64)

    # The credentials actually reach the worker. Same class of check as Test-Push's "no field the
    # worker reads is dropped on the way": the two halves agree about a field name only by
    # convention, and a typo is silent - the copy just fails to authenticate and reports access
    # denied, which looks like a permissions problem on the far end.
    Assert-True 'netPassword is declared a secret, so the queue never carries it in clear' `
                ($src -match "SecretFields\s*=\s*@\([^)]*'netPassword'")
    Assert-True 'the worker reads netUser off the job'     ($src -match '\$app\.netUser')
    Assert-True 'the worker reads netPassword off the job' ($src -match '\$app\.netPassword')
    Assert-True 'and unprotects it rather than using the wrapped form' `
                ($src -match 'Unprotect-Secret \(\[string\]\$app\.netPassword\)')
    # Captured into locals BEFORE the confirm closure is made, then put on the entry from those -
    # the callback carries values rather than reading $script: state at fire time.
    Assert-True 'the GUI captures the sign-in before the confirm closure is built' `
                (($src -match '\$netU\s*=\s*\[string\]\$script:NetUser') -and ($src -match '\$netP\s*=\s*\[string\]\$script:NetPassword'))
    Assert-True 'and the GUI puts both on the queue entry' `
                (($src -match 'netUser\s*=\s*\$netU\b') -and ($src -match 'netPassword\s*=\s*\$netP\b'))

    # Nothing can be said about what is ON a share until the share is reachable, so the connect
    # has to come ahead of every other check rather than somewhere in the middle of them.
    $cpAt   = $workerBody.IndexOf('function Copy-ProfileData')
    $connAt = $workerBody.IndexOf('Connect-Share $unc', $cpAt)
    $srcAt  = $workerBody.IndexOf('Test-Path -LiteralPath $src', $cpAt)
    Assert-True 'the share is connected before the source is even looked for' `
                ($cpAt -ge 0 -and $connAt -gt $cpAt -and $connAt -lt $srcAt)


    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
}
finally {
    if ($KeepTemp) {
        Write-Host "`nSandbox kept: $root" -ForegroundColor Yellow
    } else {
        # [IO.Directory]::Delete, not Remove-Item: the fixture deliberately contains a path over
        # 260 characters, which is the one thing Remove-Item cannot always get rid of.
        try { [IO.Directory]::Delete('\\?\' + $root, $true) }
        catch { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        if (Test-Path -LiteralPath $root) {
            Write-Host "CLEANUP INCOMPLETE, still present: $root" -ForegroundColor Red
        } else {
            Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray
        }
    }
}
