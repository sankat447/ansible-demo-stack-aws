#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  AIOps layer teardown. Removes ONLY what this repo created:
#    - ArgoCD Applications from the aiops app-of-apps (+ their workloads)
#    - AAP operator, CRs, and this layer's namespaces (via Terraform)
#    - The logical databases this layer added to Aurora (with confirm)
#  The BASE platform (cluster, Aurora, RHOAI, Portkey, Vault, Keycloak,
#  openshift-gitops, ...) is never touched.
#  Auto-confirm:  yes y | ./destroy.sh
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/environments/demo"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"
KUBECONFIG_DEFAULT="$HOME/GitHub/ai-demo-stack-aws/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig"
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_DEFAULT}"

banner() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════════"
}

confirm() {
  local prompt="${1:-Proceed?}"
  read -r -p "$prompt [y/N] " ans || ans=n
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ───────────────────────────────────────────────────────────────────────
banner "Phase 0 — Preflight"
# ───────────────────────────────────────────────────────────────────────
for tool in aws oc terraform jq; do
  command -v "$tool" >/dev/null || { echo "FATAL: '$tool' missing"; exit 1; }
done
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login
oc whoami >/dev/null 2>&1 || { echo "FATAL: cannot reach cluster"; exit 1; }
echo "Target: $(oc whoami --show-server)"
confirm "Destroy the AIOps layer (base platform stays)?" || exit 0

# ───────────────────────────────────────────────────────────────────────
banner "Phase 1 — Remove ArgoCD applications (cascading via finalizers)"
# ───────────────────────────────────────────────────────────────────────
if oc -n openshift-gitops get application aiops >/dev/null 2>&1; then
  # Deleting the parent removes the children; their resources-finalizer
  # cascades workload deletion.
  oc -n openshift-gitops delete application aiops --timeout=300s || true
fi
# Belt and braces: any orphaned child apps from this layer.
for app in aiops-event-sources aiops-collab aiops-demo-app aiops-workbench; do
  oc -n openshift-gitops delete application "$app" --ignore-not-found --timeout=300s || true
done
# Un-wire the notifications keys deploy.sh added (base CM survives).
if oc -n openshift-gitops get cm argocd-notifications-cm >/dev/null 2>&1; then
  oc -n openshift-gitops patch cm argocd-notifications-cm --type json -p '[
    {"op":"remove","path":"/data/service.webhook.aiops-event-bridge"},
    {"op":"remove","path":"/data/template.aiops-event"},
    {"op":"remove","path":"/data/trigger.on-health-degraded"},
    {"op":"remove","path":"/data/trigger.on-sync-failed"}
  ]' 2>/dev/null || true
fi
echo "OK: GitOps applications removed"

# ───────────────────────────────────────────────────────────────────────
banner "Phase 2 — Drop this layer's logical databases (Aurora survives)"
# ───────────────────────────────────────────────────────────────────────
if confirm "Drop logical DBs aap, hub, eda, mattermost, aiops from the shared Aurora?"; then
  if oc get ns aiops-db-bootstrap >/dev/null 2>&1; then
    oc -n aiops-db-bootstrap delete job aurora-db-drop --ignore-not-found
    cat <<'EOF' | oc -n aiops-db-bootstrap apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: aurora-db-drop
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: quay.io/sclorg/postgresql-15-c9s:c9s
          envFrom:
            - secretRef:
                name: aurora-bootstrap
          command:
            - /bin/bash
            - -c
            - |
              set -e
              for db in aap hub eda mattermost aiops; do
                psql -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" || true
                psql -d postgres -c "DROP ROLE IF EXISTS ${db}_app;" || true
              done
EOF
    oc -n aiops-db-bootstrap wait --for=condition=complete job/aurora-db-drop --timeout=300s \
      || echo "WARN: drop job did not complete — check manually"
  else
    echo "NOTE: bootstrap namespace already gone — skipping DB drop"
  fi
else
  echo "Keeping the logical databases (re-deploy will reuse them)."
fi

# ───────────────────────────────────────────────────────────────────────
banner "Phase 3 — Terraform destroy (operators, CRs, namespaces, secrets)"
# ───────────────────────────────────────────────────────────────────────
# NB: capture the exit code in the `||` RHS — a bare `|| true` resets
# PIPESTATUS (lesson A10).
rc=0
terraform -chdir="$TF_DIR" init -input=false -reconfigure 2>&1 | tail -2 || rc="${PIPESTATUS[0]}"
[[ "$rc" -eq 0 ]] || { echo "FATAL: terraform init failed"; exit 1; }
rc=0
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve \
  2>&1 | tee "$LOG_DIR/tf-destroy.log" | grep -E '^(module\.|Destroy|Plan|Error)' || rc="${PIPESTATUS[0]}"
[[ "$rc" -eq 0 ]] || { echo "FATAL: terraform destroy failed — see $LOG_DIR/tf-destroy.log"; exit 1; }

# CSV/InstallPlans are OLM-owned children of the Subscription and can
# linger; the namespaces are TF-deleted which clears them. Sanity only:
for ns in aap aiops-events aiops-collab aiops-notebooks aiops-db-bootstrap aiops-demo-app; do
  oc delete ns "$ns" --ignore-not-found --timeout=300s >/dev/null 2>&1 || true
done

# ───────────────────────────────────────────────────────────────────────
banner "Phase 4 — Verify the base platform is intact"
# ───────────────────────────────────────────────────────────────────────
FAIL=0
for ns in openshift-gitops rhoai-model-serving ai-demo vault rhoai-sso openshift-monitoring; do
  if ! oc get ns "$ns" >/dev/null 2>&1; then
    echo "ALERT: base namespace '$ns' missing — investigate immediately"
    FAIL=1
  fi
done
LEFT="$(oc get ns -o name 2>/dev/null | grep -E 'aiops|^namespace/aap$' || true)"
[[ -z "$LEFT" ]] && echo "OK: no AIOps namespaces remain" || echo "WARN: still terminating: $LEFT"
[[ "$FAIL" -eq 0 ]] && echo "OK: base platform namespaces all present"

banner "DONE — AIOps layer removed; base platform untouched"
