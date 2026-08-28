<#
.SYNOPSIS
    Re-copies tools\Installer-Family.ps1 into the marked region of server\AppDeploy.ps1.

.DESCRIPTION
    The detector has ONE source. The client cannot load a second file (go.ps1 pins exactly one
    script), so a verbatim copy lives between two marker comments in AppDeploy.ps1 and the
    elevated worker receives it rendered from those functions at Start-Worker. Edit the source,
    run this, and Test-InstallerFamily.ps1 section 6b proves the two are equal.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$adPath = Join-Path $repo 'server\AppDeploy.ps1'
$fam = [IO.File]::ReadAllText((Join-Path $repo 'tools\Installer-Family.ps1'))
$nl = "`r`n"
$fam = ($fam -replace "`r?`n", $nl).TrimEnd() + $nl
$ad = [IO.File]::ReadAllText($adPath)
$m = [regex]::Match($ad, '(?s)(# ---- begin tools\\Installer-Family\.ps1[^\r\n]*\r?\n[^\r\n]*\r?\n)(.*?)(# ---- end tools\\Installer-Family\.ps1)')
if (-not $m.Success) { throw "the marked region was not found in $adPath" }
$new = $ad.Substring(0, $m.Groups[2].Index) + $fam + $ad.Substring($m.Groups[2].Index + $m.Groups[2].Length)
# the function list the renderer walks has to match the file too
$names = @([regex]::Matches($fam, '(?m)^function\s+([A-Za-z][\w-]*)') | ForEach-Object { $_.Groups[1].Value })
$listLine = '$script:InstallerFamilyFunctions = @(' + (($names | ForEach-Object { "'" + $_ + "'" }) -join ', ') + ')'
$new = [regex]::Replace($new, '(?m)^\$script:InstallerFamilyFunctions = @\(.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $listLine })
[IO.File]::WriteAllText($adPath, $new, (New-Object Text.UTF8Encoding $true))
$t = $null; $e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($adPath, [ref]$t, [ref]$e)
if ($e.Count) { throw "AppDeploy.ps1 no longer parses: $($e[0].Message) at line $($e[0].Extent.StartLineNumber)" }
Write-Host "synced $($names.Count) function(s) into $adPath" -ForegroundColor Green
