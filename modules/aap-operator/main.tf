# Ansible Automation Platform: operator (pinned), AutomationController,
# AutomationHub, and EDA controller — all backed by logical databases in
# the existing Aurora cluster (type: unmanaged), admin/DB credentials in
# Kubernetes Secrets (lesson L5: never ConfigMaps).
#
# CRs are applied with kubectl_manifest (server-side apply) because
# their CRDs only exist after the Subscription installs — plan-time
# schema validation would otherwise fail.

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    kubectl    = { source = "gavinbunney/kubectl" }
  }
}

locals {
  controller_host = "${var.controller_name}-${var.namespace}.${var.cluster_apps_domain}"
  hub_host        = "${var.hub_name}-${var.namespace}.${var.cluster_apps_domain}"
  eda_host        = "${var.eda_name}-${var.namespace}.${var.cluster_apps_domain}"
}

resource "kubernetes_namespace_v1" "aap" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "aiops"
      # ArgoCD may manage config objects here alongside TF-owned ones.
      "argocd.argoproj.io/managed" = "true"
    }
  }
}

# ── Secrets ────────────────────────────────────────────────────────────

resource "kubernetes_secret_v1" "admin_password" {
  metadata {
    name      = "${var.controller_name}-admin-password"
    namespace = kubernetes_namespace_v1.aap.metadata[0].name
  }
  data = { password = var.admin_password }
}

resource "kubernetes_secret_v1" "postgres_configuration" {
  for_each = {
    (var.controller_name) = var.db_credentials["aap"]
    (var.hub_name)        = var.db_credentials["hub"]
    (var.eda_name)        = var.db_credentials["eda"]
  }

  metadata {
    name      = "${each.key}-postgres-configuration"
    namespace = kubernetes_namespace_v1.aap.metadata[0].name
  }

  data = {
    host     = var.db_host
    port     = "5432"
    database = each.value.database
    username = each.value.username
    password = each.value.password
    sslmode  = "prefer"
    type     = "unmanaged" # reuse Aurora — the operator must NOT provision postgres
  }
}

# ── Operator (OLM) ─────────────────────────────────────────────────────

resource "kubectl_manifest" "operator_group" {
  yaml_body = yamlencode({
    apiVersion = "operators.coreos.com/v1"
    kind       = "OperatorGroup"
    metadata = {
      name      = "aap-operator-group"
      namespace = kubernetes_namespace_v1.aap.metadata[0].name
    }
    spec = {
      targetNamespaces = [kubernetes_namespace_v1.aap.metadata[0].name]
    }
  })
}

resource "kubectl_manifest" "subscription" {
  depends_on = [kubectl_manifest.operator_group]

  yaml_body = yamlencode({
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "ansible-automation-platform-operator"
      namespace = kubernetes_namespace_v1.aap.metadata[0].name
    }
    spec = {
      channel         = var.channel
      name            = "ansible-automation-platform-operator"
      source          = "redhat-operators"
      sourceNamespace = "openshift-marketplace"
      startingCSV     = var.starting_csv
      # Manual = upgrades never surprise us. deploy.sh approves the
      # InstallPlan matching startingCSV (and only that one).
      installPlanApproval = "Manual"
    }
  })
}

# ── Custom resources ───────────────────────────────────────────────────
# deploy.sh waits for the CSV to reach Succeeded before `terraform apply`
# reaches these (kubectl_manifest retries cover small races).

resource "kubectl_manifest" "controller" {
  depends_on = [kubectl_manifest.subscription]

  yaml_body = yamlencode({
    apiVersion = "automationcontroller.ansible.com/v1beta1"
    kind       = "AutomationController"
    metadata = {
      name      = var.controller_name
      namespace = kubernetes_namespace_v1.aap.metadata[0].name
    }
    spec = {
      admin_password_secret         = kubernetes_secret_v1.admin_password.metadata[0].name
      postgres_configuration_secret = "${var.controller_name}-postgres-configuration"
      ingress_type                  = "Route"
      route_host                    = local.controller_host
      replicas                      = 1
      garbage_collect_secrets       = true
      # Lesson L2 guard: if this namespace ever joins the service mesh,
      # routes stop working without this pod-template annotation.
      annotations = "maistra.io/expose-route: 'true'"
      extra_settings = [
        {
          setting = "AWX_TASK_ENV['GIT_SSL_NO_VERIFY']"
          value   = "'True'" # in-cluster Gitea uses the ingress wildcard cert
        }
      ]
    }
  })
}

resource "kubectl_manifest" "hub" {
  depends_on = [kubectl_manifest.subscription]

  yaml_body = yamlencode({
    apiVersion = "automationhub.ansible.com/v1beta1"
    kind       = "AutomationHub"
    metadata = {
      name      = var.hub_name
      namespace = kubernetes_namespace_v1.aap.metadata[0].name
    }
    spec = {
      postgres_configuration_secret = "${var.hub_name}-postgres-configuration"
      ingress_type                  = "Route"
      route_host                    = local.hub_host
      file_storage_storage_class    = var.hub_storage_class
      file_storage_access_mode      = "ReadWriteMany"
      file_storage_size             = "10Gi"
    }
  })
}

resource "kubectl_manifest" "eda" {
  depends_on = [kubectl_manifest.controller]

  yaml_body = yamlencode({
    apiVersion = "eda.ansible.com/v1alpha1"
    kind       = "EDA"
    metadata = {
      name      = var.eda_name
      namespace = kubernetes_namespace_v1.aap.metadata[0].name
    }
    spec = {
      automation_server_url = "https://${local.controller_host}"
      database = {
        database_secret = "${var.eda_name}-postgres-configuration"
      }
      ingress_type = "Route"
      route_host   = local.eda_host
    }
  })
}
