---
name: project-office365-parked
description: "office365's sha256 is deliberately blank in both apps.json and the sidecar - it is the consumer bootstrapper and cannot install unattended"
metadata: 
  node_type: memory
  type: project
  originSessionId: d9b40d25-5b06-4b73-9420-dacbe5207039
  modified: 2026-08-22T16:53:22.432Z
---

`office365` in `server/apps.json` has an EMPTY `sha256`, and so does its entry in
`tools/.push-state.json` (along with `localPath`, `mtimeUtc`, `hashedUtc`). That is deliberate,
not an unfinished app.

**Why:** the file behind it is `OfficeSetup.exe`, 7.4 MB - the **consumer** Office bootstrapper,
not the Office Deployment Tool. It has no silent switch: it opens its own UI and downloads
Office itself, so on a client machine with nobody sitting at it, it stalls. It had a real hash
again as of 2026-08-22 and would have gone live on the next Update. A blank `sha256` parks it:
`Test-App` reports "not hashed yet", so `New-PushPlan` skips it and Publish drops it, and the
edge never serves it. The `remote` block in the sidecar is left intact on purpose - the bytes
really are in R2, and claiming otherwise would trigger a pointless re-upload.

**How to apply:** do not "fix" the blank hash. Re-arming it needs a real ODT package
(`setup.exe` + `configuration.xml` hosted together under the same key prefix), not a re-hash of
the bootstrapper. Blanking the sidecar's `localPath` too is what stops a casual open of the app
in the editor from silently re-hashing and re-arming it - see [[project-sidecar-outranks-catalog]].

Related: [[project-silent-switch-detection-removed]], [[project-catalog-repack-check]].
