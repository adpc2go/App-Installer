---
name: project-cloudflare-r2-hosting
description: "Why PC2Go's installer catalog is hosted on Cloudflare R2, and the constraints that decision carries"
metadata: 
  node_type: memory
  type: project
  originSessionId: b081ec35-97f2-4ebc-af0b-ab272b08c124
  modified: 2026-08-17T21:38:55.713Z
---

Decided 2026-08-17. The catalog is ~63 GB across 17 apps and each technician session
pushes ~30 GB to a client, so **egress, not storage, is the entire cost question**. R2
charges $0 egress at any volume; CloudFront starts at $0.085/GB with the Middle East on a
premium tier. Estimated bills: **R2 $0.80/month vs ~$256/month on AWS**. Cloudflare also
has a Kuwait City PoP.

Three constraints that are easy to forget and expensive to rediscover:

- **Cloudflare's CDN terms permit large non-HTML files only when hosted on a Cloudflare
  service such as R2.** The same installers behind the CDN on an ordinary VPS remain a
  violation.
- **R2 requires a payment method even at $0 usage**, and it must be enabled by hand in the
  dashboard — there is no wrangler command for it. Error `10042` means that step was
  skipped.
- **R2 has no Middle East region.** `eeur` was chosen for Kuwait; worth measuring against
  `weur` before treating it as settled.

Multiple free-tier accounts to dodge the 10 GB limit was considered and rejected: it is a
ToS violation risking termination of all linked accounts, and R2 wants a card per account
anyway, so it does not even solve the problem.

Related: [[user-msp-context]], [[feedback-prove-it-with-tests]]
