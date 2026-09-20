<#
.SYNOPSIS
    The compiled client installs a real program through the real elevated worker. LAB VM ONLY.

.DESCRIPTION
    End to end, with nothing stubbed: the exe fetches a catalog from a loopback edge, downloads
    the installer from it, hands the file to the elevated worker exactly as the script does, and
    the worker verifies the hash, runs the installer silently and checks the verify path. The
    outcome is read back from the run record the exe writes and from the machine itself.

    Then a second run proves the sheet's "already installed" gate: the same request installs
    nothing and says why.

    Requires elevation and -IKnowThisWrecksTheMachine, because it installs Notepad++ for real.
    Run it through the lab runner against the CLEAN checkpoint. The exe is looked for in
    tests\fixtures\client\ (a staging copy) and then in client\dist\.
#>
[CmdletBinding()]
param([switch]$IKnowThisWrecksTheMachine)

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

if (-not $IKnowThisWrecksTheMachine) { Write-Host 'This suite installs software for real. Run it on the lab VM with -IKnowThisWrecksTheMachine.' -ForegroundColor Yellow; exit 2 }
$elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { Write-Host 'Must run elevated: the client launches the worker with RunAs and this harness cannot answer a UAC prompt.' -ForegroundColor Yellow; exit 2 }

$exe = @((Join-Path $repo 'tests\fixtures\client\PC2Go.Deploy.exe'), (Join-Path $repo 'client\dist\PC2Go.Deploy.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $exe) { throw 'PC2Go.Deploy.exe not found (tests\fixtures\client or client\dist)' }
$fixture = Join-Path $repo 'tests\fixtures\installers\npp.installer.exe'
if (-not (Test-Path -LiteralPath $fixture)) { throw "fixture missing: $fixture (tests\Get-InstallerFixtures.ps1)" }

$cacheDir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
$logDir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy-Logs'
$runsDir = Join-Path $cacheDir 'runs'
$nppExe = Join-Path ${env:ProgramFiles} 'Notepad++\notepad++.exe'
$port = 18790

Write-Section '0. The machine before'
# A machine that already has Notepad++ (a lab VM whose clean checkpoint is gone) still proves the
# removal half: the install sections are skipped rather than failed, and said so.
$alreadyHere = Test-Path -LiteralPath $nppExe
if ($alreadyHere) { Write-Host '  NOTE  Notepad++ is already on this machine - the install sections are skipped, the removal sections run.' -ForegroundColor Yellow }
else { Assert-True 'Notepad++ is not on this machine yet' $true }
Remove-Item -LiteralPath $runsDir -Recurse -Force -ErrorAction SilentlyContinue
$fixBytes = [IO.File]::ReadAllBytes($fixture)
$sha = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToUpper()
$catalog = @{
    manifestVersion = 1; updated = (Get-Date -Format 'yyyy-MM-dd')
    categories = @('Utilities')
    apps = @(
        @{ id = 'npp'; name = 'Notepad++'; version = 'fixture'; category = 'Utilities'; publisher = 'Notepad++ Team'
           url = "http://127.0.0.1:$port/files/npp.installer.exe"; sha256 = $sha; sizeBytes = $fixBytes.Length
           silentArgs = '/S'; silentSource = 'typed'; installer = @{ family = 'NSIS' }
           verifyPaths = @('%ProgramFiles%\Notepad++\notepad++.exe')
           uninstall = @{ detect = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'; command = '%ProgramFiles%\Notepad++\uninstall.exe'; args = '/S' }
           iconText = 'N' }
    )
}
$json = [Text.Encoding]::UTF8.GetBytes(($catalog | ConvertTo-Json -Depth 6))

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$hits = New-Object Collections.ArrayList
$serve = {
    param($l, $j, $f, $hits)
    while ($l.IsListening) {
        try { $c = $l.GetContext() } catch { break }
        [void]$hits.Add($c.Request.HttpMethod + ' ' + $c.Request.RawUrl + ' range=' + $c.Request.Headers['Range'])
        try {
            if ($c.Request.RawUrl -eq '/apps.json') { $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($j, 0, $j.Length) }
            elseif ($c.Request.RawUrl -eq '/files/npp.installer.exe') {
                $from = 0
                $r = '' + $c.Request.Headers['Range']
                if ($r -match '^bytes=(\d+)-') { $from = [int]$Matches[1]; $c.Response.StatusCode = 206; $c.Response.Headers['Content-Range'] = "bytes $from-$($f.Length - 1)/$($f.Length)" }
                $c.Response.ContentType = 'application/octet-stream'
                $c.Response.ContentLength64 = $f.Length - $from
                $c.Response.OutputStream.Write($f, $from, $f.Length - $from)
            } else { $c.Response.StatusCode = 404 }
        } catch { }
        try { $c.Response.Close() } catch { }
    }
}
$ps = [PowerShell]::Create(); [void]$ps.AddScript($serve).AddArgument($listener).AddArgument($json).AddArgument($fixBytes).AddArgument($hits); $h = $ps.BeginInvoke()

function Invoke-Run([string]$Switches, [int]$TimeoutSec) {
    $before = @(Get-ChildItem $logDir -Filter 'session-*.log' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $t0 = Get-Date
    $p = Start-Process -FilePath $exe -ArgumentList "-BaseUrl http://127.0.0.1:$port -NoSelfElevate $Switches" -PassThru
    $exited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { $p.Kill() }
    $new = @(Get-ChildItem $logDir -Filter 'session-*.log' -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime | Select-Object -Last 1)
    $log = $(if ($new.Count) { Get-Content $new[0].FullName -Raw } else { '' })
    return [pscustomobject]@{ Exited = $exited; Seconds = [int]((Get-Date) - $t0).TotalSeconds; Log = $log; ExitCode = $p.ExitCode }
}

try {
  if (-not $alreadyHere) {
    Write-Section '1. One app, end to end: fetch, download, elevated worker, silent install'
    $run = Invoke-Run '-AutoInstall npp -AutoClose -KeepCache' 600
    Assert-True  'the client ran the batch and closed by itself' $run.Exited
    Write-Host ("        ({0}s)" -f $run.Seconds)
    Assert-True  'the catalog came from the loopback edge' ($run.Log -match 'Catalog loaded: 1 applications')
    Assert-True  'the harness pressed Install through the sheet' ($run.Log -match 'Harness: auto-installing npp' -and $run.Log -match 'Batch started: 1 application')
    Assert-True  'the installer was downloaded' ($run.Log -match 'Notepad\+\+ downloaded')
    Assert-True  'and handed to the elevated worker' ($run.Log -match 'Queued for install')
    Assert-True  'the worker verified the file' ($run.Log -match 'Verifying file')
    Assert-True  'and installed it' ($run.Log -match 'Notepad\+\+ -> Installed')
    Assert-True  'the batch finished clean' ($run.Log -match 'Batch complete: 1 completed, 0 failed\.')
    Assert-True  'the edge saw the catalog and the file' (($hits -join "`n") -match 'GET /apps.json' -and ($hits -join "`n") -match 'GET /files/npp.installer.exe')
    Assert-True  'Notepad++ is on the machine' (Test-Path -LiteralPath $nppExe)
    Assert-True  'and registered with Windows' (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++')
    $rec = @(Get-ChildItem $runsDir -Filter 'run-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1)
    Assert-True  'a run record was written' ($rec.Count -eq 1)
    if ($rec.Count) {
        $r = Get-Content $rec[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'run record: kind' 'install' $r.kind
        Assert-Equal 'run record: one ok, none failed' '1/0' ("$($r.counts.ok)/$($r.counts.failed)")
        Assert-Equal 'run record: the row' 'npp/ok' ("$($r.items[0].id)/$($r.items[0].outcome)")
        Assert-True  'run record: the detail is the worker''s whole sentence' ($r.items[0].detail -like 'Installed*')
    }
    Assert-True  'the queue file was shredded once the worker was done' (-not (Test-Path (Join-Path $cacheDir 'queue.jsonl')))
    Assert-True  'the worker''s status file names the install' ((Get-Content (Join-Path $cacheDir 'status.jsonl') -Raw) -match '"state":"Installed"')
    Assert-True  'the worker''s own activity log has the run' (Test-Path (Join-Path $cacheDir 'activity.jsonl'))
    Assert-True  'the downloaded installer stayed (-KeepCache)' (Test-Path (Join-Path $cacheDir 'files\npp\npp.installer.exe'))

    Write-Section '2. The same request again: the sheet skips what is already here'
    $hits.Clear()
    $run2 = Invoke-Run '-AutoInstall npp -AutoClose' 120
    Assert-True  'the client closed by itself' $run2.Exited
    Assert-True  'nothing was installed, and the log says why' ($run2.Log -match 'Harness: nothing to install - everything selected is already on this machine')
    Assert-True  'no batch was started' ($run2.Log -notmatch 'Batch started')
    Assert-True  'the edge saw only the catalog' (($hits -join "`n") -notmatch '/files/')
  }

    Write-Section '3. Uninstall: the Control Panel entry, the vendor uninstaller through the worker, the leftover sweep, the wipe'
    $hits.Clear()
    Remove-Item -LiteralPath $runsDir -Recurse -Force -ErrorAction SilentlyContinue
    $run3 = Invoke-Run '-AutoUninstall "Notepad++" -AutoWipe -AutoClose' 600
    Assert-True  'the client ran the removal and closed by itself' $run3.Exited
    Write-Host ("        ({0}s)" -f $run3.Seconds)
    Assert-True  'the installed-programs list was read' ($run3.Log -match 'Installed programs: \d+ Control Panel entries')
    Assert-True  'the harness found Notepad++ in it and pressed Uninstall through the sheet' ($run3.Log -match 'Harness: auto-uninstalling Notepad\+\+' -and $run3.Log -match 'Uninstall batch started: 1 application')
    Assert-True  'the worker ran the uninstaller' ($run3.Log -match 'Notepad\+\+: Uninstalling')
    Assert-True  'and reported it gone' ($run3.Log -match 'Notepad\+\+ -> Uninstalled')
    Assert-True  'the leftover sweep ran' ($run3.Log -match 'Leftover scan|Wiping \d+ leftover|nothing found')
    Assert-True  'the batch finished' ($run3.Log -match 'Batch complete: 1 completed, 0 failed')
    Assert-True  'Notepad++ is off the machine' (-not (Test-Path -LiteralPath $nppExe))
    Assert-True  'and out of the registry' (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'))
    $rec3 = @(Get-ChildItem $runsDir -Filter 'run-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1)
    Assert-True  'a run record was written' ($rec3.Count -eq 1)
    if ($rec3.Count) {
        $r3 = Get-Content $rec3[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'run record: kind' 'uninstall' $r3.kind
        Assert-Equal 'run record: one ok' '1/0' ("$($r3.counts.ok)/$($r3.counts.failed)")
    }
    Assert-True  'the edge saw only the catalog' (($hits -join "`n") -notmatch '/files/')

    Write-Section '4. The same removal again: the list no longer has it'
    $run4 = Invoke-Run '-AutoUninstall "Notepad++" -AutoClose' 120
    Assert-True  'the client closed by itself' $run4.Exited
    Assert-True  'nothing matched, and the log says so' ($run4.Log -match 'Harness: auto-uninstalling \(nothing matched\)')
}
finally {
    $listener.Stop(); $ps.Stop(); $ps.Dispose()
}

Write-Host ""
Write-Host ("PASS {0}   FAIL {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
