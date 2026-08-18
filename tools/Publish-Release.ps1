<#
.SYNOPSIS
    Publishes go.ps1, AppDeploy.ps1 and apps.json to R2 and deploys the Worker.

.DESCRIPTION
    Automates the release procedure from README.md "Server setup": upload the tool,
    hash it, pin the hash, re-upload the bootstrap.

    Doing it by hand is how a stale pin ships. A stale pin does not fail loudly - it
    fails on a client machine, mid-session, with "AppDeploy.ps1 failed integrity check",
    which reads exactly like a compromise. So the hash is computed and written here,
    then verified against the live endpoint afterwards.

    Installers under /files/ are NOT uploaded by this script. wrangler's object put is
    a single-shot upload and will not carry a 30 GB Autodesk package; use rclone against
    the S3-compatible endpoint for those. See cloudflare\README.md.

.PARAMETER Environment
    wrangler environment to deploy. Omit for the default.

.PARAMETER SkipDeploy
    Upload to R2 and update the pin, but do not run 'wrangler deploy'.

.PARAMETER Force
    Publish even when the catalog still contains placeholder hashes or unverified
    silent-install switches.

.EXAMPLE
    .\tools\Publish-Release.ps1
    Validate, upload, pin, deploy, verify.

.EXAMPLE
    .\tools\Publish-Release.ps1 -SkipDeploy
    Stage the files without pushing a new Worker version.
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$RepoRoot,
    [switch]$SkipDeploy,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# $RepoRoot exists so this can be pointed at a staging copy - or at a fixture - instead of only
# ever validating the repo it happens to sit in. Without it, the validation logic could not be
# tested against anything but the real catalog.
$root         = $(if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent $PSScriptRoot })
$serverDir    = Join-Path $root 'server'
$cfDir        = Join-Path $root 'cloudflare'
$wranglerToml = Join-Path $cfDir 'wrangler.toml'

$appDeploy = Join-Path $serverDir 'AppDeploy.ps1'
$goPs1     = Join-Path $serverDir 'go.ps1'
$appsJson  = Join-Path $serverDir 'apps.json'

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }

foreach ($f in @($appDeploy, $goPs1, $appsJson, $wranglerToml)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f" }
}

function Invoke-Wrangler {
    param([string[]]$Arguments)
    & wrangler @Arguments
    if ($LASTEXITCODE -ne 0) { throw "wrangler $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# ---------------------------------------------------------------- 1. validate
#
# Validation runs before the wrangler check on purpose: linting the catalog is useful on
# its own, and demanding a deploy toolchain to find out that a sha256 is still a
# placeholder would just discourage running it.

Write-Step 'Validating catalog'

$catalogRaw = Get-Content -LiteralPath $appsJson -Raw
try { $catalog = $catalogRaw | ConvertFrom-Json }
catch { throw "apps.json is not valid JSON: $($_.Exception.Message)" }

$problems = New-Object System.Collections.Generic.List[string]

foreach ($app in @($catalog.apps)) {
    $sha = '' + $app.sha256
    if (-not $sha -or $sha -match 'REPLACE|PLACEHOLDER' -or $sha.Length -ne 64) {
        $problems.Add("$($app.id): sha256 is not a real hash ('$sha')")
    }
    # Mirrors open item #1 in README.md. A wrong silent switch does not error - the
    # installer opens its GUI and the batch hangs on the client's machine.
    if (('' + $app._installNote) -match 'VERIFY') {
        $problems.Add("$($app.id): silent-install switches still marked VERIFY")
    }
    foreach ($step in @($app.postInstall)) {
        # The tool refuses these at runtime too, but catching it here means an unpinned
        # elevated payload never reaches a client in the first place.
        # `from` names a file INSIDE the package, and the package's own sha256 is verified
        # before a single byte of it is unpacked - so those bytes are already pinned, and a
        # second hash would be pinning them to themselves. The worker draws exactly this
        # distinction; without it here, every app the after-install list produces would be
        # refused at publish time.
        if ($step.type -eq 'run' -and -not $step.sha256 -and -not $step.from) {
            $problems.Add("$($app.id): postInstall 'run' step '$($step.name)' has no sha256")
        }
    }
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($problems.Count) catalog issue(s):"
    foreach ($p in $problems) { Write-Host "      - $p" -ForegroundColor Yellow }
    Write-Host ''
    if (-not $Force) {
        throw 'Refusing to publish. Fix these, or re-run with -Force if this is a staging push.'
    }
    Write-Warn 'Publishing anyway (-Force).'
} else {
    Write-Ok "$(@($catalog.apps).Count) apps, no placeholder hashes, no unverified switches"
}

# ------------------------------------------------------------------- 2. hash

Write-Step 'Hashing AppDeploy.ps1'

$hash   = (Get-FileHash -LiteralPath $appDeploy -Algorithm SHA256).Hash.ToUpper()
$sizeKb = [math]::Round((Get-Item -LiteralPath $appDeploy).Length / 1KB, 1)
Write-Ok "$hash  ($sizeKb KB)"

# ------------------------------------------------------------------ 3. upload

if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
    throw "wrangler not found on PATH. Install it with: npm install -g wrangler"
}

$tomlRaw = Get-Content -LiteralPath $wranglerToml -Raw
$bucket  = ([regex]::Match($tomlRaw, 'bucket_name\s*=\s*"([^"]+)"')).Groups[1].Value
if (-not $bucket) { throw "Could not read bucket_name from $wranglerToml" }

# Preflight. Both of these fail deep inside an object-put with a raw API error that reads
# like a bug in this script, so check them up front and say what to actually do.
Write-Step 'Checking R2'

# Capture with ErrorActionPreference relaxed. Redirecting a native command's stderr in
# PowerShell 5.1 wraps each line in a NativeCommandError, which under 'Stop' terminates
# the script before the diagnosis below can run - the caller then sees wrangler's raw API
# error instead of the actionable message.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$bucketList = (& wrangler r2 bucket list 2>&1 | Out-String)
$listExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($bucketList -match '10042' -or $bucketList -match 'enable R2') {
    throw @"
R2 is not enabled on this Cloudflare account.

Enable it once at https://dash.cloudflare.com -> R2 Object Storage -> Enable R2.
It asks for a payment method even though the free tier (10 GB storage, zero egress)
covers a small catalog. Then re-run this script.
"@
}
if ($listExit -ne 0) {
    throw "Could not list R2 buckets. Are you logged in? Try: wrangler login`n$bucketList"
}

if ($bucketList -notmatch [regex]::Escape($bucket)) {
    throw @"
Bucket '$bucket' does not exist.

Create it, choosing a location close to your clients. R2 has no Middle East region;
for Kuwait, eeur and weur both ride Cloudflare's backbone into the Kuwait City PoP:

    wrangler r2 bucket create $bucket --location eeur
"@
}
Write-Ok "R2 enabled, bucket '$bucket' exists"

Write-Step 'Uploading to R2'

$uploads = @(
    @{ Local = $goPs1;     Key = 'go.ps1';        Type = 'text/plain' },
    @{ Local = $appDeploy; Key = 'AppDeploy.ps1'; Type = 'text/plain' },
    @{ Local = $appsJson;  Key = 'apps.json';     Type = 'application/json' }
)

foreach ($u in $uploads) {
    Invoke-Wrangler -Arguments @(
        'r2', 'object', 'put', "$bucket/$($u.Key)",
        '--file', $u.Local, '--content-type', $u.Type, '--remote'
    )
    Write-Ok $u.Key
}

# --------------------------------------------------------------------- 4. pin

Write-Step 'Pinning hash in wrangler.toml'

$updated = [regex]::Replace($tomlRaw, '(?m)^(APPDEPLOY_SHA256\s*=\s*)"[^"]*"', "`${1}`"$hash`"")
if ($updated -eq $tomlRaw -and $tomlRaw -notmatch [regex]::Escape($hash)) {
    throw "Could not find an APPDEPLOY_SHA256 line to update in $wranglerToml"
}

Set-Content -LiteralPath $wranglerToml -Value $updated -Encoding UTF8 -NoNewline
Write-Ok 'wrangler.toml updated'

# ------------------------------------------------------------------ 5. deploy

if ($SkipDeploy) {
    Write-Warn 'Skipping deploy (-SkipDeploy). The live Worker still serves the OLD pin.'
    return
}

Write-Step 'Deploying Worker'

Push-Location $cfDir
try {
    $deployArgs = @('deploy')
    if ($Environment) { $deployArgs += @('--env', $Environment) }
    Invoke-Wrangler -Arguments $deployArgs
} finally {
    Pop-Location
}

# ------------------------------------------------------------------ 6. verify
#
# The pin is the one thing that fails silently at publish time and loudly on a client
# machine, so confirm the live endpoint actually serves what we just built.

Write-Step 'Verifying live endpoint'

$baseUrl = $null
try {
    $status = & wrangler deployments status 2>$null
    $m = [regex]::Match(('' + $status), 'https://[^\s]+')
    if ($m.Success) { $baseUrl = $m.Value.TrimEnd('/') }
} catch { }

if (-not $baseUrl) {
    Write-Warn 'Could not determine the deployed URL automatically.'
    Write-Warn 'Verify by hand:  (irm https://YOUR-DOMAIN/go) -match "PinnedHash"'
    Write-Host ''
    Write-Host "Expected pin: $hash" -ForegroundColor White
    return
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $served = Invoke-WebRequest -Uri "$baseUrl/go" -UseBasicParsing -TimeoutSec 30

    $servedPin  = ([regex]::Match($served.Content, "\`$PinnedHash\s*=\s*'([^']*)'")).Groups[1].Value
    $servedBase = ([regex]::Match($served.Content, "\`$BaseUrl\s*=\s*'([^']*)'")).Groups[1].Value

    if ($servedPin -eq $hash) {
        Write-Ok 'Live /go serves the correct pin'
        Write-Ok "Live /go points at $servedBase"
    } else {
        Write-Warn "Live /go serves pin '$servedPin' but this release is '$hash'."
        Write-Warn 'The Worker may still be propagating - re-check in a minute.'
    }
} catch {
    Write-Warn "Could not fetch $baseUrl/go : $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Technician line:' -ForegroundColor Cyan
Write-Host "  powershell -NoP -EP Bypass -C `"irm $baseUrl/go | iex`"" -ForegroundColor White
Write-Host ''
Write-Host 'Installers under /files/ upload separately with rclone - see cloudflare\README.md.' -ForegroundColor DarkGray
