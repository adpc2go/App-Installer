<#
.SYNOPSIS
    What every tweak CLAIMS to write, against what the machine actually has. Read-only.

.DESCRIPTION
    "Applied" currently means "the write returned without throwing". That is not the same as
    "the machine changed", and on Windows 11 24H2/25H2 the two have come apart: values that
    worked for years are now ignored, protected, or moved to a policy key. A tweak can report
    Applied, be detected as Applied on the next run, and have changed nothing a person can see -
    because the detection reads back the same value the apply wrote. That is a tautology, not a
    check.

    This asks the machine instead. Every Set-Reg and Remove-RegVal in Apply-Tweak is extracted
    by AST - so it reports what SHIPS, not a second copy that can drift - and each one is read
    back from the live registry as the CURRENT user.

    It writes nothing, changes nothing, and needs no elevation. Run it as the signed-in
    technician, because half the values live in HKCU and an elevated shell may be a different
    profile - which is itself one of the things this can catch.

    Run it twice: once before an Optimize run and once after. A row that says MISMATCH after
    the tool reported Applied is a tweak that did not take, named exactly.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-TweakReality.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-TweakReality.ps1 -Only startclean,taskbarclean
#>
[CmdletBinding()]
param(
    [string]$WorkerPath,
    # Limit to particular tweak ids - useful when chasing one row rather than surveying.
    [string[]]$Only,
    # Show the rows whose arguments are computed at runtime and cannot be read statically.
    [switch]$IncludeDynamic
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Split-Path -Parent $here
if (-not $WorkerPath) { $WorkerPath = Join-Path $repo 'server\AppDeploy.ps1' }
if (-not (Test-Path -LiteralPath $WorkerPath)) { throw "Cannot find $WorkerPath" }

# powershell.exe -File hands every argument over as a plain string, so "-Only a,b,c" arrives as
# ONE element containing the commas rather than three. Left alone, the filter then matches
# nothing at all and the run reports a clean zero - which looks like "no tweaks found" rather
# than "you held it wrong". Splitting here makes -File and -Command behave the same.
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Write-Host ''
Write-Host 'Tweak reality check - what the code writes vs what this machine has' -ForegroundColor Cyan
Write-Host ('-' * 68) -ForegroundColor DarkCyan
Write-Host ("machine : {0}" -f $env:COMPUTERNAME)
Write-Host ("user    : {0}" -f $env:USERNAME)
Write-Host ("sid     : {0}" -f ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("elevated: {0}{1}" -f $elev, $(if ($elev) { '   <- HKCU here may not be the signed-in profile' } else { '' })) `
           -ForegroundColor $(if ($elev) { 'Yellow' } else { 'Gray' })
Write-Host ("build   : {0}" -f [Environment]::OSVersion.Version)
Write-Host ''

# ---------------------------------------------------------------- extract what ships
#
# Apply-Tweak lives INSIDE the $workerScript here-string, so parsing AppDeploy.ps1 as a whole
# sees one enormous string literal and none of its functions. Slice it out by its delimiters
# first - the same idiom Test-AfterInstallList and Test-DirtyCleanup use - then parse that.
$workerSrc = Get-Content -LiteralPath $WorkerPath -Raw
$wLines = $workerSrc -split "`r?`n"
$wStart = ($wLines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
if (-not $wStart) { throw 'Could not locate the $workerScript here-string in AppDeploy.ps1.' }
$wEnd = ($wLines | Select-String -Pattern "^'@$" |
         Where-Object { $_.LineNumber -gt $wStart } | Select-Object -First 1).LineNumber
$workerBody = ($wLines[$wStart..($wEnd - 2)] -join "`r`n")
$ast = [System.Management.Automation.Language.Parser]::ParseInput($workerBody, [ref]$null, [ref]$null)

$applyFn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Apply-Tweak' }, $true) |
    Select-Object -First 1
if (-not $applyFn) { throw 'Could not find Apply-Tweak in the worker.' }

# The outermost switch in Apply-Tweak is the id dispatch; anything nested inside a clause
# belongs to that clause, which is exactly what FindAll on the clause body gives us.
$sw = $applyFn.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -First 1
if (-not $sw) { throw 'Could not find the tweak switch inside Apply-Tweak.' }

function Get-Literal($ExprAst) {
    if ($ExprAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $ExprAst.Value }
    if ($ExprAst -is [System.Management.Automation.Language.ConstantExpressionAst])       { return $ExprAst.Value }
    return $null   # a variable or an expression - not knowable without running it
}

$rows = @()
foreach ($clause in $sw.Clauses) {
    $id = Get-Literal $clause.Item1
    if (-not $id) { continue }
    if ($Only -and ($Only -notcontains $id)) { continue }
    foreach ($cmd in $clause.Item2.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        # Set-RegSoft counts too. It is the same write with a different failure policy, and
        # leaving it out quietly under-reported every row that uses it - taskbarclean showed two
        # values instead of seven, which is exactly the kind of silent gap this harness exists
        # to close.
        if ($name -notin 'Set-Reg', 'Set-RegSoft', 'Remove-RegVal') { continue }
        $a = @($cmd.CommandElements | Select-Object -Skip 1)
        $path  = $(if ($a.Count -ge 1) { Get-Literal $a[0] } else { $null })
        $vname = $(if ($a.Count -ge 2) { Get-Literal $a[1] } else { $null })
        $want  = $(if ($name -eq 'Remove-RegVal') { '<absent>' }
                   elseif ($a.Count -ge 3) { Get-Literal $a[2] } else { $null })
        $rows += [pscustomobject]@{
            Tweak = $id; Op = $name; Path = $path; Value = $vname
            Want = $want
            Dynamic = ($null -eq $path -or $null -eq $vname -or ($name -eq 'Set-Reg' -and $null -eq $want))
        }
    }
}

# ---------------------------------------------------------------- ask the machine
function ConvertTo-PsPath([string]$p) {
    # The worker's Resolve-Reg redirects HKCU through HKEY_USERS\<sid> when a SID travelled
    # with the entry. Here we deliberately read plain HKCU: this process's own profile is the
    # profile the technician is looking at, which is the thing being verified.
    switch -Regex ($p) {
        '^HKCU[:\\]'  { return ($p -replace '^HKCU:?\\', 'HKCU:\') }
        '^HKLM[:\\]'  { return ($p -replace '^HKLM:?\\', 'HKLM:\') }
        '^HKCR[:\\]'  { return ($p -replace '^HKCR:?\\', 'HKCR:\') }
        '^HKU[:\\]'   { return ($p -replace '^HKU:?\\',  'Registry::HKEY_USERS\') }
        default       { return $p }
    }
}

$agree = 0; $mismatch = 0; $skipped = 0
$byTweak = @{}

foreach ($r in $rows) {
    if ($r.Dynamic) {
        $skipped++
        if ($IncludeDynamic) {
            if (-not $byTweak.ContainsKey($r.Tweak)) { $byTweak[$r.Tweak] = @() }
            $byTweak[$r.Tweak] += [pscustomobject]@{ State='DYNAMIC'; Text="$($r.Op) (computed at runtime)" }
        }
        continue
    }
    $ps = ConvertTo-PsPath $r.Path
    $have = $null
    $present = $false
    try {
        if (Test-Path -LiteralPath $ps) {
            $item = Get-ItemProperty -LiteralPath $ps -Name $r.Value -ErrorAction SilentlyContinue
            if ($null -ne $item) { $have = $item.($r.Value); $present = $true }
        }
    } catch { }

    $ok = $(if ($r.Want -eq '<absent>') { -not $present } else { $present -and ("$have" -eq "$($r.Want)") })
    if ($ok) { $agree++ } else { $mismatch++ }

    if (-not $byTweak.ContainsKey($r.Tweak)) { $byTweak[$r.Tweak] = @() }
    $byTweak[$r.Tweak] += [pscustomobject]@{
        State = $(if ($ok) { 'OK' } else { 'MISMATCH' })
        Text  = ("{0}\{1}  want={2} have={3}" -f $r.Path, $r.Value, $r.Want,
                 $(if ($present) { $have } else { '<absent>' }))
    }
}

# ---------------------------------------------------------------- report
foreach ($t in ($byTweak.Keys | Sort-Object)) {
    $lines = $byTweak[$t]
    $bad = @($lines | Where-Object { $_.State -eq 'MISMATCH' }).Count
    $colour = $(if ($bad) { 'Yellow' } else { 'Green' })
    Write-Host ("{0,-18} {1}" -f $t, $(if ($bad) { "$bad of $($lines.Count) NOT set on this machine" } else { "all $($lines.Count) set" })) `
               -ForegroundColor $colour
    foreach ($l in $lines) {
        if ($l.State -eq 'OK') { continue }   # only the interesting ones, or the output is unreadable
        Write-Host ("    {0}  {1}" -f $l.State, $l.Text) -ForegroundColor $(
            switch ($l.State) { 'MISMATCH' { 'Red' } 'DYNAMIC' { 'DarkGray' } default { 'Gray' } })
    }
}

Write-Host ''
Write-Host ("{0} value(s) match, {1} do not, {2} computed at runtime and not checkable statically" -f
            $agree, $mismatch, $skipped) -ForegroundColor $(if ($mismatch) { 'Yellow' } else { 'Green' })
Write-Host ''
Write-Host 'Read this as: BEFORE an Optimize run, MISMATCH is simply "not applied yet".' -ForegroundColor DarkGray
Write-Host 'AFTER a run that reported Applied, every MISMATCH is a tweak that did not take.' -ForegroundColor DarkGray
