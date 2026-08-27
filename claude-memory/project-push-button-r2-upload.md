---
name: project-push-button-r2-upload
description: "The Push button and the native PowerShell S3 uploader behind it - built 2026-08-19, what is proven and what is not"
metadata: 
  node_type: memory
  type: project
  originSessionId: 91706c3d-67f6-4913-8c25-f32c1137fde4
  modified: 2026-08-19T07:21:14.125Z
---

Built 2026-08-19. The catalog editor's **Push to R2...** button, and `tools/R2-Upload.ps1`, a
native SigV4 multipart S3 client in PowerShell 5.1. This closed the gap that left 16 of 17 apps
on `REPLACE_WITH_REAL_SHA256`: nothing had ever put the installers in the bucket, because
`wrangler r2 object put` is single-shot (~300 MiB) and rclone was never installed.

**Why native S3 and not rclone:** no new binary on the machine, and full control of resume,
retry and progress. `cloudflare/README.md`'s rclone section is replaced by the Push flow.

**Three decisions worth not re-deriving:**

1. **`UNSIGNED-PAYLOAD` for parts**, so a 64 MiB part streams off disk instead of being read
   twice. What replaces the signature covering the bytes is the **ETag check** - R2 returns the
   part's MD5, compared against one computed from the buffer on its way out. That check is
   load-bearing: if R2 ever stops returning MD5 as the part ETag, `-SignPayload` becomes the
   only safe mode. `Test-Push.ps1 -Live` is the only thing that settles it.
2. **The signing key is re-derived every request, never cached.** Caching breaks only when an
   upload crosses midnight UTC - which a 15 GB upload on a client link does routinely and no
   harness can reach. Designed away rather than tested for; reach for that pattern again.
3. **Sidecar `tools/.push-state.json`, not apps.json.** `Export-Catalog` strips `_localFile` on
   every save, so after one save Push could not find a byte. The sidecar also holds the
   multipart `uploadId` and part ETags, which is what makes a dropped 14 GB upload resume.

**Two real bugs found by building it:**

- `[Uri].AbsolutePath` returns the **already-escaped** path, so re-canonicalising it while
  signing double-escaped a space to `%2520`. AWS's published `get-vanilla` vector cannot catch
  this - its path is a bare `/`. It would have surfaced only as `SignatureDoesNotMatch` against
  real R2, on the first filename containing a space.
- A socket dropped mid-write surfaces as `IOException` at least as often as `WebException`.
  Catching only the latter let the commonest real failure escape the retry loop entirely.

**Testing:** `tools/Test-Push.ps1`, 125 assertions, seconds to run, against a fake S3 endpoint on
loopback that stores real parts and reassembles them. **Three mutants injected, all three
caught** (double-escape, ETag check removed, sidecar trusted over ListParts). Its server reads
request BODIES, which is new for this repo - a `StreamReader` buffers ahead and silently eats the
first kilobytes, so headers are read one byte at a time off the raw stream.

**NOT proven, and it matters:** `-Live` has only ever run its skip branch here, because no
credentials are saved on this machine. Nothing has confirmed R2 accepts UNSIGNED-PAYLOAD or that
its part ETag is the MD5. **Run `tools\Test-Push.ps1 -Live` once before the first real push.**
Also untested: anything past 2 GB, keep-alive, TLS, proxies.

**The sharpest hazard, unchanged by this work:** `Publish-Release.ps1` uploads the new
`AppDeploy.ps1` to R2 *before* it pins the hash and deploys. A failure in between leaves every
client refusing to start with "AppDeploy.ps1 failed integrity check" - which reads exactly like a
compromise. Push records the previously-live pin, retries `wrangler deploy` once, then says
precisely what broke and how to end it. It cannot close the window.

**Trap for the next person:** a harness that dot-sources the editor prefix has an empty
`$PSScriptRoot`, so the editor resolved its tools folder to the *current directory* and wrote its
sidecar into the repo root. `Test-CatalogEditorGui.ps1` now passes `-PushStatePath` and
`-R2CredentialPath` explicitly. Same reason `Show-AppDialog` must NOT call the sidecar functions:
two harnesses lift it standalone, so the main window persists through `Save-AppSources` instead.

Related: [[project-cloudflare-r2-hosting]], [[feedback-prove-it-with-tests]],
[[project-session-2026-08-18-state]]
