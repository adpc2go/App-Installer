<#
.SYNOPSIS
    Installs three REAL products on this machine, then removes them with the tool's own code.

.DESCRIPTION
    Test-DirtyCleanup.ps1 proves the DECISIONS: given a verdict and a ticked target, the wipe
    removes the debris and nothing else. What it never touches is DISCOVERY - Get-InstalledPrograms
    reading the registry, and Parse-UninstallString turning a vendor's uninstall string into a
    command. Those run against a real machine, and until now nothing had executed them.

    So this installs real software and takes it away again:

      A  "Lumen Notes"   - a light app. Real files, a real HKCU uninstall entry, a real
                           uninstall command whose path is quoted and contains spaces.
      B  "Quill Editor"  - the same, but a REAL compiled .exe runs from its install folder
                           holding one of its own files open with FileShare.None. A locked
                           file is the usual reason a removal half-works, so the tool has to
                           close it first and then delete.
      C  "Vellum Sync"   - the same, plus traces where a real app leaves them: %APPDATA%,
                           %LOCALAPPDATA%, a HKCU\SOFTWARE key and a Run entry. Its uninstaller
                           removes only the program folder, so deep clean has to find the rest
                           and the wipe has to remove it.

    Everything is PER-USER on purpose. A machine-wide install needs elevation, and a UAC prompt
    cannot be answered by an unattended run - so nothing here writes to HKLM, installs for other
    users, or touches anything that was on this machine already. Every artefact is created by
    this script under names it owns, and the finally block removes all of them whatever happens,
    then says so if any survived.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-RealUninstall.ps1
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

$script:Pass = 0
$script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") {
        $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
# the worker's own words for why, so a failing verdict explains itself instead of just
# disagreeing with the expected string
function Assert-State([string]$What, [string]$Expected, $Reported) {
    if ($Reported -and "$($Reported.state)" -ne $Expected -and $Reported.detail) {
        Assert-Equal $What $Expected "$($Reported.state) - $($Reported.detail)"
    } else {
        Assert-Equal $What $Expected $(if ($Reported) { $Reported.state } else { '(nothing reported)' })
    }
}
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

$tag         = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$installRoot = Join-Path $env:LOCALAPPDATA "PC2GoLiveTest-$tag"
$unRoot      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$runKey      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$keyA        = "$unRoot\PC2GoTest-A-$tag"
$keyB        = "$unRoot\PC2GoTest-B-$tag"
$keyC        = "$unRoot\PC2GoTest-C-$tag"
$keyD        = "$unRoot\PC2GoTest-D-$tag"
$vellumKey   = 'HKCU:\SOFTWARE\VellumSync'
$appDataC    = Join-Path $env:APPDATA 'VellumSync'
$localC      = Join-Path $env:LOCALAPPDATA 'VellumSync'
$script:Locker = $null
$sandbox = $null

# Everything this script made, gone - whatever happened. Defined before anything is created,
# so an early failure still cleans up after itself.
function Remove-Artefacts {
    if ($script:Locker) { try { if (-not $script:Locker.HasExited) { $script:Locker.Kill() } } catch {} }
    Start-Sleep -Milliseconds 300
    foreach ($k in @($keyA, $keyB, $keyC, $keyD, $vellumKey)) {
        try { if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
    try { Remove-ItemProperty -LiteralPath $runKey -Name 'VellumSync' -Force -ErrorAction SilentlyContinue } catch {}
    foreach ($d in @($installRoot, $appDataC, $localC)) {
        try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

try {
    Write-Host "Install root : $installRoot" -ForegroundColor DarkGray
    Write-Host "Registry     : $unRoot\PC2GoTest-*-$tag  (HKCU only)" -ForegroundColor DarkGray

    # ================================================================== extraction
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $lines = $src -split "`r?`n"

    function Get-Fn([string]$Name) {
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name" }
        return $fn.Extent.Text
    }
    # AsText before Clean-DisplayName: a registry value can come back as a char[] or an
    # array, and Clean-DisplayName leans on it for every name it reads
    # Test-ProtectedPath is what Scan-Leftovers calls to decide whether a path is one of the
    # protected roots; lifting the caller without it throws CommandNotFound on the first target
    foreach ($n in 'Format-Size', 'Get-FolderSize', 'ConvertTo-PSRegPath', 'AsText', 'Clean-DisplayName',
                   'Parse-UninstallString', 'ConvertTo-Int', 'Get-InstalledPrograms',
                   'Test-ProtectedPath', 'Scan-Leftovers',
                   # the installer-family detector Get-InstalledPrograms consults for non-quiet rows
                   'Get-InstallerFamilyLabel', 'Get-FamilySwitches', 'Read-FileRange', 'ConvertTo-Latin1',
                   'Find-Marker', 'ConvertFrom-HexMarker', 'Get-PeLayout', 'Get-VersionStrings',
                   'Get-PeResourceLeaves', 'Get-CompanionNames', 'Test-Companion', 'Get-InstallerFamily',
                   'Get-UninstallFamily', 'New-InstallerFamilyFixture') {
        . ([scriptblock]::Create((Get-Fn $n)))
    }
    # the real AppItem / WipeItem, so a renamed field breaks this rather than passing on a stand-in
    $ts = ($lines | Select-String -SimpleMatch "Add-Type -TypeDefinition @'" | Select-Object -First 1).LineNumber
    $te = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $ts } | Select-Object -First 1).LineNumber
    Add-Type -TypeDefinition (($lines[$ts..($te - 2)]) -join "`r`n")

    $script:ProtectedPaths = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:ProtectedPaths' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
    $script:SharedComponentHints = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:SharedComponentHints' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
    $script:ScanLabel = 'live test'
    $TxtNow = [pscustomobject]@{ Text = '' }
    $DotNow = [pscustomobject]@{ Fill = '' }
    function Update-UI { }

    # the elevated worker, out of its here-string - the same code that runs on a client
    $ws = ($lines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    $we = ($lines | Select-String -Pattern "^'@$" | Where-Object { $_.LineNumber -gt $ws } | Select-Object -First 1).LineNumber
    $sandbox = Join-Path $env:TEMP "pc2go-live-$tag"
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $workerFile = Join-Path $sandbox 'worker.ps1'
    Set-Content -LiteralPath $workerFile -Encoding UTF8 `
                -Value ((($lines[$ws..($we - 2)]) -join "`r`n") -replace '#__PREFTABLE__', '')
    $queue  = Join-Path $sandbox 'queue.jsonl'
    $status = Join-Path $sandbox 'status.jsonl'
    $cancel = Join-Path $sandbox 'cancel.flag'
    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Invoke-Worker {
        Add-Content -LiteralPath $queue -Encoding UTF8 -Value '{"end":true}'
        return (Start-Process -FilePath $psExe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$workerFile`"",
            '-QueueFile', "`"$queue`"", '-StatusFile', "`"$status`"", '-CancelFile', "`"$cancel`""))
    }
    function Get-Reported([string]$Id) {
        @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue |
          ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
          Where-Object { $_ -and $_.id -eq $Id }) | Select-Object -Last 1
    }

    # ================================================================== install the products
    Write-Section 'Installing three real products (per-user, no elevation)'

    # ---- A: a light app, whose uninstall string is a QUOTED path containing spaces
    $dirA = Join-Path $installRoot 'Lumen Notes'
    New-Item -ItemType Directory -Force -Path $dirA | Out-Null
    Set-Content -LiteralPath "$dirA\lumen.exe"  -Value 'binary' -Encoding ASCII
    Set-Content -LiteralPath "$dirA\readme.txt" -Value 'notes'  -Encoding ASCII
    # The uninstaller lives OUTSIDE the folder it deletes, exactly as a real one does - a batch
    # that removes its own directory mid-run cannot read its next line, and cmd.exe then returns
    # a non-zero code that the worker rightly reads as a failed uninstall. The path still has
    # spaces and is still quoted, which is the part worth testing.
    $unDirA = Join-Path $installRoot 'Uninstall\Lumen Notes'
    New-Item -ItemType Directory -Force -Path $unDirA | Out-Null
    $unA = Join-Path $unDirA 'uninstall.cmd'
    Set-Content -LiteralPath $unA -Encoding ASCII -Value (@(
        '@echo off',
        "reg delete `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoTest-A-$tag`" /f >nul 2>&1",
        'timeout /t 1 /nobreak >nul',
        "rd /s /q `"$dirA`"",
        'exit /b 0') -join "`r`n")
    New-Item -Path $keyA -Force | Out-Null
    Set-ItemProperty -Path $keyA -Name 'DisplayName'     -Value 'Lumen Notes'
    Set-ItemProperty -Path $keyA -Name 'DisplayVersion'  -Value '1.4.2'
    Set-ItemProperty -Path $keyA -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $keyA -Name 'InstallLocation' -Value $dirA
    Set-ItemProperty -Path $keyA -Name 'UninstallString' -Value "`"$unA`""
    Set-ItemProperty -Path $keyA -Name 'EstimatedSize'   -Value 12 -Type DWord
    Assert-True 'A: Lumen Notes is installed' ((Test-Path $dirA) -and (Test-Path $keyA))

    # ---- B: same, plus a REAL exe running from its folder holding a file open
    $dirB = Join-Path $installRoot 'Quill Editor'
    New-Item -ItemType Directory -Force -Path $dirB | Out-Null
    Set-Content -LiteralPath "$dirB\document.dat" -Value 'user document' -Encoding ASCII
    $lockerSrc = @'
using System;
using System.IO;
using System.Threading;
public class Locker {
    public static void Main(string[] a) {
        // FileShare.None: nothing else on the machine can open or delete this while we hold it
        using (FileStream fs = new FileStream(a[0], FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
            Thread.Sleep(600000);
        }
    }
}
'@
    $lockerExe = Join-Path $dirB 'quill.exe'
    Add-Type -TypeDefinition $lockerSrc -OutputAssembly $lockerExe -OutputType ConsoleApplication
    Assert-True 'B: a real .exe was compiled into the install folder' (Test-Path $lockerExe)
    $unDirB = Join-Path $installRoot 'Uninstall\Quill Editor'
    New-Item -ItemType Directory -Force -Path $unDirB | Out-Null
    $unB = Join-Path $unDirB 'uninstall.cmd'
    Set-Content -LiteralPath $unB -Encoding ASCII -Value (@(
        '@echo off',
        "reg delete `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoTest-B-$tag`" /f >nul 2>&1",
        'timeout /t 1 /nobreak >nul',
        "rd /s /q `"$dirB`"",
        'exit /b 0') -join "`r`n")
    New-Item -Path $keyB -Force | Out-Null
    Set-ItemProperty -Path $keyB -Name 'DisplayName'          -Value 'Quill Editor'
    Set-ItemProperty -Path $keyB -Name 'DisplayVersion'       -Value '3.0'
    Set-ItemProperty -Path $keyB -Name 'Publisher'            -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $keyB -Name 'InstallLocation'      -Value $dirB
    # QuietUninstallString must WIN over UninstallString - that is the documented ranking
    Set-ItemProperty -Path $keyB -Name 'UninstallString'      -Value "`"$unB`" /interactive"
    Set-ItemProperty -Path $keyB -Name 'QuietUninstallString' -Value "`"$unB`""
    $script:Locker = Start-Process -FilePath $lockerExe -ArgumentList "`"$dirB\document.dat`"" -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    Assert-True 'B: the locker process is running' (-not $script:Locker.HasExited)
    $lockHeld = $false
    try { ([IO.File]::Open("$dirB\document.dat", 'Open', 'ReadWrite', 'None')).Dispose() }
    catch { $lockHeld = $true }
    Assert-True 'B: and document.dat really is locked' $lockHeld

    # ---- C: same, plus traces where a real app leaves them
    $dirC = Join-Path $installRoot 'Vellum Sync'
    New-Item -ItemType Directory -Force -Path $dirC | Out-Null
    Set-Content -LiteralPath "$dirC\vellum.exe" -Value 'binary' -Encoding ASCII
    New-Item -ItemType Directory -Force -Path $appDataC, $localC | Out-Null
    Set-Content -LiteralPath (Join-Path $appDataC 'settings.ini') -Value 'x' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $localC  'cache.bin')     -Value 'x' -Encoding ASCII
    New-Item -Path $vellumKey -Force | Out-Null
    Set-ItemProperty -Path $vellumKey -Name 'InstallPath' -Value $dirC
    Set-ItemProperty -Path $runKey -Name 'VellumSync' -Value "`"$dirC\vellum.exe`" /background"
    $unDirC = Join-Path $installRoot 'Uninstall\Vellum Sync'
    New-Item -ItemType Directory -Force -Path $unDirC | Out-Null
    $unC = Join-Path $unDirC 'uninstall.cmd'
    # deliberately removes ONLY the program folder, the way real uninstallers do
    Set-Content -LiteralPath $unC -Encoding ASCII -Value (@(
        '@echo off',
        "reg delete `"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoTest-C-$tag`" /f >nul 2>&1",
        'timeout /t 1 /nobreak >nul',
        "rd /s /q `"$dirC`"",
        'exit /b 0') -join "`r`n")
    New-Item -Path $keyC -Force | Out-Null
    Set-ItemProperty -Path $keyC -Name 'DisplayName'     -Value 'Vellum Sync'
    Set-ItemProperty -Path $keyC -Name 'DisplayVersion'  -Value '2.1'
    Set-ItemProperty -Path $keyC -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $keyC -Name 'InstallLocation' -Value $dirC
    Set-ItemProperty -Path $keyC -Name 'UninstallString' -Value "`"$unC`""
    Assert-True 'C: Vellum Sync is installed, with registry and profile traces' `
                ((Test-Path $dirC) -and (Test-Path $vellumKey) -and (Test-Path $appDataC))

    # ---- D: an Inno Setup-shaped product - unins000.exe carrying the Inno signature, a plain
    # UninstallString with no switch and NO "Inno Setup: *" registry values, so only the file's
    # own signature can say what it is. Never removed by the worker; discovery only.
    $dirD = Join-Path $installRoot 'Ember Reader'
    New-Item -ItemType Directory -Force -Path $dirD | Out-Null
    $unD = Join-Path $dirD 'unins000.exe'
    [void](New-InstallerFamilyFixture -Family inno -Path $unD)
    New-Item -Path $keyD -Force | Out-Null
    Set-ItemProperty -Path $keyD -Name 'DisplayName'     -Value 'Ember Reader'
    Set-ItemProperty -Path $keyD -Name 'DisplayVersion'  -Value '3.0'
    Set-ItemProperty -Path $keyD -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
    Set-ItemProperty -Path $keyD -Name 'InstallLocation' -Value $dirD
    Set-ItemProperty -Path $keyD -Name 'UninstallString' -Value "`"$unD`""
    Assert-True 'D: Ember Reader is installed with an Inno-signed uninstaller' ((Test-Path $unD) -and (Test-Path $keyD))

    # ================================================================== discovery
    Write-Section 'The tool finds them the way Control Panel does'

    $found = @(Get-InstalledPrograms)
    $fa = @($found | Where-Object { $_.Name -eq 'Lumen Notes'  }) | Select-Object -First 1
    $fb = @($found | Where-Object { $_.Name -eq 'Quill Editor' }) | Select-Object -First 1
    $fc = @($found | Where-Object { $_.Name -eq 'Vellum Sync'  }) | Select-Object -First 1
    Assert-True  'A is discovered'          $fa
    Assert-True  'B is discovered'          $fb
    Assert-True  'C is discovered'          $fc
    Assert-Equal 'A: version read'          '1.4.2' $fa.Version
    Assert-Equal 'A: publisher read'        'PC2Go Test Fixtures' $fa.Publisher
    Assert-Equal 'A: install location read' $dirA $fa.Location
    # the quoted path with spaces has to survive parsing intact, or the removal runs nothing
    Assert-Equal 'A: quoted path parsed intact' $unA $fa.Exe
    Assert-Equal 'A: no stray arguments'        '' $fa.Args
    Assert-True  'B: QuietUninstallString wins over UninstallString' ($fb.Exe -eq $unB -and $fb.Args -eq '')
    Assert-True  'B: and is therefore marked silent'                 $fb.Silent
    # the family detector: a positive signature earns the documented quiet flags; nothing else does
    $fd = @($found | Where-Object { $_.Name -eq 'Ember Reader' }) | Select-Object -First 1
    Assert-True  'D is discovered'                                   $fd
    Assert-Equal 'D: the uninstaller signature names Inno Setup'     'inno' $fd.Family
    Assert-True  'D: and the row is silent'                          $fd.Silent
    Assert-Equal 'D: with the documented Inno quiet flags appended'  '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' $fd.Args
    Assert-Equal 'D: the vendor string is kept beside them'          '' $fd.BaseArgs
    Assert-True  'A: a plain .cmd uninstaller is NOT called silent'  (-not $fa.Silent)
    Assert-Equal 'A: and names no family'                            '' $fa.Family

    Write-Section 'Parse-UninstallString against the shapes vendors actually write'
    $msi = Parse-UninstallString 'MsiExec.exe /I{90160000-008C-0000-1000-0000000FF1CE}'
    Assert-Equal 'MSI /I is rewritten to a silent /x' 'msiexec.exe' $msi.exe
    Assert-Equal 'with the GUID and quiet switches'   '/x {90160000-008C-0000-1000-0000000FF1CE} /qn /norestart' $msi.args
    Assert-True  'and counts as silent'               $msi.silent
    $msi2 = Parse-UninstallString '"C:\Windows\System32\msiexec.exe" /X{12345678-1234-1234-1234-123456789012}'
    Assert-Equal 'a quoted msiexec /X is rewritten too' '/x {12345678-1234-1234-1234-123456789012} /qn /norestart' $msi2.args
    $sp = Parse-UninstallString '"C:\Program Files\Some App\unins000.exe" /SILENT'
    Assert-Equal 'a quoted path keeps its spaces' 'C:\Program Files\Some App\unins000.exe' $sp.exe
    Assert-Equal 'and its arguments'              '/SILENT' $sp.args
    $uq = Parse-UninstallString 'C:\Tools\setup.exe -uninstall -quiet'
    Assert-Equal 'an unquoted path splits at .exe' 'C:\Tools\setup.exe' $uq.exe
    Assert-Equal 'keeping the rest as arguments'   '-uninstall -quiet' $uq.args

    # ================================================================== remove A and B
    Write-Section 'Removing A (light) and B (locked file) with the real worker'

    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'lumen'; action = 'uninstall'; command = $fa.Exe; args = $fa.Args
        detect = "$dirA\lumen.exe"; location = $dirA } | ConvertTo-Json -Compress)
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'quill'; action = 'uninstall'; command = $fb.Exe; args = $fb.Args
        detect = "$dirB\document.dat"; location = $dirB } | ConvertTo-Json -Compress)
    $t0 = Get-Date
    $p = Invoke-Worker
    Write-Host ("  worker exited {0} after {1:N1}s" -f $p.ExitCode, ((Get-Date) - $t0).TotalSeconds) -ForegroundColor DarkGray

    $ra = Get-Reported 'lumen'
    Assert-State 'A: reported Uninstalled'        'Uninstalled' $ra
    Assert-True  'A: the folder is gone'          (-not (Test-Path -LiteralPath $dirA))
    Assert-True  'A: the uninstall entry is gone' (-not (Test-Path -LiteralPath $keyA))

    $rb = Get-Reported 'quill'
    Assert-State 'B: reported Uninstalled' 'Uninstalled' $rb
    # the whole point of B: a running exe holds its own folder open, so the tool has to close
    # it before the uninstaller can delete anything
    Assert-True 'B: the locking process was closed' ($script:Locker.HasExited)
    Assert-True 'B: the locked document is gone'    (-not (Test-Path -LiteralPath "$dirB\document.dat"))
    Assert-True 'B: the folder is gone'             (-not (Test-Path -LiteralPath $dirB))

    # ================================================================== deep clean C
    Write-Section 'Removing C, then deep-cleaning what its uninstaller left behind'

    Remove-Item -LiteralPath $queue -Force -ErrorAction SilentlyContinue
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'vellum'; action = 'uninstall'; command = $fc.Exe; args = $fc.Args
        detect = "$dirC\vellum.exe"; location = $dirC } | ConvertTo-Json -Compress)
    $p = Invoke-Worker
    $rc = Get-Reported 'vellum'
    Assert-State 'C: reported Uninstalled'       'Uninstalled' $rc
    Assert-True  'C: the program folder is gone' (-not (Test-Path -LiteralPath $dirC))
    # a real uninstaller leaves exactly this behind, which is why deep clean exists
    Assert-True  'but its AppData survived the uninstaller' (Test-Path -LiteralPath $appDataC)
    Assert-True  'and so did its registry key'              (Test-Path -LiteralPath $vellumKey)

    $item = New-Object AppItem
    $item.Id = 'vellum'; $item.Name = 'Vellum Sync'
    $item.CleanPaths = @(); $item.CleanReg = @(); $item.CleanHosts = @()
    $item.CleanTokens = @('VellumSync', 'Vellum Sync')
    $item.CreatedPaths = @()
    $hits = @(Scan-Leftovers $item $true)
    Write-Host ("  the scan found {0} leftover(s)" -f $hits.Count) -ForegroundColor DarkGray
    foreach ($h in $hits) { Write-Host ("    {0,-9} {1}" -f $h.Kind, $h.Path) -ForegroundColor DarkGray }

    $hitRoaming = @($hits | Where-Object { $_.Path -eq $appDataC }) | Select-Object -First 1
    $hitLocal   = @($hits | Where-Object { $_.Path -eq $localC })   | Select-Object -First 1
    $hitReg     = @($hits | Where-Object { $_.Type -eq 'reg' -and (ConvertTo-PSRegPath $_.Path) -eq $vellumKey }) | Select-Object -First 1
    Assert-True 'deep clean found the Roaming folder'    $hitRoaming
    Assert-True 'deep clean found the Local folder'      $hitLocal
    Assert-True 'deep clean found the HKCU registry key' $hitReg
    # found by name match and not by the catalog, so it must NOT be pre-ticked
    Assert-True 'a name-matched hit is offered, not pre-ticked' (-not $hitRoaming.Del)

    # The autostart entry is a registry VALUE, not a sub-key. The key sweep walks straight past
    # it, so it needs its own stage - without which the product is "completely removed" and
    # still tries to launch at every login, pointing at an exe that is no longer there.
    Assert-True 'the autostart entry is still in the registry after the uninstaller ran' `
                ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name 'VellumSync' -ErrorAction SilentlyContinue))
    $hitRun = @($hits | Where-Object { $_.Type -eq 'regvalue' -and $_.Name -eq 'VellumSync' }) | Select-Object -First 1
    Assert-True  'deep clean found the autostart entry'   $hitRun
    Assert-Equal 'and points at the key that holds it'    $runKey (ConvertTo-PSRegPath $hitRun.Path)
    Assert-Equal 'naming the entry, since every autorun shares one key' 'VellumSync' $hitRun.SizeText
    Assert-True  'a name match is offered, never pre-ticked' (-not $hitRun.Del)

    # ---- approve everything the scan found, and wipe it for real
    Remove-Item -LiteralPath $queue -Force -ErrorAction SilentlyContinue
    # exactly what the GUI queues once the technician ticks the rows, value names included
    $targets = @($hits | ForEach-Object { @{ type = $_.Type; path = $_.Path; name = $_.Name } })
    Add-Content -LiteralPath $queue -Encoding UTF8 -Value (@{
        id = 'vellum'; action = 'wipe'; targets = $targets } | ConvertTo-Json -Compress -Depth 5)
    $p = Invoke-Worker
    $rw = Get-Reported 'vellum'
    Assert-State 'the wipe reported Cleaned'  'Cleaned' $rw
    Assert-True  'and said what it removed'   ($rw.detail -like '*trace(s) removed*')
    Assert-True  'the Roaming folder is gone' (-not (Test-Path -LiteralPath $appDataC))
    Assert-True  'the Local folder is gone'   (-not (Test-Path -LiteralPath $localC))
    Assert-True  'the registry key is gone'   (-not (Test-Path -LiteralPath $vellumKey))
    Assert-True  'the autostart entry is gone' `
                 ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name 'VellumSync' -ErrorAction SilentlyContinue))
    # one VALUE was removed, never the key - Run holds every other product's autostart entry
    # too, and taking the key would stop all of them
    Assert-True  'but the Run key itself survives'       (Test-Path -LiteralPath $runKey)
    # nothing of the machine's own was in the kill list, so nothing of the machine's own went
    Assert-True  'an unrelated HKCU key was left alone'  (Test-Path -LiteralPath 'HKCU:\SOFTWARE\Microsoft')

    Write-Host ''
    Write-Host ("{0}/{1} passed" -f $script:Pass, ($script:Pass + $script:Fail)) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($KeepArtefacts) {
        Write-Host "Artefacts kept: $installRoot" -ForegroundColor Yellow
    } else {
        Remove-Artefacts
        $left = @(@($installRoot, $appDataC, $localC) | Where-Object { Test-Path -LiteralPath $_ }) +
                @(@($keyA, $keyB, $keyC, $vellumKey) | Where-Object { Test-Path -LiteralPath $_ })
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE, still present: " + ($left -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
    if ($sandbox -and (Test-Path -LiteralPath $sandbox)) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

