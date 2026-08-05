#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  AIOps layer deploy — attaches to the EXISTING ai-demo base cluster.
#  Idempotent: re-run after any interruption; completed phases skip.
#  Auto-confirm:  yes y | ./deploy.sh
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/environments/demo"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"
KUBECONFIG_DEFAULT="$HOME/GitHub/ai-demo-stack-aws/environments/demo/ocp-install-dir/ai-demo/auth/kubeconfig"
export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_DEFAULT}"
APPS_DOMAIN="apps.ai-demo.iisdemolab.click"

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

oc_aap() { oc -n aap "$@"; }

# ───────────────────────────────────────────────────────────────────────
banner "Phase 0.1 — Tooling"
# ───────────────────────────────────────────────────────────────────────
for tool in aws oc terraform jq ansible-playbook ansible-galaxy curl git; do
  command -v "$tool" >/dev/null || { echo "FATAL: '$tool' not found in PATH"; exit 1; }
done
command -v rosa >/dev/null || echo "WARN: rosa CLI missing — phase 0.3 will be skipped"
echo "OK: tooling present"

echo "Installing pinned collections for seed playbooks..."
ansible-galaxy collection install -r "$REPO_ROOT/collections/requirements.yml" \
  2>&1 | tee "$LOG_DIR/galaxy.log" | tail -2 || true

# ───────────────────────────────────────────────────────────────────────
banner "Phase 0.2 — AWS SSO (may open a browser)"
# ───────────────────────────────────────────────────────────────────────
if aws sts get-caller-identity >/dev/null 2>&1; then
  echo "OK: AWS session active ($(aws sts get-caller-identity --query Arn --output text))"
else
  echo "No AWS session — starting SSO login..."
  aws sso login
  aws sts get-caller-identity >/dev/null || { echo "FATAL: AWS login failed"; exit 1; }
fi

# ───────────────────────────────────────────────────────────────────────
banner "Phase 0.3 — Red Hat SSO"
# ───────────────────────────────────────────────────────────────────────
if command -v rosa >/dev/null; then
  if rosa whoami >/dev/null 2>&1; then
    echo "OK: Red Hat session active"
  elif [ -t 0 ]; then
    echo "No Red Hat session — 'rosa login' (may open a browser)..."
    rosa login || echo "WARN: rosa login failed — operator catalog access may already suffice"
  else
    # Non-interactive (yes y | ...): rosa login would eat piped stdin.
    echo "WARN: no Red Hat session and stdin is not a tty — skipping rosa login."
    echo "      The cluster's pull secret already grants catalog access; run 'rosa login' manually if needed."
  fi
fi

# ───────────────────────────────────────────────────────────────────────
banner "Phase 0.4 — Cluster access"
# ───────────────────────────────────────────────────────────────────────
oc whoami >/dev/null 2>&1 || { echo "FATAL: cannot reach cluster with KUBECONFIG=$KUBECONFIG"; exit 1; }
echo "OK: connected as $(oc whoami) to $(oc whoami --show-server)"
oc get ns openshift-gitops >/dev/null || { echo "FATAL: openshift-gitops missing — is this the base cluster?"; exit 1; }

# Lesson L6: only pushed commits reach ArgoCD.
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "WARN: uncommitted changes — ArgoCD syncs the REMOTE. Commit + push first (lesson L6)."
  confirm "Continue anyway?" || exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" log --oneline origin/main..main 2>/dev/null)" ]]; then
  echo "WARN: local commits not pushed — ArgoCD will not see them (lesson L6)."
  confirm "Continue anyway?" || exit 1
fi

# Lightspeed backend (Q5): prompt for the Red Hat key only if requested.
LS_PROVIDER="$(grep -E '^lightspeed_provider' "$TF_DIR/terraform.tfvars" | cut -d'"' -f2 || echo portkey)"
if [[ "$LS_PROVIDER" == "redhat" && -z "${TF_VAR_lightspeed_api_key:-}" ]]; then
  read -r -s -p "Red Hat Content Provider API key (input hidden): " TF_VAR_lightspeed_api_key
  echo ""
  export TF_VAR_lightspeed_api_key
fi

confirm "Deploy the AIOps layer onto $(oc whoami --show-server)?" || exit 0

# ───────────────────────────────────────────────────────────────────────
banner "Phase 1 — Terraform: DBs, namespaces, secrets, operator subscription"
# ───────────────────────────────────────────────────────────────────────
terraform -chdir="$TF_DIR" init -input=false 2>&1 | tee "$LOG_DIR/tf-init.log" | tail -3 || true
# Stage 1: everything EXCEPT the AAP CRs (their CRDs don't exist yet).
terraform -chdir="$TF_DIR" apply -input=false -auto-approve \
  -target=module.aurora_db \
  -target=module.collab \
  -target=module.event_sources \
  -target=module.workbench \
  -target=module.aap.kubernetes_namespace_v1.aap \
  -target=module.aap.kubernetes_secret_v1.admin_password \
  -target='module.aap.kubernetes_secret_v1.postgres_configuration' \
  -target=module.aap.kubectl_manifest.operator_group \
  -target=module.aap.kubectl_manifest.subscription \
  2>&1 | tee "$LOG_DIR/tf-stage1.log" | grep -E '^(module\.|Apply|Plan|Error)' || true
[[ "${PIPESTATUS[0]}" -eq 0 ]] || { echo "FATAL: terraform stage 1 failed — see $LOG_DIR/tf-stage1.log"; exit 1; }

# ───────────────────────────────────────────────────────────────────────
banner "Phase 2 — Approve the pinned InstallPlan, wait for the operator"
# ───────────────────────────────────────────────────────────────────────
STARTING_CSV="$(terraform -chdir="$TF_DIR" output -raw aap_starting_csv 2>/dev/null || \
  awk '/variable "aap_starting_csv"/,/^}/' "$TF_DIR/variables.tf" | awk -F'"' '/default/{print $2}')"
echo "Pinned CSV: $STARTING_CSV"

echo "Waiting for the InstallPlan to appear..."
for _ in $(seq 1 30); do
  PLAN="$(oc_aap get installplan -o json 2>/dev/null \
    | jq -r --arg csv "$STARTING_CSV" \
      '.items[] | select(.spec.clusterServiceVersionNames[]? == $csv) | .metadata.name' | head -1)"
  [[ -n "$PLAN" ]] && break
  sleep 10
done
[[ -n "${PLAN:-}" ]] || { echo "FATAL: no InstallPlan for $STARTING_CSV — check the subscription"; exit 1; }

if [[ "$(oc_aap get installplan "$PLAN" -o jsonpath='{.spec.approved}')" != "true" ]]; then
  echo "Approving InstallPlan $PLAN (pinned to $STARTING_CSV only)"
  oc_aap patch installplan "$PLAN" --type merge -p '{"spec":{"approved":true}}'
fi

echo "Waiting for CSV $STARTING_CSV to reach Succeeded (up to 15m)..."
for _ in $(seq 1 90); do
  PHASE="$(oc_aap get csv "$STARTING_CSV" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$PHASE" == "Succeeded" ]] && break
  sleep 10
done
[[ "${PHASE:-}" == "Succeeded" ]] || { echo "FATAL: CSV phase is '${PHASE:-missing}'"; exit 1; }
echo "OK: AAP operator installed"

# ───────────────────────────────────────────────────────────────────────
banner "Phase 3 — Terraform: AAP/EDA custom resources + Lightspeed"
# ───────────────────────────────────────────────────────────────────────
terraform -chdir="$TF_DIR" apply -input=false -auto-approve \
  2>&1 | tee "$LOG_DIR/tf-stage2.log" | grep -E '^(module\.|Apply|Plan|Error)' || true
[[ "${PIPESTATUS[0]}" -eq 0 ]] || { echo "FATAL: terraform stage 2 failed — see $LOG_DIR/tf-stage2.log"; exit 1; }

# ───────────────────────────────────────────────────────────────────────
banner "Phase 4 — GitOps bootstrap (app-of-apps + notifications wiring)"
# ───────────────────────────────────────────────────────────────────────
oc apply -f "$REPO_ROOT/gitops/config/apps/aiops-app-of-apps.yaml"
echo "OK: app-of-apps applied — ArgoCD now owns gitops/manifests/**"

# Register the event-bridge as a notifications webhook service.
# argocd-notifications-cm is OPERATOR-owned (not ArgoCD-synced), so a
# patch is legitimate here — but if the operator reconciles it away,
# that's a base-repo PR (see LESSONS_LEARNED A4).
if oc -n openshift-gitops get cm argocd-notifications-cm >/dev/null 2>&1; then
  oc -n openshift-gitops patch cm argocd-notifications-cm --type merge -p '{
    "data": {
      "service.webhook.aiops-event-bridge": "url: http://event-bridge.aiops-events.svc:8688/argocd\nheaders:\n- name: Content-Type\n  value: application/json",
      "template.aiops-event": "webhook:\n  aiops-event-bridge:\n    method: POST\n    body: |\n      {\"app\":\"{{.app.metadata.name}}\",\"state\":\"{{if eq .app.status.health.status \"Degraded\"}}degraded{{else}}sync-failed{{end}}\",\"message\":\"{{.app.status.operationState.message}}\"}",
      "trigger.on-health-degraded": "- when: app.status.health.status == '\''Degraded'\''\n  send: [aiops-event]",
      "trigger.on-sync-failed": "- when: app.status.operationState.phase in ['\''Error'\'', '\''Failed'\'']\n  send: [aiops-event]"
    }
  }'
  echo "OK: ArgoCD notifications route to the event-bridge"
else
  echo "WARN: argocd-notifications-cm not found — notifications controller likely disabled."
  echo "      Enabling it is a BASE-repo change (ArgoCD CR spec.notifications.enabled) — raise a PR there."
fi

# ───────────────────────────────────────────────────────────────────────
banner "Phase 5 — Wait for component health"
# ───────────────────────────────────────────────────────────────────────
wait_url() { # name url max_tries
  local name="$1" url="$2" tries="${3:-90}"
  echo -n "Waiting for $name "
  for _ in $(seq 1 "$tries"); do
    if curl -ksf -o /dev/null "$url"; then echo " OK"; return 0; fi
    echo -n "."
    sleep 10
  done
  echo " TIMEOUT"
  echo "WARN: $name not healthy yet ($url) — continuing; re-run deploy.sh to retry"
  return 1
}

wait_url "AAP Controller" "https://aap-controller-aap.$APPS_DOMAIN/api/v2/ping/" || true
wait_url "EDA"            "https://aap-eda-aap.$APPS_DOMAIN/_healthz" 45 || true
wait_url "Gitea"          "https://gitea-aiops-collab.$APPS_DOMAIN/api/healthz" 45 || true
wait_url "Mattermost"     "https://mattermost-aiops-collab.$APPS_DOMAIN/api/v4/system/ping" 45 || true

# ───────────────────────────────────────────────────────────────────────
banner "Phase 6 — Seed demo content (idempotent)"
# ───────────────────────────────────────────────────────────────────────
CONTROLLER_URL="https://aap-controller-aap.$APPS_DOMAIN"
EDA_URL="https://aap-eda-aap.$APPS_DOMAIN"
AAP_ADMIN_PW="$(oc_aap get secret aap-controller-admin-password -o jsonpath='{.data.password}' | base64 -d)"
GITEA_USER="$(oc -n aiops-collab get secret gitea-admin -o jsonpath='{.data.username}' | base64 -d)"
GITEA_PASS="$(oc -n aiops-collab get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d)"

# 6a. Automation ServiceAccount + bearer token for in-cluster playbooks.
oc get sa aiops-automation -n aap >/dev/null 2>&1 || oc create sa aiops-automation -n aap
oc adm policy add-cluster-role-to-user edit -z aiops-automation -n aap >/dev/null
SA_TOKEN="$(oc create token aiops-automation -n aap --duration=8760h)"

# 6b. Mattermost: admin, team, and the incoming webhook for AAP.
MM_ADMIN_PW="$(oc -n aiops-collab get secret mattermost-admin -o jsonpath='{.data.password}' | base64 -d)"
oc -n aiops-collab exec deploy/mattermost -- mmctl --local user create \
  --email ansibleadmin@ansible.com --username ansibleadmin \
  --password "$MM_ADMIN_PW" --system-admin 2>/dev/null || true
oc -n aiops-collab exec deploy/mattermost -- mmctl --local team create \
  --name aiops --display-name "AIOps" 2>/dev/null || true
oc -n aiops-collab exec deploy/mattermost -- mmctl --local team users add \
  aiops ansibleadmin 2>/dev/null || true
MM_WEBHOOK="$(oc -n aiops-collab exec deploy/mattermost -- mmctl --local webhook create-incoming \
  --channel aiops:town-square --user ansibleadmin --display-name aap-notifications \
  --json 2>/dev/null | jq -r '.id' || true)"
if [[ -z "$MM_WEBHOOK" || "$MM_WEBHOOK" == "null" ]]; then
  MM_WEBHOOK="$(oc -n aiops-collab exec deploy/mattermost -- mmctl --local webhook list aiops --json 2>/dev/null \
    | jq -r '.[0].id // empty' || true)"
fi
MM_WEBHOOK_URL="http://mattermost.aiops-collab.svc:8065/hooks/$MM_WEBHOOK"
echo "Mattermost webhook: ${MM_WEBHOOK:-FAILED — notify playbooks will need manual wiring}"

# 6c. EDA needs a controller token registered to launch job templates.
curl -ksf -X POST "$EDA_URL/api/eda/v1/users/me/awx-tokens/" \
  -u "admin:$AAP_ADMIN_PW" -H 'Content-Type: application/json' \
  -d "{\"name\":\"aiops-controller-token\",\"token\":\"$(curl -ksf -X POST "$CONTROLLER_URL/api/v2/tokens/" \
      -u "admin:$AAP_ADMIN_PW" -H 'Content-Type: application/json' \
      -d '{"description":"eda","scope":"write"}' | jq -r .token)\",\"url\":\"$CONTROLLER_URL\"}" \
  >/dev/null 2>&1 || echo "NOTE: awx-token may already exist (fine)"

# 6d. Vector DB credentials for the seed playbook.
VECTOR_HOST="$(oc -n aiops-notebooks get secret aiops-vector-db -o jsonpath='{.data.PGHOST}' | base64 -d)"
VECTOR_PASS="$(oc -n aiops-notebooks get secret aiops-vector-db -o jsonpath='{.data.PGPASSWORD}' | base64 -d)"

# 6e. Controller + EDA configuration-as-code.
ansible-playbook "$REPO_ROOT/playbooks/setup/seed-controller.yml" \
  -e controller_host="$CONTROLLER_URL" \
  -e controller_username=admin \
  -e controller_password="$AAP_ADMIN_PW" \
  -e eda_host="$EDA_URL" \
  -e gitea_username="$GITEA_USER" \
  -e gitea_password="$GITEA_PASS" \
  -e mattermost_webhook_url="$MM_WEBHOOK_URL" \
  -e openshift_sa_token="$SA_TOKEN" \
  -e '{"vector_db": {"host": "'"$VECTOR_HOST"'", "database": "aiops", "username": "aiops_app", "password": "'"$VECTOR_PASS"'"}}' \
  2>&1 | tee "$LOG_DIR/seed.log" | grep -E '^(TASK|PLAY|ok:|changed:|failed:|fatal:)' || true
[[ "${PIPESTATUS[0]}" -eq 0 ]] || { echo "FATAL: seeding failed — see $LOG_DIR/seed.log"; exit 1; }

# 6f. Optional: Keycloak SSO federation (needs the base IdP admin creds).
# Interactive-only: the hidden password read is meaningless under `yes y |`.
if [ -t 0 ] && confirm "Wire Keycloak SSO now (requires Keycloak admin password)?"; then
  read -r -s -p "Keycloak admin password: " KC_PW; echo ""
  ansible-playbook "$REPO_ROOT/playbooks/setup/keycloak-oidc.yml" \
    -e keycloak_url="https://keycloak-rhoai-sso.$APPS_DOMAIN" \
    -e keycloak_admin_user=admin -e keycloak_admin_password="$KC_PW" \
    -e controller_host="$CONTROLLER_URL" -e controller_username=admin \
    -e controller_password="$AAP_ADMIN_PW" \
    2>&1 | tee "$LOG_DIR/keycloak.log" | tail -5 || true
else
  echo "Skipped — local admin auth works; re-run deploy.sh to add SSO later."
fi

# ───────────────────────────────────────────────────────────────────────
banner "DONE — AIOps layer deployed"
# ───────────────────────────────────────────────────────────────────────
cat <<EOF

  AAP Controller : $CONTROLLER_URL          (admin / <Vault-of-record: aap-controller-admin-password secret>)
  EDA            : $EDA_URL
  Automation Hub : https://aap-hub-aap.$APPS_DOMAIN
  Gitea          : https://gitea-aiops-collab.$APPS_DOMAIN  ($GITEA_USER)
  Mattermost     : https://mattermost-aiops-collab.$APPS_DOMAIN  (ansibleadmin)
  Demo app       : https://demo-httpd-aiops-demo-app.$APPS_DOMAIN
  Workbench      : RHOAI dashboard → project 'AIOps Notebooks'

  Run the demo:  AAP → launch '❌ Break Apache' → watch Mattermost Town
  Square → review the Lightspeed prompt → generate → remediate. Details:
  docs/USE_CASES.md (UC-0).

EOF
