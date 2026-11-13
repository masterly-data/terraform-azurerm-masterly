# --- Application secrets (born in the install, never in Git) ---------------------

resource "random_password" "session_secret" {
  length  = 48
  special = false
}

# The BFF shared secret (MASTERLY_BFF_SHARED_SECRET), held by ca-api and ca-frontend and by no
# other app. A break-glass sign-in made in the GUI reaches the api from the frontend's BFF, not
# from the browser, so on its own the api sees a frontend replica's address: every GUI attempt
# then shares one throttle window, and the audit record names the replica. With this secret on
# both apps, the BFF states the browser's address and presents the secret to show it is this
# install's BFF; the api believes the address only on a request that carries the matching
# value, so a caller that does not hold it cannot choose its own address, on the internal hop
# or on a published api (api_ingress_external). Without the same value on both apps, the
# mechanism is off.
#
# The same shape as the session secret: 48 alphanumeric characters, above the 32 bytes the api
# requires at startup. To rotate it, replace it (`terraform apply
# -replace=random_password.bff_shared_secret`): one apply gives both apps the new value. Until
# both run with the same value the api ignores the BFF's statement and attributes GUI attempts
# to the frontend replica, as it did before this secret existed; nothing fails because of the
# mismatch itself.
resource "random_password" "bff_shared_secret" {
  length  = 48
  special = false
}

locals {
  # The identity provider's endpoints: an explicit input wins, otherwise derived from
  # oidc_tenant_id for a single-tenant Entra registration, otherwise null (and the oidc
  # validation in variables-core.tf has already refused that combination).
  oidc_tenant_base     = var.oidc_tenant_id == null ? null : "https://login.microsoftonline.com/${var.oidc_tenant_id}"
  oidc_authority       = var.oidc_authority != null ? var.oidc_authority : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/v2.0")
  oidc_allowed_issuers = var.oidc_allowed_issuers != null ? var.oidc_allowed_issuers : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/v2.0")
  oidc_jwks_uri        = var.oidc_jwks_uri != null ? var.oidc_jwks_uri : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/discovery/v2.0/keys")
  oidc_audience        = var.oidc_audience != null ? var.oidc_audience : var.oidc_client_id

  # With a custom domain the BFF callback is known before any apply: the hostname the install is
  # served on, which oidc_redirect_uri may not contradict (variables-auth.tf). Without one it is the
  # input, set from frontend_url on the second apply.
  oidc_redirect_uri = local.frontend_custom_hostname != null ? "https://${local.frontend_custom_hostname}/api/auth/callback" : var.oidc_redirect_uri

  # Break-glass admits an address that already holds the Owner role, and the first Owner is
  # initial_owner_email, so that is the default once a hash arms it. The presence test is
  # unmarked (the hash is sensitive, whether one was given is not), as for the secret names.
  breakglass_owner_email = var.breakglass_owner_email != null ? var.breakglass_owner_email : (
    nonsensitive(var.breakglass_secret_hash != null) ? var.initial_owner_email : null
  )
}
