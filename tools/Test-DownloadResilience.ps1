<#
.SYNOPSIS
    Fault-injection harness for the download half: cancel, connection loss, and resume.

.DESCRIPTION
    A technician's session is 30 GB over a link that drops. The question worth answering is
    not "does a download work" but "what happens when it stops working half way" - so the
    server here is one we can kill on purpose, mid-transfer, and bring back.

    It drives the same BITS API AppDeploy.ps1 uses (Start-BitsTransfer -Asynchronous, then
    Get-BitsTransfer polling, Suspend/Resume, Remove) against a local HTTP server that
    supports Range requests, because Range is what makes a resume a resume rather than a
    silent restart from zero.

    Runs unelevated and touches nothing outside %TEMP%.

    SCOPE, stated honestly: this covers BITS and the transfer contract. It does NOT drive
    AppDeploy's own window - the install list is not reachable by UI Automation - so the GUI's
    timer wiring around these calls is still only covered by reading it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DownloadResilience.ps1
#>
[CmdletBinding()]
param(
    [int]$SizeMB = 24,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

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

$root = Join-Path $env:TEMP ("appdeploy-dl-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

# ------------------------------------------------------------------ the killable server
# Runs in its own runspace so the test can stop it dead in the middle of a transfer, which is
# what "the connection dropped" looks like from the client's side. Range support is the point:
# without it BITS cannot resume and would silently start again from zero.
$serverCode = {
    param($Prefix, $FilePath, $ChunkBytes, $DelayMs, $StopFlag)
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    while (-not (Test-Path -LiteralPath $StopFlag)) {
        $ctx = $null
        try {
            $async = $listener.BeginGetContext($null, $null)
            while (-not $async.AsyncWaitHandle.WaitOne(200)) {
                if (Test-Path -LiteralPath $StopFlag) { break }
            }
            if (-not $async.IsCompleted) { break }
            $ctx = $listener.EndGetContext($async)
        } catch { break }
        try {
            $req = $ctx.Request
            $res = $ctx.Response
            $from = 0
            $to = $bytes.Length - 1
            $range = $req.Headers['Range']
            if ($range -match 'bytes=(\d+)-(\d*)') {
                $from = [int]$Matches[1]
                if ($Matches[2]) { $to = [int]$Matches[2] }
                $res.StatusCode = 206
                $res.Headers['Content-Range'] = "bytes $from-$to/$($bytes.Length)"
            } else {
                $res.StatusCode = 200
            }
            $res.Headers['Accept-Ranges'] = 'bytes'
            $len = $to - $from + 1
            $res.ContentLength64 = $len
            if ($req.HttpMethod -eq 'HEAD') { $res.Close(); continue }
            $sent = 0
            while ($sent -lt $len) {
                if (Test-Path -LiteralPath $StopFlag) { break }
                $n = [Math]::Min($ChunkBytes, $len - $sent)
                $res.OutputStream.Write($bytes, $from + $sent, $n)
                $res.OutputStream.Flush()
                $sent += $n
                Start-Sleep -Milliseconds $DelayMs   # throttled, so there is time to interrupt
            }
            $res.Close()
        } catch { try { $ctx.Response.Abort() } catch {} }
    }
    try { $listener.Stop(); $listener.Close() } catch {}
}

$script:Server = $null
$script:ServerHandle = $null
$stopFlag = Join-Path $root 'server.stop'

function Start-TestServer([string]$prefix, [string]$file, [int]$chunk, [int]$delay) {
    Remove-Item -LiteralPath $stopFlag -ErrorAction SilentlyContinue
    $script:Server = [powershell]::Create()
    [void]$script:Server.AddScript($serverCode).AddArgument($prefix).AddArgument($file).
        AddArgument($chunk).AddArgument($delay).AddArgument($stopFlag)
    $script:ServerHandle = $script:Server.BeginInvoke()
    Start-Sleep -Milliseconds 700
}

function Stop-TestServer {
    if (-not $script:Server) { return }
    Set-Content -LiteralPath $stopFlag -Value 'stop' -Encoding ASCII
    Start-Sleep -Milliseconds 900
    try { $script:Server.Stop() } catch {}
    try { $script:Server.Dispose() } catch {}
    $script:Server = $null
}

function Get-JobState($job) {
    try { return (Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop).JobState } catch { return 'Gone' }
}

try {
    # a payload big enough that a throttled transfer lasts long enough to interrupt
    $payload = Join-Path $root 'package.bin'
    $rand = New-Object byte[] (1MB)
    (New-Object Random 1234).NextBytes($rand)
    $fs = [IO.File]::Create($payload)
    try { for ($i = 0; $i -lt $SizeMB; $i++) { $fs.Write($rand, 0, $rand.Length) } } finally { $fs.Dispose() }
    $wantHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
    $port = Get-Random -Minimum 49200 -Maximum 51000
    $prefix = "http://127.0.0.1:$port/"
    $url = "$prefix" + 'package.bin'
    Write-Host ("Payload {0} MB, served throttled from {1}" -f $SizeMB, $prefix) -ForegroundColor DarkGray

    # ============================================================ 1. cancel mid-download
    Write-Section '1. Cancel while a download is running'
    Start-TestServer $prefix $payload (64 * 1024) 40
    $dest = Join-Path $root 'cancelled.bin'
    $job = Start-BitsTransfer -Source $url -Destination $dest -Asynchronous -DisplayName 'PC2GoTest:cancel'
    $moved = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ((Get-BitsTransfer -JobId $job.JobId).BytesTransferred -gt 0) { $moved = $true; break }
    }
    Assert-Equal 'the transfer started moving bytes' $true $moved
    # this is exactly what Abort-Batch does
    Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
    Assert-Equal 'cancelling removes the job'        'Gone'  (Get-JobState $job)
    Assert-Equal 'and leaves no half file behind'    $false  (Test-Path -LiteralPath $dest)

    # ============================================================ 2. connection lost
    Write-Section '2. The connection dies mid-transfer'
    $dest2 = Join-Path $root 'resumed.bin'
    # the same retry cadence AppDeploy now sets - without it BITS backs off for minutes
    $job2 = Start-BitsTransfer -Source $url -Destination $dest2 -Asynchronous -DisplayName 'PC2GoTest:resume' -RetryInterval 60
    $partial = 0
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        $partial = (Get-BitsTransfer -JobId $job2.JobId).BytesTransferred
        if ($partial -gt 2MB) { break }
    }
    Assert-Equal 'some of the file arrived first' $true ($partial -gt 2MB)
    Write-Host ("  ... {0} MB in, killing the server" -f [math]::Round($partial / 1MB, 1)) -ForegroundColor DarkGray
    Stop-TestServer

    # BITS is supposed to hold the job and keep retrying, NOT fail it and NOT discard progress
    $state = ''
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $state = Get-JobState $job2
        if ($state -in 'TransientError', 'Error') { break }
    }
    Assert-Equal 'the job survives the outage'        $true  ($state -notin 'Gone', 'Error')
    Assert-Equal 'and reports a transient error'      'TransientError' $state
    $held = (Get-BitsTransfer -JobId $job2.JobId).BytesTransferred
    Assert-Equal 'the bytes already fetched are kept' $true  ($held -ge $partial)

    # ============================================================ 3. the link comes back
    Write-Section '3. The connection returns'
    Start-TestServer $prefix $payload (512 * 1024) 5
    # 60s is the floor BITS accepts for RetryInterval, so give it a couple of cycles
    $t0 = Get-Date
    $done = $false
    for ($i = 0; $i -lt 340; $i++) {
        Start-Sleep -Milliseconds 500
        $state = Get-JobState $job2
        if ($state -eq 'Transferred') { $done = $true; break }
    }
    $took = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Host "  ... recovery took ${took}s" -ForegroundColor DarkGray
    Assert-Equal 'it resumes and completes on its own' $true $done
    Assert-Equal 'and recovers within two retry cycles' $true ($done -and $took -lt 150)
    if ($done) {
        Complete-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $job2.JobId)
        Assert-Equal 'the finished file is byte-identical' $wantHash (Get-FileHash -LiteralPath $dest2 -Algorithm SHA256).Hash
        Assert-Equal 'and is the full size'                (Get-Item $payload).Length (Get-Item $dest2).Length
    }

    # ============================================================ 4. pause / resume
    Write-Section '4. Pause and resume - the GUI Pause button'
    $dest3 = Join-Path $root 'paused.bin'
    $job3 = Start-BitsTransfer -Source $url -Destination $dest3 -Asynchronous -DisplayName 'PC2GoTest:pause'
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ((Get-BitsTransfer -JobId $job3.JobId).BytesTransferred -gt 1MB) { break }
    }
    Suspend-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $job3.JobId)
    Start-Sleep -Milliseconds 600
    $atPause = (Get-BitsTransfer -JobId $job3.JobId).BytesTransferred
    Assert-Equal 'suspending holds the job'   'Suspended' (Get-JobState $job3)
    Start-Sleep -Seconds 2
    Assert-Equal 'and nothing moves while it is held' $atPause (Get-BitsTransfer -JobId $job3.JobId).BytesTransferred
    Resume-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $job3.JobId) -Asynchronous
    $done3 = $false
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Get-JobState $job3) -eq 'Transferred') { $done3 = $true; break }
    }
    Assert-Equal 'resuming finishes the job'  $true $done3
    if ($done3) {
        Complete-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $job3.JobId)
        Assert-Equal 'and the result is still intact' $wantHash (Get-FileHash -LiteralPath $dest3 -Algorithm SHA256).Hash
    }

    # ============================================================ 5. download during install
    Write-Section '5. A download running while an install hogs the machine'
    # The tool overlaps them on purpose - app N installs while app N+1 downloads - so the
    # question is whether a busy machine starves the transfer. Measured rather than assumed.
    $dest4 = Join-Path $root 'concurrent.bin'
    $job4 = Start-BitsTransfer -Source $url -Destination $dest4 -Asynchronous -DisplayName 'PC2GoTest:concurrent' -Priority Foreground
    $spin = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-Command',
        '$e=[Diagnostics.Stopwatch]::StartNew(); while ($e.Elapsed.TotalSeconds -lt 25) { $null = 1..40000 | ForEach-Object { $_ * 3 } }')
    $done4 = $false
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Get-JobState $job4) -eq 'Transferred') { $done4 = $true; break }
    }
    try { if (-not $spin.HasExited) { Stop-Process -Id $spin.Id -Force } } catch {}
    Assert-Equal 'the transfer still completes under load' $true $done4
    if ($done4) {
        Complete-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $job4.JobId)
        Assert-Equal 'and is not corrupted by the contention' $wantHash (Get-FileHash -LiteralPath $dest4 -Algorithm SHA256).Hash
    }
}
finally {
    Stop-TestServer
    foreach ($n in 'PC2GoTest:cancel', 'PC2GoTest:resume', 'PC2GoTest:pause', 'PC2GoTest:concurrent') {
        Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n } |
            Remove-BitsTransfer -ErrorAction SilentlyContinue
    }
    if ($KeepTemp) { Write-Host "`nSandbox kept: $root" -ForegroundColor Yellow }
    else { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
