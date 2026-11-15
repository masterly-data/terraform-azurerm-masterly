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

# --- The BFF's DPoP key (enable_bff_dpop_key) ---------------------------------------------
# The frontend's BFF signs a DPoP proof with this key on every call it makes to the api for a
# signed-in user, and the api binds the session to the key that proved the sign-in. The frontend
# reads it as MASTERLY_BFF_DPOP_KEY (EC P-256, PKCS#8 PEM) and, during a rotation, the outgoing key
# as MASTERLY_BFF_DPOP_KEY_PREVIOUS. Without it the frontend generates a key per process, so a
# session does not survive a restart and cannot move between frontend replicas. Only ca-frontend
# carries it: the api reads no BFF key, it checks each proof against the session's binding.
#
# Two slots, A and B, each a key replaced when its own timer expires. Each timer runs for twice the
# rotation period, and B's expires halfway through A's, so one of the two is replaced every 90
# days. The current key is the slot replaced last; the other slot is the outgoing key, kept on
# ca-frontend for the overlap after a rotation and then only in the vault or the app's secrets,
# unread, until its own timer replaces it. Both slots exist whenever the switch is on, so a
# rotation changes secret VALUES and which secret each env name points at, and never deletes a
# Key Vault secret: with purge protection a deleted secret's name stays taken until it is purged.
#
# A timer expires on the clock but the key is replaced by an apply: the first apply after the
# rotation date replaces it, and an install nobody applies keeps its key. The private key is held
# in Terraform state, as every other secret the module generates is.

resource "time_rotating" "bff_dpop_key_a" {
  count = var.enable_bff_dpop_key ? 1 : 0

  rotation_days = local.bff_dpop_key_slot_days
}

# B's first expiry is halfway through A's, and each later one is 90 days either side of A's
# expiry as it stands when B is replaced: before it when that is still at least 45 days away,
# otherwise after it. So the two stay about 90 days apart, and a late apply that replaces A
# later than planned moves B's next expiry with it rather than replacing the two together.
# The time is worked out only when B is created: ignore_changes keeps a later plan, which sees a
# later plan time, from replacing B.
resource "time_rotating" "bff_dpop_key_b" {
  count = var.enable_bff_dpop_key ? 1 : 0

  rotation_rfc3339 = (
    timecmp(timeadd(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, "-${local.bff_dpop_key_rotation_days * 24}h"), timeadd(plantimestamp(), "${local.bff_dpop_key_rotation_days * 12}h")) > 0
    ? timeadd(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, "-${local.bff_dpop_key_rotation_days * 24}h")
    : timeadd(time_rotating.bff_dpop_key_a[0].rotation_rfc3339, "${local.bff_dpop_key_rotation_days * 24}h")
  )

  lifecycle {
    ignore_changes = [rotation_rfc3339]
  }
}

# Refresh removes an expired timer from state, so its next action is create, which does not
# trigger replace_triggered_by. Persist its start in terraform_data: the new start updates that
# existing resource, and that update replaces the key, including on a normal expiry.
resource "terraform_data" "bff_dpop_key_a_rotation" {
  count = var.enable_bff_dpop_key ? 1 : 0

  input = time_rotating.bff_dpop_key_a[0].rfc3339
}

resource "terraform_data" "bff_dpop_key_b_rotation" {
  count = var.enable_bff_dpop_key ? 1 : 0

  input = time_rotating.bff_dpop_key_b[0].rfc3339
}

resource "tls_private_key" "bff_dpop_key_a" {
  count = var.enable_bff_dpop_key ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"

  lifecycle {
    replace_triggered_by = [terraform_data.bff_dpop_key_a_rotation[count.index]]
  }
}

resource "tls_private_key" "bff_dpop_key_b" {
  count = var.enable_bff_dpop_key ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"

  lifecycle {
    replace_triggered_by = [terraform_data.bff_dpop_key_b_rotation[count.index]]
  }
}

locals {
  # A new key every 90 days; each slot's timer runs for two periods.
  bff_dpop_key_rotation_days = 90
  bff_dpop_key_slot_days     = local.bff_dpop_key_rotation_days * 2

  # How long the outgoing key stays on ca-frontend after a rotation. At least 45 minutes: a
  # session renews within 15, and ACA re-reads a versionless Key Vault reference within 30.
  bff_dpop_key_overlap_minutes = 60

  # Both slots whenever the switch is on, whatever the clock says: these names drive the vault
  # secrets and the frontend's grants, which a rotation must never remove.
  bff_dpop_key_secret_names = var.enable_bff_dpop_key ? ["bff-dpop-key-a", "bff-dpop-key-b"] : []

  bff_dpop_key_a_start = one(time_rotating.bff_dpop_key_a[*].rfc3339)
  bff_dpop_key_b_start = one(time_rotating.bff_dpop_key_b[*].rfc3339)

  # The slot replaced last is the current key. B counts as later only by more than the overlap:
  # the first apply creates B a moment after A, and A is the key that apply hands out, so that B's
  # first replacement keeps A, the key in use, as the outgoing one. The try()s turn the switch
  # being off (no slot) into slot A and no overlap; the env refs below are empty then anyway.
  bff_dpop_key_b_is_current  = try(timecmp(local.bff_dpop_key_b_start, timeadd(local.bff_dpop_key_a_start, "${local.bff_dpop_key_overlap_minutes}m")) > 0, false)
  bff_dpop_key_current       = local.bff_dpop_key_b_is_current ? "bff-dpop-key-b" : "bff-dpop-key-a"
  bff_dpop_key_previous      = local.bff_dpop_key_b_is_current ? "bff-dpop-key-a" : "bff-dpop-key-b"
  bff_dpop_key_current_start = local.bff_dpop_key_b_is_current ? local.bff_dpop_key_b_start : local.bff_dpop_key_a_start
  bff_dpop_key_other_start   = local.bff_dpop_key_b_is_current ? local.bff_dpop_key_a_start : local.bff_dpop_key_b_start

  # The outgoing key is on ca-frontend while this plan is within the overlap after the current
  # key's rotation, and only if the other slot was in use before it: on the first apply both
  # slots are created together and neither has signed anything. The first plan after the overlap
  # drops it, as builtin_auth_recovery_until's does (builtin-auth.tf).
  bff_dpop_key_previous_open = try(
    timecmp(timeadd(local.bff_dpop_key_other_start, "${local.bff_dpop_key_overlap_minutes}m"), local.bff_dpop_key_current_start) < 0 &&
    timecmp(plantimestamp(), timeadd(local.bff_dpop_key_current_start, "${local.bff_dpop_key_overlap_minutes}m")) < 0,
    false,
  )

  # ca-frontend's env names for the key: the two names the frontend reads, each pointing at a slot.
  bff_dpop_key_env_secret_refs = var.enable_bff_dpop_key ? merge(
    { MASTERLY_BFF_DPOP_KEY = local.bff_dpop_key_current },
    local.bff_dpop_key_previous_open ? { MASTERLY_BFF_DPOP_KEY_PREVIOUS = local.bff_dpop_key_previous } : {},
  ) : {}
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
