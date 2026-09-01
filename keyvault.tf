# The install's Key Vault (ADR 0066 increment 2) — the durable secret-store binding.
# Opt-in (default off; dev/demo run the in-process store): when enabled, this provisions a
# per-install vault (RBAC mode, no access policies) and grants the apps identity the
# Secrets Officer data-plane role. The api is flipped to MASTERLY_SECRET_STORE=keyvault and
# handed the vault URI; auth is the managed identity via AZURE_CLIENT_ID — no secret.
# Sealed material (BYO-DB connection strings, GitOps tokens) then survives restarts.
#
# Hardening (production): soft-delete + purge protection so a compromised or fat-fingered
# principal cannot permanently destroy the vault (purge protection is irreversible, so it is
# armed only in production), and — like the starter Postgres and Redis — no public network
# presence: public access is disabled and the apps reach the vault over a private endpoint in
# snet-private-endpoints, with private DNS (privatelink.vaultcore.azure.net). demo/dev keeps
# public access for ease of evaluation.
#
# Kept in its own file (the email.tf composition pattern) — Terraform merges every *.tf.

variable "enable_key_vault" {
  type        = bool
  default     = false
  description = "Provision a per-install Key Vault and run the apps on the keyvault secret-store binding (ADR 0066). Required for mode=production; off = the in-process store (dev/demo — sealed secrets are lost on restart)."
}

variable "key_vault_soft_delete_retention_days" {
  type        = number
  default     = 90
  description = "Soft-delete retention window for the install's Key Vault (7-90 days). Deleted secrets/vaults are recoverable within this window."

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "key_vault_private_dns_zone_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing privatelink.vaultcore.azure.net private DNS zone (hub-and-spoke landing zones that centralize private DNS and deny zone creation in spokes). When set, the module creates no zone and no VNet link — linking this VNet to the central zone (or DINE policy) is the platform team's side. Null (default) creates a per-install zone + link when the vault runs private (production)."
}

data "azurerm_client_config" "current" {}

locals {
  # Public network access is disabled in production (private-endpoint-only, mirroring the
  # data plane); demo/dev keep it public for ease of evaluation.
  key_vault_public           = var.mode != "production"
  key_vault_private_endpoint = var.enable_key_vault && !local.key_vault_public
  create_key_vault_dns       = local.key_vault_private_endpoint && var.key_vault_private_dns_zone_id == null
  key_vault_dns_zone_id      = local.key_vault_private_endpoint ? (var.key_vault_private_dns_zone_id != null ? var.key_vault_private_dns_zone_id : azurerm_private_dns_zone.key_vault[0].id) : null
}

resource "azurerm_key_vault" "this" {
  count = var.enable_key_vault ? 1 : 0

  # Vault names are 3-24 chars, globally unique: truncate long custom prefixes so the
  # install suffix always fits.
  name                = "kv-${substr(var.name_prefix, 0, 14)}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC-only (no access policies): grants are role assignments, same as every other
  # data-plane permission in this module.
  rbac_authorization_enabled = true

  # Recoverability: soft-delete is always on (Azure default, 90d), and purge protection —
  # which is IRREVERSIBLE once enabled — is armed in production so the vault (and its sealed
  # secrets) cannot be permanently destroyed by a compromised or fat-fingered principal.
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  purge_protection_enabled   = var.mode == "production"

  # No public presence in production: the apps reach the vault over the private endpoint
  # below. Default-deny network ACLs back the private path (Azure services + the private
  # endpoint still resolve). demo/dev keeps public access for evaluation.
  public_network_access_enabled = local.key_vault_public

  network_acls {
    bypass         = "AzureServices"
    default_action = local.key_vault_public ? "Allow" : "Deny"
  }

  tags = local.tags
}

# The apps identity reads/writes/deletes secrets — the Secrets Officer data-plane role,
# scoped to this vault only.
resource "azurerm_role_assignment" "kv_secrets_officer" {
  count = var.enable_key_vault ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = module.apps_identity.principal_id
}

# Private DNS + endpoint (production only): the vault's public hostname resolves to the
# private endpoint inside the VNet, so MASTERLY_KEYVAULT_URL is unchanged. Skipped when a
# central zone is injected (key_vault_private_dns_zone_id).
resource "azurerm_private_dns_zone" "key_vault" {
  count = local.create_key_vault_dns ? 1 : 0

  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  count = local.create_key_vault_dns ? 1 : 0

  name                  = "pdzl-${var.name_prefix}-kv"
  resource_group_name   = azurerm_resource_group.aca.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault[0].name
  virtual_network_id    = local.virtual_network_id
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count = local.key_vault_private_endpoint ? 1 : 0

  name                = "pe-${var.name_prefix}-kv"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-kv"
    private_connection_resource_id = azurerm_key_vault.this[0].id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault"
    private_dns_zone_ids = [local.key_vault_dns_zone_id]
  }

  tags = local.tags
}

locals {
  # Merged into the api's env in main.tf. AZURE_CLIENT_ID resolves the user-assigned
  # identity for DefaultAzureCredential (same key/value the servicebus binding sets —
  # merge-safe).
  keyvault_env = var.enable_key_vault ? {
    MASTERLY_SECRET_STORE = "keyvault"
    MASTERLY_KEYVAULT_URL = azurerm_key_vault.this[0].vault_uri
    AZURE_CLIENT_ID       = module.apps_identity.client_id
  } : {}
}

output "key_vault_uri" {
  value       = var.enable_key_vault ? azurerm_key_vault.this[0].vault_uri : null
  description = "URI of the install's Key Vault (null when the in-process secret store is used)."
}
