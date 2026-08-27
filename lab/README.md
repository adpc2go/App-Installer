# App-Installer test lab

Real Windows 11, wiped clean in under ten seconds, host never rebooted.

## Two VMs, on purpose

| | Edition | Loop | Why it exists |
|---|---|---|---|
| `Home` | Windows 11 **Home** | ~6s | What most client machines actually run - the honest test target |
| `Pro` | Windows 11 **Pro** | ~10s | Comfortable to work in: native clipboard, resizable window |

Windows **Home cannot accept an inbound RDP session**, and Hyper-V's Enhanced Session Mode
*is* RDP into the guest. So the Home VM can never have Enhanced Session, native clipboard,
or a resizable window - through any setting, driver or registry key. That is a licensing
gate in the Home SKU, not a fault. It is the entire reason the Pro VM exists.

Both guests have identical drivers. Pro shows a second display adapter in Device Manager
only because an RDP session is live; it disappears when you disconnect.

## Daily use

From any directory - these live in your PowerShell profile:

```powershell
lab -Mode Live      # Home: wipe, then run  irm https://apps.pc2go.ca/go | iex
lab                 # Home: wipe, push the working tree, run server\AppDeploy.ps1
labpro -Mode Live   # same, against the Pro VM

lab -NoRevert       # do NOT wipe - inspect a failure before losing it
lab -NoLaunch       # wipe and boot, start nothing - for editing the baseline

lablog              # guest launch transcript
labsync -Background # live host->guest clipboard mirror (Home)
tolab / fromlab     # one-shot clipboard, either direction
labsave             # freeze the current guest state as a baseline
labconn             # mstsc over the VMBus (Pro)
```

Or call the scripts directly with `-VMName Pro`. Credentials are stored per VM under
`%LOCALAPPDATA%\<VMName>\guest.cred.xml`, DPAPI-encrypted to your Windows account.

The guest console opens **black**, not PowerShell blue.

## When to run what

| What you want | Run |
|---|---|
| Test the **published** tool the way a technician gets it | `lab -Mode Live` |
| Test code you just **edited** but have not published | `lab` |
| A test failed and you want to **look at the wreckage** | run nothing yet - the VM is still dirty, go look |
| ...then retry **on top of** that dirty state | `lab -NoRevert` |
| See the error the guest printed | `lablog` |
| Paste things into the VM all session | `labsync -Background` once, then just copy normally |
| Grab text **out** of the VM | `fromlab` |
| Prepare the baseline by hand | `lab -NoLaunch`, change it, then `labsave -To CLEAN-v6 -Promote` |
| Same, but scripted and repeatable | `.\Update-Baseline.ps1 -ApplyFile .\my-change.ps1 -To CLEAN-v6` |
| Run any of it against Pro | `labpro ...` or add `-VMName Pro` |
| Pro lost its connection after a guest reboot | close the window and reopen, or `labconn -VMName Pro` |

### The normal rhythm

```
labsync -Background     once, at the start of the day (Home only)

lab -Mode Live          clean VM, your tool launches
                        ...poke at it, find a bug...
                        fix the code in VS Code on the HOST - the dirty VM is irrelevant
lab -Mode Live          clean VM again, new code, ~6 seconds
                        repeat
```

You never uninstall anything, never clean up, never undo. **The wipe is the first thing every
run does, not the last** - so leaving the VM filthy is expected. There is no cleanup step in
this workflow.

The only time you skip the wipe is when a failure is worth studying: leave it dirty, read
`lablog`, poke around, and use `-NoRevert` if you want to run again without losing it. That
is also how you test the leftover-removal path properly - let something install and fail
dirty, then run the uninstaller against that exact mess rather than a fresh machine.

### Which VM

Use **Home** by default. It is the honest target: most client machines run Home, and if your
uninstaller works there it works everywhere. Use **Pro** when you want to work comfortably
inside the VM - reading logs, editing files, poking at the registry - because it has native
clipboard and a resizable window.

## How the wipe works

The checkpoint froze two things: the disk, and the RAM.

```
AppLab.vhdx      frozen at checkpoint - never written to again
AppLab_*.avhdx   every change since: installs, registry, temp files
saved memory     RAM contents at the moment of the checkpoint
```

(The VMs were renamed to `Home` and `Pro` after creation. `Rename-VM` does not rename files,
so the disks under `C:\VMs` are still `AppLab*.vhdx` and `AppLabPro*.vhdx`. Cosmetic only.)

Reverting deletes the `.avhdx` and reloads the saved memory. It does not copy or restore
anything, which is why it costs the same ~1.5s whether the test installed one app or fifty,
and why the disk never grows across runs.

Reloading memory is also why the guest *resumes* at a logged-in desktop instead of booting.
A Production checkpoint would use VSS and cold-boot instead - about 25s. Standard is
deliberate.

Nothing in the guest survives a revert, and the code push is one-way (host -> guest), so
nothing a test does can reach your working tree.

## Changing what "clean" means

All of this runs on the HOST, never inside the VM.

**Changes you make by hand** (install something, tweak a setting):

```powershell
lab -NoLaunch                          # 1. start from a CLEAN vm - do not skip this
                                       # 2. make your changes in the VM window
labsave -To CLEAN-v6 -Promote          # 3. freeze it and make it the default
```

Step 1 is the whole discipline. `Save-Baseline.ps1` captures the guest exactly as it is, so
capturing after a test run bakes that test's installs and registry debris in permanently.
It prompts before committing, and `-Promote` renames the old baseline rather than deleting
it.

**Changes you can script** - this reverts to clean for you, so the discipline is automatic:

```powershell
.\Update-Baseline.ps1 -VMName Home -ApplyFile .\guest-set-resolution.ps1 -To CLEAN-v6
.\Test.ps1 -Checkpoint CLEAN-v6        # try it before committing to it
Rename-VMCheckpoint -VMName Home -Name CLEAN -NewName CLEAN-old
Start-Sleep -Seconds 2                 # Hyper-V needs a beat between renames
Rename-VMCheckpoint -VMName Home -Name CLEAN-v6 -NewName CLEAN
```

### Two traps when re-baselining

- **Reboot the guest and it comes back at the LOCK SCREEN.** A Standard checkpoint captures
  memory, so locking there means typing a password on every future run. Always log back in
  and sit at the desktop before saving. This has already bitten once - a reboot mid-edit
  reset the display resolution and the wrong value got frozen in.
- **Never change VM hardware while a memory checkpoint exists.** RAM, vCPU, `Set-VMVideo` -
  the saved memory image is bound to the device configuration it was captured with, and the
  restore fails with *"Microsoft Video Monitor ... Catastrophic failure"*. To change
  hardware: delete every checkpoint, change it, boot, re-baseline.

## Resolution and sharpness

The two VMs resize by completely different mechanisms.

| | Home (Basic Session) | Pro (Enhanced Session) |
|---|---|---|
| What is sent | a video feed of a virtual monitor | RDP drawing instructions |
| Who sets the size | the **guest** | the **connection** |
| How to change it | Settings > System > Display inside the VM | drag the window edge |
| Resizable | no - fixed, then stretched | yes, dynamic |
| Ceiling | 1920x1200 (`Get-VMVideo`) | any |

Home is baked at **1920x1080** - 16:9, matching the monitor, so no letterboxing. Anything
set by hand inside Home reverts on the next `lab`; bake it in with
`Update-Baseline.ps1 -ApplyFile .\guest-set-resolution.ps1` (edit `$W`/`$H` at the top).

**Why Home looked blurry and oversized:** the primary display runs at 150% scaling
(1707x960 effective on a 2560x1440 panel), and Windows was upscaling the whole vmconnect
window by 1.5x - bigger *and* softer. Fixed by marking vmconnect DPI-aware:

```
HKCU\...\AppCompatFlags\Layers   C:\Windows\System32\vmconnect.exe = "~ HIGHDPIAWARE"
```

Basic Session is now 1:1 and sharp, but smaller. Put the Home window on the unscaled
2560x1440 monitor for the best of both. Pro is unaffected - RDP negotiates DPI itself.

## Clipboard

**Pro:** native, both directions. Nothing to configure.

**Home:** impossible natively (see above). Use the bridge:

```powershell
labsync -Background   # live mirror, host -> guest, automatic
labsync               # same, foreground, Ctrl+C to stop
tolab / fromlab       # one-shot, either direction
```

`labsync` must run **STA** - a PowerShell background job runs MTA, where `Get-Clipboard`
silently returns nothing and the loop never sees a change. `-Background` spawns a detached
`-STA` process for that reason, and it reconnects on its own when a revert kills its session.

Both bridge scripts hand the actual clipboard call to a scheduled task in the guest's
signed-in session: the clipboard belongs to a window station, and PowerShell Direct lands in
session 0, where a `Set-Clipboard` writes a clipboard nothing on the desktop can see.

vmconnect also has **Clipboard > Type clipboard text** built in - host to guest, typed as
keystrokes, no setup.

## Scripts

| | |
|---|---|
| `Test.ps1` | **The loop.** Revert, resume, push code, launch. `-Mode Live`, `-NoRevert`, `-NoLaunch`, `-Checkpoint`, `-VMName` |
| `Save-Baseline.ps1` | Freeze the current guest state as a baseline (hand-made changes) |
| `Update-Baseline.ps1` | Revert to clean, apply a script, checkpoint (scripted changes) |
| `Get-LabLog.ps1` | Read the guest launch transcript from the host |
| `Send-LabClipboard.ps1` / `Get-LabClipboard.ps1` | One-shot clipboard, either direction |
| `Sync-LabClipboard.ps1` | Live host->guest clipboard mirror |
| `Connect-Lab.ps1` | mstsc over the VMBus (port 2179). Pro only - Home cannot host RDP |
| `guest-enable-rdp.ps1` | Enables RDP in a guest (applied via `Update-Baseline.ps1`) |
| `guest-set-resolution.ps1` | Sets guest resolution via ChangeDisplaySettings, in the interactive session |

### Build scripts (already run - here for a rebuild)

| | |
|---|---|
| `1-Enable-HyperV.ps1` | Enables Hyper-V. Needs a real **Restart**, not Shut down - Fast Startup skips pending servicing and the install silently half-applies. |
| `2-New-LabVM.ps1` | Gen 2 VM, TPM + Secure Boot, Default Switch. Setup needs a **local** account. |
| `3-Set-Baseline.ps1` | Preps guest, stores credential, ejects the ISO, takes the first checkpoint. `-NoCheckpoint` does everything except the checkpoint. |

## Checkpoints

```
Home            Pro
  CLEAN           CLEAN
```

One each - keep it that way.

Every checkpoint adds another differencing disk to the chain, and every disk read walks the
whole chain. Home briefly carried five (from rebuilding the baseline five times during
setup) and they cost ~39 GB of `.avhdx` on top of an 18 GB base. Deleting the four
superseded ones merged them down and reclaimed **35 GB**:

```
before  Home ~57 GB + Pro ~31 GB = 99 GB
after   Home  33.7 GB + Pro 26.6 GB = 64 GB
```

So: keep intermediate checkpoints only while you are still deciding whether a new baseline
is right. Once it is settled, delete the old ones - `Remove-VMCheckpoint` merges rather than
discards, so the surviving baseline keeps all its data. Do it with the VM **off**; the merge
is faster and cannot race a running guest.

## Gotchas

- **`vmicrdv` must be Automatic**, or Enhanced Session does not come back after a guest
  reboot and vmconnect reports a flat *"could not connect"* instead of retrying. Set on Pro
  by `3-Set-Baseline.ps1`.
- **Guests must use a LOCAL account.** PowerShell Direct cannot authenticate a Microsoft
  account. `Shift+F10` then `start ms-cxh:localonly` during setup.
- **`Test.ps1` needs Hyper-V rights.** You are in `Hyper-V Administrators`, so it runs from a
  normal terminal - no elevation.
- **Activation is not needed.** Unactivated Windows 11 runs indefinitely; you lose a
  watermark and personalization settings, nothing your installer touches.

## What this covers that `../sandbox/` does not

Reboot-requiring installers, live Defender, a realistically dirty baseline, MSIX/Store,
drivers and services. `sandbox/` is a 20-second smoke test; this is the release gate.
