# aca-env-consumption

Azure Container App Environment configured for **Consumption-only** workloads
(no dedicated workload profile, no infrastructure subnet). Logs are shipped to a
Log Analytics workspace.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | Environment name. |
| `resource_group_name` | string | — | RG that holds the environment. |
| `location` | string | — | Azure region. |
| `log_analytics_workspace_id` | string | — | Resource ID of the LAW receiving container logs. |
| `tags` | map(string) | `{}` | Tags on the environment. |

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the environment. |
| `default_domain` | Default domain suffix for apps in this environment. |

## Deviation from `design.md`

`design.md` lists a `log_analytics_primary_shared_key` input. The azurerm v4
`azurerm_container_app_environment` resource has **no shared-key argument** — it
wires logs by workspace *resource ID* only (`log_analytics_workspace_id` +
`logs_destination = "log-analytics"`, both set here). The spurious variable is
therefore dropped.

`zone_redundancy_enabled` is also omitted: azurerm requires it to be paired with
`infrastructure_subnet_id`, which a Consumption-only environment (no VNet
integration in v1) does not have. Setting it — even to `false` — trips the
provider's `RequiredWith` validation. Add both together if VNet integration
lands later.

## Usage

```hcl
module "aca_env" {
  source = "../../modules/aca-env-consumption"

  name                       = "aca-cp-eu"
  resource_group_name        = azurerm_resource_group.aca.name
  location                   = "westeurope"
  log_analytics_workspace_id = module.law.id
  tags                       = local.common_tags
}
```

Interface contract: [`docs/design.md`](../../docs/design.md) §1.
