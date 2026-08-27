---
name: feedback-prove-it-with-tests
description: "This user wants failure modes empirically proven with fault-injection tests, not asserted"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b081ec35-97f2-4ebc-af0b-ab272b08c124
  modified: 2026-08-17T21:39:20.044Z
---

Asked three times in one message for "aggressive test", and repeatedly frames requests as
scenarios rather than features — *"imagine I'm downloading 14 GB Revit, then after 13 GB I
lose connection or the computer rebooted"*, *"what if the installer got ended from Task
Manager, what will it report as?"*

**Why:** this tool runs elevated on client machines the business does not own, where a
failure is a support incident rather than a bug report. Claims about resilience are worth
nothing to them unless something actually broke the connection and the code survived it.
Building a fault-injecting HTTP server and an exit-code probe found four real bugs that
reading the code had only *suggested* — silent truncation promoting a partial file as
complete, no read timeout, no retry, and killed-vs-refused installers being
indistinguishable.

**How to apply:** when they describe a failure scenario, build a harness that reproduces it
before proposing a fix, and report the failing output verbatim. Extract the real function
from `AppDeploy.ps1` via the PowerShell AST rather than copying it, so the tests exercise
shipping code. State plainly which cases the harness could *not* reach — they take caveats
seriously and follow up on them.

Related: [[user-msp-context]], [[project-cloudflare-r2-hosting]]
