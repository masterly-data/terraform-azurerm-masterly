# Container Apps built-in authentication on ca-edge (builtin-auth.tf, builtin_auth_edge): the
# default-deny backstop behind Envoy of ADR 0120 (as amended by ADR 0117, clarified 2026-11-22),
# off by default.
#
# Applies, in their own file, for the reasons tests/builtin_auth_api.tftest.hcl gives: ca-edge's
# and ca-frontend's ids are computed, so at plan they are unknown on Terraform 1.10, and the
# alerts' scopes and the gate's parent are asserted against them here. The body, the exclusions,
# the recovery window and the refusals are plan runs in builtin_auth.tftest.hcl.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  override_resource {
    target = module.frontend.azurerm_container_app.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
    }
  }

  override_resource {
    target = azurerm_container_app.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"
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
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.138.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  ingress_allowed_cidrs = ["203.0.113.7/32"]
  edge                  = {}
  oidc_tenant_id        = "11111111-1111-1111-1111-111111111111"
  builtin_auth = {
    tenant_id = "11111111-1111-1111-1111-111111111111"
    client_id = "22222222-2222-2222-2222-222222222222"
  }
  builtin_auth_client_secret = "test-only-not-a-secret"
}

# Switch unset: no gate and no alert on ca-edge; the frontend's alert is the one it always was.
run "builtin_auth_edge_off_has_no_edge_gate_or_alert" {
  command = apply

  assert {
    condition = (
      jsonencode(keys(azapi_resource.builtin_auth)) == jsonencode(["frontend"]) &&
      length(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write) == 0
    )
    error_message = "With builtin_auth_edge unset, there must be no auth configuration and no auth-config alert on ca-edge."
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write) == 1 &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == jsonencode([module.frontend.id]) &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == jsonencode(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"])
    )
    error_message = "With builtin_auth_edge unset, the frontend's alert must be scoped to ca-frontend alone."
  }

  assert {
    condition     = length(azurerm_container_app.edge[0].secret) == 0
    error_message = "ca-edge must carry no secret."
  }
}

# Threat: an out-of-band change going unreported. With the switch on, one alert on ca-edge's
# authConfigs writes, beside the frontend's, which keeps its scope; the gate's parent is ca-edge.
run "builtin_auth_edge_on_alerts_on_edge_auth_config_writes" {
  command = apply

  variables {
    builtin_auth_edge = true
  }

  assert {
    condition     = azapi_resource.builtin_auth["edge"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"
    error_message = "ca-edge's auth configuration must be a child of ca-edge."
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].name == "alert-masterly-edge-auth-config-write" &&
      azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].location == "global" &&
      azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].resource_group_name == "rg-masterly-aca" &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].scopes) == jsonencode([azurerm_container_app.edge[0].id]) &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].scopes) == jsonencode(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"]) &&
      length(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].criteria) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].criteria[0].category == "Administrative" &&
      azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].criteria[0].operation_name == "Microsoft.App/containerApps/authConfigs/write" &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].tags) == jsonencode({ install-id = "test", org-id = "org_test" })
    )
    error_message = "With builtin_auth_edge = true, there must be one global Administrative alert, alert-masterly-edge-auth-config-write, on Microsoft.App/containerApps/authConfigs/write, scoped to ca-edge alone, carrying the install's tags."
  }

  # The same action group as the frontend's and ca-api's alerts.
  assert {
    condition = (
      length(local.alert_action_group_ids) == 1 &&
      jsonencode([for a in azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].action : a.action_group_id]) == jsonencode([azurerm_monitor_action_group.alerts[0].id]) &&
      jsonencode([for a in azurerm_monitor_activity_log_alert.builtin_auth_edge_config_write[0].action : a.action_group_id]) == jsonencode([for a in azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action : a.action_group_id])
    )
    error_message = "ca-edge's alert must notify the install's action group, as the frontend's does."
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].name == "alert-masterly-frontend-auth-config-write" &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == jsonencode([module.frontend.id]) &&
      jsonencode(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == jsonencode(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"])
    )
    error_message = "With builtin_auth_edge = true, the frontend's alert must stay builtin_auth_config_write[0], scoped to ca-frontend alone."
  }

  # Threat: a secret through the shared registration. ca-edge's container app carries none, and
  # its Envoy configuration is the one edge.tf renders, which reads no builtin_auth_edge.
  assert {
    condition = (
      length(azurerm_container_app.edge[0].secret) == 0 &&
      azurerm_container_app.edge[0].template[0].container[0].args[2] == jsonencode(local.edge_envoy_config) &&
      length(regexall("builtin_auth_edge", file("${path.module}/edge.tf"))) == 0
    )
    error_message = "With builtin_auth_edge = true, ca-edge must carry no secret, and its Envoy configuration must be local.edge_envoy_config, which edge.tf builds without reading builtin_auth_edge."
  }
}
