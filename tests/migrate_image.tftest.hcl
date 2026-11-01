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
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location              = "swedencentral"
  org_id                = "org_test"
  install_id            = "test"
  api_image             = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server      = ""
  ingress_allowed_cidrs = ["203.0.113.7/32"]
  enable_diagnostics    = false
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
  target = module.aca_env
  outputs = {
    id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/cae-masterly"
    default_domain                 = "masterly.swedencentral.azurecontainerapps.io"
    internal_load_balancer_enabled = false
    logs_destination               = "log-analytics"
    mutual_tls_enabled             = true
  }
}

override_module {
  target = module.logs
  outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly"
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
    condition     = azurerm_container_app_job.migrate.template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
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
    condition     = azurerm_container_app_job.migrate.template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
    error_message = "A changed api_image must not move the migrate job's image: CD owns it, and moves it to a release's digest and runs it before it rolls ca-api and ca-workers (ignore_changes on template[0].container[0].image, as on the apps)."
  }

  assert {
    condition     = terraform_data.migrate_image.output == "masterly.azurecr.io/release/api:v0.0.1"
    error_message = "The start action's replace trigger must still follow the resolved api image."
  }
}
