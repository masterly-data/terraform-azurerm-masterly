# Install modes and production-mode guards (main.tf), and data residency.
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

# mode=production (ADR 0066 inc 4): the full production wiring plans clean.
run "production_mode_full_wiring_plans" {
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

  assert {
    condition     = length(azurerm_key_vault.this) == 1 && length(azurerm_redis_cache.this) == 1 && output.workers_app_name == "ca-workers"
    error_message = "Production wiring must provision the vault, Redis, and the workers app."
  }

  # Hardening in production: purge protection armed, default-deny ACLs, and a private
  # endpoint (+ its private DNS zone) that the apps reach it on.
  #
  # The endpoint is ENABLED here because this run states a deployer address, which is what
  # lets Terraform seed the vault's secrets from outside the VNet. That is a firewalled
  # public endpoint, not an open one: default_action stays Deny and the only address admitted
  # is the one given. The fully-closed shape is asserted in
  # production_in_vnet_apply_keeps_the_vault_closed below.
  assert {
    condition = (
      azurerm_key_vault.this[0].purge_protection_enabled == true &&
      azurerm_key_vault.this[0].network_acls[0].default_action == "Deny" &&
      azurerm_key_vault.this[0].network_acls[0].ip_rules == toset(["203.0.113.7"]) &&
      length(azurerm_private_endpoint.key_vault) == 1 &&
      length(azurerm_private_dns_zone.key_vault) == 1
    )
    error_message = "Production Key Vault must have purge protection, default-deny ACLs admitting only the deployer, and a private endpoint."
  }

  # Redis is private-endpoint-only in production too.
  assert {
    condition     = azurerm_redis_cache.this[0].public_network_access_enabled == false && length(azurerm_private_endpoint.redis) == 1
    error_message = "Production Redis must disable public access and be reached over a private endpoint."
  }

  # Diagnostics on-by-default in production: settings for the enabled data-plane resources
  # (Redis + Key Vault here; Postgres is BYO-DB so absent) plus the app 5xx alerts.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.redis) == 1 &&
      length(azurerm_monitor_diagnostic_setting.key_vault) == 1 &&
      length(azurerm_monitor_diagnostic_setting.postgres) == 0 &&
      length(azurerm_monitor_metric_alert.app_5xx) == 2
    )
    error_message = "Production must wire diagnostics for the enabled data-plane resources and the app 5xx alerts (Postgres absent on BYO-DB)."
  }

  # Availability, the other half of the catalogue (MAS-263). All THREE apps declare a replica
  # floor in production, so all three get the "no running replica" alert. The database alerts
  # are absent here for the same reason the diagnostic setting is: on BYO-DB the module wires no
  # telemetry for a server it does not provision, so it has no stream whose end it could notice.
  #
  # The key set is asserted, not just the count (MAS-305): ca-workers is the one that cannot be
  # covered by anything else in the file — it serves no traffic, so the 5xx alert reads the two
  # apps that keep answering fine while the queue behind them grows. A regression that dropped
  # workers and picked up some other app would hold the count at three.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 3 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "api") &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "frontend") &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "workers") &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 0
    )
    error_message = "Production must alert on all three apps having no replica — api, frontend AND workers — and must not claim database availability coverage on BYO-DB."
  }

  # The workers alert must read the same metric as its siblings, and read it the same way.
  # Every one of these still plans if it is wrong: a Minimum aggregation would fire on every
  # ordinary revision roll, and GreaterThan would invert the alert into one that fires whenever
  # the pipeline is healthy. Pinned for the reason the is_db_alive criteria are pinned below.
  #
  # `Replicas` on the Microsoft.App/containerapps namespace is read off Learn's supported-metrics
  # reference for the resource type, which documents it as "Replica Count — number of replicas
  # count of container app", Average/Total/Maximum/Minimum, PT1M. Count is NOT among them, which
  # is why absence detection here is a floor-gated Maximum and not a Count-aggregation rule.
  assert {
    condition = (
      azurerm_monitor_metric_alert.app_unavailable["workers"].criteria[0].metric_namespace == "Microsoft.App/containerapps" &&
      azurerm_monitor_metric_alert.app_unavailable["workers"].criteria[0].metric_name == "Replicas" &&
      azurerm_monitor_metric_alert.app_unavailable["workers"].criteria[0].aggregation == "Maximum" &&
      azurerm_monitor_metric_alert.app_unavailable["workers"].criteria[0].operator == "LessThan" &&
      azurerm_monitor_metric_alert.app_unavailable["workers"].criteria[0].threshold == 1
    )
    error_message = "The workers availability alert must read Replicas (Microsoft.App/containerapps) with Maximum aggregation below 1."
  }

  # An operator paged for ca-workers must not be told the install is unreachable — it is not.
  # The severity band in this module marks ABSENCE, so workers keeps severity 0 alongside the
  # serving apps; what differs is the sentence, and a copy-paste that gave workers the serving
  # apps' wording would page somebody to check a front door that is working.
  assert {
    condition = (
      azurerm_monitor_metric_alert.app_unavailable["workers"].severity == 0 &&
      strcontains(azurerm_monitor_metric_alert.app_unavailable["workers"].description, "async pipeline has STOPPED") &&
      strcontains(azurerm_monitor_metric_alert.app_unavailable["api"].description, "this install is DOWN")
    )
    error_message = "The workers alert must carry the availability severity and say the pipeline stopped, not that the install is down."
  }

  # Severity is what tells an operator "down" from "strained" in the notification itself: every
  # saturation alert in this module is 1 or 2, every availability alert is 0. If these converge
  # the distinction the alert set exists to draw stops being visible without opening the portal.
  assert {
    condition = (
      azurerm_monitor_metric_alert.app_unavailable["api"].severity == 0 &&
      azurerm_monitor_metric_alert.app_5xx["api"].severity == 1
    )
    error_message = "An availability alert must outrank a saturation alert (severity 0 vs 1) — the severity is how the two states are told apart."
  }

  # The wedged-replica alert (MAS-318): present, and present for the right reason. It is NOT
  # gated on a replica floor the way app_unavailable is — an app scaled to zero runs no probe
  # and writes no line, so the rule is silent there rather than noisy — and it carries the
  # availability severity, because this module's severity band separates the QUESTION (is the
  # install serving?) from strain, which is what the README sells to operators.
  assert {
    condition = (
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].severity == 0
    )
    error_message = "Production must carry the readiness alert, at the availability severity."
  }

  # The criteria triple, pinned for the reason MAS-307 exists: the provider validates none of
  # these against each other or against the query, so every wrong combination below plans and
  # applies exactly as cleanly as the right one and then behaves like a healthy install.
  # `LessThan` here would invert the rule into one that fires whenever every app is ready.
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].time_aggregation_method == "Count" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].threshold == 0 &&
      azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].dimension[0].name == "ContainerAppName_s"
    )
    error_message = "The readiness alert must fire when the query returns at least one row, split by app."
  }

  # The QUERY, which nothing else in this repo can check. `terraform validate` does not parse
  # KQL and neither does the provider; only Azure does, at create time, which this repo has no
  # credentials to reach (ADR 0067 — CI is mock-provider only). What IS checkable here is that
  # the load-bearing tokens are all still in the string, and each one of them is load-bearing:
  #
  #  * the shared prefix — the whole reason one rule covers both this module's apps and
  #    Masterly's own control plane. Reword it and the rule matches nothing, forever, silently.
  #  * both app names, so a rename cannot leave the filter pointing at an app that is gone.
  #  * the minute-bucket count and its threshold — what makes the rule sustained rather than
  #    edge-triggered, and what keeps a cold start (485s of legitimate probe failure, main.tf)
  #    under the bar.
  #  * the empty-datatable anchor, which reads as redundant next to `isfuzzy` and is not: a
  #    fuzzy union whose only operand is a missing table still fails with SEM0104, so deleting
  #    the anchor leaves a query that plans, applies, and only breaks at evaluation time on a
  #    fresh install.
  #
  # This is assertable at all only because the query interpolates configured NAMES; the
  # postgres_silent query interpolates a resource id, which is unknown at plan, and its text is
  # therefore unreachable from here (see the note in the starter-server run below).
  assert {
    condition = (
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "readiness check failed") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "ContainerAppConsoleLogs") &&
      !strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "_CL") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "\"ca-api\", \"ca-frontend\"") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "dcount(bin(TimeGenerated, 1m))") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "FailingMinutes >= 30") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "union isfuzzy=true") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready[0].criteria[0].query, "datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]")
    )
    error_message = "The readiness query must filter the console log for both serving apps on the shared prefix, count distinct failing minutes against a 30-minute bar, and keep the union's empty-datatable anchor."
  }

  # The query's one premise, enforced rather than remembered: it counts distinct MINUTES in
  # which a failing probe was logged, so it needs at least one probe per minute to read a wedge
  # at full speed. The module fixes both apps at 10 seconds. A future change past 60 seconds
  # would not break the rule — it degrades to firing later, never to silence — but it would make
  # the 30-of-60 bar mean something other than what the comment on the resource says it means.
  assert {
    condition = (
      module.api.readiness_probe.interval_seconds <= 60 &&
      module.frontend.readiness_probe.interval_seconds <= 60
    )
    error_message = "The readiness alert counts failing minutes, so both serving apps must probe at least once a minute."
  }

  # App availability diagnostics, on by default in production (ADR 0080, amendment of
  # 2026-10-07; MAS-372). All three apps send their platform metrics to the workspace, and all
  # three carry an absence rule, because production requires a replica floor on every one of
  # them. The key set is asserted, not the count, for the reason app_unavailable's is.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 3 &&
      contains(keys(azurerm_monitor_diagnostic_setting.app), "api") &&
      contains(keys(azurerm_monitor_diagnostic_setting.app), "frontend") &&
      contains(keys(azurerm_monitor_diagnostic_setting.app), "workers") &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 3 &&
      contains(keys(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent), "api") &&
      contains(keys(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent), "frontend") &&
      contains(keys(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent), "workers")
    )
    error_message = "Production must send all three apps' metrics to the workspace and carry an absence rule for each of api, frontend and workers by default."
  }

  # What the setting sends. AllMetrics is what puts `Replicas` and its siblings in AzureMetrics,
  # which is all the absence rule reads; no log category, because the diagnostic setting on the
  # environment sends every app's console and system logs to the same workspace, and a
  # second copy is billed twice. Each app is named rather than iterated, so an app that dropped
  # out of the map fails here instead of passing an empty loop.
  assert {
    condition = alltrue([
      for app in ["api", "frontend", "workers"] : (
        length(azurerm_monitor_diagnostic_setting.app[app].enabled_log) == 0 &&
        length(azurerm_monitor_diagnostic_setting.app[app].enabled_metric) == 1 &&
        one([for m in azurerm_monitor_diagnostic_setting.app[app].enabled_metric : m.category]) == "AllMetrics" &&
        azurerm_monitor_diagnostic_setting.app[app].name == "diag-masterly-${app}"
      )
    ])
    error_message = "The api, frontend and workers diagnostic settings must each send AllMetrics and no log category."
  }

  # The apps' logs leave the environment through Azure Monitor, not with the workspace's shared
  # key, and reach the workspace through the one diagnostic setting on the environment: both
  # Container Apps log categories, into the resource-specific tables.
  assert {
    condition     = module.aca_env.logs_destination == "azure-monitor"
    error_message = "The Container Apps environment must send its logs through Azure Monitor (logs_destination = \"azure-monitor\")."
  }

  assert {
    condition = (
      azurerm_monitor_diagnostic_setting.aca_env.name == "diag-masterly-aca-env" &&
      azurerm_monitor_diagnostic_setting.aca_env.log_analytics_destination_type == "Dedicated" &&
      length(azurerm_monitor_diagnostic_setting.aca_env.enabled_log) == 2 &&
      toset([for l in azurerm_monitor_diagnostic_setting.aca_env.enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
    )
    error_message = "The environment's diagnostic setting must send ContainerAppConsoleLogs and ContainerAppSystemLogs, and nothing else, to the resource-specific (Dedicated) tables."
  }

  # The criteria, pinned for the reason postgres_silent's are: SILENCE has to be the firing
  # state. GreaterThan, or a threshold of 0, plans and applies exactly as cleanly and inverts the
  # rule into one that fires on every healthy evaluation or never fires at all. The single
  # evaluation period is what Azure accepts for a query that projects no TimeGenerated (more is
  # a 400 on create), so the 45-minute window carries the silence and is pinned beside it.
  assert {
    condition = alltrue([
      for app, rule in azurerm_monitor_scheduled_query_rules_alert_v2.app_silent : (
        rule.criteria[0].time_aggregation_method == "Count" &&
        rule.criteria[0].operator == "LessThan" &&
        rule.criteria[0].threshold == 1 &&
        rule.criteria[0].failing_periods[0].number_of_evaluation_periods == 1 &&
        rule.criteria[0].failing_periods[0].minimum_failing_periods_to_trigger_alert == 1 &&
        rule.window_duration == "PT45M" &&
        rule.evaluation_frequency == "PT10M" &&
        rule.auto_mitigation_enabled == true &&
        rule.skip_query_validation == false &&
        rule.severity == 0 &&
        rule.name == "alert-masterly-${app}-silent"
      )
    ])
    error_message = "Each app absence rule must fire on an empty result (Count < 1) over one 45-minute period, at the availability severity, resolving itself."
  }

  # The sentence an operator reads: a silent ca-workers is a stopped pipeline, not a down
  # install — the distinction app_unavailable draws, carried over rather than retyped.
  assert {
    condition = (
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["workers"].description, "async pipeline has STOPPED") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["api"].description, "this install is DOWN") &&
      strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent["api"].description, "no metrics for 45 minutes")
    )
    error_message = "The app absence rules must say what stopped: the pipeline for workers, the install for the serving apps."
  }
}

# Guard: mode=production refuses a single-replica api (SPOF + downtime on every deploy).
run "production_single_replica_api_is_rejected" {
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
    api_max_replicas     = 1 # single replica in production -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.api_max_replicas]
}

# Guard: mode=production refuses the in-process worker (the pipeline must run in ca-workers).
run "production_without_workers_is_rejected" {
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
    api_max_replicas     = 2
    # enable_workers stays false -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.enable_workers]
}

# Guard: production without the durable seams is unrepresentable at plan time.
run "production_without_redis_is_rejected" {
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
    enable_key_vault     = true
    # enable_redis missing -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# --- Data residency: the declared geo is checked against where resources actually land ----
# `location` and `masterly_region` were independent inputs that nothing reconciled, so an
# install could sit in Sweden and tell customers (and auditors, and the usage ledger) that it
# was "us". These pin the reconciliation.

# Guard: a geo that contradicts the Azure location is refused at plan.
run "residency_mismatch_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    # swedencentral is geo "eu" — claiming "us" would put EU-resident data behind a US promise
    masterly_region = "us"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: a location the module cannot place is refused rather than waved through. Silently
# skipping the check would make the unknown case the UNSAFE one.
run "unknown_location_is_rejected_not_ignored" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    # In Azure, not in the EU: whether it satisfies an "eu" commitment is a legal question.
    location = "uksouth"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# ...and location_geo is the way to answer that question deliberately.
run "unknown_location_with_explicit_geo_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "uksouth"
    location_geo          = "eu"
    masterly_region       = "eu"
  }

  assert {
    condition     = local.install_geo == "eu"
    error_message = "location_geo must decide the install's geo for a location the map does not carry."
  }
}

# Guard: one install is one data plane in one location, so permitting a second geo would let
# someone create an Environment claiming a residency this install cannot honour. This was the
# old default (["eu", "us"]) — the leak shipped switched on.
run "cross_geo_allowed_regions_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    allowed_regions       = ["eu", "us"]
  }

  expect_failures = [azurerm_resource_group.aca]
}

# The safe configuration is the automatic one: unset means exactly this install's geo.
run "allowed_regions_defaults_to_the_install_geo" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(local.allowed_regions) == 1 && local.allowed_regions[0] == "eu"
    error_message = "Unset allowed_regions must resolve to the install's own geo, not a multi-geo default."
  }
}

# Azure accepts the display form; the check must not depend on which one is written.
run "display_form_location_resolves" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "Sweden Central"
  }

  assert {
    condition     = local.install_geo == "eu"
    error_message = "\"Sweden Central\" and \"swedencentral\" must resolve identically."
  }
}

# Guard: location_geo still rejects a value that is not a geo. Paired with the example's
# validate in CI, which is what caught the null case this condition originally had — `||`
# does not short-circuit in Terraform, so the unset default reached contains() and threw.
run "invalid_location_geo_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location_geo          = "emea"
  }

  expect_failures = [var.location_geo]
}
