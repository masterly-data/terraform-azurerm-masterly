# user-assigned-identity

Tiny wrapper around `azurerm_user_assigned_identity` so role assignments and
outputs are consistent across the module catalog. Used by Layer 2 to give each
Container App its own workload identity.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | `string` | yes | — | UAMI name, e.g. `id-ca-license-issuer-eu`. |
| `resource_group_name` | `string` | yes | — | Resource group that holds the identity. |
| `location` | `string` | yes | — | Azure region. |
| `tags` | `map(string)` | yes | — | Tags applied to the identity. |

## Outputs

| Name | Type | Description |
|---|---|---|
| `id` | `string` | UAMI resource ID. |
| `principal_id` | `string` | Object ID — used in role assignments. |
| `client_id` | `string` | Application ID — used for `AZURE_CLIENT_ID` in workload runtime. |
| `tenant_id` | `string` | Entra tenant ID of the identity. |

## Usage

```hcl
module "license_issuer_uami" {
  source = "../../modules/user-assigned-identity"

  name                = "id-ca-license-issuer-eu"
  resource_group_name = azurerm_resource_group.cp.name
  location            = "westeurope"
  tags                = local.common_tags
}
```

See [`docs/design.md` §1](../../docs/design.md) for the interface contract.
