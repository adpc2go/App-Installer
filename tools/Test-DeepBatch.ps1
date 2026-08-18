<#
.SYNOPSIS
    The Install tab against a REAL download and the full exit-code matrix.

.DESCRIPTION
    Test-GuiBatch drives the tab's buttons, but it pre-places the package in the cache so the
    download branch is skipped - which meant BITS had never transferred a byte inside the GUI,
    and Pause/Resume had never run at all. This closes that.

    A small HTTP server runs on 127.0.0.1 for the length of the test, serving real .zip packages
    with Content-Length, Accept-Ranges and Range support, so BITS behaves as it does against the
    real bucket - including resuming a partial transfer rather than restarting it. One package
    is deliberately large and served slowly, so there is time to press Pause while bytes are
    genuinely moving.

    On top of that it runs the exit-code matrix through the GUI rather than through the worker
    alone: 3010 (installed, reboot required), 1602 (cancelled inside the installer), 1619 (the
    package could not be opened), and the liar that exits 0 without producing its verifyPaths.
    And it covers the branch nobody had run - elevation DECLINED - by making Start-Worker fail
    the way a refused UAC prompt makes it fail.

    STILL NOT COVERED, and no test code can cover it from here: the real elevated worker. Every
    harness stubs Start-Worker to drop -Verb RunAs, because an unattended run cannot answer a
    UAC prompt. That path needs a human present on an elevated run.

    Runs unelevated. The session cache is redirected into the sandbox, so this machine's real
    PC2GoDeploy folder is never touched, and everything created is removed.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DeepBatch.ps1
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
$sandbox     = Join-Path $env:TEMP "pc2go-deep-$tag"
$installRoot = Join-Path $env:LOCALAPPDATA "PC2GoDeepTest-$tag"
$script:Http = $null

function Stop-OrphanWorkers([string]$Match = 'pc2go-deep-') {
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
function Remove-BitsJobs {
    try {
        foreach ($j in @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'PC2GoDeploy:*' })) {
            Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Wait-Dispatcher([int]$Milliseconds) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
    $t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-For([scriptblock]$Until, [int]$TimeoutMs = 180000, [int]$Step = 250) {
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

# ------------------------------------------------------------------ the HTTP server
# A raw TcpListener rather than HttpListener: an http:// prefix needs a URL reservation, which
# needs admin, and the point of this file is to run without it. BITS only needs correct
# Content-Length, Accept-Ranges and 206 Partial Content - the same handful of headers that makes
# a resumed download work against the real bucket.
$httpWorker = {
    param($Root, $Port, $SlowFile, $ChunkBytes, $ChunkDelayMs)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    while ($true) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream)
            $line = $reader.ReadLine()
            if (-not $line) { $client.Close(); continue }
            $parts = $line -split ' '
            $method = $parts[0]
            $path = ($parts[1] -replace '^/', '')
            $rangeFrom = 0
            while ($true) {
                $h = $reader.ReadLine()
                if ([string]::IsNullOrEmpty($h)) { break }
                if ($h -match '^(?i)Range:\s*bytes=(\d+)-') { $rangeFrom = [int64]$Matches[1] }
            }
            $w = New-Object IO.BinaryWriter($stream)
            # AcceptTcpClient blocks for ever, so the only reliable way to end this loop is a
            # request that arrives and says stop. Without it the runspace outlives the test and
            # teardown hangs waiting for a thread that is parked in accept().
            if ($path -eq '__stop') {
                $w.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"))
                $w.Flush(); try { $client.Close() } catch {}
                try { $listener.Stop() } catch {}
                return
            }
            $file = Join-Path $Root $path
            if (-not (Test-Path -LiteralPath $file)) {
                $w.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"))
                $w.Flush(); $client.Close(); continue
            }
            $len = (Get-Item -LiteralPath $file).Length
            $send = $len - $rangeFrom
            $status = $(if ($rangeFrom -gt 0) { '206 Partial Content' } else { '200 OK' })
            $head = "HTTP/1.1 $status`r`nContent-Length: $send`r`nAccept-Ranges: bytes`r`n"
            if ($rangeFrom -gt 0) { $head += "Content-Range: bytes $rangeFrom-$($len-1)/$len`r`n" }
            $head += "Content-Type: application/octet-stream`r`nConnection: close`r`n`r`n"
            $w.Write([Text.Encoding]::ASCII.GetBytes($head))
            $w.Flush()
            if ($method -ne 'HEAD') {
                $fs = [IO.File]::OpenRead($file)
                try {
                    [void]$fs.Seek($rangeFrom, 'Begin')
                    $slow = ([IO.Path]::GetFileName($file) -eq $SlowFile)
                    $buf = New-Object byte[] $ChunkBytes
                    while ($true) {
                        $read = $fs.Read($buf, 0, $buf.Length)
                        if ($read -le 0) { break }
                        $w.Write($buf, 0, $read)
                        $w.Flush()
                        # only the big package is throttled, so Pause lands while bytes move
                        if ($slow) { Start-Sleep -Milliseconds $ChunkDelayMs }
                    }
                } finally { $fs.Dispose() }
            }
            $w.Flush()
        } catch {
        } finally { try { $client.Close() } catch {} }
    }
    try { $listener.Stop() } catch {}
}

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray
    [void](Stop-OrphanWorkers)
    Remove-BitsJobs

    # ================================================================== packages
    Write-Section 'Building real packages, each with a different ending'

    $serveDir = Join-Path $sandbox 'www'
    New-Item -ItemType Directory -Force -Path $serveDir | Out-Null

    function New-Package([string]$Name, [string]$Body) {
        $src = Join-Path $sandbox "src-$Name\inner"
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath "$src\setup.cmd" -Encoding ASCII -Value $Body
        $out = Join-Path $serveDir "$Name.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $src -Parent), $out)
        return $out
    }
    $sl = '/'
    $dirOk     = Join-Path $installRoot 'Ok'
    $dirReboot = Join-Path $installRoot 'Reboot'
    $dirLiar   = Join-Path $installRoot 'Liar'

    $pkgOk = New-Package 'ok' ((@('@echo off', "mkdir `"$dirOk`" 2>nul",
        "echo app > `"$dirOk\app.exe`"", "exit ${sl}b 0") -join "`r`n"))
    $pkgReboot = New-Package 'reboot' ((@('@echo off', "mkdir `"$dirReboot`" 2>nul",
        "echo app > `"$dirReboot\app.exe`"", "exit ${sl}b 3010") -join "`r`n"))
    $pkgCancel = New-Package 'usercancel' ((@('@echo off', "exit ${sl}b 1602") -join "`r`n"))
    $pkgBadPkg = New-Package 'badpackage' ((@('@echo off', "exit ${sl}b 1619") -join "`r`n"))
    # exits 0 and installs nothing: verifyPaths is the only thing that catches it
    $pkgLiar = New-Package 'liar' ((@('@echo off', "exit ${sl}b 0") -join "`r`n"))

    # a big one, served slowly, so Pause lands while bytes are moving
    $bigSrc = Join-Path $sandbox 'src-big\inner'
    New-Item -ItemType Directory -Force -Path $bigSrc | Out-Null
    Set-Content -LiteralPath "$bigSrc\setup.cmd" -Encoding ASCII -Value ((@(
        '@echo off', "mkdir `"$installRoot\Big`" 2>nul",
        "echo app > `"$installRoot\Big\app.exe`"", "exit ${sl}b 0") -join "`r`n"))
    # incompressible, so the zip really is this size on the wire
    $rnd = New-Object byte[] (12MB)
    (New-Object Random 1234).NextBytes($rnd)
    [IO.File]::WriteAllBytes((Join-Path $bigSrc 'payload.bin'), $rnd)
    $pkgBig = Join-Path $serveDir 'big.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $bigSrc -Parent), $pkgBig)

    $all = @($pkgOk, $pkgReboot, $pkgCancel, $pkgBadPkg, $pkgLiar, $pkgBig)
    Assert-Equal 'six real packages were built' 6 @($all | Where-Object { Test-Path $_ }).Count
    Write-Host ("  big.zip is {0:N1} MB" -f ((Get-Item $pkgBig).Length / 1MB)) -ForegroundColor DarkGray

    # ================================================================== the server
    Write-Section 'Serving them over real HTTP for BITS to fetch'

    $port = Get-FreePort
    $script:Http = [powershell]::Create()
    [void]$script:Http.AddScript($httpWorker).AddArgument($serveDir).AddArgument($port).
                       AddArgument('big.zip').AddArgument(64KB).AddArgument(40)
    [void]$script:Http.BeginInvoke()
    Start-Sleep -Milliseconds 700

    $probe = $null
    try { $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$port/ok.zip" -UseBasicParsing -TimeoutSec 10 } catch {}
    Assert-True  'the test server answers'   ($null -ne $probe -and $probe.StatusCode -eq 200)
    Assert-Equal 'and serves the real bytes' (Get-Item $pkgOk).Length $probe.RawContentLength
    Assert-True  'advertising byte ranges, which is what makes a resume possible' `
                 ("$($probe.Headers['Accept-Ranges'])" -eq 'bytes')

    # ================================================================== the GUI
    Write-Section 'Loading the GUI and pointing the catalog at that server'

    function New-App([string]$Id, [string]$Name, [string]$Zip, [string]$Verify) {
        $f = Get-Item -LiteralPath $Zip
        return [pscustomobject]@{
            id = $Id; name = $Name; category = 'Apps'
            url = "http://127.0.0.1:$port/$($f.Name)"
            sha256 = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
            sizeBytes = $f.Length; silentArgs = ''; entry = 'inner\setup.cmd'
            verifyPaths = @($Verify)
        }
    }
    $server = Join-Path $sandbox 'catalog'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    $catalog = [pscustomobject]@{
        updated = (Get-Date -Format 'yyyy-MM-dd')
        apps = @(
            (New-App 'ok'      'Ends Well'      $pkgOk     "$dirOk\app.exe")
            (New-App 'reboot'  'Wants A Reboot' $pkgReboot "$dirReboot\app.exe")
            (New-App 'ucancel' 'User Cancelled' $pkgCancel "$installRoot\Cancel\app.exe")
            (New-App 'badpkg'  'Bad Package'    $pkgBadPkg "$installRoot\Bad\app.exe")
            (New-App 'liar'    'Claims Success' $pkgLiar   "$dirLiar\app.exe")
            (New-App 'big'     'Big Download'   $pkgBig    "$installRoot\Big\app.exe"))
    }
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ($catalog | ConvertTo-Json -Depth 8),
                            (New-Object Text.UTF8Encoding $false))

    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker.' }
    . ([scriptblock]::Create($src.Substring(0, $goAt))) `
        -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate

    $script:CacheDir      = Join-Path $sandbox 'cache'
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath     = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath    = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath    = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath    = Join-Path $script:CacheDir 'cancel.flag'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'
    $timer.Start()

    # the one stub, for the one thing an unattended run cannot do
    function Start-Worker {
        if ($script:WorkerStarted) { return $true }
        Set-Content -Path $script:WorkerPath -Value ($workerScript.Replace('#__PREFTABLE__', $script:PrefTableSource)) -Encoding UTF8
        Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
        $script:StatusOffset = 0
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -WindowStyle Hidden -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" " +
            "-QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`"") | Out-Null
        $script:WorkerStarted = $true
        Add-Log 'Worker started (test harness: no elevation prompt).'
        return $true
    }

    Load-Catalog
    Assert-Equal 'the catalog loaded six apps' 6 $script:Items.Count

    # ================================================================== 1. a real download
    Write-Section '1. A real BITS download, then the full exit-code matrix'

    $byId = @{}
    foreach ($it in $script:Items) { $byId[$it.Id] = $it }
    foreach ($id in 'ok', 'reboot', 'ucancel', 'badpkg', 'liar') { $byId[$id].IsSelected = $true }

    Invoke-Click $BtnInstall
    Assert-Equal 'the batch is downloading' 'Download' $script:Phase
    # nothing was pre-placed, so this can only complete by actually transferring bytes
    Assert-True 'BITS really fetched a package over HTTP' `
                (Wait-For { Test-Path -LiteralPath (Join-Path $script:CacheDir 'ok.zip') } 120000)

    $done = Wait-For { $script:Phase -in 'Done', 'Idle' -or "$($WipeOverlay.Visibility)" -eq 'Visible' } 300000
    if (-not $done) {
        Write-Host ("  STALLED: phase={0} dl={1}/{2} worker={3} end={4}" -f $script:Phase, $script:DlIndex,
                    $script:Pending.Count, $script:WorkerStarted, $script:EndQueued) -ForegroundColor Yellow
    }
    Assert-True 'the batch reached a conclusion' $done
    foreach ($it in $script:Items) { Write-Host ("    {0,-16} {1}" -f $it.Name, $it.Status) -ForegroundColor DarkGray }

    Assert-True 'exit 0    -> Installed'                      ($byId['ok'].Status -like 'Installed*')
    Assert-True 'exit 3010 -> Installed, reboot required'     ($byId['reboot'].Status -like 'Installed*' -and
                                                               $byId['reboot'].Status -match '(?i)reboot')
    Assert-True 'exit 1602 -> cancelled inside the installer' ($byId['ucancel'].Status -match '(?i)cancel')
    Assert-True 'exit 1619 -> the package could not be opened' ($byId['badpkg'].Status -match '(?i)could not be opened|Failed')
    # the one an exit code alone can never catch
    Assert-True 'exit 0 with nothing installed -> Failed'     ($byId['liar'].Status -like 'Failed*')
    Assert-True 'and the liar is marked dirty for the leftover scan' ($byId['liar'].Dirty)
    Assert-True 'the product that worked is really on disk'   (Test-Path -LiteralPath "$dirOk\app.exe")

    if ("$($WipeOverlay.Visibility)" -eq 'Visible') {
        Write-Host ("  leftover preview: {0} finding(s)" -f $script:WipeFindings.Count) -ForegroundColor DarkGray
        Assert-True 'a failed install opens the leftover review' $true
        Invoke-Click $BtnWipeSkip
        [void](Wait-For { $script:Phase -in 'Done', 'Idle' } 120000)
    }

    # ================================================================== 2. pause and resume
    Write-Section '2. Pause and Resume on a transfer that is actually moving'

    Remove-BitsJobs
    foreach ($it in $script:Items) { $it.IsSelected = $false }
    $byId['big'].IsSelected = $true
    Invoke-Click $BtnInstall

    Assert-True 'the big download started' (Wait-For { $byId['big'].Status -match '(?i)download|%' } 60000)
    Invoke-Click $BtnPause
    Assert-Equal 'the button now offers Resume' 'Resume' $BtnPause.Content
    Assert-True  'and the batch is paused'      $script:Paused
    $job = @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'PC2GoDeploy:big' }) | Select-Object -First 1
    Assert-True  'the BITS job exists'          ($null -ne $job)
    if ($job) {
        Wait-Dispatcher 1500
        $j2 = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
        Assert-True 'and BITS reports it suspended' ("$($j2.JobState)" -eq 'Suspended')
        $held = $j2.BytesTransferred
        Wait-Dispatcher 2500
        $j3 = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
        # the whole point of Pause over Cancel: the bytes already fetched are kept
        Assert-Equal 'no further bytes move while paused' $held $j3.BytesTransferred
    }
    Invoke-Click $BtnPause
    Assert-Equal 'the button offers Pause again' 'Pause' $BtnPause.Content
    Assert-True  'and the batch resumed'         (-not $script:Paused)

    # generous on purpose: this download is deliberately throttled, and on a machine already
    # busy running the rest of the suite it has finished as slowly as several minutes
    $bigDone = Wait-For { $script:Phase -in 'Done', 'Idle' -or "$($WipeOverlay.Visibility)" -eq 'Visible' } 480000
    Assert-True 'the resumed download finished and installed' ($bigDone -and $byId['big'].Status -like 'Installed*')
    Assert-True 'the big package really installed' (Test-Path -LiteralPath "$installRoot\Big\app.exe")

    # ================================================================== 3. elevation declined
    Write-Section '3. The branch nobody had run: elevation declined'

    Remove-BitsJobs
    function Start-Worker { Add-Log 'Elevation was declined - batch cancelled.'; return $false }
    foreach ($it in $script:Items) { $it.IsSelected = $false }
    $byId['ok'].IsSelected = $true
    Remove-Item -LiteralPath "$dirOk\app.exe" -Force -ErrorAction SilentlyContinue
    Invoke-Click $BtnInstall
    Assert-True 'a refused UAC prompt ends the batch instead of hanging' `
                (Wait-For { $script:Phase -in 'Done', 'Idle' } 180000)
    Assert-True 'and nothing was installed behind the technician''s back' `
                (-not (Test-Path -LiteralPath "$dirOk\app.exe"))

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    [void](Stop-OrphanWorkers)
    Remove-BitsJobs
    if ($script:Http) {
        # a request, not PowerShell.Stop(): stopping a runspace parked in accept() waits for a
        # thread that never comes back, which hangs the whole harness AFTER it has passed
        try { [void](Invoke-WebRequest -Uri "http://127.0.0.1:$port/__stop" -UseBasicParsing -TimeoutSec 3) } catch {}
        try { $script:Http.Dispose() } catch {}
    }
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $sandbox / $installRoot" -ForegroundColor Yellow
    } else {
        foreach ($d in @($sandbox, $installRoot)) {
            try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        }
        $left = @(@($sandbox, $installRoot) | Where-Object { Test-Path -LiteralPath $_ })
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($left -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
