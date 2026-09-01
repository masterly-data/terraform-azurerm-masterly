# Inputs of the Masterly self-hosted install module (Layer 5).
# Consumed as: source = "github.com/masterly-data/terraform-azurerm-masterly?ref=vX.Y.Z"

variable "name_prefix" {
  type        = string
  default     = "masterly"
  description = "Prefix for install-local resource names (rg-<prefix>-aca, ca-api, …). Customer installs keep the default per the naming conventions (rg-masterly-<purpose>)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphens, starting with a letter, max 21 chars."
  }
}

variable "mode" {
  type        = string
  default     = "demo"
  description = "The app's startup posture (ADR 0066): demo (dev-shaped seams on real infrastructure — evaluation) or production (crash-fast; every seam durable). production wires MASTERLY_CONTROLPLANE_STORE=postgres and requires the inputs below."

  validation {
    condition     = contains(["demo", "production"], var.mode)
    error_message = "mode must be \"demo\" or \"production\"."
  }

  # Mirror of the app's production posture: refuse at plan what the app would refuse at
  # boot, so a misconfigured install fails in terraform, not in a crash loop.
  validation {
    condition = var.mode != "production" || (
      var.identity_binding == "oidc" &&
      var.license_token != null &&
      var.license_public_jwk != null &&
      var.enable_key_vault &&
      var.enable_redis &&
      # enable_redis alone is not enough to guarantee a session registry: the offering selects
      # which of the two Redis resources is actually provisioned, and an unset one provisions
      # neither. Checked here as well as on the variable so production cannot reach a plan
      # where enable_redis is true and no cache exists.
      var.redis_offering != null
    )
    error_message = "mode=production requires identity_binding=oidc, license_token + license_public_jwk, enable_key_vault, and enable_redis with redis_offering set (ADR 0066, ADR 0071) — the app refuses fixture seams in production."
  }

  # An install nobody can sign into is worse than a refused apply. The one-shot Owner
  # bootstrap is the only way the FIRST Owner of a fresh production install comes into
  # existence: the control-plane store mints it on the first sign-in whose email matches
  # MASTERLY_INITIAL_OWNER_EMAIL (app backend core/controlplane_pg.py), and every other route
  # to membership — invitation, SCIM, role grant — needs an Owner to perform it. Break-glass
  # is not a second bootstrap: that route resolves the caller's Owner membership before it
  # mints a session (app backend api/routes/v1/auth.py), so on an install with no member row
  # it answers 403 however the two break-glass inputs are set. Unlike the guards above, this
  # one is not mirrored by the app: at boot it cannot tell a fresh install from one that
  # already has an Owner without reading the control plane, so plan time is the only place
  # the lockout can be caught.
  validation {
    condition     = var.mode != "production" || var.initial_owner_email != null
    error_message = "mode=production requires initial_owner_email — the one-shot Owner bootstrap (ADR 0066) is the only way the first Owner of a fresh install is created, so without it the apply yields an install nobody can sign into. Break-glass is not a substitute: it admits an email that already holds the Owner role. On an install that already has an active Owner the input is a harmless no-op (the rule is permanently disarmed)."
  }
}

variable "org_name" {
  type        = string
  default     = null
  description = "Display name of the Organization (production bootstrap, ADR 0066). Null = org_id."
}

variable "initial_owner_email" {
  type        = string
  default     = null
  description = "One-shot Owner bootstrap (ADR 0066): the first sign-in with this email becomes the Organization's Owner; the rule disarms permanently once an active Owner exists. Required by mode=production — it is the only path to the first Owner. Break-glass is not an alternative to it: that route admits an email that already holds the Owner role (set breakglass_owner_email to this same address to make break-glass usable from day one)."
}

variable "location" {
  type        = string
  description = "Azure region for every resource of this install (the install is region-pinned — the Environment's geo)."
}

variable "masterly_region" {
  type        = string
  default     = "eu"
  description = "The Masterly geo of this install (eu | us) — the data-residency boundary, surfaced to the apps as MASTERLY_REGION."
}

# --- Install identity (ADR 0039) -------------------------------------------------
# An Install is one deployment of the stack (this module) hosting a set of an Org's
# Environments: Organization 1—N Install 1—N Environment. These inputs identify the Install
# and its owning Org for the control plane / license and the Org-level Install registry.
# Recorded as resource tags + outputs today; consumed by the app when that wiring lands (the
# app currently hardcodes ALLOWED_REGIONS and uses a fixture Org — app backend controlplane.py).

variable "org_id" {
  type        = string
  description = "Logical id of the Organization that owns this Install (ADR 0039), e.g. \"org_acme\". Ties multiple Installs of one customer together in the Org-level registry."

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,40}$", var.org_id))
    error_message = "org_id must be lowercase alphanumeric/underscore/hyphen, starting with a letter, max 41 chars."
  }
}

variable "install_id" {
  type        = string
  description = "Stable slug identifying this Install within its Organization (ADR 0039), e.g. \"prod\" or \"non-prod\". The logical identity surfaced to the control plane/license; for multiple Installs co-located in one subscription, also set name_prefix to include it so resource names stay collision-free."

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,40}$", var.install_id))
    error_message = "install_id must be lowercase alphanumeric/underscore/hyphen, starting with a letter, max 41 chars."
  }
}

variable "allowed_regions" {
  type        = list(string)
  default     = ["eu", "us"]
  description = "Data-residency geos in which Environments may be created in this Install (ADR 0031/0039) — wired as MASTERLY_ALLOWED_REGIONS and enforced by the app at Environment creation. Region is pinned per Environment and immutable; narrow to this install's geo (e.g. [\"eu\"])."
}

variable "api_image" {
  type        = string
  description = "Fully-qualified api image (registry/repo:tag). Seeds the app; CD owns the running tag thereafter."
}

variable "frontend_image" {
  type        = string
  description = "Fully-qualified frontend image (registry/repo:tag). Seeds the app; CD owns the running tag thereafter."
}

variable "acr_login_server" {
  type        = string
  default     = "masterly.azurecr.io"
  description = "Registry the install pulls images from (managed identity)."
}

variable "registry_username" {
  type        = string
  default     = null
  description = "Credential-based image pull (ADR 0067, option 1 — direct pull from Masterly's registry): the per-customer service principal's appId, from the install bundle. Null = managed-identity pull (option 2 — your own ACR via acr_login_server/acr_id, or a Masterly-operated install)."

  validation {
    condition     = (var.registry_username == null) == (var.registry_password == null)
    error_message = "registry_username and registry_password must be set together (both from the install bundle) or both omitted."
  }
}

variable "registry_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "The pull service principal's client secret (ADR 0067). Stored as a Container App secret on every app; rotate by flipping to the customer's second active secret."
}

variable "acr_id" {
  type        = string
  default     = null
  description = "Resource ID of the registry, for the AcrPull role assignment on the install identity. Null skips the assignment (grant pull access out of band). The deploying principal needs roleAssignments/write on the registry's scope."
}

variable "ingress_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDRs allowed to reach the frontend's public ingress. Empty = unrestricted (ACA semantics). The demo install pins this to the operator's IP until real authentication lands."
}

# --- Identity (ADR 0024) ------------------------------------------------------------
# The self-hosted identity path is `oidc`: the customer's own IdP (Entra, Okta, Keycloak —
# anything publishing OIDC discovery). `dev` is the evaluation binding and is only
# representable behind an ingress IP allowlist. `stytch` is Masterly-hosted-tier wiring
# and not selectable here.

variable "identity_binding" {
  type        = string
  default     = "dev"
  description = "Identity adapter the apps run (ADR 0024): `oidc` (customer IdP — production) or `dev` (evaluation; requires ingress_allowed_cidrs)."

  validation {
    condition     = contains(["dev", "oidc"], var.identity_binding)
    error_message = "identity_binding must be \"dev\" or \"oidc\"."
  }

  # The unsafe combination is unrepresentable: dev identity accepts anyone, so it may
  # only run behind an IP allowlist.
  validation {
    condition     = var.identity_binding != "dev" || length(var.ingress_allowed_cidrs) > 0
    error_message = "identity_binding=dev is the evaluation identity — it must be paired with a non-empty ingress_allowed_cidrs, or switch to identity_binding=oidc."
  }

  # oidc needs both halves configured: backend token verification + frontend BFF client.
  validation {
    condition = var.identity_binding != "oidc" || (
      var.oidc_allowed_issuers != null &&
      var.oidc_audience != null &&
      var.oidc_jwks_uri != null &&
      var.oidc_client_id != null &&
      var.oidc_client_secret != null &&
      var.oidc_authority != null &&
      var.oidc_redirect_uri != null
    )
    error_message = "identity_binding=oidc requires oidc_allowed_issuers, oidc_audience, oidc_jwks_uri (backend verification) and oidc_client_id, oidc_client_secret, oidc_authority, oidc_redirect_uri (frontend BFF client)."
  }
}

variable "oidc_allowed_issuers" {
  type        = string
  default     = null
  description = "Comma-separated allowlist of acceptable token `iss` values — the trust boundary. Entra v2.0: https://login.microsoftonline.com/{tenant_id}/v2.0, one per trusted tenant."
}

variable "oidc_audience" {
  type        = string
  default     = null
  description = "Audience the ID token must carry (the IdP app registration's client id)."
}

variable "oidc_jwks_uri" {
  type        = string
  default     = null
  description = "The IdP's signing-key endpoint. Entra multitenant: https://login.microsoftonline.com/organizations/discovery/v2.0/keys."
}

variable "oidc_client_id" {
  type        = string
  default     = null
  description = "OIDC client id of the frontend BFF's confidential client."
}

variable "oidc_client_secret" {
  type        = string
  default     = null
  sensitive   = true
  description = "OIDC client secret of the frontend BFF's confidential client. Used only server-side at token exchange; stored as a Container App secret."
}

variable "oidc_authority" {
  type        = string
  default     = null
  description = "The IdP's discovery base for the BFF, e.g. https://login.microsoftonline.com/organizations/v2.0 — /.well-known/openid-configuration is appended."
}

variable "oidc_redirect_uri" {
  type        = string
  default     = null
  description = "The BFF callback the IdP redirects to: https://<frontend host>/api/auth/callback. Without a custom domain the frontend FQDN is only known after the first apply — bootstrap with identity_binding=dev (allowlisted), read frontend_url, then flip to oidc."
}

variable "oidc_scopes" {
  type        = string
  default     = null
  description = "Space-delimited OIDC scopes for the BFF. Null = the app default (\"openid profile email\")."
}

variable "breakglass_owner_email" {
  type        = string
  default     = null
  description = "Break-glass local Owner (ADR 0024): IdP-independent emergency sign-in for an email that already holds the Owner role — recovery, not bootstrap (the endpoint answers 403 until that member exists). Armed only when both breakglass inputs are set; initial_owner_email remains the bootstrap."
}

variable "breakglass_secret_hash" {
  type        = string
  default     = null
  sensitive   = true
  description = "sha256 hash of the break-glass secret (never the secret itself)."
}

# --- License (ADR 0013/0018) --------------------------------------------------------
# The install's entitlement: a platform-minted ES256 JWT plus the issuer's PUBLIC JWK.
# Both arrive in the customer's install bundle. Unset = the app's fixture license
# (evaluation); a configured-but-invalid license crashes the install at startup.

variable "license_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "The install's license JWT (ES256, from the install bundle). Stored as a Container App secret."
}

variable "license_public_jwk" {
  type        = string
  default     = null
  description = "The license issuer's public JWK (JSON) used to verify license_token. Public material — plain env, not a secret."
}

# --- Data plane seam (ADR 0065) -----------------------------------------------------

variable "external_database_url" {
  type        = string
  default     = null
  sensitive   = true
  description = "BYO-DB: the install-level SQLAlchemy async DSN (postgresql+asyncpg://…) of the customer's own Postgres (role needs CREATEDB — the api creates one database per Masterly Environment, ADR 0003). When set, the module provisions NO database: no Flexible Server, no private endpoint, no Postgres private DNS zone — network reachability is the customer's responsibility. Null (default) provisions the starter Postgres Flexible Server. The postgres_* inputs are ignored when set."
}

variable "postgres_sku_name" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "Postgres Flexible Server SKU (burstable B1ms default — demo/small-install sized). Burstable SKUs do not support zone-redundant HA; mode=production refuses them on the provisioned starter server."

  # Refuse the dev-grade burstable default in production (ADR 0066): burstable SKUs run on
  # CPU credits and cannot carry zone-redundant HA — unfit for a production data plane. Only
  # bites when the module actually provisions the starter server (BYO-DB ignores this input).
  validation {
    condition     = var.mode != "production" || var.external_database_url != null || !can(regex("^B_", var.postgres_sku_name))
    error_message = "mode=production refuses a burstable Postgres SKU (B_*) on the provisioned starter server — set postgres_sku_name to a General Purpose (GP_*) or Memory Optimized (MO_*) SKU, e.g. \"GP_Standard_D2ds_v5\", or bring your own database via external_database_url."
  }
}

variable "postgres_storage_mb" {
  type        = number
  default     = 32768
  description = "Postgres storage in MB."
}

variable "postgres_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL major version."
}

variable "postgres_backup_retention_days" {
  type        = number
  default     = 7
  description = "Backup retention of the provisioned Postgres server (7-35 days)."

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 35
    error_message = "postgres_backup_retention_days must be between 7 and 35."
  }

  # Production floor (ADR 0066): the 7-day dev default is too short for a production data
  # plane. Only bites on the provisioned starter server (BYO-DB owns its own retention).
  validation {
    condition     = var.mode != "production" || var.external_database_url != null || var.postgres_backup_retention_days >= 14
    error_message = "mode=production requires postgres_backup_retention_days >= 14 on the provisioned starter server (the 7-day default is dev-grade)."
  }
}

variable "postgres_geo_redundant_backup" {
  type        = bool
  default     = false
  description = "Geo-redundant backups for the provisioned Postgres server. CAUTION: replicates backups to the paired Azure region — verify that region satisfies the install's data-residency boundary before enabling."
}

variable "postgres_zone_redundant_ha" {
  type        = bool
  default     = false
  description = "Zone-redundant high availability for the provisioned Postgres server (standby in another AZ, same region). Requires a General Purpose or Memory Optimized SKU — not supported on the burstable default. Required by mode=production on the provisioned starter server."

  # Production requires an HA standby on the provisioned starter server (ADR 0066). Pairs
  # with the non-burstable SKU guard above — both must be satisfied together. BYO-DB owns
  # its own availability posture, so this only bites when the module provisions Postgres.
  validation {
    condition     = var.mode != "production" || var.external_database_url != null || var.postgres_zone_redundant_ha
    error_message = "mode=production requires postgres_zone_redundant_ha=true on the provisioned starter server (with a General Purpose or Memory Optimized postgres_sku_name), or bring your own HA database via external_database_url."
  }
}

variable "postgres_private_dns_zone_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing privatelink.postgres.database.azure.com private DNS zone (hub-and-spoke landing zones that centralize private DNS and deny zone creation in spokes). When set, the module creates no zone and no VNet link — linking this VNet to the central zone (or DINE policy) is the platform team's side. Null (default) creates a per-install zone + link."
}

variable "api_max_replicas" {
  type        = number
  default     = 1
  description = "Maximum api replicas. > 1 requires enable_redis: sessions must live in the redis registry to hold across replicas (ADR 0066). mode=production requires >= 2 (no single-replica production api)."

  validation {
    condition     = var.api_max_replicas == 1 || var.enable_redis
    error_message = "api_max_replicas > 1 requires enable_redis — the in-memory session registry cannot span replicas (ADR 0066)."
  }

  validation {
    condition     = var.api_max_replicas >= 1
    error_message = "api_max_replicas must be at least 1."
  }

  # No single-replica production api (ADR 0066): a lone replica is a single point of failure
  # and takes downtime on every revision roll. production already mandates enable_redis, so
  # scaling out is representable.
  validation {
    condition     = var.mode != "production" || var.api_max_replicas >= 2
    error_message = "mode=production requires api_max_replicas >= 2 (a single api replica is a single point of failure and takes downtime on every deploy); enable_redis is already required in production, so the multi-replica session registry is available."
  }
}

variable "api_min_replicas" {
  type        = number
  default     = 1
  description = "Minimum api replicas. 0 enables scale-to-zero (ACA's default HTTP scale rule wakes the app on the next request) — a cost posture for idle installs. Costs of 0 without enable_redis: the in-memory session registry is dropped when the last replica stops (users re-login), and the in-process worker loop only polls while a replica is up, so async jobs stall until the next HTTP request."

  validation {
    condition     = var.api_min_replicas >= 0
    error_message = "api_min_replicas must be at least 0."
  }

  validation {
    condition     = var.api_min_replicas <= var.api_max_replicas
    error_message = "api_min_replicas must not exceed api_max_replicas."
  }

  # No cold starts in production: a scaled-to-zero api takes seconds of wake latency on the
  # first request, and production already requires api_max_replicas >= 2.
  validation {
    condition     = var.mode != "production" || var.api_min_replicas >= 1
    error_message = "mode=production requires api_min_replicas >= 1 — scale-to-zero adds cold-start latency on the first request after idle."
  }
}

variable "frontend_min_replicas" {
  type        = number
  default     = 1
  description = "Minimum frontend replicas. 0 enables scale-to-zero (wakes on the next request) — a cost posture for idle installs. The frontend is stateless beyond its BFF session cookie handling, so the only cost of 0 is cold-start latency."

  validation {
    condition     = var.frontend_min_replicas >= 0
    error_message = "frontend_min_replicas must be at least 0."
  }

  validation {
    condition     = var.mode != "production" || var.frontend_min_replicas >= 1
    error_message = "mode=production requires frontend_min_replicas >= 1 — scale-to-zero adds cold-start latency on the first request after idle."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource (merge the required governance tags here: cost-center, data-residency, deployment-model, owner, lifecycle)."
}

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.20.0.0/16"]
  description = "Address space of the install's VNet. The runtime subnet (/23, required by consumption-only Container App Environments) and the private-endpoint subnet (/24) are carved from the first prefix unless explicit subnet prefixes are set."

  # Deriving the subnets needs room to carve a /23 plus a /24 at the layout the module
  # uses; a first prefix smaller than /21 must bring explicit subnet prefixes instead.
  validation {
    condition = (
      (var.aca_subnet_prefix != null && var.private_endpoints_subnet_prefix != null) ||
      tonumber(split("/", var.vnet_address_space[0])[1]) <= 21
    )
    error_message = "Subnets are derived from the first VNet prefix only when it is /21 or larger. For a smaller address space (enterprise IPAM allocations), set aca_subnet_prefix (a /23 or larger — ACA consumption requirement) and private_endpoints_subnet_prefix explicitly."
  }
}

variable "aca_subnet_prefix" {
  type        = string
  default     = null
  description = "Explicit CIDR of the ACA runtime subnet (must be /23 or larger and inside vnet_address_space). Null (default) derives the first /23 of the first VNet prefix."
}

variable "private_endpoints_subnet_prefix" {
  type        = string
  default     = null
  description = "Explicit CIDR of the private-endpoints subnet (inside vnet_address_space, clear of the runtime subnet). Null (default) derives a /24 clear of the runtime /23."
}

# --- Async bus (ADR 0029) ---------------------------------------------------------
# Default off: the install runs the polling binding (the per-Environment Postgres queue is
# the bus), so no broker is provisioned or billed. Enable to provision an Azure Service Bus
# namespace + queue and flip the apps to the servicebus binding (managed-identity auth).

variable "enable_service_bus" {
  type        = bool
  default     = false
  description = "Provision Azure Service Bus and run the apps on the servicebus bus binding (ADR 0029). Off = the polling binding (Postgres queue), which needs no broker and runs air-gapped."
}

variable "servicebus_sku" {
  type        = string
  default     = "Standard"
  description = "Service Bus namespace SKU (Basic has no topics/sessions; Standard is the small-install default)."

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.servicebus_sku)
    error_message = "servicebus_sku must be Basic, Standard, or Premium."
  }
}
