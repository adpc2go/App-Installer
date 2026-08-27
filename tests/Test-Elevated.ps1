<#
.SYNOPSIS
    The parts of the tool that only an elevated session can reach. RUN THIS YOURSELF.

.DESCRIPTION
    Every other harness in this repo stubs Start-Worker to drop -Verb RunAs, because an
    unattended run cannot answer a UAC prompt. That leaves a short, specific list untested, and
    this is it:

      1. the REAL Start-Worker, launching the REAL elevated worker
      2. a machine-wide product in HKLM - discovered, removed, verified
      3. the hosts file - a line found by the leftover scan and removed, with every other line
         left untouched
      4. a Windows service - found and deleted
      5. a scheduled task - found and deleted
      6. another user's profile - deep clean is supposed to sweep every profile, not just the
         technician's, and that has never been proven

    Section 1 runs either way. Sections 2-6 need elevation and are skipped without it, loudly.

    NOT covered even here: Microsoft Store / appx removal. That needs a real Store package to
    remove, and removing one from a working machine is not something a test should do. It stays
    on the untested list until somebody tries it on a spare machine.

    EVERYTHING is reversible. The hosts file is backed up before it is touched and its
    restoration is verified; the service, task, registry key, profile folder and install folder
    are removed in the finally block, which then reports anything that survived.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Elevated.ps1
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

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
# Install Selected and Uninstall Selected now open the pre-flight sheet first, so a press is two
# steps. Guarded rather than unconditional: pressing Install DURING a running batch still extends
# it directly and shows no sheet, and both paths have to keep working.
function Invoke-Commit($Button) {
    Invoke-Click $Button
    if ($PreflightOverlay -and "$($PreflightOverlay.Visibility)" -eq 'Visible') { Invoke-Click $BtnPfGo }
}

function Skip-Test([string]$What) { $script:Skip++; Write-Host ("  SKIP  {0}" -f $What) -ForegroundColor Yellow }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.IO.Compression.FileSystem

$elevated = $false
try {
    $elevated = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$tag       = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox   = Join-Path $env:TEMP "pc2go-elev-$tag"
$token     = "ZephyrLab$tag"      # distinctive, >= 4 chars, matches nothing else on the machine
$progDir   = Join-Path $env:ProgramFiles "PC2GoElevTest-$tag"
$hklmKey   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoTest-$tag"
$svcName   = "PC2GoTestSvc$tag"
$taskPath  = '\PC2GoTest\'
# the token has to be IN the task name, the way a real product names its own task. Called
# something unrelated, the scan is right to ignore it - it has nothing to match on.
$taskName  = "$token-probe"
$otherProf = Join-Path (Split-Path $env:UserProfile) "PC2GoTestProfile-$tag"
$hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsLine = "127.0.0.1  $($token.ToLower()).activation.invalid"
$hostsBak  = Join-Path $sandbox 'hosts.original'
$script:HostsTouched = $false

function Remove-Artefacts {
    # hosts first: it is the only thing here that belongs to the machine rather than to this test
    if ($script:HostsTouched) {
        try {
            $now = @(Get-Content -LiteralPath $hostsFile -ErrorAction Stop)
            if (@($now | Where-Object { $_.Trim() -eq $hostsLine }).Count) {
                Set-Content -LiteralPath $hostsFile -Encoding ASCII -Force `
                            -Value @($now | Where-Object { $_.Trim() -ne $hostsLine })
            }
        } catch {}
    }
    try { if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            & "$env:SystemRoot\System32\sc.exe" delete $svcName | Out-Null } } catch {}
    try { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { if (Test-Path -LiteralPath $hklmKey) { Remove-Item -LiteralPath $hklmKey -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    foreach ($d in @($progDir, $otherProf, $sandbox)) {
        try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host ("Elevated: {0}" -f $elevated) -ForegroundColor $(if ($elevated) { 'Green' } else { 'Yellow' })
    Write-Host "Sandbox : $sandbox" -ForegroundColor DarkGray
    if (-not $elevated) {
        Write-Host ''
        Write-Host 'NOT ELEVATED. Section 1 still runs and WILL raise a real UAC prompt - click' -ForegroundColor Yellow
        Write-Host 'Yes when it appears. Sections 2-6 need elevation and will be skipped.'       -ForegroundColor Yellow
        Write-Host 'For the full run: right-click PowerShell -> Run as administrator.'           -ForegroundColor Yellow
    }

    # Self-healing: an earlier run of this file could only remove its hosts line if the wipe
    # worked, and when the wipe was broken the line stayed behind. Anything matching the marker
    # this file uses is ours, and goes now, before anything else runs.
    if ($elevated) {
        try {
            $cur = @(Get-Content -LiteralPath $hostsFile -ErrorAction Stop)
            $stale = @($cur | Where-Object { $_ -match '(?i)\.activation\.invalid\s*$' })
            if ($stale.Count) {
                Set-Content -LiteralPath $hostsFile -Encoding ASCII -Force `
                            -Value @($cur | Where-Object { $_ -notmatch '(?i)\.activation\.invalid\s*$' })
                Write-Host ("  removed {0} stale test line(s) left in hosts by an earlier run" -f $stale.Count) -ForegroundColor Yellow
            }
        } catch {}
    }

    # ================================================================== extraction
    $src = Get-Content -LiteralPath $ScriptPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    function Get-Fn([string]$Name) {
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
            Select-Object -First 1
        if (-not $fn) { throw "Could not extract $Name" }
        return $fn.Extent.Text
    }

    # ================================================================== 1. the real worker
    Write-Section '1. The REAL elevated worker (this is where the UAC prompt comes from)'

    $server = Join-Path $sandbox 'catalog'
    New-Item -ItemType Directory -Force -Path $server | Out-Null
    $pkgSrc = Join-Path $sandbox 'src\inner'
    New-Item -ItemType Directory -Force -Path $pkgSrc | Out-Null
    $sl = '/'
    $appDir = Join-Path $progDir 'App'
    Set-Content -LiteralPath "$pkgSrc\setup.cmd" -Encoding ASCII -Value ((@(
        '@echo off',
        # writing under %ProgramFiles% IS the proof: an unelevated worker cannot do it
        "mkdir `"$appDir`" 2>nul",
        "echo app > `"$appDir\app.exe`"",
        "exit ${sl}b 0") -join "`r`n"))
    $zip = Join-Path $sandbox 'package.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $pkgSrc -Parent), $zip)
    $catalog = [pscustomobject]@{
        updated = (Get-Date -Format 'yyyy-MM-dd')
        apps = @([pscustomobject]@{ id = 'elev'; name = 'Elevation Probe'; category = 'Apps'
            url = 'https://example.invalid/package.zip'
            sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            sizeBytes = (Get-Item $zip).Length; silentArgs = ''; entry = 'inner\setup.cmd'
            verifyPaths = @("$appDir\app.exe") })
    }
    [IO.File]::WriteAllText((Join-Path $server 'apps.json'), ($catalog | ConvertTo-Json -Depth 8),
                            (New-Object Text.UTF8Encoding $false))

    $goAt = $src.IndexOf('# ---------- go ----------')
    if ($goAt -lt 0) { throw 'Could not find the "go" marker.' }
    . ([scriptblock]::Create($src.Substring(0, $goAt))) `
        -BaseUrl ('file:///' + ($server -replace '\\', '/')) -NoSelfElevate

    $script:CacheDir      = Join-Path $sandbox 'cache'
    New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
    $script:QueuePath     = Join-Path $script:CacheDir 'queue.jsonl'
    $script:StatusPath    = Join-Path $script:CacheDir 'status.jsonl'
    $script:WorkerPath    = Join-Path $script:CacheDir 'worker.ps1'
    $script:CancelPath    = Join-Path $script:CacheDir 'cancel.flag'
    $script:ManifestCache = Join-Path $script:CacheDir 'apps.json'
    $script:IconDir       = Join-Path $script:CacheDir 'icons'
    $timer.Start()

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
    function Invoke-Click($b) {
        $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }

    # NO STUB. This is the real Start-Worker, with -Verb RunAs.
    Load-Catalog
    # Per-app cache folder, NOT the cache root. The pump resolves this app to
    # files\elev\package.zip (Get-AppCachePath); staged at the root it finds nothing, tries to
    # download the catalog's example.invalid URL, and the batch hangs until the timeout - which
    # read exactly like a broken elevated worker. Same fix Test-GuiBatch's Set-StagedPackage got
    # when the cache went per-app.
    $elevCache = Join-Path (Join-Path $script:CacheDir 'files') 'elev'
    New-Item -ItemType Directory -Force -Path $elevCache | Out-Null
    Copy-Item -LiteralPath $zip -Destination (Join-Path $elevCache 'package.zip') -Force
    $script:Items[0].IsSelected = $true
    Write-Host '  clicking Install - approve the UAC prompt if one appears...' -ForegroundColor Yellow
    Invoke-Commit $BtnInstall
    $done = Wait-For { $script:Phase -in 'Done', 'Idle' -or "$($WipeOverlay.Visibility)" -eq 'Visible' } 300000
    Assert-True 'the batch completed with the real worker' $done
    Assert-True 'the row reports Installed'                ($script:Items[0].Status -like 'Installed*')
    # the real proof: %ProgramFiles% is not writable without elevation
    Assert-True 'and it wrote into %ProgramFiles%, which needs elevation' (Test-Path -LiteralPath "$appDir\app.exe")

    if (-not $elevated) {
        Write-Section 'Sections 2-6 need elevation'
        foreach ($s in 'a machine-wide HKLM product', 'the hosts file', 'a Windows service',
                       'a scheduled task', "another user's profile") { Skip-Test $s }
    } else {
        # ============================================================== 2. HKLM product
        Write-Section '2. A machine-wide product in HKLM'

        foreach ($n in 'Format-Size', 'Get-FolderSize', 'ConvertTo-PSRegPath', 'AsText',
                       'Clean-DisplayName', 'Parse-UninstallString', 'ConvertTo-Int',
                       'Get-InstalledPrograms') {
            . ([scriptblock]::Create((Get-Fn $n)))
        }
        $mDir = Join-Path $progDir 'Zephyr Lab'
        New-Item -ItemType Directory -Force -Path $mDir | Out-Null
        Set-Content -LiteralPath "$mDir\zephyr.exe" -Value 'binary' -Encoding ASCII
        $mUnDir = Join-Path $progDir 'Uninstall'
        New-Item -ItemType Directory -Force -Path $mUnDir | Out-Null
        $mUn = Join-Path $mUnDir 'uninstall.cmd'
        Set-Content -LiteralPath $mUn -Encoding ASCII -Value ((@(
            '@echo off',
            "reg delete `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PC2GoTest-$tag`" /f >nul 2>&1",
            "rd /s /q `"$mDir`"", 'exit /b 0') -join "`r`n"))
        New-Item -Path $hklmKey -Force | Out-Null
        Set-ItemProperty -Path $hklmKey -Name 'DisplayName'     -Value "$token Suite"
        Set-ItemProperty -Path $hklmKey -Name 'DisplayVersion'  -Value '4.0'
        Set-ItemProperty -Path $hklmKey -Name 'Publisher'       -Value 'PC2Go Test Fixtures'
        Set-ItemProperty -Path $hklmKey -Name 'InstallLocation' -Value $mDir
        Set-ItemProperty -Path $hklmKey -Name 'UninstallString' -Value "`"$mUn`""

        $found = @(Get-InstalledPrograms | Where-Object { $_.Name -eq "$token Suite" }) | Select-Object -First 1
        Assert-True  'an HKLM product is discovered' ($null -ne $found)
        Assert-Equal 'with its install location'     $mDir $found.Location

        Remove-Item -LiteralPath $script:QueuePath -Force -ErrorAction SilentlyContinue
        Add-Content -LiteralPath $script:QueuePath -Encoding UTF8 -Value (@{
            id = 'zephyr'; action = 'uninstall'; command = $found.Exe; args = $found.Args
            detect = "$mDir\zephyr.exe"; location = $mDir } | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $script:QueuePath -Encoding UTF8 -Value '{"end":true}'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
            "`"$script:WorkerPath`"", '-QueueFile', "`"$script:QueuePath`"", '-StatusFile',
            "`"$script:StatusPath`"", '-CancelFile', "`"$script:CancelPath`"") | Out-Null
        Assert-True 'the machine-wide product was removed' (-not (Test-Path -LiteralPath $mDir))
        Assert-True 'and its HKLM key with it'             (-not (Test-Path -LiteralPath $hklmKey))

        # ============================================================== 3-6. the wipe targets
        Write-Section '3-6. hosts line, service, scheduled task, another profile'

        # Test-ProtectedPath before Scan-Leftovers: the scan calls it on every file target, and
        # lifting the caller without the helper throws CommandNotFound on the first one
        foreach ($n in 'Test-ProtectedPath', 'Scan-Leftovers', 'Set-Status', 'Set-Ring') { . ([scriptblock]::Create((Get-Fn $n))) }
        $script:ProtectedPaths = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$script:ProtectedPaths' }, $true) |
            Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
        $script:SharedComponentHints = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$script:SharedComponentHints' }, $true) |
            Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) })
        $script:ScanLabel = 'elevated test'

        # ---- hosts, backed up before anything is written to it
        Copy-Item -LiteralPath $hostsFile -Destination $hostsBak -Force
        $originalHosts = @(Get-Content -LiteralPath $hostsFile)
        Add-Content -LiteralPath $hostsFile -Value $hostsLine -Encoding ASCII
        $script:HostsTouched = $true
        Assert-Equal 'the hosts line is in place' 1 @(Get-Content -LiteralPath $hostsFile | Where-Object { $_.Trim() -eq $hostsLine }).Count

        # ---- a service
        & "$env:SystemRoot\System32\sc.exe" create $svcName binPath= "$env:SystemRoot\System32\cmd.exe /c exit" DisplayName= "$token Helper" | Out-Null
        Assert-True 'the test service exists' ($null -ne (Get-Service -Name $svcName -ErrorAction SilentlyContinue))

        # ---- a scheduled task
        $act = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c exit'
        $trg = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $act -Trigger $trg -Force | Out-Null
        Assert-True 'the test task exists' ($null -ne (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue))

        # ---- another user's profile: the sweep must cover every profile, not just ours
        $otherData = Join-Path $otherProf "AppData\Roaming\$token"
        New-Item -ItemType Directory -Force -Path $otherData | Out-Null
        Set-Content -LiteralPath (Join-Path $otherData 'settings.ini') -Value 'x' -Encoding ASCII

        $item = New-Object AppItem
        $item.Id = 'zephyr'; $item.Name = "$token Suite"
        $item.CleanPaths = @(); $item.CleanReg = @(); $item.CreatedPaths = @()
        $item.CleanHosts = @($hostsLine)
        $item.CleanTokens = @($token)
        $hits = @(Scan-Leftovers $item $true)
        foreach ($h in $hits) { Write-Host ("    {0,-9} {1}" -f $h.Kind, $h.Path) -ForegroundColor DarkGray }

        # the task is the one that keeps failing - show exactly what the system calls it and
        # whether the same path can be looked back up, instead of guessing
        $rawTask = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                     Where-Object { $_.TaskName -like "*$token*" -or $_.TaskPath -like "*$token*" }) | Select-Object -First 1
        if ($rawTask) {
            $full = '' + $rawTask.TaskPath + $rawTask.TaskName
            $leaf = Split-Path $full -Leaf
            $par  = Split-Path $full -Parent
            if (-not $par.EndsWith('\')) { $par += '\' }
            $probe = $null
            try { $probe = Get-ScheduledTask -TaskName $leaf -TaskPath $par -ErrorAction Stop }
            catch { Write-Host ("    re-lookup threw: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
            Write-Host ("    task: name='{0}' path='{1}' joined='{2}'" -f $rawTask.TaskName, $rawTask.TaskPath, $full) -ForegroundColor Yellow
            Write-Host ("    split back: leaf='{0}' path='{1}'  found again: {2}" -f $leaf, $par, [bool]$probe) -ForegroundColor Yellow
        } else {
            Write-Host '    the system lists NO task matching the token' -ForegroundColor Yellow
        }

        $hSvc  = @($hits | Where-Object { $_.Type -eq 'service' -and $_.Path -eq $svcName }) | Select-Object -First 1
        $hTask = @($hits | Where-Object { $_.Type -eq 'task' -and $_.Path -like "*$taskName*" }) | Select-Object -First 1
        $hHost = @($hits | Where-Object { $_.Type -eq 'hosts' }) | Select-Object -First 1
        $hProf = @($hits | Where-Object { $_.Path -eq $otherData }) | Select-Object -First 1
        Assert-True 'the scan found the service'              ($null -ne $hSvc)
        Assert-True 'the scan found the scheduled task'       ($null -ne $hTask)
        Assert-True 'the scan found the hosts line'           ($null -ne $hHost)
        Assert-True "the scan reached ANOTHER user's profile" ($null -ne $hProf)

        # ---- approve them all and wipe, through the real worker
        Remove-Item -LiteralPath $script:QueuePath -Force -ErrorAction SilentlyContinue
        $targets = @($hits | ForEach-Object { @{ type = $_.Type; path = $_.Path; name = $_.Name } })
        Add-Content -LiteralPath $script:QueuePath -Encoding UTF8 -Value (@{
            id = 'zephyr'; action = 'wipe'; targets = $targets } | ConvertTo-Json -Compress -Depth 5)
        Add-Content -LiteralPath $script:QueuePath -Encoding UTF8 -Value '{"end":true}'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
            "`"$script:WorkerPath`"", '-QueueFile', "`"$script:QueuePath`"", '-StatusFile',
            "`"$script:StatusPath`"", '-CancelFile', "`"$script:CancelPath`"") | Out-Null

        Assert-True 'the service is gone'               ($null -eq (Get-Service -Name $svcName -ErrorAction SilentlyContinue))
        Assert-True 'the scheduled task is gone'        ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue))
        Assert-True "the other profile's data is gone"  (-not (Test-Path -LiteralPath $otherData))
        $nowHosts = @(Get-Content -LiteralPath $hostsFile)
        Assert-True 'the hosts line is gone' (-not @($nowHosts | Where-Object { $_.Trim() -eq $hostsLine }).Count)
        # the assertion that matters most: the machine's own hosts entries survive untouched
        Assert-Equal 'and every original hosts line survived' '' `
                     ((@($originalHosts | Where-Object { $_ -notin $nowHosts })) -join ' | ')
        # Only stand the cleanup down if the wipe REALLY removed it. Assuming it did is how the
        # first run of this file left a line behind on the machine: the assertion failed, and
        # the flag had already been cleared regardless.
        if (-not @($nowHosts | Where-Object { $_.Trim() -eq $hostsLine }).Count) { $script:HostsTouched = $false }
    }

    Write-Host ''
    Write-Host ("{0}/{1} passed, {2} skipped" -f $script:Pass, ($script:Pass + $script:Fail), $script:Skip) `
               -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
} finally {
    if ($KeepArtefacts) { Write-Host "Artefacts kept: $sandbox" -ForegroundColor Yellow }
    else {
        Remove-Artefacts
        $left = @()
        foreach ($p in @($progDir, $otherProf, $hklmKey)) { if (Test-Path -LiteralPath $p) { $left += $p } }
        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { $left += "service $svcName" }
        try { if (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue) { $left += "task $taskName" } } catch {}
        try { if (@(Get-Content -LiteralPath $hostsFile -ErrorAction Stop | Where-Object { $_.Trim() -eq $hostsLine }).Count) { $left += 'hosts line' } } catch {}
        if ($left.Count) { Write-Host ("CLEANUP INCOMPLETE: " + ($left -join '; ')) -ForegroundColor Red }
        else { Write-Host 'All test artefacts removed from this machine.' -ForegroundColor DarkGray }
    }
}
