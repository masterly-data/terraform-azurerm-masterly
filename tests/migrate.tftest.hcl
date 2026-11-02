# Migrate job plan regressions share a valid production posture. The install-context and
# demo-mode guard regressions are in install.tftest.hcl; image drift applies are separate.

mock_provider "azurerm" {
  # The Key Vault resource validates tenant_id as a UUID; the auto-generated mock value
  # is a random string, so pin the client-config data source.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  # These plans model new installations, with no discovered server or cache.
  mock_data "azurerm_resources" {
    defaults = {
      resources = []
    }
  }
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
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.frontend_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"
      principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      client_id    = "ffffffff-ffff-ffff-ffff-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend"
    }
  }

  override_module {
    target = module.migrate_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
      principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-migrate"
    }
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
          azurerm_role_assignment.kv_secrets_officer[0].principal_id,
          azurerm_role_assignment.kv_crypto_officer[0].principal_id,
          azurerm_role_assignment.sb_sender[0].principal_id,
          azurerm_role_assignment.sb_receiver[0].principal_id,
          azurerm_role_assignment.sb_scaler[0].principal_id,
          azurerm_role_assignment.acs_email_sender[0].principal_id,
          azurerm_role_assignment.acr_pull[0].principal_id,
          azurerm_role_assignment.acr_pull_frontend[0].principal_id,
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
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.migrate_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
      principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-migrate"
    }
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

run "migrate_identity_is_a_second_entra_administrator" {
  command = plan

  variables {
    database_auth = "entra"
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

  override_module {
    target = module.migrate_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
      principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-migrate"
    }
  }

  # `apps` is unchanged; `migrate` stands beside it.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].principal_name == "id-masterly-apps" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].object_id == module.apps_identity.principal_id &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_name == "id-masterly-migrate" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].principal_type == "ServicePrincipal" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == module.migrate_identity[0].principal_id
    )
    error_message = "On entra the server must have two Entra administrators: id-<prefix>-apps, unchanged, and id-<prefix>-migrate."
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

# Threat: the admin DSN reaches the job alone. The apps' secrets and env are exactly those of the
# run below, which sets external_database_url only.
run "external_database_admin_url_reaches_only_the_migrate_job" {
  command = plan

  variables {
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    external_database_admin_url = "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      nonsensitive(local.migrate_database_url) == "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require" &&
      nonsensitive(azurerm_key_vault_secret.install["migrate-database-url"].value) == "postgresql+asyncpg://masterly_owner:adminpw@pg.example.com:5432/postgres?ssl=require" &&
      nonsensitive(local.database_url) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require" &&
      nonsensitive(azurerm_key_vault_secret.install["database-url"].value) == "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    )
    error_message = "The migrate job must get external_database_admin_url, and the apps external_database_url."
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
      sort(keys(local.migrate_vault_secret_refs)) == tolist(["migrate-database-url"]) &&
      issensitive(var.external_database_admin_url)
    )
    error_message = "The admin DSN must be a sensitive input, held only in the migrate job's own secret."
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

# Threat: the upgrade replaces nothing stateful. The names (which force replacement) of the
# server, the vault, the namespace and the `apps` administrator are what they were before the
# job existed. The ACA environment exposes no name here; its module call is unchanged in the
# diff (aca-<prefix>), and the job only names its id.
run "migrate_job_leaves_the_stateful_resources_as_they_were" {
  command = plan

  variables {
    database_auth      = "entra"
    enable_service_bus = true
    servicebus_sku     = "Standard"
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
      startswith(azurerm_postgresql_flexible_server.this[0].name, "psql-masterly-") &&
      azurerm_postgresql_flexible_server.this[0].resource_group_name == azurerm_resource_group.data.name &&
      azurerm_postgresql_flexible_server.this[0].location == "swedencentral" &&
      startswith(azurerm_key_vault.this[0].name, "kv-masterly-") &&
      azurerm_key_vault.this[0].resource_group_name == azurerm_resource_group.data.name &&
      startswith(azurerm_servicebus_namespace.this[0].name, "sb-masterly-") &&
      azurerm_servicebus_namespace.this[0].resource_group_name == azurerm_resource_group.aca.name
    )
    error_message = "The server, vault and namespace must keep their names and resource groups."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].principal_name == "id-masterly-apps" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].principal_type == "ServicePrincipal" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].object_id == module.apps_identity.principal_id &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].tenant_id == "00000000-0000-0000-0000-000000000000"
    )
    error_message = "The apps' Entra administrator must stay exactly as it was."
  }
}
