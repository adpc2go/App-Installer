<#
.SYNOPSIS
    Downloads small public installers of each family into tests\fixtures\installers, pinned by SHA-256.

.DESCRIPTION
    Real signatures from real vendors, for Test-InstallerFamily.ps1 section 9. The folder is
    git-ignored. A file whose hash does not match its pin is deleted and reported - a fixture that
    silently changed would make the test prove the wrong thing. Run once; re-run to refresh.

    Sha256 = '' means "pin on first download": the hash is printed so it can be written in here.
#>
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
$dir = Join-Path $here 'fixtures\installers'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$fixtures = @(
    @{ File = 'npp.installer.exe';  Url = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7.9/npp.8.7.9.Installer.x64.exe'; Sha256 = 'D3CED3C33D91BC8F09F9DBD315867B09158FA907FDD7454EAEA15E933A32CADA' }
    # aka.ms always serves the CURRENT redistributable, so this one cannot be pinned to bytes;
    # the family (Burn) is what the test needs from it, and that does not change between releases
    @{ File = 'vc_redist.x64.exe';  Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'; Sha256 = '' }
    @{ File = 'git-installer.exe';  Url = 'https://github.com/git-for-windows/git/releases/download/v2.49.0.windows.1/Git-2.49.0-64-bit.exe'; Sha256 = '726056328967F242FE6E9AFBFE7823903A928AFF577DCF6F517F2FB6DA6CE83C' }
)
foreach ($f in $fixtures) {
    $path = Join-Path $dir $f.File
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($f.Sha256 -and $h -ne $f.Sha256.ToUpper()) { Write-Host "  ! $($f.File) does not match its pin - deleting" -ForegroundColor Yellow; Remove-Item -LiteralPath $path -Force }
        else { Write-Host "  + $($f.File) present ($h)" -ForegroundColor Green; continue }
    }
    Write-Host "==> $($f.File) from $($f.Url)" -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $f.Url -OutFile "$path.part" -UseBasicParsing -TimeoutSec 600
        $h = (Get-FileHash -LiteralPath "$path.part" -Algorithm SHA256).Hash
        if ($f.Sha256 -and $h -ne $f.Sha256.ToUpper()) { Remove-Item -LiteralPath "$path.part" -Force; throw "hash $h does not match the pin $($f.Sha256)" }
        Move-Item -LiteralPath "$path.part" -Destination $path -Force
        Write-Host "  + $($f.File)  sha256 $h" -ForegroundColor Green
        if (-not $f.Sha256) { Write-Host '    (write this hash into Get-InstallerFixtures.ps1 to pin it)' -ForegroundColor DarkGray }
    } catch {
        Write-Host "  ! $($f.File): $($_.Exception.Message)" -ForegroundColor Red
    }
}
