# Generates a ready-to-paste apps.json entry for an installer file.
# Usage:  .\New-AppEntry.ps1 -File C:\files\7z2408-x64.exe -Id 7zip -Name "7-Zip" -Version 24.08 `
#                            -Url https://apps.example.com/files/7z2408-x64.exe -SilentArgs /S `
#                            -VerifyPaths '%ProgramFiles%\7-Zip\7z.exe'
param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Url,
    [string]$SilentArgs = '',
    [string[]]$VerifyPaths = @()
)
$f = Get-Item -LiteralPath $File
[ordered]@{
    id          = $Id
    name        = $Name
    version     = $Version
    sizeBytes   = $f.Length
    url         = $Url
    sha256      = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    silentArgs  = $SilentArgs
    verifyPaths = $VerifyPaths
} | ConvertTo-Json
