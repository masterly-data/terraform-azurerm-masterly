# log-analytics-workspace

Standard `PerGB2018` Log Analytics workspace that accepts Microsoft Entra ID only. Local
(shared-key) authentication is off and ingestion over the public network is off, always; the
workspace receives its data through diagnostic settings, such as the one the root module puts on
the `aca-env-consumption` environment (container logs). Whether it answers queries over the
public network is an input. The `AZKVAuditLogs` table (Key Vault audit events) carries its own
retention; every other table follows the workspace's.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | `string` | yes | — | Workspace name. |
| `resource_group_name` | `string` | yes | — | Resource group that holds the workspace. |
| `location` | `string` | yes | — | Azure region. |
| `retention_days` | `number` | no | `30` | Retention in days of every table without its own (30-730). |
| `security_retention_days` | `number` | no | `90` | Retention in days of the `AZKVAuditLogs` table (30-730). |
| `internet_query_enabled` | `bool` | no | `true` | Whether the workspace answers queries over the public network. `false` leaves only queries through an Azure Monitor Private Link Scope. |
| `sku` | `string` | no | `"PerGB2018"` | Workspace pricing SKU. |
| `tags` | `map(string)` | yes | — | Tags applied to the workspace. |

## Outputs

| Name | Type | Description |
|---|---|---|
| `id` | `string` | Workspace resource ID. |
| `workspace_id` | `string` | The workspace's customer ID (a UUID). |
| `local_authentication_enabled` | `bool` | Always `false`. |
| `internet_ingestion_access_type` | `string` | Always `"Disabled"`. |
| `internet_query_access_type` | `string` | `"Enabled"` or `"Disabled"`, from `internet_query_enabled`. |
| `retention_in_days` | `number` | The workspace's retention. |
| `table_retention_days` | `map(number)` | Retention of each table the module sets one on, by table name. |

The module has no `primary_shared_key` output: the workspace's shared keys authenticate nothing.

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
