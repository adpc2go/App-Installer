---
name: project-no-git-remote
description: the App-Installer repo had no git remote and its test suite is untracked - a commit protects nothing here
metadata:
  type: project
---

`App-Installer` had **no git remote** as of 2026-08-22. `git remote -v` returned nothing, so the
repository existed in exactly one place: `C:\Users\Lenovo-G\Desktop\App-Installer`.

Worse, much of the valuable work was not tracked at all: `tests/` (all nine harnesses),
`HANDOVER.md`, `BRIEF.md`, `tools/R2-Upload.ps1`, `tools/Compress-Script.ps1`,
`tools/Convert-PackageToZip.ps1`. `tools/.push-state.json` is gitignored on purpose, but it is the
sidecar the whole catalog is re-derived from.

**Why:** it surfaced when the machine was about to be formatted with two sessions of work sitting
uncommitted on one disk. "Just commit it" would have been useless advice - there was nowhere for a
commit to go.

**How to apply:** if asked to protect, back up or hand off this work, check `git remote -v` FIRST
and say plainly if it is empty. Never imply a commit is a backup here. Check `git status
--porcelain` for untracked files before assuming the repo contains the work. A test suite outside
version control is the single biggest gap to close.

Related: [[project-session-2026-08-22-state]], [[project-sidecar-outranks-catalog]].
