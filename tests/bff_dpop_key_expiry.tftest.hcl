# A real time_rotating refresh removes an expired timer from state, leaving a create rather
# than a replacement. Verify that both slots replace their keys in that case, with no forced
# replacement. This file has its own state so its first apply can seed expired timers.
# All cloud and key resources are mocked; only the clock provider is real, with no network I/O.
# The key values are distinct non-key placeholders, observed only when a key is created.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "tls" {}
mock_provider "time" {
  mock_resource "time_rotating" {
    defaults = {
      rfc3339          = "2000-01-01T00:00:00Z"
      rotation_rfc3339 = "2000-06-29T00:00:00Z"
    }
  }
}

provider "time" {
  alias = "real"
}

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

  ingress_allowed_cidrs = ["203.0.113.7/32"]
  enable_bff_dpop_key   = true
}

run "seed_expired_rotation_state" {
  command = apply

  plan_options {
    target = [tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
  }

  override_resource {
    target = time_rotating.bff_dpop_key_a
    values = {
      id               = "2000-01-01T00:00:00Z"
      rfc3339          = "2000-01-01T00:00:00Z"
      rotation_rfc3339 = "2000-06-29T00:00:00Z"
    }
  }

  override_resource {
    target = time_rotating.bff_dpop_key_b
    values = {
      id      = "2000-04-01T00:00:00Z"
      rfc3339 = "2000-04-01T00:00:00Z"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_a
    values = {
      id                    = "fixture-key-a-before-expiry"
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-a-expired"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_b
    values = {
      id                    = "fixture-key-b-before-expiry"
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b-expired"
    }
  }

  assert {
    condition = (
      timecmp(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, plantimestamp()) < 0 &&
      timecmp(time_rotating.bff_dpop_key_b[0].rotation_rfc3339, plantimestamp()) < 0 &&
      tls_private_key.bff_dpop_key_a[0].id == "fixture-key-a-before-expiry" &&
      tls_private_key.bff_dpop_key_b[0].id == "fixture-key-b-before-expiry" &&
      tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-a-expired" &&
      tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-b-expired"
    )
    error_message = "The fixture must persist two expired timers and distinct initial key values before real refresh."
  }
}

run "expired_slot_a_refresh_replaces_its_key" {
  command = apply

  providers = {
    azurerm = azurerm
    random  = random
    azapi   = azapi
    tls     = tls
    time    = time.real
  }

  plan_options {
    target = [tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
  }

  # Hold B unchanged to observe A's expiry alone and the outgoing B key during the overlap.
  # A has no override: the real provider must discard its expired state during refresh.
  override_resource {
    target = time_rotating.bff_dpop_key_b
    values = {
      id      = "2000-04-01T00:00:00Z"
      rfc3339 = "2000-04-01T00:00:00Z"
    }
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_a
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-a-renewed"
    }
  }

  assert {
    condition = (
      time_rotating.bff_dpop_key_a[0].id != "2000-01-01T00:00:00Z" &&
      timecmp(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, plantimestamp()) > 0 &&
      tls_private_key.bff_dpop_key_a[0].id != "fixture-key-a-before-expiry" &&
      tls_private_key.bff_dpop_key_b[0].id == "fixture-key-b-before-expiry" &&
      tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-a-renewed" &&
      tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-b-expired"
    )
    error_message = "A's real refresh expiry must replace A's key without a replace option, while preserving B's outgoing key."
  }
}

run "slot_a_current_keeps_slot_b_during_the_overlap" {
  command = plan

  variables {
    enable_key_vault = true
  }

  assert {
    condition = (
      timecmp(plantimestamp(), time_rotating.bff_dpop_key_a[0].rfc3339) >= 0 &&
      timecmp(plantimestamp(), timeadd(time_rotating.bff_dpop_key_a[0].rfc3339, "${local.bff_dpop_key_overlap_minutes}m")) < 0 &&
      jsonencode(local.frontend_env_secret_refs) == jsonencode({
        MASTERLY_BFF_SHARED_SECRET     = "bff-shared-secret"
        MASTERLY_BFF_DPOP_KEY          = "bff-dpop-key-a"
        MASTERLY_BFF_DPOP_KEY_PREVIOUS = "bff-dpop-key-b"
      }) &&
      azurerm_key_vault_secret.install["bff-dpop-key-a"].value == "placeholder-not-a-key-slot-a-renewed" &&
      azurerm_key_vault_secret.install["bff-dpop-key-b"].value == "placeholder-not-a-key-slot-b-expired"
    )
    error_message = "Within the overlap after A's real expiry, ca-frontend must read the renewed A key as current and the unchanged B key as previous."
  }
}

# B still has its expired rotation_rfc3339 in state: ignore_changes preserved it while A
# rotated. Now let the real provider refresh both timers; A is unexpired and only B renews.
run "expired_slot_b_refresh_replaces_its_key" {
  command = apply

  providers = {
    azurerm = azurerm
    random  = random
    azapi   = azapi
    tls     = tls
    time    = time.real
  }

  plan_options {
    target = [tls_private_key.bff_dpop_key_a, tls_private_key.bff_dpop_key_b]
  }

  override_resource {
    target = tls_private_key.bff_dpop_key_b
    values = {
      private_key_pem_pkcs8 = "placeholder-not-a-key-slot-b-renewed"
    }
  }

  assert {
    condition = (
      time_rotating.bff_dpop_key_b[0].id != "2000-04-01T00:00:00Z" &&
      timecmp(time_rotating.bff_dpop_key_b[0].rotation_rfc3339, plantimestamp()) > 0 &&
      tls_private_key.bff_dpop_key_b[0].id != "fixture-key-b-before-expiry" &&
      tls_private_key.bff_dpop_key_b[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-b-renewed" &&
      tls_private_key.bff_dpop_key_a[0].private_key_pem_pkcs8 == "placeholder-not-a-key-slot-a-renewed"
    )
    error_message = "B's real refresh expiry must replace B's key without a replace option, while preserving A's unexpired key."
  }
}
