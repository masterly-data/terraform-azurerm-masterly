# Container Apps built-in authentication (builtin-auth.tf).
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

# --- Container Apps built-in authentication (builtin_auth) --------------------------------

run "builtin_auth_is_absent_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azapi_resource.builtin_auth) == 0
    error_message = "With builtin_auth unset, no app may get a built-in auth configuration."
  }

  assert {
    condition = (
      !contains(module.api.value_secret_names, "microsoft-provider-authentication-secret") &&
      !contains(module.frontend.value_secret_names, "microsoft-provider-authentication-secret")
    )
    error_message = "With builtin_auth unset, neither app may carry the built-in auth client secret."
  }
}

run "builtin_auth_gates_the_frontend_only" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = toset(keys(azapi_resource.builtin_auth)) == toset(["frontend"])
    error_message = "builtin_auth must configure built-in auth on ca-frontend only, under the key \"frontend\" that earlier versions used."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["frontend"].name == "current" &&
      azapi_resource.builtin_auth["frontend"].type == "Microsoft.App/containerApps/authConfigs@2025-01-01"
    )
    error_message = "The frontend's auth configuration must be authConfigs/current at 2025-01-01, as in earlier versions, or the upgrade replaces it."
  }

  # The body exactly as 0.19.0 and 0.19.1 planned it for the frontend. Any difference is an
  # update to ca-frontend's gate on upgrade, which this version must not make.
  assert {
    condition = jsonencode(azapi_resource.builtin_auth["frontend"].body) == jsonencode({
      properties = {
        platform = {
          enabled = true
        }
        globalValidation = {
          unauthenticatedClientAction = "RedirectToLoginPage"
          excludedPaths               = []
          redirectToProvider          = "azureactivedirectory"
        }
        identityProviders = {
          azureActiveDirectory = {
            registration = {
              clientId                = "22222222-2222-2222-2222-222222222222"
              clientSecretSettingName = "microsoft-provider-authentication-secret"
              openIdIssuer            = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
            }
            validation = {
              allowedAudiences = []
              defaultAuthorizationPolicy = {
                allowedApplications = ["22222222-2222-2222-2222-222222222222"]
              }
            }
          }
        }
      }
    })
    error_message = "The frontend's auth configuration body must be unchanged from 0.19.1: redirect to Entra sign-in, no excluded path by default, and only its own registration's tokens admitted."
  }

  assert {
    condition     = length(local.builtin_auth_ignored_api_entries) == 0
    error_message = "With no api entries set, the deprecation warning must not fire."
  }

  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "With the api internal, the published-api warning must not fire."
  }

  assert {
    condition = (
      contains(module.api.value_secret_names, "microsoft-provider-authentication-secret") &&
      contains(module.frontend.value_secret_names, "microsoft-provider-authentication-secret") &&
      !contains(module.workers[0].value_secret_names, "microsoft-provider-authentication-secret")
    )
    error_message = "The built-in auth client secret must stay on ca-api as well as ca-frontend, so that upgrading changes neither app, and never reach ca-workers, which has no ingress."
  }
}

# With the app ids known, nothing built-in auth configures may name ca-api as its parent.
# azapi_resource.builtin_auth is the module's only authConfigs resource.
run "builtin_auth_configures_nothing_on_ca_api" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  override_module {
    target = module.api
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name                      = "ca-api"
      fqdn                      = "ca-api.internal.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = false
      ingress_allow_insecure    = true
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
    condition = length([
      for k, r in azapi_resource.builtin_auth : k
      if r.parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
    ]) == 0
    error_message = "No built-in auth configuration may target ca-api: builtin_auth gates ca-frontend only."
  }

  assert {
    condition = (
      length(azapi_resource.builtin_auth) == 1 &&
      azapi_resource.builtin_auth["frontend"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
    )
    error_message = "builtin_auth must configure exactly one auth configuration, on ca-frontend."
  }
}

# The api entries are deprecated and ignored: setting them still plans, configures nothing on
# ca-api, leaves the frontend's configuration as it would be without them, and warns.
run "builtin_auth_ignores_the_api_entries_with_a_warning" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id                = "11111111-1111-1111-1111-111111111111"
      client_id                = "22222222-2222-2222-2222-222222222222"
      api_allowed_applications = ["33333333-3333-3333-3333-333333333333"]
      api_allowed_audiences    = ["api://masterly-api"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = toset(keys(azapi_resource.builtin_auth)) == toset(["frontend"])
    error_message = "The deprecated api entries must not bring back a configuration on ca-api."
  }

  assert {
    condition = (
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences) == jsonencode([]) &&
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["22222222-2222-2222-2222-222222222222"])
    )
    error_message = "The deprecated api entries must not reach the frontend's configuration."
  }

  expect_failures = [check.builtin_auth_api_entries_are_ignored]
}

# With the api published, builtin_auth still gates ca-frontend only, and the plan warns that
# the published api has no platform gate.
run "builtin_auth_warns_when_the_api_is_published" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  override_module {
    target = module.api
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name                      = "ca-api"
      fqdn                      = "ca-api.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = true
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = ["203.0.113.7/32"]
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
    condition     = local.builtin_auth_leaves_published_api_ungated
    error_message = "With builtin_auth set and api_ingress_external = true, the published api is ungated and the plan must warn."
  }

  assert {
    condition = (
      toset(keys(azapi_resource.builtin_auth)) == toset(["frontend"]) &&
      length([
        for k, r in azapi_resource.builtin_auth : k
        if r.parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      ]) == 0
    )
    error_message = "Publishing the api must not bring back a built-in auth configuration on ca-api."
  }

  expect_failures = [check.builtin_auth_does_not_gate_the_published_api]
}

run "builtin_auth_excluded_paths_reach_the_frontend" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["/", "/login"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation.excludedPaths) == jsonencode(["/", "/login"])
    error_message = "frontend_excluded_paths must reach ca-frontend's configuration."
  }
}

run "builtin_auth_refuses_a_non_uuid_client_id" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "masterly-frontend"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.builtin_auth]
}

run "builtin_auth_refuses_a_relative_excluded_path" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["login"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.builtin_auth]
}

run "builtin_auth_requires_its_client_secret" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
  }

  expect_failures = [var.builtin_auth]
}

# With the vault on, the built-in auth client secret is a vault reference like every other
# install secret, and the frontend reads it with its own identity's per-secret grant.
run "builtin_auth_secret_is_a_vault_reference_in_production" {
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
    registry_username    = "install-puller"
    registry_password    = "pull-secret"
    telemetry_url        = "https://cp.masterlydata.com"
    telemetry_client_id  = "sa_01TEST"

    telemetry_client_secret = "telemetry-secret"
    breakglass_owner_email  = "owner@example.com"
    breakglass_secret_hash  = "0000000000000000000000000000000000000000000000000000000000000000"
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }


  assert {
    condition = (
      contains(module.api.vault_backed_secret_names, "microsoft-provider-authentication-secret") &&
      contains(module.frontend.vault_backed_secret_names, "microsoft-provider-authentication-secret") &&
      length(module.frontend.value_secret_names) == 0
    )
    error_message = "With the Key Vault on, the built-in auth client secret must reach both apps as a vault reference, never as a value."
  }

  assert {
    condition     = contains(keys(azurerm_role_assignment.kv_secrets_user_frontend), "microsoft-provider-authentication-secret")
    error_message = "The frontend's identity must be granted read on the built-in auth secret alone, like each of its other secrets."
  }
}
