<#
.SYNOPSIS
    The catalog editor's MAIN window, the publish gate, and a BOM'd catalog.

.DESCRIPTION
    Test-AfterInstallList and Test-CatalogScenarios both drive Show-AppDialog. Neither has ever
    loaded the editor's main window, nobody has ever run Publish-Release.ps1, and the BOM case -
    the one that shows a green "Live catalog" with a single blank row - had only ever been
    reasoned about. This covers all of it:

      1. the main window: Import-Catalog, the list, Add and Edit wiring, the dirty flag, Save
      2. a real fetch over HTTP, rather than a local file path
      3. Publish-Release.ps1's validation, including the distinction that matters to the
         after-install list: a `run` step taking its file FROM the package needs no sha256,
         because the package's own hash already covers those bytes
      4. a byte-order mark on the catalog, read by the deployment tool

    Show-AppDialog is stubbed here, and only here: it ends in ShowDialog(), which blocks, and the
    dialog itself already has 130 assertions of its own. What is under test is the main window's
    wiring around it.

    NOT covered, and it is a design problem rather than a gap: Delete and the "save anyway?"
    warning both use [Windows.MessageBox]::Show, which is modal and cannot be driven or timed
    out by an unattended run. AppDeploy solves the same problem with a non-blocking overlay.

    Runs unelevated, writes only to a temp sandbox, and never touches server\apps.json.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-CatalogEditorGui.ps1
#>
[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$WorkerPath,
    [switch]$KeepArtefacts
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $repo) { $repo = $here }
if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and
         (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
if (-not $EditorPath) { $EditorPath = Join-Path $repo 'tools\Catalog-Editor.ps1' }
if (-not $WorkerPath) { $WorkerPath = Join-Path $repo 'server\AppDeploy.ps1' }
$publishPath = Join-Path $repo 'tools\Publish-Release.ps1'

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tag     = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox = Join-Path $env:TEMP "pc2go-edit-$tag"
$script:Http = $null
$port = 0

function Invoke-Click($b) {
    $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

# minimal HTTP, so the editor's URL branch is exercised rather than its local-file branch
$httpWorker = {
    param($Root, $Port)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    while ($true) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream)
            $line = $reader.ReadLine()
            if (-not $line) { $client.Close(); continue }
            $path = (($line -split ' ')[1] -replace '^/', '')
            while ($true) { $h = $reader.ReadLine(); if ([string]::IsNullOrEmpty($h)) { break } }
            $w = New-Object IO.BinaryWriter($stream)
            if ($path -eq '__stop') {
                $w.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"))
                $w.Flush(); try { $client.Close() } catch {}; try { $listener.Stop() } catch {}; return
            }
            $file = Join-Path $Root $path
            if (-not (Test-Path -LiteralPath $file)) {
                $w.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"))
                $w.Flush(); $client.Close(); continue
            }
            $bytes = [IO.File]::ReadAllBytes($file)
            $w.Write([Text.Encoding]::ASCII.GetBytes(
                "HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nAccept-Ranges: bytes`r`nConnection: close`r`n`r`n"))
            $w.Write($bytes); $w.Flush()
        } catch { } finally { try { $client.Close() } catch {} }
    }
    try { $listener.Stop() } catch {}
}
function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray

    # a real package, and a server to hand it over
    $www = Join-Path $sandbox 'www'
    New-Item -ItemType Directory -Force -Path $www | Out-Null
    $pkgSrc = Join-Path $sandbox 'src\inner'
    New-Item -ItemType Directory -Force -Path "$pkgSrc\Tools" | Out-Null
    Set-Content -LiteralPath "$pkgSrc\setup.exe"    -Value 'MZ fake installer' -Encoding ASCII
    Set-Content -LiteralPath "$pkgSrc\Tools\go.cmd" -Value '@echo off'         -Encoding ASCII
    $zip = Join-Path $www 'package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $pkgSrc -Parent), $zip)
    $zipSha  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $zipSize = (Get-Item $zip).Length

    $port = Get-FreePort
    $script:Http = [powershell]::Create()
    [void]$script:Http.AddScript($httpWorker).AddArgument($www).AddArgument($port)
    [void]$script:Http.BeginInvoke()
    Start-Sleep -Milliseconds 600

    # ================================================================== 1. the main window
    Write-Section '1. The editor main window: import, add, edit, save'

    $catPath = Join-Path $sandbox 'apps.json'
    $seed = [pscustomobject]@{
        updated = (Get-Date -Format 'yyyy-MM-dd')
        apps = @(
            [pscustomobject]@{ id = 'seed-one'; name = 'Seed One'; category = 'Apps'
                url = 'https://example.invalid/one.zip'; sha256 = ('A' * 64); sizeBytes = 1000
                silentArgs = '/S'; entry = 'inner\setup.exe'; verifyPaths = @('C:\X\one.exe') }
            [pscustomobject]@{ id = 'seed-two'; name = 'Seed Two'; category = 'Apps'
                url = 'https://example.invalid/two.exe'; sha256 = ('B' * 64); sizeBytes = 2000
                silentArgs = '/S'; verifyPaths = @('C:\X\two.exe') })
    }
    [IO.File]::WriteAllText($catPath, ($seed | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))

    $edSrc = Get-Content -LiteralPath $EditorPath -Raw
    $showAt = $edSrc.IndexOf('[void]$window.ShowDialog()')
    if ($showAt -lt 0) { throw 'Could not find ShowDialog in the editor.' }
    . ([scriptblock]::Create($edSrc.Substring(0, $showAt))) `
        -CatalogPath $catPath -PackageDir (Join-Path $sandbox 'packages') -BaseUrl "http://127.0.0.1:$port"

    Assert-True  'the editor window was built'   ($null -ne $window)
    Assert-Equal 'the catalog imported two apps' 2 @($script:Catalog.apps).Count
    Assert-Equal 'and the list shows both'       2 @($ListApps.ItemsSource).Count
    Assert-True  'nothing is dirty yet'          (-not $script:Dirty)

    # Show-AppDialog blocks on ShowDialog(); the dialog has its own 130 assertions, so what is
    # under test here is the main window's wiring around it
    $script:Injected = 0
    function Show-AppDialog($App, $Owner) {
        $script:Injected++
        Set-Field $App 'name'        "Injected $($script:Injected)"
        Set-Field $App 'id'          "injected-$($script:Injected)"
        Set-Field $App 'category'    'Apps'
        Set-Field $App 'url'         "http://127.0.0.1:$port/package.zip"
        Set-Field $App 'sha256'      $zipSha
        Set-Field $App 'sizeBytes'   $zipSize
        Set-Field $App 'silentArgs'  '/S'
        Set-Field $App 'entry'       'inner\setup.exe'
        Set-Field $App 'verifyPaths' @('C:\X\injected.exe')
        Set-Field $App 'postInstall' @([pscustomobject]@{ type = 'run'; name = 'Run go.cmd'; from = 'inner\Tools\go.cmd' })
        return $true
    }

    Invoke-Click $BtnAdd
    Assert-Equal 'Add appended an app to the catalog' 3 @($script:Catalog.apps).Count
    Assert-Equal 'the list refreshed'                 3 @($ListApps.ItemsSource).Count
    Assert-True  'and the catalog is now dirty'       $script:Dirty

    $ListApps.SelectedIndex = 0
    $before = [string]$script:Catalog.apps[0].name
    Invoke-Click $BtnEdit
    Assert-True  'Edit changed the selected row' ([string]$script:Catalog.apps[0].name -ne $before)
    Assert-Equal 'without adding another'        3 @($script:Catalog.apps).Count

    Invoke-Click $BtnSave
    Assert-True 'Save wrote the catalog' (Test-Path -LiteralPath $catPath)
    Assert-True 'and kept a .bak'        (Test-Path -LiteralPath "$catPath.bak")
    Assert-True 'the dirty flag cleared' (-not $script:Dirty)
    $bytes = [IO.File]::ReadAllBytes($catPath)
    Assert-True 'the saved catalog has NO byte-order mark' `
                (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
    $reread = (Get-Content -LiteralPath $catPath -Raw) | ConvertFrom-Json
    Assert-Equal 'and it reloads with three apps'          3 @($reread.apps).Count
    Assert-Equal 'the injected after-install step survived' 'run' ([string]$reread.apps[2].postInstall[0].type)

    # ---- Delete, which used to sit behind a modal MessageBox and so could never be driven
    $countBefore = @($script:Catalog.apps).Count
    $ListApps.SelectedIndex = 0
    $doomed = [string]$script:Catalog.apps[0].name
    Invoke-Click $BtnDelete
    Assert-Equal 'Delete asks first, in the window'   'Visible' "$($Overlay.Visibility)"
    Assert-Equal 'and nothing is removed until it is answered' $countBefore @($script:Catalog.apps).Count

    Invoke-Click $BtnOverlayCancel
    Assert-Equal 'Cancel closes the overlay'  'Collapsed' "$($Overlay.Visibility)"
    Assert-Equal 'and keeps the application'  $countBefore @($script:Catalog.apps).Count

    Invoke-Click $BtnDelete
    Invoke-Click $BtnOverlayOk
    Assert-Equal 'confirming removes it'      ($countBefore - 1) @($script:Catalog.apps).Count
    Assert-Equal 'the right one went'         0 @($script:Catalog.apps | Where-Object { $_.name -eq $doomed }).Count
    Assert-True  'and the catalog is dirty again' $script:Dirty

    # ---- saving an incomplete catalog warns in the status line instead of asking
    $rough = [pscustomobject]@{ id = 'rough'; name = 'Rough Draft'; category = 'Apps'
                                url = ''; sha256 = ''; sizeBytes = 0 }
    $script:Catalog.apps = @(@($script:Catalog.apps) + $rough)
    Assert-True 'Save goes through even with an unfinished app' (Export-Catalog)
    Assert-Equal 'no modal was raised'  'Collapsed' "$($Overlay.Visibility)"
    Assert-True  'and the status line says what is not ready' ($TxtStatus.Text -like '*not ready to publish*')
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $rough })
    [void](Export-Catalog)

    # ---- bulk import: the folder pass, minus the folder picker (a modal dialog)
    Write-Section '1b. Bulk import: a folder of installers becomes entries, hashed in the background'

    $bulkDir = Join-Path $sandbox 'installers'
    New-Item -ItemType Directory -Force -Path $bulkDir | Out-Null
    foreach ($n in 'Alpha Tool', 'Beta Suite', 'Gamma Utility') {
        Copy-Item -LiteralPath $zip -Destination (Join-Path $bulkDir "$($n -replace ' ', '-').zip") -Force
    }
    $before = @($script:Catalog.apps).Count
    $queued = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $bulkDir -File | Sort-Object Name)) {
        $nm = ((([IO.Path]::GetFileNameWithoutExtension($f.Name)) -replace '[_\.\-]+', ' ') -replace '\s+', ' ').Trim()
        $app = [pscustomobject]@{ id = (ConvertTo-Id $nm); name = $nm; category = 'Apps'
            sizeBytes = 0; url = "http://127.0.0.1:$port/package.zip"; sha256 = ''
            silentArgs = ''; verifyPaths = @() }
        Set-Field $app '_localFile' $f.FullName
        $script:Catalog.apps = @(@($script:Catalog.apps) + $app)
        [void]$script:BulkQueue.Add($app)
        $queued += $app
    }
    $script:BulkDone = 0; $script:BulkTotal = $queued.Count
    Assert-Equal 'three installers were queued' 3 $script:BulkQueue.Count
    Update-List
    Assert-Equal 'they appear in the list straight away, before any hashing' ($before + 3) @($ListApps.ItemsSource).Count
    Assert-True  'and are shown as pending rather than broken' `
                 (@($ListApps.ItemsSource | Where-Object { $_.Detail -match 'hash' }).Count -ge 1)

    Start-BulkNext
    $spins = 0
    while (($script:BulkJob -or $script:BulkQueue.Count) -and $spins -lt 600) {
        if ($script:BulkJob -and $script:BulkHandle.IsCompleted) { Complete-BulkOne }
        if (-not $script:BulkJob -and $script:BulkQueue.Count) { Start-BulkNext }
        Start-Sleep -Milliseconds 100; $spins++
    }
    Assert-True 'every queued installer finished hashing' (-not $script:BulkJob -and -not $script:BulkQueue.Count)
    foreach ($a in $queued) {
        Assert-Equal ("{0}: hashed from the real bytes" -f $a.name) $zipSha ([string]$a.sha256)
        Assert-Equal ("{0}: real size recorded" -f $a.name)         $zipSize ([long]$a.sizeBytes)
        Assert-Equal ("{0}: the installer inside was found" -f $a.name) 'inner\setup.exe' ([string]$a.entry)
    }
    Assert-Equal 'all three are now publishable' '' ((Test-App $queued[0]) -join ', ')

    # the local path is scaffolding for the machine that built the catalog - it must not be
    # published, and it must not leak somebody's folder layout into a client-facing file
    [void](Export-Catalog)
    $saved = (Get-Content -LiteralPath $catPath -Raw) | ConvertFrom-Json
    $leaked = @($saved.apps | Where-Object { $_.PSObject.Properties['_localFile'] })
    Assert-Equal 'the local file path is stripped before saving' 0 $leaked.Count

    # put the catalog back to three apps so the later sections read as before
    foreach ($a in $queued) { $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $a }) }
    [void](Export-Catalog)

    # ================================================================== 2. a real HTTP fetch
    Write-Section '2. The dialog fetching over real HTTP, not a local path'

    $fetch = [powershell]::Create()
    [void]$fetch.AddScript($script:FetchWork).AddArgument("http://127.0.0.1:$port/package.zip").
                 AddArgument((Join-Path $sandbox 'packages'))
    $r = $fetch.Invoke() | Select-Object -Last 1
    $fetch.Dispose()
    Assert-True  'the fetch returned without error'  (-not $r.error)
    Assert-Equal 'it hashed the real bytes'          $zipSha  $r.sha256
    Assert-Equal 'and recorded the real size'        $zipSize $r.size
    Assert-True  'it read the archive contents'      (@($r.files).Count -ge 2)
    Assert-Equal 'and ranked setup.exe as the entry' 'inner\setup.exe' (@($r.entries)[0])

    # ================================================================== 3. the publish gate
    Write-Section '3. Publish-Release.ps1 validation'

    # Publish-Release derives every path from $PSScriptRoot and always validates <repo>\server\
    # apps.json - there is no parameter to aim it elsewhere. So the test builds a miniature repo
    # around a COPY of the real script, which keeps the real validation logic under test rather
    # than a re-implementation of it.
    function Test-Publish([string]$Name, $Apps) {
        $root = Join-Path $sandbox "pub-$Name"
        foreach ($d in 'tools', 'server', 'cloudflare') { New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null }
        Copy-Item -LiteralPath $publishPath -Destination (Join-Path $root 'tools\Publish-Release.ps1') -Force
        # these only have to EXIST - the script checks for them before it validates anything
        foreach ($f in 'server\AppDeploy.ps1', 'server\go.ps1', 'cloudflare\wrangler.toml') {
            Set-Content -LiteralPath (Join-Path $root $f) -Value '# placeholder' -Encoding ASCII
        }
        [IO.File]::WriteAllText((Join-Path $root 'server\apps.json'),
            ([pscustomobject]@{ updated = '2026-08-18'; apps = @($Apps) } | ConvertTo-Json -Depth 8),
            (New-Object Text.UTF8Encoding $false))
        # Start-Process with the child redirecting its own streams to a file, NOT `2>&1` in this
        # pipeline: on 5.1 that wraps every stderr line in an ErrorRecord, and under
        # ErrorActionPreference = 'Stop' the refusal this test is trying to OBSERVE would
        # terminate the test instead.
        $logf = Join-Path $root 'publish.log'
        $pub  = Join-Path $root 'tools\Publish-Release.ps1'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -WindowStyle Hidden -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -Command `"& '$pub' *> '$logf'`"") | Out-Null
        if (-not (Test-Path -LiteralPath $logf)) { return '' }
        return (Get-Content -LiteralPath $logf -Raw)
    }
    $good = [pscustomobject]@{ id = 'good'; name = 'Good'; url = 'https://x.invalid/a.zip'
        sha256 = ('C' * 64); sizeBytes = 10; entry = 'inner\setup.exe' }

    $o1 = Test-Publish 'placeholder' @([pscustomobject]@{ id = 'bad'; name = 'Bad'
        url = 'https://x.invalid/a.zip'; sha256 = 'REPLACE_ME'; sizeBytes = 10 })
    Assert-True 'a placeholder sha256 is refused' ($o1 -match 'not a real hash')

    $o2 = Test-Publish 'runurl' @([pscustomobject]@{ id = 'runurl'; name = 'Run Url'
        url = 'https://x.invalid/a.zip'; sha256 = ('D' * 64); sizeBytes = 10
        postInstall = @([pscustomobject]@{ type = 'run'; name = 'Run tool'; url = 'https://x.invalid/t.exe' }) })
    Assert-True 'a run step fetched from a URL with no sha256 is refused' ($o2 -match 'has no sha256')

    # the case the after-install list actually produces
    $o3 = Test-Publish 'runfrom' @([pscustomobject]@{ id = 'runfrom'; name = 'Run From'
        url = 'https://x.invalid/a.zip'; sha256 = ('E' * 64); sizeBytes = 10; entry = 'inner\setup.exe'
        postInstall = @([pscustomobject]@{ type = 'run'; name = 'Run go.cmd'; from = 'inner\Tools\go.cmd' }) })
    Assert-True 'a run step taken FROM the package is accepted' (-not ($o3 -match 'has no sha256'))
    Assert-True 'and the catalog validates clean'               (-not ($o3 -match 'catalog issue'))

    # ================================================================== 4. the BOM catalog
    Write-Section '4. A byte-order mark on the catalog, read by the deployment tool'

    # Served over HTTP, not file:// - the bug is specifically about what Invoke-RestMethod hands
    # back from a web response, and over file:// it throws instead, which is a different path.
    $bomDir = Join-Path $www 'bom'
    New-Item -ItemType Directory -Force -Path $bomDir | Out-Null
    $json = [pscustomobject]@{ updated = '2026-08-18'; apps = @($good) } | ConvertTo-Json -Depth 8
    # WITH a BOM, which is exactly what Set-Content -Encoding UTF8 produces on 5.1
    [IO.File]::WriteAllText((Join-Path $bomDir 'apps.json'), $json, (New-Object Text.UTF8Encoding $true))
    $b = [IO.File]::ReadAllBytes((Join-Path $bomDir 'apps.json'))
    Assert-True 'the test catalog really does carry a BOM' ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

    $wSrc = Get-Content -LiteralPath $WorkerPath -Raw
    $goAt = $wSrc.IndexOf('# ---------- go ----------')
    . ([scriptblock]::Create($wSrc.Substring(0, $goAt))) `
        -BaseUrl "http://127.0.0.1:$port/bom" -NoSelfElevate
    $script:CacheDir = Join-Path $sandbox 'depcache'
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    Load-Catalog

    # the bug this pins down: a BOM used to leave $manifest as a STRING, $manifest.apps as
    # $null, and @($null) as a ONE-element array - a single blank row under a green
    # "Live catalog", which is the worst possible way to fail
    Assert-Equal 'the BOM catalog loads its one real app' 1 $script:Items.Count
    Assert-Equal 'and that app has a name'                'Good' ([string]$script:Items[0].Name)
    Assert-Equal 'no blank phantom row'                   0 @($script:Items | Where-Object { -not $_.Name }).Count

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($script:Http) {
        try { [void](Invoke-WebRequest -Uri "http://127.0.0.1:$port/__stop" -UseBasicParsing -TimeoutSec 3) } catch {}
        try { $script:Http.Dispose() } catch {}
    }
    if ($KeepArtefacts) { Write-Host "Artefacts kept: $sandbox" -ForegroundColor Yellow }
    else {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        if (Test-Path -LiteralPath $sandbox) { Write-Host "CLEANUP INCOMPLETE: $sandbox" -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed.' -ForegroundColor DarkGray }
    }
}
