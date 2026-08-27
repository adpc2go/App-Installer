---
name: project-catalog-bom-phantom-app
description: "A UTF-8 BOM on apps.json used to make AppDeploy show \"Live catalog\" plus one phantom app - found 2026-08-17, FIXED and tested 2026-08-18"
metadata:
  node_type: memory
  type: project
  originSessionId: eb5177ea-cded-46d3-b5e1-efc753bde861
  modified: 2026-08-18T20:38:20.614Z
---

**FIXED on 2026-08-18.** Kept because the failure shape is worth recognising again.

The bug: if `apps.json` was served with a UTF-8 BOM, `Invoke-RestMethod` stopped parsing it as
JSON. Over HTTP it returned the raw **string**; `Load-Catalog` then read `$manifest.apps` off a
string, got `$null`, and `@($null).Count` is 1 - so the GUI showed a green "Live catalog" badge
and one blank row instead of failing. Over `file://` it THREW instead, which is a different path
and why an early test of the fix looked like it had made things worse.

The fix in `Load-Catalog` is three parts, all needed:
1. if the response comes back as a `[string]`, `TrimStart([char]0xFEFF)` then `ConvertFrom-Json`
2. if `Invoke-RestMethod` THROWS, refetch with `Invoke-WebRequest` and parse `.Content` the same
   way, before falling back to the offline copy
3. `foreach ($a in @(@($manifest.apps) | Where-Object { $_ }))` - the `Where-Object` is what
   stops a one-element array of `$null` becoming a row with no name

Plus `if (-not $manifest -or -not $manifest.apps) { throw }`, so a catalog with no apps array
fails loudly rather than showing nothing under a green badge.

Covered by `tools/Test-CatalogEditorGui.ps1` section 4, which serves a genuinely BOM'd catalog
over loopback HTTP and asserts one real app loads, that it has a name, and that there is no
blank row.

**Why:** it was a silent failure in the one place the tool is meant to be loud - a technician saw
a working-looking window with nothing in it. A BOM is easy to get by accident: 5.1's
`Set-Content -Encoding UTF8` writes one, and so does Notepad.

**How to apply:** still write catalogs BOM-less
(`[IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))`) - the editor does -
but a BOM no longer breaks the client. See also [[feedback-prove-it-with-tests]].
