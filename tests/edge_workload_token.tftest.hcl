# edge.workload_token: ca-edge sends its own workload-identity token to ca-api in Authorization
# and the caller's in X-Masterly-Credential (edge.tf; layered authentication, ADR 0120 §2).
#
# Plan runs against the shared install mocks. ca-edge's identity is overridden with a client id of
# its own, so the route metadata naming it is known at plan and differs from every other id; the
# deployment's tenant is builtin_auth.tenant_id, as on a real install, so only the checks a run
# is about can fire. The file-wide variables turn the switch on with its prerequisites
# (builtin_auth with builtin_auth_api, and edge.jwt_authn); the runs with it off, or without a
# prerequisite, override them.
#
# The Lua is asserted from its source: Envoy is not run here. What only a live install shows (the
# token fetched, ca-api admitting it, one fetch per worker per token lifetime) is checked there.

mock_provider "azurerm" {
  source = "./tests/mocks/install"

  override_data {
    target = data.azurerm_client_config.current
    values = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      object_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    }
  }
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

override_module {
  target  = module.edge_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
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

  ingress_allowed_cidrs = ["203.0.113.7/32"]
  oidc_tenant_id        = "11111111-1111-1111-1111-111111111111"
  builtin_auth = {
    tenant_id = "11111111-1111-1111-1111-111111111111"
    client_id = "22222222-2222-2222-2222-222222222222"
  }
  builtin_auth_client_secret = "test-only-not-a-secret"
  builtin_auth_api           = true
  edge = {
    jwt_authn      = { audiences = ["22222222-2222-2222-2222-222222222222"] }
    workload_token = true
  }
}

# --- Off (the default) -----------------------------------------------------------------------

# Unset, ca-edge's container args are byte for byte what the module rendered before the switch
# existed: the literal is the digest builtin_auth_api.tftest.hcl and builtin_auth_edge.tftest.hcl
# pin on main for edge = {}, and the args' first two entries are as they were.
run "edge_workload_token_off_renders_the_args_as_before" {
  command = plan

  variables {
    builtin_auth_api = false
    edge             = { workload_token = false }
  }

  assert {
    condition     = jsonencode([for index, a in azurerm_container_app.edge[0].template[0].container[0].args : index == 2 ? sha256(a) : a]) == jsonencode(["envoy", "--config-yaml", "3fa7977ce66aca883eb804fdedca8966a2af34be7b369f6566d398cd512d3c15"])
    error_message = "With edge.workload_token false, ca-edge's container args must be the ones earlier versions rendered, not ${jsonencode([for index, a in azurerm_container_app.edge[0].template[0].container[0].args : index == 2 ? sha256(a) : a])}."
  }

  assert {
    condition = (
      !local.edge_workload_token_enabled &&
      azurerm_container_app.edge[0].template[0].container[0].args == tolist(["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]) &&
      length(coalesce(azurerm_container_app.edge[0].template[0].container[0].command, [])) == 0
    )
    error_message = "With edge.workload_token false, ca-edge must start Envoy directly from its args (no wrapper) and set no command."
  }
}

# With jwt_authn set and the switch off: no identity cluster, no wrapper, no route metadata, and
# the Lua is the Location rewrite alone, as before.
run "edge_workload_token_off_adds_no_cluster_metadata_or_lua" {
  command = plan

  variables {
    builtin_auth_api = false
    edge             = { jwt_authn = { audiences = ["22222222-2222-2222-2222-222222222222"] } }
  }

  assert {
    condition = (
      !local.edge_workload_token_enabled &&
      [for c in local.edge_envoy_config.static_resources.clusters : c.name] == ["ca-api", "entra-jwks"] &&
      !strcontains(jsonencode(local.edge_envoy_config), "IDENTITY_") &&
      azurerm_container_app.edge[0].template[0].container[0].args == tolist(["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]) &&
      !strcontains(jsonencode(azurerm_container_app.edge[0].template[0].container[0].args), "/bin/sh")
    )
    error_message = "With edge.workload_token off, there must be no identity cluster and no /bin/sh wrapper: the clusters are ca-api and entra-jwks, and the args start Envoy directly."
  }

  assert {
    condition = (
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : !contains(keys(r), "metadata")]) &&
      local.edge_lua_source == local.edge_location_rewrite_lua &&
      one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config.default_source_code.inline_string if f.name == "envoy.filters.http.lua"]) == local.edge_location_rewrite_lua &&
      !strcontains(local.edge_lua_source, "envoy_on_request")
    )
    error_message = "With edge.workload_token off, no route may carry metadata and the Lua must be the Location rewrite alone, with no envoy_on_request."
  }
}

# --- Prerequisites ---------------------------------------------------------------------------

# Threat: ca-edge's token sent for an audience nothing admits, or with ca-api not gated.
run "edge_workload_token_without_builtin_auth_api_is_refused" {
  command = plan

  variables {
    builtin_auth_api = false
  }

  expect_failures = [azurerm_container_app.edge]
}

run "edge_workload_token_without_builtin_auth_is_refused" {
  command = plan

  variables {
    builtin_auth               = null
    builtin_auth_client_secret = null
    builtin_auth_api           = false
  }

  expect_failures = [azurerm_container_app.edge]
}

# Threat: ca-edge's token attached to a caller the edge has not validated.
run "edge_workload_token_without_jwt_authn_is_refused" {
  command = plan

  variables {
    edge = { workload_token = true }
  }

  expect_failures = [azurerm_container_app.edge]
}

# builtin_auth_api with edge set and the switch off: the plan goes through, and the check warns
# that ca-api's gate refuses every caller token ca-edge forwards.
run "edge_workload_token_off_with_builtin_auth_api_warns" {
  command = plan

  variables {
    edge = { jwt_authn = { audiences = ["22222222-2222-2222-2222-222222222222"] } }
  }

  assert {
    condition = (
      local.workload_trust_enabled &&
      !local.edge_workload_token_enabled &&
      length(azurerm_container_app.edge) == 1
    )
    error_message = "With builtin_auth_api and the switch off, the plan must still go through, ca-edge included."
  }

  expect_failures = [check.builtin_auth_api_edge_sends_its_workload_token]
}

# --- On --------------------------------------------------------------------------------------

# The switch with its prerequisites plans, and the check holds (no expect_failures here).
run "edge_workload_token_on_plans_with_its_prerequisites" {
  command = plan

  assert {
    condition = (
      local.edge_workload_token_enabled &&
      local.workload_trust_enabled &&
      local.edge_jwt_authn_enabled &&
      local.edge_workload_token_audience == "22222222-2222-2222-2222-222222222222" &&
      local.edge_workload_token_audience == local.workload_trust_env["MASTERLY_WORKLOAD_API_AUDIENCE"] &&
      local.edge_workload_token_client_id == "99999999-9999-9999-9999-cccccccccccc" &&
      local.edge_workload_token_client_id == local.workload_trust_env["MASTERLY_WORKLOAD_EDGE_CLIENT_ID"]
    )
    error_message = "With the switch on, ca-edge's token must be requested for builtin_auth.client_id, the audience ca-api's L1 trust verifies, as id-<prefix>-edge, the edge client id ca-api trusts."
  }
}

# jwt_authn validates the caller before the Lua moves its token, and the per-token rate-limit key
# is read before either, so it stays the caller's token.
run "edge_workload_token_runs_after_jwt_authn" {
  command = plan

  assert {
    condition     = [for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.name] == ["envoy.filters.http.local_ratelimit", "envoy.filters.http.jwt_authn", "envoy.filters.http.lua", "envoy.filters.http.router"]
    error_message = "With edge.workload_token set, the HTTP filters must be local_ratelimit, jwt_authn, lua and the router, in that order."
  }

  assert {
    condition = (
      one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config.default_source_code.inline_string if f.name == "envoy.filters.http.lua"]) == local.edge_lua_source &&
      endswith(local.edge_lua_source, local.edge_location_rewrite_lua) &&
      startswith(local.edge_lua_source, local.edge_workload_token_lua) &&
      local.edge_forwarded_route.rate_limits[0].actions[0].request_headers.header_name == "authorization" &&
      one(values(one([for f in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.http_filters : f.typed_config if f.name == "envoy.filters.http.jwt_authn"]).providers)).forward == true
    )
    error_message = "The Lua filter must carry the token swap followed by the unchanged Location rewrite, the per-token limit must still key on Authorization, and jwt_authn must keep the token on the request (forward) for the Lua to move."
  }
}

# Threat: a route the edge answers itself fetching or carrying ca-edge's token. Only the forwarded
# routes carry the Lua metadata, each still requiring a valid caller token.
run "edge_workload_token_metadata_only_on_forwarded_routes" {
  command = plan

  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if contains(keys(r), "metadata")] == concat([for r in local.edge_serve_routes : "serve-${r.method} ${r.path}"], ["v1", "mcp"]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : jsonencode(r.metadata) == jsonencode({
        filter_metadata = {
          "envoy.filters.http.lua" = {
            audience  = "22222222-2222-2222-2222-222222222222"
            client_id = "99999999-9999-9999-9999-cccccccccccc"
          }
        }
      }) if contains(keys(r), "metadata")]) &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : contains(keys(r.typed_per_filter_config), "envoy.filters.http.jwt_authn") if contains(keys(r), "metadata")])
    )
    error_message = "The serve routes, v1 and mcp, and only they, must carry the Lua metadata, builtin_auth.client_id as the audience and id-<prefix>-edge's client id, each still requiring jwt_authn."
  }

  assert {
    condition = (
      [for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : r.name if contains(keys(r), "direct_response")] == ["request-too-large", "request-too-large-beyond-int64", "not-found"] &&
      alltrue([for r in local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0].routes : !contains(keys(r), "metadata") if contains(keys(r), "direct_response")]) &&
      !contains(keys(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.virtual_hosts[0]), "metadata")
    )
    error_message = "The 413, 413-beyond-int64 and not-found routes, and the virtual host, must carry no Lua metadata."
  }

  # Without the metadata the Lua returns before it reads a header or fetches anything.
  assert {
    condition     = length(regexall("(?s)function envoy_on_request\\(request_handle\\)\\s+local metadata = request_handle:metadata\\(\\)\\s+local audience = metadata:get\\(\"audience\"\\)\\s+local client_id = metadata:get\\(\"client_id\"\\)\\s+if audience == nil or client_id == nil then\\s+return\\s+end", local.edge_workload_token_lua)) == 1
    error_message = "envoy_on_request must return first thing on a route without the audience and client id metadata."
  }
}

# Threat: a caller choosing the L2 principal with its own X-Masterly-Credential. Refused with 400
# before any token is fetched.
run "edge_workload_token_refuses_a_callers_credential_header" {
  command = plan

  assert {
    condition = (
      length(regexall("if request_handle:headers\\(\\):get\\(\"x-masterly-credential\"\\) ~= nil then\\s+request_handle:respond\\(\\{ \\[\":status\"\\] = \"400\" \\}, \"\"\\)\\s+return\\s+end", local.edge_workload_token_lua)) == 1 &&
      length(regexall("(?s)function envoy_on_request.*\"x-masterly-credential\"\\) ~= nil.*\"400\".*edge_fetch_workload_token\\(request_handle, audience, client_id\\)", local.edge_workload_token_lua)) == 1
    )
    error_message = "envoy_on_request must answer 400 to a request carrying x-masterly-credential, before it fetches a token."
  }

  # More than one Authorization header: Envoy's Lua joins them with a comma. Refused, before any
  # fetch, so the credential moved is the one jwt_authn validated.
  assert {
    condition     = length(regexall("(?s)if string\\.find\\(credential, \",\", 1, true\\) ~= nil then\\s+request_handle:respond\\(\\{ \\[\":status\"\\] = \"400\" \\}, \"\"\\)\\s+return\\s+end\\s+local token = edge_fetch_workload_token", local.edge_workload_token_lua)) == 1
    error_message = "envoy_on_request must answer 400 to a request with more than one Authorization value, before it fetches a token."
  }
}

# The swap: the caller's Authorization moved, scheme included; the headers taken again after the
# fetch; Bearer and ca-edge's token set; 503 and nothing forwarded without a token.
run "edge_workload_token_moves_the_callers_token_and_fails_closed" {
  command = plan

  assert {
    condition = (
      length(regexall("local credential = request_handle:headers\\(\\):get\\(\"authorization\"\\)\\n", local.edge_workload_token_lua)) == 1 &&
      length(regexall("(?s)local token = edge_fetch_workload_token\\(request_handle, audience, client_id\\).*local headers = request_handle:headers\\(\\)\\s+headers:replace\\(\"x-masterly-credential\", credential\\)\\s+headers:replace\\(\"authorization\", \"Bearer \" \\.\\. token\\)\\s+end", local.edge_workload_token_lua)) == 1
    )
    error_message = "The Lua must move the caller's Authorization value as received to x-masterly-credential, and set Authorization to Bearer and ca-edge's token, on headers taken again after the fetch."
  }

  assert {
    condition = (
      length(regexall("(?s)request_handle:httpCall\\(\"identity\",.*\\}, \"\", 5000\\)", local.edge_workload_token_lua)) == 1 &&
      length(regexall("httpCall", local.edge_workload_token_lua)) == 1 &&
      length(regexall("(?s)httpCall.*function envoy_on_request.*edge_fetch_workload_token\\(request_handle, audience, client_id\\).*request_handle:headers\\(\\)\\s+headers:replace", local.edge_workload_token_lua)) == 1
    )
    error_message = "The token must be fetched with one httpCall to the identity cluster, and the request headers taken again after it."
  }

  assert {
    condition = (
      length(regexall("if token == nil then\\s+request_handle:respond\\(\\{ \\[\":status\"\\] = \"503\" \\}, \"\"\\)\\s+return\\s+end", local.edge_workload_token_lua)) == 1 &&
      length(regexall("if endpoint == nil or endpoint == \"\" or identity_header == nil or identity_header == \"\" then\\s+return nil\\s+end", local.edge_workload_token_lua)) == 1 &&
      length(regexall("if headers == nil or headers\\[\":status\"\\] ~= \"200\" or body == nil then\\s+return nil\\s+end", local.edge_workload_token_lua)) == 1 &&
      length(regexall("if token == nil or expires_on == nil then\\s+return nil\\s+end", local.edge_workload_token_lua)) == 1 &&
      length(regexall("if authority == nil then\\s+return nil\\s+end", local.edge_workload_token_lua)) == 1
    )
    error_message = "The Lua must answer 503 with an empty body when no token is had: the identity variables unset, the call failing or not 200, or no token or expires_on in its answer."
  }

  # The token request: the managed identity endpoint's API version, the audience and the identity
  # from the route's metadata, and the endpoint's header from the environment.
  assert {
    condition = (
      strcontains(local.edge_workload_token_lua, "[\":path\"] = path .. \"?api-version=2019-08-01&resource=\" .. audience .. \"&client_id=\" .. client_id,") &&
      strcontains(local.edge_workload_token_lua, "[\":method\"] = \"GET\",") &&
      strcontains(local.edge_workload_token_lua, "[\"x-identity-header\"] = identity_header,")
    )
    error_message = "The token request must be GET <endpoint path>?api-version=2019-08-01&resource=<audience>&client_id=<edge client id>, with X-IDENTITY-HEADER from the environment."
  }
}

# The cache: per audience, refreshed 5 minutes before expires_on; the endpoint and its header read
# from the environment only.
run "edge_workload_token_caches_per_audience_and_reads_the_environment" {
  command = plan

  assert {
    condition = (
      strcontains(local.edge_workload_token_lua, "edge_workload_tokens = edge_workload_tokens or {}") &&
      strcontains(local.edge_workload_token_lua, "local cached = edge_workload_tokens[audience]") &&
      strcontains(local.edge_workload_token_lua, "if cached ~= nil and os.time() < cached.expires_on - 300 then") &&
      strcontains(local.edge_workload_token_lua, "edge_workload_tokens[audience] = { token = token, expires_on = expires_on }")
    )
    error_message = "The token must be cached per audience in the worker's Lua state and refreshed 300 seconds (5 minutes) before its expires_on."
  }

  assert {
    condition = (
      strcontains(local.edge_workload_token_lua, "os.getenv(\"IDENTITY_ENDPOINT\")") &&
      strcontains(local.edge_workload_token_lua, "os.getenv(\"IDENTITY_HEADER\")") &&
      length(regexall("IDENTITY_(ENDPOINT|HEADER)", local.edge_workload_token_lua)) == 2 &&
      length(regexall("os\\.getenv", local.edge_lua_source)) == 2 &&
      length(regexall("IDENTITY_HEADER", jsonencode(local.edge_envoy_config))) == 1
    )
    error_message = "IDENTITY_ENDPOINT and IDENTITY_HEADER must be read only through os.getenv, and IDENTITY_HEADER named nowhere else in the configuration."
  }
}

# Threat: a token, or IDENTITY_HEADER's value, in the configuration, the plan or the access log.
run "edge_workload_token_logs_and_plan_carry_no_credential" {
  command = plan

  assert {
    condition = (
      !strcontains(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log), "%REQ(AUTHORIZATION)%") &&
      !strcontains(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log), "%REQ(X-MASTERLY-CREDENTIAL)%") &&
      !strcontains(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log), "%REQ(DPOP)%") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "AUTHORIZATION") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "CREDENTIAL") &&
      !strcontains(upper(jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)), "DPOP") &&
      toset(flatten(regexall("%REQ\\(([^)]+)\\)%", jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)))) == toset([":METHOD", "X-REQUEST-ID", "USER-AGENT"]) &&
      length(regexall("%", jsonencode(local.edge_envoy_config))) == length(regexall("%", jsonencode(local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.access_log)))
    )
    error_message = "With edge.workload_token set, the access log must hold no Authorization, X-Masterly-Credential or DPoP header, only the method, request id and user agent, and only the access log may use a %...% command."
  }

  assert {
    condition = (
      !issensitive(azurerm_container_app.edge[0].template[0].container[0].args) &&
      !strcontains(jsonencode(azurerm_container_app.edge[0].template[0].container[0].args), "eyJ") &&
      !strcontains(jsonencode(azurerm_container_app.edge[0].template[0].container[0].args), "access_token\":") &&
      length(regexall("Bearer ", jsonencode(local.edge_envoy_config))) == 2 &&
      length(azurerm_container_app.edge[0].secret) == 0 &&
      length(azurerm_container_app.edge[0].template[0].container[0].env) == 0
    )
    error_message = "ca-edge's args must hold no token (no JWT, no access_token value) and name Bearer only in jwt_authn's prefix and the Lua's header, and ca-edge must declare no secret and no env: IDENTITY_HEADER comes from the platform at run time."
  }
}

# Threat: the removal list stripping what the Lua sets, or DPoP lost on the way.
run "edge_workload_token_keeps_its_headers_and_dpop" {
  command = plan

  assert {
    condition = (
      local.edge_envoy_config.static_resources.listeners[0].filter_chains[0].filters[0].typed_config.route_config.request_headers_to_remove == local.edge_stripped_request_headers &&
      !contains([for h in local.edge_stripped_request_headers : lower(h)], "authorization") &&
      !contains([for h in local.edge_stripped_request_headers : lower(h)], "x-masterly-credential") &&
      !contains([for h in local.edge_stripped_request_headers : lower(h)], "dpop") &&
      !strcontains(lower(local.edge_lua_source), "dpop") &&
      !strcontains(lower(jsonencode(local.edge_envoy_config)), "dpop")
    )
    error_message = "request_headers_to_remove must not list authorization, x-masterly-credential or dpop, and neither the Lua nor anything else in the configuration may touch DPoP."
  }
}

# The identity endpoint's cluster and the wrapper that fills its address in at start-up.
run "edge_workload_token_starts_envoy_through_the_wrapper" {
  command = plan

  assert {
    condition = (
      [for c in local.edge_envoy_config.static_resources.clusters : c.name] == ["ca-api", "entra-jwks", "identity"] &&
      jsonencode(one([for c in local.edge_envoy_config.static_resources.clusters : c.load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.socket_address if c.name == "identity"])) == jsonencode({ address = "__IDENTITY_ENDPOINT_HOST__", port_value = "__IDENTITY_ENDPOINT_PORT__" }) &&
      !contains(keys(one([for c in local.edge_envoy_config.static_resources.clusters : c if c.name == "identity"])), "transport_socket")
    )
    error_message = "With edge.workload_token set, the clusters must be ca-api, entra-jwks and identity, the last addressed by the wrapper's placeholders alone."
  }

  assert {
    condition = (
      length(azurerm_container_app.edge[0].template[0].container[0].args) == 5 &&
      azurerm_container_app.edge[0].template[0].container[0].args[0] == "/bin/sh" &&
      azurerm_container_app.edge[0].template[0].container[0].args[1] == "-c" &&
      azurerm_container_app.edge[0].template[0].container[0].args[2] == local.edge_workload_token_wrapper &&
      azurerm_container_app.edge[0].template[0].container[0].args[3] == "sh" &&
      azurerm_container_app.edge[0].template[0].container[0].args[4] == jsonencode(local.edge_envoy_config) &&
      length(coalesce(azurerm_container_app.edge[0].template[0].container[0].command, [])) == 0
    )
    error_message = "With edge.workload_token set, ca-edge's args must be /bin/sh -c <wrapper> sh <configuration>, and no command, so the image's entrypoint still drops to the envoy user."
  }

  assert {
    condition = (
      endswith(local.edge_workload_token_wrapper, "exec envoy --config-yaml \"$config\"") &&
      strcontains(local.edge_workload_token_wrapper, "endpoint=\"$${IDENTITY_ENDPOINT:-}\"") &&
      strcontains(local.edge_workload_token_wrapper, "authority=\"$${authority%%/*}\"") &&
      strcontains(local.edge_workload_token_wrapper, "printf '%s' \"$1\" | sed -e \"s/__IDENTITY_ENDPOINT_HOST__/$host/\" -e \"s/\\\"__IDENTITY_ENDPOINT_PORT__\\\"/$port/\"") &&
      length(regexall("exit 1", local.edge_workload_token_wrapper)) == 3 &&
      !strcontains(local.edge_workload_token_wrapper, "localhost") &&
      !strcontains(local.edge_workload_token_wrapper, "127.0.0.1") &&
      length(regexall("[0-9]{2,}", local.edge_workload_token_wrapper)) == 0 &&
      !strcontains(jsonencode(azurerm_container_app.edge[0].template[0].container[0].args), "42356") &&
      !strcontains(jsonencode(azurerm_container_app.edge[0].template[0].container[0].args), "localhost")
    )
    error_message = "The wrapper must take the endpoint from IDENTITY_ENDPOINT, refuse to start without a usable one, substitute the placeholders, hard-code no host or port, and end by exec'ing Envoy."
  }
}
