# The apps' managed identities, the registry and image defaults, and the AcrPull grants.

# --- App identities --------------------------------------------------------------
# One identity per app is the platform's rule, and the reason is the frontend: it is the
# only internet-facing app in the install, and it needs nothing but image pull. Sharing
# `apps_identity` with it handed the public front door write access to the install's Key Vault
# secrets (Key Vault Secrets Officer then, the narrower app secrets role now), Service Bus send
# + receive and ACS Email Owner — permissions it never uses, on the one app an
# attacker reaches first. So the backend apps (api, workers) keep `apps_identity` and the
# data-plane grants that go with it; the frontend gets its own, holding AcrPull alone.

module "apps_identity" {
  source = "./modules/user-assigned-identity"

  name                = "id-${var.name_prefix}-apps"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# The frontend's own identity. Image pull, plus read on each of its own vault secrets
# (kv_secrets_user_frontend) — not the vault, no Service Bus, no ACS. Nothing here grows
# without a reason to give the public app that reach.
module "frontend_identity" {
  source = "./modules/user-assigned-identity"

  name                = "id-${var.name_prefix}-frontend"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# The migrate job's own identity (migrate.tf). On database_auth = "entra" it is the starter
# server's Microsoft Entra administrator, the install's most privileged database
# principal, so it gets image pull and read on its own vault secrets and explicitly named
# per-Environment BYO-DB DSNs, and never: a Container App, a vault-scope role, a Key Vault crypto
# or Officer role, Service Bus, Redis or ACS. Only with migrations = "job".
module "migrate_identity" {
  source = "./modules/user-assigned-identity"
  count  = local.migrate_job ? 1 : 0

  name                = "id-${var.name_prefix}-migrate"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# ca-workers' own identity, and with migrations = "job" on the starter server the principal of its
# database role, masterly_workers, which the migrate job creates on database_auth = "entra" from
# this identity's object id (migrate.tf). ca-workers runs as it (workers.tf) and it holds the backend
# grants ca-workers needs (each `*_workers` grant), and is no Postgres administrator. Two of them
# the apps identity no longer holds once ca-workers runs as this one: Service Bus Data Receiver and
# the jobs queue's Data Owner.
# Wherever ca-workers exists and the install has a Key Vault, except migrations = "start" with
# database_auth = "entra" on the starter server (local.workers_own_identity, workers.tf); otherwise
# ca-workers runs as the apps identity. With the app roles but without ca-workers (enable_workers =
# false) the identity still exists for the migrate job's role, but holds no grant and no DSN secret.
module "workers_identity" {
  source = "./modules/user-assigned-identity"
  count  = local.migrate_app_roles || local.workers_own_identity ? 1 : 0

  name                = "id-${var.name_prefix}-workers"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# --- Registry and images -----------------------------------------------------------
# Where the apps pull from, how they authenticate, and which images they run when api_image and
# frontend_image are left null. The deprecated inputs (acr_login_server, registry_username,
# registry_password) map onto the new ones here, so every app below reads only these locals.
locals {
  release_manifest = jsondecode(file("${path.module}/MANIFEST.json"))

  # registry_location, else the deprecated acr_login_server (where "" renders no registry block).
  # With neither, Masterly's registry when something pulls from it (a credential mode, a pull
  # credential or an AcrPull grant through acr_id); otherwise "", no registry block and public
  # images, which is what acr_login_server = "" migrates to.
  registry_server = var.registry_location != null ? var.registry_location : (
    var.acr_login_server != null ? var.acr_login_server : (
      var.registry_credential_mode != null || local.registry_token_set || local.registry_username_set || var.acr_id != null ? "masterly.azurecr.io" : ""
    )
  )

  # Whether a credential was supplied is not the secret: the same narrow unmarking as the
  # licence's presence in backend_secret_names.
  registry_token_set = nonsensitive(var.registry_token != null)
  # The same for the deprecated registry_username, which a calling root may pass from a variable
  # it declares sensitive: unmarked, its presence would mark the derived mode, and with it the
  # registry-password key of every secret for_each (azurerm_key_vault_secret.install). Only the
  # null test is unmarked; the username itself keeps whatever mark the caller gave it.
  registry_username_set = nonsensitive(var.registry_username != null)

  registry_credential_mode = var.registry_credential_mode != null ? var.registry_credential_mode : (
    local.registry_token_set || local.registry_username_set ? "token" : (
      contains(["", "masterly.azurecr.io"], lower(local.registry_server)) ? "managed_identity" : "customer_registry"
    )
  )
  registry_token_mode = local.registry_credential_mode == "token"

  # The appId is not the secret either and is shown in the registry block; the password stays marked.
  registry_username = !local.registry_token_mode ? null : (
    local.registry_token_set ? nonsensitive(var.registry_token.username) : var.registry_username
  )
  registry_password = !local.registry_token_mode ? null : (
    local.registry_token_set ? var.registry_token.password : var.registry_password
  )
  registry_password_secret_name = local.registry_token_mode ? "registry-password" : null

  # The images the apps are created with, after the channel and the explicit inputs are resolved
  # (module.release_channel below). Every app reads these, as does the licence claims-floor check.
  release_channel_version = module.release_channel.version
  api_image               = module.release_channel.images.api
  frontend_image          = module.release_channel.images.frontend
}

# The release each channel resolves to in MANIFEST.json, and the default references it gives:
# always release/<role> on the selected registry (Masterly's when the apps have no registry
# block), pinned by the digest the release records or by its tag for a release that records none.
# Only that last part differs between channels. A channel that resolves to no release refuses
# the plan (the module's `images` output), unless both images are set explicitly. A submodule,
# so the resolution is proven against a synthetic manifest (tests/release_channel.tftest.hcl).
module "release_channel" {
  source = "./modules/release-channel"

  manifest       = local.release_manifest
  channel        = var.release_channel
  registry       = local.registry_server != "" ? local.registry_server : "masterly.azurecr.io"
  api_image      = var.api_image
  frontend_image = var.frontend_image
}

# Optional: grant pull on the registry (the deploying principal needs
# roleAssignments/write on the registry's scope — true for the demo install, where
# platform-iac's principal manages the shared registry; customers typically grant
# pull out of band and leave acr_id null). The token mode pulls with its credential, so
# it creates no grant.
#
# EVERY identity needs the grant when acr_id is null and you grant out of band — see the
# `apps_identity_principal_id` / `frontend_identity_principal_id` /
# `migrate_identity_principal_id` / `workers_identity_principal_id` outputs.
resource "azurerm_role_assignment" "acr_pull" {
  count = !local.registry_token_mode && var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "acr_pull_frontend" {
  count = !local.registry_token_mode && var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.frontend_identity.principal_id
}

resource "azurerm_role_assignment" "acr_pull_migrate" {
  count = local.migrate_job && !local.registry_token_mode && var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.migrate_identity[0].principal_id
}

# ca-workers pulls as its own identity once it runs as it (the registry block takes the app's
# first identity, modules/aca-container-app).
resource "azurerm_role_assignment" "acr_pull_workers" {
  count = local.workers_own_identity && !local.registry_token_mode && var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.workers_identity[0].principal_id
}
