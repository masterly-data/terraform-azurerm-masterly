# The licence: refresh, and the pinned api image.
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

# --- Licence refresh (ADR 0074): one input, off unless the credential is beside it ----------

run "license_refresh_is_off_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = local.license_refresh_configured == false
    error_message = "license_refresh_configured must be false when license_issuer_url is unset."
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_LICENSE_ISSUER_URL")
    error_message = "An unset license_issuer_url must not reach the apps — the offline posture makes no outbound call."
  }
}

run "license_refresh_wires_the_url_beside_the_install_credential" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_url           = "https://cp.masterlydata.com"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  assert {
    condition     = local.api_env["MASTERLY_LICENSE_ISSUER_URL"] == "https://cp.masterlydata.com/v1/licenses/refresh"
    error_message = "license_issuer_url must reach the apps verbatim — it is a full URL, not an origin."
  }

  # The workers app runs the refresh loop on a scaled install, so it must see the same env.
  assert {
    condition     = local.api_env["MASTERLY_TELEMETRY_CLIENT_ID"] == "sa_01TEST"
    error_message = "The install credential must reach the apps alongside the refresh URL."
  }
}

# Guard: the URL without the credential looks configured and never refreshes.
run "license_refresh_without_the_credential_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    license_issuer_url    = "https://cp.masterlydata.com/v1/licenses/refresh"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# MAS-208: licence refresh and fleet telemetry are separate features that share one input, the
# install credential. Refresh with the credential and WITHOUT telemetry_url must plan cleanly,
# carry the credential and the refresh URL to the apps, and carry no telemetry URL — so the
# application refreshes daily and reports nothing (it gates reporting on the URL AND the id).
run "license_refresh_without_telemetry_url_plans_and_reports_nothing" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  assert {
    condition     = local.license_refresh_configured && !local.telemetry_configured
    error_message = "The licence URL plus the install credential must configure refresh and leave telemetry off."
  }

  assert {
    condition     = local.api_env["MASTERLY_LICENSE_ISSUER_URL"] == "https://cp.masterlydata.com/v1/licenses/refresh"
    error_message = "license_issuer_url must reach the apps without telemetry_url beside it."
  }

  assert {
    condition     = local.api_env["MASTERLY_TELEMETRY_CLIENT_ID"] == "sa_01TEST"
    error_message = "The install credential's client id must reach the apps when only refresh uses it."
  }

  assert {
    condition     = local.api_env_secret_refs["MASTERLY_TELEMETRY_CLIENT_SECRET"] == "telemetry-client-secret" && contains(local.api_secret_names, "telemetry-client-secret")
    error_message = "The install credential's secret must reach the apps as a secret reference when only refresh uses it."
  }

  # THE assertion this run is about: no reporting URL, so nothing is reported.
  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_TELEMETRY_URL")
    error_message = "Refresh alone must not set MASTERLY_TELEMETRY_URL — that would switch hourly fleet reporting on."
  }
}

# Guard: refresh with half the credential never authenticates. Both the licence guard and the
# credential-pair guard refuse it; neither names telemetry_url.
run "license_refresh_without_the_credential_secret_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    license_issuer_url    = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_client_id   = "sa_01TEST"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: the credential with neither feature that uses it looks configured and does nothing.
run "install_credential_without_a_feature_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: the secret without its client id is half a credential, whatever else is set.
run "install_credential_secret_without_client_id_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    telemetry_client_secret = "s3cret"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Not a production requirement (ADR 0074 §2: refresh is optional; air-gapped stays first-class).
run "production_does_not_require_license_refresh" {
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
    condition     = local.license_refresh_configured == false
    error_message = "mode=production must plan without license_issuer_url — refresh is optional by decision, not a production requirement."
  }
}

# --- The licence and the pinned api image (ADR 0013, amended 2026-10-06, point 5) ----------
# The plan refuses a licence whose signed claims floor is above the claims version the module's
# own MANIFEST.json records for the pinned api image. tests/license_claims_floor.tftest.hcl
# proves the check against a synthetic manifest; these prove the root module wires it to the real
# one and refuses the plan on it. The api image is a release the manifest recorded before
# api_claims_version existed, so it reads as 0 — which every released api image verifies today.
#
# The token is the shape of a licence only: a JOSE header, an empty payload and no signature
# anything could verify. Its header, base64url-decoded:
#   {"alg":"ES256","typ":"JWT","kid":"fixture","masterly_claims_version":1,"masterly_claims_floor":1}
run "a_licence_floor_above_the_pinned_api_image_fails_the_plan" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api:v0.133.2"
    license_token         = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MSwibWFzdGVybHlfY2xhaW1zX2Zsb29yIjoxfQ.e30.unsigned"
    license_public_jwk    = "{\"kty\":\"EC\"}"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "a_headerless_licence_on_the_same_image_plans_clean" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api:v0.133.2"
    license_token         = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUifQ.e30.unsigned"
    license_public_jwk    = "{\"kty\":\"EC\"}"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == 0
    error_message = "A licence with no claims-version header must plan clean, and the manifest's release cut before api_claims_version must read as 0."
  }
}

# The file-wide api_image names a tag no release records, so the same licence is not checked.
run "a_licence_floor_on_an_unrecorded_api_image_is_not_checked" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    license_token         = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MSwibWFzdGVybHlfY2xhaW1zX2Zsb29yIjoxfQ.e30.unsigned"
    license_public_jwk    = "{\"kty\":\"EC\"}"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == null
    error_message = "An api image whose tag the manifest does not record must pass unchecked."
  }
}
