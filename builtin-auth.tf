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
# builtin_auth_recovery_until is the recovery fallback: it turns ca-frontend's gate off for at
# most 60 minutes, only behind a network restriction, and the first plan after the time turns it
# back on. It never turns off ca-api's gate. The activity-log alert at the end of this file
# reports both writes.

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
  # only tokens issued to its own registration, which is what a browser sign-in yields, and its
  # gate is off while the recovery fallback is open. ca-api, with builtin_auth_api, answers 401
  # and is never turned off here. The map and its keys are the ones earlier versions used, so
  # the frontend's configuration keeps its address and its body, and an install's import blocks
  # for ["api"] from 0.19.0 and 0.19.1 line up again.
  builtin_auth_apps = local.builtin_auth_enabled ? merge(
    {
      frontend = {
        app_id                      = module.frontend.id
        platform_enabled            = !local.builtin_auth_recovery_open
        unauthenticated_action      = "RedirectToLoginPage"
        redirect_to_provider        = "azureactivedirectory"
        excluded_paths              = var.builtin_auth.frontend_excluded_paths
        allowed_applications        = [var.builtin_auth.client_id]
        allowed_additional_audience = []
      }
    },
    var.builtin_auth_api ? {
      api = {
        app_id                      = module.api.id
        platform_enabled            = true
        unauthenticated_action      = "Return401"
        redirect_to_provider        = null
        excluded_paths              = local.builtin_auth_api_excluded_paths
        allowed_applications        = local.builtin_auth_api_allowed_applications
        allowed_additional_audience = []
      }
    } : {},
  ) : {}

  # The reverse proxy in front of each gate, by the keys of builtin_auth_apps: the frontend's is
  # builtin_auth.forward_proxy, and ca-api, which only ca-frontend and ca-edge call, has none.
  # Kept out of builtin_auth_apps, whose entries must share one type: the frontend's typed
  # null and the api's untyped one would not.
  builtin_auth_forward_proxy = local.builtin_auth_enabled ? {
    frontend = var.builtin_auth.forward_proxy
    api      = null
  } : {}

  # The api entries of builtin_auth, which configured ca-api's gate in 0.19.0 and 0.19.1 and are
  # now ignored, with or without builtin_auth_api. The check below warns while any is set.
  builtin_auth_ignored_api_entries = local.builtin_auth_enabled ? concat(
    var.builtin_auth.api_allowed_applications,
    var.builtin_auth.api_allowed_audiences,
  ) : []

  # ca-api published to ingress_allowed_cidrs while builtin_auth gates the frontend only, that
  # is, without builtin_auth_api. The check below warns while it holds.
  builtin_auth_leaves_published_api_ungated = local.builtin_auth_enabled && var.api_ingress_external && !var.builtin_auth_api

  # The recovery fallback (builtin_auth_recovery_until): ca-frontend's gate is off while the
  # time is set and still after this plan, and on again at the first plan after it. The try()
  # leaves a malformed time to the variable's validation.
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

check "builtin_auth_recovery_window_has_expired" {
  assert {
    condition     = !local.builtin_auth_recovery_expired
    error_message = "builtin_auth_recovery_until has passed: the recovery window has expired, and this plan turns ca-frontend's built-in authentication back on (ca-api's, with builtin_auth_api, was never turned off). Remove builtin_auth_recovery_until."
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
          registration = local.builtin_auth_registration
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
# action group like the other alerts (diagnostics.tf). Activity-log alert rules are global
# resources: "global" is the location Azure accepts for every region this module deploys to.
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
