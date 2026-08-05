# ansible-demo-stack-aws — AIOps Layer for OpenShift

An **AIOps automation layer** deployed on top of the existing
[ai-demo-stack-aws](https://github.com/sankat447/ai-demo-stack-aws) base
platform (OpenShift 4.21 IPI on AWS + RHOAI). This repo adds four Red Hat
automation components via Terraform + GitOps — it **attaches to** the base
cluster and never modifies or re-deploys it.

## What this adds

| # | Component | Purpose |
|---|-----------|---------|
| 1 | **Ansible Automation Platform (AAP)** | Controller + private Automation Hub, backed by the existing Aurora Postgres, Keycloak-federated auth |
| 2 | **Event-Driven Ansible (EDA)** | Rulebook activations listening to Alertmanager, ArgoCD notifications, and a demo Kafka topic — each triggering AAP job templates |
| 3 | **Ansible Lightspeed** | Playbook generation from natural language — via the self-hosted llama-3-1-8b through the Portkey AI gateway (or Red Hat Content Provider if a key is supplied) |
| 4 | **RHOAI AIOps Workbench** | Jupyter workbench that embeds Prometheus alerts + pod events into pgvector, retrieves similar past incidents, and drafts incident summaries |

## The demo story

Prometheus alert fires → EDA rulebook picks it up → EDA calls an AAP
workflow → the workflow runs a Lightspeed-assisted remediation playbook →
the outcome + context is embedded into pgvector via the RHOAI notebook
pipeline → next time a similar event fires, EDA routes based on precedent.

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
modules/               aap-operator / eda-controller / lightspeed / event-sources
gitops/config/apps/    ArgoCD Applications (app-of-apps pattern)
playbooks/examples/    Demo remediation playbooks
rulebooks/examples/    Demo EDA rulebooks
notebooks/             RHOAI AIOps workbench notebooks
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
