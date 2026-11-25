### Added

- A dedicated **audit vault** (`azurerm_key_vault.audit`, `kva-<prefix>-<suffix>`) for the audit
  checkpoint signing key `audit-checkpoint-signing-<env>` and head `audit-checkpoint-head-<env>`
  alone, implementing the ADR 0033 §10 and ADR 0120 §6 rows that scope the core pool's signing
  grant and `ca-api`'s key read and head read to those names. With
  `enable_key_vault` it is created in the data resource group with the main vault's RBAC mode,
  soft-delete retention, purge protection in production and network ACLs; in production it gets a
  private endpoint (`pe-<prefix>-kv-audit`) in the main vault's privatelink zone (an injected
  `key_vault_private_dns_zone_id` is honoured), and an AuditEvent + AllMetrics diagnostic setting
  wherever the main vault has one.
- Grants on the audit vault, and no other: `Masterly signing keys` for the core worker pool's
  identity (`ca-workers`' own, or the apps identity where `ca-workers` runs as it), and for
  `ca-api`'s identity `Masterly signing key reader` (`keys/read`) plus a new custom role,
  `Masterly audit head reader (<prefix>-<suffix>)` (`secrets/getSecret/action` alone). No built-in
  role, and no grant for the deployer, planner, frontend, edge, migrate or certificate identities.
- `MASTERLY_AUDIT_KEYVAULT_URL`, the audit vault's URI, on `ca-api` and `ca-workers` only (not
  `ca-frontend`, not `caj-migrate`), listed in `RUNTIME_ENV.json` and the diagnostic bundle's
  value allowlist; in demo an outbound allowlist entry for the audit vault's host on TCP 443 for
  `ca-api` and `ca-workers` only.
- Output `audit_key_vault_uri`: the audit vault's URI, null with `enable_key_vault` off.

### Changed

- With `enable_key_vault`, the apply creates one more custom role definition (`Masterly audit head
  reader`), so the deployer needs `Microsoft.Authorization/roleDefinitions/write` on the data
  resource group, as for the existing ones. In demo, an egress firewall built from
  `outbound_allowlist` must admit the audit vault's host (`kva-*.vault.azure.net`) on TCP 443.

### Security

- On the audit vault `ca-api` can read the audit checkpoint key's public half and the signed head,
  and can neither sign a checkpoint nor overwrite the head. The residual, named in the README:
  with `enable_workers = true` and `ca-workers` running as the apps identity
  (`migrations = "start"` with `database_auth = "entra"` on the starter server), `ca-api` shares
  that identity and holds the five actions on the audit vault. The upgrade only adds resources;
  every main-vault grant, including the erasure keys' signing grants, is unchanged.
