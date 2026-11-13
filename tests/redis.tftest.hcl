# Azure Managed Redis (redis.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  # Every production run needs one of the two deployer paths to the vault stated, the same
  # as a real production install (see key_vault_deployer_ip_rules). Set file-wide so the
  # runs that assert something else are not all about this; the guard has its own run in keyvault.tftest.hcl.
  key_vault_deployer_ip_rules = ["203.0.113.7"]

  # A production plan with no notification target is refused (alert_email's validation), so
  # every production run states one. Runs about the target override it; the refusal
  # has its own runs in diagnostics.tftest.hcl.
  alert_email = "ops@example.com"
}

# --- Azure Managed Redis (ADR 0071) ------------------------------------------------------
#
# Microsoft blocked creation of Basic/Standard/Premium Azure Cache for Redis for NEW customers
# on 1 April 2026, and mode=production requires enable_redis — so at module v0.6.0 an
# organization that never ran a cache could not complete a production install at all. The fix
# is a second offering on a different ARM type (Microsoft.Cache/redisEnterprise, Balanced_*),
# which every tenant can create.
#
# What these runs can prove: the two paths are mutually exclusive, the offering is not
# silently defaulted, and every setting whose PROVIDER DEFAULT is wrong for this module is
# pinned in HCL. What they cannot prove: anything about Azure. These are plans against
# mock_provider, so a Balanced_B0 with no capacity in the region, a private DNS zone that does
# not resolve, an aggregation Azure rejects, and a URL that does not authenticate all pass here.

# The silent-default hole, closed at plan time: enable_redis alone is not a complete answer,
# because the module cannot tell a fresh tenant from one that qualifies to keep using the old
# service, and either default would be wrong for half of them.
run "redis_offering_required_when_enabled" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
  }

  expect_failures = [var.redis_offering]
}

run "redis_managed_provisions_amr_not_cache" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = length(azurerm_managed_redis.this) == 1 && length(azurerm_redis_cache.this) == 0
    error_message = "redis_offering = managed must provision Azure Managed Redis and no Azure Cache for Redis."
  }

  assert {
    condition     = azurerm_managed_redis.this[0].sku_name == "Balanced_B0"
    error_message = "The managed default SKU must stay Balanced_B0 — the smallest, and cheaper per hour than the Basic C0 it replaces."
  }

  # ForceNew at Azure: without HA there is no replication, no zone redundancy, and no SLA,
  # and flipping it later destroys and recreates the instance.
  assert {
    condition     = azurerm_managed_redis.this[0].high_availability_enabled == true
    error_message = "Azure Managed Redis must run with high availability — it is ForceNew, so this cannot be fixed later without a recreate."
  }
}

# The single most valuable assertion here. The v0.6.0 correctness fix was maxmemory_policy =
# noeviction on the old cache; the equivalent on Azure Managed Redis is spelled NoEviction and
# lives on the database child, and the PROVIDER DEFAULT IS VolatileLRU. Deleting this field
# would silently reinstate the exact defect the policy exists to prevent: every session-registry
# key carries a TTL, so volatile eviction targets precisely the revocation markers, and a
# dropped marker resurrects a revoked session that nothing downstream can detect.
run "redis_managed_runs_noeviction" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = azurerm_managed_redis.this[0].default_database[0].eviction_policy == "NoEviction"
    error_message = "Azure Managed Redis must run eviction_policy = NoEviction — the provider defaults to VolatileLRU, and an evicted revocation marker resurrects a revoked session."
  }
}

# Three renamed wiring literals and one inverted default, all in one place: the private-link
# subresource, the private DNS zone name, and public network access. Azure Managed Redis has
# no VNet injection and no IP firewall, so the private endpoint is the only isolation there is.
run "redis_managed_is_private_only" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = azurerm_managed_redis.this[0].public_network_access == "Disabled"
    error_message = "Azure Managed Redis must disable public network access — the provider defaults it to Enabled."
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.redis) == 1 &&
      length(azurerm_private_endpoint.redis[0].private_service_connection[0].subresource_names) == 1 &&
      contains(azurerm_private_endpoint.redis[0].private_service_connection[0].subresource_names, "redisEnterprise")
    )
    error_message = "The managed private endpoint must target the redisEnterprise subresource, not redisCache."
  }

  assert {
    condition     = azurerm_private_dns_zone.redis[0].name == "privatelink.redis.azure.net"
    error_message = "The managed private DNS zone must be privatelink.redis.azure.net — privatelink.redis.cache.windows.net belongs to the other service and will not resolve."
  }
}

# The connection URL is `rediss://:<key>@<host>:<port>/0` and the key comes from the database.
# The provider defaults access-key authentication to false and does not even export
# primary_access_key unless it is true, so this is silent at plan and broken at runtime.
run "redis_managed_enables_access_keys" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = azurerm_managed_redis.this[0].default_database[0].access_keys_authentication_enabled == true
    error_message = "The managed database must enable access-key authentication, or primary_access_key is not exported and the connection URL cannot authenticate."
  }

  assert {
    condition     = azurerm_managed_redis.this[0].default_database[0].client_protocol == "Encrypted"
    error_message = "The managed database must speak TLS — the app connects with rediss:// and verifies the hostname."
  }
}

# Clustering policy is immutable after creation, so this is a one-shot decision. NoCluster
# matches the non-sharded topology the application already runs on: OSSCluster (the provider
# default) needs a cluster-aware client the app does not have, and EnterpriseCluster still
# returns CROSSSLOT for the multi-key MULTI in revoke_all — the sign-out-all-sessions path.
run "redis_managed_pins_nocluster" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
  }

  assert {
    condition     = azurerm_managed_redis.this[0].default_database[0].clustering_policy == "NoCluster"
    error_message = "The managed database must pin clustering_policy = NoCluster — the provider defaults to OSSCluster, which the app's non-cluster client cannot follow, and the policy cannot be changed after creation."
  }
}

# Enterprise_* and EnterpriseFlash_* ride the SAME ARM type as the Azure Managed Redis SKUs,
# so they are an easy and expensive mistake. Their creation has been blocked for everyone
# since 1 April 2026 and they retire 31 March 2027.
run "redis_managed_rejects_the_retired_enterprise_skus" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    enable_redis           = true
    redis_offering         = "managed"
    redis_sku_name_managed = "Enterprise_E5"
  }

  expect_failures = [var.redis_sku_name_managed]
}

# Diagnostics fork by offering: metrics stay cluster-level, but the only Azure Managed Redis
# log category (ConnectionEvents) lives on the redisEnterprise/databases child, so it needs
# its own diagnostic setting. The alert namespace changes with the ARM type.
run "redis_managed_splits_diagnostics_across_cluster_and_database" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
    enable_diagnostics    = true
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.redis) == 1 &&
      length(azurerm_monitor_diagnostic_setting.redis_database) == 1
    )
    error_message = "The managed offering must wire cluster metrics and database logs as two diagnostic settings."
  }

  # The database child's one category, named. The cluster carries no log category on this
  # offering, so its setting sends metrics only.
  assert {
    condition = (
      toset([for l in azurerm_monitor_diagnostic_setting.redis_database[0].enabled_log : l.category]) == toset(["ConnectionEvents"]) &&
      alltrue([for l in azurerm_monitor_diagnostic_setting.redis_database[0].enabled_log : l.category_group == null]) &&
      length(azurerm_monitor_diagnostic_setting.redis[0].enabled_log) == 0
    )
    error_message = "On the managed offering the database setting must name ConnectionEvents (no category group) and the cluster setting must send no log category."
  }

  assert {
    condition = (
      azurerm_monitor_metric_alert.redis_evictions[0].criteria[0].metric_namespace == "Microsoft.Cache/redisEnterprise" &&
      azurerm_monitor_metric_alert.redis_memory[0].criteria[0].metric_namespace == "Microsoft.Cache/redisEnterprise"
    )
    error_message = "The Redis alerts must move to the Microsoft.Cache/redisEnterprise namespace on the managed offering."
  }
}

# Every diagnostic setting names its log categories (ADR 0080, amendment of 2026-09-10). A
# category group such as allLogs grows when Azure adds a category to the resource type, so the
# install's workspace would start receiving content nobody chose — Query Store text from the
# server, every Service Bus send and receive with its caller. This run turns on every setting
# the module has except the managed-Redis database child (asserted in the run above, as the
# two offerings are exclusive) and pins each one's categories, plus the Key Vault table.
run "diagnostic_settings_name_their_log_categories" {
  command = plan

  variables {
    ingress_allowed_cidrs               = ["203.0.113.7/32"]
    enable_diagnostics                  = true
    enable_app_availability_diagnostics = true
    enable_key_vault                    = true
    enable_redis                        = true
    redis_offering                      = "cache"
    enable_service_bus                  = true
    enable_workers                      = true
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.postgres) == 1 &&
      length(azurerm_monitor_diagnostic_setting.redis) == 1 &&
      length(azurerm_monitor_diagnostic_setting.key_vault) == 1 &&
      length(azurerm_monitor_diagnostic_setting.service_bus) == 1 &&
      length(azurerm_monitor_diagnostic_setting.app) == 3
    )
    error_message = "This run must create the Postgres, Redis, Key Vault, Service Bus and per-app diagnostic settings, or the assertions below are vacuous."
  }

  # No setting in the module asks for a category group, and every log block names a category.
  assert {
    condition = alltrue(flatten([
      for s in concat(
        azurerm_monitor_diagnostic_setting.postgres,
        azurerm_monitor_diagnostic_setting.redis,
        azurerm_monitor_diagnostic_setting.redis_database,
        azurerm_monitor_diagnostic_setting.key_vault,
        azurerm_monitor_diagnostic_setting.service_bus,
        values(azurerm_monitor_diagnostic_setting.app),
        ) : [
        for l in s.enabled_log : l.category_group == null && l.category != null && l.category != ""
      ]
    ]))
    error_message = "A diagnostic setting uses category_group, or a log block names no category. Name each log category explicitly."
  }

  # The server's own log only. The bundle reads it from AzureDiagnostics as PostgreSQLLogs.
  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.postgres[0].enabled_log : l.category]) == toset(["PostgreSQLLogs"])
    error_message = "The Postgres setting must send PostgreSQLLogs and no other log category."
  }

  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.redis[0].enabled_log : l.category]) == toset(["ConnectedClientList", "MSEntraAuthenticationAuditLog"])
    error_message = "The Azure Cache for Redis setting must send ConnectedClientList and MSEntraAuthenticationAuditLog and no other log category."
  }

  # AuditEvent, into the resource-specific AZKVAuditLogs table, which is where the diagnostic
  # bundle reads it. "Dedicated" is the setting that selects that table.
  assert {
    condition = (
      toset([for l in azurerm_monitor_diagnostic_setting.key_vault[0].enabled_log : l.category]) == toset(["AuditEvent"]) &&
      azurerm_monitor_diagnostic_setting.key_vault[0].log_analytics_destination_type == "Dedicated"
    )
    error_message = "The Key Vault setting must send AuditEvent alone, to the resource-specific table (log_analytics_destination_type = Dedicated)."
  }

  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.service_bus[0].enabled_log : l.category]) == toset(["OperationalLogs", "DiagnosticErrorLogs"])
    error_message = "The Service Bus setting must send OperationalLogs and DiagnosticErrorLogs and no other log category."
  }

  # The per-app settings stay metrics-only: the diagnostic setting on the environment already
  # sends the apps' logs.
  assert {
    condition = alltrue([
      for app, setting in azurerm_monitor_diagnostic_setting.app : length(setting.enabled_log) == 0
    ])
    error_message = "The per-app diagnostic settings must send no log category."
  }
}

# Backward compatibility: a customer already running an Azure Cache for Redis instance sets
# redis_offering = "cache" and keeps the identical resource at the identical address, with the
# noeviction guarantee and the old zone name intact. The legacy block is not edited by ADR
# 0071 apart from its count gate, so their next plan is empty.
run "redis_cache_offering_still_provisions_the_legacy_cache" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
  }

  assert {
    condition     = length(azurerm_redis_cache.this) == 1 && length(azurerm_managed_redis.this) == 0
    error_message = "redis_offering = cache must keep provisioning the legacy Azure Cache for Redis and no Azure Managed Redis."
  }

  assert {
    condition = (
      azurerm_redis_cache.this[0].redis_configuration[0].maxmemory_policy == "noeviction" &&
      azurerm_redis_cache.this[0].public_network_access_enabled == false &&
      azurerm_private_dns_zone.redis[0].name == "privatelink.redis.cache.windows.net" &&
      contains(azurerm_private_endpoint.redis[0].private_service_connection[0].subresource_names, "redisCache")
    )
    error_message = "The legacy offering must be unchanged: noeviction, no public access, the redis.cache.windows.net zone, and the redisCache subresource."
  }
}

# The managed path's WIRING, not its resource arguments. Every other managed run asserts the
# shape of azurerm_managed_redis; none of them notices if the cache is provisioned correctly and
# then never reaches the app. Inverting the offering ternary in local.redis_secrets makes the
# managed path resolve to the legacy path's empty string — well-formed on both branches, so all
# eight resource-shaped runs still pass while the install ships an empty redis-url secret with
# MASTERLY_SESSION_REGISTRY = "redis" set. That is a production install running multiple api
# replicas on no session store, which is the ADR 0066 state the module exists to refuse.
run "redis_managed_reaches_the_app" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "managed"
    enable_workers        = true
  }

  assert {
    condition     = output.redis_url_wired == true
    error_message = "The managed Redis URL must resolve to a non-empty value — an empty redis-url secret means the apps run with MASTERLY_SESSION_REGISTRY = redis and nothing to connect to."
  }

  assert {
    condition     = contains(module.api.env_names, "MASTERLY_SESSION_REGISTRY")
    error_message = "The api must carry MASTERLY_SESSION_REGISTRY on the managed path."
  }

  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_SESSION_REGISTRY")
    error_message = "The workers app must carry MASTERLY_SESSION_REGISTRY on the managed path — a worker that falls back to the in-memory registry does not share revocations with the api."
  }
}

# The aggregation on the evictions alert is the one value Learn's two pages disagree about, and
# it was changed from the design during the build. Pinning it means a future edit has to justify
# itself rather than quietly flip a signal that only fires in production.
run "redis_managed_eviction_alert_aggregates_correctly" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    initial_owner_email  = "owner@example.com"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "managed"
    enable_workers       = true
    api_max_replicas     = 2
    # BYO-DB, matching production_mode_full_wiring_plans: it opts out of the starter server's
    # production floors (GP sku, 14-day backups, zone-redundant HA), which are irrelevant to a
    # Redis alert and would otherwise be three more lines of unrelated setup.
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = azurerm_monitor_metric_alert.redis_evictions[0].criteria[0].aggregation == "Average"
    error_message = "evictedkeys is documented with the Average aggregation on Microsoft.Cache/redisEnterprise; Maximum silently changes what the alert means."
  }
}
