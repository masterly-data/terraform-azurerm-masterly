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

  # Every production run needs one of the two deployer paths to the vault stated, the same
  # as a real production install (see key_vault_deployer_ip_rules). Set file-wide so the
  # runs that assert something else are not all about this; the guard has its own run below.
  key_vault_deployer_ip_rules = ["203.0.113.7"]
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
      azurerm_subnet.aca[0].address_prefixes[0] == "10.20.0.0/23" &&
      azurerm_subnet.private_endpoints[0].address_prefixes[0] == "10.20.4.0/24"
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

  # Hardening in production: purge protection armed, default-deny ACLs, and a private
  # endpoint (+ its private DNS zone) that the apps reach it on.
  #
  # The endpoint is ENABLED here because this run states a deployer address, which is what
  # lets Terraform seed the vault's secrets from outside the VNet. That is a firewalled
  # public endpoint, not an open one: default_action stays Deny and the only address admitted
  # is the one given. The fully-closed shape is asserted in
  # production_in_vnet_apply_keeps_the_vault_closed below.
  assert {
    condition = (
      azurerm_key_vault.this[0].purge_protection_enabled == true &&
      azurerm_key_vault.this[0].network_acls[0].default_action == "Deny" &&
      azurerm_key_vault.this[0].network_acls[0].ip_rules == toset(["203.0.113.7"]) &&
      length(azurerm_private_endpoint.key_vault) == 1 &&
      length(azurerm_private_dns_zone.key_vault) == 1
    )
    error_message = "Production Key Vault must have purge protection, default-deny ACLs admitting only the deployer, and a private endpoint."
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

  # Availability, the other half of the catalogue (MAS-263). Both apps declare a replica floor
  # in production, so both get the "no running replica" alert. The database alerts are absent
  # here for the same reason the diagnostic setting is: on BYO-DB the module wires no telemetry
  # for a server it does not provision, so it has no stream whose end it could notice.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 0
    )
    error_message = "Production must alert on both apps having no replica, and must not claim database availability coverage on BYO-DB."
  }

  # Severity is what tells an operator "down" from "strained" in the notification itself: every
  # saturation alert in this module is 1 or 2, every availability alert is 0. If these converge
  # the distinction the alert set exists to draw stops being visible without opening the portal.
  assert {
    condition = (
      azurerm_monitor_metric_alert.app_unavailable["api"].severity == 0 &&
      azurerm_monitor_metric_alert.app_5xx["api"].severity == 1
    )
    error_message = "An availability alert must outrank a saturation alert (severity 0 vs 1) — the severity is how the two states are told apart."
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

  # The provisioned server gets both database availability alerts (MAS-263): the fast one that
  # reads the platform's own is_db_alive, and the slow one that fires on the ABSENCE of that
  # metric — the state a stopped server leaves behind, which no metric alert can see.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 1
    )
    error_message = "A provisioned starter server must carry both the is_db_alive alert and the no-telemetry alert."
  }

  # is_db_alive is 1 up / 0 down and Learn documents MAX() as the way to ask whether the server
  # was up in the last minute. Average would let a mostly-up server average a hard minute away;
  # Minimum would fire on every failover blip. Pinned because either substitution still plans.
  assert {
    condition = (
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].metric_name == "is_db_alive" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].aggregation == "Maximum" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].operator == "LessThan" &&
      azurerm_monitor_metric_alert.postgres_unavailable[0].criteria[0].threshold == 1
    )
    error_message = "The database availability alert must read is_db_alive with Maximum aggregation below 1."
  }

  # The whole point of the log rule: SILENCE has to be the firing condition. Counting rows and
  # firing below one is what makes an empty result an alert rather than a quiet evaluation — the
  # property a metric alert cannot have. GreaterThan here would invert the alert into a
  # permanently-firing one and still plan cleanly, so it is pinned.
  assert {
    condition = (
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].time_aggregation_method == "Count" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].operator == "LessThan" &&
      azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent[0].criteria[0].threshold == 1
    )
    error_message = "The no-telemetry alert must fire when the query returns NO rows (Count < 1) — otherwise silence stays quiet."
  }

  # Not asserted here, and worth naming rather than leaving as a silent gap: that the rule's
  # scope is the install's own workspace and its query names the install's own server. Both are
  # built from resource ids, which are unknown until apply, so under mock providers the
  # condition is unknowable rather than false. Reviewing the interpolation in diagnostics.tf is
  # what covers it.
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
    condition     = azurerm_subnet.aca[0].address_prefixes[0] == "10.99.0.0/23"
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
      length(azurerm_monitor_metric_alert.app_5xx) == 0 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 0
    )
    error_message = "Diagnostics must be off by default outside production."
  }
}

# When the frontend DOES carry secrets, it resolves them itself — so it needs data-plane read
# on the vault, and that is the one grant the split admits. It must be the NARROWEST one: the
# frontend never writes sealed material, and it is the app an attacker reaches first. Pinning
# the role name is the whole point — Secrets Officer would resolve the secrets just as well and
# hand the public front door write access to every credential the install holds.
run "the_frontend_reads_its_own_secrets_and_only_reads" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    registry_username     = "install-puller"
    registry_password     = "pull-secret"
  }

  override_module {
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.frontend_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"
      principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      client_id    = "ffffffff-ffff-ffff-ffff-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend"
    }
  }

  assert {
    condition = (
      length(azurerm_role_assignment.kv_secrets_user_frontend) == 1 &&
      azurerm_role_assignment.kv_secrets_user_frontend[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.kv_secrets_user_frontend[0].principal_id == module.frontend_identity.principal_id
    )
    error_message = "A frontend carrying vault-backed secrets must get Key Vault Secrets User on its own identity — read, and nothing more."
  }

  # The Officer grant stays where it was: on the backend apps, never on the public one.
  assert {
    condition     = azurerm_role_assignment.kv_secrets_officer[0].principal_id == module.apps_identity.principal_id
    error_message = "Key Vault Secrets Officer must never reach the frontend's identity."
  }

  # And the references name the identity that actually holds the grant. ACA resolves a vault
  # reference with the identity named ON THE SECRET, so a reference pointing at the backend's
  # identity fails to resolve on an app that does not carry it — the app then never starts,
  # and with the registry password among those secrets it cannot even pull.
  assert {
    condition = (
      module.frontend.secret_ref_identity_ids == tolist([module.frontend_identity.id]) &&
      module.api.secret_ref_identity_ids == tolist([module.apps_identity.id])
    )
    error_message = "Each app's Key Vault references must name the identity that app runs as."
  }
}

# --- The install's secrets live in the vault, not in the apps (finding S2) -----------------
# A value-based Container App secret is readable in clear by anything holding
# containerApps/listSecrets, which plain Contributor on the resource group has. With the vault
# on, every one of them becomes a reference the app resolves with its managed identity, and
# reading the material needs a Key Vault RBAC grant Contributor does not carry.

run "production_secrets_are_vault_references" {
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
    registry_username    = "install-puller"
    registry_password    = "pull-secret"
    telemetry_url        = "https://cp.masterlydata.com"
    telemetry_client_id  = "sa_01TEST"

    telemetry_client_secret = "telemetry-secret"
    breakglass_owner_email  = "owner@example.com"
    breakglass_secret_hash  = "0000000000000000000000000000000000000000000000000000000000000000"
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  # THE assertion this finding is about: not one app carries a value-based secret.
  assert {
    condition = (
      length(module.api.value_secret_names) == 0 &&
      length(module.frontend.value_secret_names) == 0 &&
      length(module.workers[0].value_secret_names) == 0
    )
    error_message = "With the Key Vault on, no app may hold a value-based secret — those are readable by any principal with containerApps/listSecrets."
  }

  # And every secret each app needs is still there, as a reference. Named exhaustively rather
  # than counted: a count passes just as happily when a secret silently stops being wired.
  assert {
    condition = module.api.vault_backed_secret_names == tolist([
      "breakglass-secret-hash",
      "database-url",
      "license-token",
      "redis-url",
      "registry-password",
      "session-secret",
      "telemetry-client-secret",
    ])
    error_message = "The api's full secret set must reach it as Key Vault references."
  }

  assert {
    condition     = module.frontend.vault_backed_secret_names == tolist(["oidc-client-secret", "registry-password"])
    error_message = "The frontend's BFF client secret and registry password must reach it as Key Vault references."
  }

  # The workers app runs the same env contract as the api, so it needs the same secret set.
  assert {
    condition     = module.workers[0].vault_backed_secret_names == module.api.vault_backed_secret_names
    error_message = "The workers app must carry the same secret set as the api — it builds the same services."
  }

  # Every one of them is written into the vault, under the install- prefix that keeps the
  # module's secrets clear of the ones the application seals at runtime (<slug>-<ulid>).
  assert {
    condition = (
      length(azurerm_key_vault_secret.install) == 8 &&
      azurerm_key_vault_secret.install["database-url"].name == "install-database-url" &&
      azurerm_key_vault_secret.install["oidc-client-secret"].name == "install-oidc-client-secret"
    )
    error_message = "Each distinct install secret must be written to the vault once, under the install- prefix."
  }

  # The deploying principal's data-plane grant: Contributor and Owner carry no Key Vault data
  # actions, so without it every write above fails on an RBAC-mode vault.
  assert {
    condition     = length(azurerm_role_assignment.kv_secrets_officer_deployer) == 1
    error_message = "The deploying principal must be granted Key Vault Secrets Officer, or Terraform cannot seed the secrets."
  }
}

# The opposite branch, unchanged: with no vault there is nowhere to put them, so the apps
# carry values exactly as they did before — and nothing is left dangling in between.
run "key_vault_off_keeps_value_based_secrets" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
  }

  assert {
    condition = (
      module.api.value_secret_names == tolist(["database-url", "redis-url", "session-secret"]) &&
      length(module.api.vault_backed_secret_names) == 0 &&
      length(azurerm_key_vault_secret.install) == 0
    )
    error_message = "Without the vault the apps must keep their value-based secrets and no vault secret may be planned."
  }
}

# Two-identity CI: the grants can be pinned to explicit principals instead of whoever is
# running the apply. Left implicit, state holds the apply identity's grant and every plan run
# by the OTHER identity proposes destroying it — the churn Layer 1 paid for.
run "key_vault_grants_can_be_pinned_to_explicit_principals" {
  command = plan

  variables {
    ingress_allowed_cidrs                = ["203.0.113.7/32"]
    enable_key_vault                     = true
    key_vault_secret_operator_object_ids = ["11111111-1111-1111-1111-111111111111"]
    key_vault_secret_reader_object_ids   = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition = (
      azurerm_role_assignment.kv_secrets_officer_deployer["11111111-1111-1111-1111-111111111111"].role_definition_name == "Key Vault Secrets Officer" &&
      azurerm_role_assignment.kv_secrets_reader["22222222-2222-2222-2222-222222222222"].role_definition_name == "Key Vault Secrets User"
    )
    error_message = "Explicit operator/reader object IDs must be granted Secrets Officer and Secrets User respectively."
  }
}

# Production with no deployer path stated: the vault is private-endpoint-only, so Terraform's
# own writes have nowhere to land. Refused at plan rather than as a 403 partway through the
# apply, with the install half-built.
run "production_without_a_deployer_path_is_rejected" {
  command = plan

  variables {
    mode                        = "production"
    identity_binding            = "oidc"
    oidc_allowed_issuers        = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience               = "api-client-id"
    oidc_jwks_uri               = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id              = "bff-client-id"
    oidc_client_secret          = "s3cret"
    oidc_authority              = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri           = "https://app.example.com/api/auth/callback"
    license_token               = "eyJ.fake.jwt"
    license_public_jwk          = "{\"kty\":\"EC\"}"
    initial_owner_email         = "owner@example.com"
    enable_key_vault            = true
    enable_redis                = true
    redis_offering              = "cache"
    enable_workers              = true
    api_max_replicas            = 3
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    key_vault_deployer_ip_rules = []
  }

  expect_failures = [var.key_vault_deployer_ip_rules]
}

# The other path: an apply that already runs inside the VNet needs no firewall exception, and
# the vault keeps no public presence at all.
run "production_in_vnet_apply_keeps_the_vault_closed" {
  command = plan

  variables {
    mode                        = "production"
    identity_binding            = "oidc"
    oidc_allowed_issuers        = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience               = "api-client-id"
    oidc_jwks_uri               = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id              = "bff-client-id"
    oidc_client_secret          = "s3cret"
    oidc_authority              = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri           = "https://app.example.com/api/auth/callback"
    license_token               = "eyJ.fake.jwt"
    license_public_jwk          = "{\"kty\":\"EC\"}"
    initial_owner_email         = "owner@example.com"
    enable_key_vault            = true
    enable_redis                = true
    redis_offering              = "cache"
    enable_workers              = true
    api_max_replicas            = 3
    external_database_url       = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    key_vault_deployer_ip_rules = []
    key_vault_deployer_in_vnet  = true
  }

  assert {
    condition = (
      azurerm_key_vault.this[0].public_network_access_enabled == false &&
      length(azurerm_key_vault.this[0].network_acls[0].ip_rules) == 0 &&
      length(azurerm_private_endpoint.key_vault) == 1
    )
    error_message = "An in-VNet apply must leave the production vault with no public presence and no firewall exception."
  }
}

# Key Vault rejects /31 and /32 prefixes outright, and a rule it rejects is a rule that admits
# nothing — the failure would surface as an apply-time 400, or worse, as a firewall that looks
# configured and lets no one through.
run "single_address_deployer_rule_must_not_be_slash_32" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    key_vault_deployer_ip_rules = ["203.0.113.7/32"]
  }

  expect_failures = [var.key_vault_deployer_ip_rules]
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

# One identity per app, and the frontend is why. Every data-plane grant in the install —
# Key Vault Secrets Officer, Service Bus send + receive, ACS Email Owner — belongs to the
# BACKEND identity; the internet-facing frontend runs as its own, holding image pull alone.
run "both_app_identities_keep_their_names" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  # A rename REPLACES the identity, and with it the principal id customers grant AcrPull to
  # out of band — so the names are contract, not cosmetics.
  assert {
    condition = (
      module.apps_identity.name == "id-masterly-apps" &&
      module.frontend_identity.name == "id-masterly-frontend"
    )
    error_message = "The app identity names must stay id-<prefix>-apps and id-<prefix>-frontend."
  }

  # Image pull is the one thing the frontend identity gets, so acr_id must grant BOTH
  # principals or the frontend cannot pull at all.
  assert {
    condition     = length(azurerm_role_assignment.acr_pull) == 1 && length(azurerm_role_assignment.acr_pull_frontend) == 1
    error_message = "acr_id must grant AcrPull to both app identities."
  }
}

# The split itself. Identity ids and principal ids are computed, so at plan they are
# unknown-vs-unknown and assert nothing; `override_module` pins both identities to known,
# distinct values so the wiring is actually checkable. (apply is not an option — the mock
# provider hands out ids that the azurerm provider then rejects as unparseable.)
run "no_data_plane_grant_reaches_the_frontend" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    enable_key_vault      = true
    enable_service_bus    = true
    enable_workers        = true
    email_acs_enabled     = true
  }

  override_module {
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.frontend_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"
      principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      client_id    = "ffffffff-ffff-ffff-ffff-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend"
    }
  }

  assert {
    condition = (
      one(module.frontend.user_assigned_identity_ids) == module.frontend_identity.id &&
      !contains(module.frontend.user_assigned_identity_ids, module.apps_identity.id)
    )
    error_message = "The frontend must run as its own identity, not the backend apps' identity."
  }

  assert {
    condition = (
      one(module.api.user_assigned_identity_ids) == module.apps_identity.id &&
      one(module.workers[0].user_assigned_identity_ids) == module.apps_identity.id
    )
    error_message = "The api and workers must keep the backend apps' identity."
  }

  assert {
    condition = (
      azurerm_role_assignment.kv_secrets_officer[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_receiver[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.acs_email_sender[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "Key Vault, Service Bus and ACS grants must go to the backend apps' identity."
  }

  # The point of the split: none of those reach the public app's identity. This run has the
  # frontend carrying no secret of its own (dev binding, no registry credential), so the
  # vault read grant is not created either — image pull really is the whole of it here.
  assert {
    condition = (
      azurerm_role_assignment.kv_secrets_officer[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_receiver[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.acs_email_sender[0].principal_id != module.frontend_identity.principal_id &&
      length(azurerm_role_assignment.kv_secrets_user_frontend) == 0
    )
    error_message = "No data-plane grant may reach the frontend's identity when it has no secret to resolve."
  }

  assert {
    condition = (
      azurerm_role_assignment.acr_pull[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.acr_pull_frontend[0].principal_id == module.frontend_identity.principal_id
    )
    error_message = "AcrPull must be granted to each identity separately."
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

# Guard: location_geo still rejects a value that is not a geo. Paired with the example's
# validate in CI, which is what caught the null case this condition originally had — `||`
# does not short-circuit in Terraform, so the unset default reached contains() and threw.
run "invalid_location_geo_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location_geo          = "emea"
  }

  expect_failures = [var.location_geo]
}

# --- The three network topologies the module serves without a fork -----------------------
# 1. public ingress behind an IP allowlist (the default, covered throughout above)
# 2. private ingress, reached over VPN/ExpressRoute
# 3. hub-and-spoke: subnets injected, the module owns no network at all

# The module builds its own VNet unless told otherwise — topology 1.
run "default_topology_owns_its_network" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 1 && length(azurerm_subnet.aca) == 1
    error_message = "With no subnets injected the module must create its own VNet and subnets."
  }

  assert {
    condition     = module.aca_env.internal_load_balancer_enabled == false
    error_message = "The default topology keeps the environment's public endpoint."
  }
}

# Topology 2: internal load balancer, no public endpoint. The frontend stays `external`
# because on an internal environment that means "reachable from the VNet", which is
# exactly what a VPN user needs.
run "private_ingress_topology" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
  }

  assert {
    condition     = module.aca_env.internal_load_balancer_enabled == true
    error_message = "aca_internal_load_balancer must reach the Container App Environment."
  }
}

# Guard: the footgun that makes an install unreachable from anywhere, including VPN.
run "internal_lb_with_unexposed_frontend_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    frontend_ingress_external  = false
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Topology 3: the platform team owns the spoke; the module creates no network.
run "injected_network_creates_no_network" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aca) == 0 && length(azurerm_subnet.private_endpoints) == 0
    error_message = "Injecting subnets must create no VNet and no subnets — the platform team owns them."
  }

  # The VNet is derived from the subnet id rather than asked for, so the two cannot disagree.
  assert {
    condition     = local.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    error_message = "The VNet id must be derived from the injected subnet id."
  }
}

# Guard: half an injected network.
run "half_injected_network_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    aca_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: private endpoints cannot live in the delegated ACA subnet.
run "same_subnet_twice_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# --- Telemetry to the control plane (ADR 0034/0056) --------------------------------------
# Built at both ends and never wired: the application's reporter gates on url AND client_id,
# and the module set neither, so no self-hosted install has ever reported.

# Off by default, and off means genuinely absent — not an empty string the app might read.
run "telemetry_is_off_unless_configured" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_TELEMETRY_URL")
    error_message = "With no telemetry inputs the reporting environment must not be set at all."
  }

  assert {
    condition     = local.telemetry_configured == false
    error_message = "telemetry_configured must be false when neither input is set."
  }
}

run "telemetry_wires_url_id_and_secret" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    telemetry_url           = "https://cp.masterlydata.com"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  assert {
    condition     = local.api_env["MASTERLY_TELEMETRY_URL"] == "https://cp.masterlydata.com"
    error_message = "telemetry_url must reach the apps."
  }

  assert {
    condition     = local.api_env["MASTERLY_TELEMETRY_CLIENT_ID"] == "sa_01TEST"
    error_message = "telemetry_client_id must reach the apps."
  }

  # The secret travels as a Container App secret, never as plain environment.
  assert {
    condition     = local.api_env_secret_refs["MASTERLY_TELEMETRY_CLIENT_SECRET"] == "telemetry-client-secret"
    error_message = "The telemetry secret must be a secret reference, not plain env."
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_TELEMETRY_CLIENT_SECRET")
    error_message = "The telemetry secret must never appear in the plain environment map."
  }
}

# Guard: half a configuration reports nothing while looking configured.
run "half_configured_telemetry_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    telemetry_url         = "https://cp.masterlydata.com"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: configured without the secret fails hourly at the control plane, not at plan.
run "telemetry_without_secret_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    telemetry_url         = "https://cp.masterlydata.com"
    telemetry_client_id   = "sa_01TEST"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# --- Licence refresh (ADR 0074): one input, off unless the credential is beside it ----------

run "license_refresh_is_off_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = local.license_refresh_configured == false
    error_message = "license_refresh_configured must be false when license_issuer_url is unset."
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_LICENSE_ISSUER_URL")
    error_message = "An unset license_issuer_url must not reach the apps — the offline posture makes no outbound call."
  }
}

run "license_refresh_wires_the_url_beside_the_install_credential" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_url           = "https://cp.masterlydata.com"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  assert {
    condition     = local.api_env["MASTERLY_LICENSE_ISSUER_URL"] == "https://cp.masterlydata.com/v1/licenses/refresh"
    error_message = "license_issuer_url must reach the apps verbatim — it is a full URL, not an origin."
  }

  # The workers app runs the refresh loop on a scaled install, so it must see the same env.
  assert {
    condition     = local.api_env["MASTERLY_TELEMETRY_CLIENT_ID"] == "sa_01TEST"
    error_message = "The install credential must reach the apps alongside the refresh URL."
  }
}

# Guard: the URL without the credential looks configured and never refreshes.
run "license_refresh_without_the_credential_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    license_issuer_url    = "https://cp.masterlydata.com/v1/licenses/refresh"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# The requirement the docs state must be the requirement the module enforces. The credential
# alone does not reach the control plane — telemetry_url is how it gets there — so a set that
# omits it is refused, and refused by the LICENCE precondition (it is evaluated first, so the
# one message Terraform prints names refresh rather than a telemetry pairing the customer
# never asked for). Without this run, following the README produced a plan failure about a
# feature the customer had not enabled.
run "license_refresh_without_telemetry_url_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Not a production requirement (ADR 0074 §2: refresh is optional; air-gapped stays first-class).
run "production_does_not_require_license_refresh" {
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
    condition     = local.license_refresh_configured == false
    error_message = "mode=production must plan without license_issuer_url — refresh is optional by decision, not a production requirement."
  }
}

# --- The api's ingress: internal by default, opt-out, never unrestricted --------------------
# The published Python SDK talks to the api directly (bearer token to /v1), not through the
# frontend's BFF — which proxies /api/proxy/... with session cookies and short-circuits
# unauthenticated requests without forwarding. While the api was hardcoded internal, no
# self-hosted install could be reached by the SDK we publish and document.

run "the_api_is_internal_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.api.ingress_external == false
    error_message = "The api must stay internal unless asked for: it sits behind the BFF."
  }

  # Plain HTTP is deliberate while the api is unreachable from outside: the hop it serves is
  # the BFF's http://ca-api, and https://ca-api cannot pass hostname verification against the
  # environment's certificate. What keeps that hop off the wire in the clear is the
  # environment's peer encryption, asserted below, not this flag.
  assert {
    condition     = module.api.ingress_allow_insecure == true
    error_message = "An internal api must still serve the BFF's http:// hop."
  }
}

run "api_ingress_can_be_opted_into_and_is_narrowed" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
  }

  assert {
    condition     = module.api.ingress_external == true
    error_message = "api_ingress_external must reach the api app."
  }

  # The flag being set proves nothing about who can reach it. Until this assertion existed,
  # removing the allowlist from the api entirely still passed every test in this file.
  assert {
    condition     = module.api.ingress_allowed_ip_ranges == ["203.0.113.7/32"]
    error_message = "An externally-exposed api must carry the same allowlist the frontend does."
  }

  assert {
    condition     = module.frontend.ingress_allowed_ip_ranges == ["203.0.113.7/32"]
    error_message = "The frontend allowlist must be unaffected by the api opting in."
  }
}

# Guard: exposing /v1 to the whole internet as the price of SDK access would be a worse
# problem than the one being solved. Empty means UNRESTRICTED in Azure, not deny-all.
run "external_api_without_an_allowlist_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = []
    api_ingress_external  = true
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
  }

  expect_failures = [azurerm_resource_group.aca]
}


# The finding this closes: `allow_insecure_connections` was hardcoded true, which was
# defensible while the api was unreachable and stopped being defensible the moment
# api_ingress_external existed. Port 80 answering without a redirect, for callers whose
# whole credential is a bearer token, is what the allowlist does not cover.
run "external_api_refuses_insecure" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
  }

  assert {
    condition     = module.api.ingress_allow_insecure == false
    error_message = "A published api must redirect http:// to https://, not serve it."
  }

  # The frontend is published in every topology, so it never had a reason to allow insecure.
  # Pinned anyway: this is the assertion that fails if someone widens the api's flip into a
  # module-wide default in the wrong direction.
  assert {
    condition     = module.frontend.ingress_allow_insecure == false
    error_message = "The frontend must redirect http:// to https://."
  }
}

# The other half of the same finding. Flipping the api to HTTPS-only would push the plaintext
# problem onto the in-environment hop if this were not on, because the BFF keeps calling
# http://ca-api by app name — the one address that cannot drift and cannot be verified over
# TLS by the client. Azure encrypts it below the application instead.
run "the_environment_encrypts_peer_traffic" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.aca_env.mutual_tls_enabled == true
    error_message = "Traffic between apps inside the environment must be encrypted."
  }

  # The BFF still addresses the api by app name, so it is still speaking http:// — which is
  # only safe because of the assertion above. Pinned here rather than in a separate run so
  # that deleting the encryption and keeping the address cannot pass quietly.
  assert {
    condition     = contains(module.frontend.env_names, "MASTERLY_API_BASE_URL")
    error_message = "The BFF must be told where the api is."
  }
}

# An app that is ALLOWED to sit at zero replicas gets no replica-availability alert, because on
# such an install zero replicas is the intended state and the alert would page every idle night.
# The gate is per app, not per install: turn diagnostics on for an evaluation install that
# scales the api to zero and the frontend still keeps its floor, so it still keeps its alert.
# Asserting the shape of the map, not just its size — a regression that alerted on the api and
# skipped the frontend would keep the count at one (MAS-263).
run "scale_to_zero_apps_get_no_replica_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    api_min_replicas      = 0
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 1 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "frontend")
    )
    error_message = "Only the app that declares a replica floor may carry a no-replica alert; a scale-to-zero app must not."
  }

  # The database alerts do not depend on replica counts at all, so enabling diagnostics on an
  # evaluation install still buys the availability coverage that matters most: this install
  # provisions the starter server, so both database alerts are present.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 1
    )
    error_message = "Enabling diagnostics outside production must still bring the database availability alerts."
  }
}
