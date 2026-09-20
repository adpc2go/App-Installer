<#
.SYNOPSIS
    The silent-switch ladder: "handle any exe", proved against a real installer that is wrong.

.DESCRIPTION
    A detected or catalogued switch runs first. When it opens a window, or exits having created
    nothing, the worker tries the common silent switches in turn - each under the window guard,
    each written to the record - before it fails the row. The uninstall side climbs the same
    ladder: as registered but watched, then the switches, then as registered with its window
    allowed for the technician. This is the harness for both.

    Nothing is stubbed that matters. A small WinExe is COMPILED here - it accepts exactly one
    switch (read from a file beside it), and for anything else it opens a window, or exits
    non-zero, or exits 0 having done nothing, as the case asks. Install-One, Uninstall-One,
    Start-InstallerWatched and Stop-ProcessTree are the worker's own, lifted from the
    here-string by AST; the guard really watches a really visible window and really kills it.

    Only the clocks are shortened: a first-attempt grace of 4 s instead of 180, a rung grace of
    3 s instead of 45. The ladder itself is the worker's table, read from the worker.

    Runs unelevated, writes only under %TEMP%, installs nothing real.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-SilentLadder.ps1
#>
[CmdletBinding()]
param([string]$WorkerPath)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
$repo = Split-Path -Parent $here
if (-not $WorkerPath) { $WorkerPath = Join-Path $repo 'server\AppDeploy.ps1' }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Cond) { Assert-Equal $What $true ([bool]$Cond) }
function Write-Section([string]$T) { Write-Host ''; Write-Host $T -ForegroundColor Cyan; Write-Host ('-' * $T.Length) -ForegroundColor DarkGray }

$root = Join-Path $env:TEMP ('pc2go-ladder-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    # ================================================================== the worker, lifted
    Write-Section '0. The worker''s own functions, and its ladder table'
    $depAll = Get-Content -LiteralPath $WorkerPath -Raw
    $wsStart = $depAll.IndexOf("`$workerScript = @'"); $wsEnd = $depAll.IndexOf("`n'@", $wsStart)
    Assert-True 'the worker here-string was found' ($wsStart -gt 0 -and $wsEnd -gt $wsStart)
    $wText = $depAll.Substring($wsStart + 18, $wsEnd - $wsStart - 18)
    $wAst = [System.Management.Automation.Language.Parser]::ParseInput($wText, [ref]$null, [ref]$null)
    foreach ($fnName in 'Install-One', 'Uninstall-One', 'Start-InstallerWatched', 'Wait-InstallerQuiet', 'Get-OfferableCreated', 'Select-OwnCreated', 'Stop-ProcessTree', 'Test-UninstallGone', 'Get-InstallVerdict', 'Resolve-PackageEntry') {
        $fd = $wAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
        Assert-True "the worker defines $fnName" ($null -ne $fd)
        if ($fd) { . ([scriptblock]::Create($fd.Extent.Text)) }
    }
    . (Join-Path $repo 'tools\Installer-Family.ps1')
    # the ladder table is the worker's, not a copy typed here
    $m = [regex]::Match($wText, '(?s)\$script:SilentSwitchLadder\s*=\s*@\((.*?)\)\r?\n')
    Assert-True 'the worker carries the ladder table' $m.Success
    $script:SilentSwitchLadder = @()
    if ($m.Success) { $script:SilentSwitchLadder = @([regex]::Matches($m.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) }
    Assert-True 'and it has more than ten rungs'               ($script:SilentSwitchLadder.Count -ge 10)
    Assert-Equal 'starting with /S'                            '/S' $script:SilentSwitchLadder[0]
    Assert-True  'NSIS and InstallAware spellings both present' (($script:SilentSwitchLadder -ccontains '/S') -and ($script:SilentSwitchLadder -ccontains '/s'))
    Assert-Equal 'with no duplicate rung'                      $script:SilentSwitchLadder.Count @($script:SilentSwitchLadder | Select-Object -Unique).Count
    # the clocks, shortened for a harness - the worker's defaults are pinned below
    $script:UiGraceSec = 4; $script:LadderGraceSec = 3; $script:UnGraceSec = 4; $script:LadderCapSec = 600
    Assert-True 'the worker''s first-attempt grace is 180 s'   ($wText -match '(?m)^\$script:UiGraceSec\s*=\s*180\b')
    Assert-True 'its rung grace is 45 s'                       ($wText -match '(?m)^\$script:LadderGraceSec\s*=\s*45\b')
    Assert-True 'and the whole ladder is capped at 15 min'     ($wText -match '(?m)^\$script:LadderCapSec\s*=\s*900\b')
    Assert-True 'an .msi never climbs the ladder'              ($wText -match "\`$ladderOn = \(\`$ext -ne '\.msi'\)")

    # the worker's surroundings, stubbed thinly: the record is kept, nothing is elevated
    $script:Status = @(); $script:Activity = @()
    function Write-Status { param($Id, $State, $Detail, $Dirty, $Created) $script:Status += [pscustomobject]@{ State = $State; Detail = ('' + $Detail); Dirty = [bool]$Dirty; Created = @($Created | Where-Object { $_ }) } }
    function Write-Activity { param($Id, $Phase, $State, $Detail) $script:Activity += "$Phase|$State|$Detail" }
    function Resolve-WatchRoots { param($Sid) }
    function Resolve-Reg { param($k) return $k }
    function Invoke-PostInstall { param($App) return @() }
    function Remove-Unpacked { }
    # a real directory watcher on the sandbox, so "created nothing" is a fact about the disk
    $script:WatchRoot = Join-Path $root 'installed'
    New-Item -ItemType Directory -Force -Path $script:WatchRoot | Out-Null
    function Get-DirSnapshot { return @(Get-ChildItem -LiteralPath $script:WatchRoot -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    function Get-CreatedDirs { param($Before) return @(Get-ChildItem -LiteralPath $script:WatchRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $Before -notcontains $_.FullName } | ForEach-Object { $_.FullName }) }
    function Last-Status { if ($script:Status.Count) { return $script:Status[$script:Status.Count - 1] } ; return $null }

    # ================================================================== the fake installer
    Write-Section '1. A real installer that understands exactly one switch'
    #
    # Compiled here as a WinExe. Beside it: switch.txt (the one switch it accepts), mode.txt
    # (what it does with any other: ui, ui:N seconds, exit1, exit0, exit0mkdir, hang), and it
    # appends every launch's arguments to launches.log. With the right switch it creates
    # installed.txt - or deletes it, if it is already there: that is its uninstall.
    $cs = @'
using System; using System.IO; using System.Threading; using System.Windows.Forms;
public class FakeInstaller {
    [STAThread] public static int Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string marker = Path.Combine(dir, "installed.txt");
        File.AppendAllText(Path.Combine(dir, "launches.log"), "[" + string.Join(" ", args) + "]" + Environment.NewLine);
        string want = File.Exists(Path.Combine(dir, "switch.txt")) ? File.ReadAllText(Path.Combine(dir, "switch.txt")).Trim() : "/S";
        string mode = File.Exists(Path.Combine(dir, "mode.txt")) ? File.ReadAllText(Path.Combine(dir, "mode.txt")).Trim() : "ui";
        string got = string.Join(" ", args).Trim();
        if (got == want) {
            if (File.Exists(marker)) File.Delete(marker); else File.WriteAllText(marker, "installed");
            return 0;
        }
        if (mode == "exit1") return 1;
        if (mode == "exit0") return 0;
        if (mode == "exit0mkdir") { Directory.CreateDirectory(Path.Combine(dir, "Partial")); return 0; }
        if (mode == "hang") { Thread.Sleep(60000); return 0; }
        int secs = 60;
        if (mode.StartsWith("ui:")) secs = int.Parse(mode.Substring(3));
        Form f = new Form(); f.Text = "Fake installer - wizard"; f.Width = 420; f.Height = 220;
        System.Windows.Forms.Timer t = new System.Windows.Forms.Timer(); t.Interval = secs * 1000; t.Tick += delegate { f.Close(); }; t.Start();
        Application.Run(f);
        return 2;
    }
}
'@
    $exeSrc = Join-Path $root 'FakeInstaller.exe'
    Add-Type -TypeDefinition $cs -OutputAssembly $exeSrc -OutputType WindowsApplication -ReferencedAssemblies 'System.Windows.Forms' -ErrorAction Stop
    Assert-True 'the fake installer compiled' (Test-Path -LiteralPath $exeSrc)
    $r = Get-InstallerFamily -Path $exeSrc
    Assert-Equal 'and it carries no installer signature, so nothing is proposed for it' '' $r.Family

    # one copy per case: the exe reads its instructions from its own folder
    $script:caseNo = 0
    function New-Case([string]$Switch, [string]$Mode) {
        $script:caseNo++
        $d = Join-Path $script:WatchRoot ("case$($script:caseNo)")
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $d 'FakeInstaller.exe') -Force
        Set-Content -LiteralPath (Join-Path $d 'switch.txt') -Value $Switch -Encoding ASCII -NoNewline
        Set-Content -LiteralPath (Join-Path $d 'mode.txt')   -Value $Mode   -Encoding ASCII -NoNewline
        return $d
    }
    function Get-Launches([string]$Dir) {
        $f = Join-Path $Dir 'launches.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @(Get-Content -LiteralPath $f | ForEach-Object { $_.Trim('[', ']') })
    }
    function New-InstallApp([string]$Dir, [string]$Silent = '', [string]$Source = '') {
        $exe = Join-Path $Dir 'FakeInstaller.exe'
        return [pscustomobject]@{ id = 'fake'; file = $exe; sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
                                  silentArgs = $Silent; silentSource = $Source; installerFamily = ''
                                  verifyPaths = @((Join-Path $Dir 'installed.txt')); entry = ''; postInstall = @()
                                  userSid = ''; chain = $false; after = @() }
    }
    # $Arguments, never $Args: that name is PowerShell's automatic variable and reads back EMPTY
    function New-UninstallApp([string]$Dir, [string]$Arguments = '', [bool]$Silent = $false) {
        return [pscustomobject]@{ id = 'fake'; command = (Join-Path $Dir 'FakeInstaller.exe'); args = $Arguments; silent = $Silent
                                  family = ''; detect = (Join-Path $Dir 'installed.txt'); location = '' }
    }
    function Invoke-Install($app) { $script:Status = @(); $script:Activity = @(); Install-One $app }
    function Invoke-Uninstall($app) { $script:Status = @(); $script:Activity = @(); Uninstall-One $app }
    function Invoke-FakeDirect([string]$Dir, [string]$Switch) {
        # run the fake by hand, as an installer would have been run before this tool met it
        $pr = $(if ($Switch) { Start-Process -FilePath (Join-Path $Dir 'FakeInstaller.exe') -ArgumentList @($Switch) -PassThru -Wait }
                else { Start-Process -FilePath (Join-Path $Dir 'FakeInstaller.exe') -PassThru -Wait })
        Remove-Item -LiteralPath (Join-Path $Dir 'launches.log') -Force -ErrorAction SilentlyContinue
        return $pr.ExitCode
    }

    # ================================================================== 2. the ladder finds it
    Write-Section '2. An unknown installer that opens a window: the ladder finds /S'
    $d = New-Case '/S' 'ui'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Install (New-InstallApp $d)
    $sw.Stop()
    $st = Last-Status
    Assert-Equal 'the row ends Installed'                          'Installed' $st.State
    Assert-True  'and says which switch worked'                    ($st.Detail -like "*installed with the switch '/S', found by trying*")
    Assert-True  'and tells the catalog what to record'            ($st.Detail -like '*put it in the catalog as silentArgs*')
    Assert-True  'the product is on disk'                          (Test-Path -LiteralPath (Join-Path $d 'installed.txt'))
    $L = @(Get-Launches $d)
    Assert-Equal 'launched twice: bare, then /S'                   '|/S' ($L -join '|')
    Assert-True  'the bare run was stopped for its window'         (($script:Activity -join "`n") -match "install\|Ladder\|'' \(.*\) opened a window and was stopped")
    Assert-True  'the rung was announced before it ran'            (($script:Activity -join "`n") -match "install\|Ladder\|trying '/S' \(1 of")
    Assert-True  'and the record says the ladder worked'           (($script:Activity -join "`n") -match "install\|Ladder\|'/S' worked, 1 switch")
    Assert-True  'within the shortened clocks, not the real ones'  ($sw.Elapsed.TotalSeconds -lt 60)
    Assert-True  'the final verdict is clean, not dirty'           ($st.Dirty -eq $false)

    # ================================================================== 3. the catalog first
    Write-Section '3. A catalog switch is always the first rung'
    $d = New-Case '/S' 'exit1'
    Invoke-Install (New-InstallApp $d '/X' 'typed')
    $st = Last-Status
    $L = @(Get-Launches $d)
    Assert-Equal 'the catalog switch ran first'                    '/X' $L[0]
    Assert-Equal 'then the ladder, from its top'                   '/S' $L[1]
    Assert-Equal 'and it landed'                                   'Installed' $st.State
    Assert-True  'the refusal was read off the exit code and the empty disk' (($script:Activity -join "`n") -match "'/X' \(catalog\) exited 1 .* and created nothing - trying the next switch")

    # ================================================================== 4. deep in the ladder
    Write-Section '4. A switch far down the ladder, reached through silent refusals'
    $d = New-Case '--mode unattended' 'exit1'
    Invoke-Install (New-InstallApp $d)
    $st = Last-Status
    $L = @(Get-Launches $d)
    $want = @('') + @($script:SilentSwitchLadder[0..([Array]::IndexOf($script:SilentSwitchLadder, '--mode unattended'))])
    Assert-Equal 'every rung above it was tried, in the table''s order' ($want -join '|') ($L -join '|')
    Assert-Equal 'and the row is Installed'                        'Installed' $st.State
    Assert-True  'naming the rung'                                 ($st.Detail -like "*'--mode unattended'*")

    # ================================================================== 5. usage text, exit 0
    Write-Section '5. An installer that answers a wrong switch with exit 0 and nothing on disk'
    $d = New-Case '/q' 'exit0'
    Invoke-Install (New-InstallApp $d)
    $st = Last-Status
    Assert-Equal 'the clean exit that created nothing was not believed' 'Installed' $st.State
    Assert-True  'the record says why the next rung was tried'     (($script:Activity -join "`n") -match 'exited 0 but created nothing and the verify paths are missing - trying the next switch')
    Assert-True  'and /q is what worked'                           ($st.Detail -like "*'/q'*")

    # ================================================================== 6. nothing works
    Write-Section '6. No rung works: the row fails, and says how many were tried'
    $d = New-Case 'NOPE' 'exit1'
    Invoke-Install (New-InstallApp $d)
    $st = Last-Status
    $L = @(Get-Launches $d)
    Assert-Equal 'the row is Failed'                               'Failed' $st.State
    Assert-Equal 'after every rung'                                (1 + $script:SilentSwitchLadder.Count) $L.Count
    Assert-True  'and the failure counts them'                     ($st.Detail -match "$($script:SilentSwitchLadder.Count) switch\(es\) were tried")
    Assert-Equal 'with nothing created by any of them'             0 @($st.Created).Count

    # ================================================================== 7. the ladder stays off
    Write-Section '7. When the ladder must not run'
    # allowUi: the window is the installer's to show, so a window is not a verdict
    $d = New-Case '/S' 'ui:5'
    $app = New-InstallApp $d
    $app | Add-Member -NotePropertyName allowUi -NotePropertyValue $true
    Invoke-Install $app
    $st = Last-Status
    Assert-Equal 'allowUi: one launch only'                        1 @(Get-Launches $d).Count
    Assert-Equal 'and the exit code is the verdict'                'Failed' $st.State
    Assert-True  'with no ladder in the record'                    (-not (($script:Activity -join "`n") -match 'install\|Ladder\|'))
    # a timeout with no window: the installer may be working, so nothing is retried on top of it
    $d = New-Case '/S' 'hang'
    $app = New-InstallApp $d
    $app | Add-Member -NotePropertyName installTimeoutSec -NotePropertyValue 3
    Invoke-Install $app
    $st = Last-Status
    Assert-Equal 'timeout: one launch only'                        1 @(Get-Launches $d).Count
    Assert-True  'reported as a timeout'                           ($st.Detail -like '*still running after*')
    Assert-True  'and dirty, because it was killed part-way'       $st.Dirty
    # something WAS created: a partial install is never covered by another attempt on top
    $d = New-Case '/S' 'exit0mkdir'
    Invoke-Install (New-InstallApp $d)
    $st = Last-Status
    Assert-Equal 'a run that created a folder is not laddered'     1 @(Get-Launches $d).Count
    Assert-True  'it is reported as unverified, naming the folder' ($st.Detail -like '*could not be verified*Partial*')
    Assert-True  'and nothing is offered for removal'              (-not $st.Dirty)

    # ================================================================== 8. the uninstall ladder
    Write-Section '8. Uninstall: as registered and watched, then the switches, then the window'
    $d = New-Case '/S' 'ui'
    [void](Invoke-FakeDirect $d '/S')
    Assert-True 'the product is installed to begin with' (Test-Path -LiteralPath (Join-Path $d 'installed.txt'))
    Invoke-Uninstall (New-UninstallApp $d '' $false)
    $st = Last-Status
    $L = @(Get-Launches $d)
    Assert-Equal 'the row ends Uninstalled'                        'Uninstalled' $st.State
    Assert-True  'saying which switch removed it'                  ($st.Detail -like "*removed with '/S', found by trying*")
    Assert-Equal 'launched twice: as registered, then with /S'     '|/S' ($L -join '|')
    Assert-True  'the product is gone'                             (-not (Test-Path -LiteralPath (Join-Path $d 'installed.txt')))
    Assert-True  'the watched first run is named in the record'    (($script:Activity -join "`n") -match 'uninstall\|Started\|.*\(as registered, watched\)')
    Assert-True  'and its window was the reason to climb'          (($script:Activity -join "`n") -match 'uninstall\|Ladder\|as registered, watched: opened a window')

    # a string that is silent in fact needs no ladder at all
    $d = New-Case '' 'ui'
    [void](Invoke-FakeDirect $d '')
    Invoke-Uninstall (New-UninstallApp $d '' $false)
    $st = Last-Status
    Assert-Equal 'a registered string that is silent in fact: one launch' 1 @(Get-Launches $d).Count
    Assert-Equal 'and Uninstalled'                                 'Uninstalled' $st.State
    Assert-Equal 'with nothing "found by trying" to report'        '' $st.Detail

    # the family flags said silent: one attempt, and a window is a failure as before
    $d = New-Case '/S' 'ui:5'
    [void](Invoke-FakeDirect $d '/S')
    Invoke-Uninstall (New-UninstallApp $d '/verysilent' $true)
    $st = Last-Status
    Assert-Equal 'a provably-silent uninstall is run once'         1 @(Get-Launches $d).Count
    Assert-Equal 'and its window is allowed, so the exit code decides' 'Failed' $st.State
    Assert-True  'the product is still there'                      (Test-Path -LiteralPath (Join-Path $d 'installed.txt'))

    # nothing works: every rung, then the window for the technician, then the exit code
    $d = New-Case 'NOPE' 'exit1'
    Set-Content -LiteralPath (Join-Path $d 'installed.txt') -Value 'installed' -Encoding ASCII
    Invoke-Uninstall (New-UninstallApp $d '/u' $false)
    $st = Last-Status
    $L = @(Get-Launches $d)
    Assert-Equal 'every rung was tried, then the registered string once more with its window' (2 + $script:SilentSwitchLadder.Count) $L.Count
    Assert-Equal 'the first and the last are the registered string' '/u|/u' ($L[0] + '|' + $L[$L.Count - 1])
    Assert-Equal 'and the row is Failed on the exit code'          'Failed' $st.State
    Assert-True  'naming the code'                                 ($st.Detail -like 'Uninstaller exit code 1*')
    # a registered string that already carries a rung does not get it twice
    $d = New-Case 'NOPE' 'exit1'
    Set-Content -LiteralPath (Join-Path $d 'installed.txt') -Value 'installed' -Encoding ASCII
    Invoke-Uninstall (New-UninstallApp $d '/S' $false)
    $L = @(Get-Launches $d)
    Assert-Equal 'a rung already in the registered string is skipped' 0 @($L | Where-Object { $_ -ceq '/S /S' }).Count

    # ================================================================== 9. pins
    Write-Section '9. Pins on the worker text'
    Assert-True 'the GUI queue sends silent and family to Uninstall-One'  ($depAll -match "silent = \[bool\]\`$s\.IsSilent")
    Assert-True 'Install-One reads the grace from the table, with a default' ($wText -match "\`$graceFirst = \[int\]\`$script:UiGraceSec;\s+if \(\`$graceFirst -le 0\) \{ \`$graceFirst = 180 \}")
    Assert-True 'the uninstall side reads its own first grace'           ($wText -match "\`$script:UnGraceSec;\s+if \(\`$graceFirst -le 0\) \{ \`$graceFirst = 120 \}")
    Assert-True 'a timeout never climbs the ladder'                      ($wText -match "if \(\`$p\.ShowedUi -and \`$haveNext\)")
    Assert-True 'the last uninstall rung is the one with its window'     ($wText -match "Label = 'as registered, with its window'")
} finally {
    # every fake window is closed by its own timer; a hung one is killed by the guard - but a
    # case that failed an assertion mid-run can leave one behind
    Get-Process -Name FakeInstaller -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (Test-Path -LiteralPath $root) { Write-Host "CLEANUP INCOMPLETE: $root" -ForegroundColor Red } else { Write-Host 'All test artefacts removed.' -ForegroundColor DarkGray }
}
Write-Host ''
Write-Host "$($script:Pass)/$($script:Pass + $script:Fail) passed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
