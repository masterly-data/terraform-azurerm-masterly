# edge: ca-edge, the opt-in Envoy machine entry point (edge.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# The Envoy configuration is asserted from local.edge_envoy_config, the object the container's
# args carry. The last two pairs of runs apply against tests/mocks/migrate (ARM-shaped ids, so
# a plan against the applied state validates), under the alias "applied", and so come last.

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

mock_provider "azurerm" {
  alias  = "applied"
  source = "./tests/mocks/migrate"
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
}

# --- edge unset ------------------------------------------------------------------------------

# Unset (the default), the install plans exactly as before: no app, no identity, no grant.
run "edge_unset_plans_no_app_identity_or_grant" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  assert {
    condition = (
      length(azurerm_container_app.edge) == 0 &&
      length(module.edge_identity) == 0 &&
      length(azurerm_role_assignment.acr_pull_edge) == 0
    )
    error_message = "With edge unset the module must plan no ca-edge Container App, no edge identity and no edge role assignment."
  }

  assert {
    condition     = output.edge_url == null && output.edge_identity_principal_id == null
    error_message = "With edge unset, edge_url and edge_identity_principal_id must be null."
  }
}

# --- The app, its ingress and its allowlist --------------------------------------------------

run "edge_is_published_https_only_on_the_allowlist" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32", "198.51.100.0/24"]
  }

  # The environment's id is computed, so module.aca_env's environment is asserted in the apply run
  # edge_applied_with_one_digest (`override_during = plan` needs Terraform 1.11 while CI runs 1.10).
  assert {
    condition = (
      length(azurerm_container_app.edge) == 1 &&
      azurerm_container_app.edge[0].name == "ca-edge" &&
      azurerm_container_app.edge[0].resource_group_name == azurerm_resource_group.aca.name
    )
    error_message = "With edge set, ca-edge must be planned in the apps' resource group."
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].ingress[0].external_enabled == true &&
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false
    )
    error_message = "ca-edge's ingress must be external with allow_insecure_connections = false (http:// redirected, never served)."
  }

  assert {
    condition = (
      tolist([for r in azurerm_container_app.edge[0].ingress[0].ip_security_restriction : r.ip_address_range]) == tolist(var.ingress_allowed_cidrs) &&
      alltrue([for r in azurerm_container_app.edge[0].ingress[0].ip_security_restriction : r.action == "Allow"])
    )
    error_message = "ca-edge's IP restrictions must be exactly ingress_allowed_cidrs, each with action Allow."
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].ingress[0].target_port == local.edge_port &&
      local.edge_envoy_config.static_resources.listeners[0].address.socket_address.port_value == local.edge_port &&
      length(local.edge_envoy_config.static_resources.listeners) == 1
    )
    error_message = "Ingress must target the one Envoy listener's port."
  }

  # In the default placement (api_environment = "aca"); the app placement has its own run in
  # app_placement.tftest.hcl.
  assert {
    condition     = var.api_environment != "aca" || (local.edge_upstream == module.api.name && local.edge_upstream_host == module.api.name)
    error_message = "The edge must address ca-api by module.api's app name."
  }
}

# Threat: an edge open to the whole internet. Empty means UNRESTRICTED in Azure. With "oidc", so
# that identity_binding's own allowlist guard (the "dev" binding's) is not what refuses the plan.
run "edge_with_an_empty_allowlist_is_refused" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = []
    identity_binding      = "oidc"
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_redirect_uri     = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
  }

  expect_failures = [azurerm_container_app.edge]
}

# --- The image -------------------------------------------------------------------------------

run "edge_default_image_is_pinned_by_digest" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      can(regex("^[^@\\s]+@sha256:[0-9a-f]{64}$", local.edge_default_image)) &&
      azurerm_container_app.edge[0].template[0].container[0].image == local.edge_default_image
    )
    error_message = "ca-edge's default image must be a reference pinned by @sha256 digest."
  }

  # The shape alone admits a placeholder such as 64 zeros, which plans cleanly and never pulls.
  # A real sha256 digest spreads over the hex alphabet: one with fewer than 8 distinct characters
  # was typed, not read from the registry.
  assert {
    condition     = length(distinct(regexall("[0-9a-f]", split("@sha256:", local.edge_default_image)[1]))) >= 8
    error_message = "ca-edge's default image digest looks like a placeholder (too few distinct hex characters): pin the digest read from the registry."
  }

  assert {
    condition     = startswith(local.edge_default_image, "docker.io/envoyproxy/envoy:v")
    error_message = "ca-edge's default image must be the upstream envoyproxy/envoy on Docker Hub, with its release tag beside the digest."
  }
}

run "edge_image_without_a_digest_is_refused" {
  command = plan

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.40.2" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_image_without_a_registry_host_is_refused" {
  command = plan

  variables {
    edge                  = { image = "envoyproxy/envoy@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_body_limit_out_of_range_is_refused" {
  command = plan

  variables {
    edge                  = { max_request_body_bytes = 100 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

# Each rate limit input is a whole number in its range: a fraction, zero and a value past the top
# are refused.
run "edge_rate_limit_per_token_not_whole_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_token = 10.5 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_per_token_zero_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_token = 0 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_per_token_out_of_range_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_token = 1000001 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_per_client_not_whole_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_client = 10.5 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_per_client_zero_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_client = 0 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_per_client_out_of_range_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_per_client = 1000001 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_interval_not_whole_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_interval_seconds = 1.5 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_interval_zero_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_interval_seconds = 0 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

run "edge_rate_limit_interval_out_of_range_is_refused" {
  command = plan

  variables {
    edge                  = { rate_limit_interval_seconds = 3601 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [var.edge]
}

# --- The identity, and the only role it can hold ---------------------------------------------

# Threat: the public edge holding a data credential. Every data-plane grant the module makes is on
# (Key Vault, Service Bus, Entra Postgres and Redis, ACS email), and every identity is overridden
# with a distinct principal, so a grant to the edge's would compare equal.
run "edge_identity_is_its_own_and_holds_no_data_role" {
  command = plan

  variables {
    edge                           = {}
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    mode                           = "production"
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "test-only"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = jsonencode({ kty = "EC" })
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "job"
    database_auth                  = "entra"
    redis_auth                     = "entra"
    acr_login_server               = null
    acr_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_service_bus             = true
    servicebus_sku                 = "Standard"
    email_acs_enabled              = true
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  override_module {
    target  = module.edge_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].identity[0].type == "UserAssigned" &&
      tolist(azurerm_container_app.edge[0].identity[0].identity_ids) == tolist([module.edge_identity[0].id]) &&
      !contains([module.apps_identity.id, module.frontend_identity.id, module.workers_identity[0].id, module.migrate_identity[0].id], module.edge_identity[0].id)
    )
    error_message = "ca-edge's only user-assigned identity must be its own, distinct from the apps, frontend, workers and migrate identities."
  }

  assert {
    condition = alltrue(concat(
      [for r in azurerm_role_assignment.kv_app_secrets : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_crypto_officer : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_app_secrets_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_crypto_officer_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_officer_deployer : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_user_frontend : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_user_migrate : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_user_migrate_api_role_password : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_byo_database_reader_migrate : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.kv_secrets_reader : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_sender : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_receiver : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_sender_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_receiver_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_scaler : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.sb_scaler_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.acs_email_sender : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.acs_email_sender_workers : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.frontend_certificate_reader : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_role_assignment.edge_certificate_reader : r.principal_id != module.edge_identity[0].principal_id],
      [for r in azurerm_postgresql_flexible_server_active_directory_administrator.apps : r.object_id != module.edge_identity[0].principal_id],
      [for r in azurerm_postgresql_flexible_server_active_directory_administrator.migrate : r.object_id != module.edge_identity[0].principal_id],
      [for r in azurerm_managed_redis_access_policy_assignment.apps : r.object_id != module.edge_identity[0].principal_id],
      [for r in azurerm_managed_redis_access_policy_assignment.workers : r.object_id != module.edge_identity[0].principal_id],
      [for r in azurerm_redis_cache_access_policy_assignment.apps : r.object_id != module.edge_identity[0].principal_id],
      [for r in azurerm_redis_cache_access_policy_assignment.workers : r.object_id != module.edge_identity[0].principal_id],
    ))
    error_message = "No Key Vault, Service Bus, Postgres, Redis or email grant may name ca-edge's principal."
  }

  # The grants above exist in this run, so the check is not vacuous.
  assert {
    condition = (
      length(azurerm_role_assignment.kv_app_secrets) > 0 &&
      length(azurerm_role_assignment.sb_sender) > 0 &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) > 0 &&
      length(azurerm_managed_redis_access_policy_assignment.apps) > 0
    )
    error_message = "This run must turn on the Key Vault, Service Bus, Entra Postgres and Entra Redis grants it checks."
  }

  # The default image is on Docker Hub, not local.registry_server: no registry login, no grant,
  # even with acr_id set.
  assert {
    condition = (
      local.registry_server == "masterly.azurecr.io" &&
      length(azurerm_role_assignment.acr_pull_edge) == 0 &&
      length(azurerm_container_app.edge[0].registry) == 0
    )
    error_message = "An edge image off the install's registry must get no AcrPull grant and no registry block."
  }

  assert {
    condition = (
      length(azurerm_container_app.edge[0].secret) == 0 &&
      length(azurerm_container_app.edge[0].template[0].container[0].env) == 0
    )
    error_message = "ca-edge must declare no secrets and no env."
  }

  # The rate limits keep their state on each replica (ADR 0120 §5): no rate-limit service, no
  # cluster beside ca-api, no Redis, and no second app or grant for the edge, with Redis on here.
  assert {
    condition = (
      [for c in local.edge_envoy_config.static_resources.clusters : c.name] == ["ca-api"] &&
      !strcontains(jsonencode(local.edge_envoy_config), "\"envoy.filters.http.ratelimit\"") &&
      !strcontains(jsonencode(local.edge_envoy_config), "rate_limit_service") &&
      !strcontains(jsonencode(local.edge_envoy_config), "grpc_service") &&
      !strcontains(lower(jsonencode(local.edge_envoy_config)), "redis") &&
      length(azurerm_container_app.edge) == 1 &&
      length(module.edge_identity) == 1 &&
      length(azurerm_role_assignment.acr_pull_edge) == 0
    )
    error_message = "The rate limits must add no rate-limit service, no cluster but ca-api, no Redis reference, and no app, identity or grant for the edge."
  }
}

run "edge_identity_is_named_for_the_edge" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.edge_identity[0].name == "id-masterly-edge"
    error_message = "ca-edge's identity must be id-<prefix>-edge."
  }
}

# A mirror on the install's registry: the edge logs in as its own identity, and that identity gets
# AcrPull there, and nothing else.
run "edge_image_on_the_install_registry_gets_acr_pull" {
  command = plan

  variables {
    edge                  = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  override_module {
    target  = module.edge_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
  }

  assert {
    condition = (
      length(azurerm_role_assignment.acr_pull_edge) == 1 &&
      azurerm_role_assignment.acr_pull_edge[0].role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull_edge[0].scope == var.acr_id &&
      azurerm_role_assignment.acr_pull_edge[0].principal_id == module.edge_identity[0].principal_id
    )
    error_message = "An edge image on local.registry_server must get AcrPull for ca-edge's own identity on acr_id."
  }

  assert {
    condition = (
      length(azurerm_container_app.edge[0].registry) == 1 &&
      azurerm_container_app.edge[0].registry[0].server == "masterly.azurecr.io" &&
      azurerm_container_app.edge[0].registry[0].identity == module.edge_identity[0].id
    )
    error_message = "An edge image on local.registry_server must be pulled as ca-edge's own identity."
  }
}

# The token credential is an app secret, and ca-edge holds none: refused rather than half-wired.
run "edge_image_on_a_token_registry_is_refused" {
  command = plan

  variables {
    edge                  = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    registry_token        = { username = "00000000-0000-0000-0000-000000000001", password = "test-only" }
  }

  expect_failures = [azurerm_container_app.edge]
}

# --- The Envoy configuration -----------------------------------------------------------------

run "edge_routes_only_v1_and_mcp_to_ca_api" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  # Only /v1 and /mcp (and the paths under them) reach a cluster, all the same one: the prefix
  # routes, and the serve routes, each a path under /v1/ (their own runs below).
  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match if contains(keys(r), "route") && !startswith(r.name, "serve-")] == [{ path_separated_prefix = "/v1" }, { path_separated_prefix = "/mcp" }] &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if contains(keys(r), "route") && startswith(r.name, "serve-")]) == length(local.edge_serve_routes) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : startswith(try(r.match.path, ""), "/v1/") || startswith(try(r.match.safe_regex.regex, ""), "^/v1/") if contains(keys(r), "route") && startswith(r.name, "serve-")]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.cluster == "ca-api" && (var.api_environment != "aca" || r.route.host_rewrite_literal == "ca-api") if contains(keys(r), "route")])
    )
    error_message = "Only the prefixes /v1 and /mcp, and the serve routes' paths under /v1/, may route to a cluster, the ca-api cluster, with Host rewritten to ca-api in the default placement."
  }

  # Every other route answers itself, and the last one is the catch-all 404.
  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : contains(keys(r), "direct_response") if !contains(keys(r), "route")]) &&
      length(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts) == 1 &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].domains == ["*"] &&
      reverse(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes)[0].match == { prefix = "/" } &&
      reverse(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes)[0].direct_response.status == 404 &&
      !contains(keys(reverse(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes)[0]), "route")
    )
    error_message = "Any path other than /v1 and /mcp must be answered 404 by a direct_response, never reach the cluster."
  }

  # Until ca-serve passes its gate, the serve routes' cluster is ca-api's.
  assert {
    condition     = local.edge_serve_cluster == "ca-api" && local.edge_serve_cluster == local.edge_upstream
    error_message = "Until ca-serve passes its gate, the serve routes' cluster must be ca-api, the edge's one cluster."
  }

  # The one cluster: in the default placement (api_environment = "aca"), ca-api by app name, port
  # 80, plain http (no transport socket). The app placement's TLS cluster has its own run in
  # app_placement.tftest.hcl.
  assert {
    condition = (
      length(local.edge_envoy_config.static_resources.clusters) == 1 &&
      local.edge_envoy_config.static_resources.clusters[0].name == "ca-api" &&
      (var.api_environment != "aca" || (
        local.edge_envoy_config.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address == { address = "ca-api", port_value = 80 } &&
        !contains(keys(local.edge_envoy_config.static_resources.clusters[0]), "transport_socket")
      ))
    )
    error_message = "In the default placement the cluster must address ca-api by app name over plain http on port 80."
  }

  # Routing reads the normalized path, so a dot segment cannot climb out of /v1.
  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.normalize_path == true &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.merge_slashes == true &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.path_with_escaped_slashes_action == "REJECT_REQUEST"
    )
    error_message = "The edge must route on the normalized path and refuse encoded slashes."
  }
}

# --- The ca-serve routes ---------------------------------------------------------------------
# edge-serve-routes.json, read at plan time: one route per entry, matched on method and path, after
# the 413 guards and before v1, all still forwarded to ca-api.

run "edge_renders_each_serve_route_once_to_ca_api" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(local.edge_serve_routes) > 0 &&
      length(local.edge_serve_routes) == length(jsondecode(file("${path.module}/edge-serve-routes.json")).routes) &&
      alltrue([for e in local.edge_serve_routes : length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if r.name == "serve-${e.method} ${e.path}"]) == 1]) &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if startswith(r.name, "serve-")]) == length(local.edge_serve_routes)
    )
    error_message = "Each entry of edge-serve-routes.json must be exactly one route, named serve-<method> <path>, and there must be no other serve route."
  }

  # Matched on the method, exactly, and on the path: exactly for a literal path, by an anchored
  # regex for a template. Nothing else in the match.
  assert {
    condition = alltrue(flatten([for e in local.edge_serve_routes : [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
      strcontains(e.path, "{") ? (
        r.match == {
          headers    = [{ name = ":method", string_match = { exact = e.method } }]
          safe_regex = { regex = "^${replace(e.path, "/\\{[a-z_]+\\}/", "[^/:]+")}$" }
        }
        ) : (
        r.match == {
          headers = [{ name = ":method", string_match = { exact = e.method } }]
          path    = e.path
        }
      )
    ) if r.name == "serve-${e.method} ${e.path}"]]))
    error_message = "Each serve route must match a :method header exactly and its path: path for a literal path, an anchored safe_regex (each {var} as [^/:]+) for a template, and nothing else."
  }

  # The forwarded route, unchanged but for the cluster, which is still ca-api: the same Host,
  # timeout and rate-limit descriptors as v1.
  assert {
    condition = alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
      r.route == merge(local.edge_forwarded_route, { cluster = "ca-api" }) &&
      r.route == local.edge_forwarded_route &&
      r.route.cluster == "ca-api" &&
      !contains(keys(r), "direct_response")
    ) if startswith(r.name, "serve-")])
    error_message = "Each serve route's route must be local.edge_forwarded_route with cluster ca-api."
  }

  # Each {var} is one segment without a ':', so a template matches only what it says.
  assert {
    condition = (
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match.safe_regex.regex if r.name == "serve-GET /v1/consume/products/{product_id}"]) == "^/v1/consume/products/[^/:]+$" &&
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match.safe_regex.regex if r.name == "serve-POST /v1/consume/products/{product_id}:read"]) == "^/v1/consume/products/[^/:]+:read$" &&
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match.path if r.name == "serve-POST /v1/golden:search"]) == "/v1/golden:search"
    )
    error_message = "{product_id} must render as [^/:]+ inside an anchored regex, and a literal path such as /v1/golden:search must be matched exactly."
  }
}

# The order: the 413 guards first, so an oversized declared body on a serve path is still answered
# 413; then the serve routes; then v1, which takes every other /v1 request; mcp; the 404.
run "edge_orders_serve_routes_after_the_413_guards_and_before_v1" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = tolist([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name]) == tolist(concat(
      ["request-too-large", "request-too-large-beyond-int64"],
      [for e in local.edge_serve_routes : "serve-${e.method} ${e.path}"],
      ["v1", "mcp", "not-found"],
    ))
    error_message = "The routes must be, in order: request-too-large, request-too-large-beyond-int64, the serve routes in the file's order, v1, mcp, not-found."
  }

  # The file's order is the source's, (path, method): a space sorts below every path character.
  assert {
    condition     = tolist([for e in local.edge_serve_routes : "${e.path} ${e.method}"]) == sort([for e in local.edge_serve_routes : "${e.path} ${e.method}"])
    error_message = "edge-serve-routes.json must list its entries sorted by (path, method), as the backend's edge-routes.json does."
  }
}

# Threat: a write routed as a read. Every serve route matches GET or POST exactly (the POSTs are
# reads that take a body), never PUT, PATCH or DELETE. Any other method on a serve path, a write
# or a HEAD, matches no serve route and falls through to v1, which matches every method.
run "edge_serve_routes_match_only_reads" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      alltrue([for e in local.edge_serve_routes : contains(["GET", "POST"], e.method)]) &&
      !anytrue([for e in local.edge_serve_routes : contains(["PUT", "PATCH", "DELETE"], upper(e.method))]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        r.match.headers == [{ name = ":method", string_match = { exact = "GET" } }] ||
        r.match.headers == [{ name = ":method", string_match = { exact = "POST" } }]
      ) if startswith(r.name, "serve-")])
    )
    error_message = "Every serve route must match exactly one method, GET or POST, and none PUT, PATCH or DELETE: a write must never be routed as a read."
  }

  assert {
    condition = (
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match if r.name == "v1"]) == { path_separated_prefix = "/v1" } &&
      index([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name], "v1") == 2 + length(local.edge_serve_routes)
    )
    error_message = "The v1 route must follow every serve route and match /v1 on any method, so a request no serve route matches still reaches ca-api as before."
  }
}

# Threat: a matcher looser than its template, opening a path the edge answers 404 today. Each regex
# is anchored at both ends under /v1/, with no wildcard, and each {var} matches one segment
# without a ':'; each literal path is under /v1/.
run "edge_serve_route_matchers_are_no_looser_than_their_paths" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
      startswith(r.match.safe_regex.regex, "^/v1/") &&
      endswith(r.match.safe_regex.regex, "$") &&
      !strcontains(r.match.safe_regex.regex, ".*") &&
      !strcontains(r.match.safe_regex.regex, ".+") &&
      !strcontains(r.match.safe_regex.regex, "{") &&
      !strcontains(r.match.safe_regex.regex, "}")
    ) if startswith(r.name, "serve-") && contains(keys(r.match), "safe_regex")])
    error_message = "Every serve safe_regex must start with ^/v1/, end with $, contain no .* or .+, and have no {var} left unrendered."
  }

  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : startswith(r.match.path, "/v1/") if startswith(r.name, "serve-") && contains(keys(r.match), "path")]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : length(setintersection(keys(r.match), ["prefix", "path_separated_prefix", "path_match_policy"])) == 0 if startswith(r.name, "serve-")])
    )
    error_message = "Every literal serve path must start with /v1/, and no serve route may match on a prefix."
  }

  # What a template matches, by RE2 (Terraform's regex engine, and Envoy's): one value per {var};
  # not a value with a '/' or a ':', not an empty one, and nothing before or after the path.
  assert {
    condition = alltrue(flatten([for e in local.edge_serve_routes : [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
      can(regex(r.match.safe_regex.regex, replace(e.path, "/\\{[a-z_]+\\}/", "p-1"))) &&
      !can(regex(r.match.safe_regex.regex, replace(e.path, "/\\{[a-z_]+\\}/", "a/b"))) &&
      !can(regex(r.match.safe_regex.regex, replace(e.path, "/\\{[a-z_]+\\}/", "a:b"))) &&
      !can(regex(r.match.safe_regex.regex, replace(e.path, "/\\{[a-z_]+\\}/", ""))) &&
      !can(regex(r.match.safe_regex.regex, "${replace(e.path, "/\\{[a-z_]+\\}/", "p-1")}/x")) &&
      !can(regex(r.match.safe_regex.regex, "/x${replace(e.path, "/\\{[a-z_]+\\}/", "p-1")}"))
    ) if r.name == "serve-${e.method} ${e.path}" && strcontains(e.path, "{")]]))
    error_message = "Each serve regex must match its template with one segment per {var}, and refuse a value with a / or a :, an empty value, and anything before or after the path."
  }

  # GET .../{product_id} does not also take the action paths beside it.
  assert {
    condition = (
      !can(regex(one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match.safe_regex.regex if r.name == "serve-GET /v1/consume/products/{product_id}"]), "/v1/consume/products/p-1:read")) &&
      !can(regex(one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match.safe_regex.regex if r.name == "serve-GET /v1/consume/products/{product_id}"]), "/v1/consume/products/p-1/changes"))
    )
    error_message = "The regex for GET /v1/consume/products/{product_id} must not match /v1/consume/products/<id>:read or /v1/consume/products/<id>/changes."
  }
}

# Threat: the edge forwarding unverified across environments. With ca-api in the app environment
# (app_placement.tftest.hcl), the one cluster targets ca-api.<app default domain>:443 through an
# UpstreamTlsContext that sends the host as SNI, checks the chain against a CA bundle file and
# checks that the certificate names the host; every forwarded route sends that host.
run "edge_forwards_to_ca_api_in_app_over_verified_tls" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  assert {
    condition = (
      length(local.edge_envoy_config.static_resources.clusters) == 1 &&
      local.edge_envoy_config.static_resources.clusters[0].name == "ca-api" &&
      local.edge_envoy_config.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address == { address = "ca-api.app-3c4d.swedencentral.azurecontainerapps.io", port_value = 443 } &&
      local.edge_envoy_config.static_resources.clusters[0].transport_socket.name == "envoy.transport_sockets.tls" &&
      local.edge_envoy_config.static_resources.clusters[0].transport_socket.typed_config["@type"] == "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext" &&
      local.edge_envoy_config.static_resources.clusters[0].transport_socket.typed_config.sni == "ca-api.app-3c4d.swedencentral.azurecontainerapps.io" &&
      local.edge_envoy_config.static_resources.clusters[0].transport_socket.typed_config.common_tls_context.validation_context.trusted_ca == { filename = "/etc/ssl/certs/ca-certificates.crt" } &&
      local.edge_envoy_config.static_resources.clusters[0].transport_socket.typed_config.common_tls_context.validation_context.match_typed_subject_alt_names == [{ san_type = "DNS", matcher = { exact = "ca-api.app-3c4d.swedencentral.azurecontainerapps.io" } }]
    )
    error_message = "With ca-api in app, the edge's cluster must target ca-api.<app default domain>:443 with an UpstreamTlsContext: sni the host, trusted_ca the CA bundle file, and the host as the subject alternative name."
  }

  assert {
    condition = (
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if contains(keys(r), "route")]) == 2 + length(local.edge_serve_routes) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.cluster == "ca-api" && r.route.host_rewrite_literal == "ca-api.app-3c4d.swedencentral.azurecontainerapps.io" if contains(keys(r), "route")])
    )
    error_message = "With ca-api in app, every forwarded route's host_rewrite_literal must be ca-api.<app default domain>."
  }

  # The serve routes send the Host the v1 route sends: they are the same forwarded route.
  assert {
    condition = (
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if startswith(r.name, "serve-")]) == length(local.edge_serve_routes) &&
      length(local.edge_serve_routes) > 0 &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        r.route.cluster == "ca-api" &&
        r.route.host_rewrite_literal == "ca-api.app-3c4d.swedencentral.azurecontainerapps.io" &&
        r.route == one([for v in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : v.route if v.name == "v1"])
      ) if startswith(r.name, "serve-")])
    )
    error_message = "With ca-api in app, every serve route must send Host ca-api.<app default domain> to the ca-api cluster, as the v1 route does."
  }

  # The Location rewrite names the app environment's ca-api host, from local.edge_upstream_host.
  assert {
    condition = (
      strcontains(local.edge_location_rewrite_lua, "\"https://ca-api.app-3c4d.swedencentral.azurecontainerapps.io\"") &&
      strcontains(local.edge_location_rewrite_lua, "\"http://ca-api.app-3c4d.swedencentral.azurecontainerapps.io\"") &&
      !strcontains(local.edge_location_rewrite_lua, "\"http://ca-api\"")
    )
    error_message = "With ca-api in app, the Location rewrite must match ca-api.<app default domain>, not the same-environment name."
  }

  # The stat prefixes stay the two the edge always had: the TLS context adds none.
  assert {
    condition     = toset(flatten(regexall("\"stat_prefix\":\"([^\"]*)\"", jsonencode(local.edge_envoy_config)))) == toset(["edge", "edge_rate_limit"])
    error_message = "The upstream TLS context must add no stat prefix."
  }
}

# Threat: the edge discloses ca-api's internal host, and a bare /mcp is redirected to it. Exactly /mcp
# is forwarded as /mcp/ on the mcp route only, and a Location naming the upstream host is made
# relative by a response-headers-only Lua filter keyed to local.edge_upstream_host.
run "edge_rewrites_bare_mcp_and_upstream_locations" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.regex_rewrite if r.name == "mcp"]) == { pattern = { regex = "^/mcp$" }, substitution = "/mcp/" } &&
      can(regex(local.edge_mcp_bare_path_rewrite.pattern.regex, "/mcp")) &&
      !can(regex(local.edge_mcp_bare_path_rewrite.pattern.regex, "/mcp/")) &&
      !can(regex(local.edge_mcp_bare_path_rewrite.pattern.regex, "/mcp/x")) &&
      !can(regex(local.edge_mcp_bare_path_rewrite.pattern.regex, "/mcpx")) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : length(setintersection(keys(r.route), ["regex_rewrite", "prefix_rewrite", "path_rewrite_policy"])) == 0 if contains(keys(r), "route") && r.name != "mcp"])
    )
    error_message = "Only the mcp route may rewrite the path, and only exactly /mcp to /mcp/."
  }

  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters[1] == {
        name         = "envoy.filters.http.lua"
        typed_config = { "@type" = "type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua", default_source_code = { inline_string = local.edge_location_rewrite_lua } }
      } &&
      strcontains(local.edge_location_rewrite_lua, "\"http://ca-api\"") &&
      strcontains(local.edge_location_rewrite_lua, "\"https://ca-api\"") &&
      strcontains(local.edge_location_rewrite_lua, "string.lower(location)") &&
      strcontains(local.edge_location_rewrite_lua, "headers:replace(\"location\", rest)") &&
      strcontains(local.edge_location_rewrite_lua, "if rest == nil then\n    return\n  end") &&
      strcontains(local.edge_location_rewrite_lua, "elseif first ~= \"/\" then") &&
      length(regexall("headers:remove\\(\"location\"\\)", local.edge_location_rewrite_lua)) == 2 &&
      length(regexall("(?i)body|envoy_on_request|%|authorization", local.edge_location_rewrite_lua)) == 0
    )
    error_message = "Between the rate limiter and the router, a Lua filter must rewrite only a response Location naming ca-api's upstream host, case-insensitively, and read no body. Any other Location is left as it is."
  }
}

# Threat: a caller injecting an identity header ca-api would trust.
run "edge_strips_identity_headers_and_keeps_authorization" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = toset(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_remove) == toset([
      "x-jwt-payload",
      "x-ms-client-principal",
      "x-ms-client-principal-id",
      "x-ms-client-principal-idp",
      "x-ms-client-principal-name",
    ])
    error_message = "The edge must remove x-jwt-payload and every X-MS-CLIENT-PRINCIPAL* header (bare, -ID, -IDP, -NAME) from every request."
  }

  assert {
    condition     = local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.common_http_protocol_options.headers_with_underscores_action == "DROP_HEADER"
    error_message = "Headers with underscores (x_ms_client_principal) must be dropped, so no server folds one into a removed name."
  }

  # Authorization is neither removed nor rewritten anywhere: no header is added or removed except
  # the list above. The configuration names it only as the header the per-token rate limit reads,
  # once on each forwarded route (the serve routes, v1 and mcp).
  assert {
    condition = (
      !contains([for h in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_remove : lower(h)], "authorization") &&
      length(setintersection(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config), ["request_headers_to_add", "response_headers_to_add"])) == 0 &&
      length(setintersection(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0]), ["request_headers_to_add", "request_headers_to_remove"])) == 0 &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : length(setintersection(keys(r), ["request_headers_to_add", "request_headers_to_remove"])) == 0]) &&
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.rate_limits[0].actions[0].request_headers.header_name if contains(keys(r), "route")] == [for i in range(2 + length(local.edge_serve_routes)) : "authorization"] &&
      length(regexall("(?i)authorization", jsonencode(local.edge_envoy_config))) == 2 + length(local.edge_serve_routes)
    )
    error_message = "The edge must not remove or rewrite the Authorization header; the configuration may name it only as the per-token rate limit's header on the forwarded routes (the serve routes, /v1 and /mcp)."
  }
}

run "edge_refuses_oversized_bodies_and_does_not_cut_streams" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  # First match wins: a declared body over the limit gets 413 before any forwarding route.
  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[0].direct_response.status == 413 &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[0].match.prefix == "/" &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[0].match.headers[0].name == "content-length" &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[0].match.headers[0].range_match.start == 10485761 &&
      local.edge_max_request_body_bytes == 10485760
    )
    error_message = "A request with Content-Length above the limit (10 MiB by default) must be answered 413 by the first route."
  }

  # The guard has no ceiling a declared size can climb over: the range runs to the int64
  # maximum (exclusive, quoted so no double rounds it), and the second route refuses every value
  # of 19 digits or more, which covers the int64 maximum itself and anything an int64 cannot hold.
  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[0].match.headers[0].range_match.end == "9223372036854775807" &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].direct_response.status == 413 &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].match.prefix == "/" &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].match.headers == [{ name = "content-length", string_match = { safe_regex = { regex = "^[0-9]{19,}$" } } }] &&
      can(regex(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].match.headers[0].string_match.safe_regex.regex, "9223372036854775807")) &&
      can(regex(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].match.headers[0].string_match.safe_regex.regex, "18446744073709551615")) &&
      !can(regex(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes[1].match.headers[0].string_match.safe_regex.regex, "1073741824"))
    )
    error_message = "A Content-Length of any size above the limit must be answered 413: the range must end at the int64 maximum and the second route must refuse every value of 19 digits or more."
  }

  # Nothing buffers a forwarded body or response: the rate limiter, the header-only Lua Location
  # rewrite and the router are the only HTTP filters, and the only per-filter configuration is the
  # rate limiter's: on the virtual host, on mcp, and (turned off) on the 413 and 404 routes.
  assert {
    condition = (
      [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.local_ratelimit", "envoy.filters.http.lua", "envoy.filters.http.router"] &&
      tolist(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config)) == tolist(["envoy.filters.http.local_ratelimit"]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : tolist(keys(r.typed_per_filter_config)) == tolist(["envoy.filters.http.local_ratelimit"]) if contains(keys(r), "typed_per_filter_config")]) &&
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if contains(keys(r), "typed_per_filter_config")] == ["request-too-large", "request-too-large-beyond-int64", "mcp", "not-found"] &&
      !strcontains(jsonencode(local.edge_envoy_config), "envoy.filters.http.buffer") &&
      !strcontains(local.edge_location_rewrite_lua, "body") &&
      !strcontains(local.edge_location_rewrite_lua, "envoy_on_request")
    )
    error_message = "No envoy.filters.http.buffer filter may apply to the forwarded routes: the HTTP filters must be local_ratelimit, the header-only Lua Location rewrite, then the router, and only the virtual host, mcp and the 413 and 404 routes may carry per-filter configuration, the rate limiter's."
  }

  # No total cap on a forwarded request, and a finite idle timeout instead.
  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.timeout == "0s" if contains(keys(r), "route")]) &&
      can(regex("^[1-9][0-9]*s$", local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.stream_idle_timeout))
    )
    error_message = "Forwarded routes must have timeout 0s (no total cap) and the connection manager a finite, non-zero stream_idle_timeout."
  }
}

# Threat: a credential in a log or in the plan.
run "edge_logs_and_plan_carry_no_credential" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log[0].typed_config.log_format.json_format.path == "%REQ_WITHOUT_QUERY(:PATH)%" &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "AUTHORIZATION") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "COOKIE") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "%REQ(:PATH)%") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "ORIGINAL-PATH") &&
      toset(flatten(regexall("%REQ\\(([^)]+)\\)%", jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)))) == toset([":METHOD", "X-REQUEST-ID", "USER-AGENT"])
    )
    error_message = "The access log must hold no Authorization header, no cookie and no query string: the path without its query, and only the method, request id and user agent of the request headers."
  }

  assert {
    condition = (
      !issensitive(local.edge_envoy_config) &&
      !issensitive(azurerm_container_app.edge[0].template[0].container[0].args) &&
      azurerm_container_app.edge[0].template[0].container[0].args == tolist(["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]) &&
      length(coalesce(azurerm_container_app.edge[0].template[0].container[0].command, [])) == 0 &&
      length(azurerm_container_app.edge[0].secret) == 0 &&
      length(azurerm_container_app.edge[0].template[0].container[0].env) == 0 &&
      length(azurerm_container_app.edge[0].template[0].init_container) == 0
    )
    error_message = "The bootstrap and ca-edge's args and command must hold no secret value, and ca-edge must declare no secrets, env or init container."
  }

  # Threat: the bearer token, the per-token limit's key, written down. The access log reads no
  # credential header; every descriptor entry is a key with an empty value (Envoy fills it from the
  # request, in memory); every stat prefix is a literal; and nothing else reads a request header.
  assert {
    condition = (
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), upper(local.edge_credential_header)) &&
      local.edge_credential_header == "authorization" &&
      alltrue(flatten([for c in concat([local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config], [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config if contains(keys(r), "typed_per_filter_config")]) : [for d in try(c["envoy.filters.http.local_ratelimit"].descriptors, []) : [for e in d.entries : e.value == ""]]])) &&
      length(flatten([for c in concat([local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config], [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config if contains(keys(r), "typed_per_filter_config")]) : [for d in try(c["envoy.filters.http.local_ratelimit"].descriptors, []) : d.entries]])) == 4 &&
      toset(flatten(regexall("\"stat_prefix\":\"([^\"]*)\"", jsonencode(local.edge_envoy_config)))) == toset(["edge", "edge_rate_limit"]) &&
      length(regexall("%", jsonencode(local.edge_envoy_config))) == length(regexall("%", jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)))
    )
    error_message = "No credential header may reach the access log, a descriptor value or a stat prefix: descriptor entries must have empty values, stat prefixes must be the literals edge and edge_rate_limit, and only the access log may use a %...% command."
  }

  # No output is built from the Envoy configuration or the credential header. Read from the source,
  # comments stripped, because an output's value is not known at plan.
  assert {
    condition = (
      length(flatten([for f in fileset(path.module, "*.tf") : regexall("(?s)\\noutput \"[^\"]+\" \\{.*?\\n\\}", file("${path.module}/${f}"))])) > 0 &&
      anytrue(flatten([for f in fileset(path.module, "*.tf") : [for o in regexall("(?s)\\noutput \"[^\"]+\" \\{.*?\\n\\}", file("${path.module}/${f}")) : strcontains(o, "output \"edge_url\"")]])) &&
      alltrue(flatten([for f in fileset(path.module, "*.tf") : [for o in regexall("(?s)\\noutput \"[^\"]+\" \\{.*?\\n\\}", file("${path.module}/${f}")) : !strcontains(o, "edge_envoy_config") && !strcontains(o, "edge_credential_header") && !strcontains(o, "edge_forwarded_route") && !strcontains(o, "edge_rate_limit") && !strcontains(lower(replace(o, "/#[^\\n]*/", "")), "authorization")]]))
    )
    error_message = "No output may be built from local.edge_envoy_config, the rate limit locals or the credential header."
  }
}

# Threat: a public-facing proxy running as root. The bootstrap goes in args, not command, so the
# image's entrypoint (/docker-entrypoint.sh) runs and drops from root to the envoy user; a command
# would replace the entrypoint and Envoy would run as root.
run "edge_runs_through_the_image_entrypoint" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].template[0].container[0].args == tolist(["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]) &&
      length(coalesce(azurerm_container_app.edge[0].template[0].container[0].command, [])) == 0
    )
    error_message = "ca-edge must pass the bootstrap in args (envoy --config-yaml <bootstrap>) and set no command, so the image's entrypoint runs and drops Envoy from root to the envoy user."
  }

  # The entrypoint drops privileges unless ENVOY_UID is set to 0, and the envoy user can bind only
  # an unprivileged port.
  assert {
    condition = (
      length(azurerm_container_app.edge[0].template[0].container[0].env) == 0 &&
      local.edge_port >= 1024 &&
      local.edge_envoy_config.static_resources.listeners[0].address.socket_address.port_value == local.edge_port &&
      azurerm_container_app.edge[0].ingress[0].target_port == local.edge_port
    )
    error_message = "ca-edge must set no ENVOY_UID (no env at all), and its listener and ingress target must be an unprivileged port (1024 or above)."
  }
}

# Threat: a reachable control plane.
run "edge_has_no_admin_interface" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = !contains(keys(local.edge_envoy_config), "admin") && !strcontains(jsonencode(local.edge_envoy_config), "\"admin\"")
    error_message = "The Envoy bootstrap must configure no admin interface."
  }

  # The probes are TCP, so no health route was added to the public listener. Its routes are its
  # five fixed ones plus one serve route per entry of edge-serve-routes.json (ADR 0120 §2), each a
  # read under /v1/, and nothing else: no health, admin or other route (MAS-5191).
  assert {
    condition = (
      toset([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name]) == setunion(
        toset(["request-too-large", "request-too-large-beyond-int64", "v1", "mcp", "not-found"]),
        toset([for r in jsondecode(file("${path.module}/edge-serve-routes.json")).routes : "serve-${r.method} ${r.path}"])
      ) &&
      length(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes) == 5 + length(jsondecode(file("${path.module}/edge-serve-routes.json")).routes) &&
      alltrue([for r in jsondecode(file("${path.module}/edge-serve-routes.json")).routes : startswith(r.path, "/v1/") && contains(["GET", "HEAD", "POST"], r.method)]) &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if strcontains(lower(r.name), "health") || strcontains(lower(r.name), "admin")]) == 0
    )
    error_message = "The public listener must carry exactly its five fixed routes (request-too-large, request-too-large-beyond-int64, v1, mcp, not-found) plus one serve route per read in edge-serve-routes.json, each under /v1/; no health or admin route."
  }
}

run "edge_probes_tcp_on_the_listener_port" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azurerm_container_app.edge[0].template[0].container[0].liveness_probe) == 1 &&
      azurerm_container_app.edge[0].template[0].container[0].liveness_probe[0].transport == "TCP" &&
      azurerm_container_app.edge[0].template[0].container[0].liveness_probe[0].port == local.edge_port &&
      length(azurerm_container_app.edge[0].template[0].container[0].readiness_probe) == 1 &&
      azurerm_container_app.edge[0].template[0].container[0].readiness_probe[0].transport == "TCP" &&
      azurerm_container_app.edge[0].template[0].container[0].readiness_probe[0].port == local.edge_port &&
      local.edge_port == 8080
    )
    error_message = "ca-edge must declare TCP liveness and readiness probes on its listener port (8080)."
  }
}

# Ordering: with egress_firewall, ca-edge's first pull from Docker Hub already takes the firewall's
# route, as the other apps' do. `terraform test` cannot read depends_on, so this reads it: comments
# stripped, as in tests/network.tftest.hcl.
run "edge_follows_the_egress_firewall_association" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = strcontains(
      replace(
        regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)resource \"azurerm_container_app\" \"edge\" \\{(.*?)\\n\\}", file("${path.module}/edge.tf"))[0])[0],
        "/#[^\\n]*/", ""
      ),
      "azurerm_subnet_route_table_association.aca,"
    )
    error_message = "ca-edge must depend on azurerm_subnet_route_table_association.aca, so its first pull does not take Azure's default path before the firewall route is attached."
  }
}

# --- Rate limits -----------------------------------------------------------------------------
# Per bearer token and per client address, on /v1 and /mcp only, kept on each replica
# (local_ratelimit; ADR 0120 §5: no Redis and no rate-limit service). One limiter on the virtual
# host for v1 and the serve routes, which are /v1 requests; mcp's own; none on the 413 and 404.

run "edge_rate_limits_v1_and_mcp_per_token_and_per_client" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  # The limiter runs before the router, which stays last. Off at the filter level: only its
  # stat_prefix is set there, so Envoy enables it for no request a route does not turn it on for.
  assert {
    condition = (
      [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.local_ratelimit", "envoy.filters.http.lua", "envoy.filters.http.router"] &&
      reverse(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters)[0].name == "envoy.filters.http.router" &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters[0].typed_config == {
        "@type"     = "type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit"
        stat_prefix = "edge_rate_limit"
      }
    )
    error_message = "The HTTP filters must be envoy.filters.http.local_ratelimit (disabled at the filter level: stat_prefix only) then the Lua Location rewrite, then envoy.filters.http.router, last."
  }

  # Every forwarded route (the serve routes, v1 and mcp) produces a per-token descriptor (the
  # Authorization header's value, key "token") and a per-client one (the client address, key
  # "remote_address").
  assert {
    condition = (
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if contains(keys(r), "route")]) == 2 + length(local.edge_serve_routes) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.rate_limits == [
        { actions = [{ request_headers = { header_name = "authorization", descriptor_key = "token" } }] },
        { actions = [{ remote_address = {} }] },
      ] if contains(keys(r), "route")])
    )
    error_message = "Every forwarded route (the serve routes, v1 and mcp) must carry a per-token descriptor (request_headers on authorization, key token) and a per-client descriptor (remote_address)."
  }

  # The limiters, the virtual host's (v1 and the serve routes) and mcp's, turn the filter on for
  # every request, enforced.
  assert {
    condition = alltrue([for c in [
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config["envoy.filters.http.local_ratelimit"],
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]),
      ] : (
      [for d in c.descriptors : d.entries] == [[{ key = "token", value = "" }], [{ key = "remote_address", value = "" }]] &&
      c["@type"] == "type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit" &&
      c.filter_enabled.default_value == { numerator = 100, denominator = "HUNDRED" } &&
      c.filter_enforced.default_value == { numerator = 100, denominator = "HUNDRED" } &&
      c.always_consume_default_token_bucket == false &&
      c.max_dynamic_descriptors == local.edge_rate_limit_max_dynamic_descriptors &&
      local.edge_rate_limit_max_dynamic_descriptors >= 1
    )])
    error_message = "The virtual host's limiter (v1 and the serve routes) and mcp's must each key a per-token and a per-client descriptor, with the limiter enabled and enforced for 100% of requests and a bound on dynamic descriptors."
  }

  # The 413 and 404 answers are never limited: each of those routes carries the limiter turned off
  # (enabled for 0% of requests), so the virtual host's does not apply, and nothing else of it.
  assert {
    condition = (
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if contains(["v1", "mcp"], r.name)]) == 2 &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if contains(["request-too-large", "request-too-large-beyond-int64", "not-found"], r.name)]) == 3 &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        r.typed_per_filter_config == local.edge_rate_limit_off &&
        r.typed_per_filter_config["envoy.filters.http.local_ratelimit"].filter_enabled.default_value == { numerator = 0, denominator = "HUNDRED" } &&
        length(setintersection(keys(r.typed_per_filter_config["envoy.filters.http.local_ratelimit"]), ["filter_enforced", "descriptors", "response_headers_to_add"])) == 0 &&
        !contains(keys(r), "route") &&
        !strcontains(jsonencode(r), "rate_limits")
      ) if contains(["request-too-large", "request-too-large-beyond-int64", "not-found"], r.name)])
    )
    error_message = "request-too-large, request-too-large-beyond-int64 and not-found must each carry the rate limiter turned off (filter_enabled 0%), with no descriptors and no rate_limits: the 413 and 404 answers are never limited."
  }

  # Unset, each limit and the interval are the defaults the variable's description states.
  assert {
    condition = (
      local.edge_rate_limit_per_token == 600 &&
      local.edge_rate_limit_per_client == 1800 &&
      local.edge_rate_limit_interval_seconds == 60 &&
      tonumber(regex("rate_limit_per_token: .*?\\(default ([0-9]+);", file("${path.module}/edge.tf"))[0]) == local.edge_rate_limit_per_token &&
      tonumber(regex("rate_limit_per_client: .*?\\(default ([0-9]+);", file("${path.module}/edge.tf"))[0]) == local.edge_rate_limit_per_client &&
      tonumber(regex("rate_limit_interval_seconds: .*?\\(default ([0-9]+);", file("${path.module}/edge.tf"))[0]) == local.edge_rate_limit_interval_seconds &&
      strcontains(file("${path.module}/edge.tf"), format("description = \"Run ca-edge for SDK and MCP clients: 429 with Retry-After over rate_limit_per_token (%d) or rate_limit_per_client (%d) per rate_limit_interval_seconds (%d) per replica, so limits multiply by %d to %d running replicas. ", local.edge_rate_limit_per_token, local.edge_rate_limit_per_client, local.edge_rate_limit_interval_seconds, azurerm_container_app.edge[0].template[0].min_replicas, azurerm_container_app.edge[0].template[0].max_replicas))
    )
    error_message = "With no rate limit fields set, the limits must be the defaults the edge variable's description states: 600 per token, 1800 per client, per 60 seconds. Its first sentence must also name the refusal (429 with Retry-After) and the replicas the limits multiply by, 1 to 3."
  }

  # docs/inputs.md is generated from the description's first sentence (scripts/check_inputs_reference.py),
  # cut at 220 characters. The sentence checked above, with the defaults, the refusal and the replica
  # scaling, must fit, and the page's edge row must carry it whole.
  assert {
    condition = (
      length(regex("description = \"(Run ca-edge .*?\\.) ", file("${path.module}/edge.tf"))[0]) <= 220 &&
      strcontains(file("${path.module}/docs/inputs.md"), "| `edge` | `object(...)` | `null` | ${regex("description = \"(Run ca-edge .*?\\.) ", file("${path.module}/edge.tf"))[0]} |")
    )
    error_message = "docs/inputs.md's edge row must be the whole first sentence of the edge description, which names the three rate limit inputs and their defaults, 429 with Retry-After and the per-replica scaling; past 220 characters the generator cuts it short. Run python3 scripts/check_inputs_reference.py --write after changing the description."
  }

  assert {
    condition = alltrue([for c in [
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config["envoy.filters.http.local_ratelimit"],
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]),
      ] : (
      c.descriptors[0].token_bucket == { max_tokens = 600, tokens_per_fill = 600, fill_interval = "60s" } &&
      c.descriptors[1].token_bucket == { max_tokens = 1800, tokens_per_fill = 1800, fill_interval = "60s" } &&
      c.token_bucket == { max_tokens = 1800, tokens_per_fill = 1800, fill_interval = "60s" }
    )])
    error_message = "With no rate limit fields set, the token bucket must hold 600 requests per 60s, the client bucket and the limiter's own 1800 per 60s."
  }

  # Refused: 429 (envoy.type.v3.StatusCode TooManyRequests), with Retry-After of the interval in
  # whole seconds, added to refused responses only (the filter's own response_headers_to_add).
  assert {
    condition = alltrue([for c in [
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config["envoy.filters.http.local_ratelimit"],
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]),
      ] : (
      c.status == { code = "TooManyRequests" } &&
      length(c.response_headers_to_add) == 1 &&
      lower(c.response_headers_to_add[0].header.key) == "retry-after" &&
      can(regex("^[1-9][0-9]*$", c.response_headers_to_add[0].header.value)) &&
      tonumber(c.response_headers_to_add[0].header.value) <= local.edge_rate_limit_interval_seconds &&
      c.response_headers_to_add[0].header.value == "60" &&
      c.response_headers_to_add[0].append_action == "OVERWRITE_IF_EXISTS_OR_ADD"
    )])
    error_message = "A rate-limited request must be answered 429 (TooManyRequests) with a Retry-After header of the interval in whole seconds (60 by default)."
  }
}

# Threat: the serve routes escaping the rate limit, or diluting it. A route without its own
# per-filter configuration takes the virtual host's, one limiter object with one set of buckets,
# so the serve routes and v1 draw on one /v1 budget per token and per client, as /v1 did alone
# before. A copy on each serve route would give each its own buckets and multiply that budget by
# the number of routes; none at all would leave them unlimited, the filter being off. mcp keeps its
# own limiter, counted separately as documented.
run "edge_serve_routes_share_the_v1_rate_limit" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config == local.edge_rate_limit_per_route
    error_message = "The virtual host must carry the rate limiter (local.edge_rate_limit_per_route), the one limiter v1 and the serve routes share."
  }

  assert {
    condition = (
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if r.name == "v1" || startswith(r.name, "serve-")]) == 1 + length(local.edge_serve_routes) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : !contains(keys(r), "typed_per_filter_config") if r.name == "v1" || startswith(r.name, "serve-")])
    )
    error_message = "v1 and every serve route must carry no per-filter configuration of their own, so they take the virtual host's limiter: one /v1 budget, neither unlimited nor multiplied per route."
  }

  assert {
    condition = (
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config if r.name == "mcp"]) == local.edge_rate_limit_per_route &&
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if try(r.typed_per_filter_config["envoy.filters.http.local_ratelimit"].filter_enabled.default_value.numerator, 0) > 0] == ["mcp"]
    )
    error_message = "mcp must carry its own copy of the rate limiter, its own budget, and be the only route that turns a limiter of its own on."
  }

  assert {
    condition = alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
      r.typed_per_filter_config["envoy.filters.http.local_ratelimit"].filter_enabled.default_value.numerator == 0
    ) if contains(keys(r), "direct_response")])
    error_message = "Every route that answers itself (the 413 and 404 routes) must turn the limiter off, so those answers stay unlimited."
  }
}

run "edge_rate_limits_come_from_the_input" {
  command = plan

  variables {
    edge                  = { rate_limit_per_token = 7, rate_limit_per_client = 11, rate_limit_interval_seconds = 13 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      local.edge_rate_limit_per_token == 7 &&
      local.edge_rate_limit_per_client == 11 &&
      local.edge_rate_limit_interval_seconds == 13 &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if try(r.typed_per_filter_config["envoy.filters.http.local_ratelimit"].filter_enabled.default_value.numerator, 0) > 0]) == 1 &&
      alltrue([for c in [
        local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config["envoy.filters.http.local_ratelimit"],
        one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]),
        ] : (
        c.descriptors[0].token_bucket == { max_tokens = 7, tokens_per_fill = 7, fill_interval = "13s" } &&
        c.descriptors[1].token_bucket == { max_tokens = 11, tokens_per_fill = 11, fill_interval = "13s" } &&
        c.token_bucket == { max_tokens = 11, tokens_per_fill = 11, fill_interval = "13s" }
      )])
    )
    error_message = "The per-token limit, the per-client limit and the interval in the rendered buckets (the virtual host's limiter and mcp's) must come from edge.rate_limit_per_token, edge.rate_limit_per_client and edge.rate_limit_interval_seconds."
  }

  assert {
    condition = alltrue([for c in [
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config["envoy.filters.http.local_ratelimit"],
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]),
      ] : (
      c.response_headers_to_add[0].header.value == "13" &&
      tonumber(c.response_headers_to_add[0].header.value) <= var.edge.rate_limit_interval_seconds
    )])
    error_message = "Retry-After must be edge.rate_limit_interval_seconds, in whole seconds."
  }
}

# Threat: a forged client address, or one bucket for everyone. The Container Apps ingress appends
# the caller to X-Forwarded-For; exactly that one hop is trusted, so the rightmost entry keys the
# per-client limit. More would let a caller choose its address; none would key every caller on the
# ingress, in one bucket. With use_remote_address, Envoy reads the Nth entry from the right for N
# trusted hops (without it, the (N+1)th: one the caller wrote).
run "edge_trusts_exactly_the_ingress_hop_for_the_client_address" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.use_remote_address == true &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.xff_num_trusted_hops == 1 &&
      length(setintersection(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config), ["original_ip_detection_extensions", "internal_address_config"])) == 0 &&
      !strcontains(jsonencode(local.edge_envoy_config), "xff_trusted_cidrs")
    )
    error_message = "The connection manager must set use_remote_address = true and xff_num_trusted_hops = 1 (the ingress's hop, no more), with no other client-address detection."
  }

  # X-Forwarded-For and the caller's request id reach ca-api as they arrived.
  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.skip_xff_append == true &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.preserve_external_request_id == true
    )
    error_message = "The edge must forward X-Forwarded-For unchanged (skip_xff_append) and keep the caller's x-request-id (preserve_external_request_id)."
  }
}

# --- Token validation at the edge (edge.jwt_authn) ---------------------------------------------
# Off by default. Set, ca-edge validates the caller's bearer token on every forwarded route against
# the install's one Entra tenant (ADR 0117, ADR 0120 §2) before ca-api sees the request.

# Unset (with the tenant set, so the OIDC inputs alone change nothing), the edge renders exactly
# as before: no filter, no cluster and no per-route entry for it.
run "edge_jwt_authn_unset_renders_as_before" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      !local.edge_jwt_authn_enabled &&
      [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.local_ratelimit", "envoy.filters.http.lua", "envoy.filters.http.router"] &&
      [for c in local.edge_envoy_config.static_resources.clusters : c.name] == ["ca-api"] &&
      !strcontains(jsonencode(local.edge_envoy_config), "jwt_authn") &&
      !strcontains(jsonencode(local.edge_envoy_config), "login.microsoftonline.com")
    )
    error_message = "With edge.jwt_authn unset, the HTTP filters must be local_ratelimit, lua and the router, the only cluster ca-api, and the configuration must name no jwt_authn and no identity provider host."
  }

  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : !contains(keys(r), "typed_per_filter_config") if r.name == "v1" || startswith(r.name, "serve-")]) &&
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config if r.name == "mcp"]) == local.edge_rate_limit_per_route
    )
    error_message = "With edge.jwt_authn unset, v1 and the serve routes must carry no per-filter configuration and mcp only the rate limiter's, as before."
  }

  assert {
    condition = (
      strcontains(file("${path.module}/edge.tf"), "With jwt_authn unset (the default) it does no authentication") &&
      strcontains(file("${path.module}/edge.tf"), "# checks it. With edge.jwt_authn unset (the default) the edge does no authentication of its own.") &&
      !strcontains(file("${path.module}/edge.tf"), "It does no authentication yet") &&
      !strcontains(file("${path.module}/edge.tf"), "does no authentication of its own yet")
    )
    error_message = "The edge variable's description and edge.tf's header must say the edge does no authentication only with jwt_authn unset."
  }
}

run "edge_jwt_authn_runs_after_the_rate_limiter_and_before_the_router" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api", "api://masterly-mcp"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.local_ratelimit", "envoy.filters.http.jwt_authn", "envoy.filters.http.lua", "envoy.filters.http.router"]
    error_message = "With edge.jwt_authn set, the HTTP filters must be local_ratelimit, jwt_authn, lua and the router, in that order."
  }

  assert {
    condition     = one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config["@type"] if f.name == "envoy.filters.http.jwt_authn"]) == "type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication"
    error_message = "The jwt_authn filter must be Envoy's JwtAuthentication."
  }
}

# Threat: a token from any issuer other than the install's tenant accepted at the edge.
run "edge_jwt_authn_trusts_only_the_install_tenant" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      length(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers) == 1 &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).issuer == local.oidc_allowed_issuers &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).issuer == "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0" &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).remote_jwks.http_uri.uri == local.oidc_jwks_uri &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).remote_jwks.http_uri.uri == "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/discovery/v2.0/keys"
    )
    error_message = "The jwt_authn filter must have exactly one provider, whose issuer is oidc_allowed_issuers (the install's tenant) and whose keys are fetched from oidc_jwks_uri (that tenant's)."
  }

}

# Threat: a misconfigured issuer list widening trust. Each refused at plan, on the edge app.
run "edge_jwt_authn_without_an_issuer_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_two_issuers_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0,https://login.microsoftonline.com/66666666-7777-8888-9999-000000000000/v2.0"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_a_non_entra_issuer_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_allowed_issuers  = "https://idp.example.com/11111111-2222-3333-4444-555555555555/v2.0"
    oidc_jwks_uri         = "https://idp.example.com/11111111-2222-3333-4444-555555555555/discovery/v2.0/keys"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_a_multitenant_issuer_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_allowed_issuers  = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_a_v1_issuer_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_allowed_issuers  = "https://sts.windows.net/11111111-2222-3333-4444-555555555555/"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_without_a_jwks_uri_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_allowed_issuers  = "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_another_tenants_jwks_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_jwks_uri         = "https://login.microsoftonline.com/66666666-7777-8888-9999-000000000000/discovery/v2.0/keys"
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_jwt_authn_with_a_jwks_uri_on_another_host_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_jwks_uri         = "https://keys.example.com/11111111-2222-3333-4444-555555555555/discovery/v2.0/keys"
  }

  expect_failures = [azurerm_container_app.edge]
}

# Threat: a token from the install's tenant for another audience (Microsoft Graph) accepted.
run "edge_jwt_authn_audiences_come_from_the_input" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api", "api://masterly-mcp"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).audiences == var.edge.jwt_authn.audiences &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).audiences == tolist(["api://masterly-api", "api://masterly-mcp"])
    )
    error_message = "The provider's audiences must be edge.jwt_authn.audiences, exactly."
  }
}

run "edge_jwt_authn_with_no_audiences_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = [] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.edge]
}

run "edge_jwt_authn_with_an_empty_audience_is_refused" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api", ""] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.edge]
}

# Threat: a request with no token reaching ca-api, on a route without the requirement or through
# a rule that allows a missing or failed token.
run "edge_jwt_authn_requires_a_token_on_every_forwarded_route" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if contains(keys(r), "route")] == concat([for r in local.edge_serve_routes : "serve-${r.method} ${r.path}"], ["v1", "mcp"]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        r.typed_per_filter_config["envoy.filters.http.jwt_authn"] == {
          "@type"          = "type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.PerRouteConfig"
          requirement_name = one(keys(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).requirement_map))
        }
      ) if contains(keys(r), "route")])
    )
    error_message = "v1, every serve route and mcp must each carry a jwt_authn requirement naming the filter's one requirement."
  }

  assert {
    condition = (
      values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).requirement_map) == [{ provider_name = one(keys(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)) }] &&
      !contains(keys(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"])), "rules") &&
      !strcontains(jsonencode(local.edge_envoy_config), "allow_missing") &&
      !strcontains(jsonencode(local.edge_envoy_config), "allow_missing_or_failed") &&
      !strcontains(jsonencode(local.edge_envoy_config), "bypass_cors_preflight")
    )
    error_message = "The requirement must name the one provider alone, with no rules and no allow_missing or allow_missing_or_failed anywhere: a missing or failed token is refused."
  }

  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if contains(keys(r), "direct_response")] == ["request-too-large", "request-too-large-beyond-int64", "not-found"] &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        r.typed_per_filter_config == local.edge_rate_limit_off &&
        !contains(keys(r.typed_per_filter_config), "envoy.filters.http.jwt_authn")
      ) if contains(keys(r), "direct_response")]) &&
      !contains(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config), "envoy.filters.http.jwt_authn")
    )
    error_message = "The 413 and not-found routes answer themselves and must carry no jwt_authn entry, only the rate limiter turned off."
  }
}

# Threat: the per-route jwt_authn entry splitting the shared /v1 limiter, or dropping it.
run "edge_jwt_authn_leaves_the_rate_limiter_as_it_was" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].typed_per_filter_config == local.edge_rate_limit_per_route &&
      length([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r if r.name == "v1" || startswith(r.name, "serve-")]) == 1 + length(local.edge_serve_routes) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : (
        tolist(keys(r.typed_per_filter_config)) == tolist(["envoy.filters.http.jwt_authn"]) &&
        r.route.rate_limits == local.edge_forwarded_route.rate_limits
      ) if r.name == "v1" || startswith(r.name, "serve-")])
    )
    error_message = "v1 and every serve route must carry the jwt_authn requirement alone, no local_ratelimit entry of their own, so they still share the virtual host's one limiter and /v1 budget."
  }

  assert {
    condition = (
      one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.typed_per_filter_config["envoy.filters.http.local_ratelimit"] if r.name == "mcp"]) == local.edge_rate_limit_per_route["envoy.filters.http.local_ratelimit"] &&
      toset(one([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : keys(r.typed_per_filter_config) if r.name == "mcp"])) == toset(["envoy.filters.http.local_ratelimit", "envoy.filters.http.jwt_authn"]) &&
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if try(r.typed_per_filter_config["envoy.filters.http.local_ratelimit"].filter_enabled.default_value.numerator, 0) > 0] == ["mcp"]
    )
    error_message = "mcp's local_ratelimit entry must still be local.edge_rate_limit_per_route's, beside the jwt_authn requirement, and mcp the only route turning a limiter of its own on."
  }
}

run "edge_jwt_authn_forwards_the_token_and_no_payload" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).forward == true &&
      !contains(keys(one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers))), "forward_payload_header") &&
      !strcontains(jsonencode(local.edge_envoy_config), "forward_payload_header") &&
      !strcontains(jsonencode(local.edge_envoy_config), "payload_in_metadata")
    )
    error_message = "The provider must forward the caller's token to ca-api (forward = true) and forward no decoded payload (no forward_payload_header, no payload_in_metadata)."
  }

  # The token is read from the Authorization header's bearer value alone, not from a query
  # parameter (Envoy's other default location), which ca-api would never see.
  assert {
    condition = (
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).from_headers == [{ name = "authorization", value_prefix = "Bearer " }] &&
      length(setintersection(keys(one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers))), ["from_params", "from_cookies"])) == 0
    )
    error_message = "The provider must read the token from the Authorization header's Bearer value only."
  }
}

# Threat: the credential or a decoded payload in a log, or reaching ca-api as an identity.
run "edge_jwt_authn_logs_no_credential_and_strips_the_payload_header" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      alltrue([for k, v in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log[0].typed_config.log_format.json_format : !strcontains(upper(v), "AUTHORIZATION")]) &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "AUTHORIZATION") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "JWT") &&
      toset(flatten(regexall("%REQ\\(([^)]+)\\)%", jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)))) == toset([":METHOD", "X-REQUEST-ID", "USER-AGENT"]) &&
      !strcontains(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log), "DYNAMIC_METADATA")
    )
    error_message = "With edge.jwt_authn set, the access log must still hold no Authorization header, no token or payload, and only the method, request id and user agent of the request headers."
  }

  assert {
    condition = (
      contains(local.edge_stripped_request_headers, "x-jwt-payload") &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_remove == local.edge_stripped_request_headers
    )
    error_message = "With edge.jwt_authn set, the edge must still remove x-jwt-payload (and the other identity headers) from every request."
  }
}

# Threat: the key fetch pointed elsewhere or intercepted, so an attacker's keys are trusted.
run "edge_jwt_authn_fetches_keys_over_verified_tls" {
  command = plan

  variables {
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = (
      [for c in local.edge_envoy_config.static_resources.clusters : c.name] == ["ca-api", "entra-jwks"] &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).remote_jwks.http_uri.cluster == local.edge_envoy_config.static_resources.clusters[1].name &&
      local.edge_jwks_host == "login.microsoftonline.com" &&
      local.edge_jwks_host == regex("^https://([^/]+)/", local.oidc_jwks_uri)[0]
    )
    error_message = "With edge.jwt_authn set, the clusters must be ca-api and entra-jwks, and the provider must fetch its keys through entra-jwks, from oidc_jwks_uri's host."
  }

  assert {
    condition = (
      local.edge_envoy_config.static_resources.clusters[1].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address == { address = "login.microsoftonline.com", port_value = 443 } &&
      length(local.edge_envoy_config.static_resources.clusters[1].load_assignment.endpoints) == 1 &&
      length(local.edge_envoy_config.static_resources.clusters[1].load_assignment.endpoints[0].lb_endpoints) == 1 &&
      local.edge_envoy_config.static_resources.clusters[1].transport_socket.name == "envoy.transport_sockets.tls" &&
      local.edge_envoy_config.static_resources.clusters[1].transport_socket.typed_config["@type"] == "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext" &&
      local.edge_envoy_config.static_resources.clusters[1].transport_socket.typed_config.sni == "login.microsoftonline.com" &&
      local.edge_envoy_config.static_resources.clusters[1].transport_socket.typed_config.common_tls_context.validation_context.trusted_ca == { filename = "/etc/ssl/certs/ca-certificates.crt" } &&
      local.edge_envoy_config.static_resources.clusters[1].transport_socket.typed_config.common_tls_context.validation_context.match_typed_subject_alt_names == [{ san_type = "DNS", matcher = { exact = "login.microsoftonline.com" } }]
    )
    error_message = "The entra-jwks cluster must reach login.microsoftonline.com on 443 over TLS with SNI set to that host, the image's CA bundle as trust, and an exact DNS SAN match on that host."
  }

  # ca-api's cluster is as it was: plain http to ca-api in the same environment.
  assert {
    condition = (
      !contains(keys(local.edge_envoy_config.static_resources.clusters[0]), "transport_socket") &&
      local.edge_envoy_config.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address == { address = "ca-api", port_value = 80 }
    )
    error_message = "With edge.jwt_authn set, the ca-api cluster must be unchanged."
  }
}

# --- Applies: what reaches a running edge ----------------------------------------------------
# Plan runs against applied state: only a change Terraform does not ignore shows in the plan.

run "edge_applied_with_one_digest" {
  command = apply

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
    time    = time
  }

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  # The edge's environment id and its upstream host are chosen between module.aca_env and the
  # front and app environments (edge_environment, api_environment), so the target depends on
  # module.environments too. Teardown's pre-destroy refresh plans the environments' diagnostic
  # settings and private DNS, which read these values: a domain and an address, not mock strings.
  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
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
    condition     = azurerm_container_app.edge[0].template[0].container[0].image == "docker.io/envoyproxy/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "ca-edge must be created with edge.image."
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].container_app_environment_id == module.aca_env[0].id &&
      azurerm_container_app.edge[0].resource_group_name == azurerm_resource_group.aca.name
    )
    error_message = "ca-edge must be created in module.aca_env's environment, in the apps' resource group."
  }
}

# Threat: a new digest that never deploys.
run "edge_new_digest_is_planned_onto_the_app" {
  command = plan

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
    time    = time
  }

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.40.2@sha256:2222222222222222222222222222222222222222222222222222222222222222" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  assert {
    condition     = azurerm_container_app.edge[0].template[0].container[0].image == "docker.io/envoyproxy/envoy:v1.40.2@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    error_message = "A changed edge.image must be planned onto ca-edge: its image must not be in ignore_changes, as the CD-owned apps' images are."
  }
}

run "edge_applied_with_the_default_configuration" {
  command = apply

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
    time    = time
  }

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  # As in edge_applied_with_one_digest: the teardown plans against this run's overrides.
  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
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
    condition     = strcontains(azurerm_container_app.edge[0].template[0].container[0].args[2], "\"start\":10485761")
    error_message = "ca-edge must be created with the default body limit in its bootstrap."
  }
}

# A change to the rendered configuration changes the revision template's args, so it rolls.
run "edge_configuration_change_is_planned_onto_the_args" {
  command = plan

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
    time    = time
  }

  variables {
    edge                  = { max_request_body_bytes = 1048576 }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].template[0].container[0].args[2] == jsonencode(local.edge_envoy_config) &&
      strcontains(azurerm_container_app.edge[0].template[0].container[0].args[2], "\"start\":1048577") &&
      !strcontains(azurerm_container_app.edge[0].template[0].container[0].args[2], "\"start\":10485761")
    )
    error_message = "A change to the rendered Envoy configuration must be planned onto ca-edge's container args, which are part of the revision template."
  }
}
