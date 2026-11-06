# The install shapes on which ca-workers stays on the apps identity (workers.tf,
# workers_own_identity): migrations = "start" with database_auth = "entra" on the starter server,
# an install without ca-workers, and an install without the vault. tests/workers_identity.tftest.hcl
# covers the shapes where it moves.
#
# Every expected value here is a literal, so this file states what those shapes plan, and a change
# that moves any of them has to change this file. Between them the runs compare the identities, the
# backend role assignments, the Redis policies, and ca-api's and ca-workers' identity, env and
# secrets, and the first run every role assignment in the module.
#
# Applies, in their own file, for the reasons tests/workers_identity.tftest.hcl gives: the scopes are
# computed, and a separate file keeps this state away from the other files' runs.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  # Diagnostics parse the managed Redis database ID.
  override_resource {
    target = azurerm_managed_redis.this
    values = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-test"
      default_database = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-test/databases/default" }
    }
  }

  # The app secrets role gets an id of its own, so a grant of it differs from any other role's.
  override_resource {
    target = azurerm_role_definition.app_secrets
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000001"
    }
  }
}
mock_provider "random" {}
mock_provider "azapi" {}

# A distinct principal per identity: the shared mock gives every identity the apps identity's, so
# without these a grant on the wrong identity would compare equal.
override_module {
  target  = module.apps_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
}

override_module {
  target  = module.frontend_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
}

override_module {
  target  = module.workers_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
}

# The ACS resources' IDs are parsed by the provider; the role assignment needs only the scope.
override_module {
  target  = module.acs_email
  outputs = { communication_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly", endpoint = "https://acs-masterly.europe.communication.azure.com", sender_address = "DoNotReply@example.azurecomm.net" }
}

variables {
  location       = "swedencentral"
  org_id         = "org_test"
  install_id     = "test"
  api_image      = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"

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
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
}

# migrations = "start" with database_auth = "entra": the shared DSN's user is the apps identity's
# name and its token is minted for AZURE_CLIENT_ID, so ca-workers stays on the apps identity.
run "start_on_entra_is_unchanged_on_managed_redis" {
  command = apply

  variables {
    database_auth = "entra"
  }

  assert {
    condition = toset([
      for ra in concat(
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
        azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
        values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
        values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
      ) : "${ra.principal_id}|${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}"
      ]) == toset([
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${var.acr_id}|AcrPull|(assigned by name)",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|${var.acr_id}|AcrPull|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Sender|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly|Communication and Email Service Owner|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_key_vault.this[0].id}|(assigned by id)|${azurerm_role_definition.app_secrets[0].role_definition_resource_id}",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_key_vault.this[0].id}|Key Vault Crypto Officer|(assigned by name)",
      "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee|${azurerm_key_vault.this[0].id}|Key Vault Secrets Officer|(assigned by name)",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|${azurerm_key_vault_secret.install["bff-shared-secret"].resource_versionless_id}|Key Vault Secrets User|(assigned by name)",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|${azurerm_key_vault_secret.install["oidc-client-secret"].resource_versionless_id}|Key Vault Secrets User|(assigned by name)",
    ])
    error_message = "On start with entra every grant must stay as it was: the apps identity keeps Service Bus Receiver and the queue's Data Owner, and no workers grant exists."
  }

  assert {
    condition = (
      length(module.workers_identity) + length(module.migrate_identity) == 0 &&
      output.workers_identity_principal_id == null &&
      azurerm_managed_redis_access_policy_assignment.apps[0].object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1 &&
      length(azurerm_managed_redis_access_policy_assignment.workers) + length(azurerm_redis_cache_access_policy_assignment.apps) + length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.apps[0].object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 0
    )
    error_message = "On start with entra there must be no workers identity, no workers Redis policy, and the apps identity must stay the only Postgres administrator."
  }

  assert {
    condition = (
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].registry.identity == module.apps_identity.id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.apps_identity.id &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.workers_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.workers_env == local.api_env &&
      module.workers[0].env_names == module.api.env_names &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      length(module.postgres_connection_urls_api) + length(module.postgres_connection_urls_workers) == 0 &&
      startswith(nonsensitive(local.database_url), "postgresql+asyncpg://id-masterly-apps@")
    )
    error_message = "On start with entra both apps must stay on the apps identity, its AZURE_CLIENT_ID and the shared database-url, whose user is that identity."
  }
}

run "start_on_entra_is_unchanged_on_azure_cache_for_redis" {
  command = apply

  variables {
    database_auth  = "entra"
    redis_offering = "cache"
  }

  assert {
    condition = toset([
      for ra in concat(
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
      ) : "${ra.principal_id}|${ra.role_definition_name}|${ra.role_definition_id}"
      ]) == toset([
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|AcrPull|(assigned by name)",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|AcrPull|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Sender|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Receiver|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Owner|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Communication and Email Service Owner|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|(assigned by id)|${azurerm_role_definition.app_secrets[0].role_definition_resource_id}",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Key Vault Crypto Officer|(assigned by name)",
    ])
    error_message = "On start with entra on Azure Cache for Redis the apps identity must keep every backend grant, and no workers grant may exist."
  }

  assert {
    condition = (
      length(module.workers_identity) == 0 &&
      length(azurerm_redis_cache_access_policy_assignment.apps) == 1 &&
      azurerm_redis_cache_access_policy_assignment.apps[0].object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      length(azurerm_redis_cache_access_policy_assignment.workers) + length(azurerm_managed_redis_access_policy_assignment.apps) + length(azurerm_managed_redis_access_policy_assignment.workers) == 0 &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.workers_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
    )
    error_message = "On start with entra on Azure Cache for Redis, ca-workers must stay on the apps identity and its Redis policy, with no workers identity."
  }
}

# No ca-workers: the api runs the loop in-process, which only demo allows (workers.tf).
run "no_workers_is_unchanged_on_password" {
  command = apply

  variables {
    mode             = "demo"
    enable_workers   = false
    api_max_replicas = 1
    database_auth    = "password"
  }

  assert {
    condition = toset([
      for ra in concat(
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
      ) : "${ra.principal_id}|${ra.role_definition_name}|${ra.role_definition_id}"
      ]) == toset([
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|AcrPull|(assigned by name)",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|AcrPull|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Sender|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Receiver|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Communication and Email Service Owner|(assigned by name)",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|(assigned by id)|${azurerm_role_definition.app_secrets[0].role_definition_resource_id}",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Key Vault Crypto Officer|(assigned by name)",
    ])
    error_message = "Without ca-workers the apps identity must keep Sender, Receiver and every other backend grant, with no queue Data Owner and no workers grant."
  }

  assert {
    condition = (
      length(module.workers) + length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      output.workers_identity_principal_id == null &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1 &&
      length(azurerm_managed_redis_access_policy_assignment.workers) + length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.workers_env == local.api_env &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      module.api.vault_backed_secret_names == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"])
    )
    error_message = "Without ca-workers on password there must be no workers identity or DSN, and ca-api must stay on the apps identity and database-url."
  }
}

run "no_workers_is_unchanged_on_entra" {
  command = apply

  variables {
    mode             = "demo"
    enable_workers   = false
    api_max_replicas = 1
    database_auth    = "entra"
  }

  assert {
    condition = (
      length(module.workers) + length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) == 1 &&
      azurerm_role_assignment.sb_receiver[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      length(azurerm_role_assignment.sb_scaler) == 0 &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.kv_app_secrets_workers) +
      length(azurerm_role_assignment.kv_crypto_officer_workers) + length(azurerm_role_assignment.sb_sender_workers) +
      length(azurerm_role_assignment.sb_receiver_workers) + length(azurerm_role_assignment.sb_scaler_workers) +
      length(azurerm_role_assignment.acs_email_sender_workers) + length(azurerm_managed_redis_access_policy_assignment.workers) +
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
    )
    error_message = "Without ca-workers on entra the apps identity must keep its grants and its administrator, with no workers identity or grant."
  }
}

run "no_workers_is_unchanged_on_byo_database" {
  command = apply

  variables {
    mode                  = "demo"
    enable_workers        = false
    api_max_replicas      = 1
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(module.workers) + length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) == 1 &&
      azurerm_role_assignment.sb_receiver[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      length(azurerm_role_assignment.sb_scaler) == 0 &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.kv_app_secrets_workers) +
      length(azurerm_role_assignment.kv_crypto_officer_workers) + length(azurerm_role_assignment.sb_sender_workers) +
      length(azurerm_role_assignment.sb_receiver_workers) + length(azurerm_role_assignment.sb_scaler_workers) +
      length(azurerm_role_assignment.acs_email_sender_workers) + length(azurerm_managed_redis_access_policy_assignment.workers) +
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url"
    )
    error_message = "Without ca-workers on BYO-DB the apps identity must keep its grants and the shared database-url, with no workers identity or grant."
  }
}

# No vault: every app carries its secrets as values, and ca-workers has no vault reference to
# resolve, so it stays on the apps identity. Only demo runs without one.
run "no_vault_is_unchanged_on_password" {
  command = apply

  variables {
    mode             = "demo"
    enable_key_vault = false
    api_max_replicas = 1
    database_auth    = "password"
  }

  assert {
    condition = toset([
      for ra in concat(
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
      ) : "${ra.principal_id}|${ra.role_definition_name}"
      ]) == toset([
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|AcrPull",
      "ffffffff-ffff-ffff-ffff-ffffffffffff|AcrPull",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Sender",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Receiver",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Azure Service Bus Data Owner",
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|Communication and Email Service Owner",
    ])
    error_message = "Without the vault the apps identity must keep every backend grant, the queue's Data Owner included, and no workers grant may exist."
  }

  assert {
    condition = (
      length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      output.workers_identity_principal_id == null &&
      length(azurerm_managed_redis_access_policy_assignment.apps) == 1 &&
      length(azurerm_managed_redis_access_policy_assignment.workers) + length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].registry.identity == module.apps_identity.id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.apps_identity.id &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.workers_env == local.api_env &&
      module.workers[0].env_names == module.api.env_names &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      length(module.workers[0].vault_backed_secret_names) + length(module.api.vault_backed_secret_names) == 0 &&
      sort(module.workers[0].value_secret_names) == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      sort(module.api.value_secret_names) == tolist(["bff-shared-secret", "database-url", "license-token", "redis-url", "session-secret"])
    )
    error_message = "Without the vault on password both apps must stay on the apps identity, with the shared database-url as a value secret."
  }
}

run "no_vault_is_unchanged_on_entra" {
  command = apply

  variables {
    mode             = "demo"
    enable_key_vault = false
    api_max_replicas = 1
    database_auth    = "entra"
  }

  assert {
    condition = (
      length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 2 &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.kv_app_secrets_workers) +
      length(azurerm_role_assignment.kv_crypto_officer_workers) + length(azurerm_role_assignment.sb_sender_workers) +
      length(azurerm_role_assignment.sb_receiver_workers) + length(azurerm_role_assignment.sb_scaler_workers) +
      length(azurerm_role_assignment.acs_email_sender_workers) + length(azurerm_managed_redis_access_policy_assignment.workers) +
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 1 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      local.workers_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.workers_env == local.api_env
    )
    error_message = "Without the vault on entra both apps must stay on the apps identity, its grants and its administrator."
  }
}

run "no_vault_is_unchanged_on_byo_database" {
  command = apply

  variables {
    mode                  = "demo"
    enable_key_vault      = false
    api_max_replicas      = 1
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(module.workers_identity) + length(module.postgres_connection_urls_workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 2 &&
      length(azurerm_role_assignment.acr_pull_workers) + length(azurerm_role_assignment.kv_app_secrets_workers) +
      length(azurerm_role_assignment.kv_crypto_officer_workers) + length(azurerm_role_assignment.sb_sender_workers) +
      length(azurerm_role_assignment.sb_receiver_workers) + length(azurerm_role_assignment.sb_scaler_workers) +
      length(azurerm_role_assignment.acs_email_sender_workers) + length(azurerm_managed_redis_access_policy_assignment.workers) +
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      local.workers_env == local.api_env &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url"
    )
    error_message = "Without the vault on BYO-DB both apps must stay on the apps identity and the shared database-url."
  }
}
