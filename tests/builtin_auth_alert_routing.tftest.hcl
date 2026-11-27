# The auth-configuration alerts (builtin-auth.tf) route to the module's own action group when
# alert_email is set (mock providers — no cloud access; runs in CI via `terraform test`).
#
# This is its own file, and an apply, for the reason availability_routing.tftest.hcl is: the
# action group's id is computed, so a plan cannot compare the alert's action to it, and
# `override_during = plan` needs Terraform 1.11 while CI runs 1.10. An apply (mock state;
# nothing reaches Azure) makes the id known, and a separate file keeps that state away from the
# per-concern plan files.

mock_provider "azurerm" {
  # The deployment's tenant is builtin_auth.tenant_id (below), as on a real install: with
  # builtin_auth_api the check builtin_auth_tenant_is_the_deployment_tenant compares the two.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_data "azurerm_resources" {
    defaults = {
      resources = []
    }
  }

  # As in availability_routing.tftest.hcl: teardown's pre-destroy refresh plans the untargeted
  # subnet associations, which parse these IDs, so they must be ARM-shaped.
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
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
}

variables {
  location              = "swedencentral"
  org_id                = "org_test"
  install_id            = "test"
  api_image             = "masterly.azurecr.io/release/api:v0.138.0"
  frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server      = ""
  ingress_allowed_cidrs = ["203.0.113.7/32"]
  alert_email           = "ops@example.com"
  builtin_auth = {
    tenant_id = "11111111-1111-1111-1111-111111111111"
    client_id = "22222222-2222-2222-2222-222222222222"
  }
  builtin_auth_client_secret = "test-only-not-a-secret"
}

run "auth_config_alert_routes_to_the_module_action_group" {
  command = apply

  # Only the group and the alert, with what they depend on. Mock providers return random
  # strings as resource IDs, and the resources that parse an ID refuse one at apply.
  plan_options {
    target = [
      azurerm_monitor_action_group.alerts,
      azurerm_monitor_activity_log_alert.builtin_auth_config_write,
    ]
  }

  override_resource {
    target = azurerm_monitor_action_group.alerts
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/microsoft.insights/actionGroups/ag-masterly-alerts"
    }
  }

  override_module {
    target = module.frontend
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name = "ca-frontend"
      fqdn = "ca-frontend.example.com"
    }
  }

  # What the frontend's inputs depend on, each with a well-formed ID, as in
  # availability_routing.tftest.hcl.
  override_resource {
    target = azurerm_resource_group.data
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
    }
  }

  override_module {
    target = module.aca_env[0]
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
    target = module.api
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name = "ca-api"
      fqdn = "ca-api.example.com"
    }
  }

  # The frontend's environment id is chosen between module.aca_env and the front environment
  # (frontend_environment), and the migrate job behind ca-api's migrate_start names the workers
  # environment (migrate_job_environment), so the environments are applied too, as in
  # availability_routing.tftest.hcl.
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

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].criteria[0].operation_name == "Microsoft.App/containerApps/authConfigs/write" &&
      toset(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"])
    )
    error_message = "With builtin_auth set, the auth-configuration alert must watch authConfigs/write on ca-frontend."
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action) == 1 &&
      contains([for a in azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id)
    )
    error_message = "With alert_email set, the auth-configuration alert must route to the module's action group."
  }
}

# With builtin_auth_api, ca-api's auth-configuration alert routes the same way, one action per
# entry of local.alert_action_group_ids, and the frontend's keeps its own.
run "api_auth_config_alert_routes_to_the_module_action_group" {
  command = apply

  variables {
    builtin_auth_api = true
  }

  plan_options {
    target = [
      azurerm_monitor_action_group.alerts,
      azurerm_monitor_activity_log_alert.builtin_auth_config_write,
      azurerm_monitor_activity_log_alert.builtin_auth_api_config_write,
    ]
  }

  override_resource {
    target = azurerm_monitor_action_group.alerts
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/microsoft.insights/actionGroups/ag-masterly-alerts"
    }
  }

  override_module {
    target = module.frontend
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name = "ca-frontend"
      fqdn = "ca-frontend.example.com"
    }
  }

  override_resource {
    target = azurerm_resource_group.data
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
    }
  }

  override_module {
    target = module.aca_env[0]
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
    target = module.api
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name = "ca-api"
      fqdn = "ca-api.example.com"
    }
  }

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

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_api_config_write) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_api_config_write[0].criteria[0].operation_name == "Microsoft.App/containerApps/authConfigs/write" &&
      toset(azurerm_monitor_activity_log_alert.builtin_auth_api_config_write[0].scopes) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"])
    )
    error_message = "With builtin_auth_api set, ca-api's auth-configuration alert must watch authConfigs/write on ca-api."
  }

  assert {
    condition = (
      length(local.alert_action_group_ids) == 1 &&
      length(azurerm_monitor_activity_log_alert.builtin_auth_api_config_write[0].action) == length(local.alert_action_group_ids) &&
      jsonencode([for a in azurerm_monitor_activity_log_alert.builtin_auth_api_config_write[0].action : a.action_group_id]) == jsonencode(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/microsoft.insights/actionGroups/ag-masterly-alerts"])
    )
    error_message = "With alert_email set, ca-api's auth-configuration alert must route to the module's action group, one action per entry of local.alert_action_group_ids."
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action) == 1 &&
      contains([for a in azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id)
    )
    error_message = "With builtin_auth_api set, the frontend's auth-configuration alert must still route to the module's action group."
  }
}

# The 401 alert on ca-api (builtin_auth_api) routes the same way, and watches ca-api only.
run "api_401_alert_routes_to_the_module_action_group" {
  command = apply

  variables {
    builtin_auth_api = true
  }

  plan_options {
    target = [
      azurerm_monitor_action_group.alerts,
      azurerm_monitor_metric_alert.builtin_auth_api_401,
    ]
  }

  override_resource {
    target = azurerm_monitor_action_group.alerts
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/microsoft.insights/actionGroups/ag-masterly-alerts"
    }
  }

  override_module {
    target = module.frontend
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name = "ca-frontend"
      fqdn = "ca-frontend.example.com"
    }
  }

  override_resource {
    target = azurerm_resource_group.data
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
    }
  }

  override_module {
    target = module.aca_env[0]
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
    target = module.api
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name = "ca-api"
      fqdn = "ca-api.example.com"
    }
  }

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

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.builtin_auth_api_401) == 1 &&
      toset(azurerm_monitor_metric_alert.builtin_auth_api_401[0].scopes) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"])
    )
    error_message = "With builtin_auth_api set, the 401 alert must watch ca-api only."
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.builtin_auth_api_401[0].action) == 1 &&
      contains([for a in azurerm_monitor_metric_alert.builtin_auth_api_401[0].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id)
    )
    error_message = "With alert_email set, the 401 alert must route to the module's action group."
  }
}
