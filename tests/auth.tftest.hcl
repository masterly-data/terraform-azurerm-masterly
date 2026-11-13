# Identity binding guards, the session secret and the BFF shared secret (auth.tf).
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

# Guard: dev identity with an open ingress is unrepresentable.
run "open_ingress_dev_identity_is_rejected" {
  command = plan

  expect_failures = [var.identity_binding]
}

# Guard: oidc requires both the backend verification half and the BFF client half.
run "half_configured_oidc_is_rejected" {
  command = plan

  variables {
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
  }

  expect_failures = [var.identity_binding]
}

# --- Rotating the session secret ------------------------------------------------------
# Replacing the signing secret on its own signs out every signed-in user. The api accepts a
# retired secret for verification while it is configured, so the rotation is two applies —
# but only if the module can actually express the outgoing value.

run "no_session_secret_rotation_window_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  # The steady state is one key. Absent, not empty: an empty value would be a second key the
  # api is told to accept, and the empty string is not a key anyone should sign with.
  assert {
    condition     = !contains(keys(local.api_env_secret_refs), "MASTERLY_SESSION_SECRET_PREVIOUS")
    error_message = "With no rotation in flight the api must not be told to accept a second session secret."
  }

  assert {
    condition     = !contains(module.api.value_secret_names, "session-secret-previous")
    error_message = "The retired-secret slot must not exist on the app when no rotation is in flight."
  }
}

run "session_secret_rotation_window_reaches_the_api" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    session_secret_previous = "the-outgoing-session-secret-0123456789ab"
  }

  # It travels as a Container App secret, exactly like the secret it replaces — never plain
  # environment, where any reader of the app's configuration would have the key.
  assert {
    condition     = local.api_env_secret_refs["MASTERLY_SESSION_SECRET_PREVIOUS"] == "session-secret-previous"
    error_message = "The outgoing session secret must reach the api as a secret reference."
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_SESSION_SECRET_PREVIOUS")
    error_message = "The outgoing session secret must never appear in the plain environment map."
  }

  assert {
    condition     = contains(module.api.value_secret_names, "session-secret-previous")
    error_message = "The outgoing session secret must be carried by the app it is verified in."
  }

  # The frontend signs and verifies nothing. A key it never needs is a key it must not hold.
  assert {
    condition     = !contains(module.frontend.value_secret_names, "session-secret-previous")
    error_message = "No session secret, current or retired, may reach the frontend."
  }
}

# A rotation window is only as strong as the weakest key in it: a listed secret still
# verifies sessions, so it is held to the minimum the api enforces for the one it signs with.
run "a_weak_retired_session_secret_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    session_secret_previous = "short"
  }

  expect_failures = [var.session_secret_previous]
}

# --- The BFF shared secret ----------------------------------------------------------------
# A break-glass attempt made in the GUI reaches the api from the frontend's BFF, so the api
# attributes it to the browser's address only when the BFF presents MASTERLY_BFF_SHARED_SECRET
# and the api holds the same value. Unset on either app, every GUI attempt shares the frontend
# replica's throttle window. The module generates the value and sets it on exactly those two
# apps, as a secret reference on both.

run "bff_shared_secret_reaches_the_api_and_the_frontend_and_nothing_else" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
  }

  assert {
    condition = (
      lookup(local.api_env_secret_refs, "MASTERLY_BFF_SHARED_SECRET", null) == "bff-shared-secret" &&
      lookup(local.frontend_env_secret_refs, "MASTERLY_BFF_SHARED_SECRET", null) == "bff-shared-secret"
    )
    error_message = "MASTERLY_BFF_SHARED_SECRET must reach both ca-api and ca-frontend as a secret reference."
  }

  # Never plain env, on either app: anything that can read an app's configuration would then
  # hold the credential that lets it state any caller address to the api.
  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_BFF_SHARED_SECRET") &&
      !contains(module.frontend.env_names, "MASTERLY_BFF_SHARED_SECRET")
    )
    error_message = "MASTERLY_BFF_SHARED_SECRET must never appear in an app's plain environment."
  }

  # Each app carries the secret its reference names. Both fill it from the one catalogue entry,
  # and so from one generated value: a mismatch would leave the mechanism silently off. (The
  # value itself is unknown until apply, so it is the name that is asserted here.)
  assert {
    condition = (
      contains(module.api.value_secret_names, "bff-shared-secret") &&
      contains(module.frontend.value_secret_names, "bff-shared-secret")
    )
    error_message = "ca-api and ca-frontend must both carry the BFF shared secret their references name."
  }

  # ca-workers serves no request, so it has no use for the credential that authenticates the
  # frontend's requests. It still gets the rest of the api's secrets.
  assert {
    condition = (
      !contains(module.workers[0].value_secret_names, "bff-shared-secret") &&
      !contains(keys(local.backend_env_secret_refs), "MASTERLY_BFF_SHARED_SECRET") &&
      !contains(module.workers[0].env_names, "MASTERLY_BFF_SHARED_SECRET") &&
      module.workers[0].value_secret_names == tolist([for name in module.api.value_secret_names : name if name != "bff-shared-secret"])
    )
    error_message = "ca-workers must carry the api's secrets except the BFF shared secret."
  }

  # The api refuses to start with fewer than 32 bytes. Alphanumeric, like the session secret.
  assert {
    condition     = random_password.bff_shared_secret.length >= 32 && random_password.bff_shared_secret.special == false
    error_message = "The BFF shared secret must be at least 32 alphanumeric characters, the minimum the api accepts at startup."
  }
}

# With the vault on it is a Key Vault reference like every other install secret — and it is
# the frontend's own secret even when nothing else is, so the frontend resolves it with its
# own identity, which gets read on that secret and nothing more.
run "bff_shared_secret_is_a_vault_reference_on_both_apps" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
    enable_workers        = true
  }

  override_module {
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.frontend_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"
      principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      client_id    = "ffffffff-ffff-ffff-ffff-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend"
    }
  }

  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "bff-shared-secret") &&
      module.frontend.vault_backed_secret_names == tolist(["bff-shared-secret"]) &&
      !contains(module.api.value_secret_names, "bff-shared-secret") &&
      length(module.frontend.value_secret_names) == 0
    )
    error_message = "With the vault on, the BFF shared secret must reach ca-api and ca-frontend as a Key Vault reference, never a value."
  }

  # Written once, under the install- prefix, and read by both apps from that one entry.
  assert {
    condition     = azurerm_key_vault_secret.install["bff-shared-secret"].name == "install-bff-shared-secret"
    error_message = "The BFF shared secret must be written to the vault once, as install-bff-shared-secret."
  }

  assert {
    condition = (
      !contains(module.workers[0].vault_backed_secret_names, "bff-shared-secret") &&
      !contains(module.workers[0].value_secret_names, "bff-shared-secret")
    )
    error_message = "ca-workers must not carry the BFF shared secret, as a reference or a value."
  }

  # The frontend resolves it with its own identity, which therefore holds Secrets User — read —
  # on that secret. A reference naming the backend's identity would never resolve on an app
  # that does not carry it, and the revision would never start.
  assert {
    condition = (
      module.frontend.secret_ref_identity_ids == tolist([module.frontend_identity.id]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(["bff-shared-secret"]) &&
      alltrue([
        for k, ra in azurerm_role_assignment.kv_secrets_user_frontend :
        ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.frontend_identity.principal_id
      ])
    )
    error_message = "The frontend must resolve the BFF shared secret with its own identity, granted Key Vault Secrets User on that secret and nothing more."
  }
}
