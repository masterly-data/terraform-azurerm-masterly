# The install's Redis (ADR 0066 increment 3, amended by ADR 0071) — cache/ephemeral state
# (hard constraint 4) and the multi-replica session registry. Opt-in (default off; dev/demo run
# the in-memory registry on a single api replica): when enabled, this provisions Redis, flips
# the apps to MASTERLY_SESSION_REGISTRY=redis, and unlocks api_max_replicas > 1.
#
# There are TWO Azure services behind that seam, chosen by redis_offering, because Microsoft
# took the old one away from new customers:
#
#   redis_offering = "managed"  -> Azure Managed Redis (Microsoft.Cache/redisEnterprise,
#                                 Balanced_* SKUs). Creatable by ANY tenant. This is the only
#                                 choice that works for an organization that has never run an
#                                 Azure Cache for Redis instance.
#   redis_offering = "cache"    -> Azure Cache for Redis (Microsoft.Cache/redis,
#                                 Basic/Standard/Premium). Since 1 April 2026 Microsoft blocks
#                                 creation of these for NEW customers — a tenant qualifies as
#                                 an existing customer only if some subscription in it held a
#                                 cache before that date — and retires them entirely on
#                                 30 September 2028. Kept only so a customer already running
#                                 one is not forced into a destroy-and-recreate.
#
# There is deliberately NO default. The module cannot tell a fresh tenant from a qualifying
# one, and both possible defaults fail in opposite directions: defaulting to "managed" would
# plan a destroy-and-recreate for an existing customer's running cache (the two are different
# ARM types, so no `moved` block can bridge them), and defaulting to "cache" would hand every
# new customer a plan that Azure refuses. An explicit choice is the only value with neither
# failure mode.
#
# Both offerings keep the same posture: NO public network presence, reachable only over a
# private endpoint in snet-private-endpoints with private DNS keeping the hostname resolvable
# inside the VNet. The zone name and the private-link subresource differ per offering (see
# local.redis_dns_zone_name / local.redis_subresource) — that matters to hub-and-spoke landing
# zones, which must pre-create the RIGHT zone.
#
# The connection URL carries the access key, so it travels as a Container App secret
# (MASTERLY_REDIS_URL via secret ref), never plain env.

variable "enable_redis" {
  type        = bool
  default     = false
  description = "Provision Redis and run the apps on the redis session registry (ADR 0066). Required for api_max_replicas > 1 and for mode=production. When true, redis_offering must also be set."
}

variable "redis_offering" {
  type        = string
  default     = null
  description = "Which Azure Redis service backs the session registry (ADR 0071): \"managed\" = Azure Managed Redis (Microsoft.Cache/redisEnterprise, Balanced_* — creatable by any tenant), \"cache\" = Azure Cache for Redis (Microsoft.Cache/redis, Basic/Standard/Premium — creatable only in tenants that already held a cache before 1 April 2026, retired 30 September 2028). No default on purpose: the module cannot tell a fresh tenant from a qualifying one, and both possible defaults fail silently in opposite directions."

  validation {
    # Two clauses, and both are load-bearing.
    #
    # coalesce() keeps the check TOTAL: null must reach the SECOND validation below, which is the
    # one that reports the required-when-enabled rule, instead of erroring here. It cannot be
    # replaced with `var.redis_offering == null || contains(...)` — Terraform does not
    # short-circuit `||`, so contains() still gets null and fails with "Invalid function
    # argument" for every caller who simply omits the variable.
    #
    # The explicit != "" closes the hole coalesce() opens: it treats the EMPTY STRING as absent
    # too. "" is not a spelling mistake a human makes, it is what a rendered tfvars template or
    # an unset TF_VAR_ pipeline variable produces. It substituted "managed" here, passed the
    # second validation ("" != null), and then matched NEITHER branch below — so every Redis
    # resource dropped to count 0 and the session registry was never set, silently, on a
    # production install with multiple api replicas. That is the ADR 0066 state this module
    # exists to refuse at plan time. (null != "" is true, so null still falls through.)
    condition     = var.redis_offering != "" && contains(["managed", "cache"], coalesce(var.redis_offering, "managed"))
    error_message = "redis_offering must be \"managed\" (Azure Managed Redis) or \"cache\" (Azure Cache for Redis)."
  }

  validation {
    condition     = !var.enable_redis || var.redis_offering != null
    error_message = "enable_redis = true requires redis_offering. Set \"managed\" for Azure Managed Redis (Balanced_B0 default) — this is the only choice that works if your tenant has never held an Azure Cache for Redis instance, because Microsoft blocked Basic/Standard/Premium creation for new customers on 1 April 2026 and there is no self-service exception. Set \"cache\" only to keep an existing Azure Cache for Redis instance you already run; it is retired 30 September 2028."
  }
}

variable "redis_sku_name_managed" {
  type        = string
  default     = "Balanced_B0"
  description = "Azure Managed Redis SKU (redis_offering = \"managed\"). Balanced_B0 = 0.5 GB, the smallest — the session registry is cache/ephemeral. Sizing is encoded in the SKU name; there is no separate capacity input on this path."

  validation {
    # Enterprise_* / EnterpriseFlash_* live on the SAME ARM type as the Azure Managed Redis
    # SKUs, so they are an easy and expensive mistake to make here. Their creation has been
    # blocked for EVERYONE since 1 April 2026 and they retire 31 March 2027. The provider
    # rejects them too, but without saying why.
    condition     = !startswith(var.redis_sku_name_managed, "Enterprise_") && !startswith(var.redis_sku_name_managed, "EnterpriseFlash_")
    error_message = "redis_sku_name_managed must be an Azure Managed Redis SKU (Balanced_*, MemoryOptimized_*, ComputeOptimized_*, FlashOptimized_*). The Enterprise_* and EnterpriseFlash_* SKUs share the same ARM type but their creation has been blocked since 1 April 2026 and they retire 31 March 2027."
  }
}

variable "redis_sku_name" {
  type        = string
  default     = "Basic"
  description = "Azure Cache for Redis SKU — legacy path only (redis_offering = \"cache\"); ignored on the managed path. Basic C0 default — cache/ephemeral only; sessions tolerate a restart."

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.redis_sku_name)
    error_message = "redis_sku_name must be Basic, Standard, or Premium."
  }
}

variable "redis_capacity" {
  type        = number
  default     = 0
  description = "Azure Cache for Redis capacity within the SKU family — legacy path only (redis_offering = \"cache\"); ignored on the managed path, where sizing is part of redis_sku_name_managed. 0 = C0, 250 MB."
}

variable "redis_private_dns_zone_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing Redis private DNS zone (hub-and-spoke landing zones that centralize private DNS and deny zone creation in spokes). THE ZONE NAME DEPENDS ON redis_offering: \"managed\" needs privatelink.redis.azure.net, \"cache\" needs privatelink.redis.cache.windows.net — they are different services and a zone of the wrong name will not resolve. When set, the module creates no zone and no VNet link — linking this VNet to the central zone (or DINE policy) is the platform team's side. Null (default) creates a per-install zone + link when Redis is enabled."
}

locals {
  # The two offerings are mutually exclusive by construction: exactly one of these is true
  # whenever Redis is enabled, and both are false when it is not.
  use_managed_redis = var.enable_redis && var.redis_offering == "managed"
  use_legacy_redis  = var.enable_redis && var.redis_offering == "cache"

  # Everything downstream gates on THIS, not on var.enable_redis directly. For every valid
  # configuration the two are identical (redis_offering is required whenever enable_redis is
  # true). The difference shows up only in the invalid state enable_redis = true with no
  # offering: gating on the offering keeps every dependent resource at count 0, so the plan
  # reports the one error that explains the problem — the redis_offering validation — instead
  # of burying it under "private_connection_resource_id is required".
  redis_enabled = local.use_managed_redis || local.use_legacy_redis

  # Azure Managed Redis and Azure Cache for Redis are different private-link resources: a
  # different subresource (groupId) and a different private DNS zone. Getting either wrong
  # produces a private endpoint that connects to nothing or a hostname that does not resolve.
  redis_dns_zone_name = local.use_managed_redis ? "privatelink.redis.azure.net" : "privatelink.redis.cache.windows.net"
  redis_subresource   = local.use_managed_redis ? "redisEnterprise" : "redisCache"

  # one() over the splat rather than [0]: safe when the count is 0, whichever branch is taken.
  redis_resource_id = local.use_managed_redis ? one(azurerm_managed_redis.this[*].id) : one(azurerm_redis_cache.this[*].id)

  # Only create the Redis private DNS zone when we provision Redis and no central zone is
  # injected (mirrors the Postgres create_postgres_dns seam).
  create_redis_dns  = local.redis_enabled && var.redis_private_dns_zone_id == null
  redis_dns_zone_id = local.redis_enabled ? (var.redis_private_dns_zone_id != null ? var.redis_private_dns_zone_id : azurerm_private_dns_zone.redis[0].id) : null
}

# --- Offering "managed": Azure Managed Redis (Microsoft.Cache/redisEnterprise) --------------
#
# The path available to every tenant, and the one Microsoft directs customers to. Same
# resource provider (Microsoft.Cache) as the legacy cache, so this adds no new provider
# prerequisite for a fresh subscription.
resource "azurerm_managed_redis" "this" {
  count = local.use_managed_redis ? 1 : 0

  name                = "redis-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location

  sku_name = var.redis_sku_name_managed

  # No public presence: reachable only via the private endpoint below (mirrors the starter
  # Postgres). This must be SET, not inherited — the provider defaults it to "Enabled", so
  # omitting it silently ships a cache reachable from the internet. Azure Managed Redis has no
  # VNet injection and no IP firewall rules, so the private endpoint is the ONLY isolation
  # mechanism and this flag is the only thing closing the public door.
  public_network_access = "Disabled"

  # Set explicitly rather than inherited, because it is ForceNew: a later provider default
  # change, or an operator "tidying" it, would destroy and recreate the cache. Without HA
  # there is no replication, no zone redundancy, and no availability SLA.
  high_availability_enabled = true

  # There is no minimum_tls_version argument on this resource, and that is correct rather than
  # a gap: Azure Managed Redis supports only TLS 1.2 and 1.3, enforced service-side. The TLS
  # choice is client_protocol = "Encrypted" below.

  default_database {
    # NoEviction is a CORRECTNESS requirement, not cache tuning — carried forward unchanged
    # from the Azure Cache for Redis path below, because the reasoning has not changed and the
    # provider default is the same trap one level down.
    #
    # This database holds the session registry, and revocation is the part that matters: the
    # `sess:rev:{jti}` markers and the `sess:orgrev:{org}` epoch are the only record that a
    # session was killed — the bearer token stays cryptographically valid until its own expiry.
    # The provider defaults eviction_policy to VolatileLRU, which evicts keys that carry a TTL,
    # and every key this registry writes carries one. So the default does not merely permit the
    # bad eviction, it targets exactly the eligible set: under memory pressure it drops a
    # revocation marker and a revoked session comes back. The application says the same in two
    # places — application-backend docs/deploy.md and the RedisSessionRegistry docstring in
    # core/sessions.py: "these keys are correctness state, not cache — an evicted marker
    # resurrects a revoked session."
    #
    # The trade is deliberate. At maxmemory the database refuses writes with OOM instead of
    # evicting, so the failure is loud and fails closed (logins refuse) rather than quiet and
    # fails open (revoked sessions return). alert-<prefix>-redis-memory in diagnostics.tf warns
    # before that point.
    #
    # Note the spelling: "NoEviction" here (the redisEnterprise enum), not the redis.conf
    # "noeviction" the legacy path passes to azurerm_redis_cache.
    eviction_policy = "NoEviction"

    # Azure Managed Redis is clustered on every tier and SKU. NoCluster is the policy that
    # matches the non-sharded topology the application already runs on, and that is what
    # backward compatibility means here:
    #   - OSSCluster (the provider default) needs a cluster-aware client that follows MOVED.
    #     The app connects with redis.asyncio.Redis.from_url — a plain, non-cluster client.
    #   - EnterpriseCluster gives a single proxy endpoint the plain client can use, but still
    #     returns CROSSSLOT for multi-key commands outside DEL/MSET/MGET/EXISTS/UNLINK/TOUCH.
    #     RedisSessionRegistry.revoke_all wraps N `SET sess:rev:<jti>` in one MULTI, and those
    #     keys carry no hash tag, so they span slots. That is the "sign out all sessions" path.
    #   - NoCluster is the policy Microsoft names for exactly this case ("when running cross
    #     slot commands extensively ... For example, MULTI commands").
    # Cost of the choice is smaller than it looks, and in one direction only: NoCluster applies
    # to instances of 25 GB or less. But the policy is NOT a one-way door — it is the only
    # policy you can move OFF. Azure documents it three times over: "Only caches with the
    # Noncluster policy can be updated to a clustered configuration after deployment" (scaling
    # FAQ), and the SDK property reads "can be updated only if the current value is NoCluster.
    # If the value is OSSCluster or EnterpriseCluster, it cannot be updated without deleting
    # the database." So starting here preserves the option to move to OSSCluster later, once
    # revoke_all's MULTI is replaced by a non-transactional pipeline; starting on either
    # clustered policy would have thrown that option away. (Geo-replicated instances are the
    # exception — their policy is fixed at creation. We do not geo-replicate a session cache.)
    clustering_policy = "NoCluster"

    # TLS. Already the provider default; set explicitly because the connection URL below is
    # rediss:// and the app verifies the hostname.
    client_protocol = "Encrypted"

    # The provider defaults this to false, and primary_access_key is only exported when it is
    # true — so without this the keyed URL below authenticates against nothing. Microsoft Entra
    # ID is the better posture and Azure Managed Redis is built for it, but the application has
    # no Entra-token Redis credential provider today; that is its own increment (ADR 0071).
    access_keys_authentication_enabled = true
  }

  tags = local.tags
}

# --- Offering "cache": Azure Cache for Redis (Microsoft.Cache/redis) ------------------------
#
# Unchanged from module v0.6.0 apart from the count gate, deliberately: a customer already
# running one of these sets redis_offering = "cache" and their next plan is empty. Creatable
# only in tenants that held a cache before 1 April 2026; retired 30 September 2028.
resource "azurerm_redis_cache" "this" {
  count = local.use_legacy_redis ? 1 : 0

  name                = "redis-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location

  capacity            = var.redis_capacity
  family              = var.redis_sku_name == "Premium" ? "P" : "C"
  sku_name            = var.redis_sku_name
  minimum_tls_version = "1.2"

  # noeviction is a CORRECTNESS requirement, not cache tuning. This cache holds the session
  # registry, and revocation is the part that matters: the `sess:rev:{jti}` markers and the
  # `sess:orgrev:{org}` epoch are the only record that a session was killed — the bearer token
  # stays cryptographically valid until its own expiry. Azure's default is volatile-lru, which
  # evicts keys that carry a TTL, and every key this registry writes carries one. So the
  # default does not merely permit the bad eviction, it targets exactly the eligible set: under
  # memory pressure it drops a revocation marker and a revoked session comes back. The
  # application says the same in two places — application-backend docs/deploy.md and the
  # RedisSessionRegistry docstring in core/sessions.py: "these keys are correctness state, not
  # cache — an evicted marker resurrects a revoked session."
  #
  # The trade is deliberate. At maxmemory the cache refuses writes with OOM instead of
  # evicting, so the failure is loud and fails closed (logins refuse) rather than quiet and
  # fails open (revoked sessions return). alert-<prefix>-redis-memory in diagnostics.tf warns
  # before that point.
  #
  # Only maxmemory_policy is set, and only because correctness depends on it. The reserved-
  # memory tunables in the same block are a sizing decision that belongs to whoever chooses
  # redis_capacity, not to this module.
  redis_configuration {
    maxmemory_policy = "noeviction"
  }

  # No public presence: reachable only via the private endpoint below (mirrors the starter
  # Postgres). Private-endpoint access is supported on every SKU offered here.
  public_network_access_enabled = false

  tags = local.tags
}

# Private DNS so the cache's public hostname resolves to the private endpoint inside the
# VNet — the application redis URL stays unchanged. Skipped when the landing zone injects a
# central zone (redis_private_dns_zone_id) and entirely absent when Redis is disabled.
# The zone NAME is offering-dependent: the two services live under different suffixes.
resource "azurerm_private_dns_zone" "redis" {
  count = local.create_redis_dns ? 1 : 0

  name                = local.redis_dns_zone_name
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  count = local.create_redis_dns ? 1 : 0

  name                  = "pdzl-${var.name_prefix}-redis"
  resource_group_name   = azurerm_resource_group.aca.name
  private_dns_zone_name = azurerm_private_dns_zone.redis[0].name
  virtual_network_id    = local.virtual_network_id
  tags                  = local.tags
}

# The cache's only network presence: a private endpoint in the install's VNet. The private
# DNS zone maps the cache's hostname to this endpoint, so the app's redis URL is identical to
# the public-path one. One endpoint either way — the target resource and the subresource
# (groupId) follow the offering.
resource "azurerm_private_endpoint" "redis" {
  count = local.redis_enabled ? 1 : 0

  name                = "pe-${var.name_prefix}-redis"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-redis"
    private_connection_resource_id = local.redis_resource_id
    subresource_names              = [local.redis_subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [local.redis_dns_zone_id]
  }

  tags = local.tags
}

locals {
  redis_env = local.redis_enabled ? {
    MASTERLY_SESSION_REGISTRY = "redis"
  } : {}

  # Azure Managed Redis: TLS on the database's own port. Read the port from the attribute
  # rather than hardcoding 10000 — the ARM contract says the database port "defaults to an
  # available port", so it is not guaranteed. The hostname is the public-form
  # <name>.<region>.redis.azure.net that the private DNS zone overrides inside the VNet; never
  # the privatelink.* form, which would fail TLS hostname verification.
  # /0 is retained: redis-py only emits SELECT when the db index is truthy, so db 0 sends
  # nothing and Redis Enterprise's single-database model stays invisible to the app.
  managed_redis_url = local.use_managed_redis ? "rediss://:${azurerm_managed_redis.this[0].default_database[0].primary_access_key}@${azurerm_managed_redis.this[0].hostname}:${azurerm_managed_redis.this[0].default_database[0].port}/0" : ""

  # Azure Cache for Redis: rediss:// on the fixed TLS port 6380.
  legacy_redis_url = local.use_legacy_redis ? "rediss://:${azurerm_redis_cache.this[0].primary_access_key}@${azurerm_redis_cache.this[0].hostname}:6380/0" : ""

  # The URL embeds the access key -> Container App secret, never plain env.
  redis_secrets = local.redis_enabled ? {
    "redis-url" = local.use_managed_redis ? local.managed_redis_url : local.legacy_redis_url
  } : {}

  redis_secret_refs = local.redis_enabled ? {
    MASTERLY_REDIS_URL = "redis-url"
  } : {}
}

# A BOOLEAN, never the URL — the URL carries an access key. This follows the same precedent as
# the aca-container-app module's env_names output: it exists so the module's posture is
# assertable in `terraform test`, and a value here would put a credential into state and test
# output. Without it the wiring is unobservable: every resource-shaped assertion still passes if
# the offering ternary in redis_secrets is inverted, because both branches are well-formed —
# the managed path just silently resolves to the legacy path's empty string, and the install
# ships an empty redis-url secret with MASTERLY_SESSION_REGISTRY = "redis" set.
# nonsensitive() is deliberate and narrow: the URL embeds an access key, so Terraform refuses an
# output derived from it, but WHETHER IT IS EMPTY is not the secret — it is one bit that reveals
# nothing about the key. Wrapping the comparison rather than the value keeps the credential out
# of state and out of test output while making the wiring assertable.
output "redis_url_wired" {
  value       = local.redis_enabled ? nonsensitive(local.redis_secrets["redis-url"] != "") : null
  description = "True when Redis is enabled and its connection URL resolved to a non-empty value. Null when the in-memory registry is used. Never the URL itself, which embeds an access key."
}

output "redis_hostname" {
  value       = local.use_managed_redis ? one(azurerm_managed_redis.this[*].hostname) : one(azurerm_redis_cache.this[*].hostname)
  description = "Hostname of the install's Redis (null when the in-memory registry is used). Azure Managed Redis answers on <name>.<region>.redis.azure.net; Azure Cache for Redis on <name>.redis.cache.windows.net."
}
