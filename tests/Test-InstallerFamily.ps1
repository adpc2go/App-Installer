<#
.SYNOPSIS
    Proves tools\Installer-Family.ps1 says only what it FOUND.

.DESCRIPTION
    Synthesised fixtures for every family (a small signed PE with a crafted overlay or section),
    precedence (a wrapper around an embedded MSI), negatives (plain exes, a zip renamed .exe, an
    empty file), the read budget (a few tens of KB whatever the file), the never-absent rule, the
    registry-side uninstall recognition, and - when tests\fixtures\installers has them - the real
    vendor installers pinned by Get-InstallerFixtures.ps1.

    -Big adds a sparse 15 GB file with a real PE head, to prove the cost does not scale with size.
#>
param([switch]$Big, [switch]$SkipReal)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
$repo = Split-Path -Parent $here
$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Cond) { Assert-Equal $What $true ([bool]$Cond) }
function Write-Section([string]$T) { Write-Host ''; Write-Host $T -ForegroundColor Cyan; Write-Host ('-' * $T.Length) -ForegroundColor DarkGray }

. (Join-Path $repo 'tools\Installer-Family.ps1')
$root = Join-Path $env:TEMP ('pc2go-family-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    Write-Section '1. Every synthesised family is named from its signature, with its documented switch'
    $expect = @{ nsis = @('nsis', '/S'); inno = @('inno', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'); '7z' = @('sfx7z', '-y')
                 rar = @('sfxrar', '-s'); burn = @('burn', '/quiet /norestart') }
    foreach ($fam in @($expect.Keys)) {
        $p = Join-Path $root "fx-$fam.exe"
        [void](New-InstallerFamilyFixture -Family $fam -Path $p)
        $r = Get-InstallerFamily -Path $p
        Assert-Equal "$fam fixture is named"               $expect[$fam][0] $r.Family
        Assert-Equal "$fam confidence is a signature"      'signature' $r.Confidence
        Assert-Equal "$fam carries the documented switch"  $expect[$fam][1] $r.InstallArgs
        Assert-True  "$fam names where it looked"          (($r.Evidence -join ';').Length -gt 10)
        Assert-True  "$fam read under 64 KB"               ($r.BytesRead -le 65536)
        Assert-True  "$fam decided in under 2 s"           ($r.Elapsed -lt 2)
    }

    Write-Section '1b. The second pass: families that name themselves in the loader'
    # The stub's own identity string, exactly where a real one carries it: in the image (or, for
    # IExpress, in the UTF-16 version resource). Read only when nothing structural matched, and
    # the read stays bounded - the whole of a 50 KB stub here, never more than the head, the
    # resource section, the overlay probe and the tail on a large one.
    $expect2 = @{ squirrel = '--silent'; velopack = '--silent'; advinst = '/exenoui /qn'; wise = '/s'; setupfactory = '/S'
                  installaware = '/s'; qtifw = '--accept-licenses --default-answer --confirm-command install'; install4j = '-q'
                  iexpress = '/Q'; bitrock = '--mode unattended'; clickteam = '/S' }
    foreach ($fam in @($expect2.Keys)) {
        $p = Join-Path $root "fx-$fam.exe"
        [void](New-InstallerFamilyFixture -Family $fam -Path $p)
        $r = Get-InstallerFamily -Path $p
        Assert-Equal "$fam fixture is named"               $fam $r.Family
        Assert-Equal "$fam confidence is a signature"      'signature' $r.Confidence
        Assert-Equal "$fam carries the documented switch"  $expect2[$fam] $r.InstallArgs
        Assert-True  "$fam names the marker it found"      (($r.Evidence -join ';') -match "marker '")
        Assert-True  "$fam read under 512 KB"              ($r.BytesRead -le 524288)
        Assert-True  "$fam decided in under 2 s"           ($r.Elapsed -lt 2)
        Assert-True  "$fam has a label"                    ((Get-InstallerFamilyLabel $fam) -and (Get-InstallerFamilyLabel $fam) -ne 'unknown')
    }
    # a Velopack stub still carries Squirrel strings; the fork is asked first and wins
    $both = Join-Path $root 'fx-both.exe'
    $stub = [IO.File]::ReadAllBytes("$env:SystemRoot\System32\where.exe")
    $ms = New-Object IO.MemoryStream; $ms.Write($stub, 0, $stub.Length)
    $mk = [Text.Encoding]::GetEncoding(28591).GetBytes(([string][char]0) * 16 + 'SquirrelSetup' + ([string][char]0) * 8 + 'Velopack' + ([string][char]0) * 8)
    $ms.Write($mk, 0, $mk.Length); [IO.File]::WriteAllBytes($both, $ms.ToArray())
    Assert-Equal 'a stub with both markers is Velopack, the fork' 'velopack' (Get-InstallerFamily -Path $both).Family
    # and the structural families still win over an identity string sitting in the payload
    $wrap = Join-Path $root 'fx-nsis-with-marker.exe'
    [void](New-InstallerFamilyFixture -Family nsis -Path $wrap)
    [IO.File]::AppendAllText($wrap, ('' + [char]0) * 8 + 'Advanced Installer')
    Assert-Equal 'an NSIS loader with an identity string in its payload is still NSIS' 'nsis' (Get-InstallerFamily -Path $wrap).Family

    Write-Section '2. A real MSI is recognised by its OLE header and yields its ProductCode'
    $msi = Join-Path $root 'fx.msi'
    $madeMsi = $false
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        $db = $inst.OpenDatabase($msi, 3)
        foreach ($sql in @('CREATE TABLE Property (Property CHAR(72) NOT NULL, Value CHAR(0) NOT NULL LOCALIZABLE PRIMARY KEY Property)',
                           "INSERT INTO Property (Property, Value) VALUES ('ProductCode', '{11111111-2222-3333-4444-555555555555}')")) {
            $v = $db.OpenView($sql)
            $v.Execute()
            $v.Close()
        }
        $db.Commit()
        $madeMsi = $true
    } catch { Write-Host "  (skipped: WindowsInstaller COM could not build a fixture - $($_.Exception.Message))" -ForegroundColor DarkYellow }
    $db = $null; $inst = $null; [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    if ($madeMsi) {
        $r = Get-InstallerFamily -Path $msi
        Assert-Equal 'the .msi is named'                    'msi' $r.Family
        Assert-Equal 'and is a signature match'             'signature' $r.Confidence
        Assert-Equal 'with /qn /norestart'                  '/qn /norestart' $r.InstallArgs
        Assert-Equal 'the OLE header is the embedded-MSI find' 'found@0x0' $r.EmbeddedMsi
    }
    # A database built from nothing has no summary stream, and read mode refuses it - so the
    # ProductCode read is proven on a real package Windows keeps in its own cache.
    $realMsi = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Installer') -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 3)
    if ($realMsi.Count) {
        $got = $false
        foreach ($m in $realMsi) { $r = Get-InstallerFamily -Path $m.FullName; if ($r.UninstallShape.Args -match '/x \{[0-9A-Fa-f\-]{36}\} /qn /norestart') { $got = $true; break } }
        Assert-True 'a real MSI yields its ProductCode into the quiet uninstall line' $got
    } else { Write-Host '  (skipped: no cached MSI under Windows\Installer to read a ProductCode from)' -ForegroundColor DarkYellow }

    Write-Section '3. Precedence: the outer loader wins, and an embedded MSI is REPORTED, never used to guess'
    $p = Join-Path $root 'fx-nsis-wrapping-msi.exe'
    [void](New-InstallerFamilyFixture -Family nsis -Path $p -EmbedOle)
    $r = Get-InstallerFamily -Path $p
    Assert-Equal 'the NSIS wrapper is the family'           'nsis' $r.Family
    Assert-Equal 'its own switch is the one proposed'       '/S' $r.InstallArgs
    Assert-True  'the embedded OLE header is named with its offset' ($r.EmbeddedMsi -like 'found@0x*')
    Assert-True  'and the note says the wrapper switch is what applies' (($r.Notes -join ' ') -match 'wrapper')

    Write-Section '4. Negatives say what was seen and propose nothing'
    foreach ($neg in @(@{ N = 'notepad.exe'; P = "$env:SystemRoot\System32\notepad.exe" }, @{ N = 'where.exe'; P = "$env:SystemRoot\System32\where.exe" })) {
        $r = Get-InstallerFamily -Path $neg.P
        Assert-Equal "$($neg.N) has no family"                '' $r.Family
        Assert-Equal "$($neg.N) is not a signature match"      'none' $r.Confidence
        Assert-Equal "$($neg.N) gets no switch"               '' $r.InstallArgs
        # the second pass reads the head (128 KB) and up to 256 KB of resources before saying no
        Assert-True  "$($neg.N) read under 512 KB"            ($r.BytesRead -le 524288)
        Assert-True  "$($neg.N) decided in under 2 s"         ($r.Elapsed -lt 2)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zd = Join-Path $root 'zsrc'; New-Item -ItemType Directory -Force -Path $zd | Out-Null; Set-Content -LiteralPath (Join-Path $zd 'a.txt') -Value 'x'
    $zipExe = Join-Path $root 'archive.exe'; [IO.Compression.ZipFile]::CreateFromDirectory($zd, $zipExe)
    $r = Get-InstallerFamily -Path $zipExe
    Assert-Equal 'a zip renamed .exe is not an installer'    'none' $r.Confidence
    $empty = Join-Path $root 'empty.exe'; [IO.File]::WriteAllBytes($empty, (New-Object byte[] 0))
    $r = Get-InstallerFamily -Path $empty
    Assert-Equal 'an empty file is nothing'                  'none' $r.Confidence
    Assert-Equal 'a missing file is nothing'                 'none' (Get-InstallerFamily -Path (Join-Path $root 'nope.exe')).Confidence
    $md = Join-Path $root 'msixsrc'; New-Item -ItemType Directory -Force -Path $md | Out-Null; Set-Content -LiteralPath (Join-Path $md 'AppxManifest.xml') -Value '<Package/>'
    $mx = Join-Path $root 'fx.msix'; [IO.Compression.ZipFile]::CreateFromDirectory($md, $mx)
    Assert-Equal 'a zip with AppxManifest.xml named .msix is MSIX' 'msix' (Get-InstallerFamily -Path $mx).Family

    Write-Section '5. Package layouts: the files beside the entry'
    $od = Join-Path $root 'odis'; New-Item -ItemType Directory -Force -Path (Join-Path $od 'image') | Out-Null
    Copy-Item "$env:SystemRoot\System32\where.exe" (Join-Path $od 'Setup.exe'); Set-Content -LiteralPath (Join-Path $od 'image\Installer.exe') -Value 'x'
    # where.exe is Microsoft's, so the Autodesk layout must NOT fire on layout alone (CompanyName gate)
    $r = Get-InstallerFamily -Path (Join-Path $od 'Setup.exe')
    Assert-Equal 'an Autodesk layout under a non-Autodesk exe is not ODIS' '' $r.Family
    $r = Get-InstallerFamily -Path (Join-Path $od 'Setup.exe') -Siblings @('setup.exe', 'configuration.xml')
    Assert-Equal 'a Microsoft setup.exe beside configuration.xml is the Office Deployment Tool' 'officeodt' $r.Family
    Assert-Equal 'with /configure'                          '/configure configuration.xml' $r.InstallArgs

    Write-Section '6. The never-absent rule'
    $src = Get-Content -LiteralPath (Join-Path $repo 'tools\Installer-Family.ps1') -Raw
    Assert-True  'the source never assigns an "absent" verdict' (-not ($src -match "EmbeddedMsi\s*=\s*'(absent|none|missing|not found)'"))
    foreach ($p2 in @((Join-Path $root 'fx-nsis.exe'), $empty, "$env:SystemRoot\System32\notepad.exe")) {
        $r = Get-InstallerFamily -Path $p2
        Assert-True "EmbeddedMsi for $(Split-Path -Leaf $p2) is found@ or not-searched" ($r.EmbeddedMsi -eq 'not-searched' -or $r.EmbeddedMsi -like 'found@0x*')
    }

    Write-Section '6b. One copy: the region inside AppDeploy.ps1 IS this file'
    $ad = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    $mm = [regex]::Match($ad, '(?s)# ---- begin tools\\Installer-Family\.ps1[^\r\n]*\r?\n[^\r\n]*\r?\n(.*?)# ---- end tools\\Installer-Family\.ps1')
    Assert-True 'AppDeploy.ps1 carries the marked region' $mm.Success
    if ($mm.Success) {
        $norm = { param($s) (($s -replace "`r`n", "`n").TrimEnd()) }
        Assert-Equal 'and it is byte-for-byte this file (run tools\Sync-InstallerFamily.ps1 after editing the detector)' (& $norm $src) (& $norm $mm.Groups[1].Value)
        Assert-True 'Start-Worker substitutes the detector into the worker' ($ad -match "Replace\('#__INSTALLERFAMILY__', \(Get-InstallerFamilySource\)\)")
        # The RENDERED text is what the worker runs, and it is not the region: it is rebuilt from
        # the loaded functions plus the tables the renderer chooses to emit. It emitted the labels
        # and forgot the identity-marker table, so a client recognised none of the second-pass
        # families while the editor recognised all of them. Render it here from the same
        # functions, run it in a fresh runspace, and ask it about a Velopack stub.
        $adAst = [System.Management.Automation.Language.Parser]::ParseInput($ad, [ref]$null, [ref]$null)
        $renderFn = $adAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InstallerFamilySource' }, $true) | Select-Object -First 1
        $listLine = [regex]::Match($ad, '(?m)^\$script:InstallerFamilyFunctions = @\(.*$').Value
        Assert-True 'AppDeploy.ps1 defines the renderer and the function list' ($null -ne $renderFn -and $listLine)
        if ($renderFn -and $listLine) {
            . ([scriptblock]::Create($listLine))
            . ([scriptblock]::Create($renderFn.Extent.Text))
            $rendered = Get-InstallerFamilySource
            Assert-True 'the rendered detector carries the identity-marker table' ($rendered -match '(?m)^\$script:InstallerIdentityMarkers = @\(')
            $vp = Join-Path $root 'fx-velopack-rendered.exe'
            [void](New-InstallerFamilyFixture -Family velopack -Path $vp)
            $rps = [powershell]::Create()
            [void]$rps.AddScript($rendered + "`n" + '$r = Get-InstallerFamily -Path $args[0]; "$($r.Family)|$($r.InstallArgs)"').AddArgument($vp)
            $verdict = [string]($rps.Invoke() | Select-Object -Last 1)
            $rps.Dispose()
            Assert-Equal 'and, run on its own, it names a Velopack stub with its switch' 'velopack|--silent' $verdict
        }
        Assert-True 'and the worker carries the placeholder'               ($ad -match '(?m)^#__INSTALLERFAMILY__\s*$')
    }

    Write-Section '7. The registry side: quiet flags only on positive evidence'
    $u = Get-UninstallFamily -Exe 'C:\Apps\X\unins000.exe' -Arguments '' -RegValues @{ 'Inno Setup: Setup Version' = '6.2' }
    Assert-Equal 'unins000.exe with Inno registry values is Inno'  'inno' $u.Family
    Assert-Equal 'and becomes silent'                              $true $u.Silent
    Assert-Equal 'with the Inno flags appended'                    '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' $u.Args
    $u = Get-UninstallFamily -Exe 'C:\Apps\X\unins000.exe' -Arguments ''
    Assert-Equal 'unins000.exe alone (no file, no registry proof) is NOT assumed' '' $u.Family
    $u = Get-UninstallFamily -Exe 'msiexec.exe' -Arguments '/X{12345678-1234-1234-1234-123456789ABC}'
    Assert-Equal 'msiexec with a product code is MSI'             'msi' $u.Family
    Assert-True  'and gets /qn /norestart'                        ($u.Args -like '*/qn /norestart')
    $u = Get-UninstallFamily -Exe 'C:\Apps\Y\vc_redist.exe' -Arguments '/uninstall' -RegValues @{ BundleCachePath = 'x' }
    Assert-Equal 'Burn registry values name a bundle'             'burn' $u.Family
    Assert-Equal 'with the quiet uninstall shape'                 '/uninstall /quiet /norestart' $u.Args
    $nsisUn = Join-Path $root 'Uninstall.exe'; Copy-Item (Join-Path $root 'fx-nsis.exe') $nsisUn -Force
    $u = Get-UninstallFamily -Exe $nsisUn -Arguments '' -InstallLocation 'C:\Apps\N'
    Assert-Equal 'an NSIS uninstaller is recognised from its own signature' 'nsis' $u.Family
    Assert-Equal 'with /S and the mandatory _?='                 '/S _?=C:\Apps\N' $u.Args
    $u = Get-UninstallFamily -Exe 'C:\Tools\setup.exe' -Arguments '-uninstall -quiet'
    Assert-Equal 'an unknown uninstaller keeps its args untouched' '-uninstall -quiet' $u.Args
    Assert-Equal 'and is not silent'                              $false $u.Silent
    # InstallShield Suite/Advanced UI - the SketchUp 2026 shape: "-remove -runfromtemp" is the
    # Suite uninstall, not InstallScript's "-removeonly", and /silent is its documented switch
    $u = Get-UninstallFamily -Exe 'C:\Program Files (x86)\InstallShield Installation Information\{bf48c79b}\SketchUp-2026-1-256-82.exe' -Arguments '-remove -runfromtemp'
    Assert-Equal 'a Suite uninstall (-remove -runfromtemp) is InstallShield' 'installshield' $u.Family
    Assert-True  'named as the Suite shape, not InstallScript'    ($u.Evidence -like '*Suite*')
    Assert-Equal 'and gets -silent appended, so it IS silent'     '-remove -runfromtemp -silent|True' "$($u.Args)|$($u.Silent)"
    $u = Get-UninstallFamily -Exe 'C:\Tools\SketchUp-2026-1-256-82.exe' -Arguments '-remove -runfromtemp -silent'
    Assert-Equal 'an entry that already has -silent is left alone' '-remove -runfromtemp -silent' $u.Args
    $u = Get-UninstallFamily -Exe 'C:\Tools\setup.exe' -Arguments '-runfromtemp -removeonly'
    Assert-True  'InstallScript -removeonly still needs its response file' (($u.Family -eq 'installshield') -and -not $u.Silent -and ($u.Notes -join ';') -like '*response file*')
    Assert-Equal 'the Suite install switch is /silent'            '/silent' (Get-FamilySwitches 'installshield' 'suite').Install
    Assert-Equal 'and its uninstall shape is -remove -silent'     '-remove -silent' (Get-FamilySwitches 'installshield' 'suite').UninstallArgs

    Write-Section '7b. The registry side, second pass: the uninstaller says what built it'
    $u = Get-UninstallFamily -Exe 'C:\Apps\W\UNWISE.EXE' -Arguments '"C:\Apps\W\INSTALL.LOG"'
    Assert-Equal 'UNWISE.EXE is Wise by name alone'               'wise' $u.Family
    Assert-Equal 'and takes /S in front of the log'               '/S "C:\Apps\W\INSTALL.LOG"' $u.Args
    $cases = @(
        @{ Fam = 'install4j';    Leaf = 'uninstall.exe';       In = '';                              Out = '-q' }
        @{ Fam = 'bitrock';      Leaf = 'uninstall.exe';       In = '';                              Out = '--mode unattended' }
        @{ Fam = 'setupfactory'; Leaf = 'unins.exe';           In = '';                              Out = '/S' }
        @{ Fam = 'clickteam';    Leaf = 'Uninstal.exe';        In = '';                              Out = '/S' }
        @{ Fam = 'qtifw';        Leaf = 'maintenancetool.exe'; In = '';                              Out = '--confirm-command purge' }
        @{ Fam = 'qtifw';        Leaf = 'maintenancetool.exe'; In = 'purge';                         Out = 'purge --confirm-command' }
        @{ Fam = 'advinst';      Leaf = 'Setup.exe';           In = '/x {12345678-1234-1234-1234-123456789ABC}'; Out = '/x {12345678-1234-1234-1234-123456789ABC} /exenoui /qn' }
        @{ Fam = 'installaware'; Leaf = 'setup.exe';           In = '/u';                            Out = '/u /s MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES' }
        @{ Fam = 'squirrel';     Leaf = 'Update.exe';          In = '--uninstall';                   Out = '--uninstall' }
        @{ Fam = 'velopack';     Leaf = 'Update.exe';          In = '--uninstall';                   Out = '--uninstall' }
        @{ Fam = 'wise';         Leaf = 'setup.exe';           In = '"C:\x\INSTALL.LOG"';            Out = '/S "C:\x\INSTALL.LOG"' }
    )
    foreach ($c in $cases) {
        $d = Join-Path $root ("un-" + $c.Fam + '-' + [IO.Path]::GetFileNameWithoutExtension($c.Leaf)); New-Item -ItemType Directory -Force -Path $d | Out-Null
        $exe = Join-Path $d $c.Leaf
        [void](New-InstallerFamilyFixture -Family $c.Fam -Path $exe)
        $u = Get-UninstallFamily -Exe $exe -Arguments $c.In
        Assert-Equal "$($c.Leaf) built by $($c.Fam): family"      $c.Fam $u.Family
        Assert-Equal "$($c.Leaf) built by $($c.Fam): silent"      $true $u.Silent
        Assert-Equal "$($c.Leaf) built by $($c.Fam): arguments"   $c.Out $u.Args
    }
    # already quiet: nothing is appended twice
    $d = Join-Path $root 'un-install4j-uninstall'
    $u = Get-UninstallFamily -Exe (Join-Path $d 'uninstall.exe') -Arguments '-q'
    Assert-Equal 'an install4j uninstaller already carrying -q is left alone' '-q' $u.Args
    # an uninstaller that is not on disk gets nothing from this pass
    $u = Get-UninstallFamily -Exe 'C:\Gone\uninstall.exe' -Arguments ''
    Assert-Equal 'a missing uninstaller is not assumed to be anything' '' $u.Family
    # an IExpress package has no uninstaller shape and is never called silent
    $ie = Join-Path $root 'un-iexpress'; New-Item -ItemType Directory -Force -Path $ie | Out-Null
    [void](New-InstallerFamilyFixture -Family iexpress -Path (Join-Path $ie 'pkg.exe'))
    $u = Get-UninstallFamily -Exe (Join-Path $ie 'pkg.exe') -Arguments ''
    Assert-Equal 'an IExpress package is not made silent on the registry side' $false $u.Silent

    if ($Big) {
        Write-Section '8. Size does not matter: a sparse 15 GB file with a PE head'
        $big = Join-Path $root 'big.exe'
        & "$env:SystemRoot\System32\fsutil.exe" file createnew $big 16106127360 | Out-Null
        $fs = [IO.File]::Open($big, 'Open', 'ReadWrite'); try { $b = [IO.File]::ReadAllBytes("$env:SystemRoot\System32\where.exe"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
        $r = Get-InstallerFamily -Path $big
        Assert-True 'the 15 GB file read under 2 MB' ($r.BytesRead -le 2MB)
        Assert-True 'and was decided in under 3 s'   ($r.Elapsed -lt 3)
    }

    if (-not $SkipReal) {
        Write-Section '9. Real installers, when the pinned fixtures are present'
        $fx = Join-Path $here 'fixtures\installers'
        $real = @(
            @{ File = 'npp.installer.exe';   Family = 'nsis';  Args = '/S' }
            @{ File = 'vc_redist.x64.exe';   Family = 'burn';  Args = '/quiet /norestart' }
            @{ File = 'git-installer.exe';   Family = 'inno';  Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        )
        $seen = 0
        foreach ($c in $real) {
            $p3 = Join-Path $fx $c.File
            if (-not (Test-Path -LiteralPath $p3)) { Write-Host "  (skipped: $($c.File) not downloaded - run tests\Get-InstallerFixtures.ps1)" -ForegroundColor DarkYellow; continue }
            $seen++
            $r = Get-InstallerFamily -Path $p3
            Assert-Equal "$($c.File) is $($c.Family)"        $c.Family $r.Family
            Assert-Equal "$($c.File) is a signature match"   'signature' $r.Confidence
            Assert-Equal "$($c.File) switch"                 $c.Args $r.InstallArgs
            Assert-True  "$($c.File) read under 4 MB"        ($r.BytesRead -le 4MB)
            Assert-True  "$($c.File) decided in under 2 s"   ($r.Elapsed -lt 2)
        }
        if (-not $seen) { Write-Host '  (no real fixtures present)' -ForegroundColor DarkYellow }
    }
} finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
Write-Host ''
Write-Host "$($script:Pass)/$($script:Pass + $script:Fail) passed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
