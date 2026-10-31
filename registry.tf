# The registry's private endpoint. Opt-in (default off): the apps pull over the registry's
# public endpoint unless this is set. When it is, the install's VNet gets a private endpoint to
# the registry acr_id names (the "registry" subresource) in snet-private-endpoints, or the
# injected private_endpoints_subnet_id, and a privatelink.azurecr.io private DNS zone linked to
# that VNet, so the registry's login server and its data endpoint resolve to the endpoint's
# private addresses from inside it. The registry_location, the image references and the
# AcrPull grants are unchanged: only the path the pulls take moves.
#
# Only the identity modes (managed_identity, customer_registry) take an endpoint. The token mode
# is the direct pull from Masterly's registry with the credential from the install bundle, and
# opens no network path into it.
#
# Kept in its own file (the email.tf composition pattern) — Terraform merges every *.tf.

variable "registry_private_endpoint" {
  type        = bool
  default     = false
  nullable    = false
  description = "Create a private endpoint to the registry the apps pull from, in the install's private-endpoint subnet, with a privatelink.azurecr.io private DNS zone linked to the install's VNet and the endpoint's DNS zone group in it, so the apps pull over the VNet. Off (the default) pulls over the registry's public endpoint. Used only with registry_credential_mode = \"managed_identity\" or \"customer_registry\" (the token mode pulls with its credential and is refused), and needs acr_id, the resource ID of the registry the endpoint connects to, which must be the registry registry_location names (the module does not compare the two). The registry must be on the Premium SKU, which is the one that takes private endpoints, and the connection is requested as automatically approved, so the identity running the apply needs the right to approve private endpoint connections on that registry. The module does not change the registry's own public network access: closing it is the registry owner's choice. The zone is always created: where the VNet is already linked to a central privatelink.azurecr.io zone, leave this off and add the endpoint on the platform side (docs/networking.md)."

  validation {
    condition     = !var.registry_private_endpoint || (var.registry_credential_mode != "token" && nonsensitive(var.registry_token == null) && var.registry_username == null)
    error_message = "registry_private_endpoint is used only with registry_credential_mode = \"managed_identity\" or \"customer_registry\": the token mode pulls with the credential from your install bundle and takes no private endpoint. Set one of those modes and remove registry_token, or leave registry_private_endpoint off."
  }

  validation {
    condition     = !var.registry_private_endpoint || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ContainerRegistry/registries/[^/]+$", var.acr_id))
    error_message = "registry_private_endpoint needs acr_id set to the resource ID of the registry the endpoint connects to (/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.ContainerRegistry/registries/<name>)."
  }
}

locals {
  # Everything below gates on THIS, not on var.registry_private_endpoint directly. For every
  # valid configuration the two are identical. In an invalid one (the token mode, or no registry
  # in acr_id) the resources stay at count 0, so the plan reports the guard above that explains
  # the problem instead of a provider error about the connection (the pattern of redis.tf).
  registry_private_endpoint = (
    var.registry_private_endpoint && !local.registry_token_mode &&
    can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ContainerRegistry/registries/[^/]+$", var.acr_id))
  )
}

resource "azurerm_private_dns_zone" "registry" {
  count = local.registry_private_endpoint ? 1 : 0

  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "registry" {
  count = local.registry_private_endpoint ? 1 : 0

  name                = "pdzl-${var.name_prefix}-registry"
  private_dns_zone_id = azurerm_private_dns_zone.registry[0].id
  virtual_network_id  = local.virtual_network_id
  tags                = local.tags
}

resource "azurerm_private_endpoint" "registry" {
  count = local.registry_private_endpoint ? 1 : 0

  name                = "pe-${var.name_prefix}-registry"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-registry"
    private_connection_resource_id = var.acr_id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  # The zone group writes the records for both of the registry's names (its login server and
  # its regional data endpoint), and removes them with the endpoint.
  private_dns_zone_group {
    name                 = "registry"
    private_dns_zone_ids = [azurerm_private_dns_zone.registry[0].id]
  }

  tags = local.tags
}

output "registry_private_endpoint_id" {
  value       = one(azurerm_private_endpoint.registry[*].id)
  description = "Resource ID of the registry's private endpoint in the install's VNet. Null when registry_private_endpoint is off."
}
