# Dumps the character codes behind the mangled names so we can see WHAT the
# invisible characters actually are, instead of inferring from a screenshot.
# Run:  powershell -NoP -EP Bypass -File tools\Show-BadName.ps1

foreach ($p in @(Get-AppxPackage | Where-Object { $_.Name -like '*Xbox*' })) {
    Write-Output "=== package: $($p.Name)"

    $names = @{}
    try {
        foreach ($sa in @(Get-StartApps -ErrorAction Stop)) {
            $fam = ('' + $sa.AppID).Split('!')[0]
            if ($fam -eq $p.PackageFamilyName) { $names['StartApps'] = $sa.Name }
        }
    } catch { Write-Output "  Get-StartApps failed: $($_.Exception.Message)" }

    try {
        $mx = Get-AppxPackageManifest -Package $p.PackageFullName -ErrorAction Stop
        $names['Properties.DisplayName'] = $mx.Package.Properties.DisplayName
        $ve = $mx.Package.Applications.Application.VisualElements
        $names['VisualElements.DisplayName'] = $ve.DisplayName
        Write-Output "  Application node count: $(@($mx.Package.Applications.Application).Count)"
    } catch { Write-Output "  manifest read failed: $($_.Exception.Message)" }

    foreach ($k in $names.Keys) {
        $v = $names[$k]
        $type = if ($null -eq $v) { 'null' } else { $v.GetType().FullName }
        Write-Output "  [$k] type=$type"
        $text = if ($v -is [string]) { $v } else { ('' + $v) }
        Write-Output "     text  : '$text'"
        $codes = ($text.ToCharArray() | Select-Object -First 24 | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' '
        Write-Output "     chars : $codes"
    }
    Write-Output ''
}
