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
