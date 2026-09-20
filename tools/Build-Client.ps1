<#
.SYNOPSIS
    Builds the compiled client: client\dist\PC2Go.Deploy.exe.

.DESCRIPTION
    Three steps, each one honest about where the truth lives:

      1. The elevated worker is lifted out of server\AppDeploy.ps1 - the $workerScript here-string
         with its three placeholders rendered exactly the way Start-Worker renders them - and
         written to client\PC2Go.Deploy\Resources\worker.ps1, which the project embeds. The script
         stays the single source of the worker until the worker moves into its own file; this
         build never edits it and never keeps a second copy under version control.
      2. dotnet build, Release, .NET Framework 4.8 (in-box on every Windows 10/11 client).
      3. The exe is copied to client\dist, signed if a certificate thumbprint is given, and hashed.
         The SHA-256 printed here is what Publish-Release.ps1 pins at the edge.

    Dot-source this file to get Get-RenderedWorker without building (the tests do).

.PARAMETER SignThumbprint
    Thumbprint of a code-signing certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My.
    Without it the exe ships unsigned and the edge pin is the only trust root - exactly as it is
    for the script today.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Configuration = 'Release',
    [string]$SignThumbprint,
    [string]$DotnetPath,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

function Get-RenderedWorker([string]$DeployPath) {
    <#
        Start-Worker does three String.Replace calls on $workerScript. Their inputs are script-scope
        tables and functions defined at the top level of AppDeploy.ps1, so those definitions are
        lifted by AST and evaluated in a fresh PowerShell - nothing else from the script runs.
    #>
    $text = [IO.File]::ReadAllText($DeployPath)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "AppDeploy.ps1 does not parse: $($errors[0].Message)" }

    $assignments = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $false))
    $byName = @{}
    foreach ($a in $assignments) {
        $left = $a.Left.Extent.Text
        if ($left -match '^\$(script:)?(workerScript|NvApiSource|DebloatPacks|OemBloatPatterns|InstallerFamilyLabels|InstallerIdentityMarkers|InstallerFamilyFunctions)$') {
            if (-not $byName.ContainsKey($Matches[2])) { $byName[$Matches[2]] = $a }
        }
    }
    foreach ($need in 'workerScript', 'NvApiSource', 'DebloatPacks', 'OemBloatPatterns', 'InstallerFamilyLabels', 'InstallerIdentityMarkers', 'InstallerFamilyFunctions') {
        if (-not $byName.ContainsKey($need)) { throw "Could not find the `$$need assignment in AppDeploy.ps1" }
    }

    # the function names the family renderer emits come from the array literal itself
    $famNames = @()
    foreach ($el in $byName['InstallerFamilyFunctions'].Right.Expression.SubExpression.Statements[0].PipelineElements[0].Expression.Elements) {
        $famNames += $el.Value
    }
    $wanted = @('Get-SharedTablesSource', 'Get-InstallerFamilySource') + $famNames
    $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $false))
    $defs = @{}
    foreach ($f in $funcs) { if ($wanted -contains $f.Name -and -not $defs.ContainsKey($f.Name)) { $defs[$f.Name] = $f.Extent.Text } }
    foreach ($w in $wanted) { if (-not $defs.ContainsKey($w)) { throw "Could not find function $w in AppDeploy.ps1" } }

    $lines = @()
    foreach ($n in 'workerScript', 'NvApiSource', 'DebloatPacks', 'OemBloatPatterns', 'InstallerFamilyLabels', 'InstallerIdentityMarkers', 'InstallerFamilyFunctions') {
        $lines += $byName[$n].Extent.Text
    }
    foreach ($w in $wanted) { $lines += $defs[$w] }
    # the three replaces, verbatim from Start-Worker
    $lines += '$nvAssign = "`$NvApiSrc = @''" + [Environment]::NewLine + $script:NvApiSource + [Environment]::NewLine + "''@"'
    $lines += '$workerScript.Replace(''#__NVAPISOURCE__'', $nvAssign).Replace(''#__SHAREDTABLES__'', (Get-SharedTablesSource)).Replace(''#__INSTALLERFAMILY__'', (Get-InstallerFamilySource))'
    $script = $lines -join [Environment]::NewLine

    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript($script)
        $out = @($ps.Invoke())
        if ($ps.Streams.Error.Count) { throw "Rendering the worker failed: $($ps.Streams.Error[0].Exception.Message)" }
    } finally { $ps.Dispose() }
    $built = [string]$out[0]
    foreach ($ph in '#__NVAPISOURCE__', '#__SHAREDTABLES__', '#__INSTALLERFAMILY__') {
        if ($built.Contains($ph)) { throw "The rendered worker still contains $ph" }
    }

    # A command the worker CALLS but does not DEFINE, whose name is a function defined in the GUI
    # half of AppDeploy.ps1, is a bug that already shipped once: Get-SafeUserSid called Add-Log,
    # which lives outside the here-string, so its refusal path threw CommandNotFound and FAILED the
    # row instead of refusing it - on every row of every batch, on any machine that reached it. The
    # worker is one flat script handed to an elevated powershell.exe: if it calls it, it has to
    # contain it, and the place to find that out is here rather than on a customer's PC.
    $wt = $null; $we = $null
    $wast = [System.Management.Automation.Language.Parser]::ParseInput($built, [ref]$wt, [ref]$we)
    if ($we.Count) { throw "The rendered worker does not parse: $($we[0].Message) (worker line $($we[0].Extent.StartLineNumber))" }
    $fnAst = { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    $has = @{}
    foreach ($f in $wast.FindAll($fnAst, $true)) { $has[$f.Name] = $true }
    $guiOnly = @{}
    foreach ($f in $ast.FindAll($fnAst, $true)) { if (-not $has.ContainsKey($f.Name)) { $guiOnly[$f.Name] = $true } }
    $missing = @{}
    foreach ($c in $wast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $nm = $c.GetCommandName()
        if ($nm -and $guiOnly.ContainsKey($nm) -and -not $missing.ContainsKey($nm)) { $missing[$nm] = $c.Extent.StartLineNumber }
    }
    if ($missing.Count) {
        $list = (@($missing.Keys | Sort-Object) | ForEach-Object { "$_ (worker line $($missing[$_]))" }) -join ', '
        throw "The rendered worker calls $($missing.Count) function(s) that exist only in the GUI half of AppDeploy.ps1: $list"
    }
    return $built
}

function Get-RenderedReader([string]$DeployPath) {
    <#
        The Uninstall tab's reads - the Control Panel inventory, the Store package list, the
        leftover sweep - are the script's own functions, lifted here into a small script the exe
        runs in a hidden powershell.exe. Nothing is re-implemented: Get-InstalledPrograms decides
        what a program is, Get-UninstallFamily decides its quiet switch, Scan-Leftovers decides
        what a leftover is, exactly as they do in the script client. The closure below is every
        top-level function those roots call, found by AST, plus the tables they read.

        Update-UI and Invoke-OffUi are stubbed: there is no window here, and the whole point of
        running in another process is that nothing needs pumping.
    #>
    $text = [IO.File]::ReadAllText($DeployPath)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "AppDeploy.ps1 does not parse: $($errors[0].Message)" }
    $funcs = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $false)) {
        if (-not $funcs.ContainsKey($f.Name)) { $funcs[$f.Name] = $f }
    }
    $roots = @('Get-InstalledPrograms', 'Get-StoreApps', 'Scan-Leftovers', 'Get-CleanNameTokens', 'Get-RowId',
               'Get-UpdateNameKey', 'Get-UpdateExeFromFolder', 'Get-StartMenuExe', 'Format-Size',
               'Resolve-OdisManifest', 'ConvertTo-PSRegPath', 'Get-InstallerFamilyLabel', 'Clean-DisplayName',
               # the Update tab: winget's own table parsed by the script's parser, the program match, Windows Update
               'Get-WingetPath', 'Get-WingetUpgradeText', 'Get-WingetUpgrades', 'Get-UpdateProgramLookup',
               'Find-UpdateMatch', 'Get-WindowsUpdateList',
               # the User Accounts tab: the profile list, the local accounts and who is an Administrator
               'Get-UserProfiles', 'Get-AdminMembers', 'Get-AccountPurpose', 'Get-LocalAccounts',
               # the Data Backup tab: folder sizes, this PC's shares, and finding the other PC
               'Get-FolderSize', 'Get-AllShares', 'Get-LocalIPv4', 'Get-LocalSubnets', 'Resolve-HostLabel',
               'Get-HostShares', 'Find-NetworkHosts',
               # the Optimize tab: the per-row detectors (named here because they are called from
               # scriptblocks in $script:TweakTests, which the closure walk cannot see)
               'Test-RegVal', 'Get-RegVal', 'Test-AppxAbsent',
               # the Firewall tab: the rule map and Load-Firewall's helpers - where a program lives,
               # which rules sit under it, which roots may never be blocked, a stray's vendor folder
               'Get-FirewallBlockMap', 'Resolve-AppRoot', 'Get-RulesUnder', 'Test-FwRootAllowed', 'Get-VendorFolder',
               # the Optimize tab's Startup sub-tab: what starts with Windows, and Task Manager's verdict on each
               'Get-StartupEntries',
               # the Toolbox's Disk Management sub-tab: every disk as Disk Management draws it, plus shrink room and the gap behind each volume
               'Get-DiskLayout',
               # the Optimize tab's Gaming sub-tab: the two detector helpers its rows call from $script:TweakTests
               # (the AC power index of the active scheme, an NVIDIA DRS setting through NVAPI), and the
               # latency probe itself - the script's own measuring instrument, run unelevated as it is there
               'Test-GameAcIndex', 'Test-NvSetting', 'Measure-GamingLatency', 'Get-Percentile')
    # Add-Log too: the rule read logs its own failure, and the script's Add-Log writes to the window
    $stubbed = @('Update-UI', 'Invoke-OffUi', 'Add-Log')
    $need = New-Object Collections.Generic.List[string]
    $queue = New-Object Collections.Generic.Queue[string]
    foreach ($r in $roots) { $queue.Enqueue($r) }
    while ($queue.Count) {
        $n = $queue.Dequeue()
        if ($need.Contains($n) -or $stubbed -contains $n) { continue }
        if (-not $funcs.ContainsKey($n)) { throw "Reader needs function $n, which AppDeploy.ps1 does not define at top level" }
        $need.Add($n)
        foreach ($c in $funcs[$n].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($name -and $funcs.ContainsKey($name) -and -not $need.Contains($name)) { $queue.Enqueue($name) }
        }
    }
    $varNames = @('InstallerFamilyLabels', 'InstallerIdentityMarkers', 'ProtectedPaths', 'SharedComponentHints', 'StartMenuLinks', 'MigrateDefs',
                  'TweakDefs', 'DebloatPacks', 'OemBloatPatterns', 'TweakTests', 'FwGroup', 'FwProtectedRoots', 'DiagRemedies',
                  # the NVAPI type source Test-NvSetting compiles on first use, and its "is NVAPI up" memo
                  'NvApiSource', 'NvGuiReady')
    $vars = @()
    foreach ($v in $varNames) {
        $a = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$script:' + $v) -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $false) | Select-Object -First 1
        if (-not $a) { throw "Reader needs `$script:$v, which AppDeploy.ps1 does not assign at top level" }
        $vars += $a.Extent.Text
    }
    # the two native pieces the reads lean on: SHLoadIndirectString for Store names, and the
    # WipeItem class Scan-Leftovers instantiates (lifted out of the script's own type block)
    $shl = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and $n.Extent.Text.Contains('SHLoadIndirectString') }, $true) | Select-Object -First 1
    if (-not $shl) { throw 'Reader needs the SHLoadIndirectString Add-Type, which was not found' }
    $wipeAt = $text.IndexOf('public class WipeItem {')
    if ($wipeAt -lt 0) { throw 'Reader needs the WipeItem class, which was not found' }
    $wipeEnd = $text.IndexOf("`n}", $wipeAt)
    $wipeClass = $text.Substring($wipeAt, $wipeEnd + 2 - $wipeAt)

    $lines = @()
    $lines += 'param([string]$Op, [string]$In, [string]$Out, [string]$Progress)'
    $lines += '$ErrorActionPreference = ''Continue'''
    $lines += 'function Update-UI { }'
    $lines += 'function Invoke-OffUi([scriptblock]$Script, [object[]]$Arguments = @(), [int]$TimeoutSec = 120, [string]$What = ''The read'') { return @(& $Script @Arguments) }'
    $lines += 'function Add-Log([string]$Message) { try { [Console]::Error.WriteLine($Message) } catch { } }'
    $lines += '$script:ScanLabel = '''''
    # what the update reads expect from the window's script scope: no fresh Uninstall list to
    # borrow (so the program lookup takes its own registry scan), no Store list in memory, and a
    # cache folder for winget's output files
    $lines += '$script:CacheDir = $(if ($Out) { Split-Path -Parent $Out } else { $env:TEMP })'
    $lines += '$script:UnDirty = $true; $script:UnItems = @(); $script:UnStore = @(); $script:StoreDirty = $true; $script:UpdStore = @()'
    $lines += '$script:UpdProgCache = $null; $script:UpdProgCacheAt = Get-Date; $script:WingetPath = ''''; $script:WingetScanNotes = @()'
    $lines += '$script:ShareTag = ''PC2Go share''; $script:NetHits = @()'
    # the latency probe narrates into the window's hint line ($TxtTweakHint.Text = ...): here that line
    # is a stand-in whose setter writes the progress file, so the exe shows the same words as it runs
    $lines += '$TxtTweakHint = New-Object psobject; $TxtTweakHint | Add-Member NoteProperty _t ''''; $TxtTweakHint | Add-Member ScriptProperty Text { $this._t } { param($v) $this._t = [string]$v; try { Write-Progress-File ([string]$v) } catch { } }'
    $lines += $shl.Extent.Text
    $lines += 'Add-Type -TypeDefinition (("using System;" + [Environment]::NewLine) + @'''
    $lines += $wipeClass
    $lines += '''@) -ErrorAction SilentlyContinue'
    $lines += $vars
    foreach ($n in $need) { $lines += $funcs[$n].Extent.Text }
    $lines += @'
function Write-Progress-File([string]$Text) {
    if ($Progress) { try { [IO.File]::WriteAllText($Progress, $Text, (New-Object Text.UTF8Encoding $false)) } catch { } }
}
$result = $null
switch ($Op) {
    'installed' {
        $rows = @(Get-InstalledPrograms)
        $result = @(foreach ($r in $rows) {
            $srcs = @($r.Icon, $r.Exe)
            if (-not $r.Icon -and (-not $r.Exe -or $r.Exe -match '(?i)^(.*\\)?(msiexec|winget)(\.exe)?$' -or $r.Exe -match '(?i)^winget ')) {
                $k = Get-UpdateNameKey $r.Name
                $own = Get-UpdateExeFromFolder ([string]$r.Location) $k
                if (-not $own) { $own = Get-StartMenuExe $k }
                if ($own) { $srcs = @($own) + $srcs }
            }
            [pscustomobject]@{
                Id = (Get-RowId 'reg' $r.RegKey); Name = (Clean-DisplayName $r.Name); Version = (Clean-DisplayName $r.Version)
                Publisher = (Clean-DisplayName $r.Publisher); Location = ('' + $r.Location); Exe = ('' + $r.Exe); Args = ('' + $r.Args)
                Family = ('' + $r.Family); FamilyLabel = $(if ($r.Family) { Get-InstallerFamilyLabel $r.Family } else { '' })
                Silent = [bool]$r.Silent; SizeKB = [long]$r.SizeKB
                Installed = $(if ($r.Installed) { ([datetime]$r.Installed).ToString('yyyy-MM-dd') } else { '' })
                RegKey = ('' + $r.RegKey); CleanTokens = @(Get-CleanNameTokens $r.Name); IconSources = @($srcs | Where-Object { $_ })
            }
        })
    }
    'store' {
        $result = @(foreach ($s in @(Get-StoreApps)) {
            [pscustomobject]@{ Name = ('' + $s.Name); Version = ('' + $s.Version); Publisher = ('' + $s.Publisher); Location = ('' + $s.Location)
                               Logo = ('' + $s.Logo); PackageFull = ('' + $s.PackageFull); IsSystem = [bool]$s.IsSystem }
        })
    }
    'leftovers' {
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $targets = @($req.targets)
        $found = New-Object Collections.ArrayList
        $i = 0
        foreach ($t in $targets) {
            $i++
            $label = "Scanning $($t.name)  ($i of $($targets.Count))"
            $stage = { param($what) Write-Progress-File ($label + '  -  ' + $what) }.GetNewClosure()
            Write-Progress-File $label
            $item = [pscustomobject]@{
                Id = ('' + $t.id); Name = ('' + $t.name)
                CleanPaths = @($t.cleanPaths | Where-Object { $_ }); CleanReg = @($t.cleanReg | Where-Object { $_ })
                CleanTokens = @($t.cleanTokens | Where-Object { $_ }); CleanHosts = @($t.cleanHosts | Where-Object { $_ })
                Removers = @($t.removers | Where-Object { $_ }); CreatedPaths = @($t.createdPaths | Where-Object { $_ })
                PreExisting = [bool]$t.preExisting
            }
            try { foreach ($f in @(Scan-Leftovers $item (-not $item.PreExisting) $stage $null)) { [void]$found.Add($f) } }
            catch { Write-Error ("scan of " + $item.Name + " failed: " + $_.Exception.Message) }
        }
        $result = @(foreach ($w in $found) {
            [pscustomobject]@{ OwnerId = $w.OwnerId; OwnerName = $w.OwnerName; Kind = $w.Kind; Type = $w.Type; Path = $w.Path; Name = $w.Name
                               SizeBytes = [long]$w.SizeBytes; SizeText = $w.SizeText; Del = [bool]$w.Del; Args = $w.Args; Sha256 = $w.Sha256
                               Weak = [bool]$w.Weak; Shared = [bool]$w.Shared; IsDir = [bool]$w.IsDir }
        })
    }
    'winget' {
        $exe = Get-WingetPath
        $rows = @()
        if ($exe) {
            $found = @(Get-WingetUpgrades (Get-WingetUpgradeText))
            $lookup = @(Get-UpdateProgramLookup)
            # the Store list, for the rows winget updates on the Store's behalf - the window has
            # none in memory here, so it is read once (a second or so) rather than guessed
            $storeLookup = @()
            try {
                foreach ($s in @(Get-StoreApps)) {
                    $storeLookup += [pscustomobject]@{ Key = (Get-UpdateNameKey $s.Name); Name = $s.Name; Publisher = $s.Publisher; Icon = ''; Exe = ''; Image = $null
                                                       Location = ('' + $s.Location); Logo = ('' + $s.Logo) }
                }
            } catch { }
            foreach ($r in $found) {
                $m = Find-UpdateMatch $r.Name $lookup
                $sm = $null
                if (-not $m) { $sm = Find-UpdateMatch $r.Name $storeLookup }
                $rows += [pscustomobject]@{
                    Name = ('' + $r.Name); Id = ('' + $r.Id); Version = ('' + $r.Version); Available = ('' + $r.Available)
                    Source = ('' + $r.Source); Explicit = [bool]$r.Explicit; RowId = (Get-RowId 'upd' $r.Id)
                    Match = $(if ($m) { [pscustomobject]@{ Publisher = ('' + $m.Publisher); Icon = ('' + $m.Icon); Exe = ('' + $m.Exe) } } else { $null })
                    StoreMatch = $(if ($sm) { [pscustomobject]@{ Publisher = ('' + $sm.Publisher); Location = ('' + $sm.Location); Logo = ('' + $sm.Logo) } } else { $null })
                }
            }
        }
        $result = @{ winget = ('' + $exe); notes = @($script:WingetScanNotes | ForEach-Object { '' + $_ }); rows = $rows }
    }
    'winupdate' {
        $result = @(foreach ($w in @(Get-WindowsUpdateList)) {
            [pscustomobject]@{ Id = ('' + $w.Id); RowId = (Get-RowId 'wu' $w.Id); Rev = [int]$w.Rev; Title = ('' + $w.Title); KB = ('' + $w.KB); Category = ('' + $w.Category)
                               Size = [long]$w.Size; Optional = [bool]$w.Optional; Driver = [bool]$w.Driver; Reboot = [bool]$w.Reboot
                               Downloaded = [bool]$w.Downloaded; Mandatory = [bool]$w.Mandatory; AutoSelect = [bool]$w.AutoSelect; Deployment = [int]$w.Deployment }
        })
    }
    'accounts' {
        # Load-Users' two reads, and the signed-in name the worker cannot see for itself
        $me = ''; try { $me = [Environment]::UserName } catch { }
        $profiles = @(Get-UserProfiles)
        $accounts = @(Get-LocalAccounts)
        $result = @{
            me = $me
            profiles = @(foreach ($p in $profiles) { [pscustomobject]@{ Sid = ('' + $p.Sid); Name = ('' + $p.Name); Path = ('' + $p.Path) } })
            accounts = @(foreach ($a in $accounts) {
                [pscustomobject]@{ Sid = ('' + $a.Sid); Name = ('' + $a.Name); FullName = ('' + $a.FullName); Enabled = [bool]$a.Enabled
                                   IsAdmin = [bool]$a.IsAdmin; IsBuiltin = [bool]$a.IsBuiltin; Kind = ('' + $a.Kind); Purpose = ('' + (Get-AccountPurpose $a.Sid)) }
            })
        }
    }
    'migrateitems' {
        # Invoke-ReplaceWithLocal's pick: the safe defaults that actually exist under the profile
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $base = '' + $req.path
        $result = @{ items = @(foreach ($d in $script:MigrateDefs) {
            if (-not $d.safe) { continue }
            if ($base -and (Test-Path -LiteralPath (Join-Path $base $d.id))) { '' + $d.id }
        }) }
    }
    'migratedefs' {
        # the table itself, so the client never keeps a second copy of what can be rescued
        $result = @{ items = @(foreach ($d in $script:MigrateDefs) {
            [pscustomobject]@{ id = ('' + $d.id); name = ('' + $d.name); safe = [bool]$d.safe; abs = [bool]$d.abs; file = [bool]$d.file }
        }) }
    }
    'manifest' {
        # Set-BackupFolder's read of pc2go-backup.json: a BOM is not ours, but somebody may have edited it in Notepad
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $mfPath = Join-Path ('' + $req.path) 'pc2go-backup.json'
        $found = [bool](Test-Path -LiteralPath $mfPath)
        $mf = $null
        if ($found) { try { $mf = (Get-Content -LiteralPath $mfPath -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $mf = $null } }
        $result = @{ found = $found; manifest = $mf }
    }
    'foldersize' {
        # the measuring pass: one size per path, the running total in the progress file every 200 folders
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $sizes = @(); $i = 0; $running = [long]0
        foreach ($p in @($req.paths)) {
            $i++
            $tick = { param($sofar) Write-Progress-File "$i|$running|$sofar"; return $true }.GetNewClosure()
            $sz = [long](Get-FolderSize ('' + $p) $tick)
            $sizes += $sz
            $running += $sz
            Write-Progress-File "$i|$running|0"
        }
        $result = @{ sizes = @($sizes) }
    }
    'shares' {
        $result = @{ all = @(foreach ($s in @(Get-AllShares)) { [pscustomobject]@{ Name = ('' + $s.Name); Path = ('' + $s.Path); Description = ('' + $s.Description) } }) }
    }
    'netscan' {
        # the sweep; every PC that answers is written to the progress file the moment it does
        $script:NetHits = @()
        $tick = {
            param($done, $total, $hits)
            $text = "P|$done|$total|$hits"
            if ($script:NetHits.Count) { $text += "`n" + ($script:NetHits -join "`n") }
            Write-Progress-File $text
            return $true
        }
        $onFound = { param($h) $script:NetHits += ('H|' + $h.Ip + '|' + $h.Name) }
        $found = @(Find-NetworkHosts -Tick $tick -TimeoutMs 600 -OnFound $onFound)
        $result = @{ hosts = @(foreach ($h in $found) { [pscustomobject]@{ Ip = ('' + $h.Ip); Name = ('' + $h.Name) } }) }
    }
    'hostshares' {
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $s = Get-HostShares ('' + $req.host)
        $result = @{ ok = ($null -ne $s); shares = @($(if ($null -ne $s) { @($s) } else { @() }) | ForEach-Object { '' + $_ }) }
    }
    'tweakdefs' {
        # the Optimize tables, so the client never keeps a second copy of what a row is
        $result = @{ items = @(foreach ($t in $script:TweakDefs) {
            [pscustomobject]@{ id = ('' + $t.id); name = ('' + $t.name); hint = ('' + $t.hint); tab = ('' + $t.tab); caution = [bool]$t.caution }
        }) }
    }
    'tweakprobe' {
        # the detectors, run as the technician: true = applied, false = not, null = an action, not a state
        $req = (Get-Content -LiteralPath $In -Raw) | ConvertFrom-Json
        $ids = @($req.ids | ForEach-Object { '' + $_ })
        $i = 0
        $result = @{ results = @(foreach ($id in $ids) {
            $i++
            Write-Progress-File "$i|$($ids.Count)"
            $test = $script:TweakTests[$id]
            $r = $null
            if ($test) { try { $r = & $test } catch { $r = $null } }
            if ($null -ne $r -and -not ($r -is [bool])) { $r = [bool]$r }
            [pscustomobject]@{ Id = $id; Result = $r }
        }) }
    }
    'gameprobe' {
        # the Gaming sub-tab's evidence: the script's own latency probe, unelevated, about five seconds;
        # its "measuring..." lines reach the exe's hint through the progress file
        $p = Measure-GamingLatency
        $result = @{ TimerP50 = [double]$p.TimerP50; PreP50 = [double]$p.PreP50; PreP99 = [double]$p.PreP99; PreMax = [double]$p.PreMax
                     Dpc = [double]$p.Dpc; Isr = [double]$p.Isr; When = $p.When.ToString('o') }
    }
    'firewall' {
        # Load-Firewall's scan, with the script's own helpers: the rule map, one row per installed
        # program that lives somewhere blockable, and one row per vendor folder of stray rules
        Write-Progress-File 'Reading firewall rules...'
        $map = Get-FirewallBlockMap
        Write-Progress-File 'Matching against installed programs...'
        $ruleTotal = 0
        foreach ($k in $map.Keys) { $ruleTotal += @($map[$k]).Count }
        $seen = @{}
        $matchedRoots = @()
        $rows = @()
        foreach ($r in @(Get-InstalledPrograms | Where-Object { $_ -and $_.Name })) {
            $root = Resolve-AppRoot $r
            if (-not $root) { continue }
            if (-not (Test-FwRootAllowed $root)) { continue }
            $key = $root.ToLower()
            if ($seen.ContainsKey($key)) { continue }     # several entries share one folder
            $seen[$key] = $true
            $c = Get-RulesUnder $map $root
            # a program's folder owns every rule under it, disabled ones included - those must
            # not fall through to the stray list as if nobody knew what they were
            if ($c.On -or $c.Off) { $matchedRoots += ($key + '\') }
            $rows += [pscustomobject]@{
                Id = (Get-RowId 'fw' $key); Name = (Clean-DisplayName $r.Name); Publisher = (Clean-DisplayName $r.Publisher)
                Root = $root; On = [int]$c.On; Off = [int]$c.Off; Stray = $false; RuleNames = @()
                IconSources = @(@($r.Icon, $r.Exe) | Where-Object { $_ })
            }
        }
        # whatever is left belongs to no installed program - grouped by vendor folder
        $unmatched = @{}
        foreach ($k in $map.Keys) {
            $isMatched = $false
            foreach ($mr in $matchedRoots) { if ($k.StartsWith($mr)) { $isMatched = $true; break } }
            if ($isMatched) { continue }
            $vendor = Get-VendorFolder $k
            if (-not $vendor) { $vendor = $k }
            $vk = $vendor.ToLower()
            if (-not $unmatched.ContainsKey($vk)) { $unmatched[$vk] = @{ Path = $vendor; Rules = @() } }
            $unmatched[$vk].Rules += @($map[$k])
        }
        $orphans = 0
        foreach ($vk in ($unmatched.Keys | Sort-Object)) {
            $grp = $unmatched[$vk]
            $rules = @($grp.Rules)
            $orphans += $rules.Count
            $firstExe = @($map.Keys | Where-Object { $_.StartsWith($vk + '\') } | Select-Object -First 1)
            $rows += [pscustomobject]@{
                Id = (Get-RowId 'fwx' $vk); Name = (Split-Path $grp.Path -Leaf); Publisher = ''
                Root = ('' + $grp.Path); On = [int]$rules.Count; Off = 0; Stray = $true
                RuleNames = @($rules | ForEach-Object { [string]$_.Name }); IconSources = @($firstExe | ForEach-Object { '' + $_ })
            }
        }
        $result = @{ ruleTotal = $ruleTotal; orphans = $orphans; rows = @($rows)
                     rules = @(foreach ($k in $map.Keys) { foreach ($rule in @($map[$k])) {
                         [pscustomobject]@{ Path = ('' + $k); Name = ('' + $rule.Name); Display = ('' + $rule.Display); Group = ('' + $rule.Group); Enabled = [bool]$rule.Enabled } } }) }
    }
    'startupapps' {
        # the entries that start with Windows for THIS account, with Task Manager's enabled/disabled verdict
        $result = @{ items = @(foreach ($e in @(Get-StartupEntries)) {
            [pscustomobject]@{ Name = ('' + $e.Name); Command = ('' + $e.Command); Location = ('' + $e.Location); Enabled = [bool]$e.Enabled; Exe = ('' + $e.Exe) }
        }) }
    }
    'disks' {
        # every disk with its partitions, in offset order, with the shrink floor and the gap behind each
        $result = @{ disks = @(foreach ($d in @(Get-DiskLayout)) {
            [pscustomobject]@{ Number = [int]$d.Number; Name = ('' + $d.Name); Size = [long]$d.Size; Style = ('' + $d.Style); Bus = ('' + $d.Bus); IsBoot = [bool]$d.IsBoot; IsDynamic = [bool]$d.IsDynamic
                               Partitions = @(foreach ($p in @($d.Partitions)) {
                                   [pscustomobject]@{ Number = [int]$p.Number; Offset = [long]$p.Offset; Size = [long]$p.Size; Letter = ('' + $p.Letter); Label = ('' + $p.Label); FileSystem = ('' + $p.FileSystem)
                                                      Free = [long]$p.Free; Kind = ('' + $p.Kind); IsBoot = [bool]$p.IsBoot; IsSystem = [bool]$p.IsSystem; MinSize = [long]$p.MinSize; MaxSize = [long]$p.MaxSize
                                                      GapAfter = [long]$p.GapAfter; IsWinRE = [bool]$p.IsWinRE } }) }
        }) }
    }
    'diagremedies' {
        # what the tool does about each sentence the slow-PC diagnosis can say
        $result = @{ items = @(foreach ($r in $script:DiagRemedies) {
            [pscustomobject]@{ layer = ('' + $r.layer); match = ('' + $r.match); kind = ('' + $r.kind); target = ('' + $r.target); label = ('' + $r.label); note = ('' + $r.note) }
        }) }
    }
    'fwmap' {
        # the live rule table alone - Get-ForeignRuleCount reads it again at confirm time
        $map = Get-FirewallBlockMap
        $result = @{ rules = @(foreach ($k in $map.Keys) { foreach ($rule in @($map[$k])) {
                         [pscustomobject]@{ Path = ('' + $k); Name = ('' + $rule.Name); Display = ('' + $rule.Display); Group = ('' + $rule.Group); Enabled = [bool]$rule.Enabled } } }) }
    }
    default { throw "unknown op '$Op'" }
}
$json = $(if ($result -is [System.Collections.IDictionary]) { ConvertTo-Json -InputObject $result -Depth 6 -Compress }
          elseif ($result.Count) { ConvertTo-Json -InputObject @($result) -Depth 6 -Compress } else { '[]' })
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding $false))
'@
    return ($lines -join [Environment]::NewLine)
}

function Find-Dotnet([string]$Hint) {
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return $Hint }
    $c = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $local = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $pf = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $pf) { return $pf }
    throw 'The .NET SDK was not found. Install it with: irm https://dot.net/v1/dotnet-install.ps1 | iex   (or winget install Microsoft.DotNet.SDK.8)'
}

function Build-Client {
    param([string]$Repo, [string]$Configuration, [string]$SignThumbprint, [string]$DotnetPath)
    $deploy = Join-Path $Repo 'server\AppDeploy.ps1'
    $projDir = Join-Path $Repo 'client\PC2Go.Deploy'
    $proj = Join-Path $projDir 'PC2Go.Deploy.csproj'
    $resDir = Join-Path $projDir 'Resources'
    $dist = Join-Path $Repo 'client\dist'
    foreach ($p in $deploy, $proj) { if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" } }

    Write-Host '== Rendering the elevated worker from AppDeploy.ps1' -ForegroundColor Cyan
    $worker = Get-RenderedWorker $deploy
    New-Item -ItemType Directory -Force -Path $resDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $resDir 'worker.ps1'), $worker, (New-Object Text.UTF8Encoding $false))
    Write-Host ("   {0:N0} characters, {1:N0} lines" -f $worker.Length, ($worker -split "`n").Count)
    Write-Host '== Rendering the reader (Control Panel, Store and leftover reads) from AppDeploy.ps1' -ForegroundColor Cyan
    $reader = Get-RenderedReader $deploy
    [IO.File]::WriteAllText((Join-Path $resDir 'reader.ps1'), $reader, (New-Object Text.UTF8Encoding $false))
    $pe = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($reader, [ref]$null, [ref]$pe)
    if ($pe.Count) { throw "The rendered reader does not parse: $($pe[0].Message) (line $($pe[0].Extent.StartLineNumber))" }
    Write-Host ("   {0:N0} characters, {1:N0} lines" -f $reader.Length, ($reader -split "`n").Count)

    $dotnet = Find-Dotnet $DotnetPath
    Write-Host "== dotnet build ($Configuration) with $dotnet" -ForegroundColor Cyan
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $buildOut = & $dotnet build $proj -c $Configuration -nologo -v q 2>&1
    if ($LASTEXITCODE -ne 0) { $buildOut | ForEach-Object { Write-Host $_ }; throw "dotnet build failed (exit $LASTEXITCODE)" }
    Write-Host ("   built in {0:N1} s" -f $sw.Elapsed.TotalSeconds)

    $exe = Join-Path $projDir "bin\$Configuration\net48\PC2Go.Deploy.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "Build produced no exe at $exe" }
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $out = Join-Path $dist 'PC2Go.Deploy.exe'
    Copy-Item -LiteralPath $exe -Destination $out -Force

    if ($SignThumbprint) {
        Write-Host '== Signing' -ForegroundColor Cyan
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $SignThumbprint } | Select-Object -First 1
        if (-not $cert) { throw "No certificate with thumbprint $SignThumbprint in CurrentUser\My or LocalMachine\My" }
        $sig = Set-AuthenticodeSignature -FilePath $out -Certificate $cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
        if ($sig.Status -ne 'Valid') { throw "Signing failed: $($sig.Status) $($sig.StatusMessage)" }
        Write-Host "   signed by $($cert.Subject)"
    }

    $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToUpper()
    $size = (Get-Item -LiteralPath $out).Length
    [IO.File]::WriteAllText((Join-Path $dist 'PC2Go.Deploy.sha256'), $hash, (New-Object Text.UTF8Encoding $false))
    Write-Host '== Output' -ForegroundColor Cyan
    Write-Host "   $out"
    Write-Host ("   {0:N0} bytes   SHA-256 {1}" -f $size, $hash)
    return [pscustomobject]@{ Exe = $out; Hash = $hash; Size = $size; WorkerChars = $worker.Length; Signed = [bool]$SignThumbprint }
}

# Dot-sourced by the tests for Get-RenderedWorker: build only when run as a script.
if ($MyInvocation.InvocationName -ne '.' -and -not $NoBuild) {
    $repo = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent $PSScriptRoot }
    Build-Client -Repo $repo -Configuration $Configuration -SignThumbprint $SignThumbprint -DotnetPath $DotnetPath
}
