# The starter Postgres Flexible Server and the connection URLs the apps and the migrate job use.

# --- Data plane: the starter Postgres Flexible Server (skipped on BYO-DB) --------
# DB-per-Environment lives INSIDE this server: the api's tenancy seam creates
# masterly_dp_<environment> databases at first touch (ADR 0003). With
# external_database_url set (ADR 0065) none of this exists — the customer's own
# Postgres is the data plane and its networking is theirs.

resource "random_password" "postgres_admin" {
  count = local.provision_postgres ? 1 : 0

  length  = 32
  special = false # keeps the DSN URL-safe
}

# The install's existing server, if any, read for its real storage size (local.postgres_storage_mb).
# The listing runs first because reading a server that does not exist is an error.
data "azurerm_resources" "postgres_storage" {
  count = local.provision_postgres ? 1 : 0

  type = "Microsoft.DBforPostgreSQL/flexibleServers"
}

data "azurerm_postgresql_flexible_server" "existing" {
  count = length(local.existing_postgres_storage_lookup) > 0 ? 1 : 0

  name                = local.existing_postgres_storage_lookup[0].name
  resource_group_name = local.rg_data_name
}

resource "azurerm_postgresql_flexible_server" "this" {
  count = local.provision_postgres ? 1 : 0

  name                = "psql-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location

  version  = var.postgres_version
  sku_name = var.postgres_sku_name

  # Never below the real size (local.postgres_storage_mb). Grown storage cannot be shrunk.
  storage_mb = local.postgres_storage_mb

  # Unset tier sends null, which keeps the provider's computed value.
  auto_grow_enabled = local.postgres_auto_grow
  storage_tier      = var.postgres_storage_tier

  # Password or Microsoft Entra ID (entra-auth.tf). Both are changed in place on an existing
  # server; neither replaces it.
  #
  # The administrator login is set only while password authentication is on, because Azure
  # refuses one at creation when it is off. On an existing server that moves to "entra" the
  # login is left alone rather than cleared: it is Optional + Computed, so null here is no
  # change, and changing it from one name to another would REPLACE the server.
  #
  # The password follows the server rather than the choice (entra-auth.tf, "The generated admin
  # password"): a server that holds the generated password keeps being sent it, on "entra" too,
  # because the provider would send a change to null as an empty password. So replacing
  # random_password.postgres_admin changes the server's password and the connection URL in the
  # same apply. Only a server created on "entra" is sent none.
  administrator_login    = local.database_entra ? null : "masterly_admin"
  administrator_password = local.postgres_admin_password_held ? random_password.postgres_admin[0].result : null

  authentication {
    active_directory_auth_enabled = local.database_entra
    password_auth_enabled         = !local.database_entra
    tenant_id                     = local.database_entra ? data.azurerm_client_config.current.tenant_id : null
  }

  zone                          = null
  public_network_access_enabled = false # reachable only via the private endpoint

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = local.postgres_geo_redundant_backup

  dynamic "high_availability" {
    for_each = var.postgres_zone_redundant_ha ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  # The authentication this server was last applied with, which is what a later plan with
  # database_auth unset reads back, and whether it holds the generated admin password
  # (entra-auth.tf). A tag change is in place.
  tags = merge(local.tags, {
    (local.auth_tag)           = local.database_auth
    (local.admin_password_tag) = local.postgres_admin_password_held ? "generated" : "none"
  })

  lifecycle {
    # A production departure is an explicit input (ADR 0066, amended 2026-09-24): an existing
    # server still on its password is never flipped by a default, and never kept on it silently.
    precondition {
      condition     = !(var.mode == "production" && var.database_auth == null && local.recorded_database_auth == "password")
      error_message = "This install's Postgres server authenticates with the masterly_admin password, and database_auth is unset. In mode = \"production\" this module now defaults to Microsoft Entra ID authentication, but it will not switch a running server on its own: every object in its databases is owned by masterly_admin, and the apps cannot use them as their Entra identity until ownership has moved. Choose explicitly. Set database_auth = \"password\" to keep the password (nothing changes; it is a documented departure from Azure's recommended baseline), or follow \"Moving an existing install to Microsoft Entra authentication\" in the module README and then set database_auth = \"entra\"."
    }

    # Both of these are ASSIGNED BY AZURE at creation and absent from this configuration, so
    # without ignoring them every later plan proposes setting them to null — and Azure refuses:
    #
    #   Error: an existing `high_availability.0.standby_availability_zone` can only be changed
    #   when exchanged with the zone specified in `zone`
    #
    # `zone` was already ignored here. `standby_availability_zone` was not, and it is inside the
    # dynamic high_availability block, which is why it was easy to miss — a ZoneRedundant server
    # gets a standby zone whether or not the configuration mentions one.
    #
    # The consequence was total: the FIRST apply succeeds, and every apply after it fails. The
    # documented production bring-up is two applies, so a customer could not even finish the
    # install, let alone upgrade. Found on the first production rehearsal, 2026-09-01.
    #
    # geo_redundant_backup_enabled is ignored for a different reason: Azure accepts it only when
    # the server is created, so the provider replaces the server to change it, and replacing it
    # destroys the server and every Environment database on it. The production default depends
    # on the region and the mode, so a module upgrade or a changed input could otherwise plan
    # that replacement on an existing install. Ignoring it means the value is used once, at
    # creation, and an existing server keeps what it was created with. To change it on an
    # existing server, restore the server to a new one with the setting you want.
    #
    # administrator_password is deliberately NOT ignored: a replaced random_password has to reach
    # the server, or the apps would roll onto a connection URL whose password Azure never got.
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
      geo_redundant_backup_enabled,
    ]
  }
}

# What the server's own error log may carry (ADR 0080, amendment of 2026-09-10). That log
# reaches the install's workspace through the diagnostic setting in diagnostics.tf, and from
# there the diagnostic bundle, so it should say what failed without repeating the values
# involved:
#
#   * log_error_verbosity = TERSE drops the DETAIL:, HINT: and CONTEXT: lines. DETAIL: is where
#     a unique or foreign-key violation prints the conflicting key values, and a check or
#     not-null violation the whole failing row.
#   * log_parameter_max_length_on_error = 0 keeps a failing statement's bound parameter values
#     out of the log.
#   * log_parameter_max_length = 0 does the same for any statement logged for another reason,
#     such as log_min_duration_statement.
#
# log_min_error_statement stays at Postgres's default, so a failing statement's text is still
# logged: it is very often the whole diagnosis, and the apps send their values as bound
# parameters, which the two settings above keep out. A statement that carries a literal value
# in its text still logs it.
#
# All three are dynamic parameters: Azure applies them without restarting the server.
locals {
  postgres_log_parameters = {
    log_error_verbosity               = "TERSE"
    log_parameter_max_length_on_error = "0"
    log_parameter_max_length          = "0"
  }

  # The parameters the module owns when postgres_pgbouncer is on. max_prepared_statements must
  # be above 0 for asyncpg's prepared statements to survive transaction pooling; the value is
  # documented on the variable.
  postgres_pgbouncer_parameters = {
    "pgbouncer.enabled"                 = "true"
    "pgbouncer.pool_mode"               = "TRANSACTION"
    "pgbouncer.max_prepared_statements" = "100"
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "log" {
  # nonsensitive() on the presence test alone: whether external_database_url was supplied is
  # not the secret, and a marked value cannot drive for_each.
  for_each = nonsensitive(local.provision_postgres) ? local.postgres_log_parameters : {}

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = each.value
}

# The operator's own parameters (postgres_server_parameters), in a resource of their own so the
# log parameters above keep their state addresses. The variable refuses the keys of
# local.postgres_log_parameters and any entry on BYO-DB; the gate below is the second line.
resource "azurerm_postgresql_flexible_server_configuration" "operator" {
  for_each = nonsensitive(local.provision_postgres) ? var.postgres_server_parameters : {}

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = each.value
}

# Azure's built-in PgBouncer in transaction mode (postgres_pgbouncer), in a resource of its own
# so the "log" and "operator" state addresses stay unchanged. The variable refuses a burstable
# SKU, BYO-DB and operator-set pgbouncer.* keys; the gate below is the second line.
resource "azurerm_postgresql_flexible_server_configuration" "pgbouncer" {
  for_each = nonsensitive(local.provision_postgres) && var.postgres_pgbouncer ? local.postgres_pgbouncer_parameters : {}

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = each.value
}

# The server's only network presence: a private endpoint in the install's VNet. The
# private DNS zone maps the server's FQDN to this endpoint, so the application DSN is
# identical to the public-path one.
resource "azurerm_private_endpoint" "postgres" {
  count = local.provision_postgres ? 1 : 0

  name                = "pe-${var.name_prefix}-postgres"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-postgres"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this[0].id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "postgres"
    private_dns_zone_ids = [local.postgres_dns_zone_id]
  }

  tags = local.tags
}

moved {
  from = random_password.postgres_admin
  to   = random_password.postgres_admin[0]
}

moved {
  from = azurerm_postgresql_flexible_server.this
  to   = azurerm_postgresql_flexible_server.this[0]
}

moved {
  from = azurerm_private_endpoint.postgres
  to   = azurerm_private_endpoint.postgres[0]
}

locals {
  # The install-level DSN (ADR 0003): the customer's own database on BYO-DB (ADR 0065),
  # otherwise the provisioned starter server's admin connection: the masterly_admin login and
  # its password, or — on database_auth = "entra" — the apps' identity's Entra role with no
  # password at all, since the api presents a token instead (entra-auth.tf).
  #
  # With postgres_pgbouncer the URL points at the built-in PgBouncer on 6432 (transaction pool);
  # database_direct_url is the same server, role and database on 5432 for what a transaction
  # pooler cannot carry (CREATE DATABASE, migrations).
  # The starter server's URLs are composed in modules/postgres-connection-urls from these.
  database_pooler_port = var.postgres_pgbouncer ? "6432" : "5432"
  database_direct_port = "5432"
  database_auth_mode   = local.database_entra ? "entra" : "password"
  database_role        = local.database_entra ? local.database_entra_role : "masterly_admin"

  database_url = var.external_database_url != null ? var.external_database_url : module.postgres_connection_urls[0].pooler_url

  # Null on BYO-DB, where postgres_pgbouncer is refused and the secret is never named.
  database_direct_url = var.external_database_url != null ? null : module.postgres_connection_urls[0].direct_url
}

module "postgres_connection_urls" {
  source = "./modules/postgres-connection-urls"
  count  = local.provision_postgres ? 1 : 0

  server_fqdn = azurerm_postgresql_flexible_server.this[0].fqdn
  auth_mode   = local.database_auth_mode
  role        = local.database_role
  password    = local.database_entra ? null : random_password.postgres_admin[0].result
  pooler_port = local.database_pooler_port
  direct_port = local.database_direct_port
}

# The migrate job's own URLs (migrate.tf): the same server and ports, with the migrate
# identity's Entra role on "entra" and masterly_admin, as today, on "password".
module "postgres_connection_urls_migrate" {
  source = "./modules/postgres-connection-urls"
  count  = local.migrate_job && local.provision_postgres ? 1 : 0

  server_fqdn = azurerm_postgresql_flexible_server.this[0].fqdn
  auth_mode   = local.database_auth_mode
  role        = local.migrate_database_role
  password    = local.database_entra ? null : random_password.postgres_admin[0].result
  pooler_port = local.database_pooler_port
  direct_port = local.database_direct_port
}

# The backend apps' own URLs with migrations = "job" on the starter server: each app signs in as
# the DML-only role the migrate job creates for it (migrate.tf, ADR 0120 §6). On "entra" the role
# is bound to the app's identity and the URL carries no password; on "password" it carries that
# role's generated password, and reaches the app only inside its own vault secret ("job" requires
# mode = production, which requires the vault). The roles exist only if the api image's migrate
# role creates them, which no release up to v0.135.0 does; the README's upgrade note gates "job"
# on such a release, and the module cannot check the image.
module "postgres_connection_urls_api" {
  source = "./modules/postgres-connection-urls"
  count  = local.migrate_app_roles ? 1 : 0

  server_fqdn = azurerm_postgresql_flexible_server.this[0].fqdn
  auth_mode   = local.database_auth_mode
  role        = local.migrate_api_role
  password    = local.database_entra ? null : random_password.migrate_api_role[0].result
  pooler_port = local.database_pooler_port
  direct_port = local.database_direct_port
}

module "postgres_connection_urls_workers" {
  source = "./modules/postgres-connection-urls"
  count  = local.workers_own_dsn ? 1 : 0

  server_fqdn = azurerm_postgresql_flexible_server.this[0].fqdn
  auth_mode   = local.database_auth_mode
  role        = local.migrate_workers_role
  password    = local.database_entra ? null : random_password.migrate_workers_role[0].result
  pooler_port = local.database_pooler_port
  direct_port = local.database_direct_port
}

locals {
  # Null without the app roles (the workers' also without ca-workers), where the secrets below
  # are never named.
  api_database_url            = one(module.postgres_connection_urls_api[*].pooler_url)
  api_database_direct_url     = one(module.postgres_connection_urls_api[*].direct_url)
  workers_database_url        = one(module.postgres_connection_urls_workers[*].pooler_url)
  workers_database_direct_url = one(module.postgres_connection_urls_workers[*].direct_url)

  # The secret each backend app reads its DSN (and, with postgres_pgbouncer, its direct DSN) from:
  # its own with the app roles, the shared install-level one otherwise, as before.
  api_database_secret_name            = local.migrate_app_roles ? "api-database-url" : "database-url"
  api_database_direct_secret_name     = local.migrate_app_roles ? "api-database-direct-url" : "database-direct-url"
  workers_database_secret_name        = local.workers_own_dsn ? "workers-database-url" : "database-url"
  workers_database_direct_secret_name = local.workers_own_dsn ? "workers-database-direct-url" : "database-direct-url"

  # The shared DSN secrets no app's env names with the app roles. They stay in the vault
  # (install_secret_names, keyvault.tf), because the revisions running before an upgrade to
  # migrations = "job" still reference them until their replacements are ready.
  shared_database_secret_names = concat(["database-url"], var.postgres_pgbouncer ? ["database-direct-url"] : [])

  # ca-api keeps their Container App secret definitions too, as vault references no env names
  # (api_vault_secret_refs, keyvault.tf): its revision from before the upgrade still resolves
  # them while the new one waits for the migrate job. ca-workers keeps none: identities belong to
  # the app too, and it now runs only as id-<prefix>-workers (workers.tf), so its old revision
  # cannot sign in as before whatever secrets stay. "job" requires the
  # vault, so these are never value secrets.
  api_retained_secret_names = local.migrate_app_roles && var.enable_key_vault ? local.shared_database_secret_names : []
}
