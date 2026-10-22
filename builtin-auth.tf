# Container Apps built-in authentication with Microsoft Entra ID (builtin_auth), on ca-frontend
# and ca-api. It is the platform's gate, in front of the application's own sign-in: a request
# that does not carry an Entra sign-in for builtin_auth.tenant_id never reaches the container.
#
# azurerm has no resource for an app's auth configuration, so it is written with azapi as the
# child resource Azure defines for it, Microsoft.App/containerApps/authConfigs, whose only valid
# name is "current". Its client secret is an ordinary Container App secret on each app (main.tf,
# secret_values), which the configuration names rather than holds.

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
  # own registration, which is what a browser sign-in yields.
  builtin_auth_apps = local.builtin_auth_enabled ? {
    frontend = {
      app_id                      = module.frontend.id
      unauthenticated_action      = "RedirectToLoginPage"
      redirect_to_provider        = "azureactivedirectory"
      excluded_paths              = var.builtin_auth.frontend_excluded_paths
      allowed_applications        = [var.builtin_auth.client_id]
      allowed_additional_audience = []
    }
    api = {
      app_id                      = module.api.id
      unauthenticated_action      = "Return401"
      redirect_to_provider        = null
      excluded_paths              = []
      allowed_applications        = distinct(concat([var.builtin_auth.client_id], var.builtin_auth.api_allowed_applications))
      allowed_additional_audience = var.builtin_auth.api_allowed_audiences
    }
  } : {}
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
