---
name: project-no-git-remote
description: the App-Installer repo still has no git remote - the work is committed locally, so a commit here is not a backup
metadata:
  type: project
---

`App-Installer` still has **no git remote** as of 2026-08-27. `git remote -v` returns nothing, so
the repository exists in exactly one place: `C:\Users\Legion-T7\Projects\App-Installer`.

What changed since 2026-08-22: the work **is** committed now. 31 commits exist, 29 of them on
branch `console-rework` (ahead of `master` by 29, behind by 0), and everything once untracked -
`tests/` (now 15 harnesses plus `Test-Worker.mjs`), `HANDOVER.md`, `BRIEF.md`, `tools/R2-Upload.ps1`
and the rest - is tracked. `tools/.push-state.json` is gitignored on purpose, but it is the sidecar
the whole catalog is re-derived from.

**Why:** it first surfaced when the machine was about to be formatted with two sessions of work
sitting uncommitted on one disk. Committing closed half the gap; the other half is still open,
because a commit with no remote still lives on exactly one disk.

**How to apply:** if asked to protect, back up or hand off this work, check `git remote -v` FIRST
and say plainly that it is empty. Never imply a commit is a backup here. Creating a private remote
and pushing has been the top item in four consecutive handovers.

Related: [[project-session-2026-08-22-state]], [[project-sidecar-outranks-catalog]].