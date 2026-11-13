# The starter Postgres: provisioning, server parameters, PgBouncer, grade, geo-backup.
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  # Every production run needs one of the two deployer paths to the vault stated, the same
  # as a real production install (see key_vault_deployer_ip_rules). Set file-wide so the
  # runs that assert something else are not all about this; the guard has its own run in keyvault.tftest.hcl.
  key_vault_deployer_ip_rules = ["203.0.113.7"]

  # A production plan with no notification target is refused (alert_email's validation), so
  # every production run states one. Runs about the target override it; the refusal
  # has its own runs in diagnostics.tftest.hcl.
  alert_email = "ops@example.com"
}

# Evaluation defaults: dev identity behind an allowlist provisions the starter Postgres,
# its private DNS zone, and its private endpoint.
run "eval_defaults_provision_starter_postgres" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 1
    error_message = "The default (no external_database_url) must provision the starter Postgres server."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == false
    error_message = "The evaluation default must leave storage autogrow off."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.postgres) == 1 && length(azurerm_private_endpoint.postgres) == 1
    error_message = "The provisioned server must come with its private DNS zone and private endpoint."
  }

  # What the server's error log may carry (ADR 0080, amendment of 2026-09-10): no DETAIL: line
  # and no bound parameter values, on error or otherwise. log_min_error_statement is left at
  # Postgres's default, so the module sets exactly these three and nothing else.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_configuration.log) == 3 &&
      azurerm_postgresql_flexible_server_configuration.log["log_error_verbosity"].name == "log_error_verbosity" &&
      azurerm_postgresql_flexible_server_configuration.log["log_error_verbosity"].value == "TERSE" &&
      azurerm_postgresql_flexible_server_configuration.log["log_parameter_max_length_on_error"].name == "log_parameter_max_length_on_error" &&
      azurerm_postgresql_flexible_server_configuration.log["log_parameter_max_length_on_error"].value == "0" &&
      azurerm_postgresql_flexible_server_configuration.log["log_parameter_max_length"].name == "log_parameter_max_length" &&
      azurerm_postgresql_flexible_server_configuration.log["log_parameter_max_length"].value == "0" &&
      !contains(keys(azurerm_postgresql_flexible_server_configuration.log), "log_min_error_statement")
    )
    error_message = "The starter server must set log_error_verbosity = TERSE, log_parameter_max_length_on_error = 0 and log_parameter_max_length = 0, and leave log_min_error_statement at its default."
  }

  # postgres_server_parameters defaults to empty: the operator resource plans nothing.
  assert {
    condition     = length(azurerm_postgresql_flexible_server_configuration.operator) == 0
    error_message = "With the default postgres_server_parameters there must be no operator configuration resources."
  }

  # The derived layout of the default /16 must never drift — it is what live installs
  # (the demo) hold in state; a change here REPLACES their subnets.
  assert {
    condition = (
      azurerm_subnet.aca[0].address_prefixes[0] == "10.20.0.0/23" &&
      azurerm_subnet.private_endpoints[0].address_prefixes[0] == "10.20.4.0/24"
    )
    error_message = "Derived subnet layout changed for the default /16 — this would replace live installs' subnets."
  }
}

# BYO-DB (ADR 0065): an external DSN provisions NO database resources at all.
run "byo_db_provisions_no_database" {
  command = plan

  variables {
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server.this) == 0 &&
      length(random_password.postgres_admin) == 0 &&
      length(azurerm_private_endpoint.postgres) == 0 &&
      length(azurerm_private_dns_zone.postgres) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgres) == 0
    )
    error_message = "external_database_url must suppress every provisioned-database resource (ADR 0065)."
  }

  # The server parameters belong to the starter server. A BYO-DB server is the customer's, and
  # its configuration is theirs.
  assert {
    condition     = length(azurerm_postgresql_flexible_server_configuration.log) == 0
    error_message = "external_database_url must set no Postgres server parameters — the server is not the module's."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server_configuration.operator) == 0
    error_message = "external_database_url must create no operator Postgres server parameters either."
  }

  assert {
    condition     = output.postgres_fqdn == null
    error_message = "postgres_fqdn must be null on BYO-DB installs."
  }
}

# postgres_server_parameters: the operator's own server parameters, beside the module's log ones.
run "postgres_server_parameters_plan_one_configuration_each" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { max_connections = "400" }
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_configuration.operator) == 1 &&
      azurerm_postgresql_flexible_server_configuration.operator["max_connections"].name == "max_connections" &&
      azurerm_postgresql_flexible_server_configuration.operator["max_connections"].value == "400" &&
      length(azurerm_postgresql_flexible_server_configuration.log) == 3
    )
    error_message = "An entry in postgres_server_parameters must plan one operator configuration, beside the three log ones."
  }
}

run "postgres_server_parameters_refuse_log_error_verbosity" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { log_error_verbosity = "VERBOSE" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_log_parameter_max_length_on_error" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { log_parameter_max_length_on_error = "-1" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_log_parameter_max_length" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { log_parameter_max_length = "-1" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_mixed_case_log_key" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { Log_Error_Verbosity = "VERBOSE" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_mixed_case_max_connections" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { MAX_CONNECTIONS = "400" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refused_with_byo_db" {
  command = plan

  variables {
    identity_binding           = "oidc"
    oidc_allowed_issuers       = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience              = "api-client-id"
    oidc_jwks_uri              = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id             = "bff-client-id"
    oidc_client_secret         = "s3cret"
    oidc_authority             = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri          = "https://app.example.com/api/auth/callback"
    external_database_url      = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    postgres_server_parameters = { work_mem = "8192" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_a_non_numeric_max_connections" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { max_connections = "lots" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_a_zero_max_connections" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { max_connections = "0" }
  }

  expect_failures = [var.postgres_server_parameters]
}

run "postgres_server_parameters_refuse_a_fractional_max_connections" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_server_parameters = { max_connections = "10.5" }
  }

  expect_failures = [var.postgres_server_parameters]
}

# postgres_pgbouncer: the built-in PgBouncer in transaction mode (ADR 0003, MAS-1615).
# Off (the default) changes nothing.
run "postgres_pgbouncer_off_changes_nothing" {
  # The URLs embed the server's fqdn, which a mock provider leaves unknown at plan, so the
  # runs here assert the port local the URLs are built from rather than the whole string.
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = local.database_pooler_port == "5432"
    error_message = "With postgres_pgbouncer off the database-url secret must stay on :5432."
  }
}

# The rest of the off-by-default checks need no server fqdn, so they run at plan.
run "postgres_pgbouncer_off_adds_no_env_secret_or_port" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_DATABASE_POOLER") && !contains(keys(local.api_env_secret_refs), "MASTERLY_DATABASE_DIRECT_URL") && !contains(keys(local.backend_env_secret_refs), "MASTERLY_DATABASE_DIRECT_URL")
    error_message = "With postgres_pgbouncer off there must be no MASTERLY_DATABASE_POOLER env and no MASTERLY_DATABASE_DIRECT_URL secret ref."
  }

  assert {
    condition     = !contains(local.backend_secret_names, "database-direct-url") && length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0
    error_message = "With postgres_pgbouncer off there must be no direct-url secret and no pgbouncer.* server configuration."
  }

  assert {
    condition     = !contains(local.private_endpoint_ports, "6432") && contains(local.private_endpoint_ports, "5432")
    error_message = "With postgres_pgbouncer off the endpoints subnet must not admit 6432."
  }
}

run "postgres_pgbouncer_sets_the_server_parameters" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 3 &&
      azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.enabled"].value == "true" &&
      azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.pool_mode"].value == "TRANSACTION" &&
      tonumber(azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.max_prepared_statements"].value) > 0 &&
      azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.max_prepared_statements"].value == "100" &&
      length(azurerm_postgresql_flexible_server_configuration.log) == 3 &&
      length(azurerm_postgresql_flexible_server_configuration.operator) == 0
    )
    error_message = "postgres_pgbouncer must set pgbouncer.enabled = true, pgbouncer.pool_mode = TRANSACTION and pgbouncer.max_prepared_statements = 100, beside the unchanged log parameters."
  }

  assert {
    condition     = contains(local.private_endpoint_ports, "6432") && contains(local.private_endpoint_ports, "5432")
    error_message = "postgres_pgbouncer must admit 6432 on the endpoints subnet, beside 5432."
  }
}

run "postgres_pgbouncer_password_urls" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
  }

  assert {
    condition     = local.database_pooler_port == "6432" && !local.database_entra
    error_message = "With the pooler on and database_auth = password, database-url must be on :6432 (database-direct-url stays on :5432)."
  }

  # The exact strings are proved in tests/postgres_connection_urls.tftest.hcl; these are the inputs
  # the root gives that module (the server's fqdn and the password are known only after apply).
  assert {
    condition = (
      local.database_direct_port == "5432" &&
      local.database_auth_mode == "password" &&
      local.database_role == "masterly_admin" &&
      length(module.postgres_connection_urls) == 1
    )
    error_message = "On password, both URLs must be built as masterly_admin with its password, the pooler URL on :6432 and the direct URL on :5432."
  }
}

run "postgres_pgbouncer_wires_pooler_env_and_direct_secret" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
    enable_workers        = true
  }

  assert {
    condition = (
      local.api_env["MASTERLY_DATABASE_POOLER"] == "transaction" &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      local.api_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "database-direct-url" &&
      local.backend_env_secret_refs["MASTERLY_DATABASE_DIRECT_URL"] == "database-direct-url" &&
      contains(local.api_secret_names, "database-direct-url") &&
      contains(local.backend_secret_names, "database-direct-url")
    )
    error_message = "ca-api and ca-workers must get MASTERLY_DATABASE_POOLER = transaction and MASTERLY_DATABASE_DIRECT_URL from the database-direct-url secret."
  }

  # The workers app is built from local.api_env and local.backend_env_secret_refs (workers.tf).
  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_DATABASE_POOLER") && !contains(module.workers[0].env_names, "MASTERLY_DATABASE_DIRECT_URL") && !contains(module.api.env_names, "MASTERLY_DATABASE_DIRECT_URL")
    error_message = "The pooler setting is plain env on both backend apps; the direct URL is never plain env."
  }
}

run "postgres_pgbouncer_entra_urls_carry_no_password" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
    database_auth         = "entra"
  }

  assert {
    condition     = local.database_pooler_port == "6432" && local.database_entra
    error_message = "On entra the URL must be on :6432 (the direct URL stays on :5432), with the Entra role and no password."
  }

  assert {
    condition     = !can(regex(":", local.database_entra_role))
    error_message = "On database_auth = entra the role in both URLs must carry no password."
  }

  # The module puts no password in either URL on entra (tests/postgres_connection_urls.tftest.hcl).
  assert {
    condition = (
      local.database_direct_port == "5432" &&
      local.database_auth_mode == "entra" &&
      local.database_role == module.apps_identity.name
    )
    error_message = "On entra, both URLs must be built as the apps' identity's role with no password, the direct URL on :5432."
  }
}

# The direct URL is a credential: a Key Vault secret when the vault is on, never plain env.
run "postgres_pgbouncer_direct_url_is_vault_backed" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
    enable_key_vault      = true
    enable_workers        = true
  }

  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "database-direct-url") &&
      contains(module.workers[0].vault_backed_secret_names, "database-direct-url") &&
      !contains(module.api.value_secret_names, "database-direct-url") &&
      !contains(module.api.env_names, "MASTERLY_DATABASE_DIRECT_URL") &&
      !contains(module.workers[0].env_names, "MASTERLY_DATABASE_DIRECT_URL") &&
      contains(keys(azurerm_key_vault_secret.install), "database-direct-url")
    )
    error_message = "With the Key Vault on, database-direct-url must reach both backend apps as a vault reference, and never as plain env."
  }
}

run "postgres_pgbouncer_refused_on_a_burstable_sku" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_sku_name     = "B_Standard_B1ms"
    postgres_pgbouncer    = true
  }

  expect_failures = [var.postgres_pgbouncer]
}

run "postgres_pgbouncer_refused_with_byo_db" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    postgres_sku_name     = "GP_Standard_D2ds_v5"
    postgres_pgbouncer    = true
  }

  expect_failures = [var.postgres_pgbouncer]
}

run "postgres_pgbouncer_refused_with_an_operator_pgbouncer_key" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_sku_name          = "GP_Standard_D2ds_v5"
    postgres_pgbouncer         = true
    postgres_server_parameters = { "pgbouncer.pool_mode" = "SESSION" }
  }

  expect_failures = [var.postgres_pgbouncer]
}

# mode=production on the PROVISIONED starter server: the data-plane defaults must be
# production-grade (non-burstable SKU + zone-redundant HA + >=14d retention). This exercises
# the starter-server path (no external_database_url), unlike the BYO-DB wiring test above.
run "production_starter_postgres_grade_plans" {
  command = plan

  variables {
    mode                  = "production"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 2

    # Production-grade starter server (no external_database_url — module provisions Postgres).
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14

    # A notification target -> the module creates its own action group.
    alert_email = "ops@example.com"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 1
    error_message = "Production with no external_database_url must provision the starter server."
  }

  # Diagnostics for the starter server + the storage alert; no CPU-credits alert on a
  # General Purpose SKU (that alert is burstable-only). The action group is created because
  # alert_email is set.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.postgres) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_storage) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_cpu_credits) == 0 &&
      length(azurerm_monitor_action_group.alerts) == 1
    )
    error_message = "Production starter server must wire Postgres diagnostics + storage alert (no CPU-credit alert on GP) and an action group when alert_email is set."
  }

  # The Postgres load alerts (MAS-1291). CPU and IOPS are Azure's own percentages; connections
  # is a count derived from the SKU's default max_connections: GP_Standard_D2ds_v5 is 8 GiB,
  # 859 connections, so the 70% default fires above 601. Every one of these plans with a wrong
  # aggregation or operator, so each is pinned.
  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_cpu[0].severity == 2 &&
      azurerm_monitor_metric_alert.postgres_cpu[0].window_size == "PT15M" &&
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].metric_namespace == "Microsoft.DBforPostgreSQL/flexibleServers" &&
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].metric_name == "cpu_percent" &&
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].aggregation == "Average" &&
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].threshold == 80
    )
    error_message = "The Postgres CPU alert must read cpu_percent (Average) above 80 over 15 minutes."
  }

  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_connections[0].severity == 2 &&
      azurerm_monitor_metric_alert.postgres_connections[0].window_size == "PT15M" &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].metric_name == "active_connections" &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].aggregation == "Average" &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 601 &&
      strcontains(azurerm_monitor_metric_alert.postgres_connections[0].description, "(859)")
    )
    error_message = "The Postgres connections alert must read active_connections (Average) above 70% of the D2ds_v5 default of 859."
  }

  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_iops[0].severity == 2 &&
      azurerm_monitor_metric_alert.postgres_iops[0].window_size == "PT15M" &&
      azurerm_monitor_metric_alert.postgres_iops[0].criteria[0].metric_name == "disk_iops_consumed_percentage" &&
      azurerm_monitor_metric_alert.postgres_iops[0].criteria[0].aggregation == "Average" &&
      azurerm_monitor_metric_alert.postgres_iops[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_metric_alert.postgres_iops[0].criteria[0].threshold == 80
    )
    error_message = "The Postgres IOPS alert must read disk_iops_consumed_percentage (Average) above 80 over 15 minutes."
  }

  # The provisioned server gets both database availability alerts (MAS-263): the fast one that
  # reads the platform's own is_db_alive, and the slow one that fires on the ABSENCE of that
  # metric — the state a stopped server leaves behind, which no metric alert can see.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 1
    )
    error_message = "A provisioned starter server must carry both the is_db_alive alert and the no-telemetry alert."
  }

  # is_db_alive is 1 up / 0 down and Learn documents MAX() as the way to ask whether the server
  # was up in the last minute. Average would let a mostly-up server average a hard minute away;
  # Minimum would fire on every failover blip. Pinned because either substitution still plans.
  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].metric_name == "is_db_alive" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].aggregation == "Maximum" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].operator == "LessThan" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].threshold == 1
    )
    error_message = "The database availability alert must read is_db_alive with Maximum aggregation below 1."
  }

  # The whole point of the log rule: SILENCE has to be the firing condition. Counting rows and
  # firing below one is what makes an empty result an alert rather than a quiet evaluation — the
  # property a metric alert cannot have. GreaterThan here would invert the alert into a
  # permanently-firing one and still plan cleanly, so it is pinned.
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].time_aggregation_method == "Count" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].operator == "LessThan" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].threshold == 1
    )
    error_message = "The no-telemetry alert must fire when the query returns NO rows (Count < 1) — otherwise silence stays quiet."
  }

  # Azure refuses more than one evaluation period for a query that does not project
  # `TimeGenerated`, and this one cannot: it reduces the window to a single count so that an
  # empty result is the firing state. A rule with two periods plans and validates clean here and
  # is refused with a 400 on create, which is how 0.16.0 and 0.17.0 shipped it. The silence the
  # rule waits for is carried by the window instead, so the window is pinned beside the periods.
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].failing_periods[0].number_of_evaluation_periods == 1 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].failing_periods[0].minimum_failing_periods_to_trigger_alert == 1
    )
    error_message = "The no-telemetry alert must use exactly one evaluation period: Azure refuses more than one (400) for a query that does not project TimeGenerated."
  }

  assert {
    condition     = azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].window_duration == "PT45M"
    error_message = "The no-telemetry alert's 45-minute window is what carries its silence threshold now that it has one evaluation period; change the description and the comment in diagnostics.tf with it."
  }

  # Not asserted here, and worth naming rather than leaving as a silent gap: that the rule's
  # scope is the install's own workspace and its query names the install's own server. Both are
  # built from resource ids, which are unknown until apply, so under mock providers the
  # condition is unknowable rather than false. Reviewing the interpolation in diagnostics.tf is
  # what covers it.
  #
  # The same limit swallows anything else about the query TEXT, and one thing in it deserves to
  # be named because it reads as decoration and is not: the union's empty-`datatable` anchor.
  # `union isfuzzy=true` alone does NOT survive an operand that fails to resolve — a fuzzy union
  # whose only operand is missing dies with SEM0104, measured against a live workspace on
  # 2026-09-09 (see the comment on the resource). Deleting the anchor as redundant leaves a query
  # that still plans, still applies, and only fails at evaluation. An assert on
  # `criteria[0].query` was written and removed: interpolating the server id makes the whole
  # string unknown at plan time, so terraform test rejects the condition as unevaluable rather
  # than failing it. Only an apply-mode run against real Azure could pin it.
}

# Guard: mode=production refuses the burstable Postgres default on the provisioned starter
# server (the dev-grade SKU is unrepresentable in production).
run "production_burstable_postgres_is_rejected" {
  command = plan

  variables {
    mode                  = "production"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 2
    # postgres_sku_name stays the burstable B_Standard_B1ms default -> refused
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  expect_failures = [var.postgres_sku_name]
}

# Guard: mode=production refuses a dev-grade 7-day backup retention on the starter server.
run "production_short_retention_is_rejected" {
  command = plan

  variables {
    mode                       = "production"
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    identity_binding           = "oidc"
    oidc_allowed_issuers       = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience              = "api-client-id"
    oidc_jwks_uri              = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id             = "bff-client-id"
    oidc_client_secret         = "s3cret"
    oidc_authority             = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri          = "https://app.example.com/api/auth/callback"
    license_token              = "eyJ.fake.jwt"
    license_public_jwk         = "{\"kty\":\"EC\"}"
    initial_owner_email        = "owner@example.com"
    enable_key_vault           = true
    enable_redis               = true
    redis_offering             = "cache"
    enable_workers             = true
    api_max_replicas           = 2
    postgres_sku_name          = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha = true
    # postgres_backup_retention_days stays the 7-day default -> refused
  }

  expect_failures = [var.postgres_backup_retention_days]
}

# Guard: mode=production refuses the starter server without zone-redundant HA.
run "production_no_ha_is_rejected" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
    # postgres_zone_redundant_ha stays false -> refused
  }

  expect_failures = [var.postgres_zone_redundant_ha]
}

# --- Geo-redundant backup on the starter Postgres server (MAS-1087) ----------------------
# Unset, postgres_geo_redundant_backup resolves to: on for mode=production in a region the
# module knows supports it, off everywhere else. An explicit true or false always wins. Each
# run below sets the full production wiring because every one of those inputs is required
# by mode=production on the starter server.

run "production_geo_backup_on_in_a_supported_region" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == true
    error_message = "mode=production in Sweden Central must create the starter server with geo-redundant backup on."
  }
}

# The display form of the location resolves through the same key as the lookup.
run "production_geo_backup_on_with_the_display_form_location" {
  command = plan

  variables {
    location                       = "Sweden Central"
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == true
    error_message = "\"Sweden Central\" and \"swedencentral\" must resolve to the same geo-redundant backup default."
  }
}

# Poland Central has no geo-redundant backup for Postgres flexible server. Turning it on there
# would fail the apply, so the production default leaves it off.
run "production_geo_backup_off_in_an_unsupported_region" {
  command = plan

  variables {
    location                       = "polandcentral"
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "mode=production in Poland Central must leave geo-redundant backup off: the region does not support it."
  }
}

# A region the module has not checked against Microsoft's table is treated as unsupported, so
# the default can never turn on a setting Azure might refuse. The customer turns it on.
run "production_geo_backup_off_in_an_unlisted_region" {
  command = plan

  variables {
    location                       = "westeurope"
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "A region absent from the module's geo-redundant backup lookup must default to off."
  }
}

# The customer's explicit false wins over the production default in a supported region.
run "production_geo_backup_explicit_false_wins" {
  command = plan

  variables {
    postgres_geo_redundant_backup  = false
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "postgres_geo_redundant_backup = false must override the production default."
  }
}

# Evaluation installs leave it off by default, in a supported region too.
run "evaluation_geo_backup_off_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "mode=demo must leave geo-redundant backup off unless the customer sets it."
  }
}

# ...and the customer's explicit true wins there.
run "evaluation_geo_backup_explicit_true_wins" {
  command = plan

  variables {
    ingress_allowed_cidrs         = ["203.0.113.7/32"]
    postgres_geo_redundant_backup = true
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == true
    error_message = "postgres_geo_redundant_backup = true must turn geo-redundant backup on in any mode."
  }
}

# An existing server is never replaced to change geo-redundant backup. Azure accepts the
# setting only at creation, so the provider replaces the server to change it, and that
# destroys every Environment database on it. The first run creates a server the way an
# earlier module version would have — production, Sweden Central, geo-redundant backup off —
# and the second plans the same install with the input unset, where the new default resolves
# to on. ignore_changes must keep the planned value at what the server was created with.
#
# What this proves, and what it does not: under mock providers there is no real provider
# diff, so Terraform cannot report "must be replaced" here. What it can show is that the
# planned value of geo_redundant_backup_enabled stays false while the module's default for a
# new server is true; with no change to that attribute there is nothing for the provider to
# replace the server over. Only a plan against a real install shows the action itself.
#
# KEEP THESE TWO RUNS LAST IN THIS FILE. Every run in a file shares one state, and the first
# of them applies to it (mock state; nothing reaches Azure). Every other run is a plan against
# empty state, and a run added after these would plan against this install instead.
run "existing_server_created_without_geo_backup" {
  command = apply

  # Only the server and what it depends on. Mock providers return random strings as resource
  # IDs, and the resources that parse the server's ID (its diagnostic setting and alerts)
  # refuse one at apply. The server is the resource under test.
  plan_options {
    target = [azurerm_postgresql_flexible_server.this]
  }

  # Real-shaped IDs for what this run creates, so the teardown at the end of the file, which
  # evaluates the whole configuration against this state, can parse them.
  override_resource {
    target = azurerm_resource_group.data
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
    }
  }

  override_resource {
    target = azurerm_postgresql_flexible_server.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-test"
    }
  }

  variables {
    postgres_geo_redundant_backup  = false
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "Setup: the existing server must be created with geo-redundant backup off."
  }
}

run "existing_server_keeps_its_geo_backup_setting" {
  command = plan

  plan_options {
    target = [azurerm_postgresql_flexible_server.this]
  }

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  # The new default for this install is on...
  assert {
    condition     = local.postgres_geo_redundant_backup == true
    error_message = "Precondition of this test: the unset input must resolve to on for production in Sweden Central."
  }

  # ...and the existing server's planned value is still what it was created with.
  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    error_message = "A changed geo-redundant backup default must not change an existing server's setting — changing it replaces the server and destroys its data."
  }
}
