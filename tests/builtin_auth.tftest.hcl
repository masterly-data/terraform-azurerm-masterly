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

# --- The recovery fallback (builtin_auth_recovery_until) and the auth-configuration alert ----

# Times 30, 59 and 61 minutes after this run's plan, for the runs below that need one relative
# to the 60-minute window (tests/helpers/plan-time).
run "plan_time" {
  command = plan

  module {
    source = "./tests/helpers/plan-time"
  }
}

run "builtin_auth_recovery_is_off_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = !local.builtin_auth_recovery_open && !local.builtin_auth_recovery_expired
    error_message = "With builtin_auth_recovery_until unset, no recovery window may be open or reported as expired."
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == true
    error_message = "With builtin_auth_recovery_until unset, ca-frontend's gate must stay on."
  }
}

# With builtin_auth unset, neither the gate nor its alert exists: the module plans exactly what
# it planned before either input existed.
run "builtin_auth_unset_creates_no_auth_config_or_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azapi_resource.builtin_auth) == 0 &&
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write) == 0
    )
    error_message = "With builtin_auth unset, the module must create no auth configuration and no auth-configuration alert."
  }
}

# The api as a plan without builtin_auth_recovery_until sees it: the next run asserts the same
# values with the window open.
run "builtin_auth_recovery_baseline_api" {
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
    target = module.frontend
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name                      = "ca-frontend"
      fqdn                      = "ca-frontend.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = true
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = ["203.0.113.7/32"]
    }
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      length(module.api.ingress_allowed_ip_ranges) == 0
    )
    error_message = "Without the recovery window, ca-api must be internal, with no ip restrictions of its own."
  }

  assert {
    condition = nonsensitive(jsonencode(module.api.env_names)) == jsonencode([
      "MASTERLY_ALLOWED_REGIONS",
      "MASTERLY_ERASURE_BACKUP_RETENTION_DAYS",
      "MASTERLY_IDENTITY_BINDING",
      "MASTERLY_INSTALL_ID",
      "MASTERLY_MODE",
      "MASTERLY_ORG_ID",
      "MASTERLY_REGION",
    ])
    error_message = "Without the recovery window, ca-api's env must be the install's own settings and nothing about built-in authentication."
  }
}

# The window open, behind an allowlist: ca-frontend's gate is off, and nothing else moves.
# ca-api's ingress and env are the baseline run's, and no auth configuration names ca-api.
run "builtin_auth_recovery_opens_only_the_frontend_gate" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
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
      ingress_allowed_ip_ranges = ["203.0.113.7/32"]
    }
  }

  assert {
    condition     = local.builtin_auth_recovery_open && !local.builtin_auth_recovery_expired
    error_message = "A builtin_auth_recovery_until 30 minutes after the plan must open the recovery window."
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == false
    error_message = "With the recovery window open, ca-frontend's built-in authentication must be planned off."
  }

  # Only platform.enabled differs from the configuration without the window.
  assert {
    condition = (
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation) == jsonencode({
        unauthenticatedClientAction = "RedirectToLoginPage"
        excludedPaths               = []
        redirectToProvider          = "azureactivedirectory"
      }) &&
      azapi_resource.builtin_auth["frontend"].body.properties.identityProviders.azureActiveDirectory.registration.clientId == "22222222-2222-2222-2222-222222222222" &&
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["22222222-2222-2222-2222-222222222222"])
    )
    error_message = "The recovery window must change platform.enabled only; the rest of ca-frontend's configuration stays as it is without it."
  }

  assert {
    condition = (
      toset(keys(azapi_resource.builtin_auth)) == toset(["frontend"]) &&
      azapi_resource.builtin_auth["frontend"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
    )
    error_message = "The recovery window must touch ca-frontend's auth configuration only, and configure none on ca-api."
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      length(module.api.ingress_allowed_ip_ranges) == 0
    )
    error_message = "The recovery window must leave ca-api's ingress as it is without it: internal, with no ip restrictions of its own."
  }

  assert {
    condition = nonsensitive(jsonencode(module.api.env_names)) == jsonencode([
      "MASTERLY_ALLOWED_REGIONS",
      "MASTERLY_ERASURE_BACKUP_RETENTION_DAYS",
      "MASTERLY_IDENTITY_BINDING",
      "MASTERLY_INSTALL_ID",
      "MASTERLY_MODE",
      "MASTERLY_ORG_ID",
      "MASTERLY_REGION",
    ])
    error_message = "The recovery window must leave ca-api's env as it is without it (the baseline run's names)."
  }
}

# Threat: an open gate with no network restriction. An unrestricted, public frontend refuses
# the window.
run "builtin_auth_recovery_is_refused_without_a_network_restriction" {
  command = plan

  variables {
    ingress_allowed_cidrs      = []
    frontend_ingress_external  = true
    aca_internal_load_balancer = false
    identity_binding           = "oidc"
    oidc_allowed_issuers       = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience              = "api-client-id"
    oidc_jwks_uri              = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id             = "bff-client-id"
    oidc_client_secret         = "s3cret"
    oidc_authority             = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri          = "https://app.example.com/api/auth/callback"
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
  }

  expect_failures = [var.builtin_auth_recovery_until]
}

# Private ingress is a network restriction: an internal environment with no allowlist accepts
# the window.
run "builtin_auth_recovery_is_accepted_on_an_internal_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs      = []
    aca_internal_load_balancer = true
    identity_binding           = "oidc"
    oidc_allowed_issuers       = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience              = "api-client-id"
    oidc_jwks_uri              = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id             = "bff-client-id"
    oidc_client_secret         = "s3cret"
    oidc_authority             = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri          = "https://app.example.com/api/auth/callback"
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == false
    error_message = "On an internal environment, the recovery window must be accepted and turn ca-frontend's gate off."
  }
}

# So is a frontend with no ingress beyond the environment.
run "builtin_auth_recovery_is_accepted_with_private_frontend_ingress" {
  command = plan

  variables {
    ingress_allowed_cidrs     = []
    frontend_ingress_external = false
    identity_binding          = "oidc"
    oidc_allowed_issuers      = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience             = "api-client-id"
    oidc_jwks_uri             = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id            = "bff-client-id"
    oidc_client_secret        = "s3cret"
    oidc_authority            = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri         = "https://app.example.com/api/auth/callback"
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == false
    error_message = "With frontend_ingress_external = false, the recovery window must be accepted and turn ca-frontend's gate off."
  }
}

# Threat: a recovery input with no gate to turn off.
run "builtin_auth_recovery_is_refused_without_builtin_auth" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
  }

  expect_failures = [var.builtin_auth_recovery_until]
}

# Threat: a long or indefinite window. A time beyond 60 minutes after the plan is refused, with
# the message naming the limit (the validation's error_message in variables-builtin-auth.tf).
run "builtin_auth_recovery_is_refused_beyond_60_minutes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = "2099-01-01T00:00:00Z"
  }

  expect_failures = [var.builtin_auth_recovery_until]
}

# The limit itself: 59 minutes after the plan is accepted, 61 minutes is refused.
run "builtin_auth_recovery_accepts_59_minutes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time.in_59_minutes
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == false
    error_message = "A builtin_auth_recovery_until 59 minutes after the plan is within the limit and must turn ca-frontend's gate off."
  }
}

# 61 minutes falls back inside the window as time passes, so it is read from a plan taken
# directly before this run, not from plan_time, which the runs above have aged by then.
run "plan_time_for_61_minutes" {
  command = plan

  module {
    source = "./tests/helpers/plan-time"
  }
}

run "builtin_auth_recovery_refuses_61_minutes" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = run.plan_time_for_61_minutes.in_61_minutes
  }

  expect_failures = [var.builtin_auth_recovery_until]
}

run "builtin_auth_recovery_refuses_a_time_that_is_not_rfc3339" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = "2026-11-14 15:30"
  }

  expect_failures = [var.builtin_auth_recovery_until]
}

# A time that has passed: the plan turns the gate back on and warns that the input is stale.
run "builtin_auth_recovery_expired_restores_the_gate_and_warns" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret  = "test-only-not-a-secret"
    builtin_auth_recovery_until = "2020-01-01T00:00:00Z"
  }

  assert {
    condition     = !local.builtin_auth_recovery_open && local.builtin_auth_recovery_expired
    error_message = "A builtin_auth_recovery_until in the past must close the window and be reported as expired."
  }

  assert {
    condition     = azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == true
    error_message = "Once builtin_auth_recovery_until has passed, the plan must turn ca-frontend's gate back on."
  }

  expect_failures = [check.builtin_auth_recovery_window_has_expired]
}

# Every write to ca-frontend's auth configuration alerts: one activity-log alert, whenever
# builtin_auth is set, scoped to ca-frontend. The routing to the module's own action group
# (alert_email, the file-wide value here) is asserted in builtin_auth_alert_routing.tftest.hcl,
# because that group's id is known only after an apply.
run "builtin_auth_alerts_on_frontend_auth_config_writes" {
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
    target = module.frontend
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
      name                      = "ca-frontend"
      fqdn                      = "ca-frontend.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = true
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = ["203.0.113.7/32"]
    }
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write) == 1 &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].name == "alert-masterly-frontend-auth-config-write" &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].resource_group_name == azurerm_resource_group.aca.name &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].location == "global"
    )
    error_message = "builtin_auth must create one activity-log alert, alert-<prefix>-frontend-auth-config-write, beside the install's other app alerts."
  }

  assert {
    condition = (
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].criteria[0].category == "Administrative" &&
      azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].criteria[0].operation_name == "Microsoft.App/containerApps/authConfigs/write" &&
      toset(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].scopes) == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"])
    )
    error_message = "The alert must fire on Microsoft.App/containerApps/authConfigs/write, an Administrative operation, on ca-frontend alone."
  }
}

# With an action group given by id, the alert routes to it.
run "builtin_auth_alert_routes_to_a_given_action_group" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    alert_email           = null
    alert_action_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ops/providers/microsoft.insights/actionGroups/ag-ops"
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition = (
      length(azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action) == 1 &&
      contains([for a in azurerm_monitor_activity_log_alert.builtin_auth_config_write[0].action : a.action_group_id], var.alert_action_group_id)
    )
    error_message = "With alert_action_group_id set, the auth-configuration alert must route to it."
  }
}
