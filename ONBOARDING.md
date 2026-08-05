# Onboarding

Step-by-step guide for provisioning, accessing, and tearing down the
AIOps layer. Assumes the base platform
([ai-demo-stack-aws](https://github.com/sankat447/ai-demo-stack-aws))
is already up at `*.apps.ai-demo.iisdemolab.click`.

Built to the objectives of the Red Hat showroom lab
[AI-Driven Ansible Automation](https://rhpds.github.io/showroom-ai-driven-ansible-automation/modules/index.html).

## 1. Prerequisites

- `aws` CLI with SSO configured for the demo account
- `rosa` CLI (Red Hat SSO)
- `oc` CLI
- `terraform` ≥ 1.6
- `ansible-playbook` + `ansible-galaxy` (seed phase; collections are
  pinned in [collections/requirements.yml](collections/requirements.yml))
- `jq`, `curl`, `git`
- Kubeconfig for the base cluster at
  `~/GitHub/ai-demo-stack-aws/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig`
  (override with `KUBECONFIG=...`)
- (Optional) Red Hat Content Provider API key for Lightspeed — set
  `lightspeed_provider = "redhat"` in
  [environments/demo/terraform.tfvars](environments/demo/terraform.tfvars)
  and deploy.sh prompts for the key. Default is the self-hosted
  llama-3-1-8b via Portkey (no key, no external cost).

## 2. Deploy

```bash
./deploy.sh          # interactive — prompts before anything mutating
yes y | ./deploy.sh  # auto-confirm
```

| Phase | What happens |
|-------|--------------|
| 0.1 | Tooling checks + pinned collection install |
| 0.2 | AWS SSO check (may open a browser) |
| 0.3 | Red Hat SSO check (`rosa login`) |
| 0.4 | Cluster access + git-pushed check (lesson L6) |
| 1 | Terraform stage 1: Aurora logical DBs (in-cluster bootstrap Job), namespaces, secrets, AAP operator Subscription (pinned CSV, Manual approval) |
| 2 | Approve exactly the pinned InstallPlan; wait for CSV `Succeeded` |
| 3 | Terraform stage 2: AutomationController / AutomationHub / EDA CRs + Lightspeed proxy |
| 4 | GitOps bootstrap: apply the app-of-apps; wire ArgoCD notifications → event-bridge |
| 5 | Health waits (AAP, EDA, Gitea, Mattermost) |
| 6 | Seed: SA token, Mattermost team + webhook, EDA controller token, controller configuration-as-code (org, credentials, projects, job templates, both workflows, 3 rulebook activations), optional Keycloak SSO |

Every phase is idempotent — re-running `deploy.sh` after an
interruption is safe and re-converges.

**Two-stage Terraform is intentional:** the AAP CRs can't apply before
the operator's CRDs exist (see LESSONS_LEARNED A5). `deploy.sh`
orchestrates it; don't run a bare `terraform apply` on first install.

## 3. Access

| Component | URL | Auth |
|-----------|-----|------|
| AAP Controller | `https://aap-controller-aap.apps.ai-demo.iisdemolab.click` | `admin` / `aap-controller-admin-password` Secret in ns `aap` (Keycloak SSO if phase 6f was run) |
| Automation Hub | `https://aap-hub-aap.apps.ai-demo.iisdemolab.click` | same admin pattern |
| EDA | `https://aap-eda-aap.apps.ai-demo.iisdemolab.click` | same admin pattern |
| Gitea | `https://gitea-aiops-collab.apps.ai-demo.iisdemolab.click` | `gitea-admin` Secret in ns `aiops-collab` |
| Mattermost | `https://mattermost-aiops-collab.apps.ai-demo.iisdemolab.click` | `ansibleadmin` / `mattermost-admin` Secret in ns `aiops-collab` |
| Demo app | `https://demo-httpd-aiops-demo-app.apps.ai-demo.iisdemolab.click` | none |
| RHOAI Workbench | base RHOAI dashboard → project **AIOps Notebooks** | OpenShift OAuth |
| ArgoCD (existing) | base stack route; this layer's apps are `aiops*` | base stack SSO |

Grab a credential quickly:

```bash
oc -n aap get secret aap-controller-admin-password -o jsonpath='{.data.password}' | base64 -d
```

> Secrets live in Kubernetes Secrets created by Terraform. The base
> stack's sealed-secrets status was unverified, so raw Secrets are used
> and the gap is documented (LESSONS_LEARNED A4) — per the rules of
> engagement fallback.

## 4. Run the demo

The runbook is the "Demo script (15 minutes)" section at the bottom of
[docs/USE_CASES.md](docs/USE_CASES.md). Short version: launch
**❌ Break Apache** in AAP → watch Mattermost Town Square → review the
Lightspeed prompt (survey) → generate → see the playbook in Gitea →
launch **🔧✅ Execute HTTPD Remediation** → demo app healthy.

## 5. Teardown

```bash
./destroy.sh          # interactive
yes y | ./destroy.sh  # auto-confirm
```

Removes ONLY: the `aiops*` ArgoCD Applications (workloads cascade via
finalizers), the five logical databases (`aap`, `hub`, `eda`,
`mattermost`, `aiops`) after a separate confirmation, the AAP
operator + CRs, and this layer's namespaces. Phase 4 then verifies the
base platform namespaces are all still present.

Verify after destroy:

```bash
oc get applications -n openshift-gitops | grep aiops   # nothing
oc get ns | grep -E 'aiops|^aap '                       # nothing
terraform -chdir=environments/demo state list           # empty
```

## 6. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Deploy stalls in phase 2 | InstallPlan for a different CSV appeared — check `oc -n aap get installplan` and the pinned `aap_starting_csv` in variables.tf |
| AAP pods `FailedCreate` forever | Lesson L1 — check the SA/SCC RoleBinding of whatever you added |
| Route TLS ok but times out | Lesson L2 — `maistra.io/expose-route: "true"` missing on the pod template |
| Rulebook fires but no job launches | EDA controller token missing — re-run deploy phase 6 (`deploy.sh` is idempotent) |
| No alerts reach EDA | User alert routing may be disabled in the base monitoring stack (LESSONS_LEARNED A6) — needs a base-repo PR, do NOT patch openshift-monitoring from here |
| Mattermost posts missing | Webhook creation failed in phase 6b — check `oc -n aiops-collab exec deploy/mattermost -- mmctl --local webhook list aiops` |
| Changed a gitops manifest but nothing happened | Lesson L6 — commit AND push; ArgoCD tracks the remote |
