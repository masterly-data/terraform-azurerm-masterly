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

# --- Who may write the install's secrets, and from where ----------------------------
#
# Terraform writes the platform secrets into the vault (below), which is a DATA-plane
# operation: it needs a Key Vault RBAC grant, and it needs a network path. Neither comes
# free from Contributor/Owner, and in production the vault has no public presence, so both
# have to be stated. These three inputs are that statement.

variable "key_vault_secret_operator_object_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Entra object IDs granted Key Vault Secrets Officer on the install vault — the data-plane
    write Terraform needs to seed the app secrets. Empty (default) grants the identity running
    the apply (data.azurerm_client_config.current.object_id), which is right when one principal
    both plans and applies.

    SET IT EXPLICITLY IF PLAN AND APPLY RUN AS DIFFERENT SERVICE PRINCIPALS. With the default,
    state holds the apply identity's grant and every plan then proposes destroying it and
    creating the planning identity's — a phantom destroy a reviewer has to know to discount,
    and a grant that silently retargets to whoever last applied. Masterly's own Layer 1 hit
    exactly this and pins the equivalent grant for the same reason.
  EOT

  validation {
    condition     = alltrue([for id in var.key_vault_secret_operator_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "key_vault_secret_operator_object_ids must be Entra object IDs (UUIDs) — the object ID of the service principal, not its application (client) ID."
  }
}

variable "key_vault_secret_reader_object_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Entra object IDs granted Key Vault Secrets User (read-only) on the install vault. The
    companion to the input above for two-identity CI: `terraform plan` REFRESHES the seeded
    secrets, so a read-only planning identity with no data-plane grant does not merely see a
    cosmetic diff — its plan fails. Grant it here rather than widening it to Secrets Officer.
  EOT

  validation {
    condition     = alltrue([for id in var.key_vault_secret_reader_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "key_vault_secret_reader_object_ids must be Entra object IDs (UUIDs)."
  }
}

variable "key_vault_deployer_ip_rules" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Public IPv4 addresses/CIDRs allowed through the vault firewall, for the machine or runner
    that applies this module. Only consulted in production, where the vault is otherwise
    private-endpoint-only: the apps reach it over the private endpoint, but the deploying
    principal does not sit in the VNet, and a vault with public access disabled refuses its
    secret writes outright (bypass = AzureServices does NOT cover a CI runner — the trusted-
    services list is Azure services, not whoever is holding the token).

    Set this to the egress address of your apply runner, or leave it empty, run the apply from
    inside the VNet (self-hosted runner, jumpbox, VPN/ExpressRoute) and say so with
    key_vault_deployer_in_vnet. Nothing else works, and production refuses to plan with
    neither stated.

    default_action stays Deny either way — this is a firewalled public endpoint, not an open
    one. Key Vault rejects /31 and /32 prefixes: give a single address as a bare IP.
  EOT

  validation {
    condition = alltrue([
      for rule in var.key_vault_deployer_ip_rules :
      can(regex("^(([0-9]{1,3}\\.){3}[0-9]{1,3})(/([0-9]|[12][0-9]|30))?$", rule))
    ])
    error_message = "key_vault_deployer_ip_rules entries must be IPv4 addresses or CIDR ranges with a prefix of /30 or shorter — Key Vault rejects /31 and /32, so write a single address as a bare IP (203.0.113.7, not 203.0.113.7/32)."
  }

  # Make the choice explicit rather than discovering it as a 403 partway through a ten-minute
  # apply, with the install half-built. Exactly one of the two paths has to be stated; the
  # module cannot tell which by looking, because "no firewall rule" is indistinguishable from
  # "I apply from inside the VNet", and one of those is correct.
  validation {
    condition = (
      var.mode != "production" ||
      !var.enable_key_vault ||
      length(var.key_vault_deployer_ip_rules) > 0 ||
      var.key_vault_deployer_in_vnet
    )
    error_message = "mode=production runs the Key Vault private-endpoint-only, and Terraform must still write the install's secrets into it: set key_vault_deployer_ip_rules to the egress address of the machine or runner that applies this module, or set key_vault_deployer_in_vnet = true if that apply already runs inside the install's VNet."
  }
}

variable "key_vault_deployer_in_vnet" {
  type        = bool
  default     = false
  description = "Declare that `terraform apply` runs from inside the install's VNet (self-hosted runner, jumpbox, VPN/ExpressRoute), so the vault needs no public firewall exception in production. Purely an assertion by the operator — Terraform cannot verify it — and it changes no resource: it satisfies the guard on key_vault_deployer_ip_rules and nothing else. It is a claim about EVERY run, not just the first: plan, apply and destroy all refresh the vault secrets, and from outside the VNet a closed vault answers 403 ForbiddenByConnection to all three (verified on Azure — a destroy failed on the refresh alone)."
}

data "azurerm_client_config" "current" {}

locals {
  # Public network access is disabled in production (private-endpoint-only, mirroring the
  # data plane); demo/dev keep it public for ease of evaluation.
  key_vault_public           = var.mode != "production"
  key_vault_private_endpoint = var.enable_key_vault && !local.key_vault_public

  # In production the endpoint is opened only to run the vault firewall: default_action stays
  # Deny and nothing but the listed deployer addresses (and the private endpoint) gets in.
  key_vault_deployer_firewall = !local.key_vault_public && length(var.key_vault_deployer_ip_rules) > 0

  # Secrets Officer for the writer, Secrets User for a read-only planner. Falling back to the
  # running identity keeps the single-principal case zero-config; see the variable for why the
  # two-identity case must not.
  key_vault_secret_operators = length(var.key_vault_secret_operator_object_ids) > 0 ? var.key_vault_secret_operator_object_ids : [data.azurerm_client_config.current.object_id]
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

  # In production the apps reach the vault over the private endpoint below, behind default-deny
  # network ACLs (Azure services + the private endpoint still resolve). The public endpoint is
  # off entirely unless key_vault_deployer_ip_rules names an address — Terraform's own secret
  # writes are data-plane calls from outside the VNet, and they need a way in. Even then it is
  # a FIREWALLED public endpoint: default_action stays Deny and only those addresses pass.
  # demo/dev keeps public access for evaluation.
  public_network_access_enabled = local.key_vault_public || local.key_vault_deployer_firewall

  network_acls {
    bypass         = "AzureServices"
    default_action = local.key_vault_public ? "Allow" : "Deny"
    ip_rules       = local.key_vault_public ? [] : var.key_vault_deployer_ip_rules
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

# --- The platform secrets, in the vault ---------------------------------------------
#
# With the vault on, the install's own secrets live IN it and the Container Apps hold
# references. The finding this closes: a value-based Container App secret is readable in
# clear through containerApps/listSecrets, which plain Contributor on the resource group
# carries — so the DSN, the session secret, the licence JWT, the OIDC client secret, the
# Redis URL (access key and all), the registry password and the telemetry secret were
# readable by anyone who could merely deploy to the install. Key Vault data-plane read is a
# separate RBAC grant that Contributor does NOT include, so moving them narrows the set of
# principals that can read them to the ones actually granted, and leaves an audit trail of
# every read.
#
# It also collapses the rotation surface: the vault becomes the one place the value lives.
# The references are VERSIONLESS on purpose — ACA re-reads a versionless reference within
# 30 minutes and restarts the active revisions, so rotating in the vault reaches the running
# apps without an apply. Pinning the version would have put the copy back, one indirection
# further away.
#
# The apps identity already holds Secrets Officer on this vault (above) for its own sealed
# material, so it can read these too. That is the same trust boundary, not a widening: the
# values are handed to those apps as environment either way.

resource "azurerm_key_vault_secret" "install" {
  for_each = var.enable_key_vault ? toset(local.install_secret_names) : toset([])

  # Prefixed: the application seals its own secrets into this vault at runtime
  # (KeyVaultSecretStore, ADR 0066) under <slug>-<ulid>. The prefix keeps the module's
  # secrets legible next to those and makes a collision impossible by construction.
  name         = "install-${each.key}"
  value        = local.secret_values[each.key]
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "text/plain"

  tags = local.tags

  # The data-plane grant must exist before the write. Entra RBAC is eventually consistent,
  # so a FIRST apply can still land inside the propagation window and fail with 403 on the
  # first secret; re-running the apply is the remedy (see README, "Key Vault-backed app
  # secrets"). Deliberately not papered over with a fixed sleep: that would tax every apply
  # for a race that only the first one can lose.
  depends_on = [azurerm_role_assignment.kv_secrets_officer_deployer]
}

# The deploying principal's data-plane write. Contributor and Owner do NOT carry Key Vault
# data actions, so without this the secret writes above fail on an RBAC-mode vault no matter
# how privileged the principal is at the control plane.
resource "azurerm_role_assignment" "kv_secrets_officer_deployer" {
  for_each = var.enable_key_vault ? toset(local.key_vault_secret_operators) : toset([])

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.key
}

# The frontend resolves its own secrets (the OIDC client secret, the registry password), so its
# identity needs data-plane READ on the vault — and only that. Deliberately Secrets User, not
# the Officer grant the backend apps hold: the frontend never writes sealed material, and it is
# the app an attacker reaches first. Only created when the frontend actually has a secret to
# resolve, so an install with neither oidc nor a registry credential grants nothing.
resource "azurerm_role_assignment" "kv_secrets_user_frontend" {
  count = var.enable_key_vault && length(local.frontend_secret_names) > 0 ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.frontend_identity.principal_id
}

# Read-only data-plane for a separate planning identity: `plan` refreshes the secrets above.
resource "azurerm_role_assignment" "kv_secrets_reader" {
  for_each = var.enable_key_vault ? toset(var.key_vault_secret_reader_object_ids) : toset([])

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.key
}

locals {
  # Every secret the module hands to any app — the set written to the vault.
  install_secret_names = distinct(concat(local.api_secret_names, local.frontend_secret_names))

  # The split the apps actually consume. With the vault on, no app carries a value; with it
  # off (dev/demo, no vault to put them in) they carry values exactly as before.
  api_value_secrets      = var.enable_key_vault ? {} : local.api_secrets
  frontend_value_secrets = var.enable_key_vault ? {} : local.frontend_secrets

  api_vault_secret_refs = var.enable_key_vault ? {
    for name in local.api_secret_names : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = module.apps_identity.id
    }
  } : {}

  # The FRONTEND's own identity, not the backend's. It carries AcrPull and nothing else by
  # design — it is the one internet-facing app — so it gets the narrowest thing that lets it
  # resolve its two secrets: Key Vault Secrets User (read), never Officer.
  frontend_vault_secret_refs = var.enable_key_vault ? {
    for name in local.frontend_secret_names : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = module.frontend_identity.id
    }
  } : {}
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

# The posture, assertable. Never the material: these are names and a count.
output "vault_backed_secret_names" {
  value       = var.enable_key_vault ? sort(local.install_secret_names) : []
  description = "Names of the install secrets held in the Key Vault (empty when the vault is off and the apps carry values instead)."
}
