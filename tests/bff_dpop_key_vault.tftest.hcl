# The BFF's DPoP key with the vault on (auth.tf, keyvault.tf): each slot is a vault secret whose
# value is the key's PKCS#8 PEM, ca-frontend references it by its versionless URL as its own
# identity, and that identity holds Key Vault Secrets User on each slot's secret alone.
#
# An apply, in its own file, for the reason keyvault.tftest.hcl's last run gives: the secrets' ids
# and the grants' scopes are computed, so at plan they are unknown on Terraform 1.10. It targets the
# frontend's grants and so applies only what they depend on (the vault, its secrets and their
# inputs, the two keys and their timers among them), each with a well-formed ID, because the
# teardown at the end of the file evaluates the whole configuration against this state. The
# timers start as a first apply starts them, B a moment after A, so slot A is current and no
# overlap is open.
#
# A targeted apply evaluates only what its targets depend on, and the apps' secret and env maps
# are not among them, so a plan of the whole configuration against that state asserts those. The
# variables and overrides are file-wide, so the plan sees the same install as the apply.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "tls" {}
mock_provider "time" {
  mock_resource "time_rotating" {
    defaults = {
      rfc3339          = "2026-01-01T00:00:00Z"
      rotation_rfc3339 = "2026-06-30T00:00:00Z"
    }
  }
}

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

  # The install both runs see: production, with the vault on and the DPoP key on.
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
  registry_username    = "install-puller"
  registry_password    = "pull-secret"
  telemetry_url        = "https://cp.masterlydata.com"
  telemetry_client_id  = "sa_01TEST"

  telemetry_client_secret = "telemetry-secret"
  breakglass_owner_email  = "owner@example.com"
  breakglass_secret_hash  = "0000000000000000000000000000000000000000000000000000000000000000"
  external_database_url   = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  migrations              = "job"

  key_vault_secret_operator_object_ids = ["11111111-1111-1111-1111-111111111111"]

  enable_bff_dpop_key = true
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

override_resource {
  target = azurerm_resource_group.data
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
  }
}

override_resource {
  target = azurerm_key_vault.this
  values = {
    id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test"
    vault_uri = "https://kv-masterly-test.vault.azure.net/"
  }
}

override_resource {
  target = azurerm_redis_cache.this
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redis/redis-masterly-test"
  }
}

# A first apply: B's timer is created two seconds after A's. That is no rotation, so A, the key
# this apply hands out, is the current one and nothing is outgoing.
override_resource {
  target = time_rotating.bff_dpop_key_a
  values = {
    rfc3339          = "2026-01-01T00:00:00Z"
    rotation_rfc3339 = "2026-06-30T00:00:00Z"
  }
}

override_resource {
  target = time_rotating.bff_dpop_key_b
  values = {
    rfc3339 = "2026-01-01T00:00:02Z"
  }
}

# Placeholders, not keys: the runs assert the wiring, never key material.
override_resource {
  target = tls_private_key.bff_dpop_key_a
  values = {
    private_key_pem_pkcs8 = "placeholder-not-a-key-slot-a"
  }
}

override_resource {
  target = tls_private_key.bff_dpop_key_b
  values = {
    private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["bff-dpop-key-a"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-bff-dpop-key-a"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-bff-dpop-key-a"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["bff-dpop-key-b"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-bff-dpop-key-b"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-bff-dpop-key-b"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["bff-shared-secret"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-bff-shared-secret"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-bff-shared-secret"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["registry-password"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-registry-password"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-registry-password"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["oidc-client-secret"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-oidc-client-secret"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-oidc-client-secret"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["database-url"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-database-url"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-database-url"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["session-secret"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-session-secret"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-session-secret"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["license-token"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-license-token"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-license-token"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["redis-url"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-redis-url"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-redis-url"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["telemetry-client-secret"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-telemetry-client-secret"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-telemetry-client-secret"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["breakglass-secret-hash"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-breakglass-secret-hash"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-breakglass-secret-hash"
  }
}

override_resource {
  target = azurerm_key_vault_secret.install["migrate-database-url"]
  values = {
    versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-migrate-database-url"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-migrate-database-url"
  }
}

run "bff_dpop_key_in_the_vault_is_read_by_the_frontend_alone" {
  command = apply

  plan_options {
    target = [azurerm_role_assignment.kv_secrets_user_frontend, time_rotating.bff_dpop_key_a, time_rotating.bff_dpop_key_b]
  }

  # The key is EC P-256, and each slot's vault secret holds that slot's key as PKCS#8 PEM.
  assert {
    condition = alltrue([
      for slot, key in { "bff-dpop-key-a" = tls_private_key.bff_dpop_key_a[0], "bff-dpop-key-b" = tls_private_key.bff_dpop_key_b[0] } :
      key.algorithm == "ECDSA" && key.ecdsa_curve == "P256" &&
      azurerm_key_vault_secret.install[slot].value == key.private_key_pem_pkcs8 &&
      azurerm_key_vault_secret.install[slot].name == "install-${slot}"
    ])
    error_message = "Each DPoP slot must be an ECDSA P256 key, written to its own vault secret (install-bff-dpop-key-a, -b) as the key's private_key_pem_pkcs8."
  }

  # Threat, a stolen frontend: its identity holds Key Vault Secrets User on each DPoP slot's
  # secret alone, scoped to that secret's ARM id, and no grant at all at vault scope.
  assert {
    condition = alltrue([
      for slot in ["bff-dpop-key-a", "bff-dpop-key-b"] :
      azurerm_role_assignment.kv_secrets_user_frontend[slot].scope == azurerm_key_vault_secret.install[slot].resource_versionless_id &&
      azurerm_role_assignment.kv_secrets_user_frontend[slot].scope != azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_secrets_user_frontend[slot].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.kv_secrets_user_frontend[slot].principal_id == module.frontend_identity.principal_id
    ])
    error_message = "The frontend identity must hold Key Vault Secrets User on each DPoP slot's secret, scoped to its resource_versionless_id, never to the vault."
  }

  # No grant at vault scope: none of the frontend's grants is on the vault, and kv_secrets_user_frontend
  # is the only Key Vault grant the module gives the frontend identity at all.
  assert {
    condition = (
      alltrue([for ra in values(azurerm_role_assignment.kv_secrets_user_frontend) : ra.scope != azurerm_key_vault.this[0].id]) &&
      length(regexall("module\\.frontend_identity\\.principal_id", file("${path.module}/keyvault.tf"))) == 1 &&
      can(regex("resource \"azurerm_role_assignment\" \"kv_secrets_user_frontend\" \\{[^}]*module\\.frontend_identity\\.principal_id", file("${path.module}/keyvault.tf")))
    )
    error_message = "The frontend identity must hold no grant at vault scope: its only Key Vault grants are kv_secrets_user_frontend, each scoped to one secret."
  }
}

# The whole configuration, planned against the state the apply left: ca-frontend's references and
# env names, and the other apps' secrets and env.
run "bff_dpop_key_in_the_vault_reaches_ca_frontend_alone" {
  command = plan

  # ca-frontend references each slot by its versionless URL as its own identity, and reads the
  # current one (A: both timers started together, so no rotation has happened) as
  # MASTERLY_BFF_DPOP_KEY, with no _PREVIOUS.
  assert {
    condition = (
      alltrue([
        for slot in ["bff-dpop-key-a", "bff-dpop-key-b"] :
        local.frontend_vault_secret_refs[slot].kv_secret_id == azurerm_key_vault_secret.install[slot].versionless_id &&
        local.frontend_vault_secret_refs[slot].identity_id == module.frontend_identity.id
      ]) &&
      local.frontend_env_secret_refs["MASTERLY_BFF_DPOP_KEY"] == "bff-dpop-key-a" &&
      !contains(keys(local.frontend_env_secret_refs), "MASTERLY_BFF_DPOP_KEY_PREVIOUS") &&
      length(local.frontend_value_secrets) == 0
    )
    error_message = "ca-frontend must reference each DPoP slot's vault secret by its versionless_id as the frontend identity, and read slot A as MASTERLY_BFF_DPOP_KEY with no MASTERLY_BFF_DPOP_KEY_PREVIOUS before any rotation."
  }

  # ca-api, ca-workers and caj-migrate carry neither slot and neither env name.
  assert {
    condition = (
      length([for n in concat(
        local.api_secret_names, local.backend_secret_names, local.migrate_secret_names,
        keys(local.api_vault_secret_refs), keys(local.backend_vault_secret_refs), keys(local.migrate_vault_secret_refs),
      ) : n if startswith(n, "bff-dpop-key")]) == 0 &&
      length([for n in concat(
        keys(local.api_env_secret_refs), keys(local.backend_env_secret_refs), keys(local.migrate_env_secret_refs),
      ) : n if startswith(n, "MASTERLY_BFF_DPOP_KEY")]) == 0
    )
    error_message = "ca-api, ca-workers and caj-migrate must carry no BFF DPoP key secret, vault reference or env."
  }
}
