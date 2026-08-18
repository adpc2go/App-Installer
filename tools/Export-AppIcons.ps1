<#
  Extracts the real product icon out of each installer (or installed exe) and writes
  PNGs named after the catalog id, ready to upload to  <server>/icons/.

  No internet involved: the icons come out of the binaries you already have.

  Usage:
    .\Export-AppIcons.ps1 -SourceDir D:\Installers -OutDir D:\icons

  It matches each catalog entry to a file in -SourceDir by the filename in its "url",
  and falls back to the app's verifyPaths (an installed copy) when the installer is
  missing or only carries a generic setup icon.

    .\Export-AppIcons.ps1 -SourceDir D:\Installers -OutDir D:\icons -UseInstalled
#>
[CmdletBinding()]
param(
    [string]$Manifest = (Join-Path $PSScriptRoot '..\server\apps.json'),
    [string]$SourceDir = '',
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$UseInstalled,
    [int]$Size = 256
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# SHDefExtractIcon reaches the large (up to 256px) icon; ExtractAssociatedIcon is
# capped at 32px and looks soft on a modern display.
Add-Type -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SHDefExtractIconW(string pszIconFile, int iIndex, uint uFlags,
    out System.IntPtr phiconLarge, out System.IntPtr phiconSmall, uint nIconSize);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@ -Namespace Native -Name IconExtract

function Save-Icon([string]$Source, [string]$Destination, [int]$Px) {
    $big = [IntPtr]::Zero; $small = [IntPtr]::Zero
    try {
        $rc = [Native.IconExtract]::SHDefExtractIconW($Source, 0, 0, [ref]$big, [ref]$small, [uint32]$Px)
        if ($rc -eq 0 -and $big -ne [IntPtr]::Zero) {
            $ico = [System.Drawing.Icon]::FromHandle($big)
            $bmp = $ico.ToBitmap()
            $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose(); $ico.Dispose()
            return $true
        }
    } catch {
    } finally {
        if ($big -ne [IntPtr]::Zero) { [void][Native.IconExtract]::DestroyIcon($big) }
        if ($small -ne [IntPtr]::Zero) { [void][Native.IconExtract]::DestroyIcon($small) }
    }
    # fallback: 32px is better than nothing
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Source)
        if ($ico) {
            $bmp = $ico.ToBitmap()
            $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose(); $ico.Dispose()
            return $true
        }
    } catch {}
    return $false
}

if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest not found: $Manifest" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$catalog = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json

$done = 0; $missing = @()
foreach ($app in @($catalog.apps)) {
    $id = [string]$app.id
    $out = Join-Path $OutDir "$id.png"
    $source = $null

    if ($SourceDir) {
        $leaf = [IO.Path]::GetFileName(([Uri]$app.url).LocalPath)
        $candidate = Join-Path $SourceDir $leaf
        if (Test-Path -LiteralPath $candidate) { $source = $candidate }
        else {
            # installers are often nested one folder deep in a deployment package
            $hit = Get-ChildItem -LiteralPath $SourceDir -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { $source = $hit.FullName }
        }
    }

    if ($UseInstalled -or -not $source) {
        foreach ($vp in @($app.verifyPaths)) {
            $p = [Environment]::ExpandEnvironmentVariables([string]$vp)
            # an installed exe carries the true product logo; a bootstrapper often
            # only has a generic setup icon, so prefer this when it exists
            if (Test-Path -LiteralPath $p) { $source = $p; break }
        }
    }

    if (-not $source) { $missing += "$id  (no installer in -SourceDir, not installed here)"; continue }
    if (Save-Icon $source $out $Size) {
        Write-Output ("OK    {0,-22} <- {1}" -f $id, (Split-Path $source -Leaf))
        $done++
    } else {
        $missing += "$id  (icon extraction failed from $source)"
    }
}

Write-Output ''
Write-Output "$done icon(s) written to $OutDir"
if ($missing.Count) {
    Write-Output ''
    Write-Output 'Needs attention:'
    $missing | ForEach-Object { Write-Output "  $_" }
}
Write-Output ''
Write-Output "Upload the folder to your server as  /icons/  so the URLs in apps.json resolve."
