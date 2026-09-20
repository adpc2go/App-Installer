# Installer-Family.ps1 - which installer built this file, from POSITIVE evidence only.
#
# One rule above every other: this file never concludes anything from what it did NOT find.
# Every claim is a signature at a stated offset, in a bounded region - the PE headers, the
# section table, the version resource, the first 1 MB and last 64 KB of the PE overlay, sixteen
# bytes at each resource leaf, and the names of the files beside the entry. A result therefore
# reads "found X at Y" or "not searched", never "absent". BytesRead travels with every result so
# a test can hold the cost to a few megabytes whatever the file's size.
#
# The previous detector (deleted 2026-08-22) sampled 0.28% of a 1 GB installer and inferred a
# family from the markers it did not see. That is the failure this design cannot repeat: an
# unknown family yields Confidence 'none' and NO switch, and the installer guard on the client
# stops a window that opens. Confidence has two values, 'signature' and 'none'.
#
# One copy of these functions is shipped inside server\AppDeploy.ps1 (top-level functions, and
# rendered into the elevated worker at Start-Worker); tools\Catalog-Editor.ps1 dot-sources this
# file and hands its text to the fetch runspace. A harness pins the copies equal. Constraints
# that follow: PowerShell 5.1 only, no external commands, no here-strings, no $script: state
# beyond the tables below, nothing that a fresh runspace does not have.

$script:InstallerFamilyLabels = @{
    msi = 'Windows Installer'; msp = 'Windows Installer patch'; msix = 'MSIX / Appx package'
    inno = 'Inno Setup'; nsis = 'NSIS'; burn = 'WiX Burn bundle'; sfx7z = '7-Zip SFX'; sfxrar = 'WinRAR SFX'
    installshield = 'InstallShield'; odis = 'Autodesk ODIS'; adobeac = 'Adobe Admin Console package'
    officeodt = 'Office Deployment Tool'; acrobat = 'Adobe Acrobat bootstrap'
    squirrel = 'Squirrel.Windows'; velopack = 'Velopack'; advinst = 'Advanced Installer'; wise = 'Wise Installation System'
    setupfactory = 'Setup Factory'; installaware = 'InstallAware'; qtifw = 'Qt Installer Framework'; install4j = 'install4j'
    iexpress = 'IExpress self-extractor'; bitrock = 'InstallBuilder (BitRock)'; clickteam = 'Clickteam Install Creator'
}

# The second-pass families: installers whose loader carries its maker's name in its own image
# (a version resource or a plain string in the stub) rather than a structural marker. Searched
# ONLY when nothing structural, no package layout and no InstallShield resource matched, in the
# bounded regions the file header comment names. Order matters: Velopack is a Squirrel fork and
# still carries Squirrel strings, so it is asked first.
$script:InstallerIdentityMarkers = @(
    @{ Family = 'velopack';     Markers = @('Velopack') }
    @{ Family = 'squirrel';     Markers = @('SquirrelSetup', 'Squirrel.Windows', 'SquirrelAwareVersion') }
    @{ Family = 'advinst';      Markers = @('Advanced Installer', 'Caphyon') }
    @{ Family = 'wise';         Markers = @('WiseMain', 'Wise Installation System', 'Wise Solutions') }
    @{ Family = 'setupfactory'; Markers = @('Setup Factory', 'Indigo Rose') }
    @{ Family = 'installaware'; Markers = @('InstallAware') }
    @{ Family = 'qtifw';        Markers = @('Qt Installer Framework', 'installerbase') }
    @{ Family = 'install4j';    Markers = @('install4j') }
    @{ Family = 'bitrock';      Markers = @('BitRock InstallBuilder', 'InstallBuilder', 'BitRock') }
    @{ Family = 'clickteam';    Markers = @('Clickteam Install Creator', 'Install Creator', 'Clickteam') }
    @{ Family = 'iexpress';     Markers = @('Win32 Cabinet Self-Extractor', 'WEXTRACT.EXE') }
)

function Get-InstallerFamilyLabel([string]$Family) {
    if ($Family -and $script:InstallerFamilyLabels.ContainsKey($Family)) { return $script:InstallerFamilyLabels[$Family] }
    if ($Family) { return $Family }
    return 'unknown'
}

# The documented switch per family. Install is what the entry file is launched with; Uninstall
# describes the uninstaller's shape so the registry side can recognise and quieten it.
function Get-FamilySwitches([string]$Family, [string]$SubType = '') {
    switch ($Family) {
        'msi'   { return @{ Install = '/qn /norestart'; UninstallExe = '^msiexec(\.exe)?$'; UninstallArgs = '/x {ProductCode} /qn /norestart'; Doc = 'Microsoft: Standard Installer Command-Line Options' } }
        'msp'   { return @{ Install = '/qn /norestart'; UninstallExe = ''; UninstallArgs = ''; Doc = 'Microsoft: msiexec /p' } }
        'msix'  { return @{ Install = ''; UninstallExe = '^appx$'; UninstallArgs = ''; Doc = 'Microsoft: Add-AppxProvisionedPackage' } }
        'inno'  { return @{ Install = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; UninstallExe = '(?i)^unins\d{3}\.exe$'; UninstallArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Doc = 'Inno Setup Help: Setup / Uninstaller Command Line Parameters' } }
        'nsis'  { return @{ Install = '/S'; UninstallExe = '(?i)^(uninst(all)?|un-?install[^\\]*)\.exe$'; UninstallArgs = '/S _?={InstallLocation}'; Doc = 'NSIS Users Manual 3.2 (/S) and 4.9 (_?=)' } }
        'burn'  { return @{ Install = '/quiet /norestart'; UninstallExe = '(?i)\.exe$'; UninstallArgs = '/uninstall /quiet /norestart'; Doc = 'WiX Toolset: Burn standard bootstrapper options' } }
        'sfx7z' { return @{ Install = '-y'; UninstallExe = ''; UninstallArgs = ''; Doc = '7-Zip: SFX modules for installers (-y; the wrapped program is run by the SFX config)' } }
        'sfxrar'{ return @{ Install = '-s'; UninstallExe = ''; UninstallArgs = ''; Doc = 'WinRAR: SFX command line switches (-s runs Setup= silently; the exit code is the SFX own)' } }
        'installshield' {
            switch ($SubType) {
                'basicmsi'      { return @{ Install = '/s /v"/qn /norestart"'; UninstallExe = '^msiexec(\.exe)?$'; UninstallArgs = '/x {ProductCode} /qn /norestart'; Doc = 'Revenera: Setup.exe command-line parameters (Basic MSI)' } }
                'installscript' { return @{ Install = '/s /f1"{ResponseFile}"'; UninstallExe = '(?i)^setup\.exe$'; UninstallArgs = '-runfromtemp -removeonly /s /f1"{ResponseFile}"'; Doc = 'Revenera: InstallScript silent install with a recorded response file' } }
                'suite'         { return @{ Install = '/silent'; UninstallExe = '(?i)\.exe$'; UninstallArgs = '-remove -silent'; Doc = 'Revenera: Suite/Advanced UI Setup.exe command-line parameters (/silent, /remove)' } }
                default         { return @{ Install = ''; UninstallExe = ''; UninstallArgs = ''; Doc = 'Revenera: the silent switch depends on the project type, which a single setup.exe does not prove' } }
            }
        }
        'odis'      { return @{ Install = '--silent'; UninstallExe = '(?i)AdODIS\\V1\\Installer\.exe$'; UninstallArgs = '-i uninstall -q -o "__ODIS_MANIFEST__"'; Doc = 'Autodesk: ODIS Setup.exe --silent / Installer.exe -i uninstall -q' } }
        'adobeac'   { return @{ Install = '--silent'; UninstallExe = '(?i)^setup\.exe$'; UninstallArgs = '--uninstall=1'; Doc = 'Adobe Enterprise: setup.exe --silent / --uninstall=1' } }
        'officeodt' { return @{ Install = '/configure configuration.xml'; UninstallExe = '(?i)OfficeClickToRun\.exe$'; UninstallArgs = ''; Doc = 'Microsoft: Office Deployment Tool setup.exe /configure' } }
        'acrobat'   { return @{ Install = '/sAll /rs /rps /msi EULA_ACCEPT=YES'; UninstallExe = '^msiexec(\.exe)?$'; UninstallArgs = '/x {ProductCode} /qn /norestart'; Doc = 'Adobe Acrobat Enterprise Toolkit: Setup.exe /sAll /rs /msi' } }
        # ---- the second pass: identity-string families (see $script:InstallerIdentityMarkers)
        'squirrel'     { return @{ Install = '--silent'; UninstallExe = '(?i)^update\.exe$'; UninstallArgs = '--uninstall'; Doc = 'Squirrel.Windows: Setup.exe --silent; Update.exe --uninstall runs without UI' } }
        'velopack'     { return @{ Install = '--silent'; UninstallExe = '(?i)^update\.exe$'; UninstallArgs = '--uninstall'; Doc = 'Velopack: Setup.exe --silent; Update.exe --uninstall' } }
        'advinst'      { return @{ Install = '/exenoui /qn'; UninstallExe = '(?i)\.exe$'; UninstallArgs = '/x /exenoui /qn'; Doc = 'Advanced Installer: EXE bootstrapper command line (/exenoui /qn; /x uninstalls)' } }
        'wise'         { return @{ Install = '/s'; UninstallExe = '(?i)^unwise(32)?\.exe$'; UninstallArgs = '/S {InstallLog}'; Doc = 'Wise Installation System: setup /s; UNWISE.EXE /S install.log' } }
        'setupfactory' { return @{ Install = '/S'; UninstallExe = '(?i)\.exe$'; UninstallArgs = '/S'; Doc = 'Indigo Rose Setup Factory: /S for the setup and its uninstaller' } }
        'installaware' { return @{ Install = '/s'; UninstallExe = '(?i)\.exe$'; UninstallArgs = '/s MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES'; Doc = 'InstallAware: /s; uninstall with MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES' } }
        'qtifw'        { return @{ Install = '--accept-licenses --default-answer --confirm-command install'; UninstallExe = '(?i)^maintenancetool\.exe$'; UninstallArgs = '--confirm-command purge'; Doc = 'Qt Installer Framework 4: command-line install and purge' } }
        'install4j'    { return @{ Install = '-q'; UninstallExe = '(?i)^uninstall\.exe$'; UninstallArgs = '-q'; Doc = 'install4j: -q (unattended) for the installer and the uninstaller' } }
        'iexpress'     { return @{ Install = '/Q'; UninstallExe = ''; UninstallArgs = ''; Doc = 'IExpress / wextract: /Q quiet (the package decides what it runs)' } }
        'bitrock'      { return @{ Install = '--mode unattended'; UninstallExe = '(?i)^uninstall\.exe$'; UninstallArgs = '--mode unattended'; Doc = 'InstallBuilder (BitRock / VMware): --mode unattended' } }
        'clickteam'    { return @{ Install = '/S'; UninstallExe = '(?i)^uninstal\.exe$'; UninstallArgs = '/S'; Doc = 'Clickteam Install Creator: /S; Uninstal.exe /S' } }
        default     { return @{ Install = ''; UninstallExe = ''; UninstallArgs = ''; Doc = '' } }
    }
}

# ---------------------------------------------------------------- bounded I/O

function Read-FileRange([string]$Path, [long]$Offset, [int]$Count, [hashtable]$Ctx) {
    if ($Count -le 0) { return ,(New-Object byte[] 0) }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Offset -ge $fs.Length) { return ,(New-Object byte[] 0) }
        $want = [int][Math]::Min([long]$Count, $fs.Length - $Offset)
        [void]$fs.Seek($Offset, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $want
        $got = 0
        while ($got -lt $want) {
            $n = $fs.Read($buf, $got, $want - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        if ($Ctx) { $Ctx.BytesRead = [long]$Ctx.BytesRead + $got }
        # The unary comma is load-bearing. A byte[] returned bare is unrolled into the pipeline
        # and collected again as Object[] of boxed bytes; every [BitConverter] call on that then
        # converts and copies the whole buffer - 62 entries took 730 ms. Kept as byte[], 5 ms.
        if ($got -lt $want) { $short = New-Object byte[] $got; [Array]::Copy($buf, $short, $got); return ,$short }
        return ,$buf
    } finally { $fs.Dispose() }
}

# One byte = one char, so String.IndexOf(..., Ordinal) is the marker search - no regex, no
# multi-byte decoding surprises, and the offset it returns IS the byte offset.
function ConvertTo-Latin1([byte[]]$Bytes) {
    if (-not $Bytes -or -not $Bytes.Length) { return '' }
    return [Text.Encoding]::GetEncoding(28591).GetString($Bytes)
}

function Find-Marker([string]$Hay, [string]$Needle, [int]$Start = 0) {
    if (-not $Hay -or -not $Needle) { return -1 }
    return $Hay.IndexOf($Needle, $Start, [StringComparison]::Ordinal)
}

function ConvertFrom-HexMarker([string]$Hex) {
    $b = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return (ConvertTo-Latin1 $b)
}

# The PE map: sections, the overlay (bytes after the last section - where NSIS, Inno, 7z and
# RAR stubs keep their payload), and the resource section. Two reads, at most 64 KB.
function Get-PeLayout([string]$Path, [hashtable]$Ctx) {
    $r = @{ IsPe = $false; Is64 = $false; Sections = @(); OverlayOffset = [long]0; OverlaySize = [long]0
            ResourceSection = $null; FileSize = [long]0 }
    try { $r.FileSize = (Get-Item -LiteralPath $Path).Length } catch { return $r }
    if ($r.FileSize -lt 64) { return $r }
    $head = Read-FileRange $Path 0 4096 $Ctx
    if ($head.Length -lt 64 -or $head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return $r }
    $pe = [BitConverter]::ToInt32($head, 0x3C)
    if ($pe -le 0 -or $pe -gt ($r.FileSize - 24)) { return $r }
    $need = $pe + 24 + 240 + (96 * 40)
    if ($need -gt $head.Length) { $head = Read-FileRange $Path 0 ([int][Math]::Min($need, 65536)) $Ctx }
    if (($pe + 24) -gt $head.Length) { return $r }
    if (-not ($head[$pe] -eq 0x50 -and $head[$pe + 1] -eq 0x45 -and $head[$pe + 2] -eq 0 -and $head[$pe + 3] -eq 0)) { return $r }
    $r.IsPe = $true
    $nSec = [BitConverter]::ToUInt16($head, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($head, $pe + 20)
    $magic = [BitConverter]::ToUInt16($head, $pe + 24)
    $r.Is64 = ($magic -eq 0x20B)
    $secTab = $pe + 24 + $optSize
    $end = [long]0
    $secs = @()
    for ($i = 0; $i -lt [Math]::Min([int]$nSec, 96); $i++) {
        $o = $secTab + ($i * 40)
        if (($o + 40) -gt $head.Length) { break }
        $name = ([Text.Encoding]::ASCII.GetString($head, $o, 8)).TrimEnd([char]0)
        $s = @{ Name = $name; VirtualSize = [BitConverter]::ToUInt32($head, $o + 8); Va = [BitConverter]::ToUInt32($head, $o + 12)
                RawSize = [BitConverter]::ToUInt32($head, $o + 16); RawPtr = [BitConverter]::ToUInt32($head, $o + 20) }
        $secs += $s
        $secEnd = [long]$s.RawPtr + [long]$s.RawSize
        if ($secEnd -gt $end) { $end = $secEnd }
        if ($name -eq '.rsrc') { $r.ResourceSection = $s }
    }
    $r.Sections = $secs
    if ($end -gt 0 -and $end -lt $r.FileSize) { $r.OverlayOffset = $end; $r.OverlaySize = $r.FileSize - $end }
    return $r
}

function Get-VersionStrings([string]$Path) {
    $v = @{ CompanyName = ''; ProductName = ''; InternalName = ''; Comments = ''; FileDescription = ''; OriginalFilename = '' }
    try {
        $fi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        foreach ($k in @($v.Keys)) { $v[$k] = ('' + $fi.$k).Trim() }
    } catch { }
    return $v
}

# Walk the .rsrc directory (three levels) and read 16 bytes at each leaf - how an MSI embedded
# as a resource (InstallShield single-exe, Advanced Installer) or Inno's RCDATA 11111 is found
# at the cost of a few hundred seeks, whatever the resource section's size.
function Get-PeResourceLeaves([string]$Path, $Layout, [hashtable]$Ctx, [int]$MaxLeaves = 256) {
    $out = New-Object Collections.ArrayList
    $rs = $Layout.ResourceSection
    if (-not $rs -or -not $rs.RawSize) { return @() }
    $dirBytes = Read-FileRange $Path ([long]$rs.RawPtr) ([int][Math]::Min([long]$rs.RawSize, 65536)) $Ctx
    if ($dirBytes.Length -lt 16) { return $out }
    # ArrayLists, not += on arrays: a few hundred entries through array growth cost seconds
    $entriesOf = {
        param([int]$dirOff)
        $list = New-Object Collections.ArrayList
        if (($dirOff + 16) -gt $dirBytes.Length) { return ,$list }
        $nNamed = [BitConverter]::ToUInt16($dirBytes, $dirOff + 12)
        $nId = [BitConverter]::ToUInt16($dirBytes, $dirOff + 14)
        $n = [Math]::Min([int]($nNamed + $nId), 512)
        for ($i = 0; $i -lt $n; $i++) {
            $e = $dirOff + 16 + ($i * 8)
            if (($e + 8) -gt $dirBytes.Length) { break }
            [void]$list.Add(@{ Id = [BitConverter]::ToUInt32($dirBytes, $e); Off = [BitConverter]::ToUInt32($dirBytes, $e + 4) })
        }
        return $list.ToArray()
    }
    # one handle for every leaf read - opening the file 256 times cost seconds on a plain exe
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buf16 = New-Object byte[] 16
        foreach ($t in @(& $entriesOf 0)) {
            if (-not ($t.Off -band 0x80000000)) { continue }
            foreach ($n in @(& $entriesOf ([int]($t.Off -band 0x7FFFFFFF)))) {
                if (-not ($n.Off -band 0x80000000)) { continue }
                foreach ($l in @(& $entriesOf ([int]($n.Off -band 0x7FFFFFFF)))) {
                    if ($l.Off -band 0x80000000) { continue }
                    $de = [int]$l.Off
                    if (($de + 16) -gt $dirBytes.Length) { continue }
                    $rva = [BitConverter]::ToUInt32($dirBytes, $de)
                    $size = [BitConverter]::ToUInt32($dirBytes, $de + 4)
                    $fileOff = [long]$rva - [long]$rs.Va + [long]$rs.RawPtr
                    if ($fileOff -lt 0 -or $fileOff -ge $Layout.FileSize) { continue }
                    [void]$fs.Seek($fileOff, [IO.SeekOrigin]::Begin)
                    $got = $fs.Read($buf16, 0, 16)
                    if ($Ctx) { $Ctx.BytesRead = [long]$Ctx.BytesRead + $got }
                    $head = New-Object byte[] $got; [Array]::Copy($buf16, $head, $got)
                    [void]$out.Add(@{ Type = [long]($t.Id -band 0x7FFFFFFF); Id = [long]($n.Id -band 0x7FFFFFFF); Offset = $fileOff; Size = [long]$size; Head = (ConvertTo-Latin1 $head) })
                    if ($out.Count -ge $MaxLeaves) { return @($out.ToArray()) }
                }
            }
        }
    } finally { $fs.Dispose() }
    return @($out.ToArray())
}

# The names beside the entry: relative, lowercase, backslashes. From an explicit list (an
# archive listing) or from the entry's own folder, one level of subfolders.
function Get-CompanionNames([string]$Path, [string[]]$Siblings) {
    $names = @()
    if ($Siblings -and $Siblings.Count) {
        $names = @($Siblings | Where-Object { $_ } | ForEach-Object { ('' + $_).Replace('/', '\').ToLowerInvariant().TrimStart('\') })
    } elseif ($Path -and (Test-Path -LiteralPath $Path)) {
        # capped: a package folder holds a few dozen names; an exe sitting in System32 does
        # not, and listing that folder is not evidence about the installer
        $dir = Split-Path -Parent $Path
        $list = New-Object Collections.ArrayList
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Select-Object -First 300)) { [void]$list.Add($f.Name.ToLowerInvariant()) }
            foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Select-Object -First 50)) {
                [void]$list.Add($d.Name.ToLowerInvariant() + '\')
                foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue | Select-Object -First 100)) { [void]$list.Add(($d.Name + '\' + $f.Name).ToLowerInvariant()) }
            }
        } catch { }
        $names = @($list.ToArray())
    }
    return $names
}

function Test-Companion([string[]]$Names, [string]$Pattern) {
    foreach ($n in $Names) { if ($n -like $Pattern) { return $n } }
    return ''
}

# ---------------------------------------------------------------- the engine

function Get-InstallerFamily {
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$Siblings = @(), [int]$OverlayProbeBytes = 1MB)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ctx = @{ BytesRead = [long]0 }
    $res = [ordered]@{ Family = ''; SubType = ''; Confidence = 'none'; Evidence = @(); InstallArgs = ''
                       UninstallShape = $null; Notes = @(); EmbeddedMsi = 'not-searched'; BytesRead = [long]0; Elapsed = [double]0 }
    $finish = {
        param($r)
        $r.BytesRead = [long]$ctx.BytesRead
        $r.Elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 3)
        if ($r.Family -and $r.Confidence -eq 'signature') {
            $sw2 = Get-FamilySwitches $r.Family $r.SubType
            if (-not $r.InstallArgs) { $r.InstallArgs = [string]$sw2.Install }
            if (-not $r.UninstallShape) { $r.UninstallShape = @{ ExePattern = [string]$sw2.UninstallExe; Args = [string]$sw2.UninstallArgs } }
            if ($sw2.Doc) { $r.Notes += "documented: $($sw2.Doc)" }
        } else {
            $r.InstallArgs = ''
        }
        return $r
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { $res.Notes += 'file not found'; return (& $finish $res) }
    $ext = ([IO.Path]::GetExtension($Path)).ToLowerInvariant()
    $leaf = ([IO.Path]::GetFileName($Path)).ToLowerInvariant()
    $names = Get-CompanionNames $Path $Siblings

    # ---- 1. non-PE containers: the head settles it
    $head = Read-FileRange $Path 0 8 $ctx
    $headHex = (($head | ForEach-Object { $_.ToString('X2') }) -join '')
    if ($headHex -eq 'D0CF11E0A1B11AE1') {
        if ($ext -eq '.msi' -or $ext -eq '.msp') {
            $res.Family = $(if ($ext -eq '.msp') { 'msp' } else { 'msi' }); $res.Confidence = 'signature'
            $res.Evidence += 'OLE compound-file header at offset 0'
            $res.EmbeddedMsi = 'found@0x0'
            if ($ext -eq '.msi') {
                $code = ''
                try {
                    # plain COM calls: InvokeMember with a boxed Int32 answered DISP_E_TYPEMISMATCH
                    $inst = New-Object -ComObject WindowsInstaller.Installer
                    $db = $inst.OpenDatabase($Path, 0)
                    $view = $db.OpenView("SELECT Value FROM Property WHERE Property='ProductCode'")
                    $view.Execute()
                    $rec = $view.Fetch()
                    if ($rec) { $code = [string]$rec.StringData(1) }
                    $view.Close()
                } catch { $res.Notes += "ProductCode not read ($($_.Exception.Message))" }
                if ($code) { $res.UninstallShape = @{ ExePattern = '^msiexec(\.exe)?$'; Args = "/x $code /qn /norestart"; ProductCode = $code }; $res.Evidence += "ProductCode $code from the Property table" }
            }
        } else {
            $res.Evidence += 'OLE compound-file header at offset 0, but the extension is not .msi/.msp'
        }
        return (& $finish $res)
    }
    if ($headHex.StartsWith('504B0304')) {
        $isAppx = ($ext -in '.msix', '.appx', '.msixbundle', '.appxbundle')
        if ($isAppx) {
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $z = [IO.Compression.ZipFile]::OpenRead($Path)
                try {
                    $hasManifest = @($z.Entries | Where-Object { $_.FullName -match '(?i)^(AppxManifest\.xml|AppxMetadata/AppxBundleManifest\.xml)$' }).Count -gt 0
                } finally { $z.Dispose() }
                if ($hasManifest) { $res.Family = 'msix'; $res.Confidence = 'signature'; $res.Evidence += 'zip with AppxManifest.xml' }
            } catch { $res.Notes += "zip could not be opened ($($_.Exception.Message))" }
        } else { $res.Evidence += 'zip header at offset 0 (not an installer by itself)' }
        return (& $finish $res)
    }

    # ---- 2. PE
    $pe = Get-PeLayout $Path $ctx
    if (-not $pe.IsPe) { $res.Evidence += "not a PE executable (head $headHex)"; return (& $finish $res) }
    $secNames = @($pe.Sections | ForEach-Object { $_.Name })
    $ver = Get-VersionStrings $Path

    $overlay = ''
    if ($pe.OverlaySize -gt 0) {
        $overlay = ConvertTo-Latin1 (Read-FileRange $Path $pe.OverlayOffset ([int][Math]::Min([long]$OverlayProbeBytes, $pe.OverlaySize)) $ctx)
    }
    $tail = ''
    if ($pe.OverlaySize -gt $OverlayProbeBytes) {
        $tail = ConvertTo-Latin1 (Read-FileRange $Path ([long]($pe.FileSize - 65536)) 65536 $ctx)
    }
    $ole = ConvertFrom-HexMarker 'D0CF11E0A1B11AE1'
    $oleAt = Find-Marker $overlay $ole
    if ($oleAt -ge 0) { $res.EmbeddedMsi = ('found@0x{0:X}' -f ($pe.OverlayOffset + $oleAt)) }

    $structural = @()   # @{ Family; Evidence }
    # Burn: the .wixburn section IS the loader
    if ($secNames -contains '.wixburn') {
        $s = $pe.Sections | Where-Object { $_.Name -eq '.wixburn' } | Select-Object -First 1
        $magic = ConvertTo-Latin1 (Read-FileRange $Path ([long]$s.RawPtr) 4 $ctx)
        if ($magic -eq (ConvertFrom-HexMarker '0043F100')) { $structural += @{ Family = 'burn'; Evidence = ('.wixburn section with Burn magic at 0x{0:X}' -f $s.RawPtr) } }
        else { $res.Notes += '.wixburn section present without the Burn magic' }
    }
    # NSIS: firstheader at the overlay start (DEADBEEF LE + "NullsoftInst")
    $nsisAt = Find-Marker $overlay ((ConvertFrom-HexMarker 'EFBEADDE') + 'NullsoftInst')
    if ($nsisAt -ge 0) { $structural += @{ Family = 'nsis'; Evidence = ('NSIS firstheader at overlay+0x{0:X}' -f $nsisAt) } }
    # Inno: the SetupID string, or the SetupLoaderOffsetTable id
    $innoAt = Find-Marker $overlay 'Inno Setup Setup Data ('
    if ($innoAt -lt 0) { $innoAt = Find-Marker $overlay 'rDlPtS' }
    if ($innoAt -lt 0 -and $tail) { $t = Find-Marker $tail 'rDlPtS'; if ($t -ge 0) { $innoAt = 0; $res.Evidence += 'Inno SetupLoaderOffsetTable at the file end' } }
    if ($innoAt -ge 0) { $structural += @{ Family = 'inno'; Evidence = ('Inno Setup signature at overlay+0x{0:X}' -f $innoAt) } }
    # 7-Zip SFX and WinRAR SFX: archive magic at the overlay start
    $sevenAt = Find-Marker $overlay (ConvertFrom-HexMarker '377ABCAF271C')
    if ($sevenAt -ge 0) {
        $ev = ('7z archive signature at overlay+0x{0:X}' -f $sevenAt)
        $cfg = Find-Marker $overlay ';!@Install@!UTF-8!'
        if ($cfg -ge 0) {
            $ev += ' with SFX install config'
            $m = [regex]::Match($overlay.Substring($cfg, [Math]::Min(2048, $overlay.Length - $cfg)), '(?m)^(RunProgram|ExecuteFile)=\"?([^\"\r\n]+)')
            if ($m.Success) { $res.Notes += "SFX config runs: $($m.Groups[2].Value)" }
        }
        $structural += @{ Family = 'sfx7z'; Evidence = $ev }
    }
    $rarAt = Find-Marker $overlay ((ConvertFrom-HexMarker '526172211A07'))
    if ($rarAt -ge 0) { $structural += @{ Family = 'sfxrar'; Evidence = ('RAR archive signature at overlay+0x{0:X}' -f $rarAt) } }

    # resource leaves: Inno's RCDATA 11111, an MSI embedded as a resource
    if (-not $structural.Count -or $res.EmbeddedMsi -eq 'not-searched') {
        foreach ($l in @(Get-PeResourceLeaves $Path $pe $ctx)) {
            if ($l.Type -eq 10 -and $l.Id -eq 11111 -and $l.Head.StartsWith('rDlPtS')) {
                if (-not @($structural | Where-Object { $_.Family -eq 'inno' }).Count) { $structural += @{ Family = 'inno'; Evidence = ('Inno RCDATA 11111 (SetupLoaderOffsetTable) at 0x{0:X}' -f $l.Offset) } }
            }
            if ($l.Head.StartsWith($ole) -and $res.EmbeddedMsi -eq 'not-searched') { $res.EmbeddedMsi = ('found@0x{0:X}' -f $l.Offset); $res.Evidence += "MSI embedded as resource $($l.Type)/$($l.Id)" }
        }
    }

    # ---- 3. version-resource families (exact values only)
    $isShield = $false
    $shieldCo = @('installshield software corporation', 'installshield software corp.', 'macrovision corporation', 'acresso software inc.', 'flexera software llc', 'flexera software, llc', 'flexera', 'revenera')
    $shieldDesc = @('installshield (r) setup launcher', 'installshield setup launcher', 'setup launcher unicode', 'setup launcher', 'installshield setup')
    if (($shieldCo -contains $ver.CompanyName.ToLowerInvariant()) -or ($shieldDesc -contains $ver.FileDescription.ToLowerInvariant()) -or ($ver.ProductName -eq 'InstallShield')) { $isShield = $true }
    # A Suite/Advanced UI bootstrapper carries the VENDOR's company name (Trimble, not Flexera)
    # and identifies its engine only in InternalName. Measured on SketchUp 2026's installer:
    # 'Trimble, Inc. | SketchUp Installer | SetupSuite'. Its silent switch is /silent - the one
    # InstallShield project type whose switch a single exe DOES prove.
    $isSuite = ($ver.InternalName -eq 'SetupSuite')
    if ($isSuite) { $isShield = $true }

    # ---- 4. package layouts
    $layout = $null
    if ($leaf -eq 'setup.exe') {
        if ($ver.CompanyName -like 'Autodesk*' -and (Test-Companion $names 'image\installer.exe')) { $layout = @{ Family = 'odis'; Evidence = 'Autodesk Setup.exe with image\Installer.exe beside it' } }
        elseif ($ver.CompanyName -like 'Adobe*' -and (Test-Companion $names 'setup.ini') -and (Test-Companion $names 'acro*.msi')) { $layout = @{ Family = 'acrobat'; Evidence = 'Adobe Setup.exe with setup.ini and Acro*.msi beside it' } }
        elseif ($ver.CompanyName -like 'Adobe*' -and ((Test-Companion $names 'asu\*') -or (Test-Companion $names 'build\asu\*') -or (Test-Companion $names '*adobeccd*') -or (Test-Companion $names 'build\*.pkg.json'))) { $layout = @{ Family = 'adobeac'; Evidence = 'Adobe setup.exe with the Admin Console package layout (ASU / AdobeCCD)' } }
        elseif ($ver.CompanyName -like 'Microsoft*' -and (Test-Companion $names 'configuration.xml')) { $layout = @{ Family = 'officeodt'; Evidence = 'Microsoft setup.exe with configuration.xml beside it' } }
    }

    # ---- 5. precedence: outermost loader wins; structural beats string; layouts sit above strings
    $order = @('burn', 'nsis', 'inno', 'sfx7z', 'sfxrar')
    $chosen = $null
    foreach ($f in $order) { $hit = @($structural | Where-Object { $_.Family -eq $f }) | Select-Object -First 1; if ($hit) { $chosen = $hit; break } }
    if ($chosen) {
        $res.Family = $chosen.Family; $res.Confidence = 'signature'; $res.Evidence += $chosen.Evidence
        foreach ($o in @($structural | Where-Object { $_.Family -ne $chosen.Family })) { $res.Evidence += "also: $($o.Evidence)"; $res.Notes += "a $(Get-InstallerFamilyLabel $o.Family) marker sits inside this $(Get-InstallerFamilyLabel $chosen.Family) file - the outer loader parses the command line" }
        if ($res.EmbeddedMsi -like 'found@*') { $res.Notes += "an MSI is embedded ($($res.EmbeddedMsi)); the wrapper's switch applies to the wrapper - whether it runs msiexec quietly is the script author's choice" }
        if ($secNames -contains '.ndata' -and $res.Family -eq 'nsis') { $res.Evidence += '.ndata section' }
    } elseif ($layout) {
        $res.Family = $layout.Family; $res.Confidence = 'signature'; $res.Evidence += $layout.Evidence
    } elseif ($isShield) {
        $res.Family = 'installshield'; $res.Confidence = 'signature'
        $res.Evidence += "InstallShield launcher (version resource: '$($ver.FileDescription)' / '$($ver.CompanyName)')"
        $iss = Test-Companion $names '*.iss'
        $msiBeside = Test-Companion $names '*.msi'
        $iniBeside = Test-Companion $names 'setup.ini'
        if ($isSuite) {
            $res.SubType = 'suite'; $res.Evidence += "Suite/Advanced UI engine (InternalName 'SetupSuite')"
            $res.InstallArgs = (Get-FamilySwitches 'installshield' 'suite').Install
        } elseif ($msiBeside -or $iniBeside) {
            $res.SubType = 'basicmsi'; $res.Evidence += "Basic MSI layout ($(@($msiBeside, $iniBeside) | Where-Object { $_ } | Select-Object -First 1) beside)"
        } elseif ((Test-Companion $names 'setup.inx') -or (Test-Companion $names 'issetup.dll') -or (Test-Companion $names 'data1.cab')) {
            $res.SubType = 'installscript'
            if ($iss) { $res.Evidence += "InstallScript with response file $iss"; $res.InstallArgs = "/s /f1`"$iss`"" }
            else { $res.SubType = 'installscript-noresponse'; $res.Notes += 'InstallScript project with no recorded .iss beside it - not silently installable without one (record it with setup.exe /r)' }
        } else {
            $res.SubType = 'unknown'
            $res.Notes += 'a single InstallShield setup.exe does not prove its project type: the switch is /s /v"/qn" (Basic MSI), /s /f1 (InstallScript, needs a response file) or /silent (Suite) - take it from the vendor page'
        }
    } else {
        # ---- 6. the second pass: a maker's name in the loader's own image
        #
        # Nothing structural, no layout, no InstallShield resource. The remaining families
        # name themselves in plain text - in the stub's data, or in the version resource
        # (UTF-16, so the same bytes are also read with their NULs dropped). Bounded: the
        # first 128 KB, up to 256 KB of .rsrc, the overlay head already in hand, and the tail.
        $ident = Find-InstallerIdentity $Path $pe $ver $overlay $tail $ctx
        if ($ident) {
            $res.Family = $ident.Family; $res.Confidence = 'signature'; $res.Evidence += $ident.Evidence
            if ($res.EmbeddedMsi -like 'found@*') { $res.Notes += "an MSI is embedded ($($res.EmbeddedMsi)); the wrapper's switch applies to the wrapper" }
        } else {
            if ($ver.CompanyName) { $res.Evidence += "PE by '$($ver.CompanyName)' with no known installer signature in the probed regions" }
            else { $res.Evidence += 'PE with no known installer signature in the probed regions' }
            if ($pe.OverlaySize -gt 0) { $res.Notes += ('overlay probed 0x{0:X}-0x{1:X} only' -f $pe.OverlayOffset, ($pe.OverlayOffset + [Math]::Min([long]$OverlayProbeBytes, $pe.OverlaySize))) }
        }
    }
    return (& $finish $res)
}

# The identity-string pass. Returns @{ Family; Evidence } for the first family whose marker is
# found, or $null. Every hit names the marker and where it was read, so the verdict is still
# "found X at Y" - never an inference from an absence.
function Find-InstallerIdentity([string]$Path, $Layout, $Ver, [string]$Overlay, [string]$Tail, [hashtable]$Ctx) {
    # exact version-resource values first: the cheapest and the most specific evidence
    $co = ('' + $Ver.CompanyName).ToLowerInvariant()
    $fd = ('' + $Ver.FileDescription).ToLowerInvariant()
    $of = ('' + $Ver.OriginalFilename).ToLowerInvariant()
    if ($of -eq 'wextract.exe' -or $fd -eq 'win32 cabinet self-extractor') { return @{ Family = 'iexpress'; Evidence = "version resource: '$($Ver.FileDescription)' / '$($Ver.OriginalFilename)'" } }
    if ($co -like 'caphyon*')       { return @{ Family = 'advinst';      Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    if ($co -like 'installaware*')  { return @{ Family = 'installaware'; Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    if ($co -like 'wise solutions*'){ return @{ Family = 'wise';         Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    if ($co -like 'indigo rose*')   { return @{ Family = 'setupfactory'; Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    if ($co -like 'ej-technologies*'){ return @{ Family = 'install4j';   Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    if ($co -like 'clickteam*')     { return @{ Family = 'clickteam';    Evidence = "version resource CompanyName '$($Ver.CompanyName)'" } }
    # then the bounded regions, as plain bytes and with NULs dropped (UTF-16 strings)
    $regions = @()
    $regions += @{ Name = 'head';    Text = (ConvertTo-Latin1 (Read-FileRange $Path 0 131072 $Ctx)) }
    $rs = $Layout.ResourceSection
    if ($rs -and $rs.RawSize -gt 0) {
        $regions += @{ Name = '.rsrc'; Text = (ConvertTo-Latin1 (Read-FileRange $Path ([long]$rs.RawPtr) ([int][Math]::Min([long]$rs.RawSize, 262144)) $Ctx)) }
    }
    if ($Overlay) { $regions += @{ Name = 'overlay'; Text = $Overlay } }
    if ($Tail)    { $regions += @{ Name = 'tail';    Text = $Tail } }
    foreach ($fam in $script:InstallerIdentityMarkers) {
        foreach ($rg in $regions) {
            $plain = [string]$rg.Text
            if (-not $plain) { continue }
            $wide  = $plain.Replace([string][char]0, '')
            foreach ($m in $fam.Markers) {
                $at = Find-Marker $plain $m
                if ($at -ge 0) { return @{ Family = $fam.Family; Evidence = ("marker '{0}' at {1}+0x{2:X}" -f $m, $rg.Name, $at) } }
                $at = Find-Marker $wide $m
                if ($at -ge 0) { return @{ Family = $fam.Family; Evidence = ("marker '{0}' (UTF-16) in the {1}" -f $m, $rg.Name) } }
            }
        }
    }
    return $null
}

# The registry side: from an uninstall entry's exe + args (+ the key's values), recognise the
# family and say which quiet flags are safe to append. Silent is $true only on positive evidence.
function Get-UninstallFamily {
    # $Arguments, never $Args: that name is PowerShell's automatic variable and a parameter
    # called $Args reads back EMPTY inside the function
    param([string]$Exe, [string]$Arguments = '', [hashtable]$RegValues = @{}, [string]$InstallLocation = '')
    $r = @{ Family = ''; Exe = $Exe; Args = $Arguments; Silent = $false; Evidence = ''; Notes = @() }
    $leaf = ('' + [IO.Path]::GetFileName(('' + $Exe))).ToLowerInvariant()
    $argl = ('' + $Arguments)
    $keys = @($RegValues.Keys | ForEach-Object { '' + $_ })
    if ($leaf -match '^msiexec(\.exe)?$' -and $argl -match '\{[0-9A-Fa-f\-]{36}\}') {
        $r.Family = 'msi'; $r.Silent = $true; $r.Evidence = 'msiexec with a product code'
        if ($argl -notmatch '(?i)/q[nb]?') { $r.Args = ($argl + ' /qn /norestart').Trim() }
        return $r
    }
    if ($leaf -match '^unins\d{3}\.exe$') {
        $inno = @($keys | Where-Object { $_ -like 'Inno Setup:*' })
        $sig = $false
        if (-not $inno.Count -and $Exe -and (Test-Path -LiteralPath $Exe)) { try { $f = Get-InstallerFamily -Path $Exe; $sig = ($f.Family -eq 'inno' -and $f.Confidence -eq 'signature') } catch { $sig = $false } }
        if ($inno.Count -or $sig) {
            $r.Family = 'inno'; $r.Silent = $true
            $r.Evidence = $(if ($inno.Count) { "registry values $($inno -join ', ')" } else { 'the uninstaller carries the Inno Setup signature' })
            if ($argl -notmatch '(?i)/(VERY)?SILENT') { $r.Args = ($argl + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim() }
            return $r
        }
    }
    if ($keys -contains 'BundleCachePath' -or $keys -contains 'BundleProviderKey' -or $keys -contains 'BundleUpgradeCode') {
        $r.Family = 'burn'; $r.Silent = $true; $r.Evidence = 'WiX Burn bundle registry values'
        if ($argl -notmatch '(?i)/quiet') { $r.Args = (($argl -replace '(?i)\s*/uninstall\s*', ' ').Trim() + ' /uninstall /quiet /norestart').Trim() }
        return $r
    }
    if ($leaf -match '^(uninst(all)?|un-?install[^\\]*)\.exe$' -and $Exe -and (Test-Path -LiteralPath $Exe)) {
        $f = $null
        try { $f = Get-InstallerFamily -Path $Exe } catch { $f = $null }
        if ($f -and $f.Confidence -eq 'signature' -and $f.Family -eq 'nsis') {
            $loc = $(if ($InstallLocation) { $InstallLocation.TrimEnd('\') } else { Split-Path -Parent $Exe })
            $r.Family = 'nsis'; $r.Silent = $true; $r.Evidence = ($f.Evidence -join '; ')
            if ($argl -notmatch '(?i)(^|\s)/S(\s|$)') { $r.Args = ($argl + ' /S').Trim() }
            if ($r.Args -notmatch '_\?=') { $r.Args = ($r.Args + " _?=$loc").Trim() }
            $r.Notes += '_?= keeps the uninstaller in place so its exit code is the real one'
            return $r
        }
        if ($f -and $f.Confidence -eq 'signature' -and $f.Family -eq 'inno') {
            $r.Family = 'inno'; $r.Silent = $true; $r.Evidence = ($f.Evidence -join '; ')
            if ($argl -notmatch '(?i)/(VERY)?SILENT') { $r.Args = ($argl + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim() }
            return $r
        }
    }
    if ($Exe -match '(?i)AdODIS\\V1\\Installer\.exe$') { $r.Family = 'odis'; $r.Silent = ($argl -match '(?i)(^|\s)-q(\s|$)'); $r.Evidence = 'Autodesk ODIS installer'; return $r }
    # Wise's uninstaller is named for what it is, and takes /S BEFORE the install log
    if ($leaf -match '^unwise(32)?\.exe$') {
        $r.Family = 'wise'; $r.Silent = $true; $r.Evidence = 'Wise UNWISE.EXE uninstaller'
        if ($argl -notmatch '(?i)(^|\s)/S(\s|$)') { $r.Args = ('/S ' + $argl).Trim() }
        return $r
    }
    # The second-pass families: the uninstaller is asked what built it, the same way an NSIS
    # or Inno one is above, and only a positive identity appends that family's documented
    # quiet flags. An uninstaller that is not on disk is left exactly as registered.
    if ($Exe -and $leaf -match '\.exe$' -and (Test-Path -LiteralPath $Exe)) {
        $f2 = $null
        try { $f2 = Get-InstallerFamily -Path $Exe } catch { $f2 = $null }
        if ($f2 -and $f2.Confidence -eq 'signature' -and $f2.Family) {
            $ev = ($f2.Evidence -join '; ')
            switch ($f2.Family) {
                'squirrel' { $r.Family = 'squirrel'; $r.Silent = $true; $r.Evidence = $ev
                             if ($argl -notmatch '(?i)--uninstall') { $r.Notes += 'registered without --uninstall - left as registered' }
                             return $r }
                'velopack' { $r.Family = 'velopack'; $r.Silent = $true; $r.Evidence = $ev
                             if ($argl -notmatch '(?i)--uninstall') { $r.Notes += 'registered without --uninstall - left as registered' }
                             return $r }
                'setupfactory' { $r.Family = 'setupfactory'; $r.Silent = $true; $r.Evidence = $ev
                                 if ($argl -notmatch '(?i)(^|\s)/S(\s|$)') { $r.Args = ($argl + ' /S').Trim() }
                                 return $r }
                'clickteam' { $r.Family = 'clickteam'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)(^|\s)/S(\s|$)') { $r.Args = ($argl + ' /S').Trim() }
                              return $r }
                'install4j' { $r.Family = 'install4j'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)(^|\s)-q(\s|$)') { $r.Args = ($argl + ' -q').Trim() }
                              return $r }
                'bitrock'   { $r.Family = 'bitrock'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)--mode\s+unattended') { $r.Args = ($argl + ' --mode unattended').Trim() }
                              return $r }
                'qtifw'     { $r.Family = 'qtifw'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)\bpurge\b') { $r.Args = ($argl + ' --confirm-command purge').Trim() }
                              elseif ($argl -notmatch '(?i)--confirm-command|(^|\s)-c(\s|$)') { $r.Args = ($argl + ' --confirm-command').Trim() }
                              return $r }
                'advinst'   { $r.Family = 'advinst'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)(^|\s)/x(\s|$)') { $r.Notes += 'registered without /x - this may be the installer rather than an uninstall line' }
                              if ($argl -notmatch '(?i)(^|\s)/qn(\s|$)') { $r.Args = ($argl + ' /exenoui /qn').Trim() }
                              return $r }
                'installaware' { $r.Family = 'installaware'; $r.Silent = $true; $r.Evidence = $ev
                                 if ($argl -notmatch '(?i)(^|\s)/s(\s|$)') { $r.Args = ($argl + ' /s MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES').Trim() }
                                 return $r }
                'wise'      { $r.Family = 'wise'; $r.Silent = $true; $r.Evidence = $ev
                              if ($argl -notmatch '(?i)(^|\s)/S(\s|$)') { $r.Args = ('/S ' + $argl).Trim() }
                              return $r }
            }
        }
    }
    # "-remove -runfromtemp" is the Suite/Advanced UI uninstall (silent with -silent);
    # "-removeonly" (with -runfromtemp) is InstallScript's, silent only with a response file
    if ($argl -match '(?i)(^|\s)[-/]remove(\s|$)' -and $argl -notmatch '(?i)-removeonly') {
        $r.Family = 'installshield'; $r.Evidence = 'InstallShield Suite uninstall (-remove)'
        # the documented quiet flag, appended when the entry lacks it - measured on SketchUp 2026,
        # whose entry is "-remove -runfromtemp" and whose uninstall otherwise opens its wizard
        if ($argl -notmatch '(?i)[-/]silent') { $r.Args = ($Arguments.Trim() + ' -silent').Trim() }
        $r.Silent = $true
        return $r
    }
    if ($argl -match '(?i)-runfromtemp|-removeonly') { $r.Family = 'installshield'; $r.Evidence = 'InstallShield InstallScript uninstall'; $r.Notes += 'silent only with a recorded response file (/s /f1)'; return $r }
    return $r
}

# ---------------------------------------------------------------- fixtures (tests only)

# A small signed PE (where.exe) with a crafted overlay or section, so each family's signature
# can be proven without a vendor download. Real installers are pinned separately.
function New-InstallerFamilyFixture {
    param([Parameter(Mandatory = $true)][string]$Family, [Parameter(Mandatory = $true)][string]$Path, [switch]$EmbedOle)
    $stub = Join-Path $env:SystemRoot 'System32\where.exe'
    $bytes = [IO.File]::ReadAllBytes($stub)
    $latin = [Text.Encoding]::GetEncoding(28591)
    $pad = New-Object byte[] 4096
    $tail = $null
    switch ($Family) {
        'nsis'  { $tail = $latin.GetBytes(([string][char]0xEF) + [char]0xBE + [char]0xAD + [char]0xDE + 'NullsoftInst' + ([string][char]0) * 64) }
        'inno'  { $tail = $latin.GetBytes('rDlPtS' + ([string][char]0) * 32 + 'Inno Setup Setup Data (6.2.0) (u)' + ([string][char]0) * 32 + 'zlb' + [char]0x1A) }
        '7z'    { $tail = $latin.GetBytes(([string][char]0x37) + [char]0x7A + [char]0xBC + [char]0xAF + [char]0x27 + [char]0x1C + ([string][char]0) * 26 + ';!@Install@!UTF-8!' + "`r`nRunProgram=`"setup.exe`"`r`n;!@InstallEnd@!`r`n") }
        'rar'   { $tail = $latin.GetBytes('Rar!' + [char]0x1A + [char]0x07 + [char]0x00 + ([string][char]0) * 64) }
        'burn'  { $tail = $null }
        'none'  { $tail = New-Object byte[] 0 }
        # the identity-string families: their marker, as the stub would carry it, in the overlay
        'squirrel'     { $tail = $latin.GetBytes(([string][char]0) * 16 + 'SquirrelSetup' + ([string][char]0) * 32) }
        'velopack'     { $tail = $latin.GetBytes(([string][char]0) * 16 + 'Velopack' + ([string][char]0) * 32) }
        'advinst'      { $tail = $latin.GetBytes(([string][char]0) * 16 + 'Advanced Installer' + ([string][char]0) * 32) }
        'wise'         { $tail = $latin.GetBytes(([string][char]0) * 16 + 'WiseMain' + ([string][char]0) * 32) }
        'setupfactory' { $tail = $latin.GetBytes(([string][char]0) * 16 + 'Setup Factory' + ([string][char]0) * 32) }
        'installaware' { $tail = $latin.GetBytes(([string][char]0) * 16 + 'InstallAware' + ([string][char]0) * 32) }
        'qtifw'        { $tail = $latin.GetBytes(([string][char]0) * 16 + 'Qt Installer Framework' + ([string][char]0) * 32) }
        'install4j'    { $tail = $latin.GetBytes(([string][char]0) * 16 + 'install4j' + ([string][char]0) * 32) }
        'bitrock'      { $tail = $latin.GetBytes(([string][char]0) * 16 + 'BitRock InstallBuilder' + ([string][char]0) * 32) }
        'clickteam'    { $tail = $latin.GetBytes(([string][char]0) * 16 + 'Clickteam Install Creator' + ([string][char]0) * 32) }
        # as a version resource would carry it: UTF-16, which the scan reads with NULs dropped
        'iexpress'     { $tail = [Text.Encoding]::Unicode.GetBytes('Win32 Cabinet Self-Extractor') }
        default { throw "unknown fixture family '$Family'" }
    }
    if ($Family -eq 'burn') {
        # rename the last section to .wixburn and put the Burn magic at its start
        $pe = [BitConverter]::ToInt32($bytes, 0x3C)
        $nSec = [BitConverter]::ToUInt16($bytes, $pe + 6)
        $optSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
        $o = $pe + 24 + $optSize + (($nSec - 1) * 40)
        $name = [Text.Encoding]::ASCII.GetBytes('.wixburn')
        [Array]::Copy($name, 0, $bytes, $o, 8)
        $rawPtr = [BitConverter]::ToUInt32($bytes, $o + 20)
        $bytes[$rawPtr] = 0x00; $bytes[$rawPtr + 1] = 0x43; $bytes[$rawPtr + 2] = 0xF1; $bytes[$rawPtr + 3] = 0x00
        [IO.File]::WriteAllBytes($Path, $bytes)
        return $Path
    }
    $out = New-Object IO.MemoryStream
    $out.Write($bytes, 0, $bytes.Length)
    $out.Write($pad, 0, 64)
    $out.Write($tail, 0, $tail.Length)
    if ($EmbedOle) {
        $out.Write($pad, 0, $pad.Length)
        $ole = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
        $out.Write($ole, 0, 8)
        $out.Write($pad, 0, 512)
    }
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    return $Path
}
