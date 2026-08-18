<#
.SYNOPSIS
    Renders the real windows to PNG so somebody can actually LOOK at them.

.DESCRIPTION
    Every harness in this repo asserts on control properties - IsEnabled, Text, Visibility - and
    not one of them has ever rendered a pixel. That leaves a whole class of defect uncovered: a
    section that runs off the bottom of the dialog, a label clipped to "Where it go", white text
    on a white background, a list with no height. All of it passes a property test, and all of it
    is obvious the moment you see it.

    This loads the real XAML, gives it real content, and renders it offscreen with
    RenderTargetBitmap - no window is shown, nothing appears on the desktop, and it needs no
    elevation. The window's CONTENT is rendered rather than the Window itself, because a Window
    refuses to be measured outside a presentation source.

    Renders: the Install tab with apps listed, the Uninstall tab, the Activity Log, and the
    catalog editor's add/edit dialog with a populated after-install list.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Export-UiSnapshots.ps1
#>
[CmdletBinding()]
param(
    [string]$CatalogPath,
    [string]$OutDir,
    [int]$Width  = 1180,
    [int]$Height = 780
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $repo) { $repo = $here }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'pc2go-ui-snapshots' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$sandbox = Join-Path $env:TEMP ("pc2go-ui-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

# Renders an element offscreen. Measure/Arrange/UpdateLayout first, or the visual tree has never
# been realised and the bitmap comes out empty - which looks exactly like a broken layout.
function Save-Visual($Element, [string]$Path, [int]$W, [int]$H) {
    $Element.Measure((New-Object Windows.Size($W, $H)))
    $Element.Arrange((New-Object Windows.Rect(0, 0, $W, $H)))
    $Element.UpdateLayout()
    # let bindings and pending dispatcher work settle before the snapshot
    $frame = New-Object Windows.Threading.DispatcherFrame
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [action]{ $frame.Continue = $false })
    [Windows.Threading.Dispatcher]::PushFrame($frame)

    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Element)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Open($Path, 'Create')
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    Write-Host ("  wrote {0}  ({1} KB)" -f (Split-Path $Path -Leaf), [math]::Round((Get-Item $Path).Length / 1KB)) -ForegroundColor Green
}

try {
    # ============================================================ the deploy GUI
    Write-Host 'Rendering the deployment GUI...' -ForegroundColor Cyan

    $server = Join-Path $sandbox 'catalog'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    $mk = { param($id, $name, $cat, $mb)
        [pscustomobject]@{ id = $id; name = $name; category = $cat
            url = "https://example.invalid/$id.zip"; sha256 = ('A' * 64)
            sizeBytes = ([int64]$mb * 1MB); silentArgs = '/S'; entry = 'inner\setup.exe'
            verifyPaths = @("%ProgramFiles%\$name\$id.exe") } }
    # Your real catalog by default, so the screenshots show YOUR applications rather than names
    # somebody invented. -CatalogPath points it somewhere else; the sample list below is only a
    # fallback for a checkout that has no catalog yet, and is a placeholder to edit, not a rule.
    if (-not $CatalogPath) { $CatalogPath = Join-Path $repo 'server\apps.json' }
    if (Test-Path -LiteralPath $CatalogPath) {
        Copy-Item -LiteralPath $CatalogPath -Destination (Join-Path $server 'apps.json') -Force
        Write-Host "  catalog: $CatalogPath" -ForegroundColor DarkGray
    } else {
        Write-Host "  no catalog at $CatalogPath - using the sample list" -ForegroundColor Yellow
        $catalog = [pscustomobject]@{
            updated = (Get-Date -Format 'yyyy-MM-dd')
            apps = @(
                (& $mk 'sample-large'  'Sample Large Suite'  'Sample'  14200)
                (& $mk 'sample-medium' 'Sample Medium App'   'Sample'   1200)
                (& $mk 'sample-small'  'Sample Small Tool'   'Sample'      2))
        }
        [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ($catalog | ConvertTo-Json -Depth 8),
                                (New-Object Text.UTF8Encoding $false))
    }

    $src = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker.' }
    . ([scriptblock]::Create($src.Substring(0, $goAt))) `
        -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate

    Load-Catalog
    Write-Host ("  catalog: {0} app(s)" -f $script:Items.Count) -ForegroundColor DarkGray
    # a couple ticked, so the selection styling is in the picture too
    if ($script:Items.Count -ge 4) { $script:Items[0].IsSelected = $true; $script:Items[3].IsSelected = $true }
    Save-Visual $window.Content (Join-Path $OutDir '1-install-tab.png') $Width $Height

    Select-Tab 'Un'
    Select-UnTab 'Desktop'
    Write-Host ("  uninstall list: {0} program(s)" -f $script:UnItems.Count) -ForegroundColor DarkGray
    Save-Visual $window.Content (Join-Path $OutDir '2-uninstall-tab.png') $Width $Height

    Select-Tab 'Log'
    Save-Visual $window.Content (Join-Path $OutDir '3-activity-log.png') $Width $Height

    # ============================================================ the catalog editor dialog
    Write-Host 'Rendering the catalog editor dialog...' -ForegroundColor Cyan

    $edSrc = Get-Content -LiteralPath (Join-Path $repo 'tools\Catalog-Editor.ps1') -Raw
    $lines = $edSrc -split "`r?`n"
    $xs = ($lines | Select-String -SimpleMatch '$dialogXaml = @''' | Select-Object -First 1).LineNumber
    $xe = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $xs } | Select-Object -First 1).LineNumber
    $dlgXaml = ($lines[$xs..($xe - 2)] -join "`r`n")

    $dlg = [Windows.Markup.XamlReader]::Parse($dlgXaml)
    $g = { param($n) $dlg.FindName($n) }
    (& $g 'DlgName').Text     = 'Autodesk Revit 2026'
    (& $g 'DlgUrl').Text      = 'https://files.pc2go.ca/packages/revit-2026.zip'
    (& $g 'DlgSilent').Text   = '--silent'
    (& $g 'DlgHashInfo').Text = '13.87 GB   sha256 9F2C41A8B77E0D34...'
    (& $g 'DlgHashInfo').Foreground = '#FF9AE6B4'
    (& $g 'DlgSilentHint').Text = 'Installer identified as Autodesk (ODIS).'
    (& $g 'DlgSilentHint').Foreground = '#FF9AE6B4'
    foreach ($e in 'Build\setup.exe', 'Installer\install.exe') { [void](& $g 'DlgEntry').Items.Add($e) }
    (& $g 'DlgEntry').Text = 'Build\setup.exe'
    [void](& $g 'DlgVerify').Items.Add('%ProgramFiles%\Autodesk\Revit 2026\Revit.exe')
    (& $g 'DlgVerify').Text = '%ProgramFiles%\Autodesk\Revit 2026\Revit.exe'
    (& $g 'DlgVerifyHint').Text = '1 path(s) found on THIS machine - the product is installed here, so these are real.'
    (& $g 'DlgVerifyHint').Foreground = '#FF9AE6B4'

    # the after-install list, with the mix that matters: two editable rows bound for two
    # different directories, plus a hand-written step the dialog can only carry
    $rows = @(
        [pscustomobject]@{ Text = 'KILL  Revit + C:\Program Files\Autodesk\Revit 2026   (kept as written)' }
        [pscustomobject]@{ Text = 'MOVE  Support\licence.dat  ->  %ProgramFiles%\Autodesk\Revit 2026\' }
        [pscustomobject]@{ Text = 'MOVE  Docs\readme.txt  ->  %ProgramData%\Autodesk\Docs\' }
        [pscustomobject]@{ Text = 'RUN   Tools\serialise.bat' })
    (& $g 'DlgPostList').ItemsSource = $rows
    (& $g 'DlgPostList').SelectedIndex = 1
    (& $g 'DlgPostMove').IsChecked = $true
    foreach ($f in 'Support\licence.dat', 'Docs\readme.txt', 'Tools\serialise.bat') { [void](& $g 'DlgPostFrom').Items.Add($f) }
    (& $g 'DlgPostFrom').Text = 'Support\licence.dat'
    foreach ($d in '%ProgramFiles%\Autodesk\Revit 2026\', '%ProgramData%\Autodesk\Docs\') { [void](& $g 'DlgPostDest').Items.Add($d) }
    (& $g 'DlgPostDest').Text = '%ProgramFiles%\Autodesk\Revit 2026\'
    (& $g 'DlgPostWhere').Text = 'Moved into %ProgramFiles%\Autodesk\Revit 2026\ once the install verifies, keeping its own name.'
    (& $g 'DlgPostWhere').Foreground = '#FF9AE6B4'
    (& $g 'DlgStatus').Text = 'Found 2 installer(s) and 431 file(s) inside the package.'
    (& $g 'DlgStatus').Foreground = '#FF34D399'

    # the dialog declares its own size; render at that size so clipping shows up honestly
    $dw = [int]$(if ($dlg.Width -gt 0) { $dlg.Width } else { 620 })
    $dh = [int]$(if ($dlg.Height -gt 0) { $dlg.Height } else { 740 })
    Save-Visual $dlg.Content (Join-Path $OutDir '4-catalog-editor-dialog.png') $dw $dh

    Write-Host ''
    Write-Host "Snapshots in: $OutDir" -ForegroundColor Cyan
} finally {
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
