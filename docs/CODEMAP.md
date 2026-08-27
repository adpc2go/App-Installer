# CODEMAP — grep-anchor index (token-lean, for fast machine scanning)

Line numbers rot; **anchors don't**. Every entry is a unique string to `grep -n` for.
Regenerate when structure changes, not on every edit. Last checked 2026-08-27.

## Repo layout

| Path | What |
|---|---|
| `server\AppDeploy.ps1` | THE app: GUI + elevated worker in one ~16.2k-line file |
| `server\apps.json` | catalog (schema: README "Catalog reference") |
| `server\go.ps1` | bootstrap: access code, splash, fetch AppDeploy, verify pinned sha, run |
| `cloudflare\worker.js` | edge: access gate, catalog filter, URL signing, /files gate |
| `tools\Catalog-Editor.ps1` | **PC2Go Management Console** GUI (~5.9k lines) — catalog, R2, publish, access code |
| `tools\Publish-Release.ps1` / `R2-Upload.ps1` | publish + S3 transport + the watched wrangler call |
| `tests\` | 15 PowerShell harnesses + `Test-Worker.mjs` (mutex-serial; see traps) |

## AppDeploy.ps1 regions (grep the anchor)

| Anchor | Region |
|---|---|
| `function Write-AccessBlob` | access-code hand-off token (DACL at creation; twin copy in go.ps1) |
| `function Clear-AccessFile` | shreds that token (called on catalog load + window close) |
| `public class AppItem` | row model (WPF binds PROPERTIES only — trap) |
| `public class WipeItem` | leftover row (Weak/Shared/Args/Sha256 for removers) |
| `$script:View = ` | CollectionViews + search filters (`$unFilter`) |
| `function Scan-Leftovers` | leftover walk (runspace-safe; $Stage/$Ctl params) |
| `function Refresh-UnList` | registry scan → rows; catalog row-upgrade (ODIS token) |
| `function Resolve-OdisManifest` | `__ODIS_MANIFEST__` → real path on client |
| `function Load-Catalog` | manifest → Items (skips `uninstallOnly`) |
| `$script:TweakDefs` | Optimize rows: tweaks/cleanup/gaming defs (`tab=` field; NO preferences) |
| `$script:FixDefs` | Toolbox rows: Fixes / Remote Access / Diagnostics (`group=` field) |
| `function Select-OptTab` | Optimize sub-tab pills (Tweaks · Cleanup · Gaming) |
| `function Invoke-TweakDetect` | check-before-apply probes (ACTIVE sub-tab only) |
| `$script:TweakTests` | the detector per row — also what Confirm-AppliedRows re-reads |
| `$workerScript = @'` | ELEVATED WORKER here-string (TWO `.Replace` substitutions in Start-Worker: PrefTable + NVAPI) |
| `function Install-One` | verify→unpack/mount→watched run→verdict→postInstall |
| `function Uninstall-One` | vendor/registry/appx removal + detect check |
| `function Test-RunAllowed` | remover exe gate (Program Files roots only) |
| `function Apply-Tweak` / `function Undo-Tweak` | worker tweak switches (incl. gaming/NVAPI) |
| `function Set-RegSoft` | write that MAY be refused; feeds `$script:RegDenied` → row text |
| `function Get-SlowPcReport` | slow-PC triage, L0–L6, read-only; `'slowpc'` case in Invoke-Fix |
| `function Invoke-Fix` | Toolbox fix dispatch inside the worker |
| `$offset = 0` + `$script:FailedIds` | worker queue loop; `chain`/`after` skip flags |
| `function Start-Worker` | worker write + hash-pinned `-EncodedCommand` stub |
| `function Enqueue-Install` | queue entry (+dep guard, chain/after fields) |
| `function Sync-DepGuards` | GUI-side dependency abort (skip.txt) |
| `function Read-WorkerStatus` | status pump; `$script:StatusOffset` NEVER moves backwards |
| `function Start-LeftoverScan` | async runspace scan (Update-/Complete-LeftoverScan) |
| `function Confirm-AppliedRows` | post-batch truth check: re-reads every "Applied" row |
| `function Send-SettingChange` | WM_SETTINGCHANGE broadcast (SMTO_ABORTIFHUNG, 100 ms) |
| `function Finish-Batch` | one exit for every batch; confirms rows, run record, cache sweep |
| `$timer.Add_Tick` | 400ms pump: downloads/BITS/segmented + 3-strike fault guard |
| `function Get-PfDepState` | dependency detection (case 3/4) |
| `function Get-PfCommitItems` | effective batch: un-rows + Sort-ByRequires + reinstalls |
| `function Sync-Preflight` | the sheet: disk math + dep panel (PfDep null-guarded) |
| `function Start-Batch` | install batch (seeds remove-first queue entries) |
| `function Start-Uninstall` | removal batch (RunStarted, deep-clean, Force path) |
| `# ---------- go ----------` | harness split marker (nothing after runs in tests) |

## Worker queue actions

`install · uninstall · wipe(file/reg/regvalue/service/task/hosts/run) · tweak · untweak ·
fix · fwblock/fwunblock/fwunblockrules · newuser · migrate · setadmin · setpassword ·
toggleacct · deleteaccount` — one JSON line each; `{"end":true}` releases the worker;
`chain=true` skips after any chain failure, `after=[ids]` skips if THOSE named ids failed.
(`pref` is GONE with the Preferences tab.)

## go.ps1 anchors

| Anchor | Region |
|---|---|
| `function Wait-AppWindow` | polls MainWindowHandle (0 until the WPF window shows), then lingers |
| `$PinnedHash = ` | integrity pin, injected by Publish-Release — never edited by hand |
| `finally {` (the outer one) | splash teardown + `$env:PC2GO_CODE = ''`; runs on Ctrl+C |

## Catalog-Editor.ps1 anchors

| Anchor | Region |
|---|---|
| `function Show-Activity` | the ONE status writer: level + expiry, so a refresh cannot clobber a result |
| `function Set-CatalogSummary` | the standing slot (`Update-List` may write ONLY this) |
| `function Set-CatalogDirty` | `$script:Dirty = $true; Request-Save` — every edit autosaves |
| `function Complete-Save` | the save tick; refuses and re-arms while a push holds the writer |
| `function Save-CatalogHistory` | 10-min ring under `server\.apps-history\` (20 kept) |
| `function Request-ListRefresh` | 180 ms debounce (the O(n²) rebuild used to run per keystroke) |
| `function Request-IconMove` / `Complete-IconMoves` | one PNG rename per burst, not per keystroke |
| `function Hide-AppIcon` | removed app's PNG → `icons\.removed\`, never orphaned |
| `function Show-Settings` | R2 credentials + access code, behind one Settings overlay |
| `function Hide-OverlayBodies` | ONE put-away for all overlay bodies (the leak this closed) |
| `function Invoke-Wrangler` / `Complete-WranglerCall` | non-blocking; polled from `$script:PushTimer` |
| `function Start-PinFetch` | live-pin check off the dispatcher |
| `function Show-AccessCodePrompt` | set/rotate the edge access code (stdin, never a command line) |
| `function Get-Field` | in-place JSON mutation trio (why unknown fields survive saves) |
| `function Test-App` | validation (uninstallOnly/requires/removers/dup-id aware; `-Index` fast path) |
| `function Export-Catalog` | save: clone-strip `_localFile`, BOM-less, session .bak |
| `function Get-PushStateFor` | sidecar re-key (refuses to steal live catalog ids) |
| `function Save-PushState` | atomic .tmp swap (+.tmp recovery in Get-PushState) |
| `function Get-AppFingerprint` | live-vs-local compare (nested url normalization) |
| `function Show-AppDialog` | the drawer (poll tick wrapped in Invoke-Guarded) |
| `$script:DrawerOnChange = {` | main-window side of apply; SIDECAR PERSIST lives here |
| `function New-PushPlan` | push buckets incl. `Stale` (size-vs-hash refusal) |
| `$script:FetchWork` | hash/fetch runspace (URL-keyed cache, .part staging) |

## R2-Upload.ps1 anchors

| Anchor | Region |
|---|---|
| `function Resolve-Wrangler` | global `wrangler` first, else `npx --yes` (SHARED with Publish-Release) |
| `function Start-WranglerWatched` | hidden, `-PassThru`, redirected, **never `-Wait`**; `[void]$p.Handle` |
| `function Update-WranglerWatched` | drain + OAuth detection + stall clock + wall clock |
| `function Stop-WranglerWatched` | tree-kill (npx launches node; killing the parent is not enough) |
| `function New-SecretTempFile` | DACL applied AT CREATION via `FileStream(FileSecurity)` |
| `function Read-WatchedFile` | byte offset, `FileShare::ReadWrite`, cut at the last newline |
| `function Invoke-R2Upload` | multipart upload with resume |

## Invariants (violate = real bug)

- One UAC prompt per batch; worker starts on FIRST Enqueue-Install, exits only on end marker.
- Nothing elevated executes unverified: installers/postInstall/removers sha-pinned; on-disk
  removers gated to Program Files roots; the worker file's hash rides the command line.
- **"Applied" means the machine agrees.** A refused write is reported as refused; every Applied
  row is re-read through its own detector before the totals are counted; a row with no detector
  makes no claim either way.
- `$script:StatusOffset` only ever moves FORWARD — backwards replays a whole batch into the log.
- apps array order = install order (never permute); `categories` array owns rail order.
- apps.json / sidecar: BOM-less UTF-8, `[IO.File]::WriteAllText` only.
- The pre-flight sheet gates on the SAME disk math Start-Batch enforces.
- Deep clean never targets orchestrated remove-first rows.
- The drawer is sidecar-free (Test-Push pins it); persist goes through DrawerOnChange.
- The access code never touches a command line (Win32_Process.CommandLine is world-readable)
  and its hand-off token is DACL'd at creation, freshness-checked, and shredded after use.
- **No Tweaks row may be a no-op on a healthy machine** (why Window Snapping was dropped rather
  than promoted: its target value IS the Windows default).
- A tweak acts in ONE direction; Undo is what goes back. (The two-directional toggle is exactly
  what the deleted Preferences tab got wrong.)
- Apply Gaming un-ticks "Xbox and Gaming - Remove"; it does NOT un-tick Game DVR
  (DVR off is a measured FPS win — a gaming machine wants it off).
- Optimize toolbar actions (Select All/Clear All/Reset/Detect) act on the ACTIVE sub-tab
  only, and Reset stays VISIBLE beside Detect — Detect's contract ("tick what is applied")
  can legitimately empty a list, and Reset is the way back.
- The Management Console autosaves; there is no Save button. One Publish button is the only
  action that reaches production.

## Traps (full numbered list + stories in HANDOVER.md)

mutex vs harnesses · WPF binds properties not fields · BitmapImage not via PSCustomObject ·
system ComboBox/ScrollBar templates · `[Math]::Max(1,$int64)` overload · `$ps.Stop()` blocks
the dispatcher (BeginStop) · `$script:` WRITES inside `.GetNewClosure()` land in the closure's
module (6 sightings — use named functions) · here-strings don't nest (`#__TOKEN__`
substitution; Start-Worker does two: PrefTable + NVAPI) · `Items.Clear()` blanks editable
ComboBox Text · missing-property assignment throws on PSCustomObject · restore selections by
identity not index · AST-lifting harnesses need new functions added to their lists (now
CHECKED, not remembered) · powercfg /query hides Attributes=1 settings (read the registry) ·
NDIS keywords start with a literal `*` (escape it) · a type literal resolves at RUNTIME so a
parse check proves nothing · create it correct or not at all (never create-then-fix) ·
`Start-Process -PassThru` + redirect + no `-Wait` loses ExitCode SILENTLY (`[void]$p.Handle`) ·
**a timer/event cannot fire while its thread blocks** (show it directly) · **`$V` and `$v` are
the same variable** · **`Kill` is an alias for `Stop-Process`** · deleting the first line of a
multi-line detector orphans its continuation (re-parse after every deletion).

## Test map (what proves what)

| Suite | Proves |
|---|---|
| Test-GuiBatch (207) | real tabs: preflight, batch, cancel, removers e2e, dependencies e2e, run records |
| Test-Push (273) | R2 signing/resume/skip, sidecar seams, worker field-transfer list |
| Test-Categories (234) | editor window, category model, icon pipeline, lift-list completeness |
| Test-AfterInstallList (207) | drawer's postInstall list + real worker execution |
| Test-CatalogEditorGui (97) | editor main window incl. the console's activity/summary split |
| Test-DirtyCleanup (83) | dirty verdicts, wipe decisions, pre-tick rules |
| Test-Wrangler (75) | the hidden wrangler call: no `-Wait`, real exit code, OAuth detect, tree-kill |
| Test-CatalogScenarios (66) | whole journeys + schema round-trip |
| Test-AccessCode (54) | DPAPI hand-off token: unreadable from byte one, stale = ignored, shredded |
| Test-RealUninstall (51) | real installs removed, incl. a FileShare.None lock |
| Test-Worker.mjs (40) | edge filter, signing (incl. removers), uninstallOnly, access gate |
| Test-DownloadResilience (35) / DeepBatch (27) | resume/ETA / real BITS + exit-code matrix |
| Test-Elevated (19, BY HAND, launched elevated) | the real elevated worker end to end |
| Test-TweakReality (no pass/fail) | every worker registry write vs this machine, by AST |

Counts are PASS lines, measured 2026-08-27. `Test-GuiBatch` carries two known pre-existing
failures (one environmental, one chain-settle timing) and `Test-Push` one flaky assertion
(`Stop-ProcessTree` — `taskkill /T` is asynchronous).
