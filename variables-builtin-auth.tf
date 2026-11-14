# Inputs read by builtin-auth.tf: the built-in sign-in.

variable "builtin_auth" {
  type = object({
    tenant_id                = string
    client_id                = string
    api_allowed_applications = optional(list(string), [])
    api_allowed_audiences    = optional(list(string), [])
    frontend_excluded_paths  = optional(list(string), [])
  })
  default     = null
  description = <<-EOT
    Container Apps built-in authentication (often called EasyAuth) with Microsoft Entra ID, on
    ca-frontend only: a gate at the platform, in front of the application's own sign-in. Null
    (the default) configures none, exactly as before this input existed. It is independent of
    identity_binding: with identity_binding = "oidc" a browser signs in twice, once at the
    platform (who may reach the frontend at all) and once in the application (which member, which
    roles), and neither layer relies on the other.

    - ca-frontend redirects an unauthenticated browser to Entra sign-in.
    - ca-api is not gated. It is reached internally, by the frontend's server-side calls to
      http://ca-api inside the Container Apps environment; the application authenticates its
      callers as identity_binding sets. With api_ingress_external = true, ca-api is also
      published to ingress_allowed_cidrs, without this gate, and a plan that sets both warns.

    tenant_id: the Entra tenant users sign in from (the issuer is
    https://login.microsoftonline.com/<tenant_id>/v2.0). client_id: the app registration the
    platform signs users in with. Register https://<frontend host>/.auth/login/aad/callback as a
    web redirect URI on it and enable ID token issuance; its client secret is
    builtin_auth_client_secret. frontend_excluded_paths: paths on ca-frontend served without
    sign-in; every path listed is reachable by anyone ingress_allowed_cidrs admits, so leave it
    empty unless a page must be public.

    api_allowed_applications and api_allowed_audiences are deprecated and ignored: they configured
    a gate on ca-api in 0.19.0 and 0.19.1. A plan that sets either warns; remove them.
  EOT

  validation {
    # A conditional, not `||`: Terraform before 1.12 evaluates both sides of `||`, and the
    # right side reads attributes of a null object when the input is unset. The deprecated api
    # entries are not checked: an ignored value cannot fail a plan.
    condition = var.builtin_auth == null ? true : alltrue([
      for id in [var.builtin_auth.tenant_id, var.builtin_auth.client_id] :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "builtin_auth.tenant_id and client_id must be UUIDs: the tenant's directory id and the registration's application (client) id, not an object id or a name."
  }

  validation {
    condition     = var.builtin_auth == null ? true : alltrue([for p in var.builtin_auth.frontend_excluded_paths : startswith(p, "/")])
    error_message = "builtin_auth.frontend_excluded_paths entries must be absolute paths starting with \"/\"."
  }

  validation {
    condition     = var.builtin_auth == null || var.builtin_auth_client_secret != null
    error_message = "builtin_auth requires builtin_auth_client_secret: the platform redeems the sign-in code with it."
  }
}

variable "builtin_auth_recovery_until" {
  type        = string
  default     = null
  description = <<-EOT
    The recovery fallback for builtin_auth: an RFC 3339 UTC time (for example
    2026-11-14T15:30:00Z) until which ca-frontend's built-in authentication is turned off, so that
    a browser reaches the application's own sign-in (and its break-glass path) without an Entra
    sign-in at the platform. Use it only when no other way in is available, such as an Entra
    outage that blocks the platform sign-in. Null (the default) leaves the gate on.

    - The time must be at most 60 minutes after the plan; a later time is refused.
    - It is refused without builtin_auth, and refused without a network restriction in front of
      ca-frontend: a non-empty ingress_allowed_cidrs, frontend_ingress_external = false, or
      aca_internal_load_balancer = true.
    - It turns off ca-frontend's gate only. It changes nothing on ca-api: its ingress, its
      environment and its authentication are as without this input, and the window in which
      ca-api's own sign-in check is relaxed during an Entra outage is not set here.
    - Terraform cannot act at the time itself: the gate comes back at the first plan and apply
      after the time has passed. A plan that still sets a passed time restores the gate and
      warns; remove the input then.
    - Every change to ca-frontend's authentication configuration, the disable and the restore
      alike, raises the activity-log alert that builtin_auth creates.
  EOT

  validation {
    # A conditional, not `||`, for the reason given on builtin_auth's validations.
    condition     = var.builtin_auth_recovery_until == null ? true : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$", var.builtin_auth_recovery_until)) && can(timecmp(var.builtin_auth_recovery_until, var.builtin_auth_recovery_until))
    error_message = "builtin_auth_recovery_until must be an RFC 3339 time in UTC, such as 2026-11-14T15:30:00Z."
  }

  validation {
    condition     = var.builtin_auth_recovery_until == null || var.builtin_auth != null
    error_message = "builtin_auth_recovery_until turns off the gate builtin_auth configures, so it requires builtin_auth. Without builtin_auth there is no gate to turn off; remove builtin_auth_recovery_until."
  }

  validation {
    condition     = var.builtin_auth_recovery_until == null || length(var.ingress_allowed_cidrs) > 0 || !var.frontend_ingress_external || var.aca_internal_load_balancer
    error_message = "builtin_auth_recovery_until turns off ca-frontend's gate, which is refused while ca-frontend is open to the internet: set ingress_allowed_cidrs to the networks that need it, or use private ingress (frontend_ingress_external = false or aca_internal_load_balancer = true)."
  }

  validation {
    # plantimestamp() is unknown under `terraform validate`, so this holds there and is checked
    # at plan. The try() leaves a malformed time to the format validation above.
    condition     = var.builtin_auth_recovery_until == null ? true : try(timecmp(var.builtin_auth_recovery_until, timeadd(plantimestamp(), "60m")) <= 0, true)
    error_message = "builtin_auth_recovery_until must be at most 60 minutes after the plan: the gate may be off for at most 60 minutes per apply. Set a time no later than 60 minutes from now, and plan again if the window must be extended."
  }
}
