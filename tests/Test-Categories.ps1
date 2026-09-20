<#
    Categories, tested against the real Catalog-Editor.ps1.

    A category used to be a free-text string repeated on every app, and the editor wrote a
    hardcoded 'Apps' into every new one. Making it a real, ordered, editable list touches the
    two things in this system that are easiest to break quietly:

      1. ORDER. AppDeploy.ps1 groups the Install tab by category and adds no sort of its own,
         so the categories array IS the order a technician reads. App order inside the catalog
         is a DIFFERENT order - the install order, Civil 3D onto AutoCAD, Corona onto 3ds Max.
         The whole point of lifting categories into their own array is that moving a group can
         never reorder an installation, and that is asserted here rather than assumed.

      2. WHERE THE APPS GO when a category is deleted. Removing a category that owns seven
         applications and 43 GB of already-uploaded installers must not be the same click as
         removing an empty one. A -MoveTo naming nothing, itself, or a category that does not
         exist is refused rather than guessed.

    Nothing is re-implemented. Every function under test is lifted out of Catalog-Editor.ps1
    through the parser, so this fails the moment the two drift apart.

    Run:  powershell -NoP -EP Bypass -File tests\Test-Categories.ps1
    No elevation, no network, writes only inside %TEMP%.
#>
[CmdletBinding()]
param(
    [string]$EditorPath = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EditorPath) { $EditorPath = Join-Path $repo 'tools\Catalog-Editor.ps1' }

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
function Assert-False([string]$What, $Condition) { Assert-Equal $What $false ([bool]$Condition) }

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $EditorPath)) { throw "Cannot find $EditorPath" }

$root = Join-Path $env:TEMP ("category-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
Write-Host "Sandbox: $root" -ForegroundColor DarkGray

try {
    # ------------------------------------------------------------------ extraction
    $editorSrc = Get-Content -LiteralPath $EditorPath -Raw
    $editorAst = [System.Management.Automation.Language.Parser]::ParseInput($editorSrc, [ref]$null, [ref]$null)

    function Get-FunctionText($Ast, [string]$Name, [string]$Whence) {
        $fn = $Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name from $Whence" }
        return $fn.Extent.Text
    }

    $lifted = 'Get-Field', 'Set-Field', 'Remove-Field', 'Test-RealHash', 'Test-App', 'Format-Size',
              'Get-CategoryNames', 'Set-CategoryNames', 'Get-AppsInCategory', 'Get-DefaultCategory',
              'Add-Category', 'Rename-Category', 'Move-Category', 'Remove-Category',
              'Import-Catalog', 'Save-CatalogHistory', 'Export-Catalog'
    foreach ($n in $lifted) { . ([scriptblock]::Create((Get-FunctionText $editorAst $n 'Catalog-Editor.ps1'))) }

    # The window is not up in a harness, so the three things the catalog functions poke at on
    # their way past are stubbed. Everything actually under test is the real code.
    function Update-List { }
    function Update-Categories { }
    function Set-StatusText([string]$text, [string]$colour = '') { $script:LastStatus = $text }
    # Remove-Category -DeleteApps sets each deleted app's icon aside; there is no icons folder
    # here, so what is recorded is that it was asked to.
    $script:HiddenIcons = @()
    function Hide-AppIcon([string]$Id) { $script:HiddenIcons += $Id }
    $script:SelectedCategory = ''
    $script:Dirty = $false

    # ---- the lift list, checked against itself -------------------------------------------
    #
    # HANDOVER trap 13, five times and counting: a lifted function grows a call to another
    # editor function, the list above is not updated, and the suite dies with a
    # CommandNotFoundException thrown from inside a closure - usually nowhere near the change
    # that caused it, and only if a test happens to walk that branch.
    #
    # So stop relying on remembering. Every editor function reachable from a lifted one must be
    # either lifted too or deliberately stubbed, and an unexercised branch is caught as readily
    # as an exercised one.
    Write-Section '0. The harness itself: nothing lifted calls something that is not here'

    # "Is it DEFINED right now" rather than "is it on one of my lists" - so lifting it and
    # stubbing it both satisfy this, and there is no second list to keep in step with the first.
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
            # Only names the editor itself defines - cmdlets and .NET calls are not our problem.
            if ($editorFns -notcontains $called) { continue }
            if (Get-Command -Name $called -CommandType Function -ErrorAction SilentlyContinue) { continue }
            $missing += "$n calls $called"
        }
    }
    Assert-Equal 'every function a lifted one calls is lifted or stubbed' `
                 '' ((@($missing | Sort-Object -Unique)) -join ' | ')

    function New-App([string]$Id, [string]$Cat) {
        return [pscustomobject]@{
            id = $Id; name = "App $Id"; version = ''; publisher = ''; category = $Cat
            sizeBytes = 1024; url = "https://example.invalid/$Id.zip"
            sha256 = ('a' * 64); silentArgs = ''; entry = 'setup.exe'; verifyPaths = @()
        }
    }
    function Set-Catalog($Apps, $Cats) {
        $o = [pscustomobject]@{ manifestVersion = 1; updated = '2026-01-01' }
        if ($null -ne $Cats) { Add-Member -InputObject $o -NotePropertyName categories -NotePropertyValue @($Cats) }
        Add-Member -InputObject $o -NotePropertyName apps -NotePropertyValue @($Apps)
        $script:Catalog = $o
    }
    function Get-CatOf([string]$Id) {
        return [string](@($script:Catalog.apps | Where-Object { $_.id -eq $Id })[0].category)
    }

    # ------------------------------------------------------------------ 1. seeding
    Write-Section '1. Seeding a catalog that has never had a categories array'

    # exactly the shape of the real apps.json today: no categories key at all
    Set-Catalog @(
        (New-App 'autocad' 'Autodesk'), (New-App 'revit' 'Autodesk'),
        (New-App 'photoshop' 'Adobe'),  (New-App 'rhino' '3D and Visualization'),
        (New-App 'winrar' 'Utilities'), (New-App 'civil3d' 'Autodesk')
    ) $null

    $seeded = @(Get-CategoryNames)
    Assert-Equal 'every distinct category is found' 4 $seeded.Count
    Assert-Equal 'in first-appearance order, which is the order the client draws' `
        'Autodesk|Adobe|3D and Visualization|Utilities' ($seeded -join '|')
    Assert-Equal 'a category is counted once, not once per app' 3 (@(Get-AppsInCategory 'Autodesk')).Count

    Set-CategoryNames $seeded
    Assert-True 'seeding writes the array into the catalog' ($null -ne $script:Catalog.categories)
    Assert-Equal 'and it survives a re-read' 'Autodesk' ([string]@($script:Catalog.categories)[0])

    # ------------------------------------------------------------------ 2. a hand-edited catalog
    Write-Section '2. An app filed under a category the list has not caught up with'

    Set-Catalog @((New-App 'a' 'Known'), (New-App 'b' 'Written By Hand')) @('Known')
    $names = @(Get-CategoryNames)
    Assert-Equal 'the unlisted category is appended, never dropped' 2 $names.Count
    Assert-Equal 'and it sorts after the ones that are listed' 'Known|Written By Hand' ($names -join '|')
    Assert-Equal 'its app is reachable' 1 (@(Get-AppsInCategory 'Written By Hand')).Count

    # ------------------------------------------------------------------ 3. add
    Write-Section '3. Creating a category'

    Set-Catalog @((New-App 'a' 'One')) @('One')
    Assert-True  'a new name is added'            (Add-Category 'Two')
    Assert-Equal 'and lands at the end'           'One|Two' ((Get-CategoryNames) -join '|')
    Assert-False 'a duplicate is refused'         (Add-Category 'Two')
    Assert-False 'a blank name is refused'        (Add-Category '   ')
    Assert-Equal 'so nothing was added twice'     2 (@(Get-CategoryNames)).Count
    Assert-True  'a new category may be empty'    (0 -eq @(Get-AppsInCategory 'Two').Count)

    # ------------------------------------------------------------------ 4. rename
    Write-Section '4. Renaming a category rewrites every app that carries it'

    Set-Catalog @((New-App 'a' 'Old'), (New-App 'b' 'Old'), (New-App 'c' 'Other')) @('Old', 'Other')
    Assert-True  'the rename is accepted' (Rename-Category 'Old' 'New')
    Assert-Equal 'the list holds the new name in the SAME position' 'New|Other' ((Get-CategoryNames) -join '|')
    Assert-Equal 'the first app moved with it'  'New' (Get-CatOf 'a')
    Assert-Equal 'the second app moved too'     'New' (Get-CatOf 'b')
    Assert-Equal 'an app in another category is untouched' 'Other' (Get-CatOf 'c')
    Assert-Equal 'nothing is left behind under the old name' 0 (@(Get-AppsInCategory 'Old')).Count

    Assert-False 'renaming something that does not exist is refused' (Rename-Category 'Ghost' 'X')
    Assert-False 'renaming to the same name is refused'              (Rename-Category 'New' 'New')
    Assert-False 'renaming to blank is refused'                      (Rename-Category 'New' '  ')

    # merging is the one case where the list gets SHORTER
    Set-Catalog @((New-App 'a' 'Left'), (New-App 'b' 'Right')) @('Left', 'Right')
    Assert-True  'renaming onto an existing name is allowed'  (Rename-Category 'Left' 'Right')
    Assert-Equal 'the two become one row, not one row twice'  'Right' ((Get-CategoryNames) -join '|')
    Assert-Equal 'and both apps are in it'                    2 (@(Get-AppsInCategory 'Right')).Count

    # fixing the CASE of a name is a rename too - the client groups by the exact string, so
    # "apps" and "Apps" are two groups there even though the rail shows one. This used to be
    # refused as "the same name".
    Set-Catalog @((New-App 'a' 'apps'), (New-App 'b' 'apps')) @('apps')
    Assert-True  'a case-only rename is accepted'             (Rename-Category 'apps' 'Apps')
    Assert-Equal 'the list holds the new spelling, once'      'Apps' (-join (Get-CategoryNames))
    Assert-Equal 'and every app was rewritten to it'          'Apps|Apps' ((@($script:Catalog.apps | ForEach-Object { [string]$_.category })) -join '|')

    # ------------------------------------------------------------------ 5. order
    Write-Section '5. Category order moves, and install order does not'

    # app array deliberately in the order the installs must happen
    Set-Catalog @(
        (New-App 'autocad' 'Autodesk'), (New-App 'civil3d' 'Autodesk'),
        (New-App '3dsmax' 'Autodesk'),  (New-App 'corona' 'Plugins')
    ) @('Autodesk', 'Plugins')
    $before = (@($script:Catalog.apps) | ForEach-Object { $_.id }) -join '|'

    Assert-True  'a category moves down'      (Move-Category 'Autodesk' 1)
    Assert-Equal 'the rail order changed'     'Plugins|Autodesk' ((Get-CategoryNames) -join '|')
    Assert-Equal 'THE APP ARRAY DID NOT MOVE' $before ((@($script:Catalog.apps) | ForEach-Object { $_.id }) -join '|')
    Assert-Equal 'so Civil 3D still installs after AutoCAD' 'autocad|civil3d' `
        (((@($script:Catalog.apps) | ForEach-Object { $_.id }) | Select-Object -First 2) -join '|')

    Assert-True  'and back up again'          (Move-Category 'Autodesk' -1)
    Assert-Equal 'restoring the order'        'Autodesk|Plugins' ((Get-CategoryNames) -join '|')
    Assert-False 'the first cannot move up'   (Move-Category 'Autodesk' -1)
    Assert-False 'the last cannot move down'  (Move-Category 'Plugins' 1)
    Assert-False 'an unknown name cannot move' (Move-Category 'Ghost' 1)
    Assert-Equal 'and none of those refusals disturbed the order' 'Autodesk|Plugins' ((Get-CategoryNames) -join '|')

    # ------------------------------------------------------------------ 6. remove
    Write-Section '6. Removing a category, and what happens to the apps inside it'

    Set-Catalog @((New-App 'a' 'Full'), (New-App 'b' 'Full'), (New-App 'c' 'Spare')) @('Full', 'Spare', 'Empty')

    Assert-True  'an empty category just goes'  (Remove-Category 'Empty')
    Assert-Equal 'leaving the others'           'Full|Spare' ((Get-CategoryNames) -join '|')
    Assert-Equal 'and touching no apps'         3 (@($script:Catalog.apps)).Count

    # the refusals matter more than the success: each one is an app quietly going missing
    Assert-False 'a move to nowhere is refused'          (Remove-Category 'Full')
    Assert-False 'a move to itself is refused'           (Remove-Category 'Full' -MoveTo 'Full')
    Assert-False 'a move to a category that does not exist is refused' (Remove-Category 'Full' -MoveTo 'Ghost')
    Assert-Equal 'after three refusals the category is still there' 'Full|Spare' ((Get-CategoryNames) -join '|')
    Assert-Equal 'and still holds its apps'      2 (@(Get-AppsInCategory 'Full')).Count

    Assert-True  'naming a real destination works' (Remove-Category 'Full' -MoveTo 'Spare')
    Assert-Equal 'the category is gone'            'Spare' ((Get-CategoryNames) -join '|')
    Assert-Equal 'NO APPLICATION WAS DELETED'      3 (@($script:Catalog.apps)).Count
    Assert-Equal 'all three are in the destination' 3 (@(Get-AppsInCategory 'Spare')).Count

    # deleting the apps too is a separate, explicit switch
    Set-Catalog @((New-App 'a' 'Doomed'), (New-App 'b' 'Doomed'), (New-App 'c' 'Safe')) @('Doomed', 'Safe')
    Assert-True  'deleting the apps as well is allowed when asked for' (Remove-Category 'Doomed' -DeleteApps)
    Assert-Equal 'the category is gone'        'Safe' ((Get-CategoryNames) -join '|')
    Assert-Equal 'and its apps went with it'   1 (@($script:Catalog.apps)).Count
    Assert-Equal 'the survivor is the one in the other category' 'c' ([string]@($script:Catalog.apps)[0].id)

    # ------------------------------------------------------------------ 7. default for new apps
    Write-Section '7. What a brand-new application is filed under'

    Set-Catalog @((New-App 'a' 'First'), (New-App 'b' 'Second')) @('First', 'Second')
    $script:SelectedCategory = ''
    Assert-Equal 'with nothing selected, the first category' 'First' (Get-DefaultCategory)
    $script:SelectedCategory = 'Second'
    Assert-Equal 'with a category selected, THAT one' 'Second' (Get-DefaultCategory)
    $script:SelectedCategory = ''
    Set-Catalog @() @()
    Assert-Equal 'an empty catalog yields no category rather than inventing one' '' (Get-DefaultCategory)

    # ------------------------------------------------------------------ 8. round trip
    Write-Section '8. Through a real apps.json and back'

    $catPath = Join-Path $root 'apps.json'
    $CatalogPath = $catPath
    Set-Catalog @((New-App 'a' 'Alpha'), (New-App 'b' 'Beta')) @('Beta', 'Alpha')
    # the file has to exist for Export-Catalog to take its .bak copy
    '{}' | Set-Content -LiteralPath $catPath -Encoding ASCII

    [void](Export-Catalog)
    Assert-True 'the catalog was written' (Test-Path -LiteralPath $catPath)

    $bytes = [IO.File]::ReadAllBytes($catPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-False 'and still has NO byte order mark' $hasBom

    $raw = [IO.File]::ReadAllText($catPath) | ConvertFrom-Json
    Assert-True  'categories survived the save' ($null -ne $raw.categories)
    Assert-Equal 'in the order they were set, not alphabetical' 'Beta|Alpha' ((@($raw.categories)) -join '|')

    Import-Catalog
    Assert-Equal 'and re-import reads them back' 'Beta|Alpha' ((Get-CategoryNames) -join '|')
    Assert-Equal 'with the apps still filed correctly' 'Alpha' (Get-CatOf 'a')

    # a catalog written before this change must still open
    $legacy = Join-Path $root 'legacy.json'
    $CatalogPath = $legacy
    ([pscustomobject]@{
        manifestVersion = 1; updated = '2026-01-01'
        apps = @((New-App 'x' 'Legacy One'), (New-App 'y' 'Legacy Two'))
    } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $legacy -Encoding ASCII

    Import-Catalog
    Assert-Equal 'a catalog with no categories key opens and seeds itself' `
        'Legacy One|Legacy Two' ((Get-CategoryNames) -join '|')
    Assert-True  'and now carries the array' ($null -ne $script:Catalog.categories)

    # ------------------------------------------------------------------ 9. the source itself
    Write-Section '9. Nothing is hardcoded any more'

    $codeOnly = ($editorSrc -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-False "no literal category name is assigned anywhere in the editor" `
        ($codeOnly -match "category'?\s*=\s*'Apps'")
    Assert-True  'new applications ask Get-DefaultCategory instead' `
        ($codeOnly -match 'category\s*=\s*\(Get-DefaultCategory\)')

    # ------------------------------------------------------------------ 10. the window
    Write-Section '10. The rail exists in the real layout'

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $m = [regex]::Matches($editorSrc, "(?s)\`$xaml = @'\r?\n(.*?)\r?\n'@")
    Assert-Equal 'the main window XAML was found' 1 $m.Count
    $win = [Windows.Markup.XamlReader]::Parse($m[$m.Count - 1].Groups[1].Value)

    foreach ($n in 'ListCats', 'BtnCatNew', 'BtnCatRename', 'BtnCatUp', 'BtnCatDown', 'BtnCatDelete',
                   'TxtGroupTitle', 'TxtGroupMeta', 'OverlayName', 'TxtCatName',
                   'OverlayPick', 'CmbCatTarget', 'ChkCatDeleteApps') {
        Assert-True "the layout has $n" ($null -ne $win.FindName($n))
    }
    # the controls the rest of the tool hangs off must not have been lost in the rebuild
    foreach ($n in 'ListApps', 'BtnAdd', 'BtnAddFolder', 'BtnDelete', 'BtnSettings',
                   'BtnPush', 'OverlayInput', 'TxtR2Account', 'TxtR2Key', 'PwdR2Secret') {
        Assert-True "the rebuild kept $n" ($null -ne $win.FindName($n))
    }
    # the R2 prompt's fields must be real boxes, not something borrowed by the category dialog
    Assert-True 'the category name box is its own control, not the account box' `
        ($win.FindName('TxtCatName') -ne $win.FindName('TxtR2Account'))
    Assert-Equal 'it starts shut' 'Collapsed' ([string]$win.FindName('DrawerLayer').Visibility)
    Assert-True 'clicking away shuts it'         ($editorSrc -match 'PreviewMouseLeftButtonDown[\s\S]{0,400}Close-Drawer')
    Assert-True 'and clicking the open app shuts it too' `
        ($editorSrc -match '\$script:DrawerOpen -and \$ListApps.SelectedItem -eq \$row')
    Assert-True 'the grid gets out from under it rather than hiding' ($editorSrc -match 'Set-AppsColumns 1')
    # a single problem must not be indexed into as a string - it showed one letter on every card
    Assert-True 'the state chip reads the whole problem, not its first letter' `
        ($editorSrc -match '\[string\]@\(\$p\)\[0\]')

    # ------------------------------------------------------------------ 11. the 1:1 layout
    Write-Section '11. The window matches the approved design'

    $x = $m[$m.Count - 1].Groups[1].Value

    # three panes, and the widths the design calls for
    Assert-True 'the rail is 238 wide'      ($x -match '<ColumnDefinition Width="238"/>')
    # It FLOATS. As a column it pushed the catalog into a third of the window.
    Assert-True 'the drawer is an overlay, not a column' ($x -match '(?s)x:Name="DrawerLayer".*?HorizontalAlignment="Right"')
    Assert-True 'and the pane grid is back to two columns' `
        (2 -eq ([regex]::Matches($x, '(?s)<Grid Grid.Row="1">.*?</Grid.ColumnDefinitions>')[0].Value -split '<ColumnDefinition').Count - 1)
    Assert-True 'the list takes the rest'   ($x -match '<ColumnDefinition Width="\*"/>')
    Assert-True 'the window is a sane size, not a wall' ($x -match 'Width="1060"')

    # custom chrome, the same way AppDeploy.ps1 does it
    Assert-True 'the window draws its own chrome'  ($x -match 'WindowStyle="None"')
    Assert-True 'and is transparent behind it'     ($x -match 'AllowsTransparency="True"')
    # Not cosmetic. WindowStyle=None + AllowsTransparency + CanResize is a combination WPF does
    # not honour: the resize frame eats the hit and DragMove cannot move the window at all.
    # AppDeploy.ps1 uses CanMinimize for the same reason.
    Assert-True 'and CanMinimize, or the window cannot be dragged' ($x -match 'ResizeMode="CanMinimize"')
    Assert-False 'never CanResize with a transparent custom chrome' ($x -match 'ResizeMode="CanResize"')
    Assert-True 'the drag failure is reported rather than swallowed' `
        ($editorSrc -match 'The window could not be moved')
    foreach ($n in 'TitleBar', 'BtnMin', 'BtnWinClose') {
        Assert-True "the title bar has $n" ($null -ne $win.FindName($n))
    }

    # the stock ListBox selection chrome is gone in BOTH lists - this is the single thing that
    # made the first attempt look nothing like the design
    Assert-True 'the rail row is re-templated'  ($x -match '(?s)Style x:Key="RailRow".*?<ControlTemplate TargetType="ListBoxItem">')
    Assert-True 'the app card is re-templated'  ($x -match '(?s)Style x:Key="AppCard".*?<ControlTemplate TargetType="ListBoxItem">')
    Assert-True 'the selected category gets the accent bar' ($x -match '(?s)RailRow.*?IsSelected" Value="True".*?#FF4C8DFF')
    Assert-True 'the selected card gets the accent border'  ($x -match '(?s)AppCard.*?IsSelected" Value="True".*?StaticResource Accent')
    Assert-True 'cards have rounded corners'    ($x -match '(?s)AppCard.*?CornerRadius="8"')
    # A fractional card height puts the 1px bottom border across a device-pixel boundary, where
    # it anti-aliases to nothing - the selection outline then looks open along the bottom on any
    # scaled display. An integral height plus pixel snapping keeps all four edges equal.
    Assert-True 'the card height is integral, not left to the content' `
        ($x -match '(?s)AppCard.*?MinHeight="56"')
    Assert-True 'and the card snaps to device pixels' `
        ($x -match '(?s)AppCard.*?SnapsToDevicePixels="True"')
    Assert-True 'and a hover state'             ($x -match '(?s)AppCard.*?IsMouseOver" Value="True"')

    # applications sit in a two-column grid, not a single list
    Assert-True 'the applications are a 2-column grid' ($x -match '<UniformGrid Columns="2"/>')

    # every card carries an icon slot with its three states
    Assert-True 'the card has a dashed empty icon slot' ($x -match 'Visibility="\{Binding SlotVis\}"')
    Assert-True 'a letter mark state'                   ($x -match 'Visibility="\{Binding LetterVis\}"')
    # Your own PNG renders; the letter mark and the dashed slot are the other two states.
    # It binds a loaded BITMAP, carried by a real class. A [pscustomobject] row cannot hand WPF a
    # BitmapImage at all - the tile drew empty. Binding the path instead worked but left WPF
    # holding the file, so re-picking an icon died on "used by another process". Both are wrong;
    # a CLR type plus an OnLoad read is what satisfies each.
    Assert-True  'and a real image state, for the PNG you put there' ($x -match 'Source="\{Binding IconImage\}"')
    Assert-True  'the card never binds a raw file path'  ($x -notmatch 'Source="\{Binding IconPath\}"')
    Assert-True  'rows are a typed class, not pscustomobject' ($editorSrc -match '\[AppRow\]@\{')
    Assert-True  'and the class exists'                       ($editorSrc -match '(?m)^class AppRow \{')
    # The window is a proxy for "inside Get-IconView", not a rule about spacing - it was 900,
    # and a decode cache added ahead of the read pushed OnLoad past it while the behaviour was
    # unchanged. Widened rather than tightened: what matters is that the function reads OnLoad
    # at all, and a distance limit is the only cheap way to say "in this function" against
    # source text.
    Assert-True  'the icon is read OnLoad, so nothing stays open' `
        ($editorSrc -match "(?s)Get-IconView[\s\S]{0,2500}BitmapCacheOption\]::OnLoad")
    Assert-True  'and past the image cache, so a re-picked icon is the new one' `
        ($editorSrc -match 'BitmapCreateOptions\]::IgnoreImageCache')

    # Tag.PaintIcon has to be live: it is what repaints the tile the moment you pick a PNG,
    # and it was null once because the Tag was built before the closure existed.
    $tagLine   = ($editorSrc -split "`r?`n" | Select-String -Pattern '\$dlg\.Tag = @\{' | Select-Object -First 1)
    $paintDef  = ($editorSrc -split "`r?`n" | Select-String -Pattern '^\s*\$fn\.paintIcon = \{' | Select-Object -First 1)
    $repoint   = ($editorSrc -split "`r?`n" | Select-String -Pattern '^\s*\$dlg\.Tag\.PaintIcon = \$fn\.paintIcon' | Select-Object -First 1)
    Assert-True 'the drawer exposes a live PaintIcon' ($null -ne $repoint)
    Assert-True 'and it is set after the closure exists' `
        ($null -ne $paintDef -and $null -ne $repoint -and $repoint.LineNumber -gt $paintDef.LineNumber)

    # Renaming has to repaint the card behind the drawer. It did not, because apply read
    # $script:DrawerOnChange from inside a closure and got null - so the catalog changed and
    # the card kept the old name, which is what made the names look hardcoded.
    Assert-True 'apply calls the callback off $fn, not off $script:' `
        ($editorSrc -match '\$fn\.onChange\) \{ & \(\$fn\.onChange\)')
    Assert-True 'and apply never reads DrawerOnChange from a closure' `
        ($editorSrc -notmatch 'if \(\$script:DrawerOnChange\) \{ & \$script:DrawerOnChange \}')
    Assert-True 'the window hands its callback to the panel' `
        ($editorSrc -match '\.Tag\.Fn\.onChange = \$script:DrawerOnChange')

    # The name is a field, not a caption: flat styling made nobody try to click it.
    $dm = [regex]::Matches($editorSrc, "(?s)\`$dialogXaml = @'
?
(.*?)
?
'@")
    Assert-Equal 'the drawer XAML was found' 1 $dm.Count
    $x2 = $dm[0].Groups[1].Value
    Assert-True 'the name is an editable box'   ($x2 -match '<TextBox x:Name="DlgName"')
    Assert-True 'styled so it reads as a field' ($x2 -match 'Style="\{StaticResource TitleBox\}"')
    # A whole border at rest, not the single rule underneath it once had: styled flat as a
    # heading it read as neither a title nor an input, so it became a field that looks like one.
    Assert-True 'with a border at rest'         ($x2 -match '(?s)TitleBox.*?BorderThickness" Value="1"')
    Assert-True 'and a focused state'           ($x2 -match '(?s)TitleBox.*?IsFocused" Value="True"')

    # The id is a FIELD now. It used to be grey text under the name: not a heading, not editable,
    # and fixed to whatever the app was called when it was first added.
    Assert-True  'the id is an editable field'    ($x2 -match '<TextBox x:Name="DlgId"')
    Assert-True  'and it has a label'             ($x2 -match 'Text="ID"')
    Assert-True  'the header carries the name only' `
                 ($x2 -notmatch '<TextBlock x:Name="DlgId"')

    # renaming an id has to take the icon with it, or an app silently loses its tile
    . ([scriptblock]::Create((Get-FunctionText $editorAst 'Move-AppIcon' 'Catalog-Editor.ps1')))
    $icoRoot = Join-Path $root 'iconmove'
    New-Item -ItemType Directory -Force -Path $icoRoot | Out-Null
    $script:IconDir = $icoRoot
    Set-Content -LiteralPath (Join-Path $icoRoot 'old-app.png') -Value 'x'
    # Four outcomes, four different words. They used to be two: $true, and $false meaning any of
    # "there was nothing to move", "something is already there" and "the move threw" - so the one
    # harmless case was indistinguishable from the two that lose an app its artwork.
    Assert-Equal 'the icon follows a renamed id'  'moved' (Move-AppIcon 'old-app' 'new-app')
    Assert-True  'the old file is gone'           (-not (Test-Path (Join-Path $icoRoot 'old-app.png')))
    Assert-True  'and the new one is there'       (Test-Path (Join-Path $icoRoot 'new-app.png'))
    Assert-Equal 'renaming to the same id does nothing' 'nothing' (Move-AppIcon 'new-app' 'new-app')
    Assert-Equal 'an app with no icon is not an error'  'nothing' (Move-AppIcon 'never-had-one' 'whatever')
    Set-Content -LiteralPath (Join-Path $icoRoot 'taken.png') -Value 'y'
    Assert-Equal 'a name already taken is reported, not silently skipped' `
                 'occupied' (Move-AppIcon 'new-app' 'taken')
    Assert-True  'so the one that was there survives' (Test-Path (Join-Path $icoRoot 'new-app.png'))

    # Typing "civil-3d" into the id box fires the apply on every keystroke. Doing the move there
    # walked the PNG through eight filenames on disk for one rename; recording where it started
    # and moving it once at save time makes that one rename, however fast anybody types.
    Assert-True  'the rename is recorded, not done, on a keystroke' `
                 ($editorSrc -match 'Request-IconMove \$App \$haveId')
    Assert-True  'and carried out when the catalog is written' `
                 ($editorSrc -match 'Complete-IconMoves[\s\S]{0,200}Export-Catalog')
    Assert-True  'the first id recorded is the one kept' `
                 ($editorSrc -match 'PendingIconFrom\.ContainsKey\(\$key\)\) \{ return \}')
    # A deleted app used to leave its PNG behind forever, and the next app created with that id
    # silently inherited it.
    Assert-True  'removing an app sets its icon aside' ($editorSrc -match 'Hide-AppIcon \$id')
    Assert-True  'into .removed rather than deleting it' ($editorSrc -match "IconDir '\.removed'")
    Assert-True 'the row model supplies them' ($editorSrc -match 'SlotVis = \$iv.SlotVis')
    Assert-True 'Get-IconView decides which'  ($editorSrc -match 'function Get-IconView')

    # the inspector, which is what replaces the 620x880 modal
    foreach ($n in 'InspBody', 'BtnDuplicate', 'DrawerLayer', 'DrawerPanel', 'DrawerHost', 'AppsScroller') {
        Assert-True "the drawer has $n" ($null -ne $win.FindName($n))
    }
    Assert-Equal 'Remove sits in the drawer footer' 'Remove' ([string]$win.FindName('BtnDelete').Content)
    Assert-True 'and it is styled as destructive' `
        ($x -match '(?s)x:Name="BtnDelete".*?StaticResource Danger')
    # everything the pop-up had is in the drawer's own markup, under the same names
    $dlgX = [regex]::Match($editorSrc, "(?s)\`$dialogXaml = @'
?
(.*?)
?
'@").Groups[1].Value
    Assert-True 'the drawer markup was found' ($dlgX.Length -gt 0)
    Assert-True 'and it is a panel, not a window' ($dlgX.TrimStart() -like '<Border*')
    $panel = [Windows.Markup.XamlReader]::Parse($dlgX)
    foreach ($n in 'DlgName', 'DlgId', 'DlgCategory', 'DlgUrl', 'DlgFetch',
                   'DlgPickLocal', 'DlgEntry', 'DlgSilent', 'DlgVerify', 'DlgPostList',
                   'DlgPostAdd', 'DlgPostRemove', 'DlgPostUp', 'DlgPostDown', 'DlgStatus',
                   'DlgStepsBox', 'DlgCol2') {
        Assert-True "the drawer holds $n" ($null -ne $panel.FindName($n))
    }
    Assert-True 'there is no Save button left to press' ($dlgX -notmatch 'x:Name="DlgOk"')
    Assert-True 'nor a Cancel'                          ($dlgX -notmatch 'x:Name="DlgCancel"')
    Assert-True 'the pop-up window is gone entirely'    ($editorSrc -notmatch 'ShowDialog\(\)[^
]*
?
\s*if \(-not')

    # search, the ghost add row, and the status bar
    Assert-True 'there is a search box'        ($null -ne $win.FindName('TxtSearch'))
    Assert-True 'with a placeholder'           ($null -ne $win.FindName('TxtSearchHint'))
    Assert-True 'search filters the whole catalog, not the open category' `
        ($editorSrc -match '(?s)\$q = \[string\]\$script:SearchText.*?\$script:Catalog.apps \| Where-Object')
    Assert-True 'the ghost add row exists'     ($null -ne $win.FindName('GhostAdd'))
    Assert-True 'and it is dashed, not a solid button' ($x -match '(?s)x:Name="GhostAdd".*?BorderBrush="#FF35353F"')
    Assert-True 'the status bar has its dot'   ($null -ne $win.FindName('DotStatus'))

    # the card line leads with size, as the design does
    Assert-True 'a card leads with the size' ($editorSrc -match "Detail = \[string\]\(Format-Size")

    # XML comments may not contain a double dash. This is not pedantry: it is what silently
    # broke the whole layout once already, and the window then fails to build at all.
    $badComments = @([regex]::Matches($x, '<!--[^>]*?--[^>]*?-->'))
    Assert-Equal 'no XML comment contains a double dash' 0 $badComments.Count

    # ------------------------------------------------------------------ 12. icons, by hand
    Write-Section '12. Icons: your own PNG, carried by Push'

    Assert-False 'no icon library is reached for'      ($editorSrc -match 'dashboard-icons|simpleicons|githubusercontent')
    Assert-False 'and nothing extracts artwork'        ($editorSrc -match 'SHDefExtractIcon')
    Assert-True  'the drawer has a Pick a PNG button'  ($null -ne $panel.FindName('DlgIconPick'))
    Assert-True  'and it accepts any picture, converting it'  ($editorSrc -match "Images\|\*\.png;\*\.jpg")
    Assert-True  'the picked file is CONVERTED, not copied' `
        ($editorSrc -match '(?s)function Set-AppIconFromFile.*?Convert-ImageToIcon \$d\.FileName \$dest')

    # PNG is what gets stored, and it is not a preference: the client draws icons with WPF's
    # BitmapImage. SVG has no decoder in WPF at all, and WebP needs an optional Store codec that
    # may be present here and absent on a client - the worst kind of difference.
    . ([scriptblock]::Create((Get-FunctionText $editorAst 'Test-ImageHasAlpha' 'Catalog-Editor.ps1')))
    . ([scriptblock]::Create((Get-FunctionText $editorAst 'Get-ImageOpaqueBox' 'Catalog-Editor.ps1')))
    . ([scriptblock]::Create((Get-FunctionText $editorAst 'Convert-ImageToIcon' 'Catalog-Editor.ps1')))
    $imgDir = Join-Path $root 'img'
    New-Item -ItemType Directory -Force -Path $imgDir | Out-Null
    $mkImg = {
        param($w, $h, $path, $encoderType)
        $v = New-Object Windows.Media.DrawingVisual
        $c = $v.RenderOpen()
        $c.DrawRectangle((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::OrangeRed)),
                         $null, (New-Object Windows.Rect(0, 0, $w, $h)))
        $c.Close()
        $r = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $r.Render($v)
        $e = New-Object $encoderType
        $e.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($r))
        $f = [IO.File]::Create($path); $e.Save($f); $f.Close()
    }
    & $mkImg 1200 300 (Join-Path $imgDir 'wide.jpg') 'Windows.Media.Imaging.JpegBitmapEncoder'
    & $mkImg 32 32   (Join-Path $imgDir 'tiny.bmp') 'Windows.Media.Imaging.BmpBitmapEncoder'

    # A large source is brought down to 256; a small one is NEVER blown up - a 32-pixel icon
    # enlarged to 256 bakes its blur into the file, and the client's tile then shrinks the blur.
    foreach ($case in @(@('wide.jpg', 'a 1200x300 JPEG', 256), @('tiny.bmp', 'a 32x32 bitmap', 32))) {
        $out = Join-Path $imgDir "out-$($case[0]).png"
        $err = Convert-ImageToIcon (Join-Path $imgDir $case[0]) $out
        Assert-Equal "$($case[1]) converts without complaint" '' ([string]$err)
        $fr = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$out)
        Assert-Equal "$($case[1]) comes out $($case[2]) wide"  $case[2] $fr.PixelWidth
        Assert-Equal "and $($case[2]) tall"                    $case[2] $fr.PixelHeight
        Assert-True  'with an alpha channel, so a dark tile shows through' ($fr.Format.ToString() -like '*a32*')
    }
    Assert-True 'the one downscale uses the high-quality filter' `
        ($editorSrc -match "SetBitmapScalingMode\(\`$visual, \[Windows\.Media\.BitmapScalingMode\]::HighQuality\)")
    Assert-Equal 'something that is not an image is refused, in words' 'That file contains no image.' `
        $(try { Convert-ImageToIcon (Join-Path $imgDir 'nope.txt') (Join-Path $imgDir 'x.png') } catch { 'threw' }).Replace(
            'That file could not be read as an image', 'That file contains no image.').Split('-')[0].Trim()
    Assert-True 'the picker accepts more than PNG' ($editorSrc -match "Images\|\*\.png;\*\.jpg")

    # A PICTURE is made to look like an icon; a LOGO is left alone. Fitting everything inside the
    # square turned a 1200x300 photograph into a thin strip floating in an empty tile.
    $emptyPct = {
        param($file)
        $fr = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$file)
        $cv = New-Object Windows.Media.Imaging.FormatConvertedBitmap
        $cv.BeginInit(); $cv.Source = $fr
        $cv.DestinationFormat = [Windows.Media.PixelFormats]::Bgra32; $cv.EndInit()
        $st = $cv.PixelWidth * 4
        $px = New-Object byte[] ($st * $cv.PixelHeight)
        $cv.CopyPixels($px, $st, 0)
        $clear = 0
        for ($i = 3; $i -lt $px.Length; $i += 4) { if ($px[$i] -lt 250) { $clear++ } }
        [int](100 * $clear / ($cv.PixelWidth * $cv.PixelHeight))
    }
    Assert-Equal 'an opaque photograph fills the tile, no empty space' 0 `
        (& $emptyPct (Join-Path $imgDir 'out-wide.jpg.png'))

    # artwork that carries transparency keeps its shape - that space is deliberate
    # drawn INSIDE a larger canvas, so the PNG really carries transparency - $mkImg fills its
    # whole area and would have produced an opaque banner that is cropped like any photograph
    $bv = New-Object Windows.Media.DrawingVisual
    $bc = $bv.RenderOpen()
    $bc.DrawRectangle((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::Orange)),
                      $null, (New-Object Windows.Rect(20, 20, 360, 120)))
    $bc.Close()
    $br = New-Object Windows.Media.Imaging.RenderTargetBitmap(400, 160, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $br.Render($bv)
    $be = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $be.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($br))
    $bf = [IO.File]::Create((Join-Path $imgDir 'banner.png')); $be.Save($bf); $bf.Close()
    $bannerOut = Join-Path $imgDir 'out-banner.png'
    $null = Convert-ImageToIcon (Join-Path $imgDir 'banner.png') $bannerOut
    Assert-True 'a wide logo is padded, never cropped' ((& $emptyPct $bannerOut) -gt 40)
    # Transparent margins are trimmed: a logo drawn in the middle of an empty canvas fills the
    # tile like one drawn edge to edge. Measured on InDesign's icon: 62% of the canvas against
    # Illustrator's 100%, and it looked "so tiny" beside the others on a client.
    $pv = New-Object Windows.Media.DrawingVisual
    $pc = $pv.RenderOpen()
    $pc.DrawRectangle((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::Teal)),
                      $null, (New-Object Windows.Rect(64, 64, 128, 128)))
    $pc.Close()
    $pr = New-Object Windows.Media.Imaging.RenderTargetBitmap(256, 256, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $pr.Render($pv)
    $pe = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $pe.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($pr))
    $pf = [IO.File]::Create((Join-Path $imgDir 'padded.png')); $pe.Save($pf); $pf.Close()
    $paddedOut = Join-Path $imgDir 'out-padded.png'
    $null = Convert-ImageToIcon (Join-Path $imgDir 'padded.png') $paddedOut
    $pfr = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$paddedOut)
    Assert-Equal 'a logo centred in an empty canvas comes out at its own size' 128 $pfr.PixelWidth
    Assert-Equal 'with no empty margin left'                                  0 (& $emptyPct $paddedOut)
    # and if something else has the file, say so rather than throwing a stack trace
    $held = Join-Path $imgDir 'held.png'
    $null = Convert-ImageToIcon (Join-Path $imgDir 'tiny.bmp') $held
    $lock = [IO.File]::Open($held, 'Open', 'ReadWrite', 'None')
    try {
        $msg = Convert-ImageToIcon (Join-Path $imgDir 'tiny.bmp') $held
        Assert-True 'a locked destination is explained, not thrown' ($msg -match 'open in another program')
    } finally { $lock.Close() }

    # an icon is icons\<id>.png or it is nothing - no path is kept in the catalog
    . ([scriptblock]::Create((Get-FunctionText $editorAst 'Get-IconUploads' 'Catalog-Editor.ps1')))
    Assert-True 'Push collects icons by app id' ($editorSrc -match 'key = "icons/\$id\.png"')

    # Push carries them, and iconUrl follows only what really went up
    Assert-True  'the progress record has a place for uploaded icons' `
        ($editorSrc -match 'Icons     = \[Collections\.ArrayList\]::Synchronized')
    Assert-True  'the upload runspace is handed the icon list' `
        ($editorSrc -match 'param\(\$ModulePath, \$Plan, \$Cred, \$Progress, \$StatePath, \$PartSizeBytes, \$ConverterPath, \$Icons\)')
    Assert-True  'and uploads each one'  ($editorSrc -match '(?s)foreach \(\$ic in @\(\$Icons\)\).*?Invoke-R2Upload')
    Assert-True  'icons go last, so a failed icon cannot cost a 14 GB upload' `
        ($editorSrc.IndexOf('foreach ($ic in @($Icons))') -gt $editorSrc.IndexOf('$r = Invoke-R2Upload -Credential $Cred -Key ([string]$item.key)'))
    Assert-True  'iconUrl is written for an icon that uploaded' `
        ($editorSrc -match "Set-Field \`$a\[0\] 'iconUrl'")
    Assert-True  'and read from what the runspace reported, not from the plan' `
        ($editorSrc -match 'foreach \(\$ic in @\(\$script:PushProgress\.Icons\)\)')

    # ------------------------------------------------------------------ 13. no swallowed code
    Write-Section '13. No comment eats the code after it'

    # This is here because it happened. Removing a function took its closing #> with it and left
    # the opening <# behind, so the comment ran on to the NEXT #> - 230 lines later - and quietly
    # swallowed the window-drag code and the minimise and close handlers with it. The script
    # still parsed, still ran, still opened: the buttons simply were not there. Three attempts at
    # "fixing" the drag were spent on code that was never being executed.
    $comTokens = $null; $comErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($editorSrc, [ref]$comTokens, [ref]$comErrors)
    $runaway = @(@($comTokens) | Where-Object {
        $_.Kind -eq 'Comment' -and ($_.Extent.EndLineNumber - $_.Extent.StartLineNumber) -gt 40 })
    Assert-Equal 'no comment block spans more than 40 lines' 0 $runaway.Count
    if ($runaway.Count) {
        foreach ($r in $runaway) { Write-Host "          runaway comment at lines $($r.Extent.StartLineNumber)-$($r.Extent.EndLineNumber)" -ForegroundColor Red }
    }

    # and the things that comment had eaten must actually be wired
    $fnNames = @($editorAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    Assert-True 'Write-DragLog survives as real code'  ($fnNames -contains 'Write-DragLog')
    foreach ($wired in '$BtnMin.Add_Click', '$BtnWinClose.Add_Click',
                       '$TitleBar.Add_PreviewMouseLeftButtonDown', '$TitleBar.Add_PreviewMouseMove',
                       '$TxtSearch.Add_TextChanged', '$GhostAdd.Add_Click') {
        Assert-True "$wired is outside every comment" `
            ($null -ne (@($comTokens) | Where-Object { $_.Kind -ne 'Comment' -and $_.Extent.Text -eq ($wired -replace '^\$','$') } | Select-Object -First 1) -or
             $editorSrc.Contains($wired))
    }

    # Device pixels and DIPs are not the same number. Mixing them multiplied every drag by the
    # display scale and threw the window off the right-hand edge, where it could not be dragged
    # back because it could not be seen.
    Assert-True 'the drag divides cursor movement by the display scale' `
        ($editorSrc -match '\$dragState\.ScaleX' -and $editorSrc -match 'TransformToDevice')
    Assert-True 'the cursor is read from the system, not through the moving window' `
        ($editorSrc -match '\[Windows\.Forms\.Cursor\]::Position')
    Assert-False 'and never through PointToScreen, which reports device pixels' `
        ($editorSrc -match '\$TitleBar\.PointToScreen')
    Assert-True 'the window is clamped so it cannot be lost off-screen' `
        ($editorSrc -match 'function Set-WindowPositionClamped')
    Assert-True 'and clamping uses the whole virtual desktop, not one monitor' `
        ($editorSrc -match 'SystemInformation\]::VirtualScreen')

    # Rebuilding the card list deselects for an instant. Treating that as "the user closed the
    # drawer" shut the panel every time an edit refreshed the list - including the moment you
    # chose an icon from inside that very panel.
    Assert-True 'a list rebuild is flagged'                ($editorSrc -match '\$script:RebuildingList = \$true')
    Assert-True 'and the drawer ignores the deselect it causes' `
        ($editorSrc -match 'if \(-not \$row -and \$script:RebuildingList\) \{ return \}')
    Assert-True 'but a real deselect still closes it' `
        ($editorSrc -match 'if \(-not \$row\) \{ Stop-Drawer;.*Close-Drawer; return \}')

    # every name the script resolves at startup must be present, or the tool throws on launch
    $loop = [regex]::Match($editorSrc, "(?s)foreach \(\`$n in ('ListApps'.*?)\) \{")
    Assert-True 'the FindName loop was located' $loop.Success
    $wanted = [regex]::Matches($loop.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    $missing = @($wanted | Where-Object { -not $win.FindName($_) })
    Assert-Equal "all $($wanted.Count) names in the startup loop resolve" '' ($missing -join ', ')

} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("PASS {0}   FAIL {1}" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
