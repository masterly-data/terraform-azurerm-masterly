# The install's Key Vault (ADR 0066 increment 2) — the durable secret-store binding.
# Opt-in (default off; dev/demo run the in-process store): when enabled, this provisions a
# per-install vault (RBAC mode, no access policies) and grants the apps identity a custom
# data-plane role that reads, writes and deletes secrets and nothing more (app_secrets, below),
# plus key read for the erasure keys of ADR 0081 (the grants below say why those are vault-scoped),
# and a second, audit vault for the audit checkpoint key and head. The api is flipped to
# MASTERLY_SECRET_STORE=keyvault and handed the vault URI; auth is the managed identity via
# AZURE_CLIENT_ID — no secret.
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

# The apps identity reads, writes and deletes secrets: it resolves the install-* references
# below and seals its own material at runtime (KeyVaultSecretStore, ADR 0066) under
# <slug>-<ulid>. That is four data actions, so the module defines a role holding exactly those
# rather than granting the built-in Key Vault Secrets Officer, whose secrets/* also carries
# purge, backup, restore and recover on every secret in the vault, the BYO-DB connection
# strings included. With this role a compromised app can still read and overwrite secrets, as
# it must to work, but it cannot copy them out as backups, restore old ones, or recover and
# purge what was deleted.
#
# Role definition names are unique across an Entra tenant, so the name carries the install
# suffix: two installs in one tenant never collide. The role is defined on, and assignable
# only within, the install's data resource group, where the vault lives. Creating it needs
# Microsoft.Authorization/roleDefinitions/write, which Owner and User Access Administrator
# carry and Role Based Access Control Administrator does not. Before upgrading, run
# scripts/preflight.sh --principal <deployer object id> and grant roleDefinitions/write if it
# reports it missing: nothing orders the removal of the old Secrets Officer grants after this
# create, so a deployer without it may lose those grants before this create fails, leaving the
# apps with no secrets grant on the vault.
resource "azurerm_role_definition" "app_secrets" {
  count = var.enable_key_vault ? 1 : 0

  name        = "Masterly app secrets (${var.name_prefix}-${random_string.install.result})"
  scope       = azurerm_resource_group.data.id
  description = "Read, write and delete secrets in the Masterly install's Key Vault. No purge, backup, restore or recover."

  permissions {
    actions = []
    data_actions = [
      "Microsoft.KeyVault/vaults/secrets/getSecret/action",
      "Microsoft.KeyVault/vaults/secrets/setSecret/action",
      "Microsoft.KeyVault/vaults/secrets/delete",
      "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
    ]
  }

  assignable_scopes = [azurerm_resource_group.data.id]
}

# The grant, scoped to this vault only. It was Key Vault Secrets Officer under the name
# kv_secrets_officer; the moved block keeps the address, so an upgrade replaces this one grant
# (a role change forces a new assignment) rather than adding a grant beside an orphaned one that
# nothing orders. The replacement is destroy-then-create: Terraform removes the Secrets Officer
# grant first and creates this one after it (create_before_destroy here would put the app modules
# in a dependency cycle). ca-api and ca-workers depend on this address, so neither app is updated
# (and restarted) before the new grant exists. A running app that reaches the vault in the seconds
# between the removal and the create, or before Azure has propagated the new grant, can be
# refused; the CHANGELOG's upgrade note says so.
resource "azurerm_role_assignment" "kv_app_secrets" {
  count = var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.this[0].id
  role_definition_id = azurerm_role_definition.app_secrets[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

moved {
  from = azurerm_role_assignment.kv_secrets_officer
  to   = azurerm_role_assignment.kv_app_secrets
}

# --- The signing keys: no Crypto Officer on any app (ADR 0120 §6, amended 2026-10-25) --------
#
# The vault holds the install's signing keys as vault keys: each Environment's erasure signing key
# (ADR 0081) and its audit checkpoint key (ADR 0033). The application creates each one on first use,
# at a fixed name derived from the Environment's id, only if it is absent, and asks the vault to sign
# with it, so the private half never leaves the vault. Since api images v0.138.0 only the workers
# process does this (the erasure job and the checkpoint signer run in the core worker pool); ca-api
# reads a key's public half, for GET /v1/audit/signing-key, the audit export and online verify, and
# nothing more.
#
# So each role gets a role the module defines, holding only what it does, in place of the built-in
# Key Vault Crypto Officer, whose keys/* also carries delete, purge, update, import, backup,
# restore, rotate, recover and release on every key in the vault:
#
#   signing_key_reader  keys/read: a key's properties and public half. Never its private half,
#                       never a signature. ca-api's identity.
#   signing_keys        the five data actions the amendment lists, and no others: keys/create,
#                       keys/read and keys/sign, and getSecret and setSecret for the suppression key
#                       and the high-water mark (which the app secrets role carries as well).
#                       ca-workers' identity, wherever ca-workers runs.
#
# Scope: a vault. An Azure role assignment cannot be scoped to a key that does not exist yet, and
# Key Vault's attribute-based conditions (preview) cover secret data actions only, not keys, so the
# narrower scope the amendment asks for needs a vault holding only the names it covers. The audit
# names (the key audit-checkpoint-signing-<env> and the secret audit-checkpoint-head-<env>) have one:
# the audit vault below (ADR 0033 §10, ADR 0120 §6), where these two roles are granted again, with
# a getSecret-only head reader role for ca-api, and nothing else is. The erasure names still sit in
# this vault, so here the roles reach every key in it, which holds no keys besides its
# Environments' signing keys, and the role carries no delete or purge. In mode = "production" purge protection is armed on the vault above as well. Losing a
# signing key is consequential all the same: see "Erasure keys belong in your secret backup" in the
# README.
#
# Creating either needs Microsoft.Authorization/roleDefinitions/write, as app_secrets does.
resource "azurerm_role_definition" "signing_key_reader" {
  count = var.enable_key_vault ? 1 : 0

  name        = "Masterly signing key reader (${var.name_prefix}-${random_string.install.result})"
  scope       = azurerm_resource_group.data.id
  description = "Read the properties and public half of the keys in the Masterly install's Key Vault. No signing, no private key material, no create, update or delete."

  permissions {
    actions = []
    data_actions = [
      "Microsoft.KeyVault/vaults/keys/read",
    ]
  }

  assignable_scopes = [azurerm_resource_group.data.id]
}

resource "azurerm_role_definition" "signing_keys" {
  count = var.enable_key_vault ? 1 : 0

  name        = "Masterly signing keys (${var.name_prefix}-${random_string.install.result})"
  scope       = azurerm_resource_group.data.id
  description = "Create a key that is absent, read keys and sign with them, and read and set secrets, in the Masterly install's Key Vault. No delete, purge, update, import, backup, restore, rotate, recover or release."

  permissions {
    actions = []
    data_actions = [
      "Microsoft.KeyVault/vaults/keys/create/action",
      "Microsoft.KeyVault/vaults/keys/read",
      "Microsoft.KeyVault/vaults/keys/sign/action",
      "Microsoft.KeyVault/vaults/secrets/getSecret/action",
      "Microsoft.KeyVault/vaults/secrets/setSecret/action",
    ]
  }

  assignable_scopes = [azurerm_resource_group.data.id]
}

# ca-api's grant. It was Key Vault Crypto Officer under the name kv_crypto_officer; the moved block
# keeps the address, so an upgrade replaces this one grant (a role change forces a new assignment)
# rather than leaving the Crypto Officer grant as an orphan whose removal nothing orders: no resource
# recorded a dependency on it. The replacement is destroy-then-create, as for kv_app_secrets:
# create_before_destroy here puts module.api in a dependency cycle on any apply that also destroys a
# resource depending on ca-api (an alert, a diagnostic setting). A new address with no moved block
# would not help: nothing in an existing install's state depends on the Crypto Officer grant, so
# its removal would be unordered too. So from the removal until Azure propagates the new grant,
# which can take minutes, ca-api cannot read a signing key's public half: GET
# /v1/audit/signing-key, the audit export and online verify can fail and succeed when retried.
# ca-api depends on this address, so its update comes after the create.
resource "azurerm_role_assignment" "kv_signing_key_reader" {
  count = var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.this[0].id
  role_definition_id = azurerm_role_definition.signing_key_reader[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

moved {
  from = azurerm_role_assignment.kv_crypto_officer
  to   = azurerm_role_assignment.kv_signing_key_reader
}

# Where ca-workers runs as the apps identity (migrations = "start" with database_auth = "entra" on
# the starter server, workers.tf), that identity also needs the signing keys role, because the
# workers process creates and signs. ca-workers depends on it, so it exists before ca-workers'
# update.
resource "azurerm_role_assignment" "kv_signing_keys" {
  count = var.enable_key_vault && var.enable_workers && !local.workers_own_identity ? 1 : 0

  scope              = azurerm_key_vault.this[0].id
  role_definition_id = azurerm_role_definition.signing_keys[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

# The app secrets role for ca-workers' own identity, when it runs as it (identity.tf,
# workers_identity): ca-workers seals material as the api does. Renamed and replaced as
# kv_app_secrets is, for the same reason.
resource "azurerm_role_assignment" "kv_app_secrets_workers" {
  count = local.workers_own_identity && var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.this[0].id
  role_definition_id = azurerm_role_definition.app_secrets[0].role_definition_resource_id
  principal_id       = module.workers_identity[0].principal_id
}

moved {
  from = azurerm_role_assignment.kv_secrets_officer_workers
  to   = azurerm_role_assignment.kv_app_secrets_workers
}

# ca-workers' own identity's signing keys grant. It replaces the Key Vault Crypto Officer grant
# that was at azurerm_role_assignment.kv_crypto_officer_workers, at a new address and with no moved
# block: ca-workers depends on both addresses (workers.tf through 0.26.0, and now this one), so the
# new grant is created before ca-workers' update, and Terraform, which records that dependency in
# state, removes the Crypto Officer grant only after the update.
resource "azurerm_role_assignment" "kv_signing_keys_workers" {
  count = local.workers_own_identity && var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.this[0].id
  role_definition_id = azurerm_role_definition.signing_keys[0].role_definition_resource_id
  principal_id       = module.workers_identity[0].principal_id
}

# --- The audit vault: the audit checkpoint key and head alone (ADR 0033 §10, ADR 0120 §6) -------
#
# A second vault for the audit names: the key audit-checkpoint-signing-<env> and the secret
# audit-checkpoint-head-<env>. Holding nothing else, it lets a grant on the vault reach those names
# and no app secret, BYO-DB connection string or erasure key. Two principals hold a role on it, and
# no other: the core worker pool's identity, the signing keys role (it creates the key, signs
# checkpoints and writes the head), and ca-api's identity, keys/read and getSecret (it reads the
# public half and the head, and can neither sign nor overwrite them). No built-in role is granted,
# so no principal gets delete, purge, backup or restore on it.
#
# Terraform writes no data-plane object here, so the deployer and the planner get no grant on it
# either, and the destroy ordering the install secrets need (below) does not apply. The application
# reads its URL from MASTERLY_AUDIT_KEYVAULT_URL, on ca-api and ca-workers alone.
#
# Its network posture is the main vault's: RBAC, the same soft-delete retention, purge protection
# and a private endpoint in production, public with an outbound allowlist entry in demo.
resource "azurerm_key_vault" "audit" {
  count = var.enable_key_vault ? 1 : 0

  # 4 + 13 + 1 + 6 = 24, the most a vault name can be, and never the main vault's name. A cut that
  # ends in a hyphen loses it: Azure refuses two hyphens in a row in a vault name.
  name                = "kva-${replace(substr(var.name_prefix, 0, 13), "/-+$/", "")}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true

  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  purge_protection_enabled   = var.mode == "production"

  public_network_access_enabled = local.key_vault_public || local.key_vault_deployer_firewall

  network_acls {
    bypass         = "AzureServices"
    default_action = local.key_vault_public ? "Allow" : "Deny"
    ip_rules       = local.key_vault_public ? [] : var.key_vault_deployer_ip_rules
  }

  tags = local.tags
}

# ca-api reads the audit head and never writes it: getSecret alone, defined like
# signing_key_reader (its keys/read is granted on this vault too).
resource "azurerm_role_definition" "audit_head_reader" {
  count = var.enable_key_vault ? 1 : 0

  name        = "Masterly audit head reader (${var.name_prefix}-${random_string.install.result})"
  scope       = azurerm_resource_group.data.id
  description = "Read the secrets in the Masterly install's audit Key Vault: the signed audit checkpoint head. No write, delete, purge, backup, restore or recover."

  permissions {
    actions = []
    data_actions = [
      "Microsoft.KeyVault/vaults/secrets/getSecret/action",
    ]
  }

  assignable_scopes = [azurerm_resource_group.data.id]
}

# ca-api: keys/read and getSecret on the audit vault, and nothing more.
resource "azurerm_role_assignment" "audit_kv_signing_key_reader" {
  count = var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.audit[0].id
  role_definition_id = azurerm_role_definition.signing_key_reader[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "audit_kv_head_reader" {
  count = var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.audit[0].id
  role_definition_id = azurerm_role_definition.audit_head_reader[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

# The core pool's signing keys grant, as on the main vault: the apps identity where ca-workers runs
# as it, which gives ca-api the five actions on this vault too (the README names that shape), and
# ca-workers' own identity where it has one. With enable_workers off the checkpoint signer runs in
# ca-api, which gets no signing grant here, as on the main vault.
resource "azurerm_role_assignment" "audit_kv_signing_keys" {
  count = var.enable_key_vault && var.enable_workers && !local.workers_own_identity ? 1 : 0

  scope              = azurerm_key_vault.audit[0].id
  role_definition_id = azurerm_role_definition.signing_keys[0].role_definition_resource_id
  principal_id       = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "audit_kv_signing_keys_workers" {
  count = local.workers_own_identity && var.enable_key_vault ? 1 : 0

  scope              = azurerm_key_vault.audit[0].id
  role_definition_id = azurerm_role_definition.signing_keys[0].role_definition_resource_id
  principal_id       = module.workers_identity[0].principal_id
}

# Its private endpoint, beside the main vault's on the private endpoints subnet, in the same
# privatelink zone (the module's or the injected one). The front subnet's NSG exception names the
# main vault's endpoint alone, so ca-frontend has no route to this one.
resource "azurerm_private_endpoint" "key_vault_audit" {
  count = local.key_vault_private_endpoint ? 1 : 0

  name                = "pe-${var.name_prefix}-kv-audit"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-kv-audit"
    private_connection_resource_id = azurerm_key_vault.audit[0].id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault-audit"
    private_dns_zone_ids = [local.key_vault_dns_zone_id]
  }

  tags = local.tags
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

  name                = "pdzl-${var.name_prefix}-kv"
  private_dns_zone_id = azurerm_private_dns_zone.key_vault[0].id
  virtual_network_id  = local.virtual_network_id
  tags                = local.tags
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
# The apps identity (and ca-workers' own, when it has one) already holds the app secrets role on
# this vault (above) for its own sealed material, so it can read these too. That is the same trust
# boundary, not a widening: the values are handed to those apps as environment either way.

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
  #
  # The private endpoint and its DNS link are ordering edges too. On create the secrets are
  # written only once the private path exists, so an in-VNet deployer can reach the vault. On
  # destroy Terraform removes a dependent before its dependency, so the secrets go first, while
  # the vault is still reachable: with the endpoint gone first, every delete failed with 403
  # ForbiddenByConnection, because the vault has no public path. Both are counted, and a
  # dependency on a count-0 resource is valid, so demo and an injected central zone still plan.
  # Every azurerm_key_vault_secret carries the same three edges; tests/keyvault.tftest.hcl
  # reads this file and fails on one that does not.
  depends_on = [
    azurerm_role_assignment.kv_secrets_officer_deployer,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
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

# The frontend resolves its own secrets (the BFF shared secret, and the OIDC client secret, the
# registry password and the two DPoP key slots when those are set), so its identity needs
# data-plane READ on exactly those — one Secrets User grant PER SECRET, scoped to that secret,
# never to the vault. The
# frontend is the app an attacker reaches first, and the vault also holds the backend's secrets
# (the admin DSN, the session secret, the licence, the Redis URL, the telemetry secret, the
# break-glass hash) and everything the api seals at runtime (KeyVaultSecretStore, ADR 0066):
# a vault-scope read would hand all of it to whoever runs code in that container. Deliberately
# Secrets User, not the Officer grant the backend apps hold: the frontend never writes sealed
# material. The keys are known at plan — they follow the resolved registry_credential_mode (the
# registry password rides only in the token mode), identity_binding, builtin_auth and
# enable_bff_dpop_key (both DPoP slots, whatever the clock says), none of them sensitive.
#
# The scope is the secret's ARM id (resource_versionless_id), not versionless_id, which is the
# data-plane URL the app's reference uses.
resource "azurerm_role_assignment" "kv_secrets_user_frontend" {
  for_each = var.enable_key_vault ? toset(local.frontend_secret_names) : toset([])

  scope                = azurerm_key_vault_secret.install[each.key].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.frontend_identity.principal_id
}

# The job reads its vault-backed secrets individually, never as Officer or at vault scope.
# external_database_admin_url stays in the ACA job secret and gets no Key Vault grant.
resource "azurerm_role_assignment" "kv_secrets_user_migrate" {
  for_each = var.enable_key_vault ? toset(local.migrate_vault_secret_names) : toset([])

  scope                = azurerm_key_vault_secret.install[each.key].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.migrate_identity[0].principal_id
}

# The app roles' passwords (migrate.tf), for the job alone. Their own resources, never in
# install_secret_names or migrate_secret_names: those become Key Vault references or values on a
# Container App or the job, and these reach the job only as a secret name in its env, which it
# reads from the vault with its own identity.
resource "azurerm_key_vault_secret" "migrate_api_role_password" {
  count = local.migrate_app_passwords ? 1 : 0

  name         = local.migrate_api_role_password_secret_name
  value        = random_password.migrate_api_role[0].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "text/plain"

  tags = local.tags

  # Same ordering as azurerm_key_vault_secret.install: after the grant, the endpoint and the link.
  depends_on = [
    azurerm_role_assignment.kv_secrets_officer_deployer,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
}

resource "azurerm_key_vault_secret" "migrate_workers_role_password" {
  count = local.migrate_app_passwords ? 1 : 0

  name         = local.migrate_workers_role_password_secret_name
  value        = random_password.migrate_workers_role[0].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "text/plain"

  tags = local.tags

  # Same ordering as azurerm_key_vault_secret.install: after the grant, the endpoint and the link.
  depends_on = [
    azurerm_role_assignment.kv_secrets_officer_deployer,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
}

# Read on each of those two secrets alone, as kv_secrets_user_migrate: never at vault scope.
resource "azurerm_role_assignment" "kv_secrets_user_migrate_api_role_password" {
  count = local.migrate_app_passwords ? 1 : 0

  scope                = azurerm_key_vault_secret.migrate_api_role_password[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.migrate_identity[0].principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user_migrate_workers_role_password" {
  count = local.migrate_app_passwords ? 1 : 0

  scope                = azurerm_key_vault_secret.migrate_workers_role_password[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.migrate_identity[0].principal_id
}

# Runtime connection secrets are created by the API, not Terraform. The operator names only
# BYO-DB DSNs here; construct their secret ARM scopes without reading their values into state.
resource "azurerm_role_assignment" "kv_byo_database_reader_migrate" {
  for_each = local.migrate_job && var.enable_key_vault ? var.migrate_byo_database_secret_names : toset([])

  scope                = "${azurerm_key_vault.this[0].id}/secrets/${each.key}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.migrate_identity[0].principal_id
}

# Read-only data-plane for a separate planning identity: `plan` refreshes the secrets above.
resource "azurerm_role_assignment" "kv_secrets_reader" {
  for_each = var.enable_key_vault ? toset(var.key_vault_secret_reader_object_ids) : toset([])

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.key
}

locals {
  # The apps can read this vault. Keep the privileged BYO DSN only in the ACA job secret.
  # Declassify its presence, never its value, so these names can drive resource for_each.
  migrate_vault_secret_names = [for name in local.migrate_secret_names : name
    if !(nonsensitive(var.external_database_admin_url != null) && contains(["migrate-database-url", "migrate-database-direct-url"], name))
  ]
  # With the app roles each backend app reads its own DSN secrets, and no app's env names the
  # shared ones, which stay here so that an upgrade does not delete what running revisions reference.
  # Without ca-workers nothing reads its list, so its DSN secrets are not created.
  install_secret_names = distinct(concat(
    local.api_secret_names,
    var.enable_workers ? local.backend_secret_names : [],
    local.frontend_secret_names,
    local.migrate_vault_secret_names,
    local.migrate_app_roles ? local.shared_database_secret_names : [],
  ))

  # The split the apps actually consume. With the vault on, no app carries a value; with it
  # off (dev/demo, no vault to put them in) they carry values exactly as before. `backend_*`
  # is what ca-workers carries: the api's set without the BFF shared secret, and with its own
  # DSNs instead of the api's when the app roles exist.
  backend_value_secrets  = var.enable_key_vault ? {} : local.backend_secrets
  api_value_secrets      = var.enable_key_vault ? {} : local.api_secrets
  frontend_value_secrets = var.enable_key_vault ? {} : local.frontend_secrets
  migrate_value_secrets  = { for name, value in local.migrate_secrets : name => value if !var.enable_key_vault || !contains(local.migrate_vault_secret_names, name) }

  # ca-workers resolves its references as the identity it runs as (workers.tf).
  backend_vault_secret_refs = var.enable_key_vault ? {
    for name in local.backend_secret_names : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = local.workers_identity_id
    }
  } : {}

  # With the app roles ca-api also keeps the shared DSN secrets (api_retained_secret_names), as
  # it carried them before the upgrade: same name, vault secret and identity, so they plan no
  # change. ACA secrets belong to the app, not to a revision, and the revision running before
  # the upgrade keeps serving, and may restart or scale, until the new one is ready, which waits
  # on the migrate job. No env of the new revision names them. Removing them is MAS-3961's.
  api_vault_secret_refs = var.enable_key_vault ? {
    for name in concat(local.api_secret_names, local.api_retained_secret_names) : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = module.apps_identity.id
    }
  } : {}

  # The FRONTEND's own identity, not the backend's. It carries AcrPull and nothing else by
  # design — it is the one internet-facing app — so it gets the narrowest thing that lets it
  # resolve its own secrets: Key Vault Secrets User (read) on each of these secrets alone
  # (kv_secrets_user_frontend), never on the vault and never Officer.
  frontend_vault_secret_refs = var.enable_key_vault ? {
    for name in local.frontend_secret_names : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = module.frontend_identity.id
    }
  } : {}

  # The migrate job's own identity, read on each of these alone (kv_secrets_user_migrate).
  migrate_vault_secret_refs = var.enable_key_vault ? {
    for name in local.migrate_vault_secret_names : name => {
      kv_secret_id = azurerm_key_vault_secret.install[name].versionless_id
      identity_id  = module.migrate_identity[0].id
    }
  } : {}
}

locals {
  # Merged into the api's env in main.tf. AZURE_CLIENT_ID resolves the user-assigned
  # identity for DefaultAzureCredential (same key/value the servicebus binding sets —
  # merge-safe). ca-workers' env is the api's, so both get the audit vault's URL; ca-frontend's
  # env and caj-migrate's (migrate.tf) never merge this map.
  keyvault_env = var.enable_key_vault ? {
    MASTERLY_SECRET_STORE       = "keyvault"
    MASTERLY_KEYVAULT_URL       = azurerm_key_vault.this[0].vault_uri
    MASTERLY_AUDIT_KEYVAULT_URL = azurerm_key_vault.audit[0].vault_uri
    AZURE_CLIENT_ID             = module.apps_identity.client_id
  } : {}
}

output "key_vault_uri" {
  value       = var.enable_key_vault ? azurerm_key_vault.this[0].vault_uri : null
  description = "URI of the install's Key Vault (null when the in-process secret store is used)."
}

output "audit_key_vault_uri" {
  value       = var.enable_key_vault ? azurerm_key_vault.audit[0].vault_uri : null
  description = "URI of the install's audit Key Vault, which holds the audit checkpoint signing key and head alone (ADR 0033 §10), and is set on ca-api and ca-workers as MASTERLY_AUDIT_KEYVAULT_URL. Null when enable_key_vault is off."
}

# The posture, assertable. Never the material: these are names and a count.
output "vault_backed_secret_names" {
  value       = var.enable_key_vault ? sort(local.install_secret_names) : []
  description = "Names of the install secrets held in the Key Vault (empty when the vault is off and the apps carry values instead)."
}
