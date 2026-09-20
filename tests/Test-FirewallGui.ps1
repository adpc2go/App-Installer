<#
.SYNOPSIS
    The Firewall TAB - the list, the detail view, the three buttons and their confirm dialogs -
    driven on the real window against the real Windows firewall. Needs an elevated PowerShell.

.DESCRIPTION
    Test-FirewallTab proves the WORKER: given a queue entry it writes and removes the right
    rules. Nothing drove the tab that writes those entries. This loads AppDeploy.ps1 up to its
    "go" line, exactly as Test-GuiBatch does, so the window is built and every handler is wired,
    then presses the real buttons on a window that is never shown.

    A throwaway program is registered in HKCU with an install folder of three exes and a dll,
    so it appears in the tab the way any installed program does. Then:

      1. The scan lists it under Not blocked; the detail view previews the three exes and not
         the dll; Resolve-AppRoot's fallbacks are proven on plain objects.
      2. Block Internet Access: the confirm names it, Continue starts a batch through the real
         worker, the batch summary counts 3 new rules, the tab re-scans itself and the row moves
         to Blocked with the count, the detail view now lists the rules as this tool's, and the
         run record is filed as Firewall and timed from its own start.
      3. Block again: the confirm says it already has rules; the batch reports nothing to do.
      4. A stray rule (netsh, under a folder no program owns) appears as an Unmatched row; Block
         refuses it; Unblock Selected with the program and the stray ticked removes all four,
         says one was foreign, and the tab is clean again.
      5. Remove ALL opens its confirm and is CANCELLED - it would touch every rule on this
         machine, so only the dialog is exercised. The empty-selection refusals are pressed too.

    The only stub is Start-Worker, redefined to launch the same worker without the UAC verb -
    this session is already elevated, so the worker inherits the token. Everything under
    C:\Users\Public\FwGui-<tag> and the HKCU key is removed in the finally block, and every
    firewall rule whose program sits inside the sandbox goes with it.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-FirewallGui.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
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

$elevated = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'This harness writes real firewall rules and needs an elevated PowerShell. Run it as administrator.' }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# ------------------------------------------------------------------ sandbox
$tag     = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path 'C:\Users\Public' "FwGui-$tag"
$app     = Join-Path $sandbox 'App'
$vendor  = Join-Path $sandbox 'Vendor'
$appName = "Fw Gui Probe $tag"
$unKey   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoFwGui-$tag"
$strayName = "PC2GoFwGui-stray-$tag"
foreach ($d in @($app, (Join-Path $app 'bin'), $vendor, (Join-Path $sandbox 'cache'), (Join-Path $sandbox 'server'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
foreach ($f in @('one.exe', 'bin\two.exe', 'three.exe', 'notes.dll')) { Set-Content -LiteralPath (Join-Path $app $f) -Value 'x' -Encoding ASCII }
Set-Content -LiteralPath (Join-Path $vendor 'shared.exe') -Value 'x' -Encoding ASCII
Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray

# every rule whose program sits inside the sandbox - the ONLY rules this harness inspects or deletes
function Get-SandboxRules {
    $f = @{}
    foreach ($af in @(Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
        $p = ('' + $af.AppPath); if (-not $p) { $p = ('' + $af.Program) }
        if ($p -and $p -ne 'Any' -and $p -ne 'System') { $f[[string]$af.InstanceID] = [Environment]::ExpandEnvironmentVariables($p) }
    }
    $prefix = $sandbox.ToLower() + '\'
    $out = @()
    foreach ($r in @(Get-NetFirewallRule -ErrorAction Stop)) {
        $p = $f[[string]$r.InstanceID]
        if ($p -and $p.ToLower().StartsWith($prefix)) {
            $out += [pscustomobject]@{ Name = ('' + $r.Name); Group = ('' + $r.Group); Program = $p; Enabled = ("$($r.Enabled)" -eq 'True') }
        }
    }
    return $out
}
function Remove-SandboxRules {
    foreach ($r in @(Get-SandboxRules)) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
}
function Wait-Dispatcher([int]$Milliseconds) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
    $t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-For([scriptblock]$Until, [int]$TimeoutMs = 120000, [int]$Step = 250) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if (& $Until) { return $true }
        Wait-Dispatcher $Step
        $waited += $Step
    }
    return [bool](& $Until)
}
function Invoke-Click($Button) {
    $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function Stop-OrphanWorkers([string]$Match = 'FwGui-') {
    $n = 0
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
            if ($p.CommandLine -and $p.CommandLine -like '*worker.ps1*' -and $p.CommandLine -like "*$Match*") {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ } catch {}
            }
        }
    } catch {}
    return $n
}
function Get-ProbeRow { @($script:FwItems | Where-Object { $_.Name -eq $appName }) | Select-Object -First 1 }
function Get-StrayRow { @($script:FwItems | Where-Object { $_.RegKey -eq 'unmatched' -and ([string]$_.UnArgs).ToLower().StartsWith($sandbox.ToLower()) }) | Select-Object -First 1 }
function Clear-FwTicks { foreach ($i in $script:FwItems) { $i.IsSelected = $false } }
function Get-LastRun {
    @(Get-ChildItem -LiteralPath (Get-RunsDir) -Filter 'run-*.json' -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Select-Object -First 1 |
      ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })[0]
}

try {
    $killed = Stop-OrphanWorkers
    if ($killed) { Write-Host "  killed $killed orphaned worker(s) from a previous run" -ForegroundColor Yellow }

    # the program, registered the way an installer registers one
    New-Item -Path $unKey -Force | Out-Null
    Set-ItemProperty -Path $unKey -Name 'DisplayName'     -Value $appName
    Set-ItemProperty -Path $unKey -Name 'DisplayVersion'  -Value '1.0'
    Set-ItemProperty -Path $unKey -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $unKey -Name 'InstallLocation' -Value $app
    Set-ItemProperty -Path $unKey -Name 'UninstallString' -Value "`"$app\one.exe`" /u"

    # a one-app local catalog, so Load-Catalog has something to load
    $server = Join-Path $sandbox 'server'
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ([pscustomobject]@{
        updated = (Get-Date -Format 'yyyy-MM-dd')
        apps = @([pscustomobject]@{ id = 'fw-dummy'; name = 'Fw Dummy'; category = 'Apps'
                url = 'https://example.invalid/x.exe'; sha256 = ('a' * 64); sizeBytes = 10
                silentArgs = '/S'; verifyPaths = @("$sandbox\never.exe") })
    } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))

    # ================================================================== load the GUI
    Write-Section 'Loading the real GUI (window built, handlers wired, never shown)'
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker in AppDeploy.ps1.' }
    $head = $src.Substring(0, $goAt)
    $fileUrl = 'file:///' + ($server -replace '\\', '/')
    . ([scriptblock]::Create($head)) -BaseUrl $fileUrl -NoSelfElevate
    Assert-True 'the window was built'           ($null -ne $window)
    Assert-True 'the Firewall buttons exist'     ($null -ne $BtnFwBlock -and $null -ne $BtnFwUnblock -and $null -ne $BtnFwRemoveAll)

    # The only stub: the real Start-Worker minus the UAC verb. Same substitutions, same
    # queue, same status file; this session is elevated, so the worker inherits the token.
    function Start-Worker {
        if ($script:WorkerStarted) { return $true }
        Remove-Item -LiteralPath $script:WorkerPath -Force -ErrorAction SilentlyContinue
        $nvAssign = "`$NvApiSrc = @'" + [Environment]::NewLine + $script:NvApiSource + [Environment]::NewLine + "'@"
        $built = $workerScript.Replace('#__NVAPISOURCE__', $nvAssign).Replace('#__SHAREDTABLES__', (Get-SharedTablesSource)).Replace('#__INSTALLERFAMILY__', (Get-InstallerFamilySource))
        Set-Content -Path $script:WorkerPath -Value $built -Encoding UTF8
        Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
        $script:StatusOffset = 0
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" " +
                  "-QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`" " +
                  "-SkipFile `"$script:SkipPath`" -ParentPid $PID"
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList $psArgs | Out-Null
        $script:WorkerStarted = $true
        Add-Log 'Worker started (test harness: inherits this elevated session, no prompt).'
        return $true
    }
    $script:CacheDir      = Join-Path $sandbox 'cache'
    $script:QueuePath     = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath    = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath    = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath    = Join-Path $script:CacheDir 'cancel.flag'
    $script:SkipPath      = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'
    $timer.Start()
    Load-Catalog
    Assert-Equal 'the local catalog loaded' 1 @($script:Items).Count

    # ================================================================== 1. the scan
    Write-Section '1. Opening the tab scans the machine; the probe is listed as Not blocked'
    Select-Tab 'Fw'
    Assert-True 'the scan finished and the split view is showing' (Wait-For { "$($FwSplit.Visibility)" -eq 'Visible' } 60000)
    Assert-Equal 'the tab is on screen'                      'Visible' "$($PanelFw.Visibility)"
    $row = Get-ProbeRow
    Assert-True  'the probe program is a row'                ($null -ne $row)
    Assert-Equal 'in the Not blocked column'                 $false ([bool]$row.IsSilent)
    Assert-Equal 'with its install folder as the root'       $app ([string]$row.UnArgs)
    Assert-Equal 'and no rule count'                         '0' ([string]$row.DetectPath)
    Assert-True  'the Not blocked header counts it'          ($TxtFwOpenHdr.Text -match 'Not blocked\s+\d+')
    Assert-True  'the hint line reports the machine total'   ($TxtFwHint.Text -match '^\d+ outbound block rule\(s\) on this machine')
    Assert-Equal 'no stray row belongs to the sandbox yet'   $true ($null -eq (Get-StrayRow))

    Show-FwDetail $row
    Assert-Equal 'the detail view opened'                    'Visible' "$($FwDetailOverlay.Visibility)"
    Assert-True  'titled as not blocked'                     ($TxtFwDetailTitle.Text -like "*$appName*not blocked")
    Assert-True  'it previews all three executables'         ($TxtFwDetail.Text -like "*\one.exe*" -and $TxtFwDetail.Text -like "*\bin\two.exe*" -and $TxtFwDetail.Text -like "*\three.exe*")
    Assert-True  'and not the dll'                           ($TxtFwDetail.Text -notlike '*notes.dll*')
    Assert-True  'the subtitle says what Block would create' ($TxtFwDetailSub.Text -like '*3 executable(s)*')
    Invoke-Click $BtnFwDetailClose
    Assert-Equal 'Close puts it away'                        'Collapsed' "$($FwDetailOverlay.Visibility)"

    # Resolve-AppRoot's fallbacks, on the shapes the registry actually hands it
    Assert-Equal 'AppRoot: InstallLocation wins when it exists'        $app (Resolve-AppRoot ([pscustomobject]@{ Location = "$app\"; Icon = ''; Exe = '' }))
    Assert-Equal 'AppRoot: a DisplayIcon "path,index" falls back to its folder' $app (Resolve-AppRoot ([pscustomobject]@{ Location = ''; Icon = "$app\one.exe,0"; Exe = '' }))
    Assert-Equal 'AppRoot: then the uninstaller''s folder'             "$app\bin" (Resolve-AppRoot ([pscustomobject]@{ Location = ''; Icon = ''; Exe = "$app\bin\two.exe" }))
    Assert-Equal 'AppRoot: an uninstaller in System32 is not an app folder' '' (Resolve-AppRoot ([pscustomobject]@{ Location = ''; Icon = ''; Exe = "$env:SystemRoot\System32\msiexec.exe" }))
    Assert-Equal 'AppRoot: a folder that is gone gives nothing'         '' (Resolve-AppRoot ([pscustomobject]@{ Location = "$sandbox\nope"; Icon = ''; Exe = '' }))
    Assert-Equal 'a drive-root InstallLocation is never offered'        $false (Test-FwRootAllowed (Resolve-AppRoot ([pscustomobject]@{ Location = 'C:\'; Icon = ''; Exe = '' })))
    # The roots no program may be blocked AT, whichever account is signed in: Users, Public,
    # every profile and its AppData roots - by shape, since the list only knows this account's.
    $usersDir = Split-Path $env:UserProfile
    Assert-Equal 'root rail: C:\Users is refused'                     $false (Test-FwRootAllowed $usersDir)
    Assert-Equal 'root rail: C:\Users\Public is refused'              $false (Test-FwRootAllowed $env:Public)
    Assert-Equal 'root rail: another user''s profile root is refused' $false (Test-FwRootAllowed (Join-Path $usersDir 'Somebody'))
    Assert-Equal 'root rail: their AppData\Local is refused'          $false (Test-FwRootAllowed (Join-Path $usersDir 'Somebody\AppData\Local'))
    Assert-Equal 'root rail: their Roaming is refused'                $false (Test-FwRootAllowed (Join-Path $usersDir 'Somebody\AppData\Roaming\'))
    Assert-Equal 'root rail: a per-user PROGRAM folder is allowed'    $true  (Test-FwRootAllowed (Join-Path $usersDir 'Somebody\AppData\Local\Programs\Foo'))
    Assert-Equal 'root rail: a folder under Public is allowed'        $true  (Test-FwRootAllowed $app)
    Assert-Equal 'vendor folder: a stray under Public groups under its own top folder' (Split-Path $sandbox -Leaf) (Split-Path (Get-VendorFolder "$vendor\shared.exe") -Leaf)
    Assert-Equal 'vendor folder: a stray in another profile groups under the vendor, not the profile' 'SomeVendor' (Split-Path (Get-VendorFolder (Join-Path $usersDir 'Somebody\AppData\Local\SomeVendor\Tool\x.exe')) -Leaf)
    Assert-Equal 'AppRoot: an uninstaller sitting in a profile root is not an app folder' '' (Resolve-AppRoot ([pscustomobject]@{ Location = ''; Icon = ''; Exe = (Join-Path $env:Public 'unins.exe') }))

    # ================================================================== 2. Block
    Write-Section '2. Block Internet Access: confirm, batch, re-scan, detail, run record'
    Invoke-Click $BtnFwBlock
    Assert-True  'nothing ticked: the tool says so'          ("$($Overlay.Visibility)" -eq 'Visible' -and $null -eq $script:ConfirmAction)
    Invoke-Click $BtnOverlayOk
    Clear-FwTicks
    $row.IsSelected = $true
    Invoke-Click $BtnFwBlock
    Assert-Equal 'the confirm opened'                        'Visible' "$($Overlay.Visibility)"
    Assert-True  'with a Continue to press'                  ($null -ne $script:ConfirmAction)
    Assert-True  'naming the program'                        ($TxtOverlayMsg.Text -like "*$appName*")
    Assert-True  'and the group the rules are tagged with'   ($TxtOverlayMsg.Text -like "*$($script:FwGroup)*")
    $script:RunStarted = (Get-Date).AddMinutes(-3)     # the record must be timed from THIS batch
    Invoke-Click $BtnOverlayOk
    Assert-Equal 'Continue started a firewall batch'         'Fw' $script:BatchTab
    Assert-Equal 'in the Install phase'                      'Install' $script:Phase
    Assert-Equal 'the buttons are locked while it runs'      $false $BtnFwBlock.IsEnabled
    Assert-True  'the batch finished'                        (Wait-For { $script:Phase -eq 'Done' } 120000)
    Assert-Equal 'the card shows the one-word verdict'       'Applied' ([string]$row.Status)
    Assert-True  'the row reports the rules it added'        ($row.StatusDetail -like 'Applied: 3 rule(s) added, 0 already blocked*')
    # the strip's own line: the status bar is the tab's selection count and is repainted by
    # the re-scan Finish-Batch runs on a firewall batch
    Assert-True  'the summary counts them as new'            ($TxtNow.Text -like 'Finished - 3 new rule(s) added*')
    $rules = @(Get-SandboxRules)
    Assert-Equal 'three real rules exist for the folder'     3 $rules.Count
    Assert-Equal 'all in the tool''s group'                  3 @($rules | Where-Object { $_.Group -eq $script:FwGroup }).Count
    Assert-Equal 'the buttons are back'                      $true $BtnFwBlock.IsEnabled
    # Finish-Batch re-scans a firewall batch, so the row object was rebuilt
    $row = Get-ProbeRow
    Assert-True  'the tab re-scanned itself'                 ($null -ne $row -and [bool]$row.IsSilent)
    Assert-Equal 'the row moved to Blocked with the count'   '3' ([string]$row.DetectPath)
    Assert-True  'and the badge says so'                     ($row.Size -like 'BLOCKED*3*')
    Assert-True  'the Blocked header counts it'              ($TxtFwBlockedHdr.Text -match 'Blocked\s+[1-9]')
    Show-FwDetail $row
    Assert-True  'the detail view is now titled blocked'     ($TxtFwDetailTitle.Text -like '*- blocked')
    Assert-True  'listing every executable as this tool''s'  (@(($TxtFwDetail.Text -split "`r`n") | Where-Object { $_ -like '*(1 rule(s), this tool)' }).Count -eq 3)
    Invoke-Click $BtnFwDetailClose
    $rec = Get-LastRun
    Assert-True  'the batch wrote a run record'              ($null -ne $rec)
    Assert-Equal 'filed as Firewall'                         'Firewall' "$($rec.kind)"
    Assert-True  'and timed from its own start'              ([int]$rec.seconds -lt 150)
    Assert-Equal 'counting one ok'                           1 ([int]$rec.counts.ok)

    # ================================================================== 3. Block again
    Write-Section '3. Block again: already blocked, nothing added'
    Clear-FwTicks
    $row.IsSelected = $true
    Invoke-Click $BtnFwBlock
    Assert-True  'the confirm says the rules already exist'  ($TxtOverlayMsg.Text -like '*already have rules (3 in total)*')
    Invoke-Click $BtnOverlayOk
    Assert-True  'the repeat batch finished'                 (Wait-For { $script:Phase -eq 'Done' } 120000)
    Assert-True  'the row says nothing to do'                ($row.StatusDetail -like 'Skipped: 0 rule(s) added, 3 already blocked*nothing to do*')
    Assert-True  'the summary says no new rules'             ($TxtNow.Text -like 'Finished - no new rules added*3 executable(s) already blocked*')
    Assert-Equal 'still exactly three rules'                 3 @(Get-SandboxRules).Count

    # ================================================================== 4. stray + unblock
    Write-Section '4. A stray rule: listed as Unmatched, refused by Block, cleared by Unblock'
    & "$env:SystemRoot\System32\netsh.exe" advfirewall firewall add rule name="$strayName" dir=out action=block program="$vendor\shared.exe" enable=yes | Out-Null
    Assert-Equal 'precondition: four rules under the sandbox' 4 @(Get-SandboxRules).Count
    Invoke-Click $BtnFwRescan
    Assert-True  'Rescan re-read the machine'                (Wait-For { "$($FwSplit.Visibility)" -eq 'Visible' } 60000)
    $row = Get-ProbeRow
    $stray = Get-StrayRow
    Assert-True  'the stray shows as an Unmatched row'       ($null -ne $stray)
    if ($null -eq $stray) {
        foreach ($u in @($script:FwItems | Where-Object { $_.RegKey -eq 'unmatched' })) {
            Write-Host ("    unmatched> {0}  [{1}]  rules={2}" -f $u.Name, $u.UnArgs, $u.DetectPath) -ForegroundColor Yellow
        }
    }
    Assert-Equal 'named after the vendor folder it groups'   (Split-Path $sandbox -Leaf) ([string]$stray.Name)
    Assert-Equal 'carrying one rule'                         '1' ([string]$stray.DetectPath)
    Assert-True  'with the rule name to delete by'           (@($stray.CleanTokens).Count -eq 1)
    Assert-True  'the hint line counts it as stray'          ($TxtFwHint.Text -like '*belong to no installed program*')
    Assert-True  'the Blocked header shows the stray count'  ($TxtFwBlockedHdr.Text -like '*stray*')

    Clear-FwTicks
    $stray.IsSelected = $true
    Invoke-Click $BtnFwBlock
    Assert-True  'Block refuses a stray on its own'          ("$($Overlay.Visibility)" -eq 'Visible' -and $null -eq $script:ConfirmAction -and $TxtOverlayMsg.Text -like '*shared vendor folders*')
    Invoke-Click $BtnOverlayOk

    Clear-FwTicks
    Invoke-Click $BtnFwUnblock
    Assert-True  'Unblock with nothing ticked says so'       ("$($Overlay.Visibility)" -eq 'Visible' -and $null -eq $script:ConfirmAction)
    Invoke-Click $BtnOverlayOk

    $row.IsSelected = $true
    $stray.IsSelected = $true
    Invoke-Click $BtnFwUnblock
    Assert-Equal 'the confirm opened'                        'Visible' "$($Overlay.Visibility)"
    Assert-True  'counting four rules across two entries'    ($TxtOverlayMsg.Text -like '4 rule(s) across 2 entr*')
    Assert-True  'and warning that one is foreign'           ($TxtOverlayMsg.Text -like '*1 of them were created by something other than this tool*')
    Invoke-Click $BtnOverlayOk
    Assert-True  'the unblock batch finished'                (Wait-For { $script:Phase -eq 'Done' } 120000)
    Assert-True  'the program row reports 3 removed'         ($row.StatusDetail -like 'Applied: 3 rule(s) removed*')
    Assert-True  'the stray row reports 1 removed, foreign'  ($stray.StatusDetail -like 'Applied: 1 rule(s) removed (1 of them created by something other than this tool)*')
    Assert-True  'the summary totals four removed'           ($TxtNow.Text -like 'Finished - *4 rule(s) removed*')
    Assert-Equal 'no rule is left under the sandbox'         0 @(Get-SandboxRules).Count
    Assert-Equal 'the netsh rule went with them'             0 @(Get-NetFirewallRule -DisplayName $strayName -ErrorAction SilentlyContinue).Count
    $row = Get-ProbeRow
    Assert-True  'after the re-scan the program is Not blocked again' ($null -ne $row -and -not $row.IsSilent)
    Assert-Equal 'and no stray row remains for the sandbox'  $true ($null -eq (Get-StrayRow))
    $rec = Get-LastRun
    Assert-Equal 'the unblock record counts two ok'          2 ([int]$rec.counts.ok)

    Clear-FwTicks
    $row.IsSelected = $true
    Invoke-Click $BtnFwUnblock
    Assert-True  'Unblock on a program with no rules is refused' ("$($Overlay.Visibility)" -eq 'Visible' -and $null -eq $script:ConfirmAction -and $TxtOverlayMsg.Text -like '*currently has an outbound block rule*')
    Invoke-Click $BtnOverlayOk

    # ================================================================== 5. Remove ALL
    Write-Section '5. Remove ALL: the dialog only - it is cancelled, never confirmed'
    Clear-FwTicks
    $before = @(Get-NetFirewallRule -Direction Outbound -Action Block -ErrorAction SilentlyContinue).Count
    Invoke-Click $BtnFwRemoveAll
    Assert-Equal 'a dialog opened'                           'Visible' "$($Overlay.Visibility)"
    if ($script:ConfirmAction) {
        Assert-True 'it is the confirm, naming every rule on this machine' ($TxtOverlayMsg.Text -like '* outbound block rule(s) across *')
        Invoke-Click $BtnOverlayCancel
    } else {
        Assert-True 'this machine has no block rules, and it says so' ($TxtOverlayMsg.Text -like '*No outbound block rules*')
        Invoke-Click $BtnOverlayOk
    }
    Assert-True  'nothing started'                           ($script:Phase -ne 'Install')
    Assert-Equal 'and nothing on the machine changed'        $before @(Get-NetFirewallRule -Direction Outbound -Action Block -ErrorAction SilentlyContinue).Count

    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    try { if ($timer) { $timer.Stop() } } catch { }
    try { if ($script:HaveMutex -and $script:AppMutex) { $script:AppMutex.ReleaseMutex() } } catch { }
    $left = Stop-OrphanWorkers
    if ($left) { Write-Host "  stopped $left worker(s) still running at exit" -ForegroundColor Yellow }
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $sandbox" -ForegroundColor Yellow
    } else {
        try { Remove-SandboxRules } catch { }
        try { Remove-NetFirewallRule -DisplayName $strayName -ErrorAction SilentlyContinue } catch { }
        try { if (Test-Path -LiteralPath $unKey) { Remove-Item -LiteralPath $unKey -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        $leftovers = @()
        if (Test-Path -LiteralPath $sandbox) { $leftovers += $sandbox }
        if (Test-Path -LiteralPath $unKey) { $leftovers += $unKey }
        try { if (@(Get-SandboxRules).Count) { $leftovers += 'firewall rules under the sandbox' } } catch { }
        if ($leftovers.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($leftovers -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
