# log-analytics-workspace

Standard `PerGB2018` Log Analytics workspace. Deployed in Layer 2 and consumed by
`aca-env-consumption` (container logs) and `app-insights` (workspace-based
telemetry).

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | `string` | yes | — | Workspace name. |
| `resource_group_name` | `string` | yes | — | Resource group that holds the workspace. |
| `location` | `string` | yes | — | Azure region. |
| `retention_days` | `number` | no | `30` | Data retention window in days. |
| `sku` | `string` | no | `"PerGB2018"` | Workspace pricing SKU. |
| `tags` | `map(string)` | yes | — | Tags applied to the workspace. |

## Outputs

| Name | Type | Description |
|---|---|---|
| `id` | `string` | Workspace resource ID. |
| `workspace_id` | `string` | The customer-ID UUID used by ingestion. |
| `primary_shared_key` | `string` (sensitive) | For agents that authenticate by key. |

## Usage

```hcl
module "law" {
  source = "../../modules/log-analytics-workspace"

  name                = "law-cp-eu"
  resource_group_name = azurerm_resource_group.cp.name
  location            = "westeurope"
  tags                = local.common_tags
}
```

See [`docs/design.md` §1](../../docs/design.md) for the interface contract.
