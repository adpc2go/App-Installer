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
    a single-shot upload and will not carry a 30 GB Autodesk package. Use the catalog
    editor's "Push to R2..." button, which uploads them over the S3 API with resumable
    multipart transfers and then runs this script. See cloudflare\README.md.

.PARAMETER Environment
    wrangler environment to deploy. Omit for the default.

.PARAMETER SkipDeploy
    Upload to R2 and update the pin, but do not run 'wrangler deploy'.

.PARAMETER ValidateOnly
    Run the catalog validation and stop. Nothing is uploaded, pinned or deployed.

    This exists for Push: it has to run the REAL validation before spending four hours
    uploading 63 GB, and the only way to reach that logic used to be to run the whole
    publish. Duplicating the rules in the editor would mean two of them, drifting apart.

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
    [switch]$ValidateOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Every failure in here is a throw, and what exit code a throw produces depends on how the
# script was invoked. Push runs this as a child process and reads the exit code to decide
# whether the catalog is live, so the contract is made explicit instead of inherited.
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

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

# Resolve-Wrangler lives in R2-Upload.ps1 so this script and the Management Console share ONE
# answer about where wrangler is. They did not: the console hardcoded `npx wrangler`, so a
# machine with a global wrangler and no npx published from here perfectly well and failed to set
# the access code there. Dot-sourced by path, the same way the console does it.
# Loaded if it is there, and NOT required to be. Validation deliberately works without any
# deploy toolchain at all (see the note above step 1), and refusing to start without this file
# would break that promise for the one mode that exists to be cheap to run.
$r2Module = Join-Path $PSScriptRoot 'R2-Upload.ps1'
if (Test-Path -LiteralPath $r2Module) { . $r2Module }

function Invoke-Wrangler {
    param([string[]]$Arguments)
    # Named here rather than at load time, so the failure lands at the moment it actually
    # matters - deploying - instead of stopping a validation run that never needed it.
    if (-not (Get-Command Resolve-Wrangler -ErrorAction SilentlyContinue)) {
        throw ("R2-Upload.ps1 is missing from $PSScriptRoot. It holds the wrangler lookup this " +
               'needs to deploy; -ValidateOnly still works without it.')
    }
    $w = Resolve-Wrangler
    $all = @($w.Pre) + @($Arguments)
    & $w.Exe @all
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

$problems  = New-Object System.Collections.Generic.List[string]
$notServed = New-Object System.Collections.Generic.List[string]
# Worth a person's attention, but never a reason to refuse a publish - the difference between
# "this will not work" and "this is not finished yet".
$softWarn  = New-Object System.Collections.Generic.List[string]
# The apps that pass the hash test, kept so they can be compared against EACH OTHER afterwards.
# Every other rule here judges one app on its own; being the same application twice is the one
# thing no single entry can tell you about itself.
$servedApps = New-Object System.Collections.Generic.List[object]

foreach ($app in @($catalog.apps)) {
    $sha = '' + $app.sha256
    # An app without a real hash is no longer an error. The Worker drops it from the catalog it
    # serves, so no client ever sees it - and it could never have installed anyway, because
    # AppDeploy.ps1 downloads the whole file and only THEN verifies the hash. Publishing one
    # would cost a technician a multi-GB download before telling them it was corrupt.
    #
    # This is what lets a half-finished catalog be published at all, which it must be: the
    # installers go up a few at a time over weeks, and the ones already done should not have to
    # wait for the rest.
    # An uninstall-only entry carries removal knowledge for a product we never install, so it
    # HAS no installer, no url and no hash - and worker.js serves it anyway, by the same
    # explicit exception. Judging it by the installer rules listed it as dropped when it is in
    # fact live: a pre-publish report telling the operator the opposite of the truth. Nothing
    # below applies to it either - there is no switch and no package to check.
    if ($app.uninstallOnly) {
        # NOT added to $servedApps, deliberately. That list feeds the duplicate checks, which
        # group by sha256 and by url - and these entries have neither, so two of them would
        # group together as "the same installer under two ids" and REFUSE the publish. They
        # still count as served: $serving is derived from $notServed, which they are not in.
        foreach ($rm in @($app.cleanup.removers)) {
            if ($rm -and $rm.url -and (('' + $rm.sha256) -match 'REPLACE|PLACEHOLDER' -or ('' + $rm.sha256).Length -ne 64)) {
                # Not a blocker: the entry's uninstall knowledge is useful with or without it.
                # But the client OFFERS this remover and the worker then refuses it on the hash
                # gate - after the technician has approved the removal - so say it here, where
                # it can still be fixed, rather than letting it surface on somebody's machine.
                $softWarn.Add("$($app.id): remover '$($rm.name)' has no real hash yet - it is offered on the client and then refused")
            }
        }
        continue
    }
    if (-not $sha -or $sha -match 'REPLACE|PLACEHOLDER' -or $sha.Length -ne 64) {
        $notServed.Add("$($app.id): no real hash yet")
        continue
    }
    $servedApps.Add($app)
    # Everything below is checked only for apps that WILL be served. Validating what actually
    # ships is the point; complaining about a row nobody can see is noise.
    #
    # Mirrors open item #1 in README.md. A wrong silent switch does not error - the
    # installer opens its GUI and the batch hangs on the client's machine.
    # The VERIFY gate is gone. It blocked publishing on a marker that meant "nobody has
    # confirmed this switch", and confirming one needs a VM and a real install - so in
    # practice it blocked the catalog rather than improving it. A wrong switch is still
    # caught, just later and by the thing that can actually tell: the installer guard on the
    # client stops a window that opens and names the switch as the likely cause.
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
        # A destination with a second root inside it - %ProgramFiles%\C:\Program Files\... -
        # expands to a directory that cannot exist, and the copy then fails on the client at the
        # end of a long install. The editor repairs this as it is typed now; this catches the
        # ones already written down.
        if (('' + $step.dest) -match '.(?:[A-Za-z]:\\|\\\\)') {
            $problems.Add("$($app.id): postInstall step '$($step.name)' has a path inside a path - '$($step.dest)'")
        }
    }
}

# ---------------------------------------------------------------- the same application twice
#
# "Add folder" builds an entry out of a FILENAME, so pointing it at a directory that already has
# an app in the catalog quietly produces a second entry for it. That is where `officesetup`
# came from, sitting beside `office365` carrying the very same bytes: the client is offered the
# same product twice with no way to tell which is which, and Push uploads those bytes twice, to
# two different keys, and the bucket is billed for both.
#
# A genuinely different VERSION of one product is not a duplicate - two releases side by side is
# what the version field is FOR - so a differing version clears the name rule. It does not clear
# the sha256 rule, and cannot: one file cannot be two versions of anything.
#
# Only apps that will actually be served are compared. A row the edge drops is not shipped, is
# not uploaded, and complaining about it would be the noise this file already refuses to make.

# names come from filenames, so compare them the way a person reads them: case, spaces and
# punctuation are not what makes two entries different products
function Get-NameKey($app)    { return ((('' + $app.name).ToLower()) -replace '[^a-z0-9]', '') }
function Get-VersionKey($app) { return ((('' + $app.version).ToLower()) -replace '\s+', '') }
function Get-IdList($group)   { return (@($group | ForEach-Object { '' + $_.id } | Sort-Object) -join ', ') }

# One report per set of entries, whichever rule catches it first. Reporting the Office pair
# three times over would bury the fifteen other lines this validation prints.
$reported = New-Object System.Collections.Generic.List[string]
function Test-AlreadyReported([string]$Ids) {
    if ($reported.Contains($Ids)) { return $true }
    $reported.Add($Ids)
    return $false
}

foreach ($g in @($servedApps | Group-Object { ('' + $_.sha256).ToUpper() } | Where-Object { $_.Count -gt 1 })) {
    $ids = Get-IdList $g.Group
    if (Test-AlreadyReported $ids) { continue }
    $problems.Add("$ids - the same installer under $($g.Count) ids: identical sha256 $($g.Name.Substring(0, 12))..., so these are one application, not two")
}
foreach ($g in @($servedApps | Group-Object { (Get-NameKey $_) + '@' + (Get-VersionKey $_) } | Where-Object { $_.Count -gt 1 })) {
    $ids = Get-IdList $g.Group
    if (Test-AlreadyReported $ids) { continue }
    $ver  = ('' + @($g.Group)[0].version)
    $said = $(if ($ver) { "both at version '$ver'" } else { 'and neither gives a version' })
    $problems.Add("$ids - the same name '$(@($g.Group)[0].name)' $said. Give one of them its real version, or remove it")
}
foreach ($g in @($servedApps | Group-Object { ('' + $_.url).ToLower() } | Where-Object { $_.Count -gt 1 })) {
    $ids = Get-IdList $g.Group
    if (Test-AlreadyReported $ids) { continue }
    $problems.Add("$ids - both download from $(@($g.Group)[0].url). One key in the bucket cannot hold two applications")
}

$serving = @($catalog.apps).Count - $notServed.Count

if ($notServed.Count -gt 0) {
    Write-Warn "$($notServed.Count) app(s) will NOT be served yet - the edge drops them from the catalog:"
    foreach ($p in $notServed) { Write-Host "      - $p" -ForegroundColor DarkGray }
    Write-Host ''
}

if ($softWarn.Count -gt 0) {
    Write-Warn "$($softWarn.Count) thing(s) worth fixing, but not a reason to hold the publish:"
    foreach ($w in $softWarn) { Write-Host "      - $w" -ForegroundColor DarkGray }
    Write-Host ''
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($problems.Count) issue(s) in apps that WOULD be served:"
    foreach ($p in $problems) { Write-Host "      - $p" -ForegroundColor Yellow }
    Write-Host ''
    if (-not $Force) {
        throw 'Refusing to publish. Fix these, or re-run with -Force if this is a staging push.'
    }
    Write-Warn 'Publishing anyway (-Force).'
} elseif ($serving -le 0) {
    # Every entry filtered out means the client gets a catalog with an empty apps array, which
    # AppDeploy treats as a failed load - a red badge on a machine that is working correctly.
    # Better to say so here than to ship it.
    throw ("None of the $(@($catalog.apps).Count) apps has a real hash yet, so the served catalog " +
           'would be empty and every client would report a catalog failure. Push at least one ' +
           'installer to R2 first.')
} else {
    Write-Ok "$serving of $(@($catalog.apps).Count) app(s) ready to serve, no unverified switches"
}

# Push calls this before it uploads a single byte. Discovering a VERIFY marker or a missing
# step hash AFTER a four-hour upload is a bad day, and this is the only copy of those rules.
if ($ValidateOnly) {
    Write-Ok 'Validation only - nothing uploaded, pinned or deployed.'
    exit 0
}

# ------------------------------------------------------------------- 2. hash

Write-Step 'Preparing AppDeploy.ps1 for shipping'

# Antivirus scans script CONTENT, so the cost of launching the tool tracks its byte count. On a
# client running McAfee alongside Defender that was measured at EIGHT SECONDS per load; on a
# Defender-only machine, 18 ms. Comments and indentation are a quarter of the file and no
# machine needs them in order to run it, so they come off here - on the way to the bucket, never
# from the source, which keeps every comment for the next person reading the repository.
#
# Line numbers are preserved, so a stack trace from a client still points at the right line of
# the file you have open.
$shipDir = Join-Path ([IO.Path]::GetTempPath()) ('pc2go-ship-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $shipDir | Out-Null
$shipDeploy = Join-Path $shipDir 'AppDeploy.ps1'

$compressor = Join-Path $PSScriptRoot 'Compress-Script.ps1'
if (Test-Path -LiteralPath $compressor) {
    . $compressor
    $rawSrc  = Get-Content -LiteralPath $appDeploy -Raw
    $shipped = ConvertTo-ShippableScript -Source $rawSrc
    # The stripped file is what runs elevated on somebody else's machine. "It still parses" is
    # not good enough: every token must be identical to the source, or it does not ship.
    if (-not (Test-ScriptTokensMatch -Original $rawSrc -Stripped $shipped)) {
        throw 'Stripping AppDeploy.ps1 changed its code, not just its comments. Refusing to publish.'
    }
    [IO.File]::WriteAllText($shipDeploy, $shipped, (New-Object Text.UTF8Encoding $false))
    $saved = [math]::Round((1 - ($shipped.Length / [double]$rawSrc.Length)) * 100, 1)
    Write-Ok ("{0:N0} KB -> {1:N0} KB  ({2}% smaller, identical tokens)" -f ($rawSrc.Length / 1KB), ($shipped.Length / 1KB), $saved)
} else {
    Copy-Item -LiteralPath $appDeploy -Destination $shipDeploy -Force
    Write-Warn 'Compress-Script.ps1 not found - shipping the source as-is.'
}

Write-Step 'Hashing AppDeploy.ps1'

# The hash MUST be of the bytes that ship, not of the source - otherwise go.ps1 refuses to run
# the tool it just downloaded and every client reports a failed integrity check.
$hash   = (Get-FileHash -LiteralPath $shipDeploy -Algorithm SHA256).Hash.ToUpper()
$sizeKb = [math]::Round((Get-Item -LiteralPath $shipDeploy).Length / 1KB, 1)
Write-Ok "$hash  ($sizeKb KB)"

# ------------------------------------------------------------------ 3. upload

# Resolve-Wrangler accepts npx as well as a global install, so this is a check that wrangler is
# REACHABLE rather than that it is on PATH. The old test rejected a machine whose only route to
# wrangler was npx - which is the machine the OAuth login here was made on.
$null = Resolve-Wrangler

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
$w = Resolve-Wrangler
$listArgs = @($w.Pre) + @('r2', 'bucket', 'list')
$bucketList = (& $w.Exe @listArgs 2>&1 | Out-String)
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
    @{ Local = $shipDeploy; Key = 'AppDeploy.ps1'; Type = 'text/plain' },
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
    exit 0
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
    $ws = Resolve-Wrangler
    $statArgs = @($ws.Pre) + @('deployments', 'status')
    $status = & $ws.Exe @statArgs 2>$null
    $m = [regex]::Match(('' + $status), 'https://[^\s]+')
    if ($m.Success) { $baseUrl = $m.Value.TrimEnd('/') }
} catch { }

if (-not $baseUrl) {
    Write-Warn 'Could not determine the deployed URL automatically.'
    Write-Warn 'Verify by hand:  (irm https://YOUR-DOMAIN/go) -match "PinnedHash"'
    Write-Host ''
    Write-Host "Expected pin: $hash" -ForegroundColor White
    # The deploy itself succeeded; only the read-back could not be addressed. That is a warning,
    # not a failure, and Push must not report it as one.
    exit 0
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
Write-Host 'Installers under /files/ go up from the catalog editor: "Push to R2..."' -ForegroundColor DarkGray

exit 0
