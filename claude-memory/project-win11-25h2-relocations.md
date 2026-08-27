---
name: project-win11-25h2-relocations
description: Windows 11 25H2 moved several tweak targets; find them by diffing the registry while toggling the real Settings UI, not from documentation
metadata:
  type: project
---

Windows 11 **25H2** relocated settings the tool had been writing for years. The old values still
write successfully and do nothing; `Migrated=1` marks the old location dead. Found on the lab VMs
in 2026-08: Explorer privacy moved **up out of** `Explorer\Advanced` into `Explorer\`; Start's
recent and frequent lists moved to `Explorer\Start` (`ShowRecentList`, `ShowFrequentList`,
`AllAppsViewMode`); Start recommendations (`Explorer\ShowRecommendations`) and the taskbar Resume
badge (`Explorer\Advanced\IsEnabled`) are new keys; Home and Gallery are unpinned through their
shell CLSIDs (`System.IsPinnedToNameSpaceTree=0`), not a policy.

**Why:** published guides, WinUtil-style scripts and Microsoft's own docs are all still wrong about
most of these, so reading more documentation does not converge. Every one was found the same way:
export the relevant hive, have the user toggle the setting in the real Settings UI, export again,
and diff. Over PowerShell Direct (`New-PSSession -VMName` with `Import-Clixml` creds) this takes
about a minute per setting.

**How to apply:** when a tweak "applies" and the user says nothing changed, do NOT re-read the code
first - diff the machine. And remember two follow-ons: a written value is not a visible one
(Explorer caches until something broadcasts `WM_SETTINGCHANGE`), and some values this build simply
**refuses** even elevated - `TaskbarDa` is the known one, and it removes the Widgets option
entirely rather than turning it off.

Related: [[feedback-prove-it-with-tests]], [[project-no-git-remote]].
