<#
.SYNOPSIS
    Creates a real local account through the real Accounts tab and the REAL elevated worker,
    proves it exists on the machine, then deletes it the same way.

.DESCRIPTION
    Test-BackupTab drives the tab unelevated and never creates an account. This is the run that
    answers "the app says the account was created - is it actually on the machine?": the answer
    comes from Get-LocalUser and the ProfileList, not from anything the tool prints.

    One UAC prompt (the tool's own single-worker prompt). Creates 'pc2go-probe' with a password,
    as an Administrator, then deletes it through the account dialog. The profile folder the tool
    deliberately KEEPS is removed by a second elevated command at the end, with its ProfileList
    entry, so the machine is left exactly as found.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ElevatedAccounts.ps1
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
function Wait-For([scriptblock]$Until, [int]$TimeoutMs = 240000) {
    $w = 0; while ($w -lt $TimeoutMs) { if (& $Until) { return $true }; Wait-Dispatcher 250; $w += 250 }
    return [bool](& $Until)
}
function Invoke-Click($b) { $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
function Get-Acct([string]$n) { try { Get-LocalUser -Name $n -ErrorAction Stop } catch { $null } }

$probe = 'pc2go-probe'
$pw    = 'Probe!2026x'
$tag   = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox = Join-Path $env:TEMP "pc2go-elacct-$tag"
$sidAtEnd = ''

try {
    if (Get-Acct $probe) { throw "'$probe' already exists on this machine - remove it first." }
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $server = Join-Path $sandbox 'catalog'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'),
        ([pscustomobject]@{ updated = (Get-Date -Format 'yyyy-MM-dd'); apps = @() } | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding $false))

    Write-Section 'Loading the real GUI - the REAL Start-Worker, no stub'
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $goAt = $src.IndexOf('# ---------- go ----------')
    . ([scriptblock]::Create($src.Substring(0, $goAt))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
    $script:CacheDir   = Join-Path $sandbox 'cache'; New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath  = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath = Join-Path $script:CacheDir 'cancel.flag'
    $script:SkipPath   = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir    = Join-Path $script:CacheDir 'icons'
    $timer.Start()

    Write-Section "1. Create '$probe' through the Accounts tab (approve the UAC prompt)"
    Select-Tab 'Users'
    Invoke-Click $BtnNewAccount
    $TxtNewUser.Text = $probe; $TxtNewFull.Text = 'PC2Go Probe'; $TxtNewPw.Text = $pw
    $ChkNewAdmin.IsChecked = $true
    Invoke-Click $BtnNewUserOk
    Assert-Equal 'the confirm sheet opened' 'Create this account?' ('' + $TxtOverlayTitle.Text)
    Write-Host '  clicking Continue - approve the UAC prompt...' -ForegroundColor Yellow
    Invoke-Click $BtnOverlayOk
    $done = Wait-For { $script:Phase -in 'Done', 'Idle' } 300000
    Assert-True 'the batch settled' $done
    $row = $script:Pending[0]
    Write-Host "  row: $($row.Status) - $($row.StatusDetail)" -ForegroundColor DarkGray
    Assert-True 'the row reports Applied' ($row.Status -like 'Applied*')
    if ("$($Overlay.Visibility)" -eq 'Visible') { Invoke-Click $BtnOverlayOk }

    $u = Get-Acct $probe
    Assert-True  'THE MACHINE has the account (Get-LocalUser)' ($null -ne $u)
    Assert-True  'net user lists it too' ((& "$env:SystemRoot\System32\net.exe" user 2>$null) -match $probe)
    if ($u) {
        $sidAtEnd = '' + $u.SID.Value
        Assert-True 'it is enabled' ([bool]$u.Enabled)
        $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object { '' + $_.SID.Value })
        Assert-True 'it is in Administrators' ($admins -contains $sidAtEnd)
        $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidAtEnd"
        Assert-True 'its profile folder was created' ((Test-Path -LiteralPath $pl) -and (Test-Path -LiteralPath (Get-ItemProperty -LiteralPath $pl).ProfileImagePath))
        Assert-True 'the tab lists it after the batch' (@($script:AccountItems | Where-Object { $_.Name -eq $probe }).Count -eq 1)
    }

    Write-Section "2. Delete '$probe' through the account dialog"
    $item = @($script:AccountItems | Where-Object { $_.Name -eq $probe })[0]
    if ($item) {
        Show-AcctDialog $item
        Invoke-Click $BtnActDelete
        Assert-Equal 'the delete confirm opened' 'Delete this account?' ('' + $TxtOverlayTitle.Text)
        Invoke-Click $BtnOverlayOk
        $done = Wait-For { $script:Phase -in 'Done', 'Idle' } 300000
        Assert-True 'the delete batch settled' $done
        $row = $script:Pending[0]
        Write-Host "  row: $($row.Status) - $($row.StatusDetail)" -ForegroundColor DarkGray
        Assert-True 'the row reports Applied' ($row.Status -like 'Applied*')
        if ("$($Overlay.Visibility)" -eq 'Visible') { Invoke-Click $BtnOverlayOk }
        Assert-True 'THE MACHINE no longer has the account' ($null -eq (Get-Acct $probe))
    }

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
} finally {
    try { $timer.Stop() } catch { }
    # leave the machine as found: the account if the delete did not run, the kept profile folder
    # and its ProfileList entry. Elevated, so this is the second (and last) prompt.
    $left = @()
    if (Get-Acct $probe) { $left += "net user $probe /delete" }
    if ($sidAtEnd) {
        $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidAtEnd"
        $dir = ''
        try { $dir = (Get-ItemProperty -LiteralPath $pl -ErrorAction Stop).ProfileImagePath } catch { }
        if ($dir -and (Test-Path -LiteralPath $dir) -and $dir -like "*\$probe*") { $left += "Remove-Item -LiteralPath '$dir' -Recurse -Force" }
        if (Test-Path -LiteralPath $pl) { $left += "Remove-Item -LiteralPath '$pl' -Recurse -Force" }
    }
    if ($left.Count) {
        Write-Host '  cleaning up (second UAC prompt)...' -ForegroundColor Yellow
        $cmd = ($left -join '; ')
        Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -Command `"$cmd`""
    }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    $stay = @()
    if (Get-Acct $probe) { $stay += "account $probe" }
    if ($sidAtEnd -and (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidAtEnd")) { $stay += 'ProfileList entry' }
    if (Test-Path -LiteralPath "C:\Users\$probe") { $stay += "C:\Users\$probe" }
    if ($stay.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($stay -join '; ')) -ForegroundColor Red } else { Write-Host 'Machine left as found.' -ForegroundColor DarkGray }
}
