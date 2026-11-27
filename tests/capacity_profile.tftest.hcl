# Capacity profiles (ADR 0120 §4): capacity_profile sizes the Postgres server, its built-in
# pooler and HA, and the apps' minimum replicas, and never chooses a Service Bus tier.
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
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.138.0"
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

  # A production plan needs builtin_auth or a recorded opt-out (builtin_auth_opt_out's
  # validation), so every run states the opt-out, which has no effect in demo. In production every
  # plan warns, quoting its reason, so each production run expects
  # check.builtin_auth_opted_out_in_production, and a production refusal run sets builtin_auth
  # instead. The runs about the sign-in gate are in the builtin_auth files and
  # security_profile.tftest.hcl.
  builtin_auth_opt_out = { reason = "Test install: the platform sign-in gate is not under test in this file." }
}

# --- The value itself ----------------------------------------------------------------------

run "capacity_profile_refuses_an_unknown_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    capacity_profile      = "large"
  }

  expect_failures = [var.capacity_profile]
}

# An unset TF_VAR_ or a rendered template gives "", which must not read as unset.
run "capacity_profile_refuses_an_empty_string" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    capacity_profile      = ""
  }

  expect_failures = [var.capacity_profile]
}

# small is for evaluation only. The SKU and HA set explicitly satisfy their own production
# guards, so the refusal is the profile's alone.
run "production_refuses_small_even_with_explicit_sku_and_ha" {
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

    capacity_profile               = "small"
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.capacity_profile]
}

# --- Each profile's sizes ------------------------------------------------------------------
#
# Evaluation mode, the starter server and ca-workers. A profile does not raise a maximum, so the
# runs set api_max_replicas (with Redis, which a maximum above 1 needs) to at least the profile's
# api floor, and workers_max_replicas to exactly the workers floor: on the polling binding
# ca-workers stays at its minimum, and a higher maximum only draws the check's warning.
#
# The same runs pin what would REPLACE the server if a profile reached it: the name, the version,
# the administrator login, the zone and geo-redundant backup. Each is the same literal in all three
# profile runs and the unset run below.

# The server's name carries the install's random suffix, which a mock plan leaves unknown
# (`override_during = plan` needs Terraform 1.11 while CI runs 1.10). This run applies the suffix
# alone, so every later run in this file plans against it in state and the name is known.
run "install_suffix_applied" {
  command = apply

  plan_options {
    target = [random_string.install]
  }

  override_resource {
    target = random_string.install
    values = { result = "abc123" }
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = random_string.install.result == "abc123"
    error_message = "The install suffix must be applied for the later runs to plan a known server name."
  }
}

run "profile_small_sizes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    capacity_profile      = "small"
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "B_Standard_B1ms" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0
    )
    error_message = "small must plan B_Standard_B1ms with no HA and no pgbouncer parameters."
  }

  assert {
    condition = (
      module.api.scale.min_replicas == 1 &&
      module.frontend.scale.min_replicas == 1 &&
      module.workers[0].scale.min_replicas == 1
    )
    error_message = "small must plan minimum replicas api/frontend/workers 1/1/1."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].name == "psql-masterly-abc123" &&
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      azurerm_postgresql_flexible_server.this[0].zone == null &&
      azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    )
    error_message = "A profile must not change the server's name, version, administrator login, zone or geo-redundant backup: each would replace the server."
  }
}

run "profile_standard_sizes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    capacity_profile      = "standard"
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "GP_Standard_D2ds_v5" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 3 &&
      azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.enabled"].value == "true"
    )
    error_message = "standard must plan GP_Standard_D2ds_v5 and the pgbouncer parameters, with no zone-redundant HA: no profile turns it on."
  }

  assert {
    condition     = local.database_pooler_port == "6432" && contains(local.private_endpoint_ports, "6432")
    error_message = "standard's pooler must move database-url to 6432 and admit 6432 on the endpoints subnet."
  }

  assert {
    condition = (
      module.api.scale.min_replicas == 2 &&
      module.frontend.scale.min_replicas == 1 &&
      module.workers[0].scale.min_replicas == 1
    )
    error_message = "standard must plan minimum replicas api/frontend/workers 2/1/1."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].name == "psql-masterly-abc123" &&
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      azurerm_postgresql_flexible_server.this[0].zone == null &&
      azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    )
    error_message = "A profile must not change the server's name, version, administrator login, zone or geo-redundant backup: each would replace the server."
  }
}

run "profile_enterprise_sizes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    workers_max_replicas  = 2
    capacity_profile      = "enterprise"
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "GP_Standard_D4ds_v5" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 3 &&
      azurerm_postgresql_flexible_server_configuration.pgbouncer["pgbouncer.enabled"].value == "true"
    )
    error_message = "enterprise must plan GP_Standard_D4ds_v5 and the pgbouncer parameters, with no zone-redundant HA: no profile turns it on."
  }

  assert {
    condition = (
      module.api.scale.min_replicas == 2 &&
      module.frontend.scale.min_replicas == 2 &&
      module.workers[0].scale.min_replicas == 2
    )
    error_message = "enterprise must plan minimum replicas api/frontend/workers 2/2/2."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].name == "psql-masterly-abc123" &&
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      azurerm_postgresql_flexible_server.this[0].zone == null &&
      azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    )
    error_message = "A profile must not change the server's name, version, administrator login, zone or geo-redundant backup: each would replace the server."
  }
}

# An existing install that sets no profile plans what it planned before profiles existed.
run "unset_profile_plans_the_earlier_defaults" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    enable_service_bus    = true
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "B_Standard_B1ms" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0 &&
      local.database_pooler_port == "5432" &&
      !contains(local.private_endpoint_ports, "6432")
    )
    error_message = "With capacity_profile unset the server must stay B_Standard_B1ms, with no HA, no pgbouncer parameters and database-url on 5432."
  }

  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Standard"
    error_message = "With capacity_profile and servicebus_sku unset the namespace must stay Standard."
  }

  assert {
    condition = (
      module.api.scale.min_replicas == 1 &&
      module.frontend.scale.min_replicas == 1 &&
      module.workers[0].scale.min_replicas == 1
    )
    error_message = "With capacity_profile unset the minimum replicas must stay 1/1/1."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].name == "psql-masterly-abc123" &&
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].administrator_login == "masterly_admin" &&
      azurerm_postgresql_flexible_server.this[0].zone == null &&
      azurerm_postgresql_flexible_server.this[0].geo_redundant_backup_enabled == false
    )
    error_message = "The unset profile must plan the same server name, version, administrator login, zone and geo-redundant backup as every profile."
  }
}

# --- Service Bus: no profile moves a namespace across Premium --------------------------------

run "profile_small_keeps_service_bus_standard" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    capacity_profile      = "small"
  }

  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Standard"
    error_message = "small with servicebus_sku unset must plan a Standard namespace."
  }
}

run "profile_standard_keeps_service_bus_standard" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_service_bus    = true
    capacity_profile      = "standard"
  }

  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Standard"
    error_message = "standard with servicebus_sku unset must plan a Standard namespace."
  }
}

# Enterprise is sized for Premium, but choosing it could replace an existing Standard
# namespace, so the profile asks for the tier.
run "profile_enterprise_refuses_service_bus_without_a_tier" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_service_bus    = true
    capacity_profile      = "enterprise"
  }

  expect_failures = [var.servicebus_sku]
}

run "profile_enterprise_with_premium_plans_premium" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_service_bus    = true
    servicebus_sku        = "Premium"
    capacity_profile      = "enterprise"
  }

  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Premium"
    error_message = "enterprise with servicebus_sku = \"Premium\" must plan a Premium namespace."
  }
}

# --- An input set explicitly wins over the profile, one run per input ------------------------

run "explicit_postgres_sku_name_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    capacity_profile      = "enterprise"
    postgres_sku_name     = "GP_Standard_D8ds_v5"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].sku_name == "GP_Standard_D8ds_v5"
    error_message = "postgres_sku_name set explicitly must win over enterprise's GP_Standard_D4ds_v5."
  }
}

run "explicit_postgres_pgbouncer_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    capacity_profile      = "enterprise"
    postgres_pgbouncer    = false
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0 &&
      local.database_pooler_port == "5432" &&
      !contains(local.backend_secret_names, "database-direct-url")
    )
    error_message = "postgres_pgbouncer = false must win over enterprise's pooler: no pgbouncer parameters, database-url on 5432, no direct-url secret."
  }
}

# No profile turns HA on (ADR 0120, 2026-11-20 amendment); postgres_zone_redundant_ha = true does,
# under any profile with a non-burstable SKU.
run "explicit_postgres_zone_redundant_ha_turns_ha_on_under_a_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_redis               = true
    redis_offering             = "cache"
    api_max_replicas           = 2
    capacity_profile           = "enterprise"
    postgres_zone_redundant_ha = true
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 1 &&
      azurerm_postgresql_flexible_server.this[0].high_availability[0].mode == "ZoneRedundant"
    )
    error_message = "postgres_zone_redundant_ha = true under enterprise must plan a ZoneRedundant standby."
  }
}

run "explicit_servicebus_sku_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_service_bus    = true
    servicebus_sku        = "Standard"
    capacity_profile      = "enterprise"
  }

  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Standard"
    error_message = "servicebus_sku = \"Standard\" must win over the Premium tier enterprise is sized for."
  }
}

# With the api floor set back to 1, enterprise needs no api maximum above 1, and so no Redis.
run "explicit_api_min_replicas_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    capacity_profile      = "enterprise"
    api_min_replicas      = 1
  }

  assert {
    condition     = module.api.scale.min_replicas == 1
    error_message = "api_min_replicas set explicitly must win over enterprise's 2."
  }
}

run "explicit_frontend_min_replicas_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    capacity_profile      = "enterprise"
    frontend_min_replicas = 1
  }

  assert {
    condition     = module.frontend.scale.min_replicas == 1
    error_message = "frontend_min_replicas set explicitly must win over enterprise's 2."
  }
}

run "explicit_workers_min_replicas_wins_over_the_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_workers        = true
    capacity_profile      = "enterprise"
    workers_min_replicas  = 1
  }

  assert {
    condition     = module.workers[0].scale.min_replicas == 1
    error_message = "workers_min_replicas set explicitly must win over enterprise's 2."
  }
}

# --- Every guard judges the resolved value ---------------------------------------------------

# Production with the SKU unset and no profile resolves the burstable B_Standard_B1ms.
run "production_refuses_a_resolved_burstable_sku" {
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

    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.postgres_sku_name]
}

# Production does not require zone-redundant HA (ADR 0120, 2026-11-20 amendment): HA unset and
# no profile plans the starter server with no standby.
run "production_plans_with_ha_unset" {
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

    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
    migrations                     = "job"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0
    error_message = "Production no longer requires zone-redundant HA: with HA unset and no profile, the starter server must plan with no standby."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

# standard satisfies the Postgres production guards with nothing else set, so the three runs
# after this one each fail on their replica floor alone.
run "production_standard_plans_with_the_sku_and_ha_unset" {
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

    capacity_profile               = "standard"
    postgres_backup_retention_days = 14
    migrations                     = "job"
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "GP_Standard_D2ds_v5" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      module.api.scale.min_replicas == 2
    )
    error_message = "standard in production must plan GP_Standard_D2ds_v5 with no HA (off by default) and an api floor of 2."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

# The enterprise profile's recovery objectives assume the standby, so production on enterprise
# without it warns (a check, not a refusal) and plans; with HA on, it plans with no warning.
run "production_enterprise_without_ha_warns" {
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
    workers_max_replicas  = 2

    capacity_profile               = "enterprise"
    postgres_backup_retention_days = 14
    migrations                     = "job"
  }

  expect_failures = [check.enterprise_production_without_postgres_ha, check.builtin_auth_opted_out_in_production]

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0
    error_message = "enterprise in production without HA must still plan, with no standby."
  }
}

run "production_enterprise_with_ha_does_not_warn" {
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
    workers_max_replicas  = 2

    capacity_profile               = "enterprise"
    postgres_backup_retention_days = 14
    postgres_zone_redundant_ha     = true
    migrations                     = "job"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].high_availability[0].mode == "ZoneRedundant"
    error_message = "enterprise in production with postgres_zone_redundant_ha = true must plan a ZoneRedundant standby."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

run "production_refuses_an_api_floor_of_zero_under_a_profile" {
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

    capacity_profile               = "standard"
    postgres_backup_retention_days = 14
    api_min_replicas               = 0
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.api_min_replicas]
}

run "production_refuses_a_frontend_floor_of_zero_under_a_profile" {
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

    capacity_profile               = "standard"
    postgres_backup_retention_days = 14
    frontend_min_replicas          = 0
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.frontend_min_replicas]
}

run "production_refuses_a_workers_floor_of_zero_under_a_profile" {
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

    capacity_profile               = "standard"
    postgres_backup_retention_days = 14
    workers_min_replicas           = 0
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.workers_min_replicas]
}

# standard turns the pooler on; a burstable SKU set explicitly cannot carry it.
run "profile_pooler_refused_on_an_explicit_burstable_sku" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_redis               = true
    redis_offering             = "cache"
    api_max_replicas           = 2
    capacity_profile           = "standard"
    postgres_sku_name          = "B_Standard_B2s"
    postgres_zone_redundant_ha = false
  }

  expect_failures = [var.postgres_pgbouncer]
}

# HA set on over a burstable SKU set explicitly under standard is refused, in evaluation mode too.
# The pooler is set off so only the HA guard is left to refuse it.
run "profile_ha_refused_on_an_explicit_burstable_sku" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_redis               = true
    redis_offering             = "cache"
    api_max_replicas           = 2
    capacity_profile           = "standard"
    postgres_sku_name          = "B_Standard_B2s"
    postgres_pgbouncer         = false
    postgres_zone_redundant_ha = true
  }

  expect_failures = [var.postgres_zone_redundant_ha]
}

# With the pooler and HA both set off, a burstable SKU under standard plans.
run "profile_burstable_sku_plans_with_pooler_and_ha_off" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_redis               = true
    redis_offering             = "cache"
    api_max_replicas           = 2
    capacity_profile           = "standard"
    postgres_sku_name          = "B_Standard_B2s"
    postgres_pgbouncer         = false
    postgres_zone_redundant_ha = false
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].sku_name == "B_Standard_B2s" &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0
    )
    error_message = "A burstable SKU under standard with the pooler and HA set off must plan the SKU with no HA and no pgbouncer parameters."
  }
}

# The same guard holds without a profile: HA set on over the burstable default.
run "explicit_ha_refused_on_the_burstable_default" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    postgres_zone_redundant_ha = true
  }

  expect_failures = [var.postgres_zone_redundant_ha]
}

# The pooler standard turns on owns the pgbouncer.* keys, as postgres_pgbouncer = true does.
run "profile_pooler_refused_with_an_operator_pgbouncer_key" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    enable_redis               = true
    redis_offering             = "cache"
    api_max_replicas           = 2
    capacity_profile           = "standard"
    postgres_server_parameters = { "pgbouncer.pool_mode" = "SESSION" }
  }

  expect_failures = [var.postgres_pgbouncer]
}

# An explicit value overrides the profile into a refusal: standard with a burstable SKU set
# explicitly (and the pooler set off, so only the production SKU guard is left to refuse it).
run "production_refuses_an_explicit_burstable_sku_under_standard" {
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

    capacity_profile               = "standard"
    postgres_sku_name              = "B_Standard_B2s"
    postgres_pgbouncer             = false
    postgres_backup_retention_days = 14
    migrations                     = "job"

    # A refusal under test, not the sign-in gate: builtin_auth meets production's gate rule
    # without the opt-out's warning.
    builtin_auth_opt_out = null
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.postgres_sku_name]
}

run "production_plans_explicit_ha_off_under_standard" {
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

    capacity_profile               = "standard"
    postgres_zone_redundant_ha     = false
    postgres_backup_retention_days = 14
    migrations                     = "job"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0
    error_message = "postgres_zone_redundant_ha = false under standard in production must plan with no standby."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

# A profile does not raise a maximum: standard's api floor of 2 over the default maximum of 1.
run "profile_api_floor_above_the_maximum_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    capacity_profile      = "standard"
  }

  expect_failures = [var.api_min_replicas]
}

run "profile_frontend_floor_above_the_maximum_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    capacity_profile      = "enterprise"
    frontend_max_replicas = 1
  }

  expect_failures = [var.frontend_max_replicas]
}

run "profile_workers_floor_above_the_maximum_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_workers        = true
    capacity_profile      = "enterprise"
  }

  expect_failures = [var.workers_max_replicas]
}

# --- BYO database: the profile's Postgres values do not apply --------------------------------

run "byo_db_standard_plans_no_pooler" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_workers        = true
    capacity_profile      = "standard"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server.this) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0 &&
      !local.postgres_pgbouncer &&
      !contains(local.private_endpoint_ports, "6432")
    )
    error_message = "With external_database_url, standard must plan no server and no pgbouncer parameters."
  }

  assert {
    condition = (
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      nonsensitive(strcontains(local.database_url, "pg.example.com:5432/")) &&
      !contains(keys(local.api_env), "MASTERLY_DATABASE_POOLER") &&
      !contains(keys(local.api_env_secret_refs), "MASTERLY_DATABASE_DIRECT_URL") &&
      !contains(local.api_secret_names, "database-direct-url") &&
      !contains(local.backend_secret_names, "database-direct-url")
    )
    error_message = "With external_database_url, MASTERLY_DATABASE_URL must stay the customer's DSN on 5432, with no pooler env and no database-direct-url secret."
  }

  # The profile still sizes what is not Postgres.
  assert {
    condition     = module.api.scale.min_replicas == 2
    error_message = "With external_database_url, standard must still set the api floor of 2."
  }
}

run "byo_db_enterprise_plans_no_pooler" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_workers        = true
    workers_max_replicas  = 2
    capacity_profile      = "enterprise"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server.this) == 0 &&
      length(azurerm_postgresql_flexible_server_configuration.pgbouncer) == 0 &&
      !local.postgres_pgbouncer &&
      local.api_env_secret_refs["MASTERLY_DATABASE_URL"] == "database-url" &&
      nonsensitive(strcontains(local.database_url, "pg.example.com:5432/")) &&
      !contains(keys(local.api_env), "MASTERLY_DATABASE_POOLER") &&
      !contains(local.api_secret_names, "database-direct-url") &&
      !contains(local.backend_secret_names, "database-direct-url")
    )
    error_message = "With external_database_url, enterprise must plan no server, no pooler wiring and no database-direct-url secret."
  }
}

# --- Diagnostics follow the resolved SKU -----------------------------------------------------

# GP_Standard_D4ds_v5 has 16 GiB, whose default max_connections is 1718.
run "profile_enterprise_connections_alert_measures_against_its_sku" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_diagnostics    = true
    capacity_profile      = "enterprise"
  }

  assert {
    condition = (
      local.postgres_sku_memory_gib == 16 &&
      local.postgres_max_connections == 1718 &&
      length(azurerm_monitor_metric_alert.postgres_connections) == 1 &&
      azurerm_monitor_metric_alert.postgres_connections[0].criteria[0].threshold == floor(1718 * var.alert_postgres_connections_percent / 100)
    )
    error_message = "With enterprise and no max_connections set, the connections alert must measure against 1718 (16 GiB)."
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.postgres_cpu_credits) == 0
    error_message = "enterprise's General Purpose SKU must plan no CPU-credit alert."
  }
}

run "profile_standard_turns_the_burstable_diagnostics_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    api_max_replicas      = 2
    enable_diagnostics    = true
    capacity_profile      = "standard"
  }

  assert {
    condition     = !local.postgres_burstable && length(azurerm_monitor_metric_alert.postgres_cpu_credits) == 0
    error_message = "standard's General Purpose SKU must turn the burstable-only diagnostics off."
  }
}
