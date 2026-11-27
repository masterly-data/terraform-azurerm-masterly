# Container Apps built-in authentication with Microsoft Entra ID (builtin_auth). It is the
# platform's gate, in front of the application's own sign-in: on ca-frontend, a browser request
# that does not carry an Entra sign-in for builtin_auth.tenant_id never reaches the container.
#
# ca-api is not gated unless builtin_auth_api is true (it is false by default). Without it,
# ca-api is reached internally, by the frontend's server-side calls inside the Container Apps
# environment, and the application authenticates its callers as identity_binding sets; with
# api_ingress_external it is also published to ingress_allowed_cidrs without this gate, and the
# check below warns while both are set. With builtin_auth_api, ca-api answers 401 to every
# request, on every path, that does not carry a token issued to ca-frontend's or ca-edge's
# workload identity for builtin_auth's registration (ADR 0120 §2). The application still
# authenticates its callers as identity_binding sets: neither layer relies on the other.
#
# azurerm has no resource for an app's auth configuration, so it is written with azapi as the
# child resource Azure defines for it, Microsoft.App/containerApps/authConfigs, whose only valid
# name is "current". Its client secret is an ordinary Container App secret (main.tf,
# secret_values), which the configuration names rather than holds. ca-api carries that secret
# whenever builtin_auth is set, so turning builtin_auth_api on or off changes neither app.
#
# builtin_auth_recovery_until is the recovery fallback: it turns ca-frontend's gate off and, with
# builtin_auth_api, ca-api's too, for at most 60 minutes, only behind a network restriction, and
# the first plan after the time turns them back on (ADR 0117, amended 2026-11-02, item 5). It
# changes nothing else on either app: ca-api's environment and ingress are as without it, so the
# application's own authentication is not told the gate is off. The activity-log alerts near the
# end of this file, one per gated app, report both writes. A further alert, on ca-api's 401s,
# exists with builtin_auth_api.
#
# ca-edge is not gated unless builtin_auth_edge is true (it is false by default). With it,
# ca-edge answers 401 at the platform to every request without a valid token, on every path
# except the machine paths Envoy's jwt_authn validates (ADR 0120, as amended by ADR 0117 and
# clarified 2026-11-22): a default-deny backstop behind Envoy, not a second check of the same
# paths. The recovery fallback never turns it off, because ca-edge serves no browser sign-in.

locals {
  builtin_auth_enabled = var.builtin_auth != null

  # The secret name Azure gives the provider's client secret when built-in auth is configured
  # from the portal or the CLI. Using the same name means an install that configured it by hand
  # takes this input over without a second, orphaned copy of the secret.
  builtin_auth_secret_name  = "microsoft-provider-authentication-secret"
  builtin_auth_secret_names = local.builtin_auth_enabled ? [local.builtin_auth_secret_name] : []

  builtin_auth_registration = local.builtin_auth_enabled ? {
    clientId                = var.builtin_auth.client_id
    clientSecretSettingName = local.builtin_auth_secret_name
    openIdIssuer            = "https://login.microsoftonline.com/${var.builtin_auth.tenant_id}/v2.0"
  } : null

  # ca-edge's registration: the same client id, and the issuer Envoy's jwt_authn trusts
  # (oidc_allowed_issuers, a single Entra v2.0 tenant issuer, which builtin_auth_edge's validation
  # requires). No client secret: ca-edge never redeems a sign-in code, and carries no secret.
  builtin_auth_edge_registration = local.builtin_auth_enabled ? {
    clientId     = var.builtin_auth.client_id
    openIdIssuer = local.oidc_allowed_issuers
  } : null

  # The registration each gate validates against, by the keys of builtin_auth_apps. Kept out of
  # builtin_auth_apps for the reason builtin_auth_forward_proxy is: the edge's has no secret
  # name, so its type differs from the others'. The frontend and ca-api keep the registration
  # earlier versions wrote, so their bodies do not change.
  builtin_auth_registrations = {
    frontend = local.builtin_auth_registration
    api      = local.builtin_auth_registration
    edge     = local.builtin_auth_edge_registration
  }

  # The paths on ca-edge the platform lets through without a token: the machine paths, which
  # Envoy's jwt_authn validates. An entry matches its path exactly, and "<path>/*" the whole tree
  # below it but never a sibling: /v1x and /mcp/<sub> are refused (ADR 0120, clarified
  # 2026-11-22). Every other path, / included, answers 401 at the platform.
  builtin_auth_edge_excluded_paths = [
    "/v1",
    "/v1/*",
    "/mcp",
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-protected-resource/mcp",
  ]

  # ca-edge gated: the switch, with builtin_auth and edge set (builtin_auth_edge's validations
  # refuse it without them).
  builtin_auth_edge_enabled = local.builtin_auth_enabled && local.edge_enabled && var.builtin_auth_edge

  # The paths on ca-api served without a token: none. A path that must be reached without one,
  # such as a webhook, is for ca-edge's proxy in front of ca-api to exempt, never ca-api's gate.
  builtin_auth_api_excluded_paths = []

  # Who may present a token to ca-api: ca-frontend's workload identity and, with edge set,
  # ca-edge's, and nothing else. Not the registration itself, whose tokens are what a browser
  # sign-in yields, and not the deprecated builtin_auth.api_allowed_applications.
  builtin_auth_api_allowed_applications = concat(
    [module.frontend_identity.client_id],
    local.edge_enabled ? [one(module.edge_identity[*].client_id)] : [],
  )

  # Per app: whether the gate is on, what an unauthenticated request gets, which paths skip the
  # gate, and who besides the registration itself may present a token. The frontend admits
  # only tokens issued to its own registration, which is what a browser sign-in yields. ca-api,
  # with builtin_auth_api, answers 401. Both gates are off while the recovery fallback is open,
  # and only platform_enabled changes: every other field is as with the window closed, so the
  # restore puts back exactly what was there. The map and its keys are the ones earlier versions
  # used, so the frontend's configuration keeps its address and its body, and an install's
  # import blocks for ["api"] from 0.19.0 and 0.19.1 line up again.
  builtin_auth_apps = local.builtin_auth_enabled ? merge(
    {
      frontend = {
        app_id                      = module.frontend.id
        platform_enabled            = !local.builtin_auth_recovery_open
        unauthenticated_action      = "RedirectToLoginPage"
        redirect_to_provider        = "azureactivedirectory"
        excluded_paths              = local.builtin_auth_frontend_excluded_paths
        allowed_applications        = [var.builtin_auth.client_id]
        allowed_additional_audience = []
      }
    },
    var.builtin_auth_api ? {
      api = {
        app_id                      = module.api.id
        platform_enabled            = !local.builtin_auth_recovery_open
        unauthenticated_action      = "Return401"
        redirect_to_provider        = null
        excluded_paths              = local.builtin_auth_api_excluded_paths
        allowed_applications        = local.builtin_auth_api_allowed_applications
        allowed_additional_audience = []
      }
    } : {},
    # ca-edge, with builtin_auth_edge: 401 without a token, outside the machine paths. Its gate
    # stays on while the recovery fallback is open, whatever builtin_auth_recovery_until says,
    # and it admits, like the frontend's, only tokens issued to the registration itself.
    local.builtin_auth_edge_enabled ? {
      edge = {
        app_id                      = one(azurerm_container_app.edge[*].id)
        platform_enabled            = true
        unauthenticated_action      = "Return401"
        redirect_to_provider        = null
        excluded_paths              = local.builtin_auth_edge_excluded_paths
        allowed_applications        = [var.builtin_auth.client_id]
        allowed_additional_audience = []
      }
    } : {},
  ) : {}

  # The reverse proxy in front of each gate, by the keys of builtin_auth_apps: the frontend's is
  # builtin_auth.forward_proxy, and ca-api, which only ca-frontend and ca-edge call, has none;
  # nor has ca-edge, which is itself the proxy in front of ca-api. Kept out of builtin_auth_apps,
  # whose entries must share one type: the frontend's typed null and the api's untyped one would
  # not.
  builtin_auth_forward_proxy = local.builtin_auth_enabled ? {
    frontend = var.builtin_auth.forward_proxy
    api      = null
    edge     = null
  } : {}

  # The api entries of builtin_auth, which configured ca-api's gate in 0.19.0 and 0.19.1 and are
  # now ignored, with or without builtin_auth_api. The check below warns while any is set.
  builtin_auth_ignored_api_entries = local.builtin_auth_enabled ? concat(
    var.builtin_auth.api_allowed_applications,
    var.builtin_auth.api_allowed_audiences,
  ) : []

  # The paths ca-frontend serves without sign-in. Unset, production opens exactly the start page
  # (/ and /start, ADR 0117) and demo opens none, as before; set, the list as given, which in
  # production the variable's validation holds to that same pair.
  builtin_auth_frontend_excluded_paths = !local.builtin_auth_enabled ? [] : (
    var.builtin_auth.frontend_excluded_paths != null ? var.builtin_auth.frontend_excluded_paths : (
      var.mode == "production" ? tolist(["/", "/start"]) : []
    )
  )

  # ca-api published to ingress_allowed_cidrs while builtin_auth gates the frontend only, that
  # is, without builtin_auth_api. The check below warns while it holds. ca-api is published only
  # as local.api_published says, which an accepted plan never is since api_ingress_external
  # requires edge; the check stays as the guard should that change.
  builtin_auth_leaves_published_api_ungated = local.builtin_auth_enabled && local.api_published && !var.builtin_auth_api

  # The recovery fallback (builtin_auth_recovery_until): ca-frontend's gate, and ca-api's with
  # builtin_auth_api, is off while the time is set and still after this plan, and on again at
  # the first plan after it. The try() leaves a malformed time to the variable's validation.
  builtin_auth_recovery_open = var.builtin_auth_recovery_until == null ? false : try(timecmp(plantimestamp(), var.builtin_auth_recovery_until) < 0, false)

  # A recovery time that has passed: the gate is back on, and the check below warns until the
  # input is removed.
  builtin_auth_recovery_expired = var.builtin_auth_recovery_until == null ? false : try(timecmp(plantimestamp(), var.builtin_auth_recovery_until) >= 0, false)
}

check "builtin_auth_api_entries_are_ignored" {
  assert {
    condition     = length(local.builtin_auth_ignored_api_entries) == 0
    error_message = "builtin_auth.api_allowed_applications and builtin_auth.api_allowed_audiences are deprecated and ignored: they never reach ca-api's gate, which builtin_auth_api turns on and which admits only ca-frontend's and ca-edge's workload identities. Remove both from builtin_auth."
  }
}

check "builtin_auth_does_not_gate_the_published_api" {
  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "builtin_auth gates ca-frontend only while builtin_auth_api is false, and api_ingress_external = true publishes ca-api to ingress_allowed_cidrs without that gate: a caller those CIDRs admit reaches the api without passing built-in authentication, and only the application's own authentication (identity_binding) stands in front of it. Narrow ingress_allowed_cidrs to the callers that need the api, set api_ingress_external = false if nothing outside the Container Apps environment calls it, or, once ca-frontend and ca-edge send their workload-identity token, set builtin_auth_api = true."
  }
}

# Threat: a production install runs with no platform gate and nothing records it. The
# opt-out is accepted (layered authentication keeps the gate optional until the private recovery
# path is proven), and every plan quotes the reason recorded for it.
check "builtin_auth_opted_out_in_production" {
  assert {
    condition     = var.mode == "production" && var.builtin_auth_opt_out != null ? false : true
    error_message = "mode = \"production\" runs without the platform sign-in gate (builtin_auth) on ca-frontend, by builtin_auth_opt_out, whose recorded reason is: \"${try(var.builtin_auth_opt_out.reason, "")}\". Anyone ingress_allowed_cidrs admits reaches the frontend with only the application's own sign-in in front of it. Set builtin_auth (and builtin_auth_client_secret) and remove builtin_auth_opt_out once the reason no longer holds."
  }
}

# With edge set, ca-api stays internal and api_ingress_external is ignored (environment.tf,
# local.api_published).
check "api_ingress_external_is_ignored_with_edge" {
  assert {
    condition     = local.edge_enabled ? !var.api_ingress_external : true
    error_message = "api_ingress_external = true is ignored with edge set: ca-api stays internal, and is reachable from outside only through ca-edge. Point the Python SDK and other clients outside the environment at the edge_url output (/v1 and /mcp under it reach ca-api), and set api_ingress_external = false."
  }
}

check "builtin_auth_recovery_window_has_expired" {
  assert {
    condition     = !local.builtin_auth_recovery_expired
    error_message = "builtin_auth_recovery_until has passed: the recovery window has expired, and this plan turns ca-frontend's built-in authentication back on, and ca-api's too where builtin_auth_api is set. Remove builtin_auth_recovery_until."
  }
}

# ca-edge's gate validates builtin_auth.client_id against the issuer Envoy trusts
# (oidc_allowed_issuers), while ca-frontend's validates it against builtin_auth.tenant_id. Two
# different tenants are not refused, but a registration lives in one tenant, so one of the two
# gates then refuses every token. A conditional, not `&&`, for the reason given on builtin_auth's
# validations; an issuer with no tenant is builtin_auth_edge's validation to refuse, not this.
check "builtin_auth_edge_tenant_is_builtin_auth_tenant" {
  assert {
    condition     = local.builtin_auth_edge_enabled && local.edge_jwt_authn_tenant != null ? lower(local.edge_jwt_authn_tenant) == lower(var.builtin_auth.tenant_id) : true
    error_message = "builtin_auth_edge validates builtin_auth.client_id against the tenant in oidc_allowed_issuers, which is not builtin_auth.tenant_id: a registration lives in one tenant, so ca-edge's gate or ca-frontend's refuses every token. Set oidc_allowed_issuers (or oidc_tenant_id) to the tenant builtin_auth.client_id is registered in."
  }
}

resource "azapi_resource" "builtin_auth" {
  for_each = local.builtin_auth_apps

  type      = "Microsoft.App/containerApps/authConfigs@2025-01-01"
  name      = "current"
  parent_id = each.value.app_id

  body = {
    # httpSettings only when forward_proxy is set: an unset attribute leaves the body exactly as
    # earlier versions wrote it, so an install that does not set it plans no change.
    properties = merge({
      platform = {
        enabled = each.value.platform_enabled
      }
      globalValidation = merge(
        {
          unauthenticatedClientAction = each.value.unauthenticated_action
          excludedPaths               = each.value.excluded_paths
        },
        each.value.redirect_to_provider != null ? { redirectToProvider = each.value.redirect_to_provider } : {},
      )
      identityProviders = {
        azureActiveDirectory = {
          registration = local.builtin_auth_registrations[each.key]
          validation = {
            # The registration's own client id is always an allowed audience; these are the
            # others.
            allowedAudiences = each.value.allowed_additional_audience
            defaultAuthorizationPolicy = {
              allowedApplications = each.value.allowed_applications
            }
          }
        }
      }
      }, local.builtin_auth_forward_proxy[each.key] == null ? {} : {
      httpSettings = {
        forwardProxy = merge(
          { convention = local.builtin_auth_forward_proxy[each.key].convention },
          local.builtin_auth_forward_proxy[each.key].custom_host_header_name == null ? {} : { customHostHeaderName = local.builtin_auth_forward_proxy[each.key].custom_host_header_name },
          local.builtin_auth_forward_proxy[each.key].custom_proto_header_name == null ? {} : { customProtoHeaderName = local.builtin_auth_forward_proxy[each.key].custom_proto_header_name },
        )
      }
    })
  }
}

# Every write to ca-frontend's auth configuration, from this module or from anywhere else: the
# recovery fallback's disable and its restore, and a change made in the portal. It exists for as
# long as builtin_auth does, not only during a recovery window, or the write that restores the
# gate would go unreported. An activity-log alert takes no severity; it notifies the install's
# action group like the other alerts (diagnostics.tf); ca-api's has its own alert below.
# Activity-log alert rules are global resources: "global" is the location Azure accepts for every
# region this module deploys to.
resource "azurerm_monitor_activity_log_alert" "builtin_auth_config_write" {
  count = local.builtin_auth_enabled ? 1 : 0

  name                = "alert-${var.name_prefix}-frontend-auth-config-write"
  resource_group_name = azurerm_resource_group.aca.name
  location            = "global"
  scopes              = [module.frontend.id]
  description         = "ca-frontend's built-in authentication configuration was written: the recovery fallback turned the gate off or back on, or the configuration was changed outside Terraform. Confirm the change was intended."

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/authConfigs/write"
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# The same for ca-api's auth configuration, for as long as builtin_auth_api gates it: the
# recovery fallback turns that gate off and back on too. A resource of its own rather than a
# second instance of the one above, so the frontend's alert keeps its address and is not
# replaced.
resource "azurerm_monitor_activity_log_alert" "builtin_auth_api_config_write" {
  count = local.builtin_auth_enabled && var.builtin_auth_api ? 1 : 0

  name                = "alert-${var.name_prefix}-api-auth-config-write"
  resource_group_name = azurerm_resource_group.aca.name
  location            = "global"
  scopes              = [module.api.id]
  description         = "ca-api's built-in authentication configuration was written: the recovery fallback turned the gate off or back on, or the configuration was changed outside Terraform. Confirm the change was intended."

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/authConfigs/write"
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# The same for ca-edge's auth configuration, for as long as builtin_auth_edge gates it. The
# recovery fallback never writes it, so every write this alert reports is this module turning the
# backstop on or off, or a change made outside Terraform.
resource "azurerm_monitor_activity_log_alert" "builtin_auth_edge_config_write" {
  count = local.builtin_auth_edge_enabled ? 1 : 0

  name                = "alert-${var.name_prefix}-edge-auth-config-write"
  resource_group_name = azurerm_resource_group.aca.name
  location            = "global"
  scopes              = [one(azurerm_container_app.edge[*].id)]
  description         = "ca-edge's built-in authentication configuration was written: builtin_auth_edge turned the backstop on or changed it, or the configuration was changed outside Terraform. Confirm the change was intended."

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/authConfigs/write"
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# A sustained rate of 401s from ca-api, while its gate (builtin_auth_api) is on. A wrong
# allowed-client list on ca-api refuses every call from ca-frontend (the BFF) and ca-edge with a
# 401, fails closed, and trips no health check (ADR 0120, "Detecting a broken L1"). When the gate
# is broken the 401 count tracks total traffic, so a count over a 15-minute window well above
# ordinary refusals is the signal. The Requests metric counts 401s at ca-api's ingress, so it
# also counts the application's own (L2) refusals; those are occasional, and the threshold is set
# above them rather than trying to tell them apart. With api_ingress_external, a direct external
# caller is refused on every call by the gate and counts here too.
#
# Unlike app_5xx this alert does not depend on diagnostics_enabled: a platform metric alert reads
# the metric directly and needs no diagnostic setting, and detecting a broken gate is a condition
# of turning it on. It exists exactly as long as builtin_auth_api does.
resource "azurerm_monitor_metric_alert" "builtin_auth_api_401" {
  count = var.builtin_auth_api ? 1 : 0

  name                = "alert-${var.name_prefix}-api-401"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [module.api.id]
  description         = "Reads ca-api's Requests metric filtered to statusCode 401: Total over a 15-minute window, evaluated every 5 minutes, severity 1, fires above 20. Fires while ca-api's built-in authentication gate is on and it returned more than 20 responses with status 401 in 15 minutes. Every call from ca-frontend and ca-edge is refused when the gate's allowed-client list is wrong, so a sustained rate of 401s means the gate is likely refusing the callers it should admit. The count includes the application's own 401s, which are occasional and sit below this threshold, and 401s to direct external callers the gate refuses. It fires only once the install passes 20 requests in 15 minutes, so a quiet install with a broken gate may not trigger it."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 20

    dimension {
      name     = "statusCode"
      operator = "Include"
      values   = ["401"]
    }
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}
