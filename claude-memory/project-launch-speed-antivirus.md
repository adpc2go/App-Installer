---
name: project-launch-speed-antivirus
description: "Why the tool is slow to appear on some client PCs - measured 2026-08-20/21, it is antivirus scanning script SIZE, not the code"
metadata: 
  node_type: memory
  type: project
  originSessionId: 91706c3d-67f6-4913-8c25-f32c1137fde4
  modified: 2026-08-21T02:37:38.488Z
---

Measured 2026-08-20/21 after the user said the app took too long to appear. **The cause is
antivirus scanning script CONTENT on every execution, so the cost tracks BYTE COUNT.** Nothing
in the code was slow.

**The numbers that settled it** (benchmark script pasted back by the user):

| | PC1 Xeon E5-2650v4, **Defender + McAfee** | PC2 i9-13900KF, **Defender only** |
|---|---|---|
| powershell start, 1 KB script | 904 ms | 101 ms |
| **cost of a 480 KB script** | **7,066 ms** | **18 ms** |
| UAC round trip | 1,516 ms | 240 ms |
| WMI `Win32_OperatingSystem` | 1,190 ms | 380 ms |

PC1 is only ~9x slower generally but pays **393x** more for script size. That is McAfee layered
on Defender, not an old CPU. **On a Defender-only machine script size is free** - so none of the
size work below is worth anything there.

**Measured end to end on PC1 afterwards: 11.5 s** from Enter to window. ~8.1 s of that is before
the script runs at all (process start + AV scan of 412 KB + UAC + the human click); 3.4 s inside.

**Shipped fixes, in order of what they were worth:**
1. `go.ps1` decides elevation itself (`Get-LocalGroupMember`) and launches the elevated copy
   directly. The unelevated pass used to load all 480 KB purely to answer "should I elevate?"
   then exit - a whole AV scan for nothing. AppDeploy keeps `Test-IsAdminMember` as the
   authority, so an uncertain fast path falls through and is never WRONG, only no faster.
2. `tools/Compress-Script.ps1` strips comments and indentation at publish time (491 -> 402 KB).
   The source keeps its comments; only the shipped bytes shrink. Line numbers preserved.
3. `Get-SessionHeader` reads the registry instead of WMI (~1 s on PC1), and the session header
   plus `Load-Prefs` moved into `ContentRendered`, so nothing that reads machine state blocks the
   window. `Load-Catalog` was already deferred that way.

**Two bugs the token-equivalence check caught in the stripper** - both would have shipped:
- a here-string is `HereStringLiteral`, **not** `StringLiteral`. Protecting the wrong kind meant
  it silently re-indented the XAML and all ~130 KB of the elevated worker - **and it still
  parsed**. Match on the kind NAME containing "String".
- `#requires -Version 5.1` tokenises as a **Comment**; blanking it dropped the PowerShell 5.1
  requirement from the shipped file.
Never assert only "it still parses" for a generated script - compare token streams, collapsing
runs of NewLine, because a `<# #>` block is one token that swallows its own newlines.

**The biggest remaining lever is NOT code.** An AV exclusion on `%LOCALAPPDATA%\PC2GoDeploy`
removes ~6.7 s at once, more than every remaining refactor combined. PC1 pays twice because two
resident scanners inspect the same file. To split the blame:
`Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\PC2GoDeploy"` then re-measure - if it barely
moves, McAfee is the one charging and needs its own exclusion.

**NOT DONE, worth ~2 s, and only if exclusions are refused:** moving the ~130 KB `$workerScript`
here-string out of `AppDeploy.ps1` into a separately downloaded, hash-pinned `Worker.ps1`
(AppDeploy is already pinned by go.ps1, so it can carry the worker's hash - no second Worker var
needed). **Seven harnesses lift code out of that here-string** (`Test-AfterInstallList`,
`Test-CatalogScenarios`, `Test-DeepBatch`, `Test-DirtyCleanup`, `Test-GuiBatch`, `Test-Push`,
`Test-RealUninstall`), so it is a real refactor, not a move. Note the worker is ~130 KB but a
non-greedy regex for it returns ~95 KB - it contains nested here-strings ending in `'@`.

**Measurement traps hit, all mine:**
- the timing log starts INSIDE the script, so it cannot see the AV scan or UAC. The only honest
  number is wall clock from Enter until the log file appears.
- a leftover instance holds the `Local\PC2GoAppInstaller` mutex, so the next launch shows
  "already running" and exits: no log written, and a window-title probe matches the OLD window
  and reports ~1.4 s. Close existing copies first, and wait on the LOG, not on a window.
- the pwsh handoff at the top of AppDeploy silently dropped `-Timing` (now forwarded).

**Process lesson:** three separate times a saving was claimed from an inferred number instead of
a measured one, and the user was right to push back hard. `PC2GO_TIMING=1` writes
`%LOCALAPPDATA%\PC2GoDeploy\timing.log`; use it, and take the wall clock alongside it.

Related: [[project-push-button-r2-upload]], [[feedback-prove-it-with-tests]]
