# Cloudflare edge — deployment runbook

R2 for storage, a Worker in front of it. Replaces the "any static HTTPS host" section of
the root README with something specific enough to actually stand up.

**Why R2 and not S3/CloudFront:** you ship ~30 GB per client session. Egress is the entire
bill. R2 charges **$0.00/GB egress** at any volume; CloudFront starts at $0.085/GB and the
Middle East is a premium tier. At 100 sessions/month that is **$0 against roughly $300**.
Storage is $0.015/GB/month — 500 GB of installers is $7.50/month, and that is the whole
invoice.

**Why Cloudflare specifically for Kuwait:** there is a Cloudflare PoP in Kuwait City, plus
16 other Middle East locations. Their MENA buildout took regional latency from ~200 ms to
~10 ms in the UAE.

**One rule you must not break:** Cloudflare's CDN terms allow large non-HTML files *only
when the content is hosted on a Cloudflare service such as R2*. Putting the installers on
a cheap VPS behind Cloudflare's CDN is still a violation and will get you cut off
mid-deployment. On R2 you are explicitly in bounds.

---

## What the Worker does

| Path | Behaviour |
|---|---|
| `/go` | Serves `go.ps1` with `$BaseUrl` and `$PinnedHash` substituted at the edge |
| `/AppDeploy.ps1` | Serves the tool |
| `/apps.json` | Serves the catalog, **rewriting every `/files/` URL into a signed, expiring one** |
| `/files/*` | Installers. HMAC-gated, `Range` and `HEAD` supported |
| `/icons/*` | Logos. Public, cached a week |
| `/health` | Liveness string |

### The client needs no changes

`AppDeploy.ps1` reads `$item.Url` straight off the catalog and hands it to BITS, and it
derives the local filename with `([Uri]$a.url).LocalPath`, which ignores the query string.
So signing the URLs *inside the catalog response* flows through the existing client
untouched. No edit to the 7,635-line script, no new client-side token logic.

### Token lifetime is set by BITS, not by security taste

A suspended BITS job keeps the URL it was created with. If the signature expires before
the technician resumes, a half-finished 30 GB download dies. `TOKEN_TTL_SECONDS` defaults
to **48 hours** for that reason.

Consequence to know about: the offline catalog cache (`$script:ManifestCache`) holds
tokens that eventually expire. A technician working from a cached catalog more than 48 h
old gets a 403 and re-runs the tool to refresh. That is the intended degradation, and it
is why the Worker returns `403 token expired` rather than a bare 404 — the distinction is
visible in the BITS error surfaced in the app's log.

---

## First-time setup

```powershell
npm install -g wrangler
wrangler login
```

### 1. Enable R2, then create the bucket

R2 is off by default on a new account. Enable it once in the dashboard:
**R2 Object Storage → Enable R2**. It asks for a payment method even though the free tier
(10 GB storage, zero egress) covers a small catalog. Skipping this produces a `403` with
error `10042` on the first upload, which reads like a broken script rather than a missing
account setting.

R2 has **no Middle East location**. For Kuwait clients, `eeur` and `weur` both ride
Cloudflare's backbone into the Kuwait City PoP. Measure before committing:

```powershell
wrangler r2 bucket create pc2go-apps --location eeur
wrangler r2 bucket list                      # confirm it is there
```

### 2. Set the signing secret

```powershell
# Generate a strong key and set it. Never commit this.
$key = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
$key | wrangler secret put SIGNING_KEY
```

Rotating this key invalidates every outstanding download token immediately — which is
exactly what you want if a catalog response ever leaks.

### 3. Bind a custom domain

Dashboard: **Workers & Pages → pc2go-edge → Settings → Domains & Routes → Add custom
domain**, e.g. `apps.pc2go.ca`.

Use a custom domain rather than the `*.workers.dev` hostname. `workers.dev` is widely
blocked by corporate filters, and you are running this on locked-down client networks.

### 4. Publish

```powershell
.\tools\Publish-Release.ps1
```

That validates the catalog, uploads the three small files, writes the SHA-256 of
`AppDeploy.ps1` into `wrangler.toml`, deploys, then fetches `/go` back and confirms the
live pin matches what it just built.

---

## Uploading installers

**`wrangler r2 object put` is a single-shot upload and will not carry a multi-GB
installer.** Use rclone, which does multipart.

Create an R2 API token (dashboard → R2 → Manage R2 API Tokens), then:

```ini
# %USERPROFILE%\.config\rclone\rclone.conf
[r2]
type = s3
provider = Cloudflare
access_key_id = <access key id>
secret_access_key = <secret access key>
endpoint = https://<account-id>.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
```

```powershell
# Mirror a local installer folder into /files/
rclone copy "D:\Installers" r2:pc2go-apps/files --progress --transfers 4 --s3-chunk-size 64M

# Icons
rclone copy ".\icons" r2:pc2go-apps/icons --progress
```

After uploading, regenerate the catalog hashes with `tools\New-AppEntry.ps1` — a wrong
`sha256` means the file is downloaded in full and then refused by the elevated worker,
which is the most expensive possible way to fail.

---

## Known trade-off: gated files are not edge-cached

Signed URLs carry a unique query string per session, and Workers' Cache API will not hold
multi-GB objects anyway. So every byte of `/files/*` comes from R2 origin rather than a
Kuwait City edge cache.

This costs **nothing in money** — R2 egress is $0 cached or not — but a second technician
pulling the same installer does not get an edge-warm copy.

If you decide the exposure is acceptable and want edge caching, set `GATE_FILES = "false"`
and put the bucket on a public custom domain. Weigh that honestly: the payload is licensed
Autodesk and Adobe software, and an open bucket URL is both a cost and a legal problem.
The default is gated.

---

## Verifying it works

```powershell
$base = 'https://apps.pc2go.ca'

# 1. Health
irm "$base/health"

# 2. The pin is injected
(irm "$base/go") -split "`n" | Select-String 'BaseUrl|PinnedHash'

# 3. The catalog is signed
((irm "$base/apps.json").apps)[0].url        # should end in ?exp=...&sig=...

# 4. An unsigned file request is refused
try { iwr "$base/files/Office365/setup.exe" -UseBasicParsing } catch { $_.Exception.Response.StatusCode }
#    expect: Forbidden

# 5. Range works — this is what BITS resume depends on
$u = ((irm "$base/apps.json").apps)[0].url
(iwr $u -Headers @{ Range = 'bytes=0-1023' } -UseBasicParsing).StatusCode
#    expect: 206
```

Step 5 is the one worth running after every change to the Worker. If it returns 200
instead of 206, resume is silently broken and a dropped connection restarts a 30 GB
download from zero.
