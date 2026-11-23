# The migrate job (migrate.tf).
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

# --- The migrate job (migrate.tf) ------------------------------------------------------------
#
# With migrations = "job", migrations and new Environments' databases run in caj-migrate, as
# id-<prefix>-migrate; ca-api and ca-workers only check the schema stamps (MASTERLY_MIGRATIONS =
# job). The identities are pinned with override_module, as in
# no_data_plane_grant_reaches_the_frontend, so the wiring is checkable at plan.

# The default, "start", is main's install: no job, no migrate identity, no grant, no second
# administrator, no MASTERLY_MIGRATIONS, so an install on a backend release up to v0.135.0, which
# has no migrate entry point, is not broken by the upgrade.
run "migrations_default_to_start_and_create_no_migrate_job" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    enable_key_vault      = true
    database_auth         = "entra"
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  assert {
    condition = (
      local.migrations == "start" &&
      length(azurerm_container_app_job.migrate) == 0 &&
      length(azapi_resource_action.migrate_start) == 0 &&
      length(terraform_data.migrate_image) == 0 &&
      length(module.migrate_identity) == 0 &&
      length(azurerm_role_assignment.acr_pull_migrate) == 0 &&
      length(azurerm_role_assignment.kv_secrets_user_migrate) == 0 &&
      length(azurerm_role_assignment.kv_byo_database_reader_migrate) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 0 &&
      length(module.postgres_connection_urls_migrate) == 0 &&
      length(local.migrate_secret_names) == 0 &&
      output.migrate_job_name == null &&
      output.migrate_identity_principal_id == null
    )
    error_message = "With migrations left at \"start\" the module must create no migrate job, identity, grant or administrator."
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_MIGRATIONS") &&
      !contains(module.workers[0].env_names, "MASTERLY_MIGRATIONS") &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      !contains(keys(azurerm_key_vault_secret.install), "migrate-database-url")
    )
    error_message = "With migrations left at \"start\" ca-api and ca-workers must carry no MASTERLY_MIGRATIONS, so they migrate at start as on main."
  }

  # Nor does "start" on "entra" create the workers' identity, its grant copies, its Redis policies
  # or the per-app DSNs: both apps keep id-<prefix>-apps and the shared database-url, as on main.
  assert {
    condition = (
      !local.workers_own_identity &&
      length(module.workers_identity) == 0 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) == 0 &&
      length(azurerm_role_assignment.kv_signing_keys_workers) == 0 &&
      length(azurerm_role_assignment.acr_pull_workers) == 0 &&
      length(azurerm_role_assignment.acs_email_sender_workers) == 0 &&
      length(azurerm_role_assignment.sb_sender_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver_workers) == 0 &&
      length(azurerm_role_assignment.sb_scaler_workers) == 0 &&
      length(azurerm_managed_redis_access_policy_assignment.workers) == 0 &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(module.postgres_connection_urls_api) == 0 &&
      length(module.postgres_connection_urls_workers) == 0 &&
      output.workers_identity_principal_id == null
    )
    error_message = "With migrations left at \"start\" the module must create no workers' identity, workers grant, workers Redis policy or per-app DSN."
  }

  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "database-url") &&
      contains(module.workers[0].vault_backed_secret_names, "database-url") &&
      !contains(keys(azurerm_key_vault_secret.install), "api-database-url") &&
      !contains(keys(azurerm_key_vault_secret.install), "workers-database-url")
    )
    error_message = "With migrations left at \"start\" both backend apps must read the shared database-url, and no per-app DSN secret may exist."
  }
}

# ca-workers' identity follows the vault and its DSN the app roles (workers.tf). They part on
# BYO-DB, the one shape with the identity and no starter server, so the DSN local must not follow
# the identity's: a workers DSN there would read a server that does not exist. Each run in
# tests/workers_identity.tftest.hcl compares the grants on a shape.
run "workers_identity_follows_the_vault_and_its_dsn_the_app_roles" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    enable_key_vault      = true
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      local.workers_own_identity &&
      !local.workers_own_dsn &&
      !issensitive(local.workers_own_identity) &&
      length(module.workers_identity) == 1 &&
      length(module.postgres_connection_urls_workers) == 0 &&
      local.workers_database_secret_name == "database-url" &&
      local.workers_database_direct_secret_name == "database-direct-url"
    )
    error_message = "On BYO-DB with the vault ca-workers must run as its own identity and read the shared database-url, with no workers DSN planned."
  }
}

# migrations_default_to_start_and_create_no_migrate_job again, with every feature a workers grant
# copies switched on (Service Bus with the queue scaler, ACS email, Entra Redis on each offering):
# the shared grants exist, their workers copies do not, because ca-workers stays on the apps
# identity with "start" on "entra", whatever features are on.
run "migrations_start_creates_no_workers_grant_with_every_feature_on" {
  command = plan

  variables {
    mode                           = "production"
    database_auth                  = "entra"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "test-only"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = jsonencode({ kty = "EC" })
    initial_owner_email            = "owner@example.com"
    acr_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    redis_auth                     = "entra"
    enable_workers                 = true
    enable_service_bus             = true
    servicebus_sku                 = "Standard"
    email_acs_enabled              = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "start"
  }

  # migrations = "start" in production plans, with the check's warning (migrate.tf).
  expect_failures = [check.production_migrations_at_start]

  assert {
    condition = (
      local.migrations == "start" &&
      length(azurerm_role_assignment.kv_app_secrets) == 1 &&
      length(azurerm_role_assignment.kv_signing_key_reader) == 1 &&
      length(azurerm_role_assignment.acr_pull) == 1 &&
      length(azurerm_role_assignment.acs_email_sender) == 1 &&
      length(azurerm_role_assignment.sb_sender) == 1 &&
      length(azurerm_role_assignment.sb_receiver) == 1 &&
      length(azurerm_role_assignment.sb_scaler) == 1 &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1
    )
    error_message = "This run must switch on every feature a workers grant copies, or its absence checks below prove nothing."
  }

  assert {
    condition = (
      length(module.workers_identity) == 0 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) == 0 &&
      length(azurerm_role_assignment.kv_signing_keys_workers) == 0 &&
      length(azurerm_role_assignment.acr_pull_workers) == 0 &&
      length(azurerm_role_assignment.acs_email_sender_workers) == 0 &&
      length(azurerm_role_assignment.sb_sender_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver_workers) == 0 &&
      length(azurerm_role_assignment.sb_scaler_workers) == 0 &&
      length(azurerm_managed_redis_access_policy_assignment.workers) == 0 &&
      length(module.postgres_connection_urls_api) == 0 &&
      length(module.postgres_connection_urls_workers) == 0
    )
    error_message = "With migrations = \"start\" no workers grant, Redis policy or per-app DSN may exist, whatever features are on."
  }
}

run "migrations_start_creates_no_workers_redis_policy_on_azure_cache_for_redis" {
  command = plan

  variables {
    mode                           = "production"
    database_auth                  = "entra"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "test-only"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = jsonencode({ kty = "EC" })
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    redis_auth                     = "entra"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "start"
  }

  # migrations = "start" in production plans, with the check's warning (migrate.tf).
  expect_failures = [check.production_migrations_at_start]

  assert {
    condition = (
      length(azurerm_redis_cache_access_policy_assignment.apps) == 1 &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0
    )
    error_message = "With migrations = \"start\" on Azure Cache for Redis, only the apps identity may hold an access policy."
  }
}

run "migrations_refuses_an_unknown_value" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    migrations            = "both"
  }

  expect_failures = [var.migrations]
}

run "migrations_job_refuses_demo_mode" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    mode                  = "demo"
    migrations            = "job"
  }

  expect_failures = [var.migrations]
}

run "external_database_admin_url_refused_without_the_migrate_job" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    external_database_admin_url = "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.external_database_admin_url]
}

run "migrate_job_schedule_refuses_an_empty_value" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    migrate_job_schedule  = ""
  }

  expect_failures = [var.migrate_job_schedule]
}

run "migrate_byo_database_secrets_require_job_mode" {
  command = plan
  variables {
    ingress_allowed_cidrs             = ["203.0.113.7/32"]
    migrate_byo_database_secret_names = ["environment-a-connection"]
  }
  expect_failures = [var.migrate_byo_database_secret_names]
}

run "migrate_job_schedule_refuses_four_fields" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    migrate_job_schedule  = "*/5 * * *"
  }

  expect_failures = [var.migrate_job_schedule]
}

# A calling root may declare its registry credential variables sensitive, as it reasonably
# would for anything taken from the install bundle. The module must plan the same way: whether
# a credential was supplied is not the secret, so the presence and mode tests that decide which
# secrets exist (keys of a for_each) must not carry the caller's mark. The deprecated
# registry_username, marked sensitive by the caller, in production with the Key Vault on.
run "sensitive_registry_username_plans_in_production_with_key_vault" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3
    acr_login_server     = null
    registry_username    = sensitive("install-puller")
    registry_password    = sensitive("pull-secret")

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = contains(keys(azurerm_key_vault_secret.install), "registry-password")
    error_message = "A sensitive registry_username must still store the pull password in the vault as registry-password."
  }

  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "registry-password") &&
      contains(module.frontend.vault_backed_secret_names, "registry-password") &&
      contains(module.workers[0].vault_backed_secret_names, "registry-password")
    )
    error_message = "A sensitive registry_username must still reach every app as the registry-password Key Vault reference."
  }

  assert {
    condition     = output.image_references.registry_credential_mode == "token" && output.image_references.registry_server == "masterly.azurecr.io"
    error_message = "A sensitive registry_username must still derive the token mode against Masterly's registry."
  }
}

# The same for registry_token passed from a sensitive object with the mode stated. The input is
# declared sensitive already, so this guards the presence test the token mode is derived from.
run "sensitive_registry_token_plans_in_production_with_key_vault" {
  command = plan

  variables {
    mode                     = "production"
    identity_binding         = "oidc"
    oidc_allowed_issuers     = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience            = "api-client-id"
    oidc_jwks_uri            = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id           = "bff-client-id"
    oidc_client_secret       = "s3cret"
    oidc_authority           = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri        = "https://app.example.com/api/auth/callback"
    license_token            = "eyJ.fake.jwt"
    license_public_jwk       = "{\"kty\":\"EC\"}"
    initial_owner_email      = "owner@example.com"
    enable_key_vault         = true
    enable_redis             = true
    redis_offering           = "cache"
    enable_workers           = true
    api_max_replicas         = 3
    acr_login_server         = null
    registry_credential_mode = "token"
    registry_token = sensitive({
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    })

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = contains(keys(azurerm_key_vault_secret.install), "registry-password")
    error_message = "A sensitive registry_token must still store the pull password in the vault as registry-password."
  }

  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "registry-password") &&
      contains(module.frontend.vault_backed_secret_names, "registry-password") &&
      contains(module.workers[0].vault_backed_secret_names, "registry-password")
    )
    error_message = "A sensitive registry_token must still reach every app as the registry-password Key Vault reference."
  }

  assert {
    condition     = length(azurerm_role_assignment.acr_pull) == 0 && output.image_references.registry_credential_mode == "token"
    error_message = "A sensitive registry_token must still resolve to the token mode and grant no AcrPull."
  }
}

# oidc_tenant_id (MAS-4145): a single-tenant Entra registration needs the tenant id alone; the
# three endpoints and the audience follow from it and the client id.
run "oidc_tenant_id_derives_the_entra_endpoints" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://app.example.com/api/auth/callback"
  }

  assert {
    condition = (
      local.identity_env.MASTERLY_OIDC_ALLOWED_ISSUERS == "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0" &&
      local.identity_env.MASTERLY_OIDC_JWKS_URI == "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/discovery/v2.0/keys" &&
      local.oidc_authority == "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0"
    )
    error_message = "oidc_tenant_id must derive the single-tenant Entra v2.0 issuer, JWKS URI and authority."
  }

  assert {
    condition     = local.identity_env.MASTERLY_OIDC_AUDIENCE == "bff-client-id"
    error_message = "oidc_audience must default to oidc_client_id."
  }
}

# An explicit endpoint or audience always wins over the derived one: a customer who set them
# before oidc_tenant_id existed sees no change.
run "explicit_oidc_inputs_win_over_the_tenant_id" {
  command = plan

  variables {
    identity_binding     = "oidc"
    oidc_tenant_id       = "11111111-2222-3333-4444-555555555555"
    oidc_allowed_issuers = "https://issuer.example.com"
    oidc_jwks_uri        = "https://issuer.example.com/keys"
    oidc_authority       = "https://issuer.example.com/authority"
    oidc_audience        = "api://custom"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
  }

  assert {
    condition = (
      local.identity_env.MASTERLY_OIDC_ALLOWED_ISSUERS == "https://issuer.example.com" &&
      local.identity_env.MASTERLY_OIDC_JWKS_URI == "https://issuer.example.com/keys" &&
      local.oidc_authority == "https://issuer.example.com/authority" &&
      local.identity_env.MASTERLY_OIDC_AUDIENCE == "api://custom"
    )
    error_message = "Explicit oidc_allowed_issuers, oidc_jwks_uri, oidc_authority and oidc_audience must win over oidc_tenant_id."
  }
}

# Neither the tenant id nor the three endpoints: still refused at plan.
run "oidc_without_tenant_or_endpoints_is_rejected" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://app.example.com/api/auth/callback"
  }

  expect_failures = [var.identity_binding]
}

run "oidc_tenant_id_must_be_a_guid" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "contoso.onmicrosoft.com"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://app.example.com/api/auth/callback"
  }

  expect_failures = [var.oidc_tenant_id]
}

# --- The production default (MAS-5130, ADR 0120 §6) ---------------------------------------
#
# A new install in mode = "production" with migrations unset gets the migrate job, so the migrate
# identity is the only Postgres administrator and ca-api's identity is none. A running install is
# never moved by the default: one whose caj-migrate exists keeps "job", one without it is refused
# until it says which it wants, and an explicit "start" plans with a warning. Every other mode keeps
# "start". The lookup (migrate.tf) is overridden per run: the shared mock finds nothing, a new
# install.

run "production_new_install_defaults_to_the_migrate_job" {
  command = plan

  variables {
    mode                           = "production"
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
    api_max_replicas               = 3
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      var.migrations == null &&
      local.recorded_migrations == null &&
      local.migrate_job &&
      length(azurerm_container_app_job.migrate) == 1 &&
      contains(module.api.env_names, "MASTERLY_MIGRATIONS") &&
      contains(module.workers[0].env_names, "MASTERLY_MIGRATIONS")
    )
    error_message = "A new production install with migrations unset must get the migrate job, and both backend apps MASTERLY_MIGRATIONS=job."
  }

  # The new install is on database_auth = "entra" by production's default: the migrate identity is
  # the server's only Entra administrator, ca-api's identity is none, and no Container App runs as
  # the migrate identity.
  assert {
    condition = (
      local.database_entra &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" &&
      !contains(module.api.user_assigned_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.workers[0].user_assigned_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.frontend.user_assigned_identity_ids, module.migrate_identity[0].id) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id])
    )
    error_message = "In production's default no Container App identity may be a Postgres administrator, and the migrate identity must be attached to no Container App."
  }
}

run "production_install_with_its_migrate_job_keeps_job" {
  command = plan

  variables {
    mode                           = "production"
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
    api_max_replicas               = 3
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
  }

  override_data {
    target = data.azurerm_resources.existing_container_apps
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
        name                = "ca-api"
        resource_group_name = "rg-masterly-aca"
        type                = "Microsoft.App/containerApps"
        location            = "swedencentral"
        tags                = {}
      }]
    }
  }

  override_data {
    target = data.azurerm_resources.existing_container_app_jobs
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/jobs/caj-migrate"
        name                = "caj-migrate"
        resource_group_name = "rg-masterly-aca"
        type                = "Microsoft.App/jobs"
        location            = "swedencentral"
        tags                = {}
      }]
    }
  }

  assert {
    condition     = local.recorded_migrations == "job" && local.migrate_job
    error_message = "A running production install whose caj-migrate exists must keep migrations = \"job\" when the input is unset."
  }
}

# The refusal: a running production install without caj-migrate (0.26.0's default) is not moved
# to the job by a default. Another install's ca-api, in another resource group, does not count.
run "production_running_install_at_start_is_refused_without_an_explicit_value" {
  command = plan

  variables {
    mode                           = "production"
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
    api_max_replicas               = 3
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
  }

  override_data {
    target = data.azurerm_resources.existing_container_apps
    values = {
      resources = [
        {
          id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
          name                = "ca-api"
          resource_group_name = "rg-masterly-aca"
          type                = "Microsoft.App/containerApps"
          location            = "swedencentral"
          tags                = {}
        },
      ]
    }
  }

  override_data {
    target = data.azurerm_resources.existing_container_app_jobs
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other-aca/providers/Microsoft.App/jobs/caj-migrate"
        name                = "caj-migrate"
        resource_group_name = "rg-other-aca"
        type                = "Microsoft.App/jobs"
        location            = "swedencentral"
        tags                = {}
      }]
    }
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Stated, "start" plans in production, and the check says what it keeps.
run "production_explicit_start_plans_with_a_warning" {
  command = plan

  variables {
    mode                           = "production"
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
    api_max_replicas               = 3
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
    migrations                     = "start"
  }

  expect_failures = [check.production_migrations_at_start]

  assert {
    condition     = !local.migrate_job && length(data.azurerm_resources.existing_container_apps) == 0 && length(azurerm_container_app_job.migrate) == 0
    error_message = "An explicit migrations = \"start\" must win in production, with no lookup and no migrate job."
  }
}

# Every other mode keeps "start" unset, and never looks.
run "demo_defaults_to_start_without_a_lookup" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = var.migrations == null && local.migrations == "start" && !local.migrate_job && length(data.azurerm_resources.existing_container_apps) == 0 && length(data.azurerm_resources.existing_container_app_jobs) == 0
    error_message = "Outside production an unset migrations must be \"start\", with no lookup."
  }
}

# Not read as unset: coalesce() would skip "", so the validation does not use it.
run "migrations_refuses_an_empty_value" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    migrations            = ""
  }

  expect_failures = [var.migrations]
}
