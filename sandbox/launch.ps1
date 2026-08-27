#requires -Version 5.1
<#
  Runs inside Windows Sandbox via the .wsb LogonCommand.
  The sandbox user (WDAGUtilityAccount) is already a local administrator, so
  AppDeploy's self-elevation completes without a credential prompt.
#>
param(
    [ValidateSet('Live','Local')] [string]$Mode = 'Live',
    [string]$BaseUrl = 'https://apps.pc2go.ca',
    [string]$Mapped  = 'C:\Users\WDAGUtilityAccount\Desktop\App-Installer'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }

# LogonCommand fires before the sandbox NIC has a usable route. Without this wait the first
# run of every session dies on a DNS failure, which from the GUI is indistinguishable from
# the tool itself being broken.
$host_ = ([uri]$BaseUrl).Host
$deadline = (Get-Date).AddSeconds(60)
$online = $false
while ((Get-Date) -lt $deadline) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect($host_, 443); $c.Close()
        $online = $true; break
    } catch { Start-Sleep -Milliseconds 400 }
}
if (-not $online) { Write-Host "No route to $host_ after 60s - launching anyway." -ForegroundColor Yellow }

$winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Mode -eq 'Live') {
    # Exactly what a technician pastes on a client machine - exercises the bootstrap,
    # the hash pin and the R2 download, not just the GUI.
    & $winPS -NoProfile -ExecutionPolicy Bypass -Command "irm $BaseUrl/go | iex"
}
else {
    # Working-tree code, no publish step. The mapped folder is read-only, so copy out
    # first: AppDeploy writes its cache beside wherever it was started from.
    $src = Join-Path $Mapped 'server\AppDeploy.ps1'
    if (-not (Test-Path -LiteralPath $src)) { throw "Not found: $src (is the folder mapped?)" }
    $dir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir 'AppDeploy.ps1'
    Copy-Item -LiteralPath $src -Destination $dst -Force
    & $winPS -NoProfile -ExecutionPolicy Bypass -File $dst -BaseUrl $BaseUrl
}
