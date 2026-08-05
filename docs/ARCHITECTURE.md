# Architecture

This layer adds four components on top of the existing
`ai-demo-stack-aws` base platform. Nothing in the base is modified;
every arrow into the base points at a service that already exists.

## Component diagram

```mermaid
flowchart TB
    subgraph AIOPS["THIS REPO — AIOps layer"]
        direction TB
        AAP["AAP Controller + Automation Hub<br/>(aap namespace)<br/>Route: aap-controller-aap.apps..."]
        EDA["EDA Controller<br/>3 rulebook activations"]
        LS["Ansible Lightspeed<br/>(llama-3-1-8b backend)"]
        WB["RHOAI AIOps Workbench<br/>(Jupyter, reuses installed RHOAI)"]
        KAFKA["Kafka (single broker)<br/>demo event topic"]
        AMWH["Alertmanager webhook receiver"]
        ARGON["ArgoCD notifications config"]
    end

    subgraph BASE["BASE PLATFORM — ai-demo-stack-aws (read-only)"]
        direction TB
        PORTKEY["Portkey AI gateway<br/>portkey.ai-demo.svc:8787"]
        VLLM["llama-3-1-8b InferenceService<br/>rhoai-model-serving"]
        AURORA["Aurora Postgres + pgvector<br/>(endpoint via SSM)"]
        REDIS["Redis<br/>redis.ai-demo.svc:6379"]
        MINIO["MinIO S3<br/>minio.rhoai-minio.svc:9000"]
        VAULT["Vault<br/>vault.vault.svc:8200"]
        KC["Keycloak<br/>rhoai-sso"]
        PROM["Prometheus + Alertmanager<br/>openshift-monitoring"]
        ARGO["OpenShift GitOps (ArgoCD)<br/>openshift-gitops"]
    end

    %% GitOps delivery
    ARGO -- "syncs gitops/config/apps/<br/>(app-of-apps in THIS repo)" --> AIOPS

    %% AAP wiring
    AAP -- "new logical DB 'aap'" --> AURORA
    AAP -- "OIDC federation" --> KC
    AAP -- "secrets (DB creds, admin pw)" --> VAULT
    AAP -- "playbook/EE artifacts" --> MINIO

    %% EDA wiring
    PROM -- "alert webhooks" --> AMWH
    AMWH --> EDA
    ARGO -- "app-status notifications" --> ARGON
    ARGON --> EDA
    KAFKA -- "simulated demo events" --> EDA
    EDA -- "launches job templates (API)" --> AAP

    %% Lightspeed wiring
    AAP -- "inline suggestions<br/>(playbook editor)" --> LS
    LS -- "OpenAI-compatible calls" --> PORTKEY
    PORTKEY --> VLLM

    %% Workbench wiring
    WB -- "pull alerts + pod events" --> PROM
    WB -- "embed + retrieve incidents<br/>(pgvector)" --> AURORA
    WB -- "LLM summaries via gateway" --> PORTKEY
    WB -- "session/state cache" --> REDIS
    WB -- "inventory source for AAP" --> AAP
```

## End-to-end event flow

```mermaid
sequenceDiagram
    participant PROM as Prometheus/Alertmanager
    participant EDA as EDA Rulebook
    participant AAP as AAP Workflow
    participant LS as Lightspeed (via Portkey → llama-3-1-8b)
    participant PB as Remediation Playbook
    participant PGV as pgvector (Aurora)
    participant WB as RHOAI Notebook

    PROM->>EDA: Alert webhook (e.g. KubePodCrashLooping)
    EDA->>PGV: (optional) similarity lookup — seen before?
    EDA->>AAP: Launch job template with alert payload
    AAP->>LS: Request playbook suggestion with incident context
    LS-->>AAP: Generated/assisted playbook tasks
    AAP->>PB: Execute remediation
    PB-->>AAP: Outcome (success/failure + logs)
    AAP->>WB: Outcome forwarded (webhook/artifact)
    WB->>PGV: Embed incident context + outcome
    Note over PGV: Next similar alert retrieves this precedent
```

## Design decisions

| Decision | Choice | Why |
|----------|--------|-----|
| AAP database | New logical DB `aap` in existing Aurora | ~$50/mo cheaper than a second cluster; base Aurora already HA (Q8 default) |
| Lightspeed backend | Self-hosted llama-3-1-8b via Portkey | Zero external API cost, stronger demo; Content Provider key can be supplied at deploy time to switch (Q5) |
| LLM routing | Everything through Portkey | Base lesson L4 — unified audit, cost tracking, rate limiting |
| EDA sources | Alertmanager + ArgoCD + Kafka | Spec requires three bootstrap activations; Kafka is single-broker, demo-only |
| Secrets | Vault (vault-injector annotations / init container) | Base lesson L5; no sealed-secrets assumed — gap documented in LESSONS_LEARNED if missing |
| Operator versions | Pinned channel + startingCSV, `installPlanApproval: Manual` for upgrades | Reproducibility rule; no `latest` |
| Delivery | ArgoCD app-of-apps in `gitops/config/apps/` | Existing openshift-gitops ArgoCD syncs this repo; bootstrap applies one file |
| Terraform state | `s3://ai-demo-stack-tfstate` key `demo/aiops.tfstate` | Same backend, separate lifecycle (Q7) |

## Namespaces created by this layer

| Namespace | Contents |
|-----------|----------|
| `aap` | AAP operator, AutomationController, AutomationHub, EDA Controller |
| `aiops-events` | Alertmanager webhook receiver, Kafka broker, event glue |
| `aiops-notebooks` | RHOAI workbench (Notebook CR), pipeline ConfigMaps |

Base lessons baked in day-1: every non-default-UID pod gets an SA +
anyuid (or narrower) RoleBinding (L1); externally-routed pods in mesh
namespaces carry `maistra.io/expose-route: "true"` (L2); new
StorageClasses over mutations (L3); all changes flow through git →
ArgoCD, never hot-patched (L6).
