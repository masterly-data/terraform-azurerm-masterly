# The availability alerts route to the module's own action group when alert_email is set, with
# enable_diagnostics off (mock providers — no cloud access; runs in CI via `terraform test`).
#
# This is its own file, and an apply, because the action group's id is computed: a plan cannot
# compare an alert's action to it, and `override_during = plan` needs Terraform 1.11 while CI
# runs 1.10. An apply (mock state; nothing reaches Azure) makes the id known. It is a separate
# file so that the apply does not become state the runs of install.tftest.hcl plan against.

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

  # The apps depend on the private-endpoints NSG (the 6432 rule must land before a pooler URL
  # does), so the apply puts the NSG in state. Teardown's pre-destroy refresh then plans the
  # untargeted subnet associations, which parse these IDs: they must be ARM-shaped.
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

variables {
  location              = "swedencentral"
  org_id                = "org_test"
  install_id            = "test"
  api_image             = "masterly.azurecr.io/api:v0.0.0"
  frontend_image        = "masterly.azurecr.io/frontend:v0.0.0"
  acr_login_server      = ""
  ingress_allowed_cidrs = ["203.0.113.7/32"]
  enable_diagnostics    = false
  alert_email           = "ops@example.com"
}

run "availability_alerts_route_to_the_module_action_group" {
  command = apply

  # Only the group and the availability alerts, with what they depend on. Mock providers return
  # random strings as resource IDs, and the resources that parse an ID refuse one at apply.
  plan_options {
    target = [
      azurerm_monitor_action_group.alerts,
      azurerm_monitor_metric_alert.postgres_unavailable,
      azurerm_monitor_metric_alert.app_unavailable,
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready,
    ]
  }

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

  override_resource {
    target = azurerm_monitor_action_group.alerts
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-monitor/providers/microsoft.insights/actionGroups/ag-masterly-alerts"
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
    target = module.frontend
    outputs = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name = "ca-frontend"
      fqdn = "ca-frontend.example.com"
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

  assert {
    condition = (
      length(azurerm_monitor_action_group.alerts) == 1 &&
      azurerm_monitor_action_group.alerts[0].name == "ag-masterly-alerts" &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "alert_email must create ag-<prefix>-alerts with diagnostics off, and the availability alerts must exist beside it."
  }

  assert {
    condition = (
      contains([for a in azurerm_monitor_metric_alert.postgres_unavailable[0].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id) &&
      contains([for a in azurerm_monitor_metric_alert.app_unavailable["api"].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id) &&
      contains([for a in azurerm_monitor_metric_alert.app_unavailable["frontend"].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id) &&
      contains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].action[0].action_groups, azurerm_monitor_action_group.alerts[0].id)
    )
    error_message = "With alert_email set, postgres-unavailable, each <app>-unavailable and app-not-ready must route to the module's action group."
  }
}
