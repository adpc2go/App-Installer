<#
.SYNOPSIS
    "Share this PC" and "Stop sharing", run for real through the REAL elevated worker on this
    machine, and checked against what Windows itself reports.

.DESCRIPTION
    Shares a throwaway folder under C:\Users\Public through the Backup tab's dialog, then:
      - Get-SmbShare shows it, tagged 'PC2Go share', Full for Authenticated Users
      - something inbound on port 445 is enabled in the firewall
      - a file can be written through \\localhost\<name>
      - the buttons read 'Share more...' / Stop visible; the run record is filed as 'Share'
      - the closing dialog tells the other PC what to do
    then presses Stop sharing and checks the share is gone, the buttons reset, and the firewall
    is back to what it was before the run (or the row says what is still shared and why it
    was left on). Two UAC prompts. The folder is removed at the end.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ElevatedShare.ps1
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
function Dismiss { if ("$($Overlay.Visibility)" -eq 'Visible') { Invoke-Click $BtnOverlayOk } }
function Run-Batch([string]$Label) {
    Write-Host "  $Label - approve the UAC prompt..." -ForegroundColor Yellow
    $ok = Wait-For { $script:Phase -in 'Done', 'Idle' }
    Assert-True "$Label - the batch settled" $ok
    foreach ($p in @($script:Pending)) { Write-Host "  row: $($p.Name): $($p.Status) - $($p.StatusDetail)" -ForegroundColor DarkGray }
}
# Private and Domain only - the tool never touches the Public-profile rules, so a Public 445 rule that
# was already on (as on this host) must not read as "sharing is on".
function Smb-Open { try { return [bool]@(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Enabled True -Direction Inbound -ErrorAction Stop | Where-Object { "$($_.Profile)" -ne 'Public' } | Get-NetFirewallPortFilter | Where-Object { "$($_.LocalPort)" -eq '445' }).Count } catch { return $false } }

$tag = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox = Join-Path $env:TEMP "pc2go-elsh-$tag"
$folder = Join-Path $env:PUBLIC "pc2go-share-$tag"
$shareName = ''

try {
    New-Item -ItemType Directory -Force -Path $sandbox, $folder | Out-Null
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

    $baseShares = @(Get-SmbShare | Where-Object { -not $_.Name.EndsWith('$') } | ForEach-Object { $_.Name })
    $baseOpen   = Smb-Open
    $baseMine   = @(Get-PC2GoShares).Count
    Write-Host "  before: shares=[$($baseShares -join ',')] smb-inbound-open=$baseOpen pc2go-shares=$baseMine" -ForegroundColor DarkGray

    Write-Section "1. Share $folder through the dialog"
    Select-Tab 'Migrate'; Select-BackupMode 'folder'
    Invoke-Click $BtnShareThis
    Assert-Equal 'the dialog opened' 'Visible' "$($ShareOverlay.Visibility)"
    Assert-True  'it lists at least one drive' ($script:ShareDrives.Count -ge 1)
    Assert-Equal 'the folder is accepted' '' (Add-ShareFolder $folder)
    Assert-Equal 'and is the only thing ticked' 1 @(@($script:ShareDrives) + @($script:ShareFolders) | Where-Object { $_.IsSelected }).Count
    Invoke-Click $BtnShareOk
    Assert-Equal 'the batch started' 'Install' "$($script:Phase)"
    Assert-Equal 'filed under Share' 'Share' "$($script:BatchTab)"
    Run-Batch 'share'
    $setup = $script:Pending[0]; $row = $script:Pending[1]
    Assert-True 'turning sharing on reports Applied' ($setup.Status -like 'Applied*')
    Assert-True 'the share row reports Applied'      ($row.Status -like 'Applied*')
    Assert-True 'the closing dialog tells the other PC what to do' ($TxtOverlayMsg.Text -like "*Find a PC*$env:COMPUTERNAME*")
    Dismiss
    $s = @(Get-SmbShare | Where-Object { $_.Path.TrimEnd('\') -eq $folder })[0]
    Assert-True  'WINDOWS has the share (Get-SmbShare)' ($null -ne $s)
    if ($s) {
        $shareName = $s.Name
        Assert-Equal 'tagged as this tool''s' 'PC2Go share' "$($s.Description)"
        $acc = @(Get-SmbShareAccess -Name $s.Name)
        $auth = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-11').Translate([Security.Principal.NTAccount]).Value
        Assert-True "Full for $auth" ([bool]@($acc | Where-Object { $_.AccountName -eq $auth -and "$($_.AccessRight)" -eq 'Full' -and "$($_.AccessControlType)" -eq 'Allow' }).Count)
        Assert-True 'something inbound on 445 is enabled' (Smb-Open)
        $unc = "\\localhost\$($s.Name)"
        $ok = $false
        try { Set-Content -LiteralPath "$unc\hello-$tag.txt" -Value 'via the share' -Encoding ASCII; $ok = Test-Path -LiteralPath (Join-Path $folder "hello-$tag.txt") } catch { Write-Host "  write via $unc failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Assert-True "a file written through $unc lands in the folder" $ok
    }
    Assert-Equal 'the button now offers more'   'Share more...' "$($BtnShareThis.Content)"
    Assert-Equal 'and Stop sharing is visible'  'Visible' "$($BtnShareStop.Visibility)"
    $rec = @(Get-ChildItem -LiteralPath (Get-RunsDir) -Filter 'run-*.json' | Sort-Object Name | Select-Object -Last 1)[0]
    if ($rec) { Assert-Equal 'the run record is a Share run' 'Share' "$((Get-Content $rec.FullName -Raw | ConvertFrom-Json).kind)" }

    Write-Section '2. Share it again: refused as already shared, no batch'
    Invoke-Click $BtnShareThis
    [void](Add-ShareFolder $folder)
    Invoke-Click $BtnShareOk
    Assert-Equal 'the dialog stays open'        'Visible' "$($ShareOverlay.Visibility)"
    Assert-True  'and says it is already shared' ($TxtShareNote.Text -like '*already shared*')
    Invoke-Click $BtnShareCancel

    Write-Section '3. Stop sharing'
    Invoke-Click $BtnShareStop
    Assert-Equal 'the confirm names the share' $true ($TxtOverlayMsg.Text -like "*$shareName*")
    Invoke-Click $BtnOverlayOk
    Run-Batch 'stop'
    Dismiss
    $rows = @($script:Pending)
    Assert-True 'the remove row reports Applied' ($rows[0].Status -like 'Applied*')
    Assert-True 'WINDOWS no longer has the share' (-not @(Get-SmbShare | Where-Object { $_.Name -eq $shareName }).Count)
    $others = @(Get-SmbShare | Where-Object { -not $_.Name.EndsWith('$') -and "$($_.ShareType)" -eq 'FileSystemDirectory' }).Count
    if ($others) {
        Assert-True 'other shares exist, so the firewall was left on and the row says so' ($rows[1].Status -like 'Skipped*' -and (Smb-Open))
    } else {
        Assert-True 'no shares remain, so file sharing was turned back off' ($rows[1].Status -like 'Applied*' -and -not (Smb-Open))
    }
    Assert-Equal 'the button reads Share this PC again' 'Share this PC' "$($BtnShareThis.Content)"
    Assert-Equal 'and Stop sharing is hidden'           'Collapsed' "$($BtnShareStop.Visibility)"
    Assert-Equal 'nothing of ours is left'              $baseMine @(Get-PC2GoShares).Count

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
} finally {
    try { $timer.Stop() } catch { }
    $cmds = @()
    if ($shareName -and @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $shareName }).Count) { $cmds += "Remove-SmbShare -Name '$shareName' -Force" }
    # the Private/Domain sharing rules go back to how they were, whichever way the run left them
    if ($baseOpen -ne (Smb-Open)) { $cmds += "Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Direction Inbound | Where-Object { '$($_.Profile)' -ne 'Public' } | Set-NetFirewallRule -Enabled $(if ($baseOpen) { 'True' } else { 'False' })" }
    if ($cmds.Count) {
        Write-Host '  cleaning up (last UAC prompt)...' -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -Command `"$($cmds -join '; ')`""
    }
    Remove-Item -LiteralPath $sandbox, $folder -Recurse -Force -ErrorAction SilentlyContinue
    $stay = @()
    if (Test-Path -LiteralPath $folder) { $stay += $folder }
    if ($shareName -and @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $shareName }).Count) { $stay += "share $shareName" }
    if ($stay.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($stay -join '; ')) -ForegroundColor Red } else { Write-Host 'Machine left as found.' -ForegroundColor DarkGray }
}
