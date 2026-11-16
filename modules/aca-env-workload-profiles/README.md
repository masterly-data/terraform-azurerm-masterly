# aca-env-workload-profiles

Azure Container App Environment configured as a **workload-profiles** environment on a delegated
subnet, declaring the `Consumption` profile (no dedicated profile yet). The root module creates
three of these, the front, app and workers environments of ADR 0120 §4-§5, beside the
`aca-env-consumption` environment the apps run in today.

Logs are sent through **Azure Monitor** (`logs_destination = "azure-monitor"`), as in
`aca-env-consumption`: the environment does not write to a Log Analytics workspace itself, and the
caller attaches a diagnostic setting to the environment's `id` to send its apps' logs to one.

It is a separate module because `aca-env-consumption` freezes `workload_profile` under
`ignore_changes`, and a lifecycle block cannot be conditional.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | Environment name. |
| `resource_group_name` | string | — | RG that holds the environment. |
| `location` | string | — | Azure region. |
| `tags` | map(string) | `{}` | Tags on the environment. |
| `infrastructure_subnet_id` | string | — | Self-hosted extension: the delegated subnet (/27 or larger). Create-time only. |
| `internal_load_balancer_enabled` | bool | — | Internal load balancer instead of a public endpoint. No default, so each caller decides. |
| `mutual_tls_enabled` | bool | `true` | Peer-to-peer encryption between apps in the environment. |
| `identity_ids` | list(string) | `[]` | Self-hosted extension: user-assigned identities on the environment itself, which it uses to read certificates from Key Vault. Empty attaches none. |

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the environment. The diagnostic setting's target. |
| `name` | Name of the environment. |
| `default_domain` | Default domain suffix for apps in this environment; on an internal environment, the name of its private DNS zone. |
| `static_ip_address` | Self-hosted extension: the environment's static IP, the target of the zone's `*` A record. |
| `internal_load_balancer_enabled` | Whether the environment answers only inside the VNet. |
| `logs_destination` | Where the environment sends its logs. Always `azure-monitor`. |
| `mutual_tls_enabled` | Whether traffic between apps in the environment is encrypted. |
| `infrastructure_subnet_id` | Self-hosted extension: the subnet the environment resource runs in. |
| `workload_profiles` | Self-hosted extension: the profiles the environment resource declares, each with `name` and `workload_profile_type`. |
| `identity_ids` | Self-hosted extension: the identity ids attached to the environment itself. |
| `custom_domain_verification_id` | Self-hosted extension, sensitive: the value of the `asuid.<hostname>` TXT record Azure checks before it binds a custom domain. |

## Usage

```hcl
module "environment" {
  source = "../../modules/aca-env-workload-profiles"

  name                           = "aca-cp-eu-app"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = "westeurope"
  infrastructure_subnet_id       = azurerm_subnet.app.id
  internal_load_balancer_enabled = true
  tags                           = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "environment" {
  name                       = "diag-aca-cp-eu-app"
  target_resource_id         = module.environment.id
  log_analytics_workspace_id = module.law.id

  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}
```
