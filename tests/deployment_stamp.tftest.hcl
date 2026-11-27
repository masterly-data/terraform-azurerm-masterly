# The deployment stamp (ADR 0120 §8) and the release_ring input it reports (ADR 0107 §1).
#
# Branch coverage for the module's variable guards and derived values (mock providers, no cloud
# access; runs in CI via `terraform test`). One of the per-concern plan files (MAS-4478): add a
# run to the file of the concern it asserts on.
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

# --- release_ring ----------------------------------------------------------------------------

run "release_ring_refuses_an_empty_string" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = ""
  }

  expect_failures = [var.release_ring]
}

# The rings are lowercase, as ADR 0107 and the licence claim spell them.
run "release_ring_refuses_a_capitalised_ring" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = "Stable"
  }

  expect_failures = [var.release_ring]
}

# "previous" is a release_channel, not a ring: the two inputs must not be confused.
run "release_ring_refuses_a_release_channel" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = "previous"
  }

  expect_failures = [var.release_ring]
}

run "release_ring_canary_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = "canary"
  }

  assert {
    condition     = output.deployment_stamp.release_ring == "canary"
    error_message = "release_ring = \"canary\" must plan and be reported in the stamp."
  }
}

run "release_ring_beta_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = "beta"
  }

  assert {
    condition     = output.deployment_stamp.release_ring == "beta"
    error_message = "release_ring = \"beta\" must plan and be reported in the stamp."
  }
}

run "release_ring_stable_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_ring          = "stable"
  }

  assert {
    condition     = output.deployment_stamp.release_ring == "stable"
    error_message = "release_ring = \"stable\" must plan and be reported in the stamp."
  }
}

# The ring is declared for the stamp only; it must not move the images release_channel chooses.
run "release_ring_changes_no_image" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = null
    frontend_image        = null
    release_ring          = "canary"
  }

  assert {
    condition = (
      output.image_references.release_channel == "stable" &&
      output.image_references.release_version == jsondecode(file("${path.module}/MANIFEST.json")).latest
    )
    error_message = "release_ring must not change which images release_channel resolves to."
  }
}

# --- The stamp -------------------------------------------------------------------------------

run "deployment_stamp_defaults" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = output.deployment_stamp.module_version == jsondecode(file("${path.module}/MANIFEST.json")).latest
    error_message = "module_version must be MANIFEST.json's latest, read from the file and never transcribed."
  }

  assert {
    condition = (
      output.deployment_stamp.release_ring == "stable" &&
      output.deployment_stamp.capacity_profile == null &&
      length(output.deployment_stamp.add_ons) == 0 &&
      jsonencode(output.deployment_stamp.environments) == jsonencode(["aca", "app", "front", "workers"]) &&
      output.deployment_stamp.database_provider_profile == "starter"
    )
    error_message = "By default the stamp must report the stable ring, no capacity profile, no add-on, the environments aca, app, front and workers, and the starter database."
  }

  assert {
    condition     = toset(keys(output.deployment_stamp)) == toset(["module_version", "release_ring", "capacity_profile", "add_ons", "environments", "database_provider_profile"])
    error_message = "The stamp must carry exactly module_version, release_ring, capacity_profile, add_ons, environments and database_provider_profile."
  }
}

run "deployment_stamp_reports_the_capacity_profile" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    capacity_profile      = "small"
  }

  assert {
    condition     = output.deployment_stamp.capacity_profile == "small"
    error_message = "The stamp must report capacity_profile as set."
  }
}

run "deployment_stamp_names_the_add_ons_and_their_environments" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    extensions            = true
  }

  assert {
    condition = (
      jsonencode(output.deployment_stamp.add_ons) == jsonencode(["split_processing", "extensions"]) &&
      jsonencode(output.deployment_stamp.environments) == jsonencode(["aca", "app", "core", "extension", "front", "outbound", "workers"])
    )
    error_message = "With split_processing and extensions the stamp must name both add-ons and the core, outbound and extension environments."
  }
}

run "deployment_stamp_names_split_processing_alone" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
  }

  assert {
    condition = (
      jsonencode(output.deployment_stamp.add_ons) == jsonencode(["split_processing"]) &&
      !contains(output.deployment_stamp.environments, "extension")
    )
    error_message = "With split_processing alone the stamp must name that add-on and no extension environment."
  }
}

# Threat (secret disclosure): the stamp is not sensitive, so the profile is derived from the
# boolean alone. A DSN carrying a password must leave no trace of itself in it.
run "deployment_stamp_byo_db_carries_no_part_of_the_url" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgres://u:p@db.example.com:5432/m"
  }

  assert {
    condition     = output.deployment_stamp.database_provider_profile == "byo-db"
    error_message = "With external_database_url the stamp must report the byo-db profile."
  }

  assert {
    condition = (
      !strcontains(jsonencode(output.deployment_stamp), "://") &&
      !strcontains(jsonencode(output.deployment_stamp), "u:p") &&
      !strcontains(jsonencode(output.deployment_stamp), "db.example.com")
    )
    error_message = "The stamp must carry no part of external_database_url: no URL, no credentials, no host."
  }
}

run "deployment_stamp_drops_aca_once_retired" {
  command = plan

  variables {
    retire_runtime_environment = true
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    frontend_environment       = "front"
    edge_environment           = "front"
    api_environment            = "app"
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  assert {
    condition     = jsonencode(output.deployment_stamp.environments) == jsonencode(["app", "front", "workers"])
    error_message = "Once aca-<prefix> is retired the stamp must not name it."
  }
}
