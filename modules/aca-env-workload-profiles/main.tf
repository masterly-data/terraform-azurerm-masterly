# Vendored from masterly-platform-iac/modules/aca-env-consumption, as a workload-profiles
# environment (ADR 0120 §4-§5): the front, app and workers environments of the root module.
# SELF-HOSTED EXTENSION: VNet integration (infrastructure_subnet_id) is required, not optional —
# the install runs in its own VNet so the data plane can be private-endpoint-only.
#
# A module of its own rather than a switch on aca-env-consumption: that module freezes
# workload_profile under ignore_changes, and a lifecycle block cannot be conditional, so an
# environment that declares its profile cannot share the resource with one that does not. This
# module's own ignore_changes covers infrastructure_resource_group_name only, never workload_profile.

locals {
  # The Consumption profile only. Azure adds this profile itself to an environment on a delegated
  # subnet; declaring it keeps a plan from trying to strip it, without the workload_profile
  # ignore_changes the sibling module needs. Dedicated profiles are not offered yet.
  workload_profiles = [
    {
      name                  = "Consumption"
      workload_profile_type = "Consumption"
    },
  ]
}

resource "azurerm_container_app_environment" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # SELF-HOSTED EXTENSION: logs go through Azure Monitor, not straight to a workspace. The
  # caller attaches a diagnostic setting to this environment (the root module's
  # azurerm_monitor_diagnostic_setting.environment), which writes the resource-specific
  # ContainerAppConsoleLogs / ContainerAppSystemLogs tables. The provider refuses
  # log_analytics_workspace_id alongside "azure-monitor", which is why this module takes no
  # workspace.
  logs_destination = "azure-monitor"

  # SELF-HOSTED EXTENSION: create-time only — changing it REPLACES the environment (and with it
  # the apps' FQDNs). A workload-profiles environment accepts a /27 or larger, delegated to
  # Microsoft.App/environments.
  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = var.internal_load_balancer_enabled

  # SELF-HOSTED EXTENSION: peer-to-peer encryption inside the environment. azurerm sets both
  # `peerAuthentication.mtls.enabled` and `peerTrafficConfiguration.encryption.enabled` from this
  # one bool, and refreshes state from the first only; modules/aca-env-consumption/main.tf has
  # the detail and the az query that checks the second.
  mutual_tls_enabled = var.mutual_tls_enabled

  # SELF-HOSTED EXTENSION: user-assigned identities on the environment itself, which it uses
  # to read certificates from Key Vault (the root's custom-domain.tf, when the frontend and the
  # edge run on the front environment). Empty by default, which renders no block, so an
  # environment without them plans exactly as before.
  dynamic "identity" {
    for_each = length(var.identity_ids) > 0 ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = var.identity_ids
    }
  }

  dynamic "workload_profile" {
    for_each = local.workload_profiles
    content {
      name                  = workload_profile.value.name
      workload_profile_type = workload_profile.value.workload_profile_type
    }
  }

  tags = var.tags

  lifecycle {
    # Defensive. Azure creates the ME_<env>_<rg>_<location> managed group with the profile, and
    # infrastructure_resource_group_name is Optional + ForceNew in azurerm; the provider
    # suppresses its diff only when workload_profile is non-empty. The declared Consumption
    # profile normally does that, so this changes nothing today; it keeps a plan on stale state
    # from replacing the environment if that ever stops holding. workload_profile is NOT
    # ignored: this module declares it.
    ignore_changes = [infrastructure_resource_group_name]
  }
}
