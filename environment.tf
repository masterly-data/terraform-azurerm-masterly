# The Log Analytics workspace, the Container Apps environment the apps run in, and the front,
# app and workers environments beside it.

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
  # Only the certificate identities, each only with its input: frontend_custom_domain and
  # edge_custom_domain (custom-domain.tf). Empty with neither.
  identity_ids = concat(module.frontend_certificate_identity[*].id, module.edge_certificate_identity[*].id)
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
# A Container Apps environment's categories always land in the resource-specific
# ContainerAppConsoleLogs and ContainerAppSystemLogs tables, the only ones the alerts and the
# diagnostic bundle read. Azure keeps no destination type on this resource type (it reads back
# null), so none is set here: setting one made every plan show a change. The legacy custom-log
# (_CL) tables get no new rows.
resource "azurerm_monitor_diagnostic_setting" "aca_env" {
  name                       = "diag-${var.name_prefix}-aca-env"
  target_resource_id         = module.aca_env.id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}

# --- The front, app and workers environments (ADR 0120 §4-§5) ------------------------
# One workload-profiles environment on each environment subnet (network.tf), created beside
# aca-<prefix>. No app runs in them yet: every app, the migrate job and the custom-domain
# certificate stay on module.aca_env, which plans no change.
#
# The app and workers environments are always internal: nothing in them is meant to be reached
# from outside the VNet, so no input turns their load balancer public. The front follows
# aca_internal_load_balancer, the install's existing privacy switch, so an install that is
# private today never gets a public front.

locals {
  # Keyed on what is known at plan, never on a subnet id: on a network the module builds, the
  # ids are unknown until apply, and a for_each over unknown keys refuses the plan. These are
  # exactly the keys whose local.env_subnet_ids value is not null.
  container_app_environment_keys = toset([
    for k in ["front", "app", "workers"] : k
    if(local.inject_network ? local.env_subnet_id_inputs[k] != null : local.create_env_subnets)
  ])

  container_app_environment_internal = {
    front   = var.aca_internal_load_balancer
    app     = true
    workers = true
  }

  # The internal environments get a private DNS zone named their default domain, unless the
  # hub owns DNS (environment_private_dns_enabled = false).
  container_app_environment_dns_keys = toset([
    for k in local.container_app_environment_keys : k
    if var.environment_private_dns_enabled && local.container_app_environment_internal[k]
  ])
}

module "environments" {
  source   = "./modules/aca-env-workload-profiles"
  for_each = local.container_app_environment_keys

  name                           = "aca-${var.name_prefix}-${each.key}"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = var.location
  infrastructure_subnet_id       = local.env_subnet_ids[each.key]
  internal_load_balancer_enabled = local.container_app_environment_internal[each.key]
  tags                           = local.tags

  # The subnet's NSG is in place before an environment starts using the subnet.
  depends_on = [azurerm_subnet_network_security_group_association.environment]
}

# Each environment's console and system logs -> the install's workspace, as for aca-<prefix>
# above. log_analytics_destination_type is left unset: Azure does not keep "Dedicated" on a
# Container Apps environment's setting, so writing it would plan an update on every run.
resource "azurerm_monitor_diagnostic_setting" "environment" {
  for_each = local.container_app_environment_keys

  name                       = "diag-${var.name_prefix}-aca-${each.key}"
  target_resource_id         = module.environments[each.key].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}

# An internal environment's default domain resolves nowhere until a private DNS zone of that
# name, with a wildcard record to the environment's static IP, is linked to the VNet (Microsoft's
# pattern for an internal Container Apps environment). The zone's name is the default domain Azure
# assigns at create time, so a zone cannot be injected the way the Key Vault one is; a hub that
# owns DNS turns these off and creates the records from the container_app_environments output.
# The link always points at the install's own VNet, never at one named by an input.
resource "azurerm_private_dns_zone" "environment" {
  for_each = local.container_app_environment_dns_keys

  name                = module.environments[each.key].default_domain
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "environment" {
  for_each = local.container_app_environment_dns_keys

  name                = "*"
  private_dns_zone_id = azurerm_private_dns_zone.environment[each.key].id
  ttl                 = 300
  records             = [module.environments[each.key].static_ip_address]
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "environment" {
  for_each = local.container_app_environment_dns_keys

  name                 = "pdzl-${var.name_prefix}-aca-${each.key}"
  private_dns_zone_id  = azurerm_private_dns_zone.environment[each.key].id
  virtual_network_id   = local.virtual_network_id
  registration_enabled = false
  tags                 = local.tags
}
