---
name: project-catalog-repack-check
description: Some packages staged for the catalog are pirated repacks; look inside before publishing
metadata: 
  node_type: memory
  type: project
  originSessionId: 38253778-0f2e-4380-9a63-5d0eb97126d3
  modified: 2026-08-21T17:01:08.864Z
---

On 2026-08-21 the `sketchup` entry blocked a publish. Its package,
`SketchUp.Pro.2026.26.1.256.rar`, turned out to be a pirated repack — it contained a `Crack/`
folder with replacement `SketchUp.exe` and `LayOut.exe` beside the installer. The entry and the
R2 object were both deleted at the user's direction.

**Why:** the packages are staged from `C:\Users\Lenovo-G\Documents\Apps`, and at least some came
from file-sharing sources. Nothing in the toolchain detects this — the publish gate only checks
hashes, VERIFY markers and now duplicates, and the Worker only checks that a hash is 64 hex
characters. A repack passes every automated check and ships cracked software to client machines,
which for an MSP is both a licensing liability and unsigned code running elevated on customer PCs.

**How to apply:** before publishing any app whose package came from that folder, list the archive
(`tar -tf`) and look at what is actually inside. A `Crack`, `Patch`, `Keygen` or `Fix` directory,
or replacement copies of the product's own executables, means it is not the vendor's installer.
Say so plainly and do not clear the gate for it. The 15 unhashed entries — autocad, revit,
photoshop, acrobat and the rest — have never been inspected and may be the same kind of thing.

Related: [[project-session-2026-08-18-state]], [[project-push-button-r2-upload]].
