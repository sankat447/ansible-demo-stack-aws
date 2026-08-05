# Ansible Lightspeed backend endpoint.
#
# Everything that generates playbooks (the 🧠 generator job template,
# notebooks) talks to ONE stable in-cluster URL:
#
#   http://lightspeed.<aap-ns>.svc:8080/v1/...
#
# which this nginx proxy forwards to either:
#   - portkey: the base stack's Portkey gateway → self-hosted
#     llama-3-1-8b (Q5 default; satisfies lesson L4 — no direct vLLM), or
#   - redhat:  the Red Hat Content Provider API, adding the bearer key.
#
# The full nginx config is rendered by Terraform and mounted as a
# Secret (it embeds the bearer key — lesson L5). No envsubst/startup
# templating: the UBI s2i nginx image includes nginx.default.d/*.conf
# inside its default :8080 server block, so this is location blocks only.

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

locals {
  upstream = var.provider_choice == "redhat" ? var.redhat_endpoint : var.portkey_endpoint
  api_key  = var.provider_choice == "redhat" ? var.api_key : "portkey-self-hosted"

  nginx_conf = <<-CONF
    location /healthz {
      return 200 'ok';
    }

    location / {
      proxy_pass ${local.upstream};
      proxy_ssl_server_name on;
      proxy_set_header Authorization "Bearer ${local.api_key}";
      # Portkey routing hint — ignored by the Red Hat endpoint.
      proxy_set_header x-portkey-model "${var.model_name}";
      proxy_read_timeout 300s;   # LLM generations are slow
      proxy_send_timeout 300s;
    }
  CONF
}

resource "kubernetes_secret_v1" "config" {
  metadata {
    name      = "lightspeed-config"
    namespace = var.namespace
    labels    = { app = "lightspeed" }
  }
  data = {
    "lightspeed.conf" = local.nginx_conf
  }
}

resource "kubernetes_deployment_v1" "proxy" {
  metadata {
    name      = "lightspeed"
    namespace = var.namespace
    labels    = { app = "lightspeed" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "lightspeed" }
    }
    template {
      metadata {
        labels = { app = "lightspeed" }
        annotations = {
          # Restart on backend switch.
          "checksum/config" = sha256(local.nginx_conf)
          # Lesson L2: harmless outside the mesh, saves a debugging day inside it.
          "maistra.io/expose-route" = "true"
        }
      }
      spec {
        container {
          name  = "nginx"
          image = var.proxy_image
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "conf"
            mount_path = "/opt/app-root/etc/nginx.default.d/lightspeed.conf"
            sub_path   = "lightspeed.conf"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
          }
        }
        volume {
          name = "conf"
          secret {
            secret_name = kubernetes_secret_v1.config.metadata[0].name
          }
        }
      }
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
  }
}

resource "kubernetes_service_v1" "proxy" {
  metadata {
    name      = "lightspeed"
    namespace = var.namespace
    labels    = { app = "lightspeed" }
  }
  spec {
    selector = { app = "lightspeed" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
