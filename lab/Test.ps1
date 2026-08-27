#requires -Version 5.1
<#
  THE LOOP. This is the only script you run day to day.

    .\Test.ps1              push the working tree, run it from local source
    .\Test.ps1 -Mode Live   ignore local source, run the published irm one-liner
    .\Test.ps1 -NoRevert    keep the current guest state (inspect a failure before wiping)

  Revert -> resume -> push code -> launch GUI, in about ten seconds. The host is never
  rebooted; the guest never keeps anything from the previous run.
#>
[CmdletBinding()]
param(
    [string]$VMName   = 'AppLab',
    [string]$Checkpoint = 'CLEAN',
    [ValidateSet('Local','Live')] [string]$Mode = 'Local',
    [string]$BaseUrl  = 'https://apps.pc2go.ca',
    [string]$Source,
    [string]$CredPath = "$env:LOCALAPPDATA\$VMName\guest.cred.xml",
    [int]$LogWait  = 6,
    [switch]$NoLaunch,
    [switch]$NoRevert
)

$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()

# $PSScriptRoot is not reliably populated while param() defaults are evaluated, which left
# -Source empty and failed before anything ran. Resolve it here, with a fallback for the
# invocation styles where even that is blank.
if (-not $Source) {
    $here = if ($PSScriptRoot) { $PSScriptRoot }
            elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
            else { (Get-Location).Path }
    $Source = Split-Path -Parent $here
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'server'))) {
    throw "Source '$Source' has no server\ folder - pass -Source <App-Installer root>."
}
if (-not (Test-Path $CredPath)) { throw "No stored credential. Run 3-Set-Baseline.ps1 first." }
$cred = Import-Clixml $CredPath

if (-not $NoRevert) {
    Write-Host "reverting to '$Checkpoint' ..." -NoNewline
    Stop-VM $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    # Discards everything since the checkpoint, so the differencing disk resets instead of
    # growing a little more with every test run.
    Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
    Write-Host " done ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"
}
# Do NOT touch video hardware here. A Standard checkpoint's saved memory image is bound to
# the device configuration it was taken with, so changing resolution makes the restore fail
# with "Microsoft Video Monitor ... Catastrophic failure". Resolution belongs to Enhanced
# Session (negotiated over RDP), not to the VM's video device.
if ((Get-VM $VMName).State -ne 'Running') { Start-VM $VMName }

# The guest is resuming from saved memory, so this normally succeeds on the first or
# second attempt. Retrying beats a fixed sleep, which is either too short or wasted time.
Write-Host 'waiting for guest ...' -NoNewline
$deadline = (Get-Date).AddSeconds(120); $s = $null
while ((Get-Date) -lt $deadline) {
    try { $s = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
}
if (-not $s) { throw "Guest did not answer PowerShell Direct within 120s." }
Write-Host " up ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"

# Wipe and boot, but run nothing - for editing the baseline by hand before .\Save-Baseline.ps1
if ($NoLaunch) {
    Write-Host ("clean VM up in {0:0.0}s - nothing launched" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Remove-PSSession $s
    Get-Process vmconnect -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "*$VMName*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process vmconnect.exe -ArgumentList 'localhost', $VMName
    return
}

if ($Mode -eq 'Local') {
    Write-Host 'pushing working tree ...' -NoNewline
    Invoke-Command $s { Remove-Item 'C:\Lab\src' -Recurse -Force -ErrorAction SilentlyContinue
                        New-Item -ItemType Directory -Force -Path 'C:\Lab\src' | Out-Null }
    foreach ($d in 'server','packages','tools','tests') {
        $p = Join-Path $Source $d
        if (Test-Path $p) { Copy-Item $p -Destination 'C:\Lab\src' -ToSession $s -Recurse -Force }
    }
    Write-Host " done ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"
    # run.ps1 is already Windows PowerShell 5.1, so call the script directly. The nested
    # powershell.exe this used to spawn printed its error to a console of its own, where
    # the transcript below could never capture it.
    $launch = "& 'C:\Lab\src\server\AppDeploy.ps1' -BaseUrl '$BaseUrl'"
} else {
    $launch = "irm $BaseUrl/go | iex"
}

# PowerShell Direct lands in session 0, where a WPF window exists but is drawn on a desktop
# nobody can see. A scheduled task with an interactive principal runs in the signed-in
# session instead, which is the only way the GUI actually appears.
Invoke-Command -Session $s -ArgumentList $launch, $cred.UserName -ScriptBlock {
    param($cmd, $user)
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
    # Wrapped in a transcript so anything the tool writes - including the exception that
    # kills it - lands in a file the host can read, not only on the guest's screen.
    $body = @"
`$Host.UI.RawUI.BackgroundColor = 'Black'
`$Host.UI.RawUI.ForegroundColor = 'Gray'
Clear-Host
Start-Transcript -Path 'C:\Lab\run.log' -Force | Out-Null
`$ErrorActionPreference = 'Continue'
try { $cmd } catch { Write-Host ('LAUNCH ERROR: ' + `$_.Exception.ToString()) }
Stop-Transcript | Out-Null
"@
    Set-Content -Path 'C:\Lab\run.ps1' -Value $body -Encoding UTF8
    Remove-Item 'C:\Lab\run.log' -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'LabRun' -Confirm:$false -ErrorAction SilentlyContinue
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\run.ps1'
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'LabRun' -Action $a -Principal $p | Out-Null
    Start-ScheduledTask -TaskName 'LabRun'
}
Remove-PSSession $s

Write-Host ("ready in {0:0.0}s  [{1}]" -f $sw.Elapsed.TotalSeconds, $Mode) -ForegroundColor Green

# Give the tool a moment, then pull its transcript back. A guest-side failure is otherwise
# invisible from here: the window it printed to is inside the VM.
Start-Sleep -Seconds $LogWait
try {
    $s2 = New-PSSession -VMName $VMName -Credential $cred
    $log = Invoke-Command $s2 { Get-Content 'C:\Lab\run.log' -Raw -ErrorAction SilentlyContinue }
    Remove-PSSession $s2
    if (-not $log) { Write-Host 'guest transcript empty - tool may still be starting' -ForegroundColor DarkGray }
    elseif ($log -match 'LAUNCH ERROR|FullyQualifiedErrorId|Exception') {
        Write-Host '--- guest reported an error ---' -ForegroundColor Yellow
        Write-Host $log
    } else { Write-Host 'guest transcript clean (.\Get-LabLog.ps1 to read it)' -ForegroundColor DarkGray }
} catch { Write-Host "could not read guest log: $($_.Exception.Message)" -ForegroundColor DarkGray }

# Called directly, vmconnect holds the calling shell until its window is closed - which
# makes every run look like a hang and blocks the terminal you launched it from.
# Stale windows pile up otherwise, one per run, and an old one keeps stealing focus. Match
# on the window title so a second lab VM - or a Windows installer running in one - is not
# closed out from under you.
Get-Process vmconnect -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "*$VMName*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName
