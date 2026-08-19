# PC2Go bootstrap - served at https://apps.pc2go.ca/go
#
# Universal launch line (works pasted into cmd, Windows PowerShell 5.1, or PowerShell 7):
#   powershell -NoP -EP Bypass -C "irm https://apps.pc2go.ca/go | iex"
# PowerShell-only shorthand:
#   irm https://apps.pc2go.ca/go | iex
#
# This bootstrap runs fine under 5.1 or 7, then always launches the tool with
# Windows PowerShell 5.1 (in-box on Win10/11), where WPF + BITS behave natively.

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }

$winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $winPS)) {
    Write-Host 'Windows PowerShell 5.1 not found - this tool requires Windows 10 or 11.' -ForegroundColor Yellow
    return
}

$BaseUrl = 'https://apps.pc2go.ca'             # <-- your server
$dir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ps1 = Join-Path $dir 'AppDeploy.ps1'

Invoke-WebRequest -Uri "$BaseUrl/AppDeploy.ps1" -OutFile $ps1 -UseBasicParsing

# Integrity pin: after each release, paste the SHA-256 of AppDeploy.ps1 here.
# Defends against tampering of the large script even if only this tiny
# bootstrap is delivered over a trusted channel.
$PinnedHash = '5EAAB1A5567CEF8D0699534A5B0D4E91B6CB167F10ACE6707E7CC8FAF4CA422F'
if ($PinnedHash -ne 'PINNED_SHA256_GOES_HERE') {
    $actual = (Get-FileHash -LiteralPath $ps1 -Algorithm SHA256).Hash
    if ($actual -ne $PinnedHash.ToUpper()) {
        Remove-Item $ps1 -Force
        throw 'AppDeploy.ps1 failed integrity check - aborting.'
    }
}

Start-Process -FilePath $winPS -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -BaseUrl `"$BaseUrl`""
