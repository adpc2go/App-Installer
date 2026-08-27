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
    [string]$Source   = (Split-Path $PSScriptRoot -Parent),
    [string]$CredPath = "$env:LOCALAPPDATA\AppLab\guest.cred.xml",
    [switch]$NoRevert
)

$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()
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

if ($Mode -eq 'Local') {
    Write-Host 'pushing working tree ...' -NoNewline
    Invoke-Command $s { Remove-Item 'C:\Lab\src' -Recurse -Force -ErrorAction SilentlyContinue
                        New-Item -ItemType Directory -Force -Path 'C:\Lab\src' | Out-Null }
    foreach ($d in 'server','packages','tools','tests') {
        $p = Join-Path $Source $d
        if (Test-Path $p) { Copy-Item $p -Destination 'C:\Lab\src' -ToSession $s -Recurse -Force }
    }
    Write-Host " done ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s)"
    $launch = "& '$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File 'C:\Lab\src\server\AppDeploy.ps1' -BaseUrl '$BaseUrl'"
} else {
    $launch = "& '$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -Command `"irm $BaseUrl/go | iex`""
}

# PowerShell Direct lands in session 0, where a WPF window exists but is drawn on a desktop
# nobody can see. A scheduled task with an interactive principal runs in the signed-in
# session instead, which is the only way the GUI actually appears.
Invoke-Command -Session $s -ArgumentList $launch, $cred.UserName -ScriptBlock {
    param($cmd, $user)
    New-Item -ItemType Directory -Force -Path 'C:\Lab' | Out-Null
    Set-Content -Path 'C:\Lab\run.ps1' -Value $cmd -Encoding UTF8
    Unregister-ScheduledTask -TaskName 'LabRun' -Confirm:$false -ErrorAction SilentlyContinue
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Lab\run.ps1'
    $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'LabRun' -Action $a -Principal $p | Out-Null
    Start-ScheduledTask -TaskName 'LabRun'
}
Remove-PSSession $s

vmconnect.exe localhost $VMName
Write-Host ("ready in {0:0.0}s  [{1}]" -f $sw.Elapsed.TotalSeconds, $Mode) -ForegroundColor Green
