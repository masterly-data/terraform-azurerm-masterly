# The dedicated workers app (ADR 0066 increment 3): the async-pipeline consume loop as its
# own Container App — same image and env contract as the api, command overridden to
# `python -m masterly_app.workers`, no ingress, no probes. Enabling it flips the api off
# the in-process loop (MASTERLY_INPROCESS_WORKER=false), so exactly one side owns it.

variable "enable_workers" {
  type        = bool
  default     = false
  description = "Run the dedicated workers Container App and take the api off the in-process worker loop (ADR 0066). Off = the api runs the loop in-process (the single-process dev/demo shape, ADR 0012). Required by mode=production — the api scales for request load, the pipeline for job load, independently."

  # Production runs the pipeline in its own app (ADR 0066): with a multi-replica api the
  # in-process loop would run on every replica; the dedicated workers app owns the loop and
  # scales independently of request traffic.
  validation {
    condition     = var.mode != "production" || var.enable_workers
    error_message = "mode=production requires enable_workers=true — the async pipeline must run in the dedicated ca-workers app, not in-process on the (multi-replica) api."
  }
}

variable "workers_min_replicas" {
  type        = number
  default     = 1
  description = "Minimum workers replicas (keep >= 1: the loop polls; scale-to-zero would stall the pipeline on the polling binding)."
}

variable "workers_max_replicas" {
  type        = number
  default     = 1
  description = "Maximum workers replicas. The per-Environment drain is advisory-locked, so extra replicas add throughput across Environments, not duplicate work."
}

locals {
  # Merged into the api's env in main.tf when the workers app owns the loop.
  workers_inprocess_env = var.enable_workers ? {
    MASTERLY_INPROCESS_WORKER = "false"
  } : {}
}

module "workers" {
  count  = var.enable_workers ? 1 : 0
  source = "./modules/aca-container-app"

  name                = "ca-workers"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = var.api_image # the same image as the api; only the command differs

  acr_login_server           = var.acr_login_server
  user_assigned_identity_ids = [module.apps_identity.id]

  registry_username             = var.registry_username
  registry_password_secret_name = var.registry_username != null ? "registry-password" : null

  ingress_enabled = false
  command         = ["python", "-m", "masterly_app.workers"]

  min_replicas = var.workers_min_replicas
  max_replicas = var.workers_max_replicas

  # The full api env contract: build_services in the workers process reads the same
  # settings (identity, license, bus, secret store, redis) as the api.
  env             = local.api_env
  secrets         = local.api_secrets
  env_secret_refs = local.api_env_secret_refs

  tags = local.tags

  depends_on = [
    azurerm_private_endpoint.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.redis,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_role_assignment.kv_secrets_officer,
    azurerm_role_assignment.sb_sender,
    azurerm_role_assignment.sb_receiver,
  ]
}

output "workers_app_name" {
  value       = var.enable_workers ? module.workers[0].name : null
  description = "Container App name of the workers (null when the api runs the loop in-process)."
}
