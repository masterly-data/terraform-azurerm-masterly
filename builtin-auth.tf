# Container Apps built-in authentication with Microsoft Entra ID (builtin_auth), on ca-frontend
# only. It is the platform's gate, in front of the application's own sign-in: a browser request
# that does not carry an Entra sign-in for builtin_auth.tenant_id never reaches the container.
#
# ca-api is not gated. It is reached internally, by the frontend's server-side calls inside the
# Container Apps environment; the application authenticates its callers as identity_binding
# sets. With api_ingress_external it is also published to ingress_allowed_cidrs, without this
# gate, and the check below warns while both are set. 0.19.0 and 0.19.1 also gated ca-api;
# taking this version destroys that one configuration and leaves the frontend's unchanged.
#
# azurerm has no resource for an app's auth configuration, so it is written with azapi as the
# child resource Azure defines for it, Microsoft.App/containerApps/authConfigs, whose only valid
# name is "current". Its client secret is an ordinary Container App secret (main.tf,
# secret_values), which the configuration names rather than holds. ca-api still carries that
# secret, as it did when it was gated, so that taking this version changes neither app; nothing
# on ca-api reads it.

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

  # Per app: what an unauthenticated request gets, which paths skip the gate, and who besides
  # the registration itself may present a token. The frontend admits only tokens issued to its
  # own registration, which is what a browser sign-in yields. The map and its key are the ones
  # earlier versions used, so the frontend's configuration keeps its address and its body.
  builtin_auth_apps = local.builtin_auth_enabled ? {
    frontend = {
      app_id                      = module.frontend.id
      unauthenticated_action      = "RedirectToLoginPage"
      redirect_to_provider        = "azureactivedirectory"
      excluded_paths              = var.builtin_auth.frontend_excluded_paths
      allowed_applications        = [var.builtin_auth.client_id]
      allowed_additional_audience = []
    }
  } : {}

  # The api entries of builtin_auth, which configured ca-api's gate in 0.19.0 and 0.19.1 and are
  # now ignored. The check below warns while any is set.
  builtin_auth_ignored_api_entries = local.builtin_auth_enabled ? concat(
    var.builtin_auth.api_allowed_applications,
    var.builtin_auth.api_allowed_audiences,
  ) : []

  # ca-api published to ingress_allowed_cidrs while builtin_auth gates the frontend only. The
  # check below warns while it holds.
  builtin_auth_leaves_published_api_ungated = local.builtin_auth_enabled && var.api_ingress_external
}

check "builtin_auth_api_entries_are_ignored" {
  assert {
    condition     = length(local.builtin_auth_ignored_api_entries) == 0
    error_message = "builtin_auth.api_allowed_applications and builtin_auth.api_allowed_audiences are deprecated and ignored: builtin_auth gates ca-frontend only, and ca-api is reached internally, inside the Container Apps environment. Remove both from builtin_auth."
  }
}

check "builtin_auth_does_not_gate_the_published_api" {
  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "builtin_auth gates ca-frontend only, and api_ingress_external = true publishes ca-api to ingress_allowed_cidrs without that gate: a caller those CIDRs admit reaches the api without passing built-in authentication, and only the application's own authentication (identity_binding) stands in front of it. Narrow ingress_allowed_cidrs to the callers that need the api, or set api_ingress_external = false if nothing outside the Container Apps environment calls it."
  }
}

resource "azapi_resource" "builtin_auth" {
  for_each = local.builtin_auth_apps

  type      = "Microsoft.App/containerApps/authConfigs@2025-01-01"
  name      = "current"
  parent_id = each.value.app_id

  body = {
    properties = {
      platform = {
        enabled = true
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
    }
  }
}
