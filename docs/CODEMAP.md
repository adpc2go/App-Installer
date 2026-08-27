# CODEMAP — grep-anchor index (token-lean, for fast machine scanning)

Line numbers rot; **anchors don't**. Every entry is a unique string to `grep -n` for.
Regenerate when structure changes, not on every edit.

## Repo layout

| Path | What |
|---|---|
| `server\AppDeploy.ps1` | THE app: GUI + elevated worker in one ~14.5k-line file |
| `server\apps.json` | catalog (schema: README "Catalog reference") |
| `server\go.ps1` | bootstrap: fetch AppDeploy, verify pinned sha, run |
| `cloudflare\worker.js` | edge: catalog filter, URL signing, /files gate |
| `tools\Catalog-Editor.ps1` | **PC2Go Management Console** GUI (~5k lines) — catalog, R2, publish, access code |
| `tools\Publish-Release.ps1` / `R2-Upload.ps1` | publish + S3 transport |
| `tests\` | 11 harnesses + `Test-Worker.mjs` (mutex-serial; see traps) |

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
| `$script:TweakDefs` | Optimize rows: tweaks/cleanup/gaming defs (tab= field) |
| `function Select-OptTab` | Optimize sub-tab pills |
| `function Invoke-TweakDetect` | check-before-apply probes (ACTIVE sub-tab only; Prefs = Sync-Prefs) |
| `$workerScript = @'` | ELEVATED WORKER here-string (TWO `.Replace` substitutions in Start-Worker: PrefTable + NVAPI) |
| `function Install-One` | verify→unpack/mount→watched run→verdict→postInstall |
| `function Uninstall-One` | vendor/registry/appx removal + detect check |
| `function Test-RunAllowed` | remover exe gate (Program Files roots only) |
| `function Apply-Tweak` / `function Undo-Tweak` | worker tweak switches (incl. gaming/NVAPI) |
| `$offset = 0` + `$script:FailedIds` | worker queue loop; `chain`/`after` skip flags |
| `function Start-Worker` | worker write + hash-pinned `-EncodedCommand` stub |
| `function Enqueue-Install` | queue entry (+dep guard, chain/after fields) |
| `function Sync-DepGuards` | GUI-side dependency abort (skip.txt) |
| `function Read-WorkerStatus` | status pump; AwaitingScan → leftover scan |
| `function Start-LeftoverScan` | async runspace scan (Update-/Complete-LeftoverScan) |
| `function Finish-Batch` | one exit for every batch; run record; cache sweep |
| `$timer.Add_Tick` | 400ms pump: downloads/BITS/segmented + 3-strike fault guard |
| `function Get-PfDepState` | dependency detection (case 3/4) |
| `function Get-PfCommitItems` | effective batch: un-rows + Sort-ByRequires + reinstalls |
| `function Sync-Preflight` | the sheet: disk math + dep panel (PfDep null-guarded) |
| `function Start-Batch` | install batch (seeds remove-first queue entries) |
| `function Start-Uninstall` | removal batch (RunStarted, deep-clean, Force path) |
| `# ---------- go ----------` | harness split marker (nothing after runs in tests) |

## Worker queue actions

`install · uninstall · wipe(file/reg/regvalue/service/task/hosts/run) · tweak · untweak ·
pref · fix · fwblock/fwunblock/fwunblockrules · newuser · migrate · setadmin · setpassword ·
toggleacct · deleteaccount` — one JSON line each; `{"end":true}` releases the worker;
`chain=true` skips after any chain failure, `after=[ids]` skips if THOSE named ids failed.

## Catalog-Editor.ps1 anchors

| Anchor | Region |
|---|---|
| `function Show-AccessCodePrompt` | set/rotate the edge access code (`Invoke-Wrangler`, stdin) |
| `function Get-Field` | in-place JSON mutation trio (why unknown fields survive saves) |
| `function Test-App` | validation (uninstallOnly/requires/removers/dup-id aware) |
| `function Export-Catalog` | save: clone-strip `_localFile`, BOM-less, .bak guarded |
| `function Get-PushStateFor` | sidecar re-key (refuses to steal live catalog ids) |
| `function Save-PushState` | atomic .tmp swap (+.tmp recovery in Get-PushState) |
| `function Get-AppFingerprint` | live-vs-local compare (nested url normalization) |
| `function Show-AppDialog` | the drawer (poll tick wrapped in Invoke-Guarded) |
| `$script:DrawerOnChange = {` | main-window side of apply; SIDECAR PERSIST lives here |
| `function New-PushPlan` | push buckets incl. `Stale` (size-vs-hash refusal) |
| `$script:FetchWork` | hash/fetch runspace (URL-keyed cache, .part staging) |

## Invariants (violate = real bug)

- One UAC prompt per batch; worker starts on FIRST Enqueue-Install, exits only on end marker.
- Nothing elevated executes unverified: installers/postInstall/removers sha-pinned; on-disk
  removers gated to Program Files roots; the worker file's hash rides the command line.
- apps array order = install order (never permute); `categories` array owns rail order.
- apps.json / sidecar: BOM-less UTF-8, `[IO.File]::WriteAllText` only.
- The pre-flight sheet gates on the SAME disk math Start-Batch enforces.
- Deep clean never targets orchestrated remove-first rows.
- The drawer is sidecar-free (Test-Push pins it); persist goes through DrawerOnChange.
- The access code never touches a command line (Win32_Process.CommandLine is world-readable)
  and its hand-off token is DACL'd at creation, freshness-checked, and shredded after use.
- No registry value is written by both a tweak row and a preference toggle.
- Apply Gaming un-ticks "Xbox and Gaming - Remove"; it does NOT un-tick Game DVR
  (DVR off is a measured FPS win — a gaming machine wants it off).
- Optimize toolbar actions (Select All/Clear All/Reset/Detect) act on the ACTIVE sub-tab
  only, and Reset stays VISIBLE beside Detect — Detect's contract ("tick what is applied")
  can legitimately empty a list, and Reset is the way back.

## Traps (full numbered list + stories in HANDOVER.md)

mutex vs harnesses · WPF binds properties not fields · BitmapImage not via PSCustomObject ·
system ComboBox/ScrollBar templates · `[Math]::Max(1,$int64)` overload · `$ps.Stop()` blocks
the dispatcher (BeginStop) · `$script:` WRITES inside `.GetNewClosure()` land in the closure's
module (6 sightings — use named functions) · here-strings don't nest (`#__TOKEN__`
substitution; Start-Worker does two: PrefTable + NVAPI) · `Items.Clear()` blanks editable ComboBox Text ·
missing-property assignment throws on PSCustomObject · restore selections by identity not
index · AST-lifting harnesses need new functions added to their lists · powercfg /query hides
Attributes=1 settings (read the registry) · NDIS keywords start with a literal `*` (escape it).

## Test map (what proves what)

| Suite | Proves |
|---|---|
| Test-GuiBatch (207) | real tabs: preflight, batch, cancel, removers e2e, dependencies e2e, run records |
| Test-Push (273) | R2 signing/resume/skip, sidecar seams, worker field-transfer list |
| Test-Categories (228) | editor window, category model, icon pipeline |
| Test-AfterInstallList (206) | drawer's postInstall list + real worker execution |
| Test-DirtyCleanup (83) | dirty verdicts, wipe decisions, pre-tick rules |
| Test-CatalogEditorGui (68) / Scenarios (65) | editor main window / whole journeys + schema round-trip |
| Test-RealUninstall (51) | real installs removed, incl. a FileShare.None lock |
| Test-DownloadResilience (35) / DeepBatch (27) | resume/ETA / real BITS + exit-code matrix |
| Test-Worker.mjs (30) | edge filter, signing (incl. removers), uninstallOnly pass-through |
| Test-Elevated (19, BY HAND, launched elevated) | the real elevated worker end to end |
