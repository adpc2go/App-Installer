<#
.SYNOPSIS
    Rewrites a .rar or .iso package as a .zip the client can actually open.

.DESCRIPTION
    tar.exe ships WITH Windows, so its libarchive version is the OS build's and cannot be
    updated on its own. libarchive before 3.6 cannot extract many RAR5 archives: measured on one
    1.1 GB package, libarchive 3.8.4 extracted it in 7 seconds and libarchive 3.5.2 - a stock
    Windows 10 build still in the field - failed with "Truncated data in huffman tables". The
    bytes were identical, and their sha256 had already been verified before unpacking began.

    So .rar is the wrong container for a fleet, and the failure is invisible on the machine that
    BUILDS the catalog, because that machine has a current tar. A .zip written with Deflate is
    read by .NET directly and never reaches tar at all.

    The conversion is verified rather than assumed: every file that came out of the source has
    to be in the .zip at the same length, with nothing extra, or the .zip is deleted and nothing
    is published. -Exclude drops paths on the way through, which is how a package gets published
    without something that was only ever inside it for testing.

.PARAMETER Path
    The .rar, .iso or .zip to convert.

.PARAMETER Destination
    The .zip to write. Defaults to the source's own name with a .zip extension, beside it.

.PARAMETER Exclude
    Wildcard patterns, matched against each entry's path INSIDE the package. A pattern with no
    wildcard matches that path or anything beneath it, so -Exclude 'Tools' drops 'Tools\a.exe'.

.PARAMETER AddFrom
    Files or folders on this machine to fold INTO the package before it is zipped. A vendor
    installer does not ship your logo, your licence file or your configured .ini, so the
    after-install steps have nothing to copy from unless they are put in here first. A folder
    keeps its structure; a file lands directly under -AddInto.

.PARAMETER AddInto
    The folder inside the package that -AddFrom lands in. Defaults to "PostInstall", so a step
    refers to "PostInstall\logo.ico" no matter what the vendor's own folders are called. Pass ''
    to add at the top level.

.PARAMETER WorkDir
    Where to unpack while converting. Defaults to a new folder under $env:TEMP, removed
    afterwards. Needs room for the unpacked contents AND the new .zip.

.PARAMETER Force
    Overwrite an existing destination.

.EXAMPLE
    .\tools\Convert-PackageToZip.ps1 -Path 'C:\Apps\Thing 1.2.3.rar'

.EXAMPLE
    .\tools\Convert-PackageToZip.ps1 -Path 'C:\Apps\Suite.rar' -Exclude 'Extras', '*.nfo'
    Converts, leaving the Extras folder and any .nfo files out of what gets published.

.EXAMPLE
    .\tools\Convert-PackageToZip.ps1 -Path 'C:\Apps\Suite.rar' -AddFrom 'C:\Branding'
    Folds everything in C:\Branding into the package as PostInstall\..., ready for an
    after-install step to copy into the install folder. The list it prints at the end is what
    the editor's "from" dropdown will offer.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Destination,
    [string[]]$Exclude = @(),
    [string[]]$AddFrom = @(),
    [string]$AddInto = 'PostInstall',
    [string]$WorkDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Step([string]$T) { Write-Host "==> $T" -ForegroundColor Cyan }
function Write-Ok  ([string]$T) { Write-Host "  + $T" -ForegroundColor Green }
function Write-Warn([string]$T) { Write-Host "  ! $T" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $Path)) { throw "No such file: $Path" }
$src = Get-Item -LiteralPath $Path
$ext = $src.Extension.ToLower()
if ($ext -notin '.rar', '.iso', '.zip') { throw "Only .rar, .iso and .zip can be converted; this is $ext" }

if (-not $Destination) {
    $Destination = Join-Path $src.DirectoryName ([IO.Path]::GetFileNameWithoutExtension($src.Name) + '.zip')
}
$destResolved = ''
try { $destResolved = (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).Path } catch { }
if ($destResolved -and $destResolved -eq (Resolve-Path -LiteralPath $src.FullName).Path) {
    throw 'The destination is the source. Give -Destination a different name.'
}
if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
    throw "$Destination already exists. Pass -Force to replace it."
}

# A pattern with no wildcard means "this path, or anything under it" - otherwise -Exclude 'Extras'
# would silently keep every file inside Extras, which is the opposite of what was asked for.
function Test-Excluded([string]$Rel) {
    foreach ($pat in @($Exclude)) {
        if (-not $pat) { continue }
        if ($Rel -like $pat) { return $true }
        if ($pat -notmatch '[\*\?]' -and ($Rel -like "$pat\*")) { return $true }
    }
    return $false
}

$tmpRoot = $WorkDir
if (-not $tmpRoot) { $tmpRoot = Join-Path $env:TEMP ('pkgconv-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
$unpacked = Join-Path $tmpRoot 'unpacked'
$ownWork = -not $WorkDir
New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
$mounted = $false

try {
    # ---------------------------------------------------------------- 1. read the source
    Write-Step "Reading $($src.Name)  ($('{0:N0}' -f $src.Length) bytes)"

    if ($ext -eq '.iso') {
        # Mounted, never read with tar: on an image with no Joliet extension tar falls back to
        # raw ISO9660 and truncates every name to 31 characters, which hands an installer paths
        # that do not exist. Same reasoning as the catalog editor's reader.
        $img = Get-DiskImage -ImagePath $src.FullName -ErrorAction SilentlyContinue
        if (-not ($img -and $img.Attached)) {
            $img = Mount-DiskImage -ImagePath $src.FullName -Access ReadOnly -PassThru -ErrorAction Stop
            $mounted = $true
        }
        $root = ''
        for ($i = 0; $i -lt 40 -and -not $root; $i++) {
            Start-Sleep -Milliseconds 250
            $v = Get-Volume -DiskImage $img -ErrorAction SilentlyContinue
            if ($v -and $v.DriveLetter) { $root = "$($v.DriveLetter):\" }
        }
        if (-not $root) { throw 'the image mounted but Windows gave it no drive letter' }
        Write-Ok "mounted read-only at $root"
        foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($root.Length)
            if (Test-Excluded $rel) { continue }
            $to = Join-Path $unpacked $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $to -Force
        }
    }
    else {
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tar)) { throw 'tar.exe is missing from System32' }
        $tv = ''
        try { $tv = ([string](& $tar --version 2>$null | Select-Object -First 1)).Trim() } catch { }
        Write-Ok "using $tv"
        # The machine doing the CONVERSION needs a tar that can read the source - which is
        # exactly the version the failing clients do not have.
        if ($ext -eq '.rar' -and $tv -match 'libarchive (\d+)\.(\d+)') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            if ($maj -lt 3 -or ($maj -eq 3 -and $min -lt 6)) {
                Write-Warn "this machine's libarchive is older than 3.6, so it may not read the .rar either"
            }
        }
        $errLog = Join-Path $tmpRoot 'tar.err'
        $tp = Start-Process -FilePath $tar -ArgumentList @('-xf', "`"$($src.FullName)`"", '-C', "`"$unpacked`"") `
                            -Wait -PassThru -WindowStyle Hidden -RedirectStandardError $errLog
        $why = @(Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and $_ -notmatch 'Error exit delayed' })
        if ($tp.ExitCode -ne 0) {
            throw ("could not unpack the source - tar exited $($tp.ExitCode)" +
                   $(if ($why.Count) { " - $($why[0])" } else { '' }))
        }
        if ($why.Count) { Write-Warn "tar reported: $($why[0])" }
    }

    # ---------------------------------------------------------------- 2. exclusions
    $all = @(Get-ChildItem -LiteralPath $unpacked -File -Recurse -Force -ErrorAction SilentlyContinue)
    if (-not $all.Count) { throw 'nothing came out of the package' }
    # Get-Item, NOT Resolve-Path. Resolve-Path hands the path back as it was WRITTEN, 8.3 short
    # names and all - and $unpacked is built from $env:TEMP, which on any profile whose account
    # name is long or hyphenated is "C:\Users\LEGION~1\...". Get-ChildItem's FullName below is
    # the LONG form, "C:\Users\Legion-T7\...", so the two differ by a character or two and
    # Substring($prefix.Length) slices one short: every relative path came out as "\setup.exe"
    # rather than "setup.exe". The verify step then reported every file as BOTH missing from the
    # zip and unexpectedly present in it, and deleted a perfectly good package.
    #
    # Measured, not imagined - it is what Test-Push section 11c does on this machine. Get-Item
    # returns the canonical long form, which is exactly what FullName reports, so the two are
    # finally being measured with the same ruler.
    $prefix = (Get-Item -LiteralPath $unpacked).FullName.TrimEnd('\') + '\'

    $dropped = @()
    foreach ($f in $all) {
        $rel = $f.FullName.Substring($prefix.Length)
        if (Test-Excluded $rel) { $dropped += $rel; Remove-Item -LiteralPath $f.FullName -Force }
    }
    if ($dropped.Count) {
        Write-Step "Leaving $($dropped.Count) file(s) out"
        foreach ($d in @($dropped | Select-Object -First 12)) { Write-Host "      - $d" -ForegroundColor DarkGray }
        if ($dropped.Count -gt 12) { Write-Host "      - +$($dropped.Count - 12) more" -ForegroundColor DarkGray }
    }
    # an empty directory left by an exclusion would become a phantom folder in the .zip
    foreach ($d in @(Get-ChildItem -LiteralPath $unpacked -Directory -Recurse -Force |
                     Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not @(Get-ChildItem -LiteralPath $d.FullName -Force).Count) { Remove-Item -LiteralPath $d.FullName -Force }
    }

    # ---------------------------------------------------------------- 2b. things to add
    #
    # A vendor installer carries the vendor's files and nothing else. A logo, a licence, a
    # pre-configured .ini - the things an after-install step exists to place - have to be put
    # into the package here, or the step has nothing to copy FROM and fails on the client with
    # "source file missing" at the end of a long install.
    if (@($AddFrom).Count) {
        Write-Step "Adding $(@($AddFrom).Count) source(s) into the package"
        $into = $unpacked
        if ($AddInto) { $into = Join-Path $unpacked $AddInto }
        foreach ($a in @($AddFrom)) {
            if (-not $a) { continue }
            if (-not (Test-Path -LiteralPath $a)) { throw "-AddFrom: no such file or folder: $a" }
            $item = Get-Item -LiteralPath $a
            New-Item -ItemType Directory -Force -Path $into | Out-Null
            if ($item.PSIsContainer) {
                # the folder's CONTENTS, keeping their structure - copying the folder itself
                # would bury everything one level deeper than the -AddInto that was asked for
                foreach ($f in @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force)) {
                    $rel = $f.FullName.Substring($item.FullName.TrimEnd('\').Length + 1)
                    $to  = Join-Path $into $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
                    Copy-Item -LiteralPath $f.FullName -Destination $to -Force
                    Write-Host ("      + {0}" -f (Join-Path $AddInto $rel)) -ForegroundColor DarkGray
                }
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $into $item.Name) -Force
                Write-Host ("      + {0}" -f (Join-Path $AddInto $item.Name)) -ForegroundColor DarkGray
            }
        }
    }

    $kept = @(Get-ChildItem -LiteralPath $unpacked -File -Recurse -Force |
              ForEach-Object { [pscustomobject]@{ Rel = $_.FullName.Substring($prefix.Length); Len = $_.Length } })
    if (-not $kept.Count) { throw 'every file was excluded - there would be nothing to install' }
    Write-Ok "$($kept.Count) file(s), $('{0:N0}' -f (($kept | Measure-Object Len -Sum).Sum)) bytes"

    # ---------------------------------------------------------------- 3. write the .zip
    Write-Step "Writing $([IO.Path]::GetFileName($Destination))"
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    # Deflate on purpose: it is what .NET's ZipFile reads, which is what keeps the client off
    # the tar path entirely. Optimal rather than SmallestSize - these are already-compressed
    # installers, so the extra time buys almost nothing.
    [IO.Compression.ZipFile]::CreateFromDirectory($unpacked, $Destination,
        [IO.Compression.CompressionLevel]::Optimal, $false)

    # ---------------------------------------------------------------- 4. prove it round-tripped
    Write-Step 'Verifying'
    $inZip = @{}
    $zip = [IO.Compression.ZipFile]::OpenRead($Destination)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }   # a directory entry
            $inZip[($e.FullName -replace '/', '\')] = [long]$e.Length
        }
    } finally { $zip.Dispose() }

    $keptRel = @($kept | ForEach-Object { $_.Rel })
    $missing = @(); $wrong = @()
    foreach ($k in $kept) {
        if (-not $inZip.ContainsKey($k.Rel)) { $missing += $k.Rel; continue }
        if ($inZip[$k.Rel] -ne $k.Len) { $wrong += "$($k.Rel) ($($k.Len) -> $($inZip[$k.Rel]))" }
    }
    $extra = @($inZip.Keys | Where-Object { $keptRel -notcontains $_ })

    if ($missing.Count -or $wrong.Count -or $extra.Count) {
        foreach ($m in @($missing | Select-Object -First 5)) { Write-Warn "missing from the zip: $m" }
        foreach ($w in @($wrong   | Select-Object -First 5)) { Write-Warn "wrong length: $w" }
        foreach ($x in @($extra   | Select-Object -First 5)) { Write-Warn "unexpected in the zip: $x" }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw 'the .zip does not match what came out of the package - nothing was kept'
    }
    Write-Ok "$($kept.Count) file(s) present at the same length, and nothing extra"

    $out = Get-Item -LiteralPath $Destination
    $sha = (Get-FileHash -LiteralPath $out.FullName -Algorithm SHA256).Hash
    $installers = @($kept | Where-Object { $_.Rel -match '\.(exe|msi)$' } |
                   Sort-Object @{ e = { ($_.Rel -split '\\').Count } }, @{ e = { $_.Rel } })

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host ("  file    {0}" -f $out.FullName)
    Write-Host ("  size    {0:N0} bytes  (was {1:N0})" -f $out.Length, $src.Length)
    Write-Host ("  sha256  {0}" -f $sha)
    if ($installers.Count) {
        Write-Host ("  entry   {0}" -f $installers[0].Rel)
        if ($installers.Count -gt 1) { Write-Host ("          (+{0} other installer(s) inside)" -f ($installers.Count - 1)) }
    } else {
        Write-Warn 'no .exe or .msi inside - the catalog entry will have nothing to run'
    }
    # Everything that is NOT the installer is a candidate for an after-install step, and the
    # editor's "from" dropdown will offer exactly this list once the package is re-fetched.
    $copyable = @($kept | Where-Object { $_.Rel -notmatch '\.(exe|msi)$' } | ForEach-Object { $_.Rel })
    if ($copyable.Count) {
        Write-Host ''
        Write-Host '  files an after-install step can copy:' -ForegroundColor DarkGray
        foreach ($cf in @($copyable | Select-Object -First 15)) { Write-Host "      $cf" -ForegroundColor DarkGray }
        if ($copyable.Count -gt 15) { Write-Host ("      +{0} more" -f ($copyable.Count - 15)) -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host 'Next: open the app in the catalog editor, "Use a local file..." and pick this .zip.' -ForegroundColor DarkGray
    Write-Host '      That re-hashes it, rewrites the URL, and keeps the switches and verify path.' -ForegroundColor DarkGray

    [pscustomobject]@{ Path = $out.FullName; SizeBytes = $out.Length; Sha256 = $sha
                       FileCount = $kept.Count; Entry = $(if ($installers.Count) { $installers[0].Rel } else { '' })
                       Excluded = $dropped; Copyable = $copyable }
}
finally {
    if ($mounted) { try { Dismount-DiskImage -ImagePath $src.FullName -ErrorAction SilentlyContinue | Out-Null } catch { } }
    if ($ownWork) { try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}
