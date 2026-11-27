# The BFF's DPoP key (auth.tf, enable_bff_dpop_key): generated, rotated with an overlap, and handed
# to ca-frontend alone.
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# This file also mocks tls and time. A timer's start and end are computed, so at plan they are
# unknown on Terraform 1.10, and the runs that read which slot is current apply the two keys first
# (and with them their timers), then plan the whole configuration against that state. The mock's default times are fixed and well-formed, because B's
# timer is worked out from A's. An override's values must be literals on Terraform 1.10, so they
# cannot come from tests/helpers/plan-time: the states before and after a rotation use fixed past
# dates, and the state during the overlap creates B's timer with the real time provider, so that
# B starts at the apply's own time and the plan that follows falls seconds after it.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "tls" {}
mock_provider "time" {
  mock_resource "time_rotating" {
    defaults = {
      rfc3339          = "2026-01-01T00:00:00Z"
      rotation_rfc3339 = "2026-06-30T00:00:00Z"
    }
  }
}

# The real time provider, for the one run that needs a timer started now. It takes no
# configuration and calls nothing outside the process.
provider "time" {
  alias = "real"
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

# --- Off by default -------------------------------------------------------------------------

# Off: no key, no timer, and no app's secrets or env change.
run "bff_dpop_key_is_off_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
  }

  assert {
    condition = (
      !var.enable_bff_dpop_key &&
      length(tls_private_key.bff_dpop_key_a) == 0 && length(tls_private_key.bff_dpop_key_b) == 0 &&
      length(time_rotating.bff_dpop_key_a) == 0 && length(time_rotating.bff_dpop_key_b) == 0 &&
      length(terraform_data.bff_dpop_key_a_rotation) == 0 && length(terraform_data.bff_dpop_key_b_rotation) == 0 &&
      length(terraform_data.bff_dpop_key_provisioned) == 0
    )
    error_message = "enable_bff_dpop_key must default to false, and with it off the module must plan no DPoP key, timer, rotation intermediary or provisioning marker."
  }

  assert {
    condition = (
      length(local.bff_dpop_key_secret_names) == 0 &&
      length(local.bff_dpop_key_env_secret_refs) == 0 &&
      toset(local.frontend_secret_names) == toset(["bff-shared-secret"]) &&
      toset(keys(local.frontend_env_secret_refs)) == toset(["MASTERLY_BFF_SHARED_SECRET"]) &&
      length([for k in keys(azurerm_key_vault_secret.install) : k if startswith(k, "bff-dpop-key")]) == 0 &&
      length([for k in keys(azurerm_role_assignment.kv_secrets_user_frontend) : k if startswith(k, "bff-dpop-key")]) == 0
    )
    error_message = "With enable_bff_dpop_key off, ca-frontend must carry only the BFF shared secret, as before, and no DPoP vault secret or grant may be planned."
  }
}

# --- Switch on, without the vault -------------------------------------------------------------

# The key is EC P-256, a new one every 90 days with the outgoing one kept for at least 45
# minutes, and without the vault it is a Container App secret value on ca-frontend alone.
run "bff_dpop_key_without_the_vault_is_a_value_secret_on_ca_frontend_only" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
  }

  assert {
    condition = alltrue([
      for k in [tls_private_key.bff_dpop_key_a[0], tls_private_key.bff_dpop_key_b[0]] :
      k.algorithm == "ECDSA" && k.ecdsa_curve == "P256"
    ])
    error_message = "Both DPoP key slots must be ECDSA on the P256 curve: the frontend reads an EC P-256 key."
  }

  # 90 days between keys, each slot's timer running for two of them, and an overlap of at least
  # the 15-minute session renewal plus ACA's 30-minute re-read of a versionless reference.
  assert {
    condition = (
      local.bff_dpop_key_rotation_days == 90 &&
      time_rotating.bff_dpop_key_a[0].rotation_days == 2 * local.bff_dpop_key_rotation_days &&
      local.bff_dpop_key_overlap_minutes >= 15 + 30
    )
    error_message = "The DPoP key must rotate every 90 days (each slot's timer twice that), with an overlap of at least 45 minutes."
  }

  assert {
    condition = (
      length(azurerm_key_vault_secret.install) == 0 &&
      contains(module.frontend.value_secret_names, "bff-dpop-key-a") &&
      contains(module.frontend.value_secret_names, "bff-dpop-key-b") &&
      length(module.frontend.vault_backed_secret_names) == 0
    )
    error_message = "Without the vault both DPoP key slots must be Container App secret values on ca-frontend, and no Key Vault secret may be planned."
  }

  # Threat: the key reaches an app that does not sign DPoP proofs.
  assert {
    condition = (
      length([for n in concat(
        module.api.value_secret_names, module.api.vault_backed_secret_names,
        local.api_secret_names, local.backend_secret_names, local.migrate_secret_names,
      ) : n if startswith(n, "bff-dpop-key")]) == 0 &&
      length([for n in concat(
        keys(local.api_env_secret_refs), keys(local.backend_env_secret_refs), keys(local.migrate_env_secret_refs),
        keys(local.api_env), keys(local.workers_env), keys(local.migrate_env),
      ) : n if startswith(n, "MASTERLY_BFF_DPOP_KEY")]) == 0
    )
    error_message = "ca-api, ca-workers and caj-migrate must carry no BFF DPoP key secret and no BFF DPoP key env."
  }

  # Threat: the private key leaks through a plain env value or an output. It reaches the apps only
  # through the secret catalogue, under the two slot names; ca-frontend's plain env does not name
  # it, and no output reads the key, the catalogue or the frontend's secrets.
  assert {
    condition = (
      length([for n in concat(module.frontend.env_names, keys(local.frontend_env)) : n if startswith(n, "MASTERLY_BFF_DPOP_KEY")]) == 0 &&
      length(regexall("private_key_pem", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) == 2 &&
      length(regexall("\"bff-dpop-key-[ab]\"\\s+= one\\(tls_private_key\\.bff_dpop_key_[ab]\\[\\*\\]\\.private_key_pem_pkcs8\\)", file("${path.module}/main.tf"))) == 2 &&
      length(regexall("(?s)\\noutput \"[^\"]+\" \\{.*?\\n\\}", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) > 0 &&
      alltrue([
        for o in regexall("(?s)\\noutput \"[^\"]+\" \\{.*?\\n\\}", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")])) :
        !can(regex("tls_private_key|bff_dpop_key|secret_values|frontend_secrets|frontend_value_secrets", o))
      ])
    )
    error_message = "The DPoP private key may reach an app only as a secret through local.secret_values: never as plain env, and never through a module output."
  }
}

# --- The replay cache needs Redis beyond one api replica --------------------------------------

# The api's DPoP replay cache is in memory without Redis, which holds for one replica only: the
# existing refusal of api_max_replicas > 1 without enable_redis still applies with the key on.
run "bff_dpop_key_with_two_api_replicas_and_no_redis_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
    api_max_replicas      = 2
    enable_redis          = false
  }

  expect_failures = [var.api_max_replicas]
}

# The three descriptions name Azure Managed Redis as the replay cache's target, and the in-memory
# cache's one-replica limit.
run "the_replay_cache_target_is_named_in_the_descriptions" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue([
      for d in [
        regex("(?s)variable \"enable_bff_dpop_key\" \\{.*?\\n\\}", file("${path.module}/variables-auth.tf")),
        regex("(?s)variable \"api_max_replicas\" \\{.*?\\n\\}", file("${path.module}/variables-core.tf")),
        regex("(?s)variable \"enable_redis\" \\{.*?\\n\\}", file("${path.module}/redis.tf")),
      ] :
      strcontains(d, "DPoP replay cache") && strcontains(d, "Azure Managed Redis (redis_offering = \\\"managed\\\"") && strcontains(d, "one api replica only")
    ])
    error_message = "The descriptions of enable_bff_dpop_key, api_max_replicas and enable_redis must name Azure Managed Redis (redis_offering = \"managed\") as the DPoP replay cache's target, and say the in-memory cache is allowed on one api replica only."
  }
}

# --- Rotation -----------------------------------------------------------------------------------
#
# Three states, each set by applying the two keys and their timers, then planning the whole
# configuration, with the vault on, against that state. The overlap is measured from the plan's
# own time (plantimestamp()), and an override's values must be literals, so:
#
# - Slot A started on 2026-01-01 throughout, so its overlap is long over. Its timer expires in
#   2099, so B's expiry, worked out from A's, stays at least 45 days ahead of any plan.
# - Before a rotation, B started 90 days before A (a fixed past date).
# - During the overlap, B's timer is replaced by the real time provider, so B starts at that
#   apply's own time, a real past rotation, and the plan that follows falls seconds after it,
#   well inside the 60 minutes.
# - After the overlap, B started 90 days after A (a fixed past date), so every plan falls long
#   after its start plus 60 minutes.
#
# Each later apply replaces B's timer, which replaces B's key with it. The key values are
# placeholders, not keys: the runs assert the wiring, never key material.

# Before a rotation: A is the current key and the overlap after it has ended.
run "rotation_before_a_rotation_apply" {
  command = apply

  plan_options {
    target = [terraform_data.bff_dpop_key_provisioned, time_rotating.bff_dpop_key_a, time_rotating.bff_dpop_key_b, tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
  }

  # Each id is its start, as the real provider writes it. B's matters: the real provider replaces
  # B's timer in the overlap run below and parses the id it finds in this state. A's matches the
  # override that run gives A, so A's state does not change there. B's expiry is left to the
  # mock's default, a well-formed date the module's plan overwrites from A's.
  override_resource {
    target = time_rotating.bff_dpop_key_a
    values = {
      id               = "2026-01-01T00:00:00Z"
      rfc3339          = "2026-01-01T00:00:00Z"
      rotation_rfc3339 = "2099-12-31T00:00:00Z"
    }
  }

  override_resource {
    target = time_rotating.bff_dpop_key_b
    values = {
      id      = "2025-10-03T00:00:00Z"
      rfc3339 = "2025-10-03T00:00:00Z"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_a
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-a"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_b
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b-before"
    }
  }

  # B's timer expires halfway through A's: 90 days before A's while that is at least 45 days away.
  assert {
    condition     = time_rotating.bff_dpop_key_b[0].rotation_rfc3339 == timeadd(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, "-2160h")
    error_message = "Slot B's timer must expire 90 days before slot A's, so that the two slots are replaced 90 days apart."
  }

  # A targeted apply evaluates no local, so which env names ca-frontend reads is asserted by the
  # plan that follows; here, only that A is the slot replaced last.
  assert {
    condition     = timecmp(time_rotating.bff_dpop_key_a[0].rfc3339, time_rotating.bff_dpop_key_b[0].rfc3339) > 0
    error_message = "Before a rotation slot A must be the slot replaced last."
  }
}

run "rotation_before_a_rotation" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
    enable_bff_dpop_key   = true
  }

  assert {
    condition = (
      jsonencode(local.frontend_env_secret_refs) == jsonencode({ MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret", MASTERLY_BFF_DPOP_KEY = "bff-dpop-key-a" }) &&
      azurerm_key_vault_secret.install["bff-dpop-key-a"].value == tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8
    )
    error_message = "Before a rotation ca-frontend must read MASTERLY_BFF_DPOP_KEY alone, from slot A's vault secret, whose value is slot A's key as PKCS#8 PEM."
  }

  assert {
    condition = (
      toset([for k in keys(azurerm_key_vault_secret.install) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(azurerm_role_assignment.kv_secrets_user_frontend) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(local.frontend_vault_secret_refs) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"])
    )
    error_message = "Both slots' vault secrets, the frontend's grants on them and its references to them must be planned before a rotation."
  }
}

# During the overlap: B is replaced now, by the real time provider, and the plan that follows falls
# seconds after its start, so B is the current key and A, the outgoing one, is kept as _PREVIOUS.
# A keeps the fixed times it was given before a rotation, overridden here so the real provider
# makes no call for it.
run "rotation_during_the_overlap_apply" {
  command = apply

  providers = {
    azurerm = azurerm
    random  = random
    azapi   = azapi
    tls     = tls
    time    = time.real
  }

  plan_options {
    target  = [terraform_data.bff_dpop_key_provisioned, time_rotating.bff_dpop_key_a, time_rotating.bff_dpop_key_b, tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
    replace = [time_rotating.bff_dpop_key_b[0]]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
  }

  override_resource {
    target = time_rotating.bff_dpop_key_a
    values = {
      id               = "2026-01-01T00:00:00Z"
      rfc3339          = "2026-01-01T00:00:00Z"
      rotation_rfc3339 = "2099-12-31T00:00:00Z"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_b
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b-after"
    }
  }

  # The env names are asserted by the plan that follows; here, that B's key was replaced with its
  # timer and A's was not.
  assert {
    condition = (
      timecmp(time_rotating.bff_dpop_key_b[0].rfc3339, time_rotating.bff_dpop_key_a[0].rfc3339) > 0 &&
      tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-b-after" &&
      tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-a" &&
      tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 != tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8
    )
    error_message = "Replacing B's timer must replace B's key (the new key) and leave A's (the outgoing one), and the two must differ."
  }
}

run "rotation_during_the_overlap" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
    enable_bff_dpop_key   = true
  }

  # B's start is a real rotation, in the past, and this plan falls inside the overlap after it.
  assert {
    condition = (
      timecmp(plantimestamp(), time_rotating.bff_dpop_key_b[0].rfc3339) >= 0 &&
      timecmp(plantimestamp(), timeadd(time_rotating.bff_dpop_key_b[0].rfc3339, "${local.bff_dpop_key_overlap_minutes}m")) < 0
    )
    error_message = "This plan must fall after slot B's real start and within the overlap after it."
  }

  assert {
    condition = (
      jsonencode(local.frontend_env_secret_refs) == jsonencode({
        MASTERLY_BFF_SHARED_SECRET     = "bff-shared-secret"
        MASTERLY_BFF_DPOP_KEY          = "bff-dpop-key-b"
        MASTERLY_BFF_DPOP_KEY_PREVIOUS = "bff-dpop-key-a"
      }) &&
      azurerm_key_vault_secret.install["bff-dpop-key-b"].value == tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 &&
      azurerm_key_vault_secret.install["bff-dpop-key-a"].value == tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8 &&
      azurerm_key_vault_secret.install["bff-dpop-key-b"].value != azurerm_key_vault_secret.install["bff-dpop-key-a"].value
    )
    error_message = "During the overlap ca-frontend must read MASTERLY_BFF_DPOP_KEY from slot B's vault secret (the new key) and MASTERLY_BFF_DPOP_KEY_PREVIOUS from slot A's (the outgoing key), and the two values must differ."
  }

  assert {
    condition = (
      toset([for k in keys(azurerm_key_vault_secret.install) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(azurerm_role_assignment.kv_secrets_user_frontend) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(local.frontend_vault_secret_refs) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"])
    )
    error_message = "Both slots' vault secrets, the frontend's grants on them and its references to them must be planned during the overlap."
  }
}

# After the overlap: B was replaced last, 90 days after A, and its overlap is long over, so only
# the new key is set.
run "rotation_after_the_overlap_apply" {
  command = apply

  plan_options {
    target  = [terraform_data.bff_dpop_key_provisioned, time_rotating.bff_dpop_key_a, time_rotating.bff_dpop_key_b, tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
    replace = [time_rotating.bff_dpop_key_b[0]]
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
  }

  override_resource {
    target = time_rotating.bff_dpop_key_b
    values = {
      rfc3339 = "2026-04-01T00:00:00Z"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_b
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b-after"
    }
  }

  # The env names are asserted by the plan that follows; here, that B is the slot replaced last.
  assert {
    condition     = timecmp(time_rotating.bff_dpop_key_b[0].rfc3339, time_rotating.bff_dpop_key_a[0].rfc3339) > 0
    error_message = "After the rotation slot B must be the slot replaced last."
  }
}

# Ending the overlap removes ca-frontend's _PREVIOUS env and nothing else: both slots' vault
# secrets, grants and references are planned at the same addresses as during the overlap, so no
# vault secret is deleted and none is recreated under soft-delete.
run "rotation_after_the_overlap" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
    enable_bff_dpop_key   = true
  }

  assert {
    condition     = timecmp(plantimestamp(), timeadd(time_rotating.bff_dpop_key_b[0].rfc3339, "${local.bff_dpop_key_overlap_minutes}m")) >= 0
    error_message = "This plan must fall after the overlap that follows slot B's start."
  }

  assert {
    condition = (
      jsonencode(local.frontend_env_secret_refs) == jsonencode({ MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret", MASTERLY_BFF_DPOP_KEY = "bff-dpop-key-b" }) &&
      azurerm_key_vault_secret.install["bff-dpop-key-b"].value == tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8
    )
    error_message = "After the overlap ca-frontend must read MASTERLY_BFF_DPOP_KEY alone, from slot B's vault secret."
  }

  assert {
    condition = (
      toset([for k in keys(azurerm_key_vault_secret.install) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(azurerm_role_assignment.kv_secrets_user_frontend) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      toset([for k in keys(local.frontend_vault_secret_refs) : k if startswith(k, "bff-dpop-key")]) == toset(["bff-dpop-key-a", "bff-dpop-key-b"]) &&
      contains(module.frontend.vault_backed_secret_names, "bff-dpop-key-a") &&
      contains(module.frontend.vault_backed_secret_names, "bff-dpop-key-b")
    )
    error_message = "Ending the overlap must remove only the MASTERLY_BFF_DPOP_KEY_PREVIOUS env: both slots' vault secrets, the frontend's grants on them and its references to them must still be planned."
  }
}

# The same state without the vault: ca-frontend reads MASTERLY_BFF_DPOP_KEY from a Container App
# secret whose value is the current key, and no vault secret holds it.
run "rotation_after_the_overlap_without_the_vault" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_bff_dpop_key   = true
  }

  assert {
    condition = (
      jsonencode(local.frontend_env_secret_refs) == jsonencode({ MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret", MASTERLY_BFF_DPOP_KEY = "bff-dpop-key-b" }) &&
      local.frontend_value_secrets["bff-dpop-key-b"] == tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 &&
      contains(module.frontend.value_secret_names, "bff-dpop-key-b") &&
      length(azurerm_key_vault_secret.install) == 0 &&
      length(local.frontend_vault_secret_refs) == 0
    )
    error_message = "Without the vault ca-frontend must read MASTERLY_BFF_DPOP_KEY from a Container App secret holding the current key, and no Key Vault secret may be planned for it."
  }
}
