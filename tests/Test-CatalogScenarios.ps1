<#
.SYNOPSIS
    End-to-end journeys through the catalog editor and out the other side into the worker.

.DESCRIPTION
    The other harnesses test parts. This one tests the WHOLE trip, in the order a technician
    actually does it, with nothing hand-written in the middle:

      1. a real .zip is built and added as a brand-new app through the real dialog - the real
         background fetch, real SHA-256 over real bytes, real archive reading, real entry
         ranking, real after-install rows
      2. the result is saved to a real apps.json through Export-Catalog, and read back
      3. the saved app is re-opened in the dialog and edited - retargeted, reordered, one action
         removed - and saved again
      4. the twice-edited entry is handed to the REAL elevated worker as a queue item, which
         unpacks the package, runs the installer, verifies it, and runs the steps the editor
         wrote

    Step 4 is the point. Every other test stops at "the editor produced the right JSON"; this
    one asks whether a person clicking through the GUI ends up with software installed and two
    files where they wanted them, which is the only question that actually matters.

    The dialog is driven by splitting Show-AppDialog at its ShowDialog() line and raising real
    Click events on a window that is never shown, and the background fetch is pumped by running
    a dispatcher frame - so the async path under test is the real one, not a synchronous
    stand-in for it.

    Runs unelevated. Everything happens inside a temp sandbox, the real server\apps.json is
    never opened, nothing is downloaded, and nothing outside $env:TEMP is written to.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-CatalogScenarios.ps1
#>
[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$WorkerPath,
    [switch]$KeepTemp
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

$script:Pass = 0
$script:Fail = 0

function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") {
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Join-Path $env:TEMP ("catalog-scenario-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

try {
    # ================================================================== extraction
    $editorSrc = Get-Content -LiteralPath $EditorPath -Raw
    $workerSrc = Get-Content -LiteralPath $WorkerPath -Raw
    $editorAst = [System.Management.Automation.Language.Parser]::ParseInput($editorSrc, [ref]$null, [ref]$null)

    function Get-FunctionText($Ast, [string]$Name) {
        $fn = $Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name" }
        return $fn.Extent.Text
    }

    $lifted = @('Get-Field', 'Set-Field', 'Remove-Field', 'Get-BoxText', 'Test-RealHash', 'Test-App',
                   'Invoke-Guarded',
                   'Format-Size', 'ConvertTo-Id', 'Get-VerifyCandidates',
                   'Format-PostDest', 'Get-PostStepSummary', 'Update-PostRowText', 'New-PostRow',
                   'Get-PostRows', 'ConvertTo-PostStep', 'Set-PostRows', 'Test-InPackage',
                   'ConvertFrom-PackageFileName',
                   'Get-CategoryNames', 'Get-AppsInCategory', 'Get-DefaultCategory',
                   'Get-IconFileFor', 'Get-IconView', 'Set-CatalogDirty', 'Request-Save',
                   'Move-AppIcon', 'Request-IconMove',
                   'Show-AppDialog',
                   'Save-CatalogHistory', 'Export-Catalog')
    foreach ($n in $lifted) {
        . ([scriptblock]::Create((Get-FunctionText $editorAst $n)))
    }

    # the runspace payload the dialog's Fetch button actually runs
    $script:FetchWork = $editorAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:FetchWork' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) }
    if (-not $script:FetchWork) { throw 'Could not extract $script:FetchWork.' }

    $lines = $editorSrc -split "`r?`n"
    $xs = ($lines | Select-String -SimpleMatch '$dialogXaml = @''' | Select-Object -First 1).LineNumber
    $xe = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $xs } | Select-Object -First 1).LineNumber
    $xaml = ($lines[$xs..($xe - 2)] -join "`r`n")

    # Show-AppDialog no longer blocks on ShowDialog - it builds the drawer's contents,
    # wires them, and returns. So it is simply CALLED, and it publishes $c and $state
    # for a harness to inspect. Edits apply as they are made; there is no accept step.

    # the elevated worker, sliced out of its here-string
    $wl = $workerSrc -split "`r?`n"
    $ws = ($wl | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    $we = ($wl | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $ws } | Select-Object -First 1).LineNumber
    $workerFile = Join-Path $root 'worker.ps1'
    Set-Content -LiteralPath $workerFile -Encoding UTF8 `
                -Value ((($wl[$ws..($we - 2)]) -join "`r`n") -replace '#__PREFTABLE__', '')

    # Set-StatusText writes to the main window's label, which does not exist out here
    $TxtStatus = [pscustomobject]@{ Text = ''; Foreground = '' }
    function Set-StatusText([string]$text, [string]$colour = '#FFB6B6C0') { $TxtStatus.Text = $text }
    # The overlay these reach for belongs to the MAIN window, which no harness puts up. Three of
    # them are Invoke-Guarded's own error path, so without them a throw inside any lifted code
    # died reporting the throw - hiding the real failure behind a CommandNotFoundException.
    function Get-LevelDot([int]$Level) { '#FF4ADE80' }
    function Show-Fail([string]$Text) { $script:LastStatus = $Text }
    function Show-Warn([string]$Text) { $script:LastStatus = $Text }
    function Show-Done([string]$Text) { $script:LastStatus = $Text }
    function Show-Notice([string]$Title, [string]$Body) { $script:LastNotice = "$Title :: $Body" }
    # The drawer asks whether the app is live to decide if its id may still follow the name.
    # Nothing is live in a sandbox, so the id follows the name - which is what the journeys expect.
    function Get-AppLive($a) { [pscustomobject]@{ Text = '' } }
    # Confirming immediately is the honest stand-in: the question cannot be asked without a
    # window, and what these tests are about is what happens AFTER it is answered yes.
    function Show-Confirm([string]$Title, [string]$Body, [string]$OkText, [scriptblock]$OnConfirm) {
        $script:LastConfirm = "$Title :: $Body"
        if ($OnConfirm) { & $OnConfirm }
    }

    function Invoke-Click($Button) {
        $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
    # an editable ComboBox raises TextChanged from inside its template, which a window that was
    # never shown has not built - so raise what the template would have raised
    function Set-ComboText($Combo, [string]$Text) {
        $Combo.Text = $Text
        $Combo.RaiseEvent((New-Object Windows.Controls.TextChangedEventArgs(
            [Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.UndoAction]::None)))
    }
    # The fetch is a runspace polled by a DispatcherTimer, so the window stays responsive while a
    # multi-GB package is hashed. Running a dispatcher frame lets that timer actually tick here,
    # which keeps the real async path under test.
    function Wait-Dispatcher([int]$Milliseconds) {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
        $t.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    Write-Host 'Editor, worker and dialog extracted.' -ForegroundColor DarkGray

    # ================================================================== the package
    Write-Section 'Building a real package to add'

    $pkgSrc = Join-Path $root 'src\inner'
    New-Item -ItemType Directory -Force -Path "$pkgSrc\Support", "$pkgSrc\Docs", "$pkgSrc\Tools" | Out-Null
    $installDir = Join-Path $root 'installed\ScenarioApp'
    $docsDir    = Join-Path $root 'installed\ScenarioDocs'
    $ranMarker  = Join-Path $root 'finish-ran.txt'
    $sl = '/'
    Set-Content -LiteralPath "$pkgSrc\setup.cmd" -Encoding ASCII -Value (@(
        '@echo off',
        "mkdir `"$installDir`" 2>nul",
        "echo app > `"$installDir\app.exe`"",
        "exit ${sl}b 0") -join "`r`n")
    Set-Content -LiteralPath "$pkgSrc\Support\licence.dat" -Encoding ASCII -Value 'LICENCE-BODY'
    Set-Content -LiteralPath "$pkgSrc\Docs\readme.txt"     -Encoding ASCII -Value 'READ-ME'
    Set-Content -LiteralPath "$pkgSrc\Tools\finish.cmd"    -Encoding ASCII -Value (@(
        '@echo off', "> `"$ranMarker`" echo done", "exit ${sl}b 0") -join "`r`n")

    $zip = Join-Path $root 'package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $pkgSrc -Parent), $zip)
    $realHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $realSize = (Get-Item -LiteralPath $zip).Length
    Assert-True 'a real .zip package exists' (Test-Path -LiteralPath $zip)
    Write-Host ("  package.zip is {0}, sha256 {1}..." -f (Format-Size $realSize), $realHash.Substring(0, 16)) -ForegroundColor DarkGray

    # ================================================================== 1. add a new app
    Write-Section '1. Adding it as a brand-new app, through the dialog'

    $dialogXaml = $xaml
    $Owner      = $null
    $PackageDir = Join-Path $root 'packages'
    $BaseUrl    = 'https://example.invalid'
    # exactly the object the main window's Add button builds
    $App = [pscustomobject]@{
        id = ''; name = ''; version = ''; publisher = ''; category = 'Apps'
        sizeBytes = 0; url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @()
    }
    $dlg   = Show-AppDialog $App $null $LocalFile
    $c     = $dlg.Tag.C
    $state = $dlg.Tag.State

    $c.DlgName.Text = 'Scenario App'
    $c.DlgUrl.Text  = 'https://example.invalid/package.zip'
    # what "Use a local file..." does once the file picker has returned
    & ($dlg.Tag.Fn.startFetch) $zip
    $waited = 0
    while ($state.job -and $waited -lt 30000) { Wait-Dispatcher 200; $waited += 200 }
    Assert-True  'the background fetch finished'   ($null -eq $state.job)
    Assert-Equal 'it hashed the real bytes'        $realHash $state.sha256
    Assert-Equal 'and recorded the real size'      $realSize $state.size
    Assert-True  'and listed the package contents' ($state.files.Count -ge 4)
    Assert-True  'including the licence file'      ($state.files -contains 'inner\Support\licence.dat')
    # Only .exe and .msi are ranked and offered, which is right - those are what vendors ship.
    # This package's installer is a .cmd, so the editor proposes nothing and the person types it.
    # That the box stays editable for exactly that case is worth pinning down.
    Assert-Equal 'a package with no .exe or .msi gets no proposal' 0 $c.DlgEntry.Items.Count
    Set-ComboText $c.DlgEntry 'inner\setup.cmd'
    Assert-Equal 'but the entry can still be typed' 'inner\setup.cmd' (Get-BoxText $c.DlgEntry)

    # the verify path: what proves it installed
    Set-ComboText $c.DlgVerify (Join-Path $installDir 'app.exe')

    # two files, two directories - the thing that needed hand-editing before
    Invoke-Click $c.DlgPostAdd
    Assert-Equal 'the install folder is offered' ($installDir.TrimEnd('\') + '\') $c.DlgPostDest.Text
    Set-ComboText $c.DlgPostFrom 'inner\Support\licence.dat'
    Assert-Equal 'the licence keeps the install folder' ($installDir.TrimEnd('\') + '\') $state.rows[0].Dest

    Invoke-Click $c.DlgPostAdd
    Set-ComboText $c.DlgPostFrom 'inner\Docs\readme.txt'
    Set-ComboText $c.DlgPostDest $docsDir
    Assert-Equal 'the second action has its own directory' ($docsDir.TrimEnd('\') + '\') $state.rows[1].Dest

    # and something to run afterwards
    Invoke-Click $c.DlgPostAdd
    $c.DlgPostRun.IsChecked = $true
    Set-ComboText $c.DlgPostFrom 'inner\Tools\finish.cmd'
    Assert-Equal 'three actions queued up' 3 $state.rows.Count

    & ($dlg.Tag.Apply)
    Assert-Equal 'Save accepted the app, and reports no problem' '' ([string]$c.DlgStatus.Text)
    & ($dlg.Tag.Apply)

    Assert-Equal 'the id came from the name'    'scenario-app'    $App.id
    Assert-Equal 'the entry was kept'           'inner\setup.cmd' $App.entry
    Assert-Equal 'the hash is the real one'     $realHash         $App.sha256
    Assert-Equal 'three steps were written'     3 (@($App.postInstall).Count)
    Assert-Equal 'in the order they were added' 'copy,copy,run' ((@($App.postInstall) | ForEach-Object { $_.type }) -join ',')
    Assert-Equal 'nothing blocks publishing'    '' ((Test-App $App) -join ', ')
    try { $dlg.Close() } catch { }

    # ================================================================== 2. save the catalog
    Write-Section '2. Saving it to a real apps.json, and reading it back'

    $CatalogPath = Join-Path $root 'apps.json'
    Set-Content -LiteralPath $CatalogPath -Encoding UTF8 -Value '{"apps":[]}'
    $script:Catalog = [pscustomobject]@{ apps = @($App) }
    # Export-Catalog puts up a "save anyway?" MessageBox when an app is incomplete, and a modal
    # dialog in an unattended run is a hang, not a failure. Assert the catalog is clean FIRST,
    # so a regression upstream fails here loudly instead of stopping the harness dead.
    $blockers = @(Test-App $App)
    Assert-Equal 'the app is complete, so saving will not prompt' '' ($blockers -join ', ')
    if ($blockers.Count) { throw "refusing to call Export-Catalog with an incomplete app: $($blockers -join ', ')" }
    Assert-True 'Export-Catalog reported success' (Export-Catalog)
    Assert-True 'apps.json was written'           (Test-Path -LiteralPath $CatalogPath)
    Assert-True 'a .bak was kept'                 (Test-Path -LiteralPath "$CatalogPath.bak")

    # The BOM is not cosmetic. Invoke-RestMethod hands back a raw string instead of parsed JSON
    # when one is present, and the tool then shows one blank row under a green "Live catalog".
    $bytes = [IO.File]::ReadAllBytes($CatalogPath)
    Assert-True 'the catalog has NO byte-order mark' (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
    $reloaded = (Get-Content -LiteralPath $CatalogPath -Raw) | ConvertFrom-Json
    Assert-Equal 'it parses as JSON with one app'  1 (@($reloaded.apps).Count)
    Assert-Equal 'the app survived the round trip' 'scenario-app' $reloaded.apps[0].id
    Assert-Equal 'and so did all three steps'      3 (@($reloaded.apps[0].postInstall).Count)
    Assert-Equal 'the second file still has its own directory' ($docsDir.TrimEnd('\') + '\') $reloaded.apps[0].postInstall[1].dest

    # ================================================================== 3. edit it again
    Write-Section '3. Re-opening the saved app and editing it'

    $App = $reloaded.apps[0]
    # a step added by hand that the dialog has no UI for - it must survive being edited around
    Set-Field $App 'postInstall' (@(
        [pscustomobject]@{ type = 'kill'; name = 'scenario'; folder = $installDir }) + @($App.postInstall))
    $dlg   = Show-AppDialog $App $null $LocalFile
    $c     = $dlg.Tag.C
    $state = $dlg.Tag.State

    Assert-Equal 'all four steps are listed' 4 $state.rows.Count
    Assert-Equal 'the hand-written kill is first, and read-only' 'other' $state.rows[0].Kind
    Assert-True  'the two file copies are editable' ($state.rows[1].Kind -eq 'copy' -and $state.rows[2].Kind -eq 'copy')
    Assert-True  'and the run step too'             ($state.rows[3].Kind -eq 'run')

    # retarget the readme, drop the run step, move the kill below the copies
    $c.DlgPostList.SelectedIndex = 2
    $newDocs = Join-Path $root 'installed\Elsewhere'
    Set-ComboText $c.DlgPostDest $newDocs
    Assert-Equal 'the readme was retargeted' ($newDocs.TrimEnd('\') + '\') $state.rows[2].Dest

    $c.DlgPostList.SelectedIndex = 3
    Invoke-Click $c.DlgPostRemove
    Assert-Equal 'the run step was removed' 3 $state.rows.Count

    $c.DlgPostList.SelectedIndex = 0
    Invoke-Click $c.DlgPostDown
    Invoke-Click $c.DlgPostDown
    # a row's Kind is what the DIALOG can do with it, so every step it cannot edit reads 'other';
    # the step's own type is asserted below, after the save
    Assert-Equal 'the kill was moved to the end' 'copy,copy,other' (($state.rows | ForEach-Object { $_.Kind }) -join ',')

    & ($dlg.Tag.Apply)
    Assert-Equal 'the edit was accepted, and reports no problem' '' ([string]$c.DlgStatus.Text)
    & ($dlg.Tag.Apply)
    $steps = @($App.postInstall)
    Assert-Equal 'three steps saved'                    3 $steps.Count
    Assert-Equal 'in the new order'                     'copy,copy,kill' (($steps | ForEach-Object { $_.type }) -join ',')
    Assert-Equal 'the hand-written kill kept its folder' $installDir $steps[2].folder
    Assert-Equal 'and the readme its new home'          ($newDocs.TrimEnd('\') + '\') $steps[1].dest
    try { $dlg.Close() } catch { }

    $script:Catalog = [pscustomobject]@{ apps = @($App) }
    Assert-True 'the edited catalog saves again' (Export-Catalog)

    # ================================================================== 3b. fields with no UI
    Write-Section '3b. New-schema fields survive being edited around'

    # requires HAS a control now; the rest ride with no UI at all - same contract the
    # hand-written kill step proves above: editing the app must not shake them loose.
    # Section 4 hands this very $App to the REAL worker afterwards, so everything 3b
    # scribbles on it is captured here and restored at the end - fake verifyPaths in
    # particular would make that install unverifiable and skip its after-install steps.
    $origName = [string](Get-Field $App 'name')
    $origVp   = @(Get-Field $App 'verifyPaths')
    Set-Field $App 'requires' @('some-base')
    Set-Field $App 'uninstallOnly' $true
    Set-Field $App 'uninstall' ([pscustomobject]@{
        command = 'C:\V\un.exe'; args = '-i uninstall -q -o "__ODIS_MANIFEST__"'; detect = 'C:\V\v.exe' })
    $cl = Get-Field $App 'cleanup'
    if (-not $cl) { $cl = [pscustomobject]@{}; Set-Field $App 'cleanup' $cl }
    Set-Field $cl 'removers' @([pscustomobject]@{ name = 'vendor-clear'
        path = '%ProgramFiles%\V\uninstall.exe'; args = '--mode unattended'; shared = $true })
    # several verify paths, hand-curated: the drawer edits the FIRST and must keep the rest -
    # the old write-back truncated to one, which is exactly the regression pinned here
    Set-Field $App 'verifyPaths' @('C:\V\v.exe', 'C:\V\lib\core.dll')

    $dlg2   = Show-AppDialog $App $null $LocalFile
    $c2     = $dlg2.Tag.C
    Assert-Equal 'the requires field loads into its box' 'some-base' ([string]$c2.DlgRequires.Text)
    $c2.DlgName.Text = 'Scenario App Renamed'
    $c2.DlgRequires.Text = 'other-base'
    & ($dlg2.Tag.Apply)
    & ($dlg2.Tag.Apply)
    try { $dlg2.Close() } catch { }

    Assert-Equal 'requires was rewritten from the box'   'other-base' ([string]@(Get-Field $App 'requires')[0])
    Assert-True  'uninstallOnly survived the edit'       ([bool](Get-Field $App 'uninstallOnly'))
    Assert-True  'the ODIS token survived unmangled'     ((Get-Field (Get-Field $App 'uninstall') 'args') -like '*"__ODIS_MANIFEST__"*')
    Assert-Equal 'the remover survived'                  'vendor-clear' ([string](Get-Field @(Get-Field (Get-Field $App 'cleanup') 'removers')[0] 'name'))
    Assert-Equal 'BOTH verify paths survived the drawer' 2 @(Get-Field $App 'verifyPaths').Count
    Assert-Equal 'the second one intact'                 'C:\V\lib\core.dll' ([string]@(Get-Field $App 'verifyPaths')[1])

    $script:Catalog = [pscustomobject]@{ apps = @($App) }
    Assert-True 'and it still saves' (Export-Catalog)
    $reload2 = (Get-Content -LiteralPath $CatalogPath -Raw) | ConvertFrom-Json
    Assert-Equal 'requires round-trips to disk'          'other-base' ([string]$reload2.apps[0].requires[0])
    Assert-True  'uninstallOnly round-trips'             ([bool]$reload2.apps[0].uninstallOnly)

    # Hand section 4 back the app it expects: real name, real verify paths, installable again -
    # and SAVED, because section 4 reads the catalog off disk, and the file on disk right now
    # is the 3b-polluted one whose fake verify paths make the install unverifiable.
    Set-Field $App 'name' $origName
    Set-Field $App 'verifyPaths' @($origVp)
    Remove-Field $App 'uninstallOnly'
    Remove-Field $App 'requires'
    Remove-Field $App 'uninstall'
    $script:Catalog = [pscustomobject]@{ apps = @($App) }
    Assert-True 'and the restored app saves for section 4' (Export-Catalog)

    # ================================================================== 4. the real worker
    Write-Section '4. Handing the edited entry to the real elevated worker'

    $final = ((Get-Content -LiteralPath $CatalogPath -Raw) | ConvertFrom-Json).apps[0]
    $queue  = Join-Path $root 'queue.jsonl'
    $status = Join-Path $root 'status.jsonl'
    $cancel = Join-Path $root 'cancel.flag'
    # the GUI downloads the url and hands the worker the local file; everything else is the
    # catalog entry exactly as the editor wrote it
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id          = $final.id
        action      = 'install'
        file        = $zip
        sha256      = $final.sha256
        silentArgs  = $final.silentArgs
        entry       = $final.entry
        verifyPaths = @($final.verifyPaths)
        postInstall = @($final.postInstall)
    } | ConvertTo-Json -Compress -Depth 8)
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value '{"end":true}'

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerFile`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker exited {0} after {1:N1}s" -f $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray

    $reported = @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue |
                  ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
    $last = @($reported | Where-Object { $_.id -eq $final.id }) | Select-Object -Last 1
    Assert-True  'the worker reported on the app' ($null -ne $last)
    Assert-Equal 'it installed'                   'Installed' $last.state
    Assert-True  'and said the steps completed'   ($last.detail -like '*post-install step(s) completed*')

    Assert-True 'the product is on disk' (Test-Path -LiteralPath (Join-Path $installDir 'app.exe'))
    $gotLicence = Join-Path $installDir 'licence.dat'
    $gotReadme  = Join-Path $newDocs 'readme.txt'
    Assert-True  'the licence landed in the install folder' (Test-Path -LiteralPath $gotLicence)
    Assert-True  'the readme landed in the OTHER folder'    (Test-Path -LiteralPath $gotReadme)
    Assert-Equal 'the licence is the real file' 'LICENCE-BODY' (@(Get-Content -LiteralPath $gotLicence -ErrorAction SilentlyContinue) -join '').Trim()
    Assert-Equal 'the readme is the real file'  'READ-ME'      (@(Get-Content -LiteralPath $gotReadme  -ErrorAction SilentlyContinue) -join '').Trim()
    # the run step was REMOVED in step 3, so it must not have run
    Assert-True 'the removed run step did not run' (-not (Test-Path -LiteralPath $ranMarker))
    # and the scratch copy of the package is not left behind
    Assert-True 'the unpacked package was cleaned up' `
                (-not (Test-Path -LiteralPath (Join-Path (Split-Path $zip -Parent) "$($final.id)-unpacked")))

    # ================================================================== 5. refusals
    Write-Section '5. The journeys that must NOT get through'

    # a single .exe cannot feed an after-install file, because there is no package to take it from
    $dialogXaml = $xaml
    $App = [pscustomobject]@{ id = ''; name = ''; category = 'Apps'; sizeBytes = 0
                              url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @() }
    $dlg   = Show-AppDialog $App $null $LocalFile
    $c     = $dlg.Tag.C
    $state = $dlg.Tag.State
    $c.DlgName.Text = 'Bare Installer'
    $c.DlgUrl.Text  = 'https://example.invalid/setup.exe'
    Invoke-Click $c.DlgPostAdd
    Set-ComboText $c.DlgPostFrom 'Support\licence.dat'
    Set-ComboText $c.DlgPostDest 'C:\Program Files\Bare'
    & ($dlg.Tag.Apply)
    Assert-True 'a single installer cannot carry an after-install file' ($c.DlgStatus.Text -like '*must be a .zip*')
    Assert-True 'and the dialog stays open' ($c.DlgStatus.Text -ne '')
    try { $dlg.Close() } catch { }

    # publishing refuses the same thing from the catalog side
    $bad = [pscustomobject]@{ name = 'Bare'; url = 'https://example.invalid/s.exe'
                              sha256 = ('C' * 64); sizeBytes = 10
                              postInstall = @([pscustomobject]@{ type = 'copy'; from = 'a\b.dat'; dest = 'C:\x\' }) }
    Assert-True 'Test-App refuses it too' ((@(Test-App $bad) -join ' ') -like '*need a package*')

    # ---- the lift list, checked against itself -------------------------------------------
    #
    # HANDOVER trap 13: a lifted function grows a call to another editor function, the list is
    # not updated, and this suite dies with a CommandNotFoundException thrown from inside a
    # closure - nowhere near the change that caused it, and only if a test happens to walk that
    # branch. It has now happened five times, so it is asked rather than remembered.
    #
    # "Is it DEFINED right now" rather than "is it on a list", so lifting and stubbing both
    # satisfy it and there is no second list to keep in step. Run LAST, when every stub exists.
    $editorFns = @($editorAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name } | Sort-Object -Unique)
    $missing = @()
    foreach ($n in $lifted) {
        $fnAst = $editorAst.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) |
            Select-Object -First 1
        foreach ($cmd in $fnAst.FindAll({ param($x)
            $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $called = $cmd.GetCommandName()
            if (-not $called) { continue }
            if ($editorFns -notcontains $called) { continue }
            if (Get-Command -Name $called -CommandType Function -ErrorAction SilentlyContinue) { continue }
            $missing += "$n calls $called"
        }
    }
    Assert-Equal 'every editor function a lifted one calls is lifted or stubbed' `
                 '' ((@($missing | Sort-Object -Unique)) -join ' | ')
    # ================================================================== verdict
    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($KeepTemp) { Write-Host "Sandbox kept: $root" -ForegroundColor DarkGray }
    else { try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}
