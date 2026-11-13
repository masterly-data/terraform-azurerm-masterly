# Authentication to Postgres and Redis, and the generated admin password (entra-auth.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  # Every production run needs one of the two deployer paths to the vault stated, the same
  # as a real production install (see key_vault_deployer_ip_rules). Set file-wide so the
  # runs that assert something else are not all about this; the guard has its own run in keyvault.tftest.hcl.
  key_vault_deployer_ip_rules = ["203.0.113.7"]

  # A production plan with no notification target is refused (alert_email's validation), so
  # every production run states one. Runs about the target override it; the refusal
  # has its own runs in diagnostics.tftest.hcl.
  alert_email = "ops@example.com"
}

# --- Authentication to Postgres and Redis (ADR 0066, amended 2026-09-24) ------------------------
#
# Production follows Azure's recommended baseline by default: Microsoft Entra ID only, for the
# starter server and for Redis. A password or key is an explicit departure, and a changed default
# never reaches an existing install silently. The runs below cover each default, the opt-down,
# BYO-DB, and the existing-install gate (the azurerm_resources lookup, overridden per run).

# A NEW production install that sets neither input gets Entra-only on both, on the managed Redis
# offering.
run "production_new_install_defaults_to_entra" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = output.database_auth == "entra" && output.redis_auth == "entra"
    error_message = "A new production install must default to Microsoft Entra ID authentication for Postgres and Redis."
  }

  # Entra-only on the server: Entra on, password off. (The administrator login is left unset
  # too — Azure refuses one at creation when password authentication is off — but it is
  # Optional + Computed, so under a plan it reads as unknown rather than null and cannot be
  # asserted here.)
  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].authentication[0].active_directory_auth_enabled == true &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == false &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].tenant_id == "00000000-0000-0000-0000-000000000000"
    )
    error_message = "On database_auth = \"entra\" the server must have Entra authentication on and password authentication off."
  }

  # The apps' identity is the server's Entra administrator — the role that can create a database
  # per Environment — and the URL's user is that role's name.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].principal_name == "id-masterly-apps" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].principal_type == "ServicePrincipal"
    )
    error_message = "The apps' identity must be the starter server's Entra administrator, under its own name."
  }

  # Access keys off on the managed offering, and the identity holds the data access policy.
  assert {
    condition = (
      azurerm_managed_redis.this[0].default_database[0].access_keys_authentication_enabled == false &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1 &&
      length(azurerm_redis_cache_access_policy_assignment.apps) == 0
    )
    error_message = "On redis_auth = \"entra\" Azure Managed Redis must have access keys off and an access policy assignment for the apps' identity."
  }

  # The application's side, on both processes that connect: the api and ca-workers.
  assert {
    condition = alltrue([
      for names in [module.api.env_names, module.workers[0].env_names] :
      contains(names, "MASTERLY_DATABASE_AUTH") && contains(names, "MASTERLY_REDIS_AUTH") && contains(names, "AZURE_CLIENT_ID")
    ])
    error_message = "The api and the workers app must both carry MASTERLY_DATABASE_AUTH, MASTERLY_REDIS_AUTH and AZURE_CLIENT_ID on \"entra\"."
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_DATABASE_AUTH") && !contains(module.frontend.env_names, "MASTERLY_REDIS_AUTH")
    error_message = "The frontend connects to neither store and must carry neither binding."
  }

  # What the next plan reads back: the choice is recorded on the resources themselves.
  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].tags["masterly-auth"] == "entra" &&
      azurerm_managed_redis.this[0].tags["masterly-auth"] == "entra"
    )
    error_message = "The server and the cache must record the authentication they were applied with in their masterly-auth tag."
  }

  # The URL still reaches the apps, now without a key.
  assert {
    condition     = output.redis_url_wired == true
    error_message = "The keyless Redis URL must still resolve to a non-empty value."
  }
}

# The same default on the Azure Cache for Redis offering: Entra on, access keys off, and the
# built-in Data Contributor policy (reads and writes, no admin commands).
run "production_new_install_cache_offering_defaults_to_entra" {
  command = plan

  variables {
    mode                  = "production"
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 2
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      azurerm_redis_cache.this[0].redis_configuration[0].active_directory_authentication_enabled == true &&
      azurerm_redis_cache.this[0].access_keys_authentication_enabled == false &&
      length(azurerm_redis_cache_access_policy_assignment.apps) == 1 &&
      azurerm_redis_cache_access_policy_assignment.apps[0].access_policy_name == "Data Contributor" &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 0
    )
    error_message = "On redis_auth = \"entra\" Azure Cache for Redis must have Entra on, access keys off, and a Data Contributor assignment for the apps' identity."
  }

  # BYO-DB keeps its DSN: no lookup, no database binding, no Entra administrator.
  assert {
    condition = (
      output.database_auth == null &&
      output.redis_auth == "entra" &&
      length(data.azurerm_resources.existing_postgres) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      !contains(module.api.env_names, "MASTERLY_DATABASE_AUTH") &&
      contains(module.api.env_names, "MASTERLY_REDIS_AUTH")
    )
    error_message = "BYO-DB must keep DSN authentication whatever the mode, while Redis follows its own default."
  }
}

# Evaluation installs keep the password and the key, exactly as before this input existed: no
# Entra administrator, no access policy, and nothing new in the apps' environment.
run "demo_defaults_keep_password_and_key" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = output.database_auth == "password" && output.redis_auth == "key"
    error_message = "mode = \"demo\" must keep password and key authentication by default."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].authentication[0].active_directory_auth_enabled == false &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == true &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0
    )
    error_message = "On database_auth = \"password\" the server must keep the masterly_admin login with password authentication and no Entra administrator."
  }

  assert {
    condition = (
      azurerm_managed_redis.this[0].default_database[0].access_keys_authentication_enabled == true &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 0
    )
    error_message = "On redis_auth = \"key\" Azure Managed Redis must keep access keys on and needs no access policy assignment."
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_DATABASE_AUTH") &&
      !contains(module.api.env_names, "MASTERLY_REDIS_AUTH") &&
      !contains(module.api.env_names, "AZURE_CLIENT_ID")
    )
    error_message = "Password and key authentication must add nothing to the api's environment — absent is the application's own default."
  }
}

# The opt-down: a production install that states database_auth = "password" and
# redis_auth = "key" keeps both, and the module does not look up what exists — an explicit
# value always wins.
run "production_opt_down_keeps_password_and_key" {
  command = plan

  variables {
    mode                           = "production"
    database_auth                  = "password"
    redis_auth                     = "key"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition = (
      output.database_auth == "password" &&
      output.redis_auth == "key" &&
      length(data.azurerm_resources.existing_postgres) == 0 &&
      length(data.azurerm_resources.existing_redis) == 0
    )
    error_message = "An explicit database_auth / redis_auth must win, without a lookup of what exists."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == true &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      azurerm_redis_cache.this[0].access_keys_authentication_enabled == true &&
      azurerm_redis_cache.this[0].redis_configuration[0].active_directory_authentication_enabled == false &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      length(azurerm_redis_cache_access_policy_assignment.apps) == 0 &&
      !contains(module.api.env_names, "MASTERLY_DATABASE_AUTH") &&
      !contains(module.api.env_names, "MASTERLY_REDIS_AUTH")
    )
    error_message = "The production opt-down must keep the password and the key exactly as before."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].tags["masterly-auth"] == "password" &&
      azurerm_redis_cache.this[0].tags["masterly-auth"] == "key"
    )
    error_message = "The opt-down must be recorded on the resources, like the default."
  }
}

# The existing-install gate, Postgres half: a production install upgraded from a version before
# this default, whose server (untagged) still uses its password, stops at plan and asks for an
# explicit choice rather than being switched to Entra-only under objects masterly_admin owns.
run "production_existing_password_server_is_refused" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    redis_auth                     = "entra"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "org-id" = "org_test" }
      }]
    }
  }

  expect_failures = [azurerm_postgresql_flexible_server.this]
}

# ...and Redis half: an existing cache still on its access key is not switched either — the
# running api image, which this module does not control, may predate Entra support.
run "production_existing_key_cache_is_refused" {
  command = plan

  variables {
    mode                  = "production"
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "managed"
    enable_workers        = true
    api_max_replicas      = 2
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  override_data {
    target = data.azurerm_resources.existing_redis
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-abc123"
        name                = "redis-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.Cache/redisEnterprise"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "org-id" = "org_test" }
      }]
    }
  }

  expect_failures = [azurerm_managed_redis.this]
}

# An existing server this module already switched (tagged "entra") stays on Entra with the input
# unset — the gate must not fire on the second plan of the install it created — while a lookup
# that only finds ANOTHER install's server (different resource group) is ignored.
run "existing_entra_server_stays_entra_and_other_installs_are_ignored" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [
        {
          id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
          name                = "psql-masterly-abc123"
          resource_group_name = "rg-masterly-data"
          type                = "Microsoft.DBforPostgreSQL/flexibleServers"
          location            = "swedencentral"
          tags                = { "install-id" = "test", "masterly-auth" = "entra" }
        },
      ]
    }
  }

  override_data {
    target = data.azurerm_resources.existing_redis
    values = {
      resources = [
        {
          id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other-data/providers/Microsoft.Cache/redisEnterprise/redis-other-xyz789"
          name                = "redis-other-xyz789"
          resource_group_name = "rg-other-data"
          type                = "Microsoft.Cache/redisEnterprise"
          location            = "swedencentral"
          tags                = { "install-id" = "other" }
        },
      ]
    }
  }

  assert {
    condition     = output.database_auth == "entra" && output.redis_auth == "entra"
    error_message = "A server recorded as \"entra\" must stay on Entra, and another install's untagged cache must not count as this install's."
  }
}

# Outside production there is no departure to state, so an existing server keeps whatever it
# records without a refusal: an untagged one keeps its password, and a demo server someone moved
# to Entra is not moved back by the demo default.
run "demo_existing_servers_keep_what_they_have" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test" }
      }]
    }
  }

  override_data {
    target = data.azurerm_resources.existing_redis
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-abc123"
        name                = "redis-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.Cache/redisEnterprise"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "masterly-auth" = "entra" }
      }]
    }
  }

  assert {
    condition     = output.database_auth == "password" && output.redis_auth == "entra"
    error_message = "Outside production an existing server or cache must keep the authentication it records, in either direction."
  }
}

# An explicit "entra" wins over the default without a Redis lookup. The server is still read,
# for one fact only: whether it holds the generated admin password it must keep being sent (the
# transition runs at the end of this file). On a new install it finds nothing. Whether a switch
# of an existing server is in place is the provider's answer and not something a mock can show:
# the `authentication` block is updated in place, and the administrator login is left unset
# rather than renamed (a rename replaces the server). Only a plan against a live install proves it.
run "production_explicit_entra_reads_only_the_server" {
  command = plan

  variables {
    mode                           = "production"
    database_auth                  = "entra"
    redis_auth                     = "entra"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition = (
      length(data.azurerm_resources.existing_postgres) == 1 &&
      length(data.azurerm_resources.existing_redis) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1
    )
    error_message = "An explicit \"entra\" must read only the server, and grant the apps' identity on both stores."
  }

  # A new server on "entra" is sent no password: Azure refuses one at creation when password
  # authentication is off.
  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].administrator_password == null &&
      azurerm_postgresql_flexible_server.this[0].tags["masterly-admin-password"] == "none"
    )
    error_message = "A server created on \"entra\" must be sent no administrator password, and record that it holds none."
  }
}

# BYO-DB: database_auth = "entra" is refused, because there is no server of this module's to
# switch; the DSN is the customer's credential.
run "byo_db_refuses_entra_database_auth" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    database_auth         = "entra"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.database_auth]
}

# The two inputs accept only their own values; an empty string (a rendered template, an unset
# pipeline variable) is refused rather than read as unset.
run "database_auth_rejects_an_unknown_value" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    database_auth         = ""
  }

  expect_failures = [var.database_auth]
}

run "redis_auth_rejects_the_database_spelling" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
    redis_auth            = "password"
  }

  expect_failures = [var.redis_auth]
}

# --- The generated admin password across transitions ------------------------------------------
#
# A server holds exactly the administrator_password this configuration last sent, and the
# provider sends any change to it — a change to null included — as a new password. The
# override_data blocks below stand in for the tags a real server carries by then.

# A server created on "entra" records "none", and on every later plan, with the input set or
# unset, it is sent no password: it never had the generated one, and Azure refuses a password
# where password authentication was off from the start. (Its creation is asserted in
# production_explicit_entra_reads_only_the_server.)
run "a_server_created_on_entra_is_never_sent_a_password" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "masterly-auth" = "entra", "masterly-admin-password" = "none" }
      }]
    }
  }

  assert {
    condition = (
      output.database_auth == "entra" &&
      azurerm_postgresql_flexible_server.this[0].administrator_password == null &&
      azurerm_postgresql_flexible_server.this[0].tags["masterly-admin-password"] == "none"
    )
    error_message = "A server created on \"entra\" must stay on \"entra\" and never be sent a password."
  }
}

# The runs from here to the end of the file APPLY against the mock providers and share one state,
# in order, so each later run plans against the server the earlier ones left: the only way to see
# what an existing server is sent. Keep them last — every run after them would start from that
# state. They target the server (and so what it depends on, the password among them): the rest
# of the install is not what they are about, and mock values would not pass the provider's own
# checks of the IDs one resource hands another.

# A new install on "password" (the evaluation default). The server gets a well-formed ID, which
# the teardown's destroy plan hands the private endpoint.
run "password_install_created" {
  command = apply

  plan_options {
    target = [azurerm_postgresql_flexible_server.this]
  }

  override_resource {
    target = azurerm_postgresql_flexible_server.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
    }
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].administrator_password == random_password.postgres_admin[0].result &&
      azurerm_postgresql_flexible_server.this[0].tags["masterly-admin-password"] == "generated"
    )
    error_message = "A server created on \"password\" must be sent the generated password and record that it holds it."
  }
}

# Rotation: replacing random_password.postgres_admin must change the server's password in the
# same apply that rolls the connection URL onto it. If the server kept its old password, the apps
# would restart on a URL whose password Azure never received.
run "password_rotation_reaches_the_server" {
  command = apply

  plan_options {
    target  = [azurerm_postgresql_flexible_server.this]
    replace = [random_password.postgres_admin[0]]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "masterly-auth" = "password", "masterly-admin-password" = "generated" }
      }]
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].administrator_password == random_password.postgres_admin[0].result
    error_message = "A replaced random_password.postgres_admin must reach the server in the same apply as the connection URL."
  }
}

# The same server moved to "entra" on purpose. The lookup finds it untagged — the case of a server
# created by an earlier version of this module — and the server keeps being sent the password it
# holds, so the move plans no password change: null would reach Azure as an empty password.
run "moving_to_entra_keeps_the_held_password" {
  command = apply

  plan_options {
    target = [azurerm_postgresql_flexible_server.this]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    database_auth         = "entra"
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test" }
      }]
    }
  }

  assert {
    condition = (
      output.database_auth == "entra" &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == false &&
      azurerm_postgresql_flexible_server.this[0].administrator_password == random_password.postgres_admin[0].result &&
      azurerm_postgresql_flexible_server.this[0].tags["masterly-admin-password"] == "generated"
    )
    error_message = "A server moved from \"password\" to \"entra\" must keep being sent the password it holds, and record that it holds it."
  }
}

# And on the plan after, with the input unset: the tags now say "entra" and "generated", and the
# server is still sent the same password — no change on any later plan either.
run "a_moved_server_keeps_its_password_on_later_plans" {
  command = plan

  plan_options {
    target = [azurerm_postgresql_flexible_server.this]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_data {
    target = data.azurerm_resources.existing_postgres
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = { "install-id" = "test", "masterly-auth" = "entra", "masterly-admin-password" = "generated" }
      }]
    }
  }

  assert {
    condition = (
      output.database_auth == "entra" &&
      azurerm_postgresql_flexible_server.this[0].administrator_password == random_password.postgres_admin[0].result
    )
    error_message = "A moved server must stay on \"entra\" and keep being sent the password it holds."
  }
}

# Planned against the state the generated-admin-password chain above (its last apply, moving_to_entra_keeps_the_held_password) leaves: its conditions read values that are known only
# after an apply, so it follows that apply here rather than sitting with the other
# sizing runs (MAS-4478).
# The Service Bus binding: ca-workers scales on the jobs queue it receives from, authenticated as
# the apps' identity, which holds the Manage right on that queue alone. An install whose replica
# bounds are unchanged keeps them; only the rule and the grant are added.
run "service_bus_workers_scale_on_the_jobs_queue" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    enable_workers        = true
    workers_max_replicas  = 4
  }

  override_module {
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  assert {
    condition = (
      length(module.workers[0].scale.custom_scale_rules) == 1 &&
      module.workers[0].scale.custom_scale_rules[0].custom_rule_type == "azure-servicebus" &&
      module.workers[0].scale.custom_scale_rules[0].metadata["queueName"] == azurerm_servicebus_queue.jobs[0].name &&
      module.workers[0].scale.custom_scale_rules[0].metadata["messageCount"] == "5" &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.apps_identity.id
    )
    error_message = "ca-workers must scale on the jobs queue's message count, authenticated as the apps' identity."
  }

  # The rule watches the namespace the workers receive from: the same name the workers' env
  # is given as MASTERLY_SERVICEBUS_NAMESPACE.
  assert {
    condition     = module.workers[0].scale.custom_scale_rules[0].metadata["namespace"] == local.servicebus_env["MASTERLY_SERVICEBUS_NAMESPACE"]
    error_message = "The scale rule must watch the namespace the workers receive from."
  }

  assert {
    condition     = module.workers[0].scale.min_replicas == 1 && module.workers[0].scale.max_replicas == 4
    error_message = "The scale rule must work between workers_min_replicas and workers_max_replicas."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.sb_scaler) == 1 &&
      azurerm_role_assignment.sb_scaler[0].role_definition_name == "Azure Service Bus Data Owner" &&
      azurerm_role_assignment.sb_scaler[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "The apps' identity must hold Azure Service Bus Data Owner for the scale rule to read the queue."
  }

  # The api has its own HTTP scale rule and no grace-period change.
  assert {
    condition     = length(module.api.scale.custom_scale_rules) == 0 && module.api.scale.termination_grace_period_seconds == null
    error_message = "Only ca-workers gets the queue scale rule and the grace period."
  }
}
