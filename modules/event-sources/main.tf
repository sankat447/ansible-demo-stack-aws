# Event-source plumbing that must exist before/independently of GitOps:
# the namespace, and the AlertmanagerConfig that routes platform alerts
# to the EDA webhook. The Kafka broker, demo app, and log shipper are
# ArgoCD-managed (gitops/manifests/event-sources, gitops/manifests/demo-app).

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    kubectl    = { source = "gavinbunney/kubectl" }
  }
}

resource "kubernetes_namespace_v1" "events" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "aiops"
      # Required for user alert routing: AlertmanagerConfig CRs are only
      # honored in namespaces visible to user-workload monitoring.
      "openshift.io/user-monitoring" = "true"
    }
  }
}

# Routes platform Alertmanager notifications to the EDA rulebook webhook.
#
# ASSUMPTION (verify at deploy — see LESSONS_LEARNED): the base cluster
# has user-workload monitoring with user alert routing enabled
# (`enableUserAlertmanagerConfig: true`). If it does NOT, enabling it is
# a change to openshift-monitoring config, which belongs to the BASE
# repo — STOP and raise a PR there instead of patching from here.
resource "kubectl_manifest" "alertmanager_route" {
  count = var.enable_alertmanager_source ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1beta1"
    kind       = "AlertmanagerConfig"
    metadata = {
      name      = "aiops-eda-webhook"
      namespace = kubernetes_namespace_v1.events.metadata[0].name
    }
    spec = {
      route = {
        receiver = "eda"
        matchers = [
          { name = "alertname", matchType = "=~", value = "KubePodCrashLooping|KubePersistentVolumeFillingUp|KubeNodeNotReady" }
        ]
        groupBy        = ["alertname", "namespace"]
        groupWait      = "10s"
        groupInterval  = "1m"
        repeatInterval = "15m"
      }
      receivers = [
        {
          name = "eda"
          webhookConfigs = [
            {
              # The event-bridge (Vector) is the Alertmanager webhook
              # receiver; it lands alerts on the Kafka topic
              # `aiops.alerts`, which the EDA rulebook consumes. A
              # stable Deployment+Service beats selecting EDA
              # activation pods directly (their labels are an operator
              # implementation detail). Defined in
              # gitops/manifests/event-sources.
              url = "http://event-bridge.${var.namespace}.svc:8687/alerts"
            }
          ]
        }
      ]
    }
  })
}
