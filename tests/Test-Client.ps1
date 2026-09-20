<#
.SYNOPSIS
    The compiled client (client\PC2Go.Deploy): built, probed, and held to the script's contract.

.DESCRIPTION
    The exe speaks to the same elevated worker, through the same files, with the same words on
    the rows. Every pin here is against the SCRIPT's own definitions lifted by AST - the keys of
    Enqueue-Install's queue entry, the stub Start-Worker runs, Format-Size's output - so the two
    clients cannot drift without this failing. The exe answers through -SelfTest, which runs the
    product's own code with no window, and through a real launch against a loopback edge.

    Needs the .NET SDK (tools\Build-Client.ps1 says where to get it). -NoBuild reuses
    client\dist\PC2Go.Deploy.exe as it is.
#>
[CmdletBinding()]
param([switch]$NoBuild)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:Pass = 0; $script:Fail = 0; $script:Skipped = ''
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}" -f $What) -ForegroundColor Red
           Write-Host ("          expected [{0}]" -f $Expected) -ForegroundColor DarkGray
           Write-Host ("          actual   [{0}]" -f $Actual) -ForegroundColor DarkGray }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) { Write-Host ""; Write-Host "=== $Title" -ForegroundColor Cyan }

$sandbox = Join-Path $env:TEMP ('pc2go-client-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$deployPath = Join-Path $repo 'server\AppDeploy.ps1'
$deployText = Get-Content -LiteralPath $deployPath -Raw
$tokens = $null; $errors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseInput($deployText, [ref]$tokens, [ref]$errors)

function Get-FnAst([string]$Name) {
    $deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
}
function Get-Fn([string]$Name) { (Get-FnAst $Name).Extent.Text }
# the exe's icon cache file for one logo (IconPump.CacheName): the safe id and the first four
# bytes of the SHA-1 of the trimmed, lower-cased URL - computed here too so a cache file on disk
# can be traced back to the catalog entry that made it
function Get-IconCacheName([string]$Id, [string]$Url) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url.Trim().ToLowerInvariant()))
    $safe = ($Id -replace '[^A-Za-z0-9._-]', '_').Trim('.'); if (-not $safe) { $safe = 'unknown' }
    return ('{0}-{1}' -f $safe, (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''))
}
# the keys of the hashtable literal assigned to $<var> inside a function - the script's own list
function Get-HashKeys([string]$Function, [string]$Var) {
    $fn = Get-FnAst $Function
    $asg = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $Var) }, $true) | Select-Object -First 1
    $ht = $asg.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | Select-Object -First 1
    return @($ht.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") })
}

try {
    # ============================================================== 0. build
    Write-Section '0. Build: one exe, no packages, the worker embedded'
    # Read BEFORE the dot-source: Build-Client.ps1's own -NoBuild parameter lands in this scope and
    # shadows ours, and for a while every run of this suite silently tested the exe already on disk.
    $wantBuild = -not $NoBuild
    . (Join-Path $repo 'tools\Build-Client.ps1') -NoBuild
    $exe = Join-Path $repo 'client\dist\PC2Go.Deploy.exe'
    if ($wantBuild) {
        $built = Build-Client -Repo $repo -Configuration 'Release'
        Assert-True 'Build-Client returned the exe and its hash' ($built.Exe -eq $exe -and $built.Hash -match '^[0-9A-F]{64}$')
    }
    Assert-True 'client\dist\PC2Go.Deploy.exe exists' (Test-Path -LiteralPath $exe)
    $csproj = Get-Content -LiteralPath (Join-Path $repo 'client\PC2Go.Deploy\PC2Go.Deploy.csproj') -Raw
    Assert-True 'the project targets .NET Framework 4.8 (in-box on every Windows 10/11)' ($csproj -match '<TargetFramework>net48</TargetFramework>')
    Assert-True 'and pulls no NuGet packages - one file to hash, ship and verify' ($csproj -notmatch 'PackageReference')
    Assert-True 'and embeds the worker under the name the exe reads' ($csproj -match 'EmbeddedResource Include="Resources\\worker\.ps1" LogicalName="worker\.ps1"')
    Assert-True 'dist holds nothing but the exe and its hash' (@(Get-ChildItem (Split-Path $exe) -File | Where-Object { $_.Name -notin 'PC2Go.Deploy.exe', 'PC2Go.Deploy.sha256' }).Count -eq 0)
    Assert-True 'the exe is small (under 2 MB)' ((Get-Item -LiteralPath $exe).Length -lt 2MB)
    Assert-True 'the rendered worker is not versioned' ((Get-Content (Join-Path $repo '.gitignore') -Raw) -match 'client/PC2Go\.Deploy/Resources/worker\.ps1')

    # ============================================================== 1. the worker
    Write-Section '1. The embedded worker is the script''s worker, rendered the way Start-Worker renders it'
    $rendered = Get-RenderedWorker $deployPath
    foreach ($ph in '#__NVAPISOURCE__', '#__SHAREDTABLES__', '#__INSTALLERFAMILY__') {
        Assert-True "placeholder $ph was rendered" (-not $rendered.Contains($ph))
    }
    Assert-True 'the NVAPI source is inlined'            ($rendered -match '\$NvApiSrc = @''' -and $rendered -match 'GoNvApi')
    Assert-True 'the shared tables are inlined'          ($rendered -match '\$script:DebloatPacks = @\{' -and $rendered -match '\$script:OemBloatPatterns = @\(')
    Assert-True 'the installer families are inlined'     ($rendered -match '\$script:InstallerFamilyLabels = @\{' -and $rendered -match 'function Get-InstallerFamily \{' -and $rendered -match 'function Find-InstallerIdentity \{')
    $wsAsg = $deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$workerScript' }, $false) | Select-Object -First 1
    $workerScript = [string]$wsAsg.Right.Expression.Value
    Assert-True 'it begins exactly where the here-string begins' ($rendered.StartsWith($workerScript.Substring(0, 4000)))
    $tailAt = $workerScript.LastIndexOf('#__INSTALLERFAMILY__')
    $tail = $workerScript.Substring($tailAt + '#__INSTALLERFAMILY__'.Length)
    Assert-True 'and ends exactly where the here-string ends' ($rendered.EndsWith($tail))
    Assert-True 'the only differences are the three renderings' (($rendered.Length - $workerScript.Length) -gt 10000)

    # ============================================================== 1b. the reader
    Write-Section '1b. The reader: the Uninstall tab''s reads are the script''s own functions, run in another process'
    $readerSrc = Get-RenderedReader $deployPath
    $pe = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($readerSrc, [ref]$null, [ref]$pe)
    Assert-Equal 'the rendered reader parses' 0 @($pe).Count
    foreach ($fn in 'Get-InstalledPrograms', 'Parse-UninstallString', 'Get-UninstallFamily', 'Get-InstallerFamily', 'Get-StoreApps', 'Resolve-PackageString', 'Scan-Leftovers', 'Get-FolderSize', 'Test-ProtectedPath', 'Get-CleanNameTokens', 'Get-RowId', 'Clean-DisplayName') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    Assert-True 'and the tables those read'          ($readerSrc -match '\$script:ProtectedPaths = @\(' -and $readerSrc -match '\$script:SharedComponentHints = @\(' -and $readerSrc -match '\$script:InstallerFamilyLabels = @\{')
    Assert-True 'and the WipeItem class from the script''s own type block' ($readerSrc.Contains('public class WipeItem {') -and $readerSrc -match 'public string SectionGlyph')
    Assert-True 'and SHLoadIndirectString for Store names' ($readerSrc -match 'SHLoadIndirectString')
    Assert-True 'Update-UI and Invoke-OffUi are stubbed - nothing pumps in another process' ($readerSrc -match '(?m)^function Update-UI \{ \}' -and $readerSrc -match '(?m)^function Invoke-OffUi\(')
    $readerFile = Join-Path $sandbox 'reader.ps1'
    [IO.File]::WriteAllText($readerFile, $readerSrc, (New-Object Text.UTF8Encoding $false))
    $outInst = Join-Path $sandbox 'installed.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op installed -Out `"$outInst`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the installed read exits 0 on this machine' 0 $rp.ExitCode
    # [array] first: ConvertFrom-Json hands a top-level array back as ONE object, and @() around
    # that pipeline is a one-element array holding the array
    $inst = @([array]((Get-Content -LiteralPath $outInst -Raw) | ConvertFrom-Json))
    Assert-True  'and lists this machine''s programs' ($inst.Count -ge 1)
    $first = $inst[0]
    Assert-Equal 'a row carries every field the client reads' 'Args,CleanTokens,Exe,Family,FamilyLabel,IconSources,Id,Installed,Location,Name,Publisher,RegKey,Silent,SizeKB,Version' (($first.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-True  'row ids are the script''s reg-<sha1> form' (@($inst | Where-Object { $_.Id -notmatch '^reg-[0-9a-f]{12}$' }).Count -eq 0)
    Assert-True  'installed dates travel as yyyy-MM-dd or empty' (@($inst | Where-Object { $_.Installed -and $_.Installed -notmatch '^\d{4}-\d{2}-\d{2}$' }).Count -eq 0)
    # the same functions, lifted into THIS process, agree row for row - the reader adds nothing of its own
    . ([scriptblock]::Create($readerSrc.Substring(0, $readerSrc.IndexOf('function Write-Progress-File'))))
    $here = @(Get-InstalledPrograms)
    Assert-Equal 'the reader''s inventory is the script''s inventory (same count)' $here.Count $inst.Count
    Assert-Equal 'and the same names in the same order' (($here | ForEach-Object { Clean-DisplayName $_.Name }) -join '|') (($inst | ForEach-Object { $_.Name }) -join '|')
    # a leftover scan on a synthetic product: the curated folder is listed and pre-ticked, the URL remover offered unticked
    $probeDir = Join-Path $sandbox 'PC2GoScanProbe'
    New-Item -ItemType Directory -Force $probeDir | Out-Null
    Set-Content (Join-Path $probeDir 'a.txt') 'x'
    $req = @{ targets = @(@{ id = 'probe'; name = 'PC2Go Scan Probe'; cleanPaths = @($probeDir); cleanReg = @(); cleanTokens = @('PC2GoScanProbe'); cleanHosts = @()
                             removers = @(@{ name = 'fake tool'; url = 'https://example.invalid/x.exe'; sha256 = 'AB'; args = '-x' }); createdPaths = @(); preExisting = $false }) } | ConvertTo-Json -Depth 6
    $inLeft = Join-Path $sandbox 'left-in.json'; $outLeft = Join-Path $sandbox 'left-out.json'; $prog = Join-Path $sandbox 'left-progress.txt'
    Set-Content -LiteralPath $inLeft -Value $req -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op leftovers -In `"$inLeft`" -Out `"$outLeft`" -Progress `"$prog`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the leftover read exits 0' 0 $rp.ExitCode
    $left = @([array]((Get-Content -LiteralPath $outLeft -Raw) | ConvertFrom-Json))
    $folder = @($left | Where-Object { $_.Type -eq 'file' -and $_.Path -eq $probeDir })
    Assert-Equal 'the curated folder is found once' 1 $folder.Count
    Assert-True  'and pre-ticked, because the product was not here before' ([bool]$folder[0].Del)
    Assert-Equal 'as a FOLDER'  'FOLDER' $folder[0].Kind
    $tool = @($left | Where-Object { $_.Type -eq 'run' })
    Assert-Equal 'the vendor removal tool is offered' 1 $tool.Count
    Assert-True  'unticked - ticking one executes it' (-not [bool]$tool[0].Del)
    Assert-Equal 'with its hash for the worker to verify' 'AB' $tool[0].Sha256
    Assert-True  'progress named the last stage' ((Get-Content -LiteralPath $prog -Raw) -match 'hosts file')
    # the User Accounts tab: the profile list and the local accounts, through the same reader
    foreach ($fn in 'Get-UserProfiles', 'Get-AdminMembers', 'Get-AccountPurpose', 'Get-LocalAccounts') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    Assert-True 'and the migration table for Replace with a local admin' ($readerSrc -match '\$script:MigrateDefs = @\(')
    $outAcct = Join-Path $sandbox 'accounts.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op accounts -Out `"$outAcct`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the accounts read exits 0' 0 $rp.ExitCode
    $acct = (Get-Content -LiteralPath $outAcct -Raw) | ConvertFrom-Json
    Assert-Equal 'it names the signed-in account, which the worker cannot see for itself' ([Environment]::UserName) $acct.me
    Assert-True  'and lists this machine''s local accounts' (@($acct.accounts).Count -ge 1)
    $a0 = @($acct.accounts)[0]
    Assert-Equal 'a row carries every field Load-Users reads' 'Enabled,FullName,IsAdmin,IsBuiltin,Kind,Name,Purpose,Sid' (($a0.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-True  'the built-in Administrator (RID 500) is among them, flagged built-in' (@($acct.accounts | Where-Object { $_.Sid -match '-500$' -and $_.IsBuiltin }).Count -eq 1)
    Assert-True  'at least one enabled Administrator exists' (@($acct.accounts | Where-Object { $_.IsAdmin -and $_.Enabled }).Count -ge 1)
    Assert-True  'profiles carry Sid, Name and a path that exists' (@($acct.profiles | Where-Object { -not ($_.Sid -and $_.Name -and (Test-Path -LiteralPath $_.Path)) }).Count -eq 0)
    $here2 = @(Get-LocalAccounts)
    Assert-Equal 'the reader''s account list is the script''s account list (same names, same order)' (($here2 | ForEach-Object { $_.Name }) -join '|') ((@($acct.accounts) | ForEach-Object { $_.Name }) -join '|')
    $inMig = Join-Path $sandbox 'mig-in.json'; $outMig = Join-Path $sandbox 'mig-out.json'
    Set-Content -LiteralPath $inMig -Value (@{ path = $env:USERPROFILE } | ConvertTo-Json) -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op migrateitems -In `"$inMig`" -Out `"$outMig`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the migrateitems read exits 0' 0 $rp.ExitCode
    $mig = (Get-Content -LiteralPath $outMig -Raw) | ConvertFrom-Json
    Assert-True  'it lists the safe folders that exist under this profile (Desktop is one)' (@($mig.items) -contains 'Desktop')
    Assert-True  'and never a browser profile - those are not in the safe set' (@($mig.items | Where-Object { $_ -like 'AppData*' }).Count -eq 0)
    # the Data Backup tab: the table itself, a manifest, folder sizes and this PC's shares - the script's own reads
    foreach ($fn in 'Get-FolderSize', 'Get-AllShares', 'Get-LocalSubnets', 'Resolve-HostLabel', 'Get-HostShares', 'Find-NetworkHosts') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    $outDefs = Join-Path $sandbox 'defs.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op migratedefs -Out `"$outDefs`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the migratedefs read exits 0' 0 $rp.ExitCode
    $defs = @((Get-Content -LiteralPath $outDefs -Raw | ConvertFrom-Json).items)
    Assert-Equal 'it is the script''s table, row for row' @($script:MigrateDefs).Count $defs.Count
    Assert-True  'Desktop is safe, Public is beside the profiles, Chrome is a deliberate pick' (
        ($defs | Where-Object { $_.id -eq 'Desktop' }).safe -and ($defs | Where-Object { $_.id -eq 'Public' }).abs -and -not ($defs | Where-Object { $_.id -like '*Chrome*' }).safe)
    $bk = Join-Path $sandbox 'PC2Go Backup - probe'
    New-Item -ItemType Directory -Force $bk | Out-Null
    Set-Content -LiteralPath (Join-Path $bk 'pc2go-backup.json') -Value ('{"kind":"profile-backup","sourceProfile":"C:\\Users\\probe","sourceMachine":"PROBE-PC","finishedUtc":"2026-09-04T10:00:00Z","items":[{"rel":"Desktop","source":"C:\\Users\\probe\\Desktop","bytes":12}]}') -Encoding UTF8
    $inMf = Join-Path $sandbox 'mf-in.json'; $outMf = Join-Path $sandbox 'mf-out.json'
    Set-Content -LiteralPath $inMf -Value (@{ path = $bk } | ConvertTo-Json) -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op manifest -In `"$inMf`" -Out `"$outMf`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the manifest read exits 0' 0 $rp.ExitCode
    $mf = (Get-Content -LiteralPath $outMf -Raw) | ConvertFrom-Json
    Assert-True  'a backup this tool wrote is found and read back' ([bool]$mf.found -and $mf.manifest.sourceMachine -eq 'PROBE-PC' -and @($mf.manifest.items).Count -eq 1)
    Set-Content -LiteralPath $inMf -Value (@{ path = $sandbox } | ConvertTo-Json) -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op manifest -In `"$inMf`" -Out `"$outMf`"" -PassThru -Wait -WindowStyle Hidden
    $mf2 = (Get-Content -LiteralPath $outMf -Raw) | ConvertFrom-Json
    Assert-True  'a folder without one says so - never "an empty backup"' (-not [bool]$mf2.found)
    $szDir = Join-Path $sandbox 'sizeprobe'; New-Item -ItemType Directory -Force (Join-Path $szDir 'sub') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $szDir 'a.bin'), (New-Object byte[] 1000)); [IO.File]::WriteAllBytes((Join-Path $szDir 'sub\b.bin'), (New-Object byte[] 2345))
    $inSz = Join-Path $sandbox 'sz-in.json'; $outSz = Join-Path $sandbox 'sz-out.json'
    Set-Content -LiteralPath $inSz -Value (@{ paths = @($szDir, $bk) } | ConvertTo-Json) -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op foldersize -In `"$inSz`" -Out `"$outSz`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the foldersize read exits 0' 0 $rp.ExitCode
    $sz = @([array]((Get-Content -LiteralPath $outSz -Raw | ConvertFrom-Json).sizes))
    Assert-Equal 'it measures the tree to the byte, in order' "3345,$((Get-Item (Join-Path $bk 'pc2go-backup.json')).Length)" ($sz -join ',')
    # the Optimize tab: the table and the detectors, run as the technician
    foreach ($fn in 'Test-RegVal', 'Get-RegVal', 'Test-AppxAbsent') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    Assert-True 'and the tweak tables and detectors' ($readerSrc -match '\$script:TweakDefs = @\(' -and $readerSrc -match '\$script:TweakTests = @\{' -and $readerSrc -match '\$script:DebloatPacks = @\{')
    # the Gaming sub-tab: its two detector helpers, the NVAPI source they compile, and the latency probe - the script's own, lifted verbatim
    foreach ($fn in 'Test-GameAcIndex', 'Test-NvSetting', 'Measure-GamingLatency', 'Get-Percentile') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    Assert-True 'and the NVAPI type source Test-NvSetting compiles on first use' ($readerSrc -match '\$script:NvApiSource = @''' -and $readerSrc -match 'public static class GoNvApi')
    Assert-True 'and a stand-in hint line whose setter writes the progress file, so the probe narrates to the exe' ($readerSrc -match 'TxtTweakHint \| Add-Member ScriptProperty Text')
    $outGp = Join-Path $sandbox 'gameprobe.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op gameprobe -Out `"$outGp`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the gameprobe read exits 0 (about five seconds, read-only)' 0 $rp.ExitCode
    $gp = Get-Content -LiteralPath $outGp -Raw | ConvertFrom-Json
    Assert-True  'and measured this machine: timer granularity above zero, jitter p99 and max at or above zero, DPC read or marked unread' ([double]$gp.TimerP50 -gt 0 -and [double]$gp.PreP99 -ge 0 -and [double]$gp.PreMax -ge [double]$gp.PreP99 -and ([double]$gp.Dpc -ge 0 -or [double]$gp.Dpc -eq -1))
    Assert-True  'the gaming rows are in the table the exe reads, fourteen of them, four CAUTION' (@($script:TweakDefs | Where-Object { $_.tab -eq 'gaming' }).Count -eq 14 -and @($script:TweakDefs | Where-Object { $_.tab -eq 'gaming' -and $_.caution }).Count -eq 4)
    $outTd = Join-Path $sandbox 'tweakdefs.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op tweakdefs -Out `"$outTd`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the tweakdefs read exits 0' 0 $rp.ExitCode
    $td = @((Get-Content -LiteralPath $outTd -Raw | ConvertFrom-Json).items)
    Assert-Equal 'it is the script''s table, row for row' @($script:TweakDefs).Count $td.Count
    Assert-True  'restorepoint is a Tweaks row, windowsold a CAUTION cleanup row, hags a gaming row' (
        (($td | Where-Object { $_.id -eq 'restorepoint' }).tab -eq '') -and (($td | Where-Object { $_.id -eq 'windowsold' }).tab -eq 'cleanup') -and
        (($td | Where-Object { $_.id -eq 'windowsold' }).caution) -and (($td | Where-Object { $_.id -eq 'hags' }).tab -eq 'gaming'))
    $inPr = Join-Path $sandbox 'probe-in.json'; $outPr = Join-Path $sandbox 'probe-out.json'; $progPr = Join-Path $sandbox 'probe-progress.txt'
    Set-Content -LiteralPath $inPr -Value (@{ ids = @('tempfiles', 'mouseaccel', 'no-such-row', 'faststartup') } | ConvertTo-Json) -Encoding UTF8
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op tweakprobe -In `"$inPr`" -Out `"$outPr`" -Progress `"$progPr`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the tweakprobe read exits 0' 0 $rp.ExitCode
    $pr = @((Get-Content -LiteralPath $outPr -Raw | ConvertFrom-Json).results)
    Assert-Equal 'one answer per id, in order' 'tempfiles,mouseaccel,no-such-row,faststartup' (($pr | ForEach-Object { $_.Id }) -join ',')
    Assert-True  'a cleanup row answers null - an action, not a state' ($null -eq $pr[0].Result)
    Assert-True  'an unknown id answers null rather than throwing' ($null -eq $pr[2].Result)
    Assert-True  'a registry probe answers a bool, and agrees with the script''s own detector' (($pr[1].Result -is [bool]) -and ($pr[1].Result -eq [bool](& $script:TweakTests['mouseaccel'])) -and ($pr[3].Result -eq [bool](& $script:TweakTests['faststartup'])))
    Assert-Equal 'progress counted every row' '4|4' ((Get-Content -LiteralPath $progPr -Raw).Trim())
    # the Firewall tab: the rule map and Load-Firewall's helpers, run against this machine's real rule table
    foreach ($fn in 'Get-FirewallBlockMap', 'Resolve-AppRoot', 'Get-RulesUnder', 'Test-FwRootAllowed', 'Get-VendorFolder') {
        Assert-True "it carries $fn, lifted verbatim" ($readerSrc.Contains((Get-Fn $fn)))
    }
    Assert-True 'and the protected roots and the rule group' ($readerSrc -match '\$script:FwProtectedRoots = @\(' -and $readerSrc -match "\`$script:FwGroup = 'Application Block'")
    Assert-True 'Add-Log is stubbed - the rule read logs its own failure, and the script''s Add-Log writes to the window' ($readerSrc -match '(?m)^function Add-Log\(' -and -not $readerSrc.Contains('$script:LogPara'))
    $outFw = Join-Path $sandbox 'firewall.json'; $progFw = Join-Path $sandbox 'firewall-progress.txt'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op firewall -Out `"$outFw`" -Progress `"$progFw`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the firewall read exits 0 on this machine' 0 $rp.ExitCode
    $fw = (Get-Content -LiteralPath $outFw -Raw) | ConvertFrom-Json
    Assert-Equal 'it answers with the totals, the rows and the rule map' 'orphans,rows,rules,ruleTotal' (($fw.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-Equal 'the spinner''s second stage was written' 'Matching against installed programs...' ((Get-Content -LiteralPath $progFw -Raw).Trim())
    $fwRows = @([array]$fw.rows)
    Assert-True  'a row carries every field the client reads' ($fwRows.Count -ge 1 -and (($fwRows[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'IconSources,Id,Name,Off,On,Publisher,Root,RuleNames,Stray')
    Assert-True  'program rows are fw-<sha1>, stray rows fwx-<sha1>' (@($fwRows | Where-Object { ($_.Stray -and $_.Id -notmatch '^fwx-[0-9a-f]{12}$') -or (-not $_.Stray -and $_.Id -notmatch '^fw-[0-9a-f]{12}$') }).Count -eq 0)
    Assert-True  'no program row lives under a root the script refuses to block' (@($fwRows | Where-Object { -not $_.Stray -and -not (Test-FwRootAllowed $_.Root) }).Count -eq 0)
    Assert-True  'a stray row names exactly the rules it counts' (@($fwRows | Where-Object { $_.Stray -and @($_.RuleNames).Count -ne $_.On }).Count -eq 0)
    $hereMap = Get-FirewallBlockMap
    $hereTotal = 0; foreach ($k in $hereMap.Keys) { $hereTotal += @($hereMap[$k]).Count }
    Assert-Equal 'the rule total is the script''s own map, counted in this process' $hereTotal $fw.ruleTotal
    Assert-Equal 'and the flattened map has one entry per rule' $fw.ruleTotal @([array]$fw.rules).Count
    Assert-True  'the blocked rows account for every rule that is not stray' ((@($fwRows | Where-Object { -not $_.Stray } | ForEach-Object { $_.On + $_.Off }) | Measure-Object -Sum).Sum + $fw.orphans -le $fw.ruleTotal)
    $outFm = Join-Path $sandbox 'fwmap.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op fwmap -Out `"$outFm`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the fwmap read exits 0' 0 $rp.ExitCode
    Assert-Equal 'and lists the same rules again' $fw.ruleTotal @([array]((Get-Content -LiteralPath $outFm -Raw | ConvertFrom-Json).rules)).Count
    # the Startup sub-tab: this account's startup entries with Task Manager's verdict, and the worker that flips it
    Assert-True 'it carries Get-StartupEntries and Get-StartupApprovedState, lifted verbatim' ($readerSrc.Contains((Get-Fn 'Get-StartupEntries')) -and $readerSrc.Contains((Get-Fn 'Get-StartupApprovedState')))
    $outSu = Join-Path $sandbox 'startup.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op startupapps -Out `"$outSu`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the startupapps read exits 0' 0 $rp.ExitCode
    $su = @([array]((Get-Content -LiteralPath $outSu -Raw | ConvertFrom-Json).items))
    $hereSu = @(Get-StartupEntries)
    Assert-Equal 'it lists this account''s startup entries - the same count the script''s own function finds in this process' $hereSu.Count $su.Count
    Assert-True  'a row carries Name, Command, Location, Enabled and the Exe behind the command' ($su.Count -eq 0 -or (($su[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Command,Enabled,Exe,Location,Name')
    Assert-True  'every Exe is empty or a file on this disk - the icon source, never a guess' (@($su | Where-Object { $_.Exe -and -not (Test-Path -LiteralPath $_.Exe -PathType Leaf) }).Count -eq 0)
    # Resolve-StartupExe, the function behind that field, on the command shapes the Run keys hold
    $np = Join-Path $env:SystemRoot 'System32\notepad.exe'
    Assert-Equal 'Resolve-StartupExe: a quoted path with arguments is the path' $np (Resolve-StartupExe ('"' + $np + '" /A'))
    Assert-Equal 'an unquoted one too' $np (Resolve-StartupExe ($np + ' /A'))
    Assert-Equal '%variables% are expanded' $np (Resolve-StartupExe '%SystemRoot%\System32\notepad.exe')
    $spaced = Join-Path $sandbox 'Program Files Test'; New-Item -ItemType Directory -Force -Path $spaced | Out-Null; Copy-Item -LiteralPath $np -Destination (Join-Path $spaced 'tool.exe')
    Assert-Equal 'an unquoted path with spaces and arguments is grown token by token until a file answers' (Join-Path $spaced 'tool.exe') (Resolve-StartupExe ((Join-Path $spaced 'tool.exe') + ' --tray --quiet'))
    $lnk = Join-Path $sandbox 'Tool.lnk'; $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $sc.TargetPath = $np; $sc.Arguments = '/A'; $sc.Save()
    Assert-Equal 'a Startup-folder shortcut resolves to its target' $np (Resolve-StartupExe $lnk)
    Assert-Equal 'a bare program name is found the way the shell finds it' (Join-Path $env:SystemRoot 'System32\rundll32.exe') (Resolve-StartupExe 'rundll32.exe some.dll,Entry')
    Assert-Equal 'and nothing on disk means empty, never a guess' '' (Resolve-StartupExe 'C:\nowhere\gone.exe --x')
    Assert-True  'every location is one the worker knows how to switch' (@($su | Where-Object { $_.Location -notin 'HKCU\Run', 'HKLM\Run', 'HKLM\Run32', 'StartupFolder', 'CommonStartup' }).Count -eq 0)
    Assert-True  'and Enabled is a verdict, not a guess' (@($su | Where-Object { $_.Enabled -isnot [bool] }).Count -eq 0)
    Assert-True  'the worker switches an entry through Set-StartupEntry on startupoff / startupon' ($rendered -match '(?m)^function Set-StartupEntry\(' -and $rendered -match "'startupoff'\s+\{" -and $rendered -match "'startupon'\s+\{")
    # the new rows: three performance tweaks, four cleanup actions, one fix - in the table, with a detector, an apply and an undo each
    foreach ($id in 'searchscope', 'defenderscan', 'storagesense', 'browsercache', 'crashdumps', 'docache', 'shadowcap') {
        $row = @($script:TweakDefs | Where-Object { $_.id -eq $id })
        Assert-True "row '$id' is in the table with a detector, an Apply clause and an Undo clause" ($row.Count -eq 1 -and $script:TweakTests.ContainsKey($id) -and $rendered -match "'$id'\s+\{")
    }
    Assert-True 'the four cleanup rows are cleanup rows, and the shadow-storage cap is CAUTION' (
        (@($script:TweakDefs | Where-Object { $_.id -in 'browsercache', 'crashdumps', 'docache', 'shadowcap' -and $_.tab -eq 'cleanup' }).Count -eq 4) -and
        [bool](@($script:TweakDefs | Where-Object { $_.id -eq 'shadowcap' })[0].caution) -and -not [bool](@($script:TweakDefs | Where-Object { $_.id -eq 'browsercache' })[0].caution))
    Assert-True 'the three performance tweaks are pre-ticked Tweaks rows' (@($script:TweakDefs | Where-Object { $_.id -in 'searchscope', 'defenderscan', 'storagesense' -and -not $_.tab -and -not $_.caution }).Count -eq 3)
    Assert-True 'the cleanup rows answer null to Detect - actions, not states' (($null -eq (& $script:TweakTests['browsercache'])) -and ($null -eq (& $script:TweakTests['shadowcap'])))
    Assert-True 'the Search Index rebuild is a fix the worker knows' ($rendered -match "'searchrebuild'\s+\{")
    # the Disk Management sub-tab: the layout read on this machine, and the worker's three disk actions
    Assert-True 'it carries Get-DiskLayout, lifted verbatim' ($readerSrc.Contains((Get-Fn 'Get-DiskLayout')))
    $outDk = Join-Path $sandbox 'disks.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op disks -Out `"$outDk`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the disks read exits 0' 0 $rp.ExitCode
    $dk = @([array]((Get-Content -LiteralPath $outDk -Raw | ConvertFrom-Json).disks))
    Assert-Equal 'it lists every disk Get-Disk lists' @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 }).Count $dk.Count
    Assert-True  'a disk carries its number, name, size, style, bus, boot flag, dynamic flag and partitions' ($dk.Count -eq 0 -or (($dk[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Bus,IsBoot,IsDynamic,Name,Number,Partitions,Size,Style')
    $allParts = @($dk | ForEach-Object { $_.Partitions })
    Assert-True  'a partition carries every field the client reads' ($allParts.Count -eq 0 -or (($allParts[0].PSObject.Properties.Name | Sort-Object) -join ',') -eq 'FileSystem,Free,GapAfter,IsBoot,IsSystem,IsWinRE,Kind,Label,Letter,MaxSize,MinSize,Number,Offset,Size')
    Assert-True  'every partition is a kind the client draws' (@($allParts | Where-Object { $_.Kind -notin 'volume', 'system', 'reserved', 'recovery', 'other' }).Count -eq 0)
    Assert-True  'partitions come in offset order, and no gap is negative' (@($dk | Where-Object { $ps = @($_.Partitions); $bad = $false; for ($i = 1; $i -lt $ps.Count; $i++) { if ([long]$ps[$i].Offset -lt [long]$ps[$i-1].Offset) { $bad = $true } }; foreach ($q in $ps) { if ([long]$q.GapAfter -lt 0) { $bad = $true } }; $bad }).Count -eq 0)
    Assert-True  'the Windows volume is found, as a volume, on the boot disk' (@($dk | Where-Object { $_.IsBoot } | ForEach-Object { $_.Partitions } | Where-Object { $_.Kind -eq 'volume' -and $_.Letter -eq $env:SystemDrive.TrimEnd(':') }).Count -eq 1)
    Assert-True  'the worker resizes through Invoke-DiskAction on diskshrink / diskextend / diskextendmove' ($rendered -match '(?m)^function Invoke-DiskAction\(' -and $rendered -match "'diskshrink'\s+\{" -and $rendered -match "'diskextend'\s+\{" -and $rendered -match "'diskextendmove'\s+\{")
    Assert-True  'and refuses a dynamic disk, a non-recovery blocker and BitLocker before touching anything' ($rendered -match 'is a dynamic disk - Windows cannot resize those from here' -and $rendered -match 'is not a recovery partition - it is not touched from here' -and $rendered -match 'BitLocker is on for')
    # the Diagnose remedies: one row per sentence the diagnosis can say, held in step with the sentences by the function's own AST
    $outRm = Join-Path $sandbox 'remedies.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op diagremedies -Out `"$outRm`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the diagremedies read exits 0' 0 $rp.ExitCode
    $rm = @([array]((Get-Content -LiteralPath $outRm -Raw | ConvertFrom-Json).items))
    Assert-Equal 'it is the script''s remedy table, row for row' @($script:DiagRemedies).Count $rm.Count
    # the fix table is GUI-side and not lifted into the reader, so its ids come from the script's AST here
    $fixAsgNow = $deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:FixDefs' }, $false) | Select-Object -First 1
    $fixIdsNow = @($fixAsgNow.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object { ($_.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'id' }).Item2.Extent.Text.Trim("'") })
    $badRows = @()
    foreach ($r in $rm) {
        if ($r.layer -notmatch '^L[0-6]$' -or -not $r.match -or $r.kind -notin 'tweak', 'fix', 'cleanup', 'startup', 'uninstall', 'backup', 'none') { $badRows += $r.match; continue }
        if ($r.kind -ne 'none' -and -not $r.label) { $badRows += $r.match; continue }
        if ($r.kind -eq 'tweak' -and -not @($script:TweakDefs | Where-Object { $_.id -eq $r.target }).Count) { $badRows += $r.match; continue }
        if ($r.kind -eq 'fix' -and $fixIdsNow -notcontains $r.target) { $badRows += $r.match; continue }
        if ($r.kind -in 'startup', 'uninstall' -and $r.target -and $r.target -notmatch '^\d+$') { $badRows += $r.match }
    }
    Assert-Equal 'every remedy names a layer, a kind the client knows, a label when it has a button, and a tweak or fix that exists' '' ($badRows -join ' | ')
    # every sentence Get-SlowPcReport can say, from its own AST: the $lN += literals, expressions replaced by 1.
    # The function lives INSIDE the worker here-string, so it is found in the rendered worker's AST, not the script's.
    $workerAst = [System.Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$null)
    $slowFn = $workerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SlowPcReport' }, $true) | Select-Object -First 1
    Assert-True 'Get-SlowPcReport is in the rendered worker' ($null -ne $slowFn)
    $lits = @()
    foreach ($asg in @($slowFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'PlusEquals' -and $n.Left.Extent.Text -match '^\$l[0-6]$' }, $true))) {
        $layer = 'L' + $asg.Left.Extent.Text.Substring(2)
        foreach ($s in @($asg.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
            # a literal INSIDE an expandable string's $(...) is part of an expression, not a sentence of its own
            $inside = $false; $up = $s.Parent
            while ($up) { if ($up -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $inside = $true; break }; $up = $up.Parent }
            if ($inside) { continue }
            $t = [string]$s.Value
            if ($s -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { foreach ($ne in @($s.NestedExpressions | Sort-Object { $_.Extent.StartOffset } -Descending)) { $t = $t.Replace($ne.Extent.Text, '1') } }
            if ($t.Trim()) { $lits += [pscustomobject]@{ Layer = $layer; Text = $t } }
        }
    }
    Assert-True  'the diagnosis has sentences to map, found by AST' ($lits.Count -ge 20)
    $orphanFindings = @($lits | Where-Object { $l = $_; -not @($rm | Where-Object { $_.layer -eq $l.Layer -and $l.Text -match $_.match }).Count })
    Assert-Equal 'every sentence the diagnosis can say has a remedy row on its layer' '' (($orphanFindings | ForEach-Object { "$($_.Layer): $($_.Text)" }) -join ' | ')
    $orphanRemedies = @($rm | Where-Object { $r = $_; -not @($lits | Where-Object { $_.Layer -eq $r.layer -and $_.Text -match $r.match }).Count })
    Assert-Equal 'and every remedy answers a sentence the diagnosis actually says' '' (($orphanRemedies | ForEach-Object { "$($_.layer): $($_.match)" }) -join ' | ')
    Assert-True  'the Restart Now fix is a fix the worker knows' ($rendered -match "'restart'\s+\{" -and $rendered -match 'shutdown\.exe" /r /t 60')
    # the hardware layer judges the disk Windows runs from, names the disk a SMART counter belongs to, and a browser eating CPU is its own sentence
    Assert-True  'only the Windows disk decides "spinning disk" - other disks are listed, not judged' ($rendered -match '\$sysNums = @\(Get-Disk' -and $rendered -match 'if \(-not \$isSys\) \{ continue \}')
    Assert-True  'a read-error or wear sentence names the disk it is about, and says "copy what you need off it" for a disk that is not the Windows disk' ($rendered -match "Plural \(\[int\]\`$c\.ReadErrorsTotal\) 'read error' 'read errors'\) on the Windows disk \(\`$\(\`$d\.FriendlyName\)\) - back this machine up NOW" -and $rendered -match 'not the Windows disk - copy what you need off it')
    # the first match on a layer wins in the client, so the note row must come BEFORE the backup row it would otherwise fall into
    $l0Rows = @($rm | Where-Object { $_.layer -eq 'L0' }); $l0Match = @($l0Rows | ForEach-Object { $_.match })
    $iNote = [array]::IndexOf($l0Match, 'not the Windows disk'); $iBackup = [array]::IndexOf($l0Match, 'back this machine up NOW|SSD wear')
    Assert-True  'and the table answers a failing non-Windows disk with a note, placed before the Back-this-machine-up row' ($iNote -ge 0 -and $iBackup -gt $iNote -and $l0Rows[$iNote].kind -eq 'none')
    Assert-True  'a browser outrunning the shell gets the browser sentence, not the rogue-helper one' ($rendered -match "- a browser: tabs and extensions, not Windows")
    Assert-True  'CPU is judged per program, summed over its processes, above the shell AND a 2%-of-one-core floor' ($rendered -match "CPU-seconds in \`$\(Plural \`$g\.N 'process' 'processes'\)" -and $rendered -match '\$floor = \[math\]::Max\(60, \$up \* 3600 \* 0\.02\)' -and $rendered -match '\$g\.Cpu -gt \$shell -and \$g\.Cpu -gt \$floor')
    Assert-True  'the diagnosis says real plurals - "1 read error", "3 read errors" - never "(s)"' ($rendered -match '(?m)^\s*function Plural\(' -and -not ($slowFn.Extent.Text -match '\((s|es)\)"'))
    Assert-Equal 'and the remedy table answers it first on L1, with advice instead of a button' 'none' (@($rm | Where-Object { $_.layer -eq 'L1' })[0].kind)
    $outSh = Join-Path $sandbox 'shares.json'
    $rp = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$readerFile`" -Op shares -Out `"$outSh`"" -PassThru -Wait -WindowStyle Hidden
    Assert-Equal 'the shares read exits 0' 0 $rp.ExitCode
    $sh = (Get-Content -LiteralPath $outSh -Raw) | ConvertFrom-Json
    Assert-True  'it answers with a list of {Name, Path, Description}, admin shares filtered out' (
        ($null -ne $sh.all) -and (@($sh.all | Where-Object { $_.Name -like '*$' }).Count -eq 0) -and (@($sh.all | Where-Object { -not ($_.PSObject.Properties.Name -contains 'Path') }).Count -eq 0))

    # ============================================================== 1c. the download path
    Write-Section '1c. The download path: several connections, a journal that survives a kill, a server that drops, refuses Range, or goes dark'
    # A Range-capable HTTP server in its own runspace, throttled so there is time to interrupt it,
    # with a stop flag (an outage) and two faults on demand: refuse Range (200 + the whole file,
    # whatever was asked) and cut every Nth response a third of the way through.
    $dlServer = {
        param($Prefix, $FilePath, $ChunkBytes, $DelayMs, $StopFlag, $Mode, $CutEvery)
        $listener = New-Object Net.HttpListener
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $bytes = [IO.File]::ReadAllBytes($FilePath)
        $n = 0
        while (-not (Test-Path -LiteralPath $StopFlag)) {
            $ctx = $null
            try {
                $async = $listener.BeginGetContext($null, $null)
                while (-not $async.AsyncWaitHandle.WaitOne(200)) { if (Test-Path -LiteralPath $StopFlag) { break } }
                if (-not $async.IsCompleted) { break }
                $ctx = $listener.EndGetContext($async)
            } catch { break }
            try {
                $n++
                $req = $ctx.Request; $res = $ctx.Response
                $from = 0; $to = $bytes.Length - 1
                $range = $req.Headers['Range']
                if ($Mode -ne 'norange' -and $range -match 'bytes=(\d+)-(\d*)') {
                    $from = [int]$Matches[1]
                    if ($Matches[2]) { $to = [int]$Matches[2] }
                    $res.StatusCode = 206
                    $res.Headers['Content-Range'] = "bytes $from-$to/$($bytes.Length)"
                } else { $res.StatusCode = 200 }
                $res.Headers['ETag'] = '"fixture-1"'
                if ($Mode -ne 'norange') { $res.Headers['Accept-Ranges'] = 'bytes' }
                $len = $to - $from + 1
                $res.ContentLength64 = $len
                $cutAt = $(if ($Mode -eq 'cut' -and $CutEvery -gt 0 -and ($n % $CutEvery) -eq 0 -and $len -gt 3) { [int]($len / 3) } else { -1 })
                $sent = 0
                while ($sent -lt $len) {
                    if (Test-Path -LiteralPath $StopFlag) { break }
                    if ($cutAt -ge 0 -and $sent -ge $cutAt) { $res.Abort(); $ctx = $null; break }
                    $k = [Math]::Min($ChunkBytes, $len - $sent)
                    $res.OutputStream.Write($bytes, $from + $sent, $k)
                    $res.OutputStream.Flush()
                    $sent += $k
                    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
                }
                if ($ctx) { $res.Close() }
            } catch { try { if ($ctx) { $ctx.Response.Abort() } } catch { } }
        }
        try { $listener.Stop(); $listener.Close() } catch { }
    }
    $dlDir = Join-Path $sandbox 'dl'; New-Item -ItemType Directory -Force $dlDir | Out-Null
    $dlStop = Join-Path $dlDir 'server.stop'
    $dlPort = 18790
    $dlPrefix = "http://127.0.0.1:$dlPort/"
    $dlSrv = $null
    function Start-DlServer([string]$file, [string]$mode = 'normal', [int]$cutEvery = 0, [int]$delay = 10) {
        Remove-Item -LiteralPath $dlStop -ErrorAction SilentlyContinue
        $script:dlSrv = [powershell]::Create()
        [void]$script:dlSrv.AddScript($dlServer).AddArgument($dlPrefix).AddArgument($file).AddArgument(65536).AddArgument($delay).AddArgument($dlStop).AddArgument($mode).AddArgument($cutEvery)
        [void]$script:dlSrv.BeginInvoke()
        Start-Sleep -Milliseconds 700
    }
    function Stop-DlServer {
        if (-not $script:dlSrv) { return }
        Set-Content -LiteralPath $dlStop -Value 'stop' -Encoding ASCII
        Start-Sleep -Milliseconds 900
        try { $script:dlSrv.Stop() } catch { }; try { $script:dlSrv.Dispose() } catch { }
        $script:dlSrv = $null
    }
    function Invoke-Probe([string]$dest, [string]$report, [long]$size, [int]$streams = 0) {
        $argLine = "-Download `"$dlPrefix/f.bin`" -Dest `"$dest`" -Size $size -ChunkFloor 1048576 -Out `"$report`"" + $(if ($streams) { " -Streams $streams" } else { '' })
        $p = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -Wait
        return $p.ExitCode
    }
    function Read-Probe([string]$report) { return (Get-Content -LiteralPath $report -Raw | ConvertFrom-Json) }
    # 48 MB of random bytes: big enough for 48 one-megabyte pieces and 16 workers, small enough to run in seconds
    $dlSize = 48MB
    $dlSrc = Join-Path $dlDir 'src.bin'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $dlPayload = New-Object byte[] $dlSize; $rng.GetBytes($dlPayload); [IO.File]::WriteAllBytes($dlSrc, $dlPayload); $dlPayload = $null
    $dlHash = (Get-FileHash -LiteralPath $dlSrc -Algorithm SHA256).Hash.ToUpper()
    try {
        # (a) a healthy server
        Start-DlServer $dlSrc
        $d1 = Join-Path $dlDir 'a.bin'; $r1 = Join-Path $dlDir 'a.json'
        Assert-Equal 'a 48 MB file comes down over several connections (exit 0)' 0 (Invoke-Probe $d1 $r1 $dlSize)
        $j1 = Read-Probe $r1
        Assert-Equal 'by the multi-connection path' 'segmented' $j1.path
        Assert-Equal 'byte for byte' $dlHash $j1.sha256
        Assert-True  'announced as such in the log' (@($j1.log | Where-Object { $_ -like 'Downloading Probe (48.0 MB) over 16 connections...' }).Count -eq 1)
        Assert-True  'and nothing is left beside the file - no .part, no journal' (-not (Test-Path "$d1.part") -and -not (Test-Path "$d1.parts"))
        # (b) the process is KILLED mid-file - a crash, a reboot, a closed window - and the next run resumes it
        $d2 = Join-Path $dlDir 'b.bin'; $r2 = Join-Path $dlDir 'b.json'
        $p2 = Start-Process -FilePath $exe -ArgumentList "-Download `"$dlPrefix/f.bin`" -Dest `"$d2`" -Size $dlSize -ChunkFloor 1048576 -Out `"$r2`"" -PassThru
        $killedAt = [long]0; $waited = 0
        while ($waited -lt 30000 -and -not $p2.HasExited) {
            Start-Sleep -Milliseconds 100; $waited += 100
            if (Test-Path -LiteralPath "$d2.parts") {
                try { $jj = Get-Content -LiteralPath "$d2.parts" -Raw | ConvertFrom-Json; $s = [long]0; foreach ($x in @($jj.done)) { $s += [long]$x }
                      if ($s -gt 0 -and $s -lt $dlSize) { $p2.Kill(); $killedAt = $s; break } } catch { }
            }
        }
        Assert-True  'the journal appeared while the download ran, and the process was killed with the file part-way' ($killedAt -gt 0 -and $killedAt -lt $dlSize)
        Assert-True  'what was fetched is still on disk: the pre-allocated .part is full size and the journal says how far each piece got' ((Test-Path "$d2.part") -and (Get-Item "$d2.part").Length -eq $dlSize -and (Test-Path "$d2.parts") -and -not (Test-Path $d2))
        Assert-Equal 'the next run finishes it (exit 0)' 0 (Invoke-Probe $d2 $r2 $dlSize)
        $j2 = Read-Probe $r2
        Assert-Equal 'byte for byte, out of two runs' $dlHash $j2.sha256
        Assert-True  'and said so: it resumed what was already here rather than starting over' (@($j2.log | Where-Object { $_ -like 'Resuming Probe - * of 48.0 MB already here.' }).Count -eq 1)
        $fetched = @($j2.log | Where-Object { $_ -like 'Probe: * fetched this time over up to * connections, * kept from before.' })
        Assert-Equal 'the closing line counts what was fetched and what was kept' 1 $fetched.Count
        Stop-DlServer
        # (c) a server that cuts every third response a third of the way through: retried at once, from where each piece stood
        Start-DlServer $dlSrc 'cut' 3
        $d3 = Join-Path $dlDir 'c.bin'; $r3 = Join-Path $dlDir 'c.json'
        Assert-Equal 'a server that keeps dropping connections still delivers (exit 0)' 0 (Invoke-Probe $d3 $r3 $dlSize)
        $j3 = Read-Probe $r3
        Assert-Equal 'byte for byte' $dlHash $j3.sha256
        Assert-True  'the drops were seen and retried' (@($j3.log | Where-Object { $_ -match 'chunk \d+ attempt \d+ failed .* - retrying in' }).Count -ge 1)
        Assert-Equal 'over the multi-connection path throughout - a cut socket is not a reason to fall back' 'segmented' $j3.path
        Stop-DlServer
        # (d) the server goes DARK for three seconds mid-file and comes back: the workers wait and carry on
        Start-DlServer $dlSrc 'normal' 0 25
        $d4 = Join-Path $dlDir 'd.bin'; $r4 = Join-Path $dlDir 'd.json'
        $p4 = Start-Process -FilePath $exe -ArgumentList "-Download `"$dlPrefix/f.bin`" -Dest `"$d4`" -Size $dlSize -ChunkFloor 1048576 -Out `"$r4`"" -PassThru
        Start-Sleep -Milliseconds 1500
        Stop-DlServer
        Start-Sleep -Seconds 3
        Start-DlServer $dlSrc
        if (-not $p4.WaitForExit(120000)) { $p4.Kill() }
        Assert-Equal 'an outage mid-file does not end the download (exit 0)' 0 $p4.ExitCode
        $j4 = Read-Probe $r4
        Assert-Equal 'byte for byte' $dlHash $j4.sha256
        # Whether a worker SEES the outage as an error depends on what was in flight when the
        # listener closed: HTTP.sys holds the other connections and hands them to the listener
        # that comes back, so a run can pass the dark window with no error at all (1 in ~5 runs
        # here). Retries being narrated as retries is (c)'s pin; this one is the outcome - waited
        # out, on the multi-connection path, with no failure and no fall-back - and that the
        # download really was running when the server went dark.
        Assert-True  'the outage was waited out - no failure, no fall-back to one connection' (-not $j4.error -and $j4.path -eq 'segmented' -and @($j4.log | Where-Object { $_ -match 'did not work|falling back' }).Count -eq 0)
        Assert-True  'and the download was still running when the server went dark' ($j4.seconds -ge 5)
        Stop-DlServer
        # (e) a server that will not do Range: one connection from byte zero, the path that shipped before
        Start-DlServer $dlSrc 'norange'
        $d5 = Join-Path $dlDir 'e.bin'; $r5 = Join-Path $dlDir 'e.json'
        Assert-Equal 'a server without Range still delivers (exit 0)' 0 (Invoke-Probe $d5 $r5 $dlSize)
        $j5 = Read-Probe $r5
        Assert-Equal 'over ONE connection' 'single' $j5.path
        Assert-True  'after saying why' (@($j5.log | Where-Object { $_ -like 'Multi-connection download did not work for Probe (the server ignored a Range request (HTTP 200)) - falling back to a single connection.' }).Count -eq 1)
        Assert-Equal 'byte for byte' $dlHash $j5.sha256
        Stop-DlServer
    } finally { Stop-DlServer }

    # ============================================================== 2. the self-test
    Write-Section '2. -SelfTest: the product''s own code paths, reported without a window'
    $rep = Join-Path $sandbox 'selftest.json'
    $p = Start-Process -FilePath $exe -ArgumentList ('-SelfTest -Out "{0}" -Catalog "{1}"' -f $rep, (Join-Path $repo 'server\apps.json')) -PassThru -Wait
    Assert-Equal 'the self-test exits 0' 0 $p.ExitCode
    Assert-True 'and writes its report' (Test-Path -LiteralPath $rep)
    $j = Get-Content -LiteralPath $rep -Raw | ConvertFrom-Json

    # the worker the exe writes is the rendered worker, byte for byte, in Set-Content's shape
    $body = $rendered.Replace("`r`n", "`n").Replace("`n", "`r`n")
    if (-not $body.EndsWith("`r`n")) { $body += "`r`n" }
    $bytes = (New-Object Text.UTF8Encoding $true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($body)
    $sha = [Security.Cryptography.SHA256]::Create()
    $want = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToUpper()
    Assert-Equal 'the exe embeds the rendered worker byte for byte (BOM, CRLF, trailing newline)' $want $j.workerSha256
    Assert-Equal 'no placeholder survives inside the exe' 0 @($j.workerPlaceholdersLeft).Count
    $rsha = [Security.Cryptography.SHA256]::Create()
    $readerWant = ([BitConverter]::ToString($rsha.ComputeHash([Text.Encoding]::UTF8.GetBytes($readerSrc))) -replace '-', '').ToUpper()
    Assert-Equal 'the exe embeds the rendered reader byte for byte' $readerWant $j.readerSha256
    Assert-Equal 'and it answers every read the tabs ask for' 'installed,store,leftovers,winget,winupdate,accounts,migrateitems,migratedefs,manifest,foldersize,shares,netscan,hostshares,tweakdefs,tweakprobe,firewall,fwmap,startupapps,disks,diagremedies,gameprobe' (@($j.readerOps) -join ',')
    # the Gaming sub-tab: the exe's Format / Compare are the script's Format-GamingProbe / Compare-GamingProbe, checked against them on the same numbers
    . ([scriptblock]::Create((Get-Fn 'Format-GamingProbe')))
    . ([scriptblock]::Create((Get-Fn 'Compare-GamingProbe')))
    $gpb = @{ TimerP50 = 1.94; PreP50 = 0.02; PreP99 = 0.612; PreMax = 2.31; Dpc = 0.4; Isr = 0.1 }
    $gpa = @{ TimerP50 = 1.02; PreP50 = 0.01; PreP99 = 0.210; PreMax = 0.98; Dpc = 0.2; Isr = 0.1 }
    $gpn = @{ TimerP50 = 1.94; PreP50 = 0.02; PreP99 = 0.700; PreMax = 2.40; Dpc = -1; Isr = -1 }
    Assert-Equal 'the probe sentence is the script''s, DPC and all' (Format-GamingProbe $gpb) $j.gameFormat[0]
    Assert-Equal 'and without DPC when the counters were not read' (Format-GamingProbe $gpn) $j.gameFormat[1]
    $cmpI = Compare-GamingProbe $gpb $gpa; $cmpW = Compare-GamingProbe $gpa $gpb; $cmpN = Compare-GamingProbe $gpb $gpn
    Assert-Equal 'before/after IMPROVED reads as the script says it' ($cmpI.Line + '||' + $cmpI.Verdict) $j.gameCompare[0]
    Assert-Equal 'WORSE likewise' ($cmpW.Line + '||' + $cmpW.Verdict) $j.gameCompare[1]
    Assert-Equal 'and a wobble inside the 30% / 0.2 ms gate is no verdict at all' ($cmpN.Line + '||' + $cmpN.Verdict) $j.gameCompare[2]
    Assert-True  'which is the no-change sentence' ($j.gameCompare[2] -like '*||no measurable change in this window*')
    $costsBlock = [regex]::Match($deployText, '(?s)\$costs = @\{(.*?)\n\s*\}').Groups[1].Value
    $costKeys = @([regex]::Matches($costsBlock, '(?m)^\s*(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Assert-Equal 'the CAUTION costs named on the Apply Gaming sheet are the script''s $costs table, key for key' ($costKeys -join ',') (@($j.gamingCosts) -join ',')
    Assert-Equal 'a probe result parses with its numbers and stamp' '1.9|0.25|1.5|0.3|2026-09-09T10:00:00' $j.gameProbeParse
    # the probe explained: the thresholds a player feels, on each of the three cards
    Assert-Equal 'micro-stutter: under 0.2 ms smooth, under 1 ms felt, over that visible - advice on the two that are not smooth' 'ok|Smooth|0.100 ms|False;warn|Felt in competitive play|0.600 ms|True;bad|Visible stutter|1.500 ms|True' (@($j.gameCards.stutter) -join ';')
    Assert-Equal 'timer granularity is context, never a fault: high resolution or the idle default' 'info|High resolution|1.0 ms|False;info|Idle default|15.6 ms|False' (@($j.gameCards.timer) -join ';')
    Assert-Equal 'background load: quiet, one busy driver, a misbehaving one, or counters unavailable' 'ok|Quiet|0.4%|False;warn|One driver is busy|2.5%|True;bad|A driver is misbehaving|7.0%|True;info|Counters unavailable|not read|False' (@($j.gameCards.load) -join ';')
    $cs = @($j.gameCardStates)
    Assert-Equal 'before a run the timer card reads and the others wait' 'stutter:pending,timer:reading,load:pending' $cs[0]
    Assert-Equal 'the probe''s narration turns the cards in order: warming up, then round 2 of 3, then sampling the load' 'stutter:reading(warming up...),timer:measured,load:pending|stutter:reading(round 2 of 3...),timer:measured,load:pending|stutter:measured,timer:measured,load:reading(sampling 1 of 3...)' (($cs[1], $cs[2], $cs[3]) -join '|')
    Assert-Equal 'a finished probe fills every card with its number' 'stutter:filled:0.600 ms,timer:filled:15.6 ms,load:filled:2.5%' $cs[4]
    Assert-Equal 'the after of Apply Gaming keeps the before and adds the after, coloured by the after' 'stutter:0.600 ms -> 0.100 ms:ok,timer:15.6 ms -> 1.0 ms:info,load:2.5% -> 0.4%:ok' $cs[5]
    Assert-Equal 'the report file: the slow-PC header shape, a before and an after block, the verdict line' 'PC2Go gaming probe   2026-09-09 15:30   PROBE|2|VERDICT IMPROVED: preemption jitter p99 down 0.500 ms' (@($j.gameReport) -join '|')
    Assert-True  'the worker starts with its param block' (([string]$j.workerFirstLine).StartsWith('param([string]$QueueFile, [string]$StatusFile'))

    # the stub Start-Worker runs, line for line
    $startWorker = Get-Fn 'Start-Worker'
    $stubSrc = [regex]::Match($startWorker, '(?s)\$stub = @"\r?\n(.*?)\r?\n"@').Groups[1].Value
    Assert-True 'Start-Worker''s stub was found' ($stubSrc.Length -gt 100)
    $stubLines = @($j.stub -split "`n" | ForEach-Object { $_.TrimEnd() })
    Assert-True 'the stub re-hashes the worker before running it'  ($stubLines -contains "    if ((Get-FileHash -LiteralPath `$w -Algorithm SHA256).Hash -ne '$('A' * 64)') {")
    $modified = [regex]::Match($stubSrc, 'the installer worker was modified on disk[^"]*').Value
    Assert-True 'and says the script''s exact sentence when it does not match' ($modified.Length -gt 20 -and $j.stub.Contains($modified))
    Assert-True 'it hands over queue, status, cancel and skip files and the parent pid' ($j.stub -match '-QueueFile ''[^'']+queue\.jsonl'' -StatusFile \$st' -and $j.stub -match '-CancelFile ''[^'']+cancel\.flag'' -SkipFile ''[^'']+skip\.txt'' -ParentPid 4242')
    Assert-Equal 'and exits 9 on both failure paths' 2 @([regex]::Matches($j.stub, 'exit 9')).Count
    Assert-True 'a throw at start is reported through the status file' ($j.stub -match 'the elevated worker could not start - ')
    # the template is a double-quoted here-string: `$ is a literal dollar and `` a literal backtick.
    # Lines with $(...) or '$want' carry per-batch values and are pinned by shape above.
    $stubTemplateLines = @($stubSrc -split "`r?`n" | Where-Object { $_ -notmatch '\$\(' -and $_ -notmatch "'\`$want'" } |
        ForEach-Object { $_.TrimEnd().Replace('`$', '$').Replace('``', '`') })
    foreach ($l in $stubTemplateLines) { if ($l.Trim()) { Assert-True ("stub line kept verbatim: " + $l.Trim().Substring(0, [Math]::Min(48, $l.Trim().Length))) ($stubLines -contains $l) } }

    # the queue entry: every key the script writes, no more, no less
    $entryKeys = Get-HashKeys 'Enqueue-Install' 'entry'
    $exeKeys = @($j.queueEntry.PSObject.Properties.Name)
    Assert-Equal 'the install entry carries exactly Enqueue-Install''s keys' (($entryKeys | Sort-Object) -join ',') (($exeKeys | Sort-Object) -join ',')
    Assert-Equal 'in the same order' ($entryKeys -join ',') ($exeKeys -join ',')
    $stepKeys = @(Get-HashKeys 'Enqueue-Install' 'step') + 'file'
    $exeStep = @($j.queueEntry.postInstall[0].PSObject.Properties.Name)
    Assert-Equal 'a post-install step carries exactly the script''s step keys (plus file)' (($stepKeys | Sort-Object) -join ',') (($exeStep | Sort-Object) -join ',')
    Assert-Equal 'stopOnError false arrives as false' $false $j.queueEntry.postInstall[0].stopOnError
    Assert-Equal 'action is install' 'install' $j.queueEntry.action
    Assert-Equal 'the sha256 travels upper-case' ('B' * 64) $j.queueEntry.sha256
    Assert-Equal 'the id keeps its spaces on the queue' 'self test' $j.queueEntry.id
    Assert-Equal 'and is tamed for the folder name' 'self_test' $j.safeId

    # the status line, read the way the timer reads it
    Assert-Equal 'status: state'   'Installing' $j.statusParse.state
    Assert-Equal 'status: detail'  'running Setup.exe /S' $j.statusParse.detail
    Assert-Equal 'status: pct'     42 $j.statusParse.pct
    Assert-Equal 'status: elapsed' 7 $j.statusParse.elapsed
    Assert-Equal 'status: an absent pct reads as -1, not 0' -1 $j.statusBatch.pct
    Assert-Equal 'status: the batch marker is recognised' '_batch' $j.statusBatch.id

    # the words on the row, shortened the way Set-Status shortens them
    $w = @{}; foreach ($r in $j.rowWords) { $w[$r.state] = $r }
    Assert-Equal 'Installed settles to one word'   'Installed' $w['Installed'].short
    Assert-Equal 'Failed settles to one word'      'Failed' $w['Failed'].short
    Assert-Equal 'Skipped settles to one word'     'Skipped' $w['Skipped'].short
    Assert-Equal 'Installing keeps its detail'     'Installing: running' $w['Installing'].short
    Assert-Equal 'Installed is ok/ok'              'ok/ok' ($w['Installed'].kind + '/' + $w['Installed'].ring)
    Assert-Equal 'Failed is fail/fail'             'fail/fail' ($w['Failed'].kind + '/' + $w['Failed'].ring)
    Assert-Equal 'Skipped is warn/warn'            'warn/warn' ($w['Skipped'].kind + '/' + $w['Skipped'].ring)
    Assert-Equal 'Installing is active/busy'       'active/busy' ($w['Installing'].kind + '/' + $w['Installing'].ring)
    Assert-True  'Cleaned after a dirty failure does not turn green' ($j.cleanedDirty -like 'Failed: partial install removed - *')

    # numbers read the same in both clients
    . ([scriptblock]::Create((Get-Fn 'Format-Size')))
    . ([scriptblock]::Create((Get-Fn 'Format-Eta')))
    . ([scriptblock]::Create((Get-Fn 'Get-DiskVerdict')))
    Assert-Equal 'Format-Size agrees with the script' ((Format-Size 0), (Format-Size (512KB)), (Format-Size 5MB), (Format-Size 3GB) -join '|') ($j.formatSize -join '|')
    Assert-Equal 'Format-Eta agrees with the script'  ((Format-Eta 1000 100), (Format-Eta 100000 100), (Format-Eta 0 100) -join '|') ($j.formatEta -join '|')
    Assert-Equal 'Get-DiskVerdict agrees with the script' ((Get-DiskVerdict 0 0 0), (Get-DiskVerdict 10 100 20), (Get-DiskVerdict 3GB 100GB 2GB), (Get-DiskVerdict 50GB 100GB 1GB) -join '|') ($j.diskVerdict -join '|')
    # the batch order: smallest first so the first install starts at once, a base ahead of its add-on, unknown size last
    Assert-Equal 'a batch downloads smallest first, 3ds Max ahead of the plugin that needs it, the unsized file last' 'office,3ds-max,plugin,revit,acrobat' (@($j.batchOrder) -join ',')
    # the overall bar in the execution phase - every batch kind has one, not just the two that
    # download, and it counts EVERY ticked row, whether or not that row reports a percentage
    $bar = @($j.overallBar)
    Assert-Equal 'a row that is running but reports no figure is worth half a share, so the bar moves the moment it starts' '12.5|12%   -   0 of 4 finished' $bar[0]
    Assert-Equal 'a single running row: half way, with a figure - never a sweep, which renders as a frozen solid line' '50|50%   -   0 of 1 finished' $bar[1]
    Assert-Equal 'two of four settled - a failure counts as settled - is half way' '50|50%   -   2 of 4 finished' $bar[2]
    Assert-Equal 'a row the worker reports a percentage for contributes that fraction, not a flat half' '37.5|37%   -   1 of 4 finished' $bar[3]
    Assert-Equal 'it says "finished", not "done" - the strip header counts successes and this counts settled rows' '100|100%   -   4 of 4 finished' $bar[4]
    Assert-Equal 'an empty batch shows nothing rather than dividing by zero' '0|' $bar[5]
    # the row the strip follows, so a batch of twenty does not leave the technician watching "Queued"
    Assert-Equal 'the strip follows the row being worked, not the settled one above it or the queued one below' 'b' (@($j.activeRow)[0])
    Assert-Equal 'a failed row is settled - the strip moves past it' '(none)' (@($j.activeRow)[1])
    Assert-Equal 'nothing started yet: nothing to follow, the strip stays put' '(none)' (@($j.activeRow)[2])
    Assert-Equal 'every row settled: nothing to follow' '(none)' (@($j.activeRow)[3])
    Assert-Equal 'a downloading row is being worked on too' 'b' (@($j.activeRow)[4])
    Assert-Equal 'a requirement that is neither installed nor in the batch is missing' 'plugin->3ds-max' (@($j.depMissing) -join ',')
    Assert-Equal 'an id the catalog does not know is skipped, as the script does - never a reason the batch will not start' 'electrical->autocad' (@($j.depUnknown) -join ',')
    Assert-Equal 'a base in the same batch satisfies its add-on' 0 $j.depSatisfied
    # the cleanup summary figure, the Startup row projection and its worker entry, and the fix table
    Assert-Equal 'the reclaimed figure sums GB and MB rows and ignores "under 1 MB" and rows without one' ([long](1.5 * 1GB) + [long](300 * 1MB)) ([long]$j.reclaimed)
    $sr = @($j.startupRows)
    Assert-Equal 'a running startup entry: grouped as starting, no badge, its initial on the tile' 'startup-hkcu-run-discord|Starts with Windows|True||D' (($sr[0].id, $sr[0].category, $sr[0].isSilent, $sr[0].size, $sr[0].iconText) -join '|')
    Assert-Equal 'a switched-off one: grouped as off, OFF badge' 'startup-startupfolder-onedrive-setup-lnk|Switched off - does not start|False|OFF' (($sr[1].id, $sr[1].category, $sr[1].isSilent, $sr[1].size) -join '|')
    Assert-Equal 'the executable the reader resolved is the row''s icon source; without one the tile keeps its glyph' 'C:\Users\x\AppData\Local\Discord\Update.exe|Visible||Visible' (($sr[0].exe, $sr[0].glyphVis, $sr[1].exe, $sr[1].glyphVis) -join '|')
    # the icon cache key: id AND URL, the same bytes this suite computes, so a file on disk traces back to its catalog entry
    $ik = @($j.iconCacheKeys)
    Assert-True  'a logo is cached under its id and its URL: the same id from another server is another file, case and spaces do not matter' ($ik[0] -match '^winrar-[0-9a-f]{8}\.png$' -and $ik[1] -match '^winrar-[0-9a-f]{8}\.png$' -and $ik[0] -ne $ik[1] -and $ik[0] -eq $ik[2])
    Assert-Equal 'and the suite computes the same name from the same URL' ((Get-IconCacheName 'winrar' 'https://apps.pc2go.ca/icons/winrar.png') + '.png') $ik[0]
    $se = @($j.startupEntries)
    Assert-Equal 'the worker entry names the entry, where it lives, the action and the technician''s SID' 'startupoff|Discord|HKCU\Run|S-1-5-21-1-2-3-1001|action,id,location,name,userSid' (($se[0].action, $se[0].name, $se[0].location, $se[0].userSid, (($se[0].PSObject.Properties.Name | Sort-Object) -join ',')) -join '|')
    Assert-Equal 'switching back on is startupon for the Startup folder entry' 'startupon|OneDrive Setup.lnk|StartupFolder' (($se[1].action, $se[1].name, $se[1].location) -join '|')
    $fixAsg = $deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:FixDefs' }, $false) | Select-Object -First 1
    $fixIds = @($fixAsg.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object { ($_.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'id' }).Item2.Extent.Text.Trim("'") })
    Assert-Equal 'the Toolbox draws exactly the script''s fix table, id for id, in order' ($fixIds -join ',') (@($j.fixIds) -join ',')
    # the Disk Management plan: free space behind -> extend; a recovery partition then free space -> move; a data partition behind -> nothing, and why; a dynamic disk -> nothing
    $ep = @($j.extendPlans)
    Assert-Equal 'free space directly behind C: is a plain extend of exactly that much' ('extend|' + (200GB - (101MB + 120GB))) (($ep[0].kind, $ep[0].bytes) -join '|')
    Assert-Equal 'a recovery partition then free space is a move, gaining the gap plus the old partition less the 1 GB reserve' ('move|' + ((200GB - (101MB + 120GB + 800MB)) + 800MB - 1GB) + '|3') (($ep[1].kind, $ep[1].bytes, $ep[1].blocker) -join '|')
    Assert-True  'and says what is in the way' ($ep[1].reason -like 'the Windows Recovery partition (800.0 MB) sits between C: and * of free space')
    Assert-Equal 'a data partition behind C: is nothing, naming it' 'none|2' (($ep[2].kind, $ep[2].blocker) -join '|')
    Assert-True  'with the reason a technician can act on' ($ep[2].reason -like 'D: (50.0 GB) sits directly behind C: - only free space directly behind a volume can be joined to it')
    Assert-Equal 'a dynamic disk is nothing' 'none' $ep[3].kind
    Assert-Equal 'the last volume on a disk extends into the free space at the end' 'extend' $ep[4].kind
    Assert-Equal 'a 1 MB alignment gap is slack, not free space: Extend names the partition behind it instead' 'none|2' (($ep[5].kind, $ep[5].blocker) -join '|')
    Assert-True  'in words' ($ep[5].reason -like 'Partition 2 (15.0 GB) sits directly behind E: - *')
    Assert-Equal 'the shrink room is size minus what Windows says is the floor' (60GB) ([long]$j.shrinkRoom)
    # Numbers to FIND it, offset and size to PROVE it is the same partition that was read - and
    # still never a drive letter. Disk numbers come from enumeration order, so a USB disk swapped
    # between the read and the press renumbers underneath a cached card and "shrink disk 2
    # partition 1" resolves, correctly, to somebody else's drive.
    Assert-Equal 'the disk entry names disk and partition numbers, never a letter, and carries an identity' 'diskextendmove|0|1|0|action,bytes,disk,id,offset,partition,size' (($j.diskEntry.action, $j.diskEntry.disk, $j.diskEntry.partition, $j.diskEntry.bytes, (($j.diskEntry.PSObject.Properties.Name | Sort-Object) -join ',')) -join '|')
    # the diagnosis report parse
    $dl = @($j.diagLayers)
    Assert-Equal 'seven layers, in reading order' 'L0,L1,L2,L3,L4,L5,L6' (($dl | ForEach-Object { $_.key }) -join ',')
    Assert-Equal 'each verdict lands on its layer' 'OK|chrome has used 900 CPU-seconds|2 startup items worth reviewing: McAfee, Norton' (($dl[0].verdict, $dl[1].verdict, $dl[5].verdict) -join '|')
    Assert-Equal 'OK is OK, a finding is not' 'True|False|False' (($dl[0].ok, $dl[1].ok, $dl[5].ok) -join '|')
    Assert-Equal 'the lines behind a verdict travel with it' "run     McAfee`nrun     Norton" $dl[5].lines
    Assert-Equal 'the header is the first line' 'PC2Go slow-PC triage   2026-09-05 01:10   PROBE' $j.diagHeader
    Assert-Equal 'before a run the screen shows seven grey cards, none read yet' (@(1..7 | ForEach-Object { 'pending:Not read yet' }) -join ',') (@($j.diagSkeleton) -join ',')
    Assert-Equal 'a live VERDICT status paints its layer and marks the next as reading; other statuses are ignored' 'True,True,False|ok,finding,reading,pending,pending,pending,pending|chrome has used 900 CPU-seconds' ((@($j.diagLive.applied) -join ','), (@($j.diagLive.states) -join ','), $j.diagLive.l1 -join '|')
    # the remedies under the findings
    $df = @{}; foreach ($l in $j.diagFindings) { $df[$l.key] = $l }
    Assert-Equal 'a CPU-hog finding offers Uninstall, filtered to the process' 'uninstall|Find it in Uninstall|chrome|True' (@($df['L1'].findings) -join ';')
    Assert-Equal 'a startup finding offers the Startup sub-tab with the named entries' 'startup|Review startup entries|McAfee,Norton|True' (@($df['L5'].findings) -join ';')
    Assert-Equal 'an OK layer has nothing to fix, and keeps its OK line' '0|Visible' ((@($df['L0'].findings).Count, $df['L0'].verdictVis) -join '|')
    Assert-Equal 'a finding card lists its findings and hides the joined verdict line' 'Collapsed' $df['L1'].verdictVis
    Assert-Equal 'a sentence no remedy knows still gets a line without a button, beside one that does' 'none||False|True;none||False|True' (@($j.diagUnmatched) -join ';')
    # the "What to do" card: numbered steps from the findings with buttons, in layer order; the general approach when nothing is actionable; nothing while a run reads
    Assert-Equal 'a report with two actionable findings is a two-step plan, in layer order, no notes' 'True|1:uninstall:Find it in Uninstall,2:startup:Review startup entries|0' (($j.diagPlan.visible, (@($j.diagPlan.steps) -join ','), $j.diagPlan.notes) -join '|')
    Assert-True  'and says so' ($j.diagPlan.summary -like '2 things the tool can do, in order*')
    Assert-Equal 'a clean report gets the general approach: cleanup, startup, tweaks, restart' 'True|1:cleanup:,2:startup:,3:tweaks:,4:fix:restart|0' (($j.diagPlanClean.visible, (@($j.diagPlanClean.steps) -join ','), $j.diagPlanClean.notes) -join '|')
    Assert-True  'and says the layers are clean' ($j.diagPlanClean.summary -like 'All seven layers are clean*')
    Assert-Equal 'a finding without a remedy is a note, and the general steps still follow' '4|1' (($j.diagPlanNotes.steps, $j.diagPlanNotes.notes) -join '|')
    Assert-True  'with the honest sentence' ($j.diagPlanNotes.summary -like 'Nothing here is fixed by a setting: 1 finding to know about, in 1 layer.*')
    Assert-Equal 'no plan while a run is still reading' $false $j.diagPlanRunning
    Assert-True  'the client takes the general approach''s Tweaks step to the Tweaks sub-tab' ((Get-Content -LiteralPath (Join-Path $repo 'client\PC2Go.Deploy\MainWindow.Toolbox.cs') -Raw) -match 'case "tweaks":')
    Assert-Equal 'the report path is lifted off the row''s detail' 'C:\Users\x\AppData\Local\PC2GoDeploy\slowpc-20260905-011000.txt' $j.diagReportPath

    # the Firewall row, as Load-Firewall paints it: the badge, the tile colour, the column, the counts
    $fr = @{}; foreach ($r in $j.fwRows) { $fr[$r.id] = $r }
    Assert-Equal 'a blocked program: red BLOCKED badge with the off count, in the Blocked column' 'BLOCKED  3  (1 off)|#FFF87171|#FFF87171|Blocked - no internet access|1|True|3|1||Vendor A|True' (($fr['fw-a'].size, $fr['fw-a'].badgeBg, $fr['fw-a'].iconBg, $fr['fw-a'].category, $fr['fw-a'].source, $fr['fw-a'].isSilent, $fr['fw-a'].on, $fr['fw-a'].off, $fr['fw-a'].regKey, $fr['fw-a'].version, $fr['fw-a'].hasRules) -join '|')
    Assert-Equal 'and its install folder under the name' 'C:\Program Files\Blocked App' $fr['fw-a'].publisher
    Assert-Equal 'a program with only switched-off rules: amber RULES OFF, NOT blocked, but still has rules to clear' 'RULES OFF  2|#FFF59E0B|#FF64748B|Not blocked|False|True' (($fr['fw-b'].size, $fr['fw-b'].badgeBg, $fr['fw-b'].iconBg, $fr['fw-b'].category, $fr['fw-b'].isSilent, $fr['fw-b'].hasRules) -join '|')
    Assert-Equal 'an untouched program: no badge, nothing to unblock' '|Not blocked|False|False' (($fr['fw-c'].size, $fr['fw-c'].category, $fr['fw-c'].isSilent, $fr['fw-c'].hasRules) -join '|')
    Assert-Equal 'a stray vendor folder: ORPHAN badge, unmatched, its rule names kept for removal by name' 'ORPHAN  4|#FFF59E0B|Stray rules - no installed program owns these|2|True|4|unmatched|no installed program claims this folder|4' (($fr['fwx-d'].size, $fr['fwx-d'].badgeBg, $fr['fwx-d'].category, $fr['fwx-d'].source, $fr['fwx-d'].isSilent, $fr['fwx-d'].on, $fr['fwx-d'].regKey, $fr['fwx-d'].version, $fr['fwx-d'].tokens) -join '|')
    # the queue entries: the script's two literals in Start-FwBatch, key for key
    $fwFn = Get-FnAst 'Start-FwBatch'
    $fwAsg = $fwFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$entry' }, $true) | Select-Object -First 1
    $fwHts = @($fwAsg.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))
    Assert-Equal 'Start-FwBatch writes two entry shapes' 2 $fwHts.Count
    $byNameKeys = @($fwHts[0].KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") } | Sort-Object) -join ','
    $byRootKeys = @($fwHts[1].KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") } | Sort-Object) -join ','
    $fe = @($j.fwEntries)
    Assert-Equal 'a block entry carries exactly the script''s root-based keys' $byRootKeys (($fe[0].PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-Equal 'with the action, the folder, the publisher, the build and the group' ('fwblock|C:\Program Files\Open App|Vendor C|' + $j.build + '|Application Block') (($fe[0].action, $fe[0].root, $fe[0].publisher, $fe[0].build, $fe[0].group) -join '|')
    Assert-Equal 'an unblock entry for a program is root-based too' ('fwunblock|C:\Program Files\Blocked App|' + $byRootKeys) (($fe[1].action, $fe[1].root, (($fe[1].PSObject.Properties.Name | Sort-Object) -join ',')) -join '|')
    Assert-Equal 'an unblock entry for a stray row is by rule NAME, with the script''s keys' $byNameKeys (($fe[2].PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-Equal 'naming the rules and the folder they must live under' 'fwunblockrules|4|C:\Program Files (x86)\Common Files\Adobe|Application Block' (($fe[2].action, @($fe[2].rules).Count, $fe[2].folder, $fe[2].group) -join '|')
    # the batch summary, foreign count and detail view on synthetic rows
    Assert-Equal 'the firewall summary counts what was actually new, skipped, removed and idle - in real plurals' '6 new rules added, 5 executables already blocked, skipped, 4 rules removed, 1 program had nothing to do' $j.fwSummary[0]
    Assert-Equal 'and falls back to the plain count when no row carried a number' '1 completed, 0 failed' $j.fwSummary[1]
    Assert-Equal 'foreign rules: one under the program, one named by the stray, none for an untouched program' '1,1,0' (@($j.fwForeign) -join ',')
    Assert-Equal 'the blocked detail: one line per executable, who made the rule, what is switched off' 'c:\program files\blocked app\a.exe    (1 rule, this tool)|c:\program files\blocked app\sub\b.exe    (1 rule, another tool, 1 switched OFF)' (@($j.fwDetail) -join '|')

    # the catalog, by the script's rules
    $m = (Get-Content -LiteralPath (Join-Path $repo 'server\apps.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $seen = @{}; $wantIds = @()
    foreach ($a in @($m.apps)) {
        if ($a.uninstallOnly) { continue }
        $id = ('' + $a.id).Trim()
        if (-not $id -or $seen.ContainsKey($id)) { continue }
        if (-not ('' + $a.url).Trim() -or ('' + $a.url) -notmatch '^(?i)(https?|file)://') { continue }
        if (('' + $a.sha256) -notmatch '^(?i)[0-9a-f]{64}$') { continue }
        $seen[$id] = $true; $wantIds += $id
    }
    Assert-Equal 'the exe accepts exactly the rows Load-Catalog accepts' ($wantIds -join ',') (@($j.catalogIds) -join ',')
    Assert-Equal 'and skips the rest with a reason each' (@($m.apps | Where-Object { -not $_.uninstallOnly }).Count - $wantIds.Count) @($j.catalogSkipped).Count
    $cats = @($m.categories)
    foreach ($c in @($j.catalogRows | ForEach-Object { $_.category } | Select-Object -Unique)) { if ($cats -notcontains $c) { $cats += $c } }
    Assert-Equal 'the rail is the catalog''s categories list, unlisted ones appended' ($cats -join '|') (@($j.catalogCategories) -join '|')
    $order = @{}; for ($i = 0; $i -lt $cats.Count; $i++) { $order[$cats[$i]] = $i }
    $ranks = @($j.catalogRows | ForEach-Object { $order[$_.category] })
    Assert-True 'rows come grouped in rail order' ((@($ranks | Sort-Object) -join ',') -eq ($ranks -join ','))
    foreach ($row in $j.catalogRows) {
        $src = @($m.apps) | Where-Object { $_.id -eq $row.id } | Select-Object -First 1
        Assert-Equal "size text for $($row.id) matches Format-Size" (Format-Size ([long]$src.sizeBytes)) $row.size
        Assert-Equal "file name for $($row.id) comes from the url" ([IO.Path]::GetFileName(([Uri][string]$src.url).LocalPath)) $row.fileName
        Assert-Equal "sha256 for $($row.id) is upper-cased" (('' + $src.sha256).ToUpper()) $row.sha256
    }

    # ============================================================== 3. a real launch
    Write-Section '3. A real launch against a loopback edge'
    # The exe and the script share one single-instance mutex. While a client is open on this
    # desktop, a launch here would only raise "already running" on the technician's screen three
    # times over; say so and skip - that is a state of the desktop, not a verdict on the build.
    $clientOpen = $false
    try { $mx = [Threading.Mutex]::OpenExisting('Local\PC2GoAppInstaller'); $mx.Dispose(); $clientOpen = $true } catch { }
    if ($clientOpen) {
        $script:Skipped = 'the launch section: a PC2Go App Installer (the exe or the script) is open on this desktop - close it and rerun'
        Write-Host ('  SKIP  ' + $script:Skipped) -ForegroundColor Yellow
    } else {
    $port = 18800 + (Get-Random -Maximum 150)
    $json = [IO.File]::ReadAllBytes((Join-Path $repo 'server\apps.json'))
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $hits = New-Object Collections.ArrayList
    $logDir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy-Logs'
    $cacheDir = Join-Path $env:LOCALAPPDATA 'PC2GoDeploy'
    $crashBefore = @(Get-ChildItem $cacheDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue | ForEach-Object Name)
    $iconDir = Join-Path $cacheDir 'icons'
    $missBefore = @(Get-ChildItem $iconDir -Filter '*.miss' -ErrorAction SilentlyContinue | ForEach-Object Name)

    # ONE pending GetContextAsync across runs. A fresh one per run left the previous run's still
    # waiting, and it swallowed the next run's catalog request - which then went unanswered.
    $script:CtxTask = $null
    function Invoke-ClientRun([string]$Switches, [int]$Status = 200, [string]$WaitFor = 'Catalog loaded', [int]$WaitSec = 25) {
        # session logs are named to the second, and a launch inside the previous run's second
        # appends to its file instead of opening one this loop would notice
        Start-Sleep -Milliseconds 1100
        $before = @(Get-ChildItem $logDir -Filter 'session-*.log' -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $proc = Start-Process -FilePath $exe -ArgumentList "-BaseUrl http://127.0.0.1:$port -NoSelfElevate -KeepCache $Switches" -PassThru
        $deadline = (Get-Date).AddSeconds($WaitSec)
        $logPath = $null; $seen = $false
        while ((Get-Date) -lt $deadline -and -not $seen -and -not $proc.HasExited) {
            if ($null -eq $script:CtxTask) { $script:CtxTask = $listener.GetContextAsync() }
            $ctxTask = $script:CtxTask
            while (-not $ctxTask.Wait(150)) {
                if ($proc.HasExited -or (Get-Date) -ge $deadline) { break }
                if (-not $logPath) {
                    $new = @(Get-ChildItem $logDir -Filter 'session-*.log' -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName })
                    if ($new.Count) { $logPath = $new[0].FullName }
                }
                if ($logPath -and (Select-String -Path $logPath -Pattern $WaitFor -Quiet)) { $seen = $true; break }
            }
            if ($ctxTask.IsCompleted) {
                $ctx = $ctxTask.Result
                $script:CtxTask = $null
                [void]$hits.Add([pscustomobject]@{ Url = $ctx.Request.RawUrl; Code = ('' + $ctx.Request.Headers['x-pc2go-code']); Enc = ('' + $ctx.Request.Headers['Accept-Encoding']); UA = $ctx.Request.UserAgent })
                if ($Status -eq 403) {
                    $ctx.Response.StatusCode = 403
                    $ctx.Response.Headers['x-pc2go-auth'] = 'required'
                } elseif ($ctx.Request.RawUrl -eq '/apps.json') {
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.OutputStream.Write($json, 0, $json.Length)
                } else { $ctx.Response.StatusCode = 404 }
                $ctx.Response.Close()
            }
        }
        if (-not $seen -and $logPath) { Start-Sleep -Milliseconds 800; $seen = [bool](Select-String -Path $logPath -Pattern $WaitFor -Quiet) }
        $exited = $false
        if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; $exited = $proc.WaitForExit(8000); if (-not $exited) { $proc.Kill() } } else { $exited = $true }
        return [pscustomobject]@{ Seen = $seen; Log = $(if ($logPath) { Get-Content $logPath -Raw } else { '' }); Exited = $exited; ExitedEarly = ($proc.HasExited -and -not $seen) }
    }

    $hits.Clear()
    $run = Invoke-ClientRun ''
    Assert-True  'the window comes up and the catalog loads from the loopback edge' $run.Seen
    Assert-True  'the catalog request carried the client''s user agent' (@($hits | Where-Object { $_.Url -eq '/apps.json' -and $_.UA -eq 'PC2GoDeploy/1.0' }).Count -ge 1)
    Assert-True  'and asked for gzip' (@($hits | Where-Object { $_.Url -eq '/apps.json' -and $_.Enc -match 'gzip' }).Count -ge 1)
    Assert-True  'and sent no code, because none was given' (@($hits | Where-Object { $_.Url -eq '/apps.json' -and $_.Code -eq '' }).Count -ge 1)
    Assert-True  'the session log names the build, the machine and the server' ($run.Log -match 'PC2Go App Installer \(client \d+\)' -and $run.Log -match 'Server    : http://127\.0\.0\.1')
    Assert-True  'skipped entries are explained one per line' ($run.Log -match 'Catalog entry skipped - .*sha256 is missing')
    Assert-True  'the window closes cleanly from its close button' $run.Exited

    $hits.Clear()
    $env:PC2GO_CODE = 'test-code-1234'
    try { $run = Invoke-ClientRun '' } finally { $env:PC2GO_CODE = '' }
    Assert-True  'a code in the environment travels as the x-pc2go-code header' (@($hits | Where-Object { $_.Url -eq '/apps.json' -and $_.Code -eq 'test-code-1234' }).Count -ge 1)
    Assert-True  'and the catalog still loads' $run.Seen

    $hits.Clear()
    $run = Invoke-ClientRun '' 403 'refused this session''s access code'
    Assert-True  'a 403 marked x-pc2go-auth is reported as an access-code problem, not a network one' $run.Seen
    Assert-True  'and the window stays up to say so' (-not $run.ExitedEarly)

    $crashAfter = @(Get-ChildItem $cacheDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue | Where-Object { $crashBefore -notcontains $_.Name })
    Assert-Equal 'no crash file was written by any run' 0 $crashAfter.Count
    # The three windows above closed within a second of their catalog - before their logos had
    # arrived. Until client 16 that wrote a .miss per logo into the icon cache the REAL launches
    # share, remembered for a day: the technician's own client then showed letters instead of
    # logos (2026-09-05, four misses at 13:15:30 from this very section). A miss now records only a
    # server's 404, keyed by the URL - so no run here may leave one for a logo the edge serves.
    $missNew = @(Get-ChildItem $iconDir -Filter '*.miss' -ErrorAction SilentlyContinue | Where-Object { $missBefore -notcontains $_.Name } | ForEach-Object Name)
    $catIcons = @((Get-Content -LiteralPath (Join-Path $repo 'server\apps.json') -Raw | ConvertFrom-Json).apps | Where-Object { $_.iconUrl })
    $wrongMiss = @(foreach ($a in $catIcons) {
        if ($missNew -contains ((Get-IconCacheName $a.id $a.iconUrl) + '.miss')) {
            try { if ((Invoke-WebRequest -Uri $a.iconUrl -Method Head -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200) { $a.id } } catch { }
        }
    })
    Assert-Equal 'a window closed before its logos arrived left no miss for a logo the server serves - the next launch asks again' 0 $wrongMiss.Count
    Assert-Equal 'and no id-keyed miss, the kind that hid the logos, is left in the shared cache' 0 @(Get-ChildItem $iconDir -Filter '*.miss' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notmatch '-[0-9a-f]{8}$' }).Count
    $listener.Stop()
    }

    # ============================================================== 4. the bootstrap and the edge
    Write-Section '4. go.ps1, the Worker, wrangler.toml and Publish know about the exe'
    $goPath = Join-Path $repo 'server\go.ps1'
    $goTxt = Get-Content -LiteralPath $goPath -Raw
    Assert-True 'go.ps1 declares the client kind and the exe pin for the edge to rewrite' ($goTxt -match "(?m)^\`$Client = 'script'" -and $goTxt -match "(?m)^\`$ExeHash = 'PINNED_EXE_SHA256_GOES_HERE'")
    Assert-True 'the exe is fetched by the same key the Worker serves' ($goTxt -match "\`$key = 'PC2Go\.Deploy\.exe'")
    Assert-True 'the exe is launched with the tool''s own switches, no interpreter in between' ($goTxt -match '\$launch = "-BaseUrl `"\$BaseUrl`"\$extra"')
    Assert-Equal 'both launches go through $launchExe' 2 @([regex]::Matches($goTxt, 'Start-Process -FilePath \$launchExe')).Count
    # the choice, evaluated with the bootstrap's own lines
    $chooseAt = $goTxt.IndexOf('$useExe = ')
    $chooseEnd = $goTxt.IndexOf("`n", $goTxt.IndexOf('if ($useExe) { $tool = $exe'))
    $choose = $goTxt.Substring($chooseAt, $chooseEnd - $chooseAt)
    function Test-Choice([string]$Client, [string]$ExeHash) {
        $ps1 = 'X:\AppDeploy.ps1'; $exe = 'X:\PC2Go.Deploy.exe'; $PinnedHash = ('1' * 64); $pinned = $true
        . ([scriptblock]::Create($choose))
        return "$tool|$want|$key|$toolPinned"
    }
    Assert-Equal 'exe + real pin -> the exe, its pin, its key' "X:\PC2Go.Deploy.exe|$('a' * 64)|PC2Go.Deploy.exe|True" (Test-Choice 'exe' ('a' * 64))
    Assert-Equal 'exe + no pin -> the script (never an unverified exe)' "X:\AppDeploy.ps1|$('1' * 64)|AppDeploy.ps1|True" (Test-Choice 'exe' 'PINNED_EXE_SHA256_GOES_HERE')
    Assert-Equal 'script -> the script, whatever the exe pin says' "X:\AppDeploy.ps1|$('1' * 64)|AppDeploy.ps1|True" (Test-Choice 'script' ('a' * 64))

    $wjs = Get-Content -LiteralPath (Join-Path $repo 'cloudflare\worker.js') -Raw
    Assert-True 'the Worker gates the exe behind the access code' ($wjs -match '\|\| path === "/PC2Go\.Deploy\.exe"\) \{')
    Assert-True 'and serves it from the bucket'                    ($wjs -match 'serveObject\(request, env, "PC2Go\.Deploy\.exe"')
    Assert-True 'and rewrites $Client and $ExeHash into the bootstrap' ($wjs -match '\\\$Client\\s\*=' -and $wjs -match '\\\$ExeHash\\s\*=')
    Assert-True 'and only injects a 64-hex exe pin'                 ($wjs -match 'CLIENT_EXE_SHA256[\s\S]{0,200}\^\[0-9A-F\]\{64\}\$')
    Assert-True '/go-exe forces the exe for a trial run'            ($wjs -match 'path === "/go-exe"\) return await serveBootstrap\(env, url, "exe"\)')
    $toml = Get-Content -LiteralPath (Join-Path $repo 'cloudflare\wrangler.toml') -Raw
    Assert-True 'wrangler.toml carries BOOT_CLIENT and CLIENT_EXE_SHA256' ($toml -match '(?m)^BOOT_CLIENT = "(script|exe)"' -and $toml -match '(?m)^CLIENT_EXE_SHA256 = "[0-9A-F]*"')
    $pub = Get-Content -LiteralPath (Join-Path $repo 'tools\Publish-Release.ps1') -Raw
    Assert-True 'Publish -Client uploads the exe under the key the Worker serves' ($pub -match "Key = 'PC2Go\.Deploy\.exe'; Type = 'application/octet-stream'")
    Assert-True 'and pins CLIENT_EXE_SHA256'                          ($pub -match 'CLIENT_EXE_SHA256\\s\*=\\s\*\)"\[\^"\]\*"')
    Assert-True 'and refuses an exe pin line that is not there'      ($pub -match 'No CLIENT_EXE_SHA256 line')
    Assert-True 'and keeps the two new anchors through stripping'    ($pub -match '\\\$Client\\s\*=' -and $pub -match '\\\$ExeHash\\s\*=')
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("PASS {0}   FAIL {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Skipped) { Write-Host ('SKIPPED ' + $script:Skipped) -ForegroundColor Yellow }
if ($script:Fail) { exit 1 }
