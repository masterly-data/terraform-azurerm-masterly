# ca-workers' own identity (identity.tf workers_identity, workers.tf workers_own_identity) on each
# install shape where it runs as it: "job" on the starter server on both database_auth values,
# "start" on "password", and BYO-DB on both migrations values. The grants it holds, compared
# with the apps identity's (which gives up Service Bus Receiver and the jobs queue's Data Owner to
# it), and the frontend's and migrate job's grants beside them. The shapes where it stays on the
# apps identity are in tests/workers_identity_unchanged.tftest.hcl.
#
# Applies, in their own file, because the grants' scopes (the vault, the namespace, the queue,
# the ACS resource, the Redis instance) are computed: at plan they are unknown and
# `override_during = plan` needs Terraform 1.11 while CI runs 1.10. An apply (mock state; nothing
# reaches Azure) makes them known. A separate file keeps this state away from the runs of the
# other files. Every identity is overridden with a distinct principal, so a grant on the wrong one
# fails.

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

  # The app secrets role gets an id of its own, so the privilege-creep comparison below tells a
  # grant of it from a grant of any other role definition, which keeps the mock's shared id.
  override_resource {
    target = azurerm_role_definition.app_secrets
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000001"
    }
  }
}
mock_provider "random" {}
mock_provider "azapi" {}

# The same distinct principals for every run that does not name its own.
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
  redis_auth                     = "entra"
  enable_workers                 = true
  enable_service_bus             = true
  servicebus_sku                 = "Standard"
  email_acs_enabled              = true
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  migrations                     = "job"
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
}

# Every grant on, Azure Managed Redis, "entra" and PgBouncer.
run "workers_identity_gains_only_what_the_apps_identity_held_on_managed_redis" {
  command = apply

  variables {
    redis_offering     = "managed"
    database_auth      = "entra"
    postgres_pgbouncer = true
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

  # The ACS resources' IDs are parsed by the provider; the role assignment needs only the scope.
  override_module {
    target  = module.acs_email
    outputs = { communication_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly", endpoint = "https://acs-masterly.europe.communication.azure.com", sender_address = "DoNotReply@example.azurecomm.net" }
  }

  # The list below names every azurerm_role_assignment in the module, so a new one must be added.
  assert {
    condition     = length(regexall("resource \"azurerm_role_assignment\"", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) == 24
    error_message = "A role assignment was added or removed: name it in this file's grant lists."
  }

  # Threat: privilege creep. Every (scope, role name, role id) id-<prefix>-workers holds is also held by
  # the apps identity, among the role assignments and the Redis access policies, or is one of the
  # two the apps identity held before "job" and gives up to it: Service Bus Data Receiver on the
  # namespace and Data Owner on the jobs queue (ADR 0120).
  assert {
    condition = (
      length([
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : ra if ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ]) == 7 &&
      alltrue([
        for pair in [
          for ra in concat(
            azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
            azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
            azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
            azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
            azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
            values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
            values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
          ) : "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" if ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          ] : contains(concat([
            for ra in concat(
              azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
              azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
              azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
              azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
              azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
              values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
              values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
            ) : "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" if ra.principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            ], [
            "${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
            "${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
        ]), pair)
      ]) &&
      length(azurerm_managed_redis_access_policy_assignment.workers) == 1 &&
      azurerm_managed_redis_access_policy_assignment.workers[0].object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      alltrue([
        for a in azurerm_managed_redis_access_policy_assignment.workers :
        contains([for b in azurerm_managed_redis_access_policy_assignment.apps : b.managed_redis_id if b.object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], a.managed_redis_id)
      ]) &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0
    )
    error_message = "id-<prefix>-workers must hold its seven role assignments and its Redis policy, each on a (scope, role) the apps identity also holds or the Receiver and queue Data Owner it gave up."
  }

  # ca-api's identity sends alone; Receiver and the queue's Data Owner are ca-workers' own.
  assert {
    condition = (
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.sb_sender[0].scope == azurerm_servicebus_namespace.this[0].id &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      local.workers_scale_on_queue &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].scope != azurerm_servicebus_namespace.this[0].id
    )
    error_message = "With migrations = \"job\" the apps identity must hold Service Bus Sender alone, and id-<prefix>-workers Sender and Receiver on the namespace and Data Owner on the jobs queue alone."
  }

  # Each grant on its own scope: the vault, the registry, ACS, the namespace and the jobs queue.
  assert {
    condition = (
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      endswith(azurerm_role_definition.app_secrets[0].role_definition_resource_id, "/a99a5ec1-0000-4000-8000-000000000001") &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.acs_email_sender_workers[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly" &&
      azurerm_role_assignment.acs_email_sender_workers[0].role_definition_name == "Communication and Email Service Owner" &&
      azurerm_role_assignment.sb_sender_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_receiver_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].role_definition_name == "Azure Service Bus Data Owner" &&
      azurerm_managed_redis_access_policy_assignment.workers[0].managed_redis_id == azurerm_managed_redis.this[0].id &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 1 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "id-<prefix>-workers' grants must be on the vault, the registry, ACS, the namespace and the jobs queue; the migrate identity must be the only Postgres administrator."
  }

  # Threat, the public front door and the schema owner: the frontend holds AcrPull and Key Vault
  # Secrets User on each of its own secrets, nothing else; the migrate identity AcrPull and Secrets
  # User on its own secrets, as on main.
  assert {
    condition = (
      toset([
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : "${ra.scope}|${ra.role_definition_name}" if ra.principal_id == "ffffffff-ffff-ffff-ffff-ffffffffffff"
        ]) == toset(concat(
        ["${var.acr_id}|AcrPull"],
        [for name in local.frontend_secret_names : "${azurerm_key_vault_secret.install[name].resource_versionless_id}|Key Vault Secrets User"],
      )) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(local.frontend_secret_names) &&
      length(azurerm_role_assignment.acr_pull_frontend) == 1 &&
      toset([
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : ra.role_definition_name if ra.principal_id == "dddddddd-dddd-dddd-dddd-dddddddddddd"
      ]) == toset(["AcrPull", "Key Vault Secrets User"]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url", "migrate-database-direct-url"]) &&
      length(azurerm_role_assignment.acr_pull_migrate) == 1 &&
      alltrue([
        for ra in concat(
          azurerm_role_assignment.acr_pull_workers, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
        ) : ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ])
    )
    error_message = "The frontend identity must hold only AcrPull and Key Vault Secrets User on each of its own secrets, the migrate identity only AcrPull and Secrets User on its own, and every new grant must name id-<prefix>-workers."
  }

  # Each app signs in as its own role, through PgBouncer and directly, with no password.
  assert {
    condition = (
      can(regex("^postgresql\\+asyncpg://masterly_api@[^:/@]+:6432/[^?]+\\?ssl=require$", nonsensitive(local.api_database_url))) &&
      can(regex("^postgresql\\+asyncpg://masterly_api@[^:/@]+:5432/[^?]+\\?ssl=require$", nonsensitive(local.api_database_direct_url))) &&
      can(regex("^postgresql\\+asyncpg://masterly_workers@[^:/@]+:6432/[^?]+\\?ssl=require$", nonsensitive(local.workers_database_url))) &&
      can(regex("^postgresql\\+asyncpg://masterly_workers@[^:/@]+:5432/[^?]+\\?ssl=require$", nonsensitive(local.workers_database_direct_url))) &&
      nonsensitive(azurerm_key_vault_secret.install["api-database-url"].value) == nonsensitive(local.api_database_url) &&
      nonsensitive(azurerm_key_vault_secret.install["api-database-direct-url"].value) == nonsensitive(local.api_database_direct_url) &&
      nonsensitive(azurerm_key_vault_secret.install["workers-database-url"].value) == nonsensitive(local.workers_database_url) &&
      nonsensitive(azurerm_key_vault_secret.install["workers-database-direct-url"].value) == nonsensitive(local.workers_database_direct_url) &&
      startswith(nonsensitive(azurerm_key_vault_secret.install["database-url"].value), "postgresql+asyncpg://id-masterly-apps@")
    )
    error_message = "On entra with PgBouncer, ca-api's URLs must name masterly_api and ca-workers' masterly_workers, on 6432 and 5432, with no password; the shared URL stays as it was."
  }

  # Threat: ca-api must never run as ca-workers' identity, or the erasure grants reach it. Each app
  # runs, pulls, scales and resolves its references as its own, and a plan shows which that is.
  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      !issensitive(local.workers_own_identity) && !issensitive(local.workers_identity_id)
    )
    error_message = "With \"job\" on entra, ca-workers must run as id-<prefix>-workers and ca-api as id-<prefix>-apps alone, with each identity's AZURE_CLIENT_ID."
  }

  # ca-workers' DSNs are its own role's, through its own identity.
  assert {
    condition = (
      local.workers_own_dsn &&
      length(module.postgres_connection_urls_workers) == 1 &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "workers-database-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "workers-database-direct-url" &&
      local.backend_vault_secret_refs["workers-database-url"].identity_id == module.workers_identity[0].id &&
      local.backend_vault_secret_refs["workers-database-direct-url"].identity_id == module.workers_identity[0].id
    )
    error_message = "With \"job\" on the starter server ca-workers must read workers-database-url and workers-database-direct-url through id-<prefix>-workers."
  }
}

# The same comparison on Azure Cache for Redis and "password", without PgBouncer.
run "workers_identity_gains_only_what_the_apps_identity_held_on_azure_cache_for_redis" {
  command = apply

  variables {
    redis_offering = "cache"
    database_auth  = "password"
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

  override_module {
    target  = module.acs_email
    outputs = { communication_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly", endpoint = "https://acs-masterly.europe.communication.azure.com", sender_address = "DoNotReply@example.azurecomm.net" }
  }

  assert {
    condition = (
      alltrue([
        for pair in [
          for ra in concat(
            azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
            azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
            azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
            azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
            azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
            values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
            values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
          ) : "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" if ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          ] : contains(concat([
            for ra in concat(
              azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
              azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
              azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
              azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
              azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
              values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
              values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
            ) : "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" if ra.principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            ], [
            "${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
            "${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
        ]), pair)
      ]) &&
      length(azurerm_managed_redis_access_policy_assignment.workers) + length(azurerm_managed_redis_access_policy_assignment.apps) == 0 &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 1 &&
      alltrue([
        for a in azurerm_redis_cache_access_policy_assignment.workers :
        a.object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
        contains([for b in azurerm_redis_cache_access_policy_assignment.apps : "${b.redis_cache_id}|${b.access_policy_name}" if b.object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], "${a.redis_cache_id}|${a.access_policy_name}")
      ])
    )
    error_message = "On Azure Cache for Redis, every (scope, role) id-<prefix>-workers holds must also be held by the apps identity, its Redis policy included, or be the Receiver and queue Data Owner it gave up."
  }

  # On "password" too, ca-api's identity sends alone and ca-workers' own receives and scales.
  assert {
    condition = (
      length(azurerm_role_assignment.sb_sender) == 1 &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.sb_sender[0].scope == azurerm_servicebus_namespace.this[0].id &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_sender_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_receiver_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      local.workers_scale_on_queue &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].scope != azurerm_servicebus_namespace.this[0].id
    )
    error_message = "On password with migrations = \"job\" the apps identity must hold Service Bus Sender alone, and id-<prefix>-workers Sender and Receiver on the namespace and Data Owner on the jobs queue alone."
  }

  # Its own assignment on the cache, distinct from the apps identity's by name and alias.
  assert {
    condition = (
      azurerm_redis_cache_access_policy_assignment.workers[0].redis_cache_id == azurerm_redis_cache.this[0].id &&
      azurerm_redis_cache_access_policy_assignment.workers[0].access_policy_name == "Data Contributor" &&
      azurerm_redis_cache_access_policy_assignment.workers[0].name == "masterly-workers" &&
      azurerm_redis_cache_access_policy_assignment.workers[0].object_id_alias == "id-masterly-workers" &&
      azurerm_redis_cache_access_policy_assignment.apps[0].name == "masterly-apps" &&
      azurerm_redis_cache_access_policy_assignment.apps[0].object_id_alias == "id-masterly-apps" &&
      azurerm_redis_cache_access_policy_assignment.workers[0].name != azurerm_redis_cache_access_policy_assignment.apps[0].name &&
      azurerm_redis_cache_access_policy_assignment.workers[0].object_id_alias != azurerm_redis_cache_access_policy_assignment.apps[0].object_id_alias &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) + length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 0
    )
    error_message = "On Azure Cache for Redis, id-<prefix>-workers must get its own Data Contributor assignment, with a name and alias distinct from masterly-apps."
  }

  # Each URL carries its own role and that role's generated password, on 5432.
  assert {
    condition = (
      nonsensitive(azurerm_key_vault_secret.install["api-database-url"].value) == nonsensitive("postgresql+asyncpg://masterly_api:${random_password.migrate_api_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/postgres?ssl=require") &&
      nonsensitive(azurerm_key_vault_secret.install["workers-database-url"].value) == nonsensitive("postgresql+asyncpg://masterly_workers:${random_password.migrate_workers_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/postgres?ssl=require") &&
      !contains(keys(azurerm_key_vault_secret.install), "api-database-direct-url") &&
      !contains(keys(azurerm_key_vault_secret.install), "workers-database-direct-url") &&
      startswith(nonsensitive(azurerm_key_vault_secret.install["database-url"].value), "postgresql+asyncpg://masterly_admin:")
    )
    error_message = "On password, each app's URL must carry its own role and that role's generated password; the shared URL stays masterly_admin's."
  }

  # Threat: ca-api must never run as ca-workers' identity.
  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "workers-database-url" &&
      local.backend_vault_secret_refs["workers-database-url"].identity_id == module.workers_identity[0].id
    )
    error_message = "With \"job\" on password, ca-workers must run as id-<prefix>-workers and read workers-database-url through it, and ca-api must stay on id-<prefix>-apps alone."
  }

  # All seven of its grants, each on its own scope: the comparison above would also pass on none.
  assert {
    condition = (
      length(concat(
        azurerm_role_assignment.acr_pull_workers, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
      )) == 7 &&
      azurerm_role_assignment.acr_pull_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.acs_email_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acs_email_sender_workers[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly"
    )
    error_message = "With \"job\" on password, id-<prefix>-workers must hold all seven role assignments, AcrPull, the app secrets role, Crypto Officer and ACS Email Owner each on its own scope."
  }
}

# "password" with PgBouncer: each app's pooled (6432) and direct (5432) URLs carry its own role and
# password, each in its own vault secret.
run "backend_apps_get_their_own_password_urls_with_pgbouncer" {
  command = apply

  variables {
    redis_offering     = "cache"
    database_auth      = "password"
    postgres_pgbouncer = true
  }

  override_module {
    target  = module.acs_email
    outputs = { communication_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly", endpoint = "https://acs-masterly.europe.communication.azure.com", sender_address = "DoNotReply@example.azurecomm.net" }
  }

  assert {
    condition = (
      nonsensitive(azurerm_key_vault_secret.install["api-database-url"].value) == nonsensitive("postgresql+asyncpg://masterly_api:${random_password.migrate_api_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:6432/postgres?ssl=require") &&
      nonsensitive(azurerm_key_vault_secret.install["api-database-direct-url"].value) == nonsensitive("postgresql+asyncpg://masterly_api:${random_password.migrate_api_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/postgres?ssl=require") &&
      nonsensitive(azurerm_key_vault_secret.install["workers-database-url"].value) == nonsensitive("postgresql+asyncpg://masterly_workers:${random_password.migrate_workers_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:6432/postgres?ssl=require") &&
      nonsensitive(azurerm_key_vault_secret.install["workers-database-direct-url"].value) == nonsensitive("postgresql+asyncpg://masterly_workers:${random_password.migrate_workers_role[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/postgres?ssl=require") &&
      module.api.vault_backed_secret_names == tolist(["api-database-direct-url", "api-database-url", "bff-shared-secret", "database-direct-url", "database-url", "license-token", "redis-url", "session-secret"]) &&
      module.workers[0].vault_backed_secret_names == tolist(["license-token", "redis-url", "session-secret", "workers-database-direct-url", "workers-database-url"]) &&
      length(module.api.value_secret_names) + length(module.workers[0].value_secret_names) == 0
    )
    error_message = "On password with PgBouncer, each app's pooled and direct URLs must carry its own role and password, in its own vault secrets alone."
  }
}

# migrations = "start" on "password", with PgBouncer and Azure Managed Redis: ca-workers moves to
# its own identity, and with no masterly_workers role it reads the shared DSNs through it.
run "workers_own_identity_on_password_start" {
  command = apply

  variables {
    migrations         = "start"
    redis_offering     = "managed"
    database_auth      = "password"
    postgres_pgbouncer = true
  }

  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.workers[0].env_names == module.api.env_names &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      !issensitive(local.workers_own_identity) && !issensitive(local.workers_identity_id) &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "On password with \"start\", ca-workers must run as id-<prefix>-workers and ca-api as id-<prefix>-apps alone, with each identity's AZURE_CLIENT_ID."
  }

  # Every grant it needs, each on its own scope, and the two the apps identity gives up.
  assert {
    condition = (
      azurerm_role_assignment.acr_pull_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_sender_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_receiver_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.acs_email_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acs_email_sender_workers[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly" &&
      azurerm_managed_redis_access_policy_assignment.workers[0].object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_managed_redis_access_policy_assignment.workers[0].managed_redis_id == azurerm_managed_redis.this[0].id &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "On password with \"start\", id-<prefix>-workers must hold every backend grant on its own scope, and the apps identity no Receiver and no queue Data Owner."
  }

  # Threat: privilege creep, as in the first run of this file.
  assert {
    condition = [
      for held in [[
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : { principal = ra.principal_id, grant = "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" }
      ]] :
      length([for h in held : h if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]) == 7 &&
      alltrue([
        for h in held : contains(concat([for g in held : g.grant if g.principal == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], [
          "${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
          "${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
        ]), h.grant) if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ]) &&
      contains([for b in azurerm_managed_redis_access_policy_assignment.apps : b.managed_redis_id if b.object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], azurerm_managed_redis_access_policy_assignment.workers[0].managed_redis_id)
    ][0]
    error_message = "Every (scope, role) id-<prefix>-workers holds on password with \"start\" must also be held by the apps identity, or be the Receiver and queue Data Owner it gave up."
  }

  # The shared DSNs, through ca-workers' own identity. Nothing names the masterly_workers role,
  # which only the migrate job creates, or a secret no one writes.
  assert {
    condition = (
      !local.workers_own_dsn &&
      length(module.postgres_connection_urls_workers) + length(module.postgres_connection_urls_api) + length(random_password.migrate_workers_role) == 0 &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "database-direct-url" &&
      local.backend_vault_secret_refs["database-url"].identity_id == module.workers_identity[0].id &&
      local.backend_vault_secret_refs["database-direct-url"].identity_id == module.workers_identity[0].id &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      module.workers[0].vault_backed_secret_names == tolist(["database-direct-url", "database-url", "license-token", "redis-url", "session-secret"]) &&
      !anytrue([for name in keys(azurerm_key_vault_secret.install) : startswith(name, "api-") || startswith(name, "workers-")])
    )
    error_message = "On password with \"start\", ca-workers must read database-url and database-direct-url through id-<prefix>-workers, with no workers DSN planned."
  }
}

# BYO-DB with "start", on Azure Cache for Redis. There is no starter server for a workers DSN to
# name, and database_auth stays unset: the customer's DSN is the credential.
run "workers_own_identity_on_byo_database_with_start" {
  command = apply

  variables {
    migrations            = "start"
    redis_offering        = "cache"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.workers[0].env_names == module.api.env_names &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      !issensitive(local.workers_own_identity) && !issensitive(local.workers_identity_id) &&
      output.workers_identity_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "On BYO-DB with \"start\", ca-workers must run as id-<prefix>-workers and ca-api as id-<prefix>-apps alone, with each identity's AZURE_CLIENT_ID."
  }

  assert {
    condition = (
      azurerm_role_assignment.acr_pull_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_sender_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_receiver_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.acs_email_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acs_email_sender_workers[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly" &&
      azurerm_redis_cache_access_policy_assignment.workers[0].object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_redis_cache_access_policy_assignment.workers[0].redis_cache_id == azurerm_redis_cache.this[0].id &&
      length(azurerm_managed_redis_access_policy_assignment.workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "On BYO-DB with \"start\", id-<prefix>-workers must hold every backend grant on its own scope, and the apps identity no Receiver and no queue Data Owner."
  }

  # Threat: privilege creep, as in the first run of this file.
  assert {
    condition = [
      for held in [[
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : { principal = ra.principal_id, grant = "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" }
      ]] :
      length([for h in held : h if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]) == 7 &&
      alltrue([
        for h in held : contains(concat([for g in held : g.grant if g.principal == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], [
          "${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
          "${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
        ]), h.grant) if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ]) &&
      contains([for b in azurerm_redis_cache_access_policy_assignment.apps : "${b.redis_cache_id}|${b.access_policy_name}" if b.object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], "${azurerm_redis_cache_access_policy_assignment.workers[0].redis_cache_id}|${azurerm_redis_cache_access_policy_assignment.workers[0].access_policy_name}")
    ][0]
    error_message = "Every (scope, role) id-<prefix>-workers holds on BYO-DB with \"start\" must also be held by the apps identity, or be the Receiver and queue Data Owner it gave up."
  }

  # Threat: a workers DSN planned against a server that does not exist, or a secret no one writes.
  assert {
    condition = (
      !local.workers_own_dsn &&
      length(azurerm_postgresql_flexible_server.this) + length(module.postgres_connection_urls_workers) + length(random_password.migrate_workers_role) == 0 &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.backend_vault_secret_refs["database-url"].identity_id == module.workers_identity[0].id &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      !anytrue([for name in keys(azurerm_key_vault_secret.install) : startswith(name, "api-") || startswith(name, "workers-")])
    )
    error_message = "On BYO-DB ca-workers must read the shared database-url through id-<prefix>-workers, with no workers DSN planned and no workers secret named."
  }
}

# BYO-DB with "job": the migrate job exists, but creates no app roles on the customer's database,
# so ca-workers moves to its own identity and keeps the shared DSN.
run "workers_own_identity_on_byo_database_with_job" {
  command = apply

  variables {
    migrations            = "job"
    redis_offering        = "managed"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].secret_ref_identity_ids == tolist([module.workers_identity[0].id]) &&
      module.workers[0].registry.identity == module.workers_identity[0].id &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == module.workers_identity[0].id &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.workers[0].env_names == module.api.env_names &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      local.api_env["AZURE_CLIENT_ID"] == "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc" &&
      !issensitive(local.workers_own_identity) && !issensitive(local.workers_identity_id)
    )
    error_message = "On BYO-DB with \"job\", ca-workers must run as id-<prefix>-workers and ca-api as id-<prefix>-apps alone, with each identity's AZURE_CLIENT_ID."
  }

  assert {
    condition = (
      azurerm_role_assignment.acr_pull_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acr_pull_workers[0].scope == var.acr_id &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_sender_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_receiver_workers[0].scope == azurerm_servicebus_namespace.this[0].id &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_scaler_workers[0].scope == azurerm_servicebus_queue.jobs[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.acs_email_sender_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.acs_email_sender_workers[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly" &&
      azurerm_managed_redis_access_policy_assignment.workers[0].object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_managed_redis_access_policy_assignment.workers[0].managed_redis_id == azurerm_managed_redis.this[0].id &&
      length(azurerm_redis_cache_access_policy_assignment.workers) == 0 &&
      length(azurerm_role_assignment.sb_receiver) + length(azurerm_role_assignment.sb_scaler) == 0 &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "On BYO-DB with \"job\", id-<prefix>-workers must hold every backend grant on its own scope, and the apps identity no Receiver and no queue Data Owner."
  }

  # Threat: privilege creep, as in the first run of this file.
  assert {
    condition = [
      for held in [[
        for ra in concat(
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers, azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader), azurerm_role_assignment.frontend_certificate_reader,
        ) : { principal = ra.principal_id, grant = "${ra.scope}|${ra.role_definition_name}|${ra.role_definition_id}" }
      ]] :
      length([for h in held : h if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]) == 7 &&
      alltrue([
        for h in held : contains(concat([for g in held : g.grant if g.principal == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], [
          "${azurerm_servicebus_namespace.this[0].id}|Azure Service Bus Data Receiver|(assigned by name)",
          "${azurerm_servicebus_queue.jobs[0].id}|Azure Service Bus Data Owner|(assigned by name)",
        ]), h.grant) if h.principal == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      ]) &&
      contains([for b in azurerm_managed_redis_access_policy_assignment.apps : b.managed_redis_id if b.object_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"], azurerm_managed_redis_access_policy_assignment.workers[0].managed_redis_id)
    ][0]
    error_message = "Every (scope, role) id-<prefix>-workers holds on BYO-DB with \"job\" must also be held by the apps identity, or be the Receiver and queue Data Owner it gave up."
  }

  # The identity moves; the role does not exist. The job is told of no workers role either.
  assert {
    condition = (
      !local.workers_own_dsn &&
      length(azurerm_postgresql_flexible_server.this) + length(module.postgres_connection_urls_workers) + length(random_password.migrate_workers_role) == 0 &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.backend_vault_secret_refs["database-url"].identity_id == module.workers_identity[0].id &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      !anytrue([for k in keys(local.migrate_env) : startswith(k, "MASTERLY_MIGRATE_")]) &&
      !anytrue([for name in keys(azurerm_key_vault_secret.install) : startswith(name, "api-") || startswith(name, "workers-")])
    )
    error_message = "On BYO-DB with \"job\" ca-workers must read the shared database-url through id-<prefix>-workers, and nothing may name a workers role or DSN."
  }
}

# Threat: a grant removed before its replacement exists stalls the jobs pipeline mid-upgrade.
# Terraform test cannot read depends_on, so this reads it: comments stripped, and each name with
# its trailing comma, so sb_receiver does not match sb_receiver_workers.
run "workers_depends_on_every_grant_it_replaces" {
  command = plan

  variables {
    migrations     = "start"
    redis_offering = "managed"
    database_auth  = "password"
  }

  assert {
    condition = alltrue([
      for ref in [
        "azurerm_role_assignment.acr_pull_workers,",
        "azurerm_role_assignment.kv_app_secrets_workers,",
        "azurerm_role_assignment.kv_crypto_officer_workers,",
        "azurerm_role_assignment.sb_sender_workers,",
        "azurerm_role_assignment.sb_receiver_workers,",
        "azurerm_role_assignment.sb_scaler_workers,",
        "azurerm_role_assignment.acs_email_sender_workers,",
        "azurerm_managed_redis_access_policy_assignment.workers,",
        "azurerm_redis_cache_access_policy_assignment.workers,",
        "azurerm_role_assignment.sb_receiver,",
        "azurerm_role_assignment.sb_scaler,",
        "azurerm_postgresql_flexible_server_active_directory_administrator.apps,",
      ] :
      strcontains(replace(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)module \"workers\" \\{(.*?)\\n\\}", file("${path.module}/workers.tf"))[0])[0], "/#[^\\n]*/", ""), ref)
    ])
    error_message = "ca-workers must depend on every *_workers grant and Redis policy, so they exist before its update, and on sb_receiver, sb_scaler and the apps' Entra administrator, so their removal follows it."
  }

  # The identity follows the vault; the migrate job's need for it, and the DSN, follow the app roles.
  assert {
    condition = (
      strcontains(regex("(?s)module \"workers_identity\" \\{(.*?)\\n\\}", file("${path.module}/identity.tf"))[0], "count  = local.migrate_app_roles || local.workers_own_identity ? 1 : 0") &&
      strcontains(regex("(?s)module \"postgres_connection_urls_workers\" \\{(.*?)\\n\\}", file("${path.module}/main.tf"))[0], "count  = local.workers_own_dsn ? 1 : 0") &&
      strcontains(file("${path.module}/workers.tf"), "workers_own_dsn = local.migrate_app_roles && var.enable_workers") &&
      startswith(regex("workers_own_identity = (.*)", file("${path.module}/workers.tf"))[0], "var.enable_workers && var.enable_key_vault && ")
    )
    error_message = "module.workers_identity must exist with the app roles or where ca-workers runs as it; the workers DSN must follow local.workers_own_dsn; and workers_own_identity must need ca-workers and the vault."
  }
}

# "job" without ca-workers cannot be planned on either value of mode: production requires
# ca-workers, and "job" refuses demo. So no plan can show module.workers_identity on that shape, and
# these two runs prove only that it is refused. The source-reading run above holds the identity's
# count to the app roles and workers_own_identity to enable_workers, should either refusal change.
run "job_without_workers_is_refused_on_production" {
  command = plan

  variables {
    migrations     = "job"
    enable_workers = false
    redis_offering = "managed"
    database_auth  = "password"
  }

  expect_failures = [var.enable_workers]
}

run "job_without_workers_is_refused_on_demo" {
  command = plan

  variables {
    mode             = "demo"
    migrations       = "job"
    enable_workers   = false
    api_max_replicas = 1
    redis_offering   = "managed"
    database_auth    = "password"
  }

  expect_failures = [var.migrations]
}
