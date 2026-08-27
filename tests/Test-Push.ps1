<#
.SYNOPSIS
    The R2 upload transport, proved against a fake S3 endpoint that breaks on purpose.

.DESCRIPTION
    Push uploads a 15 GB package to R2 over a link that will drop. Every claim this code makes
    about surviving that - it resumes, it retries, it refuses a part that did not land intact -
    is worth nothing until something has actually broken the connection and the code carried on.
    So this harness runs a real S3 endpoint on loopback, stores real parts on disk, reassembles
    them, and hashes the result against the source file. Then it breaks it nine ways.

    What it covers:

      1. the signer, against AWS's own published test vector, plus the escaping case that
         vector structurally cannot reach
      2. part arithmetic at real catalog sizes, without moving a byte
      3. the DPAPI credential round trip
      4. a whole multipart upload, byte-identical at the far end
      5. a socket dropped mid-part; a 500 once; a 500 for ever; a wrong ETag
      6. resume - across a process restart, when R2 has forgotten a part, and when R2 has
         forgotten the upload entirely
      7. the refusals: the local file changed under a live upload, and the write lock
      8. Stop, leaving something resumable behind
      9. what is already in the bucket, and a wrong secret

    Sizing is deliberate. Parts are 64 KB against an ~800 KB file, so thirteen parts and the
    whole fault matrix run in seconds. R2's real 5 MiB floor and 64 MiB default are covered in
    section 2 as pure arithmetic, which needs no bytes at all. A slow test moving real volumes
    would cover the transport worse, not better.

    Runs unelevated, writes only to a temp sandbox, and never touches server\apps.json or the
    real credential store in %LOCALAPPDATA%.

    NOT covered, stated rather than implied: whether R2 accepts UNSIGNED-PAYLOAD at all,
    whether its part ETag really is the MD5, keep-alive, TLS, proxies, latency, and anything
    that only appears past 2 GB. The fake endpoint is a model of R2, not R2.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Push.ps1
#>
[CmdletBinding()]
param(
    [string]$ModulePath,
    # A real .iso to exercise the mount/enumerate/dismount path. Left empty, the harness looks
    # for the smallest one under Documents\Apps and skips loudly if there is none.
    [string]$IsoPath,
    [switch]$Live,
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
if (-not $ModulePath) { $ModulePath = Join-Path $repo 'tools\R2-Upload.ps1' }

$script:Pass = 0; $script:Fail = 0
function Assert-Equal([string]$What, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green }
    else { $script:Fail++
        Write-Host ("  FAIL  {0}`n          expected [{1}]`n          actual   [{2}]" -f $What, $Expected, $Actual) -ForegroundColor Red }
}
function Assert-True([string]$What, $Condition) { Assert-Equal $What $true ([bool]$Condition) }
function Write-Section([string]$Title) {
    Write-Host ''; Write-Host $Title -ForegroundColor Cyan; Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray
}

# The transport is dot-sourced whole rather than sliced out with the AST. The other harnesses
# extract functions because they are trapped inside a script that would otherwise run a GUI;
# R2-Upload.ps1 is a pure library with no such problem, and dot-sourcing is the stronger
# guarantee because it also proves the file parses and loads as a unit.
. $ModulePath

$tag       = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$sandbox   = Join-Path $env:TEMP "pc2go-push-$tag"
$script:S3 = $null
$port      = 0

$FakeKey    = 'AKIAFAKEFAKEFAKEFAKE'
$FakeSecret = 'fake-secret-do-not-use-anywhere-real-0000'
$Bucket     = 'pc2go-apps'

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

# ---------------------------------------------------------------- the fake S3 endpoint
#
# Raw TcpListener rather than HttpListener: no URL ACL and no elevation. It ends through a
# /__stop request because a listener parked in AcceptTcpClient cannot be interrupted by
# PowerShell.Stop() - Test-DeepBatch.ps1 learned that one the hard way, where the suite hung
# AFTER it had already passed.
#
# The genuinely new thing here is that this endpoint reads request BODIES. Every other server
# in this repo wraps the NetworkStream in a StreamReader to read the request line, and a
# StreamReader buffers ahead - it would silently swallow the first kilobytes of the body, so
# parts would arrive short with nothing saying why. Headers are therefore read one byte at a
# time off the raw stream, and the body by looping Read() for exactly Content-Length.
$s3Worker = {
    param($Root, $Port, $ModulePath, $Faults, $Log, $Bucket, $AccessKeyId, $Secret)

    . $ModulePath

    $uploadsDir = Join-Path $Root 'uploads'
    $objectsDir = Join-Path $Root 'objects'
    New-Item -ItemType Directory -Force -Path $uploadsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $objectsDir | Out-Null

    function Read-Line([IO.Stream]$s) {
        $sb = New-Object Text.StringBuilder
        while ($true) {
            $b = $s.ReadByte()
            if ($b -lt 0) { if ($sb.Length -eq 0) { return $null } else { break } }
            if ($b -eq 10) { break }                        # LF ends the line
            if ($b -ne 13) { [void]$sb.Append([char]$b) }   # ignore CR
        }
        return $sb.ToString()
    }

    function Send-Reply([IO.Stream]$s, [int]$Status, [string]$Reason, [string]$Body,
                        [hashtable]$Extra, [long]$DeclaredLength = -1) {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Body)
        $len   = $(if ($DeclaredLength -ge 0) { $DeclaredLength } else { $bytes.Length })
        $head  = "HTTP/1.1 $Status $Reason`r`nContent-Length: $len`r`nConnection: close`r`n"
        if ($Extra) { foreach ($k in $Extra.Keys) { $head += "$k`: $($Extra[$k])`r`n" } }
        $head += "`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $s.Write($hb, 0, $hb.Length)
        if ($bytes.Length) { $s.Write($bytes, 0, $bytes.Length) }
        $s.Flush()
    }

    function Get-Md5Hex([byte[]]$Bytes) {
        $m = [Security.Cryptography.MD5]::Create()
        try {
            $sb = New-Object Text.StringBuilder
            foreach ($b in $m.ComputeHash($Bytes)) { [void]$sb.AppendFormat('{0:x2}', $b) }
            return $sb.ToString()
        } finally { $m.Dispose() }
    }

    function Get-FlatName([string]$Key) { return ($Key -replace '[\\/:*?"<>|]', '_') }

    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()

    while ($true) {
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
            $stream = $client.GetStream()

            $requestLine = Read-Line $stream
            if (-not $requestLine) { try { $client.Close() } catch { }; continue }
            $bits   = $requestLine -split ' '
            $method = $bits[0]
            $target = $bits[1]

            $headers = @{}
            while ($true) {
                $h = Read-Line $stream
                if ([string]::IsNullOrEmpty($h)) { break }
                $i = $h.IndexOf(':')
                if ($i -gt 0) { $headers[$h.Substring(0, $i).Trim().ToLowerInvariant()] = $h.Substring($i + 1).Trim() }
            }

            $rawPath  = $target
            $rawQuery = ''
            $qi = $target.IndexOf('?')
            if ($qi -ge 0) { $rawPath = $target.Substring(0, $qi); $rawQuery = $target.Substring($qi + 1) }

            $query = @{}
            foreach ($pair in ($rawQuery -split '&')) {
                if (-not $pair) { continue }
                $e = $pair.IndexOf('=')
                if ($e -lt 0) { $query[[Uri]::UnescapeDataString($pair)] = '' }
                else { $query[[Uri]::UnescapeDataString($pair.Substring(0, $e))] =
                       [Uri]::UnescapeDataString($pair.Substring($e + 1)) }
            }

            $decoded = [Uri]::UnescapeDataString($rawPath)
            if ($decoded -eq '/__stop') {
                Send-Reply $stream 200 'OK' 'stopping' $null
                try { $client.Close() } catch { }
                try { $listener.Stop() } catch { }
                return
            }

            $key = $decoded.TrimStart('/')
            if ($key.StartsWith("$Bucket/")) { $key = $key.Substring($Bucket.Length + 1) }

            $partNumber = 0
            if ($query.ContainsKey('partNumber')) { $partNumber = [int]$query['partNumber'] }

            # -------- signature check, before anything else --------
            # Recomputed from what actually arrived on the wire, which is what catches the
            # classic SigV4 mistake of signing one set of headers and sending another. It is
            # symmetric with the client, so it cannot prove the signer is CORRECT - section 1's
            # known-answer vector does that - but it does prove the two halves agree, which no
            # amount of self-consistent client code would ever reveal.
            $authOk = $true
            if ($Faults.VerifySignatures) {
                $authOk = $false
                try {
                    $xh   = [string]$headers['x-amz-content-sha256']
                    $xd   = [string]$headers['x-amz-date']
                    $when = [datetime]::ParseExact($xd, 'yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture,
                                ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
                    $want = Get-SigV4Authorization -Method $method -Uri ([Uri]("http://" + $headers['host'] + $target)) `
                                -Headers @{ 'host' = [string]$headers['host']; 'x-amz-content-sha256' = $xh; 'x-amz-date' = $xd } `
                                -PayloadHash $xh -AccessKeyId $AccessKeyId -Secret $Secret -UtcNow $when
                    $authOk = ([string]$headers['authorization'] -eq $want.Authorization)
                } catch { $authOk = $false }
            }

            $bodyLen = 0
            if ($headers.ContainsKey('content-length')) { $bodyLen = [int]$headers['content-length'] }

            # -------- fault: drop the socket part-way through the body --------
            if ($method -eq 'PUT' -and $partNumber -gt 0 -and [int]$Faults.DropOnPart -eq $partNumber) {
                $Faults.DropOnPart = 0                     # one-shot, so the retry can succeed
                $eat  = New-Object byte[] 4096
                $seen = 0
                while ($seen -lt [Math]::Min($bodyLen, 8192)) {
                    $n = $stream.Read($eat, 0, $eat.Length)
                    if ($n -le 0) { break }
                    $seen += $n
                }
                [void]$Log.Add(@{ Method = $method; Key = $key; PartNumber = $partNumber
                                  Bytes = $seen; AuthOk = $authOk; Query = $rawQuery; Note = 'dropped' })
                try { $client.Client.Close() } catch { }   # abortive: no response at all
                try { $client.Close() } catch { }
                continue
            }

            $body = $null
            if ($bodyLen -gt 0) {
                $body = New-Object byte[] $bodyLen
                $got = 0
                while ($got -lt $bodyLen) {
                    $n = $stream.Read($body, $got, $bodyLen - $got)
                    if ($n -le 0) { break }
                    $got += $n
                }
                if ($got -ne $bodyLen) {
                    [void]$Log.Add(@{ Method = $method; Key = $key; PartNumber = $partNumber
                                      Bytes = $got; AuthOk = $authOk; Query = $rawQuery; Note = 'short body' })
                    Send-Reply $stream 400 'Bad Request' '<Error><Code>IncompleteBody</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
            }

            [void]$Log.Add(@{ Method = $method; Key = $key; PartNumber = $partNumber
                              Bytes = $bodyLen; AuthOk = $authOk; Query = $rawQuery; Note = '' })

            if (-not $authOk) {
                Send-Reply $stream 403 'Forbidden' '<Error><Code>SignatureDoesNotMatch</Code></Error>' $null
                try { $client.Close() } catch { }
                continue
            }

            # ---------------------------------------------------------- dispatch

            # CreateMultipartUpload
            if ($method -eq 'POST' -and $query.ContainsKey('uploads')) {
                $id = 'up-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
                New-Item -ItemType Directory -Force -Path (Join-Path $uploadsDir $id) | Out-Null
                Send-Reply $stream 200 'OK' "<InitiateMultipartUploadResult><Bucket>$Bucket</Bucket><Key>$key</Key><UploadId>$id</UploadId></InitiateMultipartUploadResult>" $null
                try { $client.Close() } catch { }
                continue
            }

            # UploadPart
            if ($method -eq 'PUT' -and $partNumber -gt 0) {
                $dir = Join-Path $uploadsDir ([string]$query['uploadId'])
                if (-not (Test-Path -LiteralPath $dir)) {
                    Send-Reply $stream 404 'Not Found' '<Error><Code>NoSuchUpload</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
                if ($Faults.Fail500Always -or [int]$Faults.Fail500OnPartAlways -eq $partNumber) {
                    Send-Reply $stream 500 'Internal Server Error' '<Error><Code>InternalError</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
                if ([int]$Faults.Fail500OnPart -eq $partNumber) {
                    $Faults.Fail500OnPart = 0
                    Send-Reply $stream 500 'Internal Server Error' '<Error><Code>InternalError</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
                [IO.File]::WriteAllBytes((Join-Path $dir "$partNumber.bin"), $body)
                $etag = Get-Md5Hex $body
                if ([int]$Faults.BadEtagOnPartAlways -eq $partNumber) { $etag = '0' * 32 }
                elseif ([int]$Faults.BadEtagOnPart -eq $partNumber) { $Faults.BadEtagOnPart = 0; $etag = '0' * 32 }
                Send-Reply $stream 200 'OK' '' @{ 'ETag' = "`"$etag`"" }
                try { $client.Close() } catch { }
                continue
            }

            # ListParts
            if ($method -eq 'GET' -and $query.ContainsKey('uploadId')) {
                $dir = Join-Path $uploadsDir ([string]$query['uploadId'])
                if ($Faults.NoSuchUploadOnList -or -not (Test-Path -LiteralPath $dir)) {
                    Send-Reply $stream 404 'Not Found' '<Error><Code>NoSuchUpload</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
                $xml = "<ListPartsResult><Bucket>$Bucket</Bucket><Key>$key</Key>"
                foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.bin' | Sort-Object { [int]$_.BaseName })) {
                    $n = [int]$f.BaseName
                    if ([int]$Faults.OmitPartOnList -eq $n) { continue }
                    $pb = [IO.File]::ReadAllBytes($f.FullName)
                    $xml += "<Part><PartNumber>$n</PartNumber><ETag>&quot;$(Get-Md5Hex $pb)&quot;</ETag><Size>$($pb.Length)</Size></Part>"
                }
                $xml += '<IsTruncated>false</IsTruncated></ListPartsResult>'
                Send-Reply $stream 200 'OK' $xml $null
                try { $client.Close() } catch { }
                continue
            }

            # CompleteMultipartUpload
            if ($method -eq 'POST' -and $query.ContainsKey('uploadId')) {
                $dir = Join-Path $uploadsDir ([string]$query['uploadId'])
                if (-not (Test-Path -LiteralPath $dir)) {
                    Send-Reply $stream 404 'Not Found' '<Error><Code>NoSuchUpload</Code></Error>' $null
                    try { $client.Close() } catch { }
                    continue
                }
                if ($Faults.FailCompleteWith) {
                    Send-Reply $stream 200 'OK' "<Error><Code>$($Faults.FailCompleteWith)</Code></Error>" $null
                    try { $client.Close() } catch { }
                    continue
                }
                # Reassembled in the order the CLIENT asked for, not in directory order. That is
                # what makes "the object is byte-identical" a real assertion rather than a
                # restatement of how the parts happened to be filed.
                $want = @()
                foreach ($m in [regex]::Matches([Text.Encoding]::UTF8.GetString($body), '<PartNumber>(\d+)</PartNumber>')) {
                    $want += [int]$m.Groups[1].Value
                }
                $dest = Join-Path $objectsDir (Get-FlatName $key)
                $md5s = ''
                $out  = New-Object IO.FileStream($dest, [IO.FileMode]::Create, [IO.FileAccess]::Write)
                try {
                    foreach ($n in $want) {
                        $pb = [IO.File]::ReadAllBytes((Join-Path $dir "$n.bin"))
                        $out.Write($pb, 0, $pb.Length)
                        $md5s += Get-Md5Hex $pb
                    }
                } finally { $out.Dispose() }
                # S3's multipart ETag shape: md5-of-the-part-md5s, then a dash and the count.
                $etag = (Get-Md5Hex ([Text.Encoding]::ASCII.GetBytes($md5s))) + '-' + $want.Count
                Set-Content -LiteralPath "$dest.etag" -Value $etag -Encoding ASCII
                Send-Reply $stream 200 'OK' "<CompleteMultipartUploadResult><Bucket>$Bucket</Bucket><Key>$key</Key><ETag>&quot;$etag&quot;</ETag></CompleteMultipartUploadResult>" $null
                try { $client.Close() } catch { }
                continue
            }

            # AbortMultipartUpload
            if ($method -eq 'DELETE' -and $query.ContainsKey('uploadId')) {
                $dir = Join-Path $uploadsDir ([string]$query['uploadId'])
                if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
                Send-Reply $stream 204 'No Content' '' $null
                try { $client.Close() } catch { }
                continue
            }

            $flat = Join-Path $objectsDir (Get-FlatName $key)

            if ($method -eq 'HEAD') {
                if (Test-Path -LiteralPath $flat) {
                    $len  = (Get-Item -LiteralPath $flat).Length
                    $etag = 'unknown'
                    if (Test-Path -LiteralPath "$flat.etag") { $etag = (Get-Content -LiteralPath "$flat.etag" -Raw).Trim() }
                    # A HEAD carries no body but must still declare the object's length, which is
                    # the whole point of the request - hence DeclaredLength.
                    Send-Reply $stream 200 'OK' '' @{ 'ETag' = "`"$etag`"" } $len
                } else {
                    Send-Reply $stream 404 'Not Found' '' $null
                }
                try { $client.Close() } catch { }
                continue
            }

            if ($method -eq 'PUT') {                       # single-shot PutObject
                [IO.File]::WriteAllBytes($flat, $body)
                $etag = Get-Md5Hex $body
                Set-Content -LiteralPath "$flat.etag" -Value $etag -Encoding ASCII
                Send-Reply $stream 200 'OK' '' @{ 'ETag' = "`"$etag`"" }
                try { $client.Close() } catch { }
                continue
            }

            if ($method -eq 'DELETE') {
                if (Test-Path -LiteralPath $flat) { Remove-Item -LiteralPath $flat -Force -ErrorAction SilentlyContinue }
                Send-Reply $stream 204 'No Content' '' $null
                try { $client.Close() } catch { }
                continue
            }

            Send-Reply $stream 404 'Not Found' '<Error><Code>NoSuchKey</Code></Error>' $null
        } catch {
        } finally { try { $client.Close() } catch { } }
    }
    try { $listener.Stop() } catch { }
}

# ---------------------------------------------------------------- sidecar, in miniature
# Enough of what the editor will persist to drive resume across a simulated restart.
function Save-StateFile([string]$Path, $State) {
    $doc = @{ version = 1; updatedUtc = ([datetime]::UtcNow.ToString('o')); apps = @{ 'example-app' = $State } }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-StateFile([string]$Path) {
    $j = ((Get-Content -LiteralPath $Path -Raw).TrimStart([char]0xFEFF)) | ConvertFrom-Json
    $a = $j.apps.'example-app'
    $s = @{}
    foreach ($p in $a.PSObject.Properties) { $s[$p.Name] = $p.Value }
    if ($s.upload) {
        $u = @{}
        foreach ($p in $s.upload.PSObject.Properties) { $u[$p.Name] = $p.Value }
        $parts = @{}
        if ($u.parts) { foreach ($p in $u.parts.PSObject.Properties) { $parts[$p.Name] = [string]$p.Value } }
        $u.parts  = $parts
        $s.upload = $u
    }
    return $s
}
function New-State([string]$LocalPath, [string]$Sha) {
    $fi = Get-Item -LiteralPath $LocalPath
    return @{ localPath = $LocalPath; sizeBytes = [long]$fi.Length
              mtimeUtc  = $fi.LastWriteTimeUtc.ToString('o'); sha256 = $Sha
              key = 'files/example-app/Example.bin'; upload = $null; remote = $null }
}
function New-Progress {
    return [hashtable]::Synchronized(@{
        Cancel = $false; AppBytes = [long]0; AppTotal = [long]0; Part = 0; PartCount = 0
        Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })
}
function Get-PutCount($Log, [int]$PartNumber) {
    return @($Log | Where-Object { $_.Method -eq 'PUT' -and [int]$_.PartNumber -eq $PartNumber }).Count
}

# The same AST lift the other harnesses use, here only to read one function's text back out.
function Get-FunctionSource([string]$Source, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "Could not extract $Name" }
    return $fn.Extent.Text
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Write-Host "Sandbox: $sandbox" -ForegroundColor DarkGray

    # ============================================================== 1. the signer
    Write-Section '1. SigV4: the published vector, and the escaping it cannot reach'

    $v = Get-SigV4Authorization -Method 'GET' -Uri ([Uri]'https://example.amazonaws.com/') `
            -Headers @{ 'host' = 'example.amazonaws.com'; 'x-amz-date' = '20150830T123600Z' } `
            -PayloadHash 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
            -AccessKeyId 'AKIDEXAMPLE' -Secret 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' `
            -UtcNow ([datetime]::new(2015, 8, 30, 12, 36, 0, [DateTimeKind]::Utc)) `
            -Region 'us-east-1' -Service 'service'
    Assert-Equal 'AWS get-vanilla: the canonical request hashes to the documented value' `
        'bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63' `
        (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($v.CanonicalRequest)))
    Assert-Equal 'AWS get-vanilla: the signature matches the documented value' `
        '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31' $v.Signature

    Assert-Equal 'a space escapes to %20, never +'      'a%20b' (ConvertTo-RfcEscaped 'a b')
    Assert-Equal 'a plus escapes to %2B'                'a%2Bb' (ConvertTo-RfcEscaped 'a+b')
    Assert-Equal 'a tilde is unreserved and left alone' 'a~b'   (ConvertTo-RfcEscaped 'a~b')
    Assert-Equal 'path separators survive escaping' '/b/x%20y/z.exe' (ConvertTo-CanonicalUri '/b/x y/z.exe')
    Assert-Equal 'a valueless query param canonicalises WITH the equals sign' `
        'uploads=' (ConvertTo-CanonicalQuery @{ 'uploads' = '' })
    Assert-Equal 'query params sort by name' 'max-parts=1000&uploadId=a%2Fb' `
        (ConvertTo-CanonicalQuery @{ 'uploadId' = 'a/b'; 'max-parts' = '1000' })

    # The regression the AWS vector structurally cannot catch: its path is a bare "/", so it
    # never re-canonicalises an already-escaped AbsolutePath. Double-escaping there would show
    # up only as SignatureDoesNotMatch against real R2, on the first key with a space in it.
    $awk = [Uri]("https://h.example.com" + (ConvertTo-CanonicalUri '/pc2go-apps/files/my app/Set up (x64)+v2.exe'))
    $sa  = Get-SigV4Authorization -Method 'PUT' -Uri $awk `
            -Headers @{ 'host' = $awk.Authority; 'x-amz-content-sha256' = 'UNSIGNED-PAYLOAD' } `
            -PayloadHash 'UNSIGNED-PAYLOAD' -AccessKeyId 'AK' -Secret 'SK' `
            -UtcNow ([datetime]::new(2026, 8, 19, 1, 2, 3, [DateTimeKind]::Utc))
    $signedPath = ($sa.CanonicalRequest -split "`n")[1]
    Assert-True  'an awkward key is single-escaped, not double-escaped' (-not ($signedPath -match '%25'))
    Assert-Equal 'and what is signed is exactly what goes on the wire' $awk.AbsolutePath $signedPath

    # ============================================================== 2. part arithmetic
    Write-Section '2. Part sizing at real catalog sizes (no bytes moved)'

    Assert-Equal 'the default part size is 64 MiB' 67108864 (Get-R2PartSize -SizeBytes 100MB)
    Assert-Equal 'the 15 GB package comes to 224 parts' 224 `
        (Get-R2PartCount -SizeBytes 15032385536 -PartSizeBytes (Get-R2PartSize -SizeBytes 15032385536))
    Assert-Equal 'a 5 MB file is a single part' 1 `
        (Get-R2PartCount -SizeBytes 5242880 -PartSizeBytes (Get-R2PartSize -SizeBytes 5242880))
    Assert-True 'a 700 GB file still fits under the 10,000-part cap' `
        ((Get-R2PartCount -SizeBytes 700GB -PartSizeBytes (Get-R2PartSize -SizeBytes 700GB)) -le 10000)

    # The rule R2 enforces at Complete - which is where a violation surfaces, after every byte
    # has already gone up.
    $ps = 64KB; $sz = [long]800KB + 123
    $cnt  = Get-R2PartCount -SizeBytes $sz -PartSizeBytes $ps
    $lens = @(1..$cnt | ForEach-Object { Get-R2ExpectedPartLength -SizeBytes $sz -PartSizeBytes $ps -PartNumber $_ -PartCount $cnt })
    Assert-Equal 'every part but the last is exactly the part size' 0 `
        (@($lens[0..($cnt - 2)] | Where-Object { $_ -ne $ps }).Count)
    Assert-True  'the last part is non-empty and no larger than a full part' `
        ($lens[$cnt - 1] -gt 0 -and $lens[$cnt - 1] -le $ps)
    Assert-Equal 'the parts add up to the whole file' $sz (($lens | Measure-Object -Sum).Sum)

    # ============================================================== 3. credentials
    Write-Section '3. Credentials: the DPAPI round trip, and a readable failure'

    $credPath = Join-Path $sandbox 'creds.xml'
    Save-R2Credential -AccountId 'acct123' -AccessKeyId $FakeKey -Secret $FakeSecret `
                      -Bucket $Bucket -Endpoint '' -Path $credPath
    $back = Get-R2Credential -Path $credPath
    Assert-Equal 'the access key id survives the round trip' $FakeKey    $back.AccessKeyId
    Assert-Equal 'the secret survives the round trip'        $FakeSecret $back.Secret
    Assert-Equal 'a blank endpoint is derived from the account id' `
        'https://acct123.r2.cloudflarestorage.com' $back.Endpoint
    $onDisk = Get-Content -LiteralPath $credPath -Raw
    Assert-True 'the secret is NOT on disk in cleartext'        (-not ($onDisk -match [regex]::Escape($FakeSecret)))
    Assert-True 'the access key id is NOT on disk in cleartext' (-not ($onDisk -match [regex]::Escape($FakeKey)))
    Assert-True 'a missing credential file reads as absent, not as an error' `
        ($null -eq (Get-R2Credential -Path (Join-Path $sandbox 'nope.xml')))

    $corrupt = Join-Path $sandbox 'creds-bad.xml'
    (Get-Content -LiteralPath $credPath -Raw).Replace('01000000', '01000001') |
        Set-Content -LiteralPath $corrupt -Encoding UTF8
    $msg = ''
    try { Get-R2Credential -Path $corrupt | Out-Null } catch { $msg = $_.Exception.Message }
    Assert-True 'an unreadable blob gives a sentence, not "Key not valid for use in specified state"' `
        ($msg -match 'cannot be read by this Windows account' -and $msg -notmatch 'Key not valid')

    # ============================================================== the endpoint
    $bucketRoot = Join-Path $sandbox 'r2'
    New-Item -ItemType Directory -Force -Path $bucketRoot | Out-Null

    $faults = [hashtable]::Synchronized(@{
        VerifySignatures = $true; DropOnPart = 0; Fail500OnPart = 0; Fail500Always = $false
        Fail500OnPartAlways = 0; BadEtagOnPart = 0; BadEtagOnPartAlways = 0
        NoSuchUploadOnList = $false; OmitPartOnList = 0; FailCompleteWith = ''
    })
    $log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))

    $port = Get-FreePort
    $script:S3 = [powershell]::Create()
    [void]$script:S3.AddScript($s3Worker).AddArgument($bucketRoot).AddArgument($port).
           AddArgument($ModulePath).AddArgument($faults).AddArgument($log).
           AddArgument($Bucket).AddArgument($FakeKey).AddArgument($FakeSecret)
    [void]$script:S3.BeginInvoke()
    Start-Sleep -Milliseconds 800

    $cred = Get-R2CredentialObject -AccountId 'acct123' -AccessKeyId $FakeKey -Secret $FakeSecret `
                                   -Bucket $Bucket -Endpoint "http://127.0.0.1:$port"

    # ~800 KB of non-repeating bytes, so a mis-ordered or duplicated part cannot hash correctly
    # by luck the way a file of zeroes would.
    $srcDir = Join-Path $sandbox 'src'
    New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    $srcFile = Join-Path $srcDir 'Example.bin'
    $rand = New-Object Random(20260819)
    $blob = New-Object byte[] (800KB + 777)
    $rand.NextBytes($blob)
    [IO.File]::WriteAllBytes($srcFile, $blob)
    $srcSha      = (Get-FileHash -LiteralPath $srcFile -Algorithm SHA256).Hash
    $partSize    = 64KB
    $expectParts = Get-R2PartCount -SizeBytes $blob.Length -PartSizeBytes $partSize
    $statePath   = Join-Path $sandbox '.push-state.json'
    $key         = 'files/example-app/Example.bin'
    $objDir      = Join-Path $bucketRoot 'objects'

    # ============================================================== 4. the happy path
    Write-Section "4. A whole multipart upload ($expectParts parts), reassembled and hashed"

    $st = New-State $srcFile $srcSha
    $pr = New-Progress
    $r = Invoke-R2Upload -Credential $cred -Key $key -LocalPath $srcFile -State $st -Progress $pr `
                         -PartSizeBytes $partSize -OnStateChanged { Save-StateFile $statePath $st }
    Assert-True  'the upload reports success'              $r.Ok
    Assert-Equal 'every part was uploaded'                 $expectParts $r.Uploaded
    Assert-Equal 'nothing was skipped on a fresh upload'   0 $r.Skipped
    Assert-Equal 'every request carried a valid signature' 0 (@($log | Where-Object { -not $_.AuthOk }).Count)
    Assert-Equal 'the object is byte-identical to the source' $srcSha `
        (Get-FileHash -LiteralPath (Join-Path $objDir 'files_example-app_Example.bin') -Algorithm SHA256).Hash
    Assert-Equal 'progress counted exactly the file size'  ([long]$blob.Length) ([long]$pr.AppBytes)
    Assert-True  'the sidecar cleared the in-flight upload' ($null -eq $st.upload)
    Assert-True  'and recorded the remote object'           ($null -ne $st.remote)
    Assert-True  'the sidecar on disk carries no BOM' (([IO.File]::ReadAllBytes($statePath))[0] -ne 0xEF)
    Assert-True  'and the atomic write left no .tmp behind' (-not (Test-Path -LiteralPath "$statePath.tmp"))

    # ============================================================== 5. faults
    Write-Section '5. A dropped socket, a 500, and a wrong ETag'

    $log.Clear()
    $faults.DropOnPart = 3
    $st = New-State $srcFile $srcSha
    $pr = New-Progress
    $r = Invoke-R2Upload -Credential $cred -Key 'files/example-app/drop.bin' -LocalPath $srcFile `
                         -State $st -Progress $pr -PartSizeBytes $partSize -BackoffBaseSeconds 0.05 `
                         -OnStateChanged { }
    Assert-True  'a socket dropped mid-part still finishes the upload' $r.Ok
    Assert-Equal 'part 3 was sent exactly twice' 2 (Get-PutCount $log 3)
    Assert-Equal 'and part 4 only once'          1 (Get-PutCount $log 4)
    Assert-Equal 'the object survived the drop byte-identical' $srcSha `
        (Get-FileHash -LiteralPath (Join-Path $objDir 'files_example-app_drop.bin') -Algorithm SHA256).Hash
    Assert-Equal 'progress was wound back, not double-counted' ([long]$blob.Length) ([long]$pr.AppBytes)

    $log.Clear()
    $faults.Fail500OnPart = 2
    $st = New-State $srcFile $srcSha
    $r = Invoke-R2Upload -Credential $cred -Key 'files/example-app/f500.bin' -LocalPath $srcFile `
                         -State $st -Progress (New-Progress) -PartSizeBytes $partSize `
                         -BackoffBaseSeconds 0.05 -OnStateChanged { }
    Assert-True  'a single 500 is retried and the upload completes' $r.Ok
    Assert-Equal 'part 2 was sent twice'        2 (Get-PutCount $log 2)
    Assert-Equal 'and no other part was resent' 1 (Get-PutCount $log 1)

    $log.Clear()
    $faults.Fail500OnPartAlways = 2
    $st = New-State $srcFile $srcSha
    $r = Invoke-R2Upload -Credential $cred -Key 'files/example-app/f500a.bin' -LocalPath $srcFile `
                         -State $st -Progress (New-Progress) -PartSizeBytes $partSize -MaxAttempts 3 `
                         -BackoffBaseSeconds 0.05 -OnStateChanged { }
    $faults.Fail500OnPartAlways = 0
    Assert-True  'a part that never succeeds fails the app'  (-not $r.Ok)
    Assert-True  'and names the part and the attempt count'  ($r.Message -match 'part 2 of \d+ failed after 3 attempt')
    Assert-Equal 'it gave up after exactly MaxAttempts tries' 3 (Get-PutCount $log 2)
    Assert-Equal 'it did NOT complete the upload' 0 (@($log | Where-Object { $_.Method -eq 'POST' -and $_.Query -match 'uploadId' }).Count)
    Assert-Equal 'and it did NOT abort it either' 0 (@($log | Where-Object { $_.Method -eq 'DELETE' }).Count)
    Assert-True  'the sidecar kept a resumable uploadId'     ($null -ne $st.upload -and [string]$st.upload.uploadId)
    Assert-True  'along with the parts that did land'        ($st.upload.parts.Count -ge 1)

    $log.Clear()
    $faults.BadEtagOnPartAlways = 1
    $st = New-State $srcFile $srcSha
    $r = Invoke-R2Upload -Credential $cred -Key 'files/example-app/etag.bin' -LocalPath $srcFile `
                         -State $st -Progress (New-Progress) -PartSizeBytes $partSize -MaxAttempts 2 `
                         -BackoffBaseSeconds 0.05 -OnStateChanged { }
    $faults.BadEtagOnPartAlways = 0
    Assert-True  'a part whose ETag does not match what was sent is refused' (-not $r.Ok)
    Assert-Equal 'it is retried rather than accepted' 2 (Get-PutCount $log 1)
    Assert-True  'and the upload is never completed' `
        (-not (Test-Path -LiteralPath (Join-Path $objDir 'files_example-app_etag.bin')))

    # ============================================================== 6. resume
    Write-Section '6. Resume: across a restart, a forgotten part, a forgotten upload'

    $log.Clear()
    $faults.Fail500OnPartAlways = 5
    $st = New-State $srcFile $srcSha
    $r = Invoke-R2Upload -Credential $cred -Key 'files/example-app/resume.bin' -LocalPath $srcFile `
                         -State $st -Progress (New-Progress) -PartSizeBytes $partSize -MaxAttempts 2 `
                         -BackoffBaseSeconds 0.05 -OnStateChanged { Save-StateFile $statePath $st }
    Assert-True 'the first attempt stops at the broken part' (-not $r.Ok)

    $faults.Fail500OnPartAlways = 0
    $log.Clear()
    # The restart: nothing in memory survives, the sidecar is re-read from disk.
    $st2 = Read-StateFile $statePath
    $r2 = Invoke-R2Upload -Credential $cred -Key 'files/example-app/resume.bin' -LocalPath $srcFile `
                          -State $st2 -Progress (New-Progress) -PartSizeBytes $partSize `
                          -BackoffBaseSeconds 0.05 -OnStateChanged { Save-StateFile $statePath $st2 }
    Assert-True  'the resumed upload succeeds' $r2.Ok
    Assert-True  'it asked R2 what was already there' (@($log | Where-Object { $_.Method -eq 'GET' }).Count -ge 1)
    Assert-True  'it skipped the parts already uploaded' ($r2.Skipped -ge 3)
    Assert-Equal 'uploaded plus skipped is the whole file' $expectParts ($r2.Uploaded + $r2.Skipped)
    Assert-Equal 'no part was uploaded twice across the resume' 0 `
        (@(1..$expectParts | Where-Object { (Get-PutCount $log $_) -gt 1 }).Count)
    Assert-Equal 'and the resumed object is byte-identical' $srcSha `
        (Get-FileHash -LiteralPath (Join-Path $objDir 'files_example-app_resume.bin') -Algorithm SHA256).Hash

    # R2 is the authority: a part the sidecar claims but ListParts does not report goes again.
    $log.Clear()
    $faults.Fail500OnPartAlways = 6
    $st = New-State $srcFile $srcSha
    [void](Invoke-R2Upload -Credential $cred -Key 'files/example-app/omit.bin' -LocalPath $srcFile `
                           -State $st -Progress (New-Progress) -PartSizeBytes $partSize -MaxAttempts 1 `
                           -BackoffBaseSeconds 0.05 -OnStateChanged { })
    $faults.Fail500OnPartAlways = 0
    $faults.OmitPartOnList = 2
    $log.Clear()
    $r3 = Invoke-R2Upload -Credential $cred -Key 'files/example-app/omit.bin' -LocalPath $srcFile `
                          -State $st -Progress (New-Progress) -PartSizeBytes $partSize `
                          -BackoffBaseSeconds 0.05 -OnStateChanged { }
    $faults.OmitPartOnList = 0
    Assert-True  'the upload completes when R2 has lost a part the sidecar claimed' $r3.Ok
    Assert-Equal 'and the part R2 did not report was sent again' 1 (Get-PutCount $log 2)

    $log.Clear()
    $st = New-State $srcFile $srcSha
    $st.upload = @{ uploadId = 'up-doesnotexist'; partSizeBytes = $partSize
                    startedUtc = ([datetime]::UtcNow.ToString('o')); parts = @{ '1' = 'deadbeef' } }
    $faults.NoSuchUploadOnList = $true
    $r4 = Invoke-R2Upload -Credential $cred -Key 'files/example-app/gone.bin' -LocalPath $srcFile `
                          -State $st -Progress (New-Progress) -PartSizeBytes $partSize `
                          -BackoffBaseSeconds 0.05 -OnStateChanged { }
    $faults.NoSuchUploadOnList = $false
    Assert-True  'an uploadId R2 has forgotten is discarded rather than fatal' $r4.Ok
    Assert-True  'a fresh multipart upload was started' (@($log | Where-Object { $_.Query -match 'uploads' }).Count -ge 1)
    Assert-Equal 'and every part went up from scratch'  $expectParts $r4.Uploaded

    # ============================================================== 7. refusals
    Write-Section '7. Refusals: the file changed, and the write lock'

    $changed = Join-Path $srcDir 'Changed.bin'
    [IO.File]::WriteAllBytes($changed, $blob)
    $st = New-State $changed (Get-FileHash -LiteralPath $changed -Algorithm SHA256).Hash
    $faults.Fail500OnPartAlways = 4
    [void](Invoke-R2Upload -Credential $cred -Key 'files/example-app/changed.bin' -LocalPath $changed `
                           -State $st -Progress (New-Progress) -PartSizeBytes $partSize -MaxAttempts 1 `
                           -BackoffBaseSeconds 0.05 -OnStateChanged { })
    $faults.Fail500OnPartAlways = 0
    Assert-True 'a partial upload left an uploadId to resume from' ([string]$st.upload.uploadId).Length -gt 0

    Start-Sleep -Milliseconds 1100                     # so the mtime genuinely differs
    $blob2 = New-Object byte[] (800KB + 777)
    $rand.NextBytes($blob2)
    [IO.File]::WriteAllBytes($changed, $blob2)
    $newSha = (Get-FileHash -LiteralPath $changed -Algorithm SHA256).Hash

    $log.Clear()
    $r5 = Invoke-R2Upload -Credential $cred -Key 'files/example-app/changed.bin' -LocalPath $changed `
                          -State $st -Progress (New-Progress) -PartSizeBytes $partSize `
                          -BackoffBaseSeconds 0.05 -OnStateChanged { }
    Assert-True  'a file edited under a live upload starts over rather than splicing' $r5.Ok
    Assert-True  'the stale multipart upload was aborted' (@($log | Where-Object { $_.Method -eq 'DELETE' }).Count -ge 1)
    Assert-Equal 'every part was re-sent' $expectParts $r5.Uploaded
    Assert-Equal 'and the object is the NEW bytes, not a splice of both' $newSha `
        (Get-FileHash -LiteralPath (Join-Path $objDir 'files_example-app_changed.bin') -Algorithm SHA256).Hash

    # The FileShare.Read handle Invoke-R2Upload holds for the whole upload is what stops the
    # file being swapped between part 1 and part 224.
    $locked = Join-Path $srcDir 'Locked.bin'
    [IO.File]::WriteAllBytes($locked, $blob)
    $holder = New-Object IO.FileStream($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $denied = $false
    try {
        try {
            $w = New-Object IO.FileStream($locked, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $w.Dispose()
        } catch { $denied = $true }
    } finally { $holder.Dispose() }
    Assert-True 'while the upload holds the file, another writer is denied' $denied

    # ============================================================== 8. stop
    Write-Section '8. Stop, and what it leaves behind'

    $log.Clear()
    $st = New-State $srcFile $srcSha
    $pr = New-Progress
    $pr.Cancel = $true
    $r6 = Invoke-R2Upload -Credential $cred -Key 'files/example-app/cancel.bin' -LocalPath $srcFile `
                          -State $st -Progress $pr -PartSizeBytes $partSize -BackoffBaseSeconds 0.05 `
                          -OnStateChanged { }
    Assert-True  'Stop reports cancelled rather than failed' ($r6.Cancelled -and -not $r6.Ok)
    Assert-Equal 'Stop does NOT abort the multipart upload'  0 (@($log | Where-Object { $_.Method -eq 'DELETE' }).Count)
    Assert-True  'and leaves a resumable uploadId behind'    ($null -ne $st.upload -and [string]$st.upload.uploadId)
    Assert-True  'nothing was completed' (-not (Test-Path -LiteralPath (Join-Path $objDir 'files_example-app_cancel.bin')))

    # ============================================================== 9. the bucket, and a bad key
    Write-Section '9. What is already there, and a wrong secret'

    $info = Get-R2ObjectInfo -Credential $cred -Key $key
    Assert-True  'HEAD finds an object that is there' $info.Exists
    Assert-Equal 'and reports its real size'          ([long]$blob.Length) ([long]$info.Size)
    $missing = Get-R2ObjectInfo -Credential $cred -Key 'files/example-app/never-uploaded.bin'
    Assert-True  'HEAD reports one that is not there' (-not $missing.Exists)
    Assert-Equal 'as a 404 rather than an error'      404 $missing.StatusCode

    $log.Clear()
    $badCred = Get-R2CredentialObject -AccountId 'acct123' -AccessKeyId $FakeKey -Secret 'wrong-secret' `
                                      -Bucket $Bucket -Endpoint "http://127.0.0.1:$port"
    $err = ''
    try {
        [void](Invoke-R2Upload -Credential $badCred -Key 'files/example-app/badsig.bin' -LocalPath $srcFile `
                               -State (New-State $srcFile $srcSha) -Progress (New-Progress) `
                               -PartSizeBytes $partSize -BackoffBaseSeconds 0.05 -OnStateChanged { })
    } catch { $err = $_.Exception.Message }
    Assert-True 'a wrong secret is refused by the endpoint'      ($err -match '403|SignatureDoesNotMatch')
    Assert-True 'the endpoint saw the signature as invalid'      (@($log | Where-Object { -not $_.AuthOk }).Count -ge 1)
    Assert-Equal 'and a 403 is NOT retried - it would fail identically five times' `
        1 (@($log | Where-Object { $_.Query -match 'uploads' }).Count)

    # ============================================================== 10. the editor's wiring
    Write-Section '10. The editor: the button, the bar, and the sidecar surviving a save'

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $editorPath = Join-Path $repo 'tools\Catalog-Editor.ps1'
    $edSrc = Get-Content -LiteralPath $editorPath -Raw

    # Every blocking MessageBox on the Push path would be a hang in an unattended run and an
    # untestable branch here. The only one allowed is Invoke-Guarded's last-resort fallback,
    # which runs when the overlay ITSELF is what broke.
    Assert-Equal 'the editor still has exactly one [Windows.MessageBox], the guarded fallback' `
        1 ([regex]::Matches($edSrc, '\[Windows\.MessageBox\]').Count)
    Assert-True 'Push-to-R2 reports through the in-window overlay, not a MessageBox' `
        ($edSrc -match 'function Show-CredentialPrompt')

    # The split the other GUI harnesses use: everything up to ShowDialog(), which blocks.
    $showAt = $edSrc.IndexOf('[void]$window.ShowDialog()')
    Assert-True 'the editor still ends in the ShowDialog marker the harnesses split on' ($showAt -gt 0)

    $edSandbox = Join-Path $sandbox 'editor'
    New-Item -ItemType Directory -Force -Path "$edSandbox\server" | Out-Null
    $miniCatalog = @{
        manifestVersion = 1; updated = '2026-08-19'
        apps = @(@{ id = 'example-app'; name = 'Example App'; category = 'Apps'
                    sizeBytes = [long]$blob.Length; url = 'https://apps.example.com/files/old.bin'
                    sha256 = $srcSha; silentArgs = '/S'; verifyPaths = @('%ProgramFiles%\Example\app.exe')
                    uninstall = @{ command = 'x'; args = 'y'; detect = 'z' }
                    iconUrl = 'https://apps.example.com/icons/example.png' })
    }
    $edCatalog = "$edSandbox\server\apps.json"
    [IO.File]::WriteAllText($edCatalog, ($miniCatalog | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    $edState = "$edSandbox\.push-state.json"

    . ([scriptblock]::Create($edSrc.Substring(0, $showAt))) `
        -CatalogPath $edCatalog -PackageDir "$edSandbox\packages" `
        -BaseUrl "http://127.0.0.1:$port" -R2CredentialPath "$edSandbox\creds.xml" `
        -R2Endpoint "http://127.0.0.1:$port" -PushStatePath $edState

    Assert-True  'the editor window builds with the Push controls'  ($null -ne $window)
    Assert-True  'BtnPush resolved (so it is in the FindName loop)' ($null -ne $BtnPush)
    Assert-True  'BtnPushCancel resolved'                           ($null -ne $BtnPushCancel)
    Assert-True  'the PasswordBox for the R2 secret resolved'       ($null -ne $PwdR2Secret)
    Assert-Equal 'the progress strip starts hidden'   'Collapsed' ([string]$PushBar.Visibility)
    Assert-Equal 'the credential fields start hidden' 'Collapsed' ([string]$OverlayInput.Visibility)
    Assert-Equal 'the bar is scaled in tenths of a percent, not percent' 1000 ([int]$PushProgressBar.Maximum)

    # Show-Notice must put the credential fields away, or an R2 secret box turns up under an
    # unrelated message.
    $OverlayInput.Visibility = 'Visible'
    Show-Notice 'x' 'y'
    Assert-Equal 'Show-Notice collapses the credential fields' 'Collapsed' ([string]$OverlayInput.Visibility)
    $OverlayInput.Visibility = 'Visible'
    Show-Confirm 'x' 'y' 'OK' { }
    Assert-Equal 'Show-Confirm collapses them too' 'Collapsed' ([string]$OverlayInput.Visibility)
    $Overlay.Visibility = 'Collapsed'

    # The prompt should ask only for what a person had to go and create. The account id is
    # already on this machine in wrangler's cache, so leaving it blank would be asking them to
    # go and look it up for no reason.
    New-Item -ItemType Directory -Force -Path "$edSandbox\.wrangler\cache" | Out-Null
    Set-Content -LiteralPath "$edSandbox\.wrangler\cache\wrangler-account.json" `
        -Value '{"account":{"id":"acctfromcache","name":"Test"}}' -Encoding ASCII
    $script:RepoRoot = $edSandbox
    Show-CredentialPrompt { }
    Assert-Equal 'the account id is pre-filled from wrangler''s cache' 'acctfromcache' ([string]$TxtR2Account.Text)
    Assert-Equal 'the credential fields are shown for this one' 'Visible' ([string]$OverlayInput.Visibility)
    Assert-Equal 'and the secret box starts empty' '' ([string]$PwdR2Secret.Password)
    $Overlay.Visibility = 'Collapsed'
    $OverlayInput.Visibility = 'Collapsed'

    # ---- the sidecar is the point of the whole thing: it must outlive a save ----
    $app = @($script:Catalog.apps)[0]
    Set-LocalFileFor $app $srcFile
    Set-PushHashFor  $app $srcSha ([long]$blob.Length)
    Assert-Equal 'the local file is found before saving' $srcFile (Get-LocalFileFor $app)
    Assert-Equal 'the R2 key is files/<id>/<leaf>' 'files/example-app/Example.bin' (Get-AppKey $app)
    Assert-Equal 'and the url is the live host plus that key' `
        "http://127.0.0.1:$port/files/example-app/Example.bin" (Get-AppUrl $app)

    # Save-AppSources is the seam between the dialog and the sidecar. The dialog only writes the
    # _localFile FIELD - it is lifted out of the editor and run standalone by two other
    # harnesses, so it must not depend on the sidecar - and the main window persists it here.
    # Asserting the sidecar functions directly missed a regression that broke both of those
    # harnesses, so this drives the seam the main window actually uses.
    $script:PushState = $null
    Remove-Item -LiteralPath $edState -Force -ErrorAction SilentlyContinue
    Set-Field $app '_localFile' $srcFile
    Save-AppSources $app
    Assert-True  'Save-AppSources wrote the sidecar from the field the dialog set' `
        (Test-Path -LiteralPath $edState)
    Assert-Equal 'and the local file resolves through it' $srcFile (Get-LocalFileFor $app)
    Assert-True  'the dialog itself has no sidecar dependency (it is lifted standalone elsewhere)' `
        (-not ((Get-FunctionSource $edSrc 'Show-AppDialog') -match 'Set-LocalFileFor|Set-PushHashFor|Save-PushState'))

    [void](Export-Catalog)
    $savedRaw = Get-Content -LiteralPath $edCatalog -Raw
    Assert-True  'Export-Catalog still strips _localFile from the published catalog' `
        (-not ($savedRaw -match '_localFile'))
    Assert-True  'and never leaks a local disk path into it' (-not ($savedRaw -match 'Example\.bin'))
    # The bug this whole sidecar exists for: after one save, _localFile is gone, and without the
    # sidecar Push could not find a single byte.
    Remove-Field $app '_localFile'
    $script:PushState = $null
    Assert-Equal 'the local file is STILL found after a save wipes _localFile' $srcFile (Get-LocalFileFor $app)
    Assert-True  'the sidecar on disk has no BOM' (([IO.File]::ReadAllBytes($edState))[0] -ne 0xEF)
    Assert-True  'and no .tmp was left behind'    (-not (Test-Path -LiteralPath "$edState.tmp"))

    # Fields the editor has no UI for must survive Push rewriting url/sha256/sizeBytes.
    $reloaded = ($savedRaw.TrimStart([char]0xFEFF) | ConvertFrom-Json).apps[0]
    Assert-Equal 'uninstall survives untouched' 'x'  ([string]$reloaded.uninstall.command)
    Assert-Equal 'iconUrl survives untouched'   'https://apps.example.com/icons/example.png' ([string]$reloaded.iconUrl)

    # ---- the plan, and the refusal when there are no bytes ----
    $plan = New-PushPlan
    Assert-Equal 'the plan has the one app'            1 @($plan.Items).Count
    Assert-Equal 'and nothing is unresolvable'         0 @($plan.NoFile).Count
    Assert-Equal 'sized from the real file on disk'    ([long]$blob.Length) ([long]$plan.Bytes)

    $orphan = [pscustomobject]@{ id = 'orphan'; name = 'Orphan App'; sha256 = ('a' * 64)
                                 sizeBytes = 10; url = 'https://apps.pc2go.ca/files/orphan/x.exe' }
    $script:Catalog.apps = @(@($script:Catalog.apps) + $orphan)
    $plan2 = New-PushPlan
    Assert-True 'an app with no local file and nothing in R2 is refused by name' `
        (@($plan2.NoFile) -contains 'Orphan App')

    # An unfinished app must not block a finished one. Push originally refused the whole catalog
    # if any single app was incomplete - copied from Publish, where that rule is right - which
    # made the button useless on a real catalog, because a catalog is half-finished for most of
    # its life. This is the case actually hit in use: one ready app, sixteen not.
    $halfDone = [pscustomobject]@{ id = 'half-done'; name = 'Half Done'; category = 'Apps'
                                   sizeBytes = 0; url = ''; sha256 = 'REPLACE_WITH_REAL_SHA256'
                                   silentArgs = ''; verifyPaths = @() }
    $script:Catalog.apps = @(@($script:Catalog.apps) + $halfDone)
    $plan3 = New-PushPlan
    Assert-Equal 'an incomplete app does NOT block the one that is ready' 1 @($plan3.Items).Count
    Assert-Equal 'and the ready one is the app with bytes on disk' 'example-app' ([string]@($plan3.Items)[0].id)
    Assert-True  'the incomplete one is listed with the reason it was skipped' `
        ((@($plan3.NotReady) -join ' ') -match 'Half Done')
    Assert-True  'the catalog as a whole is NOT publishable while it is incomplete' `
        (-not (Test-CatalogPublishable))
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $halfDone })
    Assert-True  'and IS publishable once every app is complete' (Test-CatalogPublishable)

    # A placeholder is not a hash. Storing it would later make the skip check compare a
    # placeholder against a placeholder and declare the file already uploaded.
    $script:PushState = $null
    Set-PushHashFor $app 'REPLACE_WITH_REAL_SHA256' 123
    Assert-True 'a placeholder sha256 is never recorded as a real hash' `
        ([string](Get-PushStateFor $app).sha256 -ne 'REPLACE_WITH_REAL_SHA256')

    # Servable count is what the edge would actually show a technician, and what decides whether
    # Push has anything worth doing at all. Asserted as a delta rather than an absolute, because
    # an absolute would silently encode how many fixtures happen to be in the catalog by now.
    $servableBefore = Get-ServableCount
    Assert-True 'at least one app is servable' ($servableBefore -ge 1)
    $incomplete = [pscustomobject]@{ id = 'not-done'; name = 'Not Done'; category = 'Apps'
                                     sizeBytes = 0; url = ''; sha256 = ''; silentArgs = ''; verifyPaths = @() }
    $script:Catalog.apps = @(@($script:Catalog.apps) + $incomplete)
    Assert-Equal 'adding an incomplete app does not change what the edge would serve' `
        $servableBefore (Get-ServableCount)
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $incomplete })
    Assert-Equal 'and removing it again leaves the count where it was' $servableBefore (Get-ServableCount)

    # The dead end worth pinning: an app that is ready and ALREADY uploaded needs no transfer -
    # but the catalog still has to reach the edge before any client can see it. Push used to
    # stop at "nothing to upload" and tell the user to go and press a different button, which is
    # how a finished upload sits unpublished for a week. It must offer to publish instead.
    #
    # A dedicated fixture, not a mutation of $app: clearing the shared app's local file broke
    # three later assertions that depend on it, which is its own small lesson.
    $doneApp = [pscustomobject]@{ id = 'done-app'; name = 'Done App'; category = 'Apps'
                                  sizeBytes = 4096; url = 'https://apps.pc2go.ca/files/done-app/d.exe'
                                  sha256 = ('c' * 64); silentArgs = ''; verifyPaths = @() }
    $script:Catalog.apps = @(@($script:Catalog.apps) + $doneApp)
    $de = Get-PushStateFor $doneApp
    $de.localPath = ''
    $de.remote = @{ verifiedUtc = ([datetime]::UtcNow.ToString('o')); sizeBytes = 4096
                    etag = 'x'; sha256 = ('c' * 64) }
    $planDone = New-PushPlan
    Assert-Equal 'an app already in R2 with a matching hash needs no upload' `
        0 @($planDone.Items | Where-Object { $_.id -eq 'done-app' }).Count
    Assert-True  'and is NOT reported as missing its installer' `
        (@($planDone.NoFile) -notcontains 'Done App')
    Assert-True  'yet it still counts as servable, so Push must not dead-end' `
        ((Get-ServableCount) -ge 2)
    Assert-True  'and a publish-only path exists for exactly that case' `
        ($null -ne (Get-Command Start-PublishOnly -ErrorAction SilentlyContinue))
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $doneApp })

    # ---- the catalog rewrite, from the bytes that actually went up ----
    $script:Catalog.apps = @(@($script:Catalog.apps) | Where-Object { $_ -ne $orphan })
    $script:PushPlan = @(New-PushPlan).Items
    [void]$script:PushProgress.Done.Add(@{ id = 'example-app'; name = 'Example App' })
    $n = Update-CatalogFromPush
    Assert-Equal 'the rewrite touched the one pushed app' 1 $n
    Assert-Equal 'its url now points at the real key' `
        "http://127.0.0.1:$port/files/example-app/Example.bin" ([string](Get-Field $app 'url'))
    Assert-Equal 'its sha256 is the hash of the file that went up' $srcSha ([string](Get-Field $app 'sha256'))
    Assert-True  'and no apps.example.com placeholder survives' `
        (-not (([string](Get-Field $app 'url')) -match 'apps\.example\.com'))

    # ============================================================== 11. the publish gate
    Write-Section '11. Publish-Release.ps1: -ValidateOnly, and the exit code Push reads'

    $pub = Join-Path $repo 'tools\Publish-Release.ps1'
    $mini = Join-Path $sandbox 'minirepo'
    New-Item -ItemType Directory -Force -Path "$mini\server"     | Out-Null
    New-Item -ItemType Directory -Force -Path "$mini\cloudflare" | Out-Null
    Set-Content -LiteralPath "$mini\server\AppDeploy.ps1" -Value '# tool'      -Encoding ASCII
    Set-Content -LiteralPath "$mini\server\go.ps1"        -Value '# bootstrap' -Encoding ASCII
    Set-Content -LiteralPath "$mini\cloudflare\wrangler.toml" -Value @'
name = "test"
bucket_name = "pc2go-apps"
APPDEPLOY_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
'@ -Encoding ASCII

    function Invoke-Publish([string]$Json, [string[]]$ExtraArgs) {
        [IO.File]::WriteAllText("$mini\server\apps.json", $Json, (New-Object Text.UTF8Encoding $false))
        $logf = Join-Path $sandbox "pub-$([Guid]::NewGuid().ToString('N').Substring(0,4)).log"
        $args = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$pub' -RepoRoot '$mini' $($ExtraArgs -join ' ') *> '$logf'`""
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -Wait -PassThru -WindowStyle Hidden -ArgumentList $args
        $out = ''
        if (Test-Path -LiteralPath $logf) { $out = Get-Content -LiteralPath $logf -Raw }
        return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out }
    }

    $goodApp = @{ id = 'a'; name = 'A'; sha256 = ('b' * 64); url = 'https://apps.pc2go.ca/files/a/s.exe'
                  sizeBytes = 10; silentArgs = '/S' }
    $good = @{ manifestVersion = 1; apps = @($goodApp) } | ConvertTo-Json -Depth 10
    $r = Invoke-Publish $good @('-ValidateOnly')
    Assert-Equal '-ValidateOnly exits 0 on a clean catalog' 0 $r.Exit
    Assert-True  'and says it uploaded nothing'   ($r.Out -match 'nothing uploaded')
    Assert-True  'it really did not deploy'       (-not ($r.Out -match 'Deploying Worker'))
    Assert-True  'and did not even reach wrangler' (-not ($r.Out -match 'Checking R2'))

    # A placeholder hash no longer blocks publishing - the Worker filters that app out of the
    # catalog it serves, so no client ever sees it. What IS still refused is a catalog where
    # nothing at all is ready: the served apps array would be empty, and every client would
    # report a catalog failure on a perfectly healthy machine.
    $bad = @{ manifestVersion = 1
              apps = @(@{ id = 'a'; name = 'A'; sha256 = 'REPLACE_WITH_REAL_SHA256'
                          url = 'u'; sizeBytes = 10 }) } | ConvertTo-Json -Depth 10
    $r = Invoke-Publish $bad @('-ValidateOnly')
    Assert-Equal 'a catalog with nothing ready exits non-zero' 1 $r.Exit
    Assert-True  'and explains that the served catalog would be empty' ($r.Out -match 'would be empty')

    $partial = @{ manifestVersion = 1
                  apps = @($goodApp, @{ id = 'b'; name = 'B'; sha256 = 'REPLACE_WITH_REAL_SHA256'
                                        url = 'u'; sizeBytes = 10 }) } | ConvertTo-Json -Depth 10
    $r = Invoke-Publish $partial @('-ValidateOnly')
    Assert-Equal 'one ready app plus one unfinished publishes fine' 0 $r.Exit
    Assert-True  'and the unfinished one is reported as not served yet' ($r.Out -match 'NOT be served yet')
    Assert-True  'while the ready one is counted as servable' ($r.Out -match '1 of 2 app')

    # A VERIFY marker no longer blocks anything. It meant "nobody has confirmed this switch",
    # and confirming one needs a VM and a real install - so it blocked the catalog rather than
    # improving it, on 13 of 17 entries. A wrong switch is still caught, by the thing that can
    # actually tell: the installer guard on the client stops a window that opens and names the
    # switch as the likely cause. The note itself is kept, as a note.
    $verify = @{ manifestVersion = 1
                 apps = @(@{ id = 'a'; name = 'A'; sha256 = ('b' * 64); url = 'u'; sizeBytes = 10
                             _installNote = 'VERIFY these switches' }) } | ConvertTo-Json -Depth 10
    $r = Invoke-Publish $verify @('-ValidateOnly')
    Assert-Equal 'a VERIFY note no longer blocks a publish' 0 $r.Exit
    Assert-True  'and nothing complains about switches'     (-not ($r.Out -match 'still marked VERIFY'))

    # ---- the same application twice, which is what put officesetup beside office365
    #
    # Push runs this validation before it uploads a byte, so a rule here is the thing that stops
    # the same installer going up under two keys and being billed for twice.

    # identical BYTES under two ids. Spelt in different case on purpose: sha256 is hex, and one
    # half of the catalog is written by the editor and the other by hand.
    $dupSha = @{ manifestVersion = 1
                 apps = @(@{ id = 'office365'; name = 'Microsoft 365'; version = 'Current Channel'
                             sha256 = ('d' * 64); sizeBytes = 10; silentArgs = '/S'
                             url = 'https://apps.pc2go.ca/files/office365/OfficeSetup.exe' },
                          @{ id = 'officesetup'; name = 'OfficeSetup'; version = ''
                             sha256 = ('D' * 64); sizeBytes = 10; silentArgs = '/S'
                             url = 'https://apps.pc2go.ca/files/officesetup/OfficeSetup.exe' }) } |
              ConvertTo-Json -Depth 10
    $r = Invoke-Publish $dupSha @('-ValidateOnly')
    Assert-Equal 'one installer under two ids is refused'  1 $r.Exit
    Assert-True  'and both ids are named'                  ($r.Out -match 'office365' -and $r.Out -match 'officesetup')
    Assert-True  'and it says why they are the same thing' ($r.Out -match 'identical sha256')
    # the two entries differ in name AND in version, so only the bytes give them away - which is
    # exactly the pair that got through before this rule existed
    Assert-True  'a differing version does NOT excuse identical bytes' ($r.Out -match 'not two')

    # the same product at two REAL versions is the case the version field exists for
    $twoVersions = @{ manifestVersion = 1
                      apps = @(@{ id = 'rhino7'; name = 'Rhino'; version = '7'
                                  sha256 = ('a' * 64); sizeBytes = 10; silentArgs = '/S'
                                  url = 'https://apps.pc2go.ca/files/rhino7/r7.exe' },
                               @{ id = 'rhino8'; name = 'Rhino'; version = '8'
                                  sha256 = ('c' * 64); sizeBytes = 10; silentArgs = '/S'
                                  url = 'https://apps.pc2go.ca/files/rhino8/r8.exe' }) } |
                   ConvertTo-Json -Depth 10
    $r = Invoke-Publish $twoVersions @('-ValidateOnly')
    Assert-Equal 'two real versions of one product publish fine' 0 $r.Exit
    Assert-True  'and both are counted as servable'              ($r.Out -match '2 of 2 app')

    # the same name at the same version, with different bytes, is still one product twice - and
    # this is the shape "Add folder" produces, because it names an entry after its file
    $dupName = @{ manifestVersion = 1
                  apps = @(@{ id = 'rhino'; name = 'Rhino 8'; version = '8'
                              sha256 = ('a' * 64); sizeBytes = 10; silentArgs = '/S'
                              url = 'https://apps.pc2go.ca/files/rhino/a.exe' },
                           @{ id = 'rhino-8'; name = 'rhino  8'; version = '8'
                              sha256 = ('c' * 64); sizeBytes = 10; silentArgs = '/S'
                              url = 'https://apps.pc2go.ca/files/rhino-8/b.exe' }) } |
               ConvertTo-Json -Depth 10
    $r = Invoke-Publish $dupName @('-ValidateOnly')
    Assert-Equal 'the same name at the same version is refused'  1 $r.Exit
    Assert-True  'and says to give one of them its real version' ($r.Out -match 'real version')

    # two entries aimed at ONE object in the bucket: whichever is pushed last wins, and the
    # other entry then serves a file that is not its own
    $dupUrl = @{ manifestVersion = 1
                 apps = @(@{ id = 'p1'; name = 'Product One'; version = '1'
                             sha256 = ('a' * 64); sizeBytes = 10; silentArgs = '/S'
                             url = 'https://apps.pc2go.ca/files/shared/setup.exe' },
                          @{ id = 'p2'; name = 'Product Two'; version = '2'
                             sha256 = ('c' * 64); sizeBytes = 10; silentArgs = '/S'
                             url = 'https://apps.pc2go.ca/files/shared/setup.exe' }) } |
              ConvertTo-Json -Depth 10
    $r = Invoke-Publish $dupUrl @('-ValidateOnly')
    Assert-Equal 'two entries on one bucket key are refused' 1 $r.Exit
    Assert-True  'and the key is named'                      ($r.Out -match 'files/shared/setup.exe')

    # a duplicate the edge would DROP anyway is not worth a word: it is not served, so it is not
    # shipped, and it is not uploaded either
    $dupUnserved = @{ manifestVersion = 1
                      apps = @($goodApp,
                               @{ id = 'x1'; name = 'Half Done'; version = ''; sha256 = 'REPLACE_WITH_REAL_SHA256'
                                  url = 'u'; sizeBytes = 10 },
                               @{ id = 'x2'; name = 'Half Done'; version = ''; sha256 = 'REPLACE_WITH_REAL_SHA256'
                                  url = 'u'; sizeBytes = 10 }) } | ConvertTo-Json -Depth 10
    $r = Invoke-Publish $dupUnserved @('-ValidateOnly')
    Assert-Equal 'two unfinished rows for one product do not block a publish' 0 $r.Exit

    # -Force is the staging escape hatch, and it has to keep working for this rule too
    $r = Invoke-Publish $dupSha @('-ValidateOnly', '-Force')
    Assert-Equal '-Force still publishes a duplicate on purpose' 0 $r.Exit
    Assert-True  'while saying it did so'                        ($r.Out -match 'Publishing anyway')
    # a destination with a second root inside it expands to C:\Program Files\C:\Program Files\..
    # - a directory that cannot exist - and the copy fails on the client at the end of a long
    # install. The editor repairs this as it is typed; entries already written down come here.
    $badDest = @{ manifestVersion = 1
                  apps = @(@{ id = 'sketchup-pro-2026'; name = 'SketchUp Pro'; version = '2026.26.1.256'
                              sha256 = ('a' * 64); sizeBytes = 10; silentArgs = '/S'
                              url = 'https://apps.pc2go.ca/files/sketchup-pro-2026/s.rar'
                              postInstall = @(@{ type = 'copy'; name = 'Copy LayOut.exe'
                                                 from = 'pkg\LayOut.exe'
                                                 dest = '%ProgramFiles%\C:\Program Files\SketchUp\SketchUp 2026\LayOut\' }) }) } |
               ConvertTo-Json -Depth 10
    $r = Invoke-Publish $badDest @('-ValidateOnly')
    Assert-Equal 'a path inside a path is refused'   1 $r.Exit
    Assert-True  'and the step is named'             ($r.Out -match 'Copy LayOut.exe')
    Assert-True  'and the phrase says what is wrong' ($r.Out -match 'path inside a path')

    # the same entry with the destination the technician actually meant
    $goodDest = $badDest.Replace('%ProgramFiles%\\C:\\Program Files\\', 'C:\\Program Files\\')
    $r = Invoke-Publish $goodDest @('-ValidateOnly')
    Assert-Equal 'and the repaired destination publishes' 0 $r.Exit

    # ============================================================== 11c. Push converts .rar
    Write-Section '11c. Push rewrites a .rar as a .zip before it uploads it'

    # The whole of $script:PushWork, lifted out of the editor the same way $script:FetchWork is.
    # Only the network edge is stubbed - the conversion, the ordering and the reporting are the
    # code that ships.
    # $edSrc is the editor's own text, read further up; this harness has no shared AST for it
    $cvAst = [System.Management.Automation.Language.Parser]::ParseInput($edSrc, [ref]$null, [ref]$null)
    $pushWork = $cvAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:PushWork' }, $true) |
        Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) }
    if (-not $pushWork) { throw 'Could not extract $script:PushWork.' }

    $cvDir = Join-Path $sandbox 'pushconv'
    New-Item -ItemType Directory -Force -Path "$cvDir\inner" | Out-Null
    Set-Content -LiteralPath "$cvDir\inner\setup.exe" -Value 'MZ convert me' -Encoding ASCII
    # A real .rar cannot be created here - WinRAR 7 is not a build dependency - so the source is
    # a .zip RENAMED to .rar. tar reads by content, not by extension, and so does the converter,
    # so the path under test is the real one.
    $srcZip = Join-Path $cvDir 'Payload 1.0.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory("$cvDir\inner", $srcZip)
    $fakeRar = Join-Path $cvDir 'Payload 1.0.rar'
    Move-Item -LiteralPath $srcZip -Destination $fakeRar -Force
    $expectZip = [IO.Path]::ChangeExtension($fakeRar, '.zip')

    # The stub says the object is ALREADY in the bucket at the converted size, so the upload is
    # skipped. That is deliberate: it proves the conversion happens BEFORE the skip check. Get
    # that order wrong and the skip compares the bucket against a .rar that never goes up.
    $stubModule = Join-Path $cvDir 'stub-r2.ps1'
    Set-Content -LiteralPath $stubModule -Encoding ASCII -Value @"
function Get-R2ObjectInfo {
    param(`$Credential, [string]`$Key)
    `$p = `$env:PC2GO_TEST_ZIP
    if (`$p -and (Test-Path -LiteralPath `$p)) {
        return [pscustomobject]@{ Exists = `$true; Size = (Get-Item -LiteralPath `$p).Length; ETag = ''; StatusCode = 200 }
    }
    return [pscustomobject]@{ Exists = `$false; Size = 0; ETag = ''; StatusCode = 404 }
}
function Invoke-R2Upload {
    param(`$Credential, `$Key, `$LocalPath, `$State, `$Progress, `$PartSizeBytes, `$MaxAttempts, `$SignPayload, `$OnStateChanged, `$BackoffBaseSeconds)
    throw 'the upload should have been skipped'
}
"@
    $env:PC2GO_TEST_ZIP = $expectZip

    function New-CvProgress {
        return [hashtable]::Synchronized(@{
            Cancel = $false; Phase = 'idle'; AppId = ''; AppName = ''; AppIndex = 0; AppCount = 1
            AppBytes = [long]0; AppTotal = [long]0; DoneBytes = [long]0; TotalToSend = [long]0
            Part = 0; PartCount = 0
            Done      = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
            Skipped   = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
            Failed    = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
            Log       = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
            Converted = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
        })
    }
    function New-CvItem([string]$Id, [string]$Rar, [string]$Zip) {
        return [pscustomobject]@{
            id = $Id; name = "Payload $Id"; localPath = $Rar
            key = "files/$Id/$([IO.Path]::GetFileName($Zip))"
            sha256 = ('f' * 64); sizeBytes = [long](Get-Item -LiteralPath $Rar).Length
            remoteVerified = $false; convert = $true; convertTo = $Zip
            App = [pscustomobject]@{ id = $Id }
        }
    }

    $converter = Join-Path $repo 'tools\Convert-PackageToZip.ps1'
    Assert-True 'the converter the editor hands over actually exists' (Test-Path -LiteralPath $converter)

    $cvProgress = New-CvProgress
    $cvState = Join-Path $cvDir 'state.json'
    & $pushWork $stubModule @((New-CvItem 'payload' $fakeRar $expectZip)) $null $cvProgress $cvState ([long]0) $converter | Out-Null

    Assert-Equal 'the push finished'                    'done'  ([string]$cvProgress.Phase)
    Assert-Equal 'nothing failed'                       0       (@($cvProgress.Failed).Count)
    Assert-Equal 'one package was converted'            1       (@($cvProgress.Converted).Count)
    Assert-True  'and the .zip is really on disk'       (Test-Path -LiteralPath $expectZip)
    $cv = @($cvProgress.Converted)[0]
    Assert-Equal 'the conversion reports the .zip path' $expectZip ([string]$cv.path)
    Assert-Equal 'and where it came from'               $fakeRar   ([string]$cv.from)
    Assert-Equal 'with the .zip real size'              ((Get-Item -LiteralPath $expectZip).Length) ([long]$cv.sizeBytes)
    Assert-Equal 'and the .zip real hash'               ((Get-FileHash -LiteralPath $expectZip -Algorithm SHA256).Hash) ([string]$cv.sha256)
    # Deliberately NOT "the hash differs from the .rar's". This fixture's .rar is a .zip that was
    # renamed, so re-zipping one small file can legitimately reproduce identical bytes - the
    # assertion would be testing the fixture, not the code. What has to be true is that the facts
    # reported describe the file that will be UPLOADED, not the one that was on disk before it.
    Assert-True  'the upload target is the .zip, not the source' (([string]$cv.path) -ne ([string]$cv.from))
    Assert-True  'and the path it names really is a .zip'        (([string]$cv.path) -like '*.zip')
    # conversion BEFORE the bucket is asked: the stub answered with the .zip's size, so the skip
    # could only have matched if the item had already been repointed at the .zip
    Assert-Equal 'the upload was skipped against the CONVERTED size' 1 (@($cvProgress.Skipped).Count)
    # and the setup file inside survived, or `entry` in the catalog would name nothing
    $chk = [IO.Compression.ZipFile]::OpenRead($expectZip)
    try { $inside = @($chk.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName -replace '/', '\' }) }
    finally { $chk.Dispose() }
    Assert-True 'the installer inside the package came through' ($inside -contains 'setup.exe')

    # ---- a second push must not spend minutes rebuilding an identical .zip
    $stamp = (Get-Item -LiteralPath $expectZip).LastWriteTimeUtc
    $cvProgress = New-CvProgress
    & $pushWork $stubModule @((New-CvItem 'payload' $fakeRar $expectZip)) $null $cvProgress $cvState ([long]0) $converter | Out-Null
    Assert-Equal 'a second push reuses the .zip rather than rebuilding it' `
                 $stamp ((Get-Item -LiteralPath $expectZip).LastWriteTimeUtc)
    Assert-Equal 'and still reports what it will upload' 1 (@($cvProgress.Converted).Count)

    # ---- a .rar touched later than its .zip IS rebuilt
    (Get-Item -LiteralPath $fakeRar).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(5)
    $cvProgress = New-CvProgress
    & $pushWork $stubModule @((New-CvItem 'payload' $fakeRar $expectZip)) $null $cvProgress $cvState ([long]0) $converter | Out-Null
    Assert-True 'a source newer than its .zip is converted again' `
                ((Get-Item -LiteralPath $expectZip).LastWriteTimeUtc -gt $stamp)

    # ---- a missing converter is a named failure, not a silent .rar upload
    $cvProgress = New-CvProgress
    $gone = New-CvItem 'payload2' $fakeRar (Join-Path $cvDir 'never-made.zip')
    & $pushWork $stubModule @($gone) $null $cvProgress $cvState ([long]0) `
                (Join-Path $cvDir 'no-such-converter.ps1') | Out-Null
    Assert-Equal 'a missing converter fails that app'   1 (@($cvProgress.Failed).Count)
    Assert-True  'and says the converter is the reason' ((@($cvProgress.Failed)[0].reason) -match 'is missing')
    Assert-Equal 'and nothing was uploaded for it'      0 (@($cvProgress.Done).Count)
    Assert-True  'and no .zip was left behind'          (-not (Test-Path -LiteralPath (Join-Path $cvDir 'never-made.zip')))

    Remove-Item Env:\PC2GO_TEST_ZIP -ErrorAction SilentlyContinue
    # ============================================================== 11b. .rar packages
    Write-Section '11b. WinRAR packages, against a real .rar'

    # A real archive made by the real WinRAR, read by the real FetchWork. .NET cannot open a
    # .rar at all, so this exercises the tar fallback that is the whole of rar support - and it
    # is the only way to know whether Windows' bsdtar was built with the rar reader linked in.
    $rarExe = Join-Path $env:ProgramFiles 'WinRAR\Rar.exe'
    if (-not (Test-Path -LiteralPath $rarExe)) {
        Write-Host '  SKIP  WinRAR is not installed here - .rar handling was NOT exercised' -ForegroundColor Yellow
    } else {
        $rsrc = Join-Path $sandbox 'rarsrc'
        New-Item -ItemType Directory -Force -Path "$rsrc\Tools" | Out-Null
        Set-Content -LiteralPath "$rsrc\setup.exe"    -Value 'MZ fake installer' -Encoding ASCII
        Set-Content -LiteralPath "$rsrc\Tools\go.cmd" -Value '@echo off'         -Encoding ASCII
        $rarFile = Join-Path $sandbox 'package.rar'
        Push-Location $rsrc
        $null = & $rarExe a -r -inul $rarFile '*' 2>&1
        $rarRc = $LASTEXITCODE
        Pop-Location
        Assert-Equal 'WinRAR built the test archive' 0 $rarRc

        # The shipping scriptblock, lifted from the editor rather than reimplemented.
        $fetch = $edAst = [System.Management.Automation.Language.Parser]::ParseInput($edSrc, [ref]$null, [ref]$null)
        $fetchWork = $edAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$script:FetchWork' }, $true) |
            Select-Object -First 1 | ForEach-Object { & ([scriptblock]::Create($_.Right.Extent.Text)) }
        Assert-True 'the fetch/hash scriptblock was lifted from the editor' ($null -ne $fetchWork)

        $rr = & $fetchWork $rarFile (Join-Path $sandbox 'rarpkg') | Select-Object -Last 1
        Assert-True  'a .rar is read rather than rejected'   (-not $rr.error)
        Assert-Equal 'it is hashed from the real bytes' `
            (Get-FileHash -LiteralPath $rarFile -Algorithm SHA256).Hash ([string]$rr.sha256)
        Assert-Equal 'and sized from them'  ((Get-Item -LiteralPath $rarFile).Length) ([long]$rr.size)
        Assert-True  'the installer inside is found and ranked first' `
            (@($rr.entries).Count -ge 1 -and ([string]@($rr.entries)[0]) -eq 'setup.exe')
        Assert-True  'the nested file is listed for after-install steps' (@($rr.files) -contains 'Tools\go.cmd')
        # bsdtar lists a directory inside a .rar with NO trailing separator, so "Tools" would
        # otherwise be offered as a file to copy.
        Assert-True  'and the directory itself is NOT offered as a file' (-not (@($rr.files) -contains 'Tools'))
        Assert-True  'the packager notes it was read through tar' ([string]$rr.packager -match 'rar')

        # Test-App is what decides whether a .rar may carry an `entry` at all.
        $rarApp = [pscustomobject]@{ id = 'rar-app'; name = 'Rar App'; category = 'Apps'
                                     sizeBytes = [long]$rr.size; sha256 = [string]$rr.sha256
                                     url = 'https://apps.pc2go.ca/files/rar-app/package.rar'
                                     entry = 'setup.exe'; silentArgs = ''; verifyPaths = @() }
        Assert-Equal 'a .rar with a setup file chosen validates clean' 0 @(Test-App $rarApp).Count
        Set-Field $rarApp 'entry' ''
        Assert-True  'a .rar with no setup file chosen is refused' `
            ((@(Test-App $rarApp) -join ' ') -match 'no setup file chosen')

        # The worker unpacks through the same tar call. Proving the mechanism here is not the
        # same as proving a full elevated install - Test-CatalogScenarios does that for .zip and
        # not yet for .rar - so this asserts exactly what it can: the bytes come back out.
        $unpack = Join-Path $sandbox 'rarunpack'
        New-Item -ItemType Directory -Force -Path $unpack | Out-Null
        $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
        $tp = Start-Process -FilePath $tarExe -ArgumentList @('-xf', "`"$rarFile`"", '-C', "`"$unpack`"") `
                            -Wait -PassThru -WindowStyle Hidden
        Assert-Equal 'tar extracts the .rar the way the worker does' 0 $tp.ExitCode
        Assert-Equal 'and the entry file comes out byte-identical' `
            (Get-FileHash -LiteralPath "$rsrc\setup.exe" -Algorithm SHA256).Hash `
            (Get-FileHash -LiteralPath "$unpack\setup.exe" -Algorithm SHA256).Hash

        Assert-True 'the worker gate accepts .rar as a package' `
            ((Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw) -match
             "\`$pkgExt -in '\.zip', '\.rar'")
    }

    # ============================================================== 11c. .iso packages
    Write-Section '11c. ISO images: mounted, never extracted'

    # These assertions need no image and always run.
    $isoApp = [pscustomobject]@{ id = 'iso-app'; name = 'Iso App'; category = 'Apps'
                                 sizeBytes = 100; sha256 = ('d' * 64)
                                 url = 'https://apps.pc2go.ca/files/iso-app/disc.iso'
                                 entry = 'Setup\install.exe'; silentArgs = ''; verifyPaths = @() }
    Assert-Equal 'an .iso with a setup file chosen validates clean' 0 @(Test-App $isoApp).Count
    Set-Field $isoApp 'entry' ''
    Assert-True  'an .iso with no setup file chosen is refused' `
        ((@(Test-App $isoApp) -join ' ') -match 'no setup file chosen')

    $workerSrc = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    Assert-True 'the worker mounts an .iso rather than unpacking it' ($workerSrc -match "\`$pkgExt -eq '\.iso'")
    Assert-True 'and the .iso branch is checked BEFORE the archive branch' `
        ($workerSrc.IndexOf("`$pkgExt -eq '.iso'") -lt $workerSrc.IndexOf("elseif (`$app.entry -or `$pkgExt -in"))
    Assert-True 'Remove-Unpacked dismounts instead of deleting a mounted disc' `
        ($workerSrc -match 'if \(\$script:MountedIso\)[\s\S]{0,400}Dismount-DiskImage')

    # A real image, if this machine has one. Building an ISO from scratch needs unsafe-compiled
    # IMAPI2 interop, which is more fragile than the thing under test - so a real one is used
    # when available and the section says so plainly when it is not.
    if (-not $IsoPath) {
        $guess = Join-Path $env:USERPROFILE 'Documents\Apps'
        if (Test-Path -LiteralPath $guess) {
            $IsoPath = @(Get-ChildItem -LiteralPath $guess -Filter *.iso -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                         Sort-Object Length | Select-Object -First 1 -ExpandProperty FullName)
        }
    }
    if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath)) {
        Write-Host '  SKIP  no .iso available - mount/enumerate/dismount was NOT exercised' -ForegroundColor Yellow
        Write-Host '        pass -IsoPath <file.iso> to run it' -ForegroundColor Yellow
    } else {
        Write-Host "  using $(Split-Path $IsoPath -Leaf)" -ForegroundColor DarkGray
        $wasMounted = [bool](Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue).Attached
        Assert-True 'the image is not already mounted before the test' (-not $wasMounted)

        $ir = & $fetchWork $IsoPath (Join-Path $sandbox 'isopkg') | Select-Object -Last 1
        Assert-True  'an .iso is read rather than rejected' (-not $ir.error)
        Assert-Equal 'it is hashed from the image itself' `
            (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash ([string]$ir.sha256)
        Assert-True  'its contents are listed'            (@($ir.files).Count -gt 0)
        Assert-True  'an installer inside is found'       (@($ir.entries).Count -gt 0)
        Assert-True  'and it is reported as a mounted image, not a tar read' `
            ([string]$ir.packager -match 'ISO')

        # The reason ISOs are mounted at all. bsdtar falls back to raw ISO9660 on an image with
        # no Joliet extension and truncates every name to 31 characters, so an installer would
        # be handed paths that do not exist - after the whole image had been downloaded.
        $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
        $tarNames = @(& $tarExe -tf $IsoPath 2>$null | ForEach-Object { ($_ -replace '/', '\') })
        $tarLongest   = 0; $mountLongest = 0
        foreach ($n in $tarNames)    { $l = ($n -split '\\')[-1].Length; if ($l -gt $tarLongest)   { $tarLongest = $l } }
        foreach ($n in @($ir.files)) { $l = ($n -split '\\')[-1].Length; if ($l -gt $mountLongest) { $mountLongest = $l } }
        Write-Host "        longest name: mounted=$mountLongest tar=$tarLongest" -ForegroundColor DarkGray
        Assert-True 'mounting never yields a shorter name than tar would' ($mountLongest -ge $tarLongest)

        Assert-True 'the image is dismounted again afterwards' `
            (-not [bool](Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue).Attached)

        # An image left mounted by an interrupted run used to make every later attempt throw,
        # rendering that application uninstallable until somebody rebooted. It must adopt the
        # existing mount - and must leave a mount it did not create exactly as it found it.
        $pre = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -PassThru -ErrorAction SilentlyContinue
        if ($pre) {
            for ($i = 0; $i -lt 40 -and -not (Get-Volume -DiskImage $pre -ErrorAction SilentlyContinue).DriveLetter; $i++) {
                Start-Sleep -Milliseconds 250
            }
            $ir2 = & $fetchWork $IsoPath (Join-Path $sandbox 'isopkg2') | Select-Object -Last 1
            Assert-True  'an already-mounted image is read rather than refused' (-not $ir2.error)
            Assert-Equal 'and yields the same file list' @($ir.files).Count @($ir2.files).Count
            Assert-True  'a mount it did not create is left mounted' `
                ([bool](Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue).Attached)
            try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
        } else {
            Write-Host '  SKIP  could not pre-mount to test the adopt-existing path' -ForegroundColor Yellow
        }
    }

    # ============================================================== 11d. the installer guard
    Write-Section '11d. An installer that never finishes'

    # Until now the installer ran under Start-Process -Wait, which has no timeout. A wrong
    # silent switch therefore hung the batch for ever: the installer opened its GUI, that window
    # was invisible because the worker runs elevated and hidden, and nothing reported a fault
    # because nothing had failed - it was still "installing". These are the two ways out.
    $wPath = Join-Path $repo 'server\AppDeploy.ps1'
    $wSrc  = Get-Content -LiteralPath $wPath -Raw

    # The elevated worker is not top-level code - it is a here-string, `$workerScript = @'`,
    # written out and run in its own elevated process. So parsing AppDeploy.ps1 finds 91
    # functions and none of the install ones: they are inside a string as far as the AST is
    # concerned. Test-DirtyCleanup.ps1 solves this the same way, by lifting the here-string
    # first and parsing that.
    $wLines = Get-Content -LiteralPath $wPath
    $wStart = ($wLines | Select-String -SimpleMatch '$workerScript = @''' | Select-Object -First 1).LineNumber
    Assert-True 'the worker here-string was located in AppDeploy.ps1' ($wStart -gt 0)
    $wEnd = 0
    for ($i = $wStart; $i -lt $wLines.Count; $i++) {
        if ($wLines[$i].TrimEnd() -eq "'@") { $wEnd = $i; break }
    }
    Assert-True 'and its closing marker was found' ($wEnd -gt $wStart)
    $workerBody = ($wLines[$wStart..($wEnd - 1)] -join "`n")

    foreach ($fn in @('Start-InstallerWatched', 'Stop-ProcessTree')) {
        . ([scriptblock]::Create((Get-FunctionSource $workerBody $fn)))
    }
    Assert-True 'the watched-launch helper was lifted from the worker' `
        ($null -ne (Get-Command Start-InstallerWatched -ErrorAction SilentlyContinue))
    Assert-True 'the worker no longer waits on an installer with no timeout' `
        (-not ($wSrc -match "Start-Process -FilePath \`$runFile -Wait -PassThru"))

    # A well-behaved silent installer: exits promptly, no window, real exit code passed through.
    $r = Start-InstallerWatched -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-Command', 'exit 3010') `
            -Extra @{ WindowStyle = 'Hidden' } -TimeoutSec 60 -UiGraceSec 5
    Assert-Equal 'a silent installer''s real exit code is passed through' 3010 $r.ExitCode
    Assert-True  'and it is not reported as a UI or timeout case' (-not $r.ShowedUi -and -not $r.TimedOut)

    # The case that used to hang for ever: a GUI appears and stays up.
    $guiCode = 'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.Form; $f.Text = "fake installer"; $f.Show(); Start-Sleep -Seconds 120'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Start-InstallerWatched -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-STA', '-Command', $guiCode) `
            -TimeoutSec 120 -UiGraceSec 3
    $sw.Stop()
    Assert-True  'an installer that opens a window is stopped'      $r.ShowedUi
    Assert-True  'and reported as a UI case, not a timeout'         (-not $r.TimedOut)
    Assert-True  'within roughly the grace period, not the timeout' ($sw.Elapsed.TotalSeconds -lt 30)

    # Genuinely stuck, with no window to give it away.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Start-InstallerWatched -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') `
            -Extra @{ WindowStyle = 'Hidden' } -TimeoutSec 4 -UiGraceSec 60
    $sw.Stop()
    Assert-True  'an installer that never exits is stopped on the timeout' $r.TimedOut
    Assert-True  'and reported as a timeout, not a UI case'                (-not $r.ShowedUi)
    Assert-True  'at about the timeout, not for ever'                      ($sw.Elapsed.TotalSeconds -lt 20)

    # An installer is usually a stub that launches the real thing. Killing only the process we
    # started would leave the actual installer running, still holding the files the leftover
    # scan is about to offer to delete.
    $marker = Join-Path $sandbox 'child-alive.txt'
    $treeCode = "Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 90; Set-Content -LiteralPath ''$marker'' -Value alive' -WindowStyle Hidden; Start-Sleep -Seconds 90"
    $before = @(Get-Process powershell -ErrorAction SilentlyContinue).Count
    $r = Start-InstallerWatched -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-Command', $treeCode) `
            -Extra @{ WindowStyle = 'Hidden' } -TimeoutSec 5 -UiGraceSec 60
    Assert-True 'the stuck parent was stopped' $r.TimedOut
    Start-Sleep -Seconds 3
    $after = @(Get-Process powershell -ErrorAction SilentlyContinue).Count
    Assert-True 'and its child was stopped with it, not left running' ($after -le $before)
    Assert-True 'the child never got to finish its work' (-not (Test-Path -LiteralPath $marker))

    # ============================================================== 11e. the bootstrap cache
    Write-Section '11e. go.ps1 stops re-downloading the tool every run'

    # go.ps1 fetched ~480 KB on every launch even when the identical bytes were already on disk,
    # costing a download and - the part that actually hurts on a client - a second full AMSI
    # scan before PowerShell would run a line. The pinned hash already knows whether the local
    # copy is the right one. What must NOT change is the pin itself: a cached file may be used
    # only when its hash equals the pin, the same test a fresh download has to pass.
    $goSrc = Get-Content -LiteralPath (Join-Path $repo 'server\go.ps1') -Raw
    $decideAt = $goSrc.IndexOf('$needFetch = $true')
    $fetchAt  = $goSrc.IndexOf('if ($needFetch) {')
    Assert-True 'the caching decision was found in go.ps1' ($decideAt -gt 0 -and $fetchAt -gt $decideAt)
    $decide = $goSrc.Substring($decideAt, $fetchAt - $decideAt)

    $goFile = Join-Path $sandbox 'AppDeploy-cached.ps1'
    Set-Content -LiteralPath $goFile -Value '# pretend tool' -Encoding ASCII
    $goodHash = (Get-FileHash -LiteralPath $goFile -Algorithm SHA256).Hash

    function Test-NeedFetch([string]$Path, [string]$Pin) {
        $ps1 = $Path
        $PinnedHash = $Pin
        $pinned = ($PinnedHash -ne 'PINNED_SHA256_GOES_HERE')
        . ([scriptblock]::Create($decide))
        return $needFetch
    }

    Assert-Equal 'a cached copy matching the pin is NOT downloaded again' `
        $false (Test-NeedFetch $goFile $goodHash)
    Assert-Equal 'a cached copy that does NOT match the pin is re-downloaded' `
        $true (Test-NeedFetch $goFile ('f' * 64))
    Assert-Equal 'no cached copy means download' `
        $true (Test-NeedFetch (Join-Path $sandbox 'not-here.ps1') $goodHash)
    # With no pin configured there is nothing to compare against, so the only safe answer is to
    # fetch - never to trust whatever happens to be lying in the cache directory.
    Assert-Equal 'an unpinned release always downloads rather than trusting the cache' `
        $true (Test-NeedFetch $goFile 'PINNED_SHA256_GOES_HERE')

    Assert-True 'a freshly downloaded copy is still verified against the pin' `
        ($goSrc -match 'if \(\$needFetch\) \{[\s\S]{0,400}failed integrity check')
    Assert-True 'and a failed check still deletes the file rather than running it' `
        ($goSrc -match 'Remove-Item \$ps1 -Force[\s\S]{0,120}failed integrity check')

    # ============================================================== 11f. one load, not two
    Write-Section '11f. The tool is loaded once per launch, not twice'

    # Measured on a client running McAfee alongside Defender: loading the ~480 KB tool costs
    # EIGHT SECONDS of script scanning, every run - and it was paid TWICE, once by a process
    # whose only job was to decide "should I elevate?" and then exit. go.ps1 makes that decision
    # itself now. It must stay small enough to scan instantly, and it must never be WRONG:
    # anything uncertain falls through to the tool's own check.
    $goPath = Join-Path $repo 'server\go.ps1'
    $goTxt  = Get-Content -LiteralPath $goPath -Raw
    Assert-True 'go.ps1 decides elevation itself'          ($goTxt -match 'Get-LocalGroupMember')
    Assert-True 'and tells the tool not to decide again'   ($goTxt -match '\-NoSelfElevate')
    Assert-True 'it elevates with RunAs on the fast path'  ($goTxt -match 'Verb RunAs')
    # The entire point: the bootstrap must stay trivial to scan. If it ever grows towards the
    # size of the tool, this optimisation has quietly undone itself.
    Assert-True ('go.ps1 is still small (' + [int]((Get-Item $goPath).Length / 1KB) + ' KB, under 32)') `
        ((Get-Item $goPath).Length -lt 32KB)

    # The fallback is what makes it safe for the fast path to be wrong.
    $depTxt = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    Assert-True 'the tool still self-elevates when launched directly' `
        ($depTxt -match 'NoSelfElevate -and \(Test-IsAdminMember\)')
    # Asserted by what the line DOES, not by how its parameters happen to be spelled. The exact
    # literal was pinned here and broke the moment -PassThru was added between two of the
    # existing switches - reporting a missing fallback that had never gone anywhere. A test that
    # fails on a reordering it does not care about trains people to ignore it.
    $plainLaunch = @($goTxt -split "`r?`n" | Where-Object {
        $_ -match 'Start-Process' -and $_ -match '\$winPS' -and $_ -match '\$launch' -and $_ -notmatch 'RunAs' })
    Assert-True 'go.ps1 still has a plain launch to fall through to' ($plainLaunch.Count -ge 1)

    # Both implementations must reach the same verdict on this machine. They are separate code
    # by design - the tool keeps an ADSI fallback the bootstrap deliberately does not copy - so
    # the risk worth pinning is that they disagree.
    # End at the catch, NOT at "if ($elevate) {". Everything between those two markers is
    # dot-sourced into THIS runspace, and go.ps1 grew a splash between them - so the slice
    # picked up "$script:SplashTimer.Stop()" and "Hide-Splash", neither of which exists here,
    # and the whole harness died on a null method call straight after section 11f, taking
    # 11g, 11h, 11i and 12 with it. The decision block is what this test is about, so the
    # marker has to end where the decision does.
    $a = $goTxt.IndexOf('$elevate = $false')
    $endMark = '} catch { $elevate = $false }'
    $catch = $goTxt.IndexOf($endMark, [Math]::Max($a, 0))
    $b = $(if ($a -ge 0 -and $catch -gt $a) { $catch + $endMark.Length } else { -1 })
    Assert-True 'the decision block was found in go.ps1' ($a -gt 0 -and $b -gt $a)
    . ([scriptblock]::Create($goTxt.Substring($a, $b - $a)))
    $fastPath = $elevate
    . ([scriptblock]::Create((Get-FunctionSource $depTxt 'Test-IsAdminMember')))
    $isElev = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    Assert-Equal 'the bootstrap and the tool agree on whether to elevate' `
        ((-not $isElev) -and (Test-IsAdminMember)) $fastPath

    # ============================================================== 11g. what actually ships
    Write-Section '11g. Comments and indentation are stripped on the way out'

    # Antivirus scans script CONTENT. On a client with McAfee beside Defender, loading the
    # ~490 KB tool cost EIGHT SECONDS every run; on a Defender-only machine, 18 ms. A quarter of
    # the file is comments and indentation no machine needs, so they come off at publish time.
    # The comments stay in the repository, where they are worth something.
    . (Join-Path $repo 'tools\Compress-Script.ps1')

    $realSrc = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    $shipped = ConvertTo-ShippableScript -Source $realSrc
    Assert-True  'the shipped tool is meaningfully smaller' ($shipped.Length -lt $realSrc.Length * 0.9)
    # The strongest guarantee available: not "it still parses" but "it is the same program".
    Assert-True  'and its token stream is IDENTICAL to the source' `
        (Test-ScriptTokensMatch -Original $realSrc -Stripped $shipped)
    $pe = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($shipped, [ref]$null, [ref]$pe)
    Assert-Equal 'the shipped tool parses without error' 0 @($pe).Count
    # Line numbers must survive, or a stack trace from a client points at the wrong line.
    Assert-Equal 'line numbers are preserved' `
        (($realSrc -split "`r?`n").Count) (($shipped -split "`r?`n").Count)

    # A here-string is HereStringLiteral, NOT StringLiteral. Getting that wrong protected
    # nothing and silently re-indented the XAML and all 130 KB of the elevated worker - and it
    # still parsed, which is exactly why this is asserted on bytes.
    foreach ($pat in @('(?s)\$workerScript = @''.*?\n''@', '(?s)\$xaml = @''.*?\n''@')) {
        $a = [regex]::Match($realSrc, $pat).Value
        $b = [regex]::Match($shipped, $pat).Value
        Assert-True ("a $([int]($a.Length/1KB)) KB here-string survives byte-for-byte") ($a.Length -gt 0 -and $a -eq $b)
    }

    # #requires tokenises as a Comment but the ENGINE acts on it. Blanking it would drop the
    # "Windows PowerShell 5.1" requirement from the file that actually ships.
    Assert-True 'the #requires directive is not stripped' ($shipped -match '(?m)^#requires -Version 5\.1')

    Assert-True 'a comment really is gone from the shipped copy' `
        ($realSrc -match 'Antivirus scans script CONTENT' -or -not ($shipped -match 'bumped on every change'))
    $err = ''
    try { [void](ConvertTo-ShippableScript -Source 'function Broken { if ($x -eq ) { } }') }
    catch { $err = $_.Exception.Message }
    Assert-True 'it refuses to strip a script that does not parse' ($err -match 'does not parse')

    # And the publish path must hash and upload the STRIPPED bytes. Hashing the source instead
    # would pin a hash the client never sees, and every machine would report a failed integrity
    # check on a tool that is perfectly fine.
    $pubTxt = Get-Content -LiteralPath (Join-Path $repo 'tools\Publish-Release.ps1') -Raw
    Assert-True 'publish hashes the shipped file, not the source' `
        ($pubTxt -match 'Get-FileHash -LiteralPath \$shipDeploy')
    Assert-True 'publish uploads the shipped file'  ($pubTxt -match 'Local = \$shipDeploy')
    Assert-True 'and refuses to publish if stripping changed the code' `
        ($pubTxt -match 'Refusing to publish')

    # ============================================================== 11h. a wrong verifyPath
    Write-Section '11h. A wrong verifyPath must not offer a working install for deletion'

    # What happened in the field: Office installed correctly over ten minutes, the watcher logged
    # "installed into: C:\Program Files\Microsoft Office", and the very next line said "installed
    # nothing". Worse, it marked the app dirty, so the leftover scan offered 9.4 GB of working
    # Office to the technician as debris. The catalog's verifyPaths was a guess derived from the
    # app's NAME - while the same entry's uninstall.detect had the real path all along.
    #
    # The real block is lifted out of the worker and run against stubs, so this exercises the
    # code that ships rather than a description of it.
    $verifyStart = $workerBody.IndexOf('if (-not $ok) {')
    Assert-True 'the verify-paths verdict was located in the worker' ($verifyStart -gt 0)
    $depth = 0; $verifyEnd = -1
    for ($i = $verifyStart; $i -lt $workerBody.Length; $i++) {
        if ($workerBody[$i] -eq '{') { $depth++ }
        elseif ($workerBody[$i] -eq '}') { $depth--; if ($depth -eq 0) { $verifyEnd = $i; break } }
    }
    Assert-True 'and its closing brace was found' ($verifyEnd -gt $verifyStart)
    $verifyBlock = $workerBody.Substring($verifyStart, $verifyEnd - $verifyStart + 1)

    $script:Reported = $null
    function Write-Status { param($Id, $State, $Detail, $Dirty = $false, $Created = @())
        $script:Reported = [pscustomobject]@{ State = $State; Detail = $Detail
                                              Dirty = [bool]$Dirty; Created = @($Created) } }
    function Write-Activity { param($a, $b, $c, $d) }
    function Remove-Unpacked { }

    # Case 1: the installer ran, created folders, but no verifyPath matched. A real install with
    # bad catalog data - it must NOT be offered for deletion.
    $ok = $false
    $app = [pscustomobject]@{ id = 'office365'; verifyPaths = @('%ProgramFiles%\NoSuchProduct\nope.exe') }
    $p = [pscustomobject]@{ ExitCode = 0 }
    $created = @('C:\Program Files\Microsoft Office', 'C:\Program Files\Microsoft Office 15')
    . ([scriptblock]::Create($verifyBlock))
    Assert-Equal 'it is still reported as Failed (it could not be VERIFIED)' 'Failed' $script:Reported.State
    Assert-Equal 'but NOT dirty - a working install is not debris' $false $script:Reported.Dirty
    Assert-Equal 'and nothing is handed to the leftover scan'      0 @($script:Reported.Created).Count
    Assert-True  'it no longer claims the installer did nothing' `
        (-not ($script:Reported.Detail -match 'installed nothing'))
    # the row now carries one actionable sentence with the COUNT; the full path lists moved to
    # the activity log, where a paragraph belongs - the count is the row's proof it knows
    Assert-True  'it names what WAS created'  ($script:Reported.Detail -match 'created 2 folder')
    Assert-True  'and points at the real fix' ($script:Reported.Detail -match 'verifyPaths')

    # Case 2: nothing created and nothing verifies - the installer really did do nothing. That
    # case must keep its old behaviour, dirty flag included.
    $script:Reported = $null
    $created = @()
    . ([scriptblock]::Create($verifyBlock))
    Assert-Equal 'an installer that created nothing is still Failed' 'Failed' $script:Reported.State
    Assert-Equal 'and is still dirty, so cleanup is still offered'   $true  $script:Reported.Dirty
    Assert-True  'with the original wording' ($script:Reported.Detail -match 'installed nothing')

    Remove-Item Function:\Write-Status, Function:\Write-Activity, Function:\Remove-Unpacked -ErrorAction SilentlyContinue

    # And the entry that caused it must agree with itself.
    $liveCat = (Get-Content -LiteralPath (Join-Path $repo 'server\apps.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $o365 = @($liveCat.apps) | Where-Object { $_.id -eq 'office365' } | Select-Object -First 1
    if ($o365) {
        Assert-True 'office365 no longer verifies a path derived from its name' `
            (-not ((@($o365.verifyPaths) -join ' ') -match 'OfficeSetup\\OfficeSetup\.exe'))
        Assert-Equal 'and its verifyPath agrees with its uninstall detect path' `
            ([string]$o365.uninstall.detect) ([string]@($o365.verifyPaths)[0])
    }

    # ============================================================== 11i. nothing lost in transit
    Write-Section '11i. Every post-install field the worker reads is actually sent to it'

    # A `powershell` step logged its own name - "PowerShell: irm https://..." - and then reported
    # "no command given". The GUI copies post-install steps into the queue FIELD BY FIELD, and
    # `command` was never added when that step type was introduced. The name survived, the
    # command did not, so the message contradicted itself. `folder` and `waitMs` were missing the
    # same way and nobody had noticed.
    #
    # Compared structurally rather than by example, because the next step type will add another
    # field and the person adding it will not think of this list.
    $depAll = Get-Content -LiteralPath (Join-Path $repo 'server\AppDeploy.ps1') -Raw
    $reads = @([regex]::Matches($depAll, '\$step\.([A-Za-z][A-Za-z0-9]*)') |
               ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True 'the worker reads some step fields' ($reads.Count -gt 5)

    $copyAt = $depAll.IndexOf('$step = @{ type =')
    Assert-True 'the GUI step-copy was located' ($copyAt -gt 0)
    $copyEnd = $depAll.IndexOf('}', $depAll.IndexOf('waitMs', $copyAt))
    $copyTxt = $depAll.Substring($copyAt, [Math]::Max(0, $copyEnd - $copyAt))
    $copied = @([regex]::Matches($copyTxt, '([A-Za-z][A-Za-z0-9]*)\s*=') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    # `file` is attached separately when the step carries a url, so it is legitimately absent
    # from the literal. Everything else the worker reads must be in there.
    $missing = @($reads | Where-Object { $_ -ne 'file' -and $copied -notcontains $_ })
    Assert-Equal ('no field the worker reads is dropped on the way (missing: ' + ($missing -join ', ') + ')') `
        0 $missing.Count
    foreach ($f in @('command', 'folder', 'waitMs')) {
        Assert-True "the '$f' field is copied into the queue" ($copied -contains $f)
    }

    # And a batch that installed something must never call it cancelled.
    Assert-True 'a Skipped item is reported as a warning, not as cancelled' `
        ($depAll -match 'hadWarnings -gt 0.*with warnings')
    Assert-True 'only a genuinely Cancelled item is called cancelled' `
        ($depAll -match "wasCancelled = .*'\^Cancelled'")

    # ============================================================== 12. the Worker
    Write-Section '12. The Worker''s catalog filter (node)'

    # The Worker decides which applications a client can even see, so it is now part of this
    # suite rather than a separate thing to remember. It is JavaScript, so it runs under node -
    # and if node is absent that is reported loudly rather than passing by silence.
    $workerTest = Join-Path $repo 'tests\Test-Worker.mjs'
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host '  SKIP  node is not on PATH - tests\Test-Worker.mjs was NOT run' -ForegroundColor Yellow
    } elseif (-not (Test-Path -LiteralPath $workerTest)) {
        Assert-True 'tests\Test-Worker.mjs exists' $false
    } else {
        $wOut = & $node.Source $workerTest 2>&1 | Out-String
        $wExit = $LASTEXITCODE
        $m = [regex]::Match($wOut, 'PASS (\d+)\s+FAIL (\d+)')
        Assert-Equal 'the Worker test suite passes' 0 $wExit
        if ($m.Success) {
            Assert-Equal 'and reports no failures' 0 ([int]$m.Groups[2].Value)
            Write-Host "        ($($m.Groups[1].Value) worker assertions)" -ForegroundColor DarkGray
        } else {
            Assert-True 'the Worker test produced a result line' $false
            Write-Host $wOut -ForegroundColor DarkGray
        }
    }

    # ============================================================== L. the real bucket
    #
    # Everything above runs against a model of R2 that this repository wrote. Two assumptions
    # in that model cannot be checked by it, because it is the thing making them:
    #
    #   * that R2 accepts x-amz-content-sha256: UNSIGNED-PAYLOAD at all
    #   * that the ETag it returns for a part really is that part's MD5
    #
    # The second is load-bearing. Under UNSIGNED-PAYLOAD the signature does not cover the bytes,
    # so the ETag comparison in Send-R2Part is the only thing standing between a corrupted part
    # and a completed object. Both are settled here and nowhere else, which is why this should
    # be run once against the real bucket before the first real push.
    if ($Live) {
        Write-Section 'L. Against the real R2 bucket (-Live)'

        $realCred = $null
        try { $realCred = Get-R2Credential -Path (Get-DefaultR2CredentialPath) } catch { }
        if (-not $realCred) {
            Write-Host '  SKIP  no R2 credentials saved yet - run Push once in the editor first,' -ForegroundColor Yellow
            Write-Host "        or they are not readable by this account ($(Get-DefaultR2CredentialPath))." -ForegroundColor Yellow
        } else {
            Write-Host "  Bucket: $($realCred.Bucket) at $($realCred.Endpoint)" -ForegroundColor DarkGray
            $liveKey  = "files/_pushtest/$([Guid]::NewGuid().ToString('N')).bin"
            $liveFile = Join-Path $sandbox 'live.bin'
            # 30 MiB in 5 MiB parts: six of them, so multipart is genuinely exercised rather
            # than collapsing into a single-shot PUT. 5 MiB is R2's floor for a non-final part.
            $lb = New-Object byte[] (30MB)
            (New-Object Random(4242)).NextBytes($lb)
            [IO.File]::WriteAllBytes($liveFile, $lb)
            $liveSha = (Get-FileHash -LiteralPath $liveFile -Algorithm SHA256).Hash
            $liveSt  = New-State $liveFile $liveSha

            try {
                # Stop it part-way, then resume - the failure the whole design exists for, on
                # the real service rather than on loopback.
                $pr = New-Progress
                $pr.Cancel = $false
                $stopper = [powershell]::Create()
                [void]$stopper.AddScript({ param($p) Start-Sleep -Milliseconds 2500; $p.Cancel = $true }).AddArgument($pr)
                [void]$stopper.BeginInvoke()

                $r = Invoke-R2Upload -Credential $realCred -Key $liveKey -LocalPath $liveFile `
                                     -State $liveSt -Progress $pr -PartSizeBytes 5MB -OnStateChanged { }
                try { $stopper.Dispose() } catch { }

                if ($r.Cancelled) {
                    Assert-True 'a live upload stopped mid-flight keeps a resumable uploadId' `
                        ($null -ne $liveSt.upload -and [string]$liveSt.upload.uploadId)
                    $pr2 = New-Progress
                    $r = Invoke-R2Upload -Credential $realCred -Key $liveKey -LocalPath $liveFile `
                                         -State $liveSt -Progress $pr2 -PartSizeBytes 5MB -OnStateChanged { }
                    Assert-True 'and it resumes against real R2 rather than starting over' ($r.Skipped -ge 1)
                } else {
                    Write-Host '  note: the upload finished before the stop fired - resume not exercised' -ForegroundColor DarkGray
                }

                # Send-R2Part returns Ok ONLY when the ETag R2 sent back equals the MD5 computed
                # locally from the bytes on their way out. So a completed upload is exactly the
                # proof this section exists for - both assumptions at once.
                Assert-True 'R2 accepted UNSIGNED-PAYLOAD and every part ETag matched its local MD5' $r.Ok
                if (-not $r.Ok) {
                    Write-Host "        $($r.Message)" -ForegroundColor Red
                    Write-Host '        If this is a signature or payload-hash refusal, re-run the real' -ForegroundColor Yellow
                    Write-Host '        upload with -SignPayload and treat that as the permanent mode.' -ForegroundColor Yellow
                }

                $liveInfo = Get-R2ObjectInfo -Credential $realCred -Key $liveKey
                Assert-True  'the object is really in the bucket' $liveInfo.Exists
                Assert-Equal 'at exactly the right size' ([long]$lb.Length) ([long]$liveInfo.Size)
                Assert-True  'and its ETag is the multipart shape, md5-of-md5s-<count>' `
                    (([string]$liveInfo.ETag).Trim('"') -match '^[0-9a-f]{32}-\d+$')
            } finally {
                # Never leave a test object in a bucket that costs money and holds licensed
                # payload. Aborts any half-finished multipart upload too.
                if ($liveSt.upload -and [string]$liveSt.upload.uploadId) {
                    try { [void](Remove-R2Upload -Credential $realCred -Key $liveKey -UploadId ([string]$liveSt.upload.uploadId)) } catch { }
                }
                $del = Invoke-R2Request -Credential $realCred -Method 'DELETE' -Key $liveKey
                Assert-True 'the throwaway object was removed again' `
                    ($del.StatusCode -eq 204 -or $del.StatusCode -eq 200 -or $del.StatusCode -eq 404)
            }
        }
    }

} finally {
    if ($script:S3) {
        try {
            $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port)
            $s = $c.GetStream()
            $b = [Text.Encoding]::ASCII.GetBytes("GET /__stop HTTP/1.1`r`nHost: 127.0.0.1`r`n`r`n")
            $s.Write($b, 0, $b.Length); $s.Flush()
            Start-Sleep -Milliseconds 300
            $c.Close()
        } catch { }
        try { $script:S3.Dispose() } catch { }
    }
    if (-not $KeepArtefacts -and (Test-Path -LiteralPath $sandbox)) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop }
        catch { Write-Host "CLEANUP INCOMPLETE: $sandbox" -ForegroundColor Yellow }
    } elseif ($KeepArtefacts) {
        Write-Host "Artefacts kept: $sandbox" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host ("PASS {0}   FAIL {1}" -f $script:Pass, $script:Fail) `
        -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    if ($script:Fail) { exit 1 }
}
