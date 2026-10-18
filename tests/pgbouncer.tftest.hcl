# The composed connection URLs of postgres_pgbouncer (MAS-2365). These runs APPLY against the mock
# providers, targeting the server and the two Key Vault secrets that carry the URLs, so the
# server's fqdn can be overridden with a known value and the URLs become known strings. (A local
# is only evaluated when something targeted uses it, hence the vault secrets.) The file has its
# own state, so the "keep apply runs last" rule of install.tftest.hcl does not apply to it.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "azurerm_resources" {
    defaults = {
      resources = []
    }
  }
}
mock_provider "random" {}

variables {
  location                    = "swedencentral"
  org_id                      = "org_test"
  install_id                  = "test"
  api_image                   = "masterly.azurecr.io/api:v0.0.0"
  frontend_image              = "masterly.azurecr.io/frontend:v0.0.0"
  acr_login_server            = ""
  ingress_allowed_cidrs       = ["203.0.113.7/32"]
  key_vault_deployer_ip_rules = ["203.0.113.7"]
  postgres_sku_name           = "GP_Standard_D2ds_v5"
  postgres_pgbouncer          = true
  enable_key_vault            = true
}

run "pgbouncer_password_urls" {
  command = apply

  plan_options {
    target = [
      azurerm_postgresql_flexible_server.this,
      azurerm_key_vault_secret.install["database-url"],
      azurerm_key_vault_secret.install["database-direct-url"],
    ]
  }

  override_resource {
    target = azurerm_postgresql_flexible_server.this
    values = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
      fqdn = "psql-masterly-abc123.postgres.database.azure.com"
    }
  }

  override_resource {
    target = azurerm_key_vault.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-test"
    }
  }

  assert {
    condition     = azurerm_key_vault_secret.install["database-url"].value == "postgresql+asyncpg://masterly_admin:${random_password.postgres_admin[0].result}@psql-masterly-abc123.postgres.database.azure.com:6432/postgres?ssl=require"
    error_message = "With the pooler on and database_auth = password, database-url must be the masterly_admin DSN with its password on :6432/postgres."
  }

  assert {
    condition     = azurerm_key_vault_secret.install["database-direct-url"].value == "postgresql+asyncpg://masterly_admin:${random_password.postgres_admin[0].result}@psql-masterly-abc123.postgres.database.azure.com:5432/postgres?ssl=require"
    error_message = "With the pooler on and database_auth = password, database-direct-url must be the same role and database on :5432."
  }
}

run "pgbouncer_entra_urls_carry_no_password" {
  command = apply

  plan_options {
    target = [
      azurerm_postgresql_flexible_server.this,
      module.apps_identity,
      azurerm_key_vault_secret.install["database-url"],
      azurerm_key_vault_secret.install["database-direct-url"],
    ]
  }

  override_resource {
    target = azurerm_postgresql_flexible_server.this
    values = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
      fqdn = "psql-masterly-abc123.postgres.database.azure.com"
    }
  }

  override_resource {
    target = azurerm_key_vault.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-test"
    }
  }

  variables {
    database_auth = "entra"
  }

  assert {
    condition     = azurerm_key_vault_secret.install["database-url"].value == "postgresql+asyncpg://${module.apps_identity.name}@psql-masterly-abc123.postgres.database.azure.com:6432/postgres?ssl=require"
    error_message = "On entra, database-url must be the apps' identity role on :6432/postgres, with no password."
  }

  assert {
    condition     = azurerm_key_vault_secret.install["database-direct-url"].value == "postgresql+asyncpg://${module.apps_identity.name}@psql-masterly-abc123.postgres.database.azure.com:5432/postgres?ssl=require"
    error_message = "On entra, database-direct-url must be the same role and database on :5432, with no password."
  }

  assert {
    condition     = !can(regex("://[^@/]*:", azurerm_key_vault_secret.install["database-url"].value)) && !can(regex("://[^@/]*:", azurerm_key_vault_secret.install["database-direct-url"].value))
    error_message = "On entra, neither URL's userinfo may carry a password."
  }
}
