# Vendored from masterly-platform-iac/modules/aca-env-consumption.
# SELF-HOSTED EXTENSION: optional VNet integration (infrastructure_subnet_id) — the
# install runs in its own VNet so the data plane can be private-endpoint-only.

resource "azurerm_container_app_environment" "this" {
  name                       = var.name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = var.log_analytics_workspace_id
  logs_destination           = "log-analytics"

  # SELF-HOSTED EXTENSION: create-time only — changing it REPLACES the environment
  # (and with it the apps' FQDNs). Consumption-only environments need a /23 subnet.
  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = var.internal_load_balancer_enabled

  tags = var.tags

  lifecycle {
    # Azure materializes a default "Consumption" workload profile on VNet-integrated
    # environments after creation (API-side drift); a plan would then try to strip it.
    # Freeze it — the module stays consumption-only for new installs either way.
    ignore_changes = [workload_profile]
  }
}
