# AIOps layer root — attaches to the EXISTING base cluster.
# No VPC, no Aurora cluster, no state bucket is created here.

module "aurora_db" {
  source = "../../modules/aurora-db"

  aurora_endpoint_ssm_param        = var.aurora_endpoint_ssm_param
  aurora_master_password_ssm_param = var.aurora_master_password_ssm_param
  aurora_master_username           = var.aurora_master_username

  databases = {
    aap        = {}                          # AutomationController (Q8: logical DB, not a new cluster)
    hub        = {}                          # AutomationHub
    eda        = {}                          # EDA controller
    mattermost = {}                          # collab stack
    aiops      = { extensions = ["vector"] } # incident embeddings (pgvector)
  }
}

module "aap" {
  source = "../../modules/aap-operator"

  channel             = var.aap_channel
  starting_csv        = var.aap_starting_csv
  admin_password      = var.aap_admin_password
  db_host             = module.aurora_db.host
  db_credentials      = module.aurora_db.credentials
  cluster_apps_domain = var.cluster_apps_domain
}

module "lightspeed" {
  source = "../../modules/lightspeed"

  namespace        = module.aap.namespace
  provider_choice  = var.lightspeed_provider
  api_key          = var.lightspeed_api_key
  portkey_endpoint = var.portkey_endpoint
  model_name       = var.llm_model_name
}

module "event_sources" {
  source = "../../modules/event-sources"

  enable_alertmanager_source = var.enable_alertmanager_source
}

module "collab" {
  source = "../../modules/collab"

  db_host       = module.aurora_db.host
  mattermost_db = module.aurora_db.credentials["mattermost"]
}

module "workbench" {
  source = "../../modules/rhoai-workbench"

  db_host          = module.aurora_db.host
  vector_db        = module.aurora_db.credentials["aiops"]
  portkey_endpoint = var.portkey_endpoint
  llm_model_name   = var.llm_model_name
}
