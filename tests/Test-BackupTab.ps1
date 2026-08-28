<#
.SYNOPSIS
    Drives the real Data Backup and Accounts tabs - the buttons, the modes, the log - on a window
    that is built but never shown.

.DESCRIPTION
    Test-DataBackup proves the copy ENGINE inside the worker. Nothing proved the tab in front of
    it: which mode needs which pick, what the button does while it measures, what the Activity
    log says while a copy runs, and what the closing dialog reports. Every one of those had a
    bug that a green engine test could not see:

      * Restore demanded a SOURCE PROFILE - a list that is not on screen in restore mode - so
        "Restore Data" answered 'No source' against an empty column and could not be started.
      * The measuring pass pumped the dispatcher, which let the button re-enter itself and start
        a second walk over the first. Now the second press is Stop.
      * A copy reports progress once a second and every report went into a 500-line log.
      * Every account batch ended with 'Downloaded installers removed' about installers it never had.
      * The overall bar inherited the previous install batch's position and opened at 100%.

    This loads AppDeploy.ps1 to its "go" line - window built, handlers wired - redirects the
    cache into a sandbox, launches the SAME worker script without the UAC prompt, and then:

      1. Restore mode reaches the confirm sheet with NO source profile picked, measures from the
         backup folder, and is cancelled before anything is copied.
      2. Drive/USB mode refuses a folder inside the profile before measuring, and a folder that
         has gone away.
      3. A REAL backup of one small profile folder to the sandbox, end to end through the real
         worker: the log carries each phase once, the clock is on the progress row, the bar reads
         'step 1 of 1', Test-BatchBusy names the copy, no installer lines, the closing dialog
         says where it went, the run record is filed as a Backup, and the manifest is there.
      4. Get-FolderSize stops when its tick says stop.
      5. Switching mode forgets the folder; the Add Account dialog refuses the names Windows refuses.

    Runs unelevated. The one real copy is FROM this account's own profile TO a folder under
    C:\Users\Public (it has to be outside the profile - the tab refuses anything inside it, and
    %TEMP% is inside it), never into a profile. Both folders are removed at the end; nothing else
    is written, and nothing is deleted.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-BackupTab.ps1
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

$script:Pass = 0
$script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") {
        $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$tag     = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox = Join-Path $env:TEMP "pc2go-bk-$tag"

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
function Stop-OrphanWorkers([string]$Match = 'pc2go-bk-') {
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
function Get-OverlayTitle { return ('' + $TxtOverlayTitle.Text) }
function Dismiss-Overlay {
    if ("$($Overlay.Visibility)" -eq 'Visible') {
        if ("$($BtnOverlayCancel.Visibility)" -eq 'Visible') { Invoke-Click $BtnOverlayCancel } else { Invoke-Click $BtnOverlayOk }
    }
}
function Get-LogLines { return @((Get-LogText) -split "`r?`n" | Where-Object { $_.Trim() }) }

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host "Sandbox   : $sandbox" -ForegroundColor DarkGray
    $killed = Stop-OrphanWorkers
    if ($killed) { Write-Host "  killed $killed orphaned worker(s) from a previous run" -ForegroundColor Yellow }

    # An empty local catalog is enough: the Install tab is not under test, and the GUI loads
    # without a single app in it.
    $server = Join-Path $sandbox 'catalog'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'),
        ([pscustomobject]@{ updated = (Get-Date -Format 'yyyy-MM-dd'); apps = @() } | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding $false))

    Write-Section 'Loading the real GUI (window built, handlers wired, never shown)'
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker in AppDeploy.ps1.' }
    . ([scriptblock]::Create($src.Substring(0, $goAt))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
    Assert-True 'the window was built'        ($null -ne $window)
    Assert-True 'the Backup button exists'    ($null -ne $BtnMigrate)

    # The only stub: the same worker, built the same way, launched without the UAC prompt.
    function Start-Worker {
        if ($script:WorkerStarted) { return $true }
        Remove-Item -LiteralPath $script:WorkerPath -Force -ErrorAction SilentlyContinue
        $nvAssign = "`$NvApiSrc = @'" + [Environment]::NewLine + $script:NvApiSource + [Environment]::NewLine + "'@"
        $built = $workerScript.Replace('#__NVAPISOURCE__', $nvAssign).Replace('#__SHAREDTABLES__', (Get-SharedTablesSource))
        Set-Content -Path $script:WorkerPath -Value $built -Encoding UTF8
        Remove-Item -LiteralPath $script:StatusPath, $script:CancelPath -ErrorAction SilentlyContinue
        $script:StatusOffset = 0
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:WorkerPath`" " +
                  "-QueueFile `"$script:QueuePath`" -StatusFile `"$script:StatusPath`" -CancelFile `"$script:CancelPath`" " +
                  "-SkipFile `"$script:SkipPath`" -ParentPid $PID"
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList $psArgs | Out-Null
        $script:WorkerStarted = $true
        Add-Log 'Worker started (test harness: no elevation prompt).'
        return $true
    }

    $script:CacheDir      = Join-Path $sandbox 'cache'
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath     = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath    = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath    = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath    = Join-Path $script:CacheDir 'cancel.flag'
    $script:SkipPath      = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'
    $timer.Start()

    Select-Tab 'Migrate'
    Assert-True 'the profile list found this account' (@($script:SrcUsers | Where-Object { $_.Name -eq [Environment]::UserName }).Count -eq 1)
    $meSrc = @($script:SrcUsers | Where-Object { $_.Name -eq [Environment]::UserName })[0]
    $meDst = @($script:DstUsers | Where-Object { $_.Name -eq [Environment]::UserName })[0]
    Assert-True 'and the account list too' ($null -ne $meDst)
    $myProfile = [string]$meSrc.UnArgs

    # ================================================================== 1. restore
    Write-Section '1. Restore mode starts with NO source profile picked'

    # A backup folder the way the worker writes one: the manifest plus one item folder.
    $bk = Join-Path $sandbox 'PC2Go Backup - FAKEPC - someone'
    New-Item -ItemType Directory -Force -Path (Join-Path $bk 'Documents') | Out-Null
    Set-Content -LiteralPath (Join-Path $bk 'Documents\hello.txt') -Value 'restore me' -Encoding ASCII
    [IO.File]::WriteAllText((Join-Path $bk 'pc2go-backup.json'), ([ordered]@{
        version = 1; kind = 'profile-backup'; sourceMachine = 'FAKEPC'; sourceUser = ''
        sourceProfile = 'C:\Users\someone'; startedUtc = ([datetime]::UtcNow).ToString('o')
        finishedUtc = ([datetime]::UtcNow).ToString('o'); seconds = 1
        items = @(@{ rel = 'Documents'; files = 1; bytes = 10; verified = $true }) } | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding $false))

    Select-BackupMode 'restore'
    Assert-Equal 'the source list is off screen in restore mode' 'Collapsed' "$($ListSrcUsers.Visibility)"
    Assert-Equal 'and no source profile is picked'            0 @($script:SrcUsers | Where-Object { $_.IsSelected }).Count
    Set-BackupFolder $bk '' ''
    Assert-True 'the folder note describes the backup'         ($TxtFolderNote.Text -like '*FAKEPC*')
    Assert-Equal 'the item list is read from the BACKUP'       1 $script:MigrateItems.Count
    Assert-Equal 'and names the folder it holds'               'Documents' $script:MigrateItems[0].Name
    $meDst.IsSelected = $true

    Invoke-Click $BtnMigrate
    Assert-Equal 'the confirm sheet opened - no "No source" refusal' 'Restore this backup?' (Get-OverlayTitle)
    Assert-True  'the sheet names the backup as the source'          ($TxtOverlayMsg.Text -like "*$bk*")
    Assert-True  'and the account as the destination'                ($TxtOverlayMsg.Text -like "*`"$([Environment]::UserName)`"*")
    Assert-True  'the item was measured from the backup, not a profile' ($script:MigrateItems[0].Size -match '\d')
    Assert-True  'the log records the measurement'                   ((Get-LogText) -match 'Restore: measured 1 item')
    Assert-True  'measuring left the button usable'                  ($BtnMigrate.IsEnabled -and -not $script:Measuring)
    Assert-Equal 'and put its label back'                            'Restore Data' "$($BtnMigrate.Content)"
    Dismiss-Overlay
    Assert-Equal 'cancelled: nothing was queued' 'Idle' "$($script:Phase)"

    # A folder that is NOT a backup is refused before any UAC prompt.
    $plain = Join-Path $sandbox 'just-a-folder'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    Set-BackupFolder $plain '' ''
    Invoke-Click $BtnMigrate
    Assert-Equal 'a folder without a manifest is refused up front' 'Not a backup this tool wrote' (Get-OverlayTitle)
    Dismiss-Overlay

    # ================================================================== 2. drive/USB refusals
    Write-Section '2. Drive/USB mode: the loops are refused before measuring'

    Select-BackupMode 'folder'
    Assert-Equal 'switching mode forgot the folder'             '' "$($script:FolderPath)"
    $meSrc.IsSelected = $true
    $inside = Join-Path $myProfile "pc2go-bk-$tag"
    New-Item -ItemType Directory -Force -Path $inside | Out-Null
    try {
        Set-BackupFolder $inside '' ''
        Invoke-Click $BtnMigrate
        Assert-Equal 'a folder inside the profile is refused'   'Refused - that folder is inside the profile' (Get-OverlayTitle)
        Dismiss-Overlay
    } finally { Remove-Item -LiteralPath $inside -Recurse -Force -ErrorAction SilentlyContinue }
    $gone = Join-Path $sandbox 'unplugged'
    New-Item -ItemType Directory -Force -Path $gone | Out-Null
    Set-BackupFolder $gone '' ''
    Remove-Item -LiteralPath $gone -Recurse -Force
    Invoke-Click $BtnMigrate
    Assert-Equal 'a folder that has gone away is refused'       'Folder not there' (Get-OverlayTitle)
    Dismiss-Overlay

    # ================================================================== 3. a real backup
    Write-Section '3. A real backup of one small folder, through the real worker'

    # Left where a previous install batch would have left it. The bar is computed from it.
    $script:DlIndex = 7
    # OUTSIDE the profile. %TEMP% is C:\Users\<me>\AppData\Local\Temp, and a destination inside
    # the profile being backed up is exactly what section 2 proved is refused - the first run of
    # this harness put the "USB stick" there and was turned away by its own guard. Public is
    # writable by every account and belongs to none of them.
    $dest = Join-Path $env:PUBLIC "pc2go-bk-$tag"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Set-BackupFolder $dest '' ''

    # AFTER Set-BackupFolder, which rebuilds the item list with its defaults ticked. Unticking
    # first backed up eleven folders of a real profile - 151 seconds - instead of one.
    # The smallest profile folder that exists, so the copy is seconds. Everything else unticked.
    foreach ($m in $script:MigrateItems) { $m.IsSelected = $false }
    $pick = $null
    foreach ($cand in 'Links', 'Searches', 'Contacts', 'Favorites', 'Music', 'Videos') {
        $pick = @($script:MigrateItems | Where-Object { $_.UnArgs -eq $cand })[0]
        if ($pick) { break }
    }
    if (-not $pick) { $pick = $script:MigrateItems[0] }
    $pick.IsSelected = $true
    Assert-Equal 'exactly one folder is ticked' 1 @($script:MigrateItems | Where-Object { $_.IsSelected }).Count
    Write-Host "  copying '$($pick.Name)' from this profile" -ForegroundColor DarkGray
    $logBefore = (Get-LogLines).Count
    Invoke-Click $BtnMigrate
    Assert-Equal 'the confirm sheet for a drive backup'          'Back up this data?' (Get-OverlayTitle)
    Assert-True  'it says Cancel is available while copying'     ($TxtOverlayMsg.Text -like '*press Cancel*')
    Invoke-Click $BtnOverlayOk
    Assert-Equal 'the batch started'                             'Install' "$($script:Phase)"
    Assert-Equal 'DlIndex was reset for the user batch'          0 $script:DlIndex
    Assert-Equal 'the status line names the job'                 'Backing up profile data...' "$($TxtStatus.Text)"
    Assert-Equal 'the batch is filed under the Backup tab'       'Migrate' "$($script:BatchTab)"

    # While it runs: Test-BatchBusy has to name THIS job, and the overall line has to carry the
    # clock and say 'step', not 'app'.
    # $script: on purpose: an assignment inside the Wait-For block lands in the block's own scope.
    $script:BusyMsg = ''
    $script:SawClock = $false; $script:SawStep = $false
    $settled = Wait-For {
        if (-not $script:BusyMsg -and $script:Phase -eq 'Install') {
            [void](Test-BatchBusy); $script:BusyMsg = '' + $TxtOverlayMsg.Text; Dismiss-Overlay
        }
        if ($TxtOverall.Text -like '*elapsed*') { $script:SawClock = $true }
        if ($TxtOverall.Text -like '*step 1 of 1*') { $script:SawStep = $true }
        $script:Phase -in 'Done', 'Idle'
    } 180000
    Assert-True  'the batch settled'                             $settled
    Assert-True  'Test-BatchBusy named the copy, not "apps downloading"' ($script:BusyMsg -like '*A backup or restore is still copying.*')
    $row = $script:Pending[0]
    Assert-True  'the row reports Applied'                       ($row.Status -like 'Applied*')
    if ($row.Status -notlike 'Applied*') { Write-Host "          detail: $($row.StatusDetail)" -ForegroundColor DarkGray }
    Assert-True  'with the destination in its detail'            ($row.StatusDetail -like "*$dest*")
    Assert-True  'the overall line carried the elapsed clock'    $script:SawClock
    Assert-True  'and read "step 1 of 1", not "app 1 of 1"'      $script:SawStep
    Assert-Equal 'the closing dialog is the backup verdict'      'Finished' (Get-OverlayTitle)
    Assert-True  'and says where the data went'                  ($TxtOverlayMsg.Text -like "*$dest*")
    Dismiss-Overlay
    $bkDir = Join-Path $dest (Get-BackupFolderName ([Environment]::UserName))
    Assert-True  'the backup folder exists where the sheet promised' (Test-Path -LiteralPath $bkDir)
    Assert-True  'with the manifest beside the data'             (Test-Path -LiteralPath (Join-Path $bkDir 'pc2go-backup.json'))

    # The log: each phase ONCE, the clock, no installer talk.
    $log = @((Get-LogLines) | Select-Object -Skip $logBefore)
    $copying  = @($log | Where-Object { $_ -match '-> Applying: copying ' }).Count
    $verified = @($log | Where-Object { $_ -match '-> Applying: verified ' }).Count
    Assert-Equal '"copying <folder>" is logged exactly once'     1 $copying
    Assert-Equal 'and "verified <folder>" exactly once'          1 $verified
    Assert-Equal 'no per-second progress lines reached the log'  0 @($log | Where-Object { $_ -match ' of .* at .*/s' }).Count
    Assert-Equal 'no "Downloaded installers removed" on a copy'  0 @($log | Where-Object { $_ -like '*installers removed*' }).Count
    Assert-Equal 'no "Cache kept" on a copy'                     0 @($log | Where-Object { $_ -like '*Cache kept*' }).Count
    Assert-True  'the batch summary is there'                    ([bool]@($log | Where-Object { $_ -like '*Batch complete: *' }).Count)

    $runs = @(Get-ChildItem -LiteralPath (Get-RunsDir) -Filter 'run-*.json' -ErrorAction SilentlyContinue)
    Assert-Equal 'one run record was written'                    1 $runs.Count
    if ($runs.Count) {
        $rec = Get-Content -LiteralPath $runs[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'filed as a Backup, not an Install'         'Backup' "$($rec.kind)"
        Assert-True  'with a real duration, not 0s'              ([int]$rec.seconds -ge 1)
        Assert-Equal 'and one row in total'                      1 ([int]$rec.counts.total)
        Assert-Equal 'and it is the ok one'                       1 ([int]$rec.counts.ok)
    }
    Assert-True  'the account list was rebuilt after the batch' ($script:DstUsers.Count -ge 1)
    Assert-True  'the queue file was cleared'                    (-not (Test-Path -LiteralPath $script:QueuePath))

    # ================================================================== 4. measuring stops
    Write-Section '4. Get-FolderSize stops when its tick says stop'

    $big = Join-Path $sandbox 'big'
    1..450 | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $big "d$_") | Out-Null }
    Set-Content -LiteralPath (Join-Path $big 'd1\x.txt') -Value 'x' -Encoding ASCII
    $script:TickCalls = 0
    $sz = Get-FolderSize $big { param($sofar) $script:TickCalls++; return $false }
    Assert-Equal 'the walk stopped at the first tick'           1 $script:TickCalls
    $script:TickCalls = 0
    $sz2 = Get-FolderSize $big { param($sofar) $script:TickCalls++ }
    Assert-True  'a tick that returns nothing does not stop it' ($script:TickCalls -ge 2)
    Assert-True  'and the full walk counted the file'           ($sz2 -ge 1)

    # ================================================================== 5. small guards
    Write-Section '5. Accounts: the Add Account dialog refuses what Windows refuses'

    Select-Tab 'Users'
    Invoke-Click $BtnNewAccount
    Assert-Equal 'the dialog opened' 'Visible' "$($NewUserOverlay.Visibility)"
    foreach ($bad in @('trailing.', '...', 'a:b', ('x' * 21))) {
        $TxtNewUser.Text = $bad
        Invoke-Click $BtnNewUserOk
        Assert-Equal "'$bad' is refused" 'Invalid account name' (Get-OverlayTitle)
        Dismiss-Overlay
        $NewUserOverlay.Visibility = 'Visible'
    }
    $TxtNewUser.Text = [Environment]::UserName
    Invoke-Click $BtnNewUserOk
    Assert-Equal 'an existing name is refused' 'Account exists' (Get-OverlayTitle)
    Dismiss-Overlay
    $NewUserOverlay.Visibility = 'Collapsed'

    # Test-BatchBusy wording for an account batch, without running one.
    $script:Phase = 'Install'; $script:BatchTab = 'Users'
    [void](Test-BatchBusy)
    Assert-True 'Test-BatchBusy names an account change' ($TxtOverlayMsg.Text -like '*An account change is still running.*')
    Dismiss-Overlay
    $script:Phase = 'Idle'

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    try { $timer.Stop() } catch { }
    $left = Stop-OrphanWorkers
    if ($left) { Write-Host "  stopped $left worker(s) still running at exit" -ForegroundColor Yellow }
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $sandbox" -ForegroundColor Yellow
    } else {
        $pub = Join-Path $env:PUBLIC "pc2go-bk-$tag"
        foreach ($d in @($sandbox, $pub)) {
            try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }
        $stay = @(@($sandbox, $pub) | Where-Object { Test-Path -LiteralPath $_ })
        if ($stay.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($stay -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
