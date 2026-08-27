# PC2Go App Installer

A portable remote-deployment tool for Windows. A technician on a remote session runs one
line, gets a dark native GUI, ticks the applications a client needs, and the tool downloads,
silently installs, verifies and cleans up after itself. It also removes software — including
the leftovers a normal uninstaller abandons.

Delivered the same way as `irm https://christitus.com/win | iex`: nothing to install, no
runtime to ship, no permanent footprint. PowerShell 5.1 + WPF, both already inside Windows.

---

## Technician usage

Universal line — works pasted into **cmd**, **Windows PowerShell 5.1**, **PowerShell 7**, or
the Win+R Run dialog:

```
powershell -NoP -EP Bypass -C "irm https://apps.pc2go.ca/go | iex"
```

Shorthand from a PowerShell window:

```powershell
irm https://apps.pc2go.ca/go | iex
```

It asks for the **access code** first - masked, three tries - and the GUI then launches detached,
so the console it was typed into can be closed immediately. The code gates `/AppDeploy.ps1` and
`/apps.json` at the edge; `/go` itself stays open, because the bootstrap is useless without what
it fetches. See "Access code" below for how to set or rotate it.

**If it takes a moment, it says so.** Between that line and the window there is a hash of 545 KB,
possibly a 545 KB download, and PowerShell loading and antivirus scanning that file before one
line of it runs. On a healthy machine that is under half a second and you see nothing. On a
client running a second antivirus alongside Defender it has measured **eight seconds** of script
scanning, which from the outside is indistinguishable from a hang - so the line gets pasted a
second time and everything is paid for twice.

`go.ps1` shows a small splash from the moment the access code is accepted until the tool's own
window is on screen, and it is shown **directly** rather than on a timer - an event cannot fire
while the same thread is inside a blocking download, which is why the earlier timer-based splash
never appeared at all. It comes down once `MainWindowHandle` is non-zero (the WPF window does not
claim one until it actually shows) plus a short linger, and a `finally` block takes it down even
if the technician presses Ctrl+C at the code prompt.

**Only one copy runs at a time.** Every instance shares one download queue in `%LOCALAPPDATA%`,
and the elevated worker reads it as a stream — so two copies mean two workers taking each
other's items, colliding on the same install (which fails it with *"installer exit code 1"*)
and never reaching the end marker, leaving a batch that cannot finish. A second launch is
refused with *"already running"* instead. This is measured behaviour, not a precaution: the GUI
harness reproduced it before the guard existed.

### Local testing (no server)

```powershell
powershell -NoP -EP Bypass -File "server\AppDeploy.ps1" -BaseUrl "file:///C:/Users/Legion-T7/Projects/App-Installer/server"
```

The title bar shows a build number. If you are unsure whether an edit took effect, check it —
old windows stack up and this saves chasing ghosts.

---

## How it works

```
go.ps1  (bootstrap, ~1 KB)      AppDeploy.ps1  (the tool)          worker.ps1  (elevated)
─ forces TLS 1.2+               ─ WPF GUI, four tabs               ─ ONE UAC prompt per batch
─ requires PowerShell 5.1       ─ fetches apps.json catalog        ─ consumes a streaming queue:
─ downloads AppDeploy.ps1       ─ BITS downloads, resumable        ​  installs app N while the GUI
─ verifies its SHA-256 pin        across drops AND reboots         ​  downloads app N+1
─ launches it hidden            ─ streams live status              ─ re-verifies SHA-256 inside the
                                                                   ​  elevated context before running
                                                                   ─ silent install + verification
                                                                   ─ uninstall + deep clean
                                                                   ─ system tweaks
```

The GUI never runs elevated. One elevated worker starts the moment the **first** download
finishes and handles the whole batch, so there is exactly one UAC prompt and it appears
early rather than after 30 GB of downloading.

### Install flow

1. Select apps (grouped by section, live search across all tabs)
2. **Install Selected** → the **pre-flight sheet**: what you picked, what it weighs, and whether
   it fits (see below) → **Install N** → downloads begin
3. First download completes → **single UAC prompt** → installs begin
4. Downloads and installs overlap: app 2 downloads while app 1 installs
5. Each app: SHA-256 verified in the elevated context → silent install → exit code checked
   (3010 = success, reboot required) → verify paths confirmed
6. Summary; installers deleted; cache folder self-deletes on close

**Live controls during a batch:** Pause/Resume (suspends the BITS transfer, keeps bytes),
Cancel (stops downloads immediately; a *running installer is never killed* — that corrupts
installs — it finishes, everything queued after it is cancelled), and **Add to Queue**, which
lets you add an app mid-batch without cancelling. Adding after all downloads have finished
queues a follow-up batch that starts automatically, at the cost of one extra UAC prompt.

**Indicators:** per-app progress ring (App Store style) that fills while downloading, spins
during install, then becomes a green check / red cross / amber warning badge. Plus per-app
percentage and speed, overall percentage, and a live stage line at the bottom.

**Pre-flight.** `Install Selected` and `Uninstall Selected` used to start on the press — no list,
no confirmation, and no check that what you picked would fit. There was no free-space check
anywhere in the tool, so a 13.5 GB selection on a laptop with 8 GB free downloaded for twenty
minutes and then failed inside an installer, which is the worst place to find out.

The sheet lists exactly what is about to happen, with an **✕ on every row** — taking one out
unticks it in the catalog too, or the next press would put it straight back. Underneath, the
drive the downloads actually land on (`%LOCALAPPDATA%\PC2GoDeploy`, which is not always `C:`),
what is already used, and what this run wants on top. Over half the free space warns; more than
the free space says how much short it is.

It does **not** block. The button stays live even when the disk says no, because a catalogued
size can be stale and the technician standing at the machine knows things this does not. What it
will not do is let that happen silently. `Force Remove` keeps its own separate wording — it is a
different, and worse, thing to agree to.

### Dependencies (`requires`)

An add-on names the ids it needs (`autocad-electrical` requires `autocad`; `corona` and
`floorgenerator` require `3dsmax`), and the pre-flight sheet — the one screen between picking
and committing — is where that knowledge acts:

- **Base missing entirely** (not installed, not in the batch): the sheet refuses in red and
  offers a one-click "Add AutoCAD 2026 (4.5 GB)" that ticks the base into the batch ahead of
  the add-on. An id the catalog does not know **fails open** with a log line — a fact we cannot
  obtain is never the reason a batch will not start.
- **Both selected**: bases are sorted ahead of their add-ons automatically, so the old
  catalog-order folklore is now a rule.
- **Installing a BASE while a dependent add-on is already on the machine**: the sheet offers —
  ticked by default — the clean sequence: remove the add-on, install the base, download the
  add-on again and put it back. One batch, one UAC prompt; the removal is queued to the same
  worker but nothing is removed until the base's download has actually landed. A failed removal
  skips the base *and* the reinstall; a failed base install still restores the add-on. Deep
  clean is deliberately skipped for that removal — its `%AppData%` config is exactly what the
  reinstall must inherit. Untick the box and the base installs as-is, exactly as before.

### What a run leaves behind

A finished batch used to leave **nothing you could read**. The per-app outcomes existed — the
batch strip shows them well — but they live in a collection that is cleared the moment the next
batch starts, and the only durable trace was the Activity log: one `RichTextBox` that every
message is appended to. After twenty applications that is a wall of interleaved lines, and
finding which two failed means reading all of it.

Every batch now writes one small JSON file to `%LOCALAPPDATA%\PC2GoDeploy\runs\`. The newest
twenty are kept. Nothing else in the tool reads them — they exist to be read by a person.

The **Activity** tab is where you read them: runs down the left, newest first, with the live log
as the first entry so the tab still opens on what it always showed. Pick a run and you get the
report — the counts (`20 in this run · 17 succeeded · 2 failed · 1 with warnings`), which double
as a filter, and the list underneath with **failures sorted to the top**, each carrying its
reason rather than just a red state. Then **Copy report**, **Save report…**, and **Retry N
failed**, which re-ticks the failures and opens the same pre-flight sheet any other install goes
through — it does not start anything behind your back.

**It never opens itself.** A finished run with failures puts a count on the Activity tab and
waits there until you go and look; opening it clears the badge.

### Uninstall flow

**It is a table.** Eighty programs in a two-column grid of cards cannot answer the question this
tab is opened for — nobody comes here looking for things beginning with A. They come to find what
is **big** and what is **junk**, and the size and publisher were already on every row without
being sortable by either.

So the list is one column of aligned cells under a header that sorts: **PROGRAM**, **PUBLISHER**,
**INSTALLED**, **SIZE**. Press a heading to sort by it, press it again to turn it round. Under
each name is a bar showing that program's size as a share of the largest thing on the machine —
the number is already in the column beside it; the bar is for telling a 40 GB repack from a 90 MB
utility at a glance. The biggest one is tagged **largest**.

Each row keeps the program's own logo, pulled out of its executable by the icon pump. The footer
says what is listed, what is ticked, and what removing it would give back — *80 programs | 1
selected (40.9 GB reclaimed)*.

Two honest limits. Sizes come from the registry's `EstimatedSize`, which plenty of installers
never write, and `InstallDate` is missing just as often — a program with no date sorts **last**
under *Installed* and is never counted as recent, because unknown is not the same as new.

The Uninstall tab lists **everything installed on the machine**, discovered the way Wise
Program Uninstaller does, in two sub-tabs scanned lazily on first visit:

| Sub-tab | Source | Notes |
|---|---|---|
| Desktop programs | Registry uninstall keys (`HKLM`, `WOW6432Node`, `HKCU`) | The same list Control Panel shows |
| Microsoft Store apps | `Get-AppxPackage` | Never appear in Control Panel, only in Settings |

The list is the machine's real inventory only — there is no separate section for our own
catalog. Where a catalog entry matches an installed program by name, that program's own row
quietly upgrades to the curated vendor uninstaller and cleanup targets, because Autodesk
ODIS and Adobe APRemover remove far more cleanly than a generic uninstall command. Same
row, better removal, no duplicate listing.

Removal method, best first: catalog vendor uninstaller → `QuietUninstallString` → MSI
rewritten to `msiexec /x {GUID} /qn /norestart` → raw uninstall string (row is labelled
"Shows installer UI" so nobody is surprised by a window). Store packages use
`Remove-AppxPackage -AllUsers` **plus the provisioned copy**, so the app does not reappear
for newly created user profiles.

**Force Remove** skips the vendor uninstaller entirely and wipes the app directly — the only
option when the uninstaller is missing, corrupt, or the app is already half-removed. It
confirms first, and you still review everything before deletion.

### Deep clean

Not optional, and not a checkbox — removing every trace is the reason this exists over
Control Panel. After the uninstaller runs, the tool scans for survivors and shows you the
kill list before deleting anything.

It sweeps app data under **every user profile** (not just the technician's — a folder left in
someone else's profile is the classic "it came back"), `ProgramData`, both `Program Files`, the
temp directories, Start Menu and Desktop shortcuts, registry keys beyond the app's own,
services, scheduled tasks, `hosts` lines, and **autostart entries**. That last one is a registry
*value* under `Run`/`RunOnce`, not a sub-key, so a scan that walks keys alone goes straight past
it and the product keeps launching itself at every login, pointing at an executable that is no
longer there. Only the value is removed, never the `Run` key — it holds every other product's
autostart entry too.

It also runs after a **failed install**. Every installer exit code is judged on one
question — was the machine left dirty? — and 1602, 1603, an unknown code, or an installer
that exits 0 without producing its `verifyPaths` all mean files are already on disk. Those
rows go into the same leftover scan the moment the rest of the batch has reported, inside
the same elevated session, so a broken install is rolled back under the one UAC prompt
instead of being left for a second trip through the Uninstall tab. 1223 (UAC declined) does
not qualify: nothing ran, so there is nothing to clean.

Two things it will not do. Wiping the debris never turns the row green — the install still
failed and is still counted as a failure. And if the product was **already on disk before
the batch started**, nothing is pre-ticked: a failed upgrade leaves the previous working
copy under exactly the paths the catalog names as cleanup targets, so that list is offered
for review rather than checked for you.

**Where the product actually went** is observed, not guessed. Before the installer runs the
worker records the top-level directories under `%ProgramFiles%`, `%ProgramFiles(x86)%`,
`%ProgramData%`, `%LocalAppData%` and `%AppData%`, and compares afterwards. Whatever appeared
is reported alongside the verdict and logged as *"installed into: ..."*.

`FileSystemWatcher` was rejected for this: an installer writing tens of thousands of files
overruns its buffer and events are dropped **silently**, so the record would be quietly
incomplete - worse than none, because it would still be trusted. A directory snapshot cannot
drop anything.

Those folders are pre-ticked in the kill list **whatever the pre-existing rule says**. That
rule protects a folder that might belong to the previous install; a folder that appeared
during this batch cannot be. It is the difference between a name match and a fact.

The limit is worth stating plainly: a snapshot can undo a *creation*, never an *overwrite* -
it never saw what the file used to contain. Only a System Restore point covers that.

**What it scans**

- Install folder, `%AppData%`, `%LocalAppData%`, `LocalLow`, `%ProgramData%`, `Public\Documents`,
  `Public\Desktop`, Documents, `%WinDir%\Temp` — **across every user profile on the machine**,
  not just the technician's
- Loose temp *files* matching the app, not only folders
- Folders left behind empty (tagged `EMPTY`)
- Start Menu and Desktop shortcuts
- Registry: the app's own key, `App Paths`, `Run`/`RunOnce` in all hives, and name-matched
  keys under `HKLM\SOFTWARE`, `WOW6432Node`, `HKCU\SOFTWARE`
- Services and scheduled tasks (stopped and deleted)
- **hosts file entries** matching the vendor's domains — leftover activation blocks are
  invisible to every normal uninstaller and will break a later clean reinstall

**Locked files** escalate through five stages rather than demanding a reboot: plain delete →
clear read-only/hidden/system attributes → **Restart Manager API** to identify and kill
whatever holds the handle (the same mechanism behind an installer's "close these
applications" prompt — it sees DLLs loaded into unrelated processes, and restarts Explorer
when a shell extension is the culprit) → `takeown` + `icacls` for Access Denied → schedule
for deletion at next boot via `MoveFileEx`. Results distinguish the outcomes:
*"47 traces removed, 2 scheduled for next restart"*.

### Vendor removal tools (removers)

Some products cannot be removed cleanly by their registry uninstall string: Autodesk's
licensing service has its own uninstaller hidden under `Common Files\Autodesk Shared`, and
antivirus products need the vendor's dedicated remover (avastclear). The catalog carries these
as `cleanup.removers`, and the leftover preview offers each one as a **REMOVER** row — never
pre-ticked, because ticking one *executes* it. Two routes, both verified before anything runs:
an exe already on the machine must live under a Program Files root (admin-writable only, so a
tampered queue cannot point the elevated worker at a planted file), and a fetched one travels
with a pinned SHA-256 the worker checks first — the same gate every installer passes. The
preview also grew **Select all / Clear all** (suite-shared components and hidden name-only
guesses are excluded from bulk-tick), name-only matches on short tokens are graded, dimmed and
folded behind a "Show N possible matches" toggle, and the scan itself now runs off-thread —
the window stays live and Cancel stops it, showing what was found so far.

### Optimize

A winutil-style tab, **three sub-tabs** on the same pill pattern the Uninstall tab uses. The
lists are **built into the tool**, not fetched — they work with no server and cannot be changed
by whoever controls the catalog host. Everything is applied by the same elevated worker, so a
whole batch is one UAC prompt.

| Sub-tab | Rows | What they are |
|---|---|---|
| **Tweaks** | 47 (42 pre-ticked, 5 **CAUTION**) | Configuration only. Reversible policy and registry changes, plus removals |
| **Cleanup** | 5 (4 pre-ticked, 1 **CAUTION**) | One-time disk actions. Each reports the space it reclaimed. No Undo — they are events, not states |
| **Gaming** | 14 (10 pre-ticked, 4 **CAUTION**) | The gaming-customer persona: scheduling, power, NVIDIA driver profile, NIC tuning |

Each sub-tab has **its own Apply**, and **every toolbar button acts on the sub-tab on screen
only** — Select All, Clear All, Reset, Detect Applied, and Gaming's Measure. Nothing you cannot
see ever runs. Rows carry no icon and no size column, so roughly twice as many fit on screen; a
3px accent bar (blue standard, amber CAUTION) is all that remains.

**Reset, not Clear.** Reset returns the default selection — everything ticked except CAUTION —
rather than unticking everything, because an empty list reads as "turn all of these off". It
stays visible beside Detect on purpose: Detect's contract is *"tick what is already applied"*,
which can legitimately empty a list, and Reset is the way back.

**There is no Preferences tab, and it is not coming back.** It held toggles that mirrored the
machine — and **a tick there meant "this is how the machine already is", while a tick in Tweaks
means "I will apply this"**: the same control with opposite meanings. That is how an unticked
preference once silently left-aligned a taskbar nobody asked it to move. Four rows were promoted
into Tweaks (Lock Screen, Logon Verbose Mode, Mouse Acceleration, Settings Home Page); the rest
were dropped. **Window Snapping was dropped rather than promoted because its target value IS the
Windows default** — as a tweak it would have been a row that changes nothing on a healthy
machine, and no Tweaks row is allowed to be that.

**Check before apply.** Every selected row is probed first. Anything already in place reports
*"Already applied - skipped"* and is never queued; a batch where nothing is left to do also
skips the restore point.

**Detect Applied** reads the machine and ticks what is already in place, so you can see a
client's current state before changing anything. It runs unelevated (no UAC): `HKLM` and service
state read fine without admin, and `HKCU` in the GUI is the technician's own hive, which is
exactly the profile the per-user tweaks target. Rows that are *actions* rather than states —
Disk Cleanup, Temporary Files, Restore Point — are never reported as applied.

**Undo Selected** reverts the ticked tweaks. Detect → Undo is the natural pair for cleaning up a
machine someone else debloated. Undo restores the **documented Windows default** rather than
replaying a saved snapshot: keeping a state file would leave exactly the permanent footprint
this tool promises not to. For policy values that is exact — the value is deleted and Windows
reverts on its own. Anything that deleted files or removed an app cannot be put back, and the
confirm dialog names those before you commit; the row then reports e.g. *"sync policy lifted -
OneDrive is NOT reinstalled"*. Cleanup has no Undo at all, for the same reason it has no
detector.

#### The tool checks its own work

`Applied` used to mean *"the registry write did not throw"*. It now means the machine agrees:

- A value this build of Windows **refuses** is not counted as written. The row says so and names
  it: *"(this Windows build refused: TaskbarDa)"*.
- After every batch, each row that reported `Applied` is **re-read through its own detector**
  before the totals are counted. Disagreement becomes *"Applied - could not confirm on this
  machine"* plus a log line naming every row.
- Rows with no detector — restore points, cleanup — make no claim either way. Silence is the
  honest answer for an event.

**A written value is not a visible one.** Explorer caches, and nothing re-reads until it is
told, so a batch that changed the theme or Explorer's own settings broadcasts
`WM_SETTINGCHANGE` once at the end (capped at 100 ms with `SMTO_ABORTIFHUNG`, so one wedged
window cannot stall the tool).

**Windows 11 25H2 relocated several settings**, and the values documented everywhere else are
now dead ends marked `Migrated=1`. Explorer privacy moved up out of `Advanced`; Start's recent
and frequent lists moved to `Explorer\Start`; the taskbar Resume badge and Start's
recommendations are new keys entirely; Home and Gallery are unpinned through their shell CLSIDs
rather than a policy. All five were found by diffing the registry while toggling the real
Settings UI, not from documentation.

Two rules make this safe to hand to a technician:

**Restore Point runs first.** If "Restore Point - Create" is ticked it is queued ahead of
everything else — after the other tweaks have run it would be worthless. The CAUTION dialog says
out loud whether a restore point is selected, so nobody applies twenty system changes with no
way back by accident. A point created in the last 24 hours counts as done, so a second run in
the same session does not stack another one.

**Per-user tweaks land in the right hive.** The worker runs elevated, and if the technician
elevated with a *different* admin account, `HKCU` inside it is that admin's hive, not the
client's — the classic reason a tweak "applies successfully" and changes nothing the user can
see. The GUI passes its own SID and the worker writes those values to `HKEY_USERS\<sid>`.

The service tweak sets services to **Manual**, never Disabled (a disabled service something
genuinely needs fails hard; Manual still allows a trigger start), and the list deliberately
excludes BITS — this tool downloads through it — along with the core OS services.

**Gaming** is evidence-ported rather than copied: NVIDIA Low Latency Ultra and Max Prerendered
Frames are written through the NVAPI driver profile database (the `.reg` guides that circulate
do nothing), power values are written with `powercfg` but **read back from the registry**
because `powercfg /query` hides `Attributes=1` settings like core parking, and **Measure** is a
read-only before/after latency probe with a warmup round and a double gate so it never
manufactures a verdict. Apply Gaming un-ticks "Xbox and Gaming - Remove" and says so — a gamer
keeps Game Pass — but it does **not** un-tick Game DVR, because DVR off is a measured FPS win.

Honest limits, reported in the row rather than hidden: `BitLocker - Disable` blocks *automatic
device encryption* and reports any already-encrypted volumes rather than silently decrypting
them, which would be hours of disk I/O on a client machine. `Microsoft Edge - Debloat` applies
policy only; Windows Update can still restore what it changes. And **removed apps come back on
their own** — a machine here had Xbox Game Bar and the Gaming App reinstalled by Windows Update
hours after removal, which wiped the gaming settings with them. **Nothing in the tool prevents
that.** A Store opt-out row was built for it and then removed on request, because the only
switch that works stops *every* Store update - including the codecs and WebView2 a customer's own
software depends on. Deprovisioning is correct; the Store update channel is simply out of reach.


### Toolbox

Repair actions and shortcuts, in three groups plus the legacy Windows panels.

| Group | Rows |
|---|---|
| **Fixes** | AutoLogon, Multiplane Overlay - Disable, Network - Reset, S3 Sleep - Force, NTP Server - Enable, System Corruption Scan (sfc + DISM), Windows Update - Reset, WinGet - Reinstall |
| **Remote Access** | OpenSSH Server - Enable (installs sshd, starts it, opens port 22) |
| **Diagnostics** | Slow PC - Diagnose |

Fixes run elevated through the same one-UAC queue as everything else. The **panels** are just
shortcuts, launched unelevated straight from the GUI — Windows elevates them itself if they need
it, and routing them through the worker would cost a pointless UAC prompt.

Each row's hint says what it costs, not just what it does: Multiplane Overlay fixes GPU flicker
on some panels but *costs* performance on healthy ones, so it is a symptom fix rather than a
default; S3 Sleep is hardware-dependent and can break wake.

#### Slow PC - Diagnose

Seven layers, **read in order**, about five seconds, and it **changes nothing at all**. It runs
in the elevated worker because SMART, service paths and the event log need admin. Each layer
prints its own `VERDICT L<n>` line into the Activity log, and the full report is written to the
cache folder as `slowpc-<timestamp>.txt` — UTF-8, so it survives being pasted to a client.

| Layer | Question |
|---|---|
| **L0** | Is it hardware-doomed? Disk type, RAM, free space, SMART wear and read errors, CPU class |
| **L1** | Is something eating the machine right now? Cumulative **CPU-seconds**, not percent |
| **L2** | Is it security software? Two AV products fighting is the classic |
| **L3** | Memory pressure — compression *and* low available memory together |
| **L4** | Background work — servicing, indexing, a pending reboot, uptime |
| **L5** | Startup and persistence — OEM updaters, trials, "cleaner/booster" software |
| **L6** | Faults and throttling — disk and WHEA errors, clock pinned below max, power plan |

The order is the point: each layer decides whether the next is worth doing, so the top finding
is the one to act on.

**Cumulative CPU-seconds, not percent**, is what makes L1 work — Task Manager's percentage hides
a scanner sitting at 8% forever, while CPU-seconds since boot exposes it immediately.

Two things it deliberately does *not* do. It never proposes a fix, because the verdicts are not
yet wired to the rows that would apply them. And it is **strict on purpose**: L1 only fires when
a third-party process beats `explorer` and `dwm` combined, which will miss a moderate hog on a
busy workstation. Ranking by an absolute number instead would fire on every healthy machine, so
the evidence always names the top third-party consumer *and* the number it had to beat, and the
judgement stays with the technician.

Calibrated against a healthy machine before shipping — three false positives on the first run
(Windows' own `svchost`, memory compression with plenty free, and Squirrel apps launching via
`Update.exe`) were each fixed by a rule rather than a name list — and then proved it can still
fire: 10 of 10 real PUP and OEM names flagged, 10 of 10 legitimate startup entries clean.

---

## Users — broken-profile repair

The standard fix for a corrupt Windows profile: stand up a clean local admin and move the
user's data into it. Three columns — **Copy FROM** (profiles on disk), **Copy TO** (local
accounts), **what to copy** — plus a create-account form above them.

**Create Admin Account** makes a local account that is a member of Administrators (resolved
by the well-known SID `S-1-5-32-544`, so it works on non-English Windows), with no password
that never expires. It then builds the profile immediately via the `CreateProfile` API — the
same call Windows makes on first sign-in — so `C:\Users\<name>` exists with correct ACLs and
a fresh `NTUSER.DAT` and you can copy data in **without signing into the new account first**.
Creating that folder by hand instead produces a directory the user cannot actually use.

Two rules make this safe on a client machine:

**Nothing is moved or deleted.** Files are copied with `robocopy /E /COPY:DAT /XJ`, then
verified by comparing file counts on both sides. The broken profile is left exactly where it
was, so a failed run costs disk space and never data. The tool measures the selection and
refuses if the drive cannot hold both copies.

**AppData is not migrated by default.** A profile is usually broken *because* of something in
`AppData` — a damaged `NTUSER.DAT`, a wrecked browser or Outlook profile — so copying it
wholesale carries the fault into the new account and defeats the exercise. The 9 items worth
rescuing (browser profiles, Outlook `.ost`/`.pst`, signatures, Sticky Notes, templates) are
offered individually, **never pre-ticked**, and only listed when they actually exist.

Two flags are load-bearing and enforced by tests. `/XJ` excludes junctions: every profile
contains legacy ones such as `My Documents` → `Documents`, and without it robocopy walks in
circles. `/COPY:DAT` deliberately omits ACLs so files **inherit** the destination profile's
permissions — copy the source ACLs instead and the new user often cannot open their own
files.

Robocopy's exit code is a bitfield, not a severity. Only bit 4 (16) means the copy itself
broke; bit 3 (8) means some files were skipped, which on a live profile is routine — a file
open in Word is normal, not a failed migration. Those are reported separately, naming what
was skipped, instead of failing the whole run.

**Microsoft account → local account** cannot be scripted; Windows deliberately routes that
through Settings. The tool creates the local admin and hands over the data, and you finish
the switch in *Settings → Accounts → Your info → Sign in with a local account instead*.

---

## Safety model

Blind leftover deletion on a client's machine is how a support call becomes an incident.

| Finding | Shown | Pre-checked |
|---|---|---|
| Path/key declared in the app's `cleanup` block (curated, exact) | yes | **yes** |
| Matched only by name token (heuristic guess) | yes | **no** — tick deliberately |
| Known shared suite component | yes, with amber warning | **never** |
| OS or shared vendor roots | **never listed** | — |

Two rules do the heavy lifting:

**Shared vendor roots are hard-blocked.** `%ProgramFiles%\Adobe`, `%ProgramFiles%\Autodesk`,
`Common Files`, and the `%AppData%`/`%ProgramData%` equivalents can never appear in the wipe
list. Removing AutoCAD must never offer up the Autodesk folder, because Revit lives inside
it. Reach inside shared vendor folders only via exact `cleanup.paths` entries. For the same
reason the default name token is the **app name**, never the publisher.

**Shared components are flagged, never pre-checked.** Autodesk deliberately leaves the
Licensing Service, Material Library, Desktop App and Identity components behind because
Revit and Inventor need them; Adobe does the same with Creative Cloud and Genuine Service.
These carry a visible warning — *"shared with other products of this suite"* — because the
real danger is not the tool being wrong, it is a technician being **thorough** on a machine
running other suite products.

**Integrity:** every installer's SHA-256 is verified inside the elevated process immediately
before execution; a mismatched file is rejected, never run. `go.ps1` pins the SHA-256 of
`AppDeploy.ps1` so tampering with the large script is caught before it runs. TLS 1.2+ is
forced regardless of OS defaults.

`irm | iex` is trust-by-HTTPS: whoever controls the domain and its certificate controls what
runs. Protect that server and its DNS like production infrastructure, because it is.

---

## Catalog reference (`apps.json`)

The manifest carries a **`categories`** array alongside `apps`, and it is the order the client
draws its group headers in:

```jsonc
"categories": ["Autodesk", "Adobe", "3D and Visualization", "3ds Max Plugins", "Utilities", "Apps"],
```

It exists because array position was doing two jobs at once. `AppDeploy.ps1` groups the Install
tab by category and adds no sort of its own, so the order groups appeared in was a side effect of
where each app happened to sit in `apps` — and that same order is the **install** order, which
Civil 3D onto AutoCAD and Corona onto 3ds Max depend on. Reordering the rail would have silently
reordered installations. Splitting them means a group can be moved without an install moving.

It is **seeded, not required**: a catalog with no `categories` key is read exactly as before, and
the editor fills the array in from whatever the apps already say, in first-appearance order, on
first open. A category an app names but the array has not caught up with is appended rather than
dropped, so a hand-edited catalog can never hide an app. `Catalog-Editor.ps1` creates, renames,
reorders and removes them; no category name appears anywhere in the PowerShell.

Removing a category asks where its applications go — move them to another named category, or
delete them along with it. Neither touches R2: the catalog entry goes, the uploaded installer
stays in the bucket.

```jsonc
{
  "id": "autocad",                       // unique, also the icon filename
  "iconText": "A",                       // letter mark placeholder until a logo exists
  "icon": "cad",                         // glyph family: cad|media|archive|office|dev|net|photo|design|video
  "iconColor": "#FFC7373C",              // brand colour for the tile
  "iconUrl": "https://.../icons/autocad.png",   // real logo, downloaded once and cached
  "category": "Autodesk",                // section header in the Install tab
  "publisher": "Autodesk",
  "name": "AutoCAD 2026",
  "version": "2026",
  "sizeBytes": 4831838208,               // drives the size column and disk-space check
  "url": "https://.../Setup.exe",
  "sha256": "…",                         // REQUIRED — mismatch means the file is never executed
  "silentArgs": "--silent",              // .msi files get /qn /norestart automatically
  "verifyPaths": ["%ProgramFiles%\\Autodesk\\AutoCAD 2026\\acad.exe"],
  "requires": ["autocad"],               // optional: ids that must be installed first — see Dependencies

  "uninstall": {                         // optional: vendor uninstaller, preferred over registry
    "command": "%ProgramFiles%\\Autodesk\\AdODIS\\V1\\Installer.exe",
    "args": "-i uninstall -q -o \"__ODIS_MANIFEST__\"",   // token resolved on the CLIENT — ODIS
                                         // mints its manifest at install time, so no catalog
                                         // written in advance can carry the path
    "detect": "%ProgramFiles%\\Autodesk\\AutoCAD 2026\\acad.exe"
  },

  // optional inside "cleanup": vendor removal TOOLS the leftover scan offers as run-this rows.
  // path-form runs an exe already on the machine (Program Files roots only); url-form is
  // fetched at wipe time and hash-verified by the elevated worker before a byte executes.
  // "shared": true marks a suite component (AdskLicensing) — listed, warned, never bulk-ticked.
  "cleanup": { "removers": [
    { "name": "Autodesk Licensing (AdskLicensing) — vendor removal tool",
      "path": "%CommonProgramFiles(x86)%\\Autodesk Shared\\AdskLicensing\\uninstall.exe",
      "args": "--mode unattended", "shared": true },
    { "name": "Avast Removal Tool (avastclear)",
      "url": "https://…/files/removers/avastclear.exe", "sha256": "…", "args": "/silent" } ] },

  // "uninstallOnly": true — an entry that carries removal knowledge for a product we never
  // install (Avast is the model). No url/hash/size; the edge serves it anyway, the Install tab
  // never shows it, and the Uninstall tab's row upgrade reads its uninstall/cleanup blocks.

  "postInstall": [                       // optional: steps run AFTER the install verifies
    { "type": "kill", "name": "Close the app",        // installers often auto-launch it
      "folder": "%ProgramFiles%\\Vendor\\App",        // everything running from here
      "waitMs": 2000 },                               // settle time for file handles
    { "type": "copy", "name": "Activation file",
      "url": "https://.../amtlib.dll", "sha256": "…",
      "dest": "%ProgramFiles%\\Vendor\\App" },        // a FOLDER keeps the source filename
    { "type": "run", "name": "Serialize",
      "url": "https://.../AdobeSerialization.exe",   // fetched and cached like an installer
      "sha256": "…",                     // REQUIRED for run - see below
      "args": "--tool=VolumeSerialize",
      "timeoutSec": 300 },               // killed past this; default 300
    { "type": "registry", "path": "HKLM\\SOFTWARE\\Vendor", "name": "Serial",
      "value": "XXXXX", "valueType": "String" },
    { "type": "service", "name": "VendorLicSvc", "action": "disable" }  // stop|start|disable|manual|auto
  ],

  "cleanup": {                           // deep clean targets — used when removing the app
                                         // AND when rolling back a failed install of it
    "tokens":   ["AutoCAD 2026"],        // name matches — listed UNCHECKED
    "paths":    ["%AppData%\\Autodesk\\AutoCAD 2026"],   // exact — pre-checked, unless the
                                         // app was already installed before the batch ran
    "registry": ["HKCU\\Software\\Autodesk\\AutoCAD\\R25.0"],
    "hosts":    ["autodesk.com"]         // activation-block domains to strip
  }
}
```

Add an app with `tools\Catalog-Editor.ps1` — it hashes the installer, reads what is inside the package, and writes the entry.

### Multi-file packages

Most vendors' silent installers are a **folder**, not a file. An Adobe Admin Console package
is `Build\setup.exe` plus its payloads; the Office Deployment Tool needs `configuration.xml`
beside `setup.exe`; an Autodesk deployment is an image. Point `url` at the `setup.exe` inside
one of those and every sibling file stays on the server — the install then fails for a reason
nobody can see.

Zip the folder, point `url` at the zip, and name the installer inside it with `entry`:

```jsonc
{ "url": "https://…/Photoshop.zip",
  "sha256": "…",                        // of the ZIP
  "entry": "Build\\setup.exe",          // what to run once unpacked
  "silentArgs": "--silent" }
```

The zip is SHA-256 verified **before a byte is unpacked**, so the pin covers every file inside
it as tightly as it covered a bare installer. The real `setup.exe` is then what runs, so its
exit code — and therefore `Get-InstallVerdict`, the Dirty verdict, and the deep clean — all
keep working. The unpacked copy is deleted the moment the installer exits, and the disk-space
check budgets **2.2×** for a package instead of 1.2×, because at its peak it is on disk twice.

The working directory is set to the entry's own folder, which is what makes Office's
`/configure configuration.xml` resolve.

**Taking a file back out of the package.** Vendors ship documents beside the installer - a
readme, a licence file, a plugin. A `copy` post-install step names one with `from`, relative
to the unpacked package, and it is placed in the app's install directory once the install has
verified:

```jsonc
"postInstall": [
  { "type": "copy", "name": "Copy readme.md",
    "from": "Doc\readme.md",                            // inside the package
    "dest": "%ProgramFiles%\Autodesk\Revit 2026\\" }    // trailing backslash keeps its own name
]
```

No second download and no second hash: those bytes were already inside the zip the package
pin covered. The unpacked copy therefore survives until every post-install step has run, and
is deleted immediately afterwards - it used to go the moment the installer exited, which made
this silently impossible.

**Self-extracting exes were tried first and rejected.** A WinRAR SFX returns *its own* exit
code — measured as `0` while the installer inside returned 1603 — which would report every
failed install as a success and silence the dirty verdict entirely. One variant returned 0
without running the installer at all. `tests\Test-DirtyCleanup.ps1` covers this path so the
guarantee cannot quietly regress.

### Instructions shown to the technician

Anything a person still has to do by hand goes in `instructions`, and it is put on screen
when the batch finishes rather than left in a README nobody opens:

```jsonc
{ "instructions": "Serial: XXXXX-XXXXX. Point the licence server at 27000@srv-lic.\nReboot before first launch." }
```

Only shown for apps that actually installed — explaining how to activate a product that
failed would be worse than saying nothing. It is written to the Activity Log too, so the
session transcript keeps it.

### Post-install steps

Most products are not finished when the installer exits — a serialization tool has to run, a
licence file has to land, a service has to be stopped. `postInstall` declares those per app
and they run **in order, in the same elevated worker, only after the install has verified**.

The usual shape is **install → close the app → drop a file into its folder**, because
installers routinely launch the product when they finish and a running app holds its own
files open. `kill` closes it first (politely, then forcibly, then waits for the handles to
release), so the `copy` that follows does not fail with *"file in use"* — the same reason
you have to close it by hand. `kill` takes a process `name`, a `folder` (everything running
from under it), or both; nothing running is a success, not an error, and a folder shorter
than eight characters is refused so a stray `C:\` cannot kill the machine.

A `copy` whose `dest` is a **folder** keeps the source filename, so the catalog doesn't
repeat it. It retries a few times if the target is locked.

A **`powershell`** step runs a command from the catalog, elevated, on the client — for the
finishing touches that are not a file at all (a registry tweak too fiddly for the `registry`
step, a service reconfigured, a licence activated through a vendor CLI). It is time-boxed like
every other step, its exit code is checked, and the command is passed base64-encoded so quoting
inside it cannot break the command line.

> It is also the sharpest edge in the catalog. There is no file, so there is nothing to hash —
> **the catalog itself is the only thing vouching for that command.** Anyone who can change the
> catalog can run anything on every client this tool touches. That was already true of the
> `registry` and `service` steps; this makes it arbitrary. Protect the catalog server as you
> would protect the installers.

Nothing about this is hand-edited any more: `Catalog-Editor.ps1` builds the array as a list you
can add to and reorder, and carries through the step types it has no UI for.

Five rules, all enforced in code:

**A `run` step without a `sha256` is refused.** These execute elevated, so an unpinned file is
never run — the queue may *name* a payload, never introduce an unverified one. The hash is
checked immediately before execution, exactly like the installer.

**Every step is time-boxed** (`timeoutSec`, default 300). `Start-Process -Wait` has no timeout,
so an activation tool that opens a hidden dialog would otherwise hang the entire batch
indefinitely. Past the limit the process is killed and the step reports *"TIMED OUT … it may be
waiting on a hidden prompt"*.

**A failed step halts that app's chain.** Later steps do not run against a half-finished
activation, and the row says which step broke.

**A post-install failure is not an install failure.** The product is on disk, so the row goes
amber with the exact step, not red — and never silent.

Since these run elevated from the catalog, the catalog server is now as trust-critical as the
installers themselves. Pin the hashes, and protect that host and its DNS accordingly.

---

## Server setup

Any static HTTPS host (nginx, IIS, S3/CloudFront). Must support HTTP **Range** requests so
downloads resume.

| Path | File |
|---|---|
| `/go` | `server/go.ps1` — edit `$BaseUrl` and the hash pin |
| `/AppDeploy.ps1` | `server/AppDeploy.ps1` |
| `/apps.json` | `server/apps.json` |
| `/files/*` | the installers |
| `/icons/*` | app logos, named `<id>.png` |

**Releasing a new AppDeploy.ps1:** run `tools\Publish-Release.ps1`. It uploads `go.ps1`,
`AppDeploy.ps1` and `apps.json`, pins the new hash into `cloudflare\wrangler.toml` and deploys
the Worker, which injects that pin into `go` as it is served.

Do **not** paste a real hash into `$PinnedHash` in `go.ps1`. That line is a placeholder on
purpose: the pin is kept out of the R2 copy so that an attacker able to rewrite `AppDeploy.ps1`
in the bucket cannot also rewrite the hash guarding it. A hash pasted there goes stale on the
very next release, and the file then fails its own integrity check for no visible reason.

**Nothing reaches a client until that runs.** The Worker serves what is in R2, so an edit to
`server\AppDeploy.ps1` on your machine is local until it is published.

Checking whether local matches live takes one step more than it looks. The pin is the hash of the
**shipped** file - comments stripped by `Compress-Script.ps1`, about 19% smaller - not of the
source, so `Get-FileHash server\AppDeploy.ps1` never equals `APPDEPLOY_SHA256` even immediately
after a publish. To compare properly, strip first:

```powershell
. tools\Compress-Script.ps1
$ship = ConvertTo-ShippableScript -Source (Get-Content server\AppDeploy.ps1 -Raw)
[IO.File]::WriteAllText("$env:TEMP\ship.ps1", $ship, (New-Object Text.UTF8Encoding $false))
(Get-FileHash "$env:TEMP\ship.ps1" -Algorithm SHA256).Hash    # compare with APPDEPLOY_SHA256
```

### Access code

The paste-line is public by nature — a client can note it off the screen. What it *fetches*
is not: with an `ACCESS_CODE` secret set on the Worker, the tool (`/AppDeploy.ps1`) and the
catalog (`/apps.json`) return 403 without the right `x-pc2go-code` header. The catalog is the
asset that matters — it mints fresh signed `/files/` URLs, so serving it to a stranger hands
them every installer. `/go` stays open because the bootstrap is useless without what it
fetches.

`go.ps1` asks for the code once (masked, console prompt, three tries) and hands it to the
tool out-of-band — never a URL, never a command line, never a plain file. A wrong code inside
the running tool shows an **Access code required** overlay pointing back at the go line.

Getting it into the *elevated* copy is the subtle part, and worth knowing if you touch it:
`-Verb RunAs` builds a fresh environment through the AppInfo service, so an environment
variable does not survive — and that is the common case, because an admin technician
launching normally gets elevated, and the elevated copy is the one that fetches the catalog.
The code therefore travels as a DPAPI (LocalMachine) token at
`%ProgramData%\PC2GoDeploy\access.bin`, written with its DACL applied **at creation**
(creator + Administrators + SYSTEM, inheritance off — LocalMachine DPAPI has no per-user key,
so the ACL *is* the control, and the creator is on it because a filtered-token admin cannot
write to an Administrators-only file). It is a hand-off token, not storage: anything older
than two minutes is ignored and deleted rather than trusted, and it is shredded once the
catalog loads and again on window close. `tests\Test-AccessCode.ps1` pins all of it.

Set or rotate it from the Management Console (**Access code…**), or by hand with
`wrangler secret put ACCESS_CODE`.

**What this is and is not.** It is access control, not secret-keeping: the code necessarily
exists in cleartext in memory on every client machine the tool runs on. Treat it as cheap and
routine to rotate, and do not let it become the only thing between the internet and something
that matters — the signed-URL gate on `/files` and the SHA-256 pins are still what protect
the installers themselves.

Enable: `wrangler secret put ACCESS_CODE` — and the same command **rotates** it: one new
value and every code ever handed out is dead, no republish, no client change. Unset, the gate
is dormant and everything behaves exactly as before. Recommended alongside it: a Cloudflare
rate-limit rule on 403s from these paths, so a code cannot be brute-forced politely.

Planned, not built: multiple named codes with per-code usage counts (who used which code,
how often, last seen) — the audit upgrade for when codes are handed to more than one person.

### Cloudflare R2 (recommended) — `cloudflare\README.md`

A ready deployment sits in `cloudflare\`: an R2 bucket with a Worker in front of it.

Egress is the whole bill on a tool that ships 30 GB per session, and R2 charges **$0 per
GB** at any volume against CloudFront's $0.085+ with the Middle East on a premium tier.
There is a Cloudflare PoP in Kuwait City. Note that Cloudflare's CDN terms permit large
non-HTML files **only when they are hosted on a Cloudflare service like R2** — the same
files behind the CDN on an ordinary VPS are still a violation.

The Worker adds two things this section previously left to the operator:

**Installers are no longer world-readable.** `/files/*` requires an HMAC token, and the
Worker mints those by rewriting the URLs **inside the `/apps.json` response**. Because
`AppDeploy.ps1` takes `$item.Url` straight off the catalog and derives the filename with
`([Uri]$a.url).LocalPath` — which ignores the query string — signed URLs flow through the
existing client with **no code change**. Token lifetime defaults to 48 h because a
suspended BITS job keeps the URL it was created with, and a resumed 30 GB download must
outlive the signature.

**The hash pin stops being a manual step.** `tools\Publish-Release.ps1` hashes
`AppDeploy.ps1`, writes the pin to Worker config, deploys, then re-fetches `/go` and
confirms the live pin matches. A stale pin never fails at publish time — it fails on a
client machine, mid-session, with a message indistinguishable from a real compromise.

The pin lives in Worker config rather than being derived from the bucket on the fly: an
attacker able to rewrite `AppDeploy.ps1` in R2 could rewrite its hash alongside it, so
computing it at the edge would make the check worthless.

---

## Tools

| Script | Purpose |
|---|---|
| `tools\Catalog-Editor.ps1` | **PC2Go Management Console** — the privileged side of the tool: a category rail, an application grid, and a drawer that holds every field (add apps from a file **or a folder**, hash, package, validate), plus R2 credentials, Push/Publish, and setting or rotating the access code. The filename is unchanged so every existing path and harness keeps working |
| `tools\Export-AppIcons.ps1` | Extracts real product icons from installers into `icons\*.png` |
| `tools\Publish-Release.ps1` | Validates the catalog, uploads to R2, pins the hash, deploys, verifies |
| `tools\Convert-PackageToZip.ps1` | Rewrites a `.rar` or `.iso` as a `.zip`, verified file-by-file. Push does this automatically for any `.rar` before uploading |
| `tools\R2-Upload.ps1` | The S3 transport: signing, multipart upload, resume. Dot-sourced by the editor's Push and by `Test-Push.ps1`, so one copy of the signing code ships |
| `tests\Test-Push.ps1` | Drives the whole Push path against a loopback endpoint - signing, resume, the skip rule, and the automatic `.rar` conversion |
| `tools\Compress-Script.ps1` | Strips comments from `AppDeploy.ps1` at publish time. Script size is what antivirus charges for on launch |
| `tests\Test-DirtyCleanup.ps1` | Fault-injects installer failures and asserts the dirty verdict, the wipe, and the pre-tick rule |
| `tests\Test-DownloadResilience.ps1` | Interrupts and throttles downloads, and asserts BITS resumes rather than restarting |
| `tests\Test-AfterInstallList.ps1` | Asserts the editor's after-install list — order, steps it cannot edit, and its output run by the real worker |
| `tests\Test-CatalogScenarios.ps1` | Whole journeys: real zip → real dialog → real `apps.json` → re-edit → the real worker installing it |
| `tests\Test-RealUninstall.ps1` | Installs three real per-user products on this machine, removes them with the tool, deep-cleans, and cleans up after itself |
| `tests\Test-GuiBatch.ps1` | Clicks the real Install and Uninstall tab buttons — the pre-flight sheet and its disk check, batch, Add to Queue, Cancel, the leftover preview and the wipe, the run record a finished batch writes, and the uninstall table's sorting |
| `tests\Test-DeepBatch.ps1` | A real BITS download over loopback HTTP, Pause/Resume, the full exit-code matrix, and elevation declined |
| `tests\Test-Elevated.ps1` | **Run this elevated, by hand.** The real elevated worker, HKLM products, hosts lines, services, tasks, other profiles |
| `tests\Test-CatalogEditorGui.ps1` | The editor's main window, a real HTTP fetch, `Publish-Release` validation, and a BOM'd catalog |
| `tools\Export-UiSnapshots.ps1` | Renders the real windows to PNG offscreen, so a person can see clipping and contrast that property tests miss |
| `tests\Test-Categories.ps1` | The category model and the window it lives in — seeding, rename, reorder, that deleting a category can never silently delete an app, that the drawer floats and shuts, that the id is an editable field whose icon follows a rename, and that any picture you pick becomes a 256×256 PNG |
| `tests\Test-Worker.mjs` | Imports the real `worker.js` and asserts the catalog filter, the URL signing, the `/files` gate and the access-code gate. `node tests\Test-Worker.mjs`, no wrangler and no network |
| `tests\Test-AccessCode.ps1` | The access-code hand-off: that the DPAPI token is written unreadable by other accounts **from the first byte**, that a stale token is ignored rather than trusted, and that it is shredded after use. Lifts the real functions out of `go.ps1` and `AppDeploy.ps1` by AST, so the two copies cannot drift |
| `tests\Test-Wrangler.ps1` | The hidden `wrangler` call: that it never passes `-Wait`, that its exit code is a real integer rather than empty, that a Cloudflare sign-in prompt is recognised from wrangler's own output, both give-up clocks, the tree-kill, and a secret file that never exists readable and does not survive the call |
| `tests\Test-TweakReality.ps1` | **Not a pass/fail suite.** A read-only reality check: it lifts every `Set-Reg` / `Set-RegSoft` / `Remove-RegVal` out of the worker by AST and reports, value by value, whether this machine currently matches. Before a run, a MISMATCH just means "not applied yet"; **after** a run that reported Applied, every MISMATCH is a tweak that did not take |

### The editor window

Two panes and a drawer: **categories** on the left, the **applications** in that category as a
grid in the middle, and a **drawer** that slides over the grid when you open an app.

The drawer is what replaced the pop-up. Editing an application used to mean a 620×880 modal —
taller than a 768 px laptop screen, so its buttons sat off the display, and it covered the
catalog while it was open. Everything that was in it is now in the drawer: name, id, category,
icon, download URL, Fetch and hash, setup file, silent switches, verify path, and the full
after-install builder. What went is the duplication — silent switches appeared twice, the steps
appeared twice, and the package was described in two places.

**Both windows are the same window.** 1060 x 700, one rounded panel at radius 11 filling it edge
to edge, and the same header: transparent over that panel, 54 px tall, a 32 px logo tile, the
tool's name at 14.5 semibold and a muted line under it for state. Search boxes and tabs share one
shape too - radius 6, the same fills and the same hover.

Buttons, dropdowns and scrollbars are the installer's in both windows. Two of those were not a
matter of taste: a `ComboBox` styled with setters alone keeps the SYSTEM template and renders
white whatever background is set on it, and a window with no `ScrollBar` style at all inherits
the light system scrollbar - a grey slab down the side of a dark window. Both are templated now,
in the editor's window resources and again in its drawer, which is where the dropdowns live.

Two more things that had to be got right. The client used to sit 14 px inside its own window behind a
drop shadow, so two windows of identical size rendered 28 px apart. And the header must stay
TRANSPARENT: a coloured band with square top corners, painted over a rounded panel, is what makes
a rounded window look square.

**Both windows share one palette.** The editor declares eleven brushes — `Panel`, `Sunken`,
`Raised`, `Line`, `LineSoft`, `Ink`, `Muted`, `Dim`, `Accent`, `Lift`, `Bad` — and `AppDeploy.ps1`
now declares the same names with the same values, plus `Good`, `Warn` and `Danger` for states the
editor never draws. It used to carry **41 colours written inline** at the point of use, among them
six near-identical greys and an accent of `#3D7EF0` against the editor's `#2563EB`: close enough to
read as a mistake, far enough to see side by side. Both windows are 1060 × 700.

Three literals survive on purpose. The `<Window>` element's own `Foreground` cannot be a
`StaticResource` — its attributes are set before `Window.Resources` exists. The root panel's
`#FF1B1B20` is written inline in both files, because it is the one surface the brushes sit on.
And the *largest* chip in the uninstall table carries its own border and translucent fill, which
are one-off accents rather than palette colours.

**The id is a field.** It used to sit under the name as grey text: not a heading, not editable,
and fixed to whatever the app happened to be called when it was first added. It is now the first
field in the drawer, typed like any other. What you type is normalised rather than rejected - a
space becomes a dash - and an empty box falls back to the name, which is what it always did.

Renaming an id **takes the icon with it**. An icon is found as `icons\<id>.png`, so leaving the
file under the old name would silently blank the tile of an app that has one. It never overwrites
an icon already sitting under the new name.

The id is still the R2 key prefix, so renaming one that has already been pushed leaves the old
bytes in the bucket under the old prefix. That is now your call to make rather than a decision
the tool makes for you.

**The name at the top is a field, not a caption.** Click it and rename the application; the
card behind updates as you type. The `id` under it does not change, deliberately — it is the R2
key prefix, so renaming an app after an upload would orphan the bytes already in the bucket.

**There is no Save in the drawer**, because there is nothing to save to: it writes to the
catalog entry as you type, exactly as the category dropdown does. The safety net is the one that
was already there — nothing reaches disk until **Save catalog**, and closing with unsaved
changes still warns. The one thing it will *not* write half-finished is the after-install list:
a step with no file chosen is a step the worker would refuse on a client, so the list is written
only when it is complete, and the drawer says what is missing meanwhile.

It **floats** rather than taking a column. As a column it pushed the catalog into a third of the
window and the tool went back to feeling like two windows. It shuts when you click away, and
clicking the application it is already showing shuts it too — so the same click opens and closes
Office. The grid drops to one column while it is open so nothing hides underneath it.

Both lists are re-templated. Left alone, a WPF `ListBoxItem` paints a system-blue block on
selection, which cannot show *which of two columns* is selected and looks nothing like the
client. The rail uses the same accent bar the client puts on its group headers, and applications
are cards with a hover and a selected border.

Every row carries an **icon tile**: the letter mark from the catalog's own `iconText` and
`iconColor`, or a dashed empty slot when the entry has neither. Dashed is deliberate — an empty
square reads as artwork that failed to load, where a dashed one reads as *not done yet*.

**Icons are your own pictures.** The **Pick a PNG…** button in the drawer takes any picture —
PNG, JPEG, BMP, GIF, TIFF, `.ico` — and writes it to `icons\<id>.png`. Nothing is generated,
extracted or downloaded.

It is **converted, not copied**, into a 256×256 PNG, and how depends on what you gave it. An
opaque picture — a photograph, a screenshot, a JPEG — is centre-cropped until it *fills* the
square, because that is what makes it read as an app icon; fitting it inside instead left a
1200×300 photograph as a thin strip floating in an empty tile. Artwork that carries real
transparency keeps its shape and its margins, because on a logo that space is deliberate and
cropping would cut the mark. A square logo comes out untouched either way.

**PNG is what gets stored, and that is not a preference.** The client draws icons with WPF's
`BitmapImage`: SVG has no decoder there at all, and WebP needs an optional Store codec that may
be installed here and missing on a client — the worst kind of difference. So pick whatever you
have; PNG is what lands in `icons\`.
An icon-library search was built against [dashboardicons](https://dashboardicons.com) and removed
again: measured against this catalog it matched 6 of 19, half of those coincidences
(*azure-cost-management* for "Navisworks Manage", *gravit-designer* for "Design Review"), and no
library carries Revit, Civil 3D, Photoshop, Illustrator, InDesign, DIALux, Corona or WinRAR.

**Push carries them.** `icons\<id>.png` goes up to `/icons/<id>.png` alongside the installers and
`iconUrl` is written into the catalog for each one that actually uploaded — never for one that
failed, because the client caches what it fetches and a 404 would stick. Icons go **last**: they
are kilobytes next to a 14 GB package, and a failed icon must never be the reason an installer
did not go up. `Export-AppIcons.ps1` still does a whole folder of installers in one pass if you
would rather generate them than source them.
**Removing** is in two places and never ambiguous. An application: the **Remove** button in the
drawer footer. A category: **Manage categories…** under the rail. Removing a category that owns
applications asks where they go — move them to another named category, or delete them with it —
and refuses a destination that is blank, itself, or nonexistent. Neither path touches R2: the
catalog entry goes, the uploaded installer stays in the bucket.

Search spans the whole catalog rather than the open category, because "where is Photoshop filed"
is the question being asked, and answering it only inside the folder you already have open
answers nothing.


`Catalog-Editor.ps1` is deliberately not a tab in `AppDeploy.ps1` — that file is downloaded
onto every client machine, and catalog editing has no business travelling with it. **"Add
folder"** is the point of it: it zips the folder, hashes the zip, and fills in `entry`, so
multi-file packages stop being something you have to remember. `sizeBytes` and `sha256` are
always computed from the real file, never typed. It saves BOM-less, keeps an `apps.json.bak`,
and preserves fields it has no UI for (`uninstall`, `iconUrl`, `_installNote`) by editing the
parsed JSON in place rather than rebuilding it. Saving an incomplete entry only warns —
`Publish-Release.ps1` is the gate that refuses.

**AFTER INSTALLATION is a list**, because `postInstall` always was one. Each row is an action —
*move a file in* or *run a file*, both taking their file out of the package — and rows are
added, removed and reordered on screen, so *two files into two different directories* is
something you do rather than something you hand-edit the JSON for. Order is editable because
order is what the worker obeys: `kill` the running app, **then** drop the file in. The list is
the editor — the fields below it always show the selected row and change it as you type, so
there is no half-typed action that was never added.

Steps the dialog cannot build — `kill`, `registry`, `service`, a `copy` from an absolute path —
are **shown in the list anyway**, marked *(kept as written)*. They cannot be edited there, but
they can be moved, and they are written back byte for byte. A step that could not be seen could
not be positioned. The destination follows the same rule the worker uses: a folder keeps the
file's own name, a path ending in a filename renames it on the way.

Saving refuses an action with no file, a move with no destination, and — once a fetch has read
the package — a file **that is not in it**. That last one is free text, so a typo used to be
accepted here and only surface on a client, as *"source file missing"*, at the end of a 14 GB
install. An app edited without re-fetching has no listing to check against, and no listing means
no opinion rather than a guess.

`Test-DirtyCleanup.ps1` covers the failed-install deep clean, which is otherwise only
reachable by breaking a real installer on a real machine. It builds fake installers that
exit 1603, −1, 1223, and 0-without-installing, then runs the **actual** elevated worker —
lifted verbatim out of `AppDeploy.ps1` — against them, and checks the `dirty` flag it puts
on the wire against what those installers really left on disk.

It then drives the real `Read-WorkerStatus` against synthetic rows, because holding the end
marker back until every app has reported means a mistake there does not produce a wrong
answer — it produces a batch that never finishes. The case that matters most is the boring
one: a batch where nothing went wrong must still release the worker. Needs no elevation and
writes only inside `%TEMP%`.

`Test-AfterInstallList.ps1` covers the other half of that contract — the editor's side.
`Test-DirtyCleanup.ps1` already proves the *worker* puts two files from one package into two
directories, but it feeds it hand-written JSON; what was never covered is the editor producing
that JSON. It lifts the row model out of `Catalog-Editor.ps1` and the step executor out of
`AppDeploy.ps1` through the parser, checks every control the dialog looks up actually exists in
the layout, and asserts that reordering rows reorders the steps, that a `kill` or `registry`
step survives an edit untouched, and that `args` / `timeoutSec` / `stopOnError` — which have no
UI — outlive one too. Then it hands the editor's own output to the worker's `Invoke-PostInstall`
and checks two real files land in two real directories.

It also **drives the drawer itself**. `Show-AppDialog` no longer blocks on `ShowDialog()` - it
builds the panel and returns it - so a harness calls it, reads `$dlg.Tag` for the controls, the
state and the apply handler, clicks the real buttons by raising their events, and inspects what
happened. No UI Automation, no human, no window on screen. (That change is also what caused four
separate scope bugs: with the stack frame gone every helper became a closure, and a closure here
captures `$script:` by value. See the comments at the top of `Show-AppDialog`.) That is what caught the bug where reading an editable ComboBox's `.Text`
returned `$null` on a brand-new app — `Add an action` threw before adding anything, so the list
stayed empty and the Move / Run radios stayed greyed with no way in. Note the trap it also
exposes in *testing*: setting `.IsChecked` works on a **disabled** control, so a test that only
sets properties passes while the person in front of the dialog cannot click a thing. Assert
`IsEnabled`. 206 assertions, unelevated, `%TEMP%` only.

`Test-CatalogScenarios.ps1` is the one that goes all the way. It builds a real `.zip`, adds it
as a brand-new app through the real dialog — the real background fetch and SHA-256 over real
bytes, pumped by a dispatcher frame so the async path is the real one — gives it two files
bound for two directories, saves through `Export-Catalog` to a real `apps.json`, checks that
file has no BOM, reads it back, **re-opens it in the dialog** to retarget one action, remove
another and reorder a hand-written `kill` around them, saves again, and then hands the
twice-edited entry to the **real elevated worker** as a queue item. The worker unpacks, installs,
verifies, and runs the steps; the harness then checks the product is on disk, both files are in
their separate directories with the right contents, the action that was *removed* did not run,
and the unpacked scratch copy was cleaned up. That last stretch is the only question that
actually matters — whether clicking through the GUI ends with software installed and files where
you put them. 54 assertions, unelevated, and it never opens the real `server\apps.json`.

Between them the two editor harnesses are checked against seven deliberately broken copies of
`Catalog-Editor.ps1` (foreign steps dropped, order sorted away, the trailing-slash rule removed,
steps rebuilt instead of edited, the package guard disabled, the null-`Text` crash reintroduced,
the row list made fixed-size). Every one is caught — five by the scenario harness, all seven once
`Test-AfterInstallList.ps1` runs too.

Silent switches are typed by hand, deliberately. The editor used to identify the packager and
propose one; the proposal was right often enough to be trusted and wrong often enough to reach a
client, and a wrong switch does not fail loudly - the installer opens its GUI on a machine nobody
is sitting at. What catches it now is the thing that always did the real work: the installer
guard stops a window that opens, bounds it with a timeout, and names the switch as the likely
cause.

`Publish-Release.ps1` refuses to publish a catalog whose **servable** apps carry a
`postInstall` `run` step with no `sha256`, the same installer under two ids, or an
after-install destination with a second path inside it (`-Force` overrides for staging). Validation runs before the wrangler check, so it is
usable as a catalog linter on a machine with no deploy toolchain installed.

An app that still has a placeholder hash is **not** an error: the Worker drops it from
the catalog it serves, so no client ever sees it — and it could never have installed
anyway, because `AppDeploy.ps1` verifies the hash only *after* downloading the whole
file. That is what lets a half-finished catalog be published at all, which it must be:
installers go up a few at a time over weeks, and the finished ones cannot wait for the
rest. The one case still refused is a catalog where *nothing* is ready, since the served
`apps` array would be empty and every client would report a catalog failure.

That filter is the one piece of edge logic that decides **what a technician is allowed to see**,
so it is tested rather than eyeballed. `tests\Test-Worker.mjs` imports the real `worker.js` — not
a copy — and asserts both directions: a placeholder or short hash is dropped, a finished app
survives with its uninstall block, cleanup tokens, signed URL and rehosted icon intact. It also
covers the two edges that a naive filter gets wrong, a catalog where everything is ready and one
where nothing is, and checks the filter did not break signing, the `/files/` gate or `/health`.
It needs no wrangler, no network and no deployed Worker: `node tests\Test-Worker.mjs`.

---

## Compatibility

Target: **Windows 11**, also Windows 10. Whatever shell the technician starts from, the tool
always executes under Windows PowerShell 5.1 — in-box on every Win10/11 machine, and the only
version with native BITS cmdlets. PowerShell 7 hands off automatically.

Will not work on AppLocker/WDAC machines in Constrained Language Mode, which block WPF from
PowerShell. Those environments need a signed compiled exe instead.

---

## Open items

Honest list of what is not finished. Nothing here has been run end-to-end against a real
installer yet.

1. **Silent-install switches are typed by hand, and unconfirmed.** Nothing detects or proposes
   them: that was tried and removed, because a proposal that is right most of the time is
   indistinguishable from a checked fact by the time it reaches a client. Set `silentArgs`
   from the vendor's own documentation and confirm it on a VM. A wrong one does not fail
   loudly - the installer opens its GUI and waits - so what catches it is the installer guard,
   which stops a window that opens, bounds it with a timeout, and names the switch as the
   likely cause.
2. **FloorGenerator has no installer.** It ships as a `.dlm` plugin copied into the 3ds Max
   plugins folder. Either wrap it in a self-extractor, or add a `copy` action to the tool
   (cleaner, and reusable for any future plugin).
3. **Office 365 needs its whole ODT folder hosted**, since
   `setup.exe /configure configuration.xml` reads that XML from alongside itself.
4. **Icons are supplied by hand.** Pick any picture in the drawer, or drop one at
   `icons\<id>.png`. Push uploads them and writes `iconUrl`. No library is consulted — the
   measurements are in the editor section.
5. **Code signing.** An unsigned script downloaded over a browser will trip SmartScreen. An OV
   certificate (~$100–400/yr) plus reputation, or EV for instant reputation, is worth
   budgeting for a client-facing tool.
6. **Uninstall list includes runtimes** (Visual C++, .NET, drivers). Removing those breaks
   other software. Nothing is pre-selected, but the guard rails are on the leftover *wiping*,
   not on what a technician chooses to uninstall.
7. **Two removal pieces still need arming before publish.** `avastclear.exe` must be hosted
   under `files/removers/` in R2 and its real SHA-256 pinned in `avast-free`'s remover entry
   (the edge and worker are ready for it), and the `__ODIS_MANIFEST__` resolution has only been
   proven against fixtures — confirm it once on a machine with a real Autodesk install.
   (The dependency mechanism itself — `requires`, the pre-flight guard, and the orchestrated
   remove-install-reinstall sequence — is built and test-proven.)
8. **The single-instance guard and the harnesses fight over the same mutex.** Several suites
   dot-source `AppDeploy.ps1`, which takes `Local\PC2GoAppInstaller` and **returns early** when
   it is held. So the tool cannot be open while the suites run, and two suites cannot overlap.
   The symptom is not "already running" but a confusing `The term 'Load-Catalog' is not
   recognized`, or a launched window that vanishes with no message at all — the guard's fallback
   is `Write-Host` into a console the tool has already hidden. A `-NoSingleInstance` switch for
   the harnesses, and a distinct exit code on that path, would fix both halves.
9. **`Export-UiSnapshots.ps1` hangs** before writing its first PNG, so `ui-snapshots\` is stale:
   those images predate the shared palette and the uninstall table. The renders used while
   building both were taken by parsing the XAML directly instead.
10. **No git remote.** The work *is* committed now — 29 commits on branch `console-rework` —
    but it still exists in exactly one place: this disk. Creating a private remote and pushing
    outranks every other item on this list, and this is the fourth handover to say so.
11. **S0 Sleep Network Connectivity is absent.** It was dropped with the Preferences tab and
    approved for Tools ▸ Fixes, but never re-homed. It is the one agreed change that is simply
    missing rather than deferred.
12. **The slow-PC verdicts do not link to the rows that fix them.** L6 can report "Power Saver
    on AC" while the Power Plan row that fixes it sits one tab away, unmentioned. Agreed,
    designed, not built.
13. **The access gate is not rate-limited.** Measured: five wrong codes accepted at line rate,
    0 s, unthrottled. The compare is constant-time, so the gap is throttling, not the check —
    it is a Cloudflare dashboard rule on 403s, not code.
14. **One access code for everyone.** A leaked code can only be fixed by rotating everybody.
    The planned upgrade is named codes with per-code usage counts, so one can be revoked alone.
15. **`HintNetManual` has no `Add_TextChanged`** (AppDeploy.ps1), so its grey
    `\\PC-NAME\SharedFolder` watermark sits underneath whatever the technician types. It is the
    only hint in either file missing that toggle.
16. **`Test-GuiBatch` has two pre-existing failures** — one environmental, one a chain-settle
    timing race — and `Test-Push` has one flaky assertion (`Stop-ProcessTree`: `taskkill /T` is
    asynchronous, so the check occasionally reads the child before Windows has reaped it).
    None of the three is a defect in shipped behaviour, but they make a green run ambiguous,
    which is worse than a red one.

---

## Cleanup on the client machine

Everything lives in `%LOCALAPPDATA%\PC2GoDeploy`. On a clean success — or an untouched
session — the whole folder deletes itself when the window closes, via a detached process so
it can remove its own script. On failure or partial download the cache is kept so a retry
resumes instead of re-downloading, and it is cleared on the next clean run. No registry
entries, services or scheduled tasks are created by the tool itself.

A leftover BITS job keeps the cache alive on purpose — that is what makes a 30 GB download
survive a dropped connection. But a job only earns that if it **actually holds bytes**. One
that never connected (0 bytes, `TransientError` against an unreachable host) is garbage, and
BITS retries it for up to 90 days: counted as live it would block the no-trace cleanup on
that machine forever, on every future run. Those are removed on close instead. Anything with
even one byte transferred — or queued, connecting, suspended or transferring — still
protects the cache, because destroying a client's half-finished installer is far worse than
leaving a folder behind.
