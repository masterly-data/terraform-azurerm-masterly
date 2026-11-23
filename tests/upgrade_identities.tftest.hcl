# An upgrade from the published 0.26.0 to this working tree, on one state (ADR 0120 §6, one
# workload identity per role). Each scenario applies 0.26.0 from the registry first, then this
# module on the same state_key, so the second apply starts from the state a running install has:
# the moved blocks (keyvault.tf) must find their old addresses, the Crypto Officer grants must leave
# the state, and the grants, identities and env each role ends with are asserted.
#
# Nothing reaches Azure: the providers are mocked, and a mock provider never performs a forced
# replacement (it updates in place; a renamed vault was tried and kept every value). So these runs
# cannot show whether the vault, the server, the Service Bus namespace or an environment would be
# replaced, nor tell which grant Azure creates first. Those rest
# on this release changing no argument of those four, on the ordering edges that
# tests/keyvault.tftest.hcl reads from the files, and on a live plan against a running install.
#
# Needs the registry at `terraform init`, as the providers do.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  override_resource {
    target = azurerm_managed_redis.this
    values = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-test"
      default_database = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redisEnterprise/redis-masterly-test/databases/default" }
    }
  }

  # A distinct id per role definition the module defines, so a grant's role is told apart.
  override_resource {
    target = azurerm_role_definition.app_secrets
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000001"
    }
  }

  override_resource {
    target = azurerm_role_definition.signing_key_reader
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000002"
    }
  }

  override_resource {
    target = azurerm_role_definition.signing_keys
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000003"
    }
  }
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
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
  database_auth                  = "entra"
  enable_workers                 = true
  enable_service_bus             = true
  servicebus_sku                 = "Standard"
  email_acs_enabled              = true
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
}

# --- A production install already on migrations = "job" ------------------------------------

run "job_install_on_0_26_0" {
  command   = apply
  state_key = "job"

  module {
    source  = "masterly-data/masterly/azurerm"
    version = "0.26.0"
  }

  variables {
    migrations = "job"
  }
}

# The upgrade with migrations left unset: the install's caj-migrate exists, so the default keeps
# "job" (migrate.tf, local.recorded_migrations) and the plan is not refused.
run "job_install_upgrades_with_no_crypto_officer" {
  command   = apply
  state_key = "job"

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
    condition     = local.migrate_job && output.migrate_job_name == "caj-migrate"
    error_message = "An install whose caj-migrate exists must keep migrations = \"job\" when the input is unset."
  }

  # The identities keep their names and principals: ca-api on id-<prefix>-apps, ca-workers on
  # id-<prefix>-workers, and neither carries the other's.
  assert {
    condition = (
      output.apps_identity_principal_id == run.job_install_on_0_26_0.apps_identity_principal_id &&
      output.workers_identity_principal_id == run.job_install_on_0_26_0.workers_identity_principal_id &&
      module.api.user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      local.api_env["AZURE_CLIENT_ID"] == module.apps_identity.client_id &&
      local.workers_env["AZURE_CLIENT_ID"] == module.workers_identity[0].client_id
    )
    error_message = "After the upgrade ca-api must run as id-<prefix>-apps and ca-workers as id-<prefix>-workers, each with its own AZURE_CLIENT_ID."
  }

  # Crypto Officer is gone: ca-api holds the key reader role, ca-workers the signing keys role.
  assert {
    condition = (
      length(azurerm_role_assignment.kv_signing_key_reader) == 1 &&
      azurerm_role_assignment.kv_signing_key_reader[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.kv_signing_key_reader[0].role_definition_id == azurerm_role_definition.signing_key_reader[0].role_definition_resource_id &&
      length(azurerm_role_assignment.kv_signing_keys) == 0 &&
      length(azurerm_role_assignment.kv_signing_keys_workers) == 1 &&
      azurerm_role_assignment.kv_signing_keys_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_signing_keys_workers[0].role_definition_id == azurerm_role_definition.signing_keys[0].role_definition_resource_id
    )
    error_message = "After the upgrade ca-api's identity must hold the signing key reader role and ca-workers' the signing keys role, and neither Key Vault Crypto Officer."
  }

  # The migrate job's identity is the only Postgres administrator.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == "dddddddd-dddd-dddd-dddd-dddddddddddd"
    )
    error_message = "After the upgrade the migrate job's identity must be the only Postgres Entra administrator."
  }
}

# --- A production install on 0.26.0's default, migrations = "start" ------------------------

run "start_install_on_0_26_0" {
  command   = apply
  state_key = "start"

  module {
    source  = "masterly-data/masterly/azurerm"
    version = "0.26.0"
  }
}

# Kept at "start", stated: ca-workers stays on the apps identity (the one documented exception),
# which then holds the signing keys role in place of Crypto Officer.
run "start_install_upgrades_keeping_start" {
  command   = apply
  state_key = "start"

  variables {
    migrations = "start"
  }

  # The departure is stated, not refused: the check warns, and the apply goes ahead.
  expect_failures = [check.production_migrations_at_start]


  assert {
    condition = (
      !local.workers_own_identity &&
      module.workers[0].user_assigned_identity_ids == tolist([module.apps_identity.id]) &&
      length(azurerm_role_assignment.kv_signing_key_reader) == 1 &&
      length(azurerm_role_assignment.kv_signing_keys) == 1 &&
      azurerm_role_assignment.kv_signing_keys[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.kv_signing_keys[0].role_definition_id == azurerm_role_definition.signing_keys[0].role_definition_resource_id &&
      length(azurerm_role_assignment.kv_signing_keys_workers) == 0
    )
    error_message = "With migrations = \"start\" on \"entra\", ca-workers stays on the apps identity, which then holds the signing keys role (and the reader role) instead of Crypto Officer."
  }
}

# Then the move to the migrate job, in one apply on the same state: the migrate identity becomes the only administrator, and ca-workers moves to its own identity.
run "start_install_moves_to_the_migrate_job" {
  command   = apply
  state_key = "start"

  variables {
    migrations = "job"
  }


  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.apps) == 0 &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migrate[0].object_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      length(azurerm_role_assignment.kv_signing_keys) == 0 &&
      length(azurerm_role_assignment.kv_signing_keys_workers) == 1
    )
    error_message = "After the move the migrate identity must be the only administrator, ca-workers must run as its own identity, and the signing keys role must move with it."
  }
}

# --- An evaluation install with ca-workers and no vault (mode = "demo") ----------------------

run "demo_install_without_a_vault_on_0_26_0" {
  command   = apply
  state_key = "demo"

  module {
    source  = "masterly-data/masterly/azurerm"
    version = "0.26.0"
  }

  variables {
    mode                       = "demo"
    enable_key_vault           = false
    database_auth              = "password"
    redis_auth                 = "key"
    postgres_zone_redundant_ha = false
  }
}

# Until this release ca-workers ran as the apps identity on an install without the vault; now it
# runs as its own there too, which takes the Service Bus receive grant with it.
run "demo_install_moves_ca_workers_to_its_own_identity" {
  command   = apply
  state_key = "demo"

  variables {
    mode                       = "demo"
    enable_key_vault           = false
    database_auth              = "password"
    redis_auth                 = "key"
    postgres_zone_redundant_ha = false
  }


  assert {
    condition = (
      !local.migrate_job &&
      local.workers_own_identity &&
      module.workers[0].user_assigned_identity_ids == tolist([module.workers_identity[0].id]) &&
      local.workers_env["AZURE_CLIENT_ID"] == module.workers_identity[0].client_id &&
      length(azurerm_role_assignment.sb_receiver) == 0 &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.sb_sender[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "Without the vault, ca-workers must now run as its own identity and hold Service Bus receive, with ca-api keeping send alone."
  }
}
