<#
.SYNOPSIS
    The Data Backup tab's three jobs, run for real through the REAL elevated worker into a
    throwaway account - plus the "replace with a local admin" chain.

.DESCRIPTION
    Test-BackupTab drives the tab unelevated and can only back up TO a folder. The jobs that
    matter most on a client machine - copying a broken profile into a new account, restoring a
    backup into an account, replacing a Microsoft account with a local admin - all need
    elevation and a second account, and had never been run end to end. This runs them:

      1. create 'pc2go-probe' (standard) through the Accounts tab
      2. profile -> account: copy one folder from THIS profile into pc2go-probe; the files
         are checked on disk under C:\Users\pc2go-probe, and the ACL check passes
      3. profile -> folder: back the same folder up under C:\Users\Public, then plant a marker
         file in the backup and RESTORE it into pc2go-probe; the marker must arrive
      4. replace with a local admin: from pc2go-probe's dialog, create 'pc2go-probe2' as an
         admin, copy the data across, disable pc2go-probe - one chain, one UAC prompt; every
         step is checked on the machine

    Cleanup removes both accounts, their profile folders and ProfileList entries, and the
    backup under Public. About six UAC prompts in all.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ElevatedBackup.ps1
#>
[CmdletBinding()]
param([string]$ScriptPath)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
if (-not $ScriptPath) { $ScriptPath = Join-Path $repo 'server\AppDeploy.ps1' }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) { Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
function Wait-Dispatcher([int]$ms) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($ms)
    $t.Add_Tick({ $frame.Continue = $false; $t.Stop() }.GetNewClosure())
    $t.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-For([scriptblock]$Until, [int]$TimeoutMs = 300000) {
    $w = 0; while ($w -lt $TimeoutMs) { if (& $Until) { return $true }; Wait-Dispatcher 250; $w += 250 }
    return [bool](& $Until)
}
function Invoke-Click($b) { $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
function Get-Acct([string]$n) { try { Get-LocalUser -Name $n -ErrorAction Stop } catch { $null } }
function Dismiss { if ("$($Overlay.Visibility)" -eq 'Visible') { Invoke-Click $BtnOverlayOk } }
function Run-Batch([string]$Label) {
    Write-Host "  $Label - approve the UAC prompt..." -ForegroundColor Yellow
    Invoke-Click $BtnOverlayOk
    $ok = Wait-For { $script:Phase -in 'Done', 'Idle' }
    Assert-True "$Label - the batch settled" $ok
    foreach ($p in @($script:Pending)) { Write-Host "  row: $($p.Name): $($p.Status) - $($p.StatusDetail)" -ForegroundColor DarkGray }
    Dismiss
}
function Pick-Only([string]$Rel) {
    foreach ($m in $script:MigrateItems) { $m.IsSelected = $false }
    $it = @($script:MigrateItems | Where-Object { $_.UnArgs -eq $Rel })[0]
    if ($it) { $it.IsSelected = $true }
    return $it
}
function Profile-Of([string]$n) {
    $u = Get-Acct $n; if (-not $u) { return '' }
    $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($u.SID.Value)"
    try { return ('' + (Get-ItemProperty -LiteralPath $pl -ErrorAction Stop).ProfileImagePath) } catch { return '' }
}

$p1 = 'pc2go-probe'; $p2 = 'pc2go-probe2'; $pw = 'Probe!2026x'
$tag = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox = Join-Path $env:TEMP "pc2go-elbk-$tag"
$pub = Join-Path $env:PUBLIC "pc2go-elbk-$tag"
$me = [Environment]::UserName
$sids = @{}

try {
    foreach ($n in $p1, $p2) { if (Get-Acct $n) { throw "'$n' already exists on this machine - remove it first." } }
    New-Item -ItemType Directory -Force -Path $sandbox, $pub | Out-Null
    $server = Join-Path $sandbox 'catalog'; New-Item -ItemType Directory -Force -Path $server | Out-Null
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'),
        ([pscustomobject]@{ updated = (Get-Date -Format 'yyyy-MM-dd'); apps = @() } | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding $false))

    Write-Section 'Loading the real GUI - the REAL Start-Worker, no stub'
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    . ([scriptblock]::Create($src.Substring(0, $src.IndexOf('# ---------- go ----------')))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
    $script:CacheDir = Join-Path $sandbox 'cache'; New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    foreach ($kv in @{ QueuePath = 'queue.jsonl'; StatusPath = 'status.jsonl'; WorkerPath = 'worker.ps1'; CancelPath = 'cancel.flag'
                      SkipPath = 'skip.txt'; ManifestCache = 'apps.json'; IconDir = 'icons' }.GetEnumerator()) {
        Set-Variable -Scope Script -Name $kv.Key -Value (Join-Path $script:CacheDir $kv.Value)
    }
    $timer.Start()

    # The folder this run copies around: the smallest one this profile has.
    Select-Tab 'Migrate'
    $meSrc = @($script:SrcUsers | Where-Object { $_.Name -eq $me })[0]
    $meSrc.IsSelected = $true
    $rel = $null
    foreach ($cand in 'Links', 'Searches', 'Contacts', 'Favorites') {
        if (@($script:MigrateItems | Where-Object { $_.UnArgs -eq $cand }).Count) { $rel = $cand; break }
    }
    if (-not $rel) { throw 'This profile has none of the small folders the run copies.' }
    $srcFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE $rel) -File -Recurse -Force -ErrorAction SilentlyContinue).Count
    Write-Host "  using '$rel' ($srcFiles file(s)) from $env:USERPROFILE" -ForegroundColor DarkGray

    # ================================================================== 1. the account
    Write-Section "1. Create '$p1' (standard) through the Accounts tab"
    Select-Tab 'Users'
    Invoke-Click $BtnNewAccount
    $TxtNewUser.Text = $p1; $TxtNewFull.Text = ''; $TxtNewPw.Text = $pw; $ChkNewAdmin.IsChecked = $false
    Invoke-Click $BtnNewUserOk
    Run-Batch 'create'
    Assert-True 'the account exists on the machine' ($null -ne (Get-Acct $p1))
    $prof1 = Profile-Of $p1
    Assert-True 'its profile folder exists' ($prof1 -and (Test-Path -LiteralPath $prof1))
    if (Get-Acct $p1) { $sids[$p1] = (Get-Acct $p1).SID.Value }

    # ================================================================== 2. profile -> account
    Write-Section "2. Copy '$rel' from this profile INTO '$p1' (the broken-profile job)"
    Select-Tab 'Migrate'
    Select-BackupMode 'profile'
    $meSrc = @($script:SrcUsers | Where-Object { $_.Name -eq $me })[0]; $meSrc.IsSelected = $true
    $dst1 = @($script:DstUsers | Where-Object { $_.Name -eq $p1 })[0]
    Assert-True "'$p1' is offered as a destination" ($null -ne $dst1)
    $dst1.IsSelected = $true
    [void](Pick-Only $rel)
    Invoke-Click $BtnMigrate
    Assert-Equal 'the confirm sheet opened' 'Copy this data?' ('' + $TxtOverlayTitle.Text)
    Run-Batch 'migrate'
    $row = $script:Pending[0]
    Assert-True 'the row reports Applied (no ACL / verify complaint)' ($row.Status -like 'Applied*')
    $landed = Join-Path $prof1 $rel
    Assert-True "the folder now exists under $prof1" (Test-Path -LiteralPath $landed)
    $dstFiles = @(Get-ChildItem -LiteralPath $landed -File -Recurse -Force -ErrorAction SilentlyContinue).Count
    Assert-Equal 'every file arrived' $srcFiles $dstFiles
    # The new user must be able to open what was copied: Copy-ProfileData copies WITHOUT ACLs
    # so the destination inherits, and checks the account has an entry. Verify from outside.
    $acl = Get-Acl -LiteralPath $landed
    Assert-True "$p1 has an access entry on the copied folder" ([bool]@($acl.Access | Where-Object { $_.IdentityReference.Value -like "*\$p1" }).Count)

    # ================================================================== 3. folder backup, then restore
    Write-Section "3. Back '$rel' up under Public, plant a marker in the backup, RESTORE into '$p1'"
    Select-BackupMode 'folder'
    $meSrc = @($script:SrcUsers | Where-Object { $_.Name -eq $me })[0]; $meSrc.IsSelected = $true
    Set-BackupFolder $pub '' ''
    [void](Pick-Only $rel)
    Invoke-Click $BtnMigrate
    Assert-Equal 'the backup confirm opened' 'Back up this data?' ('' + $TxtOverlayTitle.Text)
    Run-Batch 'backup'
    $bkDir = Join-Path $pub (Get-BackupFolderName $me)
    Assert-True 'the backup folder exists' (Test-Path -LiteralPath (Join-Path $bkDir $rel))
    Assert-True 'with its manifest' (Test-Path -LiteralPath (Join-Path $bkDir 'pc2go-backup.json'))
    $marker = "pc2go-restore-marker-$tag.txt"
    Set-Content -LiteralPath (Join-Path (Join-Path $bkDir $rel) $marker) -Value 'came from the backup' -Encoding ASCII

    Select-BackupMode 'restore'
    Set-BackupFolder $bkDir '' ''
    $dst1 = @($script:DstUsers | Where-Object { $_.Name -eq $p1 })[0]; $dst1.IsSelected = $true
    Assert-True 'the restore list shows the backed-up folder' ([bool](Pick-Only $rel))
    Invoke-Click $BtnMigrate
    Assert-Equal 'the restore confirm opened' 'Restore this backup?' ('' + $TxtOverlayTitle.Text)
    Run-Batch 'restore'
    $row = $script:Pending[0]
    Assert-True 'the restore row reports Applied' ($row.Status -like 'Applied*')
    Assert-True "the marker file arrived in $p1's profile - the restore really copied" (Test-Path -LiteralPath (Join-Path $landed $marker))

    # ================================================================== 4. replace with a local admin
    Write-Section "4. Replace '$p1' with a new local admin '$p2' (create -> copy -> disable, one prompt)"
    Select-Tab 'Users'
    $item1 = @($script:AccountItems | Where-Object { $_.Name -eq $p1 })[0]
    Assert-True "the Accounts tab lists '$p1'" ($null -ne $item1)
    # the account dialog's OWN boxes, filled after it opens (opening clears them): the Add
    # Account dialog's boxes are a different popup and are not what Replace reads any more
    Show-AcctDialog $item1
    $TxtActNewName.Text = $p2; $TxtActPw.Text = $pw
    Invoke-Click $BtnActLocal
    # not a Microsoft account, so the tool asks first
    Assert-Equal 'it says the account is already local' 'That is already a local account' ('' + $TxtOverlayTitle.Text)
    Invoke-Click $BtnOverlayOk
    Assert-Equal 'then offers the replacement chain' 'Replace with a local admin?' ('' + $TxtOverlayTitle.Text)
    Run-Batch 'replace'
    $u2 = Get-Acct $p2
    Assert-True "'$p2' exists on the machine" ($null -ne $u2)
    if ($u2) {
        $sids[$p2] = $u2.SID.Value
        $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object { '' + $_.SID.Value })
        $users  = @(Get-LocalGroupMember -SID 'S-1-5-32-545' -ErrorAction SilentlyContinue | ForEach-Object { '' + $_.SID.Value })
        Assert-True 'it is an Administrator' ($admins -contains $u2.SID.Value)
        Assert-True 'and in Users (sign-in tile)' ($users -contains $u2.SID.Value)
        $prof2 = Profile-Of $p2
        Assert-True 'its profile folder exists' ($prof2 -and (Test-Path -LiteralPath $prof2))
        Assert-True "the data was copied across - marker present under $p2" (Test-Path -LiteralPath (Join-Path (Join-Path $prof2 $rel) $marker))
    }
    $u1 = Get-Acct $p1
    Assert-True "'$p1' still exists (nothing deleted)" ($null -ne $u1)
    Assert-True "and is now DISABLED" ($u1 -and -not $u1.Enabled)
    Assert-True "its files are untouched" (Test-Path -LiteralPath (Join-Path $landed $marker))
    foreach ($p in @($script:Pending)) { Assert-True "chain step '$($p.Name)' reports Applied" ($p.Status -like 'Applied*') }

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
} finally {
    try { $timer.Stop() } catch { }
    $cmds = @()
    foreach ($n in $p1, $p2) {
        if (Get-Acct $n) { $cmds += "net user $n /delete" }
        $sid = $sids[$n]; if (-not $sid) { try { $sid = (Get-Acct $n).SID.Value } catch { } }
        if ($sid) {
            $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            $dir = ''; try { $dir = (Get-ItemProperty -LiteralPath $pl -ErrorAction Stop).ProfileImagePath } catch { }
            if ($dir -and $dir -like "*\$n*" -and (Test-Path -LiteralPath $dir)) { $cmds += "Remove-Item -LiteralPath '$dir' -Recurse -Force" }
            if (Test-Path -LiteralPath $pl) { $cmds += "Remove-Item -LiteralPath '$pl' -Recurse -Force" }
        }
        if (Test-Path -LiteralPath "C:\Users\$n") { $cmds += "Remove-Item -LiteralPath 'C:\Users\$n' -Recurse -Force" }
    }
    if ($cmds.Count) {
        Write-Host '  cleaning up (last UAC prompt)...' -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -Command `"$($cmds -join '; ')`""
    }
    Remove-Item -LiteralPath $sandbox, $pub -Recurse -Force -ErrorAction SilentlyContinue
    $stay = @()
    foreach ($n in $p1, $p2) {
        if (Get-Acct $n) { $stay += "account $n" }
        if (Test-Path -LiteralPath "C:\Users\$n") { $stay += "C:\Users\$n" }
    }
    if (Test-Path -LiteralPath $pub) { $stay += $pub }
    if ($stay.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($stay -join '; ')) -ForegroundColor Red } else { Write-Host 'Machine left as found.' -ForegroundColor DarkGray }
}
