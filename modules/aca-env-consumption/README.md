# aca-env-consumption

Azure Container App Environment configured for **Consumption-only** workloads
(no dedicated workload profile, no infrastructure subnet). Logs are sent through **Azure Monitor**
(`logs_destination = "azure-monitor"`): the environment does not write to a Log
Analytics workspace itself, and does not use a workspace's shared key. The caller
attaches a diagnostic setting to the environment's `id` to send its apps' logs to a
workspace — the root module does, with `ContainerAppConsoleLogs` and
`ContainerAppSystemLogs` into the resource-specific tables of the install's workspace.
One setting on the environment covers every app in it.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | Environment name. |
| `resource_group_name` | string | — | RG that holds the environment. |
| `location` | string | — | Azure region. |
| `tags` | map(string) | `{}` | Tags on the environment. |

There is no workspace input: the provider refuses `log_analytics_workspace_id` on an
environment whose `logs_destination` is `azure-monitor`, so the workspace is named on
the diagnostic setting instead.

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the environment. The diagnostic setting's target. |
| `default_domain` | Default domain suffix for apps in this environment. |
| `logs_destination` | Where the environment sends its logs. Always `azure-monitor`. |

## Deviation from `design.md`

`design.md` lists a `log_analytics_primary_shared_key` input. The azurerm
`azurerm_container_app_environment` resource has **no shared-key argument**, and this
module sends logs through Azure Monitor rather than with the workspace's key, so the
variable is dropped.

`zone_redundancy_enabled` is also omitted: azurerm requires it to be paired with
`infrastructure_subnet_id`, which a Consumption-only environment (no VNet
integration in v1) does not have. Setting it — even to `false` — trips the
provider's `RequiredWith` validation. Add both together if VNet integration
lands later.

## Usage

```hcl
module "aca_env" {
  source = "../../modules/aca-env-consumption"

  name                = "aca-cp-eu"
  resource_group_name = azurerm_resource_group.aca.name
  location            = "westeurope"
  tags                = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "aca_env" {
  name                           = "diag-aca-cp-eu"
  target_resource_id             = module.aca_env.id
  log_analytics_workspace_id     = module.law.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
```

Interface contract: [`docs/design.md`](../../docs/design.md) §1.
