<#
.SYNOPSIS
    The Optimize > Tweaks sub-tab against a REAL machine: apply every row, prove each one took,
    apply again, undo every row, prove each one went back. Elevated; run it on a lab VM.

.DESCRIPTION
    The 50 Tweaks rows (45 default + 5 CAUTION) are run through the elevated worker sliced out
    of AppDeploy.ps1, exactly as the GUI queues them: restore point first, the technician's SID
    on every entry so per-user values land in the right hive. Three things are then asserted
    that "Applied" on its own never proves:

      1. APPLY: no row fails. Every row's own Detect probe (the same scriptblock the GUI's
         Detect Applied button runs) answers TRUE, and every literal value Apply-Tweak writes
         reads back from the live registry as written.
      2. APPLY AGAIN: still no failure - a second pass on an already-tweaked machine is safe.
      3. UNDO: no row fails. Every probe answers FALSE again except the rows that document
         themselves as one-way (removed Store apps, OneDrive, the restore point), and every
         value the undo deletes is absent.

    Undo rows that used to fail this on 25H2 - Start Menu, File Explorer Privacy, File Explorer
    Home - reverted only the pre-25H2 registry locations while Detect read the 25H2 ones, so the
    machine stayed tweaked and the row still said "already applied".

    THIS CHANGES THE MACHINE IT RUNS ON and does not put it back: Store apps and OneDrive are
    removed, services and policies are changed, a restore point is created. Run it on a lab VM
    and reset the VM afterwards (lab\README.md). It refuses to run on a machine whose host name
    is not in -AllowHosts unless -IKnowThisWrecksTheMachine is given.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-TweakTab.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string[]]$AllowHosts = @('DESKTOP-854BGVS', 'DESKTOP-RTRU0VA'),   # the lab VMs Home and Pro
    [switch]$IKnowThisWrecksTheMachine,
    [string[]]$Only
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
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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
if (-not $elevated) { throw 'This harness applies every tweak for real and needs an elevated PowerShell.' }
if (($AllowHosts -notcontains $env:COMPUTERNAME) -and -not $IKnowThisWrecksTheMachine) {
    throw "$env:COMPUTERNAME is not a lab VM. This removes Store apps and OneDrive and rewrites policies; pass -IKnowThisWrecksTheMachine to run it here anyway."
}

# ------------------------------------------------------------------ extraction
$src = Get-Content -LiteralPath $ScriptPath -Raw
$lines = $src -split "`r?`n"
$startIdx = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
if (-not $startIdx) { throw 'Could not locate the $workerScript here-string.' }
$endIdx = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $startIdx } | Select-Object -First 1).LineNumber
$workerBody = ($lines[$startIdx..($endIdx - 2)] -join "`r`n")

$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
# Dot-sourced HERE, at script scope, not inside a helper: a function defined by dot-sourcing
# inside another function lives and dies in that function's scope.
foreach ($var in '$script:DebloatPacks', '$script:OemBloatPatterns', '$script:TweakDefs', '$script:TweakTests') {
    $as = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true) |
        Select-Object -First 1
    if (-not $as) { throw "Could not extract $var" }
    . ([scriptblock]::Create($as.Extent.Text))
}
foreach ($name in 'ConvertTo-PSRegPath', 'Get-RegVal', 'Test-RegVal', 'Test-AppxAbsent', 'Test-GameAcIndex', 'Get-SharedTablesSource') {
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "Could not extract function $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# the worker gets its shared tables the way Start-Worker renders them; the NVAPI and installer
# family blocks stay as comments - no Tweaks row needs either
$workerBody = $workerBody.Replace('#__SHAREDTABLES__', (Get-SharedTablesSource))

# the Tweaks sub-tab only: rows with no `tab`, restore point first, exactly as Start-Tweaks orders them
$rows = @($script:TweakDefs | Where-Object { -not $_.tab })
if ($Only.Count) { $rows = @($rows | Where-Object { $Only -contains $_.id }) }
$rows = @($rows | Where-Object { $_.id -eq 'restorepoint' }) + @($rows | Where-Object { $_.id -ne 'restorepoint' })
$ids = @($rows | ForEach-Object { [string]$_.id })

# rows whose undo documents itself as one-way: the probe is EXPECTED to still read applied.
# OneDrive is half-way: its policy IS lifted (Reverted) but the program is not reinstalled, so
# its probe stays true while its state is not Skipped.
$oneWay = @('restorepoint', 'onedriveremove', 'debloatweb', 'debloatdev', 'debloatxbox', 'debloatmsapps', 'debloatmobile', 'debloatutil')
$saysSkipped = @($oneWay | Where-Object { $_ -ne 'onedriveremove' })
# rows whose probe depends on hardware/software the machine may not have - checked against the
# worker's own detail instead of asserted blind
$conditional = @('oembloat')

# what Apply-Tweak and Undo-Tweak write, by AST - the same extraction Test-TweakReality does
$wAst = [System.Management.Automation.Language.Parser]::ParseInput($workerBody, [ref]$null, [ref]$null)
function Get-Literal($e) {
    if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $e.Value }
    if ($e -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $e.Value }
    return $null
}
function Get-StaticWrites([string]$FnName) {
    $fn = $wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FnName }, $true) | Select-Object -First 1
    $sw = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -First 1
    $out = @()
    foreach ($clause in $sw.Clauses) {
        $id = Get-Literal $clause.Item1
        if (-not $id -or $ids -notcontains $id) { continue }
        foreach ($cmd in $clause.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $cmd.GetCommandName()
            if ($name -notin 'Set-Reg', 'Set-RegSoft', 'Remove-RegVal') { continue }
            # a write nested inside an if() is conditional on the machine - skip it, the probe covers the row
            $p = $cmd.Parent; $cond = $false
            while ($p -and $p -ne $clause.Item2) { if ($p -is [System.Management.Automation.Language.IfStatementAst]) { $cond = $true; break }; $p = $p.Parent }
            if ($cond) { continue }
            $a = @($cmd.CommandElements | Select-Object -Skip 1)
            $path = $(if ($a.Count -ge 1) { Get-Literal $a[0] })
            $vname = $(if ($a.Count -ge 2) { Get-Literal $a[1] })
            $want = $(if ($name -eq 'Remove-RegVal') { '<absent>' } elseif ($a.Count -ge 3) { Get-Literal $a[2] })
            if ($null -eq $path -or $null -eq $vname -or $null -eq $want) { continue }
            # Set-RegSoft may be refused by the build - the worker reports which; not asserted here
            if ($name -eq 'Set-RegSoft') { continue }
            $out += [pscustomobject]@{ Tweak = $id; Path = $path; Name = $vname; Want = $want }
        }
    }
    return $out
}
function Read-Reg([string]$Path, [string]$Name) {
    $ps = switch -Regex ($Path) {
        '^HKCU[:\\]' { $Path -replace '^HKCU:?\\', 'HKCU:\' }
        '^HKLM[:\\]' { $Path -replace '^HKLM:?\\', 'HKLM:\' }
        default      { $Path }
    }
    try {
        if (-not (Test-Path -LiteralPath $ps)) { return @{ Present = $false } }
        $item = Get-ItemProperty -LiteralPath $ps -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) { return @{ Present = $false } }
        $v = $item.$Name
        if ($v -is [byte[]]) { $v = ($v | ForEach-Object { $_.ToString('x2') }) -join '' }
        return @{ Present = $true; Value = $v }
    } catch { return @{ Present = $false } }
}
function Test-Writes([string]$Label, [object[]]$Writes) {
    $bad = @()
    foreach ($w in $Writes) {
        $r = Read-Reg $w.Path $w.Name
        $want = $w.Want
        if ($want -is [byte[]]) { $want = ($want | ForEach-Object { $_.ToString('x2') }) -join '' }
        # 0xffffffff parses as [int]-1 in the source and reads back from a DWORD as 4294967295
        $have = $r.Value
        if ($r.Present -and $want -is [int] -and $want -lt 0 -and $have -is [ValueType]) { $have = [int64]([uint32]$have) - 4294967296 }
        $ok = $(if ("$want" -eq '<absent>') { -not $r.Present } else { $r.Present -and ("$have" -eq "$want") })
        if (-not $ok) { $bad += ("{0}: {1}\{2} want={3} have={4}" -f $w.Tweak, $w.Path, $w.Name, $want, $(if ($r.Present) { $r.Value } else { '<absent>' })) }
    }
    Assert-Equal "$Label - every literal value reads back as written ($($Writes.Count) checked)" 0 $bad.Count
    foreach ($b in $bad) { Write-Host "          $b" -ForegroundColor Red }
}
$applyWrites = @(Get-StaticWrites 'Apply-Tweak')
$undoDeletes = @(Get-StaticWrites 'Undo-Tweak' | Where-Object { $_.Want -eq '<absent>' })

# ------------------------------------------------------------------ worker
$work = Join-Path $env:TEMP ("tweaktab-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$workerPath = Join-Path $work 'worker.ps1'
Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding UTF8
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:RunNo = 0
Write-Host ("machine {0}  build {1}  user {2}  sid {3}" -f $env:COMPUTERNAME, [Environment]::OSVersion.Version, $env:USERNAME, $sid) -ForegroundColor DarkGray
Write-Host ("{0} Tweaks rows; {1} literal apply writes and {2} undo deletes extracted" -f $rows.Count, $applyWrites.Count, $undoDeletes.Count) -ForegroundColor DarkGray

function Invoke-Worker([string]$Action) {
    $script:RunNo++
    $dir = Join-Path $work "run$($script:RunNo)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $queue = Join-Path $dir 'queue.jsonl'; $status = Join-Path $dir 'status.jsonl'; $cancel = Join-Path $dir 'cancel.flag'
    foreach ($id in $ids) {
        Add-Content -LiteralPath $queue -Value (@{ id = "tweak-$id"; action = $Action; tweak = $id; userSid = $sid } | ConvertTo-Json -Compress) -Encoding UTF8
    }
    Add-Content -LiteralPath $queue -Value '{"end":true}' -Encoding UTF8
    $t0 = Get-Date
    $proc = Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerPath`"",
        '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`"")
    Write-Host ("  worker run {0} ({1}): exit {2} after {3:N0}s" -f $script:RunNo, $Action, $proc.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray
    $out = @{}
    foreach ($l in @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $l | ConvertFrom-Json } catch { }
        if ($r -and $r.id) { $out[[string]$r.id] = $r }
    }
    return $out
}
function Get-Probe([string]$Id) {
    $t = $script:TweakTests[$Id]
    if (-not $t) { return $null }
    try { return (& $t) } catch { return $null }
}
function Assert-NoFailures([string]$Label, [hashtable]$Res) {
    $failed = @(); $missing = @()
    foreach ($id in $ids) {
        $r = $Res["tweak-$id"]
        if (-not $r) { $missing += $id; continue }
        if ("$($r.state)" -eq 'Failed') { $failed += "$id -> $($r.detail)" }
    }
    Assert-Equal "$Label - every row reported back" 0 $missing.Count
    Assert-Equal "$Label - no row failed" 0 $failed.Count
    foreach ($f in $failed) { Write-Host "          $f" -ForegroundColor Red }
    foreach ($id in $ids) { $r = $Res["tweak-$id"]; if ($r) { Write-Host ("    {0,-16} {1,-8} {2}" -f $id, $r.state, $r.detail) -ForegroundColor DarkGray } }
}

Write-Section '0. Before anything: what Detect says about this machine'
$before = @{}
foreach ($id in $ids) { $before[$id] = Get-Probe $id }
Write-Host ("  {0} of {1} rows already read as applied" -f @($ids | Where-Object { $before[$_] -eq $true }).Count, $ids.Count) -ForegroundColor DarkGray

Write-Section '1. Apply every Tweaks row'
$r1 = Invoke-Worker 'tweak'
Assert-NoFailures 'apply' $r1
$notTrue = @()
foreach ($id in $ids) {
    if ($conditional -contains $id) { continue }
    if ((Get-Probe $id) -ne $true) { $notTrue += $id }
}
Assert-Equal 'every row''s own Detect probe now answers TRUE' 0 $notTrue.Count
foreach ($n in $notTrue) { Write-Host "          $n reads NOT applied after Applied" -ForegroundColor Red }
if ($ids -contains 'oembloat') {
    $d = "$($r1['tweak-oembloat'].detail)"
    # a machine with no OEM updater at all now reports Skipped ("no OEM updater services...") -
    # the probe reads false there, and that is agreement
    Assert-True 'oembloat: probe agrees with what the worker found' ((Get-Probe 'oembloat') -eq ($d -notmatch '^(0 OEM|no OEM)'))
}
Test-Writes 'apply' $applyWrites

Write-Section '2. Apply again on the already-tweaked machine'
$r2 = Invoke-Worker 'tweak'
Assert-NoFailures 'second apply' $r2
$notTrue = @(); foreach ($id in $ids) { if ($conditional -notcontains $id -and (Get-Probe $id) -ne $true) { $notTrue += $id } }
Assert-Equal 'probes still TRUE after the second pass' 0 $notTrue.Count
foreach ($n in $notTrue) { Write-Host "          $n" -ForegroundColor Red }

Write-Section '3. Undo every Tweaks row'
$r3 = Invoke-Worker 'untweak'
Assert-NoFailures 'undo' $r3
$stillTrue = @()
foreach ($id in $ids) {
    if ($oneWay -contains $id -or $conditional -contains $id) { continue }
    if ((Get-Probe $id) -eq $true) { $stillTrue += $id }
}
Assert-Equal 'every reversible row''s probe answers FALSE again' 0 $stillTrue.Count
foreach ($s in $stillTrue) { Write-Host "          $s still reads applied after Undo" -ForegroundColor Red }
Test-Writes 'undo' $undoDeletes
$skippedOneWay = @($saysSkipped | Where-Object { $ids -contains $_ -and "$($r3["tweak-$_"].state)" -eq 'Skipped' }).Count
Assert-Equal 'the one-way rows say so (Skipped) instead of claiming an undo' @($saysSkipped | Where-Object { $ids -contains $_ }).Count $skippedOneWay

Write-Host ''
$colour = $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ("{0} passed, {1} failed   (work files: {2})" -f $script:Pass, $script:Fail, $work) -ForegroundColor $colour
Write-Host 'This machine has been tweaked and untweaked for real - reset the VM before using it for anything else.' -ForegroundColor Yellow
if ($script:Fail) { exit 1 } else { exit 0 }
