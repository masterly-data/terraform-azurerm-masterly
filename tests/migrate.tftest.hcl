# Migrate job regressions share a valid production posture. The install-context and
# demo-mode guard regressions are in migrate_job.tftest.hcl; image drift applies are separate.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"
}
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "before" }
  }
}
mock_provider "azapi" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  # A production install needs a vault deployer path and an alert destination.
  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  mode                           = "production"
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
  redis_offering                 = "managed"
  enable_workers                 = true
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  database_auth                  = "password"
  migrations                     = "job"
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
}

run "migrate_job_follows_its_schedule_input" {
  command = plan

  variables {
    migrate_job_schedule = "0 * * * *"
  }

  assert {
    condition     = azurerm_container_app_job.migrate[0].schedule_trigger_config[0].cron_expression == "0 * * * *"
    error_message = "The migrate job's cron expression must be migrate_job_schedule."
  }

  assert {
    condition     = length(azurerm_role_assignment.kv_byo_database_reader_migrate) == 0 && !contains(keys(local.migrate_env), "MASTERLY_ORG_NAME")
    error_message = "Unset runtime secret names grant no reads; an unset org_name must be omitted."
  }
}

run "migrate_byo_database_secrets_refuse_paths" {
  command = plan
  variables {
    migrate_byo_database_secret_names = ["secrets/environment-a-connection"]
  }
  expect_failures = [var.migrate_byo_database_secret_names]
}

run "migrate_byo_database_secrets_refuse_install_secrets" {
  command = plan
  variables {
    migrate_byo_database_secret_names = ["INSTALL-license-token"]
  }
  expect_failures = [var.migrate_byo_database_secret_names]
}

# The start at apply. The action is replaced through terraform_data.migrate_image, whose input is
# the resolved api image, and ca-api and ca-workers name it in depends_on (main.tf, workers.tf):
# `terraform test` cannot read depends_on or replace_triggered_by, so these assert what the plan
# shows and `terraform graph` shows the edges (see the pull request).
run "migrate_job_is_started_at_apply" {
  command = plan

  assert {
    condition = (
      azapi_resource_action.migrate_start[0].type == "Microsoft.App/jobs@2025-01-01" &&
      azapi_resource_action.migrate_start[0].action == "start" &&
      azapi_resource_action.migrate_start[0].method == "POST" &&
      terraform_data.migrate_image[0].input == "masterly.azurecr.io/release/api:v0.0.0"
    )
    error_message = "An azapi start action must start the migrate job, keyed on the resolved api image."
  }
}

run "migrate_job_start_follows_the_api_image" {
  command = plan

  variables {
    api_image = "masterly.azurecr.io/release/api:v0.0.1"
  }

  assert {
    condition = (
      terraform_data.migrate_image[0].input == "masterly.azurecr.io/release/api:v0.0.1" &&
      azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.1"
    )
    error_message = "A new api_image must reach the migrate job and the input that replaces its start action."
  }
}

# Threat: the most privileged database principal holds image pull and read on its own secrets,
# and nothing else; no Container App runs as it.
run "migrate_identity_holds_acr_pull_and_its_own_secrets_only" {
  command = plan

  variables {
    acr_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_service_bus = true
    servicebus_sku     = "Standard"
    email_acs_enabled  = true
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      !contains(module.api.user_assigned_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.workers[0].user_assigned_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.frontend.user_assigned_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.api.secret_ref_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.workers[0].secret_ref_identity_ids, module.migrate_identity[0].id) &&
      !contains(module.frontend.secret_ref_identity_ids, module.migrate_identity[0].id)
    )
    error_message = "No Container App may run as, or resolve a secret with, the migrate job's identity."
  }

  assert {
    condition = (
      azurerm_role_assignment.acr_pull_migrate[0].principal_id == module.migrate_identity[0].principal_id &&
      azurerm_role_assignment.acr_pull_migrate[0].role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull_migrate[0].scope == var.acr_id
    )
    error_message = "acr_id must grant AcrPull to the migrate job's identity, on the registry."
  }

  # Read on each of its own secrets, never the vault, never Officer.
  assert {
    condition = (
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"]) &&
      alltrue([
        for k, ra in azurerm_role_assignment.kv_secrets_user_migrate :
        ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.migrate_identity[0].principal_id
      ]) &&
      alltrue([for name, ref in local.migrate_vault_secret_refs : ref.identity_id == module.migrate_identity[0].id])
    )
    error_message = "The migrate job's identity may hold Key Vault Secrets User on its own secrets alone."
  }

  # Every other grant in the install goes to another principal.
  assert {
    condition = alltrue([
      for principal in concat(
        [
          azurerm_role_assignment.kv_app_secrets[0].principal_id,
          azurerm_role_assignment.kv_crypto_officer[0].principal_id,
          azurerm_role_assignment.sb_sender[0].principal_id,
          azurerm_role_assignment.acs_email_sender[0].principal_id,
          azurerm_role_assignment.acr_pull[0].principal_id,
          azurerm_role_assignment.acr_pull_frontend[0].principal_id,
          azurerm_role_assignment.kv_app_secrets_workers[0].principal_id,
          azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id,
          azurerm_role_assignment.sb_sender_workers[0].principal_id,
          azurerm_role_assignment.sb_receiver_workers[0].principal_id,
          azurerm_role_assignment.sb_scaler_workers[0].principal_id,
          azurerm_role_assignment.acs_email_sender_workers[0].principal_id,
          azurerm_role_assignment.acr_pull_workers[0].principal_id,
        ],
        [for ra in azurerm_role_assignment.kv_secrets_user_frontend : ra.principal_id],
        [for ra in azurerm_role_assignment.kv_secrets_officer_deployer : ra.principal_id],
        [for ra in azurerm_role_assignment.kv_secrets_reader : ra.principal_id],
      ) : principal != module.migrate_identity[0].principal_id
    ])
    error_message = "No vault-scope, Officer, Crypto, Service Bus, ACS or other app's grant may reach the migrate job's identity."
  }

  # The job's DSN is in the vault under its own name, and in no app's secret set.
  assert {
    condition = (
      azurerm_key_vault_secret.install["migrate-database-url"].name == "install-migrate-database-url" &&
      !contains(module.api.vault_backed_secret_names, "migrate-database-url") &&
      !contains(module.workers[0].vault_backed_secret_names, "migrate-database-url") &&
      !contains(module.frontend.vault_backed_secret_names, "migrate-database-url") &&
      length(local.migrate_value_secrets) == 0
    )
    error_message = "With the vault on, the migrate job's DSN must be a vault secret of its own, carried by no Container App."
  }
}

# With Redis on Entra, its access policy belongs to the apps' identity, never the job's.
run "migrate_identity_holds_no_redis_access" {
  command = plan

  variables {
    redis_auth = "entra"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  assert {
    condition = alltrue(concat(
      [for a in azurerm_managed_redis_access_policy_assignment.apps : a.object_id != module.migrate_identity[0].principal_id],
      [for a in azurerm_redis_cache_access_policy_assignment.apps : a.object_id != module.migrate_identity[0].principal_id],
    )) && length(azurerm_managed_redis_access_policy_assignment.apps) + length(azurerm_redis_cache_access_policy_assignment.apps) == 1
    error_message = "The Redis access policy must go to the apps' identity, never the migrate job's."
  }

  assert {
    condition     = !contains(keys(local.migrate_env), "MASTERLY_REDIS_AUTH") && tolist(local.migrate_secret_names) == tolist(["migrate-database-url"])
    error_message = "The migrate job carries no Redis setting or URL."
  }
}

run "migrate_identity_is_the_only_entra_administrator" {
  command = plan

  variables {
    database_auth = "entra"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  # Threat: a Container App's identity is a Postgres administrator. With "job" the migrate
  # identity is the server's only Entra administrator (ADR 0120); `apps` is gone.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_name == "id-masterly-migrate" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_type == "ServicePrincipal" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == module.migrate_identity[0].principal_id
    )
    error_message = "With migrations = \"job\" on entra the server must have one Entra administrator, id-<prefix>-migrate, and none for id-<prefix>-apps."
  }

  assert {
    condition = alltrue([
      for admin in concat(
        azurerm_postgresql_flexible_server_active_directory_administrator.apps,
        azurerm_postgresql_flexible_server_active_directory_administrator.migrate,
        ) : !contains([
          module.apps_identity.principal_id,
          module.workers_identity[0].principal_id,
          module.frontend_identity.principal_id,
      ], admin.object_id)
    ])
    error_message = "No Container App identity (apps, workers, frontend) may be a Postgres Entra administrator with migrations = \"job\"."
  }

  # The job connects as its own role with its own token; the apps keep theirs.
  assert {
    condition = (
      local.migrate_database_role == "id-masterly-migrate" &&
      startswith(nonsensitive(local.migrate_database_url), "postgresql+asyncpg://id-masterly-migrate@") &&
      startswith(nonsensitive(local.database_url), "postgresql+asyncpg://id-masterly-apps@") &&
      local.migrate_env["MASTERLY_DATABASE_AUTH"] == "entra" &&
      local.migrate_env["AZURE_CLIENT_ID"] == module.migrate_identity[0].client_id &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "AZURE_CLIENT_ID"]) == "dddddddd-dddd-dddd-dddd-cccccccccccc" &&
      local.api_env["AZURE_CLIENT_ID"] == module.apps_identity.client_id
    )
    error_message = "On entra the migrate job's URL must name id-<prefix>-migrate and its AZURE_CLIENT_ID must be the migrate identity's client id."
  }
}

run "migrate_job_gets_the_direct_url_with_pgbouncer" {
  command = plan

  variables {
    postgres_pgbouncer = true
  }

  assert {
    condition = (
      sort(keys(local.migrate_env_secret_refs)) == tolist(["MASTERLY_DATABASE_DIRECT_URL", "MASTERLY_DATABASE_URL"]) &&
      local.migrate_env_secret_refs["MASTERLY_DATABASE_URL"] == "migrate-database-url" &&
      local.migrate_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "migrate-database-direct-url" &&
      tolist(local.migrate_secret_names) == tolist(["migrate-database-url", "migrate-database-direct-url"]) &&
      local.migrate_env["MASTERLY_DATABASE_POOLER"] == "transaction" &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.secret_name if e.name == "MASTERLY_DATABASE_DIRECT_URL"]) == "migrate-database-direct-url" &&
      local.database_pooler_port == "6432" &&
      local.database_direct_port == "5432" &&
      length(module.postgres_connection_urls_migrate) == 1
    )
    error_message = "With postgres_pgbouncer the migrate job must carry MASTERLY_DATABASE_URL (6432) and MASTERLY_DATABASE_DIRECT_URL (5432)."
  }
}

run "external_database_url_alone_reaches_the_migrate_job_too" {
  command = plan

  variables {
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      nonsensitive(local.migrate_database_url) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require" &&
      nonsensitive(local.database_url) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require" &&
      azurerm_key_vault_secret.install["migrate-database-url"].value == var.external_database_url &&
      length(local.migrate_value_secrets) == 0 &&
      toset(keys(local.migrate_vault_secret_refs)) == toset(["migrate-database-url"]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"]) &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 0
    )
    error_message = "With external_database_url alone the migrate job must use the same DSN as the apps."
  }

  assert {
    condition = (
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      sort(keys(local.backend_env_secret_refs)) == tolist(["MASTERLY_DATABASE_URL", "MASTERLY_LICENSE_TOKEN", "MASTERLY_REDIS_URL", "MASTERLY_SESSION_SECRET"]) &&
      sort(keys(local.api_env_secret_refs)) == tolist(["MASTERLY_BFF_SHARED_SECRET", "MASTERLY_DATABASE_URL", "MASTERLY_LICENSE_TOKEN", "MASTERLY_REDIS_URL", "MASTERLY_SESSION_SECRET"]) &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url"
    )
    error_message = "With external_database_url alone, ca-api and ca-workers must carry the secrets and env they carry on main."
  }
}

run "external_database_admin_url_refused_without_external_database_url" {
  command = plan

  variables {
    external_database_admin_url = "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.external_database_admin_url]
}

# Job mode requires production, whose durable secret store must be enabled.
run "migrate_job_refuses_production_without_the_vault" {
  command = plan

  variables {
    enable_key_vault            = false
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    external_database_admin_url = "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# Token mode with a CA bundle: no AcrPull grant, secret-scoped vault references, and the
# same CA mount as the apps.
run "migrate_job_pulls_with_the_token_and_trusts_the_ca_bundle" {
  command = plan

  variables {
    acr_login_server = null # the file-wide "" means no registry block at all
    acr_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
    ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = (
      length(azurerm_role_assignment.acr_pull_migrate) == 0 &&
      azurerm_container_app_job.migrate[0].registry[0].username == "00000000-0000-0000-0000-000000000000" &&
      azurerm_container_app_job.migrate[0].registry[0].password_secret_name == "registry-password" &&
      azurerm_container_app_job.migrate[0].registry[0].identity == null &&
      sort(keys(local.migrate_vault_secret_refs)) == tolist(["ca-bundle-pem", "migrate-database-url", "registry-password"]) &&
      length(local.migrate_value_secrets) == 0
    )
    error_message = "In the token mode the migrate job must pull with the credential, from its own registry-password secret, and get no AcrPull grant."
  }

  assert {
    condition = (
      local.migrate_env["SSL_CERT_FILE"] == "/mnt/secrets/ca-bundle/ca-bundle.pem" &&
      length(azurerm_container_app_job.migrate[0].template[0].volume) == 1 &&
      length(azurerm_container_app_job.migrate[0].template[0].init_container) == 1 &&
      azurerm_container_app_job.migrate[0].template[0].init_container[0].image == azurerm_container_app_job.migrate[0].template[0].container[0].image &&
      azurerm_container_app_job.migrate[0].template[0].container[0].volume_mounts[0].path == "/mnt/secrets/ca-bundle"
    )
    error_message = "With ca_bundle_pem the migrate job must mount the CA bundle at the path SSL_CERT_FILE names, as the apps do."
  }
}

# The app roles on "entra": two stable Postgres identifiers, each bound to its own identity's
# object id. ca-api stays on the apps identity and ca-workers runs as id-<prefix>-workers, each
# signing in as its own role. Every grant is on, so the identity checks cover them all; the
# grants' computed scopes are compared at apply (tests/workers_identity.tftest.hcl).
run "migrate_app_roles_on_entra_name_their_identities" {
  command = plan

  variables {
    database_auth      = "entra"
    redis_auth         = "entra"
    acr_login_server   = null # the file-wide "" means no registry block, so no pull identity
    acr_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_service_bus = true
    servicebus_sku     = "Standard"
    email_acs_enabled  = true
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  # Names the backend accepts, distinct from each other and from both admin roles.
  assert {
    condition = (
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE"] == "masterly_api" &&
      local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE"] == "masterly_workers" &&
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE"] != local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE"] &&
      local.migrate_database_role == "id-masterly-migrate" &&
      alltrue([
        for role in [local.migrate_env["MASTERLY_MIGRATE_API_ROLE"], local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE"]] :
        can(regex("^[a-z_][a-z0-9_]{0,62}$", role)) && role != "masterly_admin" && role != local.migrate_database_role
      ])
    )
    error_message = "The app roles must be masterly_api and masterly_workers: valid Postgres identifiers, distinct, and neither masterly_admin nor the migrate role."
  }

  assert {
    condition = (
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE_OBJECT_ID"] == module.apps_identity.principal_id &&
      local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE_OBJECT_ID"] == module.workers_identity[0].principal_id &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MIGRATE_API_ROLE_OBJECT_ID"]) == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MIGRATE_WORKERS_ROLE_OBJECT_ID"]) == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      module.workers_identity[0].name == "id-masterly-workers" &&
      length([for k in keys(local.migrate_env) : k if endswith(k, "_PASSWORD_REF")]) == 0 &&
      !contains(keys(local.migrate_env_secret_refs), "MASTERLY_MIGRATE_API_ROLE") &&
      length(random_password.migrate_api_role) + length(random_password.migrate_workers_role) +
      length(azurerm_key_vault_secret.migrate_api_role_password) + length(azurerm_key_vault_secret.migrate_workers_role_password) +
      length(azurerm_role_assignment.kv_secrets_user_migrate_api_role_password) + length(azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password) == 0
    )
    error_message = "On entra the job must get the apps identity's and id-<prefix>-workers' object ids, and no password, vault secret, grant or password ref."
  }

  # ca-workers runs, pulls, scales and resolves its secrets as id-<prefix>-workers alone; ca-api
  # as the apps identity alone. Neither names the other's identity, nor does the frontend or job.
  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      length(module.workers[0].scale.custom_scale_rules) == 1 &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.registry.identity == module.apps_identity.id &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      module.frontend.user_assigned_identity_ids == tolist([module.frontend_identity.id]) &&
      !contains(module.frontend.secret_ref_identity_ids, module.workers_identity[0].id) &&
      !contains(azurerm_container_app_job.migrate[0].identity[0].identity_ids, module.workers_identity[0].id) &&
      alltrue([for name, ref in local.migrate_vault_secret_refs : ref.identity_id != module.workers_identity[0].id])
    )
    error_message = "ca-workers must run, pull, scale and resolve its secrets as id-<prefix>-workers alone, and ca-api as the apps identity alone, each with its own AZURE_CLIENT_ID."
  }

  # The rest of the env is the api's: only AZURE_CLIENT_ID differs (workers_env, main.tf).
  assert {
    condition = (
      toset(keys(local.workers_env)) == toset(keys(local.api_env)) &&
      module.workers[0].env_names == module.api.env_names &&
      strcontains(regex("(?s)\\n  workers_env = merge\\((.*?)\\n  \\)", file("${path.module}/main.tf"))[0], "local.api_env,") &&
      length(regexall("AZURE_CLIENT_ID", regex("(?s)\\n  workers_env = merge\\((.*?)\\n  \\)", file("${path.module}/main.tf"))[0])) == 1
    )
    error_message = "ca-workers' env must be the api's, with its own AZURE_CLIENT_ID the only difference."
  }

  # Each app signs in as its own DML role with no password; neither is an administrator role.
  assert {
    condition = (
      startswith(nonsensitive(local.api_database_url), "postgresql+asyncpg://masterly_api@") &&
      startswith(nonsensitive(local.workers_database_url), "postgresql+asyncpg://masterly_workers@") &&
      local.migrate_api_role != local.database_role && local.migrate_workers_role != local.database_role &&
      local.database_role == local.database_entra_role &&
      !contains(["masterly_admin", local.database_entra_role], local.migrate_api_role) &&
      !contains(["masterly_admin", local.database_entra_role], local.migrate_workers_role) &&
      length(module.postgres_connection_urls_api) == 1 && length(module.postgres_connection_urls_workers) == 1
    )
    error_message = "On entra ca-api's URL must name masterly_api and ca-workers' masterly_workers, with no password, and neither may be masterly_admin or the apps identity's administrator role."
  }

  # Each app reads its own DSN secret, from the vault, and neither the other's nor the shared one.
  # ca-api keeps only the shared one's definition, as a reference no env names (below).
  assert {
    condition = (
      module.api.vault_backed_secret_names == tolist(["api-database-url", "bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["license-token", "redis-url", "session-secret", "workers-database-url"]) &&
      module.frontend.vault_backed_secret_names == tolist(["bff-shared-secret", "oidc-client-secret"]) &&
      length(module.api.value_secret_names) + length(module.workers[0].value_secret_names) + length(module.frontend.value_secret_names) == 0 &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "api-database-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "workers-database-url" &&
      !contains(keys(local.api_env_secret_refs), "MASTERLY_DATABASE_DIRECT_URL") &&
      !contains(keys(local.backend_env_secret_refs), "MASTERLY_DATABASE_DIRECT_URL") &&
      !anytrue([for name in concat(local.api_secret_names, values(local.api_env_secret_refs)) : contains(["workers-database-url", "workers-database-direct-url", "database-url", "database-direct-url"], name)]) &&
      !anytrue([for name in concat(local.backend_secret_names, values(local.backend_env_secret_refs)) : contains(["api-database-url", "api-database-direct-url", "database-url", "database-direct-url"], name)]) &&
      !anytrue([for name in concat(local.frontend_secret_names, local.migrate_secret_names) : can(regex("^(api-|workers-)?database-(direct-)?url$", name))]) &&
      contains(keys(azurerm_key_vault_secret.install), "database-url") &&
      local.database_role == "id-masterly-apps" &&
      !anytrue([for name in concat(module.api.env_names, module.workers[0].env_names, module.frontend.env_names) : startswith(name, "MASTERLY_MIGRATE_")])
    )
    error_message = "With the app roles each backend app must carry its own DSN secret alone, the frontend and the job neither, and the shared database-url must stay in the vault, named by no app's secret list or env."
  }

  # ACA secrets belong to the app, not to a revision: ca-api's revision from before the upgrade
  # serves, and may restart, until the new one is ready, so the shared DSN's definition stays on
  # ca-api exactly as it was (its vault secret, resolved as id-<prefix>-apps). No env names it,
  # and ca-workers, whose identity changes, keeps none.
  assert {
    condition = (
      local.api_retained_secret_names == tolist(["database-url"]) &&
      local.api_vault_secret_refs["database-url"].identity_id == module.apps_identity.id &&
      !contains(values(local.api_env_secret_refs), "database-url") &&
      !contains(keys(local.backend_vault_secret_refs), "database-url")
    )
    error_message = "ca-api must keep the shared database-url's secret definition, unchanged and named by no env, so its pre-upgrade revision still resolves it; ca-workers must keep none."
  }

  # id-<prefix>-workers holds each backend grant ca-workers needs, and nothing names it as
  # administrator.
  assert {
    condition = (
      # The app secrets role's id is computed, so at plan the grant is checked by count and
      # principal here, and by role in app_secrets_role.tftest.hcl.
      length(azurerm_role_assignment.kv_app_secrets_workers) == 1 && length(azurerm_role_definition.app_secrets) == 1 &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].role_definition_name == "Key Vault Crypto Officer" &&
      azurerm_role_assignment.acr_pull_workers[0].role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.acs_email_sender_workers[0].role_definition_name == "Communication and Email Service Owner" &&
      azurerm_role_assignment.sb_sender_workers[0].role_definition_name == "Azure Service Bus Data Sender" &&
      azurerm_role_assignment.sb_receiver_workers[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner" &&
      alltrue([
        for ra in [
          azurerm_role_assignment.kv_app_secrets_workers[0], azurerm_role_assignment.kv_crypto_officer_workers[0],
          azurerm_role_assignment.acr_pull_workers[0], azurerm_role_assignment.acs_email_sender_workers[0],
          azurerm_role_assignment.sb_sender_workers[0], azurerm_role_assignment.sb_receiver_workers[0],
          azurerm_role_assignment.sb_scaler_workers[0],
        ] : ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ]) &&
      length(azurerm_managed_redis_access_policy_assignment.workers) == 1 &&
      azurerm_managed_redis_access_policy_assignment.workers[0].object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1 &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id != module.workers_identity[0].principal_id &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "id-<prefix>-workers must hold the Key Vault, AcrPull, ACS, Service Bus and Redis grants ca-workers needs, and be no Postgres administrator; the apps identity must be none either."
  }

  # Threat, the public front door and the schema owner: no new grant names either of them, and
  # the shared grants stay on the apps identity. Its Receiver, scaler grant and Entra
  # administrator are gone: ca-workers holds the first two as its own identity.
  assert {
    condition = alltrue(concat(
      [
        for principal in [
          azurerm_role_assignment.kv_app_secrets[0].principal_id, azurerm_role_assignment.kv_crypto_officer[0].principal_id,
          azurerm_role_assignment.sb_sender[0].principal_id, azurerm_role_assignment.acs_email_sender[0].principal_id,
          azurerm_role_assignment.acr_pull[0].principal_id, azurerm_managed_redis_access_policy_assignment.apps[0].object_id,
        ] : principal == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      ],
      [
        length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) +
        length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0
      ],
      [
        for principal in [
          azurerm_role_assignment.kv_app_secrets_workers[0].principal_id, azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id,
          azurerm_role_assignment.sb_sender_workers[0].principal_id, azurerm_role_assignment.sb_receiver_workers[0].principal_id,
          azurerm_role_assignment.sb_scaler_workers[0].principal_id, azurerm_role_assignment.acs_email_sender_workers[0].principal_id,
          azurerm_role_assignment.acr_pull_workers[0].principal_id, azurerm_managed_redis_access_policy_assignment.workers[0].object_id,
        ] : !contains([module.frontend_identity.principal_id, module.migrate_identity[0].principal_id, module.apps_identity.principal_id], principal)
      ],
      [azurerm_role_assignment.acr_pull_frontend[0].principal_id == module.frontend_identity.principal_id],
      [for ra in azurerm_role_assignment.kv_secrets_user_frontend : ra.principal_id == module.frontend_identity.principal_id && ra.role_definition_name == "Key Vault Secrets User"],
      [toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(local.frontend_secret_names)],
      [azurerm_role_assignment.acr_pull_migrate[0].principal_id == module.migrate_identity[0].principal_id],
      [toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"])],
      [for ra in azurerm_role_assignment.kv_secrets_user_migrate : ra.principal_id == module.migrate_identity[0].principal_id && ra.role_definition_name == "Key Vault Secrets User"],
    ))
    error_message = "The shared grants must stay on the apps identity, without its Receiver, scaler grant or Entra administrator; no workers grant may name the frontend, migrate or apps identity; the frontend and migrate grants must be as on main."
  }
}

# Threat, ca-api's identity gains a role it should not (ADR 0120 §6). With migrations = "job" and
# every grant on, every azurerm_role_assignment in the module is listed here by address (the
# 23-block count in workers_identity.tftest.hcl keeps the list complete), and those on the apps
# principal hold exactly these roles, plus one Redis access policy and no Postgres administrator.
run "apps_identity_holds_only_its_own_roles_with_job" {
  command = plan

  variables {
    database_auth      = "entra"
    redis_auth         = "entra"
    acr_login_server   = null
    acr_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_service_bus = true
    servicebus_sku     = "Standard"
    email_acs_enabled  = true
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = sort([
      for ra in concat(
        azurerm_role_assignment.acr_pull,
        azurerm_role_assignment.acr_pull_frontend,
        azurerm_role_assignment.acr_pull_migrate,
        azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.sb_sender,
        azurerm_role_assignment.sb_receiver,
        azurerm_role_assignment.sb_sender_workers,
        azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.kv_crypto_officer,
        azurerm_role_assignment.kv_crypto_officer_workers,
        values(azurerm_role_assignment.kv_secrets_officer_deployer),
        values(azurerm_role_assignment.kv_secrets_user_frontend),
        values(azurerm_role_assignment.kv_secrets_user_migrate),
        azurerm_role_assignment.kv_secrets_user_migrate_api_role_password,
        azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
        values(azurerm_role_assignment.kv_byo_database_reader_migrate),
        values(azurerm_role_assignment.kv_secrets_reader),
        azurerm_role_assignment.acs_email_sender,
        azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.sb_scaler,
        azurerm_role_assignment.sb_scaler_workers,
      ) : ra.role_definition_name if ra.principal_id == module.apps_identity.principal_id
      ]) == sort([
      "AcrPull",
      "Azure Service Bus Data Sender",
      "Communication and Email Service Owner",
      "Key Vault Crypto Officer",
    ])
    error_message = "With migrations = \"job\" the apps identity (ca-api) may hold AcrPull, Key Vault Crypto Officer, Service Bus Data Sender and the ACS role by name, and no other built-in role assignment."
  }

  # The two app secrets grants name their role by id, which is computed at plan, so they are
  # kept out of the list above and counted here: exactly one of them is the apps identity's.
  # What the role holds is asserted in app_secrets_role.tftest.hcl.
  assert {
    condition = (
      length([
        for ra in concat(azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers) :
        ra if ra.principal_id == module.apps_identity.principal_id
      ]) == 1 &&
      azurerm_role_assignment.kv_app_secrets[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "With migrations = \"job\" the apps identity (ca-api) must hold the app secrets role once, through kv_app_secrets."
  }

  assert {
    condition = (
      length(azurerm_managed_redis_access_policy_assignment.apps) + length(azurerm_redis_cache_access_policy_assignment.apps) == 1 &&
      alltrue([for a in azurerm_managed_redis_access_policy_assignment.apps : a.object_id == module.apps_identity.principal_id]) &&
      alltrue([for a in azurerm_redis_cache_access_policy_assignment.apps : a.object_id == module.apps_identity.principal_id]) &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0
    )
    error_message = "With migrations = \"job\" the apps identity must hold one Redis access policy and be no Postgres Entra administrator."
  }
}

# With postgres_pgbouncer each app also gets its own direct URL, under its own name.
run "migrate_app_roles_on_entra_get_their_own_direct_urls_with_pgbouncer" {
  command = plan

  variables {
    database_auth      = "entra"
    postgres_pgbouncer = true
  }

  assert {
    condition = (
      startswith(nonsensitive(local.api_database_url), "postgresql+asyncpg://masterly_api@") &&
      startswith(nonsensitive(local.api_database_direct_url), "postgresql+asyncpg://masterly_api@") &&
      startswith(nonsensitive(local.workers_database_url), "postgresql+asyncpg://masterly_workers@") &&
      startswith(nonsensitive(local.workers_database_direct_url), "postgresql+asyncpg://masterly_workers@") &&
      module.api.vault_backed_secret_names == tolist(["api-database-direct-url", "api-database-url", "bff-shared-secret", "database-direct-url", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["license-token", "redis-url", "session-secret", "workers-database-direct-url", "workers-database-url"]) &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "api-database-url" &&
      local.api_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "api-database-direct-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "workers-database-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "workers-database-direct-url" &&
      alltrue([for name in ["database-url", "database-direct-url", "api-database-url", "api-database-direct-url", "workers-database-url", "workers-database-direct-url"] : contains(keys(azurerm_key_vault_secret.install), name)]) &&
      !anytrue([for name in concat(local.frontend_secret_names, local.migrate_secret_names) : can(regex("^(api-|workers-)?database-(direct-)?url$", name))])
    )
    error_message = "With postgres_pgbouncer each backend app must get its own pooled and direct URLs as its own role, under its own secret names; the shared ones stay in the vault."
  }

  # Both compositions take the pooler and direct ports the shared one does.
  assert {
    condition = alltrue([
      for block in ["postgres_connection_urls_api", "postgres_connection_urls_workers"] :
      strcontains(regex("(?s)module \"${block}\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0], "pooler_port = local.database_pooler_port") &&
      strcontains(regex("(?s)module \"${block}\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0], "direct_port = local.database_direct_port")
    ])
    error_message = "Each app's URLs must use the shared pooler (6432 with PgBouncer) and direct (5432) ports."
  }
}

# When the queue scaler is off (no Service Bus), id-<prefix>-workers holds no Service Bus role.
run "migrate_app_roles_workers_hold_no_queue_role_without_service_bus" {
  command = plan

  variables {
    enable_service_bus = false
  }

  assert {
    condition = (
      !local.workers_scale_on_queue && length(module.workers_identity) == 1 &&
      length(azurerm_role_assignment.sb_scaler_workers) + length(azurerm_role_assignment.sb_sender_workers) + length(azurerm_role_assignment.sb_receiver_workers) == 0 &&
      length(module.workers[0].scale.custom_scale_rules) == 0 &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.acs_email_sender_workers) == 0 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) == 1 && length(azurerm_role_assignment.kv_crypto_officer_workers) == 1
    )
    error_message = "Without Service Bus, id-<prefix>-workers must hold no Service Bus role, and without acr_id or ACS no AcrPull or ACS role."
  }
}

# The app roles on "password": one generated password each, held in a vault secret of its own and
# handed to the job by name. The job reads each with its own identity, on that secret alone.
run "migrate_app_roles_on_password_read_their_vault_secrets" {
  command = plan

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(random_password.migrate_api_role) == 1 && length(random_password.migrate_workers_role) == 1 &&
      alltrue([for p in [random_password.migrate_api_role[0], random_password.migrate_workers_role[0]] : p.length == 32 && !p.special]) &&
      length(azurerm_key_vault_secret.migrate_api_role_password) == 1 && length(azurerm_key_vault_secret.migrate_workers_role_password) == 1 &&
      azurerm_key_vault_secret.migrate_api_role_password[0].name == "install-migrate-api-role-password" &&
      azurerm_key_vault_secret.migrate_workers_role_password[0].name == "install-migrate-workers-role-password"
    )
    error_message = "On password each app role must get a 32-character generated password, held in its own vault secret."
  }

  assert {
    condition = (
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE"] == "masterly_api" &&
      local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE"] == "masterly_workers" &&
      local.migrate_database_role == "masterly_admin" &&
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF"] == azurerm_key_vault_secret.migrate_api_role_password[0].name &&
      local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF"] == azurerm_key_vault_secret.migrate_workers_role_password[0].name &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF"]) == "install-migrate-api-role-password" &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF"]) == "install-migrate-workers-role-password" &&
      length([for k in keys(local.migrate_env) : k if endswith(k, "_OBJECT_ID")]) == 0 &&
      length([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e if startswith(e.name, "MASTERLY_MIGRATE_") && e.secret_name != null]) == 0
    )
    error_message = "On password the job's plain env must name each app role's vault secret, with no object id and no ACA secret reference."
  }

  # Threat: privilege creep. Two new grants for the migrate identity, Secrets User, one per secret.
  # Their scope (the secret's ARM id) is known only at apply: migrate_app_role_secrets_are_read_one_by_one.
  assert {
    condition = (
      length(azurerm_role_assignment.kv_secrets_user_migrate_api_role_password) == 1 &&
      length(azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password) == 1 &&
      alltrue([
        for ra in [azurerm_role_assignment.kv_secrets_user_migrate_api_role_password[0], azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password[0]] :
        ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.migrate_identity[0].principal_id
      ]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"]) &&
      length(azurerm_role_assignment.kv_byo_database_reader_migrate) == 0 &&
      length(azurerm_role_assignment.acr_pull_migrate) == 0
    )
    error_message = "On password the migrate identity must gain exactly one Key Vault Secrets User grant per app-role secret, and nothing else."
  }

  # The job waits for both grants before its first execution reads the secrets. `terraform test`
  # cannot read depends_on, so this reads the job's own configuration.
  assert {
    condition = alltrue([
      for ref in ["azurerm_role_assignment.kv_secrets_user_migrate_api_role_password", "azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password"] :
      strcontains(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)resource \"azurerm_container_app_job\" \"migrate\" \\{(.*?)\\n\\}", file("${path.module}/migrate.tf"))[0])[0], ref)
    ])
    error_message = "caj-migrate must depend on both app-role password grants."
  }

  # Threat: password exposure. The secrets are no ACA secret on the job or any app.
  assert {
    condition = (
      tolist(local.migrate_secret_names) == tolist(["migrate-database-url"]) &&
      tolist(local.migrate_vault_secret_names) == tolist(["migrate-database-url"]) &&
      sort([for s in azurerm_container_app_job.migrate[0].secret : s.name]) == tolist(["migrate-database-url"]) &&
      length(local.migrate_value_secrets) == 0 &&
      !anytrue([
        for name in concat(
          module.api.vault_backed_secret_names, module.workers[0].vault_backed_secret_names, module.frontend.vault_backed_secret_names,
          module.api.value_secret_names, module.workers[0].value_secret_names, module.frontend.value_secret_names,
          keys(azurerm_key_vault_secret.install), output.vault_backed_secret_names,
        ) : strcontains(name, "role-password")
      ])
    )
    error_message = "The app-role passwords must be no Container App or job secret, by value or by Key Vault reference, and outside the install secret set."
  }

  # The passwords are read in three places: their vault secrets, and each app's own URL
  # composition, each reading its own role's password alone. No env, secret or output reads them.
  assert {
    condition = (
      length(regexall("random_password\\.migrate_(api|workers)_role", file("${path.module}/keyvault.tf"))) == 2 &&
      length(regexall("random_password\\.migrate_(api|workers)_role", file("${path.module}/main.tf"))) == 2 &&
      length(regexall("random_password\\.migrate_api_role", regex("(?s)module \"postgres_connection_urls_api\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0])) == 1 &&
      length(regexall("random_password\\.migrate_workers_role", regex("(?s)module \"postgres_connection_urls_api\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0])) == 0 &&
      length(regexall("random_password\\.migrate_workers_role", regex("(?s)module \"postgres_connection_urls_workers\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0])) == 1 &&
      length(regexall("random_password\\.migrate_api_role", regex("(?s)module \"postgres_connection_urls_workers\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0])) == 0 &&
      alltrue([
        for f in fileset(path.module, "*.tf") :
        length(regexall("random_password\\.migrate_(api|workers)_role", file("${path.module}/${f}"))) == 0 if !contains(["keyvault.tf", "main.tf"], f)
      ]) &&
      # No output names a password, an app's URL or its composition.
      alltrue(flatten([
        for f in fileset(path.module, "*.tf") : [
          for m in regexall("(?s)\\noutput \"[^\"]+\" \\{(.*?)\\n\\}", file("${path.module}/${f}")) :
          length(regexall("random_password\\.migrate_|(api|workers)_database_(direct_)?url|postgres_connection_urls_(api|workers)", m[0])) == 0
        ]
      ]))
    )
    error_message = "Only the two app-role vault secrets and each app's own URL composition may read the app-role passwords, and no output may name them."
  }

  # ca-workers runs as id-<prefix>-workers; each app reads its own URL, as its own role, with that
  # role's password, from the vault alone.
  assert {
    condition = (
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.frontend.user_assigned_identity_ids == tolist([module.frontend_identity.id]) &&
      module.api.vault_backed_secret_names == tolist(["api-database-url", "bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["license-token", "redis-url", "session-secret", "workers-database-url"]) &&
      module.frontend.vault_backed_secret_names == tolist(["bff-shared-secret", "oidc-client-secret"]) &&
      length(module.api.value_secret_names) + length(module.workers[0].value_secret_names) + length(module.frontend.value_secret_names) == 0 &&
      length(module.postgres_connection_urls_api) == 1 && length(module.postgres_connection_urls_workers) == 1 &&
      local.database_role == "masterly_admin" &&
      !anytrue([for name in concat(module.api.env_names, module.workers[0].env_names, module.frontend.env_names) : startswith(name, "MASTERLY_MIGRATE_")])
    )
    error_message = "On password, ca-workers must run as id-<prefix>-workers and each backend app must read its own URL, as its own role, from the vault alone."
  }
}

# Threat: the apps' Entra administrator, Receiver or scaler grant goes before ca-api and
# ca-workers run as their own roles and identity. Terraform destroys a resource only after it
# has created or updated every resource that depends on it, so these depends_on edges order the
# removals on an install moving to "job": after the migrate administrator (which depends on the
# apps one, so the two never run against the server at once) and after both apps' updates, which
# themselves follow migrate_start. `terraform test` cannot read depends_on, so this reads the
# configuration, comments stripped. The trailing comma keeps `sb_receiver_workers` from matching
# `sb_receiver`.
run "migrate_app_removals_follow_the_apps_updates" {
  command = plan

  assert {
    condition = alltrue([
      for ref in [
        "azurerm_postgresql_flexible_server_active_directory_administrator.apps,",
        "azurerm_role_assignment.sb_receiver,",
        "azapi_resource_action.migrate_start,",
      ] :
      strcontains(replace(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)module \"api\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0])[0], "/#[^\\n]*/", ""), ref)
    ])
    error_message = "ca-api must depend on the apps' Entra administrator, sb_receiver and migrate_start, so their removal follows its update."
  }

  assert {
    condition = alltrue([
      for ref in [
        "azurerm_postgresql_flexible_server_active_directory_administrator.apps,",
        "azurerm_role_assignment.sb_receiver,",
        "azurerm_role_assignment.sb_scaler,",
        "azapi_resource_action.migrate_start,",
      ] :
      strcontains(replace(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)module \"workers\" \\{(.*?)\\n\\}", file("${path.module}/workers.tf"))[0])[0], "/#[^\\n]*/", ""), ref)
    ])
    error_message = "ca-workers must depend on the apps' Entra administrator, sb_receiver, sb_scaler and migrate_start, so their removal follows its update."
  }

  assert {
    condition = (
      strcontains(
        regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)resource \"azurerm_postgresql_flexible_server_active_directory_administrator\" \"migrate\" \\{(.*?)\\n\\}", file("${path.module}/entra-auth.tf"))[0])[0],
        "azurerm_postgresql_flexible_server_active_directory_administrator.apps",
      ) &&
      !strcontains(regex("(?s)resource \"azurerm_postgresql_flexible_server_active_directory_administrator\" \"apps\" \\{(.*?)\\n\\}", file("${path.module}/entra-auth.tf"))[0], "depends_on")
    )
    error_message = "The migrate administrator must depend on the apps' one, and the apps' one on nothing (a depends_on there would cycle with the apps)."
  }
}

# Service Bus with "job" on the starter server, on "password" (the file's default) and on
# "entra": ca-api's identity sends alone, and ca-workers' own identity sends, receives and scales.
# Each grant's scope is compared at apply in tests/workers_identity.tftest.hcl.
run "migrate_app_roles_narrow_the_apps_service_bus_grants_on_password" {
  command = plan

  variables {
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].role_definition_name == "Azure Service Bus Data Sender" &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      length(azurerm_role_assignment.sb_sender_workers) == 1 && length(azurerm_role_assignment.sb_receiver_workers) == 1 &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      local.workers_scale_on_queue && length(azurerm_role_assignment.sb_scaler_workers) == 1 &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner"
    )
    error_message = "With migrations = \"job\" on password, the apps identity must hold Service Bus Sender alone, and id-<prefix>-workers Sender, Receiver and the queue's Data Owner."
  }
}

run "migrate_app_roles_narrow_the_apps_service_bus_grants_on_entra" {
  command = plan

  variables {
    database_auth      = "entra"
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].role_definition_name == "Azure Service Bus Data Sender" &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      length(azurerm_role_assignment.sb_sender_workers) == 1 && length(azurerm_role_assignment.sb_receiver_workers) == 1 &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      local.workers_scale_on_queue && length(azurerm_role_assignment.sb_scaler_workers) == 1 &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner" &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0
    )
    error_message = "With migrations = \"job\" on entra, the apps identity must hold Service Bus Sender alone and no Entra administrator, and id-<prefix>-workers Sender, Receiver and the queue's Data Owner."
  }
}

# "start" on "entra" keeps the shared Service Bus grants on the apps identity, as on main.
run "shared_service_bus_grants_stay_with_start_on_entra" {
  command = plan

  variables {
    migrations         = "start"
    database_auth      = "entra"
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  assert {
    condition = (
      local.workers_scale_on_queue &&
      alltrue([
        for group in [azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_scaler] :
        length(group) == 1 && group[0].principal_id == module.apps_identity.principal_id
      ]) &&
      azurerm_role_assignment.sb_receiver[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      azurerm_role_assignment.sb_scaler[0].role_definition_name == "Azure Service Bus Data Owner" &&
      length(azurerm_role_assignment.sb_sender_workers) + length(azurerm_role_assignment.sb_receiver_workers) +
      length(azurerm_role_assignment.sb_scaler_workers) == 0
    )
    error_message = "With migrations = \"start\" on entra the apps identity must keep Service Bus Sender, Receiver and the queue's Data Owner, and no workers grant may exist."
  }
}

# "start" on "password" (the file's default) and BYO-DB: ca-workers runs as its own identity, which
# takes the Receiver and the queue's Data Owner from the apps identity, though no app role exists.
run "service_bus_grants_move_to_the_workers_identity_with_start_on_password" {
  command = plan

  variables {
    migrations         = "start"
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      local.workers_scale_on_queue &&
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      alltrue([
        for group in [azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler_workers] :
        length(group) == 1 && group[0].principal_id == module.workers_identity[0].principal_id
      ]) &&
      azurerm_role_assignment.sb_receiver_workers[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner"
    )
    error_message = "With migrations = \"start\" on password the apps identity must hold Service Bus Sender alone, and id-<prefix>-workers Sender, Receiver and the queue's Data Owner."
  }
}

run "service_bus_grants_move_to_the_workers_identity_on_byo_database" {
  command = plan

  variables {
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_service_bus    = true
    servicebus_sku        = "Standard"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      local.workers_scale_on_queue &&
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      alltrue([
        for group in [azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler_workers] :
        length(group) == 1 && group[0].principal_id == module.workers_identity[0].principal_id
      ]) &&
      azurerm_role_assignment.sb_receiver_workers[0].role_definition_name == "Azure Service Bus Data Receiver" &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner"
    )
    error_message = "With migrations = \"job\" on BYO-DB the apps identity must hold Service Bus Sender alone, and id-<prefix>-workers Sender, Receiver and the queue's Data Owner."
  }
}

# With migrations = "start" nothing of the app roles exists.
run "migrate_app_roles_absent_with_start" {
  command = plan

  variables {
    migrations = "start"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(random_password.migrate_api_role) + length(random_password.migrate_workers_role) +
      length(azurerm_key_vault_secret.migrate_api_role_password) + length(azurerm_key_vault_secret.migrate_workers_role_password) +
      length(azurerm_role_assignment.kv_secrets_user_migrate_api_role_password) + length(azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password) +
      length(azurerm_container_app_job.migrate) == 0 &&
      !anytrue([for k in keys(local.migrate_env) : startswith(k, "MASTERLY_MIGRATE_")]) &&
      !anytrue([for name in concat(module.api.env_names, module.workers[0].env_names, module.frontend.env_names) : startswith(name, "MASTERLY_MIGRATE_")])
    )
    error_message = "With migrations = \"start\" there must be no app-role password, vault secret, grant or MASTERLY_MIGRATE_* env."
  }

  # On "password" ca-workers runs as its own identity, with the shared DSN and no per-app DSN;
  # ca-api as on main.
  assert {
    condition = (
      length(module.workers_identity) == 1 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) + length(azurerm_role_assignment.kv_crypto_officer_workers) == 2 &&
      length(module.postgres_connection_urls_api) + length(module.postgres_connection_urls_workers) == 0 &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].env_names == module.api.env_names &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      !anytrue([for name in keys(azurerm_key_vault_secret.install) : startswith(name, "api-") || startswith(name, "workers-")]) &&
      length(azurerm_role_assignment.kv_app_secrets) == 1 && length(azurerm_role_assignment.kv_crypto_officer) == 1
    )
    error_message = "With migrations = \"start\" on password ca-workers must run as id-<prefix>-workers with the shared database-url, ca-api as the apps identity, and neither with a per-app DSN."
  }
}

# On "start" with Entra, the apps identity stays the server's Entra administrator and the apps'
# URL names it, as on main.
run "migrate_app_roles_absent_with_start_on_entra" {
  command = plan

  variables {
    migrations    = "start"
    database_auth = "entra"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].object_id == module.apps_identity.principal_id &&
      local.database_role == local.database_entra_role &&
      length(module.workers_identity) + length(module.postgres_connection_urls_api) + length(module.postgres_connection_urls_workers) == 0 &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.workers_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      startswith(nonsensitive(local.database_url), "postgresql+asyncpg://id-masterly-apps@")
    )
    error_message = "With migrations = \"start\" on entra, both apps must keep the apps identity, its administrator role and the shared database-url."
  }
}

# On BYO-DB the database is the customer's: the job creates no app roles there.
run "migrate_app_roles_absent_on_byo_database" {
  command = plan

  variables {
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(azurerm_container_app_job.migrate) == 1 &&
      length(random_password.migrate_api_role) + length(random_password.migrate_workers_role) +
      length(azurerm_key_vault_secret.migrate_api_role_password) + length(azurerm_key_vault_secret.migrate_workers_role_password) +
      length(azurerm_role_assignment.kv_secrets_user_migrate_api_role_password) + length(azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password) == 0 &&
      !anytrue([for k in keys(local.migrate_env) : startswith(k, "MASTERLY_MIGRATE_")]) &&
      !anytrue([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : startswith(e.name, "MASTERLY_MIGRATE_")]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"])
    )
    error_message = "On BYO-DB there must be no app-role password, vault secret, grant or MASTERLY_MIGRATE_* env on the job."
  }

  # ca-workers runs as its own identity, with the shared DSN and no per-app DSN; ca-api as on main.
  assert {
    condition = (
      length(module.workers_identity) == 1 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) + length(azurerm_role_assignment.kv_crypto_officer_workers) == 2 &&
      length(module.postgres_connection_urls_api) + length(module.postgres_connection_urls_workers) == 0 &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].env_names == module.api.env_names &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      !anytrue([for name in keys(azurerm_key_vault_secret.install) : startswith(name, "api-") || startswith(name, "workers-")]) &&
      length(azurerm_role_assignment.kv_app_secrets) == 1 && length(azurerm_role_assignment.kv_crypto_officer) == 1
    )
    error_message = "On BYO-DB ca-workers must run as id-<prefix>-workers with the shared database-url, ca-api as the apps identity, and neither with a per-app DSN."
  }
}

# The upgrade uses real modules, including ACA and identities, with shared ARM-shaped IDs.
mock_provider "azurerm" {
  alias  = "upgrade"
  source = "./tests/mocks/migrate"
  # The nested block override takes its fields as an object. This computed database ID
  # is parsed by diagnostics.
  override_resource {
    target = azurerm_managed_redis.this
    values = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-before"
      default_database = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-before/databases/default" }
    }
  }
}

# Keep these two runs adjacent: the apply establishes the previous migration defaults for the next
# plan, including the ACA environment and all serving resources (no -target or module override).
# Mock providers do not implement Azure ForceNew decisions. Retained computed IDs detect
# Terraform-driven replacement/recreation; exact attributes also pin the replacement inputs.
# A live branch plan is still required before release (validate-module-change).
run "before_migrate_job_uses_previous_defaults" {
  command   = apply
  providers = { azurerm = azurerm.upgrade, random = random, azapi = azapi }

  variables {
    migrations         = "start"
    database_auth      = "entra"
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_MIGRATIONS") && !contains(module.workers[0].env_names, "MASTERLY_MIGRATIONS") &&
      length(azurerm_container_app_job.migrate) + length(module.migrate_identity) +
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) +
      length(terraform_data.migrate_image) + length(azapi_resource_action.migrate_start) +
      length(azurerm_role_assignment.kv_secrets_user_migrate) + length(azurerm_role_assignment.acr_pull_migrate) == 0 &&
      !contains(output.vault_backed_secret_names, "migrate-database-url") && output.aca_environment_id != null
    )
    error_message = "The baseline must apply the existing install and ACA environment, with MASTERLY_MIGRATIONS unset and no migration infrastructure."
  }
}

run "migrate_job_preserves_the_existing_install" {
  command   = plan
  providers = { azurerm = azurerm.upgrade, random = random, azapi = azapi }

  variables {
    migrations         = "job"
    database_auth      = "entra"
    enable_service_bus = true
    servicebus_sku     = "Standard"
  }

  assert {
    condition = (
      output.aca_environment_id == run.before_migrate_job_uses_previous_defaults.aca_environment_id &&
      output.postgres_fqdn == run.before_migrate_job_uses_previous_defaults.postgres_fqdn &&
      output.key_vault_uri == run.before_migrate_job_uses_previous_defaults.key_vault_uri &&
      output.service_bus_namespace == run.before_migrate_job_uses_previous_defaults.service_bus_namespace &&
      output.apps_identity_principal_id == run.before_migrate_job_uses_previous_defaults.apps_identity_principal_id &&
      output.frontend_identity_principal_id == run.before_migrate_job_uses_previous_defaults.frontend_identity_principal_id &&
      random_string.install.result == "before"
    )
    error_message = "Enabling job migrations must retain the baseline environment, database, vault, namespace, identities and install suffix."
  }

  assert {
    condition = alltrue([for group in [
      azurerm_postgresql_flexible_server.this, azurerm_key_vault.this, azurerm_servicebus_namespace.this,
      azurerm_virtual_network.this, azurerm_subnet.aca, azurerm_subnet.private_endpoints,
      azurerm_network_security_group.aca, azurerm_network_security_group.private_endpoints,
      azurerm_subnet_network_security_group_association.aca, azurerm_subnet_network_security_group_association.private_endpoints,
      azurerm_private_dns_zone.postgres, azurerm_private_dns_zone.key_vault, azurerm_private_dns_zone.redis,
      azurerm_private_dns_zone_virtual_network_link.postgres, azurerm_private_dns_zone_virtual_network_link.key_vault, azurerm_private_dns_zone_virtual_network_link.redis,
      azurerm_private_endpoint.postgres, azurerm_private_endpoint.key_vault, azurerm_private_endpoint.redis,
      azurerm_managed_redis.this, azurerm_managed_redis_access_policy_assignment.apps, azurerm_servicebus_queue.jobs,
      azurerm_role_assignment.sb_sender,
      azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer,
      azurerm_monitor_diagnostic_setting.postgres, azurerm_monitor_diagnostic_setting.key_vault,
      azurerm_monitor_diagnostic_setting.redis, azurerm_monitor_diagnostic_setting.redis_database, azurerm_monitor_diagnostic_setting.service_bus,
      azurerm_monitor_action_group.alerts, azurerm_monitor_metric_alert.postgres_storage, azurerm_monitor_metric_alert.postgres_cpu,
      azurerm_monitor_metric_alert.postgres_connections, azurerm_monitor_metric_alert.postgres_iops, azurerm_monitor_metric_alert.postgres_unavailable,
      azurerm_monitor_metric_alert.redis_evictions, azurerm_monitor_metric_alert.redis_memory,
      azurerm_monitor_metric_alert.servicebus_dead_letters, azurerm_monitor_metric_alert.workers_memory,
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency, azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready,
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent, random_password.postgres_admin,
      ] : length(group) == 1 && group[0].id != null]) && alltrue([for id in [
      azurerm_resource_group.aca.id, azurerm_resource_group.data.id, module.aca_env.id, module.logs.id,
      module.api.id, module.frontend.id, module.workers[0].id, module.apps_identity.id, module.frontend_identity.id,
      azurerm_monitor_diagnostic_setting.aca_env.id, random_password.session_secret.id, random_password.bff_shared_secret.id,
    ] : id != null])
    error_message = "Every existing counted resource must remain at its address with a known state ID; replacement or recreation makes its computed ID unknown."
  }

  assert {
    condition = (
      alltrue([for k in run.before_migrate_job_uses_previous_defaults.vault_backed_secret_names : azurerm_key_vault_secret.install[k].id != null]) &&
      alltrue([for group in [
        azurerm_role_assignment.kv_secrets_user_frontend, azurerm_role_assignment.kv_secrets_officer_deployer,
        azurerm_postgresql_flexible_server_configuration.log, azurerm_monitor_diagnostic_setting.app,
        azurerm_monitor_metric_alert.app_5xx, azurerm_monitor_metric_alert.app_unavailable, azurerm_monitor_scheduled_query_rules_alert_v2.app_silent,
      ] : alltrue([for r in group : r.id != null])]) &&
      length(azurerm_role_assignment.kv_secrets_user_frontend) == 2 && length(azurerm_role_assignment.kv_secrets_officer_deployer) == 1 &&
      length(azurerm_postgresql_flexible_server_configuration.log) == 3 && length(azurerm_monitor_diagnostic_setting.app) == 3 &&
      length(azurerm_monitor_metric_alert.app_5xx) == 2 && length(azurerm_monitor_metric_alert.app_unavailable) == 3 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 3
    )
    error_message = "Existing secrets, grants, server settings and per-app monitoring must remain in state with unchanged cardinality."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].name == "psql-masterly-before" &&
      azurerm_postgresql_flexible_server.this[0].resource_group_name == "rg-masterly-data" &&
      azurerm_postgresql_flexible_server.this[0].location == "swedencentral" &&
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled &&
      !azurerm_postgresql_flexible_server.this[0].public_network_access_enabled &&
      azurerm_key_vault.this[0].name == "kv-masterly-before" &&
      azurerm_key_vault.this[0].resource_group_name == "rg-masterly-data" &&
      azurerm_key_vault.this[0].location == "swedencentral" &&
      azurerm_key_vault.this[0].tenant_id == "00000000-0000-0000-0000-000000000000" &&
      azurerm_key_vault.this[0].soft_delete_retention_days == 90 && azurerm_key_vault.this[0].purge_protection_enabled &&
      azurerm_servicebus_namespace.this[0].name == "sb-masterly-before" &&
      azurerm_servicebus_namespace.this[0].resource_group_name == "rg-masterly-aca" &&
      azurerm_servicebus_namespace.this[0].location == "swedencentral" &&
      azurerm_servicebus_namespace.this[0].sku == "Standard" && azurerm_servicebus_namespace.this[0].premium_messaging_partitions == 0 &&
      !module.aca_env.internal_load_balancer_enabled && module.aca_env.logs_destination == "azure-monitor" && module.aca_env.mutual_tls_enabled
    )
    error_message = "The complete stateful-resource names and replacement-sensitive settings must equal the pre-job configuration, not merely share a prefix."
  }

  # ACA exposes no name/location/subnet output. Pin its replacement inputs at both module
  # boundaries, in addition to retaining its applied ID above. PostgreSQL's null admin login
  # is Optional+Computed, so pin the requested expression rather than a fabricated mock value.
  assert {
    condition = (
      jsonencode({ for pair in regexall("(?m)^  (name|resource_group_name|location|infrastructure_subnet_id|internal_load_balancer_enabled)\\s*=\\s*([^\\n]+)", regex("(?s)module \"aca_env\" \\{(.*?)\\n\\}", file("${path.module}/environment.tf"))[0]) : pair[0] => trimspace(pair[1]) }) == jsonencode({
        name                           = "\"aca-$${var.name_prefix}\""
        resource_group_name            = "azurerm_resource_group.aca.name"
        location                       = "var.location"
        infrastructure_subnet_id       = "local.aca_subnet_id"
        internal_load_balancer_enabled = "var.aca_internal_load_balancer"
      }) &&
      jsonencode({ for pair in regexall("(?m)^  (name|resource_group_name|location|infrastructure_subnet_id|internal_load_balancer_enabled|zone_redundancy_enabled|infrastructure_resource_group_name)\\s*=\\s*([^\\n]+)", regex("(?s)resource \"azurerm_container_app_environment\" \"this\" \\{(.*?)\\n\\}", file("${path.module}/modules/aca-env-consumption/main.tf"))[0]) : pair[0] => trimspace(pair[1]) }) == jsonencode({
        name                           = "var.name"
        resource_group_name            = "var.resource_group_name"
        location                       = "var.location"
        infrastructure_subnet_id       = "var.infrastructure_subnet_id"
        internal_load_balancer_enabled = "var.internal_load_balancer_enabled"
      }) &&
      jsonencode({ for pair in regexall("(?m)^  (administrator_login|delegated_subnet_id|private_dns_zone_id|create_mode|source_server_id|point_in_time_restore_time_in_utc)\\s*=\\s*([^\\n]+)", regex("(?s)resource \"azurerm_postgresql_flexible_server\" \"this\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0]) : pair[0] => trimspace(pair[1]) }) == jsonencode({
        administrator_login = "local.database_entra ? null : \"masterly_admin\""
      })
    )
    error_message = "ACA replacement inputs and Postgres administrator/network/create-mode inputs must retain their base configuration."
  }

  # The upgrade removes the apps identity's Entra administrator, Receiver and scaler grant (ADR
  # 0120): the migrate identity becomes the server's administrator, and ca-workers receives and
  # scales as its own identity. Terraform destroys the three only after updating ca-api and
  # ca-workers, which depend on them (migrate_app_removals_follow_the_apps_updates).
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      length(azurerm_role_assignment.sb_receiver) == 0 && length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender[0].principal_id == run.before_migrate_job_uses_previous_defaults.apps_identity_principal_id &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].server_name == "psql-masterly-before" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].resource_group_name == "rg-masterly-data" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_name == "id-masterly-migrate" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_type == "ServicePrincipal" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].tenant_id == "00000000-0000-0000-0000-000000000000"
    )
    error_message = "The upgrade to \"job\" must remove the apps' Entra administrator, Service Bus Receiver and scaler grant, keep Sender on the apps identity, and make id-<prefix>-migrate the server's administrator."
  }

  assert {
    condition = (
      alltrue([for group in [
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acs_email_sender,
        azurerm_role_assignment.kv_secrets_reader, module.acs_email, azapi_resource.builtin_auth,
        azurerm_redis_cache.this, azurerm_redis_cache_access_policy_assignment.apps,
        azurerm_private_endpoint.servicebus, azurerm_private_dns_zone.servicebus, azurerm_private_dns_zone_virtual_network_link.servicebus,
        azurerm_private_endpoint.registry, azurerm_private_dns_zone.registry, azurerm_private_dns_zone_virtual_network_link.registry,
        azurerm_postgresql_flexible_server_configuration.operator, azurerm_postgresql_flexible_server_configuration.pgbouncer,
        azurerm_monitor_metric_alert.postgres_cpu_credits,
      ] : length(group) == 0]) &&
      length(azurerm_container_app_job.migrate) == 1 && length(module.migrate_identity) == 1 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 1 &&
      length(terraform_data.migrate_image) == 1 && length(azapi_resource_action.migrate_start) == 1 &&
      length(azurerm_role_assignment.acr_pull_migrate) == 0 && length(azurerm_role_assignment.kv_byo_database_reader_migrate) == 0 &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url"]) &&
      toset(keys(azurerm_key_vault_secret.install)) == setunion(toset(run.before_migrate_job_uses_previous_defaults.vault_backed_secret_names), toset(["migrate-database-url", "api-database-url", "workers-database-url"])) &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == run.before_migrate_job_uses_previous_defaults.aca_environment_id &&
      local.api_env["MASTERLY_MIGRATIONS"] == "job" && contains(module.workers[0].env_names, "MASTERLY_MIGRATIONS")
    )
    error_message = "The upgrade must add only the dedicated migration job/identity and their administrator, start action, secret and scoped grant, each backend app's own DSN secret, and opt the existing serving apps into job mode."
  }

  # The upgrade adds id-<prefix>-workers and its backend grants beside the shared ones, which
  # stay but for the two above; the shared database-url stays in the vault, and on ca-api as the definition
  # its running revision resolves until the new one is ready, named by no env of the new one.
  assert {
    condition = (
      length(module.workers_identity) == 1 &&
      alltrue([for group in [
        azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
        azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler_workers,
        azurerm_managed_redis_access_policy_assignment.workers,
      ] : length(group) == 1]) &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.acs_email_sender_workers) + length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(module.postgres_connection_urls_api) == 1 && length(module.postgres_connection_urls_workers) == 1 &&
      azurerm_key_vault_secret.install["database-url"].id != null &&
      contains(run.before_migrate_job_uses_previous_defaults.vault_backed_secret_names, "database-url") &&
      contains(module.api.vault_backed_secret_names, "database-url") && local.api_vault_secret_refs["database-url"].identity_id == module.apps_identity.id &&
      !contains(values(local.api_env_secret_refs), "database-url") && !contains(module.workers[0].vault_backed_secret_names, "database-url") &&
      contains(module.api.vault_backed_secret_names, "api-database-url") && contains(module.workers[0].vault_backed_secret_names, "workers-database-url")
    )
    error_message = "The upgrade must add id-<prefix>-workers' grants and each app's own DSN beside the remaining shared grants and the shared database-url secret, which stay in the vault and on ca-api, named by no env."
  }
}

# Apply last so every vault value is known without affecting the preceding plan regressions.
# The apps retain the secrets and env asserted in external_database_url_alone_reaches_the_migrate_job_too.
run "external_database_admin_url_reaches_only_the_migrate_job" {
  command = apply
  providers = {
    azurerm = azurerm.upgrade
    random  = random
    azapi   = azapi
  }
  variables {
    enable_key_vault            = true
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    external_database_admin_url = "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require"
  }
  assert {
    condition = (
      local.migrate_database_url == var.external_database_admin_url &&
      one([for secret in azurerm_container_app_job.migrate[0].secret : secret.value if secret.name == "migrate-database-url"]) == var.external_database_admin_url &&
      nonsensitive(local.database_url) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require" &&
      nonsensitive(azurerm_key_vault_secret.install["database-url"].value) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require" &&
      alltrue([for secret in azurerm_key_vault_secret.install : secret.value != var.external_database_admin_url])
    )
    error_message = "Only the ACA job secret may hold external_database_admin_url; every vault secret must exclude it. The apps keep external_database_url."
  }
  assert {
    condition = (
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      sort(keys(local.backend_env_secret_refs)) == tolist(["MASTERLY_DATABASE_URL", "MASTERLY_LICENSE_TOKEN", "MASTERLY_REDIS_URL", "MASTERLY_SESSION_SECRET"]) &&
      sort(keys(local.api_env_secret_refs)) == tolist(["MASTERLY_BFF_SHARED_SECRET", "MASTERLY_DATABASE_URL", "MASTERLY_LICENSE_TOKEN", "MASTERLY_REDIS_URL", "MASTERLY_SESSION_SECRET"]) &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      length(module.api.value_secret_names) == 0 &&
      length(module.workers[0].value_secret_names) == 0
    )
    error_message = "external_database_admin_url must change nothing in ca-api's or ca-workers' secrets or env."
  }
  assert {
    condition = (
      tolist(local.migrate_secret_names) == tolist(["migrate-database-url"]) &&
      length(local.migrate_vault_secret_refs) == 0 && length(azurerm_role_assignment.kv_secrets_user_migrate) == 0 &&
      !contains(keys(azurerm_key_vault_secret.install), "migrate-database-url") &&
      issensitive(var.external_database_admin_url) && issensitive(local.migrate_value_secrets["migrate-database-url"])
    )
    error_message = "The admin DSN must remain sensitive in the job secret, with no vault copy, reference or grant."
  }
}

# Applied, so the secrets' ARM ids and the passwords are known: each grant is scoped to its own
# secret, never the vault, and no password value reaches an env, a Container App or job secret, or
# another vault secret. Distinct ids, so a grant on the wrong secret fails.
run "migrate_app_role_secrets_are_read_one_by_one" {
  command = apply
  providers = {
    azurerm = azurerm.upgrade
    random  = random
    azapi   = azapi
  }

  override_resource {
    target = azurerm_key_vault_secret.migrate_api_role_password
    values = {
      versionless_id          = "https://kv-masterly-before.vault.azure.net/secrets/install-migrate-api-role-password"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-before/secrets/install-migrate-api-role-password"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.migrate_workers_role_password
    values = {
      versionless_id          = "https://kv-masterly-before.vault.azure.net/secrets/install-migrate-workers-role-password"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-before/secrets/install-migrate-workers-role-password"
    }
  }

  assert {
    condition = (
      azurerm_key_vault_secret.migrate_api_role_password[0].key_vault_id == azurerm_key_vault.this[0].id &&
      azurerm_key_vault_secret.migrate_workers_role_password[0].key_vault_id == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_secrets_user_migrate_api_role_password[0].scope == azurerm_key_vault_secret.migrate_api_role_password[0].resource_versionless_id &&
      azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password[0].scope == azurerm_key_vault_secret.migrate_workers_role_password[0].resource_versionless_id &&
      azurerm_role_assignment.kv_secrets_user_migrate_api_role_password[0].scope != azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password[0].scope &&
      alltrue([
        for ra in [azurerm_role_assignment.kv_secrets_user_migrate_api_role_password[0], azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password[0]] :
        ra.scope != azurerm_key_vault.this[0].id && startswith(ra.scope, "${azurerm_key_vault.this[0].id}/secrets/install-migrate-")
      ])
    )
    error_message = "Each app-role password grant must be scoped to its own secret's ARM id, never to the vault."
  }

  # Threat: password exposure. Each password reaches an app only inside that app's own DSN vault
  # secret: it is in no env, no ACA secret on the job or an app, and no other vault secret.
  assert {
    condition = (
      azurerm_key_vault_secret.migrate_api_role_password[0].value == random_password.migrate_api_role[0].result &&
      azurerm_key_vault_secret.migrate_workers_role_password[0].value == random_password.migrate_workers_role[0].result &&
      issensitive(random_password.migrate_api_role[0].result) && issensitive(random_password.migrate_workers_role[0].result) &&
      random_password.migrate_api_role[0].result != random_password.migrate_workers_role[0].result &&
      strcontains(azurerm_key_vault_secret.install["api-database-url"].value, "://masterly_api:${random_password.migrate_api_role[0].result}@") &&
      strcontains(azurerm_key_vault_secret.install["workers-database-url"].value, "://masterly_workers:${random_password.migrate_workers_role[0].result}@") &&
      alltrue(flatten([
        for pair in [
          { password = random_password.migrate_api_role[0].result, own = ["api-database-url", "api-database-direct-url"] },
          { password = random_password.migrate_workers_role[0].result, own = ["workers-database-url", "workers-database-direct-url"] },
          ] : concat(
          [for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : !strcontains(coalesce(e.value, "-"), pair.password)],
          [for s in azurerm_container_app_job.migrate[0].secret : !strcontains(coalesce(s.value, "-"), pair.password)],
          [for v in values(local.migrate_env) : !strcontains(v, pair.password)],
          [for v in values(local.api_env) : !strcontains(v, pair.password)],
          [for v in values(local.workers_env) : !strcontains(v, pair.password)],
          # The catalogue holds each app's direct URL too; only the names an app carries reach it.
          [for name, v in local.secret_values : !strcontains(v, pair.password) if v != null && !contains(pair.own, name)],
          [for name, s in azurerm_key_vault_secret.install : !strcontains(s.value, pair.password) if !contains(pair.own, name)],
        )
      ])) &&
      length(module.api.value_secret_names) + length(module.workers[0].value_secret_names) + length(module.frontend.value_secret_names) == 0 &&
      module.api.vault_backed_secret_names == tolist(["api-database-url", "bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["license-token", "redis-url", "session-secret", "workers-database-url"])
    )
    error_message = "Each app-role password must reach an app only inside that app's own DSN vault secret: in no job or app env, no ACA secret and no other install secret."
  }

  assert {
    condition = (
      tolist(local.migrate_secret_names) == tolist(["migrate-database-url"]) &&
      tolist(local.migrate_vault_secret_names) == tolist(["migrate-database-url"]) &&
      sort([for s in azurerm_container_app_job.migrate[0].secret : s.name]) == tolist(["migrate-database-url"]) &&
      local.migrate_env["MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF"] == "install-migrate-api-role-password" &&
      local.migrate_env["MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF"] == "install-migrate-workers-role-password" &&
      !contains(output.vault_backed_secret_names, "migrate-api-role-password") &&
      !contains(output.vault_backed_secret_names, "migrate-workers-role-password")
    )
    error_message = "The job must get the app-role passwords only as vault secret names, with its ACA secrets as on main."
  }
}
