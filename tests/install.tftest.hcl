# Branch coverage for the module's variable guards and conditional resources
# (mock providers — no cloud access; runs in CI via `terraform test`).

mock_provider "azurerm" {
  # The Key Vault resource validates tenant_id as a UUID; the auto-generated mock value
  # is a random string, so pin the client-config data source.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "random" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/frontend:v0.0.0"
  acr_login_server = ""
}

# Evaluation defaults: dev identity behind an allowlist provisions the starter Postgres,
# its private DNS zone, and its private endpoint.
run "eval_defaults_provision_starter_postgres" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 1
    error_message = "The default (no external_database_url) must provision the starter Postgres server."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.postgres) == 1 && length(azurerm_private_endpoint.postgres) == 1
    error_message = "The provisioned server must come with its private DNS zone and private endpoint."
  }

  # The derived layout of the default /16 must never drift — it is what live installs
  # (the demo) hold in state; a change here REPLACES their subnets.
  assert {
    condition = (
      azurerm_subnet.aca.address_prefixes[0] == "10.20.0.0/23" &&
      azurerm_subnet.private_endpoints.address_prefixes[0] == "10.20.4.0/24"
    )
    error_message = "Derived subnet layout changed for the default /16 — this would replace live installs' subnets."
  }
}

# BYO-DB (ADR 0065): an external DSN provisions NO database resources at all.
run "byo_db_provisions_no_database" {
  command = plan

  variables {
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_postgresql_flexible_server.this) == 0 &&
      length(random_password.postgres_admin) == 0 &&
      length(azurerm_private_endpoint.postgres) == 0 &&
      length(azurerm_private_dns_zone.postgres) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgres) == 0
    )
    error_message = "external_database_url must suppress every provisioned-database resource (ADR 0065)."
  }

  assert {
    condition     = output.postgres_fqdn == null
    error_message = "postgres_fqdn must be null on BYO-DB installs."
  }
}

# Landing zone: an injected central privatelink zone suppresses zone + link creation
# but keeps the server and its private endpoint.
run "injected_dns_zone_creates_no_zone" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    postgres_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.postgres) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgres) == 0 &&
      length(azurerm_postgresql_flexible_server.this) == 1 &&
      length(azurerm_private_endpoint.postgres) == 1
    )
    error_message = "postgres_private_dns_zone_id must suppress zone + link creation only."
  }
}

# mode=production (ADR 0066 inc 4): the full production wiring plans clean.
run "production_mode_full_wiring_plans" {
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
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 3

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = length(azurerm_key_vault.this) == 1 && length(azurerm_redis_cache.this) == 1 && output.workers_app_name == "ca-workers"
    error_message = "Production wiring must provision the vault, Redis, and the workers app."
  }

  # Hardening in production: the vault has purge protection armed, public access disabled,
  # default-deny ACLs, and a private endpoint (+ its private DNS zone).
  assert {
    condition = (
      azurerm_key_vault.this[0].purge_protection_enabled == true &&
      azurerm_key_vault.this[0].public_network_access_enabled == false &&
      length(azurerm_private_endpoint.key_vault) == 1 &&
      length(azurerm_private_dns_zone.key_vault) == 1
    )
    error_message = "Production Key Vault must have purge protection, no public access, and a private endpoint."
  }

  # Redis is private-endpoint-only in production too.
  assert {
    condition     = azurerm_redis_cache.this[0].public_network_access_enabled == false && length(azurerm_private_endpoint.redis) == 1
    error_message = "Production Redis must disable public access and be reached over a private endpoint."
  }

  # Diagnostics on-by-default in production: settings for the enabled data-plane resources
  # (Redis + Key Vault here; Postgres is BYO-DB so absent) plus the app 5xx alerts.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.redis) == 1 &&
      length(azurerm_monitor_diagnostic_setting.key_vault) == 1 &&
      length(azurerm_monitor_diagnostic_setting.postgres) == 0 &&
      length(azurerm_monitor_metric_alert.app_5xx) == 2
    )
    error_message = "Production must wire diagnostics for the enabled data-plane resources and the app 5xx alerts (Postgres absent on BYO-DB)."
  }
}

# mode=production on the PROVISIONED starter server: the data-plane defaults must be
# production-grade (non-burstable SKU + zone-redundant HA + >=14d retention). This exercises
# the starter-server path (no external_database_url), unlike the BYO-DB wiring test above.
run "production_starter_postgres_grade_plans" {
  command = plan

  variables {
    mode                  = "production"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 2

    # Production-grade starter server (no external_database_url — module provisions Postgres).
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14

    # A notification target -> the module creates its own action group.
    alert_email = "ops@example.com"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this) == 1
    error_message = "Production with no external_database_url must provision the starter server."
  }

  # Diagnostics for the starter server + the storage alert; no CPU-credits alert on a
  # General Purpose SKU (that alert is burstable-only). The action group is created because
  # alert_email is set.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.postgres) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_storage) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_cpu_credits) == 0 &&
      length(azurerm_monitor_action_group.alerts) == 1
    )
    error_message = "Production starter server must wire Postgres diagnostics + storage alert (no CPU-credit alert on GP) and an action group when alert_email is set."
  }
}

# Guard: mode=production refuses the burstable Postgres default on the provisioned starter
# server (the dev-grade SKU is unrepresentable in production).
run "production_burstable_postgres_is_rejected" {
  command = plan

  variables {
    mode                  = "production"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 2
    # postgres_sku_name stays the burstable B_Standard_B1ms default -> refused
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
  }

  expect_failures = [var.postgres_sku_name]
}

# Guard: mode=production refuses a dev-grade 7-day backup retention on the starter server.
run "production_short_retention_is_rejected" {
  command = plan

  variables {
    mode                       = "production"
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    identity_binding           = "oidc"
    oidc_allowed_issuers       = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience              = "api-client-id"
    oidc_jwks_uri              = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id             = "bff-client-id"
    oidc_client_secret         = "s3cret"
    oidc_authority             = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri          = "https://app.example.com/api/auth/callback"
    license_token              = "eyJ.fake.jwt"
    license_public_jwk         = "{\"kty\":\"EC\"}"
    initial_owner_email        = "owner@example.com"
    enable_key_vault           = true
    enable_redis               = true
    redis_offering             = "cache"
    enable_workers             = true
    api_max_replicas           = 2
    postgres_sku_name          = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha = true
    # postgres_backup_retention_days stays the 7-day default -> refused
  }

  expect_failures = [var.postgres_backup_retention_days]
}

# Guard: mode=production refuses the starter server without zone-redundant HA.
run "production_no_ha_is_rejected" {
  command = plan

  variables {
    mode                           = "production"
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "s3cret"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = "{\"kty\":\"EC\"}"
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_backup_retention_days = 14
    # postgres_zone_redundant_ha stays false -> refused
  }

  expect_failures = [var.postgres_zone_redundant_ha]
}

# Guard: mode=production refuses a single-replica api (SPOF + downtime on every deploy).
run "production_single_replica_api_is_rejected" {
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
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 1 # single replica in production -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.api_max_replicas]
}

# Guard: mode=production refuses the in-process worker (the pipeline must run in ca-workers).
run "production_without_workers_is_rejected" {
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
    redis_offering       = "cache"
    api_max_replicas     = 2
    # enable_workers stays false -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.enable_workers]
}

# Guard: production without the durable seams is unrepresentable at plan time.
run "production_without_redis_is_rejected" {
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
    enable_key_vault     = true
    # enable_redis missing -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# Guard: dev identity with an open ingress is unrepresentable.
run "open_ingress_dev_identity_is_rejected" {
  command = plan

  expect_failures = [var.identity_binding]
}

# Guard: oidc requires both the backend verification half and the BFF client half.
run "half_configured_oidc_is_rejected" {
  command = plan

  variables {
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
  }

  expect_failures = [var.identity_binding]
}

# Guard: a VNet smaller than /21 must bring explicit subnet prefixes.
run "small_vnet_without_explicit_subnets_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    vnet_address_space    = ["10.99.0.0/24"]
  }

  expect_failures = [var.vnet_address_space]
}

# Small VNet WITH explicit prefixes is fine.
run "small_vnet_with_explicit_subnets_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    vnet_address_space              = ["10.99.0.0/22"]
    aca_subnet_prefix               = "10.99.0.0/23"
    private_endpoints_subnet_prefix = "10.99.2.0/24"
  }

  assert {
    condition     = azurerm_subnet.aca.address_prefixes[0] == "10.99.0.0/23"
    error_message = "Explicit aca_subnet_prefix must be used verbatim."
  }
}

# Key Vault (ADR 0066): enabled provisions the vault + Secrets Officer grant and flips
# the api's secret-store env; default provisions nothing.
run "key_vault_enabled_provisions_vault_and_grant" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
  }

  assert {
    condition = (
      length(azurerm_key_vault.this) == 1 &&
      length(azurerm_role_assignment.kv_secrets_officer) == 1
    )
    error_message = "enable_key_vault must provision the vault and the Secrets Officer grant."
  }

  assert {
    condition     = azurerm_key_vault.this[0].rbac_authorization_enabled
    error_message = "The vault must be RBAC-mode — grants are role assignments, never access policies."
  }

  # Soft-delete is always on; purge protection stays OFF in demo (it is irreversible — only
  # armed in production), and the vault keeps public access + no private endpoint for eval.
  assert {
    condition = (
      azurerm_key_vault.this[0].soft_delete_retention_days == 90 &&
      azurerm_key_vault.this[0].purge_protection_enabled == false &&
      azurerm_key_vault.this[0].public_network_access_enabled == true &&
      length(azurerm_private_endpoint.key_vault) == 0
    )
    error_message = "Demo-mode vault: soft-delete on, purge protection off, public access on, no private endpoint."
  }

  # Diagnostics default off outside production: no settings, no alerts.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.key_vault) == 0 &&
      length(azurerm_monitor_metric_alert.app_5xx) == 0
    )
    error_message = "Diagnostics must be off by default outside production."
  }
}

run "key_vault_default_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_key_vault.this) == 0
    error_message = "The default must provision no Key Vault (dev/demo run the in-process store)."
  }
}

# Redis + workers (ADR 0066 inc 3): enabled provisions the cache and the workers app;
# the api replica cap is guarded by the redis requirement.
run "redis_and_workers_enabled" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 3
  }

  assert {
    condition     = length(azurerm_redis_cache.this) == 1
    error_message = "enable_redis must provision the cache."
  }

  assert {
    condition     = output.workers_app_name == "ca-workers"
    error_message = "enable_workers must create the ca-workers app."
  }

  # Hardening: the cache has no public network presence and is reached over a private
  # endpoint with its own private DNS zone — mirroring the starter Postgres.
  assert {
    condition     = azurerm_redis_cache.this[0].public_network_access_enabled == false
    error_message = "Redis must disable public network access (private-endpoint-only)."
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.redis) == 1 &&
      length(azurerm_private_dns_zone.redis) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.redis) == 1
    )
    error_message = "enable_redis must provision the Redis private endpoint + private DNS zone + link."
  }
}

# Landing zone: an injected central redis privatelink zone suppresses zone + link creation
# but keeps the cache and its private endpoint.
run "injected_redis_dns_zone_creates_no_zone" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    enable_redis              = true
    redis_offering            = "cache"
    redis_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.redis) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.redis) == 0 &&
      length(azurerm_redis_cache.this) == 1 &&
      length(azurerm_private_endpoint.redis) == 1
    )
    error_message = "redis_private_dns_zone_id must suppress zone + link creation only."
  }
}

run "redis_and_workers_default_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_redis_cache.this) == 0 && output.workers_app_name == null && output.redis_hostname == null
    error_message = "The defaults must provision neither Redis nor the workers app."
  }
}

# Service Bus (ADR 0029): enabled provisions the namespace + queue and BOTH data-plane role
# assignments. The pairing matters — the api publishes and ca-workers receives on the same
# identity, so a missing grant strands the pipeline in a way no plan would otherwise show.
run "service_bus_enabled_provisions_broker_and_grants" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    enable_workers        = true
  }

  assert {
    condition = (
      length(azurerm_servicebus_namespace.this) == 1 &&
      length(azurerm_servicebus_queue.jobs) == 1 &&
      length(azurerm_role_assignment.sb_sender) == 1 &&
      length(azurerm_role_assignment.sb_receiver) == 1
    )
    error_message = "enable_service_bus must provision the namespace, the queue, and both data-plane grants."
  }

  # SAS off (ADR 0029): managed identity only, so there is no connection string to leak.
  assert {
    condition     = azurerm_servicebus_namespace.this[0].local_auth_enabled == false
    error_message = "The namespace must refuse SAS auth — the apps authenticate as their managed identity."
  }

  # At-least-once with idempotent handlers: redeliver on failure, dead-letter past the cap,
  # never drop. The consume loop abandons a truncated drain, which relies on redelivery.
  assert {
    condition = (
      azurerm_servicebus_queue.jobs[0].max_delivery_count == 10 &&
      azurerm_servicebus_queue.jobs[0].dead_lettering_on_message_expiration
    )
    error_message = "The jobs queue must redeliver and dead-letter rather than drop work."
  }
}

run "service_bus_default_off" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azurerm_servicebus_namespace.this) == 0 &&
      length(azurerm_servicebus_queue.jobs) == 0 &&
      length(azurerm_role_assignment.sb_sender) == 0
    )
    error_message = "The default must provision no broker — the polling binding runs air-gapped."
  }
}

# Guard: scaling the api past one replica without Redis is unrepresentable.
run "api_scale_out_without_redis_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_max_replicas      = 3
  }

  expect_failures = [var.api_max_replicas]
}

# Scale-to-zero (idle-cost posture, e.g. the demo install): both apps at min 0 plan clean
# on the dev/demo shape.
run "scale_to_zero_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_min_replicas      = 0
    frontend_min_replicas = 0
  }
}

# Guard: the api's replica floor cannot exceed its cap.
run "api_min_above_max_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_min_replicas      = 2
    # api_max_replicas stays 1 -> refused
  }

  expect_failures = [var.api_min_replicas]
}

# Guard: mode=production refuses scale-to-zero (cold-start latency on the first request).
run "production_scale_to_zero_is_rejected" {
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
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 2

    api_min_replicas      = 0 # scale-to-zero in production -> refused
    frontend_min_replicas = 0 # likewise

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.api_min_replicas, var.frontend_min_replicas]
}

# Credential-based image pull (ADR 0067 option 1): direct pull from Masterly's registry
# with the per-customer service principal.
run "credential_registry_pull_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    registry_username     = "00000000-0000-0000-0000-000000000000"
    registry_password     = "sp-client-secret"
  }
}

# Guard: the credential pair must arrive whole.
run "registry_password_without_username_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    registry_password     = "sp-client-secret"
  }

  expect_failures = [var.registry_username]
}

# Guard: ACS email data location must match the install's geo.
run "acs_email_geo_mismatch_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "eastus2"
    masterly_region       = "us"
    email_acs_enabled     = true
    # email_acs_data_location stays the "Europe" default -> mismatch
  }

  expect_failures = [var.email_acs_data_location]
}

# The frontend refuses to boot on a production build with the dev binding unless the opt-in is
# present. It took the demo's login down for weeks: every server-side route threw "Refusing to
# run: MASTERLY_IDP_BINDING=dev on a production build", so /api/config and /api/auth/login
# returned empty 500s while the login PAGE still served — which is why it read as "stale" rather
# than "broken". Terraform is the only place that can pair the two, so it is pinned here.
run "dev_binding_sets_the_frontend_opt_in" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = contains(module.frontend.env_names, "MASTERLY_ALLOW_DEV_BINDING")
    error_message = "identity_binding=dev must set MASTERLY_ALLOW_DEV_BINDING, or the frontend refuses to boot"
  }
}

# And the opt-in is not carried into a real identity binding, where it would be a standing
# invitation to fall back to an identity adapter that accepts anyone.
run "oidc_does_not_set_the_dev_opt_in" {
  command = plan

  variables {
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_ALLOW_DEV_BINDING")
    error_message = "MASTERLY_ALLOW_DEV_BINDING must not be set when identity_binding is oidc"
  }
}

# Redis runs noeviction. Session revocation markers (`sess:rev:{jti}`) and the org revocation
# epoch are correctness state, and every key the registry writes carries a TTL — so Azure's
# default volatile-lru evicts exactly the keys that keep a revoked session revoked, and the
# token itself stays valid until its own expiry. Nothing downstream can detect that
# resurrection, so the policy is pinned at plan time here.
run "redis_runs_noeviction" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
  }

  assert {
    condition     = azurerm_redis_cache.this[0].redis_configuration[0].maxmemory_policy == "noeviction"
    error_message = "Redis must run maxmemory_policy = noeviction — an evicted revocation marker resurrects a revoked session"
  }
}

# Guard: mode=production refuses an install with no Owner bootstrap. A fresh production
# install starts with an empty member list, and the only rule that ever mints the first Owner
# keys on MASTERLY_INITIAL_OWNER_EMAIL — so an apply without it hands the customer an install
# nobody can sign into, which is exactly what a plan-time refusal is for.
run "production_without_initial_owner_is_rejected" {
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
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 2
    # initial_owner_email is unset -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# And an armed break-glass pair does not satisfy it. This pins the bug caught in review: the
# obvious condition "initial_owner_email OR the break-glass pair" reads as an either/or, but
# break-glass resolves an existing Owner membership before minting a session, so on a fresh
# install it is 403 — recovery for an Owner who exists, never the creation of the first one.
run "production_breakglass_does_not_replace_the_owner_bootstrap" {
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
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 2

    breakglass_owner_email = "breakglass@example.com"
    breakglass_secret_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# The frontend's readiness gate. Liveness cannot see a frontend that boots and then throws on
# every server-side route (the dev-binding opt-in), nor one wired to an api that answers 404
# (the drifting FQDN) — /api/healthz returns 200 in both states, and both ran for hours.
# /api/readyz resolves the runtime config and calls the api, so it sees both.
run "frontend_readiness_gates_on_the_api" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_min_replicas      = 0 # the demo's posture: the probe can be waiting on a cold api
    frontend_min_replicas = 0
  }

  assert {
    condition     = module.frontend.readiness_probe.path == "/api/readyz"
    error_message = "The frontend must gate readiness on /api/readyz — /api/healthz answers 200 from a frontend broken in exactly the ways this install has hit."
  }

  # The gate is only safe while it outlasts a cold backend: at the provider's defaults (1s
  # timeout, 3 failures) a scaled-to-zero api makes a healthy frontend revision look broken,
  # and ACA restarts the replica rather than activating it.
  assert {
    condition = (
      module.frontend.readiness_probe.initial_delay +
      module.frontend.readiness_probe.failure_count_threshold *
      module.frontend.readiness_probe.interval_seconds
    ) >= 240
    error_message = "The frontend's readiness budget must stay >= 240s of continuous failure, or a cold api can fail an otherwise healthy revision."
  }

  assert {
    condition     = module.frontend.readiness_probe.success_count_threshold == 1
    error_message = "One success must be enough to take traffic, or the gate adds probe intervals to every cold wake."
  }

  # The api needs the same widening, and this assertion used to say the opposite.
  #
  # It asserted the api must KEEP Azure's defaults, because tolerances re-render its container
  # template and roll the api on every live install's next apply. On 2026-08-31 that trade came
  # due: the v0.133.0 roll left ca-api--0000135 ActivationFailed holding 100% of traffic with
  # zero replicas, while the previous revision logged "Probe of Readiness failed with timeout in
  # 1 seconds" 71 times running. A one-time roll is the cheaper side of this trade by a wide
  # margin, and mode=production requires api_max_replicas >= 2, so a real install runs this race
  # on every replica start.
  assert {
    condition     = module.api.readiness_probe.path == "/readyz"
    error_message = "The api must gate readiness on /readyz."
  }

  # The same budget as the frontend, and for a stronger reason: /readyz opens Postgres, Redis
  # and Key Vault behind private endpoints, and a customer's FIRST apply is the worst case.
  # A cold api must not outlive the frontend gate that is waiting on it.
  assert {
    condition = (
      module.api.readiness_probe.initial_delay +
      module.api.readiness_probe.failure_count_threshold *
      module.api.readiness_probe.interval_seconds
    ) >= 240
    error_message = "The api's readiness budget must stay >= 240s of continuous failure. At the provider's declared-probe defaults (1s timeout, 3 failures) a cold database makes a healthy revision ActivationFailed, and it takes 100% of traffic with zero replicas."
  }

  # A timeout above the interval would let attempts overlap and never resolve.
  assert {
    condition     = module.api.readiness_probe.timeout <= module.api.readiness_probe.interval_seconds
    error_message = "The api's readiness timeout must stay at or below its interval."
  }

  assert {
    condition     = module.api.readiness_probe.success_count_threshold == 1
    error_message = "One success must be enough for the api to take traffic."
  }
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

  assert {
    condition = (
      azurerm_monitor_metric_alert.redis_evictions[0].criteria[0].metric_namespace == "Microsoft.Cache/redisEnterprise" &&
      azurerm_monitor_metric_alert.redis_memory[0].criteria[0].metric_namespace == "Microsoft.Cache/redisEnterprise"
    )
    error_message = "The Redis alerts must move to the Microsoft.Cache/redisEnterprise namespace on the managed offering."
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

# --- Data residency: the declared geo is checked against where resources actually land ----
# `location` and `masterly_region` were independent inputs that nothing reconciled, so an
# install could sit in Sweden and tell customers (and auditors, and the usage ledger) that it
# was "us". These pin the reconciliation.

# Guard: a geo that contradicts the Azure location is refused at plan.
run "residency_mismatch_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    # swedencentral is geo "eu" — claiming "us" would put EU-resident data behind a US promise
    masterly_region = "us"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: a location the module cannot place is refused rather than waved through. Silently
# skipping the check would make the unknown case the UNSAFE one.
run "unknown_location_is_rejected_not_ignored" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    # In Azure, not in the EU: whether it satisfies an "eu" commitment is a legal question.
    location = "uksouth"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# ...and location_geo is the way to answer that question deliberately.
run "unknown_location_with_explicit_geo_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "uksouth"
    location_geo          = "eu"
    masterly_region       = "eu"
  }

  assert {
    condition     = local.install_geo == "eu"
    error_message = "location_geo must decide the install's geo for a location the map does not carry."
  }
}

# Guard: one install is one data plane in one location, so permitting a second geo would let
# someone create an Environment claiming a residency this install cannot honour. This was the
# old default (["eu", "us"]) — the leak shipped switched on.
run "cross_geo_allowed_regions_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    allowed_regions       = ["eu", "us"]
  }

  expect_failures = [azurerm_resource_group.aca]
}

# The safe configuration is the automatic one: unset means exactly this install's geo.
run "allowed_regions_defaults_to_the_install_geo" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(local.allowed_regions) == 1 && local.allowed_regions[0] == "eu"
    error_message = "Unset allowed_regions must resolve to the install's own geo, not a multi-geo default."
  }
}

# Azure accepts the display form; the check must not depend on which one is written.
run "display_form_location_resolves" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "Sweden Central"
  }

  assert {
    condition     = local.install_geo == "eu"
    error_message = "\"Sweden Central\" and \"swedencentral\" must resolve identically."
  }
}
