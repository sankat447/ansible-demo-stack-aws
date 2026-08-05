# AIOps Use Cases

Three concrete flows the demo can show end-to-end. Each follows the same
spine: **alert → EDA rulebook → AAP workflow → Lightspeed-assisted
playbook → outcome embedded into pgvector**.

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

## Demo script (10 minutes)

1. `oc delete pod` on the demo app with a bad image → UC-1 fires live.
2. Publish a simulated node event to Kafka → UC-3 fires without
   touching a real node.
3. Open the RHOAI workbench notebook → show the embedded incidents and
   run the similarity search for the UC-1 alert.
4. Open AAP → show the Lightspeed-generated suggestions in the job
   artifacts and the playbook editor.
