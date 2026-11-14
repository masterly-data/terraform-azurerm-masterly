# The opt-in machine entry point, ca-edge (ADR 0120 §2): an Envoy proxy the module configures,
# published on the same CIDR allowlist as the frontend, that forwards /v1 and /mcp to ca-api and
# answers every other path itself. It has no database, vault, queue or cache access and makes no
# authorization decision: the Authorization header reaches ca-api unchanged and ca-api checks it.
# The edge does no authentication of its own yet.
#
# Declared as its own azurerm_container_app rather than through modules/aca-container-app,
# because that module ignores image drift (CD owns the api and frontend images) and nothing
# rolls the edge's image but this configuration: a new digest here must reach the app.

variable "edge" {
  type = object({
    image                  = optional(string)
    max_request_body_bytes = optional(number, 10485760)
  })
  default     = null
  description = "Run ca-edge, the Envoy machine entry point for the Python SDK and MCP clients: off by default (null creates nothing), and it does no authentication yet. It is published on the same CIDR allowlist as the frontend (ingress_allowed_cidrs, which must not be empty), forwards /v1 and /mcp to ca-api and answers every other path with 404. Unset, the install plans exactly as before this input existed. Without authentication of its own, it forwards the caller's Authorization header to ca-api unchanged, and ca-api checks it. It removes the identity headers ca-api could otherwise be handed (x-jwt-payload and X-MS-CLIENT-PRINCIPAL*) and holds streamed responses open. It runs as its own identity, id-<prefix>-edge, with no role but AcrPull, and that only when its image is on the install's registry. image: the Envoy image, pinned by digest (registry/repository[:tag]@sha256:<64 hex>); null uses the upstream envoyproxy/envoy image on Docker Hub the module pins. Set it to a mirror in your own registry when the environment cannot reach Docker Hub. max_request_body_bytes: a request whose Content-Length is larger is answered 413 at the edge (default 10485760, 10 MiB; from 1024 to 1073741824). A body sent without a Content-Length streams through. docs/networking.md has the network requirements."

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
  # so nothing else listens.
  edge_port = 8080

  # Requests declaring a body larger than this get 413 at the edge, before ca-api sees them.
  edge_max_request_body_bytes = local.edge_enabled ? var.edge.max_request_body_bytes : 10485760

  # Long enough for an MCP or SSE stream between events; a stream with no bytes either way for this
  # long is closed. There is deliberately no total cap on a request (route timeout 0s).
  edge_stream_idle_timeout = "300s"

  # ca-api by its app name over http, as ca-frontend calls it (main.tf, MASTERLY_API_BASE_URL):
  # the environment encrypts the hop with mutual TLS underneath the http:// scheme. Typed rather
  # than read from module.api, so the edge does not depend on ca-api's whole graph; a test pins
  # it to module.api's name.
  edge_upstream = "ca-api"

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
    host_rewrite_literal = local.edge_upstream
    # No total cap: a streamed MCP or SSE response is bounded by the stream idle timeout instead of
    # Envoy's 15 s default for a route.
    timeout = "0s"
  }

  # The whole Envoy bootstrap, passed to the container on its command line (below). Nothing in it is
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
                  # without buffering it (no buffer filter). The range ends at 2^53 - 1, the
                  # largest integer JSON carries exactly. Then /v1 and /mcp (and paths under
                  # them, not /v1x) go to ca-api, and everything else is answered here.
                  routes = [
                    {
                      name = "request-too-large"
                      match = {
                        prefix = "/"
                        headers = [{
                          name        = "content-length"
                          range_match = { start = local.edge_max_request_body_bytes + 1, end = 9007199254740991 }
                        }]
                      }
                      direct_response = { status = 413 }
                    },
                    {
                      name  = "v1"
                      match = { path_separated_prefix = "/v1" }
                      route = local.edge_forwarded_route
                    },
                    {
                      name  = "mcp"
                      match = { path_separated_prefix = "/mcp" }
                      route = local.edge_forwarded_route
                    },
                    {
                      name            = "not-found"
                      match           = { prefix = "/" }
                      direct_response = { status = 404 }
                    },
                  ]
                }]
              }

              http_filters = [{
                name = "envoy.filters.http.router"
                typed_config = {
                  "@type" = "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"
                }
              }]
            }
          }]
        }]
      }]

      clusters = [{
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
                  socket_address = { address = local.edge_upstream, port_value = 80 }
                }
              }
            }]
          }]
        }
      }]
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
  container_app_environment_id = module.aca_env.id
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
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "ca-edge"
      image  = local.edge_image
      cpu    = 0.25
      memory = "0.5Gi"

      # The bootstrap travels in the command, which is part of the revision template: a change to
      # the configuration rolls a new revision, as a change of image does.
      command = ["envoy", "--config-yaml", jsonencode(local.edge_envoy_config)]
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
  ]
}

output "edge_url" {
  value       = local.edge_enabled ? "https://${azurerm_container_app.edge[0].ingress[0].fqdn}" : null
  description = "ca-edge's base URL, the address for the Python SDK and MCP clients (subject to the ingress IP allowlist): /v1 and /mcp under it reach ca-api. Null unless edge is set. On an internal environment (aca_internal_load_balancer) it is reachable from the VNet, not the internet."
}

output "edge_identity_principal_id" {
  value       = one(module.edge_identity[*].principal_id)
  description = "Principal (object) id of ca-edge's own user-assigned identity (id-<prefix>-edge), with edge set; null otherwise. It needs AcrPull only when edge.image is on the install's registry and acr_id is left null; grant it there. It holds no other role."
}
