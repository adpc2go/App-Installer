<#
  Checks every iconUrl in the catalog and reports which actually return an image.
  Run this, paste the output back, and the broken ones can be replaced with URLs
  that work - rather than guessing twice.

  Usage:  powershell -NoP -EP Bypass -File tools\Test-IconUrls.ps1
          powershell -NoP -EP Bypass -File tools\Test-IconUrls.ps1 -Save D:\icons
#>
[CmdletBinding()]
param(
    [string]$Manifest = (Join-Path $PSScriptRoot '..\server\apps.json'),
    [string]$Save = ''
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch {}

$catalog = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($Save) { New-Item -ItemType Directory -Force -Path $Save | Out-Null }

$ok = 0; $bad = @()
foreach ($app in @($catalog.apps)) {
    $id = [string]$app.id
    $url = [string]$app.iconUrl
    if (-not $url) { $bad += "$id : no iconUrl"; continue }
    try {
        $tmp = [IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 20
        $len = (Get-Item $tmp).Length
        # a real image starts with a known magic number; an error page does not
        $head = [IO.File]::ReadAllBytes($tmp) | Select-Object -First 4
        $sig = ($head | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $isImage = $sig.StartsWith('89504E47') -or $sig.StartsWith('FFD8') -or $sig.StartsWith('00000100') -or $sig.StartsWith('47494638')
        if ($isImage -and $len -gt 200) {
            Write-Output ("OK    {0,-20} {1,8} bytes  {2}" -f $id, $len, $url)
            if ($Save) { Copy-Item $tmp (Join-Path $Save "$id.png") -Force }
            $ok++
        } else {
            $bad += "$id : responded but is not an image (sig $sig, $len bytes)"
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        $bad += "$id : $($_.Exception.Message)"
    }
}

Write-Output ''
Write-Output "$ok of $(@($catalog.apps).Count) icon URLs returned a real image."
if ($bad.Count) {
    Write-Output ''
    Write-Output 'FAILED:'
    $bad | ForEach-Object { Write-Output "  $_" }
}
if ($Save -and $ok) { Write-Output ''; Write-Output "Saved working icons to $Save - upload as /icons/ on your server." }
