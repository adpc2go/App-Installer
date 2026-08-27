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
    # The live host, not a placeholder. This used to default to apps.example.com, which is why
    # every url in the catalog had to be corrected by hand afterwards.
    [string]$BaseUrl = 'https://apps.pc2go.ca',
    # The three below exist so Test-Push.ps1 can aim the whole Push path at a loopback endpoint
    # and a sandbox, without touching the real credential store or the real bucket.
    [string]$R2CredentialPath,
    [string]$R2Endpoint,
    [string]$PushStatePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# only for FolderBrowserDialog - WPF has no folder picker of its own
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Dragging a WindowStyle=None window. $window.DragMove() is the obvious way and does not work
# here - it is particular about the combination of WindowStyle, AllowsTransparency and
# ResizeMode, and about what handled the button-down first, and it reports the refusal by
# throwing. Telling Windows the click landed on a caption hands the drag to the window manager
# instead, which is what a title bar actually is; snapping and drag-to-edge come free.
#
# Registered up here with the other assemblies rather than beside the handler: a type has to
# exist before anything that names it is run, and putting it in the middle of the file made it
# fragile for no benefit.
Add-Type -Namespace Native -Name WinDrag -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(
    System.IntPtr hWnd, int Msg, System.IntPtr wParam, System.IntPtr lParam);
'@

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

# The S3 transport lives in its own file so the upload runspace and Test-Push.ps1 can reach it
# without loading a window. Dot-sourced by path, once, here.
$script:R2Module = Join-Path $script:ToolsDir 'R2-Upload.ps1'
if (Test-Path -LiteralPath $script:R2Module) { . $script:R2Module }


if (-not $R2CredentialPath) { $R2CredentialPath = Join-Path $env:LOCALAPPDATA 'PC2Go\r2-credentials.xml' }
# Not under server\ on purpose: server\ is the directory Publish-Release.ps1 uploads from, and a
# file full of local disk paths has no business there.
if (-not $PushStatePath)    { $PushStatePath    = Join-Path $script:ToolsDir '.push-state.json' }

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
<#
    An installer's file name, split into the product's name and its version.

    `SketchUp Pro 2026.26.1.256.rar` used to become the NAME "SketchUp Pro 2026 26 1 256",
    because every dot, dash and underscore was turned into a space. That name is not merely
    cosmetic: Get-VerifyCandidates fabricates an install path OUT of it, so one mangled name
    produced %ProgramFiles%\SketchUp Pro 2026 26 1 256\SketchUpPro2026261256.exe - a directory
    no installer has ever created - and the after-install destination box was then prefilled
    from that. One bad guess, three wrong fields.

    A trailing run of DOTTED digits is a version and comes out separately. A bare number is left
    where it is: "AutoCAD 2026" and "Office 2024" really are called that, and moving the year
    into a version field would rename products that were never versioned that way.
#>
function ConvertFrom-PackageFileName([string]$Path) {
    $stem = [IO.Path]::GetFileNameWithoutExtension(('' + $Path))
    $ver  = ''
    # at least one dot is what separates a version from a year
    $m = [regex]::Match($stem, '(?:^|[ _.\-])[vV]?(\d+(?:\.\d+)+)$')
    if ($m.Success -and $m.Index -gt 0) {
        $ver  = $m.Groups[1].Value
        $stem = $stem.Substring(0, $m.Index)
    }
    $name = ((($stem -replace '[_\.\-]+', ' ') -replace '\s+', ' ')).Trim()
    # a file called nothing but its version keeps the whole stem: an entry with no name at all
    # is worse than an ugly one, and Test-App refuses it anyway
    if (-not $name) {
        $name = (((([IO.Path]::GetFileNameWithoutExtension(('' + $Path))) -replace '[_\.\-]+', ' ') -replace '\s+', ' ')).Trim()
        $ver  = ''
    }
    return @{ Name = $name; Version = $ver }
}

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
    param($Source, $CacheDir, $ListOnly)

    # This used to identify the packager and propose a silent switch. It was taken out on
    # purpose: the answer was never solid enough to rely on. A switch that is nearly right
    # does not fail loudly - the installer opens its GUI on a client machine and waits for a
    # click nobody is there to make - so a blank field a technician fills in deliberately
    # beats a proposal that is right most of the time. This job now does what its name says:
    # it lists what is inside the package, and hashes it.

    # setup.exe is the near-universal answer and beats a shallower file with a vaguer name;
    # depth only breaks ties. Split on BOTH separators - .NET writes backslashes into entry
    # names while the spec says forward slash, and splitting on one alone kills the tiebreak
    # silently. Hoisted out of the listing because an .iso has to rank its entries while the
    # image is still mounted, and everything else ranks them after the archive is closed.
    function Get-RankedInstallers {
        param($Names)
        return @($Names | Where-Object { $_ -match '\.(exe|msi)$' } |
            Sort-Object @{ e = { switch -Regex ([IO.Path]::GetFileName($_).ToLower()) {
                                    '^set-?up\.(exe|msi)$'      { 0 }
                                    '^install(er)?\.(exe|msi)$' { 1 }
                                    '^run\.(exe|msi)$'          { 2 }
                                    '\.msi$'                    { 3 }
                                    default                     { 4 } } } },
                        @{ e = { ($_ -split '[\\/]').Count } },
                        @{ e = { [IO.Path]::GetFileName($_) } })
    }

    try {
        $local = $Source
        # a URL is fetched once into the package folder; a local path is used where it lies
        if ($Source -match '^https?://') {
            # -ListOnly runs when a dialog OPENS, where nobody asked for anything. It reads what
            # this machine already has and never starts a 14 GB download to do it.
            if ($ListOnly) { return @{ error = 'list-only reads a local file, never a URL'; listOnly = $true } }
            if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
            $name = [IO.Path]::GetFileName(([Uri]$Source).LocalPath)
            if (-not $name) { $name = 'package.bin' }
            # Keyed by URL, not by leaf. Nine of the nineteen real catalog entries call their
            # installer Setup.exe; a leaf-keyed cache silently hands app B app A's bytes and
            # hashes them as B's - the exact collision Get-AppKey documents for R2, un-carried.
            $uh = 'u'
            try {
                $sha1 = [Security.Cryptography.SHA1]::Create()
                try {
                    $uh = ( -join ($sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source)) |
                                   ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
                } finally { $sha1.Dispose() }
            } catch { }
            $local = Join-Path $CacheDir "$uh-$name"
            if (-not (Test-Path -LiteralPath $local)) {
                # Download to .part and promote on success. WebClient writes straight to its
                # target, so a dropped transfer used to leave a truncated file the NEXT fetch
                # trusted, skipped the download, and hashed as the real thing - a catalog
                # pinned to the SHA-256 of a fragment.
                $part = "$local.part"
                if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
                $wc = New-Object Net.WebClient
                try { $wc.DownloadFile($Source, $part) } finally { $wc.Dispose() }
                Move-Item -LiteralPath $part -Destination $local -Force
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

        # How the package was opened, kept apart from what the INSTALLER turned out to be.
        # Saying "zip" where the packager belongs is what used to leave the field blank.
        $container = ''
        # .zip and .rar are both packages - something to look inside and pick a setup file from.
        # .rar is read only through tar; .NET has no idea what one is. bsdtar (libarchive) reads
        # RAR5 and, it claims, RAR4 - RAR5 is proven, RAR4 is not, because WinRAR 7.x removed
        # the ability to CREATE a RAR4 archive to test against.
        $ext    = [IO.Path]::GetExtension($local).ToLower()
        $isZip  = ($ext -eq '.zip')
        $isRar  = ($ext -eq '.rar')
        $isIso  = ($ext -eq '.iso')
        $names = @()
        $topEntry = $null
        if ($isZip -or $isRar -or $isIso) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = $null

            # An ISO is MOUNTED, never read with tar. bsdtar can list one, but on an image with
            # no Joliet extension it falls back to raw ISO9660 and truncates every name to 31
            # characters - a real ETAP disc here has a prerequisites folder called
            # {125AB5F8-0156-4A9F-B1D1-C2B7E7D82A60} that tar reports as
            # {125AB5F8-0156-4A9F-B1D1-C2B7E7. Extracting that hands InstallShield a path it
            # cannot find, and only after a 4 GB download. Windows reads the image correctly, so
            # let it: mount read-only, list, let go.
            if ($isIso) {
                $img = $null
                $weMounted = $false
                try {
                    # An image already mounted - by Explorer, or by a run that was interrupted -
                    # makes Mount-DiskImage throw. Read the existing mount instead, and leave it
                    # exactly as it was found.
                    $img = Get-DiskImage -ImagePath $local -ErrorAction SilentlyContinue
                    if (-not ($img -and $img.Attached)) {
                        $img = Mount-DiskImage -ImagePath $local -Access ReadOnly -PassThru -ErrorAction Stop
                        $weMounted = $true
                    }
                    $root = ''
                    # The volume does not appear the instant the mount call returns.
                    for ($i = 0; $i -lt 40 -and -not $root; $i++) {
                        Start-Sleep -Milliseconds 250
                        $v = Get-Volume -DiskImage $img -ErrorAction SilentlyContinue
                        if ($v -and $v.DriveLetter) { $root = "$($v.DriveLetter):\" }
                    }
                    if (-not $root) { throw 'the image mounted but Windows gave it no drive letter' }
                    $names = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
                               ForEach-Object { $_.FullName.Substring($root.Length) })
                    if (-not $names.Count) { throw 'the image mounted but appears to be empty' }
                    $container = 'ISO image (mounted to read)'
                    # Ranked and sniffed HERE, while the image is still attached. The finally
                    # below lets go of it, and an .iso is never handed to tar - on an image
                    # with no Joliet extension tar truncates every name to 31 characters, so
                    # the entry could not be found afterwards even if we tried.
                    $entries = @(Get-RankedInstallers $names)
                } catch {
                    return @{ error = "this .iso could not be opened - $($_.Exception.Message)" }
                } finally {
                    # Let go of the image, but only if this code is what mounted it. Dismounting
                    # one the technician had already opened in Explorer would yank it out from
                    # under them. Leaving our own mounted would lock the file and consume a
                    # drive letter for every package inspected.
                    if ($img -and $weMounted) {
                        try { Dismount-DiskImage -ImagePath $local -ErrorAction SilentlyContinue | Out-Null } catch { }
                    }
                }
            }

            if ($isZip) {
                try {
                    $zip = [IO.Compression.ZipFile]::OpenRead($local)
                    $names = @($zip.Entries | Where-Object { $_.Name } |
                               ForEach-Object { ($_.FullName -replace '/', '\') })
                } catch { $names = @() }
            }
            if (-not $isIso -and -not $names.Count) {
                if ($zip) { try { $zip.Dispose() } catch {}; $zip = $null }
                $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
                if (Test-Path -LiteralPath $tarExe) {
                    $names = @(& $tarExe -tf $local 2>$null |
                               ForEach-Object { ($_ -replace '/', '\') } |
                               Where-Object { $_ -and -not $_.EndsWith('\') })
                    # A directory inside a .rar is listed with NO trailing separator - "Tools"
                    # rather than "Tools\" - so the usual test does not catch it and the folder
                    # would be offered as if it were a file to copy. Anything that is a parent
                    # of another entry is a directory, whatever the listing chose to print.
                    if ($names.Count) {
                        $names = @($names | Where-Object {
                            $n = $_
                            -not (@($names | Where-Object { $_ -ne $n -and $_.StartsWith($n + '\') }).Count)
                        })
                    }
                }
                if (-not $names.Count) {
                    return @{ error = "this archive could not be read - not a $($ext.TrimStart('.')), or damaged" }
                }
                $container = $(if ($isRar) { 'rar read via tar' } else { 'zip read via tar (codec .NET cannot open)' })
            }
            $files = @($names | Sort-Object)
            # An .iso ranked and sniffed its own entries while it was still mounted, above.
            if (-not $isIso) { $entries = @(Get-RankedInstallers $names) }
            if ($zip) { try { $zip.Dispose() } catch {} ; $zip = $null }
        }

        # How the package was OPENED, which is all this reports now. It says the listing can
        # be trusted; it says nothing about what switch the installer wants.
        if (-not $packager -and $container) { $packager = $container }

        # SHA-256 over a multi-GB package is what makes a fetch slow; reading the archive's own
        # table of contents is close to free. -ListOnly is that difference and nothing else, so
        # the listing comes back down the same code path - what the dialog offers on opening is
        # exactly what Fetch would have offered.
        $sha = ''
        if (-not $ListOnly) { $sha = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash }
        @{ sha256     = $sha
           size       = (Get-Item -LiteralPath $local).Length
           file       = $local
           entries    = $entries
           files      = $files
           packager   = $packager
           listOnly   = [bool]$ListOnly }
    } catch { @{ error = $_.Exception.Message } }
}

# The upload itself. One app at a time, for the same reason hashing is serial: these are
# multi-GB files over one link, and six at once just makes all six slow, with a far worse
# story when one of them fails.
#
# It dot-sources R2-Upload.ps1 by path rather than inheriting anything, so there is exactly one
# copy of the signing code in the process, and Test-Push.ps1 can lift this scriptblock out and
# run the very code that ships.
$script:PushWork = {
    param($ModulePath, $Plan, $Cred, $Progress, $StatePath, $PartSizeBytes, $ConverterPath, $Icons)

    . $ModulePath

    function Read-Doc {
        if (Test-Path -LiteralPath $StatePath) {
            try {
                $j = ((Get-Content -LiteralPath $StatePath -Raw).TrimStart([char]0xFEFF)) | ConvertFrom-Json
                $apps = @{}
                if ($j.apps) {
                    foreach ($p in $j.apps.PSObject.Properties) {
                        $e = @{}
                        foreach ($q in $p.Value.PSObject.Properties) { $e[$q.Name] = $q.Value }
                        if ($e.upload) {
                            $u = @{}
                            foreach ($q in $e.upload.PSObject.Properties) { $u[$q.Name] = $q.Value }
                            $parts = @{}
                            if ($u.parts) { foreach ($q in $u.parts.PSObject.Properties) { $parts[$q.Name] = [string]$q.Value } }
                            $u.parts  = $parts
                            $e.upload = $u
                        }
                        $apps[$p.Name] = $e
                    }
                }
                return @{ version = 1; updatedUtc = ''; apps = $apps }
            } catch { }
        }
        return @{ version = 1; updatedUtc = ''; apps = @{} }
    }

    $doc = Read-Doc
    function Write-Doc {
        $doc.updatedUtc = [datetime]::UtcNow.ToString('o')
        $tmp = "$StatePath.tmp"
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
        # Move -Force alone: this runs after EVERY completed part, and the old delete-then-move
        # opened a no-sidecar window 200 times per 200-part upload - a crash in any one of them
        # cost the whole resume record
        Move-Item -LiteralPath $tmp -Destination $StatePath -Force
    }

    $Progress.Phase = 'upload'
    $index = 0
    foreach ($item in @($Plan)) {
        if ($Progress.Cancel) { break }
        $index++
        $Progress.AppIndex = $index
        $Progress.AppId    = [string]$item.id
        $Progress.AppName  = [string]$item.name
        $Progress.AppBytes = [long]0
        $Progress.AppTotal = [long]$item.sizeBytes
        $Progress.Part     = 0
        $Progress.PartCount = 0

        try {
            # ---- a .rar becomes a .zip before anything is measured or sent ----
            #
            # Ahead of the skip check on purpose: that check compares the object in the bucket
            # against the size of the file which will actually go up, and until this has run
            # that is the size of a .rar that is never uploaded at all.
            if ($item.convert) {
                $zipPath = [string]$item.convertTo
                $srcInfo = Get-Item -LiteralPath ([string]$item.localPath) -ErrorAction SilentlyContinue
                $zipInfo = Get-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
                # An earlier push already converted this one. Re-doing it would cost minutes and
                # gigabytes to arrive at identical bytes, so it is reused unless the source has
                # been touched since.
                $stale = (-not $zipInfo) -or (-not $srcInfo) -or
                         ($zipInfo.LastWriteTimeUtc -lt $srcInfo.LastWriteTimeUtc)
                if ($stale) {
                    if (-not (Test-Path -LiteralPath $ConverterPath)) {
                        throw "cannot convert this .rar - $ConverterPath is missing"
                    }
                    $Progress.Phase = 'convert'
                    [void]$Progress.Log.Add("$($item.name): rewriting the .rar as a .zip...")
                    # its own console output is noise in here; a throw is what matters
                    $null = & $ConverterPath -Path ([string]$item.localPath) -Destination $zipPath -Force 6>$null
                    $zipInfo = Get-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
                    if (-not $zipInfo) { throw 'the conversion produced no .zip' }
                }
                $Progress.Phase = 'upload'
                $newSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
                # Reported so the UI thread can repoint the catalog AND the sidecar together.
                # Either one left naming the .rar and the next save undoes all of this.
                [void]$Progress.Converted.Add(@{ id = [string]$item.id; name = [string]$item.name
                                                 path = $zipPath; sha256 = $newSha
                                                 sizeBytes = [long]$zipInfo.Length
                                                 key = [string]$item.key
                                                 from = [string]$item.localPath })
                [void]$Progress.Log.Add("$($item.name): .zip is $('{0:N0}' -f $zipInfo.Length) bytes")
                # everything below this point uploads the .zip
                $item.localPath = $zipPath
                $item.sha256    = $newSha
                $item.sizeBytes = [long]$zipInfo.Length
                $Progress.AppTotal = [long]$zipInfo.Length
            }

            # Ask the bucket first. An object already there at the right size is not worth
            # re-sending 15 GB to prove - see the note on the skip rule in Start-PushConfirm.
            $info = Get-R2ObjectInfo -Credential $Cred -Key ([string]$item.key)
            if ($info.Exists -and [long]$info.Size -eq [long]$item.sizeBytes) {
                [void]$Progress.Skipped.Add(@{ id = [string]$item.id; name = [string]$item.name
                                               certain = [bool]$item.remoteVerified })
                $Progress.DoneBytes = [long]$Progress.DoneBytes + [long]$item.sizeBytes
                continue
            }

            if (-not $doc.apps.ContainsKey([string]$item.id)) {
                $doc.apps[[string]$item.id] = @{ localPath = [string]$item.localPath
                                                 sizeBytes = [long]$item.sizeBytes; mtimeUtc = ''
                                                 sha256 = [string]$item.sha256; key = [string]$item.key
                                                 upload = $null; remote = $null }
            }
            $entry = $doc.apps[[string]$item.id]
            $entry.sha256 = [string]$item.sha256

            $r = Invoke-R2Upload -Credential $Cred -Key ([string]$item.key) `
                                 -LocalPath ([string]$item.localPath) -State $entry -Progress $Progress `
                                 -PartSizeBytes $PartSizeBytes -OnStateChanged { Write-Doc }

            if ($r.Ok) {
                [void]$Progress.Done.Add(@{ id = [string]$item.id; name = [string]$item.name })
                $Progress.DoneBytes = [long]$Progress.DoneBytes + [long]$item.sizeBytes
            } elseif ($r.Cancelled) {
                [void]$Progress.Log.Add("$($item.name): $($r.Message)")
                break
            } else {
                [void]$Progress.Failed.Add(@{ id = [string]$item.id; name = [string]$item.name
                                              reason = [string]$r.Message })
            }
        } catch {
            # One app failing must not take the other sixteen with it.
            [void]$Progress.Failed.Add(@{ id = [string]$item.id; name = [string]$item.name
                                          reason = $_.Exception.Message })
        }
    }
    # ---- icons, last ----
    #
    # After the installers on purpose: they are the cheap part, and a failed icon must never be
    # the reason a 14 GB package did not go up. A failure here is logged, not fatal.
    foreach ($ic in @($Icons)) {
        if ($Progress.Cancel) { break }
        try {
            $st = @{ key = [string]$ic.key; upload = $null; remote = $null }
            $r = Invoke-R2Upload -Credential $Cred -Key ([string]$ic.key) `
                                 -LocalPath ([string]$ic.path) -State $st
            if ($r.Ok) { [void]$Progress.Icons.Add(@{ id = [string]$ic.id; key = [string]$ic.key }) }
            else { [void]$Progress.Log.Add("icon $($ic.id): $($r.Message)") }
        } catch {
            [void]$Progress.Log.Add("icon $($ic.id): $($_.Exception.Message)")
        }
    }

    try { Write-Doc } catch { }
    $Progress.Phase = $(if ($Progress.Cancel) { 'cancelled' } else { 'done' })
}

# ---------------------------------------------------------------- catalog I/O

function Test-App($a) {
    # what stops THIS app from being published, in words a person can act on
    $out = @()
    if (-not (Get-Field $a 'name')) { $out += 'no name' }
    # An uninstall-only entry ships removal knowledge for a product we never install - it HAS
    # no url, hash or size, and the edge serves it anyway (worker.js makes the same exception).
    # Holding it to installer standards kept a permanent amber warning on every save.
    $unOnly = [bool](Get-Field $a 'uninstallOnly')
    if (-not $unOnly) {
        if (-not (Get-Field $a 'url'))  { $out += 'no download URL' }
        if (-not (Test-RealHash ([string](Get-Field $a 'sha256')))) { $out += 'not hashed yet' }
        if ([long](Get-Field $a 'sizeBytes') -le 0) { $out += 'size unknown' }
    }
    # requires: every id must exist in this catalog. Warning-grade wording on purpose - the
    # client fails open on an unknown id, so the catalog should merely say so, not block.
    foreach ($rid in @(Get-Field $a 'requires')) {
        if ($rid -and $script:Catalog -and -not @(@($script:Catalog.apps) | Where-Object {
                ([string](Get-Field $_ 'id')) -eq [string]$rid }).Count) {
            $out += "requires '$rid', which is not in this catalog"
        }
    }
    # A duplicated id makes everything downstream ambiguous: two icons\<id>.png claims, two
    # files/<id>/ keys overwriting each other in R2, and Update-CatalogFromPush writing onto
    # whichever matched first. Nothing else checks - the id box normalises, never de-dupes.
    $myId = [string](Get-Field $a 'id')
    if ($myId -and $script:Catalog -and
        @(@($script:Catalog.apps) | Where-Object { [string](Get-Field $_ 'id') -eq $myId }).Count -gt 1) {
        $out += "shares its id '$myId' with another application"
    }
    # a url-form remover executes ELEVATED on the client, gated by its pinned hash - an unpinned
    # one would simply be refused there, so catch it here where it can still be fixed
    $cl = Get-Field $a 'cleanup'
    if ($cl) {
        foreach ($rm in @(Get-Field $cl 'removers')) {
            if ($rm -and (Get-Field $rm 'url') -and -not (Test-RealHash ([string](Get-Field $rm 'sha256')))) {
                $out += "remover '$(Get-Field $rm 'name')' is not hashed yet"
            }
        }
    }
    # A package is something with files inside to choose a setup from - .zip or .rar. A single
    # .exe or .msi is the installer itself and has nothing to pick.
    $u = ([string](Get-Field $a 'url')).ToLower()
    $isPackage = ($u.EndsWith('.zip') -or $u.EndsWith('.rar') -or $u.EndsWith('.iso'))
    if ($isPackage -and -not (Get-Field $a 'entry')) { $out += 'no setup file chosen inside the package' }
    if ((Get-Field $a 'entry') -and -not $isPackage) { $out += 'has a setup file but the URL is not a .zip, .rar or .iso' }
    # an after-install step taking its file OUT of the package needs there to BE a package -
    # the worker refuses `from` on a single installer, and it would refuse it on a client
    if (@(@(Get-Field $a 'postInstall') | Where-Object { $_ -and (Get-Field $_ 'from') }).Count -and
        -not (Get-Field $a 'entry')) { $out += 'after-install steps need a package (.zip) with a setup file' }
    return $out
}

# ---------------------------------------------------------------- categories
#
# A category used to be a free-text string repeated on every app, and this script wrote a
# hardcoded 'Apps' into every new one. Nothing could create a category, renaming one meant
# editing every app that carried it, and a typo silently produced a second group on the
# client. It is a LIST now, and it lives in the catalog rather than in this file - seeded once
# from whatever the apps already say, so an existing apps.json needs no migration and no
# category name appears anywhere in this script.
#
# ORDER is the reason it is a list and not a set. AppDeploy.ps1 groups the Install tab by
# category and adds no sort of its own, so this array IS the order a technician reads. Keeping
# it here also decouples it from app order, which has to stay the INSTALL order - Civil 3D onto
# AutoCAD, Corona onto 3ds Max - so reordering the rail can never reorder an installation.

function Get-CategoryNames {
    $named = @(@($script:Catalog.categories) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    # Whatever the apps use that the list has not caught up with - a hand-edited catalog, or an
    # entry brought in from elsewhere. Appended rather than dropped: a category that owns apps
    # but is missing from the list would put those apps in a group the rail cannot show.
    $used = @()
    foreach ($a in @($script:Catalog.apps)) {
        $c = [string](Get-Field $a 'category')
        if ($c -and ($used -notcontains $c)) { $used += $c }
    }
    $out = @()
    foreach ($c in $named) { if ($out -notcontains $c) { $out += $c } }
    foreach ($c in $used)  { if ($out -notcontains $c) { $out += $c } }
    return @($out)
}

# Called from inside the drawer's closures. Assigning $script:Dirty directly from a scriptblock
# built with GetNewClosure() does not reach this file's scope - the read succeeds and the write
# goes somewhere else - so the unsaved-changes warning silently stopped arming. A function call
# resolves normally and cannot drift.
# ---------------------------------------------------------------- autosave
#
# There is no Save button any more, and this one line is why the whole file gets autosave for
# free: every edit already routes through Set-CatalogDirty, because assigning $script: from
# inside a drawer closure does not reach script scope (see the comment this function was
# written for). Arming the timer HERE means no edit path can forget to save.
#
# Debounced at 1.2s so typing does not serialise the catalog per character, with a 5-second
# CEILING - without it, sustained typing would defer the write forever.
$script:SaveTimer  = $null      # created below, once the window exists
$script:DirtySince = $null
$script:SaveFailed = $false

function Request-Save {
    if ($null -eq $script:DirtySince) { $script:DirtySince = Get-Date }
    if ($script:SaveTimer) { $script:SaveTimer.Stop(); $script:SaveTimer.Start() }
}

function Set-CatalogDirty { $script:Dirty = $true; Request-Save }

# The ONE write path. Export-Catalog is still the only thing that touches apps.json - autosave
# does not introduce a second writer, which matters because that writer is the only place the
# BOM-less UTF8Encoding($false) rule is enforced.
function Complete-Save([switch]$Force) {
    if ($script:SaveTimer) { $script:SaveTimer.Stop() }
    if (-not $script:Dirty) { $script:DirtySince = $null; return $true }
    # One writer at a time. Complete-Push does its own save AFTER rewriting every url and hash;
    # an autosave landing in the middle of that would write the pre-rewrite catalog over the
    # post-rewrite one. Re-arm instead, so the save lands the moment the push is done.
    if (-not $Force -and ($script:PushJob -or $script:PublishProc)) {
        if ($script:SaveTimer) { $script:SaveTimer.Start() }
        return $false
    }
    # The ceiling: while typing continues the timer keeps being pushed out, so once the oldest
    # unsaved edit is 5s old the write happens regardless.
    if (-not $Force -and $script:DirtySince -and
        ((Get-Date) - $script:DirtySince).TotalSeconds -lt 1.0) {
        if ($script:SaveTimer) { $script:SaveTimer.Start() }
        return $false
    }
    # Before the write, so the catalog and the icons directory agree the moment the file lands.
    try { Complete-IconMoves } catch { }
    try {
        $ok = Export-Catalog
        if ($ok) {
            $script:SaveFailed = $false
            $script:DirtySince = $null
            # Level 1 deliberately: an autosave is ambient, and must never be the thing that
            # wipes the confirmation of what the person actually just did.
            Show-Activity 'Saved.' '#FFB6B6C0' 1 2500
        }
        return $ok
    } catch {
        # $script:Dirty is left SET on purpose, so the next edit retries the write.
        $script:SaveFailed = $true
        Show-Fail "Could not save apps.json: $($_.Exception.Message)"
        return $false
    }
}

# A named function on purpose: assigning $script:SelectedCategory from inside a
# .GetNewClosure() block lands in the closure's own module and never reaches this file's
# scope - the documented trap, sighting number six (the category-rename dialog). A named
# call falls through to the real scope every time.
function Set-SelectedCategory([string]$Name) { $script:SelectedCategory = $Name }

function Set-CategoryNames($Names) {
    Set-Field $script:Catalog 'categories' @(@($Names) | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Get-AppsInCategory([string]$Name) {
    return @(@($script:Catalog.apps) | Where-Object { [string](Get-Field $_ 'category') -eq $Name })
}

# What a brand-new app should be filed under. Whatever the rail is showing, so "add" puts the
# app where the person is looking; the first category otherwise. Never a literal.
function Get-DefaultCategory {
    $sel = [string]$script:SelectedCategory
    if ($sel) { return $sel }
    $names = @(Get-CategoryNames)
    if ($names.Count) { return [string]$names[0] }
    return ''
}

function Add-Category([string]$Name) {
    $n = ([string]$Name).Trim()
    if (-not $n) { return $false }
    $names = @(Get-CategoryNames)
    if ($names -contains $n) { return $false }
    Set-CategoryNames (@($names) + $n)
    return $true
}

function Rename-Category([string]$Old, [string]$New) {
    $o = ([string]$Old).Trim(); $n = ([string]$New).Trim()
    if (-not $o -or -not $n -or $o -eq $n) { return $false }
    $names = @(Get-CategoryNames)
    if ($names -notcontains $o) { return $false }
    # Renaming ONTO an existing name is allowed - it is how two groups become one - so the list
    # must be de-duplicated as it is rewritten rather than ending up holding the name twice.
    $out = @()
    foreach ($c in $names) {
        $v = $(if ($c -eq $o) { $n } else { $c })
        if ($out -notcontains $v) { $out += $v }
    }
    Set-CategoryNames $out
    foreach ($a in @($script:Catalog.apps)) {
        if ([string](Get-Field $a 'category') -eq $o) { Set-Field $a 'category' $n }
    }
    return $true
}

function Move-Category([string]$Name, [int]$Delta) {
    $names = @(Get-CategoryNames)
    $i = [Array]::IndexOf($names, $Name)
    if ($i -lt 0) { return $false }
    $j = $i + $Delta
    if ($j -lt 0 -or $j -ge $names.Count) { return $false }
    $t = $names[$i]; $names[$i] = $names[$j]; $names[$j] = $t
    Set-CategoryNames $names
    return $true
}

<#
    Remove a category, and say what happens to the applications inside it.

    There is no safe default here, which is why there is no default. Deleting a category that
    owns seven apps and 43 GB of already-uploaded installers must not be the same click as
    deleting an empty one, so the caller has to choose: move them somewhere named, or delete
    them too. A -MoveTo naming nothing, itself, or a category that does not exist is REFUSED
    rather than guessed - an app silently relocated into a group nobody looks in is worse than
    an error.

    Either way the bytes in R2 are untouched. This removes catalog entries, not uploads.
#>
function Remove-Category([string]$Name, [string]$MoveTo = '', [switch]$DeleteApps) {
    $names = @(Get-CategoryNames)
    if ($names -notcontains $Name) { return $false }
    $apps = @(Get-AppsInCategory $Name)
    if ($apps.Count) {
        if ($DeleteApps) {
            $script:Catalog.apps = @(@($script:Catalog.apps) |
                Where-Object { [string](Get-Field $_ 'category') -ne $Name })
        } else {
            $target = ([string]$MoveTo).Trim()
            if (-not $target -or $target -eq $Name -or ($names -notcontains $target)) { return $false }
            foreach ($a in $apps) { Set-Field $a 'category' $target }
        }
    }
    Set-CategoryNames (@($names) | Where-Object { $_ -ne $Name })
    return $true
}

function Import-Catalog {
    if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "No catalog at $CatalogPath" }
    $raw = Get-Content -LiteralPath $CatalogPath -Raw
    $script:Catalog = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
    # property EXISTENCE, not truthiness: deleting the last application writes "apps": [] -
    # a legal, reopenable catalog - and -not @() is $true, so the editor refused to reopen
    # the very file it had just saved
    if (-not $script:Catalog -or -not $script:Catalog.PSObject.Properties['apps']) { throw 'Catalog has no apps array.' }
    # Seed the list once, from what the apps already say. A catalog that has never been opened
    # by this version has no `categories` key, and that must not read as "no categories" - it
    # would empty the rail on a catalog with nineteen filed apps.
    if (-not $script:Catalog.PSObject.Properties['categories']) { Set-CategoryNames (Get-CategoryNames) }
    Update-Categories
    Update-List
}

<#
    A ring of timestamped copies: at most one every ten minutes, twenty kept.

    apps.json.bak answers "put it back to how it was when I opened the editor". It cannot answer
    "put it back to before the thing I did an hour ago", and under autosave there is no longer
    any moment where a person DECIDED to write - so there is nothing to hang a second undo point
    on except the clock. Ten minutes and twenty copies is a bit over three hours of history for
    a file of a few tens of kilobytes.

    Every failure is swallowed. This is a courtesy, and it must never be the reason a session's
    work cannot be saved.
#>
$script:LastHistoryUtc = [datetime]::MinValue

function Save-CatalogHistory {
    # Self-initialising: the harnesses lift this out by AST and run it without the assignment
    # above, and subtracting $null from a datetime throws.
    if ($null -eq $script:LastHistoryUtc) { $script:LastHistoryUtc = [datetime]::MinValue }
    if (-not $CatalogPath -or -not (Test-Path -LiteralPath $CatalogPath)) { return }
    $now = [datetime]::UtcNow
    if (($now - $script:LastHistoryUtc).TotalMinutes -lt 10) { return }
    try {
        $dir = Join-Path (Split-Path -Parent $CatalogPath) '.apps-history'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Copied BEFORE the write, so a file here is a state the catalog actually had.
        Copy-Item -LiteralPath $CatalogPath -Force `
                  -Destination (Join-Path $dir ('apps-' + $now.ToString('yyyyMMdd-HHmmss') + '.json'))
        $script:LastHistoryUtc = $now
        # Sorted by NAME, which is why the timestamp is written widest-unit-first: it sorts
        # lexically in the same order it sorts chronologically, with no date parsing to get
        # wrong and no dependence on the file times of copies.
        foreach ($old in @(Get-ChildItem -LiteralPath $dir -Filter 'apps-*.json' -File -ErrorAction SilentlyContinue |
                           Sort-Object Name -Descending | Select-Object -Skip 20)) {
            try { Remove-Item -LiteralPath $old.FullName -Force } catch { }
        }
    } catch { }
}

function Export-Catalog {
    if (-not $script:Catalog) {
        # the catalog never parsed - saving would first overwrite the .bak with the broken
        # file and then throw anyway. Say it, and leave both files alone.
        Set-StatusText 'Nothing loaded to save - fix apps.json and reopen the editor.' '#FFF87171'
        return $false
    }
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
    # THE SESSION BACKUP, taken once - not once per save.
    #
    # Under autosave a per-save copy would mean "the catalog as it was 1.2 seconds ago", which
    # is no undo at all. Taken once, before the first write of the session, it means "the
    # catalog as it was when I opened the editor" - which is the undo a person actually reaches
    # for. Still a courtesy and never a reason a session's work cannot be saved.
    if (-not $script:SessionBackupDone -and (Test-Path -LiteralPath $CatalogPath)) {
        try { Copy-Item -LiteralPath $CatalogPath -Destination "$CatalogPath.bak" -Force } catch { }
        $script:SessionBackupDone = $true
    }
    # The longer-range undo the .bak deliberately is not - see Save-CatalogHistory.
    Save-CatalogHistory
    Set-Field $script:Catalog 'updated' (Get-Date -Format 'yyyy-MM-dd')
    # _localFile is where the bytes were on the machine that BUILT the catalog. It means nothing
    # on a client and would leak a local path into a published file, so it never gets written -
    # but it is stripped from a serialization CLONE, not from the live objects: stripping live
    # first meant a failed write had already destroyed the only in-memory copy of every picked
    # file path, and even a successful save threw away state a later Push still wanted.
    $clone = ($script:Catalog | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    foreach ($a in @($clone.apps)) { Remove-Field $a '_localFile' }
    # WriteAllText with UTF8Encoding($false), never Set-Content -Encoding UTF8, which adds a
    # BOM that stops Invoke-RestMethod parsing the catalog as JSON at all
    [IO.File]::WriteAllText($CatalogPath, ($clone | ConvertTo-Json -Depth 10),
                            (New-Object Text.UTF8Encoding $false))
    $script:Dirty = $false
    # SILENT on purpose. This runs on a 1.2s debounce now, and an amber "N are not ready to
    # publish" every second and a half would be a permanent nag about a fact that is not an
    # event - it is a standing property of the catalog, and the summary slot already reports
    # it on every refresh. Complete-Save says the one ambient word that IS an event.
    return $true
}

# ---------------------------------------------------------------- push state (sidecar)
#
# Export-Catalog strips _localFile from every app on every save, and it is right to: it is a
# path on the machine that BUILT the catalog, it means nothing on a client, and publishing it
# would leak a local directory layout. But Push needs to know where the bytes are, and it needs
# somewhere durable to keep a multipart uploadId so a dropped 14 GB upload resumes instead of
# starting over. Neither belongs in apps.json.
#
# So they live here, in a private file next to the editor, keyed by app id. _localFile stays,
# but only as an in-memory cache of what this file already knows.

function ConvertTo-HashtableDeep($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    return $Obj
}

function Get-PushState {
    if ($script:PushState) { return $script:PushState }
    $script:PushState = @{ version = 1; catalog = $CatalogPath
                           updatedUtc = ([datetime]::UtcNow.ToString('o')); apps = @{} }
    # a crash between the .tmp write and the swap leaves only the .tmp - it holds the newest
    # complete document, so recover from it rather than silently starting empty
    $readPath = $PushStatePath
    if (-not (Test-Path -LiteralPath $readPath) -and (Test-Path -LiteralPath "$PushStatePath.tmp")) {
        $readPath = "$PushStatePath.tmp"
    }
    if (Test-Path -LiteralPath $readPath) {
        try {
            $raw = (Get-Content -LiteralPath $readPath -Raw).TrimStart([char]0xFEFF)
            $j = $raw | ConvertFrom-Json
            $apps = ConvertTo-HashtableDeep $j.apps
            if ($apps) { $script:PushState.apps = $apps }
        } catch {
            # A truncated or hand-mangled sidecar is a nuisance, not a disaster - it costs a
            # re-upload, not a wrong catalog. Starting clean beats refusing to open the editor.
            $script:PushState.apps = @{}
        }
    }
    return $script:PushState
}

function Save-PushState {
    $st = Get-PushState
    $st.updatedUtc = [datetime]::UtcNow.ToString('o')
    $st.catalog    = $CatalogPath
    $dir = Split-Path -Parent $PushStatePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Written after every completed part, so a crash mid-write must not cost the whole upload
    # record: build a .tmp, then swap. BOM-less for the same reason the catalog is.
    $tmp = "$PushStatePath.tmp"
    [IO.File]::WriteAllText($tmp, ($st | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
    # Move -Force alone: the old delete-then-move opened a window in which the sidecar did
    # not exist at all, and a crash there cost every localPath and in-flight uploadId - the
    # precise loss this .tmp dance exists to prevent.
    Move-Item -LiteralPath $tmp -Destination $PushStatePath -Force
}

<#
    The sidecar entry for an app, created empty if there is not one yet.

    An app's id is derived from its name, so renaming an app orphans its entry. Before giving
    up, the entry is looked for by local path, size and mtime together - that identifies the
    same bytes under a new name, and re-keys rather than losing a part-finished upload.
#>
function Get-PushStateFor($App) {
    $st = Get-PushState
    $id = [string](Get-Field $App 'id')
    if (-not $id) { $id = ConvertTo-Id ([string](Get-Field $App 'name')) }
    if (-not $id) { return $null }
    if ($st.apps.ContainsKey($id)) { return $st.apps[$id] }

    $lf = [string](Get-Field $App '_localFile')
    if ($lf -and (Test-Path -LiteralPath $lf)) {
        $fi = Get-Item -LiteralPath $lf
        foreach ($k in @($st.apps.Keys)) {
            $e = $st.apps[$k]
            if ([string]$e.localPath -eq $lf -and [long]$e.sizeBytes -eq $fi.Length) {
                # Never steal from an app that still exists. Two entries can legitimately point
                # at the same bytes (Duplicate, a shared bundle) - re-keying is only for a
                # RENAME, where the old id has no owner left in the catalog. Without this, the
                # second app to be looked up took the first one's upload record with it,
                # including a part-finished multipart uploadId.
                if ($script:Catalog -and @(@($script:Catalog.apps) | Where-Object {
                        [string](Get-Field $_ 'id') -eq [string]$k }).Count) { continue }
                $st.apps.Remove($k)          # re-key onto the new id
                $st.apps[$id] = $e
                return $e
            }
        }
    }
    $st.apps[$id] = @{ localPath = ''; sizeBytes = [long]0; mtimeUtc = ''; sha256 = ''
                       key = ''; upload = $null; remote = $null }
    return $st.apps[$id]
}

<#
    Where this app's bytes are, or '' if this machine does not have them.

    _localFile is consulted first because it is free, but it is only a cache - Export-Catalog
    deletes it on every save, so after one save the answer has to come from the sidecar.
#>
function Get-LocalFileFor($App) {
    $lf = [string](Get-Field $App '_localFile')
    if ($lf -and (Test-Path -LiteralPath $lf)) { return $lf }
    $e = Get-PushStateFor $App
    if ($e -and [string]$e.localPath -and (Test-Path -LiteralPath ([string]$e.localPath))) {
        Set-Field $App '_localFile' ([string]$e.localPath)   # rehydrate the cache
        return [string]$e.localPath
    }
    return ''
}

function Set-LocalFileFor($App, [string]$Path, [switch]$KeepRemote) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    Set-Field $App '_localFile' $Path
    $e = Get-PushStateFor $App
    if (-not $e) { return }
    $fi = Get-Item -LiteralPath $Path
    # A different file under the same app invalidates any part-finished upload of the old one.
    # -KeepRemote is for the one caller where the path change IS the upload: a .rar converted
    # to .zip and pushed - clearing `remote` there wiped the proof written seconds earlier.
    if ([string]$e.localPath -and [string]$e.localPath -ne $Path -and -not $KeepRemote) { $e.upload = $null; $e.remote = $null }
    $e.localPath = $Path
    $e.sizeBytes = [long]$fi.Length
    $e.mtimeUtc  = $fi.LastWriteTimeUtc.ToString('o')
    Save-PushState
}

<#
    Persist what the dialog just learned about an app into the sidecar.

    Called by the main window after Show-AppDialog returns true, rather than from inside the
    dialog itself. The dialog is lifted out of this file and run standalone by two harnesses,
    and it has no business depending on a state file whose path is resolved at editor startup.
#>
function Save-AppSources($App) {
    $lf = [string](Get-Field $App '_localFile')
    if ($lf) { Set-LocalFileFor $App $lf }
    $sha = [string](Get-Field $App 'sha256')
    if ($sha) { Set-PushHashFor $App $sha ([long](Get-Field $App 'sizeBytes')) }
}

function Set-PushHashFor($App, [string]$Sha, [long]$Size) {
    # Only a real hash. The catalog ships with sha256 set to the literal REPLACE_WITH_REAL_SHA256
    # on sixteen apps, and storing that as though it were a hash would make the skip check later
    # compare a placeholder against a placeholder and call the file "already in R2".
    if (-not (Test-RealHash $Sha)) { return }
    $e = Get-PushStateFor $App
    if (-not $e) { return }
    $e.sha256    = $Sha
    $e.hashedUtc = [datetime]::UtcNow.ToString('o')
    if ($Size -gt 0) { $e.sizeBytes = $Size }
    Save-PushState
}

<#
    The R2 key and the catalog url for an app: files/<id>/<the local file's own name>.

    The <id> segment is not decoration. office365 needs its configuration.xml sitting beside
    setup.exe - its own _installNote says so - and a flat /files/ namespace cannot do that
    without two apps colliding on "setup.exe".
#>
function Get-AppKey($App) {
    $id = [string](Get-Field $App 'id')
    if (-not $id) { $id = ConvertTo-Id ([string](Get-Field $App 'name')) }
    $leaf = ''
    $lf = Get-LocalFileFor $App
    if ($lf) { $leaf = [IO.Path]::GetFileName($lf) }
    if (-not $leaf) {
        $u = [string](Get-Field $App 'url')
        if ($u) { try { $leaf = [IO.Path]::GetFileName(([Uri]$u).LocalPath) } catch { } }
    }
    if (-not $leaf) { return '' }
    return "files/$id/$leaf"
}

function Get-AppUrl($App) {
    $k = Get-AppKey $App
    if (-not $k) { return '' }
    return "$($BaseUrl.TrimEnd('/'))/$k"
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
    # Get-LocalFileFor, not the raw field: Export-Catalog strips _localFile from the LIVE
    # objects, so saving mid-bulk used to dequeue every remaining app with an empty source -
    # the hash quietly never happened and the status line still said everything was added.
    # The sidecar (which bulk import writes at add time) is the fallback that survives a save.
    [void]$script:BulkJob.AddScript([string]$script:FetchWork).
           AddArgument([string](Get-LocalFileFor $app)).AddArgument($PackageDir).
           AddArgument($false)
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
        # The hash Push compares against when deciding whether the object already in R2 is this
        # file. Kept beside the local path rather than read back out of the catalog, because the
        # catalog is the thing Push is about to rewrite.
        Set-PushHashFor $app ([string]$r.sha256) ([long]$r.size)
        # proposed, never forced - the same rule the dialog follows
        if (@($r.entries).Count -and -not (Get-Field $app 'entry')) { Set-Field $app 'entry' (@($r.entries)[0]) }
        # a verify path only if the product is genuinely on THIS machine; a guess here would be
        # indistinguishable from a checked fact later
        if (-not @(Get-Field $app 'verifyPaths').Count) {
            $real = @(Get-VerifyCandidates ([string](Get-Field $app 'name')) |
                      Where-Object { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_)) })
            if ($real.Count) { Set-Field $app 'verifyPaths' @($real[0]) }
        }
    }
    Set-CatalogDirty
    Update-List
    if ($script:BulkQueue.Count -or $script:BulkJob) {
        Set-StatusText "Hashing $($script:BulkDone + 1) of $($script:BulkTotal)..." '#FF4C8DFF'
    } else {
        Set-StatusText ("Added $($script:BulkTotal) application(s) from the folder." +
            $(if ([int]$script:BulkSkipped) { " $($script:BulkSkipped) file(s) skipped - an app with the same derived id already exists." } else { '' }) +
            ' Review each one, then save.') $(if ([int]$script:BulkSkipped) { '#FFFBBF24' } else { '#FF34D399' })
    }
}

# ---------------------------------------------------------------- what just happened
#
# One status line was doing three jobs - busy, "that worked", and the standing catalog count -
# and Update-List owned the third. Update-List runs on every keystroke, so it overwrote the
# other two within milliseconds: 'R2 credentials saved.' and 'Icon set for Revit.' were being
# written correctly and then wiped before anyone could read them. That is why actions felt
# unconfirmed, and it is why simply ADDING more messages would have changed nothing.
#
# The fix is a priority, not more text. Every message carries a level and an expiry, and a
# lower level cannot overwrite a higher one while it is still fresh:
#
#   0 idle · 1 ambient (autosave, a background check) · 2 busy · 3 a user action's result
#   4 failure
#
# So a live-check landing 200ms after you saved credentials loses to the confirmation, and the
# confirmation stays put for its six seconds. No caller has to know any of this - it is one
# comparison in one function, and Set-StatusText below maps the colours callers already pass.
$script:Activity = @{ Text = ''; Colour = '#FFB6B6C0'; Level = 0; Until = [datetime]::MinValue }

# The dot follows the message, so there is a signal even when the text is not being read.
function Get-LevelDot([int]$Level) {
    if ($Level -ge 4) { return '#FFF87171' }   # red    - failed
    if ($Level -eq 2) { return '#FF4C8DFF' }   # blue   - working
    return '#FF4ADE80'                          # green  - fine
}

function Show-Activity([string]$Text, [string]$Colour, [int]$Level, [int]$HoldMs) {
    $now = Get-Date
    # the whole rule, in one line
    if ($Level -lt $script:Activity.Level -and $now -lt $script:Activity.Until) { return }
    # NOTHING is allowed to hold the slot forever, not even a failure. A busy message whose
    # operation dies without reporting would otherwise wedge the status line for the rest of
    # the session, and a sticky red would silence every message after it.
    $hold = $HoldMs
    if ($hold -le 0) { $hold = 120000 }
    $script:Activity.Text   = $Text
    $script:Activity.Colour = $Colour
    $script:Activity.Level  = $Level
    $script:Activity.Until  = $now.AddMilliseconds($hold)
    try {
        $TxtStatus.Text = $Text
        $TxtStatus.Foreground = $Colour
        $DotStatus.Fill = Get-LevelDot $Level
    } catch { }
}

function Show-Busy([string]$Text) { Show-Activity $Text '#FF4C8DFF' 2 0 }
function Show-Done([string]$Text) { Show-Activity $Text '#FF34D399' 3 6000 }
function Show-Warn([string]$Text) { Show-Activity $Text '#FFFBBF24' 3 12000 }
function Show-Fail([string]$Text) { Show-Activity $Text '#FFF87171' 4 20000 }

# Called from the 400ms bulk timer, which already ticks unconditionally. A message that has had
# its moment stops BLOCKING, but a failure keeps its text on screen - that is the one thing that
# should still be readable when somebody comes back to the window.
function Sync-Activity {
    if ($script:Activity.Level -le 0) { return }
    if ((Get-Date) -lt $script:Activity.Until) { return }
    $wasFail = ($script:Activity.Level -ge 4)
    $script:Activity.Level = 0
    $script:Activity.Until = [datetime]::MaxValue
    if (-not $wasFail) {
        try { $TxtStatus.Text = ''; $DotStatus.Fill = Get-LevelDot 0 } catch { }
    }
}

# The standing truth about the catalog. ONE writer - Update-List - and it never touches the
# activity slot again.
function Set-CatalogSummary([string]$Text) {
    try { $TxtSummary.Text = $Text } catch { }
}

# Kept by name and signature so all ~30 existing call sites work untouched. The colour they
# already pass encodes the intent, so mapping it here reclassifies the entire file at once.
function Set-StatusText([string]$text, [string]$colour = '#FFB6B6C0') {
    switch ($colour) {
        '#FF34D399' { Show-Done $text; return }   # green - it worked
        '#FFFBBF24' { Show-Warn $text; return }   # amber - worked, with a caveat
        '#FFF87171' { Show-Fail $text; return }   # red   - it failed
        '#FF4C8DFF' { Show-Busy $text; return }   # blue  - working on it
    }
    Show-Activity $text $colour 1 4000
}

# ---------------------------------------------------------------- overlay, not MessageBox
# The answer arrives through a callback rather than a return value, because the window keeps
# running underneath. That is the whole point: a modal MessageBox stops everything until a
# person clicks it, which makes every path behind one impossible to test and hangs any
# unattended run outright.
$script:ConfirmAction = $null

<#
    Put every overlay body away, in ONE place.

    Seven functions share this single Overlay, and each used to list the others by hand. That is
    a rule that has to be re-obeyed in seven places every time a body is added, and it was
    already broken: adding the access-code body taught only Show-Confirm and Show-Notice about
    it, so "Access code -> Cancel -> New category" showed a password box underneath the category
    box. Adding a body to this array is now the entire job.
#>
function Hide-OverlayBodies {
    foreach ($panel in @($OverlayInput, $OverlayPick, $OverlayName, $OverlayManage,
                         $OverlayCode, $OverlaySettings)) {
        $panel.Visibility = 'Collapsed'
    }
}

function Show-Notice([string]$Title, [string]$Body) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayBody.Text = $Body
    $BtnOverlayCancel.Visibility = 'Collapsed'
    $BtnOverlayOk.Content = 'OK'
    Hide-OverlayBodies
    $script:ConfirmAction = $null
    $Overlay.Visibility = 'Visible'
}

function Remove-App($App, [string]$Name) {
    $id = [string](Get-Field $App 'id')
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $App })
    # The PNG used to stay in icons\ forever under an id nothing referred to - and worse, an app
    # created later with the same id silently inherited the deleted one's artwork. Set aside
    # rather than deleted, because a hand-made icon is not something to destroy on a click that
    # was about the catalog entry.
    Hide-AppIcon $id
    Set-CatalogDirty
    Update-List
    Set-StatusText "Removed $Name.."
}

# Named with a leading dot so it sorts out of the way and reads as machinery rather than as a
# category somebody made.
function Hide-AppIcon([string]$Id) {
    if (-not $Id -or -not $script:IconDir) { return }
    $src = Join-Path $script:IconDir "$Id.png"
    if (-not (Test-Path -LiteralPath $src)) { return }
    try {
        $bin = Join-Path $script:IconDir '.removed'
        if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }
        $dest = Join-Path $bin "$Id.png"
        # Removing the same id twice in one session would otherwise fail on the second - the
        # older copy is the one already set aside, so the newer one wins.
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction Stop }
        Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
    } catch { }
}

function Show-Confirm([string]$Title, [string]$Body, [string]$OkText, [scriptblock]$OnConfirm) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayBody.Text = $Body
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = $OkText
    Hide-OverlayBodies
    $script:ConfirmAction = $OnConfirm
    $Overlay.Visibility = 'Visible'
}

<#
    Removing a category, with the applications inside it accounted for out loud.

    An empty category is a plain confirm. One that owns applications is not: it offers a
    destination, defaulted to the first other category, and a separate red checkbox for
    deleting them along with it. The count and the size are named in the body because "remove
    Autodesk?" and "remove Autodesk and 43.2 GB of installers you have already uploaded?" are
    different questions and only one of them is being asked.
#>
function Show-CategoryRemove([string]$Name) {
    $apps = @(Get-AppsInCategory $Name)
    $others = @(@(Get-CategoryNames) | Where-Object { $_ -ne $Name })
    if (-not $apps.Count) {
        Show-Confirm 'Remove this category?' (
            "'$Name' holds no applications.`r`n`r`n" +
            'The catalog as it was when you opened the editor is kept as apps.json.bak.'
        ) 'Remove' ({ if (Remove-Category $Name) { Complete-CategoryChange "Removed $Name." } }.GetNewClosure())
        return
    }
    # Nowhere to move them to means the choice is not a choice, and offering an empty dropdown
    # would read as one. This is the last category in the catalog.
    if (-not $others.Count) {
        Show-Notice 'Cannot remove the last category' (
            "'$Name' holds $($apps.Count) application(s) and it is the only category left, so " +
            'there is nowhere to move them. Create another category first, or remove the ' +
            'applications individually.')
        return
    }
    $bytes = 0L
    foreach ($a in $apps) { $bytes += [long](Get-Field $a 'sizeBytes') }
    $TxtOverlayTitle.Text = "Remove the $Name category?"
    $TxtOverlayBody.Text = (
        "It holds $($apps.Count) application(s), $(Format-Size $bytes) of installers.`r`n`r`n" +
        'Removing the category does not remove those installers from R2.')
    $CmbCatTarget.ItemsSource = $others
    $CmbCatTarget.SelectedIndex = 0
    $ChkCatDeleteApps.IsChecked = $false
    Hide-OverlayBodies
    $OverlayPick.Visibility = 'Visible'
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = 'Remove category'
    $script:ConfirmAction = ({
        $target = [string]$CmbCatTarget.SelectedItem
        $del = [bool]$ChkCatDeleteApps.IsChecked
        $ok = $(if ($del) { Remove-Category $Name -DeleteApps } else { Remove-Category $Name -MoveTo $target })
        if ($ok) {
            Complete-CategoryChange $(if ($del) {
                "Removed $Name and its $($apps.Count) application(s)."
            } else {
                "Removed $Name. Its $($apps.Count) application(s) moved to $target."
            })
        } else {
            Set-StatusText "Could not remove $Name." '#FFF87171'
        }
    }.GetNewClosure())
    $Overlay.Visibility = 'Visible'
}

# Every category edit ends the same way, and forgetting any one of these three is how a change
# looks like it did not happen: the rail redraws, the list under it redraws, and the catalog is
# marked unsaved so closing warns.
function Complete-CategoryChange([string]$Say) {
    Set-CatalogDirty
    Update-Categories
    Update-List
    # The manage list is a SECOND view of the same order, and nothing ever told it. Move up
    # reordered the rail underneath while the list being clicked stayed exactly as it was, and
    # the only feedback was a status line hidden behind the overlay's own scrim - so the button
    # read as doing nothing at all.
    if ([string]$OverlayManage.Visibility -eq 'Visible') { Update-ManageList }
    if ($Say) { Set-StatusText "$Say." }
}

<#
    Ask for the R2 key pair, in the window rather than in a MessageBox.

    Same shape as Show-Confirm - the answer arrives through a callback, because the window keeps
    running underneath and a modal dialog would be undriveable by any harness and a hang in an
    unattended run. The account id is pre-filled from what wrangler already cached, so a person
    only has to paste the two halves they actually had to go and create.
#>
# ---------------------------------------------------------------- the access code
#
# The gate on /AppDeploy.ps1 and /apps.json (see cloudflare\worker.js). Setting and ROTATING
# it are the same act - one `wrangler secret put ACCESS_CODE` - which is the whole reason a
# leaked code is cheap: hand out a new one and every code ever given out is dead, with no
# republish and nothing to change on any client.
#
# Deliberately NOT stored anywhere by this tool. It is typed here, handed to wrangler, and
# forgotten; there is no "current code" to read back, because a copy kept locally would be one
# more place to leak from and would go stale the moment somebody rotated from another machine.
function Show-AccessCodePrompt {
    $TxtOverlayTitle.Text = 'Set or rotate the access code'
    $TxtOverlayBody.Text  = (
        'This is what a technician types when the tool starts. The paste-line itself stays ' +
        'public - it is what the line FETCHES that this protects, so a noted line is useless ' +
        'without the code.')
    $PwdAccessCode.Password = ''
    $TxtCodeHint.Text = (
        'Setting a new code immediately kills the old one, everywhere, for everyone. ' +
        'Leave it blank and press Remove to take the gate off entirely.')
    Hide-OverlayBodies
    $OverlayCode.Visibility      = 'Visible'
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = 'Set code'
    $script:ConfirmAction = { Set-AccessCode }
    $Overlay.Visibility = 'Visible'
}

# Hands the code to wrangler on STDIN, never on a command line - Win32_Process.CommandLine is
# readable by every process on this machine, and this is the one value that must not appear
# there. wrangler wants it on stdin anyway, so the temp file is the mechanism rather than a
# workaround: written with an owner-only DACL, redirected in, and shredded in the finally.
#
# No console window, and nothing waited on. It used to open its own visible cmd.exe over this
# window and block the dispatcher until wrangler returned, so the app stopped repainting and a
# black window appeared on top of it - both of them reported as the thing that made the tool feel
# broken. What that window was actually good for is that a person could SEE an expired Cloudflare
# sign-in; that job is now done by Complete-WranglerCall, which reads wrangler's own output.
function Set-AccessCode {
    $code = '' + $PwdAccessCode.Password
    $PwdAccessCode.Password = ''
    $cfDir = Join-Path $script:RepoRoot 'cloudflare'
    if (-not (Test-Path -LiteralPath (Join-Path $cfDir 'wrangler.toml'))) {
        Show-Notice 'Cannot reach the edge' "No cloudflare\wrangler.toml under $($script:RepoRoot), so there is nothing to configure."
        return
    }
    if (-not $code) {
        Show-Confirm 'Remove the access code?' (
            'The tool and the catalog become reachable by anyone who has the link. Only do ' +
            'this if the link itself is not shared outside your team.') 'Remove the gate' {
            Invoke-Wrangler @('secret', 'delete', 'ACCESS_CODE', '--force') '' 'Access code removed - the gate is off.'
        }
        return
    }
    # The only action in this window that changes production for everybody at once - and it was
    # the only one with no confirm on it, which also made it the easiest to do by accident. What
    # the hint said quietly beside the box is asked here instead, where it has to be answered.
    #
    # An installer already downloading is genuinely unaffected: the gate is on /AppDeploy.ps1 and
    # /apps.json only, and packages come from /files/ on URLs that were already signed.
    Show-Confirm 'Set this access code?' (
        "Every code you have handed out stops working the moment this lands - including the one " +
        "you are using yourself. There is no list of them and no way to undo it; the only way " +
        "back is to set another code and hand that one out.`r`n`r`n" +
        'A download already running is not interrupted. Anyone who STARTS the tool after this ' +
        'will be asked for the new code.') 'Set the code' ({
        Invoke-Wrangler @('secret', 'put', 'ACCESS_CODE') $code (
            'Access code set. It is live at the edge now - every previous code stopped working.')
    }.GetNewClosure())
}

$script:WranglerWatch  = $null   # the run in flight, or $null. Only ever one.
$script:WranglerOk     = ''      # what to say if it succeeds - the caller knows, the poller does not
$script:WranglerSaidIn = $false  # the sign-in notice is shown once, not every 500ms

function Invoke-Wrangler([string[]]$WranglerArgs, [string]$StdIn, [string]$OkText) {
    if ($script:WranglerWatch) {
        Show-Notice 'Already talking to Cloudflare' (
            'One edge command is already running. Wait for it to finish, or press Stop.')
        return
    }
    # The push bar is the surface this borrows, so it cannot be borrowed while a push owns it.
    if ($script:PushJob -or $script:PublishProc) {
        Show-Notice 'Busy' 'Wait for the current upload or publish to finish first.'
        return
    }
    $script:WranglerOk     = $OkText
    $script:WranglerSaidIn = $false
    try {
        $script:WranglerWatch = Start-WranglerWatched -Arguments $WranglerArgs `
            -WorkingDirectory (Join-Path $script:RepoRoot 'cloudflare') -StdIn $StdIn
    } catch {
        # Resolve-Wrangler throws here when neither wrangler nor npx exists, and its message
        # already says what to install - so it is repeated rather than replaced.
        $script:WranglerWatch = $null
        Set-StatusText "Could not run wrangler: $($_.Exception.Message)" '#FFF87171'
        Show-Notice 'wrangler could not be started' $_.Exception.Message
        return
    }
    # Indeterminate on purpose: wrangler reports no percentage, and a bar sitting at 0% is the
    # exact thing that reads as frozen. Reset in Stop-PushUi, because the push bar next door
    # does report real progress and must not inherit this.
    $PushProgressBar.IsIndeterminate = $true
    $PushBar.Visibility = 'Visible'
    $BtnPush.IsEnabled = $false
    $BtnPushCancel.IsEnabled = $true
    $TxtPushApp.Text = "Cloudflare - wrangler $($WranglerArgs -join ' ')"
    $TxtPushDetail.Text = 'Starting wrangler...'
    Show-Busy 'Talking to Cloudflare...'
    $script:PushTimer.Start()
}

<#
    One poll of the wrangler run, from the push timer. Ends it, whatever way it ended.

    The elapsed seconds are shown even when wrangler has said nothing, because "nothing yet" and
    "stuck" are indistinguishable without them, and a cold npx cache legitimately says nothing
    for the better part of a minute.
#>
function Complete-WranglerCall {
    $w = $script:WranglerWatch
    if (-not $w) { return }
    $new = Update-WranglerWatched $w
    if ($new) {
        $line = Get-WatchedLine $w
        if ($line) { $TxtPushDetail.Text = $line }
    }

    # The one thing the console window was genuinely for. wrangler prints the URL and then waits;
    # hidden, that is a silent hang, so it is repeated here where it can actually be read.
    if ($w.NeedsSignIn -and -not $script:WranglerSaidIn) {
        $script:WranglerSaidIn = $true
        $where = $(if ($w.SignInUrl) { "Open this to sign in:`r`n`r`n$($w.SignInUrl)" }
                   else { 'Run "npx wrangler whoami" in the cloudflare folder and sign in.' })
        Show-Notice 'Cloudflare needs you to sign in' (
            "wrangler is waiting for a Cloudflare sign-in before it will change anything.`r`n`r`n" +
            "$where`r`n`r`n" +
            'This window keeps working - it will carry on by itself once the sign-in is done, ' +
            'or press Stop to abandon it. Nothing at the edge has changed yet.')
        Show-Warn 'Waiting for a Cloudflare sign-in.'
    }

    if ($w.Verdict -eq 'running') {
        $secs = [int]((Get-Date) - $w.Started).TotalSeconds
        $TxtPushApp.Text = "Cloudflare - wrangler $($w.Command)   -   ${secs}s"
        return
    }

    $script:WranglerWatch = $null
    Stop-PushUi
    $tail = Get-WatchedLine $w
    switch ($w.Verdict) {
        'ok' {
            Set-StatusText $script:WranglerOk '#FF34D399'
            return
        }
        'cancelled' {
            # Honest about the one thing that cannot be known: the secret may already have been
            # accepted before the kill landed.
            Set-StatusText 'Stopped. The edge may or may not have been changed - check with "wrangler secret list".' '#FFFBBF24'
            return
        }
        'stalled' {
            Set-StatusText 'wrangler stopped responding - nothing at the edge was changed.' '#FFF87171'
            Show-Notice 'wrangler stopped responding' (
                "It ran for $([int](($w.LastOutput - $w.Started)).TotalSeconds)s, then said nothing " +
                "for $($w.StallSec) seconds and was stopped.`r`n`r`n" +
                "The usual cause is a Cloudflare sign-in it could not ask for.`r`n`r`n" +
                "Last thing it said: $(if ($tail) { $tail } else { '(nothing)' })")
            return
        }
        'timeout' {
            Set-StatusText 'wrangler ran out of time - nothing at the edge was changed.' '#FFF87171'
            Show-Notice 'wrangler ran out of time' (
                "It was still running after $($w.TimeoutSec) seconds and was stopped.`r`n`r`n" +
                "Last thing it said: $(if ($tail) { $tail } else { '(nothing)' })")
            return
        }
    }

    # failed. The exit code is reported as unknown when it is unknown, rather than as 0.
    $code = $(if ($w.ExitCode -is [int]) { $w.ExitCode } else { 'unknown' })
    Set-StatusText "wrangler exited $code - the code was NOT changed." '#FFF87171'
    Show-Notice 'wrangler did not finish' (
        "It exited with code $code. Nothing at the edge was changed.`r`n`r`n" +
        "What it said:`r`n$(if ($tail) { $tail } else { '(nothing)' })`r`n`r`n" +
        'The usual cause is a Cloudflare sign-in that has expired - run ' +
        '"npx wrangler whoami" in the cloudflare folder and sign in, then try again.')
}

function Show-CredentialPrompt([scriptblock]$OnSaved) {
    $TxtOverlayTitle.Text = 'R2 credentials needed'
    $TxtOverlayBody.Text  = (
        'Publishing uploads installers straight to R2 over the S3 API. wrangler cannot do this ' +
        "- its object put stops at about 300 MB, and the largest package here is 15 GB.`r`n`r`n" +
        'Cloudflare dashboard -> R2 -> Manage R2 API Tokens -> Create, with Object Read & Write ' +
        "on this bucket.`r`n`r`n" +
        'Stored encrypted for this Windows account on this machine only, never in the repository.')
    $acct = ''
    try { $acct = Get-WranglerAccountId -RepoRoot $script:RepoRoot } catch { }
    $TxtR2Account.Text = $acct
    $TxtR2Key.Text     = ''
    $PwdR2Secret.Password = ''
    Hide-OverlayBodies
    $OverlayInput.Visibility     = 'Visible'
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = 'Save and continue'
    $script:ConfirmAction = $OnSaved
    $Overlay.Visibility = 'Visible'
}

# ---------------------------------------------------------------- what is actually live
#
# "Did that reach the clients?" was being answered by reading a log, or by running a PowerShell
# one-liner, and twice in one afternoon the answer was a surprise - once because a save
# overwrote a newer catalog, once because the sidecar dragged an entry back to its old file.
# Neither was visible on screen. This makes it visible: fetch what the edge serves and compare
# it, per app, against what is in front of you.
#
# Read-only and advisory. It never blocks a button, and a machine with no network shows nothing
# rather than claiming everything is unpublished.
$script:LiveApps   = $null      # $null = not known yet. A hashtable id -> @{ sha; url } once known.
$script:LiveError  = ''
$script:LiveJob    = $null
$script:LiveHandle = $null

$script:LiveWork = {
    param($Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $r = Invoke-RestMethod -Uri $Url -TimeoutSec 20
        $m = @{}
        foreach ($a in @($r.apps)) {
            $id = [string]$a.id
            if (-not $id) { continue }
            # The WHOLE entry, not a summary of it. Comparing only the hash and the url reported
            # "live" after a post-install step was deleted - the file had not changed, so nothing
            # it looked at had - while the clients would plainly have got something different.
            # Whatever the edge is serving is what has to be compared.
            $m[$id] = $a
        }
        return @{ ok = $true; apps = $m }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

<#
    Is every finished app in this catalog now being served, exactly as it is here?

    This is the question a publish is really asking, and it is answerable without knowing
    anything at all about the process that did the publishing. An app with no real hash is
    skipped because the edge deliberately drops it - it can never match, and waiting for it to
    would mean a half-finished catalog could never report success.

    Returns $false while the live catalog is not known yet: unknown is not the same as no.
#>
function Test-CatalogIsLive {
    if ($null -eq $script:LiveApps) { return $false }
    $checked = 0
    foreach ($a in @($script:Catalog.apps)) {
        if (-not (Test-RealHash ([string](Get-Field $a 'sha256')))) { continue }
        $id = [string](Get-Field $a 'id')
        if (-not $id -or -not $script:LiveApps.ContainsKey($id)) { return $false }
        if ((Get-AppFingerprint $a) -ne (Get-AppFingerprint $script:LiveApps[$id])) { return $false }
        $checked++
    }
    # nothing servable at all is not a published catalog; it is an empty one
    return ($checked -gt 0)
}

function Start-LiveCheck {
    if ($script:LiveJob) { return }
    $script:LiveJob = [powershell]::Create()
    [void]$script:LiveJob.AddScript($script:LiveWork).AddArgument("$($BaseUrl.TrimEnd('/'))/apps.json")
    $script:LiveHandle = $script:LiveJob.BeginInvoke()
}

function Complete-LiveCheck {
    $r = $null
    try { $r = $script:LiveJob.EndInvoke($script:LiveHandle) | Select-Object -Last 1 }
    catch { $r = @{ ok = $false; error = $_.Exception.Message } }
    try { $script:LiveJob.Dispose() } catch { }
    $script:LiveJob = $null; $script:LiveHandle = $null
    if ($r -and $r.ok) {
        $script:LiveApps  = $r.apps
        $script:LiveError = ''
        # A publish is finished when the EDGE says so, not when a process handle does.
        #
        # Completion used to be inferred from Process.HasExited, and that is a proxy: if it never
        # came back true - for any reason at all - the window sat at 0% for ever with no second
        # opinion, while the catalog had in fact gone live minutes earlier. Watching the outcome
        # instead makes the report true by construction, and it cannot hang waiting on a signal,
        # because the thing being asked is the thing that actually matters.
        if ($script:PublishProc -and (Test-CatalogIsLive)) {
            $script:PublishProc = $null
            $script:PublishStarted = $null
            Stop-PushUi
            try { $window.TaskbarItemInfo.ProgressState = 'None' } catch { }
            Set-StatusText 'Published. The edge is now serving this catalog.' '#FF34D399'
        }
    } else {
        # Unknown is NOT "nothing is live". Saying so would send somebody re-uploading 60 GB
        # because the network was down for a moment.
        $script:LiveApps  = $null
        $script:LiveError = [string]$r.error
    }
    Update-List
}

<#
    Every field of an app, flattened into one comparable string.

    Property ORDER is not meaning: the same entry serialised twice can list its keys differently,
    and comparing raw JSON would call that a change. Keys are sorted at every level; arrays keep
    their order, because in `postInstall` the order IS the behaviour; and two values differing
    only in how a number was written compare equal, because everything ends up a string.
#>
function ConvertTo-CanonicalText($o) {
    if ($null -eq $o) { return '~' }
    if ($o -is [string]) { return [string]$o }
    if ($o -is [Management.Automation.PSCustomObject] -or $o -is [hashtable]) {
        $names = $(if ($o -is [hashtable]) { @($o.Keys) } else { @($o.PSObject.Properties.Name) })
        $parts = @()
        # $key, not $n: Test-AfterInstallList finds the dialog's control list by looking for
        # "foreach ($n in ...)" in this file, and this function sits ABOVE the dialog - so a loop
        # named $n here is the one its regex finds first.
        foreach ($key in @($names | Sort-Object)) {
            # written by the editor, deleted from every published catalog - it describes THIS
            # machine, so it can never be part of what the edge is serving
            if ($key -eq '_localFile') { continue }
            $v = $(if ($o -is [hashtable]) { $o[$key] } else { $o.$key })
            $parts += ("$key=" + (ConvertTo-CanonicalText $v))
        }
        return '{' + ($parts -join ';') + '}'
    }
    if ($o -is [Collections.IEnumerable]) {
        return '[' + ((@($o) | ForEach-Object { ConvertTo-CanonicalText $_ }) -join ',') + ']'
    }
    return [string]$o
}

<#
    What the edge would be serving for this app, as one string.

    The url is normalised first: the Worker replaces every /files/ url with a signed, expiring
    one, so the query differs on every single fetch and the path comes back percent-encoded. The
    decoded path is the only part of it that means anything here.
#>
function Get-AppFingerprint($a) {
    if ($null -eq $a) { return '' }
    # round-tripped rather than mutated: this must never touch the catalog it is describing
    $c = ($a | ConvertTo-Json -Depth 12 -Compress) | ConvertFrom-Json
    # Assigning a property that does not exist THROWS on a PSCustomObject - an entry with a
    # real hash but no url key took Update-List down with it. Guard, like Get-Field does.
    if ($c.PSObject.Properties['url']) {
        $u = ([string]$c.url -split '\?')[0]
        try { $u = [Uri]::UnescapeDataString($u) } catch { }
        $c.url = $u
    }
    # The edge signs NESTED urls too - postInstall steps and cleanup removers - and exp/sig
    # change on every fetch. Left un-stripped, such an app compares "not published" forever.
    foreach ($st in @($(if ($c.PSObject.Properties['postInstall']) { $c.postInstall }))) {
        if ($st -and $st.PSObject.Properties['url'] -and $st.url) {
            $su = ([string]$st.url -split '\?')[0]
            try { $su = [Uri]::UnescapeDataString($su) } catch { }
            $st.url = $su
        }
    }
    if ($c.PSObject.Properties['cleanup'] -and $c.cleanup -and $c.cleanup.PSObject.Properties['removers']) {
        foreach ($rm in @($c.cleanup.removers)) {
            if ($rm -and $rm.PSObject.Properties['url'] -and $rm.url) {
                $ru = ([string]$rm.url -split '\?')[0]
                try { $ru = [Uri]::UnescapeDataString($ru) } catch { }
                $rm.url = $ru
            }
        }
    }
    return ConvertTo-CanonicalText $c
}

<#
    How this app compares with what the edge is serving.

    Returns a short label and the colour to print it in. The sha256 is the thing compared: it is
    what the client verifies its download against, so two entries agreeing on it are the same app
    whatever else has been edited. The url is compared too - a file renamed but never re-uploaded
    keeps its hash, and would otherwise read as live while pointing at nothing.
#>
function Get-LiveState($a) {
    $none = @{ Text = ''; Tip = ''; Colour = '#00000000' }
    if ($null -eq $script:LiveApps) { return $none }
    $sha = ([string](Get-Field $a 'sha256')).ToUpper()
    # The edge drops anything without a real hash, so an unfinished app is not "missing from
    # live" - it is deliberately not served yet, which the Detail column already says.
    if (-not (Test-RealHash $sha)) { return $none }
    $id = [string](Get-Field $a 'id')
    if (-not $id -or -not $script:LiveApps.ContainsKey($id)) {
        return @{ Text = 'not live'; Colour = '#FFFBBF24'
                  Tip = 'Finished here, but the edge has never served it. Update publishes it.' }
    }
    $liveOne = $script:LiveApps[$id]
    if ((Get-AppFingerprint $a) -eq (Get-AppFingerprint $liveOne)) {
        return @{ Text = 'live'; Colour = '#FF34D399'
                  Tip = 'Every field matches what the edge is serving right now.' }
    }
    # Something differs. WHICH something decides what pressing Update will actually do, so it is
    # worth the two extra comparisons: a different file means bytes go up, anything else means
    # only the catalog is republished.
    if (([string]$liveOne.sha256).ToUpper() -ne $sha) {
        return @{ Text = 'not uploaded'; Colour = '#FFFBBF24'
                  Tip = 'A different file from the one in the bucket. Update uploads it, then publishes.' }
    }
    $myUrl   = ([string](Get-Field $a 'url') -split '\?')[0]
    $liveUrl = ([string]$liveOne.url -split '\?')[0]
    try { $myUrl = [Uri]::UnescapeDataString($myUrl); $liveUrl = [Uri]::UnescapeDataString($liveUrl) } catch { }
    if ($myUrl -ne $liveUrl) {
        return @{ Text = 'not published'; Colour = '#FFFBBF24'
                  Tip = "The download URL differs from the live one.`nLive: $liveUrl" }
    }
    return @{ Text = 'not published'; Colour = '#FFFBBF24'
              Tip = ('The file is the same, but something else changed - switches, verify path, ' +
                     'after-install steps, name. Update republishes the catalog; nothing uploads.') }
}

# Which category the rail is showing. Empty string means "All applications" - deliberately not
# $null, so it can be compared and written without a null check at every use.
$script:SelectedCategory = ''
$script:SuspendCatSelect = $false
# True only while Update-List is swapping ItemsSource. Rebuilding the list fires a selection
# change with NOTHING selected, and treating that as "the user deselected" is what shut the
# drawer every time an edit refreshed the cards - including choosing an icon.
$script:RebuildingList = $false

# ---------------------------------------------------------------- icon slots
#
# Three states, and the empty one is deliberately the loudest thing about a row: a dashed slot
# reads as "not done yet", where a blank square reads as artwork that failed to load. The
# client draws the same three - a real image if it has one, the letter mark if not, and its
# glyph tile underneath that - so what you arrange here is what a technician sees.


# A card's row is a CLASS, not a [pscustomobject], and that is load-bearing.
#
# WPF cannot pull a BitmapImage back out of PowerShell's object adapter - bound from a
# pscustomobject the Source came through null and the tile drew empty, frozen or not. Binding the
# file PATH instead worked, but then WPF opens the file itself and keeps the handle: picking a new
# icon for an app that already had one died with "the file is being used by another process". A
# real CLR type carries the loaded bitmap across, so the image is read here, ONCE, with OnLoad -
# nothing stays open and the next Pick a PNG can overwrite it.
#
# Every property is [string] or [object] on purpose: this file is parsed before Add-Type has run,
# so naming a WPF type here would fail to resolve.
class AppRow {
    [object]$App
    [string]$SlotVis
    [string]$LetterVis
    [string]$ImageVis
    [string]$IconText
    [string]$IconBg
    [string]$IconPath
    [object]$IconImage
    [string]$Name
    [string]$Detail
    [string]$Colour
    [string]$Live
    [string]$LiveColour
    [string]$LiveTip
}

$script:IconDir = Join-Path $script:RepoRoot 'icons'

# Derived, never stored: an icon is simply icons\<id>.png if that file is there. Keeping it out
# of the catalog means nothing to strip on save and nothing to go stale.
# Renaming an app's id has to take its icon with it: an icon is found as icons\<id>.png, so
# leaving the file under the old name silently blanks the tile of an app that has one.
#
# A FUNCTION, not a few lines inside the drawer's apply handler. That handler is a closure, and a
# closure in this file captures $script: by value - $script:IconDir read as $null there, which is
# how the first version of this threw on Join-Path and then quietly moved nothing.
<#
    Move an app's icon to follow its id, and SAY WHICH of the four things happened.

    This used to answer $true or $false, and the caller discarded the answer - which meant three
    completely different outcomes were indistinguishable and all of them silent:

      nothing  - the app never had an icon. Correct, and not worth a word.
      occupied - a file already sits on the new name. The app now shows artwork that belongs to
                 something else, and its own is orphaned under the old id.
      failed   - the move threw. The app's tile goes blank.

    Only the first of those is fine, so they can no longer share a return value.
#>
function Move-AppIcon([string]$OldId, [string]$NewId) {
    if (-not $OldId -or -not $NewId -or $OldId -eq $NewId) { return 'nothing' }
    if (-not $script:IconDir) { return 'nothing' }
    $old = Join-Path $script:IconDir "$OldId.png"
    $new = Join-Path $script:IconDir "$NewId.png"
    if (-not (Test-Path -LiteralPath $old)) { return 'nothing' }
    if (Test-Path -LiteralPath $new) { return 'occupied' }
    try { Move-Item -LiteralPath $old -Destination $new -Force; return 'moved' } catch { return 'failed' }
}

<#
    Icon renames, deferred to the save.

    The id is rewritten on every keystroke, so typing "civil-3d" used to walk the PNG through
    c.png, ci.png, civ.png ... eight real file renames for one rename, each of which could
    collide with a name that happens to be taken - and the failure was silent. Recording where
    the icon STARTED and moving it once, when the catalog is written, makes the number of renames
    one per rename no matter how fast or slow anybody types.

    Keyed by object identity, and the first value recorded wins: that is the id the file is
    actually sitting under on disk.
#>
$script:PendingIconFrom = @{}

function Request-IconMove($App, [string]$FromId) {
    # Self-initialising because the test harnesses lift this function out by AST and run it
    # without the top-level assignment above - and ContainsKey on $null throws.
    if ($null -eq $script:PendingIconFrom) { $script:PendingIconFrom = @{} }
    if (-not $App -or -not $FromId) { return }
    $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($App)
    if ($script:PendingIconFrom.ContainsKey($key)) { return }
    $script:PendingIconFrom[$key] = @{ App = $App; From = $FromId }
}

function Complete-IconMoves {
    if (-not $script:PendingIconFrom.Count) { return }
    $pending = $script:PendingIconFrom
    # Cleared FIRST. A move that fails is reported and then let go of - retrying it on every
    # subsequent save would re-report the same failure for the rest of the session.
    $script:PendingIconFrom = @{}
    foreach ($entry in $pending.Values) {
        $app = $entry.App
        # Removed from the catalog while the rename was pending - Remove-App has already dealt
        # with its icon, and moving one now would resurrect it.
        if (-not (@($script:Catalog.apps) -contains $app)) { continue }
        $to = [string](Get-Field $app 'id')
        switch (Move-AppIcon $entry.From $to) {
            'occupied' { Show-Warn "Kept the existing icons\$to.png - $($entry.From).png is still there under its old name." }
            'failed'   { Show-Warn "Could not rename icons\$($entry.From).png to $to.png - that app has no icon until it is set again." }
        }
    }
}

function Get-IconFileFor($App) {
    $id = [string](Get-Field $App 'id')
    if (-not $id -or -not $script:IconDir) { return '' }
    $f = Join-Path $script:IconDir "$id.png"
    if (Test-Path -LiteralPath $f) { return $f }
    return ''
}

$script:IconCache = @{}
function Get-IconView($App) {
    $bg = [string](Get-Field $App 'iconColor')
    if (-not $bg) { $bg = '#FF3A3A44' }
    $file = Get-IconFileFor $App
    if ($file) {
        # Read now and read WHOLE - OnLoad, then frozen. Handing WPF the path instead let it hold
        # the file open, and re-picking an icon then failed because the converter could not write
        # over it. See the AppRow class for why the bitmap can be carried at all.
        try {
            # Decoded ONCE per file version, not once per row per refresh. A frozen BitmapImage
            # is shareable across rows and across rebuilds, and the key carries the file's write
            # time - so picking a new icon or renaming one MISSES naturally and there is no
            # invalidation to forget. IgnoreImageCache below defeats WPF's own cache on purpose
            # (it is what let a re-picked icon actually change), which is exactly why this cache
            # has to exist here instead.
            $ck = ''
            try { $ck = "$file|" + (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks } catch { $ck = '' }
            if ($ck -and $script:IconCache.ContainsKey($ck)) {
                return @{ SlotVis = 'Collapsed'; LetterVis = 'Collapsed'; ImageVis = 'Visible'
                          IconText = ''; IconBg = $bg; IconImage = $script:IconCache[$ck]; IconPath = [string]$file }
            }
            $bi = New-Object Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.CacheOption  = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            $bi.UriSource    = [Uri]$file
            $bi.EndInit()
            $bi.Freeze()
            if ($ck) { $script:IconCache[$ck] = $bi }
            return @{ SlotVis = 'Collapsed'; LetterVis = 'Collapsed'; ImageVis = 'Visible'
                      IconText = ''; IconBg = $bg; IconImage = $bi; IconPath = [string]$file }
        } catch { }
    }
    $txt = [string](Get-Field $App 'iconText')
    if ($txt) {
        return @{ SlotVis = 'Collapsed'; LetterVis = 'Visible'; ImageVis = 'Collapsed'
                  IconText = $txt; IconBg = $bg; IconImage = $null; IconPath = '' }
    }
    return @{ SlotVis = 'Visible'; LetterVis = 'Collapsed'; ImageVis = 'Collapsed'
              IconText = ''; IconBg = $bg; IconImage = $null; IconPath = '' }
}
# The rail's rows, rebuilt from the catalog rather than edited in place, for the same reason
# the app list is: a count maintained by hand drifts from the thing it counts.
function Update-Categories {
    if (-not $ListCats) { return }
    $want = [string]$script:SelectedCategory
    $rows = @()
    $rows += [pscustomobject]@{
        Name = 'All applications'; Count = @($script:Catalog.apps).Count; IsAll = $true
        GripVis = 'Collapsed' }
    foreach ($n in @(Get-CategoryNames)) {
        $rows += [pscustomobject]@{ Name = $n; Count = @(Get-AppsInCategory $n).Count
                                    IsAll = $false; GripVis = 'Visible' }
    }
    # Rebuilding the source fires SelectionChanged on the way past, which would re-enter
    # Update-List mid-rebuild and fight over the selection.
    $script:SuspendCatSelect = $true
    $ListCats.ItemsSource = $rows
    # Selection is restored BY NAME, never by index: renaming or reordering moves the row, and
    # an index would silently select whatever slid into that slot instead.
    $keep = @($rows | Where-Object { -not $_.IsAll -and $_.Name -eq $want })
    if ($keep.Count) { $ListCats.SelectedItem = $keep[0] } else { $ListCats.SelectedIndex = 0 }
    $script:SuspendCatSelect = $false
}

# ---------------------------------------------------------------- refresh cost
#
# Update-List asked the same expensive questions about the same apps three times over, and it
# ran on every keystroke. Per app it called Test-App twice (each an O(n) duplicate-id scan),
# Get-LiveState three times (each doing TWO whole-object ConvertTo-Json/ConvertFrom-Json
# round-trips), and decoded the app's PNG from disk. On a 19-app catalog, typing one word cost
# roughly 1,700 JSON round-trips and 285 image decodes. That is the freeze.
#
# Two changes fix it without restructuring anything. This memo makes the answers cost once per
# refresh instead of two or three times, and it is keyed on REFERENCE identity - not on id,
# because the id is rewritten on a keystroke by the drawer and duplicates exist by design.
# Cleared at the top of every refresh, so it can never serve a stale answer.
$script:RefreshMemo = @{}
function Get-MemoKey($o) { return [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o) }
function Get-AppProblems($a) {
    $k = 'p' + (Get-MemoKey $a)
    if (-not $script:RefreshMemo.ContainsKey($k)) { $script:RefreshMemo[$k] = @(Test-App $a) }
    return $script:RefreshMemo[$k]
}
function Get-AppLive($a) {
    $k = 'l' + (Get-MemoKey $a)
    if (-not $script:RefreshMemo.ContainsKey($k)) { $script:RefreshMemo[$k] = Get-LiveState $a }
    return $script:RefreshMemo[$k]
}

# And the refresh itself is debounced, so a burst of typing costs ONE rebuild rather than one
# per character. Same shape as AppDeploy.ps1's 220ms search debounce. Callers that read
# $ListApps.Items on the very next line must keep calling Update-List directly - a deferred
# rebuild would break their selection restore.
$script:ListTimer = New-Object Windows.Threading.DispatcherTimer
$script:ListTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:ListTimer.Add_Tick({ $script:ListTimer.Stop(); Invoke-Guarded { Update-Categories; Update-List } 'Refresh list' -Quiet })
function Request-ListRefresh { $script:ListTimer.Stop(); $script:ListTimer.Start() }

function Update-List {
    $script:RefreshMemo = @{}
    $sel = $ListApps.SelectedIndex
    # Identity, not position: a rebuild that drops or reorders rows must give the SAME app
    # back, or the drawer is silently swapped onto a different application mid-keystroke -
    # the exact fix Update-Categories already carries, never carried here.
    $selApp = $null
    if ($ListApps.SelectedItem -and $ListApps.SelectedItem.App) { $selApp = $ListApps.SelectedItem.App }
    $cat = [string]$script:SelectedCategory
    $shown = @($script:Catalog.apps)
    if ($cat) { $shown = @(Get-AppsInCategory $cat) }
    # Search reaches across the whole catalog, not just the open category: "where is Photoshop
    # filed" is the question being asked, and answering it only within the folder you already
    # have open answers nothing.
    $q = [string]$script:SearchText
    if ($q) {
        $shown = @($script:Catalog.apps | Where-Object {
            ([string](Get-Field $_ 'name')) -like "*$q*" -or ([string](Get-Field $_ 'id')) -like "*$q*" })
    }
    $rows = @($shown | ForEach-Object {
        $p = Get-AppProblems $_
        # an app still queued for hashing is not "missing a hash" - it is mid-flight, and
        # listing it as a problem reads like something went wrong
        $busy = ''
        $bad  = $false
        if ($script:BulkCurrent -eq $_) { $busy = 'hashing...' }
        elseif (@($script:BulkQueue) -contains $_) { $busy = 'waiting to hash' }
        elseif ($script:PushProgress) {
            # Same idea as 'hashing...': an app mid-upload is not "missing something", it is
            # in flight, and listing it as a problem reads like something went wrong.
            $thisId = [string](Get-Field $_ 'id')
            $fail = @($script:PushProgress.Failed | Where-Object { [string]$_.id -eq $thisId })
            if ($fail.Count) { $busy = "upload failed - $($fail[0].reason)"; $bad = $true }
            elseif ($script:PushProgress.AppId -eq $thisId -and $thisId) {
                $pct = 0
                if ([long]$script:PushProgress.AppTotal -gt 0) {
                    $pct = [int](100.0 * [long]$script:PushProgress.AppBytes / [long]$script:PushProgress.AppTotal)
                }
                $busy = "uploading $pct%"
            }
            elseif (@($script:PushProgress.Skipped | Where-Object { [string]$_.id -eq $thisId }).Count) { $busy = 'already in R2' }
            elseif (@($script:PushProgress.Done    | Where-Object { [string]$_.id -eq $thisId }).Count) { $busy = 'uploaded' }
        }
        $ls = Get-AppLive $_
        $iv = Get-IconView $_
        [AppRow]@{
            App    = $_
            SlotVis = $iv.SlotVis; LetterVis = $iv.LetterVis; ImageVis = $iv.ImageVis
            IconText = $iv.IconText; IconBg = $iv.IconBg
            IconPath = $iv.IconPath; IconImage = $iv.IconImage
            Name   = [string](Get-Field $_ 'name')
            # Size ALWAYS leads, and the chip beside it carries the one thing that is wrong -
            # or, when nothing is, whether the edge has it. The two used to fight for the same
            # line, so a 14 GB package that was merely unhashed lost its size off the row.
            Detail = [string](Format-Size ([long](Get-Field $_ 'sizeBytes')))
            Colour = '#FF6E6E7A'
            Live       = $(if ($busy) { $busy } elseif (@($p).Count) { [string]@($p)[0] } else { [string]$ls.Text })
            LiveColour = $(if ($bad) { '#FFF87171' } elseif ($busy) { '#FF4C8DFF' }
                           elseif (@($p).Count) { '#FFFBBF24' } else { [string]$ls.Colour })
            LiveTip    = $(if (@($p).Count) { ($p -join ', ') } else { [string]$ls.Tip })
        }
    })
    $script:RebuildingList = $true
    try {
        $ListApps.ItemsSource = $rows
        $restored = $false
        if ($selApp) {
            for ($ri = 0; $ri -lt $rows.Count; $ri++) {
                if ($rows[$ri].App -eq $selApp) { $ListApps.SelectedIndex = $ri; $restored = $true; break }
            }
        }
        if (-not $restored) {
            if ($sel -ge 0 -and $sel -lt $rows.Count) { $ListApps.SelectedIndex = $sel }
            elseif ($rows.Count) { $ListApps.SelectedIndex = 0 }
        }
    } finally { $script:RebuildingList = $false }
    # The header names what is on screen. The status line underneath still speaks for the WHOLE
    # catalog: publishing is a catalog-wide act, and a filtered count sitting next to "ready to
    # publish" would report two apps ready while nineteen go up.
    $all = @($script:Catalog.apps)
    if ($TxtGroupTitle) {
        $TxtGroupTitle.Text = $(if ($q) { "Search: $q" } elseif ($cat) { $cat } else { 'All applications' })
        $bytes = 0L
        foreach ($a in $shown) { $bytes += [long](Get-Field $a 'sizeBytes') }
        $liveHere = 0
        foreach ($a in $shown) { $l = Get-AppLive $a; if ([string]$l.Text -eq 'live') { $liveHere++ } }
        $liveWord = $(if (-not $rows.Count) { 'nothing here yet' }
                      elseif ($liveHere -eq 0) { 'none live yet' }
                      elseif ($liveHere -eq $rows.Count) { 'all live' }
                      else { "$liveHere live" })
        $TxtGroupMeta.Text = "$($rows.Count) app$(if ($rows.Count -ne 1) { 's' })  -  $(Format-Size $bytes)  -  $liveWord"
        $GhostAdd.Content = $(if ($cat) { "+  Add application to $cat" } else { '+  Add application' })
        $GhostAdd.Visibility = $(if ($q) { 'Collapsed' } else { 'Visible' })
    }
    $ready = @($all | Where-Object { -not (Get-AppProblems $_).Count }).Count
    $behind = 0
    foreach ($a in $all) {
        $ls = Get-AppLive $a
        if ($ls.Text -and $ls.Text -ne 'live') { $behind++ }
    }
    $tail = ''
    if ($null -eq $script:LiveApps) {
        # Only worth a word if the check actually FAILED; while it is still in flight, silence.
        if ($script:LiveError) { $tail = ' - could not read what is live' }
    } elseif ($behind -gt 0) {
        $tail = ", $behind not yet live"
    } else {
        $tail = ' - everything ready is live'
    }
    # The SUMMARY slot, never the activity slot. This line ran on every keystroke and was
    # wiping every confirmation the user had just been given - see Show-Activity's comment.
    Set-CatalogSummary "$($all.Count) app(s), $ready ready to publish$tail"
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
    # A rooted path starting PART WAY THROUGH the string can only be the whole destination: it
    # is what happens when a real folder is typed into a box already holding a guess. That put
    # %ProgramFiles%\C:\Program Files\SketchUp\SketchUp 2026\LayOut\ into a saved catalog, which
    # expands to C:\Program Files\C:\Program Files\... - a path no machine has, and one that is
    # only discovered on a client after the whole install has run. Keep the last root and drop
    # whatever was in front of it.
    $root = [regex]::Match($d, '(?:[A-Za-z]:\\|\\\\)[^\\/]',
                           [Text.RegularExpressions.RegexOptions]::RightToLeft)
    if ($root.Success -and $root.Index -gt 0) { $d = $d.Substring($root.Index) }
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
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="Transparent"
        TextElement.FontFamily="Segoe UI Variable Text, Segoe UI"
        TextElement.FontSize="13" TextElement.Foreground="#FFE9E9EE">
  <!--
    The drawer's contents, and what used to be a 620x880 pop-up.

    It is still parsed fresh for each application rather than filled in place, and that is
    deliberate: every handler wired below belongs to THIS tree, so selecting another app throws
    the whole thing away and takes its handlers with it. Filling one long-lived panel instead
    would stack another set of handlers on every click.

    There is no Save and no Cancel. The drawer writes straight to the catalog entry, exactly as
    the category dropdown already did, and the window-level "nothing is written until you save"
    is what covers a mistake.
  -->
  <Border.Resources>
    <SolidColorBrush x:Key="Panel"    Color="#FF17171B"/>
    <SolidColorBrush x:Key="Sunken"   Color="#FF101014"/>
    <SolidColorBrush x:Key="Raised"   Color="#FF2A2A31"/>
    <SolidColorBrush x:Key="Line"     Color="#FF3C3C45"/>
    <SolidColorBrush x:Key="LineSoft" Color="#FF26262E"/>
    <SolidColorBrush x:Key="Ink"      Color="#FFE9E9EE"/>
    <SolidColorBrush x:Key="Muted"    Color="#FF9A9AA6"/>
    <SolidColorBrush x:Key="Dim"      Color="#FF6E6E7A"/>
    <SolidColorBrush x:Key="Accent"   Color="#FF2563EB"/>
    <SolidColorBrush x:Key="Lift"     Color="#FF4C8DFF"/>
    <SolidColorBrush x:Key="Bad"      Color="#FFF87171"/>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Raised}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="11,6"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Line}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource LineSoft}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource Dim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- The accent button from AppDeploy.ps1: a top-to-bottom gradient, lifting on hover and
         sinking when pressed. A flat fill beside it read as a different control. -->
    <Style x:Key="Accented" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#FF4C8DFF" Offset="0"/>
                  <GradientStop Color="#FF2563EB" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Lift}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF1A47AC"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Raised}"/>
                <Setter Property="Foreground" Value="{StaticResource Dim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Sunken}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="FontSize" Value="12.3"/>
    </Style>
    <!-- The name is the drawer's title AND the field you rename in. Styled flat it read as a
         printed label, so nobody tried to click it - it looked hardcoded. It now carries a soft
         rule underneath at rest, fills in under the cursor, and becomes an ordinary bordered
         field once focused. -->
    <Style x:Key="TitleBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="3,1"/>
      <Setter Property="Margin" Value="-4,0,0,1"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="ToolTip" Value="The name a technician sees. Click to rename it."/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource Sunken}"/>
          <Setter Property="BorderBrush" Value="{StaticResource Lift}"/>
        </Trigger>
        <Trigger Property="IsFocused" Value="True">
          <Setter Property="Background" Value="{StaticResource Sunken}"/>
          <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
          <Setter Property="BorderThickness" Value="1"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- Templated, because a ComboBox with only setters keeps the SYSTEM template - which is
         white whatever Background is set on it. That is the white field in a dark window. -->
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontSize" Value="12.3"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="{StaticResource Sunken}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="tb" Background="{StaticResource Sunken}" CornerRadius="6"
                            BorderBrush="{StaticResource Line}" BorderThickness="1">
                      <Path Data="M 0,0 L 4,4 L 8,0" Stroke="{StaticResource Muted}" StrokeThickness="1.4"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="tb" Property="BorderBrush" Value="{StaticResource Lift}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="9,0,26,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Margin="6,0,26,0" VerticalAlignment="Center"
                       Background="Transparent" BorderThickness="0" Foreground="{StaticResource Ink}"
                       CaretBrush="{StaticResource Ink}" Visibility="Collapsed"/>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Bottom" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                        BorderThickness="1" CornerRadius="6" MinWidth="{TemplateBinding ActualWidth}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,3,0,0">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ci" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ci" Property="Background" Value="#FF1B2233"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The scrollbar from AppDeploy.ps1. With no style at all the window inherits the system
         one, which is a light grey slab down the side of a dark window. -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#30FFFFFF" CornerRadius="3" Width="6" Margin="1,0"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>
  </Border.Resources>

  <DockPanel LastChildFill="True">

    <!-- header: the name is edited in place rather than in a field further down -->
    <Border DockPanel.Dock="Top" BorderBrush="{StaticResource LineSoft}"
            BorderThickness="0,0,0,1" Padding="14,10">
      <DockPanel LastChildFill="True">
        <Grid x:Name="DlgIconTile" DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,11,0">
          <Border x:Name="DlgIconSlot" CornerRadius="7" Background="#FF23232B"
                  BorderThickness="1" BorderBrush="#FF3E3E49"/>
          <Border x:Name="DlgIconLetter" CornerRadius="7" Background="#FF3A3A44" Visibility="Collapsed">
            <TextBlock x:Name="DlgIconText" FontSize="11" FontWeight="Bold" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>          <Border x:Name="DlgIconImageBox" CornerRadius="7" Background="Transparent"
                  Visibility="Collapsed">
            <Image x:Name="DlgIconImage" Stretch="Uniform"/>
          </Border>
        </Grid>
        <StackPanel VerticalAlignment="Center">
          <!-- The name, and only the name. The id used to sit under it as grey text: not a
               heading, not editable, and derived from whatever the app happened to be called
               when it was first added. It is a field now, further down, where fields live. -->
          <TextBox x:Name="DlgName" Style="{StaticResource TitleBox}"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border DockPanel.Dock="Bottom" BorderBrush="{StaticResource LineSoft}"
            BorderThickness="0,1,0,0" Padding="14,7">
      <TextBlock x:Name="DlgStatus" Foreground="{StaticResource Dim}" FontSize="11"
                 TextWrapping="Wrap"/>
    </Border>

    <ScrollViewer x:Name="DlgScroll" VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled" Padding="14,13,10,13">
      <!-- Two cells. At peek the steps sit UNDER the fields in column 0; opening the drawer
           moves them into column 1, which is the whole reason for opening it. -->
      <Grid x:Name="DlgGrid">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition x:Name="DlgCol2" Width="0"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel x:Name="DlgLeft" Grid.Column="0" Grid.Row="0">
          <TextBlock Text="ID" Style="{StaticResource FieldLabel}"/>
        <TextBox x:Name="DlgId" Margin="0,0,0,12"/>

        <TextBlock Text="CATEGORY" Style="{StaticResource FieldLabel}"/>
          <ComboBox x:Name="DlgCategory" Margin="0,0,0,11"/>

          <TextBlock Text="ICON" Style="{StaticResource FieldLabel}"/>
          <Border Background="{StaticResource Sunken}" BorderBrush="{StaticResource Line}"
                  BorderThickness="1" CornerRadius="6" Padding="9" Margin="0,0,0,11">
            <DockPanel LastChildFill="True">
              <Grid DockPanel.Dock="Left" Width="56" Height="56" Margin="0,0,11,0">
                <Border x:Name="DlgIconSlotBig" CornerRadius="11" Background="#FF23232B"
                        BorderThickness="1" BorderBrush="#FF3E3E49"/>
                <Border x:Name="DlgIconLetterBig" CornerRadius="11" Background="#FF3A3A44"
                        Visibility="Collapsed">
                  <TextBlock x:Name="DlgIconTextBig" FontSize="19" FontWeight="Bold" Foreground="White"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <Border x:Name="DlgIconImageBoxBig" CornerRadius="11" Background="Transparent"
                        Visibility="Collapsed">
                  <Image x:Name="DlgIconImageBig" Stretch="Uniform"/>
                </Border>
              </Grid>
              <Button x:Name="DlgIconPick" DockPanel.Dock="Right" Content="Pick a PNG..."
                      Style="{StaticResource Btn}" Margin="0" VerticalAlignment="Center"/>
              <TextBlock x:Name="DlgIconState" FontSize="11.5" VerticalAlignment="Center"
                         Foreground="{StaticResource Dim}" TextWrapping="Wrap"/>
            </DockPanel>
          </Border>
          <!-- PACKAGE first of the working fields, because it is what you do first: point at
               the file, hash it, and let everything below be read out of it. -->
          <TextBlock Text="DOWNLOAD URL" Style="{StaticResource FieldLabel}"/>
          <TextBox x:Name="DlgUrl" Margin="0,0,0,7"/>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="DlgFetch" Content="Fetch and hash" Style="{StaticResource Accented}"/>
            <Button x:Name="DlgPickLocal" Content="Use a local file..." Style="{StaticResource Btn}"/>
            <ProgressBar x:Name="DlgBusy" Width="60" Height="4" IsIndeterminate="True"
                         Visibility="Collapsed" VerticalAlignment="Center"
                         Foreground="{StaticResource Lift}" Background="{StaticResource Raised}"
                         BorderThickness="0"/>
          </StackPanel>
          <TextBlock x:Name="DlgHashInfo" TextWrapping="Wrap" Margin="0,0,0,12" FontSize="11"/>

          <TextBlock Text="SETUP FILE" Style="{StaticResource FieldLabel}"/>
          <ComboBox x:Name="DlgEntry" IsEditable="True" Margin="0,0,0,10"/>
          <TextBlock Text="SILENT SWITCHES" Style="{StaticResource FieldLabel}"/>
          <TextBox x:Name="DlgSilent" Margin="0,0,0,3"/>
          <TextBlock x:Name="DlgSilentHint" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,10"/>
          <TextBlock Text="VERIFY PATH" Style="{StaticResource FieldLabel}"/>
          <ComboBox x:Name="DlgVerify" IsEditable="True" Margin="0,0,0,3"/>
          <TextBlock x:Name="DlgVerifyHint" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,12"/>
          <TextBlock Text="REQUIRES (app ids, space separated)" Style="{StaticResource FieldLabel}"/>
          <TextBox x:Name="DlgRequires" Margin="0,0,0,12"/>
        </StackPanel>

        <Border x:Name="DlgStepsBox" Grid.Column="0" Grid.Row="1"
                Background="{StaticResource Sunken}" BorderBrush="{StaticResource Line}"
                BorderThickness="1" CornerRadius="7" Padding="11" Margin="0,0,0,4">
          <StackPanel>
            <TextBlock Text="AFTER INSTALLATION" FontWeight="Bold" FontSize="10.5"
                       Foreground="{StaticResource Muted}" Margin="0,0,0,4"/>
            <ListBox x:Name="DlgPostList" Height="104" DisplayMemberPath="Text"
                     Background="#FF17171B" BorderBrush="{StaticResource Line}"
                     Foreground="{StaticResource Ink}" FontFamily="Consolas" FontSize="11"
                     Margin="0,0,0,7"/>
            <UniformGrid Columns="2" Margin="0,0,0,9">
              <Button x:Name="DlgPostAdd"    Content="Add an action" Style="{StaticResource Btn}" Margin="0,0,4,4"/>
              <Button x:Name="DlgPostRemove" Content="Remove"        Style="{StaticResource Btn}" Margin="4,0,0,4"/>
              <Button x:Name="DlgPostUp"     Content="Move up"       Style="{StaticResource Btn}" Margin="0,0,4,0"/>
              <Button x:Name="DlgPostDown"   Content="Move down"     Style="{StaticResource Btn}" Margin="4,0,0,0"/>
            </UniformGrid>
            <Border x:Name="DlgPostEdit" Background="#FF1B1B20" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="6" Padding="9">
              <StackPanel>
                <StackPanel Margin="0,0,0,7">
                  <RadioButton x:Name="DlgPostMove" Content="Move a file in" GroupName="post"
                               Foreground="{StaticResource Ink}" FontSize="12" Margin="0,0,0,3"/>
                  <RadioButton x:Name="DlgPostRun" Content="Run a file" GroupName="post"
                               Foreground="{StaticResource Ink}" FontSize="12" Margin="0,0,0,3"/>
                  <RadioButton x:Name="DlgPostPs" Content="Run a PowerShell command" GroupName="post"
                               Foreground="{StaticResource Ink}" FontSize="12"/>
                </StackPanel>
                <StackPanel x:Name="DlgPostFilePanel">
                  <TextBlock Text="File" Style="{StaticResource Caption}"/>
                  <ComboBox x:Name="DlgPostFrom" IsEditable="True" Margin="0,0,0,8"/>
                  <TextBlock x:Name="DlgPostDestLabel" Style="{StaticResource Caption}"
                             Text="Goes to"/>
                  <ComboBox x:Name="DlgPostDest" IsEditable="True" Margin="0,0,0,6"/>
                </StackPanel>
                <StackPanel x:Name="DlgPostPsPanel" Visibility="Collapsed">
                  <TextBox x:Name="DlgPostCmd" AcceptsReturn="True" TextWrapping="Wrap" Height="66"
                           Margin="0,0,0,6" FontFamily="Consolas" FontSize="11"/>
                </StackPanel>
                <TextBlock x:Name="DlgPostWhere" TextWrapping="Wrap" FontSize="10.5"
                           Foreground="{StaticResource Dim}"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Border>
      </Grid>
    </ScrollViewer>
  </DockPanel>
</Border>
'@

# Returns $true if the dialog was accepted. $App is edited in place, so an existing entry
# keeps every field this dialog knows nothing about.
#
# $LocalFile is where this app's bytes are on THIS machine, or '' if they are not here. The
# CALLER resolves it, because the answer lives in the sidecar and this dialog is lifted out and
# run standalone by two harnesses - the same reason the save writes only the _localFile field.
<#
    Builds the drawer's contents for one application and hands them back; the caller drops
    them into DrawerHost. It is still called Show-AppDialog because that is what it was, and
    what most of this body still is - the pop-up's logic, unchanged, now writing into a docked
    panel instead of a window that had to be dismissed.

    The tree is built FRESH for each application rather than refilled, so every handler wired
    below dies with it when another app is selected. Refilling one long-lived panel would stack
    a second set of handlers on every click.

    There is no Save. Each field applies as it is edited, and $Apply is what does it.
#>
function Show-AppDialog($App, $Owner, [string]$LocalFile = '') {
    $dlg = [Windows.Markup.XamlReader]::Parse($dialogXaml)
    # Every helper below lives in here rather than in a variable of its own. They are closures
    # now - the function returns instead of blocking on ShowDialog, so its frame is gone by the
    # time a button is clicked - and a closure captures by VALUE, which silently gave $null to
    # any helper that referred to one defined further down. One table, captured by reference,
    # and the lookup happens at call time.
    $fn = @{}
    $c = @{}
    # The hashing runspace is handed TEXT, and the text has to be taken here - before any
    # closure exists. Read from inside one, $script:FetchWork converts to an empty string, so
    # the runspace ran nothing, returned nothing, raised nothing, and a fetch silently never
    # produced a hash. Captured as a local it is copied by value into every closure below.
    $fetchText = [string]$script:FetchWork
    foreach ($n in 'DlgName','DlgUrl','DlgFetch','DlgPickLocal','DlgBusy','DlgHashInfo','DlgEntry',
                   'DlgSilent','DlgSilentHint','DlgVerify','DlgVerifyHint','DlgRequires',
                   'DlgPostList','DlgPostAdd','DlgPostRemove','DlgPostUp','DlgPostDown','DlgPostEdit',
                   'DlgPostMove','DlgPostRun','DlgPostPs','DlgPostFilePanel','DlgPostPsPanel','DlgPostCmd',
                   'DlgPostFrom','DlgPostDestLabel','DlgPostDest','DlgPostWhere',
                   'DlgStatus','DlgId','DlgCategory',
                   'DlgIconSlot','DlgIconLetter','DlgIconText','DlgIconImageBox','DlgIconImage',
                   'DlgIconSlotBig','DlgIconLetterBig','DlgIconTextBig','DlgIconImageBoxBig',
                   'DlgIconImageBig','DlgIconPick','DlgIconState',
                   'DlgGrid','DlgCol2','DlgLeft','DlgStepsBox','DlgScroll') {
        $c[$n] = $dlg.FindName($n)
        # a renamed control in the XAML would otherwise surface as a null-property error six
        # handlers away from the cause
        if (-not $c[$n]) { throw "the drawer layout has no control named $n" }
    }

    # computed values, applied to the app as they change
    $state = @{
        sha256 = [string](Get-Field $App 'sha256')
        size   = [long](Get-Field $App 'sizeBytes')
        job    = $null
        handle = $null
        ok     = $false
        rows   = $null
        # Set when "Use a local file..." is used, applied to the sidecar only if the dialog is
        # accepted - picking a file and then cancelling must not repoint the app at it.
        localFile = ''
        # What the dialog itself last put in each box. Fields used to be filled "only when
        # empty", to avoid clobbering something a person typed - but that also meant picking a
        # SECOND file left the first file's name, URL, switches and verify path in place, so
        # the entry ended up labelled Office while carrying AutoCAD's hash. Remembering what we
        # wrote separates "the user chose this" from "we guessed this last time".
        auto   = @{}
        # what the fetch actually found inside the package, so a typed `from` can be checked
        # against it. Empty until a fetch happens, and empty means no opinion.
        files  = @()
        # What the entry was called when it opened, and whether it had ever been hashed. Read
        # together at the end of a fetch: a hashed entry whose name has not changed is the same
        # product's file arriving again, and its curated fields are not the dialog's to replace.
        openName = ''
        settled  = $false
        # A listing job as opposed to a hashing one. Both run through $state.job and both are
        # collected by the same poll, so the poll has to know which it is holding: a listing
        # must not touch the hash, or the size, or any field the dialog proposes.
        listOnly = $false
        # the fields below the list write into the SELECTED row as they are typed, which has to
        # be suspended whenever the code itself puts values in them - loading a row, or a fetch
        # repopulating a combo, which blanks an editable ComboBox's Text as a side effect
        loading = $false
    }

    $c.DlgName.Text    = [string](Get-Field $App 'name')
    $c.DlgUrl.Text     = [string](Get-Field $App 'url')
    $c.DlgSilent.Text  = [string](Get-Field $App 'silentArgs')
    $c.DlgVerify.Text  = [string](@(Get-Field $App 'verifyPaths') | Select-Object -First 1)
    $c.DlgRequires.Text = (@(Get-Field $App 'requires') -join ' ')
    # the combo edits the FIRST verify path; any further ones are curated by hand in the JSON
    # and must survive the drawer untouched - apply merges around them, and this says so
    $vpMore = @(@(Get-Field $App 'verifyPaths')).Count - 1
    if ($vpMore -gt 0) { $c.DlgVerifyHint.Text = "+ $vpMore more verify path(s) kept from the catalog" }
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
    #
    # The silent switch is NOT in here. Nothing derives it any more, so there is nothing to
    # replace - it is whatever a person typed, and it stays that way.
    $state.auto['name']   = Get-BoxText $c.DlgName
    $state.auto['url']    = Get-BoxText $c.DlgUrl
    $state.auto['verify'] = Get-BoxText $c.DlgVerify
    $state.auto['entry']  = Get-BoxText $c.DlgEntry

    # What this entry was when it opened, so a fetch can tell a DIFFERENT PRODUCT from the same
    # product's own file arriving again.
    #
    # The silent switches and the verify path are the only two fields here that cannot be read
    # off a package at any price - one comes from the vendor's documentation or from trying it
    # on a VM, the other from a machine that actually has the product installed. Everything
    # else is a property of the file and should follow the file.
    #
    # Swapping Office for AutoCAD must still carry them, or the entry ends up half describing
    # one product and half another. Re-fetching Office's OWN installer must not: that is what
    # replaced its empty ODT switches with '/S' and its WINWORD.EXE verify path with
    # %ProgramFiles%\OfficeSetup\OfficeSetup.exe, both invented out of the file's name. The
    # difference between those two cases is the NAME, so that is what gets remembered.
    $state.openName = Get-BoxText $c.DlgName
    $state.settled  = Test-RealHash ([string](Get-Field $App 'sha256'))

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

    $fn.syncHash = {
        if (Test-RealHash $state.sha256) {
            $c.DlgHashInfo.Foreground = '#FF9AE6B4'
            $c.DlgHashInfo.Text = "$(Format-Size $state.size)   sha256 $($state.sha256.Substring(0,16))..."
        } else {
            $c.DlgHashInfo.Foreground = '#FFF87171'
            $c.DlgHashInfo.Text = 'Not hashed yet'
        }
    }.GetNewClosure()
    # Says in words what the selected row will do. The destination is offered, not demanded:
    # the app already declares where it lands - the verify path - and the folder holding that
    # file IS the install directory, so it is filled in. It stays editable because a second
    # file often belongs somewhere else entirely, and that is exactly the case a single fixed
    # destination could not express.
    $fn.syncWhere = {
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
            $c.DlgPostWhere.Text = 'Nothing yet'
            return
        }
        if ($isPs) {
            if (-not (Get-BoxText $c.DlgPostCmd)) {
                $c.DlgPostWhere.Foreground = '#FFF87171'
                $c.DlgPostWhere.Text = 'Type the command to run.'
            } else {
                $c.DlgPostWhere.Foreground = '#FFFBBF24'
                $c.DlgPostWhere.Text = 'Runs elevated. Nothing hashes this - the catalog is the only thing vouching for it.'
            }
            return
        }
        if ($row.Kind -notin 'copy', 'run') {
            $c.DlgPostWhere.Foreground = '#FF9A9AA6'
            $c.DlgPostWhere.Text = 'Kept exactly as written.'
            return
        }
        if (-not (Test-InPackage $state.files (Get-BoxText $c.DlgPostFrom))) {
            $c.DlgPostWhere.Foreground = '#FFF87171'
            $c.DlgPostWhere.Text = "There is no such file in the package. It holds $(@($state.files).Count) file(s) - pick one from the list, or this fails on the client with 'source file missing' after the whole install has run."
            return
        }
        if ($c.DlgPostRun.IsChecked) {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = 'Runs from inside the package.'
            return
        }
        $d = Format-PostDest $c.DlgPostDest.Text
        if (-not $d) {
            $c.DlgPostWhere.Foreground = '#FFF87171'
            $c.DlgPostWhere.Text = 'Where the file goes.'
        } elseif ($d.EndsWith('\')) {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = "Moved into $d once the install verifies, keeping its own name."
        } else {
            $c.DlgPostWhere.Foreground = '#FF9AE6B4'
            $c.DlgPostWhere.Text = "Moved to $d once the install verifies - that last part is a filename, so it is renamed on the way."
        }
    }.GetNewClosure()

    # The list IS the editor: the fields below always show the selected row, and typing in them
    # changes that row. There is no "add" mode to be in, and so no half-typed action that was
    # never added - which is precisely how the single-step version used to lose a file-copy.
    $fn.syncPostEditor = {
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
        & ($fn.syncWhere)
    }.GetNewClosure()

    $fn.refreshRows = {
        param([int]$select = -1)
        $state.loading = $true
        try {
            $c.DlgPostList.ItemsSource = $null
            $c.DlgPostList.ItemsSource = @($state.rows)
            if ($select -ge 0 -and $select -lt $state.rows.Count) { $c.DlgPostList.SelectedIndex = $select }
        } finally { $state.loading = $false }
        & ($fn.syncPostEditor)
    }.GetNewClosure()

    # typing edits the selected row as you type, so the list always shows what is actually there
    $fn.applyEdit = {
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
        & ($fn.syncWhere)
    }.GetNewClosure()

    $fn.moveRow = {
        param([int]$delta)
        $i = $c.DlgPostList.SelectedIndex
        $j = $i + $delta
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $state.rows.Count) { return }
        $row = $state.rows[$i]
        $state.rows.RemoveAt($i)
        $state.rows.Insert($j, $row)
        & ($fn.refreshRows) $j
    }.GetNewClosure()

    & ($fn.syncHash)
    & ($fn.refreshRows) $(if ($state.rows.Count) { 0 } else { -1 })

    # an editable ComboBox has no TextChanged of its own - the inner text box raises it
    $c.DlgVerify.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                            [Windows.RoutedEventHandler]$fn.syncWhere)
    $c.DlgPostFrom.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                              [Windows.RoutedEventHandler]$fn.applyEdit)
    $c.DlgPostDest.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                              [Windows.RoutedEventHandler]$fn.applyEdit)
    $c.DlgPostCmd.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
                             [Windows.RoutedEventHandler]$fn.applyEdit)
    foreach ($rb in @($c.DlgPostMove, $c.DlgPostRun, $c.DlgPostPs)) { $rb.Add_Checked($fn.applyEdit) }
    $c.DlgPostList.Add_SelectionChanged({ if (-not $state.loading) { & ($fn.syncPostEditor) } }.GetNewClosure())

    $c.DlgPostAdd.Add_Click({
        # The install folder is what the app already declares - offered, never asked for twice.
        # A real path typed after this one no longer concatenates: Format-PostDest keeps the
        # root that comes LAST, so %ProgramFiles%\C:\Program Files\... cannot reach a catalog.
        $dest = ''
        if ((Get-BoxText $c.DlgVerify)) { $dest = (Split-Path (Get-BoxText $c.DlgVerify) -Parent).TrimEnd('\') + '\' }
        [void]$state.rows.Add((New-PostRow 'copy' '' $dest $null))
        & ($fn.refreshRows) ($state.rows.Count - 1)
        [void]$c.DlgPostFrom.Focus()
    }.GetNewClosure())
    # A row this dialog can rebuild gets a sentence; one it cannot gets a question.
    #
    # 'other' is every step type with no editor here - kill, registry, service - and its Obj is
    # JSON somebody wrote by hand, carried through untouched. Removing one of those is the only
    # edit in this dialog that cannot be undone by simply doing it again, because there is
    # nothing here that can build it a second time. Everything else removed silently before this,
    # which is why a mis-click was indistinguishable from a button that had not worked.
    $c.DlgPostRemove.Add_Click({
        $i = $c.DlgPostList.SelectedIndex
        if ($i -lt 0) {
            $c.DlgStatus.Foreground = '#FFFBBF24'
            $c.DlgStatus.Text = 'Choose an action to remove.'
            return
        }
        $row  = $state.rows[$i]
        $what = [string]$row.Text
        if ([string]$row.Kind -ne 'other') {
            $state.rows.RemoveAt($i)
            & ($fn.refreshRows) ([Math]::Min($i, $state.rows.Count - 1))
            $c.DlgStatus.Foreground = '#FF9A9AA6'
            $c.DlgStatus.Text = "Removed: $what"
            return
        }
        Show-Confirm 'Remove this action?' (
            "$what`r`n`r`n" +
            'There is no editor here for that kind of step - it was written into the catalog by ' +
            'hand and this dialog only carries it through. Removing it cannot be undone by ' +
            'adding it back, because nothing in this window can build it again.'
        ) 'Remove' ({
            $state.rows.RemoveAt($i)
            & ($fn.refreshRows) ([Math]::Min($i, $state.rows.Count - 1))
            $c.DlgStatus.Foreground = '#FF9A9AA6'
            $c.DlgStatus.Text = "Removed: $what"
        }.GetNewClosure())
    }.GetNewClosure())
    # parenthesised, or -1 is read as a parameter name rather than a number
    $c.DlgPostUp.Add_Click({   & ($fn.moveRow) (-1) }.GetNewClosure())
    $c.DlgPostDown.Add_Click({ & ($fn.moveRow) (1) }.GetNewClosure())

    # Writes a proposal into a box, but only over a value the dialog itself proposed earlier.
    # Anything typed by hand survives; anything left over from the previous file does not.
    $fn.setAuto = {
        param($ctl, [string]$key, [string]$value)
        $cur = Get-BoxText $ctl
        if (-not $cur -or $cur -eq [string]$state.auto[$key]) { $ctl.Text = $value }
        $state.auto[$key] = $value
    }.GetNewClosure()

    $fn.setBusy = {
        param($on, $msg)
        $c.DlgBusy.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
        $c.DlgFetch.IsEnabled = -not $on
        $c.DlgPickLocal.IsEnabled = -not $on
        $c.DlgStatus.Text = $msg
        $c.DlgStatus.Foreground = '#FF9A9AA6'
    }.GetNewClosure()

    # Whatever is in flight is dropped before anything else starts. In practice that is only
    # ever a listing - Fetch disables itself while it runs - but a listing deliberately disables
    # nothing, so Fetch really can be pressed while one is still reading.
    $fn.stopJob = {
        if (-not $state.job) { return }
        # BeginStop, never Stop(): Stop() is synchronous and this runs on the DISPATCHER, so
        # dropping a runspace parked inside a single Get-FileHash on a 15 GB package froze the
        # window for the rest of the hash - HANDOVER trap #7, second sighting. The pipeline is
        # detached here and disposed by the stop callback whenever it actually lets go.
        $j = $state.job
        $state.job = $null; $state.handle = $null; $state.listOnly = $false
        try {
            [void]$j.BeginStop({
                param($ar)
                try { $j.EndStop($ar) } catch { }
                try { $j.Dispose() } catch { }
            }.GetNewClosure(), $null)
        } catch {
            try { $j.Dispose() } catch { }
        }
    }.GetNewClosure()

    $fn.startFetch = {
        param($source)
        if (-not $source) { $c.DlgStatus.Text = 'Give a URL first, or pick a local file.'; return }
        & ($fn.stopJob)
        & ($fn.setBusy) $true 'Fetching and hashing - this can take a while on a large package...'
        $state.job = [powershell]::Create()
        [void]$state.job.AddScript($fetchText).AddArgument($source).AddArgument($PackageDir).
               AddArgument($false)
        $state.handle = $state.job.BeginInvoke()
    }.GetNewClosure()

    # Read what is INSIDE the package without hashing it, so reopening an app offers the same
    # pick-list it had when it was built. Before this, the only files offered were the ones
    # already written down - no help at all when the point is to add a second one - and with no
    # listing Test-InPackage has no opinion, so a `from` naming a file that is not in there
    # passed every check in the editor and failed on the client at the end of a long install.
    #
    # Nothing is disabled while it runs. Listing a zip is near-instant, and the one case that is
    # not - an .iso, which Windows has to mount - is still no reason to hold Save shut.
    $fn.startList = {
        param($source)
        if (-not $source -or -not (Test-Path -LiteralPath $source)) { return }
        & ($fn.stopJob)
        $state.listOnly = $true
        $state.job = [powershell]::Create()
        [void]$state.job.AddScript($fetchText).
               AddArgument($source).AddArgument($PackageDir).AddArgument($true)
        $state.handle = $state.job.BeginInvoke()
    }.GetNewClosure()

    $poll = New-Object Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(300)
    $poll.Add_Tick({ Invoke-Guarded {
        if (-not $state.job -or -not $state.handle.IsCompleted) { return }
        $r = $null
        try { $r = $state.job.EndInvoke($state.handle) | Select-Object -Last 1 }
        catch { $r = @{ error = $_.Exception.Message } }
        try { $state.job.Dispose() } catch { }
        $state.job = $null; $state.handle = $null
        # A listing changes exactly two things: what there is to choose from, and whether the
        # "not in the package" guard has an opinion. Every value on screen is the catalog's own
        # and stays untouched - nothing was hashed, so there is nothing to propose from.
        if ($state.listOnly) {
            $state.listOnly = $false
            if (-not $r -or $r.error) {
                # The package cannot be read from here. That is not a failure of anything the
                # person just did - they opened an app - so it is said quietly, and the dialog
                # carries on behaving exactly as it did before there was a list at all.
                $c.DlgStatus.Foreground = '#FF9A9AA6'
                $c.DlgStatus.Text = 'The package could not be read.'
                return
            }
            $state.files = @($r.files)
            # Repopulating an editable ComboBox blanks its Text, and that text is live-bound to
            # the selected after-install row - so row edits are suspended across it and the
            # row's own values are put back by the $fn.syncPostEditor below, which re-runs the
            # guard while it is at it.
            $state.loading = $true
            try {
                $c.DlgPostFrom.Items.Clear()
                foreach ($f in @($r.files)) { [void]$c.DlgPostFrom.Items.Add($f) }
            } finally { $state.loading = $false }
            & ($fn.syncPostEditor)
            $c.DlgStatus.Foreground = '#FF9A9AA6'
            $c.DlgStatus.Text = "$(@($r.files).Count) file(s) read from the package on this machine - it was not re-hashed."
            return
        }
        & ($fn.setBusy) $false ''
        if (-not $r) { return }
        if ($r.error) {
            $c.DlgStatus.Text = "Failed: $($r.error)"
            $c.DlgStatus.Foreground = '#FFF87171'
            return
        }
        $state.sha256 = [string]$r.sha256
        $state.size   = [long]$r.size
        $state.files  = @($r.files)
        & ($fn.syncHash)
        $c.DlgEntry.Items.Clear()
        foreach ($e in @($r.entries)) { [void]$c.DlgEntry.Items.Add($e) }
        # Repopulating an editable ComboBox blanks its Text, and that text is live-bound to the
        # selected after-install row - so row edits are suspended across it, and the row's own
        # values are pushed back afterwards by the $fn.syncPostEditor at the end of this tick.
        $state.loading = $true
        try {
            $c.DlgPostFrom.Items.Clear()
            foreach ($f in @($r.files)) { [void]$c.DlgPostFrom.Items.Add($f) }
        } finally { $state.loading = $false }
        # A hashed entry whose name has not changed is this product's own file arriving again -
        # a re-hash, not a swap - so the two fields settled elsewhere stay exactly as they are.
        # Change the name and they follow the new product, which is what swapping a package is.
        $sameProduct = ($state.settled -and (Get-BoxText $c.DlgName) -eq $state.openName)

        # Nothing is proposed here any more. The editor used to identify the packager and
        # suggest a switch; the suggestion was never reliable enough to act on, and a wrong
        # switch does not fail loudly - the installer opens its GUI on a client machine and
        # waits. What the package IS gets reported, and the switch is left to a person.
        $c.DlgSilentHint.Foreground = '#FF9A9AA6'
        $c.DlgSilentHint.Text = $(if ($r.packager) { "Package opened as $($r.packager). " } else { '' }) +
            'Switches are not guessed at - type the one this installer documents, or leave it blank ' +
            'and the installer guard will stop it if it opens a window.'
        $cands = @(Get-VerifyCandidates (Get-BoxText $c.DlgName))
        $state.loading = $true
        try { $c.DlgVerify.Items.Clear(); foreach ($cd in $cands) { [void]$c.DlgVerify.Items.Add($cd) } }
        finally { $state.loading = $false }
        if (-not $sameProduct) {
            & ($fn.setAuto) $c.DlgVerify 'verify' $(if ($cands.Count) { [string]$cands[0] } else { '' })
        } else {
            # Items.Clear() above blanked the box (an editable ComboBox does that), and for the
            # same product the refill was skipped - so a re-fetch left the verify path empty on
            # screen and the NEXT apply wrote that emptiness into the catalog. Put the settled
            # value back, silently.
            $state.loading = $true
            try { $c.DlgVerify.Text = [string](@(Get-Field $App 'verifyPaths') | Select-Object -First 1) }
            finally { $state.loading = $false }
        }
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
        & ($fn.syncPostEditor)
        # the ranked best guess is proposed; a setup file chosen by hand survives, one left over
        # from the previous package does not - and a package with no installer inside clears it,
        # or an .exe would keep a setup path belonging to somebody else's zip
        & ($fn.setAuto) $c.DlgEntry 'entry' $(if (@($r.entries).Count) { [string](@($r.entries)[0]) } else { '' })
        if (@($r.entries).Count) {
            $c.DlgStatus.Text = "Found $(@($r.entries).Count) installer(s) and $(@($r.files).Count) file(s) inside the package."
            $c.DlgStatus.Foreground = '#FF34D399'
        } elseif ([IO.Path]::GetExtension([string]$r.file).ToLower() -in '.zip', '.rar', '.iso') {
            $c.DlgStatus.Text = 'No .exe or .msi in that package.'
            $c.DlgStatus.Foreground = '#FFFBBF24'
        } else {
            $c.DlgStatus.Text = 'Hashed.'
            $c.DlgStatus.Foreground = '#FF34D399'
        }
        # A URL fetch downloaded real bytes into the package cache - record them as this app's
        # local source, or Push files the app under "no installer on this machine" while the
        # installer sits in packages\. The local-pick branch already records itself.
        if (-not $state.localFile -and $r.file -and (Test-Path -LiteralPath ([string]$r.file))) {
            $state.localFile = [string]$r.file
        }
        # The computed facts must LAND, not just paint. Storage used to depend on a ComboBox
        # repopulation happening to raise TextChanged - which demonstrably does not happen for
        # a bare .exe re-fetch: green "Hashed." on screen, the OLD hash still in the catalog,
        # and no dirty flag to warn on close. apply writes it; the sidecar learns a picked
        # file's whereabouts at the same moment (the seam Save-AppSources was written for,
        # which nothing in production ever called).
        # apply also raises $fn.onChange, and the MAIN WINDOW's handler is where the sidecar
        # learns about a picked file - the dialog itself stays deliberately sidecar-free
        # (Test-Push pins that seam), so no Save-AppSources here.
        & ($fn.apply)
    } 'Fetch' }.GetNewClosure())
    $poll.Start()

    # The bytes this app was built from, if this machine still has them. $LocalFile is what the
    # caller resolved through the sidecar; the _localFile field is the cache of that same
    # answer, and is what the two standalone harnesses set. Either way the listing costs
    # nothing, so it is simply read rather than asked for.
    $openWith = [string]$LocalFile
    if (-not $openWith) { $openWith = [string](Get-Field $App '_localFile') }
    if ($openWith) { & ($fn.startList) $openWith }

    $c.DlgFetch.Add_Click({ & ($fn.startFetch) (Get-BoxText $c.DlgUrl) }.GetNewClosure())
    $c.DlgPickLocal.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Title = 'Choose the package or installer'
        $d.Filter = 'Packages and installers (*.zip;*.rar;*.iso;*.exe;*.msi)|*.zip;*.rar;*.iso;*.exe;*.msi|All files (*.*)|*.*'
        if (-not $d.ShowDialog()) { return }
        $leaf = [IO.Path]::GetFileName($d.FileName)
        # The file already says what the app is called. Leaving the name blank after picking
        # one made the dialog look like it had ignored the click - only the URL changed, and
        # that is the field furthest down. Filled only when empty, so an existing name is
        # never overwritten by a re-hash.
        # separators read as spaces, but a trailing dotted version is a VERSION - see
        # ConvertFrom-PackageFileName for what turning 2026.26.1.256 into "2026 26 1 256" cost
        $proposed = [string](ConvertFrom-PackageFileName $d.FileName).Name
        & ($fn.setAuto) $c.DlgName 'name' $proposed
        # a local file still needs a URL for the client to fetch it from - offer the obvious one.
        # The <id> segment matches what Push uploads to and what the catalog already contains;
        # without it two apps whose installer is called setup.exe collide in the bucket.
        $idForUrl = ConvertTo-Id (Get-BoxText $c.DlgName)
        if (-not $idForUrl) { $idForUrl = ConvertTo-Id $proposed }
        & ($fn.setAuto) $c.DlgUrl 'url' "$($BaseUrl.TrimEnd('/'))/files/$idForUrl/$leaf"
        # Remember where these bytes came from. This is the branch that never recorded it, so a
        # file picked here was invisible to Push the moment the catalog was saved.
        $state.localFile = $d.FileName
        & ($fn.startFetch) $d.FileName
    }.GetNewClosure())

    # ---- applied as you type, because there is nowhere left to press Save ----
    #
    # The pop-up validated on Save and refused to close. A docked panel has no such moment, so
    # this follows the rule the rest of the tool already uses: WRITE, and SAY what is not right.
    # Publishing is the gate that refuses; Publish-Release.ps1 checks every one of these again.
    $fn.apply = {
        $name = (Get-BoxText $c.DlgName)
        Set-Field $App 'name' $name

        # The id is typed now, not derived once and frozen. It is normalised rather than
        # rejected - a space becomes a dash instead of an error - and an empty box falls back to
        # the name, which is what it always used to be.
        #
        # Renaming it moves the icon with it. An icon is found as icons\<id>.png, so leaving the
        # file behind would silently blank the tile of an app that has one.
        $wantId = ConvertTo-Id (Get-BoxText $c.DlgId)
        if (-not $wantId) { $wantId = ConvertTo-Id $name }
        $haveId = [string](Get-Field $App 'id')
        if ($wantId -and $wantId -ne $haveId) {
            # Refuse an id another app already owns. Two apps sharing an id share one icon
            # file, one files/<id>/ key in the bucket and one sidecar entry - Test-App warns
            # about an existing collision, but a rename must never be what CREATES one (and
            # Move-AppIcon would otherwise quietly hand this app the other one's artwork).
            if (@(@($script:Catalog.apps) | Where-Object { $_ -ne $App -and
                    [string](Get-Field $_ 'id') -eq $wantId }).Count) {
                $wantId = $haveId
            } else {
                # Recorded rather than done. This runs on every keystroke of the id box, and the
                # file only needs to move once - see Request-IconMove.
                Request-IconMove $App $haveId
                Set-Field $App 'id' $wantId
            }
        }
        if (-not (Get-Field $App 'category')) { Set-Field $App 'category' (Get-DefaultCategory) }
        # iconText / iconColor are deliberately NOT touched - an existing app keeps the icon it
        # already has, and a new one simply has none until somebody sets one
        # An uninstall-only entry is removal knowledge for a product we never install - it has
        # no url, hash, size, switches or verify paths BY DESIGN (worker.js serves it on that
        # basis). Applying the empty installer boxes onto it turned the clean record into a
        # half-installer with url:"" and sizeBytes:0. Only the fields such an entry actually
        # owns (name, id, category, requires) fall through this guard.
        $unOnly = [bool](Get-Field $App 'uninstallOnly')
        if (-not $unOnly) {
        Set-Field $App 'url' (Get-BoxText $c.DlgUrl)
        # Only when this DIALOG knows a hash. $state is snapshotted at open; the bulk hasher
        # writes the app object directly, so an unconditional write here regressed a
        # just-computed hash back to '' the moment someone typed in the Name box of a drawer
        # that had been opened before the queue reached its app.
        if ($state.sha256 -or -not (Get-Field $App 'sha256')) {
            Set-Field $App 'sha256' $state.sha256
            Set-Field $App 'sizeBytes' $state.size
        }
        Set-Field $App 'silentArgs' (Get-BoxText $c.DlgSilent)
        # Merge, never replace: the combo edits only the FIRST verify path, and an app can
        # carry several (hand-curated). Writing back a one-element array here silently threw
        # the rest away - the app then "verified" on its weakest path alone.
        $vpRest = @(@(Get-Field $App 'verifyPaths') | Select-Object -Skip 1)
        Set-Field $App 'verifyPaths' @(@(@((Get-BoxText $c.DlgVerify)) + $vpRest) | Where-Object { $_ })
        }
        # requires: ids, space or comma separated; blank removes the field outright
        $reqIds = @(((Get-BoxText $c.DlgRequires)) -split '[,\s]+' | Where-Object { $_ })
        if ($reqIds.Count) { Set-Field $App 'requires' @($reqIds) } else { Remove-Field $App 'requires' }
        if (-not $unOnly) {
        if ((Get-BoxText $c.DlgEntry)) { Set-Field $App 'entry' (Get-BoxText $c.DlgEntry) } else { Remove-Field $App 'entry' }
        # Record where the bytes came from, or a file chosen with "Use a local file..." is known
        # only to _localFile, which Export-Catalog deletes - one save and Push cannot find it.
        if ($state.localFile) { Set-Field $App '_localFile' ([string]$state.localFile) }
        }

        # Cleanup is derived and never shown: the deep clean only ever SEARCHES, and a
        # technician ticks what it finds before anything is deleted. The name is the token that
        # always applies; anything curated by hand earlier is kept.
        $cl = Get-Field $App 'cleanup'
        if (-not $cl) { $cl = [pscustomobject]@{}; Set-Field $App 'cleanup' $cl }
        # KNOWN QUIRK, kept deliberately: the app's name is re-unioned into tokens on every
        # apply, so a curator who removed it finds it back after the next edit. Removing the
        # name token is not a supported curation - the deep clean's name matching depends on
        # it - but if that ever changes, this line is the one to make conditional.
        Set-Field $cl 'tokens' @(@(Get-Field $cl 'tokens') + $name | Where-Object { $_ } | Select-Object -Unique)
        foreach ($k in 'paths', 'registry', 'hosts') {
            if (-not $cl.PSObject.Properties[$k]) { Set-Field $cl $k @() }
        }
        # ---- what is still wrong with it ----
        $why = ''
        $stepProblem = $false
        if (-not $name)                    { $why = 'This application still needs a name.' }
        elseif (-not (Get-BoxText $c.DlgUrl)) { $why = 'It needs a download URL before it can be published.' }
        # Walked ALWAYS, never behind the name/url check: whether the steps are complete decides
        # whether they get written at all, and a missing URL must not make an empty action look
        # fine by short-circuiting past it.
        $stepWhy = ''
        if ($true) {
            for ($i = 0; $i -lt $state.rows.Count; $i++) {
                $row = $state.rows[$i]
                if ($row.Kind -eq 'powershell') {
                    if (-not $row.Cmd) { $stepWhy = "After installation: action $($i + 1) has no command."; $stepProblem = $true; break }
                    continue
                }
                if ($row.Kind -notin 'copy', 'run') { continue }
                if (-not $row.From) { $stepWhy = "After installation: action $($i + 1) has no file chosen inside the package."; $stepProblem = $true; break }
                elseif (-not (Test-InPackage $state.files $row.From)) { $stepWhy = "After installation: action $($i + 1) names '$($row.From)', which is not in the package."; $stepProblem = $true; break }
                elseif ($row.Kind -eq 'copy' -and -not $row.Dest) { $stepWhy = "After installation: action $($i + 1) does not say where the file goes."; $stepProblem = $true; break }
            }
        }
        # these steps take their file OUT of the package, so there has to be a package - the
        # worker refuses `from` on a single installer, and it would refuse it on a client
        if (-not $stepWhy -and @(@($state.rows) | Where-Object { $_.Kind -in 'copy', 'run' }).Count -and
            -not (Get-BoxText $c.DlgEntry)) {
            $stepWhy = 'After-install actions take their file out of the package, so this app must be a .zip with a setup file chosen above.'
            $stepProblem = $true
        }
        if (-not $why) { $why = $stepWhy }
        # The after-install list is written only when it is COMPLETE. Every other field applies
        # as you type, but a half-built action is not a smaller version of a good one - it is a
        # step the worker would refuse on a client, and writing it would put it in apps.json the
        # next time anything saved. The old dialog got this for free by refusing to close.
        if (-not $stepProblem) { Set-PostRows $App $state.rows }

        if ($why) { $c.DlgStatus.Text = $why; $c.DlgStatus.Foreground = '#FFFBBF24' }
        else      { $c.DlgStatus.Text = ''  ; $c.DlgStatus.Foreground = '#FF6E6E7A' }

        Set-CatalogDirty
        # Read off $fn, NOT off $script: - the same trap as the dirty flag one line up. A
        # $script: variable read from inside a closure here comes back null, so renaming an app
        # wrote the new name to the catalog and left the card behind it showing the old one.
        # That is what made the names look hardcoded. $fn is a hashtable the caller also holds,
        # so whatever it puts there is what runs.
        if ($fn.onChange) { & ($fn.onChange) }
    }.GetNewClosure()
    # Hung on the panel rather than put in a script variable. A caller that dot-sources this
    # file gets its OWN script scope, so $script:X written in here is not the $script:X it reads
    # back - which is exactly how the unsaved-changes flag went quiet. The panel is the one
    # thing both sides certainly share.
    $dlg.Tag = @{ C = $c; State = $state; Apply = $fn.apply; Fn = $fn; PaintIcon = $fn.paintIcon }

    # ---- the fields that describe the CATALOG entry rather than the package ----
    #
    # Category and icon were the panel's two original fields and they stay at the top, so the
    # drawer at peek width still reads as the design it came from. They are wired here, inside
    # the per-application tree, so they die with it like everything else.
    $c.DlgId.Text = [string](Get-Field $App 'id')
    $state.openId = [string](Get-Field $App 'id')
    $state.loading = $true
    $c.DlgCategory.ItemsSource   = @(Get-CategoryNames)
    $c.DlgCategory.SelectedItem  = [string](Get-Field $App 'category')
    $state.loading = $false
    $c.DlgCategory.Add_SelectionChanged({
        if ($state.loading) { return }
        $to = [string]$c.DlgCategory.SelectedItem
        if (-not $to -or [string](Get-Field $App 'category') -eq $to) { return }
        Set-Field $App 'category' $to
        & ($fn.apply)
    }.GetNewClosure())

    # Three states, painted on both tiles at once so the header and the big preview can never
    # disagree. A colour arrives as a string from the catalog and has to be converted; WPF will
    # not take one for a Background from PowerShell.
    # The tile shows the catalog's own letter mark, or a dashed slot when there is none.
    # Nothing here fetches, extracts or downloads artwork - icons are uploaded by hand.
    $brush = New-Object Windows.Media.BrushConverter
    $fn.paintIcon = {
        $iv = Get-IconView $App
        foreach ($pair in @(@($c.DlgIconSlot, $iv.SlotVis), @($c.DlgIconSlotBig, $iv.SlotVis),
                            @($c.DlgIconLetter, $iv.LetterVis), @($c.DlgIconLetterBig, $iv.LetterVis),
                            @($c.DlgIconImageBox, $iv.ImageVis), @($c.DlgIconImageBoxBig, $iv.ImageVis))) {
            $pair[0].Visibility = $pair[1]
        }
        $c.DlgIconText.Text    = [string]$iv.IconText
        $c.DlgIconTextBig.Text = [string]$iv.IconText
        if ($iv.IconBg) {
            try {
                $b = $brush.ConvertFromString([string]$iv.IconBg)
                $c.DlgIconLetter.Background    = $b
                $c.DlgIconLetterBig.Background = $b
            } catch { }
        }
        # Set in CODE here, so a BitmapImage is fine - it is only the PSCustomObject binding on
        # the cards that cannot carry one. OnLoad so the file is not left open: the next Pick a
        # PNG has to be able to overwrite it.
        if ($iv.IconImage) {
            $c.DlgIconImage.Source    = $iv.IconImage
            $c.DlgIconImageBig.Source = $iv.IconImage
        }
        $c.DlgIconState.Text = $(if ($iv.ImageVis -eq 'Visible') { "icons\$([string](Get-Field $App 'id')).png" }
                                 elseif ($iv.LetterVis -eq 'Visible') { 'Letter mark' }
                                 else { 'No icon yet' })
    }.GetNewClosure()
    & ($fn.paintIcon)

    # Re-pointed here, because the Tag above was built before this closure existed and a
    # hashtable stores the value it was handed - a null. Picking a PNG called into that null,
    # the tile never repainted, and the icon only turned up if you reselected the app.
    $dlg.Tag.PaintIcon = $fn.paintIcon

    # Sources in the order worth trying. A PNG is taken as-is; anything else has its icon
    # extracted, which is the only source that can produce a Revit or a Chaos Corona - nobody
    # publishes those logos, but both installers carry one.
    # The icon button is wired by the window, not here: choosing an icon means reaching the
    # library and the overlay, and neither belongs to a panel that a harness lifts on its own.
    # What this side owns is repainting the tiles once something has been chosen.


    # DlgId included: it was the one field with no handler at all, so a typed id was silently
    # discarded unless some OTHER field happened to change afterwards
    foreach ($box in @($c.DlgName, $c.DlgUrl, $c.DlgSilent, $c.DlgRequires, $c.DlgId)) {
        $box.Add_TextChanged({ if (-not $state.loading) { & ($fn.apply) } }.GetNewClosure())
    }
    foreach ($cmb in @($c.DlgEntry, $c.DlgVerify)) {
        $cmb.Add_SelectionChanged({ if (-not $state.loading) { & ($fn.apply) } }.GetNewClosure())
        $cmb.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
            [Windows.RoutedEventHandler]{ if (-not $state.loading) { & ($fn.apply) } }.GetNewClosure())
    }

    # The poll and the hashing runspace outlive one field edit but not one application, so the
    # caller is given a way to stop them before it swaps the panel out.
    $dlg.Tag.Stop = { try { $poll.Stop() } catch { }; & ($fn.stopJob) }.GetNewClosure()
    return $dlg
}

# ---------------------------------------------------------------- main window

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC2Go Management Console" Height="700" Width="1060" MinHeight="560" MinWidth="900"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" Opacity="0"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#FFE9E9EE"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Window.Resources>
    <!-- Every colour here is one AppDeploy.ps1 already uses. The editor and the client are two
         views of the same catalog and had drifted into looking like different products. -->
    <SolidColorBrush x:Key="Panel"    Color="#FF17171B"/>
    <SolidColorBrush x:Key="Sunken"   Color="#FF101014"/>
    <SolidColorBrush x:Key="Raised"   Color="#FF2A2A31"/>
    <SolidColorBrush x:Key="Line"     Color="#FF3C3C45"/>
    <SolidColorBrush x:Key="LineSoft" Color="#FF26262E"/>
    <SolidColorBrush x:Key="Ink"      Color="#FFE9E9EE"/>
    <SolidColorBrush x:Key="Muted"    Color="#FF9A9AA6"/>
    <SolidColorBrush x:Key="Dim"      Color="#FF6E6E7A"/>
    <SolidColorBrush x:Key="Accent"   Color="#FF2563EB"/>
    <SolidColorBrush x:Key="Lift"     Color="#FF4C8DFF"/>
    <SolidColorBrush x:Key="Bad"      Color="#FFF87171"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Raised}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Line}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource LineSoft}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource Dim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The accent button from AppDeploy.ps1: a top-to-bottom gradient, lifting on hover and
         sinking when pressed. A flat fill beside it read as a different control. -->
    <Style x:Key="Accented" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#FF4C8DFF" Offset="0"/>
                  <GradientStop Color="#FF2563EB" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Lift}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF1A47AC"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Raised}"/>
                <Setter Property="Foreground" Value="{StaticResource Dim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#FF5A2A2E"/>
      <Setter Property="Foreground" Value="{StaticResource Bad}"/>
    </Style>
    <!-- Minimise and close: flat, and coloured only on hover, so the window controls never
         compete with the one blue button that actually publishes. -->
    <!-- The window buttons from AppDeploy.ps1: a 42x32 hit area that lights up on hover, and a
         close that goes red. This was a small text button that only changed colour. -->
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#22FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinCloseBtn" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#FFE1344B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Sunken}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="FontSize" Value="12.3"/>
    </Style>
    <!-- Templated, because a ComboBox with only setters keeps the SYSTEM template - which is
         white whatever Background is set on it. That is the white field in a dark window. -->
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontSize" Value="12.3"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="{StaticResource Sunken}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="tb" Background="{StaticResource Sunken}" CornerRadius="6"
                            BorderBrush="{StaticResource Line}" BorderThickness="1">
                      <Path Data="M 0,0 L 4,4 L 8,0" Stroke="{StaticResource Muted}" StrokeThickness="1.4"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="tb" Property="BorderBrush" Value="{StaticResource Lift}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="9,0,26,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Margin="6,0,26,0" VerticalAlignment="Center"
                       Background="Transparent" BorderThickness="0" Foreground="{StaticResource Ink}"
                       CaretBrush="{StaticResource Ink}" Visibility="Collapsed"/>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Bottom" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                        BorderThickness="1" CornerRadius="6" MinWidth="{TemplateBinding ActualWidth}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,3,0,0">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ci" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ci" Property="Background" Value="#FF1B2233"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The scrollbar from AppDeploy.ps1. With no style at all the window inherits the system
         one, which is a light grey slab down the side of a dark window. -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#30FFFFFF" CornerRadius="3" Width="6" Margin="1,0"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The category rail row. The stock ListBoxItem paints a system-blue block on selection;
         this replaces it with the accent bar the client uses on its group headers, so "which
         category am I in" reads the same way in both windows. -->
    <Style x:Key="RailRow" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6">
              <Grid>
                <Border x:Name="bar" Width="2" HorizontalAlignment="Left" CornerRadius="1"
                        Background="Transparent"/>
                <ContentPresenter Margin="9,7,8,7"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF1E1E25"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF243043"/>
                <Setter TargetName="bar" Property="Background" Value="#FF4C8DFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- An application card. Same reason: a highlighted strip cannot show which of two columns
         is selected, and these sit in a grid rather than a list. -->
    <Style x:Key="AppCard" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,0,9,9"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <!-- MinHeight and the two rounding flags are not cosmetic. Left to the content the
                 card came out 53.92 units tall, and a fractional height puts the 1px bottom
                 border across a device-pixel boundary, where it anti-aliases to almost nothing -
                 so the selection outline looked open along the bottom. An integral height and
                 pixel snapping keep all four edges the same weight. -->
            <Border x:Name="bd" Background="{StaticResource Panel}" CornerRadius="8"
                    BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10,9"
                    MinHeight="56" SnapsToDevicePixels="True" UseLayoutRounding="True">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF1B1B21"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Line}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF1B2233"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
  </Window.Resources>

  <!-- One rounded panel, because the window itself is transparent. Matches AppDeploy.ps1. -->
  <Border Background="#FF1B1B20" BorderBrush="{StaticResource Line}" BorderThickness="1"
          CornerRadius="11">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- ============================================================= title bar -->
      <!-- The installer's header, worn here too: transparent over the rounded panel, 54 tall, a
           32px mark and the same type scale. It used to be a coloured band with a rule under it,
           which is a different window from the one this sits beside all day. -->
      <Border x:Name="TitleBar" Grid.Row="0" Background="Transparent" Height="54" Padding="22,0,14,0">
        <DockPanel LastChildFill="False">
          <Border Width="32" Height="32" CornerRadius="10" Background="{StaticResource Accent}"
                  DockPanel.Dock="Left" VerticalAlignment="Center">
            <TextBlock Text="P2" FontSize="13" FontWeight="Bold" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <!-- There was a subtitle here reading "Reading catalog...". Nothing in the repository
               ever assigned it, so it said that permanently, long after the catalog had loaded -
               a window whose own header was untrue from the first second. The status bar has
               both a live activity line and a standing summary; this had no third thing to say. -->
          <StackPanel DockPanel.Dock="Left" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="PC2Go Management Console" FontWeight="SemiBold" FontSize="14.5"/>
          </StackPanel>
          <Button x:Name="BtnWinClose" DockPanel.Dock="Right" Style="{StaticResource WinCloseBtn}"
                  VerticalAlignment="Center" Margin="0,0,8,0">
            <Path Data="M 0,0 L 10,10 M 10,0 L 0,10" Stroke="{StaticResource Ink}" StrokeThickness="1.4"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None"/>
          </Button>
          <Button x:Name="BtnMin" DockPanel.Dock="Right" Style="{StaticResource WinBtn}"
                  VerticalAlignment="Center">
            <Rectangle Width="11" Height="1.4" Fill="{StaticResource Ink}"/>
          </Button>
          <!-- Search is sticky across categories on purpose: type a name once and it is found
               wherever it is filed, which is the question being asked when you search. -->
          <!-- Same box as AppDeploy.ps1's: 240 x 34, panel fill, radius 6. It was 220 and about
               28 tall, which is near enough to look like a mistake beside the other window. -->
          <Border DockPanel.Dock="Right" Width="240" Height="34" Background="{StaticResource Panel}"
                  BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6"
                  VerticalAlignment="Center" Margin="0,0,12,0">
            <Grid>
              <TextBlock x:Name="TxtSearchHint" Text="Search applications..." Margin="9,0,0,0"
                         Foreground="{StaticResource Dim}" FontSize="12.5"
                         VerticalAlignment="Center" IsHitTestVisible="False"/>
              <TextBox x:Name="TxtSearch" Background="Transparent" BorderThickness="0"
                       Padding="8,5" FontSize="12.5"/>
            </Grid>
          </Border>
        </DockPanel>
      </Border>

      <!-- ============================================================= three panes -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="238"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- === rail === -->
        <Border Grid.Column="0" Background="{StaticResource Panel}"
                BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
          <DockPanel Margin="8,0,8,0">
            <TextBlock DockPanel.Dock="Top" Text="CATEGORIES" FontSize="10.5" FontWeight="Bold"
                       Foreground="{StaticResource Dim}" Margin="6,13,0,8"/>
            <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,9">
              <Button x:Name="BtnCatNew" Content="&#43; New category" Style="{StaticResource Btn}"
                      Margin="0,0,0,6"/>
              <Button x:Name="BtnCatManage" Content="Manage categories..."
                      Style="{StaticResource Ghost}" Margin="0"/>
            </StackPanel>
            <ListBox x:Name="ListCats" Background="Transparent" BorderThickness="0"
                     ItemContainerStyle="{StaticResource RailRow}"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled">
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <DockPanel LastChildFill="True">
                    <TextBlock DockPanel.Dock="Left" Text="&#8942;&#8942;" FontSize="11"
                               Foreground="#FF4A4A56" VerticalAlignment="Center"
                               Margin="0,0,8,0" Visibility="{Binding GripVis}"/>
                    <TextBlock DockPanel.Dock="Right" Text="{Binding Count}" FontSize="11"
                               VerticalAlignment="Center" Margin="8,0,2,0">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Foreground" Value="#FF6E6E7A"/>
                          <Style.Triggers>
                            <DataTrigger Value="True" Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType=ListBoxItem}}">
                              <Setter Property="Foreground" Value="#FF4C8DFF"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <TextBlock Text="{Binding Name}" FontSize="12.8" VerticalAlignment="Center"
                               TextTrimming="CharacterEllipsis" Foreground="{StaticResource Ink}"/>
                  </DockPanel>
                </DataTemplate>
              </ListBox.ItemTemplate>
            </ListBox>
          </DockPanel>
        </Border>

        <!-- === applications === -->
        <DockPanel Grid.Column="1">
          <Border DockPanel.Dock="Top" BorderBrush="{StaticResource LineSoft}"
                  BorderThickness="0,0,0,1" Padding="16,13,16,12">
            <DockPanel LastChildFill="False">
              <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
                <TextBlock x:Name="TxtGroupTitle" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtGroupMeta" FontSize="11.5" Foreground="{StaticResource Dim}"/>
              </StackPanel>
              <Button x:Name="BtnAdd" DockPanel.Dock="Right" Content="Add application"
                      Style="{StaticResource Accented}" Margin="0" VerticalAlignment="Center"/>
              <Button x:Name="BtnAddFolder" DockPanel.Dock="Right" Content="Add folder..."
                      Style="{StaticResource Btn}" VerticalAlignment="Center"/>
            </DockPanel>
          </Border>
          <ScrollViewer x:Name="AppsScroller" VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Disabled" Padding="16,14,7,14">
            <StackPanel>
              <ListBox x:Name="ListApps" Background="Transparent" BorderThickness="0"
                       ItemContainerStyle="{StaticResource AppCard}"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                       ScrollViewer.VerticalScrollBarVisibility="Disabled">
                <ListBox.ItemsPanel>
                  <ItemsPanelTemplate><UniformGrid Columns="2"/></ItemsPanelTemplate>
                </ListBox.ItemsPanel>
                <ListBox.ItemTemplate>
                  <DataTemplate>
                    <DockPanel LastChildFill="True">
                      <!-- The icon slot. Dashed while empty, so a catalog full of unfilled
                           slots reads as unfinished rather than as broken artwork. -->
                      <Grid DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,11,0">
                        <Border CornerRadius="7" Background="#FF23232B" BorderThickness="1"
                                BorderBrush="#FF3E3E49" Visibility="{Binding SlotVis}"/>
                        <Path Data="M4,6 L26,6 L26,24 L4,24 Z M10,12 A1.8,1.8 0 1,1 10.1,12 M5,22 L12,15 L16,19 L20,15.5 L25,21"
                              Stroke="#FF5A5A67" StrokeThickness="1.4" Stretch="Uniform"
                              Margin="8" Visibility="{Binding SlotVis}"/>
                        <Border CornerRadius="7" Background="{Binding IconBg}"
                                Visibility="{Binding LetterVis}">
                          <TextBlock Text="{Binding IconText}" FontSize="11" FontWeight="Bold"
                                     Foreground="White" HorizontalAlignment="Center"
                                     VerticalAlignment="Center"/>
                        </Border>                        <Border CornerRadius="7" Background="Transparent"
                                Visibility="{Binding ImageVis}">
                          <Image Source="{Binding IconImage}" Stretch="Uniform"/>
                        </Border>
                      </Grid>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="{Binding Name}" FontSize="13"
                                   TextTrimming="CharacterEllipsis" Foreground="{StaticResource Ink}"/>
                        <DockPanel Margin="0,2,0,0" LastChildFill="True">
                          <TextBlock DockPanel.Dock="Right" Text="{Binding Live}" FontSize="11"
                                     Foreground="{Binding LiveColour}" VerticalAlignment="Center"/>
                          <Ellipse DockPanel.Dock="Right" Width="6" Height="6" Margin="7,0,5,0"
                                   Fill="{Binding LiveColour}" VerticalAlignment="Center"/>
                          <TextBlock Text="{Binding Detail}" FontSize="11"
                                     Foreground="{Binding Colour}" TextTrimming="CharacterEllipsis"/>
                        </DockPanel>
                      </StackPanel>
                    </DockPanel>
                  </DataTemplate>
                </ListBox.ItemTemplate>
              </ListBox>
              <!-- Sits after the last card rather than in the toolbar, because "add one HERE"
                   is a different intent from "add one", and the category is already named. -->
              <Button x:Name="GhostAdd" Margin="0,0,9,0">
                <Button.Template>
                  <ControlTemplate TargetType="Button">
                    <Border x:Name="g" CornerRadius="8" BorderThickness="1" BorderBrush="#FF35353F"
                            Background="Transparent" Padding="10,11">
                      <TextBlock x:Name="t" Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}"
                                 Foreground="{StaticResource Dim}" FontSize="12.5"
                                 HorizontalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="g" Property="BorderBrush" Value="{StaticResource Accent}"/>
                        <Setter TargetName="t" Property="Foreground" Value="{StaticResource Lift}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Button.Template>
              </Button>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>

        <!-- === the drawer === -->
        <!--
          It FLOATS over the application grid instead of taking a column of its own. As a column
          it pushed the catalog into a third of the window and left the whole thing feeling like
          two windows again, which is the opposite of the point.

          It shuts when you click away, and clicking the app it is already showing shuts it too -
          so the same click that opens Office closes it.
        -->
        <Grid x:Name="DrawerLayer" Grid.Column="1" Visibility="Collapsed">
          <Border x:Name="DrawerPanel" HorizontalAlignment="Right" Width="380"
                  Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                  BorderThickness="1,0,0,0">
            <DockPanel x:Name="InspBody">
              <Border DockPanel.Dock="Bottom" BorderBrush="{StaticResource LineSoft}"
                      BorderThickness="0,1,0,0" Padding="14,10">
                <DockPanel LastChildFill="False">
                  <Button x:Name="BtnDelete" DockPanel.Dock="Left" Content="Remove"
                          Style="{StaticResource Danger}" Margin="0"/>
                  <Button x:Name="BtnDuplicate" DockPanel.Dock="Right" Content="Duplicate"
                          Style="{StaticResource Ghost}" Margin="0"/>
                </DockPanel>
              </Border>
              <ContentControl x:Name="DrawerHost"/>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>

      <!-- ============================================================= push strip -->
      <Border x:Name="PushBar" Grid.Row="2" Visibility="Collapsed" Margin="16,10,16,0"
              Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
              BorderThickness="1" CornerRadius="7" Padding="12,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Margin="0,0,12,0">
            <TextBlock x:Name="TxtPushApp" FontSize="12.5" Margin="0,0,0,4"
                       TextTrimming="CharacterEllipsis"/>
            <ProgressBar x:Name="PushProgressBar" Height="6" Minimum="0" Maximum="1000" Value="0"
                         Foreground="{StaticResource Lift}" Background="{StaticResource Raised}"
                         BorderThickness="0" Margin="0,0,0,5"/>
            <TextBlock x:Name="TxtPushDetail" Foreground="{StaticResource Dim}" FontSize="11"
                       TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <Button x:Name="BtnPushCancel" Grid.Column="1" Content="Stop" Style="{StaticResource Btn}"
                  VerticalAlignment="Center" Margin="0"/>
        </Grid>
      </Border>

      <!-- ============================================================= status bar -->
      <Border Grid.Row="3" Background="#FF1F1F26" CornerRadius="0,0,10,10"
              BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="14,10">
        <DockPanel LastChildFill="True">
          <!-- TWO buttons, and they answer the only two questions this bar is for: "put my work
               live" and "change how this tool talks to Cloudflare".

               There were four. Save catalog went because the catalog now saves itself, and a
               button that is almost never the thing that wrote your file is worse than no button
               - it implies the opposite. The two credential buttons went behind Settings because
               they are configured once and then never touched, while sitting in the same row as
               Publish made them look like part of publishing. -->
          <Button x:Name="BtnPush" DockPanel.Dock="Right" Content="Publish"
                  Style="{StaticResource Accented}" Margin="0" VerticalAlignment="Center"/>
          <Button x:Name="BtnSettings" DockPanel.Dock="Right" Content="Settings"
                  Style="{StaticResource Ghost}" VerticalAlignment="Center"/>
          <Ellipse x:Name="DotStatus" DockPanel.Dock="Left" Width="7" Height="7" Fill="#FF4ADE80"
                   VerticalAlignment="Center" Margin="0,0,9,0"/>
          <!-- TWO slots, split by LIFETIME, and that split is the whole fix for "my
               confirmations disappear". TxtSummary is the standing truth about the catalog and
               is rewritten on every list refresh - which happens on every keystroke. TxtStatus
               is what just HAPPENED, and nothing routine is allowed to overwrite it while it is
               still fresh. They shared one control until now, so the refresh won every time and
               "Icon set for Revit." lived for about a keystroke. -->
          <TextBlock x:Name="TxtSummary" DockPanel.Dock="Right" Foreground="{StaticResource Dim}"
                     FontSize="11" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <TextBlock x:Name="TxtStatus" Foreground="{StaticResource Muted}" FontSize="11.5"
                     TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,12,0"/>
        </DockPanel>
      </Border>

      <!-- ============================================================= overlay -->
      <Border x:Name="Overlay" Grid.RowSpan="4" Background="#CC101014" Visibility="Collapsed"
              CornerRadius="11">
        <Border Background="#FF1B1B20" BorderBrush="{StaticResource Line}" BorderThickness="1"
                CornerRadius="10" Padding="20" MaxWidth="560" MaxHeight="440"
                VerticalAlignment="Top" Margin="0,60,0,0" HorizontalAlignment="Center">
          <DockPanel LastChildFill="True">
            <TextBlock x:Name="TxtOverlayTitle" DockPanel.Dock="Top" FontSize="15"
                       FontWeight="Bold" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                        HorizontalAlignment="Right" Margin="0,16,0,0">
              <Button x:Name="BtnOverlayCancel" Content="Cancel" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOverlayOk" Content="OK" Style="{StaticResource Accented}" Margin="0"/>
            </StackPanel>
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel>
                <TextBlock x:Name="TxtOverlayBody" TextWrapping="Wrap"
                           Foreground="{StaticResource Muted}" FontSize="12" Margin="0,0,0,4"/>
                <StackPanel x:Name="OverlayName" Visibility="Collapsed" Margin="0,0,0,16">
                  <TextBlock Text="Category name" Foreground="{StaticResource Muted}" FontSize="11.5"/>
                  <TextBox x:Name="TxtCatName" Margin="0,2,0,0"/>
                </StackPanel>
                <!-- The access code technicians type at launch. A PasswordBox, not a TextBox:
                     this is read out over a shoulder in the same rooms the tool is used in. -->
                <StackPanel x:Name="OverlayCode" Visibility="Collapsed" Margin="0,0,0,16">
                  <TextBlock Text="New access code" Foreground="{StaticResource Muted}" FontSize="11.5"/>
                  <PasswordBox x:Name="PwdAccessCode" Margin="0,2,0,0"/>
                  <TextBlock x:Name="TxtCodeHint" TextWrapping="Wrap" FontSize="11" Margin="0,8,0,0"
                             Foreground="{StaticResource Muted}"/>
                </StackPanel>
                <StackPanel x:Name="OverlayPick" Visibility="Collapsed" Margin="0,0,0,16">
                  <TextBlock Text="Move its applications to" Foreground="{StaticResource Muted}"
                             FontSize="11.5"/>
                  <ComboBox x:Name="CmbCatTarget" Margin="0,2,0,10"/>
                  <CheckBox x:Name="ChkCatDeleteApps" Foreground="{StaticResource Bad}"
                            FontSize="12" Content="Delete those applications instead"/>
                  <!-- The caption that used to sit here said removing a category never deletes
                       anything from R2. Show-CategoryRemove already says that in the body, above,
                       where the question is - so this was the same sentence twice. -->
                </StackPanel>
                <!-- Settings: the two things that are set up once and then left alone. Each one
                     states what is stored right now rather than explaining what it is for - the
                     state is the thing you came here to check. -->
                <StackPanel x:Name="OverlaySettings" Visibility="Collapsed" Margin="0,4,0,8">
                  <Border Background="{StaticResource Sunken}" BorderBrush="{StaticResource Line}"
                          BorderThickness="1" CornerRadius="7" Padding="12,10" Margin="0,0,0,8">
                    <StackPanel>
                      <TextBlock Text="Access code" FontSize="12.5" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TxtSetCodeState" TextWrapping="Wrap" FontSize="11"
                                 Foreground="{StaticResource Muted}" Margin="0,3,0,8"/>
                      <Button x:Name="BtnSetCode" Content="Set or rotate the access code"
                              Style="{StaticResource Btn}" HorizontalAlignment="Left" Margin="0"/>
                    </StackPanel>
                  </Border>
                  <Border Background="{StaticResource Sunken}" BorderBrush="{StaticResource Line}"
                          BorderThickness="1" CornerRadius="7" Padding="12,10">
                    <StackPanel>
                      <TextBlock Text="R2 credentials" FontSize="12.5" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TxtSetCredsState" TextWrapping="Wrap" FontSize="11"
                                 Foreground="{StaticResource Muted}" Margin="0,3,0,8"/>
                      <Button x:Name="BtnSetCreds" Content="Enter or replace the key pair"
                              Style="{StaticResource Btn}" HorizontalAlignment="Left" Margin="0"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
                <!-- Manage categories: the same verbs as the rail, in one place, for when the
                     job is "tidy the whole rail" rather than "fix this one". -->
                <StackPanel x:Name="OverlayManage" Visibility="Collapsed" Margin="0,0,0,8">
                  <ListBox x:Name="ListManageCats" Height="190" Background="{StaticResource Sunken}"
                           BorderBrush="{StaticResource Line}" Foreground="{StaticResource Ink}"
                           ItemContainerStyle="{StaticResource RailRow}" Margin="0,0,0,8">
                    <ListBox.ItemTemplate>
                      <DataTemplate>
                        <DockPanel LastChildFill="True">
                          <TextBlock DockPanel.Dock="Right" Text="{Binding Count}" FontSize="11"
                                     Foreground="{StaticResource Dim}" Margin="8,0,2,0"/>
                          <TextBlock Text="{Binding Name}" FontSize="12.5"
                                     TextTrimming="CharacterEllipsis"/>
                        </DockPanel>
                      </DataTemplate>
                    </ListBox.ItemTemplate>
                  </ListBox>
                  <UniformGrid Columns="4">
                    <Button x:Name="BtnCatRename" Content="Rename" Style="{StaticResource Btn}"/>
                    <Button x:Name="BtnCatUp" Content="Move up" Style="{StaticResource Btn}"/>
                    <Button x:Name="BtnCatDown" Content="Move down" Style="{StaticResource Btn}"/>
                    <Button x:Name="BtnCatDelete" Content="Remove" Style="{StaticResource Danger}"
                            Margin="0"/>
                  </UniformGrid>
                </StackPanel>
                <StackPanel x:Name="OverlayInput" Visibility="Collapsed" Margin="0,0,0,16">
                  <TextBlock Text="Cloudflare account ID" Foreground="{StaticResource Muted}" FontSize="11.5"/>
                  <TextBox x:Name="TxtR2Account" Margin="0,2,0,10"/>
                  <TextBlock Text="R2 access key ID" Foreground="{StaticResource Muted}" FontSize="11.5"/>
                  <TextBox x:Name="TxtR2Key" Margin="0,2,0,10"/>
                  <TextBlock Text="R2 secret access key" Foreground="{StaticResource Muted}" FontSize="11.5"/>
                  <PasswordBox x:Name="PwdR2Secret" Background="{StaticResource Sunken}"
                               Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}"
                               Padding="6,5" Margin="0,2,0,8" CaretBrush="{StaticResource Ink}"/>
                  <!-- The grey caption that used to sit under these boxes - where to create the
                       token, and where it is stored - moved into the dialog body above, which is
                       read before the boxes are filled in rather than after. -->
                </StackPanel>
              </StackPanel>
            </ScrollViewer>
          </DockPanel>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'ListApps','BtnAdd','BtnAddFolder','BtnDelete','TxtStatus','TxtSummary',
               'Overlay','TxtOverlayTitle','TxtOverlayBody','BtnOverlayOk','BtnOverlayCancel',
               'BtnPush','PushBar','TxtPushApp','PushProgressBar','TxtPushDetail','BtnPushCancel',
               'BtnSettings','OverlaySettings','BtnSetCode','BtnSetCreds','TxtSetCodeState','TxtSetCredsState',
               'OverlayCode','PwdAccessCode','TxtCodeHint',
               'OverlayInput','TxtR2Account','TxtR2Key','PwdR2Secret',
               'ListCats','BtnCatNew','BtnCatRename','BtnCatUp','BtnCatDown','BtnCatDelete',
               'TxtGroupTitle','TxtGroupMeta','OverlayPick','CmbCatTarget','ChkCatDeleteApps',
               'OverlayName','TxtCatName',
               'TitleBar','BtnMin','BtnWinClose','TxtSearch','TxtSearchHint',
               'BtnCatManage','GhostAdd','InspBody',
               'BtnDuplicate','DotStatus','OverlayManage','ListManageCats',
               'DrawerLayer','DrawerPanel','DrawerHost','AppsScroller') {
    $el = $window.FindName($n)
    # a name that does not resolve becomes $null and surfaces later as "you cannot call a
    # method on a null-valued expression", somewhere unrelated to the actual mistake
    if (-not $el) { throw "The main window layout has no control named $n." }
    Set-Variable -Name $n -Value $el -Scope Script
}

# A click handler that throws inside WPF fails SILENTLY - the button simply does nothing,
# which is indistinguishable from a dead button and hides the actual fault. Everything the
# buttons do goes through here, so a mistake is reported rather than swallowed.
#
# It is also where "every action shows something" is enforced. Every button in this file
# already routes through here, so putting the indicator in this one place means no handler can
# forget it - and a handler added later gets it for free. -Quiet is for the timer ticks, which
# also come through here: without it the dot would strobe 2.5 times a second forever and mean
# nothing.
function Invoke-Guarded([scriptblock]$Action, [string]$What, [switch]$Quiet) {
    if (-not $Quiet) {
        try {
            $DotStatus.Fill = '#FF4C8DFF'
            # One empty render pass, or the dot only appears AFTER the work finishes - which is
            # exactly when it has stopped being true.
            $DotStatus.Dispatcher.Invoke([Action]{}, 'Render')
        } catch { }
    }
    try { & $Action }
    catch {
        $detail = "$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
        # The overlay first, so a fault reports the same way everything else does. A MessageBox
        # behind it because this runs when something has ALREADY gone wrong: if the overlay
        # itself is what broke, the report must still reach a person rather than vanish into
        # the same silence this function exists to prevent.
        try { Show-Notice "$What failed" $detail }
        catch { [void][Windows.MessageBox]::Show("$What failed:`r`n`r`n$detail", 'Error', 'OK', 'Error') }
        # the overlay is modal-ish and gets dismissed; the status line is what is still there
        # afterwards, so the failure is recorded in both places
        try { Show-Fail "$What failed." } catch { }
    }
    finally {
        if (-not $Quiet) { try { $DotStatus.Fill = Get-LevelDot $script:Activity.Level } catch { } }
    }
}

$BtnAdd.Add_Click({ Invoke-Guarded {
    $app = [pscustomobject]@{
        id = ''; name = ''; version = ''; publisher = ''; category = (Get-DefaultCategory)
        sizeBytes = 0; url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @()
    }
    # The entry is created empty and filled in the drawer. There is no window to accept or
    # cancel any more, so it goes into the catalog first and the drawer opens on it - and
    # nothing reaches disk until Save catalog either way.
    $script:Catalog.apps = @(@($script:Catalog.apps) + $app)
    Set-CatalogDirty
    # A live search filters the brand-new (nameless) entry OUT of the list; the selection then
    # never moved, and the drawer stayed bound to the PREVIOUS app - every keystroke of the new
    # product overwrote an existing one while a phantom empty entry rode into the catalog. The
    # search ends when Add begins.
    if ((Get-BoxText $TxtSearch)) { $TxtSearch.Text = '' }
    Update-Categories
    Update-List
    $new = @($ListApps.Items | Where-Object { $_.App -eq $app })
    if ($new.Count) { $ListApps.SelectedItem = $new[0] }
    Open-Drawer
    Set-StatusText 'New application added. Fill it in on the right, starting with the package.'
} 'Add application' })

$BtnAddFolder.Add_Click({ Invoke-Guarded {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose a folder of installers. Every .zip, .rar, .iso, .exe and .msi directly inside it becomes an application.'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $script:BulkSkipped = 0
    # top level only, and deliberately so: recursing into a folder of installers picks up
    # every uninstaller, updater and helper exe sitting beside them
    $files = @(Get-ChildItem -LiteralPath $dlg.SelectedPath -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.zip', '.rar', '.iso', '.exe', '.msi' } | Sort-Object Name)
    if (-not $files.Count) {
        Show-Notice 'Nothing to add' "No .zip, .rar, .iso, .exe or .msi files were found directly inside:`r`n`r`n$($dlg.SelectedPath)"
        return
    }
    # WORKED OUT FIRST, COMMITTED SECOND.
    #
    # This used to create every entry, queue every hash and write the sidecar N times straight
    # off the folder picker, and the number it had skipped was only revealed at the END of
    # hashing - by which point undoing it means deleting entries one at a time. Picking a folder
    # of 40 installers is a big enough action to be worth one sentence beforehand, and the
    # sentence can only be written if nothing has happened yet.
    $plan = @()
    $skip = @()
    foreach ($f in $files) {
        $parsed = ConvertFrom-PackageFileName $f.Name
        $name = [string]$parsed.Name
        $ver  = [string]$parsed.Version
        # The id carries the version, or two releases of one product collide on it and the
        # "already in the catalog" test below silently drops the second. The duplicate rule in
        # Publish-Release reads the version field for the same reason.
        $id = ConvertTo-Id $(if ($ver) { "$name $ver" } else { $name })
        # adding the same folder twice should not double every entry - but a skip must be
        # COUNTED, or two different files deriving the same id vanish with "Added N" saying
        # everything arrived. Two files in THIS folder deriving one id collide the same way, so
        # the plan so far is checked as well as the catalog.
        if (@($script:Catalog.apps | Where-Object { (Get-Field $_ 'id') -eq $id }).Count -or
            @($plan | Where-Object { $_.Id -eq $id }).Count) {
            $skip += $f.Name
            continue
        }
        $plan += [pscustomobject]@{ File = $f; Id = $id; Name = $name; Version = $ver }
    }
    $script:BulkSkipped = $skip.Count

    if (-not $plan.Count) {
        Show-Notice 'Already in the catalog' (
            "All $($files.Count) installer(s) in that folder are already listed.")
        return
    }

    $bytes = 0L
    foreach ($p in $plan) { $bytes += [long]$p.File.Length }
    $skipLine = ''
    if ($skip.Count) {
        # Named, not just counted - "3 skipped" is unactionable, and the usual cause is a file
        # whose name derives an id something else already owns.
        $show = @($skip | Select-Object -First 6)
        $more = $(if ($skip.Count -gt 6) { "`r`n  ... and $($skip.Count - 6) more" } else { '' })
        $skipLine = ("`r`n`r`n$($skip.Count) already listed, and will be left alone:`r`n  " +
                     ($show -join "`r`n  ") + $more)
    }
    Show-Confirm 'Add these installers?' (
        "$($plan.Count) new application(s), $(Format-Size $bytes) in total, from:`r`n$($dlg.SelectedPath)" +
        $skipLine +
        "`r`n`r`nHashing starts immediately and runs in the background; nothing is uploaded."
    ) "Add $($plan.Count)" ({
        $added = 0
        foreach ($p in $plan) {
            $app = [pscustomobject]@{
                id = $p.Id; name = $p.Name; version = $p.Version; publisher = ''
                category = (Get-DefaultCategory)
                sizeBytes = 0; url = "$($BaseUrl.TrimEnd('/'))/files/$($p.Id)/$($p.File.Name)"
                sha256 = ''; silentArgs = ''; verifyPaths = @()
            }
            # Where the bytes are, for the hashing pass and later for Push. _localFile alone is
            # not enough - Export-Catalog strips it on every save - so it goes to the sidecar too.
            Set-LocalFileFor $app $p.File.FullName
            $script:Catalog.apps = @(@($script:Catalog.apps) + $app)
            [void]$script:BulkQueue.Add($app)
            $added++
        }
        $script:BulkDone = 0
        $script:BulkTotal = $added
        Set-CatalogDirty
        Update-List
        Set-StatusText "Added $added application(s). Hashing 1 of $added..." '#FF4C8DFF'
        Start-BulkNext
    }.GetNewClosure())
} 'Add folder' })

# The autosave debounce. Created here, with the other timers, because a DispatcherTimer needs
# the dispatcher to exist - Request-Save above is written to tolerate a null timer for exactly
# the window between the two.
$script:SaveTimer = New-Object Windows.Threading.DispatcherTimer
$script:SaveTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:SaveTimer.Add_Tick({ Invoke-Guarded { [void](Complete-Save) } 'Autosave' -Quiet })

# one poll for the whole bulk pass; hashing runs in a runspace so the window stays alive
$script:BulkTimer = New-Object Windows.Threading.DispatcherTimer
$script:BulkTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:BulkTimer.Add_Tick({ Invoke-Guarded {
    if ($script:BulkJob -and $script:BulkHandle.IsCompleted) { Complete-BulkOne }
    if (-not $script:BulkJob -and $script:BulkQueue.Count) { Start-BulkNext }
    # collected here rather than on a timer of its own - this one already ticks, and the live
    # check is a single fetch that finishes in well under a second or not at all
    if ($script:LiveJob -and $script:LiveHandle.IsCompleted) { Complete-LiveCheck }
    # and the status line's expiry, for the same reason: a timer that already ticks
    Sync-Activity
} 'Hashing' -Quiet })
$script:BulkTimer.Start()

$BtnDelete.Add_Click({ Invoke-Guarded {
    $row = $ListApps.SelectedItem
    if (-not $row) { Show-Warn 'Choose an application first.'; return }
    # the removal lives in a function rather than inline in the closure: a closure carries its
    # own copy of the scope it was made in, and assigning THROUGH it does not reliably reach the
    # script-scope $Catalog - a call does
    Show-Confirm 'Remove this application?' (
        "'$($row.Name)' will be taken out of the catalog.`r`n`r`n" +
        'The catalog as it was when you opened the editor is kept as apps.json.bak.'
    ) 'Remove' ({ Remove-App $row.App $row.Name }.GetNewClosure())
} 'Remove application' })

<#
    Settings: the two things configured once and then left alone.

    Each panel reports what is stored RIGHT NOW rather than explaining what it is for. That is
    the difference between a settings page and a leaflet - "stored for Legion-T7 on this
    machine" answers the question people actually open this to ask.
#>
function Show-Settings {
    $TxtOverlayTitle.Text = 'Settings'
    $TxtOverlayBody.Text  = 'How this window reaches Cloudflare. Neither of these is part of publishing.'

    # There is deliberately no way to read the current code back - a copy kept locally would be
    # one more place to leak from, and would go stale the moment somebody rotated it elsewhere.
    $TxtSetCodeState.Text = ('What a technician types when the tool starts. It cannot be read ' +
                             'back from here; setting a new one replaces it everywhere at once.')

    $have = $null
    try { $have = Get-R2Credential -Path $R2CredentialPath } catch { }
    $TxtSetCredsState.Text = $(if ($have) {
        "Stored for $env:USERNAME on this machine. Account $($have.AccountId), bucket $($have.Bucket)."
    } else {
        'Not set. Publishing will ask for these the first time it needs them.'
    })

    Hide-OverlayBodies
    $OverlaySettings.Visibility  = 'Visible'
    $BtnOverlayCancel.Visibility = 'Collapsed'
    $BtnOverlayOk.Content = 'Done'
    $script:ConfirmAction = $null
    $Overlay.Visibility = 'Visible'
}

$BtnSettings.Add_Click({ Invoke-Guarded { Show-Settings } 'Settings' })

$BtnSetCode.Add_Click({ Invoke-Guarded { Show-AccessCodePrompt } 'Access code' })

# Opens whether or not something is already stored - this is the only way to replace a key pair
# that saved but does not work, a secret clipped by one character on the way out of the dashboard.
$BtnSetCreds.Add_Click({ Invoke-Guarded {
    $have = $null
    try { $have = Get-R2Credential -Path $R2CredentialPath } catch { }
    Show-CredentialPrompt { Invoke-Guarded {
        if (Save-PromptedCredential) { Set-StatusText 'R2 credentials saved.' }
    } 'Save credentials' }
    # the account id is the one thing worth carrying over; the key pair is what is being replaced
    if ($have -and -not $TxtR2Account.Text) { $TxtR2Account.Text = $have.AccountId }
} 'R2 credentials' })

# Ctrl+S. The catalog autosaves, so this exists for the moment somebody wants it written NOW -
# it forces past the debounce rather than arming it, and past the push guard too, because a
# person pressing Ctrl+S during a push has asked for it out loud.
#
# The "Save catalog" button this replaces was worse than nothing once autosave landed: it was
# almost never the thing that actually wrote the file, so it implied the opposite of the truth.
#
# One handler for every key in the window, because each of these has to know what ELSE is on
# screen before it acts. IsDefault/IsCancel on the overlay buttons would have been less code and
# wrong: they answer to their focus scope whether or not the overlay is the thing in front of
# you, so Enter in the drawer could fire a confirm nobody was looking at.
$window.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)

    if ($ctrl -and $e.Key -eq 'S') {
        $e.Handled = $true
        Invoke-Guarded { if (Complete-Save -Force) { Show-Done 'Saved.' } } 'Save'
        return
    }

    # The overlay is modal in intent even though it is only a panel, so while it is up it owns
    # Enter and Escape outright.
    if ([string]$Overlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Return') {
            $e.Handled = $true
            $BtnOverlayOk.RaiseEvent((New-Object Windows.RoutedEventArgs(
                [Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        } elseif ($e.Key -eq 'Escape') {
            $e.Handled = $true
            # A notice has no Cancel - its OK button IS "go away" - so Escape has to go through
            # whichever one is actually on screen or it would do nothing on half the overlays.
            $btn = $(if ([string]$BtnOverlayCancel.Visibility -eq 'Visible') { $BtnOverlayCancel } else { $BtnOverlayOk })
            $btn.RaiseEvent((New-Object Windows.RoutedEventArgs(
                [Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        return
    }

    # Only when the list itself has focus. Del means "delete the selected app" on the cards and
    # "delete a character" everywhere else, including the search box directly above them.
    if ($e.Key -eq 'Delete' -and $ListApps.IsKeyboardFocusWithin -and $ListApps.SelectedItem) {
        $e.Handled = $true
        $BtnDelete.RaiseEvent((New-Object Windows.RoutedEventArgs(
            [Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
})

# ---------------------------------------------------------------- the category rail
#
# Selecting a category filters the list. "All applications" is the first row and clears the
# filter, so the flat view this window used to be is still there rather than replaced.
$ListCats.Add_SelectionChanged({ Invoke-Guarded {
    if ($script:SuspendCatSelect) { return }
    $row = $ListCats.SelectedItem
    $script:SelectedCategory = $(if ($row -and -not $row.IsAll) { [string]$row.Name } else { '' })
    Update-List
} 'Choose category' })

# The rename box and the new-category box are the same overlay, so both go through here. It
# gets its OWN text box rather than borrowing the credential panel's: that panel is built for
# three fields and a secret, and hiding two of them to reuse the third leaves the R2 prompt
# permanently missing its key boxes the next time it opens.
function Show-CategoryName([string]$Title, [string]$Body, [string]$Preset, [string]$OkText, [scriptblock]$OnName) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayBody.Text  = $Body
    $TxtCatName.Text = $Preset
    Hide-OverlayBodies
    $OverlayName.Visibility  = 'Visible'
    $BtnOverlayCancel.Visibility = 'Visible'
    $BtnOverlayOk.Content = $OkText
    $script:ConfirmAction = ({ & $OnName (Get-BoxText $TxtCatName) }.GetNewClosure())
    $Overlay.Visibility = 'Visible'
    [void]$TxtCatName.Focus()
    $TxtCatName.SelectAll()
}

function Invoke-CategoryMove([int]$Delta) {
    $row = $ListManageCats.SelectedItem
    if (-not $row -or $row.IsAll) { Set-StatusText 'Choose a category to move.' '#FFFBBF24'; return }
    $name = [string]$row.Name
    if (-not (Move-Category $name $Delta)) {
        Set-StatusText "$name is already $(if ($Delta -lt 0) { 'first' } else { 'last' })." '#FFFBBF24'
        return
    }
    $script:SelectedCategory = $name
    Complete-CategoryChange "Moved $name $(if ($Delta -lt 0) { 'up' } else { 'down' })."
}

$BtnCatNew.Add_Click({ Invoke-Guarded {
    Show-CategoryName 'New category' (
        'It appears in the rail straight away, and on the client once you publish. ' +
        'Applications are filed into it by editing them, or by adding them while it is selected.'
    ) '' 'Create' {
        param($name)
        if (-not $name) { Set-StatusText 'A category needs a name.' '#FFFBBF24'; return }
        if (-not (Add-Category $name)) {
            Set-StatusText "There is already a category called $name." '#FFFBBF24'; return
        }
        $script:SelectedCategory = $name
        Complete-CategoryChange "Added $name."
    }
} 'New category' })

$BtnCatRename.Add_Click({ Invoke-Guarded {
    $row = $ListManageCats.SelectedItem
    if (-not $row -or $row.IsAll) { Set-StatusText 'Choose a category to rename.' '#FFFBBF24'; return }
    $old = [string]$row.Name
    $OverlayManage.Visibility = 'Collapsed'
    Show-CategoryName 'Rename category' (
        "Every application filed under '$old' is rewritten to the new name, so nothing is " +
        'orphaned. Renaming onto a name that already exists merges the two.'
    ) $old 'Rename' ({
        param($name)
        if (-not $name) { Set-StatusText 'A category needs a name.' '#FFFBBF24'; return }
        $n = @(Get-AppsInCategory $old).Count
        if (-not (Rename-Category $old $name)) {
            Set-StatusText "Could not rename $old." '#FFFBBF24'; return
        }
        # named call, NOT a direct $script: assignment - inside this .GetNewClosure() block the
        # assignment lands in the closure's module and the rail then filters on a category that
        # no longer exists, rendering an empty grid under an "All applications" highlight
        Set-SelectedCategory $name
        Complete-CategoryChange "Renamed $old to $name, and $n application(s) with it."
    }.GetNewClosure())
} 'Rename category' })

# Up and Down move the group a technician sees, and ONLY that. App order in the catalog is the
# install order - Civil 3D onto AutoCAD, Corona onto 3ds Max - and it is not touched here.
$BtnCatUp.Add_Click({ Invoke-Guarded { Invoke-CategoryMove -1 } 'Move category up' })
$BtnCatDown.Add_Click({ Invoke-Guarded { Invoke-CategoryMove 1 } 'Move category down' })

$BtnCatDelete.Add_Click({ Invoke-Guarded {
    $row = $ListManageCats.SelectedItem
    if (-not $row -or $row.IsAll) { Set-StatusText 'Choose a category to remove.' '#FFFBBF24'; return }
    $OverlayManage.Visibility = 'Collapsed'
    Show-CategoryRemove ([string]$row.Name)
} 'Remove category' })

# ---------------------------------------------------------------- manage categories
#
# The rail carries the two things done constantly - pick one, make one. Renaming, reordering
# and removing are done rarely, and they are done to the LIST rather than to a category, so
# they live behind one door instead of parking four buttons under the rail forever.
function Update-ManageList {
    $want = ''
    if ($ListManageCats.SelectedItem) { $want = [string]$ListManageCats.SelectedItem.Name }
    $rows = @(@(Get-CategoryNames) | ForEach-Object {
        [pscustomobject]@{ Name = $_; Count = @(Get-AppsInCategory $_).Count; IsAll = $false } })
    $ListManageCats.ItemsSource = $rows
    $keep = @($rows | Where-Object { $_.Name -eq $want })
    if ($keep.Count) { $ListManageCats.SelectedItem = $keep[0] }
    elseif ($rows.Count) { $ListManageCats.SelectedIndex = 0 }
}

function Show-ManageCategories {
    $TxtOverlayTitle.Text = 'Manage categories'
    $TxtOverlayBody.Text = (
        'Order here is the order a technician reads on the client. It is kept separate from ' +
        'the order applications install in, so moving a category can never reorder an install.')
    Update-ManageList
    Hide-OverlayBodies
    $OverlayManage.Visibility = 'Visible'
    $BtnOverlayCancel.Visibility = 'Collapsed'
    $BtnOverlayOk.Content = 'Done'
    $script:ConfirmAction = $null
    $Overlay.Visibility = 'Visible'
}

$BtnCatManage.Add_Click({ Invoke-Guarded { Show-ManageCategories } 'Manage categories' })

# ---------------------------------------------------------------- the drawer
#
# Three widths, and the tab moves between them. Shut hands the grid the whole window; peek is
# the panel as designed; open pulls it out over the grid so the after-install builder can sit
# beside the fields instead of underneath them.
#
# Its contents are not this file's business beyond loading them: Show-AppDialog builds a fresh
# tree per application and DrawerHost holds it, so selecting another app throws the old tree
# away and its handlers with it.
$script:InspApp        = $null
$script:DrawerApply    = $null
$script:DrawerOnChange = $null
$script:DrawerOpen     = $false

# Stops whatever the outgoing panel had running - a hash in a runspace, and the timer that
# collects it - before its tree is thrown away.
function Stop-Drawer {
    $old = $DrawerHost.Content
    if ($old -and $old.Tag -and $old.Tag.Stop) { try { & ($old.Tag.Stop) } catch { } }
}

# The drawer floats, so the grid has to be told to get out from under it - otherwise half the
# catalog is simply hidden behind an opaque panel. One column while it is open, because two in
# the space left over is narrower than the names are.
function Set-AppsColumns([int]$n) {
    $ug = Get-DescendantOfType $ListApps ([Windows.Controls.Primitives.UniformGrid])
    if ($ug) { $ug.Columns = $n }
}

function Close-Drawer {
    $script:DrawerOpen = $false
    $DrawerLayer.Visibility = 'Collapsed'
    $AppsScroller.Margin = New-Object Windows.Thickness(0)
    Set-AppsColumns 2
}

function Open-Drawer {
    $script:DrawerOpen = $true
    $DrawerLayer.Visibility = 'Visible'
    $AppsScroller.Margin = New-Object Windows.Thickness(0, 0, 380, 0)
    Set-AppsColumns 1
}

# Loads the selected application into the drawer. Rebuilding the panel for the app it is ALREADY
# showing would throw away the box being typed into - and Update-List runs on every keystroke -
# so that case returns early rather than reloading.
<#
    Put YOUR png in as this application's icon.

    Copied to icons\<id>.png and nothing else - no library, no extraction, no network. The
    catalog keeps no path: the file either sits beside the others under that name or it does
    not, which is one less thing to go stale.
#>
<#
    Any picture in, one 256x256 PNG out.

    PNG is what gets stored, and that is not a preference. The client draws icons with WPF's
    BitmapImage, which decodes PNG, JPEG, BMP, GIF and TIFF on every Windows 10/11 with nothing
    installed. SVG it cannot read at all - there is no vector rasteriser in WPF. WebP needs a
    codec that ships as an optional Store component, so it may decode on the machine building
    the catalog and fail on a client, which is the worst kind of difference. PNG also keeps
    transparency, which a tile on a dark card needs, and is lossless so a logo stays crisp.

    256 square because that is what Windows itself uses for a large icon, and it is small enough
    that a whole catalog of them costs less than one installer.
#>
# Does this picture carry real transparency? The pixel format has to admit an alpha channel at
# all, and then a scattering of rows is scanned for a pixel that actually uses it - plenty of
# JPEGs decode into a format with alpha and then leave every byte at 255. Rows are read straight
# off the converted source: scaling it down first needed a frozen bitmap, threw, and every
# photograph came back "transparent" and got padded instead of filled.
function Test-ImageHasAlpha($Frame) {
    try {
        $conv = New-Object Windows.Media.Imaging.FormatConvertedBitmap
        $conv.BeginInit()
        $conv.Source            = $Frame
        $conv.DestinationFormat = [Windows.Media.PixelFormats]::Bgra32
        $conv.EndInit()
        $w = $conv.PixelWidth; $h = $conv.PixelHeight
        if ($w -lt 1 -or $h -lt 1) { return $true }
        $stride = $w * 4
        $row = New-Object byte[] $stride
        $step = [Math]::Max(1, [int]($h / 48))
        for ($y = 0; $y -lt $h; $y += $step) {
            $conv.CopyPixels((New-Object Windows.Int32Rect(0, $y, $w, 1)), $row, $stride, 0)
            for ($i = 3; $i -lt $stride; $i += 4) { if ($row[$i] -lt 250) { return $true } }
        }
        return $false
    } catch { return $true }   # unreadable alpha: pad rather than crop, which never cuts artwork
}

function Convert-ImageToIcon([string]$Source, [string]$Destination, [int]$Size = 256) {
    $frame = $null
    try {
        # An .ico holds several sizes; take the biggest rather than whatever comes first.
        $dec = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$Source,
                   [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                   [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = @($dec.Frames) | Sort-Object { $_.PixelWidth * $_.PixelHeight } | Select-Object -Last 1
    } catch {
        return "That file could not be read as an image - $($_.Exception.Message)"
    }
    if (-not $frame) { return 'That file contains no image.' }

    # A picture is made to LOOK like an icon; a logo is left alone.
    #
    # Fitting everything inside the square was wrong for photographs: a 400x300 screenshot became
    # a thin strip floating in an empty tile. So anything opaque - a JPEG, a photo, a screenshot -
    # is centre-cropped until it fills the square, the way a real app icon does. Artwork that
    # carries transparency keeps its shape and its padding, because on a logo that space is
    # deliberate and cropping into it would cut the mark. A square source is identical either way.
    $transparent = Test-ImageHasAlpha $frame
    if ($transparent) {
        $scale = [Math]::Min($Size / [double]$frame.PixelWidth, $Size / [double]$frame.PixelHeight)
    } else {
        $scale = [Math]::Max($Size / [double]$frame.PixelWidth, $Size / [double]$frame.PixelHeight)
    }
    $w = [Math]::Max(1, [int][Math]::Round($frame.PixelWidth * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($frame.PixelHeight * $scale))
    # Negative when filling - that is the crop, taken evenly off both sides.
    $x = [int](($Size - $w) / 2)
    $y = [int](($Size - $h) / 2)

    $visual = New-Object Windows.Media.DrawingVisual
    $ctx = $visual.RenderOpen()
    try {
        $ctx.DrawImage($frame, (New-Object Windows.Rect($x, $y, $w, $h)))
    } finally { $ctx.Close() }

    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
               $Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    # Says what is wrong instead of throwing a stack trace at you. The editor no longer holds its
    # own icons open, but an image viewer or an explorer preview still can.
    try {
        # encode to a .tmp and promote: File::Create truncates immediately, so a failure inside
        # the encoder used to leave a 0-byte png where a good icon had been - the tile silently
        # fell back to the letter mark as if the app never had artwork
        $tmp = "$Destination.tmp"
        $fs = [IO.File]::Create($tmp)
        try { $enc.Save($fs) } finally { $fs.Close() }
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    } catch {
        try { if (Test-Path -LiteralPath "$Destination.tmp") { Remove-Item -LiteralPath "$Destination.tmp" -Force } } catch { }
        return "$([IO.Path]::GetFileName($Destination)) could not be written - it is open in another program. Close it and pick again."
    }
    return ''
}

function Set-AppIconFromFile($App, $Panel) {
    $id = [string](Get-Field $App 'id')
    if (-not $id) { Set-StatusText 'Give the application a name first, so it has an id.' '#FFFBBF24'; return }
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Title  = "Pick a picture for $([string](Get-Field $App 'name'))"
    $d.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.ico;*.webp|All files|*.*'
    if ($d.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $dest = Join-Path $script:IconDir "$id.png"
    # Converted, not copied: whatever you picked becomes a 256x256 PNG, so a 3000px JPEG
    # screenshot and a 48px bitmap both end up as the same kind of tile.
    $why = Convert-ImageToIcon $d.FileName $dest
    if ($why) { Set-StatusText $why '#FFFBBF24'; return }
    if ($Panel -and $Panel.Tag -and $Panel.Tag.PaintIcon) { & ($Panel.Tag.PaintIcon) }
    Update-List
    $again = @($ListApps.Items | Where-Object { $_.App -eq $App })
    if ($again.Count) { $ListApps.SelectedItem = $again[0] }
    Set-CatalogDirty
    Set-StatusText "Icon set for $([string](Get-Field $App 'name')). Update... uploads it with everything else."
}

function Update-Inspector {
    $row = $ListApps.SelectedItem
    # A rebuild deselects for an instant. That is not the person closing the drawer, and tearing
    # it down here is what made picking an icon shut the panel you picked it from.
    if (-not $row -and $script:RebuildingList) { return }
    if (-not $row) { Stop-Drawer; $script:InspApp = $null; $DrawerHost.Content = $null; Close-Drawer; return }
    $a = $row.App
    if ($script:InspApp -eq $a -and $DrawerHost.Content) { return }
    Stop-Drawer
    $script:InspApp = $a
    # An edit can rename the app or move it to another category, so the rail counts and the card
    # underneath are rebuilt - and the selection is put back on the same object, by identity
    # rather than by index, so the drawer is never swapped out from under the cursor.
    $script:DrawerOnChange = {
        # The sidecar learns about a picked file HERE, main-window side - the dialog itself
        # stays deliberately sidecar-free (Test-Push pins that seam), and until tonight
        # NOTHING called Save-AppSources, so one save stripped _localFile and Push reported
        # "no installer on this machine" for a file picked minutes earlier. Persisted only on
        # a real change, or a keystroke in the Name box would rewrite the sidecar per key.
        $sa = $script:InspApp
        if ($sa) {
            $lf = [string](Get-Field $sa '_localFile')
            if ($lf) {
                $e = Get-PushStateFor $sa
                $sh = [string](Get-Field $sa 'sha256')
                if ($e -and (([string]$e.localPath -ne $lf) -or
                             ((Test-RealHash $sh) -and [string]$e.sha256 -ne $sh))) {
                    Save-AppSources $sa
                    if (Test-RealHash $sh) { Set-PushHashFor $sa $sh ([long](Get-Field $sa 'sizeBytes')) }
                }
            }
        }
        # Debounced: a burst of typing is ONE rebuild, 180ms after the last keystroke, instead
        # of one per character. The re-select that used to sit here is gone deliberately -
        # Update-List now restores the selection by identity itself, so the drawer's own copy
        # was doing the same job twice, and it cannot run against a deferred refresh anyway.
        Request-ListRefresh
    }
    $DrawerHost.Content = Show-AppDialog $a $window (Get-LocalFileFor $a)
    # Handed to the panel as well. The drawer cannot reach a $script: variable from inside its
    # own closures, so this is the copy it actually calls when you rename or recategorise.
    if ($DrawerHost.Content -and $DrawerHost.Content.Tag) {
        $DrawerHost.Content.Tag.Fn.onChange = $script:DrawerOnChange
    }
    # The step list keeps its own wheel until it runs out of list, then hands the turn to the
    # drawer. Wired here rather than inside Show-AppDialog so that function stays liftable.
    $panel = $DrawerHost.Content
    if ($panel) {
        Add-WheelForwarding $panel.FindName('DlgPostList') $panel.FindName('DlgScroll') -OnlyAtEdge
        # Wired from the window, not from inside Show-AppDialog, so that function stays liftable
        # by the harnesses. It copies YOUR png in - nothing is fetched, generated or extracted.
        $pick = $panel.FindName('DlgIconPick')
        if ($pick) { $pick.Add_Click({ Invoke-Guarded { Set-AppIconFromFile $a $panel } 'Pick icon' }.GetNewClosure()) }
    }
}

function Get-DescendantOfType($Root, [type]$Type) {
    if (-not $Root) { return $null }
    $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for ($i = 0; $i -lt $n; $i++) {
        $ch = [Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
        if ($Type.IsInstanceOfType($ch)) { return $ch }
        $deep = Get-DescendantOfType $ch $Type
        if ($deep) { return $deep }
    }
    return $null
}

# A ListBox marks the mouse wheel HANDLED even when its own scrolling is switched off, so a
# list sitting inside a scroller silently eats every wheel turn over it. Over the card area that
# is the whole middle of the window, which is why nothing moved. Hand the wheel to the scroller
# that is actually supposed to take it.
#
# -OnlyAtEdge is for a list that genuinely scrolls itself: it keeps its own wheel until it runs
# out of list, and only then passes the turn upwards.
function Add-WheelForwarding($Inner, $Target, [switch]$OnlyAtEdge) {
    $atEdgeOnly = [bool]$OnlyAtEdge
    $Inner.Add_PreviewMouseWheel({ param($src, $e)
        if ($atEdgeOnly) {
            $sv = Get-DescendantOfType $Inner ([Windows.Controls.ScrollViewer])
            if ($sv) {
                $up   = $e.Delta -gt 0
                $atTop = $sv.VerticalOffset -le 0.5
                $atEnd = $sv.VerticalOffset -ge ($sv.ScrollableHeight - 0.5)
                if (($up -and -not $atTop) -or ((-not $up) -and -not $atEnd)) { return }
            }
        }
        if (-not $Target) { return }
        $e.Handled = $true
        $fwd = New-Object Windows.Input.MouseWheelEventArgs($e.MouseDevice, $e.Timestamp, $e.Delta)
        $fwd.RoutedEvent = [Windows.UIElement]::MouseWheelEvent
        $fwd.Source = $Inner
        $Target.RaiseEvent($fwd)
    }.GetNewClosure())
}

function Get-AncestorOfType($Start, [type]$Type) {
    $d = $Start
    while ($d) {
        if ($Type.IsInstanceOfType($d)) { return $d }
        $d = $(if ($d -is [Windows.Media.Visual] -or $d -is [Windows.Media.Media3D.Visual3D]) {
                   [Windows.Media.VisualTreeHelper]::GetParent($d)
               } else { $null })
    }
    return $null
}

# One click, three outcomes - and the ORDER is what makes it read right. This is a preview
# handler, so it runs before selection changes: clicking the open app shuts the drawer and no
# selection change follows, while clicking a different one shuts it and the selection reopens it.
$ListApps.Add_PreviewMouseLeftButtonDown({ param($src, $e) Invoke-Guarded {
    $item = Get-AncestorOfType $e.OriginalSource ([Windows.Controls.ListBoxItem])
    if (-not $item) { return }
    $row = $item.DataContext
    if ($script:DrawerOpen -and $ListApps.SelectedItem -eq $row) {
        Close-Drawer
        $e.Handled = $true
        return
    }
    $ListApps.SelectedItem = $row
    Update-Inspector
    Open-Drawer
} 'Open application' })

Add-WheelForwarding $ListApps $AppsScroller
Add-WheelForwarding $ListManageCats $null -OnlyAtEdge

$ListApps.Add_SelectionChanged({ Invoke-Guarded { Update-Inspector } 'Select application' })

# Clicking anywhere that is not the drawer shuts it. ListApps is excluded because the handler
# above has already decided what that click means.
$window.Add_PreviewMouseLeftButtonDown({ param($src, $e) Invoke-Guarded {
    if (-not $script:DrawerOpen) { return }
    if (Get-AncestorOfType $e.OriginalSource ([Windows.Controls.ListBox])) { return }
    # the title bar is for moving the window, not for dismissing things
    $d0 = $e.OriginalSource
    while ($d0) {
        if ($d0 -eq $TitleBar) { return }
        $d0 = $(if ($d0 -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($d0) } else { $null })
    }
    if (Get-AncestorOfType $e.OriginalSource ([Windows.Controls.ContentControl])) { return }
    $d = $e.OriginalSource
    while ($d) {
        if ($d -eq $DrawerPanel) { return }
        $d = $(if ($d -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($d) } else { $null })
    }
    Close-Drawer
} 'Close drawer' })

# ---------------------------------------------------------------- icon library
#
# dashboardicons.com, by name. Apache-2.0, about 4,100 icons, and it covers the half of the
# icon problem extraction cannot: nobody publishes a Revit or a Chaos Corona logo, but equally
# nothing carries a decent Chrome or Zoom icon except a library. Measured against THIS catalog
# it has 3 of 19 - and 11 of the 15 apps a technician adds most often, which is what it is for.
#
# A picked icon is DOWNLOADED and rehosted on your own bucket, never hot-linked: no client
# machine should depend on GitHub being up, and the artwork must not change under you.






$BtnDuplicate.Add_Click({ Invoke-Guarded {
    $a = $script:InspApp
    if (-not $a) { return }
    $copy = ConvertFrom-Json (ConvertTo-Json $a -Depth 10)
    $base = [string](Get-Field $a 'id')
    if (-not $base) { $base = 'app' }
    $n = 2
    while (@($script:Catalog.apps | Where-Object { [string](Get-Field $_ 'id') -eq "$base-$n" }).Count) { $n++ }
    Set-Field $copy 'id' "$base-$n"
    Set-Field $copy 'name' ("$([string](Get-Field $a 'name')) (copy)")
    # The copy must NOT inherit the original's proof of upload: it is a different key in the
    # bucket, and claiming otherwise would have Push skip a file that is not there.
    Set-Field $copy 'url' ''
    Set-Field $copy 'sha256' ''
    # Nor the original's local file: the sidecar's rename re-key matches by path+size, and a
    # copy carrying the same _localFile made the next Push steal the ORIGINAL's upload record.
    Remove-Field $copy '_localFile'
    $script:Catalog.apps = @(@($script:Catalog.apps) + $copy)
    Set-CatalogDirty
    Update-Categories
    Update-List
    $new = @($ListApps.Items | Where-Object { $_.App -eq $copy })
    if ($new.Count) { $ListApps.SelectedItem = $new[0] }
    Set-StatusText "Duplicated as $([string](Get-Field $copy 'id')). Give it its own package before publishing."
} 'Duplicate' })

# ---------------------------------------------------------------- icons
#
# Yours, by hand. The editor neither generates nor fetches artwork: an icon is whatever PNG sits
# at icons\<id>.png, put there with the Pick a PNG button or copied in yourself. A library
# search was built against dashboardicons and taken out again - it matched 6 of the 19 apps
# here and half of those were coincidences, and nothing carries Revit, Civil 3D, Photoshop,
# Illustrator, InDesign, DIALux, Corona or WinRAR, which is most of this catalog.




# ---------------------------------------------------------------- window chrome
#
# WindowStyle=None, exactly as AppDeploy.ps1 does it, so the two windows read as one product.
# The cost is that dragging, minimising and closing all become ours to provide.
# Preview, not the bubbling event, and it must stay that way. The window-level handler below
# shuts the drawer on any outside click, and shutting it re-columns the grid and moves the
# scroller - a layout pass in the middle of a button-down, after which DragMove has nothing to
# drag and throws into the empty catch. Claiming the click here first is what makes the window
# movable at all. Buttons in the title bar are skipped, or minimise would start a drag.
# Moving the window is done by telling Windows the click landed on a caption, rather than by
# asking WPF to do it for us.
#
# $window.DragMove() is the obvious way and it does not work here. It is particular about the
# combination of WindowStyle=None, AllowsTransparency and ResizeMode, and about what handled the
# button-down first - and when it declines it throws, which an empty catch then hid. Two
# attempts at fixing the WPF side both failed.
#
# ReleaseCapture + WM_NCLBUTTONDOWN/HTCAPTION is what a title bar actually IS: it hands the drag
# to the window manager, which then owns it. Snapping, drag-to-edge and double-click-maximise
# come free, and none of it depends on WPF's opinion of the window chrome.

# Moving the window, by hand.
#
# Three attempts failed before this one: DragMove() on the bubbling event, DragMove() after
# changing ResizeMode, and the Win32 caption trick. Every one of them depends on something
# outside this code agreeing - WPF's chrome handling, or the window manager - and when they
# decline they do it silently, or by throwing into a catch.
#
# This asks nobody. It records where in the title bar the grab started, captures the mouse, and
# moves the window so that point stays under the cursor. There is nothing left to refuse.
#
# The state is a hashtable CAPTURED BY THE HANDLERS, not a $script: variable. $script: has been
# unreliable from inside scriptblocks throughout this file - it is what emptied the hashing
# worker and what stopped the unsaved-changes flag arming - and a drag that silently reads $null
# would look exactly like a window that will not move. A closure captures the hashtable by
# reference, so every handler writes to the same one.
$dragState = @{ Dragging = $false; StartX = 0; StartY = 0; StartLeft = 0; StartTop = 0
                ScaleX = 1.0; ScaleY = 1.0 }

# Opt-in trace: set PC2GO_DRAG_LOG to a path and every grab is recorded there. Off by default,
# because a window that works has nothing to say.
function Write-DragLog([string]$Text) {
    if (-not $env:PC2GO_DRAG_LOG) { return }
    try { Add-Content -LiteralPath $env:PC2GO_DRAG_LOG `
                      -Value "$([DateTime]::Now.ToString('HH:mm:ss.fff'))  $Text" } catch { }
}

# DEVICE PIXELS AND DIPS ARE NOT THE SAME NUMBER, and mixing them is what sent the window off the
# right-hand edge of the screen. The cursor is reported in device pixels; Window.Left and .Top
# are device-independent units. On a 150% display every movement was therefore multiplied by 1.5
# and the window ran away faster than the mouse. Divide by the display's own scale and they agree.
function Get-DisplayScale {
    $out = @{ X = 1.0; Y = 1.0 }
    try {
        $src = [Windows.PresentationSource]::FromVisual($window)
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformToDevice
            if ($m.M11 -gt 0) { $out.X = $m.M11 }
            if ($m.M22 -gt 0) { $out.Y = $m.M22 }
        }
    } catch { }
    return $out
}

# Never off the edge. A window that cannot be seen cannot be dragged back, which is exactly how
# it was lost - so a strip of the title bar is always kept on some screen.
function Set-WindowPositionClamped([double]$Left, [double]$Top) {
    $sc = Get-DisplayScale
    $vx = [Windows.Forms.SystemInformation]::VirtualScreen
    $minX = ($vx.Left   / $sc.X) - ($window.Width  - 120)
    $maxX = ($vx.Right  / $sc.X) - 120
    $minY = ($vx.Top    / $sc.Y)
    $maxY = ($vx.Bottom / $sc.Y) - 40
    $window.Left = [Math]::Max($minX, [Math]::Min($maxX, $Left))
    $window.Top  = [Math]::Max($minY, [Math]::Min($maxY, $Top))
}

$TitleBar.Add_PreviewMouseLeftButtonDown({ param($src, $e)
    Write-DragLog "down on $($e.OriginalSource.GetType().Name)"
    # minimise, close and the search box are controls, not somewhere to grab
    if (Get-AncestorOfType $e.OriginalSource ([Windows.Controls.Primitives.ButtonBase])) { Write-DragLog 'ignored: button'; return }
    if (Get-AncestorOfType $e.OriginalSource ([Windows.Controls.TextBox]))               { Write-DragLog 'ignored: textbox'; return }
    # The cursor is read from the SYSTEM, not through the window. Reading it relative to an
    # element that is itself being moved is self-referential and drifts.
    $c0 = [Windows.Forms.Cursor]::Position
    $sc = Get-DisplayScale
    $dragState.StartX    = [double]$c0.X
    $dragState.StartY    = [double]$c0.Y
    $dragState.StartLeft = [double]$window.Left
    $dragState.StartTop  = [double]$window.Top
    $dragState.ScaleX    = [double]$sc.X
    $dragState.ScaleY    = [double]$sc.Y
    $dragState.Dragging  = $true
    [void]$TitleBar.CaptureMouse()
    Write-DragLog "grab cursor=$($c0.X),$($c0.Y) window=$($window.Left),$($window.Top) scale=$($sc.X)"
}.GetNewClosure())

$TitleBar.Add_PreviewMouseMove({ param($src, $e)
    if (-not $dragState.Dragging) { return }
    if ($e.LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) {
        $dragState.Dragging = $false
        $TitleBar.ReleaseMouseCapture()
        return
    }
    try {
        $c = [Windows.Forms.Cursor]::Position
        $dx = ([double]$c.X - $dragState.StartX) / $dragState.ScaleX
        $dy = ([double]$c.Y - $dragState.StartY) / $dragState.ScaleY
        Set-WindowPositionClamped ($dragState.StartLeft + $dx) ($dragState.StartTop + $dy)
    } catch {
        Write-DragLog "move failed: $($_.Exception.Message)"
        Set-StatusText "The window could not be moved: $($_.Exception.Message)" '#FFFBBF24'
        $dragState.Dragging = $false
        $TitleBar.ReleaseMouseCapture()
    }
}.GetNewClosure())

$TitleBar.Add_PreviewMouseLeftButtonUp({ param($src, $e)
    if ($dragState.Dragging) { Write-DragLog "released at $($window.Left),$($window.Top)" }
    $dragState.Dragging = $false
    $TitleBar.ReleaseMouseCapture()
}.GetNewClosure())

# Guarded like everything else. A throw out of a bare handler takes the whole window down with
# nothing left to read, and the close button is the worst place for that to happen - it is the
# one press where losing the window looks like it worked.
$BtnMin.Add_Click({ Invoke-Guarded { $window.WindowState = 'Minimized' } 'Minimise' -Quiet })
$BtnWinClose.Add_Click({ Invoke-Guarded { $window.Close() } 'Close' -Quiet })

$TxtSearch.Add_TextChanged({ Invoke-Guarded {
    $script:SearchText = (Get-BoxText $TxtSearch)
    $TxtSearchHint.Visibility = $(if ($script:SearchText) { 'Collapsed' } else { 'Visible' })
    Request-ListRefresh
} 'Search' -Quiet })

# The ghost row is the same action as the toolbar button, so it raises that button rather than
# being a second copy of the handler that can drift from it.
$GhostAdd.Add_Click({ Invoke-Guarded { $BtnAdd.RaiseEvent(
    (New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } 'Add' })


# The "Re-publish only" button is gone. Publishing WITHOUT uploading is still reachable and is
# now DECIDED rather than chosen: Start-PublishOnly runs by itself whenever every ready
# installer is already in R2, which was the only case that button existed for.
# ---------------------------------------------------------------- push
#
# Publish uploads three small files and deploys the Worker. Push is the step before it that
# never existed: getting the installers themselves into the bucket. Until now that was an
# rclone job done by hand, which is why sixteen of the seventeen apps still carry
# REPLACE_WITH_REAL_SHA256 - nothing had ever put the bytes somewhere to hash them against.

$script:PushJob    = $null
$script:PushHandle = $null
$script:PushPlan   = @()
$script:PushIcons  = @()
$script:R2Cred     = $null
$script:PrePushPin = ''
$script:PublishProc = $null
$script:PublishStarted = $null
$script:PublishPolls = 0
$script:PublishLog  = ''
$script:PushSamples = New-Object Collections.ArrayList

# Shared with the upload runspace. It must be a synchronized hashtable and not a bare @{} -
# two threads writing a plain Hashtable can corrupt its bucket array. The ArrayLists are
# synchronized for the same reason; the runspace appends to them while the timer reads.
$script:PushProgress = [hashtable]::Synchronized(@{
    Cancel = $false; Phase = 'idle'
    AppId = ''; AppName = ''; AppIndex = 0; AppCount = 0
    AppBytes = [long]0; AppTotal = [long]0; DoneBytes = [long]0; TotalToSend = [long]0
    Part = 0; PartCount = 0
    Done    = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    Skipped = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    Failed  = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    Log     = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    # What the runspace converted, so the catalog and the sidecar can be repointed at the file
    # that actually went up. Reported rather than mutated in place: the plan items belong to the
    # UI thread, and a .rar left named in either place is how a published entry ends up
    # describing a file that is not in the bucket.
    Converted = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    # Icons ride along with the installers rather than needing a separate wrangler run. They are
    # kilobytes next to a 14 GB package, so they are uploaded last and never block anything.
    Icons     = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
})

function Format-Duration([double]$Seconds) {
    if ($Seconds -le 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return 'unknown' }
    $t = [TimeSpan]::FromSeconds([Math]::Min($Seconds, 359999))
    if ($t.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int]$t.TotalHours, $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f [int]$t.TotalMinutes, $t.Seconds) }
    return ('{0}s' -f [int]$t.TotalSeconds)
}

# A rolling 30-second window, not a cumulative average. After a stall, a cumulative figure
# stays wrong for the next hour and the remaining time it implies is worse than no figure.
function Get-PushRate([long]$Sent) {
    $now = Get-Date
    [void]$script:PushSamples.Add(@{ T = $now; B = $Sent })
    while ($script:PushSamples.Count -gt 1 -and
           ($now - $script:PushSamples[0].T).TotalSeconds -gt 30) {
        $script:PushSamples.RemoveAt(0)
    }
    if ($script:PushSamples.Count -lt 2) { return 0.0 }
    $span = ($now - $script:PushSamples[0].T).TotalSeconds
    if ($span -le 0.5) { return 0.0 }
    return (($Sent - $script:PushSamples[0].B) / $span)
}

<#
    What Push would do, worked out from what this machine knows - no network.

    Deciding skip-versus-upload needs the bucket, and asking it 17 times would freeze the window
    for as many round trips, so that decision belongs in the runspace. This only answers the
    question a person has to answer before agreeing: which apps can be pushed at all.
#>
# Every icons\<id>.png that exists, for an app that is actually in the catalog. Nothing is
# generated here - if you have not put a file there, there is nothing to send.
function Get-IconUploads {
    $out = @()
    if (-not $script:IconDir -or -not (Test-Path -LiteralPath $script:IconDir)) { return @($out) }
    foreach ($a in @($script:Catalog.apps)) {
        $id = [string](Get-Field $a 'id')
        if (-not $id) { continue }
        $p = Join-Path $script:IconDir "$id.png"
        if (Test-Path -LiteralPath $p) {
            $out += [pscustomobject]@{ id = $id; key = "icons/$id.png"; path = $p; App = $a }
        }
    }
    return @($out)
}

function New-PushPlan {
    $stalePlan = @()
    $items    = @()
    $noFile   = @()
    $notReady = @()
    foreach ($a in @($script:Catalog.apps)) {
        $name = [string](Get-Field $a 'name')
        $id   = [string](Get-Field $a 'id')
        if (-not $id) { $id = ConvertTo-Id $name }
        $lf   = Get-LocalFileFor $a
        $e    = Get-PushStateFor $a
        $sha  = [string](Get-Field $a 'sha256')

        # An incomplete app is SKIPPED, not fatal. Push used to refuse the entire catalog if any
        # single app was unfinished - a rule borrowed from Publish, where it is right, because
        # one apps.json serves every client at once. Uploading bytes is not like that. A catalog
        # is half-finished for most of its life, and being unable to upload the one application
        # that IS ready until all seventeen are done makes the button useless exactly when it is
        # most wanted.
        $why = Test-App $a
        if ($why.Count) { $notReady += "$name - $($why -join ', ')"; continue }

        if (-not $lf) {
            # No bytes here - but if the sidecar says this exact file was already completed into
            # the bucket, there is nothing to push and nothing to complain about.
            if ($e -and $e.remote -and [string]$e.remote.sha256 -and
                [string]$e.remote.sha256 -eq $sha) { continue }
            $noFile += $name
            continue
        }
        $key = Get-AppKey $a
        if (-not $key) { $noFile += $name; continue }
        # The disk file must still BE the file the catalog hashed. Sizes disagreeing means the
        # bytes changed since Fetch - pushing would upload the NEW bytes under the OLD hash,
        # publish, and every client would download the whole package and reject it. Refused
        # here, where the fix (open it, Fetch again) is one sentence.
        $catSize = [long](Get-Field $a 'sizeBytes')
        if ($catSize -gt 0 -and ([long](Get-Item -LiteralPath $lf).Length) -ne $catSize) {
            $stalePlan += "$name - the file on disk is not the size the catalog hashed; open it and press Fetch again"
            continue
        }
        # A .rar is uploaded as a .zip or it does not work on the fleet.
        #
        # tar.exe ships WITH Windows, so its libarchive version is the OS build's. Before 3.6 it
        # cannot extract many RAR5 archives - measured: identical bytes, 3.8.4 unpacks a 1.1 GB
        # package in 7 seconds, 3.5.2 fails with "Truncated data in huffman tables" after three
        # minutes, on a client, at the end of a long download. The machine BUILDING the catalog
        # has a current tar and never sees it, which is exactly what makes it worth doing here
        # automatically rather than leaving it to be remembered.
        #
        # .iso is deliberately left alone: it is mounted rather than read through tar, so it has
        # none of this problem.
        $convert = ([IO.Path]::GetExtension($lf).ToLower() -eq '.rar')
        $upload  = $lf
        if ($convert) {
            $upload = [IO.Path]::ChangeExtension($lf, '.zip')
            # the key follows the file that actually goes up, not the one on disk now
            $key = "files/$id/$([IO.Path]::GetFileName($upload))"
        }
        $items += [pscustomobject]@{
            id = $id; name = $name; localPath = $lf; key = $key
            sha256 = $sha; sizeBytes = [long](Get-Item -LiteralPath $lf).Length
            remoteVerified = [bool]($e -and $e.remote -and [string]$e.remote.sha256 -eq $sha)
            convert = $convert; convertTo = $upload
            App = $a
        }
    }
    return [pscustomobject]@{ Items = $items; NoFile = $noFile; NotReady = $notReady
                              Stale = @($stalePlan)
                              Converting = @(@($items | Where-Object { $_.convert })).Count
                              Bytes = [long](@($items | Measure-Object -Property sizeBytes -Sum).Sum) }
}

# How many apps the edge would actually serve. The Worker drops anything without a real hash,
# so this is the number a technician would see in the list on a client machine - and if it is
# zero there is nothing worth publishing at all.
function Get-ServableCount {
    return @(@($script:Catalog.apps) | Where-Object { -not (Test-App $_).Count }).Count
}

# Whether every app in the catalog is finished. No longer a gate on publishing - the Worker
# hides the unfinished ones - but it is still what decides the wording, so nobody expects
# seventeen rows to appear on a client when only one is ready.
function Test-CatalogPublishable {
    return (@(@($script:Catalog.apps) | Where-Object { (Test-App $_).Count }).Count -eq 0)
}

function Save-PromptedCredential {
    $acct = ('' + $TxtR2Account.Text).Trim()
    $key  = ('' + $TxtR2Key.Text).Trim()
    $sec  = ('' + $PwdR2Secret.Password).Trim()
    if (-not $acct -or -not $key -or -not $sec) {
        Show-Notice 'Credentials incomplete' 'All three fields are needed before Push can reach R2.'
        return $false
    }

    # Checked HERE, at the keyboard, because the alternative is finding out at push time. An R2
    # access key id is 32 hex characters and its secret is 64; a secret one character short signs
    # every request wrongly and R2 answers SignatureDoesNotMatch - which reads like a permissions
    # problem, sends you back to the dashboard, and is nothing of the kind. That exact
    # 63-character paste cost a round trip once already.
    $bad = @()
    if ($key.Length -ne 32 -or $key -notmatch '^[0-9a-fA-F]+$') {
        $bad += "The access key id is $($key.Length) characters; it should be 32 hexadecimal."
    }
    if ($sec.Length -ne 64 -or $sec -notmatch '^[0-9a-fA-F]+$') {
        $bad += "The secret is $($sec.Length) characters; it should be 64 hexadecimal."
    }
    if ($bad.Count) {
        Show-Notice 'That key pair cannot be right' (
            ($bad -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine +
            'Copy both values again from R2 - Manage R2 API Tokens. The secret is shown once, and ' +
            'it is easy to clip a character off the end.')
        return $false
    }
    $bucket = 'pc2go-apps'
    $toml = Join-Path $script:RepoRoot 'cloudflare\wrangler.toml'
    if (Test-Path -LiteralPath $toml) {
        $m = [regex]::Match((Get-Content -LiteralPath $toml -Raw), 'bucket_name\s*=\s*"([^"]+)"')
        if ($m.Success) { $bucket = $m.Groups[1].Value }
    }
    Save-R2Credential -AccountId $acct -AccessKeyId $key -Secret $sec -Bucket $bucket `
                      -Endpoint $R2Endpoint -Path $R2CredentialPath
    $PwdR2Secret.Password = ''      # not left sitting in a control for the rest of the session
    $script:R2Cred = Get-R2Credential -Path $R2CredentialPath
    return $true
}

function Start-PushConfirm {
    $plan = New-PushPlan
    if (-not $plan.Items.Count) {
        # Everything ready is already in the bucket. That is not "nothing to do" - the catalog
        # still has to reach the edge before any client can see those apps, and telling somebody
        # to go and press a different button for the second half of the job is how a finished
        # upload sits unpublished for a week.
        $n = Get-ServableCount
        Show-Confirm 'Everything is already uploaded' (
            "All $n ready application(s) are already in R2 with a matching size.`r`n`r`n" +
            'Nothing needs uploading, so this will just publish the catalog and redeploy the ' +
            "Worker - which is what makes them visible on a client machine.") 'Publish' { Start-PublishOnly }
        return
    }
    $script:PushPlan = $plan.Items
    $script:PushIcons = @(Get-IconUploads)

    $left = @($plan.NotReady).Count + @($plan.NoFile).Count
    $body = "$($plan.Items.Count) installer(s), $(Format-Size $plan.Bytes), will be checked " +
            "against $($script:R2Cred.Bucket) and uploaded if they are not already there.`r`n`r`n"
    if ($left -gt 0) {
        $body += "$left other app(s) are not ready and will be left alone - nothing about them " +
                 "changes.`r`n`r`n"
    }
    if (@($plan.Stale).Count) {
        # loud and specific: this is the one refusal whose silent version publishes a hash for
        # bytes that are no longer the file
        $body += "REFUSED - the file changed since it was hashed:`r`n  " +
                 (@($plan.Stale) -join "`r`n  ") + "`r`n`r`n"
    }
    if ([int]$plan.Converting -gt 0) {
        # Not a detail to bury: it costs minutes and disk before a byte is sent, and the entry
        # that comes out names a different file from the one on disk now.
        $body += "$($plan.Converting) of them is a .rar and will be rewritten as a .zip first. " +
                 'Windows clients on an older build cannot extract a .rar at all - their tar is ' +
                 "too old - so this is what makes those apps installable.`r`n`r`n"
    }
    $body += 'The window stays usable and Stop is safe - a stopped upload resumes from where it ' +
             "got to rather than starting the file again.`r`n`r`n"
    $body += 'Afterwards the catalog is rewritten with the real URLs and hashes, saved, and published.'
    if (-not (Test-CatalogPublishable)) {
        # Say plainly what "published" means while the catalog is half-finished, so nobody
        # expects seventeen rows to appear on a client machine.
        $body += "`r`n`r`nApplications that are not finished stay hidden: the edge only serves an " +
                 'app once it has a real hash, so an unfinished one is never offered to a technician.'
    }
    Show-Confirm 'Update?' $body 'Update' { Start-Push }
}

<#
    Publish without uploading anything - the case where every ready installer is already in R2.

    It still saves first, because Push rewrites urls and hashes from the bytes that went up and
    those edits may not have been written to disk yet. Publishing a catalog from memory while a
    different one sits on disk is how the live catalog and the repository drift apart.
#>
function Start-PublishOnly {
    # one write path, and it must land BEFORE anything is uploaded
    if (-not (Complete-Save -Force)) { return }
    $PushBar.Visibility = 'Visible'
    $BtnPush.IsEnabled = $false; $BtnSettings.IsEnabled = $false
    $BtnPushCancel.IsEnabled = $false     # a deploy in flight cannot be half-stopped
    $PushProgressBar.Value = 0
    Start-Publish
}

function Start-Push {
    $script:PushProgress.Cancel   = $false
    $script:PushProgress.Phase    = 'upload'
    $script:PushProgress.AppCount = @($script:PushPlan).Count
    $script:PushProgress.DoneBytes   = [long]0
    $script:PushProgress.TotalToSend = [long](@($script:PushPlan | Measure-Object -Property sizeBytes -Sum).Sum)
    $script:PushProgress.Done.Clear(); $script:PushProgress.Skipped.Clear()
    $script:PushProgress.Failed.Clear(); $script:PushProgress.Log.Clear()
    $script:PushProgress.Converted.Clear()
    $script:PushSamples.Clear()

    $PushBar.Visibility = 'Visible'
    $BtnPush.IsEnabled = $false; $BtnSettings.IsEnabled = $false
    # Add/Add folder write the SAME sidecar the push runspace owns for the duration - two
    # writers doing swap-in-place on one file, and the UI side's copy predates the push, so
    # whichever lands last silently discards the other's record. One writer at a time.
    $BtnAdd.IsEnabled = $false; $BtnAddFolder.IsEnabled = $false
    $BtnPushCancel.IsEnabled = $true
    $TxtPushApp.Text = 'Starting...'
    $TxtPushDetail.Text = ''
    $PushProgressBar.Value = 0
    try {
        $window.TaskbarItemInfo = New-Object Windows.Shell.TaskbarItemInfo
        $window.TaskbarItemInfo.ProgressState = 'Normal'
    } catch { }

    # Save the sidecar first: the runspace reads it from disk, so anything only in memory - a
    # file just picked, a hash just computed - would be invisible to the upload.
    Save-PushState

    $script:PushJob = [powershell]::Create()
    [void]$script:PushJob.AddScript($script:PushWork).
           AddArgument($script:R2Module).
           AddArgument($script:PushPlan).
           AddArgument($script:R2Cred).
           AddArgument($script:PushProgress).
           AddArgument($PushStatePath).
           AddArgument([long]0).
           AddArgument((Join-Path $script:ToolsDir 'Convert-PackageToZip.ps1')).
           AddArgument($script:PushIcons)
    $script:PushHandle = $script:PushJob.BeginInvoke()
    $script:PushTimer.Start()
}

function Update-PushBar {
    $p = $script:PushProgress
    $sent = [long]$p.DoneBytes + [long]$p.AppBytes
    $tot  = [long]$p.TotalToSend
    if ($tot -gt 0) { $PushProgressBar.Value = [Math]::Min(1000, (1000.0 * $sent / $tot)) }

    $TxtPushApp.Text = "$($p.AppName)  -  app $($p.AppIndex) of $($p.AppCount)"
    $rate = Get-PushRate $sent
    $eta  = $(if ($rate -gt 1) { Format-Duration (($tot - $sent) / $rate) } else { 'unknown' })
    $part = $(if ([int]$p.PartCount -gt 0) { "part $($p.Part) of $($p.PartCount)   " } else { '' })
    $TxtPushDetail.Text = ("{0}{1} of {2}   -   {3}/s   -   {4} left  |  overall {5} of {6}" -f
        $part, (Format-Size ([long]$p.AppBytes)), (Format-Size ([long]$p.AppTotal)),
        (Format-Size ([long]$rate)), $eta, (Format-Size $sent), (Format-Size $tot))
    try { if ($window.TaskbarItemInfo -and $tot -gt 0) { $window.TaskbarItemInfo.ProgressValue = ($sent / [double]$tot) } } catch { }
}

$script:PushTimer = New-Object Windows.Threading.DispatcherTimer
$script:PushTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:PushTimer.Add_Tick({ Invoke-Guarded {
    # First, and exclusive: a wrangler call borrows this same bar, and Invoke-Wrangler refuses to
    # start while either of the two below is running.
    if ($script:WranglerWatch) { Complete-WranglerCall; return }
    if ($script:PushJob) {
        Update-PushBar
        Request-ListRefresh
        if ($script:PushHandle.IsCompleted) { Complete-Push }
        return
    }
    if ($script:PublishProc) {
        # Ask the edge as well as the process, and let whichever answers first end the wait. The
        # tick is 500ms and this is a 35 KB fetch, so it is throttled to roughly every 3 seconds
        # - and Start-LiveCheck ignores a second call while one is already in flight anyway.
        $script:PublishPolls = [int]$script:PublishPolls + 1
        if (($script:PublishPolls % 6) -eq 0) { try { Start-LiveCheck } catch { } }
        Complete-PinFetch
        Complete-Publish
        # Still here, and long past any plausible deploy? Say so, rather than leaving a progress
        # bar at 0% with no way to tell whether it is working. The publish itself is not
        # cancelled - it may yet finish - but the window stops pretending to know.
        # Last resort only. By here neither the process NOR the edge has reported in ten minutes,
        # which means the publish genuinely has not landed - not merely that one signal was lost.
        if ($script:PublishProc -and $script:PublishStarted -and
            ((Get-Date) - $script:PublishStarted).TotalMinutes -ge 10) {
            $script:PublishProc = $null
            $script:PublishStarted = $null
            Stop-PushUi
            Show-Notice 'The publish has not landed' (
                "Ten minutes, and the edge is still not serving this catalog.`r`n`r`n" +
                'wrangler may be waiting on a Cloudflare sign-in - it opens its own window, and ' +
                "that window is minimised.`r`n`r`n" +
                "Read the log before pushing again: $($script:PublishLog)")
            Set-StatusText 'Not published: the edge is still serving the old catalog. Check the log.' '#FFFBBF24'
        }
    }
} 'Push' -Quiet })

function Stop-PushUi {
    $PushBar.Visibility = 'Collapsed'
    $BtnPush.IsEnabled = $true; $BtnSettings.IsEnabled = $true
    $BtnAdd.IsEnabled = $true; $BtnAddFolder.IsEnabled = $true
    # Cleared here rather than where it is set, so a push that follows a wrangler call cannot
    # inherit an animating bar and report real percentages onto it.
    $PushProgressBar.IsIndeterminate = $false
    $script:PushTimer.Stop()
}

<#
    Rewrite each pushed app from the bytes that actually went up, then save.

    This is where REPLACE_WITH_REAL_SHA256 finally becomes a hash: not typed, not copied from a
    vendor page, but the SHA-256 of the very file that is now in the bucket.
#>
function Update-CatalogFromPush {
    $n = 0
    $done = @{}
    foreach ($d in @($script:PushProgress.Done))    { $done[[string]$d.id] = $true }
    foreach ($d in @($script:PushProgress.Skipped)) { $done[[string]$d.id] = $true }
    foreach ($item in @($script:PushPlan)) {
        if (-not $done.ContainsKey([string]$item.id)) { continue }
        $a = $item.App
        Set-Field $a 'url' "$($BaseUrl.TrimEnd('/'))/$($item.key)"
        if ($item.sha256) { Set-Field $a 'sha256' $item.sha256 }
        Set-Field $a 'sizeBytes' ([long]$item.sizeBytes)
        $n++
    }
    # iconUrl is written only for icons that REALLY went up. Writing it for a file that failed
    # would put a 404 in front of every client, and the client caches what it fetches.
    foreach ($ic in @($script:PushProgress.Icons)) {
        $a = @($script:Catalog.apps | Where-Object { [string](Get-Field $_ 'id') -eq [string]$ic.id })
        if (-not $a.Count) { continue }
        Set-Field $a[0] 'iconUrl' "$($BaseUrl.TrimEnd('/'))/$($ic.key)"
        $n++
    }
    if ($n) { Set-CatalogDirty }
    return $n
}

function Complete-Push {
    try { [void]$script:PushJob.EndInvoke($script:PushHandle) } catch { }
    try { $script:PushJob.Dispose() } catch { }
    $script:PushJob = $null; $script:PushHandle = $null
    $script:PushState = $null          # the runspace owned it on disk; re-read what it wrote

    $p = $script:PushProgress
    $okCount   = @($p.Done).Count
    $skipCount = @($p.Skipped).Count
    $failed    = @($p.Failed)

    if ($p.Phase -eq 'cancelled' -or $p.Cancel) {
        Stop-PushUi
        try { $window.TaskbarItemInfo.ProgressState = 'Paused' } catch { }
        Set-StatusText ("Stopped. $okCount uploaded, $skipCount already there. " +
                        'Pushing again carries on from where it stopped - nothing already uploaded is lost.') '#FFFBBF24'
        Update-List
        return
    }

    if ($failed.Count) {
        Stop-PushUi
        try { $window.TaskbarItemInfo.ProgressState = 'Error' } catch { }
        $lines = (@($failed | ForEach-Object { "  $($_.name) - $($_.reason)" }) -join "`r`n")
        # Nothing is published. A catalog whose URLs name objects that are not in the bucket is
        # the "download 15 GB then refuse it" failure, on every client at once.
        Show-Notice 'Push finished with failures' (
            "$okCount uploaded, $skipCount already in R2, $($failed.Count) failed.`r`n`r`n$lines`r`n`r`n" +
            'Nothing was published: the catalog would name files that are not in the bucket. ' +
            'Push again to carry on - the parts already uploaded are kept.')
        Update-List
        return
    }

    try { $window.TaskbarItemInfo.ProgressState = 'None' } catch { }
    # The sidecar first, and always - it is what the editor re-derives url, hash and size FROM,
    # so a sidecar still naming the .rar makes the next save quietly undo the whole conversion.
    # That has happened once already; it is not a theoretical ordering concern.
    $convCount = 0
    foreach ($cv in @($p.Converted)) {
        $item = @($script:PushPlan | Where-Object { [string]$_.id -eq [string]$cv.id }) | Select-Object -First 1
        if (-not $item) { continue }
        Set-LocalFileFor $item.App ([string]$cv.path) -KeepRemote
        Set-PushHashFor  $item.App ([string]$cv.sha256) ([long]$cv.sizeBytes)
        $convCount++
    }
    $changed = Update-CatalogFromPush
    # Export-Catalog THROWS on failure rather than returning $false, and a throw here escaped
    # into the timer with Stop-PushUi never run - Save and Push stayed disabled forever over a
    # dirty catalog holding the record of a finished multi-GB upload.
    try { [void](Export-Catalog) } catch {
        Set-StatusText "The upload finished but the catalog could not be saved: $($_.Exception.Message). Fix the lock on apps.json and press Save." '#FFF87171'
        Stop-PushUi
        return
    }

    # The catalog is published even when it is only part-finished. It used to be held back until
    # every app was complete, on the grounds that one apps.json serves every client - but the
    # Worker now drops any app without a real hash from what it SERVES, so an unfinished entry
    # is invisible to clients rather than a broken row in front of them. Holding back would mean
    # the applications already uploaded sat unusable for however many weeks the rest took.
    $unfinished = @(@($script:Catalog.apps) | Where-Object { (Test-App $_).Count }).Count
    $note = $(if ($unfinished) { " $unfinished not ready yet - those stay hidden from clients." } else { '' })
    $conv = $(if ($convCount) { " $convCount converted to .zip." } else { '' })
    Set-StatusText "$okCount uploaded, $skipCount already there.$conv $changed rewritten. Publishing...$note" '#FF4C8DFF'
    Start-Publish
}

<#
    Hand off to Publish-Release.ps1 - the real one, not a reimplementation of it.

    In its own console because wrangler can prompt for an OAuth refresh, and polled rather than
    waited on so the window stays alive. The pin currently live is recorded first: if the deploy
    fails after the upload, that value is the only way to say what the edge is still serving.
#>
# What the edge pins RIGHT NOW, fetched in a runspace so the window never waits for it. Its only
# consumer is the message shown when a deploy fails after the upload, where it is the single fact
# that says what clients are still being served.
$script:PinJob    = $null
$script:PinHandle = $null
$script:PinWork   = {
    param($Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $live = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
        return ([regex]::Match($live.Content, "\`$PinnedHash\s*=\s*'([^']*)'")).Groups[1].Value
    } catch { return '' }
}

function Start-PinFetch {
    if ($script:PinJob) { return }
    $script:PinJob = [powershell]::Create()
    [void]$script:PinJob.AddScript($script:PinWork).AddArgument("$($BaseUrl.TrimEnd('/'))/go")
    $script:PinHandle = $script:PinJob.BeginInvoke()
}

function Complete-PinFetch {
    if (-not $script:PinJob -or -not $script:PinHandle.IsCompleted) { return }
    try { $script:PrePushPin = [string]($script:PinJob.EndInvoke($script:PinHandle) | Select-Object -Last 1) }
    catch { $script:PrePushPin = '' }
    try { $script:PinJob.Dispose() } catch { }
    $script:PinJob = $null; $script:PinHandle = $null
}

function Start-Publish {
    $pub = Join-Path $script:ToolsDir 'Publish-Release.ps1'
    if (-not (Test-Path -LiteralPath $pub)) {
        Stop-PushUi
        Show-Notice 'Published nothing' "The installers are in R2, but Publish-Release.ps1 is missing from $($script:ToolsDir)."
        return
    }
    # Off the dispatcher. This used to be a 15-second Invoke-WebRequest on the UI thread, fired at
    # the exact moment the operator had just approved a multi-gigabyte upload - so the window went
    # dead for up to fifteen seconds precisely when they were watching hardest. The pin is only
    # ever read to write one line of an error message, so nothing waits for it; the tick collects
    # it if and when it arrives, and Complete-Publish says "unknown" if it did not.
    $script:PrePushPin = ''
    Start-PinFetch

    $script:PublishLog = Join-Path $env:TEMP "pc2go-publish-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:PublishProc = Start-Process -FilePath $psExe -PassThru -WindowStyle Minimized -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -Command `"& '$pub' -RepoRoot '$($script:RepoRoot)' *> '$($script:PublishLog)'`"")
    $TxtPushApp.Text = 'Publishing the catalog and deploying the Worker...'
    $TxtPushDetail.Text = 'Publish-Release.ps1 is running in its own window.'
    # When it started, so a bar that has not moved can be told apart from work that is simply
    # slow. wrangler can sit waiting on an OAuth refresh in a window that was minimised, which
    # from in here looks identical to a hang.
    $script:PublishStarted = Get-Date
    $script:PublishPolls = 0
    # Discard what was known: it describes the catalog BEFORE this publish, and comparing against
    # it would report success on the very first poll.
    $script:LiveApps = $null
    $script:PushTimer.Start()
}

function Complete-Publish {
    if (-not $script:PublishProc.HasExited) { return }
    $code = $script:PublishProc.ExitCode
    $proc = $script:PublishProc
    $script:PublishProc = $null
    Stop-PushUi

    $log = ''
    if ($script:PublishLog -and (Test-Path -LiteralPath $script:PublishLog)) {
        try { $log = Get-Content -LiteralPath $script:PublishLog -Raw } catch { }
    }

    if ($code -eq 0) {
        Set-StatusText 'Pushed, published and deployed.' '#FF34D399'
        # Ask the edge again. Without this the live dots keep describing whatever was true when
        # the editor opened - wrong at exactly the moment they matter most, which is right after
        # something has been published.
        try { Start-LiveCheck } catch { }
        Update-List
        return
    }

    # The sharp edge. Publish-Release.ps1 uploads the new AppDeploy.ps1 to R2 BEFORE it pins the
    # hash and deploys, so a failure between those two leaves the bucket holding a tool the edge
    # still pins the old hash for - and go.ps1 then refuses to start on every client, with a
    # message that reads exactly like a compromise. Push cannot close that window; it can only
    # say precisely what happened and how to end it.
    if ($log -match 'Uploading to R2' -and $log -match 'Deploying Worker') {
        Show-Notice 'The Worker deploy failed AFTER the files were uploaded' (
            "Every client will now refuse to start with 'AppDeploy.ps1 failed integrity check' " +
            "until this is fixed. The new tool is in R2, but the edge still pins the old one.`r`n`r`n" +
            "Fix it with:`r`n    cd `"$(Join-Path $script:RepoRoot 'cloudflare')`"`r`n    wrangler deploy`r`n`r`n" +
            "Previously live pin: $(if ($script:PrePushPin) { $script:PrePushPin } else { 'unknown' })`r`n`r`n" +
            "The installers you just uploaded are fine and will not need uploading again.`r`n`r`n" +
            "Full log: $($script:PublishLog)")
        try { $window.TaskbarItemInfo.ProgressState = 'Error' } catch { }
        Set-StatusText 'DEPLOY FAILED AFTER UPLOAD - clients cannot start until wrangler deploy succeeds.' '#FFF87171'
        return
    }

    Show-Notice 'Publishing failed' (
        "The installers are in R2 and the catalog was saved, but Publish-Release.ps1 exited with " +
        "code $code, so nothing was published.`r`n`r`nLog: $($script:PublishLog)")
    Set-StatusText 'Uploaded, but not published.' '#FFFBBF24'
}

$BtnPush.Add_Click({ Invoke-Guarded {
    # Every dead end below reports through the overlay. They used to write to the status line,
    # which is one small grey sentence at the bottom of the window - indistinguishable from a
    # button that did nothing at all, which is the exact failure Invoke-Guarded exists to stop.
    if ($script:PushJob -or $script:PublishProc) {
        Show-Notice 'Already running' 'A push is already in progress. Wait for it to finish, or press Stop.'
        return
    }
    if ($script:BulkJob -or $script:BulkQueue.Count) {
        Show-Notice 'Still hashing' (
            'Some applications are still being hashed. Push needs the finished hash to know ' +
            'whether the file is already in R2, so wait for hashing to finish and try again.')
        return
    }
    if (-not (Test-Path -LiteralPath $script:R2Module)) {
        Show-Notice 'Cannot push' "tools\R2-Upload.ps1 is missing, so there is nothing to upload with."
        return
    }

    $plan = New-PushPlan
    # Only a catalog with nothing servable AT ALL is a dead end. With at least one complete app,
    # Push still has work to do even when every byte is already uploaded - publishing the
    # catalog is the job. Refusing here would strand finished uploads in the bucket with no way
    # for a client to reach them, which is exactly the state this button exists to end.
    if (-not $plan.Items.Count -and (Get-ServableCount) -le 0) {
        # Name what is in the way and what each one needs. "16 app(s) are not ready" is not
        # something anyone can act on.
        $lines = @()
        foreach ($t in @($plan.NotReady | Select-Object -First 6)) { $lines += "  $t" }
        foreach ($t in @($plan.NoFile   | Select-Object -First 6)) { $lines += "  $t - no installer on this machine" }
        $extra = (@($plan.NotReady).Count + @($plan.NoFile).Count) - @($lines).Count
        if ($extra -gt 0) { $lines += "  +$extra more" }
        Show-Notice 'Nothing to push yet' (
            "No application is complete, so there is nothing a client could install.`r`n`r`n" +
            ($lines -join "`r`n") + "`r`n`r`n" +
            'Use "Add folder..." to point at the folder your installers live in - each one is ' +
            'hashed automatically - or open an application and use "Use a local file...".')
        return
    }

    $script:R2Cred = $null
    try { $script:R2Cred = Get-R2Credential -Path $R2CredentialPath }
    catch { Show-Notice 'R2 credentials' $_.Exception.Message; return }
    if ($R2Endpoint -and $script:R2Cred) {
        $script:R2Cred = Get-R2CredentialObject -AccountId $script:R2Cred.AccountId `
            -AccessKeyId $script:R2Cred.AccessKeyId -Secret $script:R2Cred.Secret `
            -Bucket $script:R2Cred.Bucket -Endpoint $R2Endpoint
    }
    if (-not $script:R2Cred) {
        # A function call, never an assignment through the closure - a closure carries its own
        # copy of the scope it was made in, and assigning through it does not reach script scope.
        Show-CredentialPrompt { Invoke-Guarded { if (Save-PromptedCredential) { Start-PushConfirm } } 'Save credentials' }
        return
    }
    Start-PushConfirm
} 'Push' })

$BtnPushCancel.Add_Click({ Invoke-Guarded {
    # A wrangler run is killed rather than asked to stop - it has no cancellation point, and the
    # whole tree goes because npx is only a launcher. The verdict is reported by the next tick.
    if ($script:WranglerWatch) {
        $BtnPushCancel.IsEnabled = $false
        $TxtPushDetail.Text = 'Stopping wrangler...'
        Stop-WranglerWatched -Watch $script:WranglerWatch
        return
    }
    $script:PushProgress.Cancel = $true
    $BtnPushCancel.IsEnabled = $false
    $TxtPushDetail.Text = 'Stopping after the current part...'
} 'Stop' })

# Guarded, and it was not. Everything the overlay's OK button does - removing a category,
# saving credentials, downloading an icon - ran here with nothing to catch it, so one throw took
# the whole window down with no message. That is the worst possible failure: the tool vanishes
# mid-edit and there is nothing to read afterwards.
$BtnOverlayOk.Add_Click({ Invoke-Guarded {
    $Overlay.Visibility = 'Collapsed'
    $act = $script:ConfirmAction
    $script:ConfirmAction = $null
    if ($act) { & $act }
} 'Confirm' })
$BtnOverlayCancel.Add_Click({ Invoke-Guarded {
    $Overlay.Visibility = 'Collapsed'; $script:ConfirmAction = $null
} 'Cancel' })

# The backstop. A WPF exception that reaches the dispatcher with nobody handling it terminates
# the process - the window simply disappears, which is exactly what happened here. Nothing this
# tool does is worth losing an unsaved catalog over, so the fault is shown and the window lives.
$window.Dispatcher.Add_UnhandledException({ param($src, $e)
    $e.Handled = $true
    $detail = "$($e.Exception.Message)`r`n`r`n$($e.Exception.StackTrace)"
    # The status line, not a MessageBox, if the overlay itself is what broke. There is exactly
    # one MessageBox in this file - Invoke-Guarded's last resort - and it stays that way: a
    # modal box cannot be driven by a harness and hangs an unattended run for ever.
    try { Show-Notice 'Something went wrong' $detail }
    catch { try { Set-StatusText "Something went wrong: $($e.Exception.Message)" '#FFF87171' } catch { } }
})

# Closing has to decide synchronously - $e.Cancel is read the moment this returns - and an
# overlay answers later, so the close is cancelled and re-issued once the answer arrives.
$script:ForceClose = $false
$window.Add_Closing({
    param($eventSource, $e)
    # Before the dirty check, because pre-rewrite the catalog is often CLEAN mid-push: closing
    # then killed the upload runspace mid-file with no prompt at all.
    if (($script:PushJob -or $script:PublishProc) -and -not $script:ForceClose) {
        $e.Cancel = $true
        Show-Confirm 'A push is still running' (
            'Closing now kills the upload mid-file. Stop is the safe way out - it lets the ' +
            'current part finish so the resume record stays honest.'
        ) 'Close anyway' { $script:ForceClose = $true; $window.Close() }
        return
    }
    # A save that FAILED is the only unsaved-work question worth asking now - everything else
    # autosaves, so the old "you have unsaved changes" modal would be asking about work the
    # window is perfectly capable of writing by itself.
    if ($script:SaveFailed -and -not $script:ForceClose) {
        $e.Cancel = $true
        Show-Confirm 'apps.json could not be written' (
            'The last save failed, so changes since then are only in memory. Closing now loses ' +
            "them.`r`n`r`nThe catalog as it was when you opened the editor is still on disk as " +
            'apps.json.bak.'
        ) 'Close anyway' { $script:ForceClose = $true; $window.Close() }
        return
    }
    # Merely pending: do not ask a question the window can answer. Save, then close.
    if ($script:Dirty -and -not $script:ForceClose) {
        $e.Cancel = $true
        [void](Complete-Save -Force)
        $script:ForceClose = $true
        $window.Close()
    }
})

try { Import-Catalog } catch { Set-StatusText $_.Exception.Message '#FFF87171' }
# Shown only once it is laid out. A transparent window paints before its content is arranged,
# which is why launching flashed a half-built layout before the real one.
# Faded in on Loaded, exactly as AppDeploy.ps1 does it. Revealing on ContentRendered showed a
# frame of the window before its content had settled, which is the flicker on launch.
$window.Add_Loaded({
    try {
        $dur  = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220))
        $fade = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, $dur
        $window.BeginAnimation([Windows.Window]::OpacityProperty, $fade)
    } catch { $window.Opacity = 1 }
})
# After the catalog is on screen, never before: the window has to come up first, and a slow or
# unreachable edge must not be able to hold it hostage.
try { Start-LiveCheck } catch { }
[void]$window.ShowDialog()
