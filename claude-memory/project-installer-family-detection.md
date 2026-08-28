---
name: project-installer-family-detection
description: Silent-switch detection was rebuilt on 2026-08-28 on positive signatures only (tools\Installer-Family.ps1); the 2026-08-22 removal and why this version is acceptable
metadata:
  node_type: memory
  type: project
  modified: 2026-08-28T00:00:00.000Z
---

Automatic silent-switch detection was built, deleted on 2026-08-22, and rebuilt on 2026-08-28 on
the opposite principle. The user's instruction: "i want a geric , apply to an and any not from
the setting ! for each ! i want a slient for install and unistall !" - one generic mechanism
for every app, install AND uninstall, not typed per entry.

**Why the first one was deleted:** it sampled 3,145,729 of SketchUp's 1,104,552,560 bytes
(0.28%), found no MSI marker, and concluded there was none. It inferred from an absence, and a
switch that is nearly right does not fail loudly - the installer opens its GUI on a machine
nobody is sitting at.

**Why this one is acceptable:**
- It asserts only what it FOUND: a signature at a stated offset in a bounded region (PE section
  table, version resource, overlay head 1 MB / tail 64 KB, resource leaves, companion names).
  `Confidence` is `signature` or `none`; there is no "probably".
- Bounded reads are proven by test: `Test-InstallerFamily.ps1` asserts `BytesRead <= 4 MB` and
  `Elapsed < 2 s` on every fixture, including real pinned installers (Notepad++ = NSIS,
  Git = Inno, vc_redist = Burn) fetched by `tests\Get-InstallerFixtures.ps1`.
- Unknown => no switch; the installer guard (`Start-InstallerWatched`) stays the safety net and
  the failure message names the switch AND where it came from.
- A typed switch is never overwritten (`silentSource: typed`); clearing the box by hand is
  itself a decision. Evidence is logged on both sides (editor hint, client activity log).
- ONE source, `tools\Installer-Family.ps1`, copied verbatim into `AppDeploy.ps1` between marker
  comments (`tools\Sync-InstallerFamily.ps1`); `Publish-Release.ps1` refuses a stale copy.

**How to apply:** edit the detector in `tools\Installer-Family.ps1` only, run
`Sync-InstallerFamily.ps1`, then the suites. Add a family only with a positive structural
signature and its vendor-documented switch (`Get-FamilySwitches` carries the doc reference).
InstallShield proposes nothing unless a `.msi`/`setup.ini` or `.iss` sits beside `setup.exe`.
Not yet recognised: Squirrel/Velopack, Advanced Installer, Wise, Setup Factory. Not yet done:
a VM run of every catalog entry with `silentArgs` cleared.

Related: [[project-catalog-repack-check]], [[feedback-prove-it-with-tests]],
[[feedback-green-suites-are-not-field-proof]].
