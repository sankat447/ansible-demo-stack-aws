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
#   - redhat:  the Red Hat Content Provider API, adding the bearer key
#     from a Secret (lesson L5 — the key never lands in a ConfigMap).
#
# Switching backends is a tfvars change; no playbook changes.

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

locals {
  upstream = var.provider_choice == "redhat" ? var.redhat_endpoint : var.portkey_endpoint

  nginx_conf_template = <<-CONF
    server {
      listen 8080;

      location /healthz {
        return 200 'ok';
      }

      location / {
        proxy_pass $${LS_UPSTREAM};
        proxy_ssl_server_name on;
        proxy_set_header Authorization "Bearer $${LS_API_KEY}";
        # Portkey routing hint — ignored by the Red Hat endpoint.
        proxy_set_header x-portkey-model "$${LS_MODEL}";
        proxy_read_timeout 300s;   # LLM generations are slow
        proxy_send_timeout 300s;
      }
    }
  CONF
}

resource "kubernetes_config_map_v1" "proxy_template" {
  metadata {
    name      = "lightspeed-proxy-template"
    namespace = var.namespace
    labels    = { app = "lightspeed" }
  }
  data = {
    "lightspeed.conf.template" = local.nginx_conf_template
  }
}

resource "kubernetes_secret_v1" "config" {
  metadata {
    name      = "lightspeed-config"
    namespace = var.namespace
    labels    = { app = "lightspeed" }
  }
  data = {
    LS_UPSTREAM = local.upstream
    LS_MODEL    = var.model_name
    # Portkey mode needs no key; keep a harmless placeholder so the
    # header render never emits an empty Bearer.
    LS_API_KEY = var.provider_choice == "redhat" ? var.api_key : "portkey-self-hosted"
    PROVIDER   = var.provider_choice
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
          "checksum/config" = sha256(jsonencode(kubernetes_secret_v1.config.data))
          # Lesson L2: harmless outside the mesh, saves a debugging day inside it.
          "maistra.io/expose-route" = "true"
        }
      }
      spec {
        container {
          name  = "nginx"
          image = var.proxy_image
          command = ["/bin/sh", "-c", <<-SH
            envsubst '$${LS_UPSTREAM} $${LS_API_KEY} $${LS_MODEL}' \
              < /tmpl/lightspeed.conf.template \
              > /opt/app-root/etc/nginx.default.d/lightspeed.conf \
            && exec nginx -g 'daemon off;'
          SH
          ]
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.config.metadata[0].name
            }
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "tmpl"
            mount_path = "/tmpl"
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
          name = "tmpl"
          config_map {
            name = kubernetes_config_map_v1.proxy_template.metadata[0].name
          }
        }
      }
    }
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
