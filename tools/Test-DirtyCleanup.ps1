<#
.SYNOPSIS
    Fault-injection harness for the dirty-install -> deep-clean path.

.DESCRIPTION
    Installers fail in ways that are hard to arrange on purpose, and the whole point of the
    Dirty verdict is that it only matters when they do. So this harness manufactures the
    failures instead of waiting for them: fake installers that exit with the exact codes a
    real one returns when it dies mid-write, is killed, is blocked at the UAC prompt, or
    lies about having succeeded.

    Nothing is re-implemented here. The elevated worker is lifted verbatim out of
    AppDeploy.ps1 (it is a here-string, so it can be extracted and run as-is), and the
    GUI-side scanner is lifted the same way through the parser. What is asserted is the
    contract between the two halves:

      1. the worker's `dirty` flag on the wire, per exit code
      2. that flag agreeing with what is actually on disk, in both directions
      3. the approved wipe deleting the debris and nothing else
      4. Scan-Leftovers NOT pre-ticking a curated path when the product pre-existed the
         batch - the failed-upgrade case, where that folder holds the working copy

    Runs unelevated. Everything happens inside a temp sandbox; no real installer is
    downloaded or executed, and nothing outside $env:TEMP is written to.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DirtyCleanup.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY inside a param default whenever the script is an advanced one -
# [CmdletBinding()] makes defaults evaluate in the CALLER's scope, which has no script root.
# The same param block without [CmdletBinding()] resolves fine, which is what makes this so
# easy to get wrong. Resolve in the body, where $PSScriptRoot is real.
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
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"

$root = Join-Path $env:TEMP ("appdeploy-dirty-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

try {
    # ------------------------------------------------------------------ extraction
    # The worker is a here-string, so the parser sees one string literal and it has to be
    # sliced out by its delimiters. Everything else is a real function and comes out of the
    # AST. Either way the code under test is the code that ships - it cannot drift.
    $startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    if (-not $startIdx) { throw 'Could not locate the $workerScript here-string.' }
    $endIdx = ($lines | Select-String -Pattern "^'@$" |
               Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
    $workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")
    $workerPath = Join-Path $root 'worker.ps1'
    # the GUI injects its preference table at this marker; no case here touches prefs
    Set-Content -LiteralPath $workerPath -Value ($workerBody -replace '#__PREFTABLE__', '') -Encoding UTF8

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $want = 'Format-Size', 'Get-FolderSize', 'ConvertTo-PSRegPath', 'Scan-Leftovers',
            'Set-Status', 'Set-Ring', 'Read-WorkerStatus'
    foreach ($name in $want) {
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract function $name" }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    # the real AppItem / WipeItem types, so a renamed field breaks this test rather than
    # silently passing against a stand-in
    $typeStart = ($lines | Select-String -SimpleMatch "Add-Type -TypeDefinition @'" | Select-Object -First 1).LineNumber
    $typeEnd = ($lines | Select-String -Pattern "^'@$" |
                Where-Object { $_.LineNumber -gt $typeStart } | Select-Object -First 1).LineNumber
    Add-Type -TypeDefinition (($lines[$typeStart..($typeEnd - 2)]) -join "`r`n")

    # module-scope state and the UI sinks Scan-Leftovers narrates through
    $script:ProtectedPaths = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:ProtectedPaths' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
    $script:SharedComponentHints = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:SharedComponentHints' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
    $StatusPalette = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$StatusPalette' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) }
    $script:ScanLabel = 'test'
    $TxtNow = [pscustomobject]@{ Text = '' }
    $DotNow = [pscustomobject]@{ Fill = '' }
    function Update-UI { }   # no dispatcher outside the GUI

    Write-Host ("Extracted worker ({0} lines), {1} functions, {2} protected paths." -f `
                ($endIdx - $startIdx - 1), $want.Count, $script:ProtectedPaths.Count) -ForegroundColor DarkGray

    # ------------------------------------------------------- fake installers (the faults)
    $cases = @(
        @{ Id = 'clean';  Code = 0;    Verify = $true;  Debris = $false
           Why = 'installs properly'                 ; State = 'Installed'; Dirty = $false }
        @{ Id = 'fatal';  Code = 1603; Verify = $false; Debris = $true
           Why = 'fatal error mid-install'           ; State = 'Failed'   ; Dirty = $true  }
        @{ Id = 'uac';    Code = 1223; Verify = $false; Debris = $false
           Why = 'UAC declined - nothing ever ran'   ; State = 'Failed'   ; Dirty = $false }
        @{ Id = 'liar';   Code = 0;    Verify = $false; Debris = $true
           Why = 'exits 0 but installs nothing'      ; State = 'Failed'   ; Dirty = $true  }
        @{ Id = 'killed'; Code = -1;   Verify = $false; Debris = $true
           Why = 'terminated by Task Manager or AV'  ; State = 'Failed'   ; Dirty = $true  }
    )

    $queue  = Join-Path $root 'queue.jsonl'
    $status = Join-Path $root 'status.jsonl'
    $cancel = Join-Path $root 'cancel.flag'

    foreach ($c in $cases) {
        $c.VerifyDir = Join-Path $root "installed\$($c.Id)"
        $c.DebrisDir = Join-Path $root "debris\$($c.Id)"
        $body = @('@echo off')
        # debris first: a real installer writes files long before it finds out it has failed
        if ($c.Debris) {
            $body += "mkdir `"$($c.DebrisDir)`" 2>nul"
            $body += "echo partial > `"$($c.DebrisDir)\halfwritten.dat`""
        }
        if ($c.Verify) {
            $body += "mkdir `"$($c.VerifyDir)`" 2>nul"
            $body += "echo app > `"$($c.VerifyDir)\app.exe`""
        }
        $body += "exit /b $($c.Code)"
        $exe = Join-Path $root "fake-$($c.Id).cmd"
        Set-Content -LiteralPath $exe -Value ($body -join "`r`n") -Encoding ASCII
        Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
            id = $c.Id; action = 'install'; file = $exe
            sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
            silentArgs = ''; verifyPaths = @("$($c.VerifyDir)\app.exe"); postInstall = @()
        } | ConvertTo-Json -Compress -Depth 6)
    }

    # A zip package: a multi-file installer, exactly the shape 12 of the 17 real catalog
    # entries have. setup.cmd refuses to run unless its sibling payload travelled with it,
    # which is precisely what shipping one file out of a folder gets wrong. It then fails
    # 1603, so this also proves the real installer's exit code survives unpacking - the
    # thing a self-extracting exe was measured NOT to do.
    $zipSrc = Join-Path $root 'zipsrc\inner'
    New-Item -ItemType Directory -Force -Path $zipSrc | Out-Null
    $sl = [char]47
    Set-Content -LiteralPath "$zipSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off',
        "if not exist `"%~dp0payload.dat`" exit ${sl}b 9009",
        "if not exist `"configuration.xml`" exit ${sl}b 9010",
        "mkdir `"$root\debris\zipped`" 2>nul",
        "echo halfwritten > `"$root\debris\zipped\engine.dll`"",
        "exit ${sl}b 1603") -join "`r`n")
    Set-Content -LiteralPath "$zipSrc\payload.dat" -Encoding ASCII -Value 'must travel with setup.cmd'
    # the 9010 check reads a RELATIVE path, which only resolves if the working directory
    # follows the installer into its own folder - Office's '/configure configuration.xml'
    Set-Content -LiteralPath "$zipSrc\configuration.xml" -Encoding ASCII -Value '<Configuration/>'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $root 'demo-package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $zipSrc -Parent), $zipPath)
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'zipped'; action = 'install'; file = $zipPath; sha256 = $zipHash
        silentArgs = ''; entry = 'inner\setup.cmd'
        verifyPaths = @((Join-Path $root 'installed\zipped\app.exe')); postInstall = @()
    } | ConvertTo-Json -Compress -Depth 6)

    # a package whose entry does not exist: a catalog typo has to fail loudly, never run
    # something arbitrary out of the archive
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'badentry'; action = 'install'; file = $zipPath; sha256 = $zipHash
        silentArgs = ''; entry = 'inner\notthere.exe'; verifyPaths = @(); postInstall = @()
    } | ConvertTo-Json -Compress -Depth 6)

    # The shape the real catalog actually has: a zip holding the installer AND the documents
    # that ship with it. setup runs, and afterwards a file is taken OUT of the same unpacked
    # folder into the installed directory. That folder used to be deleted the moment the
    # installer exited, which made this impossible - so this case is really a test that it
    # survives long enough, and is still cleaned up once the app is finished with.
    $docSrc = Join-Path $root 'docsrc\inner'
    New-Item -ItemType Directory -Force -Path "$docSrc\Doc" | Out-Null
    $docInstall = Join-Path $root 'installed\docs'
    Set-Content -LiteralPath "$docSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off',
        "mkdir `"$docInstall`" 2>nul",
        "echo app > `"$docInstall\app.exe`"",
        "exit ${sl}b 0") -join "`r`n")
    Set-Content -LiteralPath "$docSrc\Doc\readme.md" -Encoding ASCII -Value '# how to activate this product'
    $docZip = Join-Path $root 'docs-package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $docSrc -Parent), $docZip)
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'docs'; action = 'install'; file = $docZip
        sha256 = (Get-FileHash -LiteralPath $docZip -Algorithm SHA256).Hash
        silentArgs = ''; entry = 'inner\setup.cmd'
        verifyPaths = @("$docInstall\app.exe")
        postInstall = @(@{ type = 'copy'; name = 'Copy readme.md'
                           from = 'inner\Doc\readme.md'; dest = "$docInstall\" })
    } | ConvertTo-Json -Compress -Depth 6)

    # Where did it land? The worker snapshots top-level directories under a set of roots
    # before and after the installer, and reports what appeared. Pointing those roots at the
    # sandbox is the only way to test it without installing something real - which is what the
    # PC2GO_WATCH_ROOTS seam exists for.
    $watchRoot = Join-Path $root 'roots'
    New-Item -ItemType Directory -Force -Path $watchRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $watchRoot 'AlreadyHere') | Out-Null
    $watchExe = Join-Path $root 'fake-watched.cmd'
    Set-Content -LiteralPath $watchExe -Encoding ASCII -Value (@(
        '@echo off',
        "mkdir `"$watchRoot\WatchedApp`" 2>nul",
        "echo halfwritten > `"$watchRoot\WatchedApp\engine.dll`"",
        "exit ${sl}b 1603") -join "`r`n")
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'watched'; action = 'install'; file = $watchExe
        sha256 = (Get-FileHash -LiteralPath $watchExe -Algorithm SHA256).Hash
        silentArgs = ''; verifyPaths = @(); postInstall = @()
    } | ConvertTo-Json -Compress -Depth 6)

    # ---- the OTHER destructive half: removal itself -------------------------------------
    # Every case here uses a fake uninstaller in the sandbox. Nothing real is removed, and the
    # appx branch is deliberately left alone - the only way to test that is to remove a genuine
    # Store app from this machine.
    $unDir = Join-Path $root 'uninst'
    New-Item -ItemType Directory -Force -Path $unDir | Out-Null
    function New-FakeUninstaller([string]$name, [int]$code, [string]$removes) {
        $f = Join-Path $unDir "$name.cmd"
        $lines = @('@echo off')
        if ($removes) { $lines += "rmdir ${sl}s ${sl}q `"$removes`" 2>nul" }
        $lines += "exit ${sl}b $code"
        Set-Content -LiteralPath $f -Encoding ASCII -Value ($lines -join "`r`n")
        return $f
    }
    # 1. a clean removal: the uninstaller works and its detect target disappears
    $instA = Join-Path $unDir 'ProductA'
    New-Item -ItemType Directory -Force -Path $instA | Out-Null
    Set-Content -LiteralPath "$instA\a.exe" -Value 'x' -Encoding ASCII
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'un-clean'; action = 'uninstall'
        command = (New-FakeUninstaller 'clean' 0 $instA); args = ''
        detect = "$instA\a.exe"; location = $instA
    } | ConvertTo-Json -Compress)
    # 2. the uninstaller returns a failure code
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'un-fail'; action = 'uninstall'
        command = (New-FakeUninstaller 'broken' 1603 ''); args = ''
        detect = ''; location = ''
    } | ConvertTo-Json -Compress)
    # 3. it claims success but the product is still there - the uninstall equivalent of a liar
    $instC = Join-Path $unDir 'ProductC'
    New-Item -ItemType Directory -Force -Path $instC | Out-Null
    Set-Content -LiteralPath "$instC\c.exe" -Value 'x' -Encoding ASCII
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'un-liar'; action = 'uninstall'
        command = (New-FakeUninstaller 'liar' 0 ''); args = ''
        detect = "$instC\c.exe"; location = $instC
    } | ConvertTo-Json -Compress)
    # 4. the uninstaller named in the registry no longer exists
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'un-missing'; action = 'uninstall'
        command = (Join-Path $unDir 'not-there.exe'); args = ''
        detect = ''; location = ''
    } | ConvertTo-Json -Compress)
    # 5. 3010 is "removed, reboot required" - a success, not a failure
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'un-reboot'; action = 'uninstall'
        command = (New-FakeUninstaller 'reboot' 3010 ''); args = ''
        detect = ''; location = ''
    } | ConvertTo-Json -Compress)

    # ---- refusal rails on the actions that change a machine ------------------------------
    # These actions are not executed here, on purpose: newuser creates a local administrator,
    # deleteaccount removes one, fwblock rewrites the firewall, tweak edits the registry.
    # Running them to "test" them would be doing the damage. What IS testable, and is the part
    # that protects a client, is that each refuses bad input BEFORE it touches anything.
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'bad-tweak'; action = 'tweak'; tweak = 'no-such-tweak-id'
    } | ConvertTo-Json -Compress)
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'bad-untweak'; action = 'untweak'; tweak = 'no-such-tweak-id'
    } | ConvertTo-Json -Compress)
    # a post-install kill step whose folder is short enough to match half the machine
    $railExe = Join-Path $root 'fake-rails.cmd'
    Set-Content -LiteralPath $railExe -Encoding ASCII -Value (@(
        '@echo off', "mkdir `"$root\installed\rails`" 2>nul",
        "echo app > `"$root\installed\rails\app.exe`"", "exit ${sl}b 0") -join "`r`n")
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'rails'; action = 'install'; file = $railExe
        sha256 = (Get-FileHash -LiteralPath $railExe -Algorithm SHA256).Hash
        silentArgs = ''; verifyPaths = @("$root\installed\rails\app.exe")
        postInstall = @(
            @{ type = 'kill';    name = 'too broad';   folder = 'C:\' }
            @{ type = 'kill';    name = 'nothing set' }
            @{ type = 'service'; name = 'no name given'; action = 'stop' }
            @{ type = 'run';     name = 'unverified';  file = $railExe }
            @{ type = 'copy';    name = 'from no zip'; from = 'Doc\x.txt'; dest = "$root\installed\rails\" }
            @{ type = 'nonsense'; name = 'unknown type' })
    } | ConvertTo-Json -Compress -Depth 6)

    # Two files out of one package, into two DIFFERENT directories. The worker takes an array
    # of post-install steps, so this needs no new machinery - but it had never been proven, and
    # the editor can only express one, so it is worth pinning down what the engine can do.
    $twoSrc = Join-Path $root 'twosrc\inner'
    New-Item -ItemType Directory -Force -Path "$twoSrc\Doc","$twoSrc\Lic" | Out-Null
    $twoInst = Join-Path $root 'installed\two'
    $twoOther = Join-Path $root 'installed\two-config'
    Set-Content -LiteralPath "$twoSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off', "mkdir `"$twoInst`" 2>nul", "echo app > `"$twoInst\app.exe`"",
        "exit ${sl}b 0") -join "`r`n")
    Set-Content -LiteralPath "$twoSrc\Doc\readme.md" -Encoding ASCII -Value 'readme body'
    Set-Content -LiteralPath "$twoSrc\Lic\licence.dat" -Encoding ASCII -Value 'licence body'
    $twoZip = Join-Path $root 'two-package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $twoSrc -Parent), $twoZip)
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'twofiles'; action = 'install'; file = $twoZip
        sha256 = (Get-FileHash -LiteralPath $twoZip -Algorithm SHA256).Hash
        silentArgs = ''; entry = 'inner\setup.cmd'
        verifyPaths = @("$twoInst\app.exe")
        postInstall = @(
            @{ type = 'copy'; name = 'Copy readme.md';   from = 'inner\Doc\readme.md';   dest = "$twoInst\" }
            @{ type = 'copy'; name = 'Copy licence.dat'; from = 'inner\Lic\licence.dat'; dest = "$twoOther\" })
    } | ConvertTo-Json -Compress -Depth 6)

    # the wipe the GUI queues once the technician approves the kill list
    $wipeTarget = Join-Path $root 'debris\fatal'
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'fatal'; action = 'wipe'
        targets = @(@{ type = 'file'; path = $wipeTarget })
    } | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8

    Write-Section 'Running the real elevated worker against the injected faults'
    # inherited by the worker process this launches
    $env:PC2GO_WATCH_ROOTS = $watchRoot
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker exited {0} after {1:N1}s" -f $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray

    $reported = @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue |
                  ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })

    Write-Section '1. The dirty verdict on the wire'
    foreach ($c in $cases) {
        $final = @($reported | Where-Object { $_.id -eq $c.Id -and $_.state -in 'Installed', 'Failed' }) |
                 Select-Object -First 1
        if (-not $final) {
            $script:Fail++
            Write-Host ("  FAIL  {0} ({1}): the worker never reported a verdict" -f $c.Id, $c.Why) -ForegroundColor Red
            continue
        }
        Assert-Equal ("{0,-7} exit {1,-5} {2} -> state" -f $c.Id, $c.Code, $c.Why) $c.State $final.state
        Assert-Equal ("{0,-7} exit {1,-5} {2} -> dirty" -f $c.Id, $c.Code, $c.Why) $c.Dirty ([bool]$final.dirty)
    }

    Write-Section '1b. Multi-file packages: the folder arrives intact, the exit code survives'
    $zip = @($reported | Where-Object { $_.id -eq 'zipped' -and $_.state -in 'Installed', 'Failed' }) | Select-Object -First 1
    # 9009 = the sibling payload never arrived (what shipping one file out of a folder does)
    # 9010 = it arrived but the working directory did not follow the installer in
    # 0      = a wrapper swallowed the installer's real verdict
    Assert-Equal 'sibling payload travelled with the installer' $true  ($zip.detail -notmatch '9009')
    Assert-Equal 'relative path resolved (working directory)'   $true  ($zip.detail -notmatch '9010')
    Assert-Equal 'the INSTALLER''s 1603 survived unpacking'     $true  ([bool]($zip.detail -match 'fatal error'))
    Assert-Equal 'and it is still reported dirty'               $true  ([bool]$zip.dirty)
    Assert-Equal 'the unpacked copy was not left on disk'       $false (Test-Path -LiteralPath (Join-Path $root 'zipped-unpacked'))

    # the terminal record, not the first 'Verifying file' one
    $bad = @($reported | Where-Object { $_.id -eq 'badentry' -and $_.state -in 'Installed', 'Failed' }) | Select-Object -First 1
    Assert-Equal 'a missing entry fails loudly'                 'Failed' $bad.state
    Assert-Equal 'and names what it could not find'             $true    ([bool]($bad.detail -match 'notthere\.exe'))
    Assert-Equal 'a catalog typo is not treated as dirty'       $false   ([bool]$bad.dirty)

    Write-Section '1c. A file taken OUT of the package, after the install succeeds'
    $docs = @($reported | Where-Object { $_.id -eq 'docs' -and $_.state -in 'Installed', 'Failed', 'Skipped' }) |
            Select-Object -First 1
    Assert-Equal 'the package installed'                     'Installed' $docs.state
    Assert-Equal 'readme.md was copied into the install dir' $true  (Test-Path -LiteralPath (Join-Path $root 'installed\docs\readme.md'))
    Assert-Equal 'it kept its own name and contents'         '# how to activate this product' `
                 ("$(Get-Content -LiteralPath (Join-Path $root 'installed\docs\readme.md') -Raw -ErrorAction SilentlyContinue)".Trim())
    Assert-Equal 'the unpacked package was cleaned up after' $false (Test-Path -LiteralPath (Join-Path $root 'docs-unpacked'))
    Assert-Equal 'and a successful install is never dirty'   $false ([bool]$docs.dirty)

    Write-Section '1d. Where did it land - observed, not guessed'
    $w = @($reported | Where-Object { $_.id -eq 'watched' -and $_.state -in 'Installed', 'Failed' }) |
         Select-Object -First 1
    $made = @($w.created)
    Assert-Equal 'the new folder was observed'            $true ($made -contains (Join-Path $watchRoot 'WatchedApp'))
    Assert-Equal 'exactly one folder, not the whole root' 1     $made.Count
    Assert-Equal 'a folder already present is not claimed' $false ($made -contains (Join-Path $watchRoot 'AlreadyHere'))
    Assert-Equal 'and it still reports dirty'             $true  ([bool]$w.dirty)

    # Observation beats the pre-existing rule: that rule protects a folder that might be the
    # PREVIOUS install's working copy, and a folder created during this batch cannot be.
    $obs = New-Object AppItem
    $obs.Id = 'obs'; $obs.Name = 'Observed App'
    $obs.CleanPaths = @(); $obs.CleanReg = @(); $obs.CleanHosts = @(); $obs.CleanTokens = @()
    $obs.CreatedPaths = @((Join-Path $watchRoot 'WatchedApp'))
    $hit = @(Scan-Leftovers $obs $false) | Where-Object { $_.Kind -eq 'CREATED' } | Select-Object -First 1
    Assert-Equal 'the scan lists it as CREATED'           $true  ([bool]$hit)
    Assert-Equal 'pre-ticked even with PreCheck off'      $true  $hit.Del

    Write-Section '1e. Removal - the other half that deletes things'
    function Get-UnState([string]$id) {
        $r = @($reported | Where-Object { $_.id -eq $id -and $_.state -in 'Uninstalled', 'Failed' }) | Select-Object -First 1
        if ($r) { return $r } else { return @{ state = '(none)'; detail = '' } }
    }
    $uc = Get-UnState 'un-clean'
    Assert-Equal 'a working uninstaller reports Uninstalled'   'Uninstalled' $uc.state
    Assert-Equal 'and the product really is gone'              $false (Test-Path -LiteralPath $instA)
    $uf = Get-UnState 'un-fail'
    Assert-Equal 'a failing uninstaller is reported failed'    'Failed' $uf.state
    Assert-Equal 'with the exit code named'                    $true ([bool]($uf.detail -match '1603'))
    $ul = Get-UnState 'un-liar'
    Assert-Equal 'exit 0 with the product still there fails'   'Failed' $ul.state
    Assert-Equal 'and says it is still detected'               $true ([bool]($ul.detail -match 'still detected'))
    $um = Get-UnState 'un-missing'
    Assert-Equal 'a missing uninstaller fails loudly'          'Failed' $um.state
    Assert-Equal 'and says the uninstaller was not found'      $true ([bool]($um.detail -match 'not found'))
    $ur = Get-UnState 'un-reboot'
    Assert-Equal '3010 is removal, not failure'                'Uninstalled' $ur.state

    Write-Section '1f. Actions that change a machine refuse bad input first'
    $bt = @($reported | Where-Object { $_.id -eq 'bad-tweak' -and $_.state -eq 'Failed' }) | Select-Object -First 1
    Assert-Equal 'an unknown tweak id is refused'        $true ([bool]$bt)
    Assert-Equal 'and the id is named in the message'    $true ([bool]($bt.detail -match 'no-such-tweak-id'))
    $bu = @($reported | Where-Object { $_.id -eq 'bad-untweak' -and $_.state -eq 'Failed' }) | Select-Object -First 1
    Assert-Equal 'an unknown untweak id is refused'      $true ([bool]$bu)

    # every post-install step above is bad in a different way; the app still installs, and the
    # steps report as problems rather than being silently skipped
    $rl = @($reported | Where-Object { $_.id -eq 'rails' -and $_.state -in 'Installed', 'Failed', 'Skipped' }) | Select-Object -First 1
    Assert-Equal 'the install itself still succeeded'    'Skipped' $rl.state
    $d = [string]$rl.detail
    Assert-Equal 'a kill folder of C:\ is refused as too broad' $true ([bool]($d -match 'too broad'))
    Assert-Equal 'and the problems are counted, not hidden'      $true ([bool]($d -match 'post-install issue'))

    Write-Section '1g. Two files, two different directories'
    $tw = @($reported | Where-Object { $_.id -eq 'twofiles' -and $_.state -in 'Installed','Failed','Skipped' }) | Select-Object -First 1
    Assert-Equal 'the package installed'                  'Installed' $tw.state
    Assert-Equal 'file 1 landed in the install folder'    $true (Test-Path -LiteralPath (Join-Path $twoInst 'readme.md'))
    Assert-Equal 'file 2 landed somewhere else entirely'  $true (Test-Path -LiteralPath (Join-Path $twoOther 'licence.dat'))
    Assert-Equal 'a directory that did not exist is made' $true (Test-Path -LiteralPath $twoOther)
    Assert-Equal 'and each kept its own contents'         'licence body' `
                 ("$(Get-Content -LiteralPath (Join-Path $twoOther 'licence.dat') -Raw -ErrorAction SilentlyContinue)".Trim())

    Write-Section '2. The flag agrees with the disk, in both directions'
    # a Dirty verdict that fires on a clean machine costs a pointless scan; one that misses
    # a mess costs a support call - so both mistakes are checked for
    foreach ($c in $cases) {
        if ($c.Id -eq 'fatal') { continue }   # its debris is asserted below, after the wipe
        Assert-Equal ("{0,-7} debris on disk matches its dirty flag" -f $c.Id) `
                     $c.Dirty (Test-Path -LiteralPath $c.DebrisDir)
    }

    Write-Section '3. The approved wipe deleted the mess, and only the mess'
    $cleaned = @($reported | Where-Object { $_.id -eq 'fatal' -and $_.state -eq 'Cleaned' }) | Select-Object -First 1
    Assert-Equal 'wipe reported Cleaned'                 $true  ([bool]$cleaned)
    Assert-Equal 'wipe detail names what it removed'     $true  ([bool]($cleaned.detail -match 'trace'))
    Assert-Equal 'the partial install is gone from disk' $false (Test-Path -LiteralPath $wipeTarget)
    Assert-Equal 'the healthy install was NOT touched'   $true  (Test-Path -LiteralPath (Join-Path $root 'installed\clean\app.exe'))

    # ------------------------------------------------------------- GUI-side pre-tick rule
    Write-Section '4. Curated targets are pre-ticked only when this batch created them'
    $curated = Join-Path $root 'appdata\Vendor\FakeSuite'
    New-Item -ItemType Directory -Force -Path $curated | Out-Null
    Set-Content -LiteralPath (Join-Path $curated 'settings.ini') -Value 'user data' -Encoding ASCII

    $item = New-Object AppItem
    $item.Id = 'fake-suite'; $item.Name = 'Fake Suite'
    $item.CleanPaths = @($curated); $item.CleanReg = @(); $item.CleanHosts = @()
    # a token nothing on a real machine can match, so the sweep stays deterministic
    $item.CleanTokens = @('Zzq7FakeSuiteToken')

    $fresh   = @(Scan-Leftovers $item $true)  | Where-Object { $_.Path -eq $curated } | Select-Object -First 1
    $upgrade = @(Scan-Leftovers $item $false) | Where-Object { $_.Path -eq $curated } | Select-Object -First 1

    Assert-Equal 'curated path is found either way'                 $true  ([bool]$fresh -and [bool]$upgrade)
    Assert-Equal 'fresh install failed -> pre-ticked for deletion'  $true  $fresh.Del
    Assert-Equal 'failed upgrade       -> NOT pre-ticked'           $false $upgrade.Del
    Assert-Equal 'the folder survived the scan (it only reads)'     $true  (Test-Path -LiteralPath $curated)

    Write-Section '4b. The rails that stop it deleting the wrong thing'
    # This is the destructive half of the tool. Everything above decides WHAT to offer; these
    # decide what must never be offered, or never be offered pre-ticked. They matter more than
    # any of it, because the failure mode is not "install did not work" - it is a client's
    # machine losing a folder it needed.
    $guard = New-Object AppItem
    $guard.Id = 'guard'; $guard.Name = 'Guard Test'
    $guard.CleanReg = @(); $guard.CleanHosts = @(); $guard.CleanTokens = @()
    $guard.CleanPaths = @($env:SystemRoot, $env:ProgramFiles, $env:ProgramData, $env:AppData)
    $rails = @(Scan-Leftovers $guard $true)
    Assert-Equal 'a protected root is never listed at all' 0 $rails.Count

    # a suite component several products share - found, but never ticked for you
    $sharedDir = Join-Path $root 'Autodesk Shared'
    New-Item -ItemType Directory -Force -Path $sharedDir | Out-Null
    Set-Content -LiteralPath (Join-Path $sharedDir 'licensing.dll') -Value 'x' -Encoding ASCII
    $sh = New-Object AppItem
    $sh.Id = 'sh'; $sh.Name = 'Shared Test'
    $sh.CleanReg = @(); $sh.CleanHosts = @(); $sh.CleanTokens = @()
    $sh.CleanPaths = @($sharedDir)
    $shHit = @(Scan-Leftovers $sh $true) | Where-Object { $_.Path -eq $sharedDir } | Select-Object -First 1
    Assert-Equal 'a shared suite component is still listed'   $true  ([bool]$shHit)
    Assert-Equal 'but never pre-ticked, even when curated'    $false $shHit.Del
    Assert-Equal 'and is flagged as shared so it says why'    $true  $shHit.Shared

    # the sharp one: Revit creates Autodesk Shared, then fails. The new CREATED rule pre-ticks
    # observed folders unconditionally - it must NOT win over the shared-component guard, or a
    # failed Revit install would offer to delete what Civil 3D and Navisworks depend on.
    $sh2 = New-Object AppItem
    $sh2.Id = 'sh2'; $sh2.Name = 'Shared Created'
    $sh2.CleanPaths = @(); $sh2.CleanReg = @(); $sh2.CleanHosts = @(); $sh2.CleanTokens = @()
    $sh2.CreatedPaths = @($sharedDir)
    $obsHit = @(Scan-Leftovers $sh2 $true) | Where-Object { $_.Path -eq $sharedDir } | Select-Object -First 1
    Assert-Equal 'observed-created is listed'                 $true  ([bool]$obsHit)
    Assert-Equal 'shared still wins over observed-created'    $false $obsHit.Del

    # a two-letter product name must not match half the disk
    $tok = New-Object AppItem
    $tok.Id = 'tok'; $tok.Name = 'AB'
    $tok.CleanPaths = @(); $tok.CleanReg = @(); $tok.CleanHosts = @(); $tok.CleanTokens = @('AB')
    Assert-Equal 'a token under 4 characters is ignored'      0 @(Scan-Leftovers $tok $true).Count

    Write-Section '5. PreExisting decides that, and is read before anything runs'
    # mirrors Enqueue-Install: verifyPaths tested from the GUI, before the installer starts
    $probe = {
        param($paths)
        foreach ($vp in @($paths)) {
            if ($vp -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($vp)))) { return $true }
        }
        return $false
    }
    Assert-Equal 'product already on disk -> PreExisting true'  $true  (& $probe @((Join-Path $root 'installed\clean\app.exe')))
    Assert-Equal 'product not yet on disk -> PreExisting false' $false (& $probe @((Join-Path $root 'installed\nothing\app.exe')))

    # ------------------------------------------------------------------ the batch gate
    # The end marker is now withheld until every app has reported, because the worker has
    # to still be alive to wipe a failed install's debris. That makes Read-WorkerStatus the
    # thing that decides when the batch may end - and getting it wrong does not produce a
    # wrong answer, it produces a batch that never finishes. The real function is driven
    # here against synthetic rows, with only its three exits stubbed, so the decision is
    # what gets asserted.
    Write-Section '6. When every app has reported, what happens next'
    function Start-LeftoverScan { $script:Called += 'scan' }
    function Complete-Worker    { $script:Called += 'release' }
    function Finish-Batch       { $script:Called += 'finish' }
    function Add-Log([string]$m) { }

    $script:StatusPath = Join-Path $root 'gate-status.jsonl'

    function New-Row([string]$Id) {
        $r = New-Object AppItem
        $r.Id = $Id; $r.Name = "Row $Id"
        $r
    }
    function Invoke-Gate {
        param([string[]]$Ids, [string]$Tab, [bool]$EndQueued, [string[]]$Lines)
        $script:Pending      = @($Ids | ForEach-Object { New-Row $_ })
        $script:BatchTab     = $Tab
        $script:EndQueued    = $EndQueued
        $script:AwaitingScan = $true
        $script:StatusOffset = 0
        $script:Called       = @()
        Set-Content -LiteralPath $script:StatusPath -Value $Lines -Encoding UTF8
        Read-WorkerStatus
        , $script:Called
    }
    function S([string]$Id, [string]$State, [string]$Detail = '', [bool]$Dirty = $false) {
        @{ id = $Id; state = $State; detail = $Detail; dirty = $Dirty } | ConvertTo-Json -Compress
    }

    # THE regression this guards: with the end marker held back, a batch where nothing went
    # wrong must still release the worker. If this ever returns nothing, the tool hangs on
    # a completely successful run - the worst possible way to fail.
    $r = Invoke-Gate -Ids 'a','b' -Tab 'Install' -EndQueued $false -Lines @((S 'a' 'Installed'), (S 'b' 'Installed'))
    Assert-Equal 'clean install batch      -> releases the worker, no scan' 'release' ($r -join ',')

    $r = Invoke-Gate -Ids 'a','b' -Tab 'Install' -EndQueued $false -Lines @(
        (S 'a' 'Installed'), (S 'b' 'Failed' 'fatal error during installation' $true))
    Assert-Equal 'install failed dirty     -> leftover scan'                'scan'    ($r -join ',')

    $r = Invoke-Gate -Ids 'a','b' -Tab 'Install' -EndQueued $false -Lines @(
        (S 'a' 'Installed'), (S 'b' 'Failed' 'the UAC prompt was declined' $false))
    Assert-Equal 'install failed clean     -> no pointless scan'            'release' ($r -join ',')

    $r = Invoke-Gate -Ids 'a' -Tab 'Un' -EndQueued $false -Lines @((S 'a' 'Uninstalled'))
    Assert-Equal 'uninstall batch          -> always scans'                 'scan'    ($r -join ',')

    # a cancel writes the end marker itself; the worker is already gone, so a kill list
    # would be an offer nothing could honour
    $r = Invoke-Gate -Ids 'a' -Tab 'Install' -EndQueued $true -Lines @((S 'a' 'Failed' 'killed' $true))
    Assert-Equal 'cancelled batch          -> neither, worker already gone' ''        ($r -join ',')

    $r = Invoke-Gate -Ids 'a','b' -Tab 'Install' -EndQueued $false -Lines @(
        (S 'a' 'Installed'), (S 'b' 'Installing'))
    Assert-Equal 'one app still installing -> waits'                        ''        ($r -join ',')
    Assert-Equal 'and stays armed for the next tick'                        $true     $script:AwaitingScan

    $r = Invoke-Gate -Ids 'a' -Tab 'Install' -EndQueued $true -Lines @((S 'a' 'Installed'), (S '_batch' 'Complete'))
    Assert-Equal 'the worker signing off   -> finishes the batch'           'finish'  ($r -join ',')

    Write-Section '7. A wiped failure is still a failure'
    $null = Invoke-Gate -Ids 'a' -Tab 'Install' -EndQueued $false -Lines @(
        (S 'a' 'Failed' 'fatal error during installation' $true),
        (S 'a' 'Cleaned' '6 trace(s) removed'))
    $row = $script:Pending[0]
    Assert-Equal 'row is marked dirty by the worker verdict' $true  $row.Dirty
    Assert-Equal 'row still reads as failed after the wipe'  $true  ($row.Status -like 'Failed*')
    Assert-Equal 'and still says what was removed'           $true  ($row.Status -like '*6 trace(s) removed*')
    Assert-Equal 'red, not green'                            $StatusPalette['fail'] $row.StatusFg

    # the same row after a successful install must NOT be dragged into any of this
    $null = Invoke-Gate -Ids 'a' -Tab 'Install' -EndQueued $false -Lines @((S 'a' 'Installed'))
    Assert-Equal 'a healthy row is never marked dirty'       $false $script:Pending[0].Dirty
}
finally {
    if ($KeepTemp) { Write-Host "`nSandbox kept: $root" -ForegroundColor Yellow }
    else { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
