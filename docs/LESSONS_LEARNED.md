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

- **A1 — Create Aurora logical DBs from inside the cluster.** The
  operator workstation has AWS (SSM) and cluster-API access but no
  network path into the Aurora VPC, so a `postgresql` Terraform
  provider connection fails from a laptop. Pattern: Terraform reads
  endpoint/master password from SSM → ships them as a K8s Secret → an
  in-cluster psql Job applies idempotent SQL (`modules/aurora-db`).
- **A2 — Pin images by digest at first deploy.** Operator CSVs are
  pinned day-1, but the supporting images (kafka, gitea, mattermost,
  fluent-bit, vector, ubi-httpd, psql) currently use version tags —
  and one deliberate `latest` (ubi9/httpd-24). On the first successful
  deploy, capture each running image's digest (`oc get pods -o
  jsonpath=...imageID`) and pin it in the manifests. Marked with
  `TODO first deploy` comments.
- **A3 — Never target EDA activation pods directly.** Activation pod
  labels/Services are an operator implementation detail and change
  across AAP versions. Webhook producers (Alertmanager, ArgoCD
  notifications) post to the stable event-bridge (Vector) instead,
  which lands everything on Kafka topics EDA consumes. One transport,
  no fragile selectors.
- **A4 — Sealed-secrets gap.** The base stack's sealed-secrets status
  was unverified at build time, so per the rules-of-engagement
  fallback all secrets are raw K8s Secrets created by Terraform (state
  lives in the encrypted S3 backend). If sealed-secrets exists on the
  base cluster, migrate; if Vault-injector sidecar patterns are wanted
  for AAP CR-managed pods, that needs AAP operator support — track
  upstream.
- **A5 — AAP CRs need a two-stage Terraform apply.** The
  AutomationController/Hub/EDA CRDs only exist after the operator
  installs, and OLM `Manual` approval means someone must approve the
  InstallPlan. `deploy.sh` phases 1–3 handle target-apply →
  approve+wait → full apply. A bare `terraform apply` on a fresh
  cluster fails mid-plan-apply; that's expected, not a bug.
- **A6 — AlertmanagerConfig assumes user alert routing is enabled.**
  `monitoring.coreos.com/v1beta1 AlertmanagerConfig` in `aiops-events`
  is only honored if the base monitoring stack enables user-defined
  alert routing. If alerts never reach the bridge, that switch is a
  BASE-repo change (openshift-monitoring config) — raise a PR there,
  never patch it from this repo.
- **A7 — Workflow artifacts are strings, not files.** AAP workflow
  nodes run in separate pods; a file written to /tmp in the generator
  node doesn't exist in the commit node. Pass the generated playbook
  CONTENT through `set_stats` and write it via the Gitea contents API.
- **A8 — Lightspeed "inline editor" integration is product-gated.**
  True in-editor suggestions need the Lightspeed cloud service or the
  VS Code plugin. Like the showroom lab itself, generation here is
  driven through the 🧠 generator job template (survey = human-reviewed
  prompt) hitting the lightspeed proxy → Portkey → llama-3-1-8b. Same
  UX arc, no external service dependency.
- **A9 (carried forward as L19) — `|| true` after tee pipelines** is
  applied throughout deploy.sh/destroy.sh, with `PIPESTATUS[0]`
  checked explicitly where the terraform/ansible exit code matters.
- **A10 — `|| true` RESETS PIPESTATUS.** Hit on the very first deploy:
  `pipeline || true` followed by `[[ ${PIPESTATUS[0]} -eq 0 ]]` reads
  the exit code of `true`, so a failed `terraform init` sailed through
  and the script hunted a nonexistent InstallPlan. Correct pattern:
  capture inside the `||` right-hand side, where PIPESTATUS still
  belongs to the pipeline — `pipeline || rc="${PIPESTATUS[0]}"` (see
  `run_logged()` in deploy.sh). Also: always `terraform init
  -reconfigure` in scripts — a stray local `init -backend=false` (e.g.
  from offline validation) otherwise wedges the backend.
