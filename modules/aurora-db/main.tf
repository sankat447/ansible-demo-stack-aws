# Creates logical databases in the EXISTING Aurora cluster via an
# in-cluster Job. The operator workstation has AWS (SSM) and cluster-API
# access but no network path into the Aurora VPC — pods do. So Terraform
# reads the endpoint/master password from SSM, ships them to the cluster
# as a Secret (never a ConfigMap — lesson L5), and a psql Job applies
# idempotent SQL from inside the cluster.

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    random     = { source = "hashicorp/random" }
    aws        = { source = "hashicorp/aws" }
  }
}

data "aws_ssm_parameter" "endpoint" {
  name = var.aurora_endpoint_ssm_param
}

data "aws_ssm_parameter" "master_password" {
  name            = var.aurora_master_password_ssm_param
  with_decryption = true
}

resource "random_password" "app" {
  for_each = var.databases

  length  = 24
  special = false
}

locals {
  # Idempotent per-database bootstrap: role, database, extensions.
  init_sql = join("\n", concat(
    [for name, db in var.databases : <<-SQL
      -- ${name}
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}_app') THEN
          CREATE ROLE ${name}_app LOGIN;
        END IF;
      END $$;
      ALTER ROLE ${name}_app WITH LOGIN PASSWORD '${random_password.app[name].result}';
      -- Aurora master user is not superuser: it must be a member of a
      -- role to create a database owned by it ("must be able to SET ROLE").
      GRANT ${name}_app TO ${var.aurora_master_username};
      SELECT 'CREATE DATABASE ${name} OWNER ${name}_app'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${name}')\gexec
    SQL
    ],
    flatten([for name, db in var.databases : [
      for ext in db.extensions :
      "\\connect ${name}\nCREATE EXTENSION IF NOT EXISTS ${ext};"
    ]])
  ))

  job_suffix = substr(sha256(local.init_sql), 0, 8)
}

resource "kubernetes_namespace_v1" "bootstrap" {
  metadata {
    name = "aiops-db-bootstrap"
    labels = {
      "app.kubernetes.io/part-of" = "aiops"
    }
  }
}

resource "kubernetes_secret_v1" "bootstrap" {
  metadata {
    name      = "aurora-bootstrap"
    namespace = kubernetes_namespace_v1.bootstrap.metadata[0].name
  }

  data = {
    PGHOST     = data.aws_ssm_parameter.endpoint.value
    PGUSER     = var.aurora_master_username
    PGPASSWORD = data.aws_ssm_parameter.master_password.value
    "init.sql" = local.init_sql
  }
}

resource "kubernetes_job_v1" "init" {
  metadata {
    # SQL hash in the name so changed SQL rolls a fresh (immutable) Job.
    name      = "aurora-db-init-${local.job_suffix}"
    namespace = kubernetes_namespace_v1.bootstrap.metadata[0].name
  }

  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = { app = "aurora-db-init" }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "psql"
          image   = var.psql_image
          command = ["psql", "--set=ON_ERROR_STOP=1", "-d", "postgres", "-f", "/sql/init.sql"]
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.bootstrap.metadata[0].name
            }
          }
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
            read_only  = true
          }
        }
        volume {
          name = "sql"
          secret {
            secret_name = kubernetes_secret_v1.bootstrap.metadata[0].name
            items {
              key  = "init.sql"
              path = "init.sql"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}
