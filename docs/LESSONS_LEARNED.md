# Lessons Learned

## Carried over from the base platform (ai-demo-stack-aws)

These are baked into this repo's day-1 code — do not re-learn them.

- **L1 — SCC for non-default UIDs.** Every pod running with a
  non-default UID needs a ServiceAccount + RoleBinding to
  `system:openshift:scc:anyuid` (or a narrower SCC). A missing SA
  fails silently as `ReplicaFailure: FailedCreate`.
- **L2 — Mesh route exposure.** Any deployment in a
  service-mesh-member namespace whose Route must be externally
  reachable needs `maistra.io/expose-route: "true"` on the pod
  template, or TLS handshakes succeed but backend routing times out.
- **L3 — StorageClass parameters are immutable.** Create a new SC
  instead of mutating an existing one.
- **L4 — All LLM calls via Portkey** (`portkey.ai-demo.svc:8787`).
  Never direct to vLLM/OpenAI/Anthropic. Unified audit, cost tracking,
  multi-model routing, rate limiting.
- **L5 — Secrets from Vault** via vault-injector annotations or an
  init container. Never in ConfigMaps or images.
- **L6 — ArgoCD reverts hot-patches.** Every real change must be
  committed AND pushed before it takes effect. Local commits do
  nothing.
- **L19 (base numbering) — `set -euo pipefail` + `tee` traps.** Append
  `|| true` after every tee-into-file pipeline where the following
  statement reads `PIPESTATUS`, or the script dies on benign statuses.

## New lessons from this layer (AAP / EDA / Lightspeed / RHOAI)

<!-- Populate as we build. Format:
- **A<N> — Title.** What happened, why, and the rule going forward.
-->

- *(none yet — populated during build)*
