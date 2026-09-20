<#
.SYNOPSIS
    The Firewall tab against the REAL Windows firewall: block, unblock, block again, and every
    refusal rail. Needs an elevated PowerShell.

.DESCRIPTION
    Nothing here is simulated. The elevated worker is sliced out of AppDeploy.ps1 verbatim and
    run on a queue, exactly as the GUI runs it; the GUI-side scan functions are lifted through
    the parser. What is asserted is what a technician would check in wf.msc afterwards:

      1. BLOCK a throwaway program folder (three .exe files, one .dll): one outbound Block rule
         per exe and none for the dll - named, grouped, enabled, on every profile, with the undo
         command in the Description. The GUI scan then sees the folder as blocked.
      2. BLOCK AGAIN: nothing added, every exe reported already blocked, still three rules.
      3. UNBLOCK: three removed, none left, internet back.
      4. BLOCK AGAIN after that: the same three rule NAMES as the first time - same files, same
         names, whichever week it is - so the description's Remove-NetFirewallRule line stays true.
      5. The states the code used to get wrong: a rule of ours switched OFF is switched back on
         rather than counted as "already blocked"; a rule written by netsh with no group counts
         as foreign; a rule whose program is written as %PUBLIC%\... matches the folder anyway.
      6. Refusals: a system root, the drive root, a folder that is gone, a folder with no exe,
         an unblock with nothing to remove, and removal-by-name that must refuse an inbound
         Allow rule and a rule outside the stated folder.
      7. The EFFECT, not the bookkeeping: a copy of curl.exe in the folder reaches the web,
         is blocked and cannot, is unblocked and can again.

    Everything is created under C:\Users\Public and removed in the finally block, which reports
    anything that survived. Rules are matched by their PROGRAM PATH inside the sandbox, so a
    rule belonging to anything else on the machine is never touched.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-FirewallTab.ps1
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

# ------------------------------------------------------------------ extraction
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
if (-not $startIdx) { throw 'Could not locate the $workerScript here-string.' }
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")

$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($name in 'Invoke-OffUi', 'Get-FirewallBlockMap', 'Get-RulesUnder', 'Get-VendorFolder', 'Test-FwRootAllowed', 'Get-ForeignRuleCount') {
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "Could not extract function $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
foreach ($var in '$script:FwProtectedRoots', '$script:FwGroup') {
    $as = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true) |
        Select-Object -First 1
    if (-not $as) { throw "Could not extract $var" }
    . ([scriptblock]::Create($as.Extent.Text))
}
$script:LogLines = @()
function Add-Log([string]$Text) { $script:LogLines += $Text }

# ------------------------------------------------------------------ sandbox
$tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path 'C:\Users\Public' "FwTest-$tag"
$app = Join-Path $sandbox 'App'
$vendor = Join-Path $sandbox 'Vendor'
$empty = Join-Path $sandbox 'Empty'
foreach ($d in @($app, (Join-Path $app 'bin'), $vendor, $empty, (Join-Path $sandbox 'work'))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
foreach ($f in @('one.exe', 'bin\two.exe', 'three.exe', 'notes.dll')) { Set-Content -LiteralPath (Join-Path $app $f) -Value 'x' -Encoding ASCII }
Set-Content -LiteralPath (Join-Path $vendor 'shared.exe') -Value 'x' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $empty 'readme.txt') -Value 'x' -Encoding ASCII
$workerPath = Join-Path $sandbox 'work\worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$group = $script:FwGroup
$appName = 'Fw Probe App'
$script:RunNo = 0
Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray
Write-Host ("Extracted worker ({0} lines); group '{1}'" -f ($endIdx - $startIdx - 1), $group) -ForegroundColor DarkGray

# one worker run per call; returns id -> the LAST record the worker wrote for it
function Invoke-Worker([object[]]$Entries) {
    $script:RunNo++
    $dir = Join-Path $sandbox "work\run$($script:RunNo)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $queue = Join-Path $dir 'queue.jsonl'; $status = Join-Path $dir 'status.jsonl'; $cancel = Join-Path $dir 'cancel.flag'
    foreach ($e in $Entries) { Add-Content -LiteralPath $queue -Value ($e | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8 }
    Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker run {0}: exit {1} after {2:N1}s" -f $script:RunNo, $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id) { $out[[string]$r.id] = $r }
    }
    return $out
}
function New-BlockEntry([string]$Id, [string]$Root) {
    @{ id = $Id; action = 'fwblock'; app = $appName; publisher = 'Harness Tests'; build = 'test'; root = $Root; group = $group }
}
# every firewall rule whose program sits inside the sandbox, with its path expanded the way
# the tool now expands it - the ONLY rules this harness ever inspects or deletes
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
            $out += [pscustomobject]@{ Name = ('' + $r.Name); DisplayName = ('' + $r.DisplayName); Group = ('' + $r.Group)
                                       Enabled = ("$($r.Enabled)" -eq 'True'); Direction = "$($r.Direction)"; Action = "$($r.Action)"
                                       Profile = "$($r.Profile)"; Description = ('' + $r.Description); Program = $p }
        }
    }
    return $out
}
function Add-NetshRule([string]$DisplayName, [string]$Program) {
    & "$env:SystemRoot\System32\netsh.exe" advfirewall firewall add rule name="$DisplayName" dir=out action=block program="$Program" enable=yes | Out-Null
    # netsh gives its rules a GUID Name; the harness needs that to address them the way the GUI does
    $r = @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop) | Select-Object -First 1
    if (-not $r) { throw "netsh did not create '$DisplayName'" }
    return ('' + $r.Name)
}

try {
    Write-Section '1. Block: one rule per executable, none for the dll'
    $r1 = Invoke-Worker @((New-BlockEntry 'b1' $app))
    Assert-Equal 'the worker reports Applied'                 'Applied' $r1['b1'].state
    Assert-True  'and counts 3 added, 0 already blocked'      ($r1['b1'].detail -like '3 rule(s) added, 0 already blocked*')
    $rules = @(Get-SandboxRules)
    Assert-Equal 'exactly 3 rules exist for the folder'       3 $rules.Count
    Assert-Equal 'none of them is for notes.dll'              0 @($rules | Where-Object { $_.Program -like '*.dll' }).Count
    Assert-Equal 'the one in bin\ was found (recursive)'      1 @($rules | Where-Object { $_.Program -eq (Join-Path $app 'bin\two.exe') }).Count
    Assert-Equal 'every rule is in the tool''s group'         3 @($rules | Where-Object { $_.Group -eq $group }).Count
    Assert-Equal 'every rule is outbound'                     3 @($rules | Where-Object { $_.Direction -eq 'Outbound' }).Count
    Assert-Equal 'every rule blocks'                          3 @($rules | Where-Object { $_.Action -eq 'Block' }).Count
    Assert-Equal 'every rule is enabled'                      3 @($rules | Where-Object { $_.Enabled }).Count
    Assert-Equal 'every rule applies to every profile'        3 @($rules | Where-Object { $_.Profile -eq 'Any' }).Count
    Assert-Equal 'names are deterministic Block-<hash>'        3 @($rules | Where-Object { $_.Name -match '^Block-[0-9A-F]{12}$' }).Count
    $one = @($rules | Where-Object { $_.Program -eq (Join-Path $app 'one.exe') }) | Select-Object -First 1
    Assert-Equal 'display name reads Blocked - app - exe'      "Blocked - $appName - one.exe" $one.DisplayName
    Assert-True  'no branding anywhere in the rule'            (($one.DisplayName + $one.Group + $one.Name + $one.Description) -notmatch 'PC2Go')
    Assert-True  'the description names the executable'      ($one.Description -like "*Executable: $(Join-Path $app 'one.exe')*")
    Assert-True  'and carries the undo command'              ($one.Description -like "*Remove-NetFirewallRule -Group `"$group`"*")
    $namesA = @($rules | ForEach-Object { $_.Name } | Sort-Object)

    $map = Get-FirewallBlockMap
    $c = Get-RulesUnder $map $app
    Assert-Equal 'the GUI scan sees 3 live rules under the folder' 3 $c.On
    Assert-Equal 'and none switched off'                            0 $c.Off
    Assert-True  'the folder is one the GUI would offer to block'   (Test-FwRootAllowed $app)
    Assert-Equal 'nothing foreign among them'                       0 (Get-ForeignRuleCount @([pscustomobject]@{ RegKey = ''; UnArgs = $app; CleanTokens = @() }))

    Write-Section '2. Block again: nothing added, nothing duplicated'
    $r2 = Invoke-Worker @((New-BlockEntry 'b2' $app))
    Assert-Equal 'the repeat is reported Skipped (amber)'         'Skipped' $r2['b2'].state
    Assert-True  'with 0 added and 3 already blocked'             ($r2['b2'].detail -like '0 rule(s) added, 3 already blocked*')
    Assert-Equal 'still exactly 3 rules'                          3 @(Get-SandboxRules).Count

    Write-Section '3. Unblock: every rule gone'
    $r3 = Invoke-Worker @(@{ id = 'u1'; action = 'fwunblock'; app = $appName; root = $app; group = $group })
    Assert-Equal 'the worker reports Applied'                     'Applied' $r3['u1'].state
    Assert-True  'and counts 3 removed'                           ($r3['u1'].detail -like '3 rule(s) removed*')
    Assert-True  'none of them was foreign'                       ($r3['u1'].detail -notlike '*other than this tool*')
    Assert-Equal 'no rule is left for the folder'                 0 @(Get-SandboxRules).Count
    Assert-Equal 'the GUI scan agrees'                            0 (Get-RulesUnder (Get-FirewallBlockMap) $app).On

    Write-Section '4. Block again: same files, same names'
    $r4 = Invoke-Worker @((New-BlockEntry 'b3' $app))
    Assert-Equal 'the worker reports Applied'                     'Applied' $r4['b3'].state
    Assert-True  'and counts 3 added again'                       ($r4['b3'].detail -like '3 rule(s) added, 0 already blocked*')
    $namesB = @(Get-SandboxRules | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Equal 'the three rule names are identical to run 1'    ($namesA -join ',') ($namesB -join ',')

    Write-Section '5. Switched-off, foreign and %ENV%-form rules'
    $oneName = @(Get-SandboxRules | Where-Object { $_.Program -eq (Join-Path $app 'one.exe') })[0].Name
    Set-NetFirewallRule -Name $oneName -Enabled False -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $app 'four.exe') -Value 'x' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $app 'five.exe') -Value 'x' -Encoding ASCII
    $foreignName = Add-NetshRule "FwTest-Foreign-$tag" (Join-Path $app 'four.exe')
    $envName = Add-NetshRule "FwTest-Env-$tag" ('%PUBLIC%\' + "FwTest-$tag" + '\App\five.exe')
    $map = Get-FirewallBlockMap
    $c = Get-RulesUnder $map $app
    Assert-Equal 'the GUI scan: 4 live rules (2 ours, netsh, %ENV%)' 4 $c.On
    Assert-Equal 'and 1 switched off'                                 1 $c.Off
    Assert-True  'the %PUBLIC% rule is keyed by its expanded path'    ($map.ContainsKey((Join-Path $app 'five.exe').ToLower()))
    Assert-Equal '2 of them count as foreign (no group)'              2 (Get-ForeignRuleCount @([pscustomobject]@{ RegKey = ''; UnArgs = $app; CleanTokens = @() }))
    $r5 = Invoke-Worker @((New-BlockEntry 'b4' $app))
    Assert-Equal 'block on top of that is Applied, not Skipped'       'Applied' $r5['b4'].state
    Assert-True  '0 added, 4 already blocked, 1 switched back on'     ($r5['b4'].detail -like '0 rule(s) added, 4 already blocked, 1 switched back on*')
    $rules = @(Get-SandboxRules)
    Assert-Equal 'five exes, five rules - no duplicate for the foreign ones' 5 $rules.Count
    Assert-Equal 'and every one of them is enabled again'             5 @($rules | Where-Object { $_.Enabled }).Count
    $r6 = Invoke-Worker @(@{ id = 'u2'; action = 'fwunblock'; app = $appName; root = $app; group = $group })
    Assert-True  'unblock removes all 5'                              ($r6['u2'].detail -like '5 rule(s) removed*')
    Assert-True  'and says 2 were not the tool''s own'                ($r6['u2'].detail -like '*(2 of them created by something other than this tool)*')
    Assert-Equal 'nothing left for the folder'                        0 @(Get-SandboxRules).Count
    Assert-Equal 'the netsh rules went with it'                       0 @(Get-NetFirewallRule -Name $foreignName, $envName -ErrorAction SilentlyContinue).Count

    Write-Section '6. Refusals - what the worker must NOT do'
    $strayName = Add-NetshRule "FwTest-Stray-$tag" (Join-Path $vendor 'shared.exe')
    $stray2Name = Add-NetshRule "FwTest-Stray2-$tag" (Join-Path $vendor 'shared.exe')
    New-NetFirewallRule -Name "FwTest-Allow-$tag" -DisplayName "FwTest-Allow-$tag" -Direction Inbound -Action Allow `
                        -Program (Join-Path $app 'one.exe') -ErrorAction Stop | Out-Null
    $r7 = Invoke-Worker @(
        (New-BlockEntry 'pf' $env:ProgramFiles),
        (New-BlockEntry 'drive' 'C:\'),
        (New-BlockEntry 'gone' (Join-Path $sandbox 'Missing')),
        (New-BlockEntry 'noexe' $empty),
        @{ id = 'unone'; action = 'fwunblock'; app = $appName; root = $app; group = $group },
        @{ id = 'byname'; action = 'fwunblockrules'; app = 'Vendor'; rules = @("FwTest-Allow-$tag", $strayName); folder = $vendor; group = $group },
        @{ id = 'outside'; action = 'fwunblockrules'; app = 'Vendor'; rules = @($stray2Name); folder = $app; group = $group },
        @{ id = 'ghost'; action = 'fwunblockrules'; app = 'Vendor'; rules = @('PC2Go-no-such-rule'); folder = $vendor; group = $group })
    Assert-Equal 'Program Files itself is refused'                 'Failed' $r7['pf'].state
    Assert-True  'and the reason says so'                          ($r7['pf'].detail -like 'refused:*')
    Assert-Equal 'the drive root is refused'                       'Failed' $r7['drive'].state
    Assert-Equal 'a folder that is gone fails'                     'Failed' $r7['gone'].state
    Assert-True  'naming the folder'                               ($r7['gone'].detail -like '*no longer exists*')
    Assert-Equal 'a folder with no exe is Skipped'                 'Skipped' $r7['noexe'].state
    Assert-Equal 'unblocking a folder with no rules is Skipped'    'Skipped' $r7['unone'].state
    Assert-True  'and says nothing pointed at it'                  ($r7['unone'].detail -like '*no block rules pointed*')
    Assert-Equal 'by-name: the stray is removed, the Allow refused' 'Applied' $r7['byname'].state
    Assert-True  'detail: 1 removed'                               ($r7['byname'].detail -like '1 rule(s) removed*')
    Assert-True  'detail: 1 refused - not an outbound block rule'  ($r7['byname'].detail -like '*1 refused - not an outbound block rule*')
    Assert-Equal 'the inbound Allow rule survived'                 1 @(Get-NetFirewallRule -Name "FwTest-Allow-$tag" -ErrorAction SilentlyContinue).Count
    Assert-Equal 'the stray rule is gone'                          0 @(Get-NetFirewallRule -Name $strayName -ErrorAction SilentlyContinue).Count
    Assert-Equal 'by-name outside the stated folder is Failed'     'Failed' $r7['outside'].state
    Assert-True  'and says outside'                                ($r7['outside'].detail -like "*refused - outside $app*")
    Assert-Equal 'that rule survived too'                          1 @(Get-NetFirewallRule -Name $stray2Name -ErrorAction SilentlyContinue).Count
    Assert-Equal 'a name that does not exist is Skipped'           'Skipped' $r7['ghost'].state
    Assert-True  'as already gone'                                 ($r7['ghost'].detail -like '*1 already gone*')

    Write-Section '7. The internet actually goes away (a real program, a real connection)'
    # Rule counts prove bookkeeping. This proves the effect: a copy of Windows' own curl.exe
    # dropped into the app folder (the firewall matches by PATH, so a copy is its own program)
    # reaches the web, is blocked, cannot, is unblocked, can again. Skipped only when curl is
    # missing or the machine is offline to begin with.
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $probe = Join-Path $app 'probe-net.exe'
    $url = 'http://www.msftconnecttest.com/connecttest.txt'
    # Start-Process, not '&': a blocked curl writes "could not connect" to stderr, and under
    # $ErrorActionPreference = 'Stop' that native stderr line is a terminating error - the
    # harness died on the very result it was there to see. Exit code 0 = reached the web.
    function Test-Web {
        $p = Start-Process -FilePath $probe -ArgumentList @('-s', '-m', '8', '-o', 'NUL', $url) -Wait -PassThru -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    }
    if (Test-Path -LiteralPath $curl) {
        Copy-Item -LiteralPath $curl -Destination $probe -Force
        if (Test-Web) {
            $r8 = Invoke-Worker @((New-BlockEntry 'net1' $app))
            Assert-Equal 'blocked the folder (probe included)'          'Applied' $r8['net1'].state
            Assert-Equal 'the probe can no longer reach the web'        $false (Test-Web)
            $r9 = Invoke-Worker @(@{ id = 'net2'; action = 'fwunblock'; app = $appName; root = $app; group = $group })
            Assert-Equal 'unblocked'                                    'Applied' $r9['net2'].state
            Assert-Equal 'and the probe reaches the web again'          $true (Test-Web)
        } else { Write-Host '  SKIP  no internet from this machine - effect not provable here' -ForegroundColor Yellow }
    } else { Write-Host '  SKIP  curl.exe not present' -ForegroundColor Yellow }

    Write-Section '8. GUI helpers on their own'
    Assert-Equal 'a stray under Common Files collapses to its vendor folder' (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Adobe') `
                 (Get-VendorFolder (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Adobe\OOBE\PDApp\core\PDApp.exe'))
    Assert-Equal 'Windows itself is never a blockable root'     $false (Test-FwRootAllowed (Join-Path $env:SystemRoot 'System32\drivers'))
    Assert-Equal 'Common Files is never a blockable root'       $false (Test-FwRootAllowed (Join-Path $env:ProgramFiles 'Common Files'))
    Assert-Equal 'the map ignores "C:\" as a folder'            0 (Get-RulesUnder (Get-FirewallBlockMap) 'C:\').On
    Assert-Equal 'the scan logged no read error'                0 @($script:LogLines | Where-Object { $_ -like '*could not be read*' }).Count
} finally {
    Write-Section 'Cleanup'
    $left = @()
    foreach ($r in @(Get-SandboxRules)) { try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop } catch { $left += $r.Name } }
    foreach ($r in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "FwTest-*-$tag" -or $_.Name -like "FwTest-*-$tag" })) {
        try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop } catch { $left += ('' + $r.Name) }
    }
    Assert-Equal 'no firewall rule of the sandbox survived'   0 (@(Get-SandboxRules).Count + $left.Count)
    if (-not $KeepArtefacts) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop } catch { Write-Host "  could not remove $sandbox : $($_.Exception.Message)" -ForegroundColor Yellow }
        Assert-Equal 'the sandbox folder is gone'             $false (Test-Path -LiteralPath $sandbox)
    } else { Write-Host "  kept $sandbox" -ForegroundColor Yellow }
}

Write-Host ''
$colour = $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $colour
if ($script:Fail) { exit 1 } else { exit 0 }
