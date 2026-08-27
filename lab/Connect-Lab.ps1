#requires -Version 5.1
<#
  Connect to the lab with mstsc over the Hyper-V VMBus instead of vmconnect.

    .\Connect-Lab.ps1                      # 1280x1024
    .\Connect-Lab.ps1 -Width 1920 -Height 1080
    .\Connect-Lab.ps1 -FullScreen

  This IS Enhanced Session - vmconnect's enhanced mode is RDP on port 2179 with the VM's
  GUID in the pcb field. Going through mstsc gets the same transport without depending on
  the "Use enhanced session mode" checkbox in Hyper-V Manager, and gives real clipboard
  redirection and host drive access as a side effect.
#>
param(
    [string]$VMName = 'Pro',
    [int]$Width     = 1280,
    [int]$Height    = 1024,
    [switch]$FullScreen,
    [switch]$NoDrives
)
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName
if ($vm.State -ne 'Running') { throw "$VMName is not running - run .\Test.ps1 first." }
$id = $vm.Id.Guid

$rdp = Join-Path $env:LOCALAPPDATA "Home\$VMName.rdp"
New-Item -ItemType Directory -Force -Path (Split-Path $rdp) | Out-Null

# ';EnhancedMode=1' on pcb is what asks the VMBus listener for an enhanced session rather
# than a basic console. Without it this connects, but stays a plain video pipe with no
# clipboard - exactly the mode we are trying to get out of.
$lines = @(
    'full address:s:localhost:2179'
    "pcb:s:$id;EnhancedMode=1"
    'server port:i:2179'
    'negotiate security layer:i:0'
    'authentication level:i:0'
    'enablecredsspsupport:i:0'
    'redirectclipboard:i:1'
    'promptcredentialonce:i:1'
    'audiomode:i:2'
    'session bpp:i:32'
    "screen mode id:i:$(if ($FullScreen) { 2 } else { 1 })"
    "desktopwidth:i:$Width"
    "desktopheight:i:$Height"
    'dynamic resolution:i:1'
    "redirectdrives:i:$(if ($NoDrives) { 0 } else { 1 })"
)
Set-Content -Path $rdp -Value $lines -Encoding ASCII

Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Process mstsc.exe -ArgumentList "`"$rdp`""
Write-Host "connecting to $VMName at ${Width}x${Height} (clipboard on)" -ForegroundColor Green
Write-Host "sign in as the guest account, tick 'Remember me'" -ForegroundColor DarkGray
