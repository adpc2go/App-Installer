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

    # ---- the batch strip, holding one row in every state it can show.
    #
    # This is the shot that exists because property tests cannot take it. Whether the 150px
    # cap is right, whether the name column is wide enough for real product names, whether the
    # strip crowds the buttons under a full catalog - none of that fails an assertion, and all
    # of it is obvious in a picture.
    #
    # Note which rows carry the remove button and which do not: that is Test-Removable being
    # shown rather than described. Failed, Installed and Installing cannot be pulled out.
    if ($script:Items.Count -ge 8) {
        $batch = @($script:Items[0..7])
        foreach ($b in $batch) { $b.IsSelected = $true }
        $script:Pending = $batch
        Show-BatchStrip
        Set-Status $batch[0] 'Failed: installer returned 1603' 'fail';   Set-Ring $batch[0] 'fail'
        Set-Status $batch[1] 'Installed'                       'ok';     Set-Ring $batch[1] 'ok'
        Set-Status $batch[2] 'Installing'                      'active'; Set-Ring $batch[2] 'busy'
        Set-Status $batch[3] 'Downloading 47%  8.1 MB/s  -  9m 48s left' 'active'; Set-Ring $batch[3] 'download'
        $batch[3].Progress = 47
        Set-Status $batch[4] 'Removed from batch'              'warn';   Set-Ring $batch[4] 'warn'
        Set-Status $batch[5] 'Removing - waiting for the installer to skip it' 'warn'
        Set-Ring $batch[5] 'busy'
        foreach ($q in $batch[6..7]) { Set-Status $q 'Queued' 'neutral'; Set-Ring $q 'queued' }
        Sync-BatchStrip
        $RowNow.Visibility = 'Visible'; $RowProgress.Visibility = 'Visible'
        $TxtNow.Text = "Downloading $($batch[3].Name) - 47%  at 8.1 MB/s  -  9m 48s left   (app 4 of 8)"
        $DotNow.Fill = '#FF4C8DFF'
        $BarOverall.Value = 41; $TxtOverall.Text = '41%   -   app 4 of 8'
        $BtnPause.Visibility = 'Visible'; $BtnCancel.Visibility = 'Visible'
        $TxtInstallBtn.Text = 'Add to Batch'
        $TxtStatus.Text = 'Downloading...'
        Save-Visual $window.Content (Join-Path $OutDir '1b-batch-strip.png') $Width $Height

        # and folded away to its header - the state the catalog gets its space back in.
        # Both are worth a picture: the whole argument for collapse over dismiss is that the
        # collapsed state still tells you where the batch got to.
        Switch-BatchFold
        Save-Visual $window.Content (Join-Path $OutDir '1c-batch-strip-folded.png') $Width $Height
        Switch-BatchFold

        # put the window back to rest, or every later shot carries a batch that is not running
        $BatchStrip.Visibility = 'Collapsed'
        $script:BatchLive = $false
        $script:Pending = @()
        foreach ($b in $batch) { Set-Status $b '' 'neutral'; Set-Ring $b 'none'
                                 $b.IsSelected = $false; $b.ProgressVis = 'Collapsed' }
        $RowNow.Visibility = 'Collapsed'; $RowProgress.Visibility = 'Collapsed'
        $BtnPause.Visibility = 'Collapsed'; $BtnCancel.Visibility = 'Collapsed'
        $TxtInstallBtn.Text = 'Install Selected'
    }

    Select-Tab 'Un'
    Select-UnTab 'Desktop'
    Write-Host ("  uninstall list: {0} program(s)" -f $script:UnItems.Count) -ForegroundColor DarkGray
    Save-Visual $window.Content (Join-Path $OutDir '2-uninstall-tab.png') $Width $Height

    Select-Tab 'Log'
    Save-Visual $window.Content (Join-Path $OutDir '3-activity-log.png') $Width $Height

    # ============================================================ the Data Backup tab
    #
    # Three modes sharing two columns, and the folder picker MOVES between them - it is the
    # destination for a drive backup and the SOURCE for a restore. Nothing asserts that the
    # column it lands in still has room for what was already there; a picture settles it.
    Write-Host 'Rendering the Data Backup tab...' -ForegroundColor Cyan
    Select-Tab 'Migrate'
    Select-BackupMode 'profile'
    Save-Visual $window.Content (Join-Path $OutDir '4a-backup-profile.png') $Width $Height

    Select-BackupMode 'folder'
    Set-BackupFolder 'E:\PC2Go-Backup' '' ''
    Save-Visual $window.Content (Join-Path $OutDir '4b-backup-drive.png') $Width $Height

    Select-BackupMode 'restore'
    Save-Visual $window.Content (Join-Path $OutDir '4c-backup-restore.png') $Width $Height

    # ---- Find a PC, with both lists filled. An empty dialog says nothing about whether two
    #      side-by-side lists and a manual path box actually fit in 640px.
    #
    #      The host names here are DELIBERATELY not machines on this network. Setting SelectedIndex
    #      fires the real handler, which really does try to connect - and against a PC that answers
    #      and then refuses, that raises Windows own credential prompt and blocks this renderer on
    #      a modal dialog nobody is sitting there to answer. An unreachable name comes back "could
    #      not be reached" without prompting, which is exactly the guard being relied on. The
    #      staged values are written AFTERWARDS so the picture comes out the same every time.
    Select-BackupMode 'folder'
    $NetOverlay.Visibility = 'Visible'
    foreach ($h in @(@{ n = 'OFFICE-PC'; i = '10.0.20.14' }, @{ n = 'RECEPTION-PC'; i = '10.0.20.24' })) {
        [void]$ListNetHosts.Items.Add([pscustomobject]@{ Title = $h.n; Sub = $h.i; Name = $h.n; Ip = $h.i })
    }
    $ListNetHosts.SelectedIndex = 0
    $TreeNetShares.Items.Clear()
    # a shared DRIVE and two shared folders, so both glyphs land in the picture - and one of them
    # opened, because the whole point of the tree is that a share is a door rather than a target
    $troot = New-NetNode ([string][char]0xE977) ($window.FindResource('Lift')) 'OFFICE-PC' '' '' $false
    foreach ($sh in @(@{ n = 'C'; d = $true }, @{ n = 'Backups'; d = $false }, @{ n = 'Scans'; d = $false })) {
        $unc = '\\OFFICE-PC\' + $sh.n
        $node = New-NetNode ([string][char]$(if ($sh.d) { 0xEDA2 } else { 0xE8B7 })) '#FFE3B341' $sh.n $unc $unc $true
        if ($sh.n -eq 'Backups') {
            $node.Items.Clear()
            foreach ($f in 'Reception', 'Workshop') {
                [void]$node.Items.Add((New-NetNode ([string][char]0xE8B7) '#FFE3B341' $f '' ($unc + '\' + $f) $true))
            }
            $node.IsExpanded = $true
            $node.Items[0].IsSelected = $true
        }
        [void]$troot.Items.Add($node)
    }
    $troot.IsExpanded = $true
    [void]$TreeNetShares.Items.Add($troot)
    $TxtNetStatus.Text = '2 PC(s) found'
    Show-NetNote ('Signed in as OFFICE-PC\technician.  3 share(s). Open one to pick a folder inside it - a share ' +
                  'is often a whole drive, and the root of somebody drive is rarely where a backup belongs.') 'Dim'
    Save-Visual $window.Content (Join-Path $OutDir '4d-backup-find-a-pc.png') $Width $Height

    # ---- and the answer that is NOT a failure. Discovery finding nothing is the normal outcome
    #      on a network of phones and printers, and it must not read like something went wrong.
    $ListNetHosts.Items.Clear(); $TreeNetShares.Items.Clear()
    $TxtNetStatus.Text = 'No PCs answered'
    Show-NetNote ('Nothing on this network accepted a file-sharing connection. That is normal if the other PC ' +
                  'is asleep, is on a different network, or has not shared a folder yet. You can still type ' +
                  'its name in below.') 'Muted'
    Save-Visual $window.Content (Join-Path $OutDir '4e-backup-found-nothing.png') $Width $Height
    $NetOverlay.Visibility = 'Collapsed'
    Select-BackupMode 'profile'

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
    # The editor's dialog used to be a Window, and a Window has .Content. The drawer refactor
    # made its root a Border - which has a Child, not a Content - so this handed Save-Visual a
    # $null and the whole run died at the last shot with "cannot call a method on a null-valued
    # expression". Render whatever the root actually is instead of assuming which it is.
    $dlgVisual = $(if ($dlg -is [Windows.Window]) { $dlg.Content } else { $dlg })
    Save-Visual $dlgVisual (Join-Path $OutDir '5-catalog-editor-dialog.png') $dw $dh

    Write-Host ''
    Write-Host "Snapshots in: $OutDir" -ForegroundColor Cyan
} finally {
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
