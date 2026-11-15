# The environment's diagnostic setting leaves log_analytics_destination_type unset (mock providers
# — no cloud access; runs in CI via `terraform test`).
#
# Azure keeps no destination type on a Microsoft.App/managedEnvironments diagnostic setting (it
# reads back null), so a configured one shows `+ log_analytics_destination_type` on every plan.
#
# This is its own file, and an apply, because the mock provider plans an unset optional+computed
# argument as unknown, which an assert cannot evaluate, and `override_during = plan` needs
# Terraform 1.11 while CI runs 1.10. An apply (mock state; nothing reaches Azure) gives an unset
# argument a generated value, while a configured "Dedicated" stays "Dedicated": the assert
# therefore fails if the module sets the argument. A separate file keeps the apply's state away
# from the per-concern plan files.

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
  location              = "swedencentral"
  org_id                = "org_test"
  install_id            = "test"
  api_image             = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server      = ""
  ingress_allowed_cidrs = ["203.0.113.7/32"]
}

run "the_environment_setting_leaves_the_destination_type_unset" {
  command = apply

  # Only the setting: mock providers return random strings as resource IDs, and the resources
  # that parse an ID refuse one at apply.
  plan_options {
    target = [azurerm_monitor_diagnostic_setting.aca_env]
  }

  override_module {
    target = module.aca_env
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/cae-masterly"
      default_domain                 = "masterly.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
    }
  }

  override_module {
    target = module.logs
    outputs = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly"
    }
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.aca_env.log_analytics_destination_type != "Dedicated"
    error_message = "The environment's diagnostic setting must not set log_analytics_destination_type: Azure keeps none on a Container Apps environment, so setting one shows a change on every plan."
  }

  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.aca_env.enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
    error_message = "The setting on the environment must send ContainerAppConsoleLogs and ContainerAppSystemLogs."
  }
}
