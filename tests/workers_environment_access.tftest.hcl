# ca-workers keeps its access when workers_environment and migrate_job_environment move it and
# caj-migrate to the workers environment (workers.tf, migrate.tf, ADR 0120 §4): the same env values,
# the same secret behind each secret-backed env var, and the same vault secret behind each reference,
# read with the same identity. tests/container_app_environments.tftest.hcl pins the placement, the
# names and the identities at plan.
#
# Applies, in their own file, for the reasons tests/workers_identity.tftest.hcl gives: the vault
# references and most env values are computed, unknown at plan, and `override_during = plan` needs
# Terraform 1.11 while CI runs 1.10. An apply (mock state; nothing reaches Azure) makes them known. The
# two runs assert the same values, the first with the defaults and the second with both inputs set, so
# a value the move changes fails the second. Each backend secret has a URL of its own, so a reference
# pointed at another secret compares unequal.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"
}
mock_provider "random" {}
mock_provider "azapi" {}

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

# The mock gives every environment aca-<prefix>'s id. Each gets its own, so a workload on the wrong
# one compares unequal; well-formed, because the second run plans the apps against this state.
override_module {
  target  = module.environments["front"]
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
}

override_module {
  target  = module.environments["app"]
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
}

override_module {
  target  = module.environments["workers"]
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
}

override_resource {
  target = azurerm_key_vault.this
  values = {
    id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test"
    vault_uri = "https://kv-masterly-test.vault.azure.net/"
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

# The install shape of the moved runs in tests/container_app_environments.tftest.hcl.
variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  enable_service_bus    = true
  servicebus_sku        = "Standard"
  migrations            = "job"
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
  api_max_replicas      = 3
  external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
  ingress_allowed_cidrs = ["203.0.113.7/32"]
}

# The baseline: both on aca-<prefix>.
run "ca_workers_access_on_aca_env" {
  command = apply

  assert {
    condition = (
      module.workers[0].environment_id == module.aca_env.id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.aca_env.id &&
      module.aca_env.id != module.environments["workers"].id
    )
    error_message = "This run needs both workloads on aca-<prefix>, or it is no baseline."
  }

  # The env: the api's contract with ca-workers' own AZURE_CLIENT_ID (main.tf, workers_env).
  assert {
    condition = (
      module.workers[0].env_value_sha256 == tomap({ for name, value in local.workers_env : name => sha256(value) }) &&
      tomap({ for name, digest in module.workers[0].env_value_sha256 : name => digest if name != "AZURE_CLIENT_ID" }) == tomap({ for name, digest in module.api.env_value_sha256 : name => digest if name != "AZURE_CLIENT_ID" }) &&
      module.workers[0].env_value_sha256["AZURE_CLIENT_ID"] == sha256("bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc") &&
      module.workers[0].env_value_sha256["MASTERLY_KEYVAULT_URL"] == sha256("https://kv-masterly-test.vault.azure.net/") &&
      module.workers[0].env_value_sha256["MASTERLY_SERVICEBUS_QUEUE"] == sha256(azurerm_servicebus_queue.jobs[0].name) &&
      module.workers[0].env_value_sha256["MASTERLY_MIGRATIONS"] == sha256("job") &&
      module.workers[0].env_value_sha256["MASTERLY_INPROCESS_WORKER"] == sha256("false")
    )
    error_message = "On aca-<prefix>, ca-workers' env must be the api's, with its own AZURE_CLIENT_ID, the vault's URL, the jobs queue, migrations = job and no in-process worker."
  }

  assert {
    condition = (
      module.workers[0].env_secret_refs == tomap({ MASTERLY_DATABASE_URL = "database-url", MASTERLY_LICENSE_TOKEN = "license-token", MASTERLY_REDIS_URL = "redis-url", MASTERLY_SESSION_SECRET = "session-secret" }) &&
      module.workers[0].secret_refs == tomap({
        "database-url"   = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-database-url", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "license-token"  = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-license-token", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "redis-url"      = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-redis-url", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "session-secret" = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-session-secret", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
      }) &&
      length(module.workers[0].value_secret_names) == 0
    )
    error_message = "On aca-<prefix>, each of ca-workers' secret-backed env vars must read its own secret, a reference to that secret in the vault, resolved with id-<prefix>-workers."
  }

  assert {
    condition     = one(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
    error_message = "On aca-<prefix>, caj-migrate must run as id-<prefix>-migrate alone."
  }
}

# Both moved, against the baseline's state: the same assertions, value for value.
run "ca_workers_access_in_the_workers_environment" {
  command = apply

  variables {
    workers_environment     = "workers"
    migrate_job_environment = "workers"
  }

  assert {
    condition = (
      module.workers[0].environment_id == module.environments["workers"].id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.environments["workers"].id &&
      module.environments["workers"].id != module.aca_env.id
    )
    error_message = "This run needs both workloads in the workers environment, or it proves nothing."
  }

  assert {
    condition = (
      module.workers[0].env_value_sha256 == tomap({ for name, value in local.workers_env : name => sha256(value) }) &&
      tomap({ for name, digest in module.workers[0].env_value_sha256 : name => digest if name != "AZURE_CLIENT_ID" }) == tomap({ for name, digest in module.api.env_value_sha256 : name => digest if name != "AZURE_CLIENT_ID" }) &&
      module.workers[0].env_value_sha256["AZURE_CLIENT_ID"] == sha256("bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc") &&
      module.workers[0].env_value_sha256["MASTERLY_KEYVAULT_URL"] == sha256("https://kv-masterly-test.vault.azure.net/") &&
      module.workers[0].env_value_sha256["MASTERLY_SERVICEBUS_QUEUE"] == sha256(azurerm_servicebus_queue.jobs[0].name) &&
      module.workers[0].env_value_sha256["MASTERLY_MIGRATIONS"] == sha256("job") &&
      module.workers[0].env_value_sha256["MASTERLY_INPROCESS_WORKER"] == sha256("false")
    )
    error_message = "In the workers environment, ca-workers' env must stay the api's, with its own AZURE_CLIENT_ID, the vault's URL, the jobs queue, migrations = job and no in-process worker, as on aca-<prefix>."
  }

  assert {
    condition = (
      module.workers[0].env_secret_refs == tomap({ MASTERLY_DATABASE_URL = "database-url", MASTERLY_LICENSE_TOKEN = "license-token", MASTERLY_REDIS_URL = "redis-url", MASTERLY_SESSION_SECRET = "session-secret" }) &&
      module.workers[0].secret_refs == tomap({
        "database-url"   = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-database-url", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "license-token"  = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-license-token", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "redis-url"      = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-redis-url", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
        "session-secret" = { kv_secret_id = "https://kv-masterly-test.vault.azure.net/secrets/install-session-secret", identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers" }
      }) &&
      length(module.workers[0].value_secret_names) == 0
    )
    error_message = "In the workers environment, each of ca-workers' secret-backed env vars must still read its own secret, a reference to that secret in the vault, resolved with id-<prefix>-workers, as on aca-<prefix>."
  }

  assert {
    condition     = one(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
    error_message = "In the workers environment, caj-migrate must still run as id-<prefix>-migrate alone."
  }
}
