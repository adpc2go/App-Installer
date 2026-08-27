---
name: project-silent-switch-detection-removed
description: Silent-switch auto-detection was built then deleted on 2026-08-22; do not rebuild it without solving the sampling problem
metadata: 
  node_type: memory
  type: project
  originSessionId: 38253778-0f2e-4380-9a63-5d0eb97126d3
  modified: 2026-08-22T15:40:14.055Z
---

Automatic silent-switch detection was built, extended, and then removed entirely on 2026-08-22.
Deleted: `tools/Installer-Detect.ps1`, `tools/installer-families.json`,
`tools/Test-SilentSwitches.ps1`, the sniffing inside the editor's `$FetchWork`, the
confidence-coloured hint, and the `VERIFY` gate in `Publish-Release.ps1`.

**Why:** it read a sample of the installer and inferred from what it did not find. Measured on
SketchUp's own installer — the entry is 1,104,552,560 bytes and the sample was 3,145,729 of them,
0.28%. In that sample "InstallShield" appeared 19 times, "setup.inx" twice, "msiexec" not at all,
and the code concluded there was no embedded MSI. A streaming read (OLE compound-file header,
2.1s for the whole member using Latin-1 + `String.IndexOf`; a PowerShell byte loop could not
finish it in 120s) proved there genuinely was none — but by then the user had lost confidence in
the whole approach, and a switch that is nearly right does not fail loudly: the installer opens
its GUI on a machine nobody is sitting at.

**How to apply:** `silentArgs` is a plain text field a technician fills in from vendor
documentation. Do not offer to detect, propose, or colour-code it. If detection is ever asked for
again, the question to answer first is how it establishes a NEGATIVE — no embedded MSI, no
response file — without reading the whole file, because sampling cannot. What catches a wrong
switch is the installer guard: it stops a window that opens, bounds it with a timeout, and names
the switch as the likely cause.

Related: [[project-catalog-repack-check]], [[feedback-prove-it-with-tests]].
