# ca-edge's diagnostic setting and alerts point at ca-edge and route to the module's action group
# (mock providers — no cloud access; runs in CI via `terraform test`).
#
# This is its own file, and an apply, because ca-edge's id and the action group's id are computed:
# a plan cannot compare a target, a scope, the silent rule's query or an alert's action to them,
# and `override_during = plan` needs Terraform 1.11 while CI runs 1.10. An apply (mock state;
# nothing reaches Azure) makes the ids known. It is a separate file so that the apply does not
# become state the per-concern plan files plan against (see availability_routing.tftest.hcl).

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location              = "swedencentral"
  org_id                = "org_test"
  install_id            = "test"
  api_image             = "masterly.azurecr.io/release/api:v0.138.0"
  frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server      = ""
  ingress_allowed_cidrs = ["203.0.113.7/32"]
  edge                  = {}
  enable_diagnostics    = true

  enable_app_availability_diagnostics = true

  alert_email = "ops@example.com"

  # Production needs builtin_auth or a recorded opt-out (no effect in demo). Production runs expect
  # its warning, check.builtin_auth_opted_out_in_production, except targeted ones and refusals.
  builtin_auth_opt_out = { reason = "Test install: the platform sign-in gate is not under test in this file." }
}

run "edge_setting_and_alerts_target_ca_edge_and_route_to_the_module_action_group" {
  command = apply

  # Only the setting, the alerts and what they depend on: mock providers return random strings as
  # resource IDs, and the resources that parse an ID refuse one at apply.
  plan_options {
    target = [
      azurerm_monitor_action_group.alerts,
      azurerm_monitor_diagnostic_setting.app,
      azurerm_monitor_metric_alert.app_unavailable,
      azurerm_monitor_metric_alert.app_5xx,
      azurerm_monitor_scheduled_query_rules_alert_v2.app_silent,
    ]
  }

  override_resource {
    target = azurerm_container_app.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"
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

  # The apps' environments are applied too (see availability_routing.tftest.hcl): their ids must
  # be ARM-shaped, a domain and an address.
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

  # AC1: the setting targets ca-edge, sends AllMetrics and no log category.
  assert {
    condition = (
      azurerm_monitor_diagnostic_setting.app["edge"].name == "diag-masterly-edge" &&
      azurerm_monitor_diagnostic_setting.app["edge"].target_resource_id == azurerm_container_app.edge[0].id &&
      azurerm_monitor_diagnostic_setting.app["edge"].target_resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge" &&
      azurerm_monitor_diagnostic_setting.app["edge"].log_analytics_workspace_id == module.logs.id &&
      length(azurerm_monitor_diagnostic_setting.app["edge"].enabled_metric) == 1 &&
      one([for m in azurerm_monitor_diagnostic_setting.app["edge"].enabled_metric : m.category]) == "AllMetrics" &&
      length(azurerm_monitor_diagnostic_setting.app["edge"].enabled_log) == 0
    )
    error_message = "diag-<prefix>-edge must target ca-edge and send AllMetrics and no log category."
  }

  # AC2 and AC3: both metric alerts are scoped to ca-edge.
  assert {
    condition = (
      azurerm_monitor_metric_alert.app_unavailable["edge"].scopes == toset([azurerm_container_app.edge[0].id]) &&
      azurerm_monitor_metric_alert.app_5xx["edge"].scopes == toset([azurerm_container_app.edge[0].id])
    )
    error_message = "edge-unavailable and edge-5xx must be scoped to ca-edge, and to nothing else."
  }

  # AC4 and AC9: the silent rule reads AzureMetrics for ca-edge's id, and interpolates nothing from
  # a request or a header.
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["edge"].scopes[0] == module.logs.id &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["edge"].scopes) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["edge"].criteria[0].query, "(AzureMetrics | where _ResourceId =~ \"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge\")") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["edge"].criteria[0].query, "| where Samples > 0")
    )
    error_message = "edge-silent must read AzureMetrics for ca-edge's id and nothing else."
  }

  # AC5: with alert_email set, every edge alert routes to the module's action group.
  assert {
    condition = (
      length(azurerm_monitor_action_group.alerts) == 1 &&
      contains([for a in azurerm_monitor_metric_alert.app_unavailable["edge"].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id) &&
      contains([for a in azurerm_monitor_metric_alert.app_5xx["edge"].action : a.action_group_id], azurerm_monitor_action_group.alerts[0].id) &&
      contains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["edge"].action[0].action_groups, azurerm_monitor_action_group.alerts[0].id)
    )
    error_message = "With alert_email set, edge-unavailable, edge-5xx and edge-silent must route to azurerm_monitor_action_group.alerts[0]."
  }
}
