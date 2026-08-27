# Windows test lab

A real Windows 11 machine you can wreck and reset in six seconds.

It runs in a window next to your editor. You install things in it, break things in it, then
reset it and it is exactly as it was. Your own PC is never touched and never rebooted.

---

## The problem it solves

Testing an installer means dirtying a Windows install - real installers, real registry
writes, real services, real leftovers.

Which creates a problem:

> **After one test, the machine is no longer clean, so the next test is not valid.**

App B behaves differently on a machine that still has App A's debris on it. An uninstaller
that looks like it worked may only have worked because a previous run already removed the key
it was supposed to find. Every test after the first is measuring a different machine.

The usual fixes are all bad: uninstalling by hand is slow and never truly reaches clean;
reinstalling Windows takes an hour; restoring a VM from backup takes minutes and you have to
remember to do it.

Here it costs **one command and about six seconds**, which changes what is worth testing.

---

## The whole idea in one line

**`lab` wipes the machine and starts it. That is the only command you need.**

There is no "reset" step, because resetting *is* how every run begins. You never clean up,
never uninstall, never undo. Leave the machine as wrecked as you like - the next `lab` throws
it away before doing anything else.

---

## Two workflows

Everything you will ever do is one of these two.

### A. Test something, throw it away, test again

```
lab            ->  clean machine appears
                   do whatever you want, make a mess
lab            ->  clean machine again. The mess is gone.
                   make a different mess
lab            ->  clean again
```

Same command every time. Nothing to finish, close, or restore.

### B. Change what "clean" means, permanently

```
lab -NoLaunch                    ->  clean machine appears
                                     make ONLY the change you want to keep
                                     (install something, change a setting)
labsave -To CLEAN-v2 -Promote    ->  this is now the new "clean"

lab                              ->  clean machine, WITH your change
lab                              ->  clean machine, change still there
```

### The only difference between A and B

**One command: `labsave`.**

| | |
|---|---|
| You do **not** run `labsave` | changes are temporary - the next `lab` deletes them |
| You **do** run `labsave` | changes become part of clean - every future `lab` has them |

Changes are temporary by default. `labsave` is what makes them stick.

Two things matter in workflow B:

- **Start from clean first.** Run `lab -NoLaunch`, *then* make your change, *then* save. If
  you save after a messy test session, all that mess becomes permanent too.
- **Nothing is destroyed.** `-Promote` keeps the previous clean version under another name,
  so a bad baseline can always be undone.

---

## Commands

```powershell
lab                 wipe, then run the working tree            <- the one you want
lab -NoLaunch       wipe, start nothing (for workflow B)
lab -NoRevert       do NOT wipe - keep the current mess and run again
lab -Mode Live      wipe, then run the PUBLISHED build from the server

labpro              same as lab, but the Pro machine
labsave             make the current state the new clean
lablog              show the error the machine printed
labsync -Background copy/paste from your PC into the machine (run once per session)
tolab / fromlab     one-shot copy/paste, either direction
labconn             reconnect to the Pro machine
```

`lab` runs **your working tree**. `lab -Mode Live` downloads the **published** build instead,
so it tests what actually shipped - use it after publishing a release, not while coding.

Every command takes `-VMName Home` or `-VMName Pro`; `lab` means Home, `labpro` means Pro.

---

## The two machines

| | Windows edition | Use it for |
|---|---|---|
| `Home` | Home | The honest test target - most client machines run Home |
| `Pro` | Pro | Working comfortably: copy/paste and a resizable window |

Default to **Home**. If your installer works there, it works everywhere.

Switch to **Pro** when you need to work *inside* the machine - reading logs, editing files,
digging through the registry - because it has real copy/paste and a window you can resize.

**Why they differ:** Windows Home is licensed not to accept incoming Remote Desktop
connections, and Hyper-V's "Enhanced Session" *is* Remote Desktop into the machine. So Home
can never have native clipboard or a resizable window - no setting, driver, or registry key
changes that. It is the reason the Pro machine exists. (Both have identical drivers; Pro just
shows an extra display adapter while a session is live.)

---

## How the reset works

Taking a checkpoint froze two things: the disk, and the memory.

```
<name>.vhdx      the disk, frozen - never written to again
<name>_*.avhdx   every change since: installs, registry, temp files
saved memory     RAM contents at the moment of the checkpoint
```

Resetting **deletes the changes file and reloads the saved memory**. It does not copy or
restore anything, which is why:

- it costs the same whether the test installed one app or fifty
- the disk never grows over time
- the machine *resumes* at a logged-in desktop instead of booting

Nothing inside survives a reset, and code is pushed one way only (your PC -> the machine), so
nothing a test does can reach your real files.

---

## Rules that will bite you

- **Never save a baseline from a lock screen.** The checkpoint captures memory, so if the
  machine is locked when you save, every future run starts locked and asks for a password.
  After any reboot inside the machine, log back in and reach the desktop before `labsave`.
- **Never change the machine's hardware once a baseline exists.** RAM, CPU count, video - the
  saved memory is tied to the hardware it was captured with, and the reset then fails with
  *"Microsoft Video Monitor ... Catastrophic failure"*. To change hardware: delete every
  checkpoint, change it, boot, re-save.
- **Keep one checkpoint per machine.** Each extra one adds a differencing disk that every read
  has to walk through. Five of them once cost 39 GB on top of an 18 GB base here; deleting the
  superseded four merged them down and reclaimed 35 GB. Delete old ones with the machine off.
- **The machines must use a LOCAL Windows account.** The host talks to them over PowerShell
  Direct, which cannot authenticate a Microsoft account.

---

## Display and copy/paste

**Pro:** both work natively. Drag the window edge to resize; copy/paste just works.

**Home:** neither is possible natively (see the edition note above).

- *Size* is set **inside** the machine - Settings > System > Display. Baked in at 1920x1080;
  anything you change by hand reverts on the next `lab` unless you `labsave` it.
- *Copy/paste* goes through `labsync -Background` (a live one-way mirror from your PC into the
  machine) or `tolab` / `fromlab` for one-offs.

If Home ever looks blurry and oversized, that is Windows scaling the window. It is fixed here
by marking vmconnect DPI-aware, so the picture is 1:1 and sharp - but smaller. Put that window
on an unscaled monitor for the best result.

---

## Files

| | |
|---|---|
| `Test.ps1` | The loop. `-Mode Live`, `-NoRevert`, `-NoLaunch`, `-Checkpoint`, `-VMName` |
| `Save-Baseline.ps1` | Make the current state the new clean (hand-made changes) |
| `Update-Baseline.ps1` | Reset to clean, apply a script, save (repeatable changes) |
| `Get-LabLog.ps1` | Read what the machine printed |
| `Send-LabClipboard.ps1` / `Get-LabClipboard.ps1` | One-shot copy/paste |
| `Sync-LabClipboard.ps1` | Live copy/paste mirror |
| `Connect-Lab.ps1` | Reconnect to Pro over the VMBus |
| `guest-*.ps1` | Changes applied *inside* a machine, via `Update-Baseline.ps1` |

The shortcuts (`lab`, `labpro`, ...) are functions in your PowerShell profile, so they work
from any folder. They just call these scripts.

### Rebuilding from scratch

| | |
|---|---|
| `1-Enable-HyperV.ps1` | Enables Hyper-V. Needs a real **Restart** - "Shut down" skips pending servicing and the install silently half-applies. |
| `2-New-LabVM.ps1` | Creates the machine and boots the Windows installer. Use a **local** account. |
| `3-Set-Baseline.ps1` | Preps it, saves the credential, ejects the ISO, takes the first checkpoint. |

---

## See also

`START-HERE.md` - the one-page version, if this is too much.

`../sandbox/` - a Windows Sandbox setup that starts in 20 seconds but cannot reboot, has no
live antivirus, and starts unrealistically clean. Good for a quick smoke test; this lab is
the one to trust before shipping.
