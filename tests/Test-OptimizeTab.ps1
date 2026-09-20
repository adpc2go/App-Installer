<#
.SYNOPSIS
    The Optimize tab (Tweaks and Cleanup sub-tabs) on a dev workstation, without changing it:
    the table, the apply/undo symmetry, the hosts-file writer, and the tab's own logic on the
    real window with the worker stubbed.

.DESCRIPTION
    Test-TweakTab and Test-CleanupTab prove the rows on a lab VM they are allowed to wreck.
    Nothing proved the tab that queues them, and nothing could be proven here at all. This runs
    unelevated and writes nothing outside %TEMP%:

      1. The table: every Tweaks/Cleanup row has an Apply clause; every non-cleanup row that is
         not documented one-way has an Undo clause; and every registry value Apply writes for
         those rows is written back or removed by Undo (the symmetry the Resume badge and
         CortanaConsent used to break).
      2. Write-HostsFile: keeps a read-only attribute, keeps non-ASCII text intact, and leaves
         a whole file behind.
      3. The tab, headless, worker stubbed: the pre-apply check skips what is applied, never
         pre-skips a debloat row, queues the restore point FIRST with the technician's SID on
         every line; the nothing-to-do path; a second press during the check is refused, not
         nested; Detect ticks applied rows and unticks the rest; a declined batch does not
         restart Explorer; rows the worker did not run count as "not run", not "with warnings".

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-OptimizeTab.ps1
#>
[CmdletBinding()]
param([string]$ScriptPath)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not (Test-Path (Join-Path $repo 'server\AppDeploy.ps1')) -and (Test-Path (Join-Path $here 'server\AppDeploy.ps1'))) { $repo = $here }
if (-not $ScriptPath) { $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cannot find AppDeploy.ps1 at $ScriptPath" }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) { Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$wStart = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
$wEnd = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $wStart } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$wStart..($wEnd - 2)] -join "`r`n")
$wAst = [System.Management.Automation.Language.Parser]::ParseInput($workerBody, [ref]$null, [ref]$null)
function Get-WFn([string]$Name) {
    $fn = $wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Could not extract $Name from the worker" }
    return $fn.Extent.Text
}
$tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP "pc2go-opt-$tag"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$timer = $null

# the switch cases of one function as id -> body text
function Get-Cases([string]$FnName) {
    $text = Get-WFn $FnName
    $out = @{}
    $ms = [regex]::Matches($text, "(?m)^\s{8}'([a-z0-9]+)'\s*\{")
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $from = $ms[$i].Index
        $to = $(if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $text.Length })
        $out[$ms[$i].Groups[1].Value] = $text.Substring($from, $to - $from)
    }
    return $out
}
function Get-RegWrites([string]$Body) {
    $set = @{}
    foreach ($m in [regex]::Matches($Body, "(?:Set-Reg|Set-RegSoft)\s+'([^']+)'\s+'([^']+)'")) { $set[($m.Groups[1].Value + '|' + $m.Groups[2].Value).ToLower()] = $true }
    return $set
}
function Get-RegTouches([string]$Body) {
    $set = @{}
    foreach ($m in [regex]::Matches($Body, "(?:Set-Reg|Set-RegSoft|Remove-RegVal)\s+'([^']+)'\s+'([^']+)'")) { $set[($m.Groups[1].Value + '|' + $m.Groups[2].Value).ToLower()] = $true }
    foreach ($m in [regex]::Matches($Body, "Remove-RegKey\s+'([^']+)'")) { $set[('KEY|' + $m.Groups[1].Value).ToLower()] = $true }
    return $set
}
function Click($Button) { $Button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }

try {
    # ================================================================== 1. the table
    Write-Section '1. Every row has its clauses, and Undo reverses what Apply writes'
    $defsAst = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $defsAs = $defsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:TweakDefs' }, $true) | Select-Object -First 1
    $defs = @(& ([scriptblock]::Create($defsAs.Right.Extent.Text)))
    $scoped = @($defs | Where-Object { "$($_.tab)" -ne 'gaming' })
    Assert-True 'the table loaded with Tweaks and Cleanup rows' ($scoped.Count -ge 40)
    $apply = Get-Cases 'Apply-Tweak'; $undo = Get-Cases 'Undo-Tweak'
    # the rows the Undo dialog itself calls one-way, lifted from the handler
    $oneWayM = [regex]::Match($src, "\`$oneWay = @\(\`$sel \| Where-Object \{ \`$_\.UnArgs -in ([^}]+)\}")
    $oneWay = @([regex]::Matches($oneWayM.Groups[1].Value, "'([a-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-True 'the one-way list was found' ($oneWay.Count -ge 5)
    $noApply = @(); $noUndo = @(); $asym = @()
    foreach ($d in $scoped) {
        $id = [string]$d.id
        if (-not $apply.ContainsKey($id) -and -not ($id -like 'debloat*')) { $noApply += $id }
        if ("$($d.tab)" -eq 'cleanup' -or $oneWay -contains $id -or $id -like 'debloat*') { continue }
        if (-not $undo.ContainsKey($id)) { $noUndo += $id; continue }
        $w = Get-RegWrites $apply[$id]; $t = Get-RegTouches $undo[$id]
        $ub = $undo[$id].ToLower()
        foreach ($k in $w.Keys) {
            $path = $k.Split('|')[0]; $name = $k.Split('|')[1]
            if ($t.ContainsKey($k) -or $t.ContainsKey('key|' + $path)) { continue }
            # an undo that loops over value names still names them and the key as literals
            if ($ub.Contains("'" + $path + "'") -and $ub.Contains("'" + $name + "'")) { continue }
            # hibernation is put back by powercfg, which writes HibernateEnabled itself
            if ($name -eq 'hibernateenabled' -and $ub.Contains('powercfg')) { continue }
            # FontSmoothing '2' IS the Windows default, so there is nothing to put back
            if ($name -eq 'fontsmoothing') { continue }
            $asym += "$id -> $k"
        }
    }
    Assert-Equal ('every non-debloat row has an Apply clause (missing: ' + ($noApply -join ', ') + ')') 0 $noApply.Count
    Assert-Equal ('every reversible row has an Undo clause (missing: ' + ($noUndo -join ', ') + ')') 0 $noUndo.Count
    Assert-Equal ('every value Apply writes is put back or removed by Undo (gaps: ' + ($asym -join '; ') + ')') 0 $asym.Count
    Assert-True 'restorepoint puts the creation-frequency throttle back' ($apply['restorepoint'] -match 'SystemRestorePointCreationFrequency' -and $apply['restorepoint'] -match 'finally')
    Assert-True 'windowsold fails when the folder survives'             ($apply['windowsold'] -match "'Failed'")
    Assert-True 'reservedstorage checks the DISM exit code'             ($apply['reservedstorage'] -match 'LASTEXITCODE')
    Assert-True 'oembloat records what it changed for its undo'         ($apply['oembloat'] -match 'OemBloatServices' -and $undo['oembloat'] -match 'OemBloatServices')

    # ================================================================== 2. hosts writer
    Write-Section '2. Write-HostsFile keeps the file whole, read-only, and its accents'
    . ([scriptblock]::Create((Get-WFn 'Write-HostsFile')))
    $hosts = Join-Path $root 'hosts'
    $keep = "# R" + [char]0xE9 + "seau de l'atelier - ne pas toucher"
    [IO.File]::WriteAllLines($hosts, @('127.0.0.1 localhost', $keep), (New-Object Text.UTF8Encoding $false))
    [IO.File]::SetAttributes($hosts, [IO.FileAttributes]::ReadOnly)
    Write-HostsFile $hosts @('127.0.0.1 localhost', $keep, '# added')
    $after = [IO.File]::ReadAllLines($hosts, (New-Object Text.UTF8Encoding $false))
    Assert-Equal 'the added line is there'                  '# added' $after[-1]
    Assert-Equal 'the accented comment survived untouched'   $keep $after[1]
    Assert-True  'the read-only attribute was put back'      (([IO.File]::GetAttributes($hosts) -band [IO.FileAttributes]::ReadOnly) -ne 0)
    Assert-True  'no scratch file was left beside it'        (-not (Test-Path -LiteralPath "$hosts.new"))
    [IO.File]::SetAttributes($hosts, [IO.FileAttributes]::Normal)

    # ================================================================== 3. the tab
    Write-Section '3. The tab on the real window, worker stubbed'
    $server = Join-Path $root 'server'; New-Item -ItemType Directory -Force -Path $server | Out-Null
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ([pscustomobject]@{ updated = '2026-01-01'; apps = @([pscustomobject]@{
        id = 'x'; name = 'X'; category = 'Apps'; url = 'https://example.invalid/x.exe'; sha256 = ('a' * 64); sizeBytes = 1; silentArgs = ''; verifyPaths = @("$root\never.exe") }) } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $goAt = $src.IndexOf('# ---------- go ----------')
    . ([scriptblock]::Create($src.Substring(0, $goAt))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
    $script:CacheDir = Join-Path $root 'cache'; New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath = Join-Path $script:CacheDir 'queue.jsonl'; $script:StatusPath = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath = Join-Path $script:CacheDir 'worker.ps1'; $script:CancelPath = Join-Path $script:CacheDir 'cancel.flag'; $script:SkipPath = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'; $script:IconDir = Join-Path $script:CacheDir 'icons'
    # no worker is ever launched: the queue file is the thing under test
    function Start-Worker { if ($script:WorkerStarted) { return $true }; $script:WorkerStarted = $true; return $true }
    # Explorer is never really restarted by this harness; the call is only counted
    $script:ExplorerKills = 0
    function Stop-Process { param([string]$Name, [switch]$Force, $Id, $ErrorAction) $script:ExplorerKills++ }
    function Send-SettingChange { }
    Load-Tweaks
    Select-Tab 'Tweak'
    Assert-True 'the Tweaks list is on screen'              ($script:TweakItems.Count -ge 40)
    function Row([string]$Id) { @($script:TweakItems | Where-Object { $_.UnArgs -eq $Id })[0] }
    foreach ($t in $script:TweakItems) { $t.IsSelected = $false }

    # probes replaced wholesale: what each answers is the test's to decide
    $script:TweakTests = @{}
    $script:TweakTests['telemetry'] = { $true }         # already applied -> skipped
    $script:TweakTests['debloatweb'] = { $true }        # "applied" for this account only -> must still queue
    $script:TweakTests['endtask'] = { $false }
    $script:TweakTests['restorepoint'] = $null
    foreach ($id in 'restorepoint', 'endtask', 'telemetry', 'debloatweb') { (Row $id).IsSelected = $true }
    Click $BtnTweakApply
    Assert-Equal 'the batch started (Install phase)'         'Install' $script:Phase
    Assert-Equal 'filed under Tweak'                          'Tweak' $script:BatchTab
    Assert-True  'the applied row was skipped, not queued'    ((Row 'telemetry').Status -like 'Already applied*' -or (Row 'telemetry').StatusDetail -like 'Already applied*')
    $q = @(Get-Content -LiteralPath $script:QueuePath | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and $_.action })
    Assert-Equal 'three entries were queued'                  3 $q.Count
    Assert-Equal 'the restore point is first'                 'restorepoint' ([string]$q[0].tweak)
    Assert-True  'the debloat row was queued despite its probe' (@($q | Where-Object { $_.tweak -eq 'debloatweb' }).Count -eq 1)
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    Assert-Equal 'every line carries the technician''s SID'   3 @($q | Where-Object { $_.userSid -eq $sid }).Count
    Assert-True  'the check flag is down again'               (-not $script:TweakChecking)
    Assert-True  'Explorer restart is pending for endtask'    ([bool]$script:NeedExplorerRestart)

    # ---- a declined batch: rows Failed, nothing applied, no Explorer restart
    Abort-Batch 'elevation declined'
    Assert-Equal 'the batch ended'                            'Done' $script:Phase
    Assert-Equal 'Explorer was NOT restarted for a batch that changed nothing' 0 $script:ExplorerKills
    Assert-True  'and the flag is cleared'                    (-not $script:NeedExplorerRestart)
    if ("$($Overlay.Visibility)" -eq 'Visible') { Click $BtnOverlayOk }

    # ---- a batch where one row applied and the rest never ran: "not run", and one restart
    foreach ($t in $script:TweakItems) { $t.IsSelected = $false }
    foreach ($id in 'restorepoint', 'endtask', 'debloatweb') { (Row $id).IsSelected = $true }
    Click $BtnTweakApply
    Assert-Equal 'a second batch started'                     'Install' $script:Phase
    Set-Status (Row 'restorepoint') 'Failed: restore point refused' 'fail'
    Set-Status (Row 'endtask') 'Skipped: the restore point could not be created, so this was not run' 'warn'
    Set-Status (Row 'debloatweb') 'Applied: 2 package(s) removed' 'ok'
    Finish-Batch
    Assert-True  'the summary separates not-run from warnings' ($TxtNow.Text -like 'Finished - 1 completed, 1 failed*1 not run*' -and $TxtNow.Text -notlike '*with warnings*')
    Assert-Equal 'Explorer was restarted once, something having applied' 1 $script:ExplorerKills
    if ("$($Overlay.Visibility)" -eq 'Visible') { Click $BtnOverlayOk }

    # ---- nothing to do
    foreach ($t in $script:TweakItems) { $t.IsSelected = $false }
    foreach ($id in 'restorepoint', 'telemetry') { (Row $id).IsSelected = $true }
    Click $BtnTweakApply
    Assert-True  'all-applied: no batch starts'               ($script:Phase -ne 'Install')
    Assert-True  'the hint says nothing to do'                ($TxtTweakHint.Text -like 'nothing to do*')
    Assert-True  'the restore point alone is not created'     ((Row 'restorepoint').StatusDetail -like 'Skipped - nothing else will run*' -or (Row 'restorepoint').Status -like 'Skipped*')
    Assert-True  'the check flag is down'                     (-not $script:TweakChecking)

    # ---- a second press DURING the check is refused, not nested
    foreach ($t in $script:TweakItems) { $t.IsSelected = $false }
    (Row 'endtask').IsSelected = $true
    $script:NestedRefused = $false; $script:NestedQueueSeen = 0
    $script:TweakTests['endtask'] = {
        # a click landing while the probes run - the exact moment the bug lived in
        Click $BtnTweakApply
        if ("$($TxtOverlayTitle.Text)" -eq 'Still checking') { $script:NestedRefused = $true }
        if (Test-Path -LiteralPath $script:QueuePath) { $script:NestedQueueSeen = @(Get-Content -LiteralPath $script:QueuePath).Count }
        return $false
    }
    Click $BtnTweakApply
    Assert-True  'the nested press was refused with "Still checking"' $script:NestedRefused
    Assert-Equal 'and wrote nothing to the queue'             0 $script:NestedQueueSeen
    Assert-Equal 'the outer press then started ONE batch'    'Install' $script:Phase
    Assert-Equal 'with one entry'                             1 @(Get-Content -LiteralPath $script:QueuePath | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and $_.action }).Count
    Abort-Batch 'test over'
    if ("$($Overlay.Visibility)" -eq 'Visible') { Click $BtnOverlayOk }

    # ---- Detect
    $script:TweakTests['endtask'] = { $true }
    $script:TweakTests['telemetry'] = { $false }
    (Row 'endtask').IsSelected = $false; (Row 'telemetry').IsSelected = $true
    Invoke-TweakDetect
    Assert-True  'Detect ticks a row its probe says is applied'  ((Row 'endtask').IsSelected)
    Assert-True  'and unticks one that is not'                   (-not (Row 'telemetry').IsSelected)
    Assert-True  'a row with no probe is called a one-time action' ((Row 'restorepoint').StatusDetail -like 'one-time action*' -or (Row 'restorepoint').Status -like 'one-time action*')
    Assert-True  'the check flag is down after Detect'           (-not $script:TweakChecking)

    # ---- the Cleanup sub-tab acts on its own list
    Select-OptTab 'Clean'
    Assert-Equal 'Undo is hidden on Cleanup'                     'Collapsed' "$($BtnTweakUndo.Visibility)"
    Assert-Equal 'the button reads Run Cleanup'                  'Run Cleanup' $TxtTweakApplyBtn.Text
    Set-OptSelection $false
    Assert-Equal 'Clear All emptied the Cleanup list only'       0 @($script:CleanItems | Where-Object { $_.IsSelected }).Count
    Assert-True  'and left the Tweaks list alone'                (@($script:TweakItems | Where-Object { $_.IsSelected }).Count -ge 1)

    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    try { if ($timer) { $timer.Stop() } } catch { }
    try { if ($script:HaveMutex -and $script:AppMutex) { $script:AppMutex.ReleaseMutex() } } catch { }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Write-Host "CLEANUP INCOMPLETE: $root" -ForegroundColor Red } else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
}
