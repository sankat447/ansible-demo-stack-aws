# Non-secret defaults for the demo environment. Secrets (Lightspeed API
# key when using the Red Hat provider) are prompted by deploy.sh and
# passed via TF_VAR_ environment variables — never committed.

aws_region          = "us-east-1"
cluster_apps_domain = "apps.ai-demo.iisdemolab.click"

# Q5: self-hosted llama-3-1-8b via Portkey (set to "redhat" + provide
# TF_VAR_lightspeed_api_key to use the Red Hat Content Provider).
lightspeed_provider = "portkey"

# Q6: all three bootstrap event sources.
enable_kafka                = true
enable_alertmanager_source  = true
enable_argocd_notifications = true
