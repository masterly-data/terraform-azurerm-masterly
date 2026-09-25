# How the apps authenticate to the install's own Postgres server and Redis (ADR 0066, amended
# 2026-09-24): with a Microsoft Entra ID token for the apps' user-assigned identity, or with the
# password and access key carried in their connection URLs.
#
# Entra-only is Azure's recommended baseline for both services, and it is the production default
# for a NEW install. A departure from it is an explicit input: database_auth = "password",
# redis_auth = "key". Evaluation installs (mode = "demo") keep the password and the key.
#
# What "entra" provisions:
#
#   Postgres   The flexible server runs with Microsoft Entra authentication on and password
#              authentication off. The apps' identity is the server's Microsoft Entra
#              administrator, which makes it a database role that can create databases (the api
#              creates one per Masterly Environment, ADR 0003). The connection URL names that role
#              and carries no password; the api presents a token instead.
#   Redis      Access-key authentication is off. The apps' identity holds a data access policy on
#              whichever redis_offering is active, and the URL carries no key.
#
# The application side of this is MASTERLY_DATABASE_AUTH / MASTERLY_REDIS_AUTH, read by api
# images v0.133.7 and later. An older image ignores both and finds no credential in its URLs, so
# "entra" needs the api and workers to run v0.133.7 or later.
#
# BYO-DB (external_database_url) is not affected: that database is yours, and the DSN you supply
# is the credential.
#
# --- A changed default never reaches an existing install silently --------------------------
#
# Terraform cannot tell a new install from an upgraded one on its own, and flipping a running
# install to Entra-only on upgrade would break it: every object in its databases is owned by the
# password administrator, masterly_admin, which the apps' identity cannot act as until the
# ownership steps in the README ("Moving an existing install to Microsoft Entra authentication")
# have run. So when database_auth or redis_auth is unset, the module looks for the install's own
# server or cache in Azure before choosing a default:
#
#   - none exists yet       -> the default for the mode (production: "entra").
#   - one exists            -> the authentication it records in its `masterly-auth` tag. A server
#                              or cache created before this tag existed is recorded as using its
#                              password or key.
#   - in production, one exists and records a password or key
#                           -> the plan stops and asks for an explicit database_auth / redis_auth,
#                              because a production departure is always a stated input.
#
# Setting the input skips the lookup entirely: an explicit value always wins.

variable "database_auth" {
  type        = string
  default     = null
  description = "How the apps authenticate to the starter Postgres server: \"entra\" (Microsoft Entra ID only — the apps' identity is the server's Entra administrator and password authentication is off; needs api images v0.133.7 or later) or \"password\" (the masterly_admin login's password in the connection URL; a departure from Azure's recommended baseline, see the README). Unset: a new server gets \"entra\" in mode = \"production\" and \"password\" otherwise; an existing server keeps what it has, and a production install whose existing server uses a password must set this explicitly. Moving an existing install to \"entra\" needs the ownership steps in the README first. Has no effect with external_database_url (BYO-DB), whose DSN is the credential."

  validation {
    # The same total shape as redis_offering's check: coalesce() keeps null out of contains(),
    # and the explicit != "" stops an empty string from being read as unset.
    condition     = var.database_auth != "" && contains(["entra", "password"], coalesce(var.database_auth, "entra"))
    error_message = "database_auth must be \"entra\" or \"password\", or left unset."
  }

  validation {
    condition     = var.database_auth != "entra" || var.external_database_url == null
    error_message = "database_auth = \"entra\" applies to the starter Postgres server this module provisions, and with external_database_url (BYO-DB) there is none: the database is yours, and the DSN you supply is the credential. Leave database_auth unset."
  }
}

variable "redis_auth" {
  type        = string
  default     = null
  description = "How the apps authenticate to Redis (enable_redis = true): \"entra\" (Microsoft Entra ID only — access keys are off and the apps' identity holds a data access policy; needs api images v0.133.7 or later) or \"key\" (the access key in the connection URL; a departure from Azure's recommended baseline, see the README). Unset: a new cache gets \"entra\" in mode = \"production\" and \"key\" otherwise; an existing cache keeps what it has, and a production install whose existing cache uses a key must set this explicitly."

  validation {
    condition     = var.redis_auth != "" && contains(["entra", "key"], coalesce(var.redis_auth, "entra"))
    error_message = "redis_auth must be \"entra\" or \"key\", or left unset."
  }
}

# --- What already exists (read only when the input is unset) ---------------------------------
#
# A listing by resource type, narrowed below to this install's data resource group and name.
# It is read at plan time on a new install too — every argument is known — and it finds nothing
# there. It needs read access to the subscription's resources, which the identity that applies
# this module already has.

data "azurerm_resources" "existing_postgres" {
  count = local.provision_postgres && var.database_auth == null ? 1 : 0

  type = "Microsoft.DBforPostgreSQL/flexibleServers"
}

data "azurerm_resources" "existing_redis" {
  count = local.redis_enabled && var.redis_auth == null ? 1 : 0

  type = local.use_managed_redis ? "Microsoft.Cache/redisEnterprise" : "Microsoft.Cache/Redis"
}

locals {
  # The tag each server or cache carries, recording the authentication it was last applied with.
  auth_tag = "masterly-auth"

  existing_postgres = [
    for r in flatten(data.azurerm_resources.existing_postgres[*].resources) : r
    if lower(r.resource_group_name) == lower(local.rg_data_name) && startswith(r.name, "psql-${var.name_prefix}-")
  ]
  existing_redis = [
    for r in flatten(data.azurerm_resources.existing_redis[*].resources) : r
    if lower(r.resource_group_name) == lower(local.rg_data_name) && startswith(r.name, "redis-${var.name_prefix}-")
  ]

  # What an existing resource records; null when there is none (or the input was set, and no
  # lookup ran). Untagged means it was created before this module recorded it: password / key.
  recorded_database_auth = length(local.existing_postgres) > 0 ? try(local.existing_postgres[0].tags[local.auth_tag], "password") : null
  recorded_redis_auth    = length(local.existing_redis) > 0 ? try(local.existing_redis[0].tags[local.auth_tag], "key") : null

  # The effective choice: the input when set, otherwise what exists, otherwise the mode's default
  # — the mode-conditional shape of keyvault.tf's purge_protection_enabled.
  database_auth = var.database_auth != null ? var.database_auth : coalesce(
    local.recorded_database_auth, var.mode == "production" ? "entra" : "password",
  )
  redis_auth = var.redis_auth != null ? var.redis_auth : coalesce(
    local.recorded_redis_auth, var.mode == "production" ? "entra" : "key",
  )

  # Entra only ever applies to what this module provisions: never to a BYO-DB DSN, and never
  # to a Redis that is not enabled.
  database_entra = local.provision_postgres && local.database_auth == "entra"
  redis_entra    = local.redis_enabled && local.redis_auth == "entra"

  # The Postgres role the apps' identity becomes: an Entra administrator's role is named by
  # its principal_name, and the connection URL's user must be exactly that name.
  database_entra_role = module.apps_identity.name

  # Written only for "entra". Absent is the application's own default (password / key), so an
  # install that keeps its password and key sees no change to the apps' environment at all.
  entra_auth_env = merge(
    local.database_entra ? { MASTERLY_DATABASE_AUTH = "entra" } : {},
    local.redis_entra ? { MASTERLY_REDIS_AUTH = "entra" } : {},
    # The identity the token is minted for (DefaultAzureCredential). The same key and value the
    # Key Vault and Service Bus bindings set, so the merge is safe.
    local.database_entra || local.redis_entra ? { AZURE_CLIENT_ID = module.apps_identity.client_id } : {},
  )
}

# --- Postgres: the apps' identity as the server's Microsoft Entra administrator --------------
#
# Why the administrator and not a narrower role: this is the one database principal Terraform can
# create. A role made with pgaadauth_create_principal is created by running SQL on the server,
# which is reachable only through its private endpoint, and this module runs no SQL. The
# privilege is the same as the masterly_admin login it replaces, which was the server's
# administrator too.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "apps" {
  count = local.database_entra ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = azurerm_resource_group.data.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = module.apps_identity.principal_id
  principal_name      = local.database_entra_role
  principal_type      = "ServicePrincipal"
}

# --- Redis: a data access policy for the apps' identity, on whichever offering is active ------

# Azure Managed Redis has one access policy, "default", with full data access; the assignment
# is what lets the identity authenticate at all.
resource "azurerm_managed_redis_access_policy_assignment" "apps" {
  count = local.redis_entra && local.use_managed_redis ? 1 : 0

  managed_redis_id = azurerm_managed_redis.this[0].id
  object_id        = module.apps_identity.principal_id
}

# Azure Cache for Redis: the built-in "Data Contributor" policy — reads and writes, no admin
# commands. The alias is only a display name; the Redis username is the identity's object id.
resource "azurerm_redis_cache_access_policy_assignment" "apps" {
  count = local.redis_entra && local.use_legacy_redis ? 1 : 0

  name               = "masterly-apps"
  redis_cache_id     = azurerm_redis_cache.this[0].id
  access_policy_name = "Data Contributor"
  object_id          = module.apps_identity.principal_id
  object_id_alias    = local.database_entra_role
}

# The posture, assertable in `terraform test`. Names only; the URLs stay secrets.
output "database_auth" {
  # Whether a DSN was supplied is not the secret; the same narrow unmarking as main.tf's
  # presence tests.
  value       = nonsensitive(local.provision_postgres) ? local.database_auth : null
  description = "How the apps authenticate to the starter Postgres server: \"entra\" or \"password\". Null with external_database_url (BYO-DB), where the DSN you supply is the credential."
}

output "redis_auth" {
  value       = local.redis_enabled ? local.redis_auth : null
  description = "How the apps authenticate to Redis: \"entra\" or \"key\". Null when Redis is not enabled."
}
