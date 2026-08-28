<#
.SYNOPSIS
    Enter, repair and verify the R2 key pair the editor uses to upload.

.DESCRIPTION
    The editor asks for these credentials once, on the first Push, and never again: it only shows
    that prompt when no credential is stored. So a key pair that saved but does not WORK - a
    secret clipped by one character on the way out of the dashboard, the commonest way this goes
    wrong - leaves no way back in except deleting the file, and knowing to.

    This is that way back in. It keeps whatever is already right (account id, bucket, endpoint),
    replaces what is not, checks the shape before saving, and then proves the credential by
    signing a real read-only request against the bucket.

    Nothing is echoed. The secret is read through a masked prompt and stored DPAPI-encrypted at
    CurrentUser scope, exactly as the editor stores it - readable only by this Windows account on
    this machine, which also means a reinstall destroys it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-R2Credential.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-R2Credential.ps1 -VerifyOnly
    Checks what is stored without changing it.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
. (Join-Path $here 'R2-Upload.ps1')

if (-not $Path) { $Path = Get-DefaultR2CredentialPath }

function Write-Head([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok  ([string]$Text) { Write-Host "  OK    $Text" -ForegroundColor Green }
function Write-Bad ([string]$Text) { Write-Host "  WRONG $Text" -ForegroundColor Red }
function Write-Note([string]$Text) { Write-Host "        $Text" -ForegroundColor DarkGray }

# An R2 access key id is 32 hex characters and its secret is 64. Checking that here is the whole
# point of this script: a 63-character secret signs every request incorrectly, and R2 answers
# SignatureDoesNotMatch - which reads like a permissions problem and is not one.
function Test-KeyShape([string]$Value, [int]$Expected, [string]$What) {
    if (-not $Value)                       { Write-Bad "$What is empty"; return $false }
    if ($Value -ne $Value.Trim())          { Write-Bad "$What has spaces around it"; return $false }
    if ($Value.Length -ne $Expected)       { Write-Bad "$What is $($Value.Length) characters, expected $Expected"; return $false }
    if ($Value -notmatch '^[0-9a-fA-F]+$') { Write-Bad "$What contains characters that are not hex"; return $false }
    Write-Ok "$What looks right ($Expected hex characters)"
    return $true
}

# Signs a real request. The shape checks catch a truncated paste; only R2 can say whether the
# secret is the RIGHT 64 characters.
function Test-Credential($Cred) {
    Write-Head 'Asking R2 whether these credentials sign correctly'
    try {
        $r = Invoke-R2Request -Credential $Cred -Method 'GET' -Key 'apps.json'
    } catch {
        Write-Bad "could not reach $($Cred.Endpoint)"
        Write-Note $_.Exception.Message
        return $false
    }
    if ($r.StatusCode -eq 200 -or $r.StatusCode -eq 404) {
        # 404 means the signature was accepted and the object simply is not there, which still
        # proves the credential.
        Write-Ok "signature accepted (HTTP $($r.StatusCode) from $($Cred.Bucket))"
        return $true
    }
    if ($r.StatusCode -eq 0) {
        # Invoke-R2Request does not throw on a transport fault - it answers StatusCode 0 with the
        # reason in Message. That used to print "R2 refused the request (HTTP 0)" and hide it.
        Write-Bad "could not reach $($Cred.Endpoint)"
        Write-Note $r.Message
        return $false
    }
    $body = ''
    if ($r.PSObject.Properties['Body'] -and $r.Body) {
        $body = if ($r.Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Body) } else { [string]$r.Body }
    }
    $code = ''
    if ($body -match '<Code>([^<]+)</Code>') { $code = $Matches[1] }
    Write-Bad "R2 refused the request (HTTP $($r.StatusCode)$(if ($code) { " - $code" }))"
    switch ($code) {
        'SignatureDoesNotMatch' { Write-Note 'The secret is wrong. Re-copy it from the dashboard, all 64 characters.' }
        'InvalidAccessKeyId'    { Write-Note 'The access key id is not one this account knows. Re-copy the pair.' }
        'AccessDenied'          { Write-Note "The key is valid but not allowed on '$($Cred.Bucket)'. It needs Object Read & Write on that bucket." }
        'NoSuchBucket'          { Write-Note "This account has no bucket called '$($Cred.Bucket)'." }
        default                 { if ($body) { Write-Note (($body -replace '\s+', ' ').Trim()) } }
    }
    return $false
}

Write-Host ''
Write-Host 'R2 credentials' -ForegroundColor White
Write-Host "  $Path" -ForegroundColor DarkGray

$existing = $null
if (Test-Path -LiteralPath $Path) {
    try { $existing = Get-R2Credential -Path $Path }
    catch {
        Write-Head 'A credential file is here but this account cannot read it'
        Write-Note $_.Exception.Message
        Write-Note 'DPAPI is per Windows account and per machine - a file copied from elsewhere,'
        Write-Note 'or left by a reinstall, cannot be decrypted. It will be replaced.'
    }
}

if ($existing) {
    Write-Head 'What is stored now'
    Write-Host  "  account   $($existing.AccountId)"
    Write-Host  "  bucket    $($existing.Bucket)"
    Write-Host  "  endpoint  $($existing.Endpoint)"
    $idOk  = Test-KeyShape $existing.AccessKeyId 32 'access key id'
    $secOk = Test-KeyShape $existing.Secret      64 'secret'
    if ($idOk -and $secOk) { [void](Test-Credential $existing) }
} else {
    Write-Head 'Nothing readable is stored yet'
}

if ($VerifyOnly) { Write-Host ''; return }

Write-Head 'Enter the key pair'
Write-Note 'Dashboard -> R2 -> Manage R2 API Tokens -> Create'
Write-Note 'Account API Token, Object Read & Write, scoped to the bucket below.'
Write-Note 'Press Enter on its own to keep what is already stored.'
Write-Host ''

$accountId = Read-Host "  account id     $(if ($existing) { "[$($existing.AccountId)]" })"
if (-not $accountId -and $existing) { $accountId = $existing.AccountId }
if (-not $accountId) { $accountId = Get-WranglerAccountId }
if (-not $accountId) { Write-Bad 'an account id is required'; return }

$bucketDefault = $(if ($existing) { $existing.Bucket } else { 'pc2go-apps' })
$bucket = Read-Host "  bucket         [$bucketDefault]"
if (-not $bucket) { $bucket = $bucketDefault }

$keyId = Read-Host "  access key id  $(if ($existing) { '[keep]' })"
if (-not $keyId -and $existing) { $keyId = $existing.AccessKeyId }

# Masked, and converted back only to hand to the encrypt call - never printed, never logged.
$secureSecret = Read-Host "  secret         $(if ($existing) { '[keep]' })" -AsSecureString
$secret = ''
if ($secureSecret.Length -gt 0) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    try { $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $secret -and $existing) { $secret = $existing.Secret }

$keyId  = ('' + $keyId).Trim()
$secret = ('' + $secret).Trim()

Write-Head 'Checking the shape before saving'
$ok = (Test-KeyShape $keyId 32 'access key id')
if (-not (Test-KeyShape $secret 64 'secret')) { $ok = $false }
if (-not $ok) {
    Write-Host ''
    Write-Bad 'Not saved - fix the above and run this again.'
    Write-Note 'A secret one character short is the usual cause, and it fails at push time with'
    Write-Note 'SignatureDoesNotMatch, which looks like a permissions problem and is not one.'
    return
}

# Proven BEFORE it is written, so a bad pair never replaces a good one.
$candidate = Get-R2CredentialObject -AccountId $accountId -AccessKeyId $keyId -Secret $secret -Bucket $bucket
if (-not (Test-Credential $candidate)) {
    Write-Host ''
    Write-Bad 'Not saved - R2 rejected these credentials.'
    if ($existing) { Write-Note 'Whatever was stored before is untouched.' }
    return
}

Save-R2Credential -AccountId $accountId -AccessKeyId $keyId -Secret $secret `
                  -Bucket $bucket -Endpoint $candidate.Endpoint -Path $Path
Write-Host ''
Write-Ok "saved and verified - $Path"
Write-Note 'Encrypted for this Windows account on this machine only.'
Write-Host ''
