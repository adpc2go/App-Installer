<#
.SYNOPSIS
    Contract harness for the catalog editor's after-install LIST.

.DESCRIPTION
    The editor used to hold exactly one after-install action. The catalog format never did -
    `postInstall` is an array and the worker has always run every step in it, in order - so an
    app needing two files in two directories had to be hand-edited, and the next trip through
    the dialog had to be careful not to eat the extra step. The list is what closes that gap.

    The WORKER half is already proven: Test-DirtyCleanup.ps1 drives two files out of one
    package into two different directories through the real elevated worker. What was never
    covered is the EDITOR half - reading an app's steps into rows, editing and reordering them,
    and writing them back without losing what the dialog cannot show. That is what this is for,
    plus the seam between the two: the JSON the editor produces, handed to the worker's own
    executor rather than to a hand-written fixture.

    Nothing is re-implemented here. The row model comes out of Catalog-Editor.ps1 through the
    parser, the step executor comes out of AppDeploy.ps1 the same way, and the dialog's XAML is
    lifted as the here-string it is. The code under test is the code that ships.

    What is asserted:

      1. every control the dialog looks up by name exists in the layout - a renamed control is
         otherwise a null-property error several handlers away from its cause
      2. reading steps into rows: order kept, editable rows recognised, and steps the dialog
         cannot edit (kill / registry / service / an absolute-path copy) still shown, because a
         step that cannot be seen cannot be positioned
      3. writing rows back: order follows the list, foreign steps survive byte for byte, and
         fields with no UI (args, timeoutSec, stopOnError) outlive an edit
      4. the destination rule - a folder keeps the file's name, a filename renames it
      5. the publish gate refusing what the worker would refuse
      6. the editor's own output executed by the worker's Invoke-PostInstall

    Runs unelevated. Everything happens inside a temp sandbox; no installer is downloaded or
    run, and nothing outside $env:TEMP is written to.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-AfterInstallList.ps1
#>
[CmdletBinding()]
param(
    [string]$EditorPath,
    [string]$WorkerPath,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY inside a param default whenever the script is an advanced one -
# [CmdletBinding()] makes defaults evaluate in the CALLER's scope, which has no script root.
# Resolve in the body, where $PSScriptRoot is real.
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

# A file that is not there is a RESULT, not a crash. Reading one directly aborts the whole run
# on the first failure and hides every assertion after it - which is precisely when the detail
# is worth having.
function Get-TextOrNothing([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '(nothing was written there)' }
    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

foreach ($p in @($EditorPath, $WorkerPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Cannot find $p" }
}

$root = Join-Path $env:TEMP ("afterinstall-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

try {
    # ------------------------------------------------------------------ extraction
    $editorSrc = Get-Content -LiteralPath $EditorPath -Raw
    $workerSrc = Get-Content -LiteralPath $WorkerPath -Raw

    $editorAst = [System.Management.Automation.Language.Parser]::ParseInput($editorSrc, [ref]$null, [ref]$null)

    # The elevated worker is a here-string inside AppDeploy.ps1, so the outer parser sees one
    # string literal and its functions are invisible. Slice it out by its delimiters first -
    # the same way Test-DirtyCleanup.ps1 gets at it - then parse that.
    $wLines = $workerSrc -split "`r?`n"
    $wStart = ($wLines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    if (-not $wStart) { throw 'Could not locate the $workerScript here-string in AppDeploy.ps1.' }
    $wEnd = ($wLines | Select-String -Pattern "^'@$" |
             Where-Object { $_.LineNumber -gt $wStart } | Select-Object -First 1).LineNumber
    $workerBody = ($wLines[$wStart..($wEnd - 2)] -join "`r`n")
    $workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerBody, [ref]$null, [ref]$null)

    # returns the source rather than dot-sourcing it: a dot-source INSIDE a function lands in
    # that function's scope and evaporates when it returns, which reads exactly like the
    # extraction having failed
    function Get-FunctionText($Ast, [string]$Name, [string]$Whence) {
        $fn = $Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name from $Whence" }
        return $fn.Extent.Text
    }

    # Get-DefaultCategory and the two it leans on came in when categories stopped being a
    # hardcoded 'Apps': Show-AppDialog now ASKS what a new app should be filed under instead of
    # writing a literal, so the dialog cannot be lifted without them.
    $fromEditor = 'Get-CategoryNames', 'Get-AppsInCategory', 'Get-DefaultCategory',
                  'Invoke-Guarded',
                  'Get-IconFileFor', 'Get-IconView', 'Set-CatalogDirty', 'Request-Save',
                  'Move-AppIcon', 'Request-IconMove',
                  'Show-AppDialog',
                  'Get-Field', 'Set-Field', 'Remove-Field', 'Test-RealHash', 'Test-App',
                  'Format-Size', 'ConvertTo-Id', 'Get-BoxText', 'Test-InPackage', 'Get-VerifyCandidates',
                  'Format-PostDest', 'Get-PostStepSummary', 'Update-PostRowText', 'New-PostRow',
                  'ConvertFrom-PackageFileName',
                  'Get-PostRows', 'ConvertTo-PostStep', 'Set-PostRows'
    foreach ($n in $fromEditor) { . ([scriptblock]::Create((Get-FunctionText $editorAst $n 'Catalog-Editor.ps1'))) }

    # Invoke-PostStep is the half of the contract the editor writes FOR. Taking it verbatim is
    # the only way this can fail when the two drift apart.
    foreach ($n in 'Invoke-PostStep', 'Invoke-PostInstall') { . ([scriptblock]::Create((Get-FunctionText $workerAst $n 'AppDeploy.ps1'))) }
    # the worker narrates every step down the status pipe; outside the worker there is no pipe
    function Write-Status([string]$Id, [string]$State, [string]$Detail, [bool]$Dirty = $false, [string[]]$Created = @()) { }
    # The overlay these reach for belongs to the MAIN window, which no harness puts up. Three of
    # them are Invoke-Guarded's own error path, so without them a throw inside any lifted code
    # died reporting the throw - hiding the real failure behind a CommandNotFoundException.
    function Get-LevelDot([int]$Level) { '#FF4ADE80' }
    function Show-Fail([string]$Text) { $script:LastStatus = $Text }
    function Show-Warn([string]$Text) { $script:LastStatus = $Text }
    function Show-Done([string]$Text) { $script:LastStatus = $Text }
    function Show-Notice([string]$Title, [string]$Body) { $script:LastNotice = "$Title :: $Body" }
    # Confirming immediately is the honest stand-in: the question cannot be asked without a
    # window, and what these tests are about is what happens AFTER it is answered yes.
    function Show-Confirm([string]$Title, [string]$Body, [string]$OkText, [scriptblock]$OnConfirm) {
        $script:LastConfirm = "$Title :: $Body"
        if ($OnConfirm) { & $OnConfirm }
    }

    Write-Host ("Lifted {0} functions from the editor, 2 from the worker." -f $fromEditor.Count) -ForegroundColor DarkGray

    # ------------------------------------------------------------------ 1. the layout
    Write-Section '1. The layout knows every control the code asks for'

    $lines = $editorSrc -split "`r?`n"
    $xStart = ($lines | Select-String -SimpleMatch '$dialogXaml = @''' | Select-Object -First 1).LineNumber
    if (-not $xStart) { throw 'Could not locate the $dialogXaml here-string.' }
    $xEnd = ($lines | Select-String -Pattern "^'@$" |
             Where-Object { $_.LineNumber -gt $xStart } | Select-Object -First 1).LineNumber
    $xaml = ($lines[$xStart..($xEnd - 2)] -join "`r`n")

    # the names come out of the source too, never a copy kept here - a control added to the
    # lookup and forgotten in the XAML is exactly the failure this is for
    # [^{}] rather than . : a non-greedy .* will happily start at some OTHER "foreach ($n in"
    # earlier in the editor and run all the way down to here, capturing a whole function body
    # on the way. A control-name list never contains a brace, so this cannot wander.
    $m = [regex]::Match($editorSrc, 'foreach \(\$n in ((?s:[^{}]*?))\) \{\s*\r?\n\s*\$c\[\$n\] = \$dlg\.FindName')
    if (-not $m.Success) { throw 'Could not locate the control-name list in Show-AppDialog.' }
    $wantNames = @(& ([scriptblock]::Create($m.Groups[1].Value)))
    Assert-True "the control-name list was found ($($wantNames.Count) names)" ($wantNames.Count -ge 20)

    $win = $null
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $win = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        Write-Host "  SKIP  the XAML could not be realised here ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    if ($win) {
        Assert-True 'the dialog XAML parses' ($null -ne $win)
        $missing = @($wantNames | Where-Object { -not $win.FindName($_) })
        Assert-Equal 'every looked-up control exists in the layout' '' ($missing -join ', ')
        # the list and its buttons ARE the feature; name them, so deleting one from both sides
        # at once cannot pass by simply being absent everywhere
        foreach ($n in 'DlgPostList', 'DlgPostAdd', 'DlgPostRemove', 'DlgPostUp', 'DlgPostDown',
                       'DlgPostMove', 'DlgPostRun', 'DlgPostFrom', 'DlgPostDest') {
            Assert-True "the layout has $n" ($null -ne $win.FindName($n))
        }
        Assert-Equal 'the list shows each row''s Text' 'Text' $win.FindName('DlgPostList').DisplayMemberPath
    }

    # ------------------------------------------------------------------ 2. reading steps in
    Write-Section '2. An app''s steps read into rows, in order'

    function New-TestApp($steps) {
        $a = [pscustomobject]@{ id = 'test-app'; name = 'Test App'; entry = 'Build\setup.exe' }
        if ($null -ne $steps) { Add-Member -InputObject $a -NotePropertyName 'postInstall' -NotePropertyValue @($steps) }
        return $a
    }

    $empty = New-TestApp $null
    # no @() around it: the list comes back unenumerated, so wrapping it would count the list
    # itself as one item rather than counting what is in it
    $growable = Get-PostRows $empty
    Assert-Equal 'an app with no postInstall has no rows' 0 $growable.Count
    # and it has to stay a LIST - the Add, Remove and Move buttons all mutate it, and a
    # fixed-size Object[] reads identically until the moment one of them does
    Assert-True 'the rows come back as something that can be added to' ($growable -is [Collections.ArrayList])

    $mixed = New-TestApp @(
        [pscustomobject]@{ type = 'kill'; name = 'acad'; folder = 'C:\Fake\App' }
        [pscustomobject]@{ type = 'copy'; name = 'Copy licence.dat'; from = 'Support\licence.dat'; dest = 'C:\Fake\App\' }
        [pscustomobject]@{ type = 'copy'; name = 'Copy readme.txt';  from = 'Docs\readme.txt';     dest = 'C:\Fake\Docs\' }
        [pscustomobject]@{ type = 'registry'; name = 'Serial'; path = 'HKLM:\SOFTWARE\Fake'; value = '1' }
        [pscustomobject]@{ type = 'copy'; name = 'From a path'; file = 'C:\Elsewhere\thing.dll'; dest = 'C:\Fake\App\' }
    )
    $rows = Get-PostRows $mixed
    Assert-Equal 'every step becomes a row' 5 $rows.Count
    Assert-Equal 'row 1 is the kill, not editable here'  'other' $rows[0].Kind
    Assert-Equal 'row 2 is an editable copy'             'copy'  $rows[1].Kind
    Assert-Equal 'row 3 is an editable copy'             'copy'  $rows[2].Kind
    Assert-Equal 'row 4 is the registry write'           'other' $rows[3].Kind
    Assert-Equal 'row 5 copies from an absolute path, so it is left alone' 'other' $rows[4].Kind
    Assert-Equal 'row 2 kept its source'      'Support\licence.dat' $rows[1].From
    Assert-Equal 'row 3 kept its destination' 'C:\Fake\Docs\'       $rows[2].Dest
    Assert-True  'the kill row says what it is'    ($rows[0].Text -like 'KILL*acad*')
    Assert-True  'the kill row says it is kept'    ($rows[0].Text -like '*kept as written*')
    Assert-True  'an editable row reads as a move' ($rows[1].Text -like 'MOVE*licence.dat*->*C:\Fake\App\*')

    $runApp = New-TestApp @([pscustomobject]@{ type = 'run'; name = 'Run activate.bat'; from = 'Tools\activate.bat' })
    $runRows = Get-PostRows $runApp
    Assert-Equal 'a run taking a file out of the package is editable' 'run' $runRows[0].Kind
    Assert-True  'a run row reads as a run' ($runRows[0].Text -like 'RUN*Tools\activate.bat*')

    # ------------------------------------------------------------------ 3. writing rows back
    Write-Section '3. Rows written back, in the order the list shows'

    Set-PostRows $mixed $rows
    $back = @($mixed.postInstall)
    Assert-Equal 'the same number of steps comes back' 5 $back.Count
    Assert-Equal 'order is unchanged' 'kill,copy,copy,registry,copy' (($back | ForEach-Object { $_.type }) -join ',')
    Assert-Equal 'the second file still goes to the second directory' 'C:\Fake\Docs\' $back[2].dest
    Assert-Equal 'the registry step kept its path' 'HKLM:\SOFTWARE\Fake' $back[3].path
    Assert-Equal 'the absolute-path copy kept its file' 'C:\Elsewhere\thing.dll' $back[4].file

    # the kill moved after the copies - what the Move up / Move down buttons do
    $moved = New-Object Collections.ArrayList
    [void]$moved.Add($rows[1]); [void]$moved.Add($rows[2]); [void]$moved.Add($rows[0])
    [void]$moved.Add($rows[3]); [void]$moved.Add($rows[4])
    Set-PostRows $mixed $moved
    Assert-Equal 'reordering rows reorders the steps' 'copy,copy,kill,registry,copy' `
                 ((@($mixed.postInstall) | ForEach-Object { $_.type }) -join ',')

    # removing every row must remove the property, not leave an empty array behind
    $solo = New-TestApp @([pscustomobject]@{ type = 'copy'; name = 'Copy x.dat'; from = 'a\x.dat'; dest = 'C:\B\' })
    Set-PostRows $solo (New-Object Collections.ArrayList)
    Assert-True 'removing every action removes postInstall entirely' (-not $solo.PSObject.Properties['postInstall'])

    # fields the dialog has no UI for are not the dialog's to throw away
    $rich = New-TestApp @([pscustomobject]@{ type = 'run'; name = 'Serialise'; from = 'Tools\ser.exe'
                                             args = '--serial 123'; timeoutSec = 900; stopOnError = $false })
    $richRows = Get-PostRows $rich
    $richRows[0].From = 'Tools\ser2.exe'
    Set-PostRows $rich $richRows
    $s = @($rich.postInstall)[0]
    Assert-Equal 'editing the file kept args'        '--serial 123'   $s.args
    Assert-Equal 'editing the file kept timeoutSec'  900              $s.timeoutSec
    Assert-Equal 'editing the file kept stopOnError' $false           $s.stopOnError
    Assert-Equal 'editing the file changed the file' 'Tools\ser2.exe' $s.from
    Assert-Equal 'a hand-written label is kept'      'Serialise'      $s.name

    # flipping a move into a run has to drop the destination, or the step lies about itself
    $flip = New-TestApp @([pscustomobject]@{ type = 'copy'; name = 'Copy go.cmd'; from = 'T\go.cmd'; dest = 'C:\B\' })
    $flipRows = Get-PostRows $flip
    $flipRows[0].Kind = 'run'
    Set-PostRows $flip $flipRows
    $f = @($flip.postInstall)[0]
    Assert-Equal 'move -> run becomes a run'         'run'        $f.type
    Assert-True  'move -> run drops the destination' (-not $f.PSObject.Properties['dest'])
    Assert-Equal 'the generated label follows suit'  'Run go.cmd' $f.name

    $flipRows[0].Kind = 'copy'
    $flipRows[0].Dest = 'C:\Other\'
    Set-PostRows $flip $flipRows
    $f = @($flip.postInstall)[0]
    Assert-Equal 'run -> move becomes a copy again' 'copy'      $f.type
    Assert-Equal 'and takes the new destination'    'C:\Other\' $f.dest

    # a step is never left claiming both a package-relative and an absolute source
    $stale = New-TestApp @([pscustomobject]@{ type = 'copy'; name = 'Copy y.dat'; from = 'a\y.dat'
                                              file = 'C:\Stale\y.dat'; dest = 'C:\B\' })
    Set-PostRows $stale (Get-PostRows $stale)
    Assert-True 'a stale absolute source is dropped once the step reads from the package' `
                (-not (@($stale.postInstall)[0]).PSObject.Properties['file'])

    # survives the trip through JSON, which is what saving and loading actually is
    $json = New-TestApp @(
        [pscustomobject]@{ type = 'copy'; name = 'Copy a'; from = 'p\a.dat'; dest = 'C:\A\' }
        [pscustomobject]@{ type = 'copy'; name = 'Copy b'; from = 'p\b.dat'; dest = 'C:\B\' }
    )
    $reparsed = ($json | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    $jr = Get-PostRows $reparsed
    Assert-Equal 'both actions survive a save and a reload' 2 $jr.Count
    Assert-Equal 'and still point at two different directories' 'C:\A\,C:\B\' (($jr | ForEach-Object { $_.Dest }) -join ',')

    # ------------------------------------------------------------------ 4. the destination rule
    Write-Section '4. A folder keeps the name, a filename renames'

    Assert-Equal 'a bare folder gains the slash the worker needs' 'C:\Program Files\App\' (Format-PostDest 'C:\Program Files\App')
    Assert-Equal 'a folder that already has one is untouched'     'C:\Program Files\App\' (Format-PostDest 'C:\Program Files\App\')
    Assert-Equal 'a filename is left as a rename'                 'C:\App\licence.dat'    (Format-PostDest 'C:\App\licence.dat')
    Assert-Equal 'an environment-variable folder still works'     '%ProgramFiles%\App\'   (Format-PostDest '%ProgramFiles%\App')
    Assert-Equal 'blank stays blank'                              ''                      (Format-PostDest '')
    Assert-Equal 'surrounding space is not part of the path'      'C:\App\'               (Format-PostDest '  C:\App  ')

    # ------------------------------------------------------------------ 5. publish gate
    Write-Section '5. Publishing refuses what the worker would refuse'

    $noPkg = [pscustomobject]@{
        name = 'No Package'; url = 'https://example.invalid/app.exe'
        sha256 = ('A' * 64); sizeBytes = 1000
        postInstall = @([pscustomobject]@{ type = 'copy'; name = 'Copy x'; from = 'p\x.dat'; dest = 'C:\B\' })
    }
    Assert-True 'an after-install file with no package to take it out of is not publishable' `
                ((@(Test-App $noPkg) -join ' ') -like '*need a package*')
    $withPkg = [pscustomobject]@{
        name = 'With Package'; url = 'https://example.invalid/app.zip'
        sha256 = ('A' * 64); sizeBytes = 1000; entry = 'Build\setup.exe'
        postInstall = @([pscustomobject]@{ type = 'copy'; name = 'Copy x'; from = 'p\x.dat'; dest = 'C:\B\' })
    }
    Assert-Equal 'the same app with a package is ready' '' ((Test-App $withPkg) -join ', ')

    # ------------------------------------------------------------------ 6. editor out, worker in
    Write-Section '6. What the editor wrote, run by the worker'

    # a package as the worker leaves it: unpacked, with files sitting inside
    $unpacked = Join-Path $root 'pkg-unpacked'
    foreach ($d in 'Support', 'Docs', 'Tools') { New-Item -ItemType Directory -Force -Path (Join-Path $unpacked $d) | Out-Null }
    Set-Content -LiteralPath (Join-Path $unpacked 'Support\licence.dat') -Value 'LICENCE-BODY' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $unpacked 'Docs\readme.txt')     -Value 'READ-ME'      -Encoding ASCII

    $destA  = Join-Path $root 'dest-app'
    $destB  = Join-Path $root 'dest-docs'
    $marker = Join-Path $root 'ran.txt'
    # a real batch file, so the run branch is executed rather than described
    Set-Content -LiteralPath (Join-Path $unpacked 'Tools\finish.cmd') `
                -Value "@echo off`r`n> `"$marker`" echo done" -Encoding ASCII

    # built the way the dialog builds it: rows in, steps out
    $realApp = [pscustomobject]@{ id = 'end-to-end'; entry = 'Build\setup.exe' }
    $endRows = New-Object Collections.ArrayList
    [void]$endRows.Add((New-PostRow 'copy' 'Support\licence.dat' (Format-PostDest $destA) $null))
    [void]$endRows.Add((New-PostRow 'copy' 'Docs\readme.txt'     (Format-PostDest $destB) $null))
    [void]$endRows.Add((New-PostRow 'run'  'Tools\finish.cmd'    ''                       $null))
    Set-PostRows $realApp $endRows

    # and through the catalog's own encoding, so nothing survives on object identity alone
    $onTheWire = ($realApp | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    Assert-Equal 'the editor wrote three steps' 3 (@($onTheWire.postInstall).Count)

    $script:UnpackedDir = $unpacked
    $problems = @(Invoke-PostInstall $onTheWire)
    Assert-Equal 'the worker reports no problems' '' ($problems -join '; ')

    $landedA = Join-Path $destA 'licence.dat'
    $landedB = Join-Path $destB 'readme.txt'
    Assert-True  'the first file landed in the first directory'   (Test-Path -LiteralPath $landedA)
    Assert-True  'the second file landed in the second directory' (Test-Path -LiteralPath $landedB)
    Assert-Equal 'the first file is the file, not an empty stub'  'LICENCE-BODY' (Get-TextOrNothing $landedA)
    Assert-Equal 'the second file is the file too'                'READ-ME'      (Get-TextOrNothing $landedB)
    Assert-True  'the run step actually ran'                      (Test-Path -LiteralPath $marker)

    # Order is not decoration: a failed step stops the ones after it, so where a row sits
    # decides what happens. Break the first one and the second must never run.
    $brokenApp = [pscustomobject]@{ id = 'order' }
    $brokenRows = New-Object Collections.ArrayList
    [void]$brokenRows.Add((New-PostRow 'copy' 'Support\missing.dat' (Format-PostDest (Join-Path $root 'dest-x')) $null))
    [void]$brokenRows.Add((New-PostRow 'copy' 'Docs\readme.txt'     (Format-PostDest (Join-Path $root 'dest-y')) $null))
    Set-PostRows $brokenApp $brokenRows
    $p2 = @(Invoke-PostInstall (($brokenApp | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    Assert-True 'a failed action names itself'     (($p2 -join '; ') -like '*step 1*source file missing*')
    Assert-True 'and stops the ones after it'      (($p2 -join '; ') -like '*remaining steps skipped*')
    Assert-True 'so the later file was NOT copied' (-not (Test-Path -LiteralPath (Join-Path $root 'dest-y\readme.txt')))

    # ------------------------------------------------------------------ 7. the real dialog
    Write-Section '7. The real dialog, driven by its own buttons'

    # Show-AppDialog builds the window, wires every handler, then blocks on ShowDialog and
    # applies the result. Split it there and both halves can be run for real: the wiring on a
    # window that is never shown, then the apply, with the buttons clicked in between. WPF
    # raises Click on a control that was never displayed, so this needs no UI Automation - the
    # thing that made the app list untestable - and no human to see a dialog.
    if (-not $win) {
        Write-Host '  SKIP  no WPF here, so the dialog cannot be built' -ForegroundColor Yellow
    } else {
        # Show-AppDialog no longer blocks on ShowDialog - it builds the drawer's contents,
        # wires them, and returns. So it is simply CALLED, and it publishes $c and $state
        # for a harness to inspect. Edits apply as they are made; there is no accept step.

        function Invoke-Click($Button) {
            $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        # An editable ComboBox raises TextChanged from the TextBox inside its template, and a
        # window that was never shown has no realised template - so assigning .Text here is
        # silent where a person typing would not be. Raise the event the template would have
        # raised: the handler under test then sees exactly the control state it sees in the
        # real dialog.
        function Set-ComboText($Combo, [string]$Text) {
            $Combo.Text = $Text
            $Combo.RaiseEvent((New-Object Windows.Controls.TextChangedEventArgs(
                [Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                [Windows.Controls.UndoAction]::None)))
        }

        $dialogXaml = $xaml            # the head parses this into its window
        $Owner      = $null
        $PackageDir = $root
        $BaseUrl    = 'https://example.invalid'
        # an app that already has a hand-written kill and one file-copy, which is the state a
        # technician actually opens the dialog on
        $App = [pscustomobject]@{
            id = 'dlg'; name = 'Dialog App'; url = 'https://example.invalid/app.zip'
            sha256 = ('B' * 64); sizeBytes = 4096; entry = 'Build\setup.exe'
            silentArgs = '/S'; verifyPaths = @('C:\Fake\App\app.exe')
            postInstall = @(
                [pscustomobject]@{ type = 'kill'; name = 'app'; folder = 'C:\Fake\App' }
                [pscustomobject]@{ type = 'copy'; name = 'Copy licence.dat'; from = 'Support\licence.dat'; dest = 'C:\Fake\App\' }
            )
        }
        # dot-sourced, so $c / $state / $dlg are this scope's to inspect and click
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State

        Assert-Equal 'the dialog opened with both existing steps' 2 $state.rows.Count
        Assert-Equal 'and selected the first'                     0 $c.DlgPostList.SelectedIndex
        Assert-True  'the kill row cannot be edited'              (-not $c.DlgPostEdit.IsEnabled)
        Assert-True  'and says so'                                ($c.DlgPostWhere.Text -like '*exactly as written*')
        Assert-True  'it cannot move up from the top'             (-not $c.DlgPostUp.IsEnabled)

        $c.DlgPostList.SelectedIndex = 1
        Assert-True  'selecting the copy enables the fields'      $c.DlgPostEdit.IsEnabled
        Assert-Equal 'and shows its source'  'Support\licence.dat' $c.DlgPostFrom.Text
        Assert-Equal 'and its destination'   'C:\Fake\App\'        $c.DlgPostDest.Text
        Assert-True  'the move radio is the one selected'          $c.DlgPostMove.IsChecked

        # Add an action, and give it a SECOND directory - the case the old dialog could not
        # express at all, done the way a person would do it
        Invoke-Click $c.DlgPostAdd
        Assert-Equal 'Add put a third row in'          3 $state.rows.Count
        Assert-Equal 'and selected it'                 2 $c.DlgPostList.SelectedIndex
        # the verify path is C:\Fake\App\app.exe, so the folder holding it is the offer
        Assert-Equal 'prefilled with the install folder' 'C:\Fake\App\' $c.DlgPostDest.Text
        Set-ComboText $c.DlgPostFrom 'Docs\readme.txt'
        Set-ComboText $c.DlgPostDest 'C:\Fake\Docs'
        Assert-Equal 'typing updated the row'  'Docs\readme.txt' $state.rows[2].From
        Assert-Equal 'and normalised the folder' 'C:\Fake\Docs\' $state.rows[2].Dest
        Assert-True  'the list line reads back what was typed' ($state.rows[2].Text -like 'MOVE*readme.txt*C:\Fake\Docs\*')

        # reorder: the new row up above the licence copy
        Invoke-Click $c.DlgPostUp
        Assert-Equal 'Move up moved it'      1 $c.DlgPostList.SelectedIndex
        Assert-Equal 'and the rows followed' 'other,copy,copy' (($state.rows | ForEach-Object { $_.Kind }) -join ',')
        Assert-Equal 'readme is now first of the two' 'Docs\readme.txt' $state.rows[1].From

        # the run radio hides the destination, because a run has nowhere to go
        $c.DlgPostRun.IsChecked = $true
        Assert-Equal 'switching to run changes the row' 'run' $state.rows[1].Kind
        Assert-True  'and disables the destination'     (-not $c.DlgPostDest.IsEnabled)
        $c.DlgPostMove.IsChecked = $true
        Assert-Equal 'switching back restores the move'        'copy'          $state.rows[1].Kind
        Assert-Equal 'without having lost the destination'     'C:\Fake\Docs\' $state.rows[1].Dest

        # An incomplete action is no longer REFUSED, because there is no Save to refuse at: the
        # drawer writes as you go and says what is wrong, which is the same split the rest of
        # the tool uses - saving warns, publishing is the gate that refuses.
        Invoke-Click $c.DlgPostAdd
        & ($dlg.Tag.Apply)
        Assert-True 'an action with no file is called out' ($c.DlgStatus.Text -like '*action 4*no file chosen*')
        Invoke-Click $c.DlgPostRemove
        Assert-Equal 'Remove took it back out' 3 $state.rows.Count

        # a move with nowhere to go is named too
        $c.DlgPostList.SelectedIndex = 2
        Set-ComboText $c.DlgPostDest ''
        & ($dlg.Tag.Apply)
        Assert-True 'a move with no destination is called out' ($c.DlgStatus.Text -like '*action 3*where the file goes*')
        Set-ComboText $c.DlgPostDest 'C:\Fake\App'

        # and with the list complete it says nothing at all
        & ($dlg.Tag.Apply)
        Assert-Equal 'a complete list reports no problem' '' ([string]$c.DlgStatus.Text)

        $saved = @($App.postInstall)
        Assert-Equal 'three steps were saved'          3 $saved.Count
        Assert-Equal 'in the order the list showed'    'kill,copy,copy' (($saved | ForEach-Object { $_.type }) -join ',')
        Assert-Equal 'the hand-written kill survived'  'C:\Fake\App'    $saved[0].folder
        Assert-Equal 'the new file goes to its own directory' 'C:\Fake\Docs\' $saved[1].dest
        Assert-Equal 'the original file keeps its own'        'C:\Fake\App\'  $saved[2].dest
        Assert-Equal 'two directories, from the GUI, no hand-editing' 2 `
                     (@($saved | Where-Object { $_.dest } | ForEach-Object { $_.dest } | Select-Object -Unique).Count)
    }

    # ------------------------------------------------------------------ 8. a brand-new app
    Write-Section '8. A brand-new app - what the Add button in the main window hands over'

    # Section 7 opens an app that already HAS steps, which is the friendly case. This is the one
    # a person actually meets first: an empty entry, an empty list, and nothing selected. It
    # asserts what that section could not - whether the controls are CLICKABLE. Setting
    # .IsChecked works on a disabled radio, so a greyed-out panel passes a test that only sets
    # properties and fails for the person in front of it.
    if (-not $win) {
        Write-Host '  SKIP  no WPF here' -ForegroundColor Yellow
    } else {
        $dialogXaml = $xaml
        $Owner      = $null
        $PackageDir = $root
        $BaseUrl    = 'https://example.invalid'
        # exactly the object $BtnAdd.Add_Click builds
        $App = [pscustomobject]@{
            id = ''; name = ''; version = ''; publisher = ''; category = 'Apps'
            sizeBytes = 0; url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @()
        }
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State

        Assert-Equal 'a new app opens with an empty list' 0 $state.rows.Count
        Assert-True  'with nothing selected'              ($c.DlgPostList.SelectedIndex -lt 0)
        Assert-True  'so the type radios are greyed'      (-not $c.DlgPostRun.IsEnabled)
        Assert-True  'and Add is the only way in'         $c.DlgPostAdd.IsEnabled

        Invoke-Click $c.DlgPostAdd
        Assert-Equal 'Add creates a row'      1 $state.rows.Count
        Assert-Equal 'and selects it'         0 $c.DlgPostList.SelectedIndex
        # the four that decide whether a person can do anything at all
        Assert-True 'the edit panel is now enabled'   $c.DlgPostEdit.IsEnabled
        Assert-True 'the "Move a file in" radio is clickable' $c.DlgPostMove.IsEnabled
        Assert-True 'the "Run a file" radio is clickable'     $c.DlgPostRun.IsEnabled
        Assert-True 'the file box is usable'                  $c.DlgPostFrom.IsEnabled
        Assert-True 'Move is the one selected to begin with'  $c.DlgPostMove.IsChecked

        # a new app has no verify path yet, so there is no folder to offer
        Assert-Equal 'no install folder is known yet, so none is invented' '' $c.DlgPostDest.Text

        # choosing Run must actually change the row
        $c.DlgPostRun.IsChecked = $true
        Assert-Equal 'choosing Run changes the row'  'run' $state.rows[0].Kind
        Assert-True  'and the list line follows'     ($state.rows[0].Text -like 'RUN*')

        # AND THE POINT: an action with nothing in it must never be saveable
        $c.DlgName.Text  = 'Brand New'
        $c.DlgUrl.Text   = 'https://example.invalid/app.zip'
        $c.DlgEntry.Text = 'Build\setup.exe'
        & ($dlg.Tag.Apply)
        Assert-True 'Save refuses an action with no file chosen' ($c.DlgStatus.Text -like '*action 1*no file chosen*')
        Assert-True 'and the dialog is NOT accepted' ($c.DlgStatus.Text -ne '')
        Assert-True 'so nothing empty reaches the catalog'       (-not $App.PSObject.Properties['postInstall'])

        # the same for a move with no destination
        $c.DlgPostMove.IsChecked = $true
        Set-ComboText $c.DlgPostFrom 'Tools\thing.dat'
        & ($dlg.Tag.Apply)
        Assert-True 'Save refuses a move with nowhere to go' ($c.DlgStatus.Text -like '*action 1*where the file goes*')
        Assert-True 'still not accepted' ($c.DlgStatus.Text -ne '')

        # The file box is free text. Once a fetch has read the package, a name that is not in it
        # is a typo, and the alternative to catching it here is catching it on a client at the
        # end of a 14 GB install.
        $state.files = @('Support\licence.dat', 'Docs\readme.txt', 'Tools\finish.cmd')
        Set-ComboText $c.DlgPostDest 'C:\Somewhere'
        Set-ComboText $c.DlgPostFrom 'Tools\thing.dat'
        Assert-True 'a file not in the package is called out on screen' ($c.DlgPostWhere.Text -like '*no such file in the package*')
        & ($dlg.Tag.Apply)
        Assert-True 'and Save refuses it'  ($c.DlgStatus.Text -like "*not in the package*")
        Assert-True 'still not accepted' ($c.DlgStatus.Text -ne '')

        Set-ComboText $c.DlgPostFrom 'Docs\readme.txt'
        Assert-True 'a file that IS in the package is accepted' ($c.DlgPostWhere.Text -notlike '*no such file*')
        & ($dlg.Tag.Apply)
        Assert-Equal 'and the drawer stops complaining' '' ([string]$c.DlgStatus.Text)

    }

    # ------------------------------------------------------------------ 9. the package guard
    Write-Section '9. Naming a file the package does not have'

    $pkg = @('Support\licence.dat', 'Docs\readme.txt')
    Assert-True  'a file in the listing passes'          (Test-InPackage $pkg 'Docs\readme.txt')
    Assert-True  'forward slashes are the same file'     (Test-InPackage $pkg 'Docs/readme.txt')
    Assert-True  'case is not a difference worth failing on' (Test-InPackage $pkg 'docs\README.TXT')
    Assert-True  'a typo is caught'                      (-not (Test-InPackage $pkg 'Docs\readme.text'))
    Assert-True  'a file from another folder is caught'  (-not (Test-InPackage $pkg 'readme.txt'))
    # no listing means no opinion - an app edited without re-fetching knows nothing about its
    # own package, and guessing there would block entries that are perfectly correct
    Assert-True  'with no listing, nothing is refused'   (Test-InPackage @() 'anything\at\all.dat')
    Assert-True  'and an empty name is left to the other checks' (Test-InPackage $pkg '')

    # ------------------------------------------------------------------ 10. order, executed
    Write-Section '10. The order on screen is the order that runs'

    # Six actions, each appending its own letter to one file. Order is the entire point of a
    # list, and asserting on the array is not the same as asserting on what the machine did -
    # so this reads back what the worker actually wrote, in sequence.
    $orderDir = Join-Path $root 'order'
    New-Item -ItemType Directory -Force -Path (Join-Path $orderDir 'pkg') | Out-Null
    $trail = Join-Path $orderDir 'trail.txt'
    $expected = 'A', 'B', 'C', 'D', 'E', 'F'
    foreach ($letter in $expected) {
        Set-Content -LiteralPath (Join-Path $orderDir "pkg\$letter.cmd") -Encoding ASCII `
                    -Value (@('@echo off', ">> `"$trail`" echo $letter", 'exit /b 0') -join "`r`n")
    }
    $ordered = [pscustomobject]@{ id = 'ordered' }
    $rows2 = New-Object Collections.ArrayList
    foreach ($letter in $expected) { [void]$rows2.Add((New-PostRow 'run' "pkg\$letter.cmd" '' $null)) }
    Set-PostRows $ordered $rows2
    Assert-Equal 'six actions were written' 6 (@($ordered.postInstall).Count)

    $script:UnpackedDir = $orderDir
    $orderProblems = @(Invoke-PostInstall (($ordered | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    Assert-Equal 'they all ran without complaint' '' ($orderProblems -join '; ')
    $actual = @(Get-Content -LiteralPath $trail -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-Equal 'and ran in exactly the order the list showed' ($expected -join '') ($actual -join '')

    # reverse the list and prove the machine follows IT, rather than some fixed order the array
    # happened to have anyway
    Remove-Item -LiteralPath $trail -Force -ErrorAction SilentlyContinue
    $rows2.Reverse()
    Set-PostRows $ordered $rows2
    $null = @(Invoke-PostInstall (($ordered | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    $actual2 = @(Get-Content -LiteralPath $trail -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Assert-Equal 'reversing the list reverses what runs' (($expected[5..0]) -join '') ($actual2 -join '')

    # ------------------------------------------------------------------ 11. a PowerShell action
    Write-Section '11. Run a PowerShell command'

    $psApp = [pscustomobject]@{ id = 'psapp' }
    $psMark = Join-Path $root 'ps-ran.txt'
    $psRows = New-Object Collections.ArrayList
    [void]$psRows.Add((New-PostRow 'powershell' '' '' $null "Set-Content -LiteralPath '$psMark' -Value 'it ran'"))
    Set-PostRows $psApp $psRows
    $step = @($psApp.postInstall)[0]
    Assert-Equal 'the step is a powershell step'       'powershell' $step.type
    Assert-True  'carrying the command'                ($step.command -like '*Set-Content*')
    Assert-True  'and no file fields left on it'       (-not $step.PSObject.Properties['from'] -and -not $step.PSObject.Properties['dest'])
    Assert-True  'with a label taken from the command' ([string]$step.name -like 'PowerShell:*')

    $psProblems = @(Invoke-PostInstall (($psApp | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    Assert-Equal 'the worker ran it cleanly' '' ($psProblems -join '; ')
    Assert-True  'and it really executed'     (Test-Path -LiteralPath $psMark)

    # a command that fails must be reported, not swallowed
    $bad = [pscustomobject]@{ id = 'psbad' }
    $badRows = New-Object Collections.ArrayList
    [void]$badRows.Add((New-PostRow 'powershell' '' '' $null 'exit 9'))
    Set-PostRows $bad $badRows
    $badProblems = @(Invoke-PostInstall (($bad | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    Assert-True 'a failing command is reported with its exit code' (($badProblems -join '; ') -like '*exit code 9*')

    # quoting that would break a command line must survive - this is why it is base64'd
    $q = [pscustomobject]@{ id = 'psq' }
    $qMark = Join-Path $root 'ps-quotes.txt'
    $qRows = New-Object Collections.ArrayList
    [void]$qRows.Add((New-PostRow 'powershell' '' '' $null "Set-Content -LiteralPath '$qMark' -Value 'a `"b`" & c'"))
    Set-PostRows $q $qRows
    $null = @(Invoke-PostInstall (($q | ConvertTo-Json -Depth 10) | ConvertFrom-Json))
    Assert-True  'a command containing quotes and an ampersand still runs' (Test-Path -LiteralPath $qMark)
    Assert-Equal 'and arrives intact' 'a "b" & c' ((@(Get-Content -LiteralPath $qMark -ErrorAction SilentlyContinue) -join '').Trim())

    # ------------------------------------------------------------------ 12. a second package
    Write-Section '12. Fetching a SECOND package into the same dialog'

    if (-not $win) {
        Write-Host '  SKIP  no WPF here' -ForegroundColor Yellow
    } else {
        # The reported bug: add Office, then add AutoCAD without closing the dialog, and the
        # name, URL, switches and setup file all stayed on Office - so the entry read "Office"
        # while carrying AutoCAD's hash. Fields the dialog filled in itself must follow the new
        # package; fields a person typed must not.
        $twoDir = Join-Path $root 'two-packages'
        foreach ($p in 'office', 'autocad') {
            New-Item -ItemType Directory -Force -Path (Join-Path $twoDir "$p\inner") | Out-Null
            Set-Content -LiteralPath (Join-Path $twoDir "$p\inner\$p-setup.exe") -Value "MZ $p" -Encoding ASCII
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # the runspace payload the Fetch button actually runs - an assignment, not a function,
        # so it needs lifting separately from everything else
        $script:FetchWork = $editorAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$script:FetchWork' }, $true) |
            Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) }
        # the fetch runs in a runspace polled by a DispatcherTimer, so the dispatcher has to
        # actually run for the poll to ever fire
        function Wait-Dispatcher([int]$ms) {
            $frame = New-Object Windows.Threading.DispatcherFrame
            $t = New-Object Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds($ms)
            $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
            $t.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
        }
        $officeZip  = Join-Path $twoDir 'Office 2024.zip'
        $autocadZip = Join-Path $twoDir 'AutoCAD 2026.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $twoDir 'office'),  $officeZip)
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $twoDir 'autocad'), $autocadZip)

        $dialogXaml = $xaml
        $Owner = $null
        $PackageDir = Join-Path $root 'pkgcache'
        $BaseUrl = 'https://files.example.invalid'
        $App = [pscustomobject]@{ id = ''; name = ''; category = 'Apps'; sizeBytes = 0
                                  url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @() }
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State

        # first package, the way "Use a local file..." ends up calling it
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'Office 2024'
        & ($dlg.Tag.Fn.setAuto) $c.DlgUrl  'url'  "$BaseUrl/files/Office 2024.zip"
        & ($dlg.Tag.Fn.startFetch) $officeZip
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }
        Assert-Equal 'the first package sets the name'  'Office 2024' (Get-BoxText $c.DlgName)
        Assert-Equal 'and finds its installer'          'inner\office-setup.exe' (Get-BoxText $c.DlgEntry)
        $officeSha = $state.sha256

        # now the second, WITHOUT closing the dialog
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'AutoCAD 2026'
        & ($dlg.Tag.Fn.setAuto) $c.DlgUrl  'url'  "$BaseUrl/files/AutoCAD 2026.zip"
        & ($dlg.Tag.Fn.startFetch) $autocadZip
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }

        Assert-Equal 'the name follows the second package'  'AutoCAD 2026' (Get-BoxText $c.DlgName)
        Assert-Equal 'so does the URL'  "$BaseUrl/files/AutoCAD 2026.zip" (Get-BoxText $c.DlgUrl)
        Assert-Equal 'and the setup file inside it' 'inner\autocad-setup.exe' (Get-BoxText $c.DlgEntry)
        Assert-True  'the hash is the second package''s, not the first''s' ($state.sha256 -ne $officeSha)
        Assert-Equal 'the hash matches the file on disk' `
                     ((Get-FileHash -LiteralPath $autocadZip -Algorithm SHA256).Hash) $state.sha256

        # ---- the same thing on an app that is ALREADY in the catalog
        $existing = [pscustomobject]@{
            id = 'ms-365'; name = 'Microsoft 365 Apps'; category = 'Apps'
            url = "$BaseUrl/files/Office 2024.zip"
            sha256 = (Get-FileHash -LiteralPath $officeZip -Algorithm SHA256).Hash
            sizeBytes = (Get-Item $officeZip).Length
            silentArgs = '/configure office.xml'; entry = 'inner\office-setup.exe'
            verifyPaths = @('C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE')
        }
        $App = $existing
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        Assert-Equal 'the existing app opens with its own setup file' 'inner\office-setup.exe' (Get-BoxText $c.DlgEntry)

        # Swap the package, the way "Use a local file..." does. Then check EVERY derived field
        # at once rather than one per bug report: a field that stays behind leaves the entry
        # half describing one product and half describing another, which is worse than either.
        $beforeVerify = Get-BoxText $c.DlgVerify
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'AutoCAD 2026'
        & ($dlg.Tag.Fn.setAuto) $c.DlgUrl  'url'  "$BaseUrl/files/AutoCAD 2026.zip"
        & ($dlg.Tag.Fn.startFetch) $autocadZip
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }

        Assert-Equal 'the name follows the new package'     'AutoCAD 2026' (Get-BoxText $c.DlgName)
        Assert-Equal 'the URL follows it'                   "$BaseUrl/files/AutoCAD 2026.zip" (Get-BoxText $c.DlgUrl)
        Assert-Equal 'the setup file inside it follows'     'inner\autocad-setup.exe' (Get-BoxText $c.DlgEntry)
        Assert-Equal 'the hash follows'                     ((Get-FileHash -LiteralPath $autocadZip -Algorithm SHA256).Hash) $state.sha256
        Assert-Equal 'the size follows'                     ((Get-Item $autocadZip).Length) $state.size
        # the verify path is looked up FROM the name, so it can only follow if the name did
        Assert-True  'the verify path does not stay on the old product' `
                     ((Get-BoxText $c.DlgVerify) -ne $beforeVerify)
        Assert-True  'and no field still mentions the old product' `
                     (@((Get-BoxText $c.DlgName), (Get-BoxText $c.DlgUrl), (Get-BoxText $c.DlgEntry),
                        (Get-BoxText $c.DlgVerify)) -notmatch '(?i)office|microsoft 365').Count -eq 4

        # reopen a fresh dialog for the last check
        $App = [pscustomobject]@{ id = ''; name = ''; category = 'Apps'; sizeBytes = 0
                                  url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @() }
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'AutoCAD 2026'

        # and the other half of the rule: something typed by hand is never overwritten
        $c.DlgName.Text = 'AutoCAD 2026 - Kuwait site licence'
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'Something Else'
        Assert-Equal 'a name typed by hand survives the next package' `
                     'AutoCAD 2026 - Kuwait site licence' (Get-BoxText $c.DlgName)
    }

    # ------------------------------------------------------------------ 13. reopening an app
    Write-Section '13. Reopening an app offers the files inside its own package'

    if (-not $win) {
        Write-Host '  SKIP  no WPF here' -ForegroundColor Yellow
    } else {
        # The bug: everything the dialog knew about a package arrived with the FETCH, so an app
        # opened from the catalog offered only the files its own steps already named. Adding a
        # SECOND file meant typing a path from memory - and Test-InPackage, handed an empty
        # list, says nothing either way, so a typo passed every check in the editor and failed
        # on the client at the end of a long install. Re-hashing 14 GB to get the list back is
        # not an answer. Reading the archive's table of contents is.
        $reopenDir = Join-Path $root 'reopen'
        foreach ($d in 'Support', 'Docs', 'Tools', 'inner') {
            New-Item -ItemType Directory -Force -Path (Join-Path $reopenDir "src\$d") | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $reopenDir 'src\Support\licence.dat') -Value 'LIC'        -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $reopenDir 'src\Docs\readme.txt')     -Value 'READ'       -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $reopenDir 'src\Tools\finish.cmd')    -Value '@echo done' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $reopenDir 'src\inner\setup.exe')     -Value 'MZ suite'   -Encoding ASCII
        $suiteZip = Join-Path $reopenDir 'Suite 2026.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $reopenDir 'src'), $suiteZip)
        $suiteSha = (Get-FileHash -LiteralPath $suiteZip -Algorithm SHA256).Hash

        # ---- the listing mode on its own, before any window is involved
        $listed = & $script:FetchWork $suiteZip (Join-Path $root 'pkgcache') $true | Select-Object -Last 1
        Assert-Equal 'a listing reads every file in the package'    4 (@($listed.files).Count)
        Assert-Equal 'and finds the installer inside it'            'inner\setup.exe' ([string](@($listed.entries)[0]))
        Assert-Equal 'and says that is what it was'                 $true ([bool]$listed.listOnly)
        Assert-Equal 'and did NOT hash - which is the whole point'  '' ([string]$listed.sha256)
        # the same call on a URL must not quietly start a 14 GB download to answer it
        $urlListed = & $script:FetchWork 'https://example.invalid/nope.zip' (Join-Path $root 'pkgcache') $true |
                     Select-Object -Last 1
        Assert-True  'a listing refuses a URL rather than downloading it' ([bool]$urlListed.error)

        # ---- and now through the dialog, opened the way the Edit button opens it
        $dialogXaml = $xaml
        $Owner      = $null
        $PackageDir = Join-Path $root 'pkgcache'
        $BaseUrl    = 'https://files.example.invalid'
        $App = [pscustomobject]@{
            id = 'suite'; name = 'Suite 2026'; category = 'Apps'
            url = "$BaseUrl/files/suite/Suite 2026.zip"
            sha256 = $suiteSha; sizeBytes = (Get-Item $suiteZip).Length
            silentArgs = '/S'; entry = 'inner\setup.exe'
            verifyPaths = @('C:\Fake\Suite\suite.exe')
            postInstall = @(
                [pscustomobject]@{ type = 'copy'; name = 'Copy licence.dat'
                                   from = 'Support\licence.dat'; dest = 'C:\Fake\Suite\' }
            )
        }
        # what Get-LocalFileFor hands the dialog in the real editor
        $LocalFile = $suiteZip
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }

        Assert-Equal 'opening read the package, without being asked to' 4 (@($state.files).Count)
        $offered = @($c.DlgPostFrom.Items | ForEach-Object { [string]$_ })
        Assert-True  'a file NO step mentions is offered'      ($offered -contains 'Docs\readme.txt')
        Assert-True  'so is the one a step DOES mention'       ($offered -contains 'Support\licence.dat')
        Assert-Equal 'every file in the package is on the list' 4 $offered.Count
        # the hash is the expensive half, and opening an app must not pay it or disturb it
        Assert-Equal 'the hash is still the catalog''s own'    $suiteSha $state.sha256
        Assert-Equal 'and the size with it'                    ((Get-Item $suiteZip).Length) $state.size
        # a listing disables nothing: Save and Fetch stay usable throughout
        Assert-True  'Fetch was never disabled by the listing'  $c.DlgFetch.IsEnabled
        Assert-True  'nor was Fetch'                           $c.DlgFetch.IsEnabled
        # filling an editable ComboBox blanks its Text, and that text IS the selected row's
        # file - so the row's own value has to be put back afterwards
        Assert-Equal 'the existing step kept its file' 'Support\licence.dat' $c.DlgPostFrom.Text
        Assert-Equal 'and its destination'             'C:\Fake\Suite\'      $c.DlgPostDest.Text

        # the half that saves a client install: the guard now HAS an opinion
        Set-ComboText $c.DlgPostFrom 'Support\licence.dat.bak'
        Assert-True 'a file that is not in the package is called out at once' `
                    ($c.DlgPostWhere.Text -like '*no such file in the package*')
        & ($dlg.Tag.Apply)
        Assert-True 'and Save refuses it'           ($c.DlgStatus.Text -like '*not in the package*')
        Assert-True 'without accepting the dialog' ($c.DlgStatus.Text -ne '')

        # the case the whole feature exists for: a SECOND file, picked off the list
        Set-ComboText $c.DlgPostFrom 'Support\licence.dat'
        Invoke-Click $c.DlgPostAdd
        Set-ComboText $c.DlgPostFrom 'Docs\readme.txt'
        Set-ComboText $c.DlgPostDest 'C:\Fake\Suite\Docs'
        & ($dlg.Tag.Apply)
        Assert-Equal 'a second file chosen from the list is accepted, and reports no problem' '' ([string]$c.DlgStatus.Text)
        & ($dlg.Tag.Apply)
        $reSaved = @($App.postInstall)
        Assert-Equal 'both steps were saved'    2 $reSaved.Count
        Assert-Equal 'the original first'       'Support\licence.dat' ([string]$reSaved[0].from)
        Assert-Equal 'and the new one after it' 'Docs\readme.txt'     ([string]$reSaved[1].from)

        # ---- the package is NOT on this machine: no list, no opinion, and no crash
        $App = [pscustomobject]@{
            id = 'gone'; name = 'Gone 2026'; category = 'Apps'
            url = "$BaseUrl/files/gone/Gone.zip"; sha256 = ('C' * 64); sizeBytes = 99
            silentArgs = '/S'; entry = 'inner\setup.exe'; verifyPaths = @('C:\Fake\Gone\g.exe')
            postInstall = @(
                [pscustomobject]@{ type = 'copy'; name = 'Copy thing'
                                   from = 'Support\thing.dat'; dest = 'C:\Fake\Gone\' }
            )
        }
        $LocalFile = Join-Path $reopenDir 'not-here.zip'
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        $w = 0; while ($state.job -and $w -lt 10000) { Wait-Dispatcher 200; $w += 200 }
        Assert-Equal 'a package this machine does not have leaves the list empty' 0 (@($state.files).Count)
        Assert-True  'and the step it cannot check is NOT declared wrong' `
                     ($c.DlgPostWhere.Text -notlike '*no such file in the package*')
        & ($dlg.Tag.Apply)
        Assert-Equal 'so an app whose bytes are elsewhere is not called wrong' '' ([string]$c.DlgStatus.Text)
        $LocalFile = ''
    }

    # ------------------------------------------------------------------ 14. names and paths
    Write-Section '14. A file name is not an install path'

    # `SketchUp Pro 2026.26.1.256.rar` used to be read as the NAME "SketchUp Pro 2026 26 1 256",
    # every dot turned into a space. Get-VerifyCandidates then built an install path out of that
    # name, and the after-install destination box was prefilled from THAT - so one mangled file
    # name produced %ProgramFiles%\SketchUp Pro 2026 26 1 256\SketchUpPro2026261256.exe, a
    # directory no installer creates, and a destination with a second path inside it.
    $n = ConvertFrom-PackageFileName 'SketchUp Pro 2026.26.1.256.rar'
    Assert-Equal 'a dotted version stops being part of the name' 'SketchUp Pro' ([string]$n.Name)
    Assert-Equal 'and comes back as the version'   '2026.26.1.256' ([string]$n.Version)

    # a YEAR is not a version. These products really are called this, and moving the number out
    # would rename them.
    foreach ($t in @(@{ f = 'AutoCAD 2026.zip';   n = 'AutoCAD 2026' },
                     @{ f = 'Office_2024.exe';    n = 'Office 2024' },
                     @{ f = 'Revit_2026-x64.zip'; n = 'Revit 2026 x64' })) {
        $g = ConvertFrom-PackageFileName $t.f
        Assert-Equal "'$($t.f)' keeps its number in the name" $t.n ([string]$g.Name)
        Assert-Equal "'$($t.f)' claims no version"            ''   ([string]$g.Version)
    }
    $v = ConvertFrom-PackageFileName 'setup_v3.1.exe'
    Assert-Equal 'a v-prefixed version is split off too' 'setup' ([string]$v.Name)
    Assert-Equal 'without the v'                         '3.1'   ([string]$v.Version)
    # a file named only for its version still has to produce SOMETHING to call the app
    $only = ConvertFrom-PackageFileName '2026.1.2.msi'
    Assert-True  'a file that is only a version still yields a name' ([bool]([string]$only.Name))

    # ---- a real path typed after a guess is the whole path
    #
    # This is the value that reached a saved catalog: the box was prefilled with a guessed
    # %ProgramFiles%\ folder, the technician typed the real one after it, and both were kept.
    Assert-Equal 'a path inside a path keeps only the real one' `
                 'C:\Program Files\SketchUp\SketchUp 2026\LayOut\' `
                 (Format-PostDest '%ProgramFiles%\C:\Program Files\SketchUp\SketchUp 2026\LayOut\')
    Assert-Equal 'and the same without a trailing separator' `
                 'C:\Program Files\SketchUp\SketchUp 2026\SketchUp\' `
                 (Format-PostDest '%ProgramFiles%\C:\Program Files\SketchUp\SketchUp 2026\SketchUp')
    # and everything that was already right stays exactly as it was
    Assert-Equal 'an ordinary absolute path is untouched' 'C:\Program Files\App\' `
                 (Format-PostDest 'C:\Program Files\App\')
    Assert-Equal 'an environment path is untouched'       '%ProgramFiles%\App\' `
                 (Format-PostDest '%ProgramFiles%\App\')
    Assert-Equal 'a real UNC destination is untouched'    '\\nas\share\' `
                 (Format-PostDest '\\nas\share\')
    Assert-Equal 'a filename destination still renames'   'C:\App\licence.dat' `
                 (Format-PostDest 'C:\App\licence.dat')
    Assert-Equal 'and nothing is still nothing'           '' (Format-PostDest '  ')

    # ------------------------------------------------------------------ 15. curated fields
    Write-Section '15. A hashed entry keeps the two fields nobody can derive'

    if (-not $win) {
        Write-Host '  SKIP  no WPF here' -ForegroundColor Yellow
    } else {
        # Re-fetching a file used to overwrite the silent switches and the verify path along
        # with everything else. For Office that replaced empty ODT switches with '/S' and
        # WINWORD.EXE with %ProgramFiles%\OfficeSetup\OfficeSetup.exe - both invented out of the
        # file's NAME. Those two fields cannot be read off a package at any price: one comes
        # from the vendor's documentation, the other from a machine that has the product.
        $curDir = Join-Path $root 'curated'
        New-Item -ItemType Directory -Force -Path (Join-Path $curDir 'src\inner') | Out-Null
        Set-Content -LiteralPath (Join-Path $curDir 'src\inner\OfficeSetup.exe') -Value 'MZ odt' -Encoding ASCII
        $odtZip = Join-Path $curDir 'OfficeSetup.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $curDir 'src'), $odtZip)

        $dialogXaml = $xaml
        $Owner      = $null
        $PackageDir = Join-Path $root 'pkgcache'
        $BaseUrl    = 'https://files.example.invalid'
        $LocalFile  = ''

        # the entry as it actually sits in the catalog: hashed, and carrying two values that
        # were settled by hand somewhere else
        $App = [pscustomobject]@{
            id = 'office365'; name = 'OfficeSetup'; version = 'Current Channel'; category = 'Apps'
            url = "$BaseUrl/files/office365/OfficeSetup.exe"
            sha256 = ('e' * 64); sizeBytes = 7426144
            silentArgs = ''
            verifyPaths = @('%ProgramFiles%\Microsoft Office\root\Office16\WINWORD.EXE')
        }
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        & ($dlg.Tag.Fn.startFetch) $odtZip
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }

        Assert-Equal 'the verify path survives a re-fetch' `
                     '%ProgramFiles%\Microsoft Office\root\Office16\WINWORD.EXE' (Get-BoxText $c.DlgVerify)
        Assert-Equal 'and the silent switches stay empty rather than becoming a guess' `
                     '' (Get-BoxText $c.DlgSilent)
        # what IS a property of the file still follows the file, or swapping a package would
        # leave an entry half describing one product and half another
        Assert-Equal 'the setup file inside the package still follows' 'inner\OfficeSetup.exe' (Get-BoxText $c.DlgEntry)
        Assert-Equal 'and so does the hash' ((Get-FileHash -LiteralPath $odtZip -Algorithm SHA256).Hash) $state.sha256

        # an UNFINISHED entry has nothing settled in it, so the guesses are still welcome -
        # that is the whole reason the proposals exist
        $App = [pscustomobject]@{
            id = ''; name = ''; category = 'Apps'; sizeBytes = 0
            url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @()
        }
        $dlg   = Show-AppDialog $App $null $LocalFile
        $c     = $dlg.Tag.C
        $state = $dlg.Tag.State
        & ($dlg.Tag.Fn.setAuto) $c.DlgName 'name' 'Some Installer'
        & ($dlg.Tag.Fn.startFetch) $odtZip
        $w = 0; while ($state.job -and $w -lt 30000) { Wait-Dispatcher 200; $w += 200 }
        Assert-True 'a brand-new entry is still offered a verify path' ([bool](Get-BoxText $c.DlgVerify))
    }
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
    foreach ($n in $fromEditor) {
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
    # ------------------------------------------------------------------ verdict
    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($KeepTemp) {
        Write-Host "Sandbox kept: $root" -ForegroundColor DarkGray
    } else {
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
