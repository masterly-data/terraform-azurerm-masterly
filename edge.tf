# The opt-in machine entry point, ca-edge (ADR 0120 §2): an Envoy proxy the module configures,
# published on the same CIDR allowlist as the frontend, that forwards /v1 and /mcp to ca-api and
# answers every other path itself. It has no database, vault, queue or cache access and makes no
# authorization decision: the Authorization header reaches ca-api unchanged and ca-api checks it.
# The edge does no authentication of its own yet. It limits the rate of requests per bearer token
# and per client address, counted on each replica.
#
# Declared as its own azurerm_container_app rather than through modules/aca-container-app,
# because that module ignores image drift (CD owns the api and frontend images) and nothing
# rolls the edge's image but this configuration: a new digest here must reach the app.

variable "edge" {
  type = object({
    image                       = optional(string)
    max_request_body_bytes      = optional(number, 10485760)
    rate_limit_per_token        = optional(number, 600)
    rate_limit_per_client       = optional(number, 1800)
    rate_limit_interval_seconds = optional(number, 60)
  })
  default     = null
  description = "Run ca-edge for SDK and MCP clients: 429 with Retry-After over rate_limit_per_token (600) or rate_limit_per_client (1800) per rate_limit_interval_seconds (60) per replica, so limits multiply by 1 to 3 running replicas. It is the machine entry point, off by default: an Envoy proxy for the Python SDK and MCP clients, published on the same CIDR allowlist as the frontend (ingress_allowed_cidrs, which must not be empty), that forwards /v1 and /mcp to ca-api and answers every other path with 404. Unset, the install plans exactly as before this input existed. It does no authentication yet: it forwards the caller's Authorization header to ca-api unchanged, and ca-api checks it. It removes the identity headers ca-api could otherwise be handed (x-jwt-payload and X-MS-CLIENT-PRINCIPAL*) and holds streamed responses open. It runs as its own identity, id-<prefix>-edge, with no role but AcrPull, and that only when its image is on the install's registry. image: the Envoy image, pinned by digest (registry/repository[:tag]@sha256:<64 hex>); null uses the upstream envoyproxy/envoy image on Docker Hub the module pins. Set it to a mirror in your own registry when the environment cannot reach Docker Hub. max_request_body_bytes: a request whose Content-Length is larger is answered 413 at the edge (default 10485760, 10 MiB; from 1024 to 1073741824). A body sent without a Content-Length streams through. rate_limit_per_token: the requests one bearer token (the Authorization header's value) may send to /v1 and /mcp per interval (default 600; from 1 to 1000000). A request without an Authorization header is held only to the per-client limit. rate_limit_per_client: the requests one client address may send per interval, whatever tokens it uses, so rotating tokens does not get round the per-token limit (default 1800; from 1 to 1000000). The client address is the caller's address as the Container Apps ingress reports it. rate_limit_interval_seconds: the interval both limits count over, in whole seconds (default 60; from 1 to 3600). A request over either limit is answered 429 with a Retry-After header of the interval in seconds. The limits are counted on each replica, with no shared state, and separately for /v1 and /mcp: with ca-edge at 1 to 3 replicas, the effective limit is the configured limit times the running replicas. docs/networking.md has the network requirements."

  # A conditional, not `||`: before Terraform 1.12 both sides of `||` are evaluated, and the
  # right side reads attributes of a null object when the input is unset (as builtin_auth).
  validation {
    condition = var.edge == null ? true : (
      var.edge.image == null ? true : can(regex("^(?:[^\\s/@]*[.:][^\\s/@]*|localhost)(?:/[^\\s/:@]+)+(?::\\w[\\w.-]{0,127})?@sha256:[0-9a-f]{64}$", var.edge.image))
    )
    error_message = "edge.image must be a full image reference pinned by digest, registry/repository[:tag]@sha256:<64 lowercase hex>, for example docker.io/envoyproxy/envoy:v1.40.2@sha256:<digest>. A tag alone can be moved to different content after review; the digest cannot."
  }

  validation {
    condition = var.edge == null ? true : (
      floor(var.edge.max_request_body_bytes) == var.edge.max_request_body_bytes &&
      var.edge.max_request_body_bytes >= 1024 &&
      var.edge.max_request_body_bytes <= 1073741824
    )
    error_message = "edge.max_request_body_bytes must be a whole number of bytes from 1024 to 1073741824 (1 GiB)."
  }

  validation {
    condition = var.edge == null ? true : (
      floor(var.edge.rate_limit_per_token) == var.edge.rate_limit_per_token &&
      var.edge.rate_limit_per_token >= 1 &&
      var.edge.rate_limit_per_token <= 1000000
    )
    error_message = "edge.rate_limit_per_token must be a whole number of requests from 1 to 1000000."
  }

  validation {
    condition = var.edge == null ? true : (
      floor(var.edge.rate_limit_per_client) == var.edge.rate_limit_per_client &&
      var.edge.rate_limit_per_client >= 1 &&
      var.edge.rate_limit_per_client <= 1000000
    )
    error_message = "edge.rate_limit_per_client must be a whole number of requests from 1 to 1000000."
  }

  validation {
    condition = var.edge == null ? true : (
      floor(var.edge.rate_limit_interval_seconds) == var.edge.rate_limit_interval_seconds &&
      var.edge.rate_limit_interval_seconds >= 1 &&
      var.edge.rate_limit_interval_seconds <= 3600
    )
    error_message = "edge.rate_limit_interval_seconds must be a whole number of seconds from 1 to 3600 (one hour)."
  }
}

locals {
  edge_enabled = var.edge != null

  # The upstream Envoy image, pinned by digest: v1.40.2 (released 2026-10-27), the multi-arch index
  # digest read from Docker Hub on 2026-11-14. Bump tag and digest together, from the registry
  # (docker buildx imagetools inspect docker.io/envoyproxy/envoy:<tag>), and keep within Envoy's
  # 12-month support window. A change here, or to edge.image, rolls a new ca-edge revision on the
  # next apply: the image is not in the app's ignore_changes.
  edge_default_image = "docker.io/envoyproxy/envoy:v1.40.2@sha256:8de97e654644827d62afdbf7e1d3dc9fee01a8690d410dd1c63a30dc6b6cecbb"
  edge_image         = local.edge_enabled ? coalesce(var.edge.image, local.edge_default_image) : local.edge_default_image

  # Logs in to the install's registry, as its own identity, only when the image is there. Any other
  # registry (Docker Hub by default) is pulled anonymously, with no registry block and no grant.
  edge_image_on_registry = local.edge_enabled && local.registry_server != "" && lower(split("/", local.edge_image)[0]) == lower(local.registry_server)

  # The port the listener binds and ingress targets. The admin interface is not configured at all,
  # so nothing else listens. Unprivileged (1024 or above): Envoy runs as the image's envoy user,
  # not root, and could not bind a lower port.
  edge_port = 8080

  # ca-edge's replica floor, read by the app and by the availability alerts in diagnostics.tf so
  # the two cannot drift. Fixed, not an input: the edge is the only way in for machine callers.
  edge_min_replicas = 1

  # Requests declaring a body larger than this get 413 at the edge, before ca-api sees them.
  edge_max_request_body_bytes = local.edge_enabled ? var.edge.max_request_body_bytes : 10485760

  # The rate limits on /v1 and /mcp (ADR 0120 §2): requests per interval for one bearer token and
  # for one client address. Each replica counts on its own (local_ratelimit; no Redis and no
  # rate-limit service, ADR 0120 §5), so the effective limit is these times the running replicas.
  edge_rate_limit_per_token        = local.edge_enabled ? var.edge.rate_limit_per_token : 600
  edge_rate_limit_per_client       = local.edge_enabled ? var.edge.rate_limit_per_client : 1800
  edge_rate_limit_interval_seconds = local.edge_enabled ? var.edge.rate_limit_interval_seconds : 60

  # The header that carries the caller's credential, whose value keys the per-token limit. Its value
  # is a bucket key held in Envoy's memory only: never in this configuration, a stat name or a log.
  edge_credential_header = "authorization"

  # How many distinct tokens, and distinct client addresses, one replica keeps a bucket for on each
  # route; past it the least recently seen is dropped. It bounds the memory a caller sending many
  # different tokens can take. A dropped token starts afresh, but the per-client limit still holds.
  edge_rate_limit_max_dynamic_descriptors = 1000

  # Long enough for an MCP or SSE stream between events; a stream with no bytes either way for this
  # long is closed. There is deliberately no total cap on a request (route timeout 0s).
  edge_stream_idle_timeout = "300s"

  # ca-api by its app name over http, as ca-frontend calls it (main.tf, MASTERLY_API_BASE_URL):
  # the environment encrypts the hop with mutual TLS underneath the http:// scheme. Typed rather
  # than read from module.api, so the edge does not depend on ca-api's whole graph; a test pins
  # it to module.api's name. The cluster keeps this name in every placement.
  edge_upstream = "ca-api"

  # Where the cluster connects and the Host it sends. With ca-api in the app environment
  # (api_environment = "app") the app name resolves nowhere from the front environment, so the
  # edge connects to ca-api.<app default domain> on 443 over TLS it verifies (below); by default
  # ca-api on 80, as before.
  edge_upstream_host = local.api_in_app_environment ? local.api_cross_environment_host : local.edge_upstream
  edge_upstream_port = local.api_in_app_environment ? 443 : 80

  # Upstream TLS, only across environments. The chain is checked against the image's system CA
  # bundle (the envoyproxy/envoy image installs ca-certificates there), and the certificate must
  # name the host: Envoy checks no hostname unless a subject alternative name is matched, and SNI
  # alone does not make it. Without this key the cluster has no transport socket, as before.
  edge_upstream_transport_socket = local.api_in_app_environment ? [{
    name = "envoy.transport_sockets.tls"
    typed_config = {
      "@type" = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext"
      sni     = local.edge_upstream_host
      common_tls_context = {
        validation_context = {
          trusted_ca                    = { filename = "/etc/ssl/certs/ca-certificates.crt" }
          match_typed_subject_alt_names = [{ san_type = "DNS", matcher = { exact = local.edge_upstream_host } }]
        }
      }
    }
  }] : []

  # Headers ca-api could be handed as a statement of who the caller is: the decoded token a
  # gateway forwards, and every header App Service built-in authentication sets. Removed from every
  # request before routing, whatever their case. Authorization is not among them.
  edge_stripped_request_headers = [
    "x-jwt-payload",
    "x-ms-client-principal",
    "x-ms-client-principal-id",
    "x-ms-client-principal-idp",
    "x-ms-client-principal-name",
  ]

  edge_forwarded_route = {
    cluster              = local.edge_upstream
    host_rewrite_literal = local.edge_upstream_host
    # No total cap: a streamed MCP or SSE response is bounded by the stream idle timeout instead of
    # Envoy's 15 s default for a route.
    timeout = "0s"
    # Two descriptors for local_ratelimit, one per entry: the credential header's value under the
    # key "token", and the client address under "remote_address". A request without the header
    # yields no token descriptor, so only the per-client limit applies to it.
    rate_limits = [
      { actions = [{ request_headers = { header_name = local.edge_credential_header, descriptor_key = "token" } }] },
      { actions = [{ remote_address = {} }] },
    ]
  }

  # Each bucket holds the limit's requests, refilled in full every interval.
  edge_rate_limit_bucket = {
    token = {
      max_tokens      = local.edge_rate_limit_per_token
      tokens_per_fill = local.edge_rate_limit_per_token
      fill_interval   = "${local.edge_rate_limit_interval_seconds}s"
    }
    client = {
      max_tokens      = local.edge_rate_limit_per_client
      tokens_per_fill = local.edge_rate_limit_per_client
      fill_interval   = "${local.edge_rate_limit_interval_seconds}s"
    }
  }

  # local_ratelimit turned on, for the v1 and mcp routes only; the filter itself is off (below), so
  # the 413 and 404 answers are never limited. Each descriptor has an empty value: a bucket per
  # distinct token and per distinct client address, made as they are seen. The descriptors match
  # every forwarded request (each has a client address), so the route's own bucket is never
  # consumed; it is set to the per-client limit regardless.
  edge_rate_limit_per_route = {
    "envoy.filters.http.local_ratelimit" = {
      "@type"     = "type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit"
      stat_prefix = "edge_rate_limit"
      status      = { code = "TooManyRequests" }
      filter_enabled = {
        runtime_key   = "edge_rate_limit_enabled"
        default_value = { numerator = 100, denominator = "HUNDRED" }
      }
      filter_enforced = {
        runtime_key   = "edge_rate_limit_enforced"
        default_value = { numerator = 100, denominator = "HUNDRED" }
      }
      token_bucket                        = local.edge_rate_limit_bucket.client
      always_consume_default_token_bucket = false
      descriptors = [
        { entries = [{ key = "token", value = "" }], token_bucket = local.edge_rate_limit_bucket.token },
        { entries = [{ key = "remote_address", value = "" }], token_bucket = local.edge_rate_limit_bucket.client },
      ]
      max_dynamic_descriptors = local.edge_rate_limit_max_dynamic_descriptors
      # Added to refused (429) responses only: a bucket is full again within one interval.
      response_headers_to_add = [{
        append_action = "OVERWRITE_IF_EXISTS_OR_ADD"
        header        = { key = "retry-after", value = tostring(local.edge_rate_limit_interval_seconds) }
      }]
    }
  }

  # ca-api serves MCP at /mcp/ and answers a bare /mcp with a redirect. The mcp route rewrites
  # exactly /mcp (the path only; the query string is kept) so the client never sees it.
  edge_mcp_bare_path_rewrite = { pattern = { regex = "^/mcp$" }, substitution = "/mcp/" }

  # A redirect from ca-api names the host the edge sends upstream (http://ca-api, or
  # https://ca-api.<app domain>), which a client cannot reach. The response filter turns such a
  # Location, scheme and host in any case and with an optional port, into a reference relative
  # to the edge. A result that would start with // or /\ (another host), or a malformed port, has
  # the Location removed rather than sent on with the upstream host. A Location whose host only
  # starts with the upstream host (http://ca-api.evil) is another host and is left as it was, like
  # any other Location. Headers only: no body is read, so nothing is buffered.
  edge_location_rewrite_lua = <<-LUA
    function envoy_on_response(response_handle)
      local headers = response_handle:headers()
      local location = headers:get("location")
      if location == nil then
        return
      end
      local lowered = string.lower(location)
      local rest = nil
      for _, origin in ipairs({ "http://${lower(local.edge_upstream_host)}", "https://${lower(local.edge_upstream_host)}" }) do
        if string.sub(lowered, 1, #origin) == origin then
          rest = string.sub(location, #origin + 1)
          break
        end
      end
      if rest == nil then
        return
      end
      local had_port = false
      if string.sub(rest, 1, 1) == ":" then
        had_port = true
        local i = 2
        while i <= #rest and string.byte(rest, i) >= 48 and string.byte(rest, i) <= 57 do
          i = i + 1
        end
        rest = string.sub(rest, i)
      end
      local first = string.sub(rest, 1, 1)
      if rest == "" or first == "?" or first == "#" then
        rest = "/" .. rest
      elseif first ~= "/" then
        if had_port then
          headers:remove("location")
        end
        return
      end
      local second = string.byte(rest, 2)
      if second == 47 or second == 92 then
        headers:remove("location")
        return
      end
      headers:replace("location", rest)
    end
  LUA

  # The whole Envoy bootstrap, passed to Envoy in the container's args (below). Nothing in it is
  # secret, and nothing in it may be: it is visible in the plan and on the app's revision.
  edge_envoy_config = {
    static_resources = {
      listeners = [{
        name = "ingress"
        address = {
          socket_address = { address = "0.0.0.0", port_value = local.edge_port }
        }
        filter_chains = [{
          filters = [{
            name = "envoy.filters.network.http_connection_manager"
            typed_config = {
              "@type"             = "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager"
              stat_prefix         = "edge"
              codec_type          = "AUTO"
              stream_idle_timeout = local.edge_stream_idle_timeout

              # The client address the per-client limit keys on. The Container Apps ingress in
              # front of the edge appends the caller's address to X-Forwarded-For; trusting exactly
              # that one hop makes the rightmost entry the client address. Trusting more would let
              # a caller pick its address by sending its own X-Forwarded-For, and trusting none
              # would give every caller the ingress's address, and one shared bucket. The header
              # reaches ca-api as it arrived (skip_xff_append), as does the caller's request id.
              use_remote_address           = true
              xff_num_trusted_hops         = 1
              skip_xff_append              = true
              preserve_external_request_id = true

              # Route on the normalized path, so /v1/../internal is matched as /internal (and
              # answered 404) rather than forwarded under /v1. An encoded slash or backslash is
              # refused rather than guessed at.
              normalize_path                   = true
              merge_slashes                    = true
              path_with_escaped_slashes_action = "REJECT_REQUEST"

              # x_ms_client_principal would reach an application server that folds underscores
              # into hyphens as the header removed below: drop every header with an underscore.
              common_http_protocol_options = {
                headers_with_underscores_action = "DROP_HEADER"
              }

              # One JSON line per request on stdout, which the environment ships to the workspace.
              # The path without its query string, and no Authorization, cookie or other request
              # header that can carry a credential.
              access_log = [{
                name = "envoy.access_loggers.stdout"
                typed_config = {
                  "@type" = "type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog"
                  log_format = {
                    json_format = {
                      start_time            = "%START_TIME%"
                      method                = "%REQ(:METHOD)%"
                      path                  = "%REQ_WITHOUT_QUERY(:PATH)%"
                      protocol              = "%PROTOCOL%"
                      response_code         = "%RESPONSE_CODE%"
                      response_code_details = "%RESPONSE_CODE_DETAILS%"
                      response_flags        = "%RESPONSE_FLAGS%"
                      bytes_received        = "%BYTES_RECEIVED%"
                      bytes_sent            = "%BYTES_SENT%"
                      duration_ms           = "%DURATION%"
                      upstream_host         = "%UPSTREAM_HOST%"
                      request_id            = "%REQ(X-REQUEST-ID)%"
                      user_agent            = "%REQ(USER-AGENT)%"
                    }
                    formatters = [{
                      name = "envoy.formatter.req_without_query"
                      typed_config = {
                        "@type" = "type.googleapis.com/envoy.extensions.formatter.req_without_query.v3.ReqWithoutQuery"
                      }
                    }]
                  }
                }
              }]

              route_config = {
                name                      = "edge"
                request_headers_to_remove = local.edge_stripped_request_headers
                virtual_hosts = [{
                  name    = "edge"
                  domains = ["*"]

                  # Bounds what Envoy holds for a retry; the request body itself streams through.
                  # request_body_buffer_limit replaces per_request_buffer_limit_bytes, deprecated
                  # since Envoy 1.36.
                  request_body_buffer_limit = local.edge_max_request_body_bytes

                  # First match wins. A declared body over the limit is refused before routing,
                  # without buffering it (no buffer filter). The range's end is exclusive and
                  # is the int64 maximum, quoted so it does not pass through a double on the
                  # way to the proto. A value of 19 digits or more (10^18 and up, including
                  # what does not fit an int64 and so never matches a range) is refused by the
                  # second route. Then /v1 and /mcp (and paths under them, not /v1x) go to
                  # ca-api, and everything else is answered here.
                  routes = [
                    {
                      name = "request-too-large"
                      match = {
                        prefix = "/"
                        headers = [{
                          name        = "content-length"
                          range_match = { start = local.edge_max_request_body_bytes + 1, end = "9223372036854775807" }
                        }]
                      }
                      direct_response = { status = 413 }
                    },
                    {
                      name = "request-too-large-beyond-int64"
                      match = {
                        prefix = "/"
                        headers = [{
                          name         = "content-length"
                          string_match = { safe_regex = { regex = "^[0-9]{19,}$" } }
                        }]
                      }
                      direct_response = { status = 413 }
                    },
                    {
                      name                    = "v1"
                      match                   = { path_separated_prefix = "/v1" }
                      route                   = local.edge_forwarded_route
                      typed_per_filter_config = local.edge_rate_limit_per_route
                    },
                    {
                      name                    = "mcp"
                      match                   = { path_separated_prefix = "/mcp" }
                      route                   = merge(local.edge_forwarded_route, { regex_rewrite = local.edge_mcp_bare_path_rewrite })
                      typed_per_filter_config = local.edge_rate_limit_per_route
                    },
                    {
                      name            = "not-found"
                      match           = { prefix = "/" }
                      direct_response = { status = 404 }
                    },
                  ]
                }]
              }

              # The rate limiter first, off here (Envoy enables it for no request unless told to)
              # and turned on by the v1 and mcp routes' own configuration; then the Location
              # rewrite (response headers only, no body); the router last.
              http_filters = [
                {
                  name = "envoy.filters.http.local_ratelimit"
                  typed_config = {
                    "@type"     = "type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit"
                    stat_prefix = "edge_rate_limit"
                  }
                },
                {
                  name = "envoy.filters.http.lua"
                  typed_config = {
                    "@type"             = "type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua"
                    default_source_code = { inline_string = local.edge_location_rewrite_lua }
                  }
                },
                {
                  name = "envoy.filters.http.router"
                  typed_config = {
                    "@type" = "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"
                  }
                },
              ]
            }
          }]
        }]
      }]

      # merge() with an expanded list: the transport socket is added only across environments,
      # and the default cluster has no transport_socket key at all.
      clusters = [merge(
        {
          name              = local.edge_upstream
          type              = "LOGICAL_DNS"
          connect_timeout   = "5s"
          dns_lookup_family = "V4_ONLY"
          load_assignment = {
            cluster_name = local.edge_upstream
            endpoints = [{
              lb_endpoints = [{
                endpoint = {
                  address = {
                    socket_address = { address = local.edge_upstream_host, port_value = local.edge_upstream_port }
                  }
                }
              }]
            }]
          }
        },
        [for socket in local.edge_upstream_transport_socket : { transport_socket = socket }]...
      )]
    }
  }
}

module "edge_identity" {
  source = "./modules/user-assigned-identity"
  count  = local.edge_enabled ? 1 : 0

  name                = "id-${var.name_prefix}-edge"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# Pull only, and only on the install's registry: the edge's image on any other registry needs no
# grant. Created only with acr_id; otherwise grant it out of band (edge_identity_principal_id).
resource "azurerm_role_assignment" "acr_pull_edge" {
  count = local.edge_image_on_registry && !local.registry_token_mode && var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.edge_identity[0].principal_id
}

resource "azurerm_container_app" "edge" {
  count = local.edge_enabled ? 1 : 0

  name                         = "ca-edge"
  resource_group_name          = azurerm_resource_group.aca.name
  container_app_environment_id = local.edge_environment_id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [module.edge_identity[0].id]
  }

  dynamic "registry" {
    for_each = local.edge_image_on_registry ? [1] : []
    content {
      server   = local.registry_server
      identity = module.edge_identity[0].id
    }
  }

  # Public, HTTPS only (Azure redirects http:// to https://), and only from the allowlist. Empty
  # means UNRESTRICTED in Azure, so the precondition below refuses it.
  ingress {
    external_enabled           = true
    target_port                = local.edge_port
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    dynamic "ip_security_restriction" {
      for_each = var.ingress_allowed_cidrs
      content {
        name             = "allow-${ip_security_restriction.key}"
        ip_address_range = ip_security_restriction.value
        action           = "Allow"
      }
    }
  }

  template {
    min_replicas = local.edge_min_replicas
    max_replicas = 3

    container {
      name   = "ca-edge"
      image  = local.edge_image
      cpu    = 0.25
      memory = "0.5Gi"

      # The bootstrap travels in args, which are part of the revision template: a change to the
      # configuration rolls a new revision, as a change of image does. args, not command: a command
      # would replace the image's entrypoint (/docker-entrypoint.sh), which drops from root to the
      # unprivileged envoy user before starting Envoy, and the public proxy would run as root.
      args = ["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]

      # TCP probes on the listener port, stated rather than left to Azure's defaults so they are
      # tuned and tested. TCP, not HTTP, on purpose: an HTTP probe needs a health route on the
      # public listener or Envoy's admin interface, and either is an unauthenticated surface on
      # the allowlisted ingress. Neither exists, so the route list stays as it is.
      #
      # Liveness restarts a replica whose listener has stopped accepting connections: a probe
      # every 10 s, 3 failures in a row (30 s) before the restart.
      liveness_probe {
        transport               = "TCP"
        port                    = local.edge_port
        interval_seconds        = 10
        failure_count_threshold = 3
      }

      # Readiness keeps a replica out of rotation until the listener is up; a failure never
      # restarts it. The failure budget is generous (10 s apart, 10 failures, about 100 s after a
      # 5 s initial delay) so a slow Envoy start does not leave the app unready.
      readiness_probe {
        transport               = "TCP"
        port                    = local.edge_port
        interval_seconds        = 10
        failure_count_threshold = 10
        initial_delay           = 5
      }
    }
  }

  tags = local.tags

  lifecycle {
    # Only Azure's back-fill of "Consumption" on apps in VNet-integrated environments. The image is
    # NOT ignored: nothing but this configuration moves it.
    ignore_changes = [workload_profile_name]

    precondition {
      condition     = length(var.ingress_allowed_cidrs) > 0
      error_message = "edge with an empty ingress_allowed_cidrs would publish ca-edge, and /v1 and /mcp behind it, to the whole internet: an empty list means UNRESTRICTED in Azure, not deny-all. List the CIDRs that may reach it (the networks your SDK and MCP clients call from), or leave edge unset."
    }

    # The token credential pulls with a password held as an app secret, and ca-edge holds none.
    precondition {
      condition     = !(local.edge_image_on_registry && local.registry_token_mode)
      error_message = "edge.image is on the install's registry, which this install pulls from with a registry token; ca-edge pulls only as its own identity (AcrPull) or anonymously. Mirror the Envoy image to a registry ca-edge's identity can pull from, or leave edge.image unset for the upstream image."
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull_edge,
    azurerm_private_endpoint.registry,
    azurerm_private_dns_zone_virtual_network_link.registry,
    # With egress_firewall, the first pull takes the firewall's route, as on the api.
    azurerm_subnet_route_table_association.aca,
    time_sleep.environment_move["edge"],
  ]
}

output "edge_url" {
  value = !local.edge_enabled ? null : (
    local.edge_custom_domain ? "https://${local.edge_custom_hostname}" : "https://${azurerm_container_app.edge[0].ingress[0].fqdn}"
  )
  description = "ca-edge's base URL, the address for the Python SDK and MCP clients (subject to the ingress IP allowlist): /v1 and /mcp under it reach ca-api. https://<hostname> with edge_custom_domain, the Container Apps FQDN otherwise. Null unless edge is set. On an internal environment (aca_internal_load_balancer) it is reachable from the VNet, not the internet."
}

output "edge_identity_principal_id" {
  value       = one(module.edge_identity[*].principal_id)
  description = "Principal (object) id of ca-edge's own user-assigned identity (id-<prefix>-edge), with edge set; null otherwise. It needs AcrPull only when edge.image is on the install's registry and acr_id is left null; grant it there. It holds no other role."
}
