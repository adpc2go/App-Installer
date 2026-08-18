<#
.SYNOPSIS
    Identifies an installer's packaging technology, proposes the correct silent switches,
    optionally runs them, and writes the verified result into apps.json.

.DESCRIPTION
    Open item #1: thirteen catalog entries carry silent switches marked VERIFY. A wrong
    switch does not fail - the installer opens its GUI and waits for a click that never
    comes, so the batch hangs on a client's machine with no error to report. This is the
    only way to retire that risk: identify the packager, run the switch, and confirm the
    product actually landed.

    Detection reads the binary rather than trusting the filename. Every major packager
    leaves an unambiguous marker: NSIS writes "Nullsoft Install System", Inno Setup
    writes "Inno Setup Setup Data", InstallShield and WiX likewise.

.PARAMETER File
    The installer to inspect.

.PARAMETER Execute
    Actually run the installer. REQUIRES a VM with a snapshot - this changes the machine.
    Without it the script only identifies and proposes.

.PARAMETER VerifyPaths
    Paths that must exist after a successful install. Environment variables expanded.

.PARAMETER Id
    Catalog id. With -Execute and a verified run, apps.json is updated with the confirmed
    switches and the VERIFY marker is cleared.

.PARAMETER TimeoutSec
    Kill the installer after this many seconds. Default 1800 (30 min). A hung installer
    is the exact failure being hunted, so it must be bounded.

.EXAMPLE
    .\tools\Test-SilentSwitches.ps1 -File D:\Installers\rhino.exe
    Identify only. Safe on any machine.

.EXAMPLE
    .\tools\Test-SilentSwitches.ps1 -File D:\Installers\rhino.exe -Execute `
        -VerifyPaths '%ProgramFiles%\Rhino 8\System\Rhino.exe' -Id rhino
    Run it on a VM, confirm, and write the result back to the catalog.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$File,
    [switch]$Execute,
    [string[]]$VerifyPaths = @(),
    [string]$Id,
    [string]$SilentArgs,
    [int]$TimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$appsJson = Join-Path $root 'server\apps.json'

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "  x $m" -ForegroundColor Red }

if (-not (Test-Path -LiteralPath $File)) { throw "No such file: $File" }
$fi = Get-Item -LiteralPath $File

# --------------------------------------------------------------- 1. identify

Write-Step "Identifying $($fi.Name)  ($([math]::Round($fi.Length/1MB,1)) MB)"

# Markers live in the PE resources or the setup stub, both near the start, and sometimes
# in the trailing archive footer. Scanning the whole file would mean reading 14 GB.
function Get-FileMarkers {
    param([string]$Path, [int]$HeadMB = 12, [int]$TailMB = 2)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $headLen = [int][math]::Min([long]($HeadMB * 1MB), $fs.Length)
        $head = New-Object byte[] $headLen
        [void]$fs.Read($head, 0, $headLen)
        $text = [Text.Encoding]::ASCII.GetString($head)
        $text += [Text.Encoding]::Unicode.GetString($head)

        if ($fs.Length -gt [long](($HeadMB + $TailMB) * 1MB)) {
            $tailLen = [int]($TailMB * 1MB)
            $fs.Position = $fs.Length - $tailLen
            $tail = New-Object byte[] $tailLen
            [void]$fs.Read($tail, 0, $tailLen)
            $text += [Text.Encoding]::ASCII.GetString($tail)
        }
        return $text
    } finally { $fs.Close() }
}

$kind = $null; $silent = $null; $notes = @()

if ($fi.Extension -eq '.msi') {
    $kind = 'Windows Installer (MSI)'
    $silent = '/qn /norestart'
    $notes += 'AppDeploy adds /qn /norestart to .msi automatically - silentArgs may stay empty.'
} else {
    $blob = Get-FileMarkers -Path $File

    if ($blob -match 'Nullsoft Install System') {
        $kind = 'NSIS'
        $silent = '/S'
        $notes += 'Capital S. Lowercase /s is silently ignored by NSIS and the GUI opens.'
        $notes += 'Optional target dir: /D=C:\Path  (must be LAST, unquoted).'
    }
    elseif ($blob -match 'Inno Setup Setup Data' -or $blob -match 'JR\.Inno\.Setup') {
        $kind = 'Inno Setup'
        $silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        $notes += '/SILENT still shows a progress window; /VERYSILENT shows nothing.'
        $notes += 'Add /LOG="C:\inno.log" while testing.'
    }
    elseif ($blob -match 'InstallShield') {
        $kind = 'InstallShield'
        $silent = '/s /v"/qn REBOOT=ReallySuppress"'
        $notes += 'MSI wrapper: /s is the wrapper, /v passes the rest through to msiexec.'
        $notes += 'Legacy InstallScript builds need a recorded response file instead:'
        $notes += '    setup.exe /r /f1"C:\setup.iss"     (record once, by hand)'
        $notes += '    setup.exe /s /f1"C:\setup.iss"     (replay silently)'
    }
    elseif ($blob -match 'wixburn' -or $blob -match 'WixBundle') {
        $kind = 'WiX Burn bundle'
        $silent = '/quiet /norestart'
        $notes += 'Also accepts /passive for a progress bar with no prompts.'
    }
    elseif ($blob -match 'AdODIS' -or $blob -match 'Autodesk') {
        $kind = 'Autodesk (ODIS)'
        $silent = '-i deploy -q -o <manifest>.xml'
        $notes += 'CRITICAL: the manifest filename differs per product - read it off the package.'
        $notes += 'Single-product installs use --silent; DEPLOYMENT IMAGES need -i deploy.'
        $notes += 'That mismatch is exactly open item #1.'
    }
    elseif ($blob -match 'Creative Cloud' -or ($blob -match 'Adobe' -and $blob -match 'setup')) {
        $kind = 'Adobe Admin Console package'
        $silent = '--silent'
        $notes += 'Run setup.exe from inside the package Build folder.'
    }
    elseif ($blob -match '7-Zip' -or $blob -match 'SFX') {
        $kind = 'Self-extracting archive'
        $silent = '-y'
        $notes += 'Extraction is silent; whatever it extracts may still need its own switch.'
    }
}

if (-not $kind) {
    $kind = 'Unknown'
    Write-Warn 'No packager signature matched.'
    Write-Warn 'Try, in order:  /?   /help   /S   /silent   /quiet   /verysilent'
    Write-Warn 'Many installers print their switches to a dialog with /?.'
} else {
    Write-Ok "Packager: $kind"
    if ($silent) { Write-Ok "Proposed:  $silent" }
}

$ver = $fi.VersionInfo
if ($ver.CompanyName -or $ver.ProductName) {
    Write-Host "      Publisher: $($ver.CompanyName)   Product: $($ver.ProductName) $($ver.ProductVersion)" -ForegroundColor DarkGray
}
foreach ($n in $notes) { Write-Host "      - $n" -ForegroundColor DarkGray }

$useArgs = $silent
if ($SilentArgs) { $useArgs = $SilentArgs }

if (-not $Execute) {
    Write-Host ''
    Write-Warn 'Identification only. Nothing was run.'
    Write-Host 'To verify on a VM (snapshot first):' -ForegroundColor Cyan
    Write-Host "  .\tools\Test-SilentSwitches.ps1 -File `"$File`" -Execute -Id <id> ``" -ForegroundColor White
    Write-Host "      -VerifyPaths '%ProgramFiles%\Vendor\App\app.exe'" -ForegroundColor White
    return
}

# ---------------------------------------------------------------- 2. execute

if (-not $useArgs) { throw 'No switches to run. Pass -SilentArgs explicitly.' }

Write-Host ''
Write-Warn 'This RUNS the installer and changes this machine.'
Write-Warn 'Only do this on a VM you have snapshotted.'
if ((Read-Host 'Type RUN to continue') -ne 'RUN') { Write-Host 'Aborted.'; return }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $env:TEMP "pc2go-switchtest-$stamp"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Step "Running: $($fi.Name) $useArgs"
Write-Host "      log dir: $logDir" -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $File -ArgumentList $useArgs -PassThru
$exited = $proc.WaitForExit($TimeoutSec * 1000)
$sw.Stop()

if (-not $exited) {
    Write-Bad "TIMED OUT after $TimeoutSec s - still running."
    Write-Bad 'This is the failure that hangs a batch: the switch is almost certainly wrong'
    Write-Bad 'and the installer is sitting on a hidden dialog.'
    try { $proc.Kill() } catch { }
    return
}

$code = $proc.ExitCode
$mins = [math]::Round($sw.Elapsed.TotalMinutes, 1)

# Same vocabulary the elevated worker already uses: 3010 is success-with-reboot.
$meaning = switch ($code) {
    0     { 'success' }
    3010  { 'success, reboot required' }
    1641  { 'success, reboot initiated' }
    1618  { 'FAILED - another installation already in progress' }
    1619  { 'FAILED - package could not be opened' }
    1620  { 'FAILED - package could not be verified' }
    1603  { 'FAILED - fatal error during installation' }
    default { 'unknown - check the vendor log' }
}

if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) {
    Write-Ok "Exit $code ($meaning) after $mins min"
} else {
    Write-Bad "Exit $code ($meaning) after $mins min"
}

# ---------------------------------------------------------------- 3. verify

$verifyOk = $true
if ($VerifyPaths.Count) {
    Write-Step 'Checking verifyPaths'
    foreach ($p in $VerifyPaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($p)
        if (Test-Path -LiteralPath $expanded) { Write-Ok $p }
        else { Write-Bad "MISSING: $p"; $verifyOk = $false }
    }
} else {
    Write-Warn 'No -VerifyPaths given. An exit code alone does not prove the product installed.'
    $verifyOk = $false
}

$success = ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) -and $verifyOk -and $VerifyPaths.Count

# ------------------------------------------------------------ 4. update catalog

if (-not $Id) {
    Write-Host ''
    Write-Host "Confirmed silentArgs:  $useArgs" -ForegroundColor Cyan
    Write-Host 'Re-run with -Id <catalog id> to write this into apps.json.' -ForegroundColor DarkGray
    return
}

if (-not $success) {
    Write-Warn 'Not updating apps.json - the run did not verify.'
    return
}

Write-Step "Updating apps.json entry '$Id'"

$catalog = Get-Content -LiteralPath $appsJson -Raw | ConvertFrom-Json
$entry = @($catalog.apps) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
if (-not $entry) { throw "No app with id '$Id' in apps.json" }

$entry.silentArgs = $useArgs
$entry.sizeBytes  = $fi.Length
$entry.sha256     = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash

# The VERIFY marker is the whole point of open item #1 - clear it only on a real pass.
if ($entry.PSObject.Properties.Name -contains '_installNote') {
    $entry.PSObject.Properties.Remove('_installNote')
}

$catalog | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appsJson -Encoding UTF8
Write-Ok "silentArgs = $useArgs"
Write-Ok "sha256     = $($entry.sha256)"
Write-Ok 'VERIFY marker cleared'
Write-Host ''
Write-Host 'Run .\tools\Publish-Release.ps1 to push the updated catalog.' -ForegroundColor DarkGray
