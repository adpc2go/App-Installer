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
powershell -NoP -EP Bypass -C "irm https://YOUR-SERVER/go | iex"
```

Shorthand from a PowerShell window:

```powershell
irm https://YOUR-SERVER/go | iex
```

The GUI launches detached, so the console it was typed into can be closed immediately.

**Only one copy runs at a time.** Every instance shares one download queue in `%LOCALAPPDATA%`,
and the elevated worker reads it as a stream — so two copies mean two workers taking each
other's items, colliding on the same install (which fails it with *"installer exit code 1"*)
and never reaching the end marker, leaving a batch that cannot finish. A second launch is
refused with *"already running"* instead. This is measured behaviour, not a precaution: the GUI
harness reproduced it before the guard existed.

### Local testing (no server)

```powershell
powershell -NoP -EP Bypass -File "server\AppDeploy.ps1" -BaseUrl "file:///C:/Users/Lenovo-G/Desktop/App-Installer/server"
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
2. **Install Selected** → downloads begin
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

### Uninstall flow

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

### Tweaks

A winutil-style tab, in two columns. The lists are **built into the tool**, not fetched —
they work with no server and cannot be changed by whoever controls the catalog host.
Everything is applied by the same elevated worker, so a whole batch is one UAC prompt.

**Left column — 38 tweaks**, Essential and Advanced stacked as one list:

| Group | Count | Behaviour |
|---|---|---|
| Essential Tweaks | 18 | Privacy, telemetry, disk and UI fixes. Reversible policy/registry changes |
| Advanced Tweaks **CAUTION** | 20 | Removes software or changes network/OS behaviour. Extra confirm dialog naming exactly what will run |

**Right column — 25 Customize Preferences.** These are **toggles, not one-shot tweaks**:
each has an on and an off state, and the tick shows what the machine is *currently* set to,
read live when the tab loads. Only preferences you actually **change** are applied — opening
the tab and pressing Apply never rewrites 25 settings you did not touch. `Clear` drops
pending edits and shows the machine's real state again rather than unticking everything,
because 25 unticked toggles would read as "turn all of these off".

Rows carry no icon and no size column, so roughly twice as many fit on screen; a 3px accent
bar (blue Essential, amber CAUTION, green Preference) is all that remains.

The preference table is defined **once** in the GUI and substituted into the worker's own
code when it launches. Both sides therefore always agree, and the queue still carries
nothing but an id and `on`/`off` — the elevated worker never takes registry paths off a file
any user process could write to. A test asserts the injected worker still parses and that
both tables hold identical ids.

**Presets, so nobody hand-ticks 38 rows.** One click selects a set:

| Button | Selects | For |
|---|---|---|
| **Minimal** | 8 | Restore point plus core privacy. Safe on any client machine |
| **Standard** | 23 | Every Essential plus the reversible advanced items. The recommended build |
| **Advanced** | 37 | Everything except `IPv6 Set IPv4 as Preferred` |
| **Clear** | — | Deselects everything |

`IPv6 - Disable` and `IPv6 Set IPv4 as Preferred` write the **same** registry value to
different numbers, so no preset ever contains both — a test enforces this.

**Detect Applied** reads the machine and ticks what is already in place, so you can see a
client's current state before changing anything. It runs unelevated (no UAC): `HKLM` and
service state read fine without admin, and `HKCU` in the GUI is the technician's own hive,
which is exactly the profile the per-user tweaks target. Tweaks that are *actions* rather
than states — Disk Cleanup, Temporary Files, Restore Point — are never reported as applied.

**Undo Selected** reverts the ticked tweaks. Detect → Undo is the natural pair for cleaning
up a machine someone else debloated. Undo restores the **documented Windows default** rather
than replaying a saved snapshot: keeping a state file would leave exactly the permanent
footprint this tool promises not to. For policy values that is exact — the value is deleted
and Windows reverts on its own. Anything that deleted files or removed an app cannot be put
back, and the confirm dialog names those before you commit; the row then reports e.g.
*"sync policy lifted - OneDrive is NOT reinstalled"*.

Two rules make this safe to hand to a technician:

**Restore Point runs first.** If "Restore Point - Create" is ticked it is queued ahead of
everything else — after the other tweaks have run it would be worthless. The CAUTION dialog
says out loud whether a restore point is selected, so nobody applies twenty system changes
with no way back by accident.

**Per-user tweaks land in the right hive.** The worker runs elevated, and if the technician
elevated with a *different* admin account, `HKCU` inside it is that admin's hive, not the
client's — the classic reason a tweak "applies successfully" and changes nothing the user can
see. The GUI passes its own SID and the worker writes those values to `HKEY_USERS\<sid>`.

The service tweak sets services to **Manual**, never Disabled (a disabled service something
genuinely needs fails hard; Manual still allows a trigger start), and the list deliberately
excludes BITS — this tool downloads through it — along with the core OS services.

Honest limits: `BitLocker - Disable` blocks *automatic device encryption* and reports any
already-encrypted volumes rather than silently decrypting them, which would be hours of disk
I/O on a client machine. `Microsoft Edge - Remove` runs the real uninstaller and blocks the
chromium reinstall, but Windows Update can still bring Edge back. Both report what actually
happened in the row status.



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

  "uninstall": {                         // optional: vendor uninstaller, preferred over registry
    "command": "%ProgramFiles%\\Autodesk\\AdODIS\\V1\\Installer.exe",
    "args": "-i uninstall -q -o <manifest>.xml",
    "detect": "%ProgramFiles%\\Autodesk\\AutoCAD 2026\\acad.exe"
  },

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

Add an app with `tools\New-AppEntry.ps1`, which hashes the installer and emits the JSON.

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
without running the installer at all. `tools\Test-DirtyCleanup.ps1` covers this path so the
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

**Releasing a new AppDeploy.ps1:** upload it, run `Get-FileHash server\AppDeploy.ps1`, paste
the hash into `$PinnedHash` in `go.ps1`, re-upload `go`. Optionally Authenticode-sign both.

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
| `tools\Catalog-Editor.ps1` | GUI catalog editor — add apps from a file **or a folder**, hash, package, validate |
| `tools\New-AppEntry.ps1` | Hashes an installer and emits its catalog JSON (the CLI the editor supersedes) |
| `tools\Export-AppIcons.ps1` | Extracts real product icons from installers into `icons\*.png` |
| `tools\Test-IconUrls.ps1` | Checks which `iconUrl` entries actually return an image |
| `tools\Publish-Release.ps1` | Validates the catalog, uploads to R2, pins the hash, deploys, verifies |
| `tools\Test-SilentSwitches.ps1` | Identifies an installer's packager, proposes silent switches, verifies them on a VM, writes the result back to `apps.json` |
| `tools\Test-DirtyCleanup.ps1` | Fault-injects installer failures and asserts the dirty verdict, the wipe, and the pre-tick rule |
| `tools\Test-DownloadResilience.ps1` | Interrupts and throttles downloads, and asserts BITS resumes rather than restarting |
| `tools\Test-AfterInstallList.ps1` | Asserts the editor's after-install list — order, steps it cannot edit, and its output run by the real worker |
| `tools\Test-CatalogScenarios.ps1` | Whole journeys: real zip → real dialog → real `apps.json` → re-edit → the real worker installing it |
| `tools\Test-RealUninstall.ps1` | Installs three real per-user products on this machine, removes them with the tool, deep-cleans, and cleans up after itself |
| `tools\Test-GuiBatch.ps1` | Clicks the real Install and Uninstall tab buttons — batch, Add to Queue, Cancel, the leftover preview and the wipe |
| `tools\Test-DeepBatch.ps1` | A real BITS download over loopback HTTP, Pause/Resume, the full exit-code matrix, and elevation declined |
| `tools\Test-Elevated.ps1` | **Run this elevated, by hand.** The real elevated worker, HKLM products, hosts lines, services, tasks, other profiles |
| `tools\Test-CatalogEditorGui.ps1` | The editor's main window, a real HTTP fetch, `Publish-Release` validation, and a BOM'd catalog |
| `tools\Export-UiSnapshots.ps1` | Renders the real windows to PNG offscreen, so a person can see clipping and contrast that property tests miss |

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

It also **drives the dialog itself**: `Show-AppDialog` is split at its `ShowDialog()` line, so
the first half builds and wires a window that is never shown, the real buttons are clicked by
raising their events, and the second half applies the result. No UI Automation, no human, no
window on screen. That is what caught the bug where reading an editable ComboBox's `.Text`
returned `$null` on a brand-new app — `Add an action` threw before adding anything, so the list
stayed empty and the Move / Run radios stayed greyed with no way in. Note the trap it also
exposes in *testing*: setting `.IsChecked` works on a **disabled** control, so a test that only
sets properties passes while the person in front of the dialog cannot click a thing. Assert
`IsEnabled`. 130 assertions, unelevated, `%TEMP%` only.

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

`Test-SilentSwitches.ps1` exists to retire open item #1. It reads the binary rather than
trusting the filename — NSIS, Inno Setup, InstallShield, WiX and ODIS each leave an
unambiguous marker — then proposes the switches that packager actually honours. Run
without `-Execute` it only identifies, so it is safe anywhere. With `-Execute` it runs the
installer, bounds it with a timeout (**a hang is the failure being hunted**), checks
`verifyPaths`, and only on a real pass writes `silentArgs` and clears the `VERIFY` marker.

`Publish-Release.ps1` refuses to publish a catalog that still contains placeholder
hashes, `VERIFY`-marked silent switches, or a `postInstall` `run` step with no `sha256`
(`-Force` overrides for staging). Validation runs before the wrangler check, so it is
usable as a catalog linter on a machine with no deploy toolchain installed.

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

1. **Silent-install switches are unverified.** Every Autodesk and Adobe entry is marked
   `VERIFY` in its `_installNote`. `--silent` is right for single-product ODIS and Adobe
   Admin Console packages; **deployment images** need
   `Installer.exe -i deploy -q -o <manifest>.xml` instead, and the manifest name differs per
   product. Wrong switches mean the installer opens its GUI and the batch hangs. Confirm each
   against your actual packages before using this on a client.
2. **FloorGenerator has no installer.** It ships as a `.dlm` plugin copied into the 3ds Max
   plugins folder. Either wrap it in a self-extractor, or add a `copy` action to the tool
   (cleaner, and reusable for any future plugin).
3. **Office 365 needs its whole ODT folder hosted**, since
   `setup.exe /configure configuration.xml` reads that XML from alongside itself.
4. **Icons.** `iconUrl` is wired and cached; the PNGs still need to exist. Running
   `Export-AppIcons.ps1` against your installer folder produces genuine per-product artwork
   without depending on the internet — Autodesk and Chaos product logos are not published as
   freely downloadable images, so hosting is the reliable route.
5. **Code signing.** An unsigned script downloaded over a browser will trip SmartScreen. An OV
   certificate (~$100–400/yr) plus reputation, or EV for instant reputation, is worth
   budgeting for a client-facing tool.
6. **Uninstall list includes runtimes** (Visual C++, .NET, drivers). Removing those breaks
   other software. Nothing is pre-selected, but the guard rails are on the leftover *wiping*,
   not on what a technician chooses to uninstall.
7. **Ordering is by catalog order.** Civil 3D installs onto AutoCAD, and Corona/FloorGenerator
   need 3ds Max — the current catalog order handles this, but there is no declared dependency
   mechanism if the catalog is reordered.

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
