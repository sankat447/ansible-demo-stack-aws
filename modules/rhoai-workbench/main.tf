# Namespace + secrets for the AIOps workbench. RHOAI itself is installed
# by the BASE platform — this module only prepares a data science
# project for it. The Notebook CR is ArgoCD-managed
# (gitops/manifests/workbench).

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

resource "kubernetes_namespace_v1" "notebooks" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "aiops"
      # Make it a Data Science Project in the existing RHOAI dashboard.
      "opendatahub.io/dashboard" = "true"
    }
    annotations = {
      "openshift.io/display-name" = "AIOps Notebooks"
    }
  }
}

resource "kubernetes_secret_v1" "vector_db" {
  metadata {
    name      = "aiops-vector-db"
    namespace = kubernetes_namespace_v1.notebooks.metadata[0].name
  }
  data = {
    PGHOST     = var.db_host
    PGPORT     = "5432"
    PGDATABASE = var.vector_db.database
    PGUSER     = var.vector_db.username
    PGPASSWORD = var.vector_db.password
  }
}

# Non-secret runtime config for the notebook (safe in a ConfigMap).
resource "kubernetes_config_map_v1" "notebook_env" {
  metadata {
    name      = "aiops-notebook-env"
    namespace = kubernetes_namespace_v1.notebooks.metadata[0].name
  }
  data = {
    # Lesson L4: LLM calls only via the gateway.
    PORTKEY_ENDPOINT = var.portkey_endpoint
    LLM_MODEL        = var.llm_model_name
    THANOS_URL       = "https://thanos-querier.openshift-monitoring.svc:9091"
    AAP_URL          = "https://aap-controller.aap.svc"
  }
}
