# Sizing and scaling: app_resources, replicas, the workers' scale rule.
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

# --- Sizing and scaling: app_resources, frontend_max_replicas, the workers' scale rule and
# --- termination grace period (MAS-1296) ---------------------------------------------------

# An existing install that sets none of the new inputs plans the size and replica bounds every
# app had before they existed: 0.5 vCPU / 1Gi, api 1-1, frontend 1-3, workers 1-1, and no scale
# rule on the polling binding. The workers' grace period is the one deliberate change.
run "unchanged_install_plans_no_compute_change" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
  }

  assert {
    condition = alltrue([
      for app in [module.api, module.frontend, module.workers[0]] : app.cpu == 0.5 && app.memory == "1Gi"
    ])
    error_message = "With app_resources unset every app must keep 0.5 vCPU / 1Gi."
  }

  assert {
    condition = (
      module.api.scale.min_replicas == 1 && module.api.scale.max_replicas == 1 &&
      module.frontend.scale.min_replicas == 1 && module.frontend.scale.max_replicas == 3 &&
      module.workers[0].scale.min_replicas == 1 && module.workers[0].scale.max_replicas == 1
    )
    error_message = "With the new inputs unset every app must keep its replica bounds (api 1-1, frontend 1-3, workers 1-1)."
  }

  assert {
    condition = (
      module.api.scale.termination_grace_period_seconds == null &&
      module.frontend.scale.termination_grace_period_seconds == null &&
      length(module.api.scale.custom_scale_rules) == 0 &&
      length(module.frontend.scale.custom_scale_rules) == 0 &&
      length(module.workers[0].scale.custom_scale_rules) == 0
    )
    error_message = "The api and frontend must keep Azure's default grace period, and no app may get a scale rule on the polling binding."
  }

  assert {
    condition     = module.workers[0].scale.termination_grace_period_seconds == 600 && length(azurerm_role_assignment.sb_scaler) == 0
    error_message = "ca-workers must default to a 600-second grace period, and the polling binding must plan no queue grant."
  }

  # The workers memory alert follows the configured size: 85% of 1Gi.
  assert {
    condition     = local.workers_memory_bytes == 1073741824
    error_message = "The workers memory alert's base must be the workers' configured memory."
  }
}

# The production example's sizing: the api at 1 vCPU / 2Gi, the other two apps unchanged. This
# is the shape examples/production sets on a production Premium Service Bus install.
run "production_example_runs_the_api_at_one_vcpu" {
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
    redis_offering        = "managed"
    enable_workers        = true
    enable_service_bus    = true
    servicebus_sku        = "Premium"
    api_min_replicas      = 2
    api_max_replicas      = 3
    frontend_min_replicas = 1
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"

    app_resources = {
      api = { cpu = 1, memory = "2Gi" }
    }
  }

  assert {
    condition     = module.api.cpu == 1 && module.api.memory == "2Gi"
    error_message = "The production example must plan the api at 1 vCPU / 2Gi."
  }

  assert {
    condition = (
      module.frontend.cpu == 0.5 && module.frontend.memory == "1Gi" &&
      module.workers[0].cpu == 0.5 && module.workers[0].memory == "1Gi"
    )
    error_message = "Apps not listed in app_resources must keep 0.5 vCPU / 1Gi."
  }
}

# Either half of a size determines the other, at Container Apps' 1 vCPU : 2 GiB.
run "app_resources_derives_the_missing_half" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    app_resources = {
      api      = { cpu = 1 }
      workers  = { memory = "3Gi" }
      frontend = { cpu = 0.25, memory = "0.5Gi" }
    }
  }

  assert {
    condition = (
      module.api.cpu == 1 && module.api.memory == "2Gi" &&
      module.workers[0].cpu == 1.5 && module.workers[0].memory == "3Gi" &&
      module.frontend.cpu == 0.25 && module.frontend.memory == "0.5Gi"
    )
    error_message = "app_resources must reach each app, deriving an unset half at 1 vCPU : 2 GiB."
  }

  # The workers memory alert takes its threshold as a share of the workers' size.
  assert {
    condition     = local.workers_memory_bytes == 3 * 1073741824
    error_message = "The workers memory alert must follow the workers' configured memory."
  }
}

# app_resources has four validations, and expect_failures cannot say which one refused a run. So
# each refusal below is an input that fails exactly one of them and passes the other three: the
# unit, the offered sizes and the ratio skip an attribute that is unset or malformed (try()), so a
# run that sets one attribute cannot trip the ratio, and a run whose two values are each offered
# can trip only the ratio.

# Ratio only: 1 vCPU and 1Gi are each offered, but not together.
run "app_resources_refuses_a_pair_out_of_ratio" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { api = { cpu = 1, memory = "1Gi" } }
  }

  expect_failures = [var.app_resources]
}

# Ratio only, at the ends of the range: 0.25 vCPU and 4Gi are each offered.
run "app_resources_refuses_the_smallest_cpu_with_the_largest_memory" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { workers = { cpu = 0.25, memory = "4Gi" } }
  }

  expect_failures = [var.app_resources]
}

# Offered sizes only: above the range, memory unset.
run "app_resources_refuses_a_size_container_apps_does_not_offer" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { workers = { cpu = 4 } }
  }

  expect_failures = [var.app_resources]
}

# Offered sizes only: inside the range but between two steps, memory unset.
run "app_resources_refuses_a_cpu_between_steps" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { api = { cpu = 0.3 } }
  }

  expect_failures = [var.app_resources]
}

# Offered sizes only: a well-formed memory above the range, cpu unset.
run "app_resources_refuses_memory_container_apps_does_not_offer" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { frontend = { memory = "5Gi" } }
  }

  expect_failures = [var.app_resources]
}

# Unit only: "2048Mi" does not parse as Gi, so the offered-size and ratio checks skip it.
run "app_resources_refuses_memory_in_another_unit" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { api = { memory = "2048Mi" } }
  }

  expect_failures = [var.app_resources]
}

# Keys only: the size is valid.
run "app_resources_refuses_an_unknown_app" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    app_resources         = { worker = { cpu = 1 } }
  }

  expect_failures = [var.app_resources]
}

run "frontend_max_replicas_reaches_the_frontend" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_min_replicas = 2
    frontend_max_replicas = 5
  }

  assert {
    condition     = module.frontend.scale.min_replicas == 2 && module.frontend.scale.max_replicas == 5
    error_message = "frontend_max_replicas must reach the frontend."
  }
}

run "frontend_max_below_min_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_min_replicas = 2
    frontend_max_replicas = 1
  }

  expect_failures = [var.frontend_max_replicas]
}

run "frontend_max_of_zero_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_min_replicas = 0
    frontend_max_replicas = 0
  }

  expect_failures = [var.frontend_max_replicas]
}

run "workers_max_below_min_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    workers_min_replicas  = 2
    workers_max_replicas  = 1
  }

  expect_failures = [var.workers_max_replicas]
}

run "workers_grace_period_is_an_input" {
  command = plan

  variables {
    ingress_allowed_cidrs                    = ["203.0.113.7/32"]
    enable_workers                           = true
    workers_termination_grace_period_seconds = 120
  }

  assert {
    condition     = module.workers[0].scale.termination_grace_period_seconds == 120
    error_message = "workers_termination_grace_period_seconds must reach ca-workers."
  }
}

run "workers_grace_period_above_azure_maximum_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs                    = ["203.0.113.7/32"]
    enable_workers                           = true
    workers_termination_grace_period_seconds = 601
  }

  expect_failures = [var.workers_termination_grace_period_seconds]
}

run "workers_grace_period_below_zero_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs                    = ["203.0.113.7/32"]
    enable_workers                           = true
    workers_termination_grace_period_seconds = -1
  }

  expect_failures = [var.workers_termination_grace_period_seconds]
}

run "workers_grace_period_in_fractions_of_a_second_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs                    = ["203.0.113.7/32"]
    enable_workers                           = true
    workers_termination_grace_period_seconds = 30.5
  }

  expect_failures = [var.workers_termination_grace_period_seconds]
}

# 0, the bottom of Container Apps' range, is accepted: a worker is stopped at once.
run "workers_grace_period_of_zero_is_accepted" {
  command = plan

  variables {
    ingress_allowed_cidrs                    = ["203.0.113.7/32"]
    enable_workers                           = true
    workers_termination_grace_period_seconds = 0
  }

  assert {
    condition     = module.workers[0].scale.termination_grace_period_seconds == 0
    error_message = "A grace period of 0 must plan and reach ca-workers."
  }
}

# On the polling binding there is no queue length to scale on: max above min plans, with no
# scale rule, and the check says the workers will stay at their minimum.
run "polling_binding_workers_above_min_are_warned" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    workers_max_replicas  = 3
  }

  assert {
    condition     = length(module.workers[0].scale.custom_scale_rules) == 0 && length(azurerm_role_assignment.sb_scaler) == 0
    error_message = "The polling binding must plan no scale rule and no queue grant."
  }

  expect_failures = [check.workers_scale_on_the_polling_binding]
}

# Service Bus without the workers app: the api runs the loop in-process and scales on HTTP, so
# there is no workers app to scale and no reason for the Manage grant.
run "service_bus_without_workers_plans_no_scaler_grant" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
  }

  assert {
    condition     = length(azurerm_role_assignment.sb_scaler) == 0 && length(module.api.scale.custom_scale_rules) == 0
    error_message = "Without enable_workers there is no queue scale rule and no Data Owner grant."
  }
}

# Postgres storage autogrow and storage performance tier. Neither applies to BYO-DB. A mock
# provider plan cannot show whether azurerm updates them in place; that rests on the provider
# schema (see the pull request description).
run "postgres_auto_grow_off_by_default_in_evaluation" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == false
    error_message = "Unset, an evaluation install must leave storage autogrow off."
  }

  assert {
    condition     = var.postgres_storage_tier == null
    error_message = "Unset, postgres_storage_tier must stay null so Azure's default tier is kept."
  }
}

run "postgres_auto_grow_on_by_default_in_production" {
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
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == true
    error_message = "Unset, a production install with the starter server must turn storage autogrow on."
  }
}

run "postgres_auto_grow_false_wins_in_production" {
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
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    postgres_auto_grow             = false
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == false
    error_message = "postgres_auto_grow = false must win over the production default."
  }
}

run "postgres_auto_grow_true_wins_in_evaluation" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_auto_grow    = true
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].auto_grow_enabled == true
    error_message = "postgres_auto_grow = true must win over the evaluation default."
  }
}

run "postgres_storage_tier_is_passed_through" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_storage_tier = "P30"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].storage_tier == "P30"
    error_message = "postgres_storage_tier must reach the server's storage_tier."
  }
}

run "postgres_storage_tier_below_p4_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_storage_tier = "P5"
  }

  expect_failures = [var.postgres_storage_tier]
}

run "postgres_storage_tier_above_p80_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_storage_tier = "P90"
  }

  expect_failures = [var.postgres_storage_tier]
}

run "byo_db_ignores_postgres_storage_inputs" {
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
    postgres_auto_grow    = true
    postgres_storage_tier = "P30"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 0
    error_message = "external_database_url must still suppress the starter server when the storage inputs are set."
  }
}

# Azure has grown an existing server's disk past postgres_storage_mb. The plan must carry the
# real size, never the smaller configured one: a shrink would replace the server and destroy
# its databases.
run "postgres_storage_never_planned_below_grown_size" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_storage_mb   = 32768
  }

  override_data {
    target = data.azurerm_resources.postgres_storage
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = {}
      }]
    }
  }

  override_data {
    target = data.azurerm_postgresql_flexible_server.existing
    values = {
      storage_mb = 131072
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].storage_mb == 131072
    error_message = "A server Azure has grown to 131072 MB must not be planned at the configured 32768 MB."
  }
}

# ...and raising postgres_storage_mb above the real size still grows the disk.
run "postgres_storage_mb_above_grown_size_still_grows" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    postgres_storage_mb   = 262144
  }

  override_data {
    target = data.azurerm_resources.postgres_storage
    values = {
      resources = [{
        id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-abc123"
        name                = "psql-masterly-abc123"
        resource_group_name = "rg-masterly-data"
        type                = "Microsoft.DBforPostgreSQL/flexibleServers"
        location            = "swedencentral"
        tags                = {}
      }]
    }
  }

  override_data {
    target = data.azurerm_postgresql_flexible_server.existing
    values = {
      storage_mb = 131072
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].storage_mb == 262144
    error_message = "postgres_storage_mb above the server's real size must still grow the disk."
  }
}
