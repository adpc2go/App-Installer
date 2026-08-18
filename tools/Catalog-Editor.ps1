<#
.SYNOPSIS
    Catalog editor for apps.json - a list, and one dialog to add or edit an application.

.DESCRIPTION
    Deliberately a SEPARATE tool, not a tab in AppDeploy.ps1. That file is downloaded onto
    every client machine; catalog editing has no business travelling with it.

    The rule here is that the editor asks only what a person actually knows, and works the
    rest out itself:

      * You give a download URL. It fetches the file in the background, hashes it, records
        the size, and - if it is a zip - reads the archive to find the installer inside.
        setup.exe / install.exe / run.exe / *.msi are ranked and offered, because which one
        it is differs per vendor and guessing wrong fails the install.
      * Cleanup targets are derived from the name and never shown. They are only ever a
        SEARCH for leftovers, and every hit is reviewed on screen before anything is deleted,
        so there is nothing for a human to approve here in advance.
      * sizeBytes and sha256 are computed from the real bytes, never typed.
      * The catalog is saved without a BOM. PowerShell 5.1's Set-Content -Encoding UTF8
        writes one, and a BOM makes Invoke-RestMethod hand the tool a raw string instead of
        parsed JSON - the catalog then shows as one blank row under a green "Live catalog".

    Fields it has no UI for (uninstall, iconUrl, icon, _installNote) survive untouched: the
    JSON is edited in place as parsed objects, never rebuilt from a model of it. The same is
    true of post-install steps it cannot edit - a kill, a registry write, a service - which are
    listed so their ORDER is visible and movable, and written back byte for byte.

.EXAMPLE
    powershell -NoP -EP Bypass -File tools\Catalog-Editor.ps1
#>
[CmdletBinding()]
param(
    [string]$CatalogPath,
    [string]$PackageDir,
    [string]$BaseUrl = 'https://apps.example.com'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# only for FolderBrowserDialog - WPF has no folder picker of its own
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# $PSScriptRoot is EMPTY inside a param default whenever the script is an advanced one -
# [CmdletBinding()] makes defaults evaluate in the CALLER's scope, which has no script root.
# The identical param block without [CmdletBinding()] works, which is what makes this worth
# a comment. Resolve in the body, where $PSScriptRoot is real.
$script:ToolsDir = $PSScriptRoot
if (-not $script:ToolsDir -and $MyInvocation.MyCommand.Path) {
    $script:ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:ToolsDir) { $script:ToolsDir = (Get-Location).Path }
$script:RepoRoot = Split-Path -Parent $script:ToolsDir
if (-not $script:RepoRoot) { $script:RepoRoot = $script:ToolsDir }
if (-not (Test-Path (Join-Path $script:RepoRoot 'server\apps.json')) -and
         (Test-Path (Join-Path $script:ToolsDir 'server\apps.json'))) {
    $script:RepoRoot = $script:ToolsDir
}
if (-not $CatalogPath) { $CatalogPath = Join-Path $script:RepoRoot 'server\apps.json' }
if (-not $PackageDir)  { $PackageDir  = Join-Path $script:RepoRoot 'packages' }

$script:Catalog = $null
$script:Dirty   = $false

# ---------------------------------------------------------------- field helpers

function Get-Field($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    $p = $obj.PSObject.Properties[$name]
    if (-not $p) { return '' }
    return $p.Value
}

# Assigns onto the parsed object, adding the property only when genuinely new. This is what
# keeps unknown fields alive across a save: nothing is ever rebuilt from scratch.
function Set-Field($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Remove-Field($obj, [string]$name) {
    if ($obj.PSObject.Properties[$name]) { $obj.PSObject.Properties.Remove($name) }
}

# WPF hands back $null - not '' - for an editable ComboBox that has no items and has never been
# typed into, so the obvious $ctl.Text.Trim() throws "You cannot call a method on a null-valued
# expression" on precisely the fields a BRAND-NEW app leaves empty. It cost the after-install
# list its Add button: the throw landed on the first line of that handler, before the row was
# added, so nothing appeared in the list, nothing could be selected, and the Move / Run radios
# stayed greyed out with no way in. Every box is read through here.
function Get-BoxText($ctl) { return ('' + $ctl.Text).Trim() }

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    if ($b -ge 1KB) { return "{0:N0} KB" -f ($b / 1KB) }
    return "$b B"
}

function ConvertTo-Id([string]$text) { ($text -replace '[^A-Za-z0-9]+', '-').ToLower().Trim('-') }

function Test-RealHash([string]$sha) { return ($sha -match '^[0-9A-Fa-f]{64}$') }

# The verify path is "a file that proves this installed". Rather than have somebody type one
# from memory, look it up: if the product is on THIS machine, its uninstall key already knows
# where it lives and the main executable is sitting in that folder. Guesses from the name are
# offered as a fallback, and everything stays editable - this proposes, it does not decide.
function Get-VerifyCandidates([string]$name) {
    $out = @()
    if (-not $name) { return $out }
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    # the first real word is enough of a handle: "Revit 2026" should still find "Autodesk Revit"
    $needle = ($name -split '\s+' | Where-Object { $_.Length -ge 4 } | Select-Object -First 1)
    if (-not $needle) { $needle = $name }
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
            $dn = [string]$props.DisplayName
            if (-not $dn -or $dn -notlike "*$needle*") { continue }
            $loc = [string]$props.InstallLocation
            if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { continue }
            # the biggest executable in the install folder is nearly always the product itself
            foreach ($exe in @(Get-ChildItem -LiteralPath $loc -Filter *.exe -ErrorAction SilentlyContinue |
                               Sort-Object Length -Descending | Select-Object -First 2)) {
                $out += $exe.FullName
            }
        }
    }
    # plain guesses, in case the product is not installed here
    foreach ($base in @('%ProgramFiles%', '%ProgramFiles(x86)%')) {
        $out += "$base\$name\$($name -replace '\s+', '').exe"
    }
    return @($out | Select-Object -Unique)
}

# ---------------------------------------------------------------- background work
# Fetching and hashing a multi-GB package takes minutes. On the UI thread that freezes the
# window into a "not responding" ghost, which reads as a crash - so it runs in a runspace and
# is polled, the same shape the installer itself uses for downloads.

$script:FetchWork = {
    param($Source, $CacheDir)
    try {
        $local = $Source
        # a URL is fetched once into the package folder; a local path is used where it lies
        if ($Source -match '^https?://') {
            if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
            $name = [IO.Path]::GetFileName(([Uri]$Source).LocalPath)
            if (-not $name) { $name = 'package.bin' }
            $local = Join-Path $CacheDir $name
            if (-not (Test-Path -LiteralPath $local)) {
                $wc = New-Object Net.WebClient
                $wc.DownloadFile($Source, $local)
                $wc.Dispose()
            }
        }
        if (-not (Test-Path -LiteralPath $local)) { return @{ error = "not found: $local" } }
        # Read what is inside the package: which installer to run, and every file, so the
        # after-install copy can be picked instead of typed.
        #
        # .NET reads Deflate and Stored ONLY. 7-Zip and WinRAR default to LZMA, BZip2 or Zstd,
        # and such a package throws "unsupported compression method" - which is what a real
        # Autodesk zip did. Windows ships bsdtar with those codecs linked in, so it lists what
        # .NET cannot. Same fallback the worker uses to unpack it, so the two agree.
        $entries = @()
        $files = @()
        $packager = ''
        $silent = ''
        $isZip = ([IO.Path]::GetExtension($local).ToLower() -eq '.zip')
        $names = @()
        $topEntry = $null
        if ($isZip) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = $null
            try {
                $zip = [IO.Compression.ZipFile]::OpenRead($local)
                $names = @($zip.Entries | Where-Object { $_.Name } |
                           ForEach-Object { ($_.FullName -replace '/', '\') })
            } catch { $names = @() }
            if (-not $names.Count) {
                if ($zip) { try { $zip.Dispose() } catch {}; $zip = $null }
                $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
                if (Test-Path -LiteralPath $tarExe) {
                    $names = @(& $tarExe -tf $local 2>$null |
                               ForEach-Object { ($_ -replace '/', '\') } |
                               Where-Object { $_ -and -not $_.EndsWith('\') })
                }
                if (-not $names.Count) { return @{ error = 'this archive could not be read - not a zip, or damaged' } }
                $packager = 'zip read via tar (codec .NET cannot open)'
            }
            $files = @($names | Sort-Object)
            # Name first, depth second. setup.exe is the near-universal answer and beats a
            # shallower file with a vaguer name; depth only breaks ties. Split on BOTH
            # separators - .NET writes backslashes into entry names while the spec says
            # forward slash, and splitting on one alone kills the tiebreak silently.
            $entries = @($names | Where-Object { $_ -match '\.(exe|msi)$' } |
                Sort-Object @{ e = { switch -Regex ([IO.Path]::GetFileName($_).ToLower()) {
                                        '^set-?up\.(exe|msi)$'      { 0 }
                                        '^install(er)?\.(exe|msi)$' { 1 }
                                        '^run\.(exe|msi)$'          { 2 }
                                        '\.msi$'                    { 3 }
                                        default                     { 4 } } } },
                            @{ e = { ($_ -split '[\\/]').Count } },
                            @{ e = { [IO.Path]::GetFileName($_) } })
            # Packager sniffing needs the installer's own bytes, which only the .NET reader can
            # reach here. Via tar it is skipped rather than guessed - a wrong silent switch is
            # worse than an empty field, because it fails on a client instead of on screen.
            if ($zip -and $entries.Count) {
                try {
                    $topEntry = $zip.Entries | Where-Object { ($_.FullName -replace '/', '\') -eq $entries[0] } | Select-Object -First 1
                    if ([IO.Path]::GetExtension($entries[0]).ToLower() -eq '.msi') {
                        $packager = 'Windows Installer (MSI)'
                        $silent = ''    # the worker adds /qn /norestart to every .msi itself
                    } elseif ($topEntry) {
                        $st = $topEntry.Open()
                        try {
                            $buf = New-Object byte[] (4 * 1024 * 1024)
                            $read = $st.Read($buf, 0, $buf.Length)
                            $blob = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
                        } finally { $st.Dispose() }
                        if     ($blob -match 'Nullsoft Install System') { $packager = 'NSIS'; $silent = '/S' }
                        elseif ($blob -match 'Inno Setup Setup Data|JR\.Inno\.Setup') { $packager = 'Inno Setup'; $silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
                        elseif ($blob -match 'InstallShield')     { $packager = 'InstallShield';   $silent = '/s /v"/qn REBOOT=ReallySuppress"' }
                        elseif ($blob -match 'wixburn|WixBundle') { $packager = 'WiX Burn bundle'; $silent = '/quiet /norestart' }
                        elseif ($blob -match 'AdODIS|Autodesk')   { $packager = 'Autodesk (ODIS)'; $silent = '--silent' }
                    }
                } catch { }
            }
            if ($zip) { try { $zip.Dispose() } catch {} }
        }
        @{ sha256   = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
           size     = (Get-Item -LiteralPath $local).Length
           file     = $local
           entries  = $entries
           files    = $files
           packager = $packager
           silent   = $silent }
    } catch { @{ error = $_.Exception.Message } }
}

# ---------------------------------------------------------------- catalog I/O

function Test-App($a) {
    # what stops THIS app from being published, in words a person can act on
    $out = @()
    if (-not (Get-Field $a 'name')) { $out += 'no name' }
    if (-not (Get-Field $a 'url'))  { $out += 'no download URL' }
    if (-not (Test-RealHash ([string](Get-Field $a 'sha256')))) { $out += 'not hashed yet' }
    if ([long](Get-Field $a 'sizeBytes') -le 0) { $out += 'size unknown' }
    $isZip = ([string](Get-Field $a 'url')).ToLower().EndsWith('.zip')
    if ($isZip -and -not (Get-Field $a 'entry')) { $out += 'no setup file chosen inside the package' }
    if ((Get-Field $a 'entry') -and -not $isZip) { $out += 'has a setup file but the URL is not a .zip' }
    # an after-install step taking its file OUT of the package needs there to BE a package -
    # the worker refuses `from` on a single installer, and it would refuse it on a client
    if (@(@(Get-Field $a 'postInstall') | Where-Object { $_ -and (Get-Field $_ 'from') }).Count -and
        -not (Get-Field $a 'entry')) { $out += 'after-install steps need a package (.zip) with a setup file' }
    return $out
}

function Import-Catalog {
    if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "No catalog at $CatalogPath" }
    $raw = Get-Content -LiteralPath $CatalogPath -Raw
    $script:Catalog = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if (-not $script:Catalog.apps) { throw 'Catalog has no apps array.' }
    Update-List
}

function Export-Catalog {
    # Saving WARNS, publishing REFUSES. A catalog is half-finished for most of its life, so a
    # validator that blocked saving would make the editor useless on real work in progress.
    $bad = @()
    foreach ($a in @($script:Catalog.apps)) {
        $p = Test-App $a
        if ($p.Count) { $bad += "$([string](Get-Field $a 'name')) - $($p -join ', ')" }
    }
    # A catalog is half-finished for most of its life, which is exactly why saving warns and
    # only publishing refuses. It used to ASK - a modal "save anyway?" on every save of a
    # work-in-progress catalog, which is the friction the warn/refuse split exists to avoid,
    # and which no unattended run could ever answer. It now saves and says what is not ready.
    Copy-Item -LiteralPath $CatalogPath -Destination "$CatalogPath.bak" -Force
    Set-Field $script:Catalog 'updated' (Get-Date -Format 'yyyy-MM-dd')
    # _localFile is where the bytes were on the machine that BUILT the catalog. It means nothing
    # on a client and would leak a local path into a published file, so it never gets written.
    foreach ($a in @($script:Catalog.apps)) { Remove-Field $a '_localFile' }
    # WriteAllText with UTF8Encoding($false), never Set-Content -Encoding UTF8, which adds a
    # BOM that stops Invoke-RestMethod parsing the catalog as JSON at all
    [IO.File]::WriteAllText($CatalogPath, ($script:Catalog | ConvertTo-Json -Depth 10),
                            (New-Object Text.UTF8Encoding $false))
    $script:Dirty = $false
    if ($bad.Count) {
        $first = (@($bad) | Select-Object -First 2) -join '; '
        if ($bad.Count -gt 2) { $first += "; +$($bad.Count - 2) more" }
        Set-StatusText ("Saved $(@($script:Catalog.apps).Count) app(s), but $($bad.Count) are not ready to publish - $first") '#FFFBBF24'
    } else {
        Set-StatusText "Saved $(@($script:Catalog.apps).Count) app(s). Previous copy kept as apps.json.bak." '#FF34D399'
    }
    return $true
}

# ---------------------------------------------------------------- bulk import
# Adding twenty applications used to mean twenty trips through the dialog, each one waiting on
# a hash that can take minutes. Point at a folder instead: every installer in it becomes an
# entry immediately, and they are hashed one after another in the background while the list
# stays usable. One at a time on purpose - these are multi-GB files, and hashing six at once
# just makes all six slow.
$script:BulkQueue   = New-Object Collections.ArrayList
$script:BulkCurrent = $null
$script:BulkJob     = $null
$script:BulkHandle  = $null
$script:BulkDone    = 0
$script:BulkTotal   = 0

function Start-BulkNext {
    if ($script:BulkJob -or -not $script:BulkQueue.Count) { return }
    $app = $script:BulkQueue[0]
    $script:BulkQueue.RemoveAt(0)
    $script:BulkCurrent = $app
    $script:BulkJob = [powershell]::Create()
    [void]$script:BulkJob.AddScript($script:FetchWork).
           AddArgument([string](Get-Field $app '_localFile')).AddArgument($PackageDir)
    $script:BulkHandle = $script:BulkJob.BeginInvoke()
    Update-List
}

function Complete-BulkOne {
    $r = $null
    try { $r = $script:BulkJob.EndInvoke($script:BulkHandle) | Select-Object -Last 1 }
    catch { $r = @{ error = $_.Exception.Message } }
    try { $script:BulkJob.Dispose() } catch {}
    $script:BulkJob = $null; $script:BulkHandle = $null
    $app = $script:BulkCurrent
    $script:BulkCurrent = $null
    $script:BulkDone++
    if ($app -and $r -and -not $r.error) {
        Set-Field $app 'sha256' ([string]$r.sha256)
        Set-Field $app 'sizeBytes' ([long]$r.size)
        # proposed, never forced - the same rule the dialog follows
        if (@($r.entries).Count -and -not (Get-Field $app 'entry')) { Set-Field $app 'entry' (@($r.entries)[0]) }
        if ($r.silent -and -not (Get-Field $app 'silentArgs')) { Set-Field $app 'silentArgs' ([string]$r.silent) }
        # a verify path only if the product is genuinely on THIS machine; a guess here would be
        # indistinguishable from a checked fact later
        if (-not @(Get-Field $app 'verifyPaths').Count) {
            $real = @(Get-VerifyCandidates ([string](Get-Field $app 'name')) |
                      Where-Object { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_)) })
            if ($real.Count) { Set-Field $app 'verifyPaths' @($real[0]) }
        }
    }
    $script:Dirty = $true
    Update-List
    if ($script:BulkQueue.Count -or $script:BulkJob) {
        Set-StatusText "Hashing $($script:BulkDone + 1) of $($script:BulkTotal)..." '#FF4C8DFF'
    } else {
        Set-StatusText "Added $($script:BulkTotal) application(s) from the folder. Review each one, then save." '#FF34D399'
    }
}

function Set-StatusText([string]$text, [string]$colour = '#FFB6B6C0') {
    $TxtStatus.Text = $text
    $TxtStatus.Foreground = $colour
}

# ---------------------------------------------------------------- overlay, not MessageBox
# The answer arrives through a callback rather than a return value, because the window keeps
# running underneath. That is the whole point: a modal MessageBox stops everything until a
# person clicks it, which makes every path behind one impossible to test and hangs any
# unattended run outright.
$script:ConfirmAction = $null

function Show-Notice([string]$Title, [string]$Body) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayBody.Text = $Body
    $BtnOverlayCancel.Visibility = 'Collapsed'
    $BtnOverlayOk.Content = 'OK'
    $script:ConfirmAction = $null
    $Overlay.Visibility = 'Visible'
}

function Remove-App($App, [string]$Name) {
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $App })
    $script:Dirty = $true
    Update-List
    Set-StatusText "Removed $Name. Nothing is written to disk until you save."
}

function Show-Confirm([string]$Title, [string]$Body, [string]$OkText, [scriptblock]$OnConfirm) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayBody.Text = $Body
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = $OkText
    $script:ConfirmAction = $OnConfirm
    $Overlay.Visibility = 'Visible'
}

function Update-List {
    $sel = $ListApps.SelectedIndex
    $rows = @(@($script:Catalog.apps) | ForEach-Object {
        $p = Test-App $_
        # an app still queued for hashing is not "missing a hash" - it is mid-flight, and
        # listing it as a problem reads like something went wrong
        $busy = ''
        if ($script:BulkCurrent -eq $_) { $busy = 'hashing...' }
        elseif (@($script:BulkQueue) -contains $_) { $busy = 'waiting to hash' }
        [pscustomobject]@{
            App    = $_
            Name   = [string](Get-Field $_ 'name')
            Detail = $(if ($busy) { $busy }
                       elseif ($p.Count) { ($p -join ', ') }
                       else { "$(Format-Size ([long](Get-Field $_ 'sizeBytes')))   ready" })
            Colour = $(if ($busy) { '#FF4C8DFF' } elseif ($p.Count) { '#FFFBBF24' } else { '#FF6E6E7A' })
        }
    })
    $ListApps.ItemsSource = $rows
    if ($sel -ge 0 -and $sel -lt $rows.Count) { $ListApps.SelectedIndex = $sel }
    elseif ($rows.Count) { $ListApps.SelectedIndex = 0 }
    $ready = @($rows | Where-Object { $_.Detail -like '*ready*' }).Count
    Set-StatusText "$($rows.Count) app(s), $ready ready to publish"
}

# ---------------------------------------------------------------- after-install rows
# The catalog's `postInstall` is an array and always was - the worker runs every step, in
# order, once the install has verified. What this dialog could SHOW was one step, so an app
# needing two files in two directories had to be hand-edited, and the next edit through the
# dialog then had to be careful not to eat the extra one. A list is the honest shape.
#
# Every step becomes a row. Rows this dialog understands - a copy or a run taking its file OUT
# of the package - are edited here. Anything else (a kill, a registry write, a service, a copy
# from an absolute path) is shown but carried back out untouched, because ORDER is the whole
# point of a list: kill the running app first, THEN drop the file in. A step that could not be
# seen could not be positioned.

# The worker keeps the source filename only when it can tell the destination is a folder, and
# the trailing slash is what tells it. A last part with an extension is a rename, so it is left
# exactly as typed.
function Format-PostDest([string]$dest) {
    $d = ('' + $dest).Trim()
    if (-not $d) { return '' }
    if ($d.EndsWith('\')) { return $d }
    if (-not [IO.Path]::GetExtension($d)) { return $d.TrimEnd('\') + '\' }
    return $d
}

# what a step this dialog does not edit says about itself, so it can still be read in the list
function Get-PostStepSummary($step) {
    $kept = '   (kept as written)'
    $t = ('' + (Get-Field $step 'type')).ToLower()
    switch ($t) {
        'kill' {
            $w = @(@((Get-Field $step 'name'), (Get-Field $step 'folder')) | Where-Object { $_ }) -join ' + '
            return "KILL  $w$kept"
        }
        'registry' { return "REG   $(Get-Field $step 'path') -> $(Get-Field $step 'name')$kept" }
        'service'  { return "SVC   $(Get-Field $step 'action') $(Get-Field $step 'name')$kept" }
        'copy'     { return "COPY  $(Get-Field $step 'file')  ->  $(Get-Field $step 'dest')$kept" }
        'run'      { return "RUN   $(Get-Field $step 'file')$kept" }
        'powershell' { return "PS    $(Get-Field $step 'command')$kept" }
    }
    if ($t) { return "$($t.ToUpper())$kept" }
    return "(a step with no type)$kept"
}

function Update-PostRowText($row) {
    $f = $(if ($row.From) { [string]$row.From } else { '(no file chosen)' })
    switch ($row.Kind) {
        'copy'  { $row.Text = "MOVE  $f  ->  $(if ($row.Dest) { [string]$row.Dest } else { '(nowhere yet)' })" }
        'run'   { $row.Text = "RUN   $f" }
        'powershell' {
            # one line in the list however many the command runs to, or a five-line script
            # would push every other action off the screen
            $one = (('' + $row.Cmd) -replace '\s+', ' ').Trim()
            if (-not $one) { $one = '(no command yet)' }
            if ($one.Length -gt 64) { $one = $one.Substring(0, 61) + '...' }
            $row.Text = "PS    $one"
        }
        default { $row.Text = Get-PostStepSummary $row.Obj }
    }
}

function New-PostRow([string]$kind, [string]$from, [string]$dest, $obj, [string]$cmd = '') {
    $row = [pscustomobject]@{ Kind = $kind; From = $from; Dest = $dest; Cmd = $cmd; Obj = $obj; Text = '' }
    Update-PostRowText $row
    return $row
}

# Reads an app's steps into rows. Nothing is copied out of a step except the two fields the
# dialog edits - the parsed object itself travels in the row, so an edit changes only what was
# actually edited, and a cancelled dialog changes nothing at all.
function Get-PostRows($App) {
    $rows = New-Object Collections.ArrayList
    foreach ($s in @(@(Get-Field $App 'postInstall') | Where-Object { $_ })) {
        $t = ('' + (Get-Field $s 'type')).ToLower()
        if ($t -eq 'powershell') {
            [void]$rows.Add((New-PostRow 'powershell' '' '' $s ([string](Get-Field $s 'command'))))
        } elseif (($t -in 'copy', 'run') -and (Get-Field $s 'from')) {
            [void]$rows.Add((New-PostRow $t ([string](Get-Field $s 'from')) ([string](Get-Field $s 'dest')) $s))
        } else {
            [void]$rows.Add((New-PostRow 'other' '' '' $s))
        }
    }
    # The comma is load-bearing. A bare `return $rows` ENUMERATES the list on the way out and
    # hands the caller a fixed-size Object[], which reads and indexes exactly like the ArrayList
    # right up until Add or Remove throws "Collection was of a fixed size" - so the dialog would
    # open perfectly and then die on the first click of "Add an action".
    return ,$rows
}

# A row back into a step. When the row came from an existing step it is EDITED, not rebuilt:
# args, timeoutSec and stopOnError that somebody added by hand live on that object and are not
# this dialog's to throw away.
function ConvertTo-PostStep($row) {
    if ($row.Kind -eq 'powershell') {
        $s = $row.Obj
        if (-not $s) { $s = [pscustomobject]@{} }
        Set-Field $s 'type' 'powershell'
        Set-Field $s 'command' $row.Cmd
        # a command is not a file: nothing to take out of the package, nowhere to put it
        foreach ($dead in 'from', 'file', 'dest', 'sha256') { Remove-Field $s $dead }
        $nm = [string](Get-Field $s 'name')
        if (-not $nm -or $nm -match '^PowerShell') {
            $one = (('' + $row.Cmd) -replace '\s+', ' ').Trim()
            if ($one.Length -gt 40) { $one = $one.Substring(0, 37) + '...' }
            Set-Field $s 'name' "PowerShell: $one"
        }
        return $s
    }
    if ($row.Kind -notin 'copy', 'run') { return $row.Obj }
    $s = $row.Obj
    if (-not $s) { $s = [pscustomobject]@{} }
    Set-Field $s 'type' $row.Kind
    # No url and no sha256 in either shape: the file travels INSIDE the package, whose own hash
    # was checked before a single byte was unpacked.
    Set-Field $s 'from' $row.From
    # `from` and `file` are alternatives and the worker reads `from` first - a stale `file` left
    # behind would make the step read as though it pointed somewhere it does not
    Remove-Field $s 'file'
    $leaf = $(if ($row.From) { Split-Path $row.From -Leaf } else { '' })
    $nm = [string](Get-Field $s 'name')
    # a label somebody wrote themselves is kept; the one this dialog generates is refreshed
    if (-not $nm -or $nm -match '^(Copy|Run) ') {
        Set-Field $s 'name' "$(if ($row.Kind -eq 'run') { 'Run' } else { 'Copy' }) $leaf"
    }
    if ($row.Kind -eq 'copy') { Set-Field $s 'dest' (Format-PostDest $row.Dest) } else { Remove-Field $s 'dest' }
    return $s
}

# A `from` naming a file the package does not contain passes every check there used to be, and
# then fails on the client at the end of a long install with "source file missing". After a
# fetch the editor is holding the archive's own listing, so it can say so at the moment the
# mistake is made instead.
#
# Only meaningful when a fetch has actually read the package. An app opened from the catalog and
# saved again without re-fetching knows nothing about what is inside it, and a guard that
# guessed there would block correct entries - so no list means no opinion.
function Test-InPackage($files, [string]$from) {
    if (-not @($files).Count -or -not $from) { return $true }
    # .NET writes backslashes into zip entry names while the spec says forward slash, and the
    # two must not read as different files
    $want = ($from -replace '/', '\').Trim()
    return (@(@($files) | ForEach-Object { ($_ -replace '/', '\') }) -contains $want)
}

function Set-PostRows($App, $rows) {
    $steps = @(@($rows) | ForEach-Object { ConvertTo-PostStep $_ } | Where-Object { $_ })
    if ($steps.Count) { Set-Field $App 'postInstall' $steps } else { Remove-Field $App 'postInstall' }
}

# ---------------------------------------------------------------- the add/edit dialog

$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Application" Height="880" Width="620" MinHeight="480" WindowStartupLocation="CenterOwner"
        Background="#FF1B1B20" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        Foreground="#FFE9E9EE" ResizeMode="CanResize" WindowStyle="ToolWindow">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#FF17171B"/>
      <Setter Property="Foreground" Value="#FFE9E9EE"/>
      <Setter Property="BorderBrush" Value="#FF3C3C45"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="Margin" Value="0,2,0,12"/>
      <Setter Property="CaretBrush" Value="#FFE9E9EE"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF9A9AA6"/>
      <Setter Property="FontSize" Value="11.5"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="0,2,0,12"/>
      <Setter Property="Padding" Value="6,5"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#FF2A2A31"/>
      <Setter Property="Foreground" Value="#FFE9E9EE"/>
      <Setter Property="BorderBrush" Value="#FF3C3C45"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF2563EB"/>
      <Setter Property="BorderBrush" Value="#FF2563EB"/>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <TextBlock Text="Application name"/>
        <TextBox x:Name="DlgName"/>

        <TextBlock Text="Download URL - a .zip package, or a single .exe / .msi installer"/>
        <TextBox x:Name="DlgUrl"/>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
          <Button x:Name="DlgFetch" Content="Fetch and hash" Style="{StaticResource Accent}"/>
          <Button x:Name="DlgPickLocal" Content="Use a local file..." Style="{StaticResource Btn}"/>
          <ProgressBar x:Name="DlgBusy" Width="90" Height="4" IsIndeterminate="True" Visibility="Collapsed"
                       Foreground="#FF4C8DFF" Background="#FF2A2A31" BorderThickness="0" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="DlgHashInfo" TextWrapping="Wrap" Margin="0,0,0,12" FontSize="11"/>

        <TextBlock Text="Setup file to run inside the package"/>
        <ComboBox x:Name="DlgEntry" IsEditable="True"/>

        <TextBlock Text="Silent switches - what stops the installer opening a window and waiting"/>
        <TextBox x:Name="DlgSilent"/>
        <TextBlock x:Name="DlgSilentHint" TextWrapping="Wrap" FontSize="11" Margin="0,-8,0,12"/>

        <TextBlock Text="Verify path - a file that must exist afterwards, or the installer lied"/>
        <ComboBox x:Name="DlgVerify" IsEditable="True"/>
        <TextBlock x:Name="DlgVerifyHint" TextWrapping="Wrap" FontSize="11" Margin="0,-8,0,12"/>

        <Border Background="#FF17171B" BorderBrush="#FF3C3C45" BorderThickness="1" CornerRadius="7"
                Padding="12" Margin="0,4,0,10">
          <StackPanel>
            <TextBlock Text="AFTER INSTALLATION" FontWeight="Bold"
                       Foreground="#FFB6B6C0" Margin="0,0,0,2"/>
            <TextBlock Text="Every action here runs in order, once the install has verified. An empty list means nothing happens."
                       TextWrapping="Wrap" FontSize="11" Margin="0,0,0,8"/>
            <ListBox x:Name="DlgPostList" Height="104" DisplayMemberPath="Text"
                     Background="#FF121216" Foreground="#FFE9E9EE" BorderBrush="#FF3C3C45"
                     FontFamily="Consolas, Courier New" FontSize="11.5" Margin="0,0,0,6"
                     ScrollViewer.HorizontalScrollBarVisibility="Auto"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
              <Button x:Name="DlgPostAdd"    Content="Add an action" Style="{StaticResource Btn}"/>
              <Button x:Name="DlgPostRemove" Content="Remove"        Style="{StaticResource Btn}"/>
              <Button x:Name="DlgPostUp"     Content="Move up"       Style="{StaticResource Btn}"/>
              <Button x:Name="DlgPostDown"   Content="Move down"     Style="{StaticResource Btn}"/>
            </StackPanel>
            <Border x:Name="DlgPostEdit" Background="#FF1B1B20" BorderBrush="#FF3C3C45" BorderThickness="1"
                    CornerRadius="5" Padding="10" Margin="0,0,0,4">
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <RadioButton x:Name="DlgPostMove" Content="Move a file in" GroupName="post"
                               Foreground="#FFE9E9EE" Margin="0,0,18,0"/>
                  <RadioButton x:Name="DlgPostRun" Content="Run a file" GroupName="post"
                               Foreground="#FFE9E9EE" Margin="0,0,18,0"/>
                  <RadioButton x:Name="DlgPostPs" Content="Run a PowerShell command" GroupName="post"
                               Foreground="#FFE9E9EE"/>
                </StackPanel>
                <StackPanel x:Name="DlgPostFilePanel">
                  <TextBlock Text="Which file inside the package"/>
                  <ComboBox x:Name="DlgPostFrom" IsEditable="True"/>
                  <TextBlock x:Name="DlgPostDestLabel" Text="Where it goes - the install folder is filled in for you"/>
                  <ComboBox x:Name="DlgPostDest" IsEditable="True"/>
                </StackPanel>
                <StackPanel x:Name="DlgPostPsPanel" Visibility="Collapsed">
                  <TextBlock Text="PowerShell command - runs elevated, on the client"/>
                  <TextBox x:Name="DlgPostCmd" AcceptsReturn="True" TextWrapping="Wrap" Height="72"
                           VerticalScrollBarVisibility="Auto" FontFamily="Consolas, Courier New"/>
                </StackPanel>
                <TextBlock x:Name="DlgPostWhere" TextWrapping="Wrap" FontSize="11"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>
    <DockPanel Grid.Row="1" Margin="0,14,0,0">
      <TextBlock x:Name="DlgStatus" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="DlgCancel" Content="Cancel" Style="{StaticResource Btn}"/>
        <Button x:Name="DlgOk" Content="Save" Style="{StaticResource Accent}"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

# Returns $true if the dialog was accepted. $App is edited in place, so an existing entry
# keeps every field this dialog knows nothing about.
function Show-AppDialog($App, $Owner) {
    $dlg = [Windows.Markup.XamlReader]::Parse($dialogXaml)
    $dlg.Owner = $Owner
    # A fixed 650-high dialog runs off the bottom of a scaled display, and what disappears is
    # the footer - so Save and Cancel are simply not there, with no hint that the window is
    # taller than the screen. Clamp to what the desktop actually offers and let the
    # ScrollViewer take the rest; the buttons are then always reachable.
    $avail = [Windows.SystemParameters]::WorkArea.Height - 40
    if ($avail -gt 300) {
        $dlg.MaxHeight = $avail
        if ($dlg.Height -gt $avail) { $dlg.Height = $avail }
    }
    $c = @{}
    foreach ($n in 'DlgName','DlgUrl','DlgFetch','DlgPickLocal','DlgBusy','DlgHashInfo','DlgEntry',
                   'DlgSilent','DlgSilentHint','DlgVerify','DlgVerifyHint',
                   'DlgPostList','DlgPostAdd','DlgPostRemove','DlgPostUp','DlgPostDown','DlgPostEdit',
                   'DlgPostMove','DlgPostRun','DlgPostPs','DlgPostFilePanel','DlgPostPsPanel','DlgPostCmd',
                   'DlgPostFrom','DlgPostDestLabel','DlgPostDest','DlgPostWhere',
                   'DlgStatus','DlgOk','DlgCancel') {
        $c[$n] = $dlg.FindName($n)
        # a renamed control in the XAML would otherwise surface as a null-property error six
        # handlers away from the cause
        if (-not $c[$n]) { throw "the dialog layout has no control named $n" }
    }

    # computed values live here until Save is pressed; a cancelled dialog changes nothing
    $state = @{
        sha256 = [string](Get-Field $App 'sha256')
        size   = [long](Get-Field $App 'sizeBytes')
        job    = $null
        handle = $null
        ok     = $false
        rows   = $null
        # What the dialog itself last put in each box. Fields used to be filled "only when
        # empty", to avoid clobbering something a person typed - but that also meant picking a
        # SECOND file left the first file's name, URL, switches and verify path in place, so
        # the entry ended up labelled Office while carrying AutoCAD's hash. Remembering what we
        # wrote separates "the user chose this" from "we guessed this last time".
        auto   = @{}
        # what the fetch actually found inside the package, so a typed `from` can be checked
        # against it. Empty until a fetch happens, and empty means no opinion.
        files  = @()
        # the fields below the list write into the SELECTED row as they are typed, which has to
        # be suspended whenever the code itself puts values in them - loading a row, or a fetch
        # repopulating a combo, which blanks an editable ComboBox's Text as a side effect
        loading = $false
    }

    $c.DlgName.Text    = [string](Get-Field $App 'name')
    $c.DlgUrl.Text     = [string](Get-Field $App 'url')
    $c.DlgSilent.Text  = [string](Get-Field $App 'silentArgs')
    $c.DlgVerify.Text  = [string](@(Get-Field $App 'verifyPaths') | Select-Object -First 1)
    $entry = [string](Get-Field $App 'entry')
    if ($entry) { [void]$c.DlgEntry.Items.Add($entry); $c.DlgEntry.Text = $entry }

    # Seed the "what the dialog put there" record with what came out of the catalog. Without
    # this, editing an EXISTING app leaves every field looking hand-typed, so picking a
    # different .zip or .exe changed the hash and nothing else - the setup file still pointed
    # at the old package's installer, and the URL still named the old file.
    #
    # The NAME is in here too, and it has to be. The verify path is looked up FROM the name, so
    # freezing the name freezes the verify path with it - swap the package and the entry would
    # follow while the verify path still described the old product. Everything the dialog
    # derived moves together, or the entry ends up half describing one product and half another.
    # A name someone types is still safe: it then differs from what the dialog proposed.
    $state.auto['name']   = Get-BoxText $c.DlgName
    $state.auto['url']    = Get-BoxText $c.DlgUrl
    $state.auto['silent'] = Get-BoxText $c.DlgSilent
    $state.auto['verify'] = Get-BoxText $c.DlgVerify
    $state.auto['entry']  = Get-BoxText $c.DlgEntry

    # every step the app already has, in order: the ones this dialog edits and the ones it only
    # carries. The choices in the two combos arrive with the fetch, but what is already in the
    # catalog is offered first, so an app can be edited without re-downloading a 14 GB package.
    $state.rows = Get-PostRows $App
    foreach ($f in @(@($state.rows) | Where-Object { $_.From } | ForEach-Object { $_.From } | Select-Object -Unique)) {
        [void]$c.DlgPostFrom.Items.Add($f)
    }
    foreach ($d in @(@($state.rows) | Where-Object { $_.Dest } | ForEach-Object { $_.Dest } | Select-Object -Unique)) {
        [void]$c.DlgPostDest.Items.Add($d)
    }

    $syncHash = {
        if (Test-RealHash $state.sha256) {
            $c.DlgHashInfo.Foreground = '#FF9AE6B4'
            $c.DlgHashInfo.Text = "$(Format-Size $state.size)   sha256 $($state.sha256.Substring(0,16))..."
        } else {
            $c.DlgHashInfo.Foreground = '#FFF87171'
            $c.DlgHashInfo.Text = 'Not hashed yet - fetch the file so its size and SHA-256 come from the real bytes.'
        }
    }
    # Says in words what the selected row will do. The destination is offered, not demanded:
    # the app already declares where it lands - the verify path - and the folder holding that
    # file IS the install directory, so it is filled in. It stays editable because a second
    # file often belongs somewhere else entirely, and that is exactly the case a single fixed
    # destination could not express.
    $syncWhere = {
        # the file fields and the command box are alternatives - showing both at once invites
        # filling in the one that will be ignored
        $isPs = [bool]$c.DlgPostPs.IsChecked
        $c.DlgPostFilePanel.Visibility = $(if ($isPs) { 'Collapsed' } else { 'Visible' })
        $c.DlgPostPsPanel.Visibility   = $(if ($isPs) { 'Visible' } else { 'Collapsed' })
        $c.DlgPostDest.IsEnabled = -not [bool]$c.DlgPostRun.IsChecked
        $c.DlgPostDestLabel.Opacity = $(if ($c.DlgPostRun.IsChecked) { 0.45 } else { 1.0 })
        $row = $c.DlgPostList.SelectedItem
        if ($null -eq $row) {
            $c.DlgPostWhere.Foreground = '#FF9A9AA6'
            $c.DlgPostWhere.Text = 'Nothing selected. "Add an action" puts a row in the list; the files to choose from appear once the package has been fetched.'
            return
        }
        if ($isPs) {
            if (-not (Get-BoxText $c.DlgPostCmd)) {
                $c.DlgPostWhere.Foreground = '#FFF87171'
                $c.DlgPostWhere.Text = 'Type the command to run.'
            } else {
                $c.DlgPostWhere.Foreground = '#FFFBBF24'
                $c.DlgPostWhere.Text = 'Runs ELEVATED on the client once the install verifies. There is no file to hash here, so the catalog is the only thing vouching for this command - anyone who can change the catalog can run anything on every machine this tool touches.'
            }
            return
        }
        if ($row.Kind -notin 'copy', 'run') {
            $c.DlgPostWhere.Foreground = '#FF9A9AA6'
            $c.DlgPostWhere.Text = 'Written by hand, and kept exactly as it is. Where it sits in the list can still be changed - the worker runs these in order.'
            return
        }
        if (-not (Test-InPackage $state.files (Get-BoxText $c.DlgPostFrom))) {
            $c.DlgPostWhere.Foreground = '#FFF87171'
            $c.DlgPostWhere.Text = "There is no such file in the package. It holds $(@($state.files).Count) file(s) - pick one from the list, or this fails on the client with 'source file missing' after the whole install has run."
            return
        }
        if ($c.DlgPostRun.IsChecked) {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = 'Run from inside the package once the install verifies. No separate hash is needed - the package was verified before it was unpacked.'
            return
        }
        $d = Format-PostDest $c.DlgPostDest.Text
        if (-not $d) {
            $c.DlgPostWhere.Foreground = '#FFF87171'
            $c.DlgPostWhere.Text = 'Say where the file goes. Set a verify path above and the install folder is offered here.'
        } elseif ($d.EndsWith('\')) {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = "Moved into $d once the install verifies, keeping its own name."
        } else {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = "Moved to $d once the install verifies - that last part is a filename, so it is renamed on the way."
        }
    }

    # The list IS the editor: the fields below always show the selected row, and typing in them
    # changes that row. There is no "add" mode to be in, and so no half-typed action that was
    # never added - which is precisely how the single-step version used to lose a file-copy.
    $syncPostEditor = {
        $row  = $c.DlgPostList.SelectedItem
        $edit = ($null -ne $row -and $row.Kind -in 'copy', 'run', 'powershell')
        $c.DlgPostEdit.IsEnabled   = $edit
        $c.DlgPostRemove.IsEnabled = ($null -ne $row)
        $c.DlgPostUp.IsEnabled     = ($null -ne $row -and $c.DlgPostList.SelectedIndex -gt 0)
        $c.DlgPostDown.IsEnabled   = ($null -ne $row -and $c.DlgPostList.SelectedIndex -lt ($state.rows.Count - 1))
        $state.loading = $true
        try {
            if ($edit) {
                $c.DlgPostFrom.Text = [string]$row.From
                $c.DlgPostDest.Text = [string]$row.Dest
                $c.DlgPostCmd.Text  = [string]$row.Cmd
                if ($row.Kind -eq 'run') { $c.DlgPostRun.IsChecked = $true }
                elseif ($row.Kind -eq 'powershell') { $c.DlgPostPs.IsChecked = $true }
                else { $c.DlgPostMove.IsChecked = $true }
            } else {
                $c.DlgPostFrom.Text = ''
                $c.DlgPostDest.Text = ''
                $c.DlgPostCmd.Text  = ''
                $c.DlgPostMove.IsChecked = $false
                $c.DlgPostRun.IsChecked  = $false
                $c.DlgPostPs.IsChecked   = $false
            }
        } finally { $state.loading = $false }
        & $syncWhere
    }

    $refreshRows = {
        param([int]$select = -1)
        $state.loading = $true
        try {
            $c.DlgPostList.ItemsSource = $null
            $c.DlgPostList.ItemsSource = @($state.rows)
            if ($select -ge 0 -and $select -lt $state.rows.Count) { $c.DlgPostList.SelectedIndex = $select }
        } finally { $state.loading = $false }
        & $syncPostEditor
    }

    # typing edits the selected row as you type, so the list always shows what is actually there
    $applyEdit = {
        if ($state.loading) { return }
        $row = $c.DlgPostList.SelectedItem
        if ($null -eq $row -or $row.Kind -notin 'copy', 'run', 'powershell') { return }
        $i = $c.DlgPostList.SelectedIndex
        $row.Kind = $(if ($c.DlgPostPs.IsChecked) { 'powershell' }
                      elseif ($c.DlgPostRun.IsChecked) { 'run' } else { 'copy' })
        $row.Cmd  = (Get-BoxText $c.DlgPostCmd)
        $row.From = (Get-BoxText $c.DlgPostFrom)
        # kept even while the row is a run, so flipping the type back does not lose what was
        # typed - ConvertTo-PostStep is what actually drops it, at save
        $row.Dest = Format-PostDest $c.DlgPostDest.Text
        Update-PostRowText $row
        $state.loading = $true
        try {
            $c.DlgPostList.Items.Refresh()
            $c.DlgPostList.SelectedIndex = $i
        } finally { $state.loading = $false }
        & $syncWhere
    }

    $moveRow = {
        param([int]$delta)
        $i = $c.DlgPostList.SelectedIndex
        $j = $i + $delta
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $state.rows.Count) { return }
        $row = $state.rows[$i]
        $state.rows.RemoveAt($i)
        $state.rows.Insert($j, $row)
        & $refreshRows $j
    }

    & $syncHash
    & $refreshRows $(if ($state.rows.Count) { 0 } else { -1 })

    # an editable ComboBox has no TextChanged of its own - the inner text box raises it
    $c.DlgVerify.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                            [Windows.RoutedEventHandler]$syncWhere)
    $c.DlgPostFrom.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                              [Windows.RoutedEventHandler]$applyEdit)
    $c.DlgPostDest.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                              [Windows.RoutedEventHandler]$applyEdit)
    $c.DlgPostCmd.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                             [Windows.RoutedEventHandler]$applyEdit)
    foreach ($rb in @($c.DlgPostMove, $c.DlgPostRun, $c.DlgPostPs)) { $rb.Add_Checked($applyEdit) }
    $c.DlgPostList.Add_SelectionChanged({ if (-not $state.loading) { & $syncPostEditor } })

    $c.DlgPostAdd.Add_Click({
        # the install folder is what the app already declares - offered, never asked for twice
        $dest = ''
        if ((Get-BoxText $c.DlgVerify)) { $dest = (Split-Path (Get-BoxText $c.DlgVerify) -Parent).TrimEnd('\') + '\' }
        [void]$state.rows.Add((New-PostRow 'copy' '' $dest $null))
        & $refreshRows ($state.rows.Count - 1)
        [void]$c.DlgPostFrom.Focus()
    })
    $c.DlgPostRemove.Add_Click({
        $i = $c.DlgPostList.SelectedIndex
        if ($i -lt 0) { return }
        $state.rows.RemoveAt($i)
        & $refreshRows ([Math]::Min($i, $state.rows.Count - 1))
    })
    # parenthesised, or -1 is read as a parameter name rather than a number
    $c.DlgPostUp.Add_Click({   & $moveRow (-1) })
    $c.DlgPostDown.Add_Click({ & $moveRow (1) })

    # Writes a proposal into a box, but only over a value the dialog itself proposed earlier.
    # Anything typed by hand survives; anything left over from the previous file does not.
    $setAuto = {
        param($ctl, [string]$key, [string]$value)
        $cur = Get-BoxText $ctl
        if (-not $cur -or $cur -eq [string]$state.auto[$key]) { $ctl.Text = $value }
        $state.auto[$key] = $value
    }

    $setBusy = {
        param($on, $msg)
        $c.DlgBusy.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
        $c.DlgFetch.IsEnabled = -not $on
        $c.DlgPickLocal.IsEnabled = -not $on
        $c.DlgOk.IsEnabled = -not $on
        $c.DlgStatus.Text = $msg
        $c.DlgStatus.Foreground = '#FF9A9AA6'
    }

    $startFetch = {
        param($source)
        if (-not $source) { $c.DlgStatus.Text = 'Give a URL first, or pick a local file.'; return }
        & $setBusy $true 'Fetching and hashing - this can take a while on a large package...'
        $state.job = [powershell]::Create()
        [void]$state.job.AddScript($script:FetchWork).AddArgument($source).AddArgument($PackageDir)
        $state.handle = $state.job.BeginInvoke()
    }

    $poll = New-Object Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(300)
    $poll.Add_Tick({
        if (-not $state.job -or -not $state.handle.IsCompleted) { return }
        $r = $null
        try { $r = $state.job.EndInvoke($state.handle) | Select-Object -Last 1 }
        catch { $r = @{ error = $_.Exception.Message } }
        $state.job.Dispose(); $state.job = $null; $state.handle = $null
        & $setBusy $false ''
        if (-not $r) { return }
        if ($r.error) {
            $c.DlgStatus.Text = "Failed: $($r.error)"
            $c.DlgStatus.Foreground = '#FFF87171'
            return
        }
        $state.sha256 = [string]$r.sha256
        $state.size   = [long]$r.size
        $state.files  = @($r.files)
        & $syncHash
        $c.DlgEntry.Items.Clear()
        foreach ($e in @($r.entries)) { [void]$c.DlgEntry.Items.Add($e) }
        # Repopulating an editable ComboBox blanks its Text, and that text is live-bound to the
        # selected after-install row - so row edits are suspended across it, and the row's own
        # values are pushed back afterwards by the $syncPostEditor at the end of this tick.
        $state.loading = $true
        try {
            $c.DlgPostFrom.Items.Clear()
            foreach ($f in @($r.files)) { [void]$c.DlgPostFrom.Items.Add($f) }
        } finally { $state.loading = $false }
        # proposed, never forced - but a proposal from the PREVIOUS file is not a person's
        # choice, so it gets replaced rather than kept
        & $setAuto $c.DlgSilent 'silent' ([string]$r.silent)
        if ($r.packager) {
            $c.DlgSilentHint.Foreground = '#FF9AE6B4'
            $c.DlgSilentHint.Text = "Installer identified as $($r.packager)."
        } else {
            $c.DlgSilentHint.Foreground = '#FFFBBF24'
            $c.DlgSilentHint.Text = 'Packager not recognised - switches will have to be found by hand (tools\Test-SilentSwitches.ps1 can try them on a VM).'
        }
        $cands = @(Get-VerifyCandidates (Get-BoxText $c.DlgName))
        $state.loading = $true
        try { $c.DlgVerify.Items.Clear(); foreach ($cd in $cands) { [void]$c.DlgVerify.Items.Add($cd) } }
        finally { $state.loading = $false }
        & $setAuto $c.DlgVerify 'verify' $(if ($cands.Count) { [string]$cands[0] } else { '' })
        $found = @($cands | Where-Object { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_)) }).Count
        $c.DlgVerifyHint.Foreground = $(if ($found) { '#FF9AE6B4' } else { '#FF9A9AA6' })
        $c.DlgVerifyHint.Text = $(if ($found) { "$found path(s) found on THIS machine - the product is installed here, so these are real." }
                                  else { 'Not installed on this machine, so these are guesses from the name. Confirm against a machine that has it.' })
        # the install folder of each candidate, offered as a destination rather than typed
        $state.loading = $true
        try {
            $c.DlgPostDest.Items.Clear()
            foreach ($p in @(@($cands) | ForEach-Object { (Split-Path $_ -Parent).TrimEnd('\') + '\' } |
                             Where-Object { $_ -ne '\' } | Select-Object -Unique)) {
                [void]$c.DlgPostDest.Items.Add($p)
            }
        } finally { $state.loading = $false }
        & $syncPostEditor
        # the ranked best guess is proposed; a setup file chosen by hand survives, one left over
        # from the previous package does not - and a package with no installer inside clears it,
        # or an .exe would keep a setup path belonging to somebody else's zip
        & $setAuto $c.DlgEntry 'entry' $(if (@($r.entries).Count) { [string](@($r.entries)[0]) } else { '' })
        if (@($r.entries).Count) {
            $c.DlgStatus.Text = "Found $(@($r.entries).Count) installer(s) and $(@($r.files).Count) file(s) inside the package."
            $c.DlgStatus.Foreground = '#FF34D399'
        } elseif ([IO.Path]::GetExtension([string]$r.file).ToLower() -eq '.zip') {
            $c.DlgStatus.Text = 'That zip holds no .exe or .msi - is it the right file?'
            $c.DlgStatus.Foreground = '#FFFBBF24'
        } else {
            $c.DlgStatus.Text = 'Hashed. A single installer needs no setup file chosen.'
            $c.DlgStatus.Foreground = '#FF34D399'
        }
    })
    $poll.Start()

    $c.DlgFetch.Add_Click({ & $startFetch (Get-BoxText $c.DlgUrl) })
    $c.DlgPickLocal.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Title = 'Choose the package or installer'
        $d.Filter = 'Packages and installers (*.zip;*.exe;*.msi)|*.zip;*.exe;*.msi|All files (*.*)|*.*'
        if (-not $d.ShowDialog()) { return }
        $leaf = [IO.Path]::GetFileName($d.FileName)
        # The file already says what the app is called. Leaving the name blank after picking
        # one made the dialog look like it had ignored the click - only the URL changed, and
        # that is the field furthest down. Filled only when empty, so an existing name is
        # never overwritten by a re-hash.
        $stem = [IO.Path]::GetFileNameWithoutExtension($d.FileName)
        # installers are named like Revit_2026-x64 or setup_v3.1 - separators read as spaces
        & $setAuto $c.DlgName 'name' ((($stem -replace '[_\.\-]+', ' ') -replace '\s+', ' ').Trim())
        # a local file still needs a URL for the client to fetch it from - offer the obvious one
        & $setAuto $c.DlgUrl 'url' "$BaseUrl/files/$leaf"
        & $startFetch $d.FileName
    })

    $c.DlgCancel.Add_Click({ $dlg.Close() })
    $c.DlgOk.Add_Click({
        if (-not (Get-BoxText $c.DlgName)) { $c.DlgStatus.Text = 'A name is required.'; $c.DlgStatus.Foreground = '#FFF87171'; return }
        if (-not (Get-BoxText $c.DlgUrl))  { $c.DlgStatus.Text = 'A download URL is required.'; $c.DlgStatus.Foreground = '#FFF87171'; return }
        for ($i = 0; $i -lt $state.rows.Count; $i++) {
            $row = $state.rows[$i]
            if ($row.Kind -eq 'powershell') {
                if (-not $row.Cmd) {
                    $c.DlgPostList.SelectedIndex = $i
                    $c.DlgStatus.Text = "After installation: action $($i + 1) has no command."
                    $c.DlgStatus.Foreground = '#FFF87171'
                    return
                }
                continue
            }
            if ($row.Kind -notin 'copy', 'run') { continue }
            $why = ''
            if (-not $row.From) { $why = 'has no file chosen inside the package' }
            elseif (-not (Test-InPackage $state.files $row.From)) { $why = "names '$($row.From)', which is not in the package" }
            elseif ($row.Kind -eq 'copy' -and -not $row.Dest) { $why = 'does not say where the file goes' }
            if ($why) {
                # select it too, or the message names a number with nothing on screen to point at
                $c.DlgPostList.SelectedIndex = $i
                $c.DlgStatus.Text = "After installation: action $($i + 1) $why."
                $c.DlgStatus.Foreground = '#FFF87171'
                return
            }
        }
        # these steps take their file OUT of the package, so there has to be a package - the
        # worker refuses `from` on a single installer, and it would refuse it on a client
        # a PowerShell command takes nothing out of the package, so it does not need one
        if (@(@($state.rows) | Where-Object { $_.Kind -in 'copy', 'run' }).Count -and -not (Get-BoxText $c.DlgEntry)) {
            $c.DlgStatus.Text = 'After-install actions take their file out of the package, so this app must be a .zip with a setup file chosen above.'
            $c.DlgStatus.Foreground = '#FFF87171'
            return
        }
        $state.ok = $true
        $dlg.Close()
    })
    $dlg.Add_Closed({ $poll.Stop(); if ($state.job) { try { $state.job.Dispose() } catch {} } })
    [void]$dlg.ShowDialog()
    if (-not $state.ok) { return $false }

    # ---- applied to the app object, in place ----
    $name = (Get-BoxText $c.DlgName)
    Set-Field $App 'name' $name
    if (-not (Get-Field $App 'id')) { Set-Field $App 'id' (ConvertTo-Id $name) }
    if (-not (Get-Field $App 'category')) { Set-Field $App 'category' 'Apps' }
    # iconText / iconColor are deliberately NOT touched - an existing app keeps the icon it
    # already has, and a new one simply has none until somebody sets one
    Set-Field $App 'url' (Get-BoxText $c.DlgUrl)
    Set-Field $App 'sha256' $state.sha256
    Set-Field $App 'sizeBytes' $state.size
    Set-Field $App 'silentArgs' $c.DlgSilent.Text
    Set-Field $App 'verifyPaths' @(@((Get-BoxText $c.DlgVerify)) | Where-Object { $_ })
    if ((Get-BoxText $c.DlgEntry)) { Set-Field $App 'entry' (Get-BoxText $c.DlgEntry) } else { Remove-Field $App 'entry' }
    # `instructions` is intentionally not edited here - an app that already has some keeps
    # them, rather than losing them to a field that is no longer on screen

    # Cleanup, derived and never shown. These are only ever a SEARCH: the deep clean lists
    # whatever it finds and a technician ticks it before anything is deleted, so there is
    # nothing here worth asking a person to fill in. The name is the token that always
    # applies. Anything curated by hand earlier is kept.
    $cl = Get-Field $App 'cleanup'
    if (-not $cl) { $cl = [pscustomobject]@{}; Set-Field $App 'cleanup' $cl }
    Set-Field $cl 'tokens' @(@(Get-Field $cl 'tokens') + $name | Where-Object { $_ } | Select-Object -Unique)
    foreach ($k in 'paths', 'registry', 'hosts') {
        if (-not $cl.PSObject.Properties[$k]) { Set-Field $cl $k @() }
    }

    # ---- the after-install list, written back in the order it is shown ----
    Set-PostRows $App $state.rows
    return $true
}

# ---------------------------------------------------------------- main window

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC2Go Catalog Editor" Height="620" Width="760"
        WindowStartupLocation="CenterScreen" Background="#FF1B1B20"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#FFE9E9EE">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#FF2A2A31"/>
      <Setter Property="Foreground" Value="#FFE9E9EE"/>
      <Setter Property="BorderBrush" Value="#FF3C3C45"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF2563EB"/>
      <Setter Property="BorderBrush" Value="#FF2563EB"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="APPLICATIONS" FontWeight="Bold" Foreground="#FF9A9AA6" FontSize="11.5"
                 VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnAdd" Content="Add application" Style="{StaticResource Accent}"/>
        <Button x:Name="BtnAddFolder" Content="Add folder..." Style="{StaticResource Btn}"/>
        <Button x:Name="BtnEdit" Content="Edit" Style="{StaticResource Btn}"/>
        <Button x:Name="BtnDelete" Content="Delete" Style="{StaticResource Btn}"/>
      </StackPanel>
    </DockPanel>
    <ListBox x:Name="ListApps" Grid.Row="1" Background="#FF17171B" BorderBrush="#FF3C3C45"
             Foreground="#FFE9E9EE">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <StackPanel Margin="4,6">
            <TextBlock Text="{Binding Name}" Foreground="#FFE9E9EE" FontSize="13.5"/>
            <TextBlock Text="{Binding Detail}" Foreground="{Binding Colour}" FontSize="11"/>
          </StackPanel>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
    <DockPanel Grid.Row="2" Margin="0,12,0,0">
      <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Foreground="#FFB6B6C0" FontSize="11.5"
                 TextTrimming="CharacterEllipsis"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnPublish" Content="Publish..." Style="{StaticResource Btn}"/>
        <Button x:Name="BtnSave" Content="Save catalog" Style="{StaticResource Accent}"/>
      </StackPanel>
    </DockPanel>

    <!-- Confirmations and notices, in the window rather than in a MessageBox. A MessageBox is
         modal with no timeout: it cannot be driven or dismissed by anything but a person, so
         every path behind one is untestable, and an unattended run hangs on it for ever.
         AppDeploy.ps1 solves the same problem the same way. -->
    <Border x:Name="Overlay" Grid.RowSpan="3" Background="#CC101014" Visibility="Collapsed">
      <Border Background="#FF1B1B20" BorderBrush="#FF3C3C45" BorderThickness="1" CornerRadius="10"
              Padding="20" MaxWidth="520" VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <TextBlock x:Name="TxtOverlayTitle" FontSize="15" FontWeight="Bold" Foreground="#FFE9E9EE"
                     TextWrapping="Wrap" Margin="0,0,0,8"/>
          <TextBlock x:Name="TxtOverlayBody" TextWrapping="Wrap" Foreground="#FFB6B6C0"
                     FontSize="12" Margin="0,0,0,18"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnOverlayCancel" Content="Cancel" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnOverlayOk" Content="OK" Style="{StaticResource Accent}"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Border>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'ListApps','BtnAdd','BtnAddFolder','BtnEdit','BtnDelete','BtnSave','BtnPublish','TxtStatus',
               'Overlay','TxtOverlayTitle','TxtOverlayBody','BtnOverlayOk','BtnOverlayCancel') {
    $el = $window.FindName($n)
    # a name that does not resolve becomes $null and surfaces later as "you cannot call a
    # method on a null-valued expression", somewhere unrelated to the actual mistake
    if (-not $el) { throw "The main window layout has no control named $n." }
    Set-Variable -Name $n -Value $el -Scope Script
}

# A click handler that throws inside WPF fails SILENTLY - the button simply does nothing,
# which is indistinguishable from a dead button and hides the actual fault. Everything the
# buttons do goes through here, so a mistake is reported rather than swallowed.
function Invoke-Guarded([scriptblock]$Action, [string]$What) {
    try { & $Action }
    catch {
        $detail = "$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
        # The overlay first, so a fault reports the same way everything else does. A MessageBox
        # behind it because this runs when something has ALREADY gone wrong: if the overlay
        # itself is what broke, the report must still reach a person rather than vanish into
        # the same silence this function exists to prevent.
        try { Show-Notice "$What failed" $detail }
        catch { [void][Windows.MessageBox]::Show("$What failed:`r`n`r`n$detail", 'Error', 'OK', 'Error') }
    }
}

$BtnAdd.Add_Click({ Invoke-Guarded {
    $app = [pscustomobject]@{
        id = ''; name = ''; version = ''; publisher = ''; category = 'Apps'
        sizeBytes = 0; url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @()
    }
    if (Show-AppDialog $app $window) {
        $script:Catalog.apps = @(@($script:Catalog.apps) + $app)
        $script:Dirty = $true
        Update-List
    }
} 'Add application' })

$BtnAddFolder.Add_Click({ Invoke-Guarded {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose a folder of installers. Every .zip, .exe and .msi directly inside it becomes an application.'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    # top level only, and deliberately so: recursing into a folder of installers picks up
    # every uninstaller, updater and helper exe sitting beside them
    $files = @(Get-ChildItem -LiteralPath $dlg.SelectedPath -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.zip', '.exe', '.msi' } | Sort-Object Name)
    if (-not $files.Count) {
        Show-Notice 'Nothing to add' "No .zip, .exe or .msi files were found directly inside:`r`n`r`n$($dlg.SelectedPath)"
        return
    }
    $added = 0
    foreach ($f in $files) {
        $name = ((([IO.Path]::GetFileNameWithoutExtension($f.Name)) -replace '[_\.\-]+', ' ') -replace '\s+', ' ').Trim()
        $id = ConvertTo-Id $name
        # adding the same folder twice should not double every entry
        if (@($script:Catalog.apps | Where-Object { (Get-Field $_ 'id') -eq $id }).Count) { continue }
        $app = [pscustomobject]@{
            id = $id; name = $name; version = ''; publisher = ''; category = 'Apps'
            sizeBytes = 0; url = "$BaseUrl/files/$($f.Name)"; sha256 = ''
            silentArgs = ''; verifyPaths = @()
        }
        # where the bytes are, for the hashing pass. Underscored so it reads as private, and
        # stripped before the catalog is written.
        Set-Field $app '_localFile' $f.FullName
        $script:Catalog.apps = @(@($script:Catalog.apps) + $app)
        [void]$script:BulkQueue.Add($app)
        $added++
    }
    if (-not $added) {
        Show-Notice 'Already in the catalog' 'Every installer in that folder is already listed.'
        return
    }
    $script:BulkDone = 0
    $script:BulkTotal = $added
    $script:Dirty = $true
    Update-List
    Set-StatusText "Added $added application(s). Hashing 1 of $added..." '#FF4C8DFF'
    Start-BulkNext
} 'Add folder' })

# one poll for the whole bulk pass; hashing runs in a runspace so the window stays alive
$script:BulkTimer = New-Object Windows.Threading.DispatcherTimer
$script:BulkTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:BulkTimer.Add_Tick({ Invoke-Guarded {
    if ($script:BulkJob -and $script:BulkHandle.IsCompleted) { Complete-BulkOne }
    if (-not $script:BulkJob -and $script:BulkQueue.Count) { Start-BulkNext }
} 'Hashing' })
$script:BulkTimer.Start()

$BtnEdit.Add_Click({ Invoke-Guarded {
    $row = $ListApps.SelectedItem
    if (-not $row) { return }
    if (Show-AppDialog $row.App $window) { $script:Dirty = $true; Update-List }
} 'Edit' })

$ListApps.Add_MouseDoubleClick({
    $row = $ListApps.SelectedItem
    if (-not $row) { return }
    if (Show-AppDialog $row.App $window) { $script:Dirty = $true; Update-List }
})

$BtnDelete.Add_Click({
    $row = $ListApps.SelectedItem
    if (-not $row) { return }
    # the removal lives in a function rather than inline in the closure: a closure carries its
    # own copy of the scope it was made in, and assigning THROUGH it does not reliably reach the
    # script-scope $Catalog - a call does
    Show-Confirm 'Remove this application?' (
        "'$($row.Name)' will be taken out of the catalog.`r`n`r`n" +
        'Nothing is written to disk until you save, so closing without saving still undoes it.'
    ) 'Remove' ({ Remove-App $row.App $row.Name }.GetNewClosure())
})

$BtnSave.Add_Click({ [void](Export-Catalog) })

$BtnPublish.Add_Click({
    $bad = @(@($script:Catalog.apps) | Where-Object { (Test-App $_).Count })
    if ($bad.Count) {
        Show-Notice 'Not ready to publish' (
            "$($bad.Count) app(s) are not ready. Each row in the list says what it is missing.")
        return
    }
    if ($script:Dirty -and -not (Export-Catalog)) { return }
    $pub = Join-Path $script:ToolsDir 'Publish-Release.ps1'
    if (-not (Test-Path -LiteralPath $pub)) { Set-StatusText 'Publish-Release.ps1 not found.' '#FFF87171'; return }
    # its own window on purpose: publishing uploads tens of GB and prompts
    Start-Process powershell -ArgumentList @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$pub`"")
    Set-StatusText 'Publish-Release.ps1 launched in its own window.'
})

$BtnOverlayOk.Add_Click({
    $Overlay.Visibility = 'Collapsed'
    $act = $script:ConfirmAction
    $script:ConfirmAction = $null
    if ($act) { & $act }
})
$BtnOverlayCancel.Add_Click({ $Overlay.Visibility = 'Collapsed'; $script:ConfirmAction = $null })

# Closing has to decide synchronously - $e.Cancel is read the moment this returns - and an
# overlay answers later, so the close is cancelled and re-issued once the answer arrives.
$script:ForceClose = $false
$window.Add_Closing({
    param($eventSource, $e)
    if ($script:Dirty -and -not $script:ForceClose) {
        $e.Cancel = $true
        Show-Confirm 'Unsaved changes' (
            'This catalog has changes that have not been written to disk. Closing now loses them.'
        ) 'Close anyway' { $script:ForceClose = $true; $window.Close() }
    }
})

try { Import-Catalog } catch { Set-StatusText $_.Exception.Message '#FFF87171' }
[void]$window.ShowDialog()
