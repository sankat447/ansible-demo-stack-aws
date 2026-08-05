# AIOps Use Cases

This stack is built strictly to the objectives of the Red Hat showroom
lab [AI-Driven Ansible Automation](https://rhpds.github.io/showroom-ai-driven-ansible-automation/modules/index.html):
detect, analyze, and remediate application failures automatically —
**without manual playbook creation** — on three pillars:
**observability** (log collection), **inference** (AI analysis), and
**automation** (self-healing response).

UC-0 is the lab's canonical flow, adapted to this platform. UC-1..3 are
OpenShift-native extensions built on the same spine: **event → EDA
rulebook → AAP workflow → AI analysis → Lightspeed-generated playbook →
git-committed fix → outcome embedded into pgvector**.

---

## UC-0: Broken web service — the canonical lab flow (self-healing, zero hand-written fix)

The showroom scenario is an Apache (`httpd`) systemd failure on a RHEL
webserver. Our adaptation runs `httpd` as a containerized demo workload
(`demo-httpd` in namespace `aiops-demo-app`), with the same
break-detect-analyze-generate-fix arc.

**Trigger** — the **`❌ Break Apache`** AAP job template
(`playbooks/examples/break-httpd.yml`) injects an invalid Apache config
directive into the demo workload and restarts it. The container fails.

**Observability** — a fluent-bit sidecar/shipper collects the error
logs and publishes them to the Kafka topic **`aiops.demo.events`**
(single-broker Kafka in `aiops-events`). This mirrors the lab's
Filebeat → Kafka pipeline.

**EDA rulebook** — `rulebooks/examples/kafka-httpd-failure.yml`
- Source: `ansible.eda.kafka` on topic `aiops.demo.events`
- Condition: message matches `httpd.service: Failed` / config error
  signature
- Action: launch AAP workflow **`🚨 Log Enrichment and Prompt
  Generation`**

**AAP workflow 1 — Log Enrichment and Prompt Generation** (mirrors lab
module 1, four sequential nodes):
1. **⚙️ Apache Service Status Check** — confirm the failure state,
   capture service status + recent error logs.
2. **🤖 AI: Analyze Incident** — send logs to the self-hosted
   llama-3-1-8b via **Portkey** (`portkey.ai-demo.svc:8787`,
   OpenAI-compatible — our stand-in for the lab's RHEL AI Granite
   endpoint). Returns a root-cause analysis.
3. **📣 Notify via Mattermost** — post 🛑 raw error logs and 🧠 AI RCA
   to the Town Square channel of the in-cluster Mattermost
   (`aiops-collab` namespace).
4. **⚙️ Build Ansible Lightspeed Job Template** — turn the RCA into a
   generation prompt and create/update the job template
   **`🧠 Lightspeed Remediation Playbook Generator`**.

**Human-in-the-loop checkpoint** — launching the generator surveys the
AI-drafted prompt; the operator reviews/corrects it before generation.
This is the lab's "natural stopping point" for validation.

**AAP workflow 2 — Remediation** (mirrors lab module 2, four nodes):
1. **🧠 Lightspeed Remediation Playbook Generator** — generates the fix
   playbook from the reviewed prompt (Lightspeed backend = llama via
   Portkey).
2. **🧾 Commit Fix to Gitea** — pushes the generated playbook to the
   in-cluster Gitea repo **`lightspeed-playbooks`**.
3. **Lightspeed-Playbooks project sync** — AAP pulls the new commit.
4. **⚙️ Build HTTPD Remediation Template** — creates
   **`🔧✅ Execute HTTPD Remediation`**; operator launches it limited to
   the demo workload.

**Verification** — the demo workload returns to healthy
(`oc get pods -n aiops-demo-app`, service responds 200). The lab's
`systemctl status httpd` check becomes a readiness-probe/service check.

**Learning loop (our extension)** — incident context, RCA, generated
playbook, and outcome are embedded into pgvector by the RHOAI notebook
pipeline, so the next similar failure retrieves this precedent.

---

## UC-1: Pod CrashLoopBackOff — diagnose and remediate

**Trigger alert** — `KubePodCrashLooping` from openshift-monitoring:

```promql
max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
```

**EDA rulebook** — `rulebooks/examples/pod-crashloop.yml`
- Source: Alertmanager webhook receiver (`aiops-events` namespace)
- Condition: `event.alert.labels.alertname == "KubePodCrashLooping"`
- Action: run AAP job template **`remediate-pod-crashloop`** with
  `namespace`, `pod`, `container` from alert labels as extra vars.

**AAP workflow**
1. *Gather context* — pull last 200 log lines, pod events, recent
   deploys for the workload (oc via cluster credential).
2. *Precedent lookup* — query pgvector for similar past incidents
   (same alertname + similar log embedding); attach top-3 matches.
3. *Lightspeed step* — send context to Lightspeed (llama-3-1-8b via
   Portkey): "given these logs and precedents, propose remediation
   tasks." Suggested tasks recorded as a job artifact for review.
4. *Remediation playbook* — `playbooks/examples/remediate-crashloop.yml`:
   checks for the two most common causes (bad image tag → roll back to
   previous ReplicaSet; OOMKilled → bump memory limit within a bounded
   cap) and otherwise restarts the workload with an annotation.
5. *Record outcome* — POST incident context + action + result to the
   embedding service; RHOAI notebook pipeline embeds it into pgvector.

**Outcome** — pod recovers (or is escalated with a drafted incident
summary). The incident + resolution is now retrievable as precedent.

---

## UC-2: PVC nearly full — expand before it breaks

**Trigger alert** — `KubePersistentVolumeFillingUp`:

```promql
kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.10
```

**EDA rulebook** — `rulebooks/examples/pvc-filling-up.yml`
- Source: Alertmanager webhook receiver
- Condition: `alertname == "KubePersistentVolumeFillingUp"` and
  severity in (warning, critical)
- Action: run AAP job template **`expand-pvc`** with `namespace`,
  `persistentvolumeclaim` extra vars.

**AAP workflow**
1. *Gather context* — PVC spec, StorageClass, `allowVolumeExpansion`,
   current usage trend from Prometheus.
2. *Guardrails* — only expand if SC allows expansion (gp3-csi does),
   growth ≤ 2× current size, and namespace isn't quota-capped.
   NOTE (base lesson L3): never mutate the StorageClass itself — if
   parameters are wrong, the playbook creates a new SC.
3. *Lightspeed step* — draft the expansion tasks + a cleanup suggestion
   ("top 10 largest paths on the volume" from a debug pod).
4. *Remediation playbook* — `playbooks/examples/expand-pvc.yml` patches
   `spec.resources.requests.storage` +50% (bounded), waits for
   `FileSystemResizePending` → resolved.
5. *Record outcome* — embed incident + new size + whether growth
   continued (feeds "this PVC keeps refilling — investigate the app"
   precedent).

**Outcome** — volume expanded online, no pod restart, precedent stored.

---

## UC-3: Node NotReady — cordon, drain, recover

**Trigger alert** — `KubeNodeNotReady`:

```promql
kube_node_status_condition{condition="Ready",status="true"} == 0
```

**EDA rulebook** — `rulebooks/examples/node-not-ready.yml`
- Source: Alertmanager webhook receiver
- Condition: `alertname == "KubeNodeNotReady"` sustained > 5m
  (rulebook uses a timeout/throttle to avoid flapping)
- Extra demo path: the same rulebook also subscribes to the Kafka
  topic `aiops.demo.events`, so a simulated `node-not-ready` event can
  drive the flow without breaking a real node.
- Action: run AAP workflow **`recover-node`**.

**AAP workflow**
1. *Gather context* — node conditions, kubelet status, recent MachineConfig
   rollouts, AWS instance state (via instance ID from the Machine CR).
2. *Precedent lookup* — pgvector: "have we seen this node/AZ/condition
   pattern before, and what fixed it?"
3. *Guardrails* — never act on masters; require ≥ 2 other Ready workers;
   only one node recovery at a time (AAP workflow concurrency = 1).
4. *Remediation playbook* — `playbooks/examples/recover-node.yml`:
   cordon → drain (with PDB-respecting timeout) → if kubelet-dead:
   AWS instance reboot via API → wait for Ready → uncordon. If the
   node doesn't return in 15m, leave cordoned and escalate.
5. *Escalation artifact* — Lightspeed drafts a natural-language incident
   summary (from the RHOAI notebook's summarizer prompt) attached to
   the job output — the "understanding" layer output a human reads.
6. *Record outcome* — embed the full timeline into pgvector.

**Outcome** — transient node failures self-heal; persistent ones arrive
to a human as a pre-analyzed incident with precedent links.

---

## ArgoCD notifications flow (cross-cutting)

Not a separate use case but wired at bootstrap: ArgoCD app-status
changes (`on-health-degraded`, `on-sync-failed`) post to an EDA webhook
source. The rulebook `rulebooks/examples/argocd-degraded.yml` launches
the **`gitops-drift-report`** job template, which gathers the app diff,
asks Lightspeed for a plain-English "what changed and what broke"
summary, and embeds it. This demos EDA reacting to *delivery* events,
not just *runtime* events.

## Demo script (15 minutes)

1. **UC-0 (the headline, ~8 min):** launch `❌ Break Apache` in AAP →
   watch Mattermost receive 🛑 logs then 🧠 AI RCA → review the
   Lightspeed prompt (human-in-the-loop) → generate → show the
   committed playbook in Gitea → run `🔧✅ Execute HTTPD Remediation` →
   demo app healthy again. No human wrote a single task.
2. `oc delete pod` on the demo app with a bad image → UC-1 fires live
   off the Alertmanager path.
3. Publish a simulated node event to Kafka → UC-3 fires without
   touching a real node.
4. Open the RHOAI workbench notebook → show the embedded incidents and
   run the similarity search for the UC-0/UC-1 alerts.
