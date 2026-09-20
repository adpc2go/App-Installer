<#
.SYNOPSIS
    The account actions no other suite runs, through the real elevated worker, and the account
    dialog's own input boxes. Needs an elevated PowerShell.

.DESCRIPTION
    Test-ElevatedAccounts creates and deletes one account; Test-ElevatedBackup runs the replace
    chain's happy path. This covers the rest on a throwaway account 'pc2go-rail-<tag>':

      1. promote, demote (and that a demoted account is still in Users), reset the password,
         disable, enable - each checked on the machine, not in the tool's output
      2. the refusals on the elevated side: the signed-in account (which the worker cannot see
         for itself - it is shipped as techUser), the account that elevated the tool, a built-in
         account, an account that does not exist
      3. the chain: a step pulled OUT of the batch stops the steps after it, and a copy that
         finished with a caveat (Skipped) stops the disable behind it - so a client is never
         locked out of the account whose data did not fully arrive
      4. the account dialog: its own password and replacement-name boxes, cleared when it
         opens, read by Reset password, and the name box only shown beside Replace

    The account, its profile folder and its ProfileList entry are removed at the end.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-AccountRails.ps1
#>
[CmdletBinding()]
param([string]$ScriptPath, [switch]$KeepArtefacts)
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

$elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'This harness creates and changes a local account and needs an elevated PowerShell.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")

$tag   = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$probe = "pc2go-rail-$tag"
$pw    = "Rail#$tag-9x"
$root  = Join-Path $env:TEMP "pc2go-acct-$tag"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$workerPath = Join-Path $root 'worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$me = [Environment]::UserName
$sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$script:RunNo = 0
$probeSid = ''
$timer = $null

function Get-Acct([string]$Name) { try { Get-LocalUser -Name $Name -ErrorAction Stop } catch { $null } }
function Test-InGroup([string]$GroupSid, [string]$Name) {
    $u = Get-Acct $Name; if (-not $u) { return $false }
    return (@(Get-LocalGroupMember -SID $GroupSid -ErrorAction SilentlyContinue | ForEach-Object { '' + $_.SID.Value }) -contains ('' + $u.SID.Value))
}
function Invoke-Worker([object[]]$Entries, [string[]]$Skip = @()) {
    $script:RunNo++
    $dir = Join-Path $root "run$($script:RunNo)"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $q = Join-Path $dir 'queue.jsonl'; $s = Join-Path $dir 'status.jsonl'; $sk = Join-Path $dir 'skip.txt'
    foreach ($e in $Entries) { Add-Content -LiteralPath $q -Value ($e | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8 }
    Add-Content -LiteralPath $q -Value '{"end":true}' -Encoding UTF8
    foreach ($x in $Skip) { Add-Content -LiteralPath $sk -Value $x -Encoding UTF8 }
    $t0 = Get-Date
    Start-Process -FilePath $psExe -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$q`"", '-StatusFile', "`"$s`"", '-CancelFile', "`"$(Join-Path $dir 'cancel.flag')`"", '-SkipFile', "`"$sk`"") | Out-Null
    Write-Host ("  worker run {0}: {1:N1}s" -f $script:RunNo, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $s -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id -and $r.state -in 'Applied', 'Failed', 'Skipped', 'Removed', 'Cancelled') { $out[[string]$r.id] = $r }
    }
    return $out
}

try {
    # ================================================================== 1. the actions
    Write-Section "1. Create '$probe' as a standard user, then promote, demote, reset, disable, enable"
    $r = Invoke-Worker @(@{ id = 'new'; action = 'newuser'; username = $probe; fullname = ''; password = $pw; admin = $false; techUser = $me; userSid = $sid })
    Assert-Equal 'created'                                         'Applied' $r['new'].state
    $u = Get-Acct $probe
    Assert-True  'the machine has it'                              ($null -ne $u)
    if (-not $u) { throw "the probe account was not created: $($r['new'].detail)" }
    $probeSid = '' + $u.SID.Value
    Assert-True  'in Users, not Administrators'                    ((Test-InGroup 'S-1-5-32-545' $probe) -and -not (Test-InGroup 'S-1-5-32-544' $probe))

    $r = Invoke-Worker @(
        @{ id = 'up';   action = 'setadmin';    username = $probe; admin = $true;  techUser = $me },
        @{ id = 'down'; action = 'setadmin';    username = $probe; admin = $false; techUser = $me },
        @{ id = 'pw';   action = 'setpassword'; username = $probe; password = "$pw-2"; techUser = $me },
        @{ id = 'off';  action = 'toggleacct';  username = $probe; enable = $false; techUser = $me }
    )
    Assert-Equal 'promote is Applied'                              'Applied' $r['up'].state
    Assert-Equal 'demote is Applied'                               'Applied' $r['down'].state
    Assert-True  'after the demote it is NOT an Administrator'    (-not (Test-InGroup 'S-1-5-32-544' $probe))
    Assert-True  'and still in Users (it keeps its sign-in tile)' (Test-InGroup 'S-1-5-32-545' $probe)
    Assert-Equal 'password reset is Applied'                       'Applied' $r['pw'].state
    Assert-True  'the machine shows the password was just set'     ($(try { ((Get-Date) - (Get-Acct $probe).PasswordLastSet).TotalMinutes -lt 5 } catch { $false }))
    Assert-Equal 'disable is Applied'                              'Applied' $r['off'].state
    Assert-Equal 'the machine shows it disabled'                   $false ([bool](Get-Acct $probe).Enabled)
    $r = Invoke-Worker @(@{ id = 'on'; action = 'toggleacct'; username = $probe; enable = $true; techUser = $me })
    Assert-Equal 'enable is Applied'                               'Applied' $r['on'].state
    Assert-Equal 'and it is enabled again'                         $true ([bool](Get-Acct $probe).Enabled)

    # ================================================================== 2. refusals
    Write-Section '2. Refusals on the elevated side'
    $builtin = ''
    try { $builtin = ((New-Object Security.Principal.SecurityIdentifier (($sid -replace '-\d+$', '') + '-500')).Translate([Security.Principal.NTAccount]).Value -replace '^.*\\', '') } catch { $builtin = 'Administrator' }
    $r = Invoke-Worker @(
        @{ id = 'self';    action = 'toggleacct';    username = $probe; enable = $false; techUser = $probe },
        @{ id = 'elev';    action = 'deleteaccount'; username = $me; techUser = '' },
        @{ id = 'builtin'; action = 'setadmin';      username = $builtin; admin = $false; techUser = $me },
        @{ id = 'ghost';   action = 'deleteaccount'; username = "nope-$tag"; techUser = $me }
    )
    Assert-True  'the signed-in account (techUser) cannot be disabled'      ($r['self'].state -eq 'Failed' -and $r['self'].detail -like '*signed-in account*')
    Assert-True  'the account that elevated the tool cannot be deleted'    ($r['elev'].state -eq 'Failed' -and $r['elev'].detail -like '*elevated this tool*')
    Assert-True  'the built-in Administrator cannot be demoted'            ($r['builtin'].state -eq 'Failed' -and $r['builtin'].detail -like '*built-in*')
    Assert-True  'an account that does not exist is named as such'        ($r['ghost'].state -eq 'Failed' -and $r['ghost'].detail -like '*no local account*')
    Assert-True  'the probe survived all of it, enabled'                   ([bool](Get-Acct $probe).Enabled)

    # ================================================================== 3. the chain
    Write-Section '3. The chain stops at a step that was pulled out, and at a copy with a caveat'
    $r = Invoke-Worker @(
        @{ id = 'c1'; action = 'setpassword'; username = $probe; password = "$pw-3"; chain = $true; techUser = $me },
        @{ id = 'c2'; action = 'migrate'; src = $env:USERPROFILE; dstUser = $probe; dstPath = "C:\Users\$probe"; items = @('Links'); chain = $true; techUser = $me },
        @{ id = 'c3'; action = 'toggleacct'; username = $probe; enable = $false; chain = $true; techUser = $me }
    ) @('c2')
    Assert-Equal 'step 1 ran'                                       'Applied' $r['c1'].state
    Assert-Equal 'step 2 was pulled out'                            'Removed' $r['c2'].state
    Assert-Equal 'so step 3 did not run'                            'Skipped' $r['c3'].state
    Assert-True  'and the account is still enabled'                 ([bool](Get-Acct $probe).Enabled)

    $profDir = ''
    try { $profDir = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$probeSid" -ErrorAction Stop).ProfileImagePath } catch { }
    if ($profDir -and (Test-Path -LiteralPath $profDir)) {
        # 'Public' between two profiles is skipped with a note, which makes the copy Skipped -
        # exactly the "done, with a caveat" verdict that must stop the disable behind it
        $r = Invoke-Worker @(
            @{ id = 'd1'; action = 'migrate'; src = $env:USERPROFILE; dstUser = $probe; dstPath = $profDir; items = @('Public'); chain = $true; techUser = $me; userSid = $sid },
            @{ id = 'd2'; action = 'toggleacct'; username = $probe; enable = $false; chain = $true; techUser = $me }
        )
        Assert-Equal 'a copy with a caveat reports Skipped'          'Skipped' $r['d1'].state
        Assert-Equal 'and the disable behind it does not run'        'Skipped' $r['d2'].state
        Assert-True  'the account is still enabled'                  ([bool](Get-Acct $probe).Enabled)
    } else {
        Write-Host '  (chain-with-caveat skipped: the probe has no profile folder)' -ForegroundColor Yellow
    }

    # ================================================================== 4. the dialog
    Write-Section '4. The account dialog has its own boxes, and Reset password reads them'
    $server = Join-Path $root 'server'; New-Item -ItemType Directory -Force -Path $server | Out-Null
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ([pscustomobject]@{ updated = '2026-01-01'; apps = @([pscustomobject]@{
        id = 'x'; name = 'X'; category = 'Apps'; url = 'https://example.invalid/x.exe'; sha256 = ('a' * 64); sizeBytes = 1; silentArgs = ''; verifyPaths = @("$root\never.exe") }) } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $goAt = $src.IndexOf('# ---------- go ----------')
    . ([scriptblock]::Create($src.Substring(0, $goAt))) -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate
    $script:CacheDir = Join-Path $root 'cache'; New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath = Join-Path $script:CacheDir 'queue.jsonl'; $script:StatusPath = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath = Join-Path $script:CacheDir 'worker.ps1'; $script:CancelPath = Join-Path $script:CacheDir 'cancel.flag'; $script:SkipPath = Join-Path $script:CacheDir 'skip.txt'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'; $script:IconDir = Join-Path $script:CacheDir 'icons'
    Assert-True 'the dialog has a password box and a replacement-name box' ($null -ne $TxtActPw -and $null -ne $TxtActNewName -and $null -ne $RowActNewName)
    Select-Tab 'Users'
    $rowP = @($script:AccountItems | Where-Object { $_.Name -eq $probe })[0]
    Assert-True 'the Accounts tab lists the probe' ($null -ne $rowP)
    if ($rowP) {
        $TxtActPw.Text = 'leftover'; $TxtActNewName.Text = 'leftover'
        Show-AcctDialog $rowP
        Assert-Equal 'opening the dialog clears the password box'      '' $TxtActPw.Text
        Assert-Equal 'and the replacement-name box'                    '' $TxtActNewName.Text
        Assert-Equal 'a local account shows no replacement-name row'   'Collapsed' "$($RowActNewName.Visibility)"
        Assert-Equal 'the password hint shows while the box is empty'  'Visible' "$($HintActPw.Visibility)"
        $TxtActPw.Text = "Dialog#$tag"
        Assert-Equal 'and hides once something is typed'               'Collapsed' "$($HintActPw.Visibility)"
        $BtnActPw.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Assert-Equal 'Reset password opens its confirm'                'Set this password?' ('' + $TxtOverlayTitle.Text)
        Write-Host ("  confirm> " + (('' + $TxtOverlayMsg.Text) -replace '\s+', ' ')) -ForegroundColor DarkGray
        Assert-True  'showing the password typed in THIS dialog'      ($TxtOverlayMsg.Text -like "*Dialog#$tag*")
        $BtnOverlayCancel.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Assert-Equal 'cancelled: no batch started'                     $true ($script:Phase -ne 'Install')
        # the button closed the dialog before reading the box, so the box must survive the close
        # and be cleared on the NEXT open instead
        Assert-Equal 'the dialog was closed by the button'              'Collapsed' "$($AcctOverlay.Visibility)"
        Show-AcctDialog $rowP
        Assert-Equal 'and the next open starts with an empty box'      '' $TxtActPw.Text
        Hide-AcctDialog
    }

    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    try { if ($timer) { $timer.Stop() } } catch { }
    try { if ($script:HaveMutex -and $script:AppMutex) { $script:AppMutex.ReleaseMutex() } } catch { }
    if ($KeepArtefacts) { Write-Host "Artefacts kept: $root, account $probe" -ForegroundColor Yellow }
    else {
        if (Get-Acct $probe) { try { Remove-LocalUser -Name $probe -ErrorAction Stop } catch { & "$env:SystemRoot\System32\net.exe" user $probe /delete 2>&1 | Out-Null } }
        if ($probeSid) {
            $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$probeSid"
            $dir = ''; try { $dir = (Get-ItemProperty -LiteralPath $pl -ErrorAction Stop).ProfileImagePath } catch { }
            if ($dir -and (Test-Path -LiteralPath $dir) -and $dir -like "*\$probe*") {
                # rmdir, not Remove-Item: a profile holds deny-ACL junctions (AppData\Local\Application
                # Data) that Remove-Item trips over, and rmdir removes a junction without following it
                & "$env:SystemRoot\System32\cmd.exe" /c rmdir /s /q "$dir" 2>&1 | Out-Null
                if (Test-Path -LiteralPath $dir) {
                    & "$env:SystemRoot\System32\takeown.exe" /F $dir /R /D Y 2>&1 | Out-Null
                    & "$env:SystemRoot\System32\icacls.exe" $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
                    & "$env:SystemRoot\System32\cmd.exe" /c rmdir /s /q "$dir" 2>&1 | Out-Null
                }
            }
            if (Test-Path -LiteralPath $pl) { Remove-Item -LiteralPath $pl -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        $stay = @()
        if (Get-Acct $probe) { $stay += "account $probe" }
        if ($probeSid -and (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$probeSid")) { $stay += 'ProfileList entry' }
        if (Test-Path -LiteralPath "C:\Users\$probe") { $stay += "C:\Users\$probe" }
        if ($stay.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($stay -join '; ')) -ForegroundColor Red } else { Write-Host 'Machine left as found.' -ForegroundColor DarkGray }
    }
}
