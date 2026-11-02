# CD owns the migrate job's running image, as it owns the apps' (ADR 0086 as amended 2026-10-23;
# migrate.tf): Terraform seeds it on create and then ignores drift, so a later api_image never
# moves the job off the release CD rolled and ran before the apps (mock providers — no cloud
# access; runs in CI via `terraform test`).
#
# Two applies, because only state shows an ignored change: the second changes api_image and the
# job keeps the first. It is a separate file so that the applies do not become state the runs of
# install.tftest.hcl plan against.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
      object_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    }
  }

  mock_data "azurerm_resources" {
    defaults = {
      resources = []
    }
  }

  # Teardown's pre-destroy refresh plans the untargeted subnet associations, which parse these
  # IDs: they must be ARM-shaped (as in availability_routing.tftest.hcl).
  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-test"
    }
  }

  # Production also applies the vault and its secrets, the DNS for its private endpoint,
  # and Redis. Their IDs are parsed by dependent resources during apply and teardown.
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test"
    }
  }

  mock_resource "azurerm_key_vault_secret" {
    defaults = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-test"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-test"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-net/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    }
  }

  mock_resource "azurerm_redis_cache" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redis/redis-masterly-test"
    }
  }
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location                       = "swedencentral"
  org_id                         = "org_test"
  install_id                     = "test"
  api_image                      = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image                 = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server               = ""
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
  enable_diagnostics             = false
  migrations                     = "job"
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
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  database_auth                  = "password"
  alert_email                    = "ops@example.com"
  key_vault_deployer_ip_rules    = ["203.0.113.7"]
}

# Mock providers return random strings as resource IDs, and the resources that parse an ID refuse
# one at apply.
override_resource {
  target = azurerm_resource_group.data
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
  }
}

override_module {
  target  = module.aca_env
  outputs = {
    id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/cae-masterly"
    default_domain                 = "masterly.swedencentral.azurecontainerapps.io"
    internal_load_balancer_enabled = false
    logs_destination               = "log-analytics"
    mutual_tls_enabled             = true
  }
}

override_module {
  target  = module.logs
  outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly"
  }
}

# Teardown also plans ca-api, which parses the apps identity ID even though the applies target
# only the migrate job and its image trigger.
override_resource {
  target = module.apps_identity.azurerm_user_assigned_identity.this
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
    principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
    tenant_id    = "00000000-0000-0000-0000-000000000000"
  }
}

override_module {
  target  = module.migrate_identity
  outputs = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
    principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
    tenant_id    = "00000000-0000-0000-0000-000000000000"
    name         = "id-masterly-migrate"
  }
}

override_resource {
  target = azurerm_container_app_job.migrate
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/jobs/caj-migrate"
  }
}

override_resource {
  target = azurerm_virtual_network.this
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-net/providers/Microsoft.Network/virtualNetworks/vnet-masterly"
  }
}

override_resource {
  target = azurerm_subnet.aca
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-net/providers/Microsoft.Network/virtualNetworks/vnet-masterly/subnets/snet-aca"
  }
}

override_resource {
  target = azurerm_subnet.private_endpoints
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-net/providers/Microsoft.Network/virtualNetworks/vnet-masterly/subnets/snet-pe"
  }
}

override_resource {
  target = azurerm_private_dns_zone.postgres
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-net/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }
}

override_resource {
  target = azurerm_postgresql_flexible_server.this
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-test"
  }
}

run "migrate_job_is_seeded_with_the_api_image" {
  command = apply

  plan_options {
    target = [
      azurerm_container_app_job.migrate,
      terraform_data.migrate_image,
    ]
  }

  assert {
    condition     = azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
    error_message = "Terraform must seed the migrate job with the resolved api image on create."
  }
}

run "migrate_job_keeps_the_image_cd_owns" {
  command = apply

  variables {
    api_image = "masterly.azurecr.io/release/api:v0.0.1"
  }

  plan_options {
    target = [
      azurerm_container_app_job.migrate,
      terraform_data.migrate_image,
    ]
  }

  assert {
    condition     = azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
    error_message = "A changed api_image must not move the migrate job's image: CD owns it, and moves it to a release's digest and runs it before it rolls ca-api and ca-workers (ignore_changes on template[0].container[0].image, as on the apps)."
  }

  assert {
    condition     = terraform_data.migrate_image[0].output == "masterly.azurecr.io/release/api:v0.0.1"
    error_message = "The start action's replace trigger must still follow the resolved api image."
  }
}
