<#
.SYNOPSIS
    Drives the real Install and Uninstall tabs - the buttons, not the worker underneath them.

.DESCRIPTION
    Every other harness stops at the worker. This one starts at the GUI: it loads AppDeploy.ps1
    up to its "go" line, so the window is built and every handler is wired, then clicks the real
    buttons on a window that is never shown. The app rows are plain objects with an IsSelected
    flag, so ticking one needs no UI Automation - which is what made this untestable before.

    Two things are neutralised, both deliberately, and both named here so nobody mistakes this
    for a full-fidelity run:

      * -NoSelfElevate, so the script does not relaunch itself through UAC. A real, supported
        switch, not a test hook.
      * Start-Worker is redefined to launch the SAME worker script without -Verb RunAs. The
        elevation prompt is the one thing an unattended run cannot answer; everything the worker
        then does is the real code doing it.

    What is exercised: Load-Catalog against a local catalog, selection, Start-Batch, the
    already-downloaded branch that skips a re-download, Enqueue-Install, the streaming queue,
    Read-WorkerStatus, Finish-Batch and its cache cleanup, Add to Queue mid-batch, Cancel's
    promise that a running install is never killed, then the Uninstall tab: the registry scan,
    ticking rows, Uninstall Selected, the leftover preview, and Wipe checked.

    The session cache is redirected into the sandbox, so this machine's real PC2GoDeploy folder
    is never touched and two runs can never share a queue file. That second part matters: a
    worker only exits when it reads the end marker, so a run that ends without releasing it
    leaves the process polling for ever, and the next run's items are then consumed by BOTH
    workers - which collide on the same install and fail it with exit code 1. Orphans are killed
    on the way in and on the way out.

    Runs unelevated. Per-user products only, no HKLM, and everything it creates it removes.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-GuiBatch.ps1
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
# Install Selected and Uninstall Selected now open the pre-flight sheet first, so a press is two
# steps. Guarded rather than unconditional: pressing Install DURING a running batch still extends
# it directly and shows no sheet, and both paths have to keep working.
function Invoke-Commit($Button) {
    Invoke-Click $Button
    if ($PreflightOverlay -and "$($PreflightOverlay.Visibility)" -eq 'Visible') {
        # Every fake app here verifies against the same app.exe, so from the second batch on the
        # sheet sees them as already installed and skips them - which is the tool doing its job.
        # The harness is the technician who wants them run again, so it ticks the box.
        if ($ChkPfHave -and $PfHave -and "$($PfHave.Visibility)" -eq 'Visible') { $ChkPfHave.IsChecked = $true }
        Invoke-Click $BtnPfGo
    }
}

function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tag         = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox     = Join-Path $env:TEMP "pc2go-gui-$tag"
$installRoot = Join-Path $env:LOCALAPPDATA "PC2GoGuiTest-$tag"
$unRoot      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$keyU        = "$unRoot\PC2GoGui-$tag"

function Remove-Artefacts {
    try { if (Test-Path -LiteralPath $keyU) { Remove-Item -LiteralPath $keyU -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    foreach ($d in @($installRoot, $sandbox)) {
        try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

# lets the GUI's own dispatcher timers tick - the download pump and the status reader are
# DispatcherTimers, so without a frame running nothing in a batch ever advances
function Wait-Dispatcher([int]$Milliseconds) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
    $t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-For([scriptblock]$Until, [int]$TimeoutMs = 120000, [int]$Step = 250) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if (& $Until) { return $true }
        Wait-Dispatcher $Step
        $waited += $Step
    }
    return [bool](& $Until)
}
function Invoke-Click($Button) {
    $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

# A worker only exits when it reads the end marker. A run that finishes without releasing it
# leaves the process polling its queue for ever, and it is invisible - no window, no console.
# Anything left over from this harness is this harness's mess to clear up.
function Stop-OrphanWorkers([string]$Match = 'pc2go-gui-') {
    $n = 0
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
            if ($p.CommandLine -and $p.CommandLine -like '*worker.ps1*' -and $p.CommandLine -like "*$Match*") {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ } catch {}
            }
        }
    } catch {}
    return $n
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host "Sandbox   : $sandbox" -ForegroundColor DarkGray
    # anything still polling from an earlier run of THIS harness, before a new one starts
    $killed = Stop-OrphanWorkers
    if ($killed) { Write-Host "  killed $killed orphaned worker(s) from a previous run" -ForegroundColor Yellow }

    # ================================================================== a real package + catalog
    Write-Section 'Building a real package and a local catalog'

    $pkgSrc = Join-Path $sandbox 'src\inner'
    New-Item -ItemType Directory -Force -Path $pkgSrc | Out-Null
    $appDir = Join-Path $installRoot 'GuiApp'
    $sl = '/'
    # ping, not timeout: `timeout` reads the console and fails outright when stdin is
    # redirected. The delay is the point - an install that finishes instantly leaves no window
    # in which to press Cancel, and Cancel's promise is exactly what section 2 is about.
    Set-Content -LiteralPath "$pkgSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off',
        'ping -n 4 127.0.0.1 >nul',
        "mkdir `"$appDir`" 2>nul",
        "echo app > `"$appDir\app.exe`"",
        "exit ${sl}b 0") -join "`r`n")
    $zip = Join-Path $sandbox 'package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $pkgSrc -Parent), $zip)
    $sha  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $size = (Get-Item -LiteralPath $zip).Length

    # A tiny REAL remover exe: writes "<its own path>.ran.txt" and exits 0, so the harness can
    # prove which downloaded copy actually ran - and that a hash-refused copy never did.
    $remExe = Join-Path $sandbox 'marlin-remover.exe'
    Add-Type -OutputAssembly $remExe -OutputType ConsoleApplication -TypeDefinition @'
using System.IO;
using System.Reflection;
class R {
    static int Main() {
        File.WriteAllText(Assembly.GetEntryAssembly().Location + ".ran.txt", "ok");
        return 0;
    }
}
'@
    $remSha  = (Get-FileHash -LiteralPath $remExe -Algorithm SHA256).Hash
    $remExe2 = Join-Path $sandbox 'marlin-remover2.exe'
    Copy-Item -LiteralPath $remExe -Destination $remExe2 -Force
    # paths section 3 will create; the catalog needs them as strings now
    $marlinUn  = Join-Path $installRoot 'Uninstall\Marlin Tool\uninstall.cmd'
    $marlinExe = Join-Path $installRoot 'Marlin Tool\marlin.exe'

    # Dependency fixtures for section 4: gui-dep "plugs into" gui-a. Its installed state is a
    # marker exe its fixture uninstaller removes; the uninstaller also writes a proof file so
    # the harness can tell "ran and succeeded" from "never ran".
    $depDir   = Join-Path $installRoot 'DepAddon'
    $depExe   = Join-Path $depDir 'dep.exe'
    $depUnDir = Join-Path $installRoot 'Uninstall\DepAddon'
    $depUn    = Join-Path $depUnDir 'uninstall.cmd'
    $depUnRan = Join-Path $sandbox 'dep-un-ran.txt'
    New-Item -ItemType Directory -Force -Path $depUnDir | Out-Null
    Set-Content -LiteralPath $depUn -Encoding ASCII -Value (@(
        '@echo off',
        "echo ran > `"$depUnRan`"",
        "rd /s /q `"$depDir`"",
        "exit ${sl}b 0") -join "`r`n")
    # gui-dep gets its OWN package and its OWN verify path. The first cut reused gui-a's
    # app.exe as the verify target, and the moment section 1 installed anything the add-on
    # read as "installed" - every later sheet then detected a phantom orphan and quietly
    # bolted a remove->reinstall sequence onto batches that had nothing to do with it. The
    # app behaved exactly as designed; the catalog it was fed was lying.
    $depPkgSrc = Join-Path $sandbox 'dep-src\inner'
    New-Item -ItemType Directory -Force -Path $depPkgSrc | Out-Null
    Set-Content -LiteralPath "$depPkgSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off',
        "mkdir `"$depDir`" 2>nul",
        "echo dep > `"$depExe`"",
        "exit ${sl}b 0") -join "`r`n")
    $depZip = Join-Path $sandbox 'dep-package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $depPkgSrc -Parent), $depZip)
    $depSha  = (Get-FileHash -LiteralPath $depZip -Algorithm SHA256).Hash
    $depSize = (Get-Item -LiteralPath $depZip).Length

    $server = Join-Path $sandbox 'server'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    $catalog = [pscustomobject]@{
        updated = (Get-Date -Format 'yyyy-MM-dd')
        apps = @(
            [pscustomobject]@{ id = 'gui-a'; name = 'Gui App A'; category = 'Apps'
                url = 'https://example.invalid/package.zip'; sha256 = $sha; sizeBytes = $size
                silentArgs = ''; entry = 'inner\setup.cmd'; verifyPaths = @("$appDir\app.exe") }
            [pscustomobject]@{ id = 'gui-b'; name = 'Gui App B'; category = 'Apps'
                url = 'https://example.invalid/package.zip'; sha256 = $sha; sizeBytes = $size
                silentArgs = ''; entry = 'inner\setup.cmd'; verifyPaths = @("$appDir\app.exe") }
            [pscustomobject]@{ id = 'gui-c'; name = 'Gui App C'; category = 'Apps'
                url = 'https://example.invalid/package.zip'; sha256 = $sha; sizeBytes = $size
                silentArgs = ''; entry = 'inner\setup.cmd'; verifyPaths = @("$appDir\app.exe") }
            # the add-on for the dependency section: requires gui-a, and carries the uninstall
            # block the case-4 orchestration resolves its remove-first step from
            [pscustomobject]@{ id = 'gui-dep'; name = 'Gui Dep Addon'; category = 'Apps'
                url = 'https://example.invalid/package.zip'; sha256 = $depSha; sizeBytes = $depSize
                silentArgs = ''; entry = 'inner\setup.cmd'; verifyPaths = @($depExe)
                requires = @('gui-a')
                uninstall = [pscustomobject]@{ command = $depUn; args = ''; detect = $depExe } }
            # uninstall-only: never an Install row, but the Uninstall tab's row upgrade reads
            # it - vendor command, and two removers: one honest, one with a wrong hash
            [pscustomobject]@{ id = 'marlin'; name = 'Marlin Tool'; category = 'Apps'; uninstallOnly = $true
                uninstall = [pscustomobject]@{ command = $marlinUn; args = ''; detect = $marlinExe }
                cleanup = [pscustomobject]@{
                    removers = @(
                        [pscustomobject]@{ name = 'Marlin vendor deep remover'
                            url = ('file:///' + ($remExe -replace '\\', '/')); sha256 = $remSha; args = '' }
                        [pscustomobject]@{ name = 'Tampered remover - must be refused'
                            url = ('file:///' + ($remExe2 -replace '\\', '/')); sha256 = ('0' * 64); args = '' }) } })
    }
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ($catalog | ConvertTo-Json -Depth 8),
                            (New-Object Text.UTF8Encoding $false))
    Assert-True 'a real package and a local catalog exist' ((Test-Path $zip) -and (Test-Path "$server\apps.json"))

    # ================================================================== load the GUI
    Write-Section 'Loading the real GUI (window built, handlers wired, never shown)'

    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker in AppDeploy.ps1.' }
    $head = $src.Substring(0, $goAt)
    $fileUrl = 'file:///' + ($server -replace '\\', '/')
    . ([scriptblock]::Create($head)) -BaseUrl $fileUrl -NoSelfElevate

    # The guard that stops two copies sharing one queue. This process now holds it, so a second
    # one must be refused - which is the whole point, since two workers on one queue take each
    # other's items and hang the batch.
    Assert-True 'this instance holds the single-instance lock' $script:HaveMutex
    $probe = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -NoProfile -ExecutionPolicy Bypass -Command `
                "`$m = New-Object Threading.Mutex(`$false,'Local\PC2GoAppInstaller'); try { if (`$m.WaitOne(0)) { 'GOT' } else { 'REFUSED' } } catch [Threading.AbandonedMutexException] { 'GOT' }"
    Assert-Equal 'a second instance is refused the lock' 'REFUSED' ("$probe").Trim()

    Assert-True 'the window was built'          ($null -ne $window)
    Assert-True 'the Install button exists'     ($null -ne $BtnInstall)
    Assert-True 'the Uninstall button exists'   ($null -ne $BtnUninstall)
    # $script:Elevated reports the token this process was GIVEN. Launched from an elevated
    # shell it is true by inheritance, which is not the tool elevating itself - so the claim
    # is only checkable when the harness itself started unelevated.
    $harnessElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($harnessElevated) {
        Assert-True 'and it inherited the elevated token it was launched with' ([bool]$script:Elevated)
    } else {
        Assert-True 'and it did not elevate itself' (-not $script:Elevated)
    }

    # Resolve-OdisManifest is a pure lookup; prove it against a fixture tree. The per-product
    # manifest is minted at install time, so the catalog carries a token and this resolves it.
    $odisRoot = Join-Path $sandbox 'odis'
    foreach ($p in @{ A = 'Gui App A'; B = 'Gui App B' }.GetEnumerator()) {
        $d = Join-Path $odisRoot $p.Key
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'pkg.setup.xml') -Encoding ASCII `
                    -Value "<setup><name>$($p.Value)</name></setup>"
    }
    Assert-True  'ODIS manifest resolution picks the right product' `
                 ((Resolve-OdisManifest 'Gui App B' $odisRoot) -like '*\B\pkg.setup.xml')
    Assert-Equal 'and returns empty for a product with no manifest' '' (Resolve-OdisManifest 'Nope' $odisRoot)

    # The only stub. Same worker script, same queue, same status file - just launched without
    # the UAC prompt an unattended run cannot answer.
    function Start-Worker {
        if ($script:WorkerStarted) { return $true }
        Set-Content -Path $script:WorkerPath -Value ($workerScript.Replace('#__PREFTABLE__', $script:PrefTableSource)) -Encoding UTF8
        Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
        $script:StatusOffset = 0
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" " +
                  "-QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`" " +
                  "-SkipFile `"$script:SkipPath`""
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList $psArgs | Out-Null
        $script:WorkerStarted = $true
        Add-Log 'Worker started (test harness: no elevation prompt).'
        return $true
    }

    # Move the whole session cache into the sandbox. Two reasons, both learned the hard way:
    # this machine's real PC2GoDeploy folder is no longer touched at all, and - more subtly -
    # two runs can no longer share a queue file. A run that ends with the worker unreleased
    # leaves it polling that queue forever, and the next run's items are then consumed by BOTH
    # workers, which collide on the same install and fail it with exit code 1.
    $script:CacheDir      = Join-Path $sandbox 'cache'
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath     = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath    = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath    = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath    = Join-Path $script:CacheDir 'cancel.flag'
    $script:SkipPath      = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'

    # $timer is the batch pump - it drives the download loop AND reads the worker's status
    # file. It is created in the body but STARTED in the "go" section, which is past the cut,
    # so without this nothing a batch does ever advances.
    $timer.Start()

    Load-Catalog
    Assert-Equal 'the local catalog loaded four apps' 4 $script:Items.Count
    Assert-Equal 'and the first row is named'          'Gui App A' $script:Items[0].Name

    # ================================================================== 1. install
    Write-Section '1. Install tab: tick two rows and press Install'

    # Stage the package where the pump will actually look for it: one copy per app id.
    #
    # This used to drop a single package.zip in the cache ROOT and let all three rows find it,
    # which only worked because the cache was keyed on the FILENAME. That is the same bug that
    # let nine of the nineteen real applications - every Autodesk and Adobe title, all of them
    # called Setup.exe - resolve to one path and overwrite each other mid-batch. The cache is
    # per-app now, so the fixture has to be too.
    function Set-StagedPackage {
        foreach ($id in 'gui-a', 'gui-b', 'gui-c') {
            $d = Join-Path (Join-Path $script:CacheDir 'files') $id
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Copy-Item -LiteralPath $zip -Destination (Join-Path $d 'package.zip') -Force
        }
    }
    function Test-StagedPackageGone {
        return -not @('gui-a', 'gui-b', 'gui-c' | Where-Object {
            Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:CacheDir 'files') $_) 'package.zip') }).Count
    }
    # the package is already in the cache at the right size, so the download loop takes its
    # "already fully present" branch - the same one that spares a 14 GB re-download
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    Set-StagedPackage

    # five entries in the manifest, four rows on the Install tab: the uninstall-only entry
    # must never offer itself for installation - it has no url and no hash
    Assert-Equal 'the uninstall-only entry never became an Install row' 4 @($script:Items).Count

    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    Assert-Equal 'two rows are ticked' 2 @($script:Items | Where-Object { $_.IsSelected }).Count

    # ---- pre-flight: the screen between picking and committing.
    #
    # Nothing used to stand here. Install Selected started downloading on the press, with no list
    # and - the expensive part - no check that the picked size would fit on the disk it lands on.
    Invoke-Click $BtnInstall
    Assert-Equal 'pressing Install opens the sheet, not a download' 'Visible' "$($PreflightOverlay.Visibility)"
    Assert-Equal 'and nothing has started'                          $false ($script:Phase -eq 'Download')
    Assert-Equal 'it lists exactly what was ticked'                 2 @($ListPf.ItemsSource).Count
    Assert-Equal 'the title counts them'                            'Install 2 applications' $TxtPfTitle.Text
    Assert-Equal 'and so does the button'                           'Install 2' "$($BtnPfGo.Content)"
    Assert-True  'the disk is reported'                             ($TxtPfDiskFacts.Text -match 'free')

    # taking one out has to untick it as well, or the next press puts it straight back
    $drop = @($ListPf.ItemsSource)[1].Item
    $script:PfItems = @(@($script:PfItems) | Where-Object { $_ -ne $drop })
    $drop.IsSelected = $false
    Sync-Preflight
    Assert-Equal 'taking a row out leaves one'      1 @($ListPf.ItemsSource).Count
    Assert-Equal 'and unticks it in the catalog'    1 @($script:Items | Where-Object { $_.IsSelected }).Count
    Assert-Equal 'the button follows the count'     'Install 1' "$($BtnPfGo.Content)"

    # Cancel must start nothing at all
    Invoke-Click $BtnPfCancel
    Assert-Equal 'Cancel shuts the sheet'    'Collapsed' "$($PreflightOverlay.Visibility)"
    Assert-Equal 'and started nothing'       $false ($script:Phase -eq 'Download')

    # a size bigger than the disk is called out rather than discovered mid-download
    $free = (Get-DiskFacts $script:CacheDir).Free
    $huge = [pscustomobject]@{ Name = 'Too Big'; SizeBytes = ([long]$free + 50GB)
                               IconText = 'TB'; IconBg = '#FFC7373C'; IsSelected = $true }
    Show-Preflight @($huge) 'install'
    Assert-True 'a selection larger than the disk says so' ($TxtPfDiskNote.Text -match 'will not fit')
    Assert-True 'and says how much short'                  ($TxtPfDiskNote.Text -match 'short')
    Assert-Equal 'but the button stays live - a catalogued size can be stale' `
                 $true $BtnPfGo.IsEnabled
    Invoke-Click $BtnPfCancel

    # Get-DiskFacts on a real drive. [Math]::Max(1, $total) shipped here for an hour and threw on
    # this machine: the literal 1 is an Int32, so a 1 TB drive overflowed the Max(int,int) overload.
    $facts = Get-DiskFacts $script:CacheDir
    Assert-True 'the drive is readable'        ($null -ne $facts)
    Assert-True 'it reports a positive total'  ($facts.Total -gt 0)
    Assert-True 'and free is not above total'  ($facts.Free -le $facts.Total)

    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    Invoke-Commit $BtnInstall
    Assert-Equal 'the batch started downloading'   'Download' $script:Phase
    Assert-Equal 'and Install became Add to Batch' 'Add to Batch' $TxtInstallBtn.Text
    Assert-Equal 'Cancel is offered'               'Visible' "$($BtnCancel.Visibility)"

    # ---- add a third app while the batch is live: no second worker, no second UAC
    $script:Items[2].IsSelected = $true
    Invoke-Commit $BtnInstall
    Assert-Equal 'Add to Batch extended the running batch' 3 $script:Pending.Count
    Assert-True  'and the strip picked the new row up on its own' `
                 (Wait-For { $script:BatchRows.Count -eq 3 } 5000)
    Assert-Equal 'the third row says Queued'               'Queued' $script:Items[2].Status

    $done = Wait-For { $script:Phase -in 'Done', 'Idle' } 180000
    if (-not $done) {
        # a stalled batch says nothing useful on its own - show where it stopped
        Write-Host ("  STALLED: phase={0} dlIndex={1}/{2} workerStarted={3} endQueued={4}" -f `
                    $script:Phase, $script:DlIndex, $script:Pending.Count,
                    $script:WorkerStarted, $script:EndQueued) -ForegroundColor Yellow
        foreach ($it in $script:Items) { Write-Host ("    {0,-12} {1}" -f $it.Name, $it.Status) -ForegroundColor Yellow }
        foreach ($l in @(Get-Content -LiteralPath $script:StatusPath -ErrorAction SilentlyContinue | Select-Object -Last 8)) {
            Write-Host "    worker> $l" -ForegroundColor DarkYellow
        }
    }
    Assert-True 'the batch finished' $done
    foreach ($i in 0..2) {
        Assert-True ("row {0} reports Installed" -f ($i + 1)) ($script:Items[$i].Status -like 'Installed*')
    }
    Assert-True 'the product is really on disk' (Test-Path -LiteralPath "$appDir\app.exe")
    Assert-True 'no failures were recorded'     (-not $script:HadFailures)
    Assert-True 'the cached installer was cleaned up' (Test-StagedPackageGone)

    # ---- the same app a second time. The sheet used to let a product that was plainly on the
    # machine straight back through its installer. Now it is named, skipped, and only a tick
    # sends it - the decision is the technician's, and it is explicit.
    Write-Section '1a. Already installed: skipped unless you say so'
    Show-Preflight @($script:Items[0]) 'install'
    Assert-Equal 'the sheet opened'                   'Visible' "$($PreflightOverlay.Visibility)"
    Assert-Equal 'the already-installed panel shows'  'Visible' "$($PfHave.Visibility)"
    Assert-True  'and names the app'                  ($TxtPfHaveNote.Text -like "*$($script:Items[0].Name)*")
    Assert-Equal 'the row is tagged'                  'installed - skipped' ([string]@($ListPf.ItemsSource)[0].HaveText)
    Assert-Equal 'the reinstall box starts unticked'  $false ([bool]$ChkPfHave.IsChecked)
    Assert-Equal 'the button counts nothing to run'   'Install 0' "$($BtnPfGo.Content)"
    Assert-Equal 'and is disabled'                    $false $BtnPfGo.IsEnabled
    Assert-Equal 'nothing would be committed'         0 @(Get-PfCommitItems).Count
    $ChkPfHave.IsChecked = $true
    Assert-Equal 'ticking it puts the app back'       1 @(Get-PfCommitItems).Count
    Assert-Equal 'the button follows'                 'Install 1' "$($BtnPfGo.Content)"
    Assert-Equal 'and is live again'                  $true $BtnPfGo.IsEnabled
    Assert-Equal 'the row now says reinstall'         'reinstall' ([string]@($ListPf.ItemsSource)[0].HaveText)
    Invoke-Click $BtnPfCancel
    Assert-Equal 'cancel clears the choice'           $false $script:PfReinstall
    # a not-installed app shows no panel at all
    Show-Preflight @($script:Items[3]) 'install'
    Assert-Equal 'no panel for an app that is not here' 'Collapsed' "$($PfHave.Visibility)"
    Invoke-Click $BtnPfCancel

    # ---- the run record: what a finished batch leaves behind for somebody to read.
    #
    # It left nothing before. Per-app outcomes lived in $script:BatchRows and were cleared by the
    # next batch; the only trace was the log, which after twenty apps is a wall of text.
    Write-Section '1b. The finished batch wrote itself down'

    # in the SANDBOX, not the real profile. Get-RunsDir derives from $script:CacheDir when asked
    # rather than at load time, precisely so a harness redirect is honoured - a cached path would
    # have put test records in a real technician's %LOCALAPPDATA%.
    Assert-Equal 'the record went to the sandbox cache' `
                 (Join-Path $script:CacheDir 'runs') (Get-RunsDir)

    $runs = @(Get-RunFiles)
    Assert-True  'a run record was written'   ($runs.Count -ge 1)
    $rec = Read-RunRecord $runs[0].FullName
    Assert-True  'and it reads back as JSON'  ($null -ne $rec)
    Assert-Equal 'it knows what kind of run it was' 'Install' ([string]$rec.kind)
    Assert-Equal 'it counted every item'      3 ([int]$rec.counts.total)
    Assert-Equal 'all three succeeded'        3 ([int]$rec.counts.ok)
    Assert-Equal 'and none failed'            0 ([int]$rec.counts.failed)
    Assert-True  'it took a positive number of seconds' ([int]$rec.seconds -ge 0)
    Assert-True  'every item carries its id'  (@($rec.items | Where-Object { $_.id }).Count -eq 3)

    # BOM-free, because it is read back with ConvertFrom-Json, which chokes on one
    $head = [byte[]](Get-Content -LiteralPath $runs[0].FullName -Encoding Byte -TotalCount 3)
    Assert-True 'the record has no byte-order mark' `
                (-not ($head.Count -eq 3 -and $head[0] -eq 239 -and $head[1] -eq 187 -and $head[2] -eq 191))

    # the outcome vocabulary is derived from the status text, in ONE place, so the summary and
    # the list under it can never disagree
    Assert-Equal 'Installed reads as ok'      'ok'        (Get-RunOutcome 'Installed')
    Assert-Equal 'Uninstalled reads as ok'    'ok'        (Get-RunOutcome 'Uninstalled')
    Assert-Equal 'Failed reads as failed'     'failed'    (Get-RunOutcome 'Failed: installer returned 1603')
    Assert-Equal 'Skipped is a warning, not a failure' 'warned' (Get-RunOutcome 'Skipped - already installed')
    Assert-Equal 'Removed is its own thing'   'removed'   (Get-RunOutcome 'Removed from batch')
    Assert-Equal 'Cancelled is its own thing' 'cancelled' (Get-RunOutcome 'Cancelled')

    # ---- and the Activity tab shows it, without opening itself
    Select-Tab 'Log'
    Assert-True  'the runs list has the live log plus the run' (@($ListRuns.ItemsSource).Count -ge 2)
    Assert-Equal 'the live log is first'  'Live log' ([string]@($ListRuns.ItemsSource)[0].Head)
    Assert-Equal 'and it is what shows until a run is picked' 'Collapsed' "$($RunReport.Visibility)"

    $ListRuns.SelectedIndex = 1
    Assert-Equal 'picking a run shows the report' 'Visible'   "$($RunReport.Visibility)"
    Assert-Equal 'and hides the raw log'          'Collapsed' "$($TxtLog.Visibility)"
    Assert-Equal 'the report is titled by kind'   'Install run finished' $TxtRunTitle.Text
    Assert-Equal 'it lists every item'            3 @($ListRunItems.ItemsSource).Count
    Assert-Equal 'nothing failed, so no retry'    'Collapsed' "$($BtnRunRetry.Visibility)"
    Assert-True  'the report can be copied as text' ((Get-RunReportText) -match 'Installed')

    # a run with failures: they sort to the top, the count filters, and retry appears
    $script:RunStarted = (Get-Date).AddMinutes(-3)
    Write-RunRecord @(
        [pscustomobject]@{ Id = 'gui-a'; Name = 'Gui App A'; SizeBytes = 1MB; Status = 'Failed: installer returned 1603' },
        [pscustomobject]@{ Id = 'gui-b'; Name = 'Gui App B'; SizeBytes = 2MB; Status = 'Installed' }) 'Install'
    Sync-RunList
    $ListRuns.SelectedIndex = 1
    Assert-Equal 'the failure sorts to the top' 'Gui App A' ([string]@($ListRunItems.ItemsSource)[0].Name)
    Assert-Equal 'and carries its reason'       'Failed: installer returned 1603' `
                 ([string]@($ListRunItems.ItemsSource)[0].Detail)
    Assert-Equal 'retry is offered'             'Visible' "$($BtnRunRetry.Visibility)"
    Assert-Equal 'and says how many'            'Retry 1 failed' "$($BtnRunRetry.Content)"

    $script:RunFilter = 'failed'; Sync-RunReport
    Assert-Equal 'the counts filter the list' 1 @($ListRunItems.ItemsSource).Count
    $script:RunFilter = 'all'; Sync-RunReport
    Assert-Equal 'and back to everything'     2 @($ListRunItems.ItemsSource).Count

    # the tab badge is the whole of "it waits until you look" - no window opens by itself
    Set-ActivityBadge 2
    Assert-True  'a failed run badges the tab'  ($BtnTabLog.Content -isnot [string])
    Set-ActivityBadge 0
    Assert-Equal 'and looking clears it'        'Activity' ([string]$BtnTabLog.Content)


    # ---- uninstall: the list has to answer what it is opened for.
    #
    # Eighty programs in one alphabetical column. Nobody comes here looking for things beginning
    # with A - they come to find what is BIG and what is JUNK, and both were already on the row
    # without being sortable by either.
    Write-Section '1c. Uninstall sorts and filters'

    $now = Get-Date
    # REAL AppItem rows, not hand-made PSCustomObjects. Building fakes here is what let a sort
    # on a property the real row does not have pass this test and do nothing on a live machine.
    $mk = { param($n, $pub, $kb, $when)
        $u = New-Object AppItem
        $u.Name = $n; $u.Publisher = $pub; $u.Version = '1.0'
        $u.SizeBytes = [long]$kb * 1KB; $u.Installed = $when
        $u.Category = 'Desktop programs  (Control Panel)'; $u.IsSelected = $false
        $u.Status = ''; $u.StatusFg = '#FF9A9AA6'
        $u.SpinnerVis = 'Collapsed'; $u.BadgeVis = 'Collapsed'
        $u.BadgeBg = '#FF34D399'; $u.BadgeData = 'M 0,0'
        $u }
    $script:UnItems.Clear()
    foreach ($r in @(
        (& $mk 'Huge Repack'   'Nobody'      42900000 $now.AddDays(-200)),
        (& $mk 'Design Suite'  'Adobe Inc.'   4090000 $now.AddDays(-20)),
        (& $mk 'Old Helper'    'Some GmbH'       2000 $now.AddDays(-400)),
        (& $mk 'Mystery Bar'   ''               15000 $now.AddDays(-5)),
        (& $mk 'No Date Here'  'Apple Inc.'      2000 $null))) { $script:UnItems.Add($r) }

    Sync-UnCells
    Set-UnSort 'size'
    Assert-Equal 'sorted by size, the biggest is first' 'Huge Repack' ([string]@($script:UnView)[0].Name)
    Assert-Equal 'pressing the same column again turns it round' `
                 'No Date Here' ([string]@($(Set-UnSort 'size'; $script:UnView))[0].Name)
    Set-UnSort 'size'

    Set-UnSort 'date'
    Assert-Equal 'sorted by date, the newest is first'  'Mystery Bar' ([string]@($script:UnView)[0].Name)
    Assert-Equal 'and a program with no date sorts last, not first' `
                 'No Date Here' ([string]@($script:UnView)[@($script:UnView).Count - 1].Name)

    Set-UnSort 'name'; Update-UnViews
    Assert-Equal 'every program is listed' 5 @($script:UnView).Count
    Assert-Equal 'and Name sorting is alphabetical' 'Design Suite' ([string]@($script:UnView)[0].Name)
    Assert-True  'the sorted column is the lit heading' `
                 ($BtnColName.Style -eq $window.FindResource('ColHeadOn'))
    Assert-True  'and it shows which way it is sorted' ($BtnColName.Content -match '\^|v')

    # the table's own cells, which are what the row actually draws
    $biggest = @($script:UnItems | Sort-Object SizeBytes -Descending)[0]
    Assert-Equal 'the biggest row is tagged'   'largest' ([string]$biggest.TagText)
    Assert-Equal 'and the tag is shown'        'Visible' ([string]$biggest.TagVis)
    Assert-Equal 'its bar is full'             100 ([int]$biggest.SizePercent)
    $none = @($script:UnItems | Where-Object { $_.Name -eq 'No Date Here' })[0]
    Assert-Equal 'a program with no date reads as a dash' '-' ([string]$none.ColInstalled)
    $unsized = @($script:UnItems | Where-Object { [long]$_.SizeBytes -eq 0 })
    foreach ($u in $unsized) {
        Assert-Equal 'an unsized row says so'  'no size' ([string]$u.ColSize)
        Assert-True  'and is dimmed, not hidden' ($u.RowOpacity -lt 1.0)
    }

    # bindable, or the row draws empty cells no matter what is assigned
    $probe = New-Object AppItem
    foreach ($prop in 'SizeBytes','Installed','ColSize','ColInstalled','SizePercent','TagText','TagVis','RowOpacity') {
        $m = [AppItem].GetProperty($prop)
        Assert-True "$prop is a property, not a field" ($null -ne $m)
    }

    # the app's own icon is back in the row - the table mock had no icon column, the tool has
    # had real logos here all along, and they are worth more than the 34px they cost
    Assert-True 'the row still carries the program icon' `
                ($src -match '(?s)Style x:Key="UnRow".{0,4000}Binding IconImage')

    # the row the list actually binds is an AppItem, so the fields have to exist THERE
    $probe = New-Object AppItem
    Assert-True 'AppItem carries an install date'      ($null -ne $probe.PSObject.Properties['Installed'])
    Assert-True 'and it is null until something sets it' ($null -eq $probe.Installed)
    $probe.Installed = (Get-Date).AddDays(-2)
    Assert-True 'and it holds one when set'            ($null -ne $probe.Installed)
    Assert-True 'the uninstall scan reports a size in KB' `
                ($null -ne (New-Object AppItem).PSObject.Properties['SizeBytes'])
    $script:UnItems.Clear()

    Select-Tab 'Install' 

    Assert-Equal 'the strip is still on screen after the batch ended' `
                 'Visible' "$($BatchStrip.Visibility)"
    Assert-True  'and its header counts what happened' ($TxtBatchHead.Text -like 'BATCH*3 of 3 done*')

    # ================================================================== 1b. the batch strip
    Write-Section '1b. Batch strip: the boundary, and pulling an app out of a live batch'

    # ---- the boundary, stated as a table.
    #
    # Test-Removable is what the remove button reads for its visibility AND what
    # Remove-FromBatch reads before refusing, so it is checked directly rather than inferred
    # from what happens to be on screen. The line is the moment the installer launches:
    # before it anything can be pulled out, after it a stop leaves a half-install.
    #
    # Nothing can tick while this runs - it is all on the dispatcher thread and never pumps.
    $probe     = $script:Items[0]
    $wasStatus = $probe.Status
    $script:BatchLive = $true
    foreach ($case in @(
        @{ st = '';                   can = $true  },   # not started
        @{ st = 'Queued';             can = $true  },
        @{ st = 'Downloading 42%';    can = $true  },
        @{ st = 'Queued for install'; can = $true  },   # downloaded, worker has not reached it
        @{ st = 'Verifying file';     can = $false },   # the worker has picked this one up
        @{ st = 'Installing';         can = $false },   # the line
        @{ st = 'Installed';          can = $false },
        @{ st = 'Failed: no disk';    can = $false })) {
        $probe.Status = $case.st
        Assert-Equal ("removable while '{0}'" -f $(if ($case.st) { $case.st } else { '(nothing yet)' })) `
                     $case.can (Test-Removable $probe)
    }
    $script:BatchLive = $false
    $probe.Status = 'Queued'
    Assert-Equal 'and nothing is removable once the batch is over' $false (Test-Removable $probe)

    # ---- what a press is allowed to CLAIM.
    #
    # A row this GUI still owns can be settled on the spot. A row already written into
    # queue.jsonl cannot: the elevated worker decides, it reads skip.txt only just before it
    # acts on an entry, and if it had already started this one the skip is never seen. Saying
    # 'Removed' there would assert an outcome that can be false a few hundred ms later, on the
    # one screen a technician trusts. The press is acknowledged; the outcome waits.
    $script:Pending = @($probe)
    Show-BatchStrip
    Set-Status $probe 'Queued' 'neutral'
    Remove-FromBatch $probe
    Assert-True 'a row the GUI still owns is removed outright' ($probe.Status -like 'Removed from batch*')

    Set-Status $probe 'Queued for install' 'ready'
    Remove-FromBatch $probe
    Assert-True 'a row already handed to the worker says only that removal was REQUESTED' `
                ($probe.Status -like 'Removing*')
    Assert-True 'and it does NOT claim to be removed yet' ($probe.Status -notlike 'Removed *')
    Sync-BatchStrip
    Assert-Equal 'the press is acknowledged by taking the button away' 'Collapsed' $probe.RemoveVis
    Assert-True  'a pending removal still counts as outstanding, not done' `
                 ($TxtBatchHead.Text -like '*0 of 1 done*')
    $script:BatchLive = $false
    $script:Pending = @()
    $probe.Status = $wasStatus

    # ---- pull a queued app out of a batch that is already running
    Set-StagedPackage
    foreach ($it in $script:Items) { $it.IsSelected = $false }
    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    $script:Items[2].IsSelected = $true
    Invoke-Commit $BtnInstall

    Assert-Equal 'the strip appeared with the batch'          'Visible' "$($BatchStrip.Visibility)"
    Assert-Equal 'holding one row per app'                    3 $script:BatchRows.Count
    Assert-True  'the strip rows ARE the catalog rows'        ($script:BatchRows[0] -eq $script:Items[0])
    # the catalog is a CollectionView, so it is enumerated rather than indexed
    Assert-True  'and the catalog above did not reorder'      (@($script:View)[0] -eq $script:Items[0])

    $victim = $script:Items[2]
    Assert-Equal 'the app about to be pulled is still queued' 'Queued' $victim.Status

    # The row says on its own that it can still be pulled out - that binding is what puts the
    # button on screen.
    Assert-Equal 'the queued row offers a remove button' 'Visible' $victim.RemoveVis

    # Press it through the REAL handler rather than calling Remove-FromBatch. The window is
    # never shown here, so the DataTemplate has never produced a container and there is no
    # button object to find. What the handler actually depends on is a Click bubbling up to
    # ListBatch carrying the row in Tag, and that is exactly what this raises.
    $fake = New-Object Windows.Controls.Button
    $fake.Tag = $victim
    $ListBatch.RaiseEvent((New-Object Windows.RoutedEventArgs(
        [Windows.Controls.Primitives.ButtonBase]::ClickEvent, $fake)))

    Assert-True  'the pulled row reports Removed'          ($victim.Status -like 'Removed*')
    Assert-True  'its id was written to the skip file'     `
                 (@(Get-Content -LiteralPath $script:SkipPath -ErrorAction SilentlyContinue) -contains $victim.Id)
    # it stays on screen saying what happened to it, rather than silently disappearing
    Assert-Equal 'and it stays in the strip'               3 $script:BatchRows.Count

    Assert-True 'the batch still ran to completion' (Wait-For { $script:Phase -in 'Done', 'Idle' } 180000)
    Assert-True 'the two apps that were kept installed' `
                (($script:Items[0].Status -like 'Installed*') -and ($script:Items[1].Status -like 'Installed*'))
    # the proof it was really pulled out: the elevated worker was never given it to do
    Assert-True 'the removed app never reached the worker queue' `
                (-not @(@(Get-Content -LiteralPath $script:QueuePath -ErrorAction SilentlyContinue) -match
                        ('"id":"' + [regex]::Escape($victim.Id) + '"')).Count)
    Assert-True 'a removal is not reported as a failure'   ($victim.Status -notlike 'Failed*')
    Assert-True 'and it sorts above the rows that worked'  ($script:BatchRows[0] -eq $victim)

    # ================================================================== 2. cancel
    Write-Section '2. Install tab: Cancel stops what has not started'

    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    Set-StagedPackage
    foreach ($it in $script:Items) { $it.IsSelected = $false }
    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    $script:Items[2].IsSelected = $true
    Invoke-Commit $BtnInstall
    # cancel only once something is genuinely mid-install, or there is nothing to promise about
    $running = Wait-For { @($script:Items | Where-Object { $_.Status -like 'Installing*' -or $_.Status -like 'Verifying*' }).Count -ge 1 } 90000
    Assert-True 'an install is under way before cancelling' $running
    $inFlight = @($script:Items | Where-Object { $_.Status -like 'Installing*' -or $_.Status -like 'Verifying*' }) | Select-Object -First 1

    Invoke-Click $BtnCancel
    Assert-True 'the batch came to a stop' (Wait-For { $script:Phase -in 'Done', 'Idle' } 180000)
    Assert-True 'rows that had not started report Cancelled' `
                (@($script:Items | Where-Object { $_.Status -like 'Cancelled*' }).Count -ge 1)
    # the promise the README makes: killing a running installer corrupts the install, so it is
    # allowed to finish even though everything behind it is dropped
    Assert-True 'the install already running was NOT killed' `
                ($inFlight.Status -like 'Installed*' -or $inFlight.Status -like 'Skipped*')
    # No transfer may outlive a cancel. The segmented download throws when it is stopped, and
    # the pump's catch used to read that as 'this transport did not work' and start a BITS job
    # instead - for an app the cancel had already written off, at a point where DlIndex is past
    # the end and the Download branch is never entered again to clean it up.
    Assert-True 'no download job outlived the cancel' ($null -eq $script:CurJob)

    # ================================================================== 3. uninstall tab
    Write-Section '3. Uninstall tab: a real product, ticked and removed'

    $dirU = Join-Path $installRoot 'Marlin Tool'
    New-Item -ItemType Directory -Force -Path $dirU | Out-Null
    Set-Content -LiteralPath "$dirU\marlin.exe" -Value 'binary' -Encoding ASCII
    $unDirU = Join-Path $installRoot 'Uninstall\Marlin Tool'
    New-Item -ItemType Directory -Force -Path $unDirU | Out-Null
    $unU = Join-Path $unDirU 'uninstall.cmd'
    Set-Content -LiteralPath $unU -Encoding ASCII -Value (@(
        '@echo off',
        "reg delete `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoGui-$tag`" /f >nul 2>&1",
        'timeout /t 1 /nobreak >nul',
        "rd /s /q `"$dirU`"",
        'exit /b 0') -join "`r`n")
    New-Item -Path $keyU -Force | Out-Null
    Set-ItemProperty -Path $keyU -Name 'DisplayName'     -Value 'Marlin Tool'
    Set-ItemProperty -Path $keyU -Name 'DisplayVersion'  -Value '5.5'
    Set-ItemProperty -Path $keyU -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $keyU -Name 'InstallLocation' -Value $dirU
    Set-ItemProperty -Path $keyU -Name 'UninstallString' -Value "`"$unU`""

    Select-UnTab 'Desktop'
    Assert-True 'the desktop scan found programs' ($script:UnItems.Count -gt 0)
    $marlin = @($script:UnItems | Where-Object { $_.Name -eq 'Marlin Tool' }) | Select-Object -First 1
    Assert-True 'including the one just installed' ($null -ne $marlin)

    # tick ONLY ours - everything else on this machine stays untouched
    foreach ($u in $script:UnItems) { $u.IsSelected = $false }
    $marlin.IsSelected = $true
    Assert-Equal 'exactly one row is ticked' 1 @($script:UnItems | Where-Object { $_.IsSelected }).Count

    # the catalog match upgraded this registry row: vendor command, and the removers rode along
    Assert-Equal 'the row upgraded to the vendor uninstaller' 'Vendor uninstaller' $marlin.Source
    Assert-Equal 'and carries both catalog removers'          2 @($marlin.Removers).Count

    # the record this batch writes must be timed from ITS start, not the install batch's - the
    # harness moved that clock three minutes back above, and Start-Uninstall used to inherit it
    $script:RunStarted = (Get-Date).AddMinutes(-3)
    Invoke-Commit $BtnUninstall
    # While a removal batch runs, this very list holds the rows the worker reports into, so the
    # Store pill must refuse - and refuse BEFORE lighting up, or it lit over a Desktop list.
    Assert-Equal 'the removal batch is running' 'Install' $script:Phase
    Select-UnTab 'Store'
    Assert-Equal 'switching sub-tab mid-removal is refused'    'Desktop' $script:UnSubTab
    Assert-True  'and the Store pill did not light up'         ($BtnSubStore.Style -ne $window.FindResource('TabActive'))
    Assert-True  'the Desktop pill is still the lit one'       ($BtnSubDesktop.Style -eq $window.FindResource('TabActive'))
    # wait on the ROW, not on Phase - Phase is still 'Done' from the previous batch at the
    # instant of the click, so a phase check passes immediately and proves nothing
    $unDone = Wait-For { $marlin.Status -like 'Uninstalled*' -or $marlin.Status -like 'Failed*' -or
                         "$($WipeOverlay.Visibility)" -eq 'Visible' } 180000
    Assert-True 'the uninstall batch progressed'      $unDone
    Assert-True 'the uninstall row reads Uninstalled' ($marlin.Status -like 'Uninstalled*')
    Assert-True 'the uninstall entry is gone'         (-not (Test-Path -LiteralPath $keyU))

    # The leftover scan runs off-thread now, so 'Uninstalled' on the row no longer means the
    # scan has finished - wait for its verdict (the preview, or a batch that ended finding
    # nothing) before reading anything the scan's completion writes.
    Assert-True 'the leftover scan settled' `
                (Wait-For { "$($WipeOverlay.Visibility)" -eq 'Visible' -or $script:Phase -in 'Done', 'Idle' } 120000)

    # ---- the leftover preview, and the wipe. The install folder surviving the uninstaller is
    # normal - that is exactly what deep clean is for - so it is checked AFTER the approval,
    # not before it.
    # the removers guarantee findings, so the preview is no longer a maybe
    Assert-Equal 'the leftover preview appears' 'Visible' "$($WipeOverlay.Visibility)"
    Write-Host ("  preview lists {0} finding(s), {1} pre-ticked" -f `
                $script:WipeFindings.Count,
                @($script:WipeFindings | Where-Object { $_.Del }).Count) -ForegroundColor DarkGray
    $rrows = @($script:WipeFindings | Where-Object { $_.Type -eq 'run' })
    Assert-Equal 'both catalog removers are offered'  2 $rrows.Count
    Assert-Equal 'and neither arrives pre-ticked'     0 @($rrows | Where-Object { $_.Del }).Count
    Assert-Equal 'a remover row is labelled REMOVER'  'REMOVER' $rrows[0].Kind
    foreach ($r in $rrows) { $r.Del = $true }
    Invoke-Click $BtnWipeGo
    Assert-True 'the wipe completed' (Wait-For { $script:Phase -in 'Done', 'Idle' } 120000)
    # each remover writes "<its own downloaded path>.ran.txt" - so the marker file IS the proof
    # of which copy executed, and its absence the proof the tampered one never did
    # The worker now COPIES a fetched remover out of the user-writable cache into Windows\Temp
    # (PC2GoDeploy-<guid>.exe), hashes the copy and runs the copy - so the marker lands beside
    # that copy, not beside the download. One marker there = the verified one ran; a second
    # would mean the tampered one ran too. The old cache-side paths are still accepted so the
    # assertion also holds against a worker that runs removers in place.
    $ranGood = Join-Path (Join-Path $script:CacheDir 'removers') 'marlin-remover.exe.ran.txt'
    $ranBad  = Join-Path (Join-Path $script:CacheDir 'removers') 'marlin-remover2.exe.ran.txt'
    $staged  = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Temp') -Filter 'PC2GoDeploy-*.ran.txt' -ErrorAction SilentlyContinue)
    # An UNELEVATED harness cannot list Windows\Temp at all (Users may create there, not read),
    # so the marker is invisible to it even when it was written. The worker's own activity
    # record says the same thing in words - "finished (exit 0)" after the hash passed, and
    # "failed its integrity check" for the tampered copy - and is readable either way.
    $activity = ''
    try { $activity = Get-Content -LiteralPath (Join-Path $script:CacheDir 'activity.jsonl') -Raw -ErrorAction Stop } catch { }
    $goodRan = ($activity -match 'Marlin vendor deep remover finished \(exit 0\)')
    $badRan  = ($activity -match 'Tampered remover - must be refused finished')
    $badRefused = ($activity -match 'Tampered remover - must be refused[^"]*failed its integrity check')
    Assert-True 'the hash-verified remover actually RAN'          ((Test-Path -LiteralPath $ranGood) -or $staged.Count -ge 1 -or $goodRan)
    Assert-True 'the tampered remover was refused and never ran'  (-not (Test-Path -LiteralPath $ranBad) -and $staged.Count -le 1 -and -not $badRan -and $badRefused)
    foreach ($m in $staged) { Remove-Item -LiteralPath $m.FullName -Force -ErrorAction SilentlyContinue }
    Assert-True 'the program folder is gone once the wipe is approved' (-not (Test-Path -LiteralPath $dirU))

    # ---- Select all / Clear all in the leftover preview. Bulk tick spares the one-by-one
    # clicking, but it must never tick a suite-shared component (breaking sibling products is
    # the classic support incident) and must never tick a row hidden behind the
    # possible-matches toggle - nothing gets marked for deletion while it is off screen.
    $script:WipeFindings.Clear()
    $wNorm = New-Object WipeItem; $wNorm.OwnerId = 'x'; $wNorm.OwnerName = 'X'; $wNorm.Path = 'C:\t\normal'
    $wShared = New-Object WipeItem; $wShared.OwnerId = 'x'; $wShared.OwnerName = 'X'; $wShared.Path = 'C:\t\shared'; $wShared.Shared = $true
    $wWeak = New-Object WipeItem; $wWeak.OwnerId = 'x'; $wWeak.OwnerName = 'X'; $wWeak.Path = 'C:\t\weak'; $wWeak.Weak = $true
    foreach ($w in $wNorm, $wShared, $wWeak) { $script:WipeFindings.Add($w) }
    $script:WipeShowWeak = $false
    Invoke-Click $BtnWipeAll
    Assert-True 'Select all ticks a normal row'                     $wNorm.Del
    Assert-True 'but never a suite-shared component'                (-not $wShared.Del)
    Assert-True 'and never a hidden possible match'                 (-not $wWeak.Del)
    $script:WipeShowWeak = $true
    Invoke-Click $BtnWipeAll
    Assert-True 'a possible match on screen is ticked by Select all' $wWeak.Del
    Invoke-Click $BtnWipeNone
    Assert-Equal 'Clear all unticks everything' 0 @($script:WipeFindings | Where-Object { $_.Del }).Count
    $script:WipeFindings.Clear()
    $script:WipeShowWeak = $false

    # the Uninstall record: its own kind, and timed from its own start (see the clock moved back
    # above). Written by Finish-Batch, so the batch has to be fully over before it is read.
    Assert-True 'the removal batch finished' (Wait-For { $script:Phase -in 'Done', 'Idle' } 120000)
    $unRec = @(Get-ChildItem -LiteralPath (Get-RunsDir) -Filter 'run-*.json' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1 |
               ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })[0]
    Assert-True  'the removal batch wrote a run record'   ($null -ne $unRec)
    Assert-Equal 'filed as an Uninstall'                  'Uninstall' "$($unRec.kind)"
    Assert-True  'and timed from its own start, not the previous batch''s' ([int]$unRec.seconds -lt 150)

    # ============================================================ 4. dependencies
    Write-Section '4. Dependencies: the guard, and the orchestrated sequence'

    $dep = @($script:Items | Where-Object { $_.Id -eq 'gui-dep' })[0]
    Assert-True  'the dependent row exists'        ($null -ne $dep)
    Assert-Equal 'and carries its requires id'     'gui-a' ([string]@($dep.Requires)[0])

    # a stalled or misrouted batch says nothing useful on its own - dump its whole state
    function Write-DepStall([string]$Tag) {
        Write-Host ("  [{0}] phase={1} tab={2} pending={3}" -f $Tag, $script:Phase, $script:BatchTab,
                    @($script:Pending).Count) -ForegroundColor Yellow
        foreach ($p in @($script:Pending)) {
            Write-Host ("    {0,-14} chain={1} act={2}  {3}" -f $p.Id, $p.Chain, $p.BatchAction, $p.Status) -ForegroundColor Yellow
        }
        foreach ($l in @(Get-Content -LiteralPath $script:QueuePath -ErrorAction SilentlyContinue)) {
            Write-Host "    queue>  $l" -ForegroundColor DarkYellow
        }
        foreach ($l in @(Get-Content -LiteralPath $script:StatusPath -ErrorAction SilentlyContinue | Select-Object -Last 8)) {
            Write-Host "    worker> $l" -ForegroundColor DarkYellow
        }
    }

    Assert-True 'checkpoint B: no run-marker at section start' (-not (Test-Path -LiteralPath $depUnRan))

    # ---- case 3: the base is neither installed nor in the batch -> refused, fix offered
    foreach ($i in $script:Items) { $i.IsSelected = $false }
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
    $dep.IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'the sheet opened'                'Visible' "$($PreflightOverlay.Visibility)"
    Assert-Equal 'the dependency panel shows'      'Visible' "$($PfDep.Visibility)"
    Assert-True  'and names the missing base'      ($TxtPfDepNote.Text -match 'needs Gui App A')
    Assert-Equal 'the commit button is disabled'   $false $BtnPfGo.IsEnabled
    Invoke-Click $BtnPfGo
    Assert-True  'and even a forced press starts nothing' ($script:Phase -ne 'Download')

    # ---- the one-click fix: Add the base, ordered ahead of what needs it
    Assert-Equal 'the fix is offered'              'Visible' "$($BtnPfAddDep.Visibility)"
    Invoke-Click $BtnPfAddDep
    Assert-Equal 'the base joined the sheet'       2 @($script:PfItems).Count
    Assert-Equal 'ahead of the add-on'             'gui-a' ([string]$script:PfItems[0].Id)
    Assert-Equal 'and the block lifted'            $true $BtnPfGo.IsEnabled
    Invoke-Click $BtnPfCancel
    foreach ($i in $script:Items) { $i.IsSelected = $false }

    # ---- fail open: an id the catalog does not know must never block a batch
    $saveReq = $dep.Requires
    $dep.Requires = @('ghost-id')
    $dep.IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'an unknown required id does not block' $true $BtnPfGo.IsEnabled
    Invoke-Click $BtnPfCancel
    $dep.Requires = $saveReq
    foreach ($i in $script:Items) { $i.IsSelected = $false }

    Assert-True 'checkpoint C: no run-marker after the case-3 segments' (-not (Test-Path -LiteralPath $depUnRan))

    # ---- case 4: the add-on is installed and the BASE is being installed
    New-Item -ItemType Directory -Force -Path $depDir | Out-Null
    Set-Content -LiteralPath $depExe -Value 'dep' -Encoding ASCII
    Set-StagedPackage
    $depCache = Join-Path (Join-Path $script:CacheDir 'files') 'gui-dep'
    New-Item -ItemType Directory -Force -Path $depCache | Out-Null
    Copy-Item -LiteralPath $depZip -Destination (Join-Path $depCache 'package.zip') -Force
    $base = @($script:Items | Where-Object { $_.Id -eq 'gui-a' })[0]
    $base.IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'the sheet detects the installed add-on'   'Visible' "$($PfDep.Visibility)"
    Assert-Equal 'the orchestration is offered'             'Visible' "$($ChkPfReinstall.Visibility)"
    Assert-Equal 'ticked by default'                        $true ([bool]$ChkPfReinstall.IsChecked)
    Assert-Equal 'the effective batch is the full sequence' 3 @(Get-PfCommitItems).Count
    Assert-True 'checkpoint D: no run-marker with the sheet open' (-not (Test-Path -LiteralPath $depUnRan))

    # ---- decline keeps today's behaviour: no removal, the base installs as-is
    Assert-True 'precondition: no run-marker before the decline' (-not (Test-Path -LiteralPath $depUnRan))
    $ChkPfReinstall.IsChecked = $false
    Invoke-Click $BtnPfGo
    Assert-True 'the declined batch finished'      (Wait-For { $script:Phase -in 'Done', 'Idle' } 180000)
    Write-DepStall 'after-decline'
    Assert-True 'the base installed'               ($base.Status -like 'Installed*')
    Assert-True 'the add-on was left alone'        (Test-Path -LiteralPath $depExe)
    Assert-True 'and its uninstaller never ran'    (-not (Test-Path -LiteralPath $depUnRan))

    # ---- the orchestrated sequence: remove -> install base -> reinstall add-on, one batch
    foreach ($i in $script:Items) { $i.IsSelected = $false }
    Set-StagedPackage
    New-Item -ItemType Directory -Force -Path $depCache | Out-Null
    Copy-Item -LiteralPath $depZip -Destination (Join-Path $depCache 'package.zip') -Force
    $base.IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'offered again, ticked by default again' $true ([bool]$ChkPfReinstall.IsChecked)
    # the declined batch above installed the base, so the sheet now also flags it as already
    # installed and skips it - the technician asks for the reinstall, same as Invoke-Commit does
    Assert-Equal 'and the base is flagged as already installed' 'Visible' "$($PfHave.Visibility)"
    $ChkPfHave.IsChecked = $true
    Assert-Equal 'ticking reinstall keeps the full sequence' 3 @(Get-PfCommitItems).Count
    Invoke-Click $BtnPfGo
    Assert-True 'the orchestrated batch finished'  (Wait-For { $script:Phase -in 'Done', 'Idle' } 240000)
    Assert-True 'the remove-first step really ran' (Test-Path -LiteralPath $depUnRan)
    # the removal took the folder; the reinstall put it back - the marker plus a live verify
    # path is exactly the end state the sequence promises
    Assert-True 'and the reinstall put the add-on back' (Test-Path -LiteralPath $depExe)
    $unRow = @($script:Pending | Where-Object { $_.Id -eq 'gui-dep~un' })[0]
    Assert-True 'the un-step row reports Uninstalled' ($unRow -and $unRow.Status -like 'Uninstalled*')
    Assert-True 'the base reports Installed'       ($base.Status -like 'Installed*')
    Assert-True 'and the add-on came back'         ($dep.Status -like 'Installed*')
    Assert-Equal 'the wipe preview never appeared' 'Collapsed' "$($WipeOverlay.Visibility)"
    # the ORDER is the promise: the status file is this batch's own transcript
    $stLines = @(Get-Content -LiteralPath $script:StatusPath -ErrorAction SilentlyContinue)
    $iUn = -1; $iBase = -1; $iDep = -1
    for ($k = 0; $k -lt $stLines.Count; $k++) {
        if ($iUn   -lt 0 -and $stLines[$k] -match '"gui-dep~un"' -and $stLines[$k] -match 'Uninstalled') { $iUn = $k }
        if ($iBase -lt 0 -and $stLines[$k] -match '"gui-a"'      -and $stLines[$k] -match 'Installed')   { $iBase = $k }
        if ($iDep  -lt 0 -and $stLines[$k] -match '"gui-dep"'    -and $stLines[$k] -match 'Installed')   { $iDep = $k }
    }
    Assert-True 'the sequence ran remove -> base -> reinstall' ($iUn -ge 0 -and $iBase -gt $iUn -and $iDep -gt $iBase)
    $depRec = @(Get-ChildItem -LiteralPath (Get-RunsDir) -Filter 'run-*.json' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1 |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })[0]
    Assert-Equal 'the run record counts all three ok' 3 ([int]$depRec.counts.ok)
    Assert-True  'and the un-step rides in it'        (@(@($depRec.items) | Where-Object { $_.id -eq 'gui-dep~un' }).Count -eq 1)

    # ---- a failed removal aborts the base install and the reinstall behind it
    New-Item -ItemType Directory -Force -Path $depDir | Out-Null
    Set-Content -LiteralPath $depExe -Value 'dep' -Encoding ASCII
    Remove-Item -LiteralPath $depUnRan -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $depUn -Encoding ASCII -Value (@(
        '@echo off',
        "echo ran > `"$depUnRan`"",
        "exit ${sl}b 1") -join "`r`n")
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
    foreach ($i in $script:Items) { $i.IsSelected = $false }
    Set-StagedPackage
    New-Item -ItemType Directory -Force -Path $depCache | Out-Null
    Copy-Item -LiteralPath $depZip -Destination (Join-Path $depCache 'package.zip') -Force
    $base.IsSelected = $true
    Invoke-Click $BtnInstall
    Invoke-Click $BtnPfGo
    Assert-True 'the failing batch settled'        (Wait-For { $script:Phase -in 'Done', 'Idle' } 240000)
    Write-DepStall 'after-failing-un'
    $unRow2 = @($script:Pending | Where-Object { $_.Id -eq 'gui-dep~un' })[0]
    Assert-True 'the removal reports Failed'       ($unRow2 -and $unRow2.Status -like 'Failed*')
    Assert-True 'the base was skipped, not installed' ($base.Status -match '^Skipped')
    Assert-True 'and really was not installed'     (-not (Test-Path -LiteralPath "$appDir\app.exe"))
    Assert-True 'the reinstall never ran either'   ($dep.Status -match '^(Skipped|Removed)')
    Assert-True 'and the old copy is untouched'    (Test-Path -LiteralPath $depExe)

    # ---- the base's DOWNLOAD fails: the pre-queued removal must not run on the strength of a
    # download that never landed, and the reinstall behind it has nothing to reinstall onto.
    # Nothing on the machine may change, and no worker may even start.
    Set-Content -LiteralPath $depUn -Encoding ASCII -Value (@(
        '@echo off',
        "echo ran > `"$depUnRan`"",
        "rd /s /q `"$depDir`"",
        "exit ${sl}b 0") -join "`r`n")
    Remove-Item -LiteralPath $depUnRan -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $depDir | Out-Null
    Set-Content -LiteralPath $depExe -Value 'dep' -Encoding ASCII
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
    foreach ($i in $script:Items) { $i.IsSelected = $false }
    # no cached copy for the base, and a link that cannot be fetched
    $baseCache = Join-Path (Join-Path $script:CacheDir 'files') 'gui-a'
    if (Test-Path -LiteralPath $baseCache) { Remove-Item -LiteralPath $baseCache -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $depCache | Out-Null
    Copy-Item -LiteralPath $depZip -Destination (Join-Path $depCache 'package.zip') -Force
    $saveUrl = $base.Url
    $base.Url = 'file:///' + (($sandbox -replace '\\', '/') + '/does-not-exist/package.zip')
    $base.IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'the sequence is offered for the failing-download run' 3 @(Get-PfCommitItems).Count
    Invoke-Click $BtnPfGo
    Assert-True 'the batch settled'                   (Wait-For { $script:Phase -in 'Done', 'Idle' } 240000)
    Write-DepStall 'after-failing-download'
    $base.Url = $saveUrl
    $unRow3 = @($script:Pending | Where-Object { $_.Id -eq 'gui-dep~un' })[0]
    Assert-True 'the base download failed'            ($base.Status -like 'Failed*')
    Assert-True 'the removal was skipped, saying the base was not installed' ($unRow3 -and $unRow3.Status -like 'Skipped*' -and $unRow3.StatusDetail -like '*was not installed*')
    Assert-True 'and its uninstaller never ran'       (-not (Test-Path -LiteralPath $depUnRan))
    Assert-True 'the reinstall was skipped too'       ($dep.Status -like 'Skipped*')
    Assert-True 'the installed add-on is untouched'   (Test-Path -LiteralPath $depExe)
    Assert-True 'no elevated worker was ever started' (-not $script:WorkerStarted)

    # ---- the base INSTALL fails after the removal succeeded: the reinstall must still run,
    # because restoring the add-on is what returns the machine closest to how it was found.
    # The base package is swapped for one whose installer dies with 1603 - a real MSI-style
    # fatal exit, which is also dirty, so the leftover preview appears and is skipped.
    $failSrc = Join-Path $sandbox 'fail-src\inner'
    New-Item -ItemType Directory -Force -Path $failSrc | Out-Null
    Set-Content -LiteralPath "$failSrc\setup.cmd" -Encoding ASCII -Value (@('@echo off', "exit ${sl}b 1603") -join "`r`n")
    $failZip = Join-Path $sandbox 'fail-package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $failSrc -Parent), $failZip)
    $saveSha = $base.Sha256; $saveSize = $base.SizeBytes
    $base.Sha256 = (Get-FileHash -LiteralPath $failZip -Algorithm SHA256).Hash
    $base.SizeBytes = (Get-Item -LiteralPath $failZip).Length
    New-Item -ItemType Directory -Force -Path $baseCache | Out-Null
    Copy-Item -LiteralPath $failZip -Destination (Join-Path $baseCache 'package.zip') -Force
    New-Item -ItemType Directory -Force -Path $depCache | Out-Null
    Copy-Item -LiteralPath $depZip -Destination (Join-Path $depCache 'package.zip') -Force
    Remove-Item -LiteralPath $depUnRan -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $depDir | Out-Null
    Set-Content -LiteralPath $depExe -Value 'dep' -Encoding ASCII
    foreach ($i in $script:Items) { $i.IsSelected = $false }
    $base.IsSelected = $true
    Invoke-Click $BtnInstall
    Invoke-Click $BtnPfGo
    Assert-True 'the batch reached its verdict or its leftover preview' `
                (Wait-For { "$($WipeOverlay.Visibility)" -eq 'Visible' -or $script:Phase -in 'Done', 'Idle' } 240000)
    if ("$($WipeOverlay.Visibility)" -eq 'Visible') {
        Assert-True 'the failed base install opened the leftover preview' $true
        Invoke-Click $BtnWipeSkip
    }
    Assert-True 'the batch finished'                  (Wait-For { $script:Phase -in 'Done', 'Idle' } 240000)
    Write-DepStall 'after-failing-base-install'
    $base.Sha256 = $saveSha; $base.SizeBytes = $saveSize
    $unRow4 = @($script:Pending | Where-Object { $_.Id -eq 'gui-dep~un' })[0]
    Assert-True 'the removal ran and succeeded'       ($unRow4 -and $unRow4.Status -like 'Uninstalled*' -and (Test-Path -LiteralPath $depUnRan))
    Assert-True 'the base install failed'             ($base.Status -like 'Failed*')
    Assert-True 'naming the fatal exit'               ($base.StatusDetail -like '*fatal error*')
    Assert-True 'the reinstall still ran'             ($dep.Status -like 'Installed*')
    Assert-True 'and the add-on is back on disk'      (Test-Path -LiteralPath $depExe)

    # ================================================================== 5. the click is seen
    Write-Section '5. Every click paints before the work: the strip, the dialog, the first Data Backup visit'

    # Reported from the field: 3-5 seconds with nothing on screen after Continue, on a slow
    # machine. Measured here: the batch strip was set visible and the worker was written, hashed
    # and elevated all inside one handler, so WPF drew nothing until the launch had finished.
    # Show-BatchStrip now pumps one render pass, with the busy guard held across it.
    $script:Pumps = 0
    $realUpdateUi = ${function:Update-UI}
    function Update-UI { $script:Pumps++; & $realUpdateUi }
    $script:Pending = @($script:Items | Select-Object -First 1)
    $script:Pumps = 0
    Show-BatchStrip
    Assert-True  'Show-BatchStrip pumps the dispatcher once'            ($script:Pumps -ge 1)
    Assert-Equal 'and says the worker is starting'                       'Starting the elevated worker...' $TxtNow.Text
    Assert-Equal 'with the row visible'                                  'Visible' "$($RowNow.Visibility)"
    Assert-True  'the guard is released once the pump is over'           (-not $script:BatchStarting)
    # a click landing inside that pump is refused, silently, rather than starting a second batch
    $script:BatchStarting = $true
    $ovBefore = "$($Overlay.Visibility)"
    Assert-True  'Test-BatchBusy refuses while a batch is starting'      (Test-BatchBusy)
    Assert-Equal 'without raising an overlay'                            $ovBefore "$($Overlay.Visibility)"
    $script:BatchStarting = $false

    # The confirm dialog: Continue used to hide the overlay and run the action in the same
    # handler, so the dialog sat on screen for the whole batch start. It is painted away first.
    $script:Seen = @{}
    Show-Confirm 'A question' 'about to start' ({
        $script:Seen.Overlay = "$($Overlay.Visibility)"
        $script:Seen.Pumps   = $script:Pumps
        $script:Seen.Cursor  = "$($window.Cursor)"
    }.GetNewClosure())
    $script:Pumps = 0
    $BtnOverlayOk.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert-Equal 'the overlay is hidden before the action runs'          'Collapsed' $script:Seen.Overlay
    Assert-True  'and a render pass happened first'                      ($script:Seen.Pumps -ge 1)
    Assert-Equal 'the wait cursor covers the action'                     'Wait' $script:Seen.Cursor
    Assert-True  'and is released afterwards'                            ($null -eq $window.Cursor)
    Assert-True  'Cancel still just closes'                              ($null -eq $script:ConfirmAction)
    ${function:Update-UI} = $realUpdateUi

    # The first Data Backup visit: the share check loads the SMB module (a second here, more
    # on a client) and ran after the busy pill had gone, so the tab sat unpainted. The whole
    # first visit is under one pill now.
    Assert-True 'the first Data Backup visit is covered by one busy pill' `
                ($src -match "if \(\`$firstVisit\) \{ Show-Busy 'Reading the accounts and shares on this PC\.\.\.' \}[\s\S]{0,900}finally \{ if \(\`$firstVisit\) \{ Hide-Busy \} \}")

    # The reads themselves. Every wait indicator is a storyboard spinner, and a storyboard only
    # turns while the UI thread is free. MEASURED: the firewall rule read, the SMB module load,
    # the Store package list and the network adapter read each stood their spinner still for
    # 0.5-1.2 s here, three to five times that on a client. They run on a background runspace
    # now, through Invoke-OffUi, and the window pumps while they do.
    $script:Pumps = 0
    function Update-UI { $script:Pumps++; & $realUpdateUi }
    $got = @(Invoke-OffUi { param($a, $b) Start-Sleep -Milliseconds 350; "$a+$b" } -Arguments @('x', 'y'))
    Assert-True  'Invoke-OffUi runs the script with its arguments and hands back the output, one object per row' ($got.Count -eq 1 -and $got[0] -is [string] -and $got[0] -eq 'x+y')
    Assert-Equal 'a script that emits nothing hands back nothing - not one blank row'     0 @(Invoke-OffUi { }).Count
    Assert-Equal 'and three rows come back as three'                                       3 @(Invoke-OffUi { 1; 2; 3 }).Count
    Assert-True  'and pumps the dispatcher while it waits'                              ($script:Pumps -ge 3)
    [void](Invoke-OffUi { $global:PC2GoOffUiMark = 41 })
    Assert-Equal 'the runspace is kept: what one read loaded, the next still has'       41 "$(@(Invoke-OffUi { $global:PC2GoOffUiMark })[0])"
    $why = ''
    try { [void](Invoke-OffUi { throw 'the read said no' }) } catch { $why = $_.Exception.Message }
    Assert-True  'a script that throws reaches the caller as its own message'           ($why -like '*the read said no*')
    $why = ''
    try { [void](Invoke-OffUi { Start-Sleep -Seconds 5 } -TimeoutSec 1 -What 'A slow read') } catch { $why = $_.Exception.Message }
    Assert-Equal 'a read past its time limit is stopped and named'                      'A slow read did not finish within 1 seconds' $why
    Assert-Equal 'and the shared runspace is still good afterwards'                     41 "$(@(Invoke-OffUi { $global:PC2GoOffUiMark })[0])"
    # a click the pump dispatched that reads something too must not collide with the read in flight
    # (the flag is raised BEFORE the nested call: the nested read pumps too, and a pump that
    # re-entered here on "not yet answered" recursed until the call depth ran out)
    $script:Nested = $null; $script:NestedTried = $false
    function Update-UI { if ($script:OffUiBusy -and -not $script:NestedTried) { $script:NestedTried = $true; $script:Nested = "$(@(Invoke-OffUi { 'inner:' + $global:PC2GoOffUiMark })[0])" }; & $realUpdateUi }
    [void](Invoke-OffUi { Start-Sleep -Milliseconds 300 })
    Assert-Equal 'a nested read runs on a runspace of its own'                          'inner:' $script:Nested
    ${function:Update-UI} = $realUpdateUi
    Assert-True  'and the busy flag is released'                                         (-not $script:OffUiBusy)
    $gAst = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    foreach ($fn in 'Get-FirewallBlockMap', 'Get-AllShares', 'Get-StoreApps', 'Get-LocalIPv4') {
        $body = $gAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true) | Select-Object -First 1
        Assert-True "$fn reads off the UI thread"                                       ($body -and $body.Extent.Text -match 'Invoke-OffUi')
    }
    foreach ($fn in 'Get-LocalSubnets', 'Find-NetworkHosts') {
        $body = $gAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true) | Select-Object -First 1
        Assert-True "$fn asks no network cmdlet on the UI thread itself"                ($body -and $body.Extent.Text -notmatch 'Get-Net(Adapter|IPAddress)')
    }
    Assert-True  'Load-Firewall refuses to run twice at once'                            ($src -match "if \(\`$script:FwScanning\) \{ return \}")
    # and the real reads, through the real helper, on this machine
    $ipv4 = Get-LocalIPv4
    Assert-True  'the adapter read answers with this PC''s addresses'                    (@($ipv4.Addresses).Count -ge 1 -and "$($ipv4.Addresses[0].Ip)" -match '^\d+\.\d+\.\d+\.\d+$')
    $shares = @(Get-AllShares)
    Assert-Equal 'the share read answers, every row with a name and a path'             0 @($shares | Where-Object { -not $_.Name -or -not $_.Path }).Count

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    # never leave one of these behind: it polls its queue for ever and would poison the next run
    $left = Stop-OrphanWorkers
    if ($left) { Write-Host "  stopped $left worker(s) still running at exit" -ForegroundColor Yellow }
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $installRoot / $sandbox" -ForegroundColor Yellow
    } else {
        Remove-Artefacts
        $left = @(@($installRoot) | Where-Object { Test-Path -LiteralPath $_ }) +
                @(@($keyU) | Where-Object { Test-Path -LiteralPath $_ })
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($left -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}


