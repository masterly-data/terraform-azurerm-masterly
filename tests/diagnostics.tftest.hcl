# Diagnostics: the workspace, retention, load and availability alerts (diagnostics.tf).
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

# Exactly one diagnostic setting carries the apps' logs, and it is on the environment. A plan
# cannot compare the mock provider's computed ids, so `override_module` pins the environment's and
# both serving apps' outputs to known, distinct values; with them pinned, every setting the run
# plans is counted by its target rather than trusted by its name. Diagnostics are on, so the
# per-app settings exist beside it and are shown NOT to target the environment. BYO-DB keeps the
# starter server, whose id only an apply would make known, out of the run. The environment's
# logs_destination is asserted by the production run above, which overrides nothing. A test cannot
# enumerate every azurerm_monitor_diagnostic_setting, so the count covers the settings it names: a
# new diagnostic setting added to the module has to be added to that list, or "exactly one" stops
# counting it.
run "one_diagnostic_setting_targets_the_environment" {
  command = plan

  variables {
    identity_binding                    = "oidc"
    oidc_allowed_issuers                = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                       = "api-client-id"
    oidc_jwks_uri                       = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                      = "bff-client-id"
    oidc_client_secret                  = "s3cret"
    oidc_authority                      = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri                   = "https://app.example.com/api/auth/callback"
    external_database_url               = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_diagnostics                  = true
    enable_app_availability_diagnostics = true
  }

  override_module {
    target = module.aca_env
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
    }
  }

  override_module {
    target = module.api
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name                      = "ca-api"
      fqdn                      = "ca-api.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = false
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = []
    }
  }

  override_module {
    target = module.frontend
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name                      = "ca-frontend"
      fqdn                      = "ca-frontend.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = true
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = []
    }
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 2 &&
      length(azurerm_monitor_diagnostic_setting.postgres) == 0
    )
    error_message = "This run needs the per-app settings planned beside the environment's, or it proves nothing about them."
  }

  assert {
    condition = length([
      for target in concat(
        [azurerm_monitor_diagnostic_setting.aca_env.target_resource_id],
        [for s in azurerm_monitor_diagnostic_setting.app : s.target_resource_id],
        azurerm_monitor_diagnostic_setting.postgres[*].target_resource_id,
        azurerm_monitor_diagnostic_setting.redis[*].target_resource_id,
        azurerm_monitor_diagnostic_setting.redis_database[*].target_resource_id,
        azurerm_monitor_diagnostic_setting.key_vault[*].target_resource_id,
        azurerm_monitor_diagnostic_setting.service_bus[*].target_resource_id,
      ) : target if target == module.aca_env.id
    ]) == 1
    error_message = "Exactly one diagnostic setting must target the Container Apps environment."
  }

  assert {
    condition = (
      azurerm_monitor_diagnostic_setting.aca_env.target_resource_id == module.aca_env.id &&
      azurerm_monitor_diagnostic_setting.aca_env.log_analytics_destination_type == "Dedicated" &&
      toset([for l in azurerm_monitor_diagnostic_setting.aca_env.enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
    )
    error_message = "The setting on the environment must send ContainerAppConsoleLogs and ContainerAppSystemLogs to the resource-specific (Dedicated) tables."
  }
}

# The workspace accepts Microsoft Entra ID only and takes no ingestion over the public network,
# whatever the inputs say; by default it still answers queries from the public network, keeps
# its tables for 30 days, and keeps the Key Vault audit table, and only that table, for 90.
run "workspace_is_entra_only_with_no_public_ingestion" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.logs.local_authentication_enabled == false
    error_message = "The workspace must refuse its shared keys (local authentication off)."
  }

  assert {
    condition     = module.logs.internet_ingestion_access_type == "Disabled"
    error_message = "The workspace must refuse ingestion over the public network."
  }

  assert {
    condition     = var.log_query_public_access == true && module.logs.internet_query_access_type == "Enabled"
    error_message = "By default the workspace must answer queries from the public network (log_query_public_access = true)."
  }

  assert {
    condition     = var.log_retention_days == 30 && module.logs.retention_in_days == 30
    error_message = "The workspace's retention must default to 30 days."
  }

  assert {
    condition = (
      var.security_log_retention_days == 90 &&
      length(module.logs.table_retention_days) == 1 &&
      module.logs.table_retention_days["AZKVAuditLogs"] == 90
    )
    error_message = "AZKVAuditLogs, and no other table, must carry its own retention, defaulting to 90 days."
  }
}

# The query setting and both retentions follow their inputs, in production too; local
# authentication and public ingestion stay off.
run "workspace_query_access_and_retention_follow_the_inputs" {
  command = plan

  variables {
    mode                        = "production"
    identity_binding            = "oidc"
    oidc_allowed_issuers        = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience               = "api-client-id"
    oidc_jwks_uri               = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id              = "bff-client-id"
    oidc_client_secret          = "s3cret"
    oidc_authority              = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri           = "https://app.example.com/api/auth/callback"
    license_token               = "eyJ.fake.jwt"
    license_public_jwk          = "{\"kty\":\"EC\"}"
    initial_owner_email         = "owner@example.com"
    enable_key_vault            = true
    enable_redis                = true
    redis_offering              = "cache"
    enable_workers              = true
    api_max_replicas            = 3
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    log_query_public_access     = false
    log_retention_days          = 365
    security_log_retention_days = 730
  }

  assert {
    condition     = module.logs.internet_query_access_type == "Disabled"
    error_message = "log_query_public_access = false must stop the workspace answering queries from the public network."
  }

  assert {
    condition     = module.logs.local_authentication_enabled == false && module.logs.internet_ingestion_access_type == "Disabled"
    error_message = "Local authentication and public ingestion must stay off whatever the other inputs say."
  }

  assert {
    condition = (
      module.logs.retention_in_days == 365 &&
      length(module.logs.table_retention_days) == 1 &&
      module.logs.table_retention_days["AZKVAuditLogs"] == 730
    )
    error_message = "The workspace's retention must follow log_retention_days, and AZKVAuditLogs's must follow security_log_retention_days."
  }

  # Set, and equal to the retention: Azure fills an unset total retention in on create, and the
  # next plan's attempt to clear it is refused, which failed every apply after the first.
  assert {
    condition     = module.logs.table_total_retention_days["AZKVAuditLogs"] == 730
    error_message = "AZKVAuditLogs's total retention must be set, to security_log_retention_days (no archive tier)."
  }
}

# Guard: both retentions are refused below 30 days, the least the workspace accepts.
run "log_retention_below_30_days_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    log_retention_days          = 29
    security_log_retention_days = 29
  }

  expect_failures = [var.log_retention_days, var.security_log_retention_days]
}

# Guard: both retentions are refused above 730 days, the most a table keeps for querying.
run "log_retention_above_730_days_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    log_retention_days          = 731
    security_log_retention_days = 731
  }

  expect_failures = [var.log_retention_days, var.security_log_retention_days]
}

# The environment's setting is not part of the diagnostics surface. The environment sent its logs
# to the workspace in every mode before it moved to Azure Monitor, and the diagnostic bundle reads
# them in every mode, so turning diagnostics off (the default outside production) must not take
# the logs with it. Nothing is overridden, so the environment's logs_destination is the module's
# own value.
run "container_logs_reach_the_workspace_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = false
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 0 &&
      length(azurerm_monitor_diagnostic_setting.postgres) == 0 &&
      azurerm_monitor_diagnostic_setting.aca_env.log_analytics_destination_type == "Dedicated" &&
      toset([for l in azurerm_monitor_diagnostic_setting.aca_env.enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"]) &&
      module.aca_env.logs_destination == "azure-monitor"
    )
    error_message = "With diagnostics off, the environment's diagnostic setting must still send both Container Apps log categories to the workspace."
  }
}

run "production_mode_load_alerts_on_byo_db" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  # BYO-DB: the module wires no telemetry for a server it does not provision, so it claims no
  # Postgres load coverage either — and the unknown-SKU warning is not raised, because there is
  # no server to size.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_cpu) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_connections) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_iops) == 0
    )
    error_message = "A BYO-DB install must carry no Postgres load alerts."
  }

  # The api latency rule (MAS-1291). Severity 2, the bottom of the saturation band: a warning
  # with time to act, never mistaken for the availability band's 0.
  assert {
    condition = (
      length(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency) == 1 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].severity == 2 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].evaluation_frequency == "PT5M" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].window_duration == "PT15M"
    )
    error_message = "Production must carry the api latency rule at severity 2, evaluated every 5 minutes over 15."
  }

  # One row means "over the line": Count > 0. LessThan would fire on every healthy evaluation
  # and still plan, which is why the triple is pinned (MAS-307).
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].time_aggregation_method == "Count" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].threshold == 0 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].failing_periods[0].number_of_evaluation_periods == 1 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].failing_periods[0].minimum_failing_periods_to_trigger_alert == 1
    )
    error_message = "The api latency rule must fire when its query returns at least one row, on one failing evaluation."
  }

  # The query's load-bearing tokens. The access-line pattern is the contract with the api
  # image: `<METHOD> <route> -> <status> in <ms>ms`, written by every released api image. Reword
  # it and the rule matches nothing, forever, silently. The streaming exclusions keep exports,
  # the assistant's chat and MCP from owning the percentile; the minimum-traffic floor keeps a
  # quiet install from paging on two slow requests; the default threshold is 2000 ms.
  assert {
    condition = (
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ContainerAppConsoleLogs") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "_CL") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ContainerAppName_s == \"ca-api\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "@\"[A-Z]+ ([^ ]+) -> [0-9]{3} in ([0-9.]+)ms\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "percentile(DurationMs, 95)") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "Route !contains \":export\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "Route !endswith \"/ai/chat\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "Route !startswith \"/mcp\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "Requests >= 50 and P95Ms > 2000") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "union isfuzzy=true") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]")
    )
    error_message = "The api latency query must parse the api's access line, exclude streaming routes, take the 95th percentile against the threshold above a traffic floor, and keep the union's empty-datatable anchor."
  }

  # Worker memory (MAS-1291): 85% of the replica's configured 1Gi, in bytes, read as the
  # Maximum across replicas so the one replica near its limit is not averaged away.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.workers_memory) == 1 &&
      azurerm_monitor_metric_alert.workers_memory[0].severity == 2 &&
      azurerm_monitor_metric_alert.workers_memory[0].window_size == "PT15M" &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].metric_namespace == "Microsoft.App/containerapps" &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].metric_name == "WorkingSetBytes" &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].aggregation == "Maximum" &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].operator == "GreaterThan" &&
      module.workers[0].memory == "1Gi" &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].threshold == 912680550 &&
      length(azurerm_monitor_metric_alert.workers_memory[0].criteria[0].dimension) == 0
    )
    error_message = "The workers memory alert must read WorkingSetBytes (Maximum) above 85% of the replica's 1Gi."
  }

  # No broker here, so no dead-letter alert.
  assert {
    condition     = length(azurerm_monitor_metric_alert.servicebus_dead_letters) == 0
    error_message = "Without enable_service_bus there is no dead-letter queue to alert on."
  }
}

# The load thresholds are inputs, and moving one moves the alert (MAS-1291).
run "load_alert_thresholds_are_tunable" {
  command = plan

  variables {
    ingress_allowed_cidrs              = ["203.0.113.7/32"]
    enable_diagnostics                 = true
    enable_workers                     = true
    postgres_sku_name                  = "GP_Standard_D4ds_v5"
    alert_postgres_cpu_percent         = 90
    alert_postgres_connections_percent = 50
    alert_postgres_max_connections     = 1000
    alert_postgres_iops_percent        = 70
    alert_api_p95_ms                   = 750
    alert_workers_memory_percent       = 50
  }

  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_cpu[0].criteria[0].threshold == 90 &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 500 &&
      azurerm_monitor_metric_alert.postgres_iops[0].criteria[0].threshold == 70 &&
      azurerm_monitor_metric_alert.workers_memory[0].criteria[0].threshold == 536870912 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "P95Ms > 750")
    )
    error_message = "Each load threshold must follow its input; an explicit alert_postgres_max_connections must override the SKU-derived limit."
  }
}

# The connections alert follows max_connections from the map; an explicit
# alert_postgres_max_connections beats it; the map beats the SKU default.
run "connections_alert_follows_max_connections_from_server_parameters" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_diagnostics         = true
    postgres_sku_name          = "GP_Standard_D4ds_v5"
    postgres_server_parameters = { max_connections = "400" }
  }

  assert {
    condition     = azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 280
    error_message = "With max_connections = 400 in postgres_server_parameters, the connections alert must fire at 70% of 400."
  }
}

run "explicit_alert_max_connections_beats_server_parameters" {
  command = plan

  variables {
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    enable_diagnostics             = true
    postgres_sku_name              = "GP_Standard_D4ds_v5"
    postgres_server_parameters     = { max_connections = "400" }
    alert_postgres_max_connections = 1000
  }

  assert {
    condition     = azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 700
    error_message = "An explicit alert_postgres_max_connections must beat max_connections in postgres_server_parameters."
  }
}

run "server_parameters_max_connections_sizes_the_alert_on_an_unknown_sku" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_diagnostics         = true
    postgres_sku_name          = "GP_Standard_DC2ads_v5"
    postgres_server_parameters = { max_connections = "400" }
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.postgres_connections) == 1 && azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 280
    error_message = "max_connections in postgres_server_parameters must be enough to create the connections alert on a SKU the module cannot size."
  }
}

# The two console-log rules read the resource-specific ContainerAppConsoleLogs table and no
# legacy _CL table. Pinned as ONE union, in full: a second union, a dropped operand or a lost
# anchor would each plan and apply cleanly and only show at evaluation time. The table's columns
# carry no `_s` suffix, so its operand renames them onto the names the rest of each query, and
# the readiness rule's ContainerAppName_s dimension, read.
#
# The app filters are taken from module outputs, never retyped, and pinned to exactly the apps
# each rule is about: the api for latency, the two serving apps for readiness. ca-workers is
# excluded from readiness by design — it has no probe and writes no readiness line — and this
# run and the next prove the filters do not move with enable_workers, in either direction.
run "container_log_alerts_read_the_console_log_table_with_workers" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    enable_workers        = true
  }

  assert {
    condition = (
      output.workers_app_name == "ca-workers" &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "This run must plan the workers app and both console-log rules, or the exclusions below prove nothing."
  }

  assert {
    condition = (
      length(regexall("union", azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "union isfuzzy=true\n  (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),\n  (ContainerAppConsoleLogs | project TimeGenerated, ContainerAppName_s = ContainerAppName, Log_s = Log)\n| where ")
    )
    error_message = "The api latency query must read ContainerAppConsoleLogs, and no legacy _CL table, in one fuzzy union with the empty-datatable anchor, renaming the new table's ContainerAppName and Log onto ContainerAppName_s and Log_s."
  }

  assert {
    condition = (
      length(regexall("union", azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "union isfuzzy=true\n  (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),\n  (ContainerAppConsoleLogs | project TimeGenerated, ContainerAppName_s = ContainerAppName, Log_s = Log)\n| where ")
    )
    error_message = "The readiness query must read ContainerAppConsoleLogs, and no legacy _CL table, in one fuzzy union with the empty-datatable anchor, renaming the new table's ContainerAppName and Log onto ContainerAppName_s and Log_s."
  }

  assert {
    condition = (
      module.api.name == "ca-api" &&
      length(regexall("ContainerAppName_s (==|in) ", azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "| where ContainerAppName_s == \"${module.api.name}\"\n") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ca-frontend") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ca-workers")
    )
    error_message = "The api latency query must filter on exactly the api app, by its module output name."
  }

  assert {
    condition = (
      module.api.name == "ca-api" &&
      module.frontend.name == "ca-frontend" &&
      length(regexall("ContainerAppName_s (==|in) ", azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "| where ContainerAppName_s in (\"${module.api.name}\", \"${module.frontend.name}\")\n") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "ca-workers")
    )
    error_message = "The readiness query must filter on exactly the api and the frontend, by their module output names, and never on ca-workers."
  }
}

run "container_log_alerts_read_the_console_log_table_without_workers" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    enable_workers        = false
  }

  assert {
    condition = (
      output.workers_app_name == null &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "This run must plan no workers app and both console-log rules."
  }

  assert {
    condition = (
      length(regexall("union", azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "union isfuzzy=true\n  (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),\n  (ContainerAppConsoleLogs | project TimeGenerated, ContainerAppName_s = ContainerAppName, Log_s = Log)\n| where ")
    )
    error_message = "The api latency query must read ContainerAppConsoleLogs, and no legacy _CL table, in one fuzzy union with the empty-datatable anchor, renaming the new table's ContainerAppName and Log onto ContainerAppName_s and Log_s."
  }

  assert {
    condition = (
      length(regexall("union", azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "union isfuzzy=true\n  (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),\n  (ContainerAppConsoleLogs | project TimeGenerated, ContainerAppName_s = ContainerAppName, Log_s = Log)\n| where ")
    )
    error_message = "The readiness query must read ContainerAppConsoleLogs, and no legacy _CL table, in one fuzzy union with the empty-datatable anchor, renaming the new table's ContainerAppName and Log onto ContainerAppName_s and Log_s."
  }

  assert {
    condition = (
      module.api.name == "ca-api" &&
      length(regexall("ContainerAppName_s (==|in) ", azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "| where ContainerAppName_s == \"${module.api.name}\"\n") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ca-frontend") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency[0].criteria[0].query, "ca-workers")
    )
    error_message = "The api latency query must filter on exactly the api app, by its module output name."
  }

  assert {
    condition = (
      module.api.name == "ca-api" &&
      module.frontend.name == "ca-frontend" &&
      length(regexall("ContainerAppName_s (==|in) ", azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query)) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "| where ContainerAppName_s in (\"${module.api.name}\", \"${module.frontend.name}\")\n") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "ca-workers")
    )
    error_message = "The readiness query must filter on exactly the api and the frontend, by their module output names; dropping the workers app must not drop a serving app."
  }
}

# A SKU the module cannot size: no connections alert, and a plan-time warning that says how to
# get one — never an alert measured against a guessed limit. The other load alerts are
# unaffected.
run "unknown_postgres_sku_gets_no_connections_alert_and_a_warning" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    postgres_sku_name     = "GP_Standard_DC2ads_v5"
  }

  expect_failures = [check.postgres_connections_alert_has_a_limit]

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_connections) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_cpu) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_iops) == 1
    )
    error_message = "An unrecognised SKU (GP_Standard_DC2ads_v5, a confidential-compute SKU the module does not size) must drop only the connections alert."
  }
}

# The burstable default is sized from the listed table: B1ms is 2 GiB, 50 connections.
run "burstable_default_sizes_the_connections_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
  }

  assert {
    condition     = azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 35
    error_message = "B_Standard_B1ms (max_connections 50) must alert above 35 active connections at the 70% default."
  }
}

# Memory Optimized E-series: 8 GiB per vCore. E4ds_v5 is 32 GiB, 3437 connections.
run "memory_optimized_sku_sizes_the_connections_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    postgres_sku_name     = "MO_Standard_E4ds_v5"
  }

  assert {
    condition     = azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == 2405
    error_message = "MO_Standard_E4ds_v5 (max_connections 3437) must alert above 2405 active connections at the 70% default."
  }
}

# Guards on the threshold inputs: a percentage is a percentage, a limit is a whole count.
run "load_alert_percent_out_of_range_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs                  = ["203.0.113.7/32"]
    alert_postgres_cpu_percent             = 100
    alert_postgres_max_connections         = 0
    alert_workers_memory_percent           = 0
    alert_api_p95_ms                       = 0
    alert_servicebus_dead_letter_threshold = -1
  }

  expect_failures = [
    var.alert_postgres_cpu_percent,
    var.alert_postgres_max_connections,
    var.alert_workers_memory_percent,
    var.alert_api_p95_ms,
    var.alert_servicebus_dead_letter_threshold,
  ]
}

# --- Availability alerts and the action group do not depend on enable_diagnostics ----------
# ADR 0080, amendment of 2026-10-18 (MAS-292): postgres-unavailable, <app>-unavailable and
# app-not-ready, and the module's action group, exist in every mode. Everything else in
# diagnostics.tf stays behind the flag. A production plan with no notification target is
# refused unless alerts_routed_externally is set.

# Demo, diagnostics unset, no notification target (which demo does not require): the
# availability alerts exist; the saturation and load alerts, postgres-silent, the absence
# rules and every diagnostic setting do not.
run "availability_alerts_exist_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    alert_email           = null
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "api") &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "frontend") &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "With diagnostics off, the database, api and frontend availability alerts and app-not-ready must still be created."
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_5xx) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_cpu) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_connections) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_iops) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_storage) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_cpu_credits) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 0 &&
      length(azurerm_monitor_diagnostic_setting.postgres) == 0 &&
      length(azurerm_monitor_diagnostic_setting.app) == 0 &&
      length(azurerm_monitor_diagnostic_setting.redis) == 0 &&
      length(azurerm_monitor_diagnostic_setting.redis_database) == 0 &&
      length(azurerm_monitor_diagnostic_setting.key_vault) == 0 &&
      length(azurerm_monitor_diagnostic_setting.service_bus) == 0 &&
      length(azurerm_monitor_metric_alert.redis_evictions) == 0 &&
      length(azurerm_monitor_metric_alert.redis_memory) == 0 &&
      length(azurerm_monitor_metric_alert.servicebus_dead_letters) == 0 &&
      length(azurerm_monitor_metric_alert.workers_memory) == 0 &&
      length(azurerm_monitor_action_group.alerts) == 0
    )
    error_message = "With diagnostics off, the saturation and load alerts, postgres-silent, the absence rules, the diagnostic settings and (with no alert_email) the action group must not be created."
  }
}

# A scale-to-zero api and frontend lose their unavailable alert, but app-not-ready stays and
# its query names both serving apps.
run "scale_to_zero_serving_apps_keep_app_not_ready_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_min_replicas      = 0
    frontend_min_replicas = 0
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1 &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "\"ca-api\", \"ca-frontend\"")
    )
    error_message = "With both serving apps at a zero floor there is no <app>-unavailable alert, but app-not-ready must remain and name both apps."
  }
}

run "workers_get_a_no_replica_alert_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    workers_min_replicas  = 1
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 3 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "workers")
    )
    error_message = "A workers app with a floor of at least one must carry a no-replica alert whether or not diagnostics are on."
  }
}

# alert_email with diagnostics explicitly off still creates the module's action group, and the
# availability alerts exist beside it. availability_routing.tftest.hcl checks that each alert's
# action references the group's id, through an apply that makes the computed id known.
run "action_group_exists_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = false
    alert_email           = "ops@example.com"
  }

  assert {
    condition = (
      length(azurerm_monitor_action_group.alerts) == 1 &&
      azurerm_monitor_action_group.alerts[0].name == "ag-masterly-alerts" &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "alert_email must create ag-<prefix>-alerts with diagnostics off, and the availability alerts must exist beside it."
  }
}

# An injected group wins and the module creates none; the availability alerts reference it.
run "injected_action_group_is_used_with_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = false
    alert_email           = null
    alert_action_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ops/providers/microsoft.insights/actionGroups/ag-ops"
  }

  assert {
    condition = (
      length(azurerm_monitor_action_group.alerts) == 0 &&
      contains([for a in azurerm_monitor_metric_alert.postgres_unavailable[0].action : a.action_group_id], var.alert_action_group_id) &&
      contains([for a in azurerm_monitor_metric_alert.app_unavailable["api"].action : a.action_group_id], var.alert_action_group_id) &&
      contains([for a in azurerm_monitor_metric_alert.app_unavailable["frontend"].action : a.action_group_id], var.alert_action_group_id) &&
      contains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].action[0].action_groups, var.alert_action_group_id)
    )
    error_message = "With alert_action_group_id set and no alert_email, no module action group is created and the availability alerts must route to the given id."
  }
}

# --- The production notification-target refusal -------------------------------------------

run "production_without_a_notification_target_is_refused" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3
    alert_email          = null

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.alert_email]
}

# The refusal does not depend on enable_diagnostics.
run "production_without_a_notification_target_is_refused_with_diagnostics_off" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3
    enable_diagnostics   = false
    alert_email          = null

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.alert_email]
}

# The escape hatch lets the same plans through (diagnostics unset here, off in the next run).
run "production_without_a_target_plans_with_the_escape_hatch" {
  command = plan

  variables {
    mode                     = "production"
    identity_binding         = "oidc"
    oidc_allowed_issuers     = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience            = "api-client-id"
    oidc_jwks_uri            = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id           = "bff-client-id"
    oidc_client_secret       = "s3cret"
    oidc_authority           = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri        = "https://app.example.com/api/auth/callback"
    license_token            = "eyJ.fake.jwt"
    license_public_jwk       = "{\"kty\":\"EC\"}"
    initial_owner_email      = "owner@example.com"
    enable_key_vault         = true
    enable_redis             = true
    redis_offering           = "cache"
    enable_workers           = true
    api_max_replicas         = 3
    alert_email              = null
    alerts_routed_externally = true

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts) == 0
    error_message = "The escape hatch creates no action group; it only satisfies the check."
  }
}

run "production_without_a_target_plans_with_the_escape_hatch_and_diagnostics_off" {
  command = plan

  variables {
    mode                     = "production"
    identity_binding         = "oidc"
    oidc_allowed_issuers     = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience            = "api-client-id"
    oidc_jwks_uri            = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id           = "bff-client-id"
    oidc_client_secret       = "s3cret"
    oidc_authority           = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri        = "https://app.example.com/api/auth/callback"
    license_token            = "eyJ.fake.jwt"
    license_public_jwk       = "{\"kty\":\"EC\"}"
    initial_owner_email      = "owner@example.com"
    enable_key_vault         = true
    enable_redis             = true
    redis_offering           = "cache"
    enable_workers           = true
    api_max_replicas         = 3
    enable_diagnostics       = false
    alert_email              = null
    alerts_routed_externally = true

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.app_unavailable) == 3
    error_message = "The availability alerts exist with diagnostics off and the escape hatch set."
  }
}

# Either target alone satisfies the check: alert_email (the file-wide value) in the first,
# alert_action_group_id in the second.
run "production_with_only_alert_email_plans" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3
    alert_email          = "ops@example.com"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts) == 1
    error_message = "alert_email alone must satisfy the production check and create the action group."
  }
}

run "production_with_only_alert_action_group_id_plans" {
  command = plan

  variables {
    mode                  = "production"
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
    api_max_replicas      = 3
    alert_email           = null
    alert_action_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ops/providers/microsoft.insights/actionGroups/ag-ops"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts) == 0
    error_message = "alert_action_group_id alone must satisfy the production check and create no module action group."
  }
}

# The refusal is production's: a demo install with no target and the hatch unset plans.
run "demo_without_a_notification_target_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    alert_email           = null
  }

  assert {
    condition     = length(azurerm_monitor_action_group.alerts) == 0
    error_message = "A demo install needs no notification target."
  }
}
