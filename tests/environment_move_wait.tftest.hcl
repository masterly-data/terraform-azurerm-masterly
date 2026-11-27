# environment_move_wait: the wait between deleting a moved workload and creating it again.
# A move (workers_environment, migrate_job_environment, frontend_environment, edge_environment,
# api_environment) replaces ca-workers, caj-migrate, ca-frontend, ca-edge or ca-api under the same
# name, and Azure refuses the create while the old one is pending deletion (FailedIdentityOperation).
# time_sleep.environment_move (environment.tf) holds one destroy wait per workload that exists,
# triggered by the workload's environment id, and each workload lists it in depends_on.
#
# One of the per-concern plan files (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# The environments' ids are pinned with override_module, each to a value of its own, so a sleep
# keyed on the wrong environment compares unequal.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

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

# Default placement: nothing moves, so every sleep is keyed on aca-<prefix> and no app is replaced.
# Without workers, the migrate job or the edge, the install has no sleep for them.
run "default_placement_has_a_sleep_per_workload_on_aca_env" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition     = toset(keys(time_sleep.environment_move)) == toset(["api", "frontend"])
    error_message = "A default install has only ca-api and ca-frontend, so only their sleeps."
  }

  assert {
    condition = (
      time_sleep.environment_move["api"].triggers["environment_id"] == module.aca_env[0].id &&
      time_sleep.environment_move["frontend"].triggers["environment_id"] == module.aca_env[0].id &&
      module.api.environment_id == module.aca_env[0].id &&
      module.frontend.environment_id == module.aca_env[0].id
    )
    error_message = "By default the sleeps and the apps must stay on aca-<prefix>, so an upgrade replaces nothing."
  }

  # Threat: a wait on create slows every fresh install; a trigger beyond the environment id
  # replaces apps on an ordinary apply, or carries a secret into state.
  assert {
    condition = alltrue([
      for k, s in time_sleep.environment_move :
      s.destroy_duration == local.environment_move_wait && s.create_duration == null && join(",", keys(s.triggers)) == "environment_id"
    ])
    error_message = "Every environment_move sleep must have destroy_duration = local.environment_move_wait, no create_duration, and the environment id as its only trigger."
  }

  assert {
    condition     = local.environment_move_wait == "180s" && !issensitive(time_sleep.environment_move)
    error_message = "The move wait must be 180s, and a sleep must carry no sensitive value."
  }
}

# Step 2: ca-workers and caj-migrate move to the workers environment; the edge stays on aca-<prefix>.
# All five workloads exist, so all five sleeps do.
run "workers_and_migrate_moved_key_their_sleeps_on_the_workers_environment" {
  command = plan

  variables {
    workers_environment     = "workers"
    migrate_job_environment = "workers"
    migrations              = "job"
    enable_workers          = true
    enable_service_bus      = true
    servicebus_sku          = "Standard"
    edge                    = {}
    mode                    = "production"
    identity_binding        = "oidc"
    oidc_allowed_issuers    = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience           = "api-client-id"
    oidc_jwks_uri           = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id          = "bff-client-id"
    oidc_client_secret      = "s3cret"
    oidc_authority          = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri       = "https://app.example.com/api/auth/callback"
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    initial_owner_email     = "owner@example.com"
    enable_key_vault        = true
    enable_redis            = true
    redis_offering          = "cache"
    api_max_replicas        = 3
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition     = toset(keys(time_sleep.environment_move)) == toset(["api", "frontend", "edge", "workers", "migrate"])
    error_message = "With workers, the migrate job and the edge, all five workloads must have a sleep."
  }

  assert {
    condition = (
      time_sleep.environment_move["workers"].triggers["environment_id"] == module.environments["workers"].id &&
      time_sleep.environment_move["migrate"].triggers["environment_id"] == module.environments["workers"].id &&
      module.workers[0].environment_id == module.environments["workers"].id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.environments["workers"].id
    )
    error_message = "The ca-workers and caj-migrate sleeps must be keyed on the workers environment's id, the one the workloads plan."
  }

  assert {
    condition = (
      time_sleep.environment_move["api"].triggers["environment_id"] == module.aca_env[0].id &&
      time_sleep.environment_move["frontend"].triggers["environment_id"] == module.aca_env[0].id &&
      time_sleep.environment_move["edge"].triggers["environment_id"] == module.aca_env[0].id
    )
    error_message = "Moving the workers must leave the api, frontend and edge sleeps on aca-<prefix>."
  }

  assert {
    condition = alltrue([
      for k, s in time_sleep.environment_move :
      s.destroy_duration == local.environment_move_wait && s.create_duration == null && join(",", keys(s.triggers)) == "environment_id"
    ])
    error_message = "Every environment_move sleep must have destroy_duration = local.environment_move_wait, no create_duration, and the environment id as its only trigger."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

# Step 3: ca-frontend and ca-edge move to the front environment and ca-api to the app environment.
# No workers and no migrate job here, so no sleep for them.
run "front_and_app_moved_key_their_sleeps_on_front_and_app" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
    enable_workers        = false
  }

  override_module {
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      time_sleep.environment_move["frontend"].triggers["environment_id"] == module.environments["front"].id &&
      time_sleep.environment_move["edge"].triggers["environment_id"] == module.environments["front"].id &&
      time_sleep.environment_move["api"].triggers["environment_id"] == module.environments["app"].id &&
      module.frontend.environment_id == module.environments["front"].id &&
      azurerm_container_app.edge[0].container_app_environment_id == module.environments["front"].id &&
      module.api.environment_id == module.environments["app"].id
    )
    error_message = "The frontend and edge sleeps must be keyed on the front environment's id and the api's on the app environment's."
  }

  assert {
    condition     = toset(keys(time_sleep.environment_move)) == toset(["api", "frontend", "edge"])
    error_message = "Without workers or the migrate job, there must be no sleep for ca-workers or caj-migrate."
  }

  assert {
    condition = alltrue([
      for k, s in time_sleep.environment_move :
      s.destroy_duration == local.environment_move_wait && s.create_duration == null && join(",", keys(s.triggers)) == "environment_id"
    ])
    error_message = "Every environment_move sleep must have destroy_duration = local.environment_move_wait, no create_duration, and the environment id as its only trigger."
  }
}

# Every workload lists its sleep as its last depends_on entry, so the wait falls between its destroy
# and its create: destroy the workload, destroy the sleep (it waits), create the sleep, create the
# workload.
run "every_movable_workload_depends_on_its_sleep" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  assert {
    condition = alltrue([
      can(regex("time_sleep\\.environment_move\\[\"workers\"\\],\n  \\]", file("${path.module}/workers.tf"))),
      can(regex("time_sleep\\.environment_move\\[\"migrate\"\\],\n  \\]", file("${path.module}/migrate.tf"))),
      can(regex("time_sleep\\.environment_move\\[\"edge\"\\],\n  \\]", file("${path.module}/edge.tf"))),
      can(regex("time_sleep\\.environment_move\\[\"api\"\\],\n  \\]", file("${path.module}/main.tf"))),
      can(regex("time_sleep\\.environment_move\\[\"frontend\"\\],\n  \\]", file("${path.module}/main.tf"))),
    ])
    error_message = "module.workers, caj-migrate, ca-edge, module.api and module.frontend must each list their time_sleep.environment_move key in depends_on."
  }
}
