### Added

- `retire_runtime_environment` (default `false`) deletes `aca-<name_prefix>` once nothing runs in
  it (ADR 0120). The plan refuses `true` while anything the module places is still on
  `aca-<name_prefix>`, and its message names each thing left:
  - `ca-frontend`, `ca-edge` or `ca-api` with its placement input at `"aca"`, and the
    custom-domain certificates that follow them;
  - `ca-workers` with `workers_environment = "runtime"` (with `enable_workers`);
  - `caj-migrate` with `migrations = "job"` and `migrate_job_environment = "runtime"`.

  Retiring does not lift the `egress_firewall` refusal: with everything moved, `egress_firewall`
  is still refused.

### Changed

- With `retire_runtime_environment` unset, an upgrade plans **no change**. `aca-<name_prefix>`
  and its diagnostic setting only move to indexed addresses, through two `moved` blocks:
  `module.aca_env` to `module.aca_env[0]`, and `azurerm_monitor_diagnostic_setting.aca_env` to
  `azurerm_monitor_diagnostic_setting.aca_env[0]`. Nothing is destroyed or created.
- With `retire_runtime_environment = true` and everything moved, the plan destroys
  `aca-<name_prefix>` (`module.aca_env[0]`) and `diag-<name_prefix>-aca-env`
  (`azurerm_monitor_diagnostic_setting.aca_env[0]`), and nothing else. The `aca_environment_id`
  output is then null; it is kept, so callers that read it still plan.
- Azure deletes an environment with every app and job in it, and the module cannot see what you
  created there yourself. Check `aca-<name_prefix>` for your own apps and jobs before you set the
  input.
- `snet-aca`, its NSG, the private-endpoint rule from it and `aca_subnet_id` stay. Setting the
  input back to `false` creates a new, empty `aca-<name_prefix>`.

### Documentation

- `docs/networking.md`, "Retiring the runtime environment" under "Upgrading an existing install",
  gives the upgrade as four applies in order:
  1. the environment subnets and environments;
  2. `ca-workers` and `caj-migrate`;
  3. `ca-frontend`, `ca-edge` and `ca-api` together;
  4. the retirement.

  It says what each move changes: the FQDNs, `frontend_url` and `edge_url`, the OIDC redirect URI
  to register, and the `asuid` TXT and routing records to set before the apply. It also covers
  how SDK and API clients reach the API through `ca-edge`, the one Key Vault rule (443, /32) a hub
  adds for the front subnet, and the `egress_firewall` refusal. "The environment subnets" no
  longer says a later version retires `snet-aca` with the apps' move: this version retires the
  environment only.
