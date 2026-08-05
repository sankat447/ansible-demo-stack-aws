# ansible-demo-stack-aws — AIOps Layer for OpenShift

An **AIOps automation layer** deployed on top of the existing
[ai-demo-stack-aws](https://github.com/sankat447/ai-demo-stack-aws) base
platform (OpenShift 4.21 IPI on AWS + RHOAI). This repo adds four Red Hat
automation components via Terraform + GitOps — it **attaches to** the base
cluster and never modifies or re-deploys it.

Built strictly to the objectives of the Red Hat showroom lab
[**AI-Driven Ansible Automation**](https://rhpds.github.io/showroom-ai-driven-ansible-automation/modules/index.html):
detect, analyze, and remediate application failures automatically —
without manual playbook creation — on three pillars: **observability**
(log collection → Kafka), **inference** (AI log analysis + Lightspeed
playbook generation), and **automation** (AAP self-healing workflows).

## What this adds

| # | Component | Purpose |
|---|-----------|---------|
| 1 | **Ansible Automation Platform (AAP)** | Controller + private Automation Hub, backed by the existing Aurora Postgres, Keycloak-federated auth |
| 2 | **Event-Driven Ansible (EDA)** | Rulebook activations listening to Alertmanager, ArgoCD notifications, and a demo Kafka topic — each triggering AAP job templates |
| 3 | **Ansible Lightspeed** | Playbook generation from natural language — via the self-hosted llama-3-1-8b through the Portkey AI gateway (or Red Hat Content Provider if a key is supplied) |
| 4 | **RHOAI AIOps Workbench** | Jupyter workbench that embeds Prometheus alerts + pod events into pgvector, retrieves similar past incidents, and drafts incident summaries |

Supporting cast (lab parity): single-broker **Kafka** + fluent-bit log
shipper (observability pipeline), **Gitea** (version control for
generated playbooks), **Mattermost** (incident notifications), and a
breakable **demo-httpd** workload.

## The demo story

`❌ Break Apache` job breaks the demo httpd workload → error logs flow
via fluent-bit → Kafka → an EDA rulebook picks them up → AAP's **Log
Enrichment** workflow checks the service, has the self-hosted
llama-3-1-8b (via Portkey) analyze the logs, posts the RCA to
Mattermost, and drafts a Lightspeed prompt → a human reviews the prompt
→ Lightspeed **generates** the remediation playbook → it's committed to
Gitea, project-synced into AAP, and executed → service healthy → the
whole incident is embedded into pgvector via the RHOAI notebook
pipeline, so the next similar event routes on precedent.

## Quick start

```bash
# Prereqs: aws cli (SSO configured), rosa, oc, terraform, ansible
./deploy.sh          # interactive
yes y | ./deploy.sh  # auto-confirm mode
```

Teardown (leaves the base platform intact):

```bash
./destroy.sh
```

See [ONBOARDING.md](ONBOARDING.md) for the full walkthrough.

## Cost

- No new VPC, no new Aurora, no new state bucket — everything reuses the
  base stack. AAP gets a new *logical database* (`aap`) in the existing
  Aurora cluster.
- Marginal cost is cluster compute for the AAP/EDA/Kafka pods only.
- Terraform state: `s3://ai-demo-stack-tfstate` key `demo/aiops.tfstate`.

## Repo layout

```
environments/demo/     Terraform root (backend, providers, module calls)
modules/               aurora-db / aap-operator / lightspeed / event-sources /
                       collab (Gitea+Mattermost) / rhoai-workbench
gitops/config/apps/    ArgoCD Applications (app-of-apps pattern)
gitops/manifests/      Kustomize bases the Applications sync
playbooks/examples/    Demo + workflow playbooks (break, analyze, notify, …)
playbooks/setup/       Seed configuration-as-code (controller, EDA, Keycloak)
rulebooks/examples/    EDA rulebooks (Kafka, Alertmanager, ArgoCD)
notebooks/             RHOAI AIOps workbench notebooks
collections/           Pinned collection requirements
docs/                  ARCHITECTURE, USE_CASES, LESSONS_LEARNED
```

## Docs

- [ONBOARDING.md](ONBOARDING.md) — provision, tear down, access
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces connect
- [docs/USE_CASES.md](docs/USE_CASES.md) — three concrete AIOps flows
- [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md) — carryover + new lessons

## Rules of engagement

- Base repo is read-only from here. Needed base changes go via separate PR.
- **All LLM calls go through Portkey** (`portkey.ai-demo.svc:8787`) — never
  direct to vLLM or external APIs.
- No secrets in ConfigMaps/manifests — Vault-injected or K8s Secrets.
- Operators pinned to explicit channels/versions. No `latest`.
- `destroy.sh` removes only what this repo created.
