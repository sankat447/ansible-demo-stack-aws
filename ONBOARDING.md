# Onboarding

Step-by-step guide for provisioning, accessing, and tearing down the
AIOps layer. Assumes the base platform
([ai-demo-stack-aws](https://github.com/sankat447/ai-demo-stack-aws))
is already up at `*.apps.ai-demo.iisdemolab.click`.

> **Status: skeleton.** Sections marked _(TBD)_ are filled in as the
> corresponding modules land — this doc must match reality, not plans.

## 1. Prerequisites

- `aws` CLI with SSO configured for the demo account
- `rosa` CLI (Red Hat SSO)
- `oc` CLI
- `terraform` ≥ 1.6
- `ansible` + `ansible-rulebook` (for local rulebook testing only)
- Kubeconfig for the base cluster at
  `~/GitHub/ai-demo-stack-aws/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig`
- (Optional) Red Hat Content Provider API key for Lightspeed — if you
  skip it, Lightspeed uses the self-hosted llama-3-1-8b via Portkey.

## 2. Deploy

```bash
./deploy.sh          # interactive — prompts at each phase
yes y | ./deploy.sh  # auto-confirm
```

Phases (mirroring the base repo's UX):

| Phase | What happens |
|-------|--------------|
| 0.1 | Tooling checks |
| 0.2 | AWS SSO check (may open a browser) |
| 0.3 | Red Hat SSO check (`rosa login`) |
| 1 | Terraform: AWS-side resources + `aap` logical DB in Aurora |
| 2 | Operator subscriptions (AAP, pinned channel) |
| 3 | ArgoCD app-of-apps bootstrap (one `oc apply`) |
| 4 | Wait for AAP/EDA/Lightspeed/Workbench health |
| 5 | Seed demo content (job templates, rulebook activations, notebook) |

Every phase is idempotent — re-running `deploy.sh` after an
interruption is safe and skips completed work.

## 3. Access

| Component | URL | Auth |
|-----------|-----|------|
| AAP Controller | `https://aap-controller-aap.apps.ai-demo.iisdemolab.click` | Keycloak SSO (or local admin, password in Vault) |
| Automation Hub | _(TBD — route created by module)_ | Keycloak SSO |
| EDA Controller | _(TBD)_ | Keycloak SSO |
| RHOAI Workbench | via RHOAI dashboard (base stack) → `aiops-notebooks` project | OpenShift OAuth |
| ArgoCD (existing) | base stack route, apps under `aiops-*` | base stack SSO |

Admin credentials live in Vault (`vault.vault.svc:8200`) — _(TBD: exact
paths once the Vault module lands)_.

## 4. Run the demo

See [docs/USE_CASES.md](docs/USE_CASES.md) — the "Demo script
(10 minutes)" section at the bottom is the runbook.

## 5. Teardown

```bash
./destroy.sh
```

Removes ONLY:
- ArgoCD Applications from this repo's app-of-apps (and the workloads
  they manage)
- The `aap` logical database in Aurora (with confirmation prompt)
- AWS resources created by `demo/aiops.tfstate`

The base platform (cluster, Aurora cluster, RHOAI, Portkey, Vault,
Keycloak, …) is untouched. Verify after destroy:

```bash
oc get applications -n openshift-gitops   # no aiops-* apps remain
terraform -chdir=environments/demo state list   # empty
```

## 6. Troubleshooting

_(TBD — populated alongside [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md))_
