# aca-env-consumption

Azure Container App Environment that declares **no workload profile** of its own (no dedicated
profile; on a delegated subnet Azure adds the `Consumption` profile itself, and the module ignores
that change, and the `infrastructure_resource_group_name` of the `ME_` managed group Azure creates
with it, so a plan without refresh does not replace the environment). The root module's front, app and workers environments, which declare the profile,
use `aca-env-workload-profiles` instead. Logs are sent through **Azure Monitor**
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
| `identity_ids` | list(string) | `[]` | Self-hosted extension: user-assigned identities on the environment itself, which it uses to read certificates from Key Vault. Empty renders no `identity` block. |
| `read_workload_profiles` | bool | `false` | Self-hosted extension: read the environment's workload profiles from Azure (an azapi read) into `workload_profile_names`. |

There is no workspace input: the provider refuses `log_analytics_workspace_id` on an
environment whose `logs_destination` is `azure-monitor`, so the workspace is named on
the diagnostic setting instead.

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the environment. The diagnostic setting's target. |
| `default_domain` | Default domain suffix for apps in this environment. |
| `logs_destination` | Where the environment sends its logs. Always `azure-monitor`. |
| `identity_ids` | Self-hosted extension: the identities attached to the environment. |
| `workload_profile_names` | Self-hosted extension: the workload profiles Azure reports, with `read_workload_profiles` on (null otherwise). Empty means an environment without workload profiles, where Azure ignores a route table on the subnet. Unknown at plan for a new environment. |
| `custom_domain_verification_id` | Self-hosted extension: the `asuid.<hostname>` TXT value Azure checks before it binds a custom domain. Sensitive, as the provider marks it. |

## Deviation from `design.md`

`design.md` lists a `log_analytics_primary_shared_key` input. The azurerm
`azurerm_container_app_environment` resource has **no shared-key argument**, and this
module sends logs through Azure Monitor rather than with the workspace's key, so the
variable is dropped.

`zone_redundancy_enabled` is also omitted: azurerm requires it to be paired with
`infrastructure_subnet_id`, which the platform-iac original (no VNet integration in
v1) does not set; setting it there — even to `false` — trips the provider's
`RequiredWith` validation. This module now takes `infrastructure_subnet_id`, but
zone redundancy is create-time only and stays out of scope.

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
  name                       = "diag-aca-cp-eu"
  target_resource_id         = module.aca_env.id
  log_analytics_workspace_id = module.law.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
```

Interface contract: [`docs/design.md`](../../docs/design.md) §1.
