# App-Installer test lab

Real Windows 11, reverted in seconds, host never rebooted.

## Build it (once, ~45 min, mostly unattended)

| | Run as | What |
|---|---|---|
| `1-Enable-HyperV.ps1` | elevated | Enables Hyper-V. Reboots. |
| `2-New-LabVM.ps1 -IsoPath <win11.iso>` | elevated | Creates the VM, boots Windows setup. Make a **local** account named `lab`. |
| `3-Set-Baseline.ps1` | elevated | Preps the guest, stores its credential, takes the `CLEAN` checkpoint. |

## Use it (every day)

```powershell
.\Test.ps1                # push working tree, run from local source
.\Test.ps1 -Mode Live     # run the published irm one-liner instead
.\Test.ps1 -NoRevert      # inspect a failed run before wiping it
```

Revert → resume → push code → GUI on screen. About ten seconds.

You never take another checkpoint. `Restore-VMCheckpoint` discards the run, so the
differencing disk resets rather than growing.

## Why it is built this way

- **Standard checkpoint, not Production.** Standard saves memory state, so the revert
  resumes at a live desktop instead of cold-booting. That is the difference between a
  3-second loop and a 25-second one.
- **PowerShell Direct, not a share.** Host reaches the guest over the VMBus. No network
  config, no firewall rule, nothing to re-establish after a revert.
- **A scheduled task launches the GUI.** PowerShell Direct runs in session 0, where a WPF
  window draws on a desktop nobody can see. An interactive-principal task runs in the
  signed-in session, which is the only way the window appears.
- **Automatic checkpoints disabled.** They fire on every start and stack on top of `CLEAN`,
  turning a pointer move into a chain walk.

## What this covers that `../sandbox/` does not

Reboot-requiring installers, live Defender, a realistically dirty baseline, MSIX/Store,
drivers and services. Use `sandbox/` for the 20-second smoke test; use this before you
publish.
