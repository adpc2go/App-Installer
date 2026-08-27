---
name: project-session-2026-08-22-state
description: what shipped on 2026-08-22 (batch strip, countdown, office365 parked) and the fact the PC was formatted right after
metadata:
  type: project
---

Second working session of 2026-08-22, ending with the PC being formatted.

**Shipped, all uncommitted at the time:** the batch strip in `server/AppDeploy.ps1` - a collapsible
progress panel below the catalog, per-row status and remove, failures sorted to the top, folding to
a one-line header that still carries the counts. Plus `skip.txt` for per-app removal, a two-stage
`Removing` -> `Removed` confirmation, `Format-Eta` time-remaining on downloads, and `office365`
parked. Tests: `Test-GuiBatch` 33 -> 65, `Test-DownloadResilience` 28 -> 35.

**Why:** this is the state the next session inherits. `HANDOVER.md` in the repo carries the full
detail and the reasoning - read it before touching the strip, because the pinning-vs-filtering and
the dismiss-vs-collapse arguments are both settled in there, and both were re-derived the hard way.

**How to apply:** ask first whether the format actually preserved anything - see
[[project-no-git-remote]]. If the repo came back with fewer than 19 catalog apps or fewer than nine
harnesses in `tests/`, something was lost. The R2 credentials at
`%LOCALAPPDATA%\PC2Go\r2-credentials.xml` are DPAPI-bound to the old Windows account and are gone
for certain; they must be re-entered from the Cloudflare dashboard.

Related: [[project-office365-parked]], [[feedback-confirm-every-action]],
[[project-sidecar-outranks-catalog]], [[project-launch-speed-antivirus]].
