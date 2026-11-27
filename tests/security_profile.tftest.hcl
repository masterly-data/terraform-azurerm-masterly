# The security profile: what mode = "production" requires of the platform sign-in gate
# (builtin_auth, builtin_auth_opt_out), the frontend gate's exclusions in production, ca-api
# reachable from outside only through the edge (api_ingress_external), and every published app
# HTTPS only (variables-builtin-auth.tf, builtin-auth.tf, main.tf, edge.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's. Like the
# builtin_auth files, this one leaves builtin_auth_opt_out out of the block: its runs set the gate
# or the opt-out themselves.
#
# A refusal can only name the object it fails on; its message is read from the source, in the
# runs that plan, as app_placement.tftest.hcl does.

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

  ingress_allowed_cidrs = ["203.0.113.7/32"]
}

# --- Demo: no change -------------------------------------------------------------------------

# main's defaults: ca-api internal with the BFF's http:// hop, ca-frontend published HTTPS only,
# no api_url, and no built-in authentication.
run "demo_defaults_plan_as_before" {
  command = plan

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      module.api.ingress_allowed_ip_ranges == [] &&
      output.api_url == null
    )
    error_message = "In demo with main's defaults, ca-api must stay internal with the BFF's http:// hop, and api_url null, as before."
  }

  assert {
    condition     = module.frontend.ingress_external == true && module.frontend.ingress_allow_insecure == false
    error_message = "ca-frontend must stay published, HTTPS only."
  }

  assert {
    condition     = length(azapi_resource.builtin_auth) == 0 && length(local.builtin_auth_frontend_excluded_paths) == 0
    error_message = "In demo without builtin_auth, no app may get a built-in auth configuration."
  }
}

# builtin_auth in demo with frontend_excluded_paths unset: one configuration, on ca-frontend, that
# excludes no path, as before.
run "demo_builtin_auth_plans_as_before" {
  command = plan

  variables {
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition = (
      length(azapi_resource.builtin_auth) == 1 &&
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation.excludedPaths) == jsonencode([])
    )
    error_message = "In demo, builtin_auth with frontend_excluded_paths unset must configure ca-frontend alone, excluding no path, as before."
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      output.api_url == null &&
      module.frontend.ingress_allow_insecure == false
    )
    error_message = "In demo, builtin_auth must leave ca-api's and ca-frontend's ingress as before."
  }
}

# Demo still accepts any absolute paths, as before; production holds them to the start page below.
run "demo_excluded_paths_accept_another_page" {
  command = plan

  variables {
    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["/", "/login"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation.excludedPaths) == jsonencode(["/", "/login"])
    error_message = "In demo, frontend_excluded_paths = [\"/\", \"/login\"] must still be accepted and reach ca-frontend as given."
  }
}

# The opt-out is accepted in demo and changes nothing.
run "demo_opt_out_has_no_effect" {
  command = plan

  variables {
    builtin_auth_opt_out = { reason = "Evaluation install." }
  }

  assert {
    condition = (
      length(azapi_resource.builtin_auth) == 0 &&
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      output.api_url == null
    )
    error_message = "In demo, builtin_auth_opt_out must change nothing."
  }
}

# --- ca-api published without the edge ---------------------------------------------------------

# Threat: ca-api published without the edge, past ca-edge's token checks and the sign-in gate.
run "api_ingress_external_without_edge_is_refused_in_demo" {
  command = plan

  variables {
    api_ingress_external = true
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "api_ingress_external_without_edge_is_refused_in_production" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"

    api_ingress_external = true
  }

  # The refused plan would publish ca-api beside builtin_auth's gate on the frontend, so the
  # published-api warning fires too.
  expect_failures = [azurerm_resource_group.aca, check.builtin_auth_does_not_gate_the_published_api]
}

# --- With edge: ca-api internal whatever api_ingress_external says ----------------------------

# demo, edge, api_ingress_external unset. The refusals' messages are read here: the api one names
# edge and the edge_url output, the production one both inputs, and the opt-out warning quotes the
# reason.
run "demo_edge_keeps_the_api_internal" {
  command = plan

  variables {
    edge = {}
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      module.api.ingress_allowed_ip_ranges == [] &&
      output.api_url == null
    )
    error_message = "With edge set, ca-api must stay internal, with no allowlist of its own, and api_url null."
  }

  # Threat: a published app serves plain HTTP. Every app here with external ingress refuses it.
  assert {
    condition = alltrue([
      module.frontend.ingress_external ? module.frontend.ingress_allow_insecure == false : true,
      module.api.ingress_external ? module.api.ingress_allow_insecure == false : true,
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false,
    ])
    error_message = "Every published app (ca-frontend, ca-edge, and ca-api when external) must refuse plain HTTP."
  }

  assert {
    condition = (
      can(regex("error_message = \"api_ingress_external = true without edge would publish ca-api .*Set edge, and point .* at the edge_url output", file("${path.module}/main.tf"))) &&
      can(regex("error_message = \"mode = \\\\\"production\\\\\" requires builtin_auth or builtin_auth_opt_out", file("${path.module}/variables-builtin-auth.tf"))) &&
      can(regex("whose recorded reason is: \\\\\"\\$\\{try\\(var\\.builtin_auth_opt_out\\.reason", file("${path.module}/builtin-auth.tf"))) &&
      can(regex("error_message = \"api_ingress_external = true is ignored with edge set: .*edge_url", file("${path.module}/builtin-auth.tf")))
    )
    error_message = "The api refusal must name edge and edge_url, the production refusal both inputs, the opt-out warning the reason, and the ignored-input warning edge_url."
  }
}

run "demo_edge_ignores_api_ingress_external" {
  command = plan

  variables {
    edge                 = {}
    api_ingress_external = true
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      module.api.ingress_allowed_ip_ranges == [] &&
      output.api_url == null
    )
    error_message = "With edge set, api_ingress_external = true must be ignored: ca-api internal, api_url null."
  }

  assert {
    condition = alltrue([
      module.frontend.ingress_external ? module.frontend.ingress_allow_insecure == false : true,
      module.api.ingress_external ? module.api.ingress_allow_insecure == false : true,
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false,
    ])
    error_message = "Every published app (ca-frontend, ca-edge, and ca-api when external) must refuse plain HTTP."
  }

  expect_failures = [check.api_ingress_external_is_ignored_with_edge]
}

run "production_edge_keeps_the_api_internal" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"

    edge = {}
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      module.api.ingress_allowed_ip_ranges == [] &&
      output.api_url == null
    )
    error_message = "In production with edge set, ca-api must stay internal, with no allowlist of its own, and api_url null."
  }

  assert {
    condition = alltrue([
      module.frontend.ingress_external ? module.frontend.ingress_allow_insecure == false : true,
      module.api.ingress_external ? module.api.ingress_allow_insecure == false : true,
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false,
    ])
    error_message = "Every published app (ca-frontend, ca-edge, and ca-api when external) must refuse plain HTTP."
  }
}

run "production_edge_ignores_api_ingress_external" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"

    edge                 = {}
    api_ingress_external = true
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      module.api.ingress_allowed_ip_ranges == [] &&
      output.api_url == null
    )
    error_message = "In production with edge set, api_ingress_external = true must be ignored: ca-api internal, api_url null."
  }

  assert {
    condition = alltrue([
      module.frontend.ingress_external ? module.frontend.ingress_allow_insecure == false : true,
      module.api.ingress_external ? module.api.ingress_allow_insecure == false : true,
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false,
    ])
    error_message = "Every published app (ca-frontend, ca-edge, and ca-api when external) must refuse plain HTTP."
  }

  expect_failures = [check.api_ingress_external_is_ignored_with_edge]
}

# In the app environment ca-api keeps its VNet-only ingress (external on the internal app
# environment), HTTPS only, as on main.
run "api_in_app_keeps_its_vnet_only_https_ingress" {
  command = plan

  variables {
    edge                 = {}
    frontend_environment = "front"
    edge_environment     = "front"
    api_environment      = "app"
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
    condition     = module.api.ingress_external == true && module.api.ingress_allow_insecure == false && output.api_url == null
    error_message = "In the app environment ca-api must keep its VNet-only ingress, HTTPS only, and api_url null, as on main."
  }

  assert {
    condition = alltrue([
      module.frontend.ingress_external ? module.frontend.ingress_allow_insecure == false : true,
      module.api.ingress_external ? module.api.ingress_allow_insecure == false : true,
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false,
    ])
    error_message = "Every published app (ca-frontend, ca-edge, and ca-api when external) must refuse plain HTTP."
  }
}

# --- Production: the platform sign-in gate, or a recorded opt-out ------------------------------

# Threat: a production install runs with no platform gate and nothing records it.
run "production_without_builtin_auth_or_opt_out_is_refused" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.builtin_auth_opt_out]
}

# The opt-out lets the plan proceed, with no built-in authentication, and every plan warns.
run "production_opt_out_plans_and_warns" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth_opt_out = { reason = "Single sign-on is enforced by our own reverse proxy in front of the frontend." }
  }

  assert {
    condition     = length(azapi_resource.builtin_auth) == 0
    error_message = "With builtin_auth_opt_out, no app may get a built-in auth configuration."
  }

  expect_failures = [check.builtin_auth_opted_out_in_production]
}

run "opt_out_with_an_empty_reason_is_refused" {
  command = plan

  variables {
    builtin_auth_opt_out = { reason = "" }
  }

  expect_failures = [var.builtin_auth_opt_out]
}

run "opt_out_with_a_blank_reason_is_refused" {
  command = plan

  variables {
    builtin_auth_opt_out = { reason = "  \t " }
  }

  expect_failures = [var.builtin_auth_opt_out]
}

run "opt_out_with_builtin_auth_is_refused" {
  command = plan

  variables {
    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
    builtin_auth_opt_out       = { reason = "Both set by mistake." }
  }

  expect_failures = [var.builtin_auth_opt_out]
}

# --- Production: the frontend gate opens exactly the start page --------------------------------

# Threat: the frontend gate opens more than the start page. Unset, production excludes exactly /
# and /start.
run "production_excluded_paths_default_to_the_start_page" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      client_id = "22222222-2222-2222-2222-222222222222"
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation.excludedPaths) == jsonencode(["/", "/start"])
    error_message = "In production with frontend_excluded_paths unset, ca-frontend must exclude exactly / and /start."
  }

  assert {
    condition = (
      module.api.ingress_external == false &&
      module.api.ingress_allow_insecure == true &&
      output.api_url == null &&
      module.frontend.ingress_allow_insecure == false
    )
    error_message = "In production without edge, ca-api must stay internal and ca-frontend HTTPS only."
  }
}

run "production_excluded_paths_set_to_the_start_page_are_accepted" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["/", "/start"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.globalValidation.excludedPaths) == jsonencode(["/", "/start"])
    error_message = "In production, frontend_excluded_paths = [\"/\", \"/start\"] must reach ca-frontend as given."
  }
}

run "production_excluded_paths_with_another_page_are_refused" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["/", "/login"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.builtin_auth]
}

run "production_excluded_paths_with_a_wildcard_are_refused" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = ["/start/*"]
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.builtin_auth]
}

# An empty list would gate the start page too; production holds the gate to exactly / and /start.
run "production_excluded_paths_empty_are_refused" {
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
    migrations           = "job"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    builtin_auth = {
      tenant_id               = "11111111-1111-1111-1111-111111111111"
      client_id               = "22222222-2222-2222-2222-222222222222"
      frontend_excluded_paths = []
    }
    builtin_auth_client_secret = "test-only-not-a-secret"
  }

  expect_failures = [var.builtin_auth]
}
