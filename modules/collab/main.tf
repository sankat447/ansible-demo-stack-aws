# Namespace + secrets for the collab stack (Gitea, Mattermost).
# The workloads themselves are ArgoCD-managed (gitops/manifests/collab);
# only the secrets live in Terraform (lesson L5 — never in git/ConfigMaps).

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    random     = { source = "hashicorp/random" }
  }
}

resource "kubernetes_namespace_v1" "collab" {
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/part-of" = "aiops" }
  }
}

resource "random_password" "gitea_admin" {
  length  = 20
  special = false
}

resource "kubernetes_secret_v1" "gitea_admin" {
  metadata {
    name      = "gitea-admin"
    namespace = kubernetes_namespace_v1.collab.metadata[0].name
    labels    = { app = "gitea" }
  }
  data = {
    username = "aiops-admin"
    password = random_password.gitea_admin.result
  }
}

resource "kubernetes_secret_v1" "mattermost_db" {
  metadata {
    name      = "mattermost-db"
    namespace = kubernetes_namespace_v1.collab.metadata[0].name
    labels    = { app = "mattermost" }
  }
  data = {
    # Mattermost reads its DSN from this single env var.
    MM_SQLSETTINGS_DATASOURCE = "postgres://${var.mattermost_db.username}:${var.mattermost_db.password}@${var.db_host}:5432/${var.mattermost_db.database}?sslmode=prefer&connect_timeout=10"
  }
}

resource "random_password" "mattermost_admin" {
  length  = 20
  special = false
}

resource "kubernetes_secret_v1" "mattermost_admin" {
  metadata {
    name      = "mattermost-admin"
    namespace = kubernetes_namespace_v1.collab.metadata[0].name
    labels    = { app = "mattermost" }
  }
  data = {
    username = "ansibleadmin"
    email    = "ansibleadmin@ansible.com" # lab-parity credential identity
    password = random_password.mattermost_admin.result
  }
}
