---
name: project-sidecar-outranks-catalog
description: tools/.push-state.json is what the editor re-derives url/sha256/sizeBytes from, so editing apps.json by hand silently gets undone
metadata:
  type: project
---

`tools/.push-state.json` records where each app's installer is on this machine. The editor
re-derives `url`, `sha256` and `sizeBytes` FROM it, so it outranks anything hand-edited into
`server/apps.json`.

**Why:** on 2026-08-22 a catalog entry was repointed from a `.rar` to a `.zip` by editing
apps.json directly. The sidecar still named the `.rar`, the next editor save re-derived the old
values, and that got published - so the client kept downloading the `.rar` and failing. It took a
round trip to find, twice.

**How to apply:** when changing an app's file by hand, change BOTH, in the same pass -
`apps.json` and the sidecar's `localPath` / `sizeBytes` / `sha256` / `key`. Better still, do it
through the editor's "Use a local file..." which writes both. Push now converts `.rar` to `.zip`
automatically and repoints both together, so the hand-edit case should be rare.

Related: [[project-push-button-r2-upload]].
