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

  # SELF-HOSTED EXTENSION. The input name follows the provider's, and the provider's name
  # undersells what it writes: azurerm sets BOTH `peerAuthentication.mtls.enabled` and
  # `peerTrafficConfiguration.encryption.enabled` from this one bool (verified in
  # azurerm v4.81.0 `container_app_environment_resource.go`, create and update). The second
  # is the one Azure calls peer-to-peer encryption and the one to check an install against:
  #
  #   az containerapp env show -n <env> -g <rg> \
  #     --query properties.peerTrafficConfiguration.encryption.enabled
  #
  # Read is the asymmetric half: the provider refreshes state from `peerAuthentication` ONLY.
  # If the two ever diverge in Azure — someone runs `az containerapp env update
  # --enable-peer-to-peer-encryption false` — terraform sees no drift and reports nothing.
  # The query above is the check that actually catches that; a plan is not.
  #
  # Not create-time-only: this is an in-place update, and ingress settings apply to all
  # revisions at once, so turning it on does not roll the apps.
  mutual_tls_enabled = var.mutual_tls_enabled

  tags = var.tags

  lifecycle {
    # Azure materializes a default "Consumption" workload profile on VNet-integrated
    # environments after creation (API-side drift); a plan would then try to strip it.
    # Freeze it — the module stays consumption-only for new installs either way.
    ignore_changes = [workload_profile]
  }
}
