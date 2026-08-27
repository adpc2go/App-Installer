# Sandbox test lab

Clean Windows in ~20s, no snapshot to manage. Close the window and everything is gone.

## One-time enable (elevated PowerShell, then reboot)

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

## Use

| File | What it runs |
|---|---|
| `Test-Live.wsb`  | `irm https://apps.pc2go.ca/go \| iex` — the real technician path: bootstrap, hash pin, R2 download, GUI |
| `Test-Local.wsb` | `server\AppDeploy.ps1` from the working tree — uncommitted code, no publish step |
| `Clean.wsb`      | Bare sandbox + a PowerShell window, nothing auto-started |

Double-click one. Reset = close the sandbox window and double-click again.

The repo is mapped read-only at `Desktop\App-Installer`, so nothing the test does can
touch the host copy. `Test-Local` copies `AppDeploy.ps1` to `%LOCALAPPDATA%` before
running it, because the tool writes its cache beside itself.

## What this lab cannot test

- **Installers that require a reboot** — restarting terminates the sandbox.
- **Antivirus interference** — Defender real-time protection is not active the way it is
  on a client machine, so the 8-second script-scan stall described in the root README will
  never reproduce here.
- **Leftover detection against a realistic machine** — the sandbox image starts far cleaner
  than any client, so `Test-DirtyCleanup` style checks pass more easily than they should.
- **Store / MSIX packages**, and anything installing a driver or a boot-start service.
- **Other Windows builds** — the sandbox always mirrors the host build.

Those need a real VM. This lab is the fast inner loop, not the release gate.
