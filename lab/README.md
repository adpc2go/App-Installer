# App-Installer test lab

Real Windows 11, wiped clean in ~7 seconds, host never rebooted.

## Two VMs, on purpose

| | Edition | Why |
|---|---|---|
| `AppLab` | **Home** | What most client machines actually run - the honest test target |
| `AppLabPro` | **Pro** | Comfort: native clipboard, drag-and-drop, resizable window |

Windows **Home cannot host RDP**, and Enhanced Session Mode *is* RDP into the guest. So on
the Home VM there is no native clipboard and no Enhanced Session - not through any setting.
The clipboard bridge below exists for that reason and works on both.

## Daily use

From any directory (functions live in your PowerShell profile):

```powershell
lab                 # Home: wipe, push working tree, run server\AppDeploy.ps1
lab -Mode Live      # Home: wipe, run  irm https://apps.pc2go.ca/go | iex
lab -NoRevert       # Home: do NOT wipe - inspect a failure before losing it
labpro -Mode Live   # same, against the Pro VM
tolab               # host clipboard -> lab
fromlab             # lab clipboard -> host
lablog              # guest launch transcript
```

Or call the scripts directly with `-VMName AppLabPro`. Credentials are stored per VM under
`%LOCALAPPDATA%\<VMName>\guest.cred.xml`.

## Clipboard between host and lab

**Pro VM:** native. Enhanced Session works, so copy/paste just works both ways.

**Home VM:** Windows Home cannot host RDP, and Enhanced Session *is* RDP into the guest -
so native clipboard is impossible there, through any setting. Use one of these instead:

```powershell
labsync -Background   # live mirror: host clipboard -> Home guest, automatically
labsync               # same, foreground, Ctrl+C to stop
tolab / fromlab       # one-shot, either direction
```

`labsync` must run STA - a PowerShell background job runs MTA, where Get-Clipboard silently
returns nothing and the loop never sees a change. `-Background` spawns a detached -STA
process for that reason. It reconnects on its own when a revert kills its session.

vmconnect also has **Clipboard > Type clipboard text** built in - host to guest, typed as
keystrokes, no setup.



```powershell
.\Send-LabClipboard.ps1                 # your host clipboard -> the lab
.\Send-LabClipboard.ps1 -Text 'foo'     # send literal text instead
.\Get-LabClipboard.ps1                  # the lab's clipboard -> your host
.\Get-LabClipboard.ps1 -NoSet           # print it instead of replacing yours
```

Both scripts hand the actual clipboard call to a scheduled task running in the guest's
signed-in session. The clipboard belongs to a window station, and PowerShell Direct lands
in session 0 - a `Set-Clipboard` there writes a clipboard nothing on the desktop can see.

Enhanced Session would give you this natively, plus drag-and-drop. Turn it on in
**Hyper-V Manager > Hyper-V Settings > User > Enhanced Session Mode**. These scripts keep
working either way.

## Reading guest-side errors

```powershell
.\Get-LabLog.ps1        # transcript of the last launch inside the guest
```

`Test.ps1` prints this automatically when it spots an error. Guest failures otherwise
print to a console inside the VM that the host cannot see.

## How the wipe works

The checkpoint froze two things: the disk, and the RAM.

```
AppLab.vhdx      frozen at checkpoint - never written to again
AppLab.avhdx     every change since: installs, registry, temp files
saved memory     RAM contents at the moment of the checkpoint
```

Reverting deletes the `.avhdx` and reloads the saved memory. It does not copy or restore
anything, which is why it takes the same ~1.5s whether the test installed one app or fifty,
and why the disk never grows across runs.

Reloading memory is also why the guest *resumes* at a logged-in desktop instead of booting.
A Production checkpoint would use VSS and cold-boot instead - about 25s. Standard is
deliberate.

Nothing in the guest survives a revert. The code push is one-way (host -> guest), so
nothing the test does can reach your working tree.

## Checkpoints

```
CLEAN-prerdp     original baseline, before Enhanced Session was enabled
  └── CLEAN      what Test.ps1 uses
```

## Changing what "clean" means

All of these run on the HOST, never inside the VM.

**Changes you make by hand** (install something, tweak a setting):

```powershell
lab                                    # 1. start from a CLEAN vm - do not skip this
                                       # 2. make your changes in the VM window
.\Save-Baseline.ps1 -To CLEAN-v3 -Promote   # 3. freeze it and make it the default
```

Step 1 is the whole discipline. `Save-Baseline.ps1` captures the guest exactly as it is,
so capturing after a test run bakes that test's installs and registry debris in for good.
It prompts before it commits, and `-Promote` renames the old baseline rather than deleting
it.

**Changes you can script** - use this instead, it reverts to clean for you:

Never edit the guest and re-checkpoint by hand - you would bake in the last test's residue.
Use this instead: it reverts to the current baseline first, applies your change to a
pristine guest, then writes a NEW checkpoint (the old one survives).

```powershell
.\Update-Baseline.ps1 -ApplyFile .\guest-enable-rdp.ps1 -To CLEAN-v2
.\Test.ps1 -Checkpoint CLEAN-v2          # try it

# happy with it? make it the default:
Rename-VMCheckpoint -VMName AppLab -Name CLEAN -NewName CLEAN-old
Rename-VMCheckpoint -VMName AppLab -Name CLEAN-v2 -NewName CLEAN
```

## Build scripts (already run - here for a rebuild)

| | |
|---|---|
| `1-Enable-HyperV.ps1` | Enables Hyper-V. Needs a real **Restart**, not Shut down (Fast Startup skips pending servicing). |
| `2-New-LabVM.ps1` | Gen 2 VM, TPM + Secure Boot, Default Switch. Windows setup needs a **local** account. |
| `3-Set-Baseline.ps1` | Preps guest, stores credential, takes the first checkpoint. |
| `guest-enable-rdp.ps1` | Enables RDP so vmconnect can use Enhanced Session. |

## Gotchas worth remembering

- **Window too small** = you are in Basic Session at 1024x768. Close the VM window and
  reopen it; Enhanced Session offers a size dialog. Enhanced Session rides the VMBus, not
  TCP/3389, so no firewall rule is involved.
- **`Test.ps1` needs Hyper-V rights.** You are in `Hyper-V Administrators`, so it runs from
  a normal terminal - no elevation.
- **Guest must use a LOCAL account.** PowerShell Direct cannot authenticate a Microsoft
  account.

## What this covers that `../sandbox/` does not

Reboot-requiring installers, live Defender, a realistically dirty baseline, MSIX/Store,
drivers and services. `sandbox/` is a 20-second smoke test; this is the release gate.
