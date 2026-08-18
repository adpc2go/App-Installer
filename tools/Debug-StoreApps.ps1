# Prints what the Uninstall > Microsoft Store apps list is actually being fed,
# so we can see the real strings instead of guessing from a screenshot.
# Run:  powershell -NoP -EP Bypass -File tools\Debug-StoreApps.ps1

$startNames = @{}
try {
    foreach ($sa in @(Get-StartApps -ErrorAction Stop)) {
        $fam = ('' + $sa.AppID).Split('!')[0]
        if ($fam -and -not $startNames.ContainsKey($fam)) { $startNames[$fam] = $sa.Name }
    }
    Write-Output "Get-StartApps: OK, $($startNames.Count) entries"
} catch {
    Write-Output "Get-StartApps: FAILED - $($_.Exception.Message)"
}

$rows = @()
$manifestOk = 0; $manifestFail = 0
foreach ($p in @(Get-AppxPackage)) {
    if ($p.IsFramework) { continue }
    if ($p.NonRemovable) { continue }
    $src = ''; $disp = ''
    $fam = ('' + $p.PackageFamilyName)
    if ($fam -and $startNames.ContainsKey($fam)) { $disp = $startNames[$fam]; $src = 'StartApps' }
    try {
        $mx = Get-AppxPackageManifest -Package $p.PackageFullName -ErrorAction Stop
        $manifestOk++
        if (-not $disp) {
            $raw = '' + $mx.Package.Properties.DisplayName
            if ($raw -and $raw -notlike 'ms-resource:*') { $disp = $raw; $src = 'Manifest' }
            else { $src = "unresolved($raw)" }
        }
    } catch { $manifestFail++ ; if (-not $disp) { $src = 'ManifestDenied' } }
    if (-not $disp) { $disp = '' + $p.Name; if (-not $src) { $src = 'PackageName' } }

    $rows += [pscustomobject]@{
        Shown     = $disp
        Source    = $src
        Publisher = (('' + $p.Publisher) -replace '^CN=([^,]+).*$', '$1')
        Version   = ('' + $p.Version)
        PkgName   = ('' + $p.Name)
    }
}

Write-Output "Manifest readable: $manifestOk    denied/failed: $manifestFail"
Write-Output ''
$rows | Sort-Object Shown | Format-Table Shown, Source, Publisher, Version -AutoSize | Out-String -Width 200
