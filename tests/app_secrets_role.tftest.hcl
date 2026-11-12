# The apps' role on the install vault (keyvault.tf, app_secrets): ca-api's identity, and
# ca-workers' own when it has one, read, write and delete secrets through a role defined by this
# module, not through Key Vault Secrets Officer, whose secrets/* also carries purge, backup,
# restore and recover.
#
# Applies, in their own file, for the reason workers_identity.tftest.hcl gives: the vault's id and
# the role's id are computed, so at plan they are unknown on Terraform 1.10. Every identity is
# overridden with a distinct principal, so a grant on the wrong one fails.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  # The role gets an id of its own, so a grant of any other role definition, which keeps the mock's
  # shared id, does not count as a grant of it.
  override_resource {
    target = azurerm_role_definition.app_secrets
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000001"
    }
  }
}
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "a1b2c3" }
  }
}
mock_provider "azapi" {}

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
  redis_offering                 = "cache"
  enable_workers                 = true
  enable_service_bus             = true
  servicebus_sku                 = "Standard"
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
}

# The role itself, whatever the identities: exactly four secret data actions, no control plane,
# an install-unique name, and assignable within the data resource group alone.
run "app_secrets_role_reads_writes_and_deletes_secrets_and_nothing_more" {
  command = apply

  variables {
    migrations = "start"
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

  # Threat: a wildcard, deletedSecrets/*, keys/* or secrets/update/action silently gives back what
  # Secrets Officer carried. The set is exact, so any extra action fails here.
  assert {
    condition = (
      length(azurerm_role_definition.app_secrets) == 1 &&
      length(azurerm_role_definition.app_secrets[0].permissions) == 1 &&
      toset(azurerm_role_definition.app_secrets[0].permissions[0].data_actions) == toset([
        "Microsoft.KeyVault/vaults/secrets/getSecret/action",
        "Microsoft.KeyVault/vaults/secrets/setSecret/action",
        "Microsoft.KeyVault/vaults/secrets/delete",
        "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
      ]) &&
      length(azurerm_role_definition.app_secrets[0].permissions[0].data_actions) == 4 &&
      length(coalesce(azurerm_role_definition.app_secrets[0].permissions[0].actions, [])) == 0 &&
      length(coalesce(azurerm_role_definition.app_secrets[0].permissions[0].not_data_actions, [])) == 0 &&
      alltrue([for a in azurerm_role_definition.app_secrets[0].permissions[0].data_actions : !strcontains(a, "*") && !strcontains(a, "deletedSecrets") && !strcontains(a, "/keys/")])
    )
    error_message = "The app secrets role must hold exactly getSecret, setSecret, delete and readMetadata on secrets: no wildcard, no deletedSecrets, no keys, no update and no control-plane action."
  }

  # Threat: two installs in one tenant collide on the role's name, or the role is assignable beyond
  # the install.
  assert {
    condition = (
      strcontains(azurerm_role_definition.app_secrets[0].name, random_string.install.result) &&
      azurerm_role_definition.app_secrets[0].scope == azurerm_resource_group.data.id &&
      tolist(azurerm_role_definition.app_secrets[0].assignable_scopes) == tolist([azurerm_resource_group.data.id])
    )
    error_message = "The app secrets role's name must carry the install suffix, and it must be defined on and assignable only within the data resource group."
  }

  # Shared identity: ca-api's identity holds the role on the vault, ca-workers runs as the same
  # identity, and no app identity holds Secrets Officer on the vault.
  assert {
    condition = (
      !local.workers_own_identity &&
      length(azurerm_role_assignment.kv_app_secrets) == 1 &&
      length(azurerm_role_assignment.kv_app_secrets_workers) == 0 &&
      azurerm_role_assignment.kv_app_secrets[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      endswith(azurerm_role_definition.app_secrets[0].role_definition_resource_id, "/a99a5ec1-0000-4000-8000-000000000001") &&
      azurerm_role_assignment.kv_app_secrets[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      alltrue([for ref in values(local.backend_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      length(local.api_vault_secret_refs) > 0 && length(local.backend_vault_secret_refs) > 0
    )
    error_message = "With a shared identity, ca-api's identity must hold the app secrets role on the vault, and every api and backend vault reference must resolve as it."
  }

  # Threat: the role reaches the public front door or the schema owner, or Secrets Officer is still
  # granted to an app identity on the vault, by name or by its built-in id, among the vault grants.
  assert {
    condition = (
      length([
        for ra in concat(
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        ) : ra if ra.role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id
      ]) == 1 &&
      length([
        for ra in concat(
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_crypto_officer_workers,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        ) : ra if(ra.role_definition_name == "Key Vault Secrets Officer" || endswith(lower(ra.role_definition_id), "/b86a8fe4-44ce-4948-aee5-eccb2c155cd7")) && contains(["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "ffffffff-ffff-ffff-ffff-ffffffffffff", "dddddddd-dddd-dddd-dddd-dddddddddddd"], ra.principal_id)
      ]) == 0
    )
    error_message = "With a shared identity, only ca-api's identity may hold the app secrets role, and no app identity may hold Key Vault Secrets Officer on the vault."
  }

  # The Crypto Officer grant stays as it was.
  assert {
    condition = (
      azurerm_role_assignment.kv_crypto_officer[0].role_definition_name == "Key Vault Crypto Officer" &&
      azurerm_role_assignment.kv_crypto_officer[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_crypto_officer[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "ca-api's identity keeps Key Vault Crypto Officer on the vault for the erasure keys."
  }
}

# ca-workers' own identity (migrations = "job" on the starter server): it holds the role too, and
# ca-workers' references resolve as it. Neither app identity holds Secrets Officer, and the
# frontend and migrate identities hold no grant of the role.
run "app_secrets_role_on_ca_workers_own_identity" {
  command = apply

  variables {
    migrations    = "job"
    database_auth = "password"
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
      local.workers_own_identity &&
      length(azurerm_role_definition.app_secrets) == 1 &&
      azurerm_role_assignment.kv_app_secrets[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.kv_app_secrets[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      length(azurerm_role_assignment.kv_app_secrets_workers) == 1 &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      alltrue([for ref in values(local.api_vault_secret_refs) : ref.identity_id == module.apps_identity.id]) &&
      alltrue([for ref in values(local.backend_vault_secret_refs) : ref.identity_id == module.workers_identity[0].id]) &&
      length(local.api_vault_secret_refs) > 0 && length(local.backend_vault_secret_refs) > 0
    )
    error_message = "With ca-workers on its own identity, both ca-api's and ca-workers' identities must hold the app secrets role on the vault, and each app's vault references must resolve as its own identity."
  }

  # Threat: the role reaches the public front door or the schema owner, or Secrets Officer is
  # still granted to an app identity on the vault.
  assert {
    condition = (
      length([
        for ra in concat(
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_crypto_officer_workers,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        ) : ra if ra.role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id
      ]) == 2 &&
      length([
        for ra in concat(
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_crypto_officer, azurerm_role_assignment.kv_crypto_officer_workers,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        ) : ra if(ra.role_definition_name == "Key Vault Secrets Officer" || endswith(lower(ra.role_definition_id), "/b86a8fe4-44ce-4948-aee5-eccb2c155cd7")) && contains(["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "ffffffff-ffff-ffff-ffff-ffffffffffff", "dddddddd-dddd-dddd-dddd-dddddddddddd"], ra.principal_id)
      ]) == 0
    )
    error_message = "Only ca-api's and ca-workers' identities may hold the app secrets role, and no app identity may hold Key Vault Secrets Officer on the vault."
  }

  # The Crypto Officer grants stay as they were.
  assert {
    condition = (
      azurerm_role_assignment.kv_crypto_officer[0].role_definition_name == "Key Vault Crypto Officer" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].role_definition_name == "Key Vault Crypto Officer" &&
      azurerm_role_assignment.kv_crypto_officer_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "Both app identities keep Key Vault Crypto Officer on the vault for the erasure keys."
  }
}

# Without the vault there is no role to define.
run "no_app_secrets_role_without_the_vault" {
  command = plan

  variables {
    mode             = "demo"
    enable_key_vault = false
  }

  assert {
    condition     = length(azurerm_role_definition.app_secrets) == 0 && length(azurerm_role_assignment.kv_app_secrets) == 0 && length(azurerm_role_assignment.kv_app_secrets_workers) == 0
    error_message = "With enable_key_vault = false the module must plan no app secrets role and no grant of it."
  }
}

# Threat: an upgrade leaves an app without its grant. Both grants keep the address the Secrets
# Officer grant had (moved), so an upgrade replaces each grant at one address rather than adding a
# new grant beside a removed block, whose orphaned destroy nothing would order. Both apps depend on
# those addresses, so neither is updated before its new grant exists. create_before_destroy is not
# used: on these grants it puts the app modules in a dependency cycle.
run "app_secrets_grants_keep_their_addresses_and_the_apps_depend_on_them" {
  command = plan

  variables {
    mode             = "demo"
    enable_key_vault = false
  }

  assert {
    condition = (
      can(regex("moved \\{\\s*from = azurerm_role_assignment\\.kv_secrets_officer\\s+to   = azurerm_role_assignment\\.kv_app_secrets\\s*\\}", file("${path.module}/keyvault.tf"))) &&
      can(regex("moved \\{\\s*from = azurerm_role_assignment\\.kv_secrets_officer_workers\\s+to   = azurerm_role_assignment\\.kv_app_secrets_workers\\s*\\}", file("${path.module}/keyvault.tf"))) &&
      !can(regex("resource \"azurerm_role_assignment\" \"kv_secrets_officer(_workers)?\"", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) &&
      strcontains(regex("(?s)\\nmodule \"api\" \\{.*?\\n\\}\\n", file("${path.module}/main.tf")), "azurerm_role_assignment.kv_app_secrets,") &&
      strcontains(regex("(?s)\\nmodule \"workers\" \\{.*?\\n\\}\\n", file("${path.module}/workers.tf")), "azurerm_role_assignment.kv_app_secrets,") &&
      strcontains(regex("(?s)\\nmodule \"workers\" \\{.*?\\n\\}\\n", file("${path.module}/workers.tf")), "azurerm_role_assignment.kv_app_secrets_workers,")
    )
    error_message = "kv_app_secrets and kv_app_secrets_workers must be moved from the Secrets Officer grants' addresses, with no block left at the old addresses, and module.api and module.workers must depend on them."
  }
}
