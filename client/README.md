# The compiled client

`client\PC2Go.Deploy` is the PC2Go App Installer as a signed, compiled Windows program instead
of a 22,000-line script. It is launched from **the same line** (`irm https://apps.pc2go.ca/go | iex`),
gated by the same access code, verified by the same kind of pin, and it drives the **same
elevated worker** through the same queue and status files. What changed is what runs on the
technician's side of that contract.

## Why

The script is at the ceiling of what PowerShell 5.1 and WPF on one thread can be: every read
longer than a frame has to be pumped or pushed to a runspace by hand, antivirus scans a
megabyte of script before a line runs, and the file is too big to maintain. A compiled client
removes all three at once. The rating in the 2026-09-04 handover puts the script at 6.5/10 and a
compiled, signed, async client at 10; this directory is the path there, taken in slices so the
tool keeps working between them.

## What this slice carries (client 1)

- **The window**: the same chrome, palette, tabs, tiles (36 px tile, 32 px logo, three per row),
  search, batch strip, pre-flight sheet, busy pill and overlay as the script - the XAML was
  lifted, not redrawn. `Theme.xaml` is the palette both tools share.
- **Install**, end to end: catalog fetch (gzip, `x-pc2go-code`, offline copy), icons on a
  background pump with the 24-hour `.miss` marker, the pre-flight sheet (already-installed
  skip, `requires` dependency refusal with an *Add* button, the disk verdict sentences),
  resumable downloads with one signed-URL refresh, post-install payloads fetched and hashed,
  the elevated worker launched through the identical `-EncodedCommand` stub, the status file
  read forward-only, the same words and colours on every row, live *Add to Batch*, per-row
  remove, Cancel, the run record under `runs\`, the cache sweep, and an *After installing*
  note for entries that carry `instructions`.
- **Activity Log** with copy and save; a session log under `%LOCALAPPDATA%\PC2GoDeploy-Logs`
  and a crash file under `%LOCALAPPDATA%\PC2GoDeploy` if it ever dies.
- **Everything async.** No dispatcher pumping anywhere: the catalog, the icons and the
  downloads are awaited, the 400 ms timer only reads the worker's status file.

## Slice 2 (client 2): Uninstall

- **Both lists**: Desktop programs (the Control Panel inventory as a table - logo, name over a
  size bar, publisher, install date, size, the *largest* tag, sortable headers) and Microsoft
  Store apps, with the pill counts while searching, Rescan, and the status line's reclaimed size.
- **The reads are the script's own functions.** `tools\Build-Client.ps1` lifts
  `Get-InstalledPrograms`, `Get-UninstallFamily` and the installer-family detector,
  `Get-StoreApps` with `SHLoadIndirectString`, `Scan-Leftovers` with `Get-FolderSize` and the
  protected-path list - 35 functions found by AST closure - into `reader.ps1`, embedded and run
  by the exe in a hidden `powershell.exe`. What a program is, what its quiet switch is and what
  a leftover is are decided by the same code in both clients; the exe only draws the answer.
  Another process also means the scan cannot stall the window, however slow the disk.
- **The batch**: the pre-flight sheet in its uninstall wording (already-gone rows skipped unless
  *Run the uninstaller anyway*), the `uninstall` queue entries field for field, the worker's
  ladder and lingering-window rule untouched, Force Remove (no uninstaller, straight to the
  sweep), the leftover review sheet grouped product > section with glyphs, weak matches behind a
  toggle, shared suite components warned and never bulk-selected, vendor removal tools offered
  and fetched with their hash, the `wipe` entries, Cancel at every stage, and the run record.
- **Harness seams**: `-AutoUninstall <names>`, `-AutoWipe`, `-AutoForce` beside `-AutoInstall`.

## Slice 3 (client 3): Update

- **Three sub-tabs**: Desktop apps (winget), Microsoft Store apps (a list to look at - the Store
  updates them as a set), Windows Update (recommended and optional grouped apart, driver and
  restart tags). The queued-scan rule is kept: a scan asked for while another runs is remembered
  and started when the first finishes, with the spinner saying so.
- **Reads through the reader**: `Get-WingetPath`, `Get-WingetUpgradeText`, `Get-WingetUpgrades`
  (the script's own parser of winget's table), `Get-UpdateProgramLookup` and `Find-UpdateMatch`
  (the same identity rule that gives a winget row the Uninstall tab's publisher and logo), and
  `Get-WindowsUpdateList` (the COM search) - lifted into `reader.ps1` as `winget` and
  `winupdate` ops. On this machine: 16 winget rows in 5 s, Windows Update in 12 s, off the window.
- **The batch**: the same confirm sheets, the `update` / `storeupdate` / `winupdate` queue entries
  field for field, the worker's winget ladder and Windows Update install untouched, the
  restart-needed hint after the batch, the Installed/Skipped/Applied untick rule.

## Slice 4 (client 4): User Accounts

- **The list**: `Get-UserProfiles` and `Get-LocalAccounts` (with `Get-AdminMembers` and
  `Get-AccountPurpose`) lifted into the reader as the `accounts` op, which also carries the
  signed-in name the worker cannot see for itself. The rows are Load-Users' projection field for
  field (`Services\AccountList.cs`): "Accounts in use" open, "Built into Windows, or switched off"
  folded, the badge (SIGNED IN / ADMIN / STANDARD / DISABLED), the description line. Read on
  first visit, re-read after every batch, off the window (about a second).
- **The dialog**: clicking a row opens that account's actions - only the verbs that apply to it.
  Add Account, Make Administrator / Standard user, Reset password, Enable / Disable, Delete
  (profile folder KEPT), Replace with a local admin (create + copy the safe folders + disable the
  old one, as an ordered `chain`). The refusals that save a UAC prompt are here (last enabled
  Administrator, that is you, built-in); the worker re-checks all of them because the queue file
  is user-writable.
- **The entries**: `newuser` / `setadmin` / `setpassword` / `toggleacct` / `deleteaccount` /
  `migrate`, with `techUser`, exactly as Start-UserBatch and Start-UserChain write them. Password
  fields are DPAPI-protected (LocalMachine, `DPAPI:` prefix) BEFORE the worker is launched, so a
  machine where DPAPI fails never leaves an elevated process polling a queue with no end marker.
  The safe-folder pick for Replace with a local admin is the script's own `$script:MigrateDefs`,
  through the reader's `migrateitems` op.
- **After the batch**: the closing sheet says per row what the worker wrote (a one-row batch's
  "1 completed, 0 failed" is the least useful sentence there is), the password boxes are cleared,
  the list is re-read. The run record's `kind` is `users`.

## Slice 5 (client 5): Toolbox

- **The tables** (`Services\Toolbox.cs`): the ten fixes and the fourteen legacy panels, verbatim
  from the script. Fixes run elevated through the same one-UAC queue (`{id:"fix-<id>",
  action:"fix", fix}`); a panel just opens, unelevated, straight from the GUI - Windows elevates
  it itself if it needs to. The tiles carry the real Windows icon out of the module
  (ExtractIconEx: the named DLL, then the .cpl itself, then shell32's generic one).
- **AutoLogon** has its own dialog - it IS the confirmation - and ships `alUser` / `alPassword`
  with the password DPAPI-protected before the worker exists. The password box is cleared when
  the batch ends (the script leaves it).
- **The closing sheet** lists each row's own sentence: the Slow PC verdict and its report path
  live in the worker's detail, and a bare "1 completed, 0 failed" would hide exactly what the
  diagnosis was run for. The run record's `kind` is `tools`.

## Slice 6 (client 6): Data Backup

- **One engine, three destinations**, the mode in one field: Backup (an account or folders and
  drives, to a folder, a stick or a share), Restore (a backup this tool wrote, into an account or
  back where it came from), Between accounts. The picker moves between the columns as the mode
  changes; the item list is built from the SOURCE - a restore lists what the backup holds, from
  its manifest.
- **Reads through the reader**: `migratedefs` (the table itself, so there is no second copy),
  `manifest` (pc2go-backup.json, BOM tolerated), `foldersize` (the script's `Get-FolderSize`,
  the running total in the progress file every 200 folders - the measuring pass, with Stop
  measuring), `shares` (`Get-AllShares`, SMB module or `net share`), `netscan`
  (`Find-NetworkHosts`: the /24 sweep on TCP 445, every PC that answers written to the progress
  file the moment it does) and `hostshares` (`net view \\PC`, with the "would not say" sentinel).
- **Reaching a share** (`Services\NetShare.cs`): WNetAddConnection2 with the script's rules -
  NULL never "", 1219 drops the old identity, only 5 and 1326 raise Windows' own credential
  prompt (CredUIPromptForWindowsCredentials, generic, buffer zeroed). The share tree loads
  lazily, capped at 400 folders, said when trimmed.
- **The batch**: the `migrate` entry field for field (`src, srcKind, paths, restoreTo, dstUser,
  dstPath, dstKind, netUser, netPassword, items`), `netPassword` DPAPI-wrapped, and the
  `sharesetup` / `shareon` / `shareoff` / `sharedown` chain for Share this PC. Every refusal the
  script makes before the confirm - inside-itself, contains-itself, no manifest, same account,
  not enough disk - is here with the same words; the worker checks them all again.
- **After the batch**: a migration re-reads the accounts (it creates the destination profile),
  a share re-reads the shares, and the closing sheet says per row what the worker wrote, with
  the "on the other PC, press Network..." lead after a share that worked.

## Slice 7 (client 7): Optimize - Tweaks and Cleanup

- **The table through the reader** (`tweakdefs`): the script's 66 rows, of which the 47 Tweaks
  rows and 5 Cleanup rows are drawn here - pre-configured, everything ticked except CAUTION.
  The 14 Gaming rows are the last slice; the Gaming sub-tab says so.
- **The detectors** (`tweakprobe`): `$script:TweakTests` - the script's own per-row
  scriptblocks - lifted with `Test-RegVal`, `Get-RegVal`, `Test-AppxAbsent`, `DebloatPacks` and
  `OemBloatPatterns`, and run in the reader as the technician, so HKCU is the technician's hive.
  A probe answers true / false / null; null is an action, not a state, and is never claimed
  applied. Detect Applied, the pre-apply check (a true row is reported and never queued, a
  debloat row is never pre-skipped), and the post-apply confirmation all use the one op.
- **The batches**: `tweak` / `untweak` entries with `userSid`, the restore point queued FIRST,
  the CAUTION and Windows.old confirm sheets, the undo sheet naming the one-way rows, the
  "nothing to do" path, `Still checking` while the reader probes.
- **After the batch**: the WM_SETTINGCHANGE broadcast (driven by what was applied), one
  Explorer restart per batch when a row changed what it draws, and Confirm-AppliedRows -
  "Applied - could not confirm on this machine" is a warning, not a failure. Dismissing the
  strip clears the verdicts off every Optimize and Toolbox row, as the script does.

## Slice 8 (client 8): Firewall

- **The scan through the reader** (`firewall`): `Get-FirewallBlockMap` (both firewall
  cmdlets, joined by InstanceID, paths expanded), then Load-Firewall's own loop with the
  script's helpers - `Resolve-AppRoot`, `Test-FwRootAllowed`, `Get-RulesUnder`,
  `Get-VendorFolder` - and `$script:FwProtectedRoots`. One row per installed program that lives
  somewhere blockable (on / off rule counts), one row per vendor folder of stray rules with the
  exact rule names, and the flattened map for the detail view. `Add-Log` is stubbed to stderr
  because the rule read logs its own failure. A second op (`fwmap`) re-reads the live table at
  confirm time for the foreign-rule count.
- **The rows**: the Load-Firewall projection - BLOCKED / RULES OFF / ORPHAN badges, the disabled
  count in `OrigState`, stray rows `RegKey = unmatched` with `CleanTokens` = rule names, the
  program's own icon. Blocked on the left (grouped, strays last), everything else on the right,
  the "..." detail view listing the covered executables or previewing what Block would create.
- **The batches**: `fwblock` / `fwunblock` entries `{id, action, app, publisher, build, root,
  group}` and `fwunblockrules` `{id, action, app, rules, folder, group}` for strays - the
  script's two literals, key for key. The Block sheet skips strays, names running programs
  and already-blocked rows; Unblock and Remove ALL say how many rules were made by something
  else. The summary counts what was actually new, skipped and removed; the tab re-scans after
  every batch.

## Client 9: the Data Backup first frame

The tab's mode sync runs first and synchronously when the tab is shown, so the first frame is
already the right layout (the folder picker in the TO column) rather than the window's default
one for the seconds the two reader reads take. The empty-state sentences wait for the accounts
read to answer. Every other tab paints a spinner or the busy overlay before its first await.

## Slice 9 (client 10): the download path

- **`Services\SegmentedDownloader.cs`** is the script's Invoke-SegmentedDownload: a file over
  16 MB comes down over 16 connections as a queue of ~64 chunks written straight into one
  pre-allocated `.part`, with a `.parts` journal beside it (`{total, chunk, done[], etag}` - the
  script's shape, so either client resumes the other's file). A dropped socket is a retry on
  that chunk for as long as the batch runs - at once if it was delivering, with 2-30 s backoff
  if it yielded nothing; faults that cluster halve the worker count, quiet raises it back, and
  the settled count carries to the next file. Fatal only: Range refused, the object changed
  (If-Range / ETag), a link that expired and could not be refreshed - those fall back to the
  single-connection `Downloader` (unchanged, still the path for small files and vendor CDNs
  that will not do Range). `Downloads.FetchAsync` is the one place that decides.
- **What survives what**: a crash, a kill, a reboot or a closed window leave the `.part` and the
  journal; the next run resumes every piece from where it stood and says "Resuming X - N MB of
  M MB already here." At launch the client offers to resume interrupted downloads it finds in
  the cache (Offer-ResumeDownloads). Internet loss mid-file shows "Internet lost - waiting; N%
  kept, resumes on its own" and the workers reconnect when it returns; nothing is refetched.
- **The row's words** come from the download itself: "Downloading 43%  9.1 MB/s  -  2m 10s
  left", "reconnecting 3 of 16", the two warnings above.
- **`-Download url -Dest file -Size n -Out report.json [-Streams n] [-ChunkFloor bytes]`** runs
  the same `Downloads.FetchAsync` headless. Test-Client puts a loopback Range server in front of
  it: a clean 48 MB run, the process KILLED mid-file and resumed by the next run, a server that
  cuts every third response, a server that goes dark for three seconds, a server that refuses
  Range (falls back to one connection) - byte for byte each time.

## Client 11: the batch order

- **Smallest first.** A batch used to download in catalog order, and the catalog leads with the
  Autodesk suite - so with Revit ticked nothing installed for hours while its 14 GB came down.
  `BatchPlan.Order` now sorts the pre-flight sheet, and so the batch, smallest first: a 7 MB
  Office setup installs within seconds while Revit downloads over the 16 connections. A base is
  still moved ahead of everything that requires it, and a file with no known size goes last.
- **Fail open on an unknown requirement.** A `requires` id the catalog does not know is logged
  ("X requires 'autocad', which is not in this catalog - the dependency check was skipped for
  it.") and skipped, as the script does. The exe used to disable Go for it, which made AutoCAD
  Electrical uninstallable while its entry said `autocad` and AutoCAD's id was `autocad-2027`.

## Client 12: every press answers at once

Audit of every button whose work takes seconds: Share this PC opened its dialog only after the
share list had been read; Stop sharing read the list before its confirm with nothing on screen;
Unblock and Remove ALL read the live rule table behind a wait cursor only; Block Internet Access
asked every process for its path on the window thread. Each now shows the busy pill or a note in
the dialog first, and the process walk runs off the window. Reads in other tabs during a batch
are by design: the scratchpad Concurrency-Probe ran Detect Applied, the Firewall scan, the
Uninstall scan, the accounts read and the Toolbox while a 48 MB download was in flight - all
answered, the download finished byte for byte, Undo Selected was refused with "Still busy", no
crash file.

## Client 13: more to tweak and clean, and a Startup sub-tab

- **Three performance tweaks** in the script's table, so both clients get them: Search Indexer
  Light Mode (classic scope, no indexing on battery, yields under load), Defender Scans Low
  Priority (20% CPU cap, idle scans throttled too, through `Set-MpPreference`), Storage Sense
  Monthly Cleanup (temp files and 30-day recycle-bin items; Downloads and OneDrive never
  touched). Each has a detector, an Apply and an Undo.
- **Four cleanup rows**, each reporting reclaimed space like the others: Browser Caches (cache
  folders only, never cookies or passwords; files a running browser holds are counted and left),
  Crash Dumps and Error Reports (MEMORY.DMP, minidumps, live kernel reports, both WER queues),
  Delivery Optimization Cache, and under CAUTION System Restore Space capped at 5% (older
  restore points go with the space).
- **A Toolbox fix**, Search Index Rebuild: stops Windows Search, drops Windows.edb or Windows.db,
  lets it rebuild; says search is patchy for an hour.
- **The Startup sub-tab** (exe only - the script client has no UI for a per-machine list). The
  reader's `startupapps` op runs the script's `Get-StartupEntries`: both Run keys, the 32-bit
  view, both Startup folders, and for each Task Manager's StartupApproved verdict. Rows are
  grouped "Starts with Windows" / "Switched off"; tick and Switch Off Ticked writes the same 12
  bytes Task Manager writes (03 + the time), Switch Back On writes 02. Nothing is deleted or
  uninstalled, and Task Manager shows and can undo the same state. Worker actions `startupoff`
  / `startupon` take `{id, name, location, userSid}`; the HKCU verdicts land in the technician's
  hive through the SID. The list is re-read after the batch.
- **The closing summary of a cleanup batch** adds what it gave back ("4 completed, 0 failed,
  3.1 GB reclaimed"), summed from the rows' own measurements, and the free-space line refreshes.

## Client 14: the Toolbox in three sub-tabs

- **Tools** is what the tab was: the fix rows and the legacy panels. The slow-PC diagnosis is no
  longer a checkbox among them.
- **Diagnose** is the slow-PC report as a screen. Run Diagnosis runs the same `slowpc` fix
  through the worker; the report file it writes is read back and drawn as seven layers in
  reading order - hardware, what is running, security software, memory, background work,
  startup, faults - each with its verdict and the lines behind it. The seven cards are drawn from
  the first frame, grey and "Not read yet", and each turns as the worker reports its layer - blue
  while reading, green for OK, red for a finding. The most recent report in the cache fills them
  in on open, so a machine diagnosed last visit is not blank. (Client 14 first shipped this as a
  bare explainer with a button, which read as an empty tab - the cards ARE the screen.)
- **Disk Management** draws every disk as a proportional bar from the reader's `disks` op (the
  script's `Get-DiskLayout`: partitions in offset order, the shrink floor from
  Get-PartitionSupportedSize, the gap behind each, recovery partitions by GPT type, WinRE's
  partition from ReAgentC when elevated). Each volume gets Shrink and Extend, and the reason in
  words whenever Extend cannot simply extend: free space behind it (plain extend), the recovery
  partition between it and the free space (Move recovery + Extend, five steps, each reported
  before the next runs), a data partition behind it (refused, named), a dynamic disk (refused).
  Worker actions `diskshrink` / `diskextend` / `diskextendmove` take `{disk, partition, bytes}`,
  never a drive letter. Rails: dynamic disks, a non-recovery blocker, BitLocker on the boot volume,
  and the recovery environment re-enabled and verified afterwards.
- **Tested** on a throwaway VHDX by `tests\Test-DiskTab.ps1` (elevated): shrink, extend back, the
  rails, extend past a recovery partition with the data intact and a new 1 GB recovery partition
  at the end, and the refusal when nothing is left. The ReAgentC steps run only on a real Windows
  disk and are for the lab VM.

## Client 15: a fix under every finding

- **The remedy table** is the script's `$script:DiagRemedies`, one row per sentence
  `Get-SlowPcReport` can say, read through the reader (`diagremedies`). Each row: the layer, a
  regex over one finding, what the tool does about it (tweak | fix | cleanup | startup | uninstall
  | backup | none), the tweak or fix id, the button label and the sentence under the finding.
  Test-Client extracts every `$lN += '...'` sentence from the worker's AST and holds the two
  lists in step both ways - a new finding without a remedy, or a remedy no sentence triggers,
  fails the suite.
- **On the card**, a red layer lists its findings one by one; under each, the remedy sentence
  and a button when the tool can do it. One click runs a tweak or a fix through the worker with
  every existing rule (pre-apply probe, restore point first, CAUTION sheet; Restart Now confirms
  first). Where a person must choose, the button opens the tab with the rows ready: Cleanup with
  the safe set ticked, Startup with the named entries ticked, Uninstall filtered to the process
  or the second antivirus, Data Backup for a failing drive. Hardware findings say so and have no
  button. A finding no row knows still gets a line, without a button.
- **New fix** `restart` (Restart Now - 60 Second Warning): `shutdown /r /t 60` with the reason on
  screen; "shutdown /a" cancels it. Offered for "a reboot is already pending".

Not carried yet - the Gaming sub-tab of Optimize (the user's order: last).

## Client 16: logos where they were missing, and a tick you can see

- **Install tab logos.** The exe's icon cache was keyed by the app id alone and remembered any
  failed fetch as a miss for a day. Test-Client's launch section closes its window a second after
  the catalog loads; the four logo fetches in flight died with the HttpClient, four `.miss` files
  landed in the cache the real launches share, and the technician's own client showed letters
  for the rest of the day. Now the cache key is the id plus a hash of the URL (one server's logo,
  or miss, never stands in for another's); a miss is written only when the server answered 404 or
  410 - never for no network, a timeout or a closing window - and is believed for an hour, not a
  day; the icon folder is no longer deleted at close, so "disk first" is real and the tiles are
  logos from the first frame at the next launch. Old id-keyed misses are cleared once at start.
- **Startup sub-tab.** Rows have their own style (`DetailRow`, since client 17 shared with the Toolbox fixes): a tick that shows, the program's
  own icon, the entry name over its command, the OFF badge. `AcctRow` was borrowed before, and its
  template has no checked state at all. The reader's `startupapps` rows carry `Exe`
  (`Resolve-StartupExe`: quotes and arguments stripped, %variables% expanded, an unquoted path
  with spaces grown token by token, a Startup-folder `.lnk` resolved to its target); the row asks
  the icon pump for that file's icon, as the Uninstall and Firewall rows do.
- **Test-Client** skips its launch section, saying why, when a PC2Go client (exe or script) is
  already open on the desktop - a launch then only raises "already running" on the technician's
  screen. New pins: the reader row shape, seven `Resolve-StartupExe` cases, the cache key on both
  sides (C# and PowerShell compute the same name), and that no run of the launch section leaves a
  miss for a logo the edge serves. The download outage scenario now pins the outcome (waited out
  on the multi-connection path, no failure, no fall-back, still running when the server went
  dark) instead of a retry line: whether a worker even sees the outage as an error depends on what
  was in flight when the loopback listener closed - HTTP.sys parks the other connections and
  hands them to the listener that comes back - and one run in about five passed the dark window
  with no error at all. 326 pins; 311 when the launch section is skipped.

## Client 17: the Toolbox, looked at again

A second pass over the three Toolbox sub-tabs, from screenshots of the real thing and the user's
own report, which said "spinning disk" and "182 read errors - back this machine up NOW" about a
USB backup drive while Windows runs from an NVMe SSD.

- **Diagnosis, hardware layer** (`Get-SlowPcReport` in the worker): only the disk Windows runs
  from (Get-Disk IsBoot/IsSystem, matched to the physical disk's DeviceId) decides "spinning
  disk"; other disks are listed with their names, marked "(Windows)" where it applies, and not
  judged. SMART is read per disk and the sentence names the drive: read errors on the Windows disk
  still say "back this machine up NOW"; on any other disk they say "copy what you need off it".
- **Diagnosis, what is running:** CPU is judged per PROGRAM, summed over its processes, so a
  browser with fifty processes is one finding instead of two or three, and the program must beat
  the shell AND average more than 2% of one core over the uptime - an editor at 0.8% on a
  workstation up for days is a person working, not a rogue helper. A browser gets its own
  sentence ("- a browser: tabs and extensions, not Windows") and its own remedy row, advice with
  no button, placed before the generic row because the first match on a layer wins. On this
  machine the verdict went from three sentences (firefox twice, VS Code) to one.
- **Tools sub-tab:** fix rows use the detail row style, so each fix shows its hint under its name
  - what it does and what it costs was hidden in a tooltip. The fix list takes the width; the
  legacy panels are fourteen captioned tiles, four to a row - fourteen bare icons (three shields,
  two monitors) were a guessing game.
- **Diagnose sub-tab:** one Run Diagnosis button (the header card's), greyed while a run is in
  progress; the dash says what the last run found and when ("6 finding(s) in 5 of 7 layers -
  2026-09-05 12:58") instead of repeating the report path the header already shows.
- **Disk Management:** a gap under 8 MB is alignment slack, not free space - Extend no longer
  offers to join one megabyte to a USB volume, and names the partition behind it instead. Slivers
  on the bar (the 16 MB reserved partition) show no label; their tooltip carries the name.
- Test-Client pins the new hardware and running-programs rules in the rendered worker, the browser
  row's place in the table, and the slack plan.

## Client 18: "so what do I do?", and a spinner on the disks

- **What to do.** The Diagnose screen gains one card under the header that answers the question
  the per-finding buttons never quite did. Every finding with a remedy becomes a numbered step,
  in layer order (hardware first, then what runs in the background), each with its button; the
  findings without one are listed under "Good to know - nothing to run". When nothing is
  actionable - or nothing was found at all - the card says so honestly and lists the approach
  worth taking on any slow PC: Free up space (Cleanup, safe set), Switch off what starts with
  Windows (Startup), Apply the performance tweaks (the Tweaks sub-tab, a new navigation kind
  `tweaks`), Restart then diagnose again (the Restart Now fix, confirm sheet first). The card is
  hidden while a run is still reading and before any report exists. `Diagnosis.Plan` is pure;
  the self-test projects it on a two-finding report, a clean report, a note-only report and a
  half-read run. Seen on the first real report: read errors on a USB disk became step 1, "Back
  this machine up" - wrong for a drive that is not the Windows disk. The worker now says two
  different sentences (the Windows disk: back up NOW; any other disk: "not the Windows disk -
  copy what you need off it") and the table answers the second with a note, placed before the
  backup row because the first match on a layer wins.
- **Disk Management indicator.** The read takes seconds when elevated (each volume is asked how
  far it can shrink), and the only sign of it was a faint centred line. Now a spinner turns
  beside "Reading the disks...", the strip's hint says what is being read, and Rescan is greyed
  until the answer lands.

## Client 19: Defender, and what a rebuild proved

Client 18's published file was quarantined on the user's machine as `Trojan:Win32/Bearfoos.B!ml`
- a cloud machine-learning verdict, not a signature - about twenty seconds after it started. The
local scan had passed; the diagnosis it was running finished first. The change in 18 was a card,
a spinner and two sentences. To learn whether the verdict was about the change or about the
file, the scratchpad `Av-Probe.ps1` copies a build under a new name (optionally marked as an
internet download) and watches Defender's operational log for a verdict on that path:

- the published bytes: flagged in 3 seconds - a cached verdict for that hash;
- the same source with one string changed: clean through 75 s of real-time watch, an on-demand
  scan, and 180 s marked as a download; client 19 likewise.

The verdict was bound to one file's hash, not to anything in it. Client 19 is that rebuild with
real version metadata - FileVersion 0.19.0 (Version moves with BuildTag, client N -> 0.N.0),
description "PC2Go App Installer", a comment - because reputation systems weigh a binary whose
version never changes. Until the exe is code-signed, every build is an unknown unsigned binary
carrying 460 KB of PowerShell and each publish is a new draw; the probe now runs before every
publish. `Build-Client -SignThumbprint` and go.ps1's signature check are already in place for
the day a certificate exists.

## Client 20: one line per row, real plurals, one count per screen

- **Compact rows with hover.** The Startup entries and the Toolbox fixes are one line each again;
  the explanation (the fix's hint, the startup command) is the row's tooltip, quick to appear and
  slow to vanish, shown from anywhere on the row. The user's call, made with the audience in mind:
  a handful of technicians who know the tool by heart, and the consequences (30 minutes, a reboot,
  port 22) restated on the confirm sheet at the moment of commitment. Firewall and Uninstall keep
  their second line - publisher and version are identity, not explanation.
- **Real plurals.** "3 fix(es)", "0 of 14 startup entr(y/ies) ticked", "5 finding(s)" read as
  unfilled templates. `Format.Count(n, "fix", "fixes")` replaces 106 of them across the client
  (a scripted rewrite, every replacement reviewed, fifteen sentences re-worded by hand where the
  verb no longer agreed). The worker's diagnosis sentences use a nested `Plural` helper the same
  way, and the remedy table's regexes moved to the words that never change ("back this machine
  up NOW", "worth reviewing: (.+)", "suspect the drive") so the count in front can be a real word.
- **One count per screen.** Group headers carry the counts; the strip hint and the dash no longer
  repeat them. Startup's hint says what the buttons do instead of "7 start with Windows, 7
  switched off" under headers that said exactly that; the Toolbox dash says "Tick the repairs to
  run" until something is ticked; the Firewall dash likewise; the Diagnose dash keeps only "Last
  run <stamp>", since the What-to-do card counts the findings.

## Client 21: one icon size

Install, Uninstall and Update drew their icons in a 36 px tile (32 px image, 18 px glyph);
Firewall used 32 / 30 / 13 and the Startup and fix rows had shrunk to 26 / 24 / 11 in client 20.
The user saw it ("the icon sizes are different all over the tabs"). Every list now uses the
Install size. The accounts avatar (a 40 px circle with an initial) is not an app icon and stays.

## Client 22: the Gaming sub-tab - the last slice

Every tab is in the exe now. Optimize > Gaming carries the script's fourteen gaming rows (ten
pre-ticked, four CAUTION) from the same `tweakdefs` read, with the same Apply / Undo / Detect
machinery as Tweaks, and its evidence tool:

- **Measure** runs the script's own latency probe, `Measure-GamingLatency`, lifted into the reader
  as op `gameprobe` and run unelevated exactly as the script client runs it (timer granularity,
  preemption jitter p50/p99/max over three rounds after a warm-up, DPC and ISR load). Its
  "measuring..." narration reaches the strip's hint line through the progress file - in the
  reader the window's hint line is a stand-in object whose setter writes that file.
- **The probe, explained** (the user: "I cannot see or read or know what is going on - think
  out loud, like the Diagnose tab"). Three cards above the rows, one per measurement, drawn grey
  before anything runs ("Not measured yet"), turning one by one as the probe narrates ("warming
  up", "round 2 of 3", "sampling 1 of 3"), then the number large, its meaning in one line, a
  verdict in a colour, and what to do when it is amber or red. The thresholds are the ones a
  player feels: the worst 1% of moments under 0.2 ms is smooth, up to 1 ms is felt in
  competitive play, over that is visible stutter; driver load under 1% is quiet, a few percent is
  one busy driver, over 5% a misbehaving one; the timer is context, never a fault. After Apply
  Gaming the before stays on each card, the after joins it ("0.600 ms -> 0.100 ms"), and a
  verdict card above says IMPROVED / no measurable change / WORSE with the BEFORE/AFTER line.
  Every Measure and every before/after is written to `gameprobe-<stamp>.txt` beside the slow-PC
  reports, for the invoice. `GameCards` is pure and pinned: thresholds, the narration mapping,
  the after column, the report's shape.
- **Apply Gaming** is the script's sheet word for word: un-ticks "Xbox and Gaming - Remove" on
  Tweaks (a gaming machine keeps Game Pass), says so when the Xbox apps are already gone, names
  each ticked CAUTION row's own cost (`Optimize.GamingCosts`, the script's `$costs` table key
  for key, pinned), then measures a baseline, runs the batch, measures again and compares.
  `Optimize.CompareProbe` is `Compare-GamingProbe` with the same gate - a move of more than 0.2 ms
  AND more than 30% before it is called a change; a WORSE verdict is re-measured once and the
  better kept; HAGS says "after the reboot". Test-Client runs the script's own Format-/Compare-
  GamingProbe on the same numbers and pins the exe's sentences to them.
- The detectors for the gaming rows (`Test-GameAcIndex`, `Test-NvSetting` with the NVAPI type
  source) are lifted into the reader, so Detect Applied and the pre-apply check work on this tab
  like every other. The worker already carried the apply/undo cases and the NVAPI source.

The scratchpad the session harnesses lived in was cleared by Temp cleanup between sessions;
`Shot-Uia.ps1`, `Av-Probe.ps1` and `Verify-Pin.ps1` now live under `tools\dev\`.

## Client 23: the audit slice

Seven reviewers read the whole product in parallel - three hunting bugs (batch engine, tab
code-behinds, services and parsing), one tracing the technician's journeys end to end, one on UX
and visual feedback, one on speed and error handling, one on the elevated worker. Every finding
below was re-verified here before it was touched.

**The progress bar and the batch strip** (the user, from a screenshot: "this bar doesnt move when
there is a progress, on all of them not just on cleanup"). `BarOverall` was advanced by exactly one
function, called only from the download handler, and seven of the eight batch starters never reset
it - so every worker-only batch showed the previous batch's leftover value, frozen. It now runs off
settled rows once the worker is executing (`BatchPlan.OverallFor`, pure and pinned), keeps the byte
figure during downloads, and sweeps - a new indeterminate state in `ThinProgress`, which had none -
when a batch has nothing measurable rather than showing a number it cannot support. The strip
follows the working row (`BatchPlan.ActiveRow`) so a batch of twenty does not leave the technician
watching "Queued", and folds itself on a clean finish while staying open on a failure.

**Four ways the tool could be left unusable, all fixed:**

- `BtnInstall.IsEnabled = false` appeared in eight batch starters and `= true` in none. Any
  firewall block, tweak, account change, Toolbox fix, backup or share killed the Install button for
  the rest of the session, silently. One line in `FinishBatch` covers all eight.
- Nothing watched the elevated worker. `Process.Start` discarded the handle, so a worker killed by
  endpoint protection left `_phase` at "Install" for ever, every tab refusing "Still busy", and
  Cancel doing nothing at all (its escape hatch tests `!_worker.Started`, which is false). The
  handle is kept now and `CheckWorkerAlive` turns its death into a sentence within one tick.
- Declining UAC on any of the ten worker-only starters aborted into nothing: `AbortBatch` calls
  `FinishBatch`, which returns on its first line unless a batch is under way, and those starters
  set the phase *after* `Start()`. The strip stayed live with its close button hidden.
- Cancelling a batch with apps queued for a next batch ran that next batch anyway, with a fresh UAC
  prompt, because `_deferred` was only ever emptied inside `FinishBatch`.

**Two dangerous holes in the elevated worker:**

- `Test-WipeAllowed` protected `%SystemRoot%` by **exact equality**, so `C:\Windows\System32\config`,
  `\Boot`, `\INF` and every other child passed every guard and reached `Remove-Stubborn`, which
  takes ownership of the tree and schedules whatever it cannot delete for delete-on-reboot. That is
  an unbootable customer machine. A prefix refusal was added - the same test `Test-FwRoot` already
  does on a far less destructive path - and verified by lifting the repaired guard out of the
  rendered worker: seven dangerous paths refused, real leftovers still allowed.
- `userSid` came off the queue unvalidated and is the one queue value used to *build* a path. The
  `recyclebin` tweak joins it to `<drive>:\$Recycle.Bin\`, where `..` normalises to the drive root -
  whose contents that tweak then deletes recursively, on every fixed drive and every attached USB
  disk. `Get-SafeUserSid` now refuses anything that is not a SID, at all seven assignment sites.

**Selection could act on rows the technician could not see.** Select All, Clear All and Reset took
the backing collection rather than the filtered view, so with a word in the search box "Select All"
on Cleanup ticked every cleanup action while the list showed two - including the one that removes
Windows.old for good. They act on `GetOptVisible()` now. Separately, `_startupView` and `_gameView`
carried the search filter and were never refreshed by `ApplySearch`, so a term present when either
list first loaded left that sub-tab permanently short.

**Also:** a tweak batch left every Applied row ticked, so "undo the one I got wrong" took all twelve
- `FinishBatch` now unticks anything that succeeded and leaves failures ticked, which is what makes
"press it again" the retry.

## How it is built

```
tools\Build-Client.ps1            # -> client\dist\PC2Go.Deploy.exe and its SHA-256
tools\Build-Client.ps1 -SignThumbprint <thumbprint>   # once there is a code-signing certificate
```

1. **The worker is lifted out of `server\AppDeploy.ps1`** by AST - the `$workerScript`
   here-string with its three placeholders rendered exactly as `Start-Worker` renders them -
   and embedded in the exe. The script stays the single source of the worker; the rendered
   copy (`Resources\worker.ps1`) is generated on every build and never versioned.
2. `dotnet build`, Release, **.NET Framework 4.8** - already on every Windows 10/11 the go line
   is pasted into, so nothing is installed on the client. No NuGet packages: one exe, one hash.
   The SDK is user-local: `irm https://dot.net/v1/dotnet-install.ps1 | iex` puts it under
   `%LOCALAPPDATA%\Microsoft\dotnet` without elevation; `Build-Client.ps1` finds it there.
3. The exe lands in `client\dist\` with its hash beside it.

## How it ships

```
tools\Publish-Release.ps1 -Client                 # upload the exe, pin CLIENT_EXE_SHA256
tools\Publish-Release.ps1 -Client -BootClient exe # ...and make it what /go launches for everyone
```

- The Worker serves `/PC2Go.Deploy.exe` behind the access code and rewrites two more lines into
  `go.ps1` as it serves it: `$Client` (from `BOOT_CLIENT`) and `$ExeHash` (from
  `CLIENT_EXE_SHA256`), the same way it has always rewritten `$BaseUrl` and `$PinnedHash`.
- `go.ps1` takes the exe **only with a real pin**. `BOOT_CLIENT = "exe"` with an empty pin
  launches the script, verified as it always was - an unverified exe is never run.
- **Try it before flipping it**: `irm https://apps.pc2go.ca/go-exe | iex` forces the exe for
  that one run; `/go-script` forces the script. `BOOT_CLIENT` is what `/go` does for everyone.
- Cached by hash under `%LOCALAPPDATA%\PC2GoDeploy\PC2Go.Deploy.exe`, re-fetched only when the
  pin moves. A signature, when there is one, must be intact; the pin is the trust root either way.

## How it is tested

- `tests\Test-Client.ps1` (host, 142 assertions): builds, then holds the exe to the script's
  contract **by the script's own definitions lifted by AST** - the keys of `Enqueue-Install`'s
  queue entry and of a post-install step, `Start-Worker`'s stub line for line, the embedded
  worker and reader byte for byte, `Format-Size`/`Format-Eta`/`Get-DiskVerdict` on the same
  inputs, the catalog rules on the real `apps.json`. The reader is run on the host and its
  inventory compared row for row with the same functions lifted in-process; a synthetic product
  proves the leftover scan's pre-tick and remover rules. Then three real launches against a
  loopback edge (plain, with a code, with a 403) read back through the session log. Then the
  bootstrap's choice, the Worker's routes, `wrangler.toml` and Publish.
- `tests\Test-ClientInstall.ps1` (**lab VM only**): the exe installs Notepad++ for real through
  the real elevated worker from a loopback catalog, closes itself, and the run record, the
  status file, the registry and `Program Files` are read back. A second run proves the sheet's
  already-installed gate. Then the Uninstall tab removes it again - list, sheet, worker, sweep,
  wipe - and the machine is read back once more. Harness seams: `-AutoInstall <ids>`,
  `-AutoUninstall <names>`, `-AutoWipe`, `-AutoForce`, `-AutoClose`; never set by go.ps1.
- `-SelfTest -Out <file> [-Catalog <apps.json>]` writes one JSON report from the product's own
  code with no window; the host suite reads it.

## The path to 10, from here

1. ~~Uninstall~~ - slice 2, done. ~~Update~~ - slice 3, done. ~~User Accounts~~ - slice 4, done.
   ~~Toolbox~~ - slice 5, done. ~~Data Backup~~ - slice 6, done. ~~Optimize: Tweaks and
   Cleanup~~ - slice 7, done. ~~Firewall~~ - slice 8, done.
2. The **Gaming** sub-tab, last (the user's order). Same reader pattern: lift the script's
   functions by closure, run them in the other process, draw the answer. Gaming needs
   `Test-GameAcIndex`, `Test-NvSetting` and `$script:NvApiSource` in the reader, plus the
   latency probe (`Measure-GamingLatency`) before and after Apply.
3. Retire `AppDeploy.ps1`'s GUI; the worker becomes its own file with its own pin.
4. Port the worker to C# (a service over a named pipe instead of a queue file) once every
   installer family is proven on the VM against the compiled path.
5. A code-signing certificate: `Build-Client.ps1 -SignThumbprint`, and the elevation prompt
   says PC2Go instead of PowerShell.
