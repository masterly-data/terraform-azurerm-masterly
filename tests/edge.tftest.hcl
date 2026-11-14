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
# command carries. The last two pairs of runs apply against tests/mocks/migrate (ARM-shaped ids, so
# a plan against the applied state validates), under the alias "applied", and so come last.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

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

  override_resource {
    target          = module.aca_env.azurerm_container_app_environment.this
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
    }
  }

  assert {
    condition = (
      length(azurerm_container_app.edge) == 1 &&
      azurerm_container_app.edge[0].name == "ca-edge" &&
      azurerm_container_app.edge[0].container_app_environment_id == module.aca_env.id &&
      azurerm_container_app.edge[0].resource_group_name == azurerm_resource_group.aca.name
    )
    error_message = "With edge set, ca-edge must be planned in module.aca_env's environment, in the apps' resource group."
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

  assert {
    condition     = local.edge_upstream == module.api.name
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
}

run "edge_image_without_a_digest_is_refused" {
  command = plan

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.36.0" }
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
    edge                  = { image = "masterly.azurecr.io/mirror/envoy:v1.36.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
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
    edge                  = { image = "masterly.azurecr.io/mirror/envoy:v1.36.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
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

  # Only /v1 and /mcp (and the paths under them) reach a cluster, both the same one.
  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.match if contains(keys(r), "route")] == [{ path_separated_prefix = "/v1" }, { path_separated_prefix = "/mcp" }] &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.route.cluster == "ca-api" && r.route.host_rewrite_literal == "ca-api" if contains(keys(r), "route")])
    )
    error_message = "Only the prefixes /v1 and /mcp may route to a cluster, the ca-api cluster, with Host rewritten to ca-api."
  }

  # Every other route answers itself, and the last one is the catch-all 404.
  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : contains(keys(r), "direct_response") if !contains(keys(r), "route")]) &&
      length(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts) == 1 &&
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].domains == ["*"] &&
      element(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes, -1).match == { prefix = "/" } &&
      element(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes, -1).direct_response.status == 404 &&
      !contains(keys(element(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes, -1)), "route")
    )
    error_message = "Any path other than /v1 and /mcp must be answered 404 by a direct_response, never reach the cluster."
  }

  # The one cluster: ca-api by app name, port 80, plain http (no transport socket).
  assert {
    condition = (
      length(local.edge_envoy_config.static_resources.clusters) == 1 &&
      local.edge_envoy_config.static_resources.clusters[0].name == "ca-api" &&
      local.edge_envoy_config.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address == { address = "ca-api", port_value = 80 } &&
      !contains(keys(local.edge_envoy_config.static_resources.clusters[0]), "transport_socket")
    )
    error_message = "The cluster must address ca-api by app name over plain http on port 80."
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
  # the list above.
  assert {
    condition = (
      !contains([for h in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_remove : lower(h)], "authorization") &&
      length(setintersection(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config), ["request_headers_to_add", "response_headers_to_add"])) == 0 &&
      length(setintersection(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0]), ["request_headers_to_add", "request_headers_to_remove"])) == 0 &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : length(setintersection(keys(r), ["request_headers_to_add", "request_headers_to_remove"])) == 0]) &&
      !strcontains(lower(jsonencode(local.edge_envoy_config)), "authorization")
    )
    error_message = "The edge must not remove or rewrite the Authorization header."
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

  # Nothing buffers a forwarded body or response: the router is the only HTTP filter.
  assert {
    condition = (
      [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.router"] &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : !contains(keys(r), "typed_per_filter_config")]) &&
      !strcontains(jsonencode(local.edge_envoy_config), "envoy.filters.http.buffer")
    )
    error_message = "No envoy.filters.http.buffer filter may apply to the forwarded routes."
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
      !issensitive(azurerm_container_app.edge[0].template[0].container[0].command) &&
      azurerm_container_app.edge[0].template[0].container[0].command == tolist(["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]) &&
      length(azurerm_container_app.edge[0].secret) == 0 &&
      length(azurerm_container_app.edge[0].template[0].container[0].env) == 0 &&
      length(azurerm_container_app.edge[0].template[0].init_container) == 0
    )
    error_message = "The bootstrap and ca-edge's command must hold no secret value, and ca-edge must declare no secrets, env or init container."
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
}

# --- Applies: what reaches a running edge ----------------------------------------------------
# Plan runs against applied state: only a change Terraform does not ignore shows in the plan.

run "edge_applied_with_one_digest" {
  command = apply

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
  }

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.36.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  assert {
    condition     = azurerm_container_app.edge[0].template[0].container[0].image == "docker.io/envoyproxy/envoy:v1.36.0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "ca-edge must be created with edge.image."
  }
}

# Threat: a new digest that never deploys.
run "edge_new_digest_is_planned_onto_the_app" {
  command = plan

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
  }

  variables {
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.36.0@sha256:2222222222222222222222222222222222222222222222222222222222222222" }
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  assert {
    condition     = azurerm_container_app.edge[0].template[0].container[0].image == "docker.io/envoyproxy/envoy:v1.36.0@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    error_message = "A changed edge.image must be planned onto ca-edge: its image must not be in ignore_changes, as the CD-owned apps' images are."
  }
}

run "edge_applied_with_the_default_configuration" {
  command = apply

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
  }

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  plan_options {
    target = [azurerm_container_app.edge]
  }

  assert {
    condition     = strcontains(azurerm_container_app.edge[0].template[0].container[0].command[2], "\"start\":10485761")
    error_message = "ca-edge must be created with the default body limit in its bootstrap."
  }
}

# A change to the rendered configuration changes the revision template's command, so it rolls.
run "edge_configuration_change_is_planned_onto_the_command" {
  command = plan

  providers = {
    azurerm = azurerm.applied
    random  = random
    azapi   = azapi
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
      azurerm_container_app.edge[0].template[0].container[0].command[2] == jsonencode(local.edge_envoy_config) &&
      strcontains(azurerm_container_app.edge[0].template[0].container[0].command[2], "\"start\":1048577") &&
      !strcontains(azurerm_container_app.edge[0].template[0].container[0].command[2], "\"start\":10485761")
    )
    error_message = "A change to the rendered Envoy configuration must be planned onto ca-edge's container command, which is part of the revision template."
  }
}
