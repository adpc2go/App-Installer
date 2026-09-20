<#
.SYNOPSIS
    The Update tab: the winget table parser against captured output, the real GUI headless
    (tab, sub-tabs, Select All / Clear All, the confirm dialog), and - on a lab VM - the elevated
    worker updating a real package and asking the Store for its updates.

.DESCRIPTION
    1. PARSER: Get-WingetUpgrades is lifted out of AppDeploy.ps1 by AST and fed the shapes winget
       actually prints - the plain table, the msstore agreement preamble a fresh machine prints
       before it, the second "require explicit targeting" table, an id cut off with an ellipsis,
       spinner residue, and the "no installed package" answer.
    2. GUI: AppDeploy.ps1 is loaded to its go marker (window built, never shown), the winget call
       is stubbed with a captured sample, and the tab is driven the way a technician drives it.
    3. WORKER (-VM only, elevated, lab host names only): the worker sliced out of AppDeploy.ps1
       runs `winget upgrade` for one real package the VM lists, proves a bogus winget path is
       re-resolved, proves a nonexistent id fails with a hex code, and asks the Store updater.

    Parts 1 and 2 run anywhere, unelevated, and change nothing. Part 3 changes the VM.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-UpdateTab.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-UpdateTab.ps1 -VM     # on the lab VM, elevated
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$VM,
    [string[]]$AllowHosts = @('DESKTOP-854BGVS', 'DESKTOP-RTRU0VA')
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $repo) { $repo = $here }
if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and
         (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
if (-not $ScriptPath) { $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }

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
function Invoke-Click($Button) { $Button.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }

$src = Get-Content -LiteralPath $ScriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)

# ------------------------------------------------------------------ captured winget output
# Real output from the workstation and the Pro VM on 2026-08-29, trimmed. Column offsets matter,
# so these are verbatim widths.
$samplePlain = @'
Name                                                         Id                              Version        Available     Source
--------------------------------------------------------------------------------------------------------------------------------
App Installer                                                Microsoft.AppInstaller          1.29.289.0     1.29.290      winget
Google Chrome                                                Google.Chrome                   151.0.7922.175 152.0.7977.65 winget
Microsoft Visual C++ v14 Redistributable (x64) - 14.50.35719 Microsoft.VCRedist.2015+.x64    14.50.35719.0  14.51.36247.0 winget
Notepad++ (x64)                                              Notepad++.Notepad++             8.9.7          8.9.8         winget
Some Old Tool                                                Vendor.OldTool                  Unknown        2.0.1         winget
Newer Than Catalog                                           Vendor.Newer                    < 3.0          3.0           winget
6 upgrades available.
'@
$samplePreamble = @'
The `msstore` source requires that you view the following agreements before using.
Terms of Transaction: https://aka.ms/microsoft-store-terms-of-transaction
The source requires the current machine's 2-letter geographic region to be sent to the backend service to function properly (ex. "US").

Name                Id                     Version        Available      Source
-------------------------------------------------------------------------------
App Installer       Microsoft.AppInstaller 1.29.289.0     1.29.290       winget
Outlook for Windows Microsoft.Outlook      1.2026.730.100 1.2026.812.100 winget
ChatGPT             9PLM9XGG6VKS           26.820.9563.0  26.901.1.0     msstore
3 upgrades available.
'@
$sampleTwoTables = @'
Name           Id                      Version  Available Source
----------------------------------------------------------------
Tailscale      Tailscale.Tailscale     1.102.2  1.102.3   winget
FFmpeg         Gyan.FFmpeg             9.0      9.0.1     winget
2 upgrades available.

The following packages have an upgrade available, but require explicit targeting for upgrade:
Name    Id              Version  Available Source
-------------------------------------------------
Discord Discord.Discord 1.0.9254 1.0.9255  winget
'@
# the ellipsis is built from its code point: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and
# would mangle a literal one
$sampleBroken = ('-' + [char]8 + '\' + [char]8 + '|' + "`r`n") + (@'
Name                 Id                   Version  Available Source
-------------------------------------------------------------------
Truncated Package    Vendor.VeryLongIdeX  1.0      1.1       winget
Good Package         Vendor.Good          1.0      1.1       winget
2 upgrades available.
'@ -replace 'IdeX', ('Ide' + [char]0x2026))
$sampleNone = @'
No installed package found matching input criteria.
'@

Write-Section '1. Parser: what winget prints, as rows'
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WingetUpgrades' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Get-WingetUpgrades not found in AppDeploy.ps1' }
. ([scriptblock]::Create($fn.Extent.Text))
$script:WingetScanNotes = @()

$r = @(Get-WingetUpgrades $samplePlain)
Assert-Equal 'plain table: 6 rows'                                6 $r.Count
Assert-Equal 'a name with spaces and dashes keeps its id'         'Microsoft.VCRedist.2015+.x64' ($r | Where-Object { $_.Name -like 'Microsoft Visual C++*' }).Id
Assert-Equal 'installed and available versions land in place'    '151.0.7922.175|152.0.7977.65' (($r | Where-Object { $_.Id -eq 'Google.Chrome' } | ForEach-Object { "$($_.Version)|$($_.Available)" }))
Assert-Equal 'Unknown stays literal'                              'Unknown' ($r | Where-Object { $_.Id -eq 'Vendor.OldTool' }).Version
Assert-Equal 'a "< 3.0" version loses the marker'                 '3.0' ($r | Where-Object { $_.Id -eq 'Vendor.Newer' }).Version
Assert-Equal 'every row is winget-sourced and not explicit'       6 @($r | Where-Object { $_.Source -eq 'winget' -and -not $_.Explicit }).Count

$r = @(Get-WingetUpgrades $samplePreamble)
Assert-Equal 'agreement preamble: 3 rows, notices skipped'        3 $r.Count
Assert-Equal 'the msstore row is kept with its source'            'msstore' ($r | Where-Object { $_.Id -eq '9PLM9XGG6VKS' }).Source
Assert-Equal 'two-word name parsed'                               'Outlook for Windows' ($r | Where-Object { $_.Id -eq 'Microsoft.Outlook' }).Name

$r = @(Get-WingetUpgrades $sampleTwoTables)
Assert-Equal 'two tables: 3 rows'                                 3 $r.Count
Assert-Equal 'the second table''s row is flagged Explicit'        $true ($r | Where-Object { $_.Id -eq 'Discord.Discord' }).Explicit
Assert-Equal 'the first table''s rows are not'                    0 @($r | Where-Object { $_.Explicit -and $_.Id -ne 'Discord.Discord' }).Count

$script:WingetScanNotes = @()
$r = @(Get-WingetUpgrades $sampleBroken)
Assert-Equal 'a truncated id is dropped, the good row survives'   'Vendor.Good' (@($r | ForEach-Object { $_.Id }) -join ',')
Assert-True  'and the drop is noted for the hint line'            (@($script:WingetScanNotes | Where-Object { $_ -like 'skipped an unreadable row*' }).Count -eq 1)
Assert-Equal '"no installed package" gives no rows and no throw'  0 @(Get-WingetUpgrades $sampleNone).Count
Assert-Equal 'empty text gives no rows'                           0 @(Get-WingetUpgrades '').Count

# A French client. The header words and the count line are winget resources, so they come out
# localised - the columns are found by position under the rule, never by the English words.
$sampleFrench = @'
Nom                 Identifiant            Version        Disponible     Source
-------------------------------------------------------------------------------
App Installer       Microsoft.AppInstaller 1.29.289.0     1.29.290       winget
Outlook for Windows Microsoft.Outlook      1.2026.730.100 1.2026.812.100 winget
2 mises a niveau disponibles.

Les packages suivants ont une mise a niveau disponible, mais necessitent un ciblage explicite :
Nom     Identifiant     Version  Disponible Source
--------------------------------------------------
Discord Discord.Discord 1.0.9254 1.0.9255   winget
'@
$script:WingetScanNotes = @()
$r = @(Get-WingetUpgrades $sampleFrench)
Assert-Equal 'a localised table: 3 rows, the count line is not one'    3 $r.Count
Assert-Equal 'columns land by position'                              '1.2026.730.100|1.2026.812.100' (($r | Where-Object { $_.Id -eq 'Microsoft.Outlook' } | ForEach-Object { "$($_.Version)|$($_.Available)" }))
Assert-Equal 'the second table is flagged Explicit without the English notice' $true ($r | Where-Object { $_.Id -eq 'Discord.Discord' }).Explicit
Assert-Equal 'and the first table''s rows are not'                   0 @($r | Where-Object { $_.Explicit -and $_.Id -ne 'Discord.Discord' }).Count
Assert-Equal 'no row was reported unreadable'                        0 @($script:WingetScanNotes).Count

# ------------------------------------------------------------------ 1b. the worker's verdicts
Write-Section '1b. Update-One: winget''s own reboot and already-installed codes'
$wLines = $src -split "`r?`n"
$wStart = ($wLines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
$wEnd = ($wLines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $wStart } | Select-Object -First 1).LineNumber
$wAst = [System.Management.Automation.Language.Parser]::ParseInput(($wLines[$wStart..($wEnd - 2)] -join "`r`n"), [ref]$null, [ref]$null)
$uo = $wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-One' }, $true) | Select-Object -First 1
if (-not $uo) { throw 'Update-One not found in the worker' }
. ([scriptblock]::Create($uo.Extent.Text))
function Get-WingetExe($app) { return 'C:\fake\winget.exe' }
function Invoke-Winget([string]$Id, [string]$Name, [string]$Exe, [string[]]$ArgList, [int]$TimeoutSec) { return @{ Code = $script:FakeCode; Output = ''; TimedOut = $false; Cancelled = $false } }
function Write-Status([string]$Id, [string]$State, [string]$Detail) { $script:LastVerdict = @{ state = $State; detail = $Detail } }
function Test-Verdict([int]$Code) {
    $script:FakeCode = $Code; $script:LastVerdict = $null
    Update-One ([pscustomobject]@{ id = 'u'; name = 'Thing'; wingetId = 'Vendor.Thing'; winget = ''; source = ''; installed = '1.0'; available = '1.1' })
    return $script:LastVerdict
}
$v = Test-Verdict 0
Assert-Equal 'exit 0 is Installed'                                         'Installed' $v.state
$v = Test-Verdict -1978334967
Assert-Equal '0x8A150109 (reboot required to finish) is Installed'         'Installed' $v.state
Assert-True  'and says a restart is needed - the phrase the batch counts'  ($v.detail -like '*a restart is needed*')
$v = Test-Verdict -1978334965
Assert-Equal '0x8A15010B (reboot initiated) is Installed'                  'Installed' $v.state
Assert-True  'and says a restart is needed'                                ($v.detail -like '*a restart is needed*')
$v = Test-Verdict 3010
Assert-True  'MSI 3010 uses the same phrase'                               ($v.state -eq 'Installed' -and $v.detail -like '*a restart is needed*')
$v = Test-Verdict -1978334966
Assert-True  '0x8A15010A (reboot required BEFORE install) is Failed, saying restart then retry' ($v.state -eq 'Failed' -and $v.detail -like '*restart*retry*')
$v = Test-Verdict -1978334963
Assert-Equal '0x8A15010D (already installed) is Skipped'                   'Skipped' $v.state
$v = Test-Verdict -1978334975
Assert-True  '0x8A150101 (package in use) names the running program'      ($v.state -eq 'Failed' -and $v.detail -like '*running*close it*')
$v = Test-Verdict -1978335232
Assert-True  'an unmapped code is reported in hex'                         ($v.state -eq 'Failed' -and $v.detail -like '*0x8A150000*')
# the install step must be able to FIND a preview update again: by id alone the agent answers
# nothing for one (measured, KB5120998), so it has to ask for the optional-installation class too
$iw = $wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-WindowsUpdate' }, $true) | Select-Object -First 1
Assert-True  'Install-WindowsUpdate looks a preview up as an optional installation when the plain id search is empty' ($iw -and $iw.Extent.Text -match "UpdateID='\`$id' and DeploymentAction='OptionalInstallation'")
$gw = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WindowsUpdateList' }, $true) | Select-Object -First 1
Assert-True  'and the scan asks for optional installations, so previews are listed at all'   ($gw -and $gw.Extent.Text -match "DeploymentAction='OptionalInstallation'")

# ------------------------------------------------------------------ 2. the real GUI, headless
Write-Section '2. The real GUI (window built, handlers wired, never shown)'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$sandbox = Join-Path $env:TEMP ("upd-tab-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$server = Join-Path $sandbox 'catalog'
New-Item -ItemType Directory -Force -Path $server, (Join-Path $sandbox 'cache') | Out-Null
[IO.File]::WriteAllText((Join-Path $server 'apps.json'),
    ([pscustomobject]@{ updated = (Get-Date -Format 'yyyy-MM-dd'); apps = @() } | ConvertTo-Json -Depth 4),
    (New-Object Text.UTF8Encoding $false))
$goAt = $src.IndexOf('# ---------- go ----------')
if ($goAt -lt 0) { throw 'Could not find the "go" marker in AppDeploy.ps1.' }
. ([scriptblock]::Create($src.Substring(0, $goAt))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
Assert-True 'the window was built'   ($null -ne $window)
Assert-True 'the Update tab exists'  ($null -ne $BtnTabUpdate -and $null -ne $BtnUpdApply)
$script:CacheDir = Join-Path $sandbox 'cache'
$script:IconDir = Join-Path $sandbox 'cache\icons'
New-Item -ItemType Directory -Force -Path $script:IconDir | Out-Null
$timer.Start()   # the poll timer drains the icon pump - without it no row ever gets its image
# the console's crash capture (after the go marker) - a handler exception must land in a file, not kill the run
$crashAt = $src.IndexOf('# ---------- crash capture ----------'); $crashEnd = $src.IndexOf('# The last thing measured', $crashAt)
. ([scriptblock]::Create($src.Substring($crashAt, $crashEnd - $crashAt)))
# the two machine reads, stubbed: winget answers with the captured sample, the Store list is two fakes
function Get-WingetUpgradeText { return $samplePreamble + "`r`n" + $sampleTwoTables }
function Get-StoreApps {
    return @([pscustomobject]@{ Name = 'Fake Calculator'; Version = '11.0.1'; Publisher = 'Microsoft'; Location = ''; Logo = ''; PackageFull = 'Fake.Calc_1.0_x64__abc'; IsSystem = $false },
             [pscustomobject]@{ Name = 'Fake Photos';     Version = '2026.1';  Publisher = 'Microsoft'; Location = ''; Logo = ''; PackageFull = 'Fake.Photos_1.0_x64__abc'; IsSystem = $false })
}
# Windows Update, stubbed: one recommended, one optional driver needing a restart, one optional quality preview
function Get-WindowsUpdateList {
    # shaped exactly as the Update Agent answers on a real machine: a driver and a preview are
    # NOT browse-only - they are optional INSTALLATIONS (Deployment 4) that Windows does not
    # auto-select, which is how Settings files them under Optional updates
    return @([pscustomobject]@{ Id = '11111111-aaaa-4bbb-8ccc-000000000001'; Rev = 200; Title = 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.4)'; KB = 'KB2267602'; Category = 'Definition Updates'; Size = 120MB; Optional = $false; Driver = $false; Reboot = $false; Downloaded = $false; Mandatory = $false; AutoSelect = $true;  Deployment = 1 },
             [pscustomobject]@{ Id = '11111111-aaaa-4bbb-8ccc-000000000002'; Rev = 1;   Title = 'Intel - Net - 22.250.1.1';                                                            KB = '';          Category = 'Drivers';            Size = 3MB;   Optional = $false; Driver = $true;  Reboot = $true;  Downloaded = $false; Mandatory = $false; AutoSelect = $false; Deployment = 4 },
             [pscustomobject]@{ Id = '11111111-aaaa-4bbb-8ccc-000000000003'; Rev = 1;   Title = '2026-08 Cumulative Update Preview for Windows 11 (KB5099999)';                    KB = 'KB5099999'; Category = 'Updates';            Size = 700MB; Optional = $false; Driver = $false; Reboot = $true;  Downloaded = $false; Mandatory = $false; AutoSelect = $true;  Deployment = 4 })
}
# the registry scan the Uninstall tab would do, stubbed: Discord and Tailscale are "installed"
# under names winget does not use verbatim; App Installer / FFmpeg are not desktop programs
function Get-InstalledPrograms {
    return @([pscustomobject]@{ Name = 'Discord (64-bit)';       Version = '1.0.9254'; Publisher = 'Discord Inc.'; Location = ''; Icon = "$env:SystemRoot\System32\notepad.exe"; Exe = ''; RegKey = 'HKCU\...\Discord' },
             [pscustomobject]@{ Name = 'Tailscale 1.102.2 (x64)'; Version = '1.102.2';  Publisher = 'Tailscale Inc.'; Location = ''; Icon = ''; Exe = "$env:SystemRoot\System32\notepad.exe"; RegKey = 'HKLM\...\Tailscale' },
             [pscustomobject]@{ Name = 'Git';                     Version = '2.50';     Publisher = 'The Git Development Community'; Location = ''; Icon = ''; Exe = ''; RegKey = 'HKLM\...\Git' })
}

$strip = $BtnTabInstall.Parent
Assert-True 'tab order: Update, Install, Uninstall' (($strip.Children.IndexOf($BtnTabUpdate) -lt $strip.Children.IndexOf($BtnTabInstall)) -and ($strip.Children.IndexOf($BtnTabInstall) -lt $strip.Children.IndexOf($BtnTabUn)))
Invoke-Click $BtnTabUpdate
Assert-Equal 'the Update panel is shown'                          'Visible' "$($PanelUpdate.Visibility)"
Assert-Equal 'the bottom-bar button reads Update Selected'        'Update Selected' $TxtUpdApplyBtn.Text
Assert-Equal 'desktop rows built from winget (msstore row left out)' 5 $script:UpdItems.Count
Assert-Equal 'nothing is ticked by default'                       0 @($script:UpdItems | Where-Object { $_.IsSelected }).Count
$disc = @($script:UpdItems | Where-Object { $_.UnArgs -eq 'Discord.Discord' })[0]
Assert-Equal 'table cells: installed and available versions'      '1.0.9254|1.0.9255' "$($disc.ColInstalled)|$($disc.ColSize)"
Assert-Equal 'the explicit-targeting row wears the pill and a note' $true (($disc.TagVis -eq 'Visible') -and ($disc.TagText -eq 'needs explicit targeting') -and ($disc.Status -like '*explicit targeting*'))
Assert-Equal 'the header is the Uninstall table''s: PROGRAM lit, sorted A-Z' 'PROGRAM ^' $BtnUpdColName.Content
Invoke-Click $BtnUpdColPub
Assert-Equal 'clicking PUBLISHER sorts by it'                      'Publisher|Ascending' (($script:UpdView.SortDescriptions | ForEach-Object { "$($_.PropertyName)|$($_.Direction)" }) -join ',')
Invoke-Click $BtnUpdColPub
Assert-Equal 'clicking it again turns the sort round'              'PUBLISHER v' $BtnUpdColPub.Content
Invoke-Click $BtnUpdColName
# identity shared with the Uninstall tab: same program, same name, same publisher, its icon requested from the same file
Assert-Equal 'Discord matched the registry entry "Discord (64-bit)"' 'Desktop programs' $disc.Category
Assert-Equal 'kept winget''s name, took the publisher from there'  'Discord|Discord Inc.   |   winget: Discord.Discord' "$($disc.Name)|$($disc.Publisher)"
$ts = @($script:UpdItems | Where-Object { $_.UnArgs -eq 'Tailscale.Tailscale' })[0]
Assert-Equal 'Tailscale matched despite the version and bitness in the registry name' 'Desktop programs' $ts.Category
$ffm = @($script:UpdItems | Where-Object { $_.UnArgs -eq 'Gyan.FFmpeg' })[0]
Assert-True  'FFmpeg (no registry entry) is filed as a component'  ($ffm.Category -like 'Other: components and runtimes*')
Assert-True  'Git was NOT claimed by anything (short names never match by containment)' (@($script:UpdItems | Where-Object { $_.Name -eq 'Git' }).Count -eq 0)
Assert-True  'the hint says how many rows are Uninstall-tab programs' ($TxtUpdHint.Text -like '*2 of them are programs on the Uninstall tab*')
for ($i = 0; $i -lt 100 -and -not $disc.IconImage; $i++) { Update-UI; Start-Sleep -Milliseconds 50 }
Assert-True  'the matched row shows a real icon, pulled the way the Uninstall tab pulls it' ($null -ne $disc.IconImage)
Assert-True  'the hint counts the Store update it left out'       ($TxtUpdHint.Text -like '5 update(s) available*1 Store app(s) also have updates*')
Assert-Equal 'status line: 0 of 5 selected'                       '0 of 5 update(s) selected' $TxtStatus.Text
Invoke-Click $BtnUpdSelAll
Assert-Equal 'Select All ticks every row'                         5 @($script:UpdItems | Where-Object { $_.IsSelected }).Count
Assert-Equal 'status line follows'                                '5 of 5 update(s) selected' $TxtStatus.Text
Invoke-Click $BtnUpdSelNone
Assert-Equal 'Clear All unticks every row'                        0 @($script:UpdItems | Where-Object { $_.IsSelected }).Count
Invoke-Click $BtnUpdApply
Assert-Equal 'Update with nothing ticked: "Nothing selected"'     'Nothing selected' $TxtOverlayTitle.Text
$Overlay.Visibility = 'Collapsed'
$disc.IsSelected = $true
$ai = @($script:UpdItems | Where-Object { $_.UnArgs -eq 'Microsoft.AppInstaller' })[0]; $ai.IsSelected = $true
Invoke-Click $BtnUpdApply
Assert-Equal 'a confirm dialog names the programs'                'Update selected programs?' $TxtOverlayTitle.Text
Assert-True  'with both names and their version badges'           (($TxtOverlayMsg.Text -like '*Discord*1.0.9255*') -and ($TxtOverlayMsg.Text -like '*App Installer*'))
Assert-Equal 'and offers Continue'                                'Visible' "$($BtnOverlayCancel.Visibility)"
Invoke-Click $BtnOverlayCancel
Assert-Equal 'Cancel starts nothing'                              'Idle' $script:Phase

# the search box narrows the list and the counts ride on the sub-tab - typed into the real box,
# then the dispatcher is pumped past the 220 ms debounce so the real tick refreshes the views
function Search-For([string]$Text) {
    $TxtSearch.Text = $Text
    $t0 = Get-Date
    while ($script:SearchTimer.IsEnabled -and ((Get-Date) - $t0).TotalSeconds -lt 3) { Update-UI; Start-Sleep -Milliseconds 60 }
    Update-UI
}
Search-For 'discord'
Assert-Equal 'search count on the sub-tab label'                  'Desktop apps   1' $BtnSubUpdDesk.Content
Search-For 'zzz-nothing'
Assert-True  'a search that matches nothing says so'              ($EmptyUpd.Visibility -eq 'Visible' -and $EmptyUpd.Text -like 'Nothing here matches*')
Search-For ''
Assert-Equal 'clearing the search restores the label'             'Desktop apps   5' $BtnSubUpdDesk.Content

Invoke-Click $BtnSubUpdStore
Assert-Equal 'Store sub-tab: the button becomes the bulk action'  'Update all Store apps' $TxtUpdApplyBtn.Text
Assert-Equal 'Select All / Clear All / Rescan are hidden there'   'Collapsed|Collapsed|Collapsed' "$($BtnUpdSelAll.Visibility)|$($BtnUpdSelNone.Visibility)|$($BtnUpdRescan.Visibility)"
Assert-Equal 'the Store list is populated'                        2 $script:UpdStore.Count
Assert-Equal 'Store header: VERSION column, no AVAILABLE'         'VERSION|Hidden' "$($BtnUpdColInst.Content)|$($BtnUpdColAvail.Visibility)"
Assert-True  'and the status line says the Store updates as a set' ($TxtStatus.Text -like '2 Store app(s) installed*')
Invoke-Click $BtnUpdApply
Assert-Equal 'the bulk action confirms first'                     'Update all Store apps?' $TxtOverlayTitle.Text
Invoke-Click $BtnOverlayCancel
Invoke-Click $BtnSubUpdWin
Assert-Equal 'Windows Update sub-tab: 3 updates, none ticked'     '3|0' "$($script:UpdWin.Count)|$(@($script:UpdWin | Where-Object { $_.IsSelected }).Count)"
Assert-Equal 'recommended and optional are separate groups'       'Optional updates  (what Settings > Optional updates lists - Windows leaves these to you)|Recommended updates  (Windows would install these on its own)' ((@($script:UpdWin | ForEach-Object { $_.Category } | Sort-Object -Unique)) -join '|')
$pv = @($script:UpdWin | Where-Object { $_.Name -like '*Preview*' })[0]
Assert-True  'a preview update lands under Optional even though it is not browse-only' ($pv -and $pv.Category -like 'Optional*')
$dr = @($script:UpdWin | Where-Object { $_.Name -like 'Intel*' })[0]
Assert-True  'a driver lands under Optional, as Settings files it'     ($dr -and $dr.Category -like 'Optional*')
Assert-True  'only the auto-selected update is recommended'            (@($script:UpdWin | Where-Object { $_.Category -like 'Recommended*' }).Count -eq 1)
$drvRow = @($script:UpdWin | Where-Object { $_.Name -like 'Intel*' })[0]
Assert-Equal 'a driver wears the driver pill and says it needs a restart' 'driver|Visible|restart needed' "$($drvRow.TagText)|$($drvRow.TagVis)|$($drvRow.ColSize)"
$prevRow = @($script:UpdWin | Where-Object { $_.Name -like '*Preview*' })[0]
Assert-Equal 'a preview wears the optional pill, KB and category in the second column' 'optional|KB5099999   Updates' "$($prevRow.TagText)|$($prevRow.Publisher)"
Assert-Equal 'the header is relabelled for updates'               'UPDATE ^|KB   CATEGORY|DOWNLOAD|RESTART' "$($BtnUpdColName.Content)|$($BtnUpdColPub.Content)|$($BtnUpdColInst.Content)|$($BtnUpdColAvail.Content)"
Assert-Equal 'the button reads Install Selected Updates'          'Install Selected Updates' $TxtUpdApplyBtn.Text
Assert-True  'the hint counts recommended, optional, drivers and restarts' ($TxtUpdHint.Text -like '3 Windows update(s) waiting - 1 recommended, 2 optional (1 driver(s))*2 need a restart*')
Invoke-Click $BtnUpdSelAll
Assert-Equal 'Select All ticks the Windows list'                  3 @($script:UpdWin | Where-Object { $_.IsSelected }).Count
Assert-Equal 'status line follows'                                '3 of 3 Windows update(s) selected' $TxtStatus.Text
Invoke-Click $BtnUpdApply
Assert-Equal 'the confirm names the optional ones and the restarts' $true (($TxtOverlayTitle.Text -eq 'Install Windows updates?') -and ($TxtOverlayMsg.Text -like '*2 of them are OPTIONAL*') -and ($TxtOverlayMsg.Text -like '*2 need a restart*'))
Invoke-Click $BtnOverlayCancel
Invoke-Click $BtnUpdSelNone
Invoke-Click $BtnSubUpdDesk
Assert-Equal 'back on Desktop: rows are still there, still unticked' '5|2' "$($script:UpdItems.Count)|$(@($script:UpdItems | Where-Object { $_.IsSelected }).Count)"

# ------------------------------------------------------------------ 2b. a sub-tab clicked mid-scan
Write-Section '2b. Update, then a quick Windows Update click: the second scan is queued, not dropped'
# Reported from the field: "when I click fast Update > Windows, it doesn't scan; I have to go slow
# or hit Rescan". The winget scan pumps the dispatcher while it waits, the pump delivers the
# sub-tab click, and Load-WinUpdates saw the scanning flag and returned without a word. The clicks
# are re-enacted from INSIDE the winget stub, which is exactly where they land.
$script:Calls = @{ winget = 0; wu = 0 }
$realWinget = ${function:Get-WingetUpgradeText}
$realWu     = ${function:Get-WindowsUpdateList}
$script:MidScanClick = $BtnSubUpdWin
$script:WingetAnswer = $samplePreamble + "`r`n" + $sampleTwoTables
function Get-WingetUpgradeText {
    $script:Calls.winget++
    Invoke-Click $script:MidScanClick             # the technician's fast second click
    $script:Seen = @{ Spinner = $TxtLoadUpd.Text; SpinnerVis = "$($LoadUpd.Visibility)"; WinRows = $script:UpdWin.Count; Scanning = $script:UpdScanning }
    Invoke-Click $BtnUpdRescan                    # and Rescan hammered while it runs
    return $script:WingetAnswer
}
function Get-WindowsUpdateList { $script:Calls.wu++; return & $realWu }
$script:UpdDirty = $true; $script:UpdWinDirty = $true
$script:UpdWin.Clear()
Invoke-Click $BtnSubUpdDesk                       # on Desktop with a stale list: this starts the winget scan
Assert-True  'the Windows Update click landed while winget was still being asked' ($script:Seen.Scanning -and $script:Seen.WinRows -eq 0)
Assert-Equal 'and the spinner said what would happen next'         'Finishing the winget scan, then asking Windows Update...|Visible' "$($script:Seen.Spinner)|$($script:Seen.SpinnerVis)"
Assert-Equal 'winget was asked once, Windows Update once - Rescan mid-scan did not double either' '1|1' "$($script:Calls.winget)|$($script:Calls.wu)"
Assert-Equal 'the Windows list was scanned without a second click'  '3|False' "$($script:UpdWin.Count)|$($script:UpdWinDirty)"
Assert-Equal 'and is the one on screen, spinner gone'               'Win|Visible|Collapsed|Collapsed' "$($script:UpdSubTab)|$($ScrollUpdWin.Visibility)|$($ScrollUpdDesk.Visibility)|$($LoadUpd.Visibility)"
Assert-True  'the hint is the Windows one, not winget''s'            ($TxtUpdHint.Text -like '3 Windows update(s) waiting*')
Assert-Equal 'the desktop scan still finished behind it'            '5|False' "$($script:UpdItems.Count)|$($script:UpdDirty)"
Assert-True  'and its words were kept for its own tab'              ($script:UpdWords.Desk.Hint -like '5 update(s) available*')
Invoke-Click $BtnSubUpdDesk
Assert-True  'back on Desktop the winget hint is painted'            ($TxtUpdHint.Text -like '5 update(s) available*')

# the other way round: Windows Update scanning, Desktop clicked mid-scan
$script:Calls = @{ winget = 0; wu = 0 }
$script:MidScanClick = $BtnSubUpdDesk
function Get-WindowsUpdateList {
    $script:Calls.wu++
    Invoke-Click $script:MidScanClick
    $script:Seen = @{ Spinner = $TxtLoadUpd.Text; Scanning = $script:UpdScanning }
    return & $realWu
}
$script:UpdDirty = $true; $script:UpdWinDirty = $true
$script:UpdItems.Clear()
Invoke-Click $BtnSubUpdWin
Assert-True  'the Desktop click landed inside the Windows Update scan'   $script:Seen.Scanning
Assert-Equal 'the spinner said so'                                        'Finishing the Windows Update scan, then asking winget...' $script:Seen.Spinner
Assert-Equal 'both scans ran, once each'                                  '1|1' "$($script:Calls.winget)|$($script:Calls.wu)"
Assert-Equal 'Desktop is on screen with its fresh rows'                   'Desk|Visible|5|3' "$($script:UpdSubTab)|$($ScrollUpdDesk.Visibility)|$($script:UpdItems.Count)|$($script:UpdWin.Count)"
Assert-True  'under the winget hint'                                      ($TxtUpdHint.Text -like '5 update(s) available*')

# an empty answer keeps to its own tab: winget finds nothing while the technician is on Windows Update
$script:Calls = @{ winget = 0; wu = 0 }
$script:MidScanClick = $BtnSubUpdWin
$script:WingetAnswer = $sampleNone
$script:UpdDirty = $true; $script:UpdWinDirty = $true
Invoke-Click $BtnSubUpdDesk
Assert-Equal 'the Windows list shows its rows, no "up to date" label over them' 'Win|3|Collapsed' "$($script:UpdSubTab)|$($script:UpdWin.Count)|$($EmptyUpd.Visibility)"
Invoke-Click $BtnSubUpdDesk
Assert-Equal 'back on Desktop the empty list says why'                    'Visible|Everything winget knows about is up to date.' "$($EmptyUpd.Visibility)|$($EmptyUpd.Text)"
Invoke-Click $BtnSubUpdWin
Assert-Equal 'and the label does not follow to Windows Update'            'Collapsed' "$($EmptyUpd.Visibility)"
${function:Get-WingetUpgradeText} = $realWinget
${function:Get-WindowsUpdateList} = $realWu
Invoke-Click $BtnUpdRescan
Invoke-Click $BtnSubUpdDesk
Invoke-Click $BtnUpdRescan
Assert-Equal 'Rescan on each tab, nothing running: both lists fresh again' '5|3|False|False' "$($script:UpdItems.Count)|$($script:UpdWin.Count)|$($script:UpdDirty)|$($script:UpdWinDirty)"
# the list is held while its own batch runs
$script:Phase = 'Install'; $script:BatchTab = 'Update'
Invoke-Click $BtnUpdSelAll
Assert-Equal 'Select All is refused while an update batch runs'   'Updates are running' $TxtOverlayTitle.Text
$Overlay.Visibility = 'Collapsed'; $script:Phase = 'Idle'; $script:BatchTab = 'Install'
Assert-Equal 'no crash file was written by any of that'           0 @(Get-ChildItem (Join-Path $sandbox 'cache') -Filter 'crash-*.txt').Count
$timer.Stop()
$script:IconState.Stop = $true
try { $script:IconPS.Stop() } catch { }
try { $window.Close() } catch { }

# ------------------------------------------------------------------ 3. the worker, on a lab VM
if ($VM) {
    Write-Section '3. The elevated worker against real winget and the real Store (lab VM)'
    $elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) { throw 'Part 3 needs an elevated PowerShell.' }
    if ($AllowHosts -notcontains $env:COMPUTERNAME) { throw "$env:COMPUTERNAME is not a lab VM; part 3 updates real software." }
    $lines = $src -split "`r?`n"
    $startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    $endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
    $workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")
    $work = Join-Path $env:LOCALAPPDATA ("updtab-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $workerPath = Join-Path $work 'worker.ps1'
    Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:RunNo = 0
    function Invoke-Worker([object[]]$Entries) {
        $script:RunNo++
        $dir = Join-Path $work "run$($script:RunNo)"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $queue = Join-Path $dir 'queue.jsonl'; $status = Join-Path $dir 'status.jsonl'; $cancel = Join-Path $dir 'cancel.flag'
        foreach ($e in $Entries) { Add-Content -LiteralPath $queue -Value ($e | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8 }
        Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8
        $t0 = Get-Date
        $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"", '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
        Write-Host ("  worker run {0}: exit {1} after {2:N0}s" -f $script:RunNo, $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
        $all = @(); foreach ($l in @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue)) { try { $all += ($l | ConvertFrom-Json) } catch { } }
        foreach ($a in $all) { Write-Host ("    {0,-10} {1,-10} {2}" -f $a.id, $a.state, $a.detail) -ForegroundColor DarkGray }
        return $all
    }
    $pathFn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WingetPath' }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($pathFn.Extent.Text))
    $script:WingetPath = ''
    $exe = Get-WingetPath
    Assert-True 'winget resolved on the VM' ([bool]$exe)
    Write-Host "  winget: $exe" -ForegroundColor DarkGray
    $out = Join-Path $work 'upgrade.txt'
    $p = Start-Process -FilePath $exe -ArgumentList @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity') -RedirectStandardOutput $out -Wait -PassThru -WindowStyle Hidden
    $live = @(Get-WingetUpgrades ([IO.File]::ReadAllText($out)) | Where-Object { $_.Source -eq 'winget' })
    Write-Host ("  {0} winget update(s) listed on this VM" -f $live.Count) -ForegroundColor DarkGray
    $pick = @($live | Where-Object { $_.Id -in 'Microsoft.AppInstaller', 'Notepad++.Notepad++', '7zip.7zip', 'Microsoft.Outlook' }) | Select-Object -First 1
    if (-not $pick) { $pick = $live | Select-Object -First 1 }
    if (-not $pick) {
        Write-Host '  SKIP  nothing to update on this VM' -ForegroundColor Yellow
    } else {
        Write-Host "  updating $($pick.Id) $($pick.Version) -> $($pick.Available)" -ForegroundColor DarkGray
        $entry = @{ id = 'upd-1'; action = 'update'; wingetId = $pick.Id; name = $pick.Name; winget = $exe; source = 'winget'; installed = $pick.Version; available = $pick.Available }
        $all = Invoke-Worker @($entry)
        $final = @($all | Where-Object { $_.id -eq 'upd-1' }) | Select-Object -Last 1
        Assert-True  'the real package updated (Installed) or was honestly Skipped' ($final.state -in 'Installed', 'Skipped')
        Assert-True  'the row showed live progress before the verdict'             (@($all | Where-Object { $_.id -eq 'upd-1' -and $_.state -eq 'Installing' }).Count -ge 1)
        if ($final.state -eq 'Installed') {
            $p = Start-Process -FilePath $exe -ArgumentList @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity') -RedirectStandardOutput $out -Wait -PassThru -WindowStyle Hidden
            $after = @(Get-WingetUpgrades ([IO.File]::ReadAllText($out)) | Where-Object { $_.Id -eq $pick.Id })
            Assert-Equal 'winget no longer lists it as outdated' 0 $after.Count
        }
    }
    $bogus = @{ id = 'upd-2'; action = 'update'; wingetId = 'This.DoesNotExist.Anywhere'; name = 'Ghost'; winget = 'C:\nope\winget.exe'; source = 'winget'; installed = '1.0'; available = '2.0' }
    $all = Invoke-Worker @($bogus)
    $final = @($all | Where-Object { $_.id -eq 'upd-2' }) | Select-Object -Last 1
    Assert-Equal 'a bogus winget path is re-resolved and a nonexistent id FAILS' 'Failed' $final.state
    Assert-True  'with winget''s hex exit code in the detail'                    ($final.detail -match '0x[0-9A-F]{8}')
    $all = Invoke-Worker @(@{ id = 'store'; action = 'storeupdate'; name = 'Update all Store apps' })
    $final = @($all | Where-Object { $_.id -eq 'store' }) | Select-Object -Last 1
    Assert-Equal 'the Store updater accepted the scan request'                   'Applied' $final.state

    # Windows Update for real: the GUI's own scan (its Update-UI pump stubbed), then the worker
    # installs the smallest non-driver, non-feature update it finds - Defender definitions when
    # they are offered: seconds, no restart.
    $wuFn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WindowsUpdateList' }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($wuFn.Extent.Text))
    function Update-UI { }
    $t0 = Get-Date
    $wu = @(Get-WindowsUpdateList)
    Write-Host ("  Windows Update lists {0} update(s) ({1:N0}s): {2} optional" -f $wu.Count, ((Get-Date) - $t0).TotalSeconds, @($wu | Where-Object { $_.Optional }).Count) -ForegroundColor DarkGray
    foreach ($w in $wu) { Write-Host ("    {0}  [{1}] {2}{3}" -f $w.Title, $w.Category, $(if ($w.Optional) { 'optional ' }), $(if ($w.Reboot) { 'restart' })) -ForegroundColor DarkGray }
    $pickW = @($wu | Where-Object { $_.Title -match 'Security Intelligence|Defender' }) | Select-Object -First 1
    if (-not $pickW) { $pickW = @($wu | Where-Object { -not $_.Driver -and -not $_.Reboot -and $_.Title -notmatch 'Feature update|Upgrade' } | Sort-Object Size) | Select-Object -First 1 }
    if (-not $pickW) {
        Write-Host '  SKIP  no small restart-free Windows update offered to this VM' -ForegroundColor Yellow
    } else {
        Write-Host "  installing: $($pickW.Title)" -ForegroundColor DarkGray
        $all = Invoke-Worker @(@{ id = 'wu-1'; action = 'winupdate'; updateId = $pickW.Id; name = $pickW.Title; kb = $pickW.KB })
        $final = @($all | Where-Object { $_.id -eq 'wu-1' }) | Select-Object -Last 1
        Assert-True  'the Windows update installed (or was honestly Skipped as already gone)' ($final.state -in 'Installed', 'Skipped')
        Assert-True  'the row showed download/install progress before the verdict'          (@($all | Where-Object { $_.id -eq 'wu-1' -and $_.state -eq 'Installing' }).Count -ge 2)
        if ($final.state -eq 'Installed') {
            $again = @(Get-WindowsUpdateList | Where-Object { $_.Id -eq $pickW.Id })
            Assert-Equal 'Windows Update no longer lists it' 0 $again.Count
        }
    }
    $all = Invoke-Worker @(@{ id = 'wu-2'; action = 'winupdate'; updateId = '00000000-0000-0000-0000-000000000000'; name = 'Ghost update'; kb = '' })
    Assert-Equal 'an update that no longer exists is Skipped, not Failed' 'Skipped' (@($all | Where-Object { $_.id -eq 'wu-2' }) | Select-Object -Last 1).state
}

Write-Host ''
$colour = $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $colour
if ($script:Fail) { exit 1 } else { exit 0 }
