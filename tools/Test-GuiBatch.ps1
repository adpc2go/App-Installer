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
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-GuiBatch.ps1
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
                silentArgs = ''; entry = 'inner\setup.cmd'; verifyPaths = @("$appDir\app.exe") })
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
    Assert-True 'and it did not elevate itself' (-not $script:Elevated)

    # The only stub. Same worker script, same queue, same status file - just launched without
    # the UAC prompt an unattended run cannot answer.
    function Start-Worker {
        if ($script:WorkerStarted) { return $true }
        Set-Content -Path $script:WorkerPath -Value ($workerScript.Replace('#__PREFTABLE__', $script:PrefTableSource)) -Encoding UTF8
        Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
        $script:StatusOffset = 0
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" " +
                  "-QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`""
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
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'

    # $timer is the batch pump - it drives the download loop AND reads the worker's status
    # file. It is created in the body but STARTED in the "go" section, which is past the cut,
    # so without this nothing a batch does ever advances.
    $timer.Start()

    Load-Catalog
    Assert-Equal 'the local catalog loaded three apps' 3 $script:Items.Count
    Assert-Equal 'and the first row is named'          'Gui App A' $script:Items[0].Name

    # ================================================================== 1. install
    Write-Section '1. Install tab: tick two rows and press Install'

    # the package is already in the cache at the right size, so the download loop takes its
    # "already fully present" branch - the same one that spares a 14 GB re-download
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    Copy-Item -LiteralPath $zip -Destination (Join-Path $script:CacheDir 'package.zip') -Force

    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    Assert-Equal 'two rows are ticked' 2 @($script:Items | Where-Object { $_.IsSelected }).Count

    Invoke-Click $BtnInstall
    Assert-Equal 'the batch started downloading'   'Download' $script:Phase
    Assert-Equal 'and Install became Add to Queue' 'Add to Queue' $TxtInstallBtn.Text
    Assert-Equal 'Cancel is offered'               'Visible' "$($BtnCancel.Visibility)"

    # ---- add a third app while the batch is live: no second worker, no second UAC
    $script:Items[2].IsSelected = $true
    Invoke-Click $BtnInstall
    Assert-Equal 'Add to Queue extended the running batch' 3 $script:Pending.Count
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
    Assert-True 'the cached installer was cleaned up' `
                (-not (Test-Path -LiteralPath (Join-Path $script:CacheDir 'package.zip')))

    # ================================================================== 2. cancel
    Write-Section '2. Install tab: Cancel stops what has not started'

    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $zip -Destination (Join-Path $script:CacheDir 'package.zip') -Force
    foreach ($it in $script:Items) { $it.IsSelected = $false }
    $script:Items[0].IsSelected = $true
    $script:Items[1].IsSelected = $true
    $script:Items[2].IsSelected = $true
    Invoke-Click $BtnInstall
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

    Invoke-Click $BtnUninstall
    # wait on the ROW, not on Phase - Phase is still 'Done' from the previous batch at the
    # instant of the click, so a phase check passes immediately and proves nothing
    $unDone = Wait-For { $marlin.Status -like 'Uninstalled*' -or $marlin.Status -like 'Failed*' -or
                         "$($WipeOverlay.Visibility)" -eq 'Visible' } 180000
    Assert-True 'the uninstall batch progressed'      $unDone
    Assert-True 'the uninstall row reads Uninstalled' ($marlin.Status -like 'Uninstalled*')
    Assert-True 'the uninstall entry is gone'         (-not (Test-Path -LiteralPath $keyU))

    # ---- the leftover preview, and the wipe. The install folder surviving the uninstaller is
    # normal - that is exactly what deep clean is for - so it is checked AFTER the approval,
    # not before it.
    if ("$($WipeOverlay.Visibility)" -eq 'Visible') {
        Write-Host ("  preview lists {0} finding(s), {1} pre-ticked" -f `
                    $script:WipeFindings.Count,
                    @($script:WipeFindings | Where-Object { $_.Del }).Count) -ForegroundColor DarkGray
        Assert-True 'the leftover preview was shown before anything was deleted' `
                    ($script:WipeFindings.Count -ge 1)
        Invoke-Click $BtnWipeGo
        Assert-True 'the wipe completed' (Wait-For { $script:Phase -in 'Done', 'Idle' } 120000)
    } else {
        Write-Host '  (no leftovers found, so there was no preview to approve)' -ForegroundColor DarkGray
    }
    Assert-True 'the program folder is gone once the wipe is approved' (-not (Test-Path -LiteralPath $dirU))

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


