# Inputs read by auth.tf: the OIDC identity provider, the break-glass owner and the BFF's DPoP key.

variable "oidc_tenant_id" {
  type        = string
  default     = null
  description = "Your Microsoft Entra tenant (directory) id, when Entra is your identity provider. Set it and the three endpoints below default to that tenant's single-tenant v2.0 values: oidc_authority and oidc_allowed_issuers to https://login.microsoftonline.com/<tenant>/v2.0, oidc_jwks_uri to https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys. Any of the three you set yourself wins. Leave null for another identity provider, or for a multitenant Entra registration, and set the three explicitly."

  validation {
    condition     = var.oidc_tenant_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.oidc_tenant_id))
    error_message = "oidc_tenant_id must be a tenant id (a GUID such as 00000000-0000-0000-0000-000000000000), not a domain name. Find it as Directory (tenant) ID on the app registration's overview."
  }
}

variable "oidc_allowed_issuers" {
  type        = string
  default     = null
  description = "Comma-separated allowlist of acceptable token `iss` values — the trust boundary. Defaults from oidc_tenant_id when that is set. Entra v2.0: https://login.microsoftonline.com/{tenant_id}/v2.0. Normally ONE entry: this install's own issuer. Every entry is trusted install-wide, so do not add a customer tenant here to onboard them — register an org-scoped SSO connection in the product instead, which is bound to the Organizations that registered it."
}

variable "oidc_audience" {
  type        = string
  default     = null
  description = "Audience the ID token must carry. Null (the default) uses oidc_client_id: the backend verifies the ID token the BFF obtained, whose audience is that same client id, so one app registration serves both. Set it only if your identity provider issues tokens for a different audience."
}

variable "oidc_jwks_uri" {
  type        = string
  default     = null
  description = "The IdP's signing-key endpoint. Defaults from oidc_tenant_id when that is set. Entra multitenant: https://login.microsoftonline.com/organizations/discovery/v2.0/keys."
}

variable "oidc_authority" {
  type        = string
  default     = null
  description = "The IdP's discovery base for the BFF. Defaults from oidc_tenant_id when that is set. For example https://login.microsoftonline.com/organizations/v2.0 — /.well-known/openid-configuration is appended."
}

variable "oidc_redirect_uri" {
  type        = string
  default     = null
  description = "The BFF callback the IdP redirects to: https://<frontend host>/api/auth/callback. With frontend_custom_domain set, leave it null: the module derives https://<hostname>/api/auth/callback, which you register at your IdP before the first apply, and a production install is one apply; a value set alongside the custom domain must name the same host, and the derived value is the one the frontend gets. Without a custom domain the frontend FQDN is an output of the first apply, so a production install is two applies, both with identity_binding=oidc: apply 1 carries a placeholder (e.g. https://redirect-not-yet-known.invalid/api/auth/callback — read only during sign-in, never at boot), then read frontend_url, register https://<frontend host>/api/auth/callback at your IdP, set it here and apply again. Do not bring production up on the dev identity binding and switch afterwards: that second apply changes identity and the production posture at once, on a running install. See examples/production."

  # The redirect and the bound hostname cannot disagree: a callback to a host the install does
  # not serve breaks sign-in, or sends the authorization code somewhere else. The whole authority
  # is read: user information (anything before an @) is refused, since in
  # https://<hostname>:443@other.example/ the host is other.example, not <hostname>.
  validation {
    condition = var.oidc_redirect_uri == null ? true : (
      var.frontend_custom_domain == null ? true : (
        !strcontains(try(regex("^https://([^/?#]*)", var.oidc_redirect_uri)[0], "@"), "@") &&
        lower(replace(try(regex("^https://([^/?#]*)", var.oidc_redirect_uri)[0], ""), "/:[0-9]*$/", "")) == var.frontend_custom_domain.hostname
      )
    )
    error_message = "oidc_redirect_uri must be an https:// URL on frontend_custom_domain.hostname, with no user information (@) in its authority, when both are set; leave oidc_redirect_uri null and the module derives https://<hostname>/api/auth/callback."
  }
}

variable "breakglass_owner_email" {
  type        = string
  default     = null
  description = "Break-glass local Owner (ADR 0024): IdP-independent emergency sign-in for an email that already holds the Owner role — recovery, not bootstrap (the endpoint answers 403 until that member exists). Armed only when both breakglass inputs are set; initial_owner_email remains the bootstrap. Null (the default) uses initial_owner_email once breakglass_secret_hash is set, which is the usual choice: that address becomes the first Owner, so it is the one break-glass can admit. Without a hash it stays unset, as before."
}

# --- The BFF's DPoP key ------------------------------------------------------------------
# The frontend's BFF proves possession of a key on every call it makes to the api for a signed-in
# user (DPoP), and the api binds each session to the key that proved its sign-in. auth.tf
# generates the key, rotates it, and hands it to ca-frontend alone. docs/identity.md, "The BFF's
# DPoP key", has the rotation and where the key is held.

variable "enable_bff_dpop_key" {
  type        = bool
  default     = false
  description = "Generate the BFF's DPoP signing key (EC P-256) and hand it to ca-frontend alone, as MASTERLY_BFF_DPOP_KEY (PKCS#8 PEM). The module replaces it every 90 days, at the first apply after the period ends, and keeps the outgoing key on ca-frontend as MASTERLY_BFF_DPOP_KEY_PREVIOUS for 60 minutes after each rotation, so sessions bound to it survive the change; the first apply after those 60 minutes removes it. Applying at least monthly keeps the slots about 90 days apart. If a slot expires inside the other slot's overlap, the older key's overlap is shortened to the gap between rotations; the key current just before the second rotation becomes MASTERLY_BFF_DPOP_KEY_PREVIOUS. If both slots expire before the next apply, both keys are replaced together without retaining the outgoing key, and users must sign in again once. With enable_key_vault the key is a Key Vault secret that ca-frontend reads with its own identity, which holds Key Vault Secrets User on that secret alone; without it, a Container App secret on ca-frontend. The private key is held in Terraform state. Off (default): the frontend generates a key per process, so DPoP-bound sessions do not survive a restart and cannot span frontend replicas. The key takes effect with the first frontend release after v0.145.0; the api's session binding and DPoP replay cache arrive with the first api release after v0.137.0, so on earlier images the key is set but unread. The api's DPoP replay cache has Azure Managed Redis (redis_offering = \"managed\", with enable_redis) as its target; the in-memory cache it uses without Redis is allowed on one api replica only, which api_max_replicas enforces."
}
