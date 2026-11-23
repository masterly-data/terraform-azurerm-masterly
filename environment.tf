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
  # Gone with retire_runtime_environment, once nothing runs in it (variables-environment.tf).
  # Read it through module.aca_env[*] or one(): with count = 0 there is no [0].
  count  = var.retire_runtime_environment ? 0 : 1
  source = "./modules/aca-env-consumption"

  name                           = "aca-${var.name_prefix}"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = var.location
  infrastructure_subnet_id       = local.aca_subnet_id
  internal_load_balancer_enabled = var.aca_internal_load_balancer
  # Only the certificate identities, each only with its input: frontend_custom_domain and
  # edge_custom_domain (custom-domain.tf). Empty with neither.
  # They follow the apps: with frontend_environment and edge_environment = "front" they are on the
  # front environment instead, and this list is empty.
  identity_ids = local.environment_certificate_identity_ids["aca"]
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
  count = var.retire_runtime_environment ? 0 : 1

  name                       = "diag-${var.name_prefix}-aca-env"
  target_resource_id         = module.aca_env[0].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}

# Before retire_runtime_environment the two were single objects. Without these an upgrade would
# destroy aca-<prefix>, with every app in it, and create it again.
moved {
  from = module.aca_env
  to   = module.aca_env[0]
}

moved {
  from = azurerm_monitor_diagnostic_setting.aca_env
  to   = azurerm_monitor_diagnostic_setting.aca_env[0]
}

# --- The front, app and workers environments (ADR 0120 §4-§5) ------------------------
# One workload-profiles environment on each environment subnet (network.tf), created beside
# aca-<prefix>. By default no app runs in them: every app, the migrate job and the custom-domain
# certificates stay on module.aca_env, which plans no change. frontend_environment,
# edge_environment and api_environment move ca-frontend and ca-edge to the front environment and
# ca-api to the app environment, together; the certificates follow the frontend and the edge.
# workers_environment and migrate_job_environment place ca-workers and caj-migrate in the
# workers environment.
#
# The app and workers environments are always internal: nothing in them is meant to be reached
# from outside the VNet, so no input turns their load balancer public. The front follows
# aca_internal_load_balancer, the install's existing privacy switch, so an install that is
# private today never gets a public front.

locals {
  # Keyed on what is known at plan, never on a subnet id: on a network the module builds, the
  # ids are unknown until apply, and a for_each over unknown keys refuses the plan. These are
  # exactly the keys whose local.env_subnet_ids value is not null.
  # The add-on keys (core, outbound, extension) only with their add-on on (main.tf).
  container_app_environment_keys = toset(concat(
    [
      for k in ["front", "app", "workers"] : k
      if(local.inject_network ? local.env_subnet_id_inputs[k] != null : local.create_env_subnets)
    ],
    [
      for k in local.add_on_keys : k
      if(local.inject_network ? local.add_on_subnet_id_inputs[k] != null : local.create_add_on_subnets)
    ],
  ))

  # Every Container Apps environment the install has, as keys: "aca" (aca-<prefix>) first while it
  # is not retired, then the keys above. Known at plan; the outbound_allowlist output's keys and the
  # deployment_stamp output's environments.
  install_environment_keys = concat(var.retire_runtime_environment ? [] : ["aca"], sort(tolist(local.container_app_environment_keys)))

  baseline_container_app_environment_internal = {
    front   = var.aca_internal_load_balancer
    app     = true
    workers = true
  }

  # The add-on environments are always internal, as app and workers are: core reaches the data plane
  # only, outbound calls out and is called by nothing, and extension is reached by nothing of ours.
  add_on_container_app_environment_internal = {
    core      = true
    outbound  = true
    extension = true
  }

  container_app_environment_internal = merge(local.baseline_container_app_environment_internal, local.add_on_container_app_environment_internal)

  # The internal environments get a private DNS zone named their default domain, unless the
  # hub owns DNS (environment_private_dns_enabled = false).
  container_app_environment_dns_keys = toset([
    for k in local.container_app_environment_keys : k
    if var.environment_private_dns_enabled && local.container_app_environment_internal[k]
  ])

  # --- Where ca-frontend, ca-edge and ca-api run (variables-core.tf) ---
  # "aca" is module.aca_env; any other placement is that key of module.environments. A placement
  # on an environment the module does not create is refused (main.tf, azurerm_resource_group.aca);
  # try() only keeps the missing key from erroring beside that refusal, and the fallback is never
  # applied. aca-<prefix> is read through one(): retire_runtime_environment refuses while any app
  # is placed on it, and the splat keeps a retired (count = 0) module.aca_env from erroring.
  aca_environment_id      = one(module.aca_env[*].id)
  frontend_environment_id = var.frontend_environment == "aca" ? local.aca_environment_id : try(module.environments[var.frontend_environment].id, local.aca_environment_id)
  edge_environment_id     = var.edge_environment == "aca" ? local.aca_environment_id : try(module.environments[var.edge_environment].id, local.aca_environment_id)
  api_environment_id      = var.api_environment == "aca" ? local.aca_environment_id : try(module.environments[var.api_environment].id, local.aca_environment_id)

  # ca-workers and caj-migrate: aca-<prefix>, or the workers environment. Read by the workload and
  # by its environment_move sleep below, so the two can never disagree. try() keeps a missing
  # workers environment from erroring where the workload does not exist; its own refusal reports it.
  workers_environment_id     = var.workers_environment == "workers" ? try(module.environments["workers"].id, local.aca_environment_id) : local.aca_environment_id
  migrate_job_environment_id = var.migrate_job_environment == "workers" ? try(module.environments["workers"].id, local.aca_environment_id) : local.aca_environment_id

  # How long a moved workload stays deleted before it is created again. A move replaces the Container
  # App or job under the same name, and Azure still holds the old one's identity pending deletion
  # when Terraform creates the new one: 409 or 400 FailedIdentityOperation. On STG, 2026-11-20, both
  # moves failed on the first apply (test-install #49 and #50) and a retry a few minutes later
  # applied cleanly; 180s is a first guess from that, to be measured by the first test-install move
  # after release. It is a destroy wait, so a fresh install is not slowed.
  environment_move_wait = "180s"

  # The workloads that exist, each with the environment id it runs in. A move changes that id.
  environment_move_workloads = merge(
    {
      api      = local.api_environment_id
      frontend = local.frontend_environment_id
    },
    var.enable_workers ? { workers = local.workers_environment_id } : {},
    local.migrate_job ? { migrate = local.migrate_job_environment_id } : {},
    local.edge_enabled ? { edge = local.edge_environment_id } : {},
  )

  # What the module still places on aca-<prefix>; retire_runtime_environment is refused while any
  # is left (variables-environment.tf). The certificates follow ca-frontend and ca-edge, so they
  # leave with them. ca-workers counts only with enable_workers, caj-migrate only with
  # migrations = "job": otherwise neither exists.
  runtime_environment_workloads = compact([
    var.frontend_environment == "aca" ? "ca-frontend (frontend_environment = \"aca\")" : "",
    var.edge_environment == "aca" ? (local.edge_enabled ? "ca-edge (edge_environment = \"aca\")" : "edge_environment = \"aca\"") : "",
    var.api_environment == "aca" ? "ca-api (api_environment = \"aca\")" : "",
    var.frontend_environment == "aca" && local.frontend_custom_domain ? "the frontend_custom_domain certificate (it follows frontend_environment)" : "",
    var.edge_environment == "aca" && local.edge_custom_domain ? "the edge_custom_domain certificate (it follows edge_environment)" : "",
    var.enable_workers && var.workers_environment == "runtime" ? "ca-workers (workers_environment = \"runtime\")" : "",
    var.migrations == "job" && var.migrate_job_environment == "runtime" ? "caj-migrate (migrations = \"job\" with migrate_job_environment = \"runtime\")" : "",
  ])

  # ca-api in the app environment: its callers cross environments, so they address it by its
  # name under the app environment's default domain, over HTTPS, and verify its certificate. Built
  # from the environment's default domain, never from module.api's fqdn: Azure has reported that
  # fqdn in the internal and the external form with no change on our side (main.tf).
  api_in_app_environment     = var.api_environment == "app"
  api_cross_environment_host = local.api_in_app_environment ? "ca-api.${try(module.environments["app"].default_domain, "")}" : null

  # The one origin ca-frontend's BFF calls ca-api on, scheme and host only. Both apps read it from
  # here so the two can never disagree: the BFF uses it as MASTERLY_API_BASE_URL, and ca-api as
  # MASTERLY_DPOP_INTERNAL_ORIGIN, the URL every session's DPoP proof must name (main.tf).
  api_internal_origin = local.api_in_app_environment ? "https://${local.api_cross_environment_host}" : "http://ca-api"

  # The certificate identities go on the environment that runs the app they serve, and nowhere
  # else; concat(frontend, edge), the order module.aca_env always had.
  # The add-on environments run neither app, so they carry no identity at all: in the extension
  # environment, any identity would be a token extension code could use (ADR 0120 §7).
  environment_certificate_identity_ids = merge(
    {
      for k in ["aca", "front", "app", "workers"] : k => concat(
        var.frontend_environment == k ? module.frontend_certificate_identity[*].id : [],
        var.edge_environment == k ? module.edge_certificate_identity[*].id : [],
      )
    },
    { for k in ["core", "outbound", "extension"] : k => [] },
  )

  # The environment that holds the custom-domain certificates (custom-domain.tf), for the
  # verification id the asuid TXT records carry.
  certificate_environment_key = var.frontend_environment
}

module "environments" {
  source   = "./modules/aca-env-workload-profiles"
  for_each = local.container_app_environment_keys

  name                           = "aca-${var.name_prefix}-${each.key}"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = var.location
  infrastructure_subnet_id       = local.env_subnet_ids[each.key]
  internal_load_balancer_enabled = local.container_app_environment_internal[each.key]
  # One choice for the baseline (ADR 0120, 2026-11-20 amendment), which core and outbound share as
  # the workers environment split in two. The extension environment is outside it and never is.
  zone_redundancy_enabled = each.key == "extension" ? false : var.environment_zone_redundant
  # The certificate identities, only on the environment the frontend and the edge run in.
  identity_ids = local.environment_certificate_identity_ids[each.key]
  tags         = local.tags

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

# The wait between deleting a moved workload and creating it again (local.environment_move_wait).
# Each workload lists its sleep in depends_on, so a move runs: destroy the workload, destroy the
# sleep (it waits), create the sleep, create the workload. The trigger is the environment id and
# nothing else, so only a move replaces a sleep. Terraform applies a keyed depends_on to the whole
# resource, so a workload also waits for the other sleeps' recreation; they run in parallel.
resource "time_sleep" "environment_move" {
  for_each = local.environment_move_workloads

  triggers = {
    environment_id = each.value
  }
  destroy_duration = local.environment_move_wait
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

# A zone-redundant environment spreads an app's replicas across zones only when it has two or
# more. A warning, not a refusal: one replica still runs, in one zone. ca-edge's floor is fixed at
# one and no input changes it, so it is not counted; docs/networking.md states the gap.
locals {
  zone_redundant_single_replica_apps = var.environment_zone_redundant ? compact([
    var.api_environment != "aca" && local.api_min_replicas < 2 ? "ca-api (api_min_replicas = ${local.api_min_replicas})" : "",
    var.frontend_environment != "aca" && local.frontend_min_replicas < 2 ? "ca-frontend (frontend_min_replicas = ${local.frontend_min_replicas})" : "",
    var.enable_workers && var.workers_environment == "workers" && local.workers_min_replicas < 2 ? "ca-workers (workers_min_replicas = ${local.workers_min_replicas})" : "",
  ]) : []
}

check "environment_zone_redundancy_needs_two_replicas" {
  assert {
    condition     = length(local.zone_redundant_single_replica_apps) == 0
    error_message = "environment_zone_redundant is on, but these apps run in a zone-redundant environment with fewer than two replicas, so each runs in one zone and stops if that zone fails: ${join("; ", local.zone_redundant_single_replica_apps)}. Raise each minimum to at least 2 (capacity_profile \"enterprise\" sets 2 for all three)."
  }
}
