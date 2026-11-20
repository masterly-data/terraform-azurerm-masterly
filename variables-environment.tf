# Inputs read by environment.tf: the Container App Environment's log workspace, the private DNS
# of the front, app and workers environments, and the retirement of aca-<prefix>.

# --- The install's Log Analytics workspace ---------------------------------------------
# The workspace accepts Microsoft Entra ID only: its shared keys authenticate nothing, and it
# takes no ingestion over the public network. The install's own logs and metrics reach it
# through diagnostic settings, which deliver inside Azure Monitor and need neither. These inputs
# choose who may query it from where, and how long it keeps what it holds.

variable "log_query_public_access" {
  type        = bool
  default     = true
  description = "Whether the install's Log Analytics workspace answers queries from the public network. True (the default) lets the Azure portal, the diagnostic bundle (scripts/diagnostic-bundle.sh) and your own tools query it from wherever they run. Every query is signed in with Microsoft Entra ID, because the workspace accepts no shared key: Log Analytics Reader on the workspace runs queries, which is what the diagnostic bundle needs, and Log Analytics Contributor also changes the workspace's settings. Set false to answer only queries that arrive through an Azure Monitor Private Link Scope (AMPLS). The module creates no AMPLS, because an AMPLS changes how every Azure Monitor endpoint resolves for the whole network that uses its private DNS zones, not only this workspace's, so it belongs to whoever owns that network. Before setting false: add the workspace to your AMPLS, give the AMPLS a private endpoint in a network your operators query from, with its privatelink DNS zones linked to that network, and run the diagnostic bundle from inside it. Ingestion over the public network is off whatever this says. The module does not place the workspace in a network security perimeter: an enforced perimeter decides which sources may send logs to the workspace and which may query it, including the diagnostic settings that deliver this install's logs, so its access rules have to be written for your whole estate, which only you can see. This setting, with an AMPLS you own, restricts queries without one. If you associate the workspace with a perimeter of your own, start it in transition mode and confirm the install's logs still arrive before you enforce it."
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "Days the install's Log Analytics workspace keeps what it holds, for every table except AZKVAuditLogs (which follows security_log_retention_days): the apps' console and system logs, the data-plane resources' logs and the metrics the diagnostic settings send (30-730). Azure bills retention beyond the first 31 days per GB per month. Lowering it removes data older than the new window."

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "security_log_retention_days" {
  type        = number
  default     = 90
  description = "Days the install's Log Analytics workspace keeps the AZKVAuditLogs table, which holds the Key Vault audit events: every operation on the install's vault, successful or refused, with the identity that made it (30-730). It is set as the retention of that table alone, so the audit trail can be kept longer than the operational logs log_retention_days governs. The table exists in every workspace, so this is applied whether or not the install has a vault; it holds rows only when enable_key_vault and diagnostics (enable_diagnostics) are both on. Azure bills retention beyond the first 31 days per GB per month. Lowering it removes audit events older than the new window."

  validation {
    condition     = var.security_log_retention_days >= 30 && var.security_log_retention_days <= 730
    error_message = "security_log_retention_days must be between 30 and 730."
  }
}

# --- The front, app and workers environments (ADR 0120) --------------------------------
# One workload-profiles environment on each environment subnet. The app and workers environments
# are always internal, and the front is internal exactly when aca_internal_load_balancer is true.

variable "environment_private_dns_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Whether the module creates the private DNS that resolves the front, app and workers Container Apps environments inside the VNet. True (the default): for each of them that is internal (app and workers always, the front when aca_internal_load_balancer is true), the module creates a private DNS zone in rg-<name_prefix>-aca named the environment's default domain, a wildcard (*) A record to the environment's static IP, and a link from the zone to the install's VNet (on an injected network, the VNet of aca_subnet_id) with auto-registration off. Without such a zone the apps in an internal environment cannot be reached by name. Set false when your platform team owns DNS: the module then creates no zone, record or link, and the container_app_environments output gives each environment's default_domain and static_ip_address for the records your hub creates. Azure assigns the default domain when it creates the environment, so the zone cannot be created ahead of the install."
}

variable "environment_zone_redundant" {
  type        = bool
  default     = false
  nullable    = false
  description = "Whether the front, app and workers Container Apps environments are zone-redundant: Azure spreads each environment's infrastructure and its apps' replicas across the region's availability zones, so an app keeps running when one zone fails (ADR 0120, 2026-11-20 amendment). False (the default) plans no change. Azure fixes this when it creates an environment, so changing it on an existing install REPLACES all three environments and every app in them: the apps' FQDNs change, a frontend or edge custom domain's certificate and binding are created again on the new front environment, whose new custom_domain_verification_id the asuid TXT record must carry before the apply, and the apps start on the module's images until CD's release runs again. Turn it on when you create an install, or plan the replacement in a maintenance window. It needs a region with availability zones, and an app needs at least two replicas to run in two zones: the plan warns (environment_zone_redundancy_needs_two_replicas) when ca-api, ca-frontend or ca-workers runs in one of these environments with a minimum below two (api_min_replicas, frontend_min_replicas, workers_min_replicas, or capacity_profile). ca-edge is not counted: its minimum is fixed at one replica, so with edge set and edge_environment = "front" it can run in a single zone and stop with it until it scales out again; no input changes that today. It covers only the three environments, not aca-<name_prefix>, so move the apps there (frontend_environment, edge_environment, api_environment, workers_environment). For an install that must survive a zone failure, set postgres_zone_redundant_ha too: the database is in one zone otherwise. Refused on an install without the three environments."

  # Read at plan: the environment keys depend on the subnet inputs only (environment.tf).
  validation {
    condition     = !var.environment_zone_redundant || length(local.container_app_environment_keys) == 3
    error_message = "environment_zone_redundant = true applies to the front, app and workers environments, and this install does not have all three: environment_subnet_ids has no environment subnets. On an injected network set front_subnet_id, app_subnet_id and workers_subnet_id; on a network the module builds set front_subnet_prefix, app_subnet_prefix and workers_subnet_prefix, or use a VNet of /21 or larger. Or leave environment_zone_redundant false."
  }
}

# Removes aca-<prefix> once every workload has moved off it. The subnet it ran on, snet-aca, its
# NSG and aca_subnet_id stay: only the environment and its diagnostic setting go.
variable "retire_runtime_environment" {
  type        = bool
  default     = false
  nullable    = false
  description = "Whether to delete aca-<name_prefix>, the Container Apps environment the apps ran in before the front, app and workers environments, once nothing runs in it. False (the default) keeps it, and an upgrade plans no change to it. True deletes aca-<name_prefix> and its diagnostic setting, diag-<name_prefix>-aca-env, and the aca_environment_id output becomes null. Set it only after every move is applied, in the order docs/networking.md gives under \"Retiring the runtime environment\": ca-workers and caj-migrate to the workers environment (workers_environment and migrate_job_environment = \"workers\"), then ca-frontend, ca-edge and ca-api together (frontend_environment and edge_environment = \"front\", api_environment = \"app\"), which also moves the custom-domain certificates. The plan refuses true while any of these is still placed on aca-<name_prefix>, and names what is left; the migrate job is counted only with migrations = \"job\", and ca-workers only with enable_workers. Anything you created in aca-<name_prefix> yourself is not visible to the module: move or delete it first, because Azure deletes the environment with every app and job in it. snet-aca, its NSG and aca_subnet_id stay. Setting it back to false creates a new, empty aca-<name_prefix>."

  # Azure deletes an environment with everything in it, so nothing the module places there may
  # be left: local.runtime_environment_workloads (environment.tf) lists what still is.
  validation {
    condition     = !var.retire_runtime_environment || length(local.runtime_environment_workloads) == 0
    error_message = "retire_runtime_environment = true would delete aca-<name_prefix> while these still run in it: ${join("; ", local.runtime_environment_workloads)}. Move them first, in the order docs/networking.md gives under \"Retiring the runtime environment\", apply, and then set retire_runtime_environment = true; or keep it false."
  }
}
