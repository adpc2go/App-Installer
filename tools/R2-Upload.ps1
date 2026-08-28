<#
.SYNOPSIS
    S3 (SigV4) multipart upload to Cloudflare R2. A library - dot-source it, do not run it.

.DESCRIPTION
    Why this exists at all: Publish-Release.ps1 uploads three small files with
    `wrangler r2 object put`, which is a single-shot upload. The catalog is ~63 GB across 17
    applications and the largest single package is 15 GB, so wrangler cannot carry it and
    rclone is a dependency this repo does not want. R2 speaks the S3 API, so the tool speaks
    S3 - multipart, resumable, with no new binaries on the machine.

    Everything here is a pure function. There is no param() block, no top-level side effect
    and nothing after the last closing brace, because three different callers dot-source it:

      * Catalog-Editor.ps1, for the Push button
      * the upload runspace it starts, which dot-sources this file BY PATH so there is
        exactly one copy of the signing code in the process
      * Test-Push.ps1, which needs the transport without a GUI attached

.NOTES
    Two decisions worth knowing before changing anything:

    UNSIGNED-PAYLOAD. Parts are sent with x-amz-content-sha256: UNSIGNED-PAYLOAD so a 64 MiB
    part can stream straight off disk instead of being read once to hash it and again to send
    it. What that gives up is the signature covering the bytes, so it is replaced by checking
    the part's ETag - R2 returns the part's MD5 - against an MD5 computed locally from the
    same buffer on its way out. That check is therefore load-bearing: if R2 ever stops
    returning MD5 as the part ETag, wire integrity is gone and -SignPayload becomes the only
    safe mode. Test-Push.ps1 -Live asserts the ETag really is the MD5.

    The signing key is derived on every single request and never cached. It is five HMACs,
    which is free next to a 64 MiB PUT. Caching it introduces a bug that only appears when an
    upload crosses midnight UTC: the datestamp rolls, the cached key is stale, and every
    remaining part fails with 403. A 15 GB upload on a client link crosses midnight routinely
    and no test harness can reach that, so it is designed away rather than tested for.
#>

# ---------------------------------------------------------------- constants

# SHA-256 of the empty string. Every request that carries no body signs this.
$script:R2EmptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

# R2/S3 limits. MinPart is what R2 enforces on every part but the last; MaxPart and MaxParts
# are the hard ceilings a request is refused above.
$script:R2MinPartBytes = 5MB
$script:R2MaxPartBytes = 5GB
$script:R2MaxParts     = 10000

# ---------------------------------------------------------------- encoding helpers

<#
    RFC 3986 percent-encoding, written out rather than delegated to [Uri]::EscapeDataString.

    EscapeDataString is RFC 3986 compliant on .NET 4.5 and later and would work, but the exact
    escaping is what the signature is computed over - a framework that treats one character
    differently produces SignatureDoesNotMatch against R2 while every local test still passes,
    because the harness signs with the same helper. Spelling it out makes the known-answer
    test in Test-Push.ps1 mean something.
#>
function ConvertTo-RfcEscaped([string]$Text) {
    if (-not $Text) { return '' }
    $sb = New-Object Text.StringBuilder
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($Text)) {
        if (($b -ge 0x41 -and $b -le 0x5A) -or        # A-Z
            ($b -ge 0x61 -and $b -le 0x7A) -or        # a-z
            ($b -ge 0x30 -and $b -le 0x39) -or        # 0-9
             $b -eq 0x2D -or $b -eq 0x5F -or          # - _
             $b -eq 0x2E -or $b -eq 0x7E) {           # . ~
            [void]$sb.Append([char]$b)
        } else {
            [void]$sb.AppendFormat('%{0:X2}', $b)
        }
    }
    return $sb.ToString()
}

<#
    The canonical URI: every path segment escaped, separators left alone.

    S3 is the one AWS service that does NOT double-encode the path here. Encoding the whole
    path in one call would turn the separators into %2F and every request would fail; encoding
    twice would break any key containing a space. A space must come out as %20 and never as +.
#>
function ConvertTo-CanonicalUri([string]$Path) {
    if (-not $Path) { return '/' }
    $out = ($Path.Split('/') | ForEach-Object { ConvertTo-RfcEscaped $_ }) -join '/'
    if (-not $out.StartsWith('/')) { $out = '/' + $out }
    return $out
}

<#
    The canonical query string: sorted by name, both halves escaped, joined with &.

    A valueless parameter canonicalises as "uploads=", with the equals sign and an empty
    value - not as a bare "uploads". Getting that wrong breaks CreateMultipartUpload only,
    which makes it look like a permissions problem rather than a signing one.
#>
function ConvertTo-CanonicalQuery([hashtable]$Query) {
    if (-not $Query -or $Query.Count -eq 0) { return '' }
    $pairs = @()
    foreach ($name in ($Query.Keys | Sort-Object)) {
        $pairs += ('{0}={1}' -f (ConvertTo-RfcEscaped ([string]$name)),
                                (ConvertTo-RfcEscaped ([string]$Query[$name])))
    }
    return ($pairs -join '&')
}

function ConvertTo-HexString([byte[]]$Bytes) {
    $sb = New-Object Text.StringBuilder
    foreach ($b in $Bytes) { [void]$sb.AppendFormat('{0:x2}', $b) }
    return $sb.ToString()
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-HexString $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
}

function Get-HmacSha256 {
    param([byte[]]$Key, [string]$Message)
    $h = New-Object Security.Cryptography.HMACSHA256
    $h.Key = $Key
    try { return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message)) } finally { $h.Dispose() }
}

# ---------------------------------------------------------------- SigV4

function Get-SigV4SigningKey {
    param(
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][string]$DateStamp,
        [string]$Region  = 'auto',
        [string]$Service = 's3'
    )
    $k = [Text.Encoding]::UTF8.GetBytes("AWS4$Secret")
    $k = Get-HmacSha256 $k $DateStamp
    $k = Get-HmacSha256 $k $Region
    $k = Get-HmacSha256 $k $Service
    return (Get-HmacSha256 $k 'aws4_request')
}

<#
    Build the Authorization header for one request.

    It signs EXACTLY the headers handed to it and adds none of its own beyond x-amz-date, so
    the caller decides what is covered and the published AWS test vectors can be reproduced
    verbatim. Returns the intermediate strings as well, because when a signature is wrong the
    only useful question is which of the three stages diverged.
#>
function Get-SigV4Authorization {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$PayloadHash,
        [Parameter(Mandatory = $true)][string]$AccessKeyId,
        [Parameter(Mandatory = $true)][string]$Secret,
        [datetime]$UtcNow = ([datetime]::UtcNow),
        [string]$Region   = 'auto',
        [string]$Service  = 's3'
    )

    $amzDate   = $UtcNow.ToString('yyyyMMddTHHmmssZ')
    $dateStamp = $UtcNow.ToString('yyyyMMdd')
    if (-not $Headers.ContainsKey('x-amz-date')) { $Headers['x-amz-date'] = $amzDate }

    # Canonical headers: lowercase name, trimmed value, sorted by name, one per line.
    $names = @($Headers.Keys | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    $canonHeaders = ''
    foreach ($n in $names) {
        $v = ''
        foreach ($k in $Headers.Keys) {
            if (([string]$k).ToLowerInvariant() -eq $n) { $v = [string]$Headers[$k]; break }
        }
        $canonHeaders += ('{0}:{1}' -f $n, $v.Trim()) + "`n"
    }
    $signedHeaders = ($names -join ';')

    # The query is signed from the URI, not from the caller's hashtable, so what is signed and
    # what is sent cannot drift apart.
    $canonQuery = ''
    if ($Uri.Query -and $Uri.Query.Length -gt 1) {
        $q = @{}
        foreach ($pair in $Uri.Query.TrimStart('?').Split('&')) {
            if (-not $pair) { continue }
            $i = $pair.IndexOf('=')
            if ($i -lt 0) {
                $q[[Uri]::UnescapeDataString($pair)] = ''
            } else {
                $q[[Uri]::UnescapeDataString($pair.Substring(0, $i))] =
                    [Uri]::UnescapeDataString($pair.Substring($i + 1))
            }
        }
        $canonQuery = ConvertTo-CanonicalQuery $q
    }

    # Unescape before canonicalising. [Uri].AbsolutePath hands back the ALREADY-escaped path, so
    # canonicalising it directly turns a space into %2520 - and the AWS published vector cannot
    # catch that, because its path is a bare "/". It would surface only as SignatureDoesNotMatch
    # against real R2, on the first key containing a space or a bracket.
    $canonicalRequest = @(
        $Method.ToUpperInvariant()
        (ConvertTo-CanonicalUri ([Uri]::UnescapeDataString($Uri.AbsolutePath)))
        $canonQuery
        $canonHeaders
        $signedHeaders
        $PayloadHash
    ) -join "`n"

    $scope = "$dateStamp/$Region/$Service/aws4_request"
    $stringToSign = @(
        'AWS4-HMAC-SHA256'
        $amzDate
        $scope
        (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonicalRequest)))
    ) -join "`n"

    # Derived here, every time, on purpose - see the note in the file header about midnight UTC.
    $signingKey = Get-SigV4SigningKey -Secret $Secret -DateStamp $dateStamp -Region $Region -Service $Service
    $signature  = ConvertTo-HexString (Get-HmacSha256 $signingKey $stringToSign)

    return [pscustomobject]@{
        Authorization    = "AWS4-HMAC-SHA256 Credential=$AccessKeyId/$scope, SignedHeaders=$signedHeaders, Signature=$signature"
        Signature        = $signature
        AmzDate          = $amzDate
        DateStamp        = $dateStamp
        SignedHeaders    = $signedHeaders
        CanonicalRequest = $canonicalRequest
        StringToSign     = $stringToSign
    }
}

# ---------------------------------------------------------------- credentials

function Get-R2CredentialObject {
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$AccessKeyId,
        [Parameter(Mandatory = $true)][string]$Secret,
        [string]$Bucket   = 'pc2go-apps',
        [string]$Endpoint = ''
    )
    if (-not $Endpoint) { $Endpoint = "https://$AccountId.r2.cloudflarestorage.com" }
    return [pscustomobject]@{
        AccountId   = $AccountId
        Bucket      = $Bucket
        Endpoint    = $Endpoint.TrimEnd('/')
        AccessKeyId = $AccessKeyId
        Secret      = $Secret
    }
}

function Get-DefaultR2CredentialPath {
    return (Join-Path $env:LOCALAPPDATA 'PC2Go\r2-credentials.xml')
}

<#
    Read the account id wrangler already cached, so the first-run prompt asks for the key pair
    and not for something the machine already knows.
#>
function Get-WranglerAccountId {
    param([string]$RepoRoot)
    $candidates = @()
    if ($RepoRoot) {
        $candidates += (Join-Path $RepoRoot '.wrangler\cache\wrangler-account.json')
        $candidates += (Join-Path $RepoRoot 'cloudflare\.wrangler\cache\wrangler-account.json')
    }
    foreach ($p in $candidates) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $j = (Get-Content -LiteralPath $p -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
            if ($j.account -and $j.account.id) { return [string]$j.account.id }
        } catch { }
    }
    return ''
}

function Save-R2Credential {
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$AccessKeyId,
        [Parameter(Mandatory = $true)][string]$Secret,
        [string]$Bucket   = 'pc2go-apps',
        [string]$Endpoint = '',
        [Parameter(Mandatory = $true)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # ConvertFrom-SecureString with no -Key is DPAPI, CurrentUser scope: the blob is readable
    # only by this Windows account on this machine. The access key id is encrypted too - it is
    # not itself a secret, but half a credential in cleartext in a file a technician will
    # screenshot is a bad look for no gain.
    [pscustomobject]@{
        version     = 1
        accountId   = $AccountId
        bucket      = $Bucket
        endpoint    = $Endpoint
        accessKeyId = (ConvertTo-SecureString $AccessKeyId -AsPlainText -Force | ConvertFrom-SecureString)
        secret      = (ConvertTo-SecureString $Secret      -AsPlainText -Force | ConvertFrom-SecureString)
        savedUtc    = ([datetime]::UtcNow.ToString('o'))
    } | Export-Clixml -LiteralPath $Path -Force
}

function Unprotect-R2Text {
    param([Parameter(Mandatory = $true)][string]$Blob)
    $s = ConvertTo-SecureString $Blob      # throws unless this user, on this machine
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Get-R2Credential {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $b = Import-Clixml -LiteralPath $Path
    try {
        $key = Unprotect-R2Text ([string]$b.accessKeyId)
        $sec = Unprotect-R2Text ([string]$b.secret)
    } catch {
        # Raw, this is "Key not valid for use in specified state." - a crypto exception that
        # reads like a bug in the tool rather than what it is.
        throw ("The saved R2 credentials in $Path cannot be read by this Windows account on " +
               "this machine. They are encrypted per-user, so a copied file or a different " +
               "sign-in will not open them. Enter the key pair again to replace them.")
    }
    return Get-R2CredentialObject -AccountId ([string]$b.accountId) -AccessKeyId $key -Secret $sec `
                                  -Bucket ([string]$b.bucket) -Endpoint ([string]$b.endpoint)
}

# ---------------------------------------------------------------- transport

<#
    Build a signed HttpWebRequest.

    The header split is not stylistic. Content-Length, Content-Type and Host are restricted on
    HttpWebRequest and throw if set through .Headers.Add - they have to go through the typed
    properties. Authorization and the x-amz-* headers are ordinary and go through .Headers.
    We never send a Date header at all; x-amz-date replaces it, which sidesteps the third
    restricted header entirely.
#>
function New-R2WebRequest {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Key,
        [hashtable]$Query           = @{},
        [string]$PayloadHash        = '',
        [long]$ContentLength        = -1,
        [string]$ContentType        = '',
        [datetime]$UtcNow           = ([datetime]::UtcNow),
        [int]$TimeoutSec            = 100,
        [int]$ReadWriteTimeoutSec   = 120
    )
    if (-not $PayloadHash) { $PayloadHash = $script:R2EmptyHash }

    # Path-style addressing (/{bucket}/{key}), not virtual-host style. It keeps the harness
    # able to point the whole library at http://127.0.0.1:<port> with no rewriting, and avoids
    # DNS and SNI surprises against R2.
    $path = '/' + $Credential.Bucket + '/' + $Key.TrimStart('/')
    $url  = $Credential.Endpoint + (ConvertTo-CanonicalUri $path)
    $qs   = ConvertTo-CanonicalQuery $Query
    if ($qs) { $url += '?' + $qs }
    $uri = [Uri]$url

    $headers = @{
        'host'                 = $uri.Authority      # Authority, not Host: it carries the port
        'x-amz-content-sha256' = $PayloadHash
    }
    $sig = Get-SigV4Authorization -Method $Method -Uri $uri -Headers $headers -PayloadHash $PayloadHash `
                                  -AccessKeyId $Credential.AccessKeyId -Secret $Credential.Secret -UtcNow $UtcNow

    $req = [Net.HttpWebRequest]::Create($uri)
    $req.Method  = $Method.ToUpperInvariant()
    $req.Timeout = $TimeoutSec * 1000
    # Without ReadWriteTimeout a half-dead socket parks the upload for ever instead of raising
    # the WebException the retry loop is waiting for. This is the difference between "it
    # resumed" and "it hung overnight".
    $req.ReadWriteTimeout  = $ReadWriteTimeoutSec * 1000
    $req.KeepAlive         = $true
    $req.AllowAutoRedirect = $false
    $req.ServicePoint.Expect100Continue = $false     # one wasted round trip per part otherwise
    $req.UserAgent = 'PC2Go-CatalogEditor/1.0'
    $req.Headers.Add('Authorization', $sig.Authorization)
    $req.Headers.Add('x-amz-content-sha256', $PayloadHash)
    $req.Headers.Add('x-amz-date', [string]$headers['x-amz-date'])
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($ContentLength -ge 0) {
        $req.ContentLength = $ContentLength
        $req.AllowWriteStreamBuffering = $false      # do not buffer 64 MiB in memory
    }
    return $req
}

<#
    Turn a response - or the response carried by a WebException - into one shape.

    Non-2xx makes HttpWebRequest throw, and the useful information (the status code, and R2's
    <Error><Code> body) is inside the exception. Callers need to branch on 403 versus 500
    versus NoSuchUpload, so a thrown WebException is converted into a result rather than
    propagated. A WebException with no response at all - a reset socket, DNS, a timeout - has
    no status, and that is reported as status 0 with the exception message.
#>
function Read-R2Response {
    param($Request)
    $resp = $null
    try {
        $resp = $Request.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) {
            return [pscustomobject]@{
                StatusCode = 0; Headers = @{}; Body = ''; ErrorCode = ''
                Transport  = $true; Message = $_.Exception.Message
            }
        }
    }
    try {
        $body = ''
        $stream = $resp.GetResponseStream()
        if ($stream) {
            $sr = New-Object IO.StreamReader($stream)
            try { $body = $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
        $h = @{}
        foreach ($n in $resp.Headers.AllKeys) { $h[$n.ToLowerInvariant()] = $resp.Headers[$n] }

        $code = ''
        if ($body -and $body -match '<Code>([^<]+)</Code>') { $code = $Matches[1] }

        return [pscustomobject]@{
            StatusCode = [int]$resp.StatusCode
            Headers    = $h
            Body       = $body
            ErrorCode  = $code
            Transport  = $false
            Message    = ''
        }
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function Invoke-R2Request {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Key,
        [hashtable]$Query    = @{},
        [byte[]]$Body,
        [string]$ContentType = '',
        [switch]$UnsignedPayload,
        [int]$TimeoutSec     = 100
    )
    $len  = -1
    $hash = $script:R2EmptyHash
    if ($Body -and $Body.Length) {
        $len  = [long]$Body.Length
        $hash = $(if ($UnsignedPayload) { 'UNSIGNED-PAYLOAD' } else { Get-Sha256Hex $Body })
    } elseif ($Method -eq 'PUT' -or $Method -eq 'POST') {
        $len = 0
    }

    $req = New-R2WebRequest -Credential $Credential -Method $Method -Key $Key -Query $Query `
                            -PayloadHash $hash -ContentLength $len -ContentType $ContentType `
                            -TimeoutSec $TimeoutSec
    if ($Body -and $Body.Length) {
        try {
            $rs = $req.GetRequestStream()
            try { $rs.Write($Body, 0, $Body.Length) } finally { $rs.Dispose() }
        } catch [Net.WebException] {
            return [pscustomobject]@{
                StatusCode = 0; Headers = @{}; Body = ''; ErrorCode = ''
                Transport  = $true; Message = $_.Exception.Message
            }
        }
    }
    return Read-R2Response $req
}

# ---------------------------------------------------------------- S3 operations

function Get-R2ObjectInfo {
    param([Parameter(Mandatory = $true)]$Credential, [Parameter(Mandatory = $true)][string]$Key)
    $r = Invoke-R2Request -Credential $Credential -Method 'HEAD' -Key $Key
    if ($r.StatusCode -eq 200) {
        $size = [long]0
        if ($r.Headers.ContainsKey('content-length')) { $size = [long]$r.Headers['content-length'] }
        $etag = ''
        if ($r.Headers.ContainsKey('etag')) { $etag = [string]$r.Headers['etag'] }
        return [pscustomobject]@{ Exists = $true; Size = $size; ETag = $etag; StatusCode = 200 }
    }
    return [pscustomobject]@{ Exists = $false; Size = [long]0; ETag = ''; StatusCode = $r.StatusCode }
}

function New-R2Upload {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$ContentType = 'application/octet-stream'
    )
    $r = Invoke-R2Request -Credential $Credential -Method 'POST' -Key $Key `
                          -Query @{ 'uploads' = '' } -ContentType $ContentType
    if ($r.StatusCode -ne 200) {
        throw "R2 refused to start a multipart upload for '$Key' (HTTP $($r.StatusCode)$(if ($r.ErrorCode) { " $($r.ErrorCode)" })). $($r.Message)"
    }
    # SelectNodes without a namespace manager returns nothing against S3's default namespace,
    # which reads as "R2 sent an empty response". Dotted access is namespace-agnostic.
    $x  = [xml]$r.Body
    $id = [string]$x.InitiateMultipartUploadResult.UploadId
    if (-not $id) { throw "R2 started a multipart upload for '$Key' but returned no UploadId." }
    return $id
}

function Get-R2UploadParts {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$UploadId
    )
    $parts  = @{}
    $marker = ''
    while ($true) {
        $q = @{ 'uploadId' = $UploadId; 'max-parts' = '1000' }
        if ($marker) { $q['part-number-marker'] = $marker }
        $r = Invoke-R2Request -Credential $Credential -Method 'GET' -Key $Key -Query $q
        if ($r.StatusCode -eq 404 -or $r.ErrorCode -eq 'NoSuchUpload') { return $null }
        if ($r.StatusCode -ne 200) {
            throw "Could not list the parts already uploaded for '$Key' (HTTP $($r.StatusCode)$(if ($r.ErrorCode) { " $($r.ErrorCode)" })). $($r.Message)"
        }
        $x = [xml]$r.Body
        foreach ($p in @($x.ListPartsResult.Part)) {
            if (-not $p) { continue }
            $parts[[int]$p.PartNumber] = [pscustomobject]@{
                ETag = ([string]$p.ETag).Trim('"'); Size = [long]$p.Size
            }
        }
        # Pagination is unreachable at 224 parts, but a catalog that grows a 700 GB entry would
        # hit it and the failure is silent: half the parts look missing and get re-uploaded.
        if (([string]$x.ListPartsResult.IsTruncated) -ne 'true') { break }
        $marker = [string]$x.ListPartsResult.NextPartNumberMarker
        if (-not $marker) { break }
    }
    return $parts
}

function Complete-R2Upload {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$UploadId,
        [Parameter(Mandatory = $true)][hashtable]$Parts
    )
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<CompleteMultipartUpload>')
    foreach ($n in ($Parts.Keys | Sort-Object { [int]$_ })) {
        $etag = ([string]$Parts[$n]).Trim().Trim('"')
        [void]$sb.AppendFormat('<Part><PartNumber>{0}</PartNumber><ETag>"{1}"</ETag></Part>', [int]$n, $etag)
    }
    [void]$sb.Append('</CompleteMultipartUpload>')

    $body = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $r = Invoke-R2Request -Credential $Credential -Method 'POST' -Key $Key `
                          -Query @{ 'uploadId' = $UploadId } -Body $body -ContentType 'application/xml'
    if ($r.StatusCode -ne 200) {
        throw "R2 refused to complete the upload of '$Key' (HTTP $($r.StatusCode)$(if ($r.ErrorCode) { " $($r.ErrorCode)" })). $($r.Message)"
    }
    # S3 can answer 200 and then put an <Error> in the body - it starts the response before it
    # knows the outcome. Treating that as success would report a finished upload that is not
    # there, which is the one lie this whole file exists to avoid.
    if ($r.ErrorCode) {
        throw "R2 refused to complete the upload of '$Key': $($r.ErrorCode). $($r.Body)"
    }
    $x = [xml]$r.Body
    return [string]$x.CompleteMultipartUploadResult.ETag
}

function Remove-R2Upload {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$UploadId
    )
    $r = Invoke-R2Request -Credential $Credential -Method 'DELETE' -Key $Key -Query @{ 'uploadId' = $UploadId }
    return ($r.StatusCode -eq 204 -or $r.StatusCode -eq 200 -or $r.StatusCode -eq 404)
}

# ---------------------------------------------------------------- part sizing

<#
    Choose a part size for a file.

    64 MiB by default, which matches the --s3-chunk-size 64M that cloudflare\README.md already
    recommends for rclone, and puts the 15 GB package at 224 parts. R2's floor is 5 MiB; using
    it would make Revit 3,000 round trips and 3,000 sidecar writes to save nothing.

    The /9000 term is headroom against the 10,000-part cap rather than a real constraint - at
    a fixed 64 MiB the ceiling is already 625 GB. It exists so a hypothetical 700 GB entry
    raises the part size instead of being refused at part 10,001 (InvalidArgument) after
    eight hours of uploading the first 10,000.
#>
function Get-R2PartSize {
    param([Parameter(Mandatory = $true)][long]$SizeBytes, [long]$MinPartBytes = 64MB)
    if ($SizeBytes -le 0) { return [long]$MinPartBytes }
    $need = [long][Math]::Ceiling($SizeBytes / 9000.0)
    $size = [long][Math]::Max([long]$MinPartBytes, $need)
    # round up to a whole 8 MiB, so the number is readable in a log
    $size = [long]([Math]::Ceiling($size / 8MB) * 8MB)
    if ($size -gt $script:R2MaxPartBytes) {
        throw ("$SizeBytes bytes cannot be uploaded: it would need parts larger than R2's 5 GB " +
               'maximum part size.')
    }
    return $size
}

function Get-R2PartCount {
    param([Parameter(Mandatory = $true)][long]$SizeBytes, [Parameter(Mandatory = $true)][long]$PartSizeBytes)
    if ($SizeBytes -le 0) { return 0 }
    return [int][Math]::Ceiling($SizeBytes / [double]$PartSizeBytes)
}

# ---------------------------------------------------------------- sending one part

<#
    Send one part, streaming it off disk, and prove it landed intact.

    The MD5 is computed from the very buffer being written, so it measures what actually went
    out rather than what was on disk a moment earlier, and it is compared to the ETag R2
    returns. Under UNSIGNED-PAYLOAD that comparison is the only thing standing between a
    corrupted part and a completed object, so a mismatch fails this attempt.

    Cancel is checked every buffer - roughly every megabyte - rather than only between parts,
    so Stop lands in about a second instead of after 64 MiB. (On the -SignPayload fallback the
    whole part is read and hashed first, so there Stop lands between parts.)
#>
function Send-R2Part {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$UploadId,
        [Parameter(Mandatory = $true)][int]$PartNumber,
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][long]$Length,
        $Progress,
        [switch]$SignPayload,
        [int]$TimeoutSec = 100
    )

    [void]$Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $query = @{ 'partNumber' = [string]$PartNumber; 'uploadId' = $UploadId }
    $sent  = [long]0

    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $payloadHash = 'UNSIGNED-PAYLOAD'
        $buffered    = $null

        if ($SignPayload) {
            # The fallback path: read the part fully so it can be hashed, then send those exact
            # bytes. Two passes and up to 64 MiB on the Large Object Heap - which is why it is
            # not the default - but it is the only mode that survives R2 refusing UNSIGNED-PAYLOAD.
            $buffered = New-Object byte[] $Length
            $got = [long]0
            while ($got -lt $Length) {
                $n = $Stream.Read($buffered, [int]$got, [int][Math]::Min([long]1MB, $Length - $got))
                if ($n -le 0) { break }
                $got += $n
            }
            if ($got -ne $Length) { throw "Part ${PartNumber}: expected $Length bytes but the file gave $got." }
            $payloadHash = Get-Sha256Hex $buffered
        }

        $req = New-R2WebRequest -Credential $Credential -Method 'PUT' -Key $Key -Query $query `
                                -PayloadHash $payloadHash -ContentLength $Length -TimeoutSec $TimeoutSec

        try {
            $rs = $req.GetRequestStream()
            try {
                if ($SignPayload) {
                    [void]$md5.TransformFinalBlock($buffered, 0, $buffered.Length)
                    $rs.Write($buffered, 0, $buffered.Length)
                    $sent = $Length
                    if ($Progress) { $Progress.AppBytes = [long]$Progress.AppBytes + $Length }
                } else {
                    $buf  = New-Object byte[] (1MB)
                    $left = $Length
                    while ($left -gt 0) {
                        if ($Progress -and $Progress.Cancel) { throw 'PC2GO_CANCELLED' }
                        $want = [int][Math]::Min([long]$buf.Length, $left)
                        $n = $Stream.Read($buf, 0, $want)
                        if ($n -le 0) { throw "Part ${PartNumber}: the file ended $left bytes early." }
                        [void]$md5.TransformBlock($buf, 0, $n, $null, 0)
                        $rs.Write($buf, 0, $n)
                        $left -= $n
                        $sent += $n
                        if ($Progress) { $Progress.AppBytes = [long]$Progress.AppBytes + $n }
                    }
                    [void]$md5.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                }
            } finally { $rs.Dispose() }
        } catch {
            # Cancel is a control flow signal, not a fault - it must reach the caller intact.
            if ("$($_.Exception.Message)" -eq 'PC2GO_CANCELLED') { throw }
            # The socket died while the body was going out. A reset mid-write surfaces as
            # IOException as often as WebException - catching only the latter would let a
            # dropped connection escape as an unhandled error instead of being retried, which
            # is the single most common real-world failure this code exists to survive.
            # Hand back the bytes already counted so the caller can wind the progress total
            # back before retrying, or a re-sent part is counted twice and the bar passes 100%.
            # A read-side fault ("the file ended N bytes early", a Seek that failed) is not a
            # network fault, and looked like one: StatusCode 0 is retried five times, ~30 s of
            # backoff, for a file that will be exactly as short on every attempt.
            $local = ("$($_.Exception.Message)" -match '^Part \d+:')
            return [pscustomobject]@{
                Ok = $false; ETag = ''; StatusCode = 0; ErrorCode = $(if ($local) { 'LocalRead' } else { '' })
                Message = $_.Exception.Message; BytesSent = $sent
            }
        }

        $r = Read-R2Response $req
        if ($r.StatusCode -ne 200) {
            return [pscustomobject]@{
                Ok = $false; ETag = ''; StatusCode = $r.StatusCode; ErrorCode = $r.ErrorCode
                Message = $(if ($r.Message) { $r.Message } else { $r.Body }); BytesSent = $sent
            }
        }

        $etag = ''
        if ($r.Headers.ContainsKey('etag')) { $etag = ([string]$r.Headers['etag']).Trim('"') }
        $local = ConvertTo-HexString $md5.Hash

        if (-not $etag) {
            return [pscustomobject]@{
                Ok = $false; ETag = ''; StatusCode = 200; ErrorCode = 'NoETag'; BytesSent = $sent
                Message = "Part $PartNumber was accepted but R2 returned no ETag, so it cannot be verified."
            }
        }
        if ($etag.ToLowerInvariant() -ne $local.ToLowerInvariant()) {
            return [pscustomobject]@{
                Ok = $false; ETag = $etag; StatusCode = 200; ErrorCode = 'ETagMismatch'; BytesSent = $sent
                Message = "Part $PartNumber arrived as $etag but was sent as $local - it did not land intact."
            }
        }
        return [pscustomobject]@{
            Ok = $true; ETag = $etag; StatusCode = 200; ErrorCode = ''; Message = ''; BytesSent = $sent
        }

    } finally { $md5.Dispose() }
}

# ---------------------------------------------------------------- retry policy

<#
    Which failures are worth trying again.

    403 and the other 4xx are deliberately NOT retried: a bad key, a read-only token or a
    wrong signature fails identically five times, and the delay only hides the real message.
    NoSuchUpload on a part is a 4xx too, so it ends this push; the NEXT push lists the parts,
    finds the upload gone, and starts a fresh one - that is where it is actually handled.
#>
function Test-R2Retryable {
    param($Result)
    if ($Result.ErrorCode -eq 'LocalRead') { return $false }   # the file is short; the network is fine
    if ($Result.StatusCode -eq 0)   { return $true }      # reset socket, timeout, DNS
    if ($Result.StatusCode -ge 500) { return $true }
    if ($Result.StatusCode -eq 429) { return $true }
    return ($Result.ErrorCode -eq 'SlowDown'      -or $Result.ErrorCode -eq 'InternalError' -or
            $Result.ErrorCode -eq 'RequestTimeout' -or $Result.ErrorCode -eq 'ETagMismatch' -or
            $Result.ErrorCode -eq 'NoETag')
}

function Get-R2BackoffSeconds {
    param([Parameter(Mandatory = $true)][int]$Attempt, [double]$BaseSeconds = 2.0)
    $base   = $BaseSeconds * [Math]::Pow(2, ($Attempt - 1))              # 2, 4, 8, 16
    $jitter = 0.8 + ((Get-Random -Minimum 0 -Maximum 401) / 1000.0)      # +/- 20%
    return [Math]::Round($base * $jitter, 2)
}

# ---------------------------------------------------------------- one whole file

function Get-R2ExpectedPartLength {
    param([long]$SizeBytes, [long]$PartSizeBytes, [int]$PartNumber, [int]$PartCount)
    if ($PartNumber -lt $PartCount) { return [long]$PartSizeBytes }
    return [long]($SizeBytes - ([long]($PartCount - 1) * $PartSizeBytes))
}

<#
    Upload one local file to one R2 key, resuming whatever a previous run left behind.

    $State is the sidecar entry for this app, a hashtable, mutated in place. $OnStateChanged is
    called after every meaningful change so the caller can persist it - after every part, on
    purpose. Writing a 4 KB JSON file 224 times over four hours costs nothing, and persisting
    the uploadId BEFORE the first part is the difference between an upload that resumes and an
    orphan R2 charges storage for.

    On resume, R2 is the authority and the sidecar is only a hint. ListParts decides what is
    really there; a part the sidecar claims but R2 does not return, or returns at the wrong
    length, is re-uploaded. Trusting the local file instead would produce an object that
    completes successfully and is quietly wrong.

    The three refusals are the point of the whole function:
      * the part size changed since the uploadId was issued  -> abort and start fresh, because
        R2 requires every part but the last to be identical in size and the mismatch would not
        surface until CompleteMultipartUpload, after every byte had already gone up
      * the local file's length or mtime changed             -> abort and start fresh, because
        resuming would splice two different files together and hash the result as if it were one
      * a part cannot be verified against its ETag           -> never complete the upload
#>
function Invoke-R2Upload {
    param(
        [Parameter(Mandatory = $true)]$Credential,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)]$State,
        $Progress,
        [long]$PartSizeBytes = 0,
        [int]$MaxAttempts    = 5,
        [switch]$SignPayload,
        [scriptblock]$OnStateChanged,
        [double]$BackoffBaseSeconds = 2.0
    )

    $persist = { if ($OnStateChanged) { & $OnStateChanged } }

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                  Message = "The installer is no longer at $LocalPath."
                                  Uploaded = 0; Skipped = 0 }
    }
    $fi     = Get-Item -LiteralPath $LocalPath
    $length = [long]$fi.Length
    $mtime  = $fi.LastWriteTimeUtc.ToString('o')

    if ($length -le 0) {
        return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                  Message = "$LocalPath is empty."; Uploaded = 0; Skipped = 0 }
    }

    $partSize = $(if ($PartSizeBytes -gt 0) { [long]$PartSizeBytes } else { Get-R2PartSize -SizeBytes $length })
    $count    = Get-R2PartCount -SizeBytes $length -PartSizeBytes $partSize

    if ($count -gt $script:R2MaxParts) {
        return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                  Message = "$LocalPath would need $count parts, past R2's limit of $($script:R2MaxParts)."
                                  Uploaded = 0; Skipped = 0 }
    }

    # ------------------------------------------------------------ resume or start fresh
    $done     = @{}          # partNumber -> etag, believed to be in R2
    $uploadId = ''

    if ($State.ContainsKey('upload') -and $State.upload -and $State.upload.uploadId) {
        $uploadId = [string]$State.upload.uploadId
        $why      = ''
        if ([long]$State.upload.partSizeBytes -ne $partSize) {
            $why = "the part size changed from $($State.upload.partSizeBytes) to $partSize"
        } elseif ([long]$State.sizeBytes -ne $length) {
            $why = "the file is now $length bytes, not $($State.sizeBytes)"
        } elseif ([string]$State.mtimeUtc -ne $mtime) {
            $why = 'the file was modified since that upload started'
        } elseif ([string]$State.key -and [string]$State.key -ne $Key) {
            # An uploadId belongs to ONE key. A renamed id or re-pathed file yields a new key,
            # and listing the old upload under it answered NoSuchUpload - so the old upload was
            # never aborted, just forgotten, and stayed billable in the bucket for ever.
            $why = "the R2 key changed from $($State.key) to $Key"
        }
        if ($why) {
            $oldKey = $(if ([string]$State.key) { [string]$State.key } else { $Key })
            $aborted = $false
            try { $aborted = [bool](Remove-R2Upload -Credential $Credential -Key $oldKey -UploadId $uploadId) } catch { $aborted = $false }
            if (-not $aborted -and $Progress -and $Progress.Log) {
                # not silent: an upload that could not be aborted is still costing money
                [void]$Progress.Log.Add("${oldKey}: the previous multipart upload ($uploadId) could not be aborted - abort it from the R2 dashboard")
            }
            $uploadId = ''
            $State.upload = $null
            & $persist
            if ($Progress -and $Progress.Log) { [void]$Progress.Log.Add("$Key restarted: $why") }
        } else {
            $remote = $null
            $listFailed = ''
            try { $remote = Get-R2UploadParts -Credential $Credential -Key $Key -UploadId $uploadId }
            catch { $remote = $null; $listFailed = $_.Exception.Message }
            if ($listFailed) {
                # A 5xx, a 429 or a dropped socket on the LISTING is not "R2 has forgotten it".
                # Treating it that way discarded the uploadId, orphaned every part already up
                # (billable, never aborted) and sent the whole file again. Keep the state, fail
                # this push, and the next one resumes exactly where this one would have.
                return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                          Message = "could not check which parts are already uploaded - $listFailed. Nothing was discarded; push again to resume."
                                          Uploaded = 0; Skipped = 0 }
            }
            if ($null -eq $remote) {
                # R2 has forgotten it - expired, aborted, or never existed. Or: it was COMPLETED
                # and the completion's response never arrived, which looks identical from here.
                # If the object is already there at the right size, that is what happened, and
                # re-uploading the whole file to prove it would be the wrong answer.
                $obj = $null
                try { $obj = Get-R2ObjectInfo -Credential $Credential -Key $Key } catch { $obj = $null }
                if ($obj -and $obj.Exists -and [long]$obj.Size -eq $length) {
                    $State.upload = $null
                    $State.remote = @{ verifiedUtc = ([datetime]::UtcNow.ToString('o')); sizeBytes = $length
                                       etag = [string]$obj.ETag; sha256 = [string]$State.sha256 }
                    & $persist
                    if ($Progress -and $Progress.Log) { [void]$Progress.Log.Add("${Key}: the previous upload had already completed - nothing to send") }
                    return [pscustomobject]@{ Ok = $true; Cancelled = $false; ETag = [string]$obj.ETag; Message = ''
                                              Uploaded = 0; Skipped = $count }
                }
                $uploadId = ''
                $State.upload = $null
                & $persist
            } else {
                foreach ($n in $remote.Keys) {
                    $expect = Get-R2ExpectedPartLength -SizeBytes $length -PartSizeBytes $partSize `
                                                       -PartNumber ([int]$n) -PartCount $count
                    if ([long]$remote[$n].Size -eq $expect) { $done[[int]$n] = [string]$remote[$n].ETag }
                }
            }
        }
    }

    if (-not $uploadId) {
        $uploadId = New-R2Upload -Credential $Credential -Key $Key
        $State.sizeBytes = $length
        $State.mtimeUtc  = $mtime
        $State.key       = $Key
        $State.upload    = @{ uploadId = $uploadId; partSizeBytes = $partSize
                              startedUtc = ([datetime]::UtcNow.ToString('o')); parts = @{} }
        # Before the first part goes up, never after.
        & $persist
        $done = @{}
    }

    # The sidecar's part list is rebuilt from what R2 actually reported, so a stale local claim
    # cannot survive a resume.
    $State.upload.parts = @{}
    foreach ($n in $done.Keys) { $State.upload.parts["$n"] = $done[$n] }
    & $persist

    if ($Progress) {
        $already = [long]0
        foreach ($n in $done.Keys) {
            $already += Get-R2ExpectedPartLength -SizeBytes $length -PartSizeBytes $partSize `
                                                 -PartNumber ([int]$n) -PartCount $count
        }
        $Progress.AppBytes  = $already
        $Progress.AppTotal  = $length
        $Progress.PartCount = $count
    }

    # ------------------------------------------------------------ send what is missing
    $skipped  = $done.Count
    $uploaded = 0
    # FileShare.Read denies other writers for the whole upload: the file cannot be swapped or
    # appended to underneath us between part 1 and part 224.
    $fs = New-Object IO.FileStream($LocalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        for ($n = 1; $n -le $count; $n++) {
            if ($done.ContainsKey($n)) { continue }
            if ($Progress -and $Progress.Cancel) {
                return [pscustomobject]@{ Ok = $false; Cancelled = $true; ETag = ''
                                          Message = "Stopped after $uploaded of $count parts."
                                          Uploaded = $uploaded; Skipped = $skipped }
            }

            $offset = [long]($n - 1) * $partSize
            $len    = Get-R2ExpectedPartLength -SizeBytes $length -PartSizeBytes $partSize `
                                               -PartNumber $n -PartCount $count
            if ($Progress) { $Progress.Part = $n }

            $result   = $null
            $lastFail = ''
            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try {
                    $result = Send-R2Part -Credential $Credential -Key $Key -UploadId $uploadId `
                                          -PartNumber $n -Stream $fs -Offset $offset -Length $len `
                                          -Progress $Progress -SignPayload:$SignPayload
                } catch {
                    if ("$($_.Exception.Message)" -eq 'PC2GO_CANCELLED') {
                        return [pscustomobject]@{ Ok = $false; Cancelled = $true; ETag = ''
                                                  Message = "Stopped during part $n of $count."
                                                  Uploaded = $uploaded; Skipped = $skipped }
                    }
                    $result = [pscustomobject]@{ Ok = $false; ETag = ''; StatusCode = 0; ErrorCode = ''
                                                 Message = $_.Exception.Message; BytesSent = [long]0 }
                }
                if ($result.Ok) { break }

                # Wind the counter back before retrying, or a part sent twice is counted twice
                # and the percentage sails past 100.
                if ($Progress -and $result.BytesSent) {
                    $Progress.AppBytes = [long]$Progress.AppBytes - [long]$result.BytesSent
                }
                $lastFail = $result.Message
                if (-not (Test-R2Retryable $result)) { break }
                if ($attempt -lt $MaxAttempts) {
                    $wait = Get-R2BackoffSeconds -Attempt $attempt -BaseSeconds $BackoffBaseSeconds
                    if ($Progress -and $Progress.Log) {
                        [void]$Progress.Log.Add("$Key part $n attempt $attempt failed ($lastFail); retrying in ${wait}s")
                    }
                    # Slept in slices so Stop is still answered during a 16-second backoff.
                    $until = (Get-Date).AddSeconds($wait)
                    while ((Get-Date) -lt $until) {
                        if ($Progress -and $Progress.Cancel) { break }
                        Start-Sleep -Milliseconds 200
                    }
                    if ($Progress -and $Progress.Cancel) {
                        return [pscustomobject]@{ Ok = $false; Cancelled = $true; ETag = ''
                                                  Message = "Stopped during part $n of $count."
                                                  Uploaded = $uploaded; Skipped = $skipped }
                    }
                }
            }

            if (-not $result.Ok) {
                # The uploadId and every good part stay in the sidecar. Pushing again carries on
                # from here rather than starting the file over.
                return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                          Message = "part $n of $count failed after $MaxAttempts attempt(s): $lastFail"
                                          Uploaded = $uploaded; Skipped = $skipped }
            }

            $done[$n] = $result.ETag
            $State.upload.parts["$n"] = $result.ETag
            $uploaded++
            & $persist
        }
    } finally { $fs.Dispose() }

    # ------------------------------------------------------------ complete
    # Retried like a part for transient faults - a single 5xx after a four-hour upload used to
    # end the push with an exception. A PERMANENT refusal (InvalidPart, EntityTooSmall,
    # InvalidPartOrder, any other 4xx) is different: the next push would list the same parts,
    # find them all present, call Complete again and fail identically, for ever, with the
    # upload dangling - so that upload is aborted and the state cleared, and the push says so.
    $etag = ''
    $completeErr = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $etag = Complete-R2Upload -Credential $Credential -Key $Key -UploadId $uploadId -Parts $done; $completeErr = ''; break }
        catch { $completeErr = $_.Exception.Message }
        if ($completeErr -match 'HTTP 4\d\d|InvalidPart|EntityTooSmall|InvalidPartOrder|NoSuchUpload') { break }
        if ($attempt -lt 3) {
            $wait = Get-R2BackoffSeconds -Attempt $attempt -BaseSeconds $BackoffBaseSeconds
            if ($Progress -and $Progress.Log) { [void]$Progress.Log.Add("$Key complete attempt $attempt failed ($completeErr); retrying in ${wait}s") }
            Start-Sleep -Seconds ([int][Math]::Ceiling($wait))
        }
    }
    if ($completeErr) {
        if ($completeErr -match 'HTTP 4\d\d|InvalidPart|EntityTooSmall|InvalidPartOrder|NoSuchUpload') {
            try { [void](Remove-R2Upload -Credential $Credential -Key $Key -UploadId $uploadId) } catch { }
            $State.upload = $null
            & $persist
            return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                      Message = "R2 would not assemble the parts ($completeErr). That upload was abandoned; push again to send the file afresh."
                                      Uploaded = $uploaded; Skipped = $skipped }
        }
        # transient and still failing: the parts stay, the next push resumes at Complete
        return [pscustomobject]@{ Ok = $false; Cancelled = $false; ETag = ''
                                  Message = "every part is uploaded but the completion failed ($completeErr). Push again to finish it."
                                  Uploaded = $uploaded; Skipped = $skipped }
    }

    $State.upload = $null
    $State.remote = @{ verifiedUtc = ([datetime]::UtcNow.ToString('o')); sizeBytes = $length
                       etag = $etag; sha256 = [string]$State.sha256 }
    & $persist

    return [pscustomobject]@{ Ok = $true; Cancelled = $false; ETag = $etag; Message = ''
                              Uploaded = $uploaded; Skipped = $skipped }
}

# ================================================================ wrangler, watched
#
# Everything below exists so wrangler can run with NO console window without blocking the window
# that started it.
#
# The console window was load-bearing before this. wrangler stops and waits when a Cloudflare
# sign-in has expired, and the only reason that was survivable is that a person could see the
# prompt. Hiding the window on its own would have turned a visible prompt into a permanent,
# silent hang - strictly worse than what it replaced. So the visibility is not removed, it is
# rebuilt from three things: the output is drained and shown inside the app, a sign-in prompt is
# recognised from its own text, and two independent clocks give up rather than wait for ever.

# taskkill /T, because npx is a launcher: it spawns node, which spawns wrangler. Killing the
# parent alone leaves the real process running - still holding the stdout file this drains, and
# still able to change the edge some seconds after the operator pressed Stop.
function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        Start-Process -FilePath $tk -ArgumentList @('/PID', "$ProcessId", '/T', '/F') `
                      -Wait -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
}

<#
    Where wrangler actually is - resolved once, and in ONE place for every caller.

    There is more than one way for wrangler to be present and only one of them puts it on PATH.
    A global npm install does; reaching it through npx - which is how the OAuth login on this
    machine was made - does not.

    This lives here rather than in Publish-Release.ps1 because the two callers disagreed. The
    editor hardcoded `cmd /c npx wrangler`, so a machine with wrangler installed globally but no
    npx published fine and failed to set the access code; and that same hardcoded line omitted
    --yes, so a cold npx cache sat on its own "Ok to proceed?" prompt. Both of those are silent
    hangs once the window is hidden, which is why this had to move before the window could go.
#>
$script:WranglerCmd = $null
function Resolve-Wrangler {
    if ($script:WranglerCmd) { return $script:WranglerCmd }
    $direct = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($direct) { $script:WranglerCmd = @{ Exe = $direct.Source; Pre = @() }; return $script:WranglerCmd }
    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if ($npx) {
        # --yes so a missing package is fetched rather than sitting on a confirmation prompt
        # nobody is watching for.
        $script:WranglerCmd = @{ Exe = $npx.Source; Pre = @('--yes', 'wrangler') }
        return $script:WranglerCmd
    }
    throw ('wrangler is not installed and npx is not available. Install Node.js, then either ' +
           '"npm install -g wrangler" or make sure npx is on PATH.')
}

<#
    A file holding one secret, readable by nobody else, created that way rather than made that
    way afterwards.

    WriteAllText followed by SetAccessControl leaves a window - short, but real - in which the
    file exists with inherited permissions and the secret already inside it. Handing the DACL to
    the FileStream constructor means the file never exists in any other state.
#>
function New-SecretTempFile {
    param([Parameter(Mandatory = $true)][string]$Text)
    $path = Join-Path $env:TEMP ('pc2go-secret-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $sec = New-Object Security.AccessControl.FileSecurity
    # Protection first, inheritance NOT copied: without this the inherited entries survive and
    # the rule added below is an addition to them rather than the whole list.
    $sec.SetAccessRuleProtection($true, $false)
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        ([Security.Principal.WindowsIdentity]::GetCurrent()).User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)))
    # No BOM. wrangler reads stdin verbatim, so a BOM would become the first character of the
    # access code and every technician would be typing a code that does not match.
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Text)
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew,
                                   [Security.AccessControl.FileSystemRights]::WriteData,
                                   [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    return $path
}

function Remove-SecretTempFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    # Overwritten before deletion. On an SSD that is better than handing the bytes to free space
    # rather than a guaranteed erase - the same trick the client side uses, with the same honesty
    # about what it is worth.
    try { [IO.File]::WriteAllBytes($Path, (New-Object byte[] ([int](Get-Item -LiteralPath $Path).Length))) } catch { }
    try { Remove-Item -LiteralPath $Path -Force } catch { }
}

<#
    Read whatever WHOLE lines have appeared since last time.

    The child process holds these files open, so the handle must share Read AND Write or every
    single poll throws and the progress silently freezes - which would look exactly like the
    hang this whole file exists to remove.

    Only complete lines are consumed; a half-written last line is left for the next pass. That
    also keeps the byte offset on a character boundary, so a multi-byte character split across
    two reads is never decoded twice or half. -Flush lifts the rule once the process has exited,
    because there will be no next pass and wrangler does not always end its last line.
#>
function Read-WatchedFile {
    param([string]$Path, [Parameter(Mandatory = $true)][ref]$Offset, [switch]$Flush)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try { $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
    catch { return '' }
    try {
        if ($fs.Length -le $Offset.Value) { return '' }
        [void]$fs.Seek($Offset.Value, 'Begin')
        $buf = New-Object byte[] ([int][Math]::Min(1048576, $fs.Length - $Offset.Value))
        $n = $fs.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return '' }
        # node writes UTF-8 on Windows. Everything this actually reads for a decision - a URL, an
        # exit message - is ASCII, where UTF-8 and the ANSI codepage agree, so a wrong guess here
        # can garble a decorative character but cannot change a verdict.
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $cut = $text.LastIndexOf([char]10)
        if ($cut -lt 0) {
            if (-not $Flush) { return '' }
            $cut = $text.Length - 1
        }
        $whole = $text.Substring(0, $cut + 1)
        $Offset.Value = $Offset.Value + [Text.Encoding]::UTF8.GetByteCount($whole)
        return $whole
    } catch { return '' } finally { if ($fs) { $fs.Dispose() } }
}

<#
    Start wrangler hidden and hand back something to watch it with. It NEVER waits.

    -Wait is precisely what froze the window before, so it is deliberately absent and the caller
    polls Update-WranglerWatched from a timer it already owns. Start-Process can only redirect to
    files, which is exactly what the drain above wants anyway.
#>
function Start-WranglerWatched {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$StdIn = '',
        [int]$TimeoutSec = 600,   # 10 minutes of wall clock
        [int]$StallSec   = 180    # 3 minutes with nothing at all to say
    )
    $w = Resolve-Wrangler
    $stamp = [Guid]::NewGuid().ToString('N')
    $watch = @{
        Command     = ($Arguments -join ' ')
        OutPath     = (Join-Path $env:TEMP "pc2go-wrangler-$stamp.out")
        ErrPath     = (Join-Path $env:TEMP "pc2go-wrangler-$stamp.err")
        InPath      = ''
        OutOffset   = [long]0
        ErrOffset   = [long]0
        Text        = ''
        Started     = (Get-Date)
        LastOutput  = (Get-Date)
        TimeoutSec  = $TimeoutSec
        StallSec    = $StallSec
        NeedsSignIn = $false
        SignInUrl   = ''
        Verdict     = 'running'
        ExitCode    = $null
        Proc        = $null
    }
    if ($StdIn) { $watch.InPath = New-SecretTempFile -Text $StdIn }
    $sp = @{ FilePath = $w.Exe; ArgumentList = (@($w.Pre) + @($Arguments))
             WorkingDirectory = $WorkingDirectory
             PassThru = $true; WindowStyle = 'Hidden'
             RedirectStandardOutput = $watch.OutPath
             RedirectStandardError  = $watch.ErrPath }
    if ($watch.InPath) { $sp['RedirectStandardInput'] = $watch.InPath }
    try {
        $watch.Proc = Start-Process @sp
        # Touched immediately, and this line is not optional. When Start-Process redirects and is
        # NOT given -Wait, PowerShell lets the process handle go, and ExitCode then reads back
        # EMPTY - no exception, just nothing - so a successful run would be judged a failure.
        # Reading .Handle here keeps the handle open, which is the only thing that makes ExitCode
        # answerable later. Measured on this machine: without it, every exit code is ''.
        [void]$watch.Proc.Handle
    } catch {
        Remove-SecretTempFile $watch.InPath
        throw
    }
    return $watch
}

# Everything wrangler has said, reduced to one line fit for a status bar. ANSI colour is stripped
# rather than trusted absent - wrangler suppresses it for a pipe, but anything that reopens a TTY
# in between would otherwise paint escape codes into a WPF TextBlock.
function Get-WatchedLine {
    param([Parameter(Mandatory = $true)]$Watch)
    $clean = [regex]::Replace([string]$Watch.Text, "\x1b\[[0-9;?]*[A-Za-z]", '')
    $lines = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $lines.Count) { return '' }
    return $lines[-1]
}

function Stop-WranglerWatched {
    param([Parameter(Mandatory = $true)]$Watch, [string]$Verdict = 'cancelled')
    if ($Watch.Verdict -ne 'running') { return }
    try { if (-not $Watch.Proc.HasExited) { Stop-ProcessTree $Watch.Proc.Id } } catch { }
    $Watch.Verdict = $Verdict
    Remove-SecretTempFile $Watch.InPath
    $Watch.InPath = ''
    # the stdout/stderr capture files too - only the natural-exit path removed them, so every
    # Stop, stall and timeout left a pair of pc2go-wrangler-*.out/.err behind in %TEMP%
    try { Remove-Item -LiteralPath $Watch.OutPath, $Watch.ErrPath -Force -ErrorAction SilentlyContinue } catch { }
    # the Process object is deliberately NOT disposed: callers (and the harness) still read
    # HasExited/ExitCode off it after a Stop, and a disposed handle answers those with a throw
}

<#
    One poll. Returns whatever new text appeared, and moves Verdict off 'running' when the run is
    over for any reason at all.

    Two give-up clocks, because they mean different things:
      * stalled - nothing said for StallSec while still running. Something is waiting on input
        that is never going to arrive.
      * timeout - the wall clock ran out. It may still be working, but not usefully.
    The sign-in case is caught by CONTENT first and much sooner, because wrangler announces it;
    the clocks are the backstop for a hang that says nothing at all.
#>
function Update-WranglerWatched {
    param([Parameter(Mandatory = $true)]$Watch)
    if ($Watch.Verdict -ne 'running') { return '' }

    $exited = $false
    try { $exited = $Watch.Proc.HasExited } catch { $exited = $true }

    $o = [long]$Watch.OutOffset
    $e = [long]$Watch.ErrOffset
    $new = (Read-WatchedFile -Path $Watch.OutPath -Offset ([ref]$o) -Flush:$exited) +
           (Read-WatchedFile -Path $Watch.ErrPath -Offset ([ref]$e) -Flush:$exited)
    $Watch.OutOffset = $o
    $Watch.ErrOffset = $e

    if ($new) {
        $Watch.Text = [string]$Watch.Text + $new
        $Watch.LastOutput = Get-Date
        # Recognised from what it prints, because that is the only signal left once the window is
        # gone. Checked once only: after the first hit the URL is already on screen, and matching
        # it again every poll would re-raise a prompt the operator is in the middle of answering.
        if (-not $Watch.NeedsSignIn) {
            $m = [regex]::Match($new, 'https?://[^\s"]*(?:dash\.cloudflare\.com/oauth2|localhost:8976)[^\s"]*')
            if (-not $m.Success) { $m = [regex]::Match($new, 'https?://dash\.cloudflare\.com/\S*') }
            if ($m.Success -or $new -match 'Ok to proceed|press any key|authorize') {
                $Watch.NeedsSignIn = $true
                $Watch.SignInUrl = $(if ($m.Success) { $m.Value } else { '' })
            }
        }
    }

    if ($exited) {
        $code = $null
        try { $code = $Watch.Proc.ExitCode } catch { $code = $null }
        # An empty exit code means the handle was lost, NOT that it succeeded. Anything that is
        # not a real 0 is treated as a failure, because reporting an unknown outcome as success
        # on the one call that changes the edge is the worst available way to be wrong.
        $Watch.ExitCode = $code
        $Watch.Verdict = $(if (($code -is [int]) -and ($code -eq 0)) { 'ok' } else { 'failed' })
        Remove-SecretTempFile $Watch.InPath
        $Watch.InPath = ''
        try { Remove-Item -LiteralPath $Watch.OutPath, $Watch.ErrPath -Force -ErrorAction SilentlyContinue } catch { }
        return $new
    }

    $now = Get-Date
    if (($now - $Watch.Started).TotalSeconds -ge $Watch.TimeoutSec) {
        Stop-WranglerWatched -Watch $Watch -Verdict 'timeout'
    } elseif (($now - $Watch.LastOutput).TotalSeconds -ge $Watch.StallSec) {
        Stop-WranglerWatched -Watch $Watch -Verdict 'stalled'
    }
    return $new
}
