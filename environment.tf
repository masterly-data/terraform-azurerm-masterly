# The Log Analytics workspace and the Container Apps environment the apps run in.

# --- Observability + the ACA environment ---------------------------------------

module "logs" {
  source = "./modules/log-analytics-workspace"

  name                    = "log-${var.name_prefix}"
  resource_group_name     = azurerm_resource_group.aca.name
  location                = var.location
  retention_days          = var.log_retention_days
  security_retention_days = var.security_log_retention_days
  internet_query_enabled  = var.log_query_public_access
  tags                    = local.tags
}

module "aca_env" {
  source = "./modules/aca-env-consumption"

  name                           = "aca-${var.name_prefix}"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = var.location
  infrastructure_subnet_id       = local.aca_subnet_id
  internal_load_balancer_enabled = var.aca_internal_load_balancer
  # Only the certificate identity, and only with frontend_custom_domain (custom-domain.tf).
  identity_ids = module.frontend_certificate_identity[*].id
  # Only with egress_firewall: the route table's precondition reads the profiles (network.tf).
  read_workload_profiles = var.egress_firewall != null
  tags                   = local.tags
}

# The apps' console and system logs -> the install's workspace. The environment sends its logs
# through Azure Monitor (modules/aca-env-consumption), so this setting is the only path they
# take to the workspace, and the one place they are named. It is on the environment rather than
# on each app, so it covers ca-api, ca-frontend, ca-workers, the ca-bundle-init init containers
# that run inside them and any app added later, with no per-app wiring to forget.
#
# Not gated on enable_diagnostics: the environment sent these logs to the workspace in every
# mode before it moved to Azure Monitor, and the diagnostic bundle reads them in every mode.
#
# "Dedicated" writes the resource-specific ContainerAppConsoleLogs and ContainerAppSystemLogs
# tables, the only ones the alerts and the diagnostic bundle read. The legacy custom-log (_CL)
# tables get no new rows after the apply.
resource "azurerm_monitor_diagnostic_setting" "aca_env" {
  name                           = "diag-${var.name_prefix}-aca-env"
  target_resource_id             = module.aca_env.id
  log_analytics_workspace_id     = module.logs.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
