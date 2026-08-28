# Handover - 2026-08-27

A **field-test session**. The tool ran on real client machines - Windows 11 Home and Pro, both
25H2 - and the reports came back as symptoms rather than stack traces: *"I used dark theme,
nothing changed"*, *"show recent apps is not off"*, *"90% of them still there"*. Almost
everything below was found by measuring a machine, not by reading the code. Read the first
section before touching anything: it changes what "Applied" is allowed to mean.

**It is committed.** The last three handovers opened with a warning that nothing was; that is
now false. 29 commits sit on branch `console-rework`, ahead of `master` by 29 and behind by 0.
The live pin is `10AFBE9AFE2C7C0B07C527D6012627C0D0579FCD044D1C3C455C749B2B1DC494`.
**There is still no git remote** - one disk, two local branches. It stays at the top of
"Next, in order" for the fourth handover running.

## The finding that mattered: the tool was lying about its own work

*"the app was reporting its done while its not done"*, and the user was right. `Applied` meant
**"the registry write did not throw"** - not that the value landed, and never that Windows read
it back. Three changes make the word mean something:

- **`Set-RegSoft` + `$script:RegDenied`.** A value this Windows build refuses is no longer
  counted as written. `Apply-Tweak` resets the list per row and appends
  *"(this Windows build refused: X)"* to that row's own status, naming the values.
- **`Confirm-AppliedRows`, called first thing in `Finish-Batch`.** After a batch, every row
  that says `Applied` is re-read **through its own detector** - the same probe Detect Applied
  uses. Disagreement becomes *"Applied - could not confirm on this machine"*, an amber ring,
  and a log line naming every row. It runs **before** the totals are counted, so the summary
  describes what the machine confirms rather than what the writes returned.
- **No probe means no claim.** A restore point and every cleanup row are *events*, not states.
  They have no detector, they are skipped, and silence is the honest answer for them.

That is the shape of the whole session: the tool now checks its own work, and where it cannot,
it says so instead of claiming success.

## Windows 11 25H2 moved five settings, and the old writes were dead

Each was found by **before/after registry diffing over PowerShell Direct** while the user
toggled the real Settings UI on the VM - not from documentation, which is still wrong about
most of these. `Migrated=1` marks the old location dead.

| What the user saw | Old location | Where 25H2 actually reads it |
|---|---|---|
| Explorer Privacy unchanged | `Explorer\Advanced\ShowRecent`, `ShowFrequent`, `ShowCloudFilesInQuickAccess` | the same names one level **up**, in `Explorer\` |
| Start still showed recent / most-used | `Explorer\Advanced\Start_TrackDocs` and friends | `Explorer\Start\ShowRecentList`, `ShowFrequentList`, `AllAppsViewMode=2` |
| Start recommendations still there | (none) | `Explorer\ShowRecommendations` |
| Taskbar "Resume" badge | (none) | `Explorer\Advanced\IsEnabled` |
| Home and Gallery in the sidebar | (none) | `HKCU\Software\Classes\CLSID\{f874310e-...}` and `{e88865ea-...}`, `System.IsPinnedToNameSpaceTree=0` |

**A written value is not a visible one.** Explorer caches; nothing re-reads until it is told.
`Send-SettingChange` (GUI side) broadcasts `WM_SETTINGCHANGE` / `ImmersiveColorSet` through
`SendMessageTimeout` with `SMTO_ABORTIFHUNG` and a **100 ms** cap - so one wedged top-level
window cannot stall the tool the way a plain `SendMessage` would - plus `SHChangeNotify`.
Measured cost ~300 ms, once per batch, and only when the batch wrote something that needs it.

**`TaskbarDa` is refused by this build even non-elevated, and it is not a bug to chase.** It
does not turn Widgets off - it removes the whole option from Settings. The row reports the
refusal rather than pretending.

**Gaming: `AllowAutoGameMode` / `AutoGameModeEnabled` were never wrong.** The user's own
WinUtil log proved the tool writes the same values. What actually happened: **Windows Update
reinstalled `XboxGamingOverlay` and `GamingApp` hours after removal and wiped the gaming
settings with them.** `Remove-AppxByName` deprovisions correctly; the gap is the Store update
channel. A Store opt-out row was built for it and then dropped the same day at the user's
instruction, because the only switch that works stops *every* Store update, including the codecs
and WebView2 a customer's own software needs. So nothing in the tool prevents the reinstall now.

## The doubled Optimize log was not double execution

A run logged 42 rows twice. It was **one batch reported twice**: `Read-WorkerStatus`'s offset
could move **backwards**, so consumed status lines were replayed. Diagnosed by timing rather
than by reading - pass 2's 42 rows completed inside one second against 20 s for pass 1, which
no real batch does. The guard is one line, and the offset now only ever moves forward:

```powershell
if ($lines.Count -le $script:StatusOffset) { return }
```

## Preferences is gone, and four rows came up to Tweaks

The user's call, and the right one: *"we dont need the whole prepfrance tab ? why it should be
threr empty ?"* - an empty tab had been staged for safety, and was removed outright instead.

Why the tab was wrong is the part worth keeping: **a tick in Tweaks means "I will apply this",
while a tick in Preferences meant "this is how the machine already is"** - the same control
carrying opposite meanings. That is how an unticked preference once silently left-aligned a
taskbar nobody asked it to move. A tweak acts in **one direction** only; Undo is what goes back.

Promoted: **Lock Screen - Disable**, **Logon Verbose Mode - Enable**, **Mouse Acceleration -
Disable**, **Settings Home Page - Hide**. **Window Snapping was dropped rather than promoted**,
and the rule behind that is the reusable part: *its target value IS the Windows default*, so as
a tweak it would have been a row that changes nothing on a healthy machine. No Tweaks row is
allowed to be a no-op on a healthy machine.

Also removed, on the user's instruction: the **DNS resolver** row and the **stop automatic
Store updates** row. (Deleting `dnsresolver` is where the multi-line-detector trap bit - see
the traps below.)

**S0 Sleep Network Connectivity is currently ABSENT.** The user approved moving it into
Tools > Fixes; it was dropped from Preferences and never re-homed. It is the one piece of
agreed work this session did not finish.

## Slow PC - Diagnose (Tools > Diagnostics)

`Get-SlowPcReport`, in the elevated worker because SMART, services and the event log need
admin. Seven layers **read in order**, ~5 s, and it **changes nothing**. One
`Write-Status <id> 'Checking' "VERDICT L<n>: ..."` per layer, so each lands as its own line in
the existing Activity log with no new UI, and the report is written to
`$script:CacheDir\slowpc-<yyyyMMdd-HHmmss>.txt` through `Out-File -Encoding utf8` - the `>`
redirection operator writes UTF-16 on 5.1, which turns a pasted report into mojibake for
whoever receives it.

L0 hardware Ã‚Â· L1 what is running Ã‚Â· L2 security software Ã‚Â· L3 memory Ã‚Â· L4 background work Ã‚Â·
L5 startup and persistence Ã‚Â· L6 faults and throttling. The order is the point: each layer
decides whether the next is worth doing, and the top finding is the one to act on.

**Calibration was the work, not the layers.** The first run on a healthy i9 workstation flagged
three false positives, and each fix is a rule worth keeping:

- **L1** named `svchost` and `WmiPrvSE`, because Windows' own infrastructure accumulates
  thousands of CPU-seconds on any long-running machine. It now judges by **where the binary
  lives**, not by a hand-maintained name list.
- **L3** flagged 1 GB of memory compression with 15 GB free. Compression only means pressure
  when memory is **also** short, so it now needs both.
- **L5** flagged Discord and Logitech, because Squirrel-packaged apps launch through
  `Update.exe` and the pattern contained a bare `update`.

Then it was proved it can still **fire**, because a check that cannot fail proves nothing:
**10/10 real PUP and OEM names flagged, 10/10 legitimate startup entries clean**, and a
third-party binary correctly told apart from `svchost`.

**Known limit, stated on purpose.** L1's bar - beat `explorer` + `dwm` combined - will miss a
moderate hog on a busy workstation: the user's own `rsEngineSvc` at 1562 CPU-s reads *below*
this machine's 1858 shell total. Ranking by an absolute number would fire constantly instead.
So the verdict stays strict, and the **evidence always names the top third-party consumer with
the number it had to beat**, leaving the judgement with the technician.

Not wired yet: the verdicts do not link to the rows that fix them (Power Saver -> Power Plan,
and so on). Discussed, agreed, not built.

## go.ps1: the splash, and Ctrl+C

Three separate bugs, one window.

- **It never appeared.** The splash was raised on a timer, and **an event action cannot fire
  while the same thread sits inside a blocking call** - measured: an 800 ms timer fired at
  +4051 ms of a 4052 ms download. It is now shown **directly**, right after the code is typed.
- **It never left** when Ctrl+C was pressed at the code prompt. The whole flow is wrapped in
  `try { ... } finally { SplashTimer.Stop(); Hide-Splash; $env:PC2GO_CODE = '' }`, and
  `finally` does run on `StopPipeline` - proven, not assumed.
- **It vanished too early**, before the app window was up. `Wait-AppWindow` polls
  `MainWindowHandle`, which stays 0 until the WPF window actually shows (measured flipping at
  3716 ms), then lingers 1200 ms.

## New traps (continuing the numbering)

19. **An event or timer action cannot fire while its thread is inside a blocking call.** A
    DispatcherTimer set for 800 ms fired at +4051 ms of a 4052 ms `Invoke-WebRequest`. If
    something must be on screen *before* slow work starts, show it directly - a timer is not a
    thread.
20. **`$V` and `$v` are the same variable.** PowerShell names are case-insensitive, so
    `Get-Volume`'s result silently overwrote the verdict table: all seven verdicts came back
    empty while the evidence collected perfectly. Nothing errors and nothing warns. Found by
    running it, not by reading it.
21. **`Kill` is an alias for `Stop-Process`.** A helper function of that name is shadowed and
    silently never runs.
22. **Editing `AppDeploy.ps1`: multi-line string replacement is unreliable** (mixed line
    endings through the file); brace-balanced line-range edits work. And **deleting the first
    line of a multi-line detector orphans its continuation** - removing `dnsresolver`'s first
    line produced five parse errors somewhere else entirely. Re-parse after every deletion.
23. **Publishing and running the suites in one command is a sequencing mistake.** It was done
    once this session, and a `Test-Push` failure surfaced *after* the publish had gone out. It
    turned out to be flaky rather than a regression, which is luck, not process.

## Test baseline

Re-measured 2026-08-27 on this machine, counted by PASS lines. Suites are mutex-serial and the
tool cannot be open while they run.

| Suite | Pass | Fail |
|---|---|---|
| Test-AfterInstallList | 207 | 0 |
| Test-GuiBatch | 205 | **2** (both pre-existing) |
| Test-Push | 273 | 0 |
| Test-Categories | 234 | 0 |
| Test-CatalogEditorGui | 97 | 0 |
| Test-DirtyCleanup | 83 | 0 |
| Test-Wrangler | 75 | 0 |
| Test-CatalogScenarios | 66 | 0 |
| Test-AccessCode | 54 | 0 |
| Test-Worker.mjs | 40 | 0 |
| Test-TweakReality | read-only reality check, no pass/fail | Ã¢â‚¬â€ |

**1,294 PowerShell assertions plus the Worker's 40, and 2 failures**, both in `Test-GuiBatch`
and both pre-existing: *"and it did not elevate itself"* (environmental) and *"the failing
batch settled"* (a chain-settle timing race). Not re-run this session, unchanged since 08-26:
`Test-RealUninstall` (51), `Test-DownloadResilience` (35), `Test-DeepBatch` (27), and
`Test-Elevated` (19/19, which must be **launched from an already-elevated PowerShell** or its
UAC prompt opens unfocused).

`Test-TweakReality` is new and is deliberately **not** a pass/fail suite: it is a read-only
reality check that extracts `Set-Reg` / `Set-RegSoft` / `Remove-RegVal` from the worker by AST
and reports, per value, whether this machine currently matches. Read it as: *before* an
Optimize run a MISMATCH simply means "not applied yet"; **after** a run that reported Applied,
every MISMATCH is a tweak that did not take.

`Test-Wrangler` (75) covers the hidden wrangler call - never `-Wait`, a real integer exit code,
sign-in detected from wrangler's own output, both give-up clocks, the tree-kill, and a secret
file that never exists readable and does not survive the call.

**One flaky assertion to know about:** `Test-Push`'s *"and its child was stopped with it, not
left running"* (a `Stop-ProcessTree` test) failed once in three runs, the other two at 274/0.
`taskkill /T` is asynchronous and the assertion occasionally reads the child before Windows has
finished reaping it. It is a timing race in the test, not a defect in the tree-kill.

## Next, in order

1. **git remote + push.** Fourth handover saying it. 29 commits, one disk.
2. **Re-home S0 Sleep Network Connectivity in Tools > Fixes** - approved, dropped, never
   rebuilt. The only agreed item this session left undone.
3. Wire the slow-PC verdicts to the rows that fix them.
4. Cloudflare **rate-limit rule on 403s**: the access gate can be brute-forced at line rate
   (measured 5 attempts in 0 s, unthrottled). A dashboard setting, not code.
5. Multi-code access audit - named codes plus per-code usage counts, so one leaked code can be
   revoked without rotating everyone.
6. Host `avastclear.exe` under `files/removers/` in R2 and pin its sha256 (`-ValidateOnly`
   still warns).
7. `HintNetManual` (AppDeploy.ps1) still has no `Add_TextChanged`, so the grey
   `\\PC-NAME\SharedFolder` sits under whatever the technician types.
8. `Test-GuiBatch`'s two pre-existing failures - one environmental, one chain-settle timing.
9. `Export-UiSnapshots.ps1` still hangs; `ui-snapshots\` is still stale.

---

# Handover - 2026-08-26

Two Claude sessions worked the same tree in parallel, coordinating by message. Everything
below is verified by the suites listed at the end. `docs\CODEMAP.md` is new: a grep-anchor
index of the repo, written to be scanned by a machine before a human.

## Still not committed - RESOLVED 2026-08-27

This said: ~50 verified fixes and three new feature systems sat uncommitted on one disk with
no remote. They are committed now, on branch `console-rework`. There is still no remote - see
the 08-27 section at the top.

## Workstream A - Optimize tab rebuild (build 54)

> Historical. The Preferences sub-tab described below was REMOVED on 08-27 - four rows were
> promoted into Tweaks and the rest dropped. Read the 08-27 section for what ships today.

The old Tweaks tab is now **Optimize**, four sub-tabs on the Uninstall pill pattern, each
Apply acting only on what is on screen: Tweaks 44 rows (38 pre-ticked / 6 CAUTION, config
only), Cleanup 5 (one-time disk actions, no Undo, reclaimed GB reported), Gaming 14 (the
gaming-customer persona), Preferences 11 toggles (mirror the machine; only changes written).
Presets are DELETED; Clear became Reset (defaults, not all-unticked) + Select All/Clear
All/Detect Applied/Measure - ALL FOUR toolbar actions act on the active sub-tab only
(user decision, 08-26; Reset/Detect on Preferences = Sync-Prefs, i.e. drop pending edits /
re-read the machine). 13 dead/counterproductive tweaks removed, 21 added, 11 duplicate
preference toggles cut, 2 moved to Tools>Fixes; no registry value is written by both a tweak
and a toggle. Check-before-apply probes every row first ("Already applied - skipped", never
queued; a no-op batch also skips the restore point); the restore point is a real gate; three
undo collisions fixed; `Resolve-UserPath` lands per-user work on the SIGNED-IN user (fixed
the old tempfiles wrong-profile bug); one Explorer restart per batch, by the GUI as the right
user; per-session log at `%LOCALAPPDATA%\PC2GoDeploy-Logs\session-*.log`; 32-bit-on-64-bit
Sysnative relaunch added beside the PS7 handoff.

Gaming specifics (evidence-ported from the GameOpt project; its documented placebos
deliberately absent): NVAPI P/Invoke for NVIDIA Low Latency Ultra + Max Prerendered Frames 1
(driver profile DB, NOT registry - .reg guides fail), including the DeleteProfileSetting
binding so undo genuinely removes them; NIC advanced-property tuning with case-sensitive
single-match + WildcardPattern::Escape (NDIS keywords start with a literal `*`); power values
written via powercfg but READ from the registry (powercfg /query hides Attributes=1 settings
like core parking), undo DELETES the explicit index so the scheme inherits its default; a
before/after latency probe (preemption jitter p99/max, timer granularity, DPC/ISR) with a
warmup round and a double gate so it never manufactures a verdict. Persona rule: Apply Gaming
un-ticks "Xbox and Gaming - Remove" (a gamer keeps Game Pass) and says so; it does NOT
un-tick Game DVR - DVR off is a measured FPS win, so a gaming machine wants it off.

Not field-tested yet: no VM round-trip, no Win11 Home policy check, no wrong-profile test, no
laptop chassis test, no real Apply Gaming on a gaming machine, HAGS reboot unverified; two
registry values ship FLAGGED unverified in comments (Win11 24H2/25H2 taskbar Resume toggle,
lock-screen status policy).

## Workstream B - Install/Uninstall, removers, dependencies, editor review

Schema growth (all in README's catalog reference): `requires: [ids]` with a pre-flight guard
and one-click orchestration (remove add-on -> install base -> reinstall add-on, one UAC,
worker `chain`/`after` flags, deep clean deliberately skipped for the remove-first step);
`cleanup.removers` (vendor removal tools as never-pre-ticked run-this rows - path-form gated
to Program Files roots, url-form hash-pinned and edge-signed); `uninstallOnly: true`
(removal-only entries, `avast-free` is the model - edge serves them hash-less, Install tab
hides them, Test-App skips installability blockers); `__ODIS_MANIFEST__` in uninstall.args,
resolved on the client (fixture-proven, NOT yet proven against a real Autodesk machine).
Leftover preview grew Select all/Clear all (shared components and hidden guesses excluded),
weak-match grading behind a "Show N possible matches" toggle, and the scan runs off-thread
and cancellable. Earlier the same day: uninstall run records timed from their own start,
sub-tab pills refused before restyle, live-add resets, Test-Elevated's staging fixed
(19/19 elevated - the suite must be LAUNCHED elevated or its UAC prompt opens unfocused).

The Catalog Editor got its full review: three passes, 41 findings, 28 fixed. Headlines:
hashes computed but never stored (poll tick now calls apply); Save-AppSources never called in
production (now wired via DrawerOnChange, main-window side - Test-Push pins that the dialog
stays sidecar-free); partial downloads no longer cached as complete (.part + URL-keyed
cache); Duplicate/rename can no longer steal a sidecar upload record; Push refuses a file
whose size no longer matches the hashed catalog entry; sidecar swaps atomic with .tmp
recovery; category-rename closure bug (trap sighting #6) and the synchronous Stop() freeze
(trap #7 again, now BeginStop) fixed; "Add application" during a search no longer edits the
wrong app. Deferred, known: drawer "Use a local file" DURING a push can still race the
sidecar; name-box keystrokes still rename icon files live; a dismissed-not-switched drawer
keeps its hash running invisibly.

## New traps for the list (continuing the 08-25 numbering)

9.  A single-quoted here-string cannot nest: an inner `'@` terminates the OUTER string and
    the whole file stops parsing. Inject via `.Replace('#__TOKEN__', $text)` - Start-Worker
    performs TWO substitutions (PrefTable, NVAPI source) - keep both when editing. The
    `__ODIS_MANIFEST__` token is a different mechanism entirely: a catalog string resolved
    client-side by Resolve-OdisManifest, never passed through Start-Worker.
10. `Items.Clear()` on an editable ComboBox blanks its Text - and storage that relies on that
    side effect raising TextChanged does not fire for a bare .exe.
11. Assigning a MISSING property on a PSCustomObject throws - guard like Get-Field does.
12. Restore list selections by identity, never index (Update-List does now).
13. AST-lifting harnesses need every new function added to their lift lists
    (Test-CatalogScenarios, Test-AfterInstallList's $fromEditor) - the symptom is
    CommandNotFoundException from deep inside a lifted closure.
14. **A type literal is resolved at RUNTIME, so a parse check proves nothing about it.**
    `[IO.FileSystemRights]` does not exist (it is `Security.AccessControl.FileSystemRights`);
    the file parsed clean with 0 errors and would have thrown "Unable to find type" the first
    time a technician actually used the access code. Every `[Foo.Bar]` in a rarely-taken
    branch is untested code however green the parse is - only executing it proves it.
15. **Assertions can encode folklore.** A test that "a LocalMachine DPAPI blob must FAIL to
    Unprotect under CurrentUser" is wrong: the blob carries its own scope and the argument is
    advisory, so it succeeds. When a new test fails, decide which of the two is wrong before
    touching either - here the CODE was right and the test was corrected to pin the scope at
    source level instead. (Both 14 and 15 came out of the same hour: writing the test found
    the bug that writing the code did not.)
16. **Create it correct, or not at all - never create-then-fix.** Two unrelated bugs tonight
    were the same bug: a file written with an inherited ACL and tightened afterwards is
    world-readable for the gap (closed with the FileStream(FileSecurity) overload), and a
    here-string nested inside another terminates it early (closed with `#__TOKEN__`
    substitution at build time). Both had a window where correctness leaked out. If a thing
    must be secure, atomic, or well-formed, the operation that brings it into existence has
    to be the operation that makes it so - a second step is a window, whatever guards it.
17. **`Start-Process -PassThru` + a redirect + no `-Wait` loses the exit code SILENTLY.**
    PowerShell releases the process handle, and `$p.ExitCode` then reads back as empty - no
    exception, no error, just nothing - so `if ($p.ExitCode -eq 0)` is false on a run that
    succeeded. Touch `[void]$p.Handle` immediately after starting, which keeps the handle open.
    Measured on this machine; without it every exit code is `''`. The shapes already in the repo
    are NOT affected: `-PassThru` with no redirect (Invoke-RobocopyWatched, Start-InstallerWatched)
    and `-PassThru -Wait` both report correctly, and Start-Publish redirects inside its own
    command line (`*> log`) rather than through the parameter. It is specifically the
    parameter-redirect-without-Wait combination. Pinned by Test-Wrangler's "its exit code is a
    real integer, not empty".
18. **Trap 13 bit FIVE times, so it is now checked instead of remembered.** (Request-Save twice,
    Request-IconMove, Save-CatalogHistory, plus the original.) Test-Categories,
    Test-CatalogScenarios and Test-AfterInstallList each now assert *"every editor function a
    lifted one calls is lifted or stubbed"*: walk each lifted function's AST for CommandAsts,
    keep the names Catalog-Editor.ps1 defines, and fail on any that is not a defined function by
    that point in the run. It tests for DEFINED rather than for membership of a list, so lifting
    and stubbing both satisfy it and there is no second list to maintain. Verified by
    reintroducing the real bug: it fails with `Export-Catalog calls Save-CatalogHistory`, at the
    top of the run rather than deep inside a closure.

    Adding it found three latent gaps nobody had hit: **`Invoke-Guarded`'s own error path**
    (`Get-LevelDot`, `Show-Fail`, `Show-Notice`) was unstubbed in both dialog harnesses, so a
    throw inside any lifted code would have died *reporting* the throw and buried the real
    failure under a CommandNotFoundException.

    Still true, and still worth doing by hand: a lifted function that touches script-scope state
    should initialise it itself (`if ($null -eq $script:X) { $script:X = @{} }`) so it can run
    standalone at all.

## Test baseline

GuiBatch 207 Ã‚Â· Push 274 Ã‚Â· Categories 235 Ã‚Â· AfterInstallList 207 Ã‚Â· DirtyCleanup 83 Ã‚Â·
CatalogEditorGui 97 Ã‚Â· Wrangler 75 Ã‚Â· CatalogScenarios 66 Ã‚Â· AccessCode 54 Ã‚Â· RealUninstall 51 Ã‚Â·
Worker.mjs 40 Ã‚Â· DownloadResilience 35 Ã‚Â· DeepBatch 27 Ã‚Â· Elevated 19/19 (by hand, elevated).
Suites are mutex-serial; the tool cannot be open while they run.

Counted on 2026-08-26 by PASS lines, which is why some numbers moved without the suite
changing - the older figures came from each suite's own summary line. What is directly
comparable: **CatalogEditorGui 68 -> 97** (the new console section), **Categories 228 -> 235**
(the icon-move contract plus the lift-list check), and **Wrangler 75, new**. The console
suites plus the Worker run green at **1,008 PowerShell assertions + 40 Worker, 0 failures**,
and `Publish-Release.ps1 -ValidateOnly` exits 0.

Late addition, same day: the **access code**, and the editor became the **PC2Go Management
Console** (window title only - the filename `Catalog-Editor.ps1` is unchanged so every path,
harness and doc reference still resolves).

ACCESS_CODE secret on the Worker gates /AppDeploy.ps1 and /apps.json (constant-time compare,
`x-pc2go-auth: required` marker on the 403, /go stays open because the bootstrap is useless
without what it fetches). go.ps1 prompts masked, 3 tries, and covers the already-cached-tool
path with a HEAD probe - otherwise nothing would ask for the code and the tool would 403 with
no console to explain it. Get-CatalogFailure grew an "Access code required" branch.

**The carrier is the subtle part, and it is not the environment.** `-Verb RunAs` builds a
fresh environment through the AppInfo service, so an env var does NOT reach the elevated
copy - and go.ps1 itself elevates (:278), so that is the COMMON path, not an edge case: it
would have failed exactly for an admin technician on a normal launch, and worked everywhere
else. The code travels as a DPAPI(LocalMachine) token at
`%ProgramData%\PC2GoDeploy\access.bin`:
  * ProgramData because %LOCALAPPDATA% is per-user and the UAC prompt may be answered by a
    different admin; LocalMachine because a CurrentUser blob would be undecryptable there.
  * DACL applied AT CREATION (FileStream's FileSecurity overload, not write-then-tighten):
    LocalMachine DPAPI has no per-user key, so readable IS decryptable and the ACL is the
    entire control - a write-then-tighten window is the one moment the design exists to close.
  * Creator + Administrators + SYSTEM, inheritance off. The CREATOR is on it deliberately: a
    filtered-token admin cannot write to an Administrators-only file, which would break the
    writer this exists to serve.
  * It is a HAND-OFF TOKEN, not storage. Older than 2 minutes (or dated in the future) = debris:
    ignored and deleted, never trusted. Without that, a leftover file lets a second technician
    silently authenticate with a code they never typed. Shredded on catalog load and on close.
  * Never a command line: Win32_Process.CommandLine is world-readable.
Management Console > Access code... sets/rotates via `wrangler secret put ACCESS_CODE`, code
on STDIN from an owner-only-DACL temp file, shredded in a finally; blank + Remove deletes it.

Say it plainly to whoever inherits this: **the gate is access control, not secret-keeping.**
The code is necessarily cleartext in client memory, so it is meant to be cheap and routine to
rotate; the signed-URL gate and the SHA-256 pins are still what protect the installers.

Covered by `tests\Test-AccessCode.ps1` (38) and Test-Worker.mjs's gate section (40 total).
NOT yet done: the Cloudflare rate-limit rule on 403s (a dashboard setting, not code), and the
planned multi-code audit (named codes + per-code usage counts, so a single leaked code can be
revoked without rotating everyone) - the user asked for that as a later upgrade.

## Next, in order

1. **git remote + push.** Third handover saying it.
2. Host avastclear.exe under files/removers/ in R2, pin its sha256 in `avast-free`.
3. Prove `__ODIS_MANIFEST__` + the AdskLicensing remover on a machine with real Autodesk.
4. Field-test the Optimize/Gaming build (the not-tested list above).
5. Decide `office365` (still armed per the 08-25 note below unless since changed).
6. Export-UiSnapshots still hangs; ui-snapshots\ still stale.

---

# Handover - 2026-08-25

The format described further down **has happened**. The repo now lives at
`C:\Users\Legion-T7\Projects\App-Installer`; everything below the divider is the note written on
the old machine, kept for its reasoning rather than its instructions.

## Where things stand

**Still no git remote.** `git remote -v` is empty, and this session is entirely uncommitted on
`master`. Two commits exist, the newest `3b44e68`. `tests\`, `icons\`, `ui-snapshots\`,
`BRIEF.md`, `HANDOVER.md` and three `tools\*.ps1` are untracked.

**Nothing from this session has been published.** The Worker serves what is in R2:

| | SHA-256 |
|---|---|
| this tree, **stripped for shipping** (478 KB) | `4E5E58F3B1A4C2BADC020A81228451794CC4DC2D2313D858F086AE6FA2BFB556` |
| `APPDEPLOY_SHA256` in `wrangler.toml` | `296EE8E1C5128DB7E1F1959CB714CBE565BE71C8AB940369C37410BD36BE7D38` |

The pin is the hash of the **shipped** bytes, not of `server\AppDeploy.ps1` - comments are
stripped on the way to the bucket - so hashing the source directly proves nothing.

Technicians running the paste line still get the old build. `tools\Publish-Release.ps1` closes
that gap.

## WARNING: office365 is armed again

`office365` carries a real hash (`D351FECB...`), 7.1 MB, **no `silentArgs`**, pointing at
`files/office365/OfficeSetup.exe`. That is the **consumer bootstrapper**, which the previous pass
deliberately disarmed: it has no silent switch, opens its own UI and fetches Office itself, so on
an unattended machine it stalls. As it stands it **would publish on the next Update**. Either
blank its `sha256` again, or replace it with a real ODT package (`setup.exe` +
`configuration.xml` under one key prefix).

The catalog holds **19 apps in 6 categories**. Four carry a real hash and would publish:
`winrar`, `sketchup-pro-2026`, `office365`, `email-migration`. The other fifteen still say
`REPLACE_WITH_REAL_SHA256`, so the edge drops them - deliberate, not a fault.

## What changed in this session

Both windows were reworked to be one tool rather than two that merely resemble each other.

- **One identity.** 1060x700, one rounded panel at radius 11, one header (transparent, 54 tall,
  32px mark), one search box and one tab shape. The client had carried 41 inline colours and no
  named brushes; it now shares the editor's eleven, plus `Good`, `Warn`, `Danger`, `AccentDown`.
- **Pre-flight sheet.** `Install Selected` and `Uninstall Selected` no longer start on the press:
  the list, an X per row, and a disk check against the drive the downloads land on. Nothing in
  the tool checked free space before.
- **Run records.** Every finished batch writes one JSON file to
  `%LOCALAPPDATA%\PC2GoDeploy\runs\` (newest 20 kept). The Activity tab became runs-plus-report:
  counts that filter, failures first with their reasons, Copy / Save / Retry. It never opens
  itself - a failed run badges the tab and waits.
- **The uninstall list became a table.** One column, sortable headings, a size bar per row, the
  program icon, and a footer saying what removing the ticked rows gives back.
- **The editor.** The id is an editable field rather than grey text under the name, and renaming
  it moves `icons\<id>.png` with it. Dark ComboBox and ScrollBar templates - both had been
  rendering with the SYSTEM template, which is white. Placeholder captions cut by ~970 characters.
- **`go.ps1`** grew a splash that appears only if the run is still going after 1.2 seconds. That
  file went from 125 to 240 lines, and it is AMSI-scanned on every run - worth remembering.

Test counts after all of it: `Test-Categories` 228, `Test-GuiBatch` 140, `Test-AfterInstallList`
206, `Test-CatalogScenarios` 54, `Test-CatalogEditorGui` 62, `Test-DeepBatch` 27,
`Test-RealUninstall` 51, `Test-DownloadResilience` 35. `Test-DirtyCleanup` has one pre-existing
failure (`the new folder was observed`) that predates this work.

## Traps found this session

1. **The single-instance mutex and the harnesses collide.** Suites dot-source `AppDeploy.ps1`,
   which takes `Local\PC2GoAppInstaller` and returns early when it is held. The tool cannot be
   open while suites run, and two suites cannot overlap. It does not say so: the guard falls back
   to `Write-Host` into a console the tool has already hidden, so a launched window simply
   vanishes and a harness dies on `The term 'Load-Catalog' is not recognized`. Proven
   deterministically by holding the mutex and running the suite.
2. **WPF binds to properties, never fields.** `SizeBytes` was a public field on `AppItem`, so
   sorting by it silently did nothing on a real machine while passing a test built from
   `PSCustomObject`s. Anything a row binds or sorts on has to be a property.
3. **A `PSCustomObject` cannot carry a `BitmapImage` through a binding** - frozen or not. The
   card rows are a typed class for exactly that reason.
4. **A `ComboBox` styled with setters alone keeps the system template**, which is white whatever
   background is set on it. A window with no `ScrollBar` style inherits the light system one.
5. **A coloured header band with square top corners, painted over a rounded panel, makes a
   rounded window look square.** The header has to be transparent.
6. **`[Math]::Max(1, $someInt64)`** picks the `Int32` overload and throws on a 1 TB drive.
7. **`$ps.Stop()` blocks against a running `Dispatcher.Run()`** - shut the dispatcher down from
   outside, or the bootstrap hangs forever.
8. **`$script:` read inside a closure in `Catalog-Editor.ps1` comes back null.** Capture it in a
   local first, or call a named function - the fifth time this has bitten in that file.

## Next, in order

1. **Create a git remote and push.** Third session running with everything on one disk.
2. Decide on `office365` before any publish.
3. Fix `Export-UiSnapshots.ps1` - it hangs before writing its first PNG, so `ui-snapshots\` is
   stale and still shows the pre-palette windows.
4. Consider `-NoSingleInstance` for the harnesses and a distinct exit code on the guard, so trap
   1 stops costing hours.

---

# Earlier - Handover Ã¢â‚¬â€ 2026-08-22 (second pass)

*(Historical. The format has happened; the paths below are from the old machine.)*


## READ FIRST: this PC is being formatted

Written 2026-08-22, immediately before a wipe. **There is no git remote** - `git remote -v` is
empty, so this repository exists in exactly one place: `C:\Users\Lenovo-G\Desktop\App-Installer`.
Committing does not protect it. It has to leave the machine.

### Copy off the machine, or lose it

| What | Where | Why a commit does not cover it |
|---|---|---|
| The whole repo | `Desktop\App-Installer`, 1.9 MB | no remote exists |
| `tests\` - all nine harnesses | in the repo, **untracked** | never added to git |
| `HANDOVER.md`, `BRIEF.md` | in the repo, **untracked** | never added to git |
| `tools\R2-Upload.ps1`, `Compress-Script.ps1`, `Convert-PackageToZip.ps1` | in the repo, **untracked** | never added to git |
| `tools\.push-state.json` | in the repo, **gitignored** | ignored on purpose - but it is the sidecar everything is re-derived from |
| Claude memory | `%USERPROFILE%\.claude\projects\c--Users-Lenovo-G-Desktop-App-Installer\memory\` | outside the repo entirely |

### Gone for good regardless of backups

**`%LOCALAPPDATA%\PC2Go\r2-credentials.xml`.** DPAPI-encrypted at CurrentUser scope, so the
key IS the Windows account, not the file. A format destroys the key and the blob becomes
undecryptable - backing it up achieves nothing. After the rebuild, re-enter the R2 access key
id and secret from the Cloudflare dashboard and the tool re-encrypts them under the new
account. `R2-Upload.ps1` already fails with a readable message for exactly this case.

### Not worth saving

The staged installers - `Downloads\Winrar.zip`, `Downloads\advik-rediffmail-backup.exe`,
`Downloads\OfficeSetup.exe`, `Documents\Apps\SketchUp Pro 2026.26.1.256.zip`. All four are
already in R2 (their sidecar `remote` blocks say so), so they can be pulled back down. Only the
sidecar itself matters, because it is what remembers they exist.

### First things after the rebuild

1. **Create a git remote and push.** This is the second session running where everything sat
   uncommitted on one disk. A private repo costs nothing and deletes this whole section.
2. `git add` the untracked files above - the test suite in particular has no business being
   outside version control.
3. Restore `tools\.push-state.json`, then re-point `localPath` for whatever you re-download.
   Remember the sidecar outranks the catalog.
4. Re-enter the R2 credentials.
5. Add a Defender exclusion for wherever the tool runs from - script SIZE is what costs 7s on a
   McAfee+Defender client, and an exclusion beats any refactor.

---

## State right now

The catalog now has **19** apps, of which **3** carry a real hash and would publish:
`winrar`, `sketchup-pro-2026`, `email-migration`. The rest have no hash, so the edge drops
them Ã¢â‚¬â€ that is deliberate, not a fault.

**`office365` was parked this session.** It had picked up a real hash and would have gone
live on the next Update, but the file behind it is `OfficeSetup.exe` Ã¢â‚¬â€ the **consumer**
bootstrapper, 7.4 MB, not the Office Deployment Tool. It has no silent switch: it opens its
own UI and fetches Office itself, so on a machine with nobody sitting at it, it stalls. Its
`sha256` is now empty in `server/apps.json`, which makes `Test-App` say "not hashed yet", so
`New-PushPlan` skips it and Publish drops it.

The sidecar was blanked in the same pass Ã¢â‚¬â€ `sha256`, `hashedUtc`, `localPath`, `mtimeUtc` Ã¢â‚¬â€
because the sidecar outranks the catalog and would otherwise re-arm it. `remote` was left
alone on purpose: those bytes really are in R2, and saying otherwise buys a pointless
re-upload. Re-arming it needs a real ODT package (`setup.exe` + `configuration.xml` under one
key prefix), not a re-hash of the bootstrapper.

**The edge was not re-checked this session** Ã¢â‚¬â€ the last verified reading is the one from the
previous pass (tool hash `E6C93E07B12AEFB9Ã¢â‚¬Â¦`, the Worker pin agreeing, 2 apps served).

Nothing is committed. The tree is still on `3b44e68`.

## Shipped and live

- **Downloads over 8 connections** for files Ã¢â€°Â¥100 MB. Measured against the edge, 192 MB, median
  of three: 1 stream 48 MB/s, 4 Ã¢â€ â€™ 78, 8 Ã¢â€ â€™ 92, 16 Ã¢â€ â€™ 97. One connection left half the link unused.
  Falls back to BITS on any doubt, so the worst case is the old behaviour.
- **`.rar` Ã¢â€ â€™ `.zip` conversion, automatic inside Update.** libarchive before 3.6 cannot extract
  many RAR5 archives; a stock Windows 10 client here has 3.5.2 and failed where this machine's
  3.8.4 succeeded in 7 seconds on identical bytes. `.iso` is left alone Ã¢â‚¬â€ it is mounted, never
  read through tar.
- **tar failures name the machine**, not just the archive: stderr is captured, and a `.rar`
  failure says which libarchive is present and to republish as `.zip`.
- **`.rar`/`.iso` are removed by the cache sweep** Ã¢â‚¬â€ they were missing from the list, so the log
  claimed installers were deleted while a 1.1 GB `.rar` stayed.
- **Post-install issue count is honest** Ã¢â‚¬â€ a failure on the *last* step no longer adds
  "remaining steps skipped", which turned one problem into "2 issue(s)".

## Editor, not published (reopen the editor to get it)

- **One button.** `UpdateÃ¢â‚¬Â¦` and `Save catalog`. `Re-publish onlyÃ¢â‚¬Â¦` is gone: Update asks the
  bucket first and skips anything already there, so with nothing to upload the two did identical
  work.
- **A live dot per app** Ã¢â‚¬â€ green when every field matches what the edge serves, amber for
  *not uploaded* / *not published* / *not live*. Compares the **whole entry**, so removing a
  post-install step shows as changed. Refreshes after a publish.
- **Publishing completes when the edge says so**, not when a process handle reports. That is why
  a publish once sat at 0% forever while the catalog had actually gone live.
- **The status line has its own row** under the buttons and wraps Ã¢â‚¬â€ it used to sit on top of them.
- **Reopening an app lists what is in its package** without re-hashing, so the after-install
  *from* dropdown is populated and a file that is not in the package is called out.
- **Duplicate guard**: same bytes under two ids, same name at the same version, or two entries on
  one bucket key. A genuinely different version is fine.
- **Filenames are parsed properly** Ã¢â‚¬â€ `SketchUp Pro 2026.26.1.256.rar` gives name *SketchUp Pro*
  and version *2026.26.1.256*, instead of a name with the version spread through it.
- **A destination with a path inside it is repaired** as you type, and refused at publish.
- **A hashed entry keeps its silent switches and verify path** when its own file is re-fetched.
  They only follow the package when the NAME changes, which is what swapping a product looks like.

## Rebuilt, differently: installer-family detection

The first detector (`Installer-Detect.ps1`, `installer-families.json`, the sniffing inside
`$FetchWork`, the confidence hints, the `VERIFY` gate) was removed on 2026-08-22 because it
sampled 3 MB of a 1.05 GB installer - 0.28% - found no MSI marker, and concluded there was
none. A switch that is nearly right does not fail loudly; the installer opens its GUI on a
machine nobody is sitting at.

The rebuild (2026-08-28) answers the sampling problem by never drawing a conclusion from an
absence. `tools\Installer-Family.ps1` reads only bounded regions (PE section table, version
resource, overlay head 1 MB / tail 64 KB, resource leaves, companion names), and reports a
family **only** on a positive signature at a stated offset - `Confidence` is `signature` or
`none`, evidence is logged, `BytesRead` is asserted under 4 MB by its harness. Unknown means no
switch and the guard stands in. The same source is copied verbatim into `AppDeploy.ps1`
between two marker comments (`tools\Sync-InstallerFamily.ps1` re-splices it; `Publish-Release`
refuses a stale copy), rendered into the elevated worker at `Start-Worker`. Editor: fetch
detects, `silentArgs`/`silentSource`/`installer`/(command-less) `uninstall` are written under
the rule typed-is-never-overwritten, `Use detected` restores. Client: `Install-One` detects when
the catalog has no switch and `silentSource` is not `typed`; `Get-InstalledPrograms` asks
`Get-UninstallFamily` for every non-quiet registry row. Harnesses: `Test-InstallerFamily`
(fixtures via `Get-InstallerFixtures.ps1`), `Test-Push` 11j, `Test-RealUninstall` product D,
`Test-CatalogEditorGui` 2b, `Test-AfterInstallList` 16.

Second pass not built: Squirrel/Velopack, Advanced Installer, Wise, Setup Factory.

## BUILT: the batch strip

Specified in the previous pass, built in this one. The design below is unchanged Ã¢â‚¬â€ it is kept
in full because the reasoning is what stops it being relitigated. What actually shipped, and
where it departs from the spec, is under **"How it came out"** at the end of this section.

### The problem, in two halves

1. Selecting two apps whose names start with A and Y means scrolling up and down to watch both.
   The list is the catalog AND the progress view, and those want opposite layouts.
2. Apps need adding to - or removing from - a batch that has already started. Three queued, then
   a fourth is wanted, or one is no longer wanted.

### What was rejected, and why

- **Filter the list to the batch while it runs.** Solves the scrolling, then hides exactly the
  rows you need in order to ADD a fourth app. The two requirements collide.
- **Pin selected rows to the top.** Solves both symptoms and breaks a third thing: spatial
  memory. People learn a list by position, and reordering on every tick means the fifth click
  lands somewhere other than where it was aimed. Gmail and file managers do not float selected
  rows for this reason.

### What to build

Two surfaces - the pattern Steam, browser download panels and package managers all use.

```
+- APPLICATIONS ---------------- [search] --+
|  ... the catalog, NEVER reorders ...      |
|                                           |
+- BATCH  (3 of 4 done, 1 failed) ----------+
|  x Revit          failed: ...        [x]  |
|  * AutoCAD        installing              |
|  o 3ds Max        queued             [x]  |
+-------------------------------------------+
```

- Catalog stays put. Ticking changes a checkbox and nothing else.
- Batch strip appears when a batch starts, below the list, bounded height, its OWN scrollbar.
  Without the cap and its own scroll, eight selected apps fill the window and the scrolling
  problem comes back wearing a different hat.
- Per-row status and a per-row remove button.
- Failures sort to the top OF THE STRIP once the batch ends. Reordering is fine there - it is a
  status view, nobody navigates it by position.
- The strip PERSISTS after the batch finishes, until dismissed. Snapping back to the catalog at
  completion recreates the problem at the exact moment the results want reading.
- The window already has this shape: the editor's push strip sits in the same position.

### Adding mid-batch is nearly free

The worker does not read a fixed list. It TAILS `queue.jsonl` - reads to the end, sleeps 700ms,
looks again - and only stops at the `{"end":true}` marker, which is not written until every
download is handled. So appending to `$script:Pending` while `$script:DlIndex` has not reached
the end is enough; the download pump picks it up.

Install/Uninstall pressed during a run should ADD to the running batch, and the button should say
so - "Add to batch" - rather than silently meaning something different from its label.

### Removing depends entirely on how far it got

| State | Removable |
|---|---|
| Queued, not downloaded | Yes, free - drop it from `$script:Pending` (mind `$DlIndex` bookkeeping) |
| Downloading now | Yes - cancel the transfer; that path exists and is tested |
| Downloaded, waiting to install | Yes, but needs a signal - see below |
| Installing now | No. Stopping gives a half-install, which is the dirty state cleanup exists for |
| Already installed | No. That is an uninstall, not a removal |

Once an app is in `queue.jsonl` the GUI cannot take it back - the file is append-only and the
worker is a separate elevated process. But the worker ALREADY checks a flag before each entry
(the cancel file, which marks that entry `Cancelled` instead of running it). A per-app skip is
the same shape: a small file of ids, checked at the same point. Reuse that pattern rather than
inventing a second channel.

The boundary to state plainly in the UI: **the moment the installer launches**. Before it,
anything can be pulled out. After it, only stopped and cleaned up.

### Deferred

A search box on the catalog. That - not reordering - is the real answer to "where is Revit" once
the catalog outgrows one screen. Worth it at ~40 apps, not at 19.

### How it came out

All in `server/AppDeploy.ps1`. About +18 KB of source (530,899 Ã¢â€ â€™ 549,403 bytes, +3.5%) Ã¢â‚¬â€ worth
knowing only because script SIZE is what costs 7s on a McAfee+Defender client.

- **The strip is a fourth row in the bottom bar**, above the status line and the buttons and
  below whichever tab panel is showing. `MaxHeight="150"` with its own `ScrollViewer`.
- **The rows ARE the catalog rows** Ã¢â‚¬â€ the same `AppItem` objects, not copies. They already
  raise `PropertyChanged`, so one status update lights up both places and there is no mirror to
  keep in step. `$script:BatchRows` is just a second `ObservableCollection` over the same
  objects.
- **Every batch type gets it**, not only Install: all eight starters (install, uninstall,
  force-remove, tweaks, prefs, firewall, accounts, migrate) open it, because all eight write
  into `$script:Pending` and the strip is a view of `$script:Pending`.
- **A removed row is marked, not spliced out.** The spec said "drop it from `$script:Pending`
  (mind `$DlIndex` bookkeeping)". It is left in place with status `Removed from batch` and the
  download pump steps over it instead. `$DlIndex` counts positions in that array, so removing
  an entry behind the index would silently skip its neighbour Ã¢â‚¬â€ and a row that stays visible,
  saying what happened to it, reads better than one that vanishes.
- **Collapse, not dismiss.** The strip has a header that never moves and never goes away while
  a batch exists. The chevron - or a click anywhere on the header bar - folds it to that one
  line and back. Folded it still reads `BATCH  1 of 8 done, 1 failed, 1 removed, 5 to go`, so
  getting the space back never costs the information. A real `x` appears only once the batch
  has ENDED, when there is no live state left to lose track of.

  This replaced a plain dismiss button, which was wrong, and was caught by somebody using it:
  pressing `x` mid-batch hid the progress view with no way to reopen it. The first fix was a
  "Batch (8)" button appearing elsewhere - a scavenger hunt. The real problem underneath is
  that the catalog and the strip have OPPOSITE duty cycles: during a two-hour download the
  catalog is dead weight and the strip is the only thing being read; between batches it is the
  other way round. Fold answers that, dismiss did not. Compare `1b-batch-strip.png` against
  `1c-batch-strip-folded.png` - folded, the catalog gets back two whole category groups.
- **`Removed` is its own outcome**, not folded into Cancelled or Failed. It is reported
  separately in the batch summary ("2 completed, 0 failed, 1 removed"), and `Abort-Batch` and
  Cancel both leave it alone rather than overwriting it with a failure nobody caused.
- **A press is acknowledged; the outcome waits for whoever owns it.** Pressing remove on a row
  this GUI still owns (queued, or downloading) settles immediately: `Removed from batch`. On a
  row already written into `queue.jsonl` it does NOT - it says `Removing - waiting for the
  installer to skip it`, and the worker's own report turns that into `Removed`. The worker reads
  `skip.txt` only just before it acts on an entry, so if it had already started this one the skip
  is never seen and the install completes. Claiming `Removed` there would assert an outcome that
  can be false a few hundred milliseconds later, on the one screen a technician trusts. Cancel
  already worked this way (`Cancelling - waiting for the current install to finish...`); this is
  the same pattern.
- **Downloads say how much LONGER.** `Format-Eta` turns the rolling speed sample and the
  catalog's size into `3m 12s left`, on both the BITS and the multi-connection paths, on the row
  and on the status line. It returns BLANK rather than a guess when there is no speed sample yet
  or the rate would put the estimate past a day - `14h left` that becomes `3m left` ten seconds
  later is worse than nothing. Installs still get a spinner: a vendor installer offers no
  denominator, and inventing one would be the same lie in a different place.
- **`skip.txt`**, one id per line, beside `cancel.flag` in the cache. The worker takes it as
  `-SkipFile` and re-reads it before every entry, at the same point it checks the cancel flag.
  Re-read rather than cached, because the GUI appends to it long after the worker started Ã¢â‚¬â€
  which is the whole point of it being a file.
- **`$script:BatchLive`**, not `$script:Phase`, decides whether a row can still be pulled out.
  Every starter opens the strip on the line BEFORE it sets `Phase`, so reading `Phase` there
  said "no batch running" and painted every row without its remove button until the first tick,
  400ms later. The test caught this; the flag fixed it.
- **`Test-Removable` is a whitelist**, not a blacklist: blank, `Queued*`, `Starting download`,
  `Downloading*`, `Retrying*`, `Link expired*`. Any state it does not recognise hides the
  button. The worker reports a lot of intermediate states and more will be added; an
  unrecognised one has to fail towards "you cannot remove that" rather than towards a removal
  that arrives after the installer has launched.
- **The button now says what it does.** `Install Selected` Ã¢â€ â€™ `Add to Batch` while downloads are
  running (a press really does extend the batch on screen) Ã¢â€ â€™ `Queue Next Batch` once the worker
  has been told no more are coming, because from there the same press starts a follow-up batch
  with its own UAC prompt.

**The cancel hole is closed too.** A removal during a segmented download returns out of the
pump's `catch` instead of retrying on BITS Ã¢â‚¬â€ and so does a **cancel**, which used to fall
straight through it. That mattered more: by the time the `catch` runs, the Cancel handler has
already pushed `$DlIndex` past the end and moved `Phase` to `Install`, so a BITS job started
there is never looked at again Ã¢â‚¬â€ it sits in `$script:CurJob` transferring a file the batch has
written off, and the Download branch is never re-entered to clean it up.

It was first written off as blocked by `Test-DownloadResilience`. That was wrong: section 7
calls `Invoke-SegmentedDownload` **directly** and asserts what the function does Ã¢â‚¬â€ it never
touches the pump's fallback decision. Nothing was in the way. Locked now by a new assertion in
Test-GuiBatch section 2: `no download job outlived the cancel`.

### The deep-clean list: asked and answered

It does **not** have the same shape, so it did not need solving twice.

The leftover review is `WipeOverlay` Ã¢â‚¬â€ a modal, 620 wide, `MaxHeight="520"`, with its own
`ScrollViewer` and rows grouped under the app that owns them. It is already bounded and
already self-scrolling: the same answer the strip arrives at, reached earlier by a different
route. And it is a **review-then-approve** surface, not a progress view Ã¢â‚¬â€ read once, ticked,
dismissed. Nothing about it doubles as the catalog, which is the actual collision the strip
exists to solve.

What it did get for free: while the wipe runs, progress is reported onto the app rows
(`Set-Status $item 'Cleaning leftovers'`), and those rows are exactly what the strip shows. So
the deep-clean phase of an uninstall batch now has a compact progress view it did not have
before, without a line written for it.

## Next, in order

1. **Finish what the fold change started.** Two loose ends, both known:
   - `Test-GuiBatch` has NO coverage of fold/unfold or of the after-the-batch close. The
     attempt to add it was written against the old dismiss button and never landed.
   - The full suite has not been re-run since the fold change, the two-stage removal, or the
     countdown. Only `Test-GuiBatch` (65/65) and `Test-DownloadResilience` (35/0) were.
2. **Decide the tick question.** After Install is pressed the rows stay ticked, so a row IN the
   batch looks identical to one merely selected - tick a ninth app and nothing says it is not
   running. Proposal, NOT agreed: clear the ticks when a batch starts, so a tick means one
   thing only - "staged, not submitted". Ask before building it.
3. **Decide the strip height.** `tools\Export-UiSnapshots.ps1` now renders it Ã¢â‚¬â€ a new
   `1b-batch-strip.png` with one row in every state the strip can show, against the real
   19-app catalog. It reads correctly: the header counts, the colours match the catalog rows,
   and the remove button appears on exactly the one row that is still removable (mid-download)
   and on none of Failed / Installed / Installing / Removed. The open question is the cap:
   rows are ~27px, so `MaxHeight="150"` shows about **five** before it scrolls. If a normal
   batch here is six to eight, ~200 is the better number. Nobody has run a real batch against
   it yet, which is the only way to answer that.
4. **`sketchup-pro-2026` has an empty `silentArgs`** and is live. It will open a GUI and be
   stopped by the guard. Its installer is InstallScript with no embedded MSI (measured), so it
   needs a `setup.iss` recorded on a VM.
5. **Measure the download on the Kuwait client** Ã¢â‚¬â€ 1.92Ãƒâ€” here, and the gain grows with latency.
   If it is 4Ãƒâ€” there, that work is the most valuable thing in the project; if it is 1.2Ãƒâ€”, say so
   and stop.
6. **16 of the 19 apps have no file on this machine**, so nothing can be confirmed about them.
   Only `winrar`, `sketchup-pro-2026` and `email-migration` have bytes here. `office365` joined
   the sixteen this session, on purpose - see the top of this document.

## Traps that still bite

- **A helper called from a lifted function must be lifted with it.** `Test-DownloadResilience`
  does not dot-source the head - it pulls `Invoke-SegmentedDownload`, `Format-Size` and
  `Format-Eta` out by AST and stubs the GUI calls. Adding a call to anything else inside that
  function throws `CommandNotFoundException` from inside the download loop. It nearly slipped
  through: the speed sample only fires after a full second, so a fast local transfer never
  reaches the line and the harness stays green while a real download on a slow link is the only
  thing that breaks. The lift list is now an exact-count check that names what is missing.
- **A harness failing at "this instance holds the single-instance lock" is not a code failure,
  and it happens often.** Three times in one session, on `Test-GuiBatch` twice and on
  `Export-UiSnapshots` once Ã¢â‚¬â€ every time, a plain re-run passed and the mutex probed free
  afterwards. Something transient grabs `Local\PC2GoAppInstaller`; AppDeploy `return`s at that
  check rather than exiting, so the caller carries on and every later assertion fails against a
  `$null` window, which reads exactly like the change under test having broken everything. Any
  harness that dot-sources the head should assert `$script:HaveMutex` and BAIL rather than
  keep going - `Test-GuiBatch` already asserts it, it just does not stop.
- **The sidecar outranks the catalog.** `tools\.push-state.json` is what the editor
  re-derives `url`, `sha256` and `sizeBytes` from. Editing `apps.json` by hand and leaving the sidecar
  pointing at the old file means the next save silently undoes the edit. This happened twice.
- A leftover instance holds the `Local\PC2GoAppInstaller` mutex, so the next launch says
  "already running" and exits.
- `go.ps1` is never cached and `AppDeploy.ps1` re-downloads when the pin changes Ã¢â‚¬â€ judge launch
  speed on the **second** run.
- `Test-GuiBatch`, `Test-DeepBatch` and `Test-Push`'s installer-guard assertion are
  timing-sensitive. Run them when the machine is not busy; a failure there is usually load.
- The elevated worker is a here-string, so parsing `AppDeploy.ps1` finds none of the install
  functions. Lift the string first.
- `Set-Content -Encoding UTF8` writes a BOM in PS 5.1, and a BOM on `apps.json` makes the client
  read an empty catalog. Always `WriteAllText` + `UTF8Encoding($false)`.

## Tests

All green, every harness re-run in full after the strip went in.

| Harness | Result |
|---|---|
| Test-AfterInstallList | 207/207 |
| Test-Push | 273 / 0 |
| Test-CatalogEditorGui | 59/59 |
| Test-CatalogScenarios | 54/54 |
| Test-DirtyCleanup | 83 / 0 |
| Test-DeepBatch | 27/27 |
| Test-GuiBatch | **65/65** (was 33) - no fold coverage yet |
| Test-DownloadResilience | **35 / 0** (was 28) |

`Test-GuiBatch` section 1b is new, and is where the strip is proved:

- the removability boundary as a table Ã¢â‚¬â€ eight states checked against `Test-Removable`
  directly, rather than inferred from what happens to be on screen;
- the strip appearing with the batch, holding one row per app, holding the SAME objects as the
  catalog, and the catalog not reordering underneath it;
- a queued app pulled out through the **real routed handler** Ã¢â‚¬â€ a `Click` raised on `ListBatch`
  carrying the row in `Tag`, which is exactly what the on-screen button does. The window is
  never shown here, so there is no button object to find;
- its id landing in `skip.txt`, the row staying visible rather than vanishing, the batch still
  completing, the other two still installing, and Ã¢â‚¬â€ the real proof Ã¢â‚¬â€ the removed app never
  appearing in `queue.jsonl` at all;
- a removal reported as removed rather than failed, and sorted above the rows that worked.

`Test-DownloadResilience` sections 6Ã¢â‚¬â€œ8 are new: eight connections rebuilding one file
byte-identically, resume from a half-written journal, a stale journal being discarded, Stop
mid-download, and everything it refuses so BITS can take over.

**Still never run:** `Test-Push -Live` against real R2. It is the only thing that settles
whether R2 accepts `UNSIGNED-PAYLOAD` and whether a part ETag really is the MD5.
