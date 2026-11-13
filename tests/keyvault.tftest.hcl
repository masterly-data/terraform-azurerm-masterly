# The Key Vault, its grants, and the install's secrets in it (keyvault.tf).
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

# Key Vault (ADR 0066): enabled provisions the vault + the app secrets role and grant and flips
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
      length(azurerm_role_definition.app_secrets) == 1 &&
      length(azurerm_role_assignment.kv_app_secrets) == 1
    )
    error_message = "enable_key_vault must provision the vault, the app secrets role and its grant."
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

  # Diagnostics default off outside production: no settings, no saturation or load alerts. The
  # availability alerts do not depend on diagnostics and exist in every mode.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.key_vault) == 0 &&
      length(azurerm_monitor_metric_alert.app_5xx) == 0 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1 &&
      length(azurerm_monitor_metric_alert.postgres_cpu) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_connections) == 0 &&
      length(azurerm_monitor_metric_alert.postgres_iops) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.api_latency) == 0 &&
      length(azurerm_monitor_diagnostic_setting.app) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 0
    )
    error_message = "Diagnostics must be off by default outside production, while the availability alerts exist."
  }
}

# The erasure keys (ADR 0081) live in this same vault, and the application creates them at
# runtime — so the grant that lets it is vault-scoped and has to be Crypto Officer, the only
# built-in Crypto role that can create a key. Pinning the role name and the principal is the
# point: Crypto User would fail the first erasure an install runs, months after the apply that
# looked clean, and a grant that drifted onto the frontend's identity would hand the
# internet-facing app the signing key.
run "key_vault_enabled_grants_the_apps_identity_crypto_officer" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
  }

  # The identity's principal id is only known after apply, so it is supplied here — the same
  # shape the frontend grant test uses — and the assertion below is then about the grant's
  # target rather than about what the mock provider happened to return.
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

  assert {
    condition = (
      length(azurerm_role_assignment.kv_crypto_officer) == 1 &&
      azurerm_role_assignment.kv_crypto_officer[0].role_definition_name == "Key Vault Crypto Officer" &&
      azurerm_role_assignment.kv_crypto_officer[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "enable_key_vault must grant the apps identity Key Vault Crypto Officer, and no other Crypto role."
  }

  # The grant's scope is the install's own vault. It is a computed id, so a plan cannot compare
  # it to a literal; what a plan can prove is that exactly one vault is being created for it to
  # name, which is what makes "scoped to this vault" true rather than merely intended.
  assert {
    condition     = length(azurerm_key_vault.this) == 1
    error_message = "The Crypto Officer grant is scoped to the install vault, so exactly one vault must be planned beside it."
  }
}

# The other branch: no vault, no key grant. A role assignment left planned against a vault that
# is not created is a plan that cannot apply.
run "key_vault_off_plans_no_crypto_grant" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_role_assignment.kv_crypto_officer) == 0
    error_message = "Without the vault there is nothing to grant Crypto Officer on."
  }

  # Nor a frontend read grant: there are no vault secrets to scope one to.
  assert {
    condition     = length(azurerm_role_assignment.kv_secrets_user_frontend) == 0
    error_message = "Without the vault no Key Vault role assignment may be planned for the frontend."
  }
}

# When the frontend DOES carry secrets, it resolves them itself — so it needs data-plane read
# on each of them, and that is the one grant the split admits. It must be the NARROWEST one:
# the frontend never writes sealed material, and it is the app an attacker reaches first.
# Pinning the role name is the whole point — Secrets Officer would resolve the secrets just as
# well and hand the public front door write access to every credential it can see. The keys
# pin the other half: one grant per frontend secret, so nothing the backend holds is granted.
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
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(["bff-shared-secret", "registry-password", "oidc-client-secret"]) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(local.frontend_secret_names) &&
      alltrue([
        for k, ra in azurerm_role_assignment.kv_secrets_user_frontend :
        ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.frontend_identity.principal_id
      ])
    )
    error_message = "A frontend carrying vault-backed secrets must get Key Vault Secrets User on its own identity, once per frontend secret — read, and nothing more."
  }

  # The app secrets and Crypto Officer grants stay where they were: on the backend apps, never on
  # the public one.
  assert {
    condition = (
      azurerm_role_assignment.kv_app_secrets[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.kv_crypto_officer[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "The app secrets role and Key Vault Crypto Officer must never reach the frontend's identity."
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
      "bff-shared-secret",
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
    condition     = module.frontend.vault_backed_secret_names == tolist(["bff-shared-secret", "oidc-client-secret", "registry-password"])
    error_message = "The frontend's BFF shared secret, BFF client secret and registry password must reach it as Key Vault references."
  }

  # The workers app runs the same env contract as the api, so it needs the same secret set —
  # all but the BFF shared secret, which authenticates the frontend's calls to the api and
  # belongs to those two apps alone.
  assert {
    condition     = module.workers[0].vault_backed_secret_names == tolist([for name in module.api.vault_backed_secret_names : name if name != "bff-shared-secret"])
    error_message = "The workers app must carry the api's secret set, less the BFF shared secret — it builds the same services and serves no request."
  }

  # Every one of them is written into the vault, under the install- prefix that keeps the
  # module's secrets clear of the ones the application seals at runtime (<slug>-<ulid>).
  assert {
    condition = (
      length(azurerm_key_vault_secret.install) == 9 &&
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
      module.api.value_secret_names == tolist(["bff-shared-secret", "database-url", "redis-url", "session-secret"]) &&
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

  # Outside production servicebus_sku has no value of its own and means Standard, which is
  # what the variable defaulted to before it lost its default, so such an install plans no
  # change to its namespace.
  assert {
    condition     = azurerm_servicebus_namespace.this[0].sku == "Standard"
    error_message = "Outside production an unset servicebus_sku must still plan a Standard namespace."
  }

  # SAS off (ADR 0029): managed identity only, so there is no connection string to leak.
  assert {
    condition     = azurerm_servicebus_namespace.this[0].local_auth_enabled == false
    error_message = "The namespace must refuse SAS auth — the apps authenticate as their managed identity."
  }

  # TLS floor stated by the module, not left to the provider's default.
  assert {
    condition     = azurerm_servicebus_namespace.this[0].minimum_tls_version == "1.2"
    error_message = "The namespace must refuse clients below TLS 1.2."
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

  # The lock duration is stated, at Azure's maximum, rather than left to the one-minute
  # default. The worker renews it during a drain; this is the margin after a failed renewal.
  assert {
    condition     = azurerm_servicebus_queue.jobs[0].lock_duration == "PT5M"
    error_message = "The jobs queue must set a five-minute lock duration, not Azure's one-minute default."
  }
}

# Dead-lettered job messages (MAS-1291): any message in the job queue's dead-letter sub-queue,
# read as the Maximum so one arriving inside the window is seen, and scoped to that queue by
# name so a later queue in the namespace is not swept in. Severity 1: work may already be stuck.
run "service_bus_dead_letters_are_alerted" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    enable_workers        = true
    enable_diagnostics    = true
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.servicebus_dead_letters) == 1 &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].severity == 1 &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].window_size == "PT15M" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].metric_namespace == "Microsoft.ServiceBus/namespaces" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].metric_name == "DeadletteredMessages" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].aggregation == "Maximum" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].operator == "GreaterThan" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].threshold == 0 &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].dimension[0].name == "EntityName" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].dimension[0].operator == "Include" &&
      azurerm_monitor_metric_alert.servicebus_dead_letters[0].criteria[0].dimension[0].values == tolist(["masterly-jobs"])
    )
    error_message = "The dead-letter alert must read DeadletteredMessages (Maximum) above 0 on the masterly-jobs queue."
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

  # Disabled, Service Bus leaves nothing behind on the network side either: no endpoint, no
  # zone, and no AMQP port opened on the endpoints subnet.
  assert {
    condition = (
      length(azurerm_private_endpoint.servicebus) == 0 &&
      length(azurerm_private_dns_zone.servicebus) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.servicebus) == 0 &&
      !anytrue([
        for rule in azurerm_network_security_group.private_endpoints[0].security_rule :
        contains(rule.destination_port_ranges, "5671")
        if rule.name == "allow-data-plane-from-apps"
      ])
    )
    error_message = "With Service Bus off there is no Service Bus endpoint, zone, or AMQP port."
  }
}

# Service Bus in production on Premium: Azure's recommended baseline (ADR 0066, amendment of
# 2026-09-24; Azure Policy cbd11fd3-3002-4907-b6c8-579f0e700e13). Public network access is
# Disabled — IP rules would not pass the policy — and the apps reach the namespace over a
# private endpoint with its private DNS zone, the same shape as Postgres, Key Vault and Redis.
run "production_premium_service_bus_is_private" {
  command = plan

  variables {
    mode                  = "production"
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
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_service_bus    = true
    servicebus_sku        = "Premium"
  }

  assert {
    condition = (
      azurerm_servicebus_namespace.this[0].sku == "Premium" &&
      azurerm_servicebus_namespace.this[0].public_network_access_enabled == false
    )
    error_message = "A production Premium namespace must have public network access disabled."
  }

  # Premium is refused by the service with no messaging unit, so the module states one.
  assert {
    condition = (
      azurerm_servicebus_namespace.this[0].capacity == 1 &&
      azurerm_servicebus_namespace.this[0].premium_messaging_partitions == 1
    )
    error_message = "A Premium namespace needs one messaging unit and one partition; 0 is refused at apply."
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.servicebus) == 1 &&
      azurerm_private_endpoint.servicebus[0].private_service_connection[0].subresource_names == tolist(["namespace"]) &&
      azurerm_private_endpoint.servicebus[0].resource_group_name == azurerm_resource_group.data.name &&
      length(azurerm_private_dns_zone.servicebus) == 1 &&
      azurerm_private_dns_zone.servicebus[0].name == "privatelink.servicebus.windows.net" &&
      length(azurerm_private_dns_zone_virtual_network_link.servicebus) == 1
    )
    error_message = "A private namespace needs a private endpoint on the namespace subresource, in the data resource group, with a privatelink.servicebus.windows.net zone linked to the VNet."
  }

  # The endpoint lives in the module's endpoints subnet, and that subnet's NSG admits AMQP over
  # TLS from the runtime subnet: without 5671 the apps' Service Bus client cannot connect.
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.private_endpoints[0].security_rule :
      rule.source_address_prefix == azurerm_subnet.aca[0].address_prefixes[0] &&
      contains(rule.destination_port_ranges, "5671") &&
      contains(rule.destination_port_ranges, "443")
      if rule.name == "allow-data-plane-from-apps"
    ])
    error_message = "The endpoints subnet must admit AMQP over TLS (5671) from the runtime subnet when the namespace is private."
  }
}

# A landing zone that centralizes private DNS supplies the zone: the module creates none and
# no VNet link, and the endpoint registers in the injected zone.
run "production_premium_service_bus_uses_injected_dns_zone" {
  command = plan

  variables {
    mode                           = "production"
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
    api_max_replicas               = 3
    external_database_url          = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_service_bus             = true
    servicebus_sku                 = "Premium"
    servicebus_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.servicebus) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.servicebus) == 0 &&
      length(azurerm_private_endpoint.servicebus) == 1 &&
      azurerm_private_endpoint.servicebus[0].private_dns_zone_group[0].private_dns_zone_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"])
    )
    error_message = "An injected Service Bus zone must be used as given, with no zone or link created."
  }
}

# Guard: an injected zone of any other name would leave the namespace's hostname resolving to
# its public address, which a private namespace refuses — a broken bus that plans clean.
run "service_bus_dns_zone_of_the_wrong_name_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    enable_service_bus             = true
    servicebus_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  expect_failures = [var.servicebus_private_dns_zone_id]
}

# Production asks for the SKU rather than defaulting it (owner decision on MAS-1086). A
# Premium default would replace every existing Standard namespace whose install never set the
# SKU (azurerm forces replacement on any move to or from Premium), and a Standard default
# would leave a new install off Azure's baseline without anyone choosing that. So production
# with Service Bus enabled and no SKU is refused at plan, as redis_offering is.
run "production_service_bus_without_sku_is_rejected" {
  command = plan

  variables {
    mode                  = "production"
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
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_service_bus    = true
  }

  expect_failures = [var.servicebus_sku]
}

# The refusal is about the namespace, not the input: production with Service Bus off needs no
# SKU and plans no namespace.
run "production_without_service_bus_needs_no_sku" {
  command = plan

  variables {
    mode                  = "production"
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
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_servicebus_namespace.this) == 0 &&
      length(azurerm_private_endpoint.servicebus) == 0
    )
    error_message = "Production with Service Bus disabled must plan without servicebus_sku and create no namespace."
  }
}

# An empty string is what an unset TF_VAR_ or a rendered template produces. It must not pass
# as "unset" and then be read as Standard.
run "service_bus_empty_sku_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    servicebus_sku        = ""
  }

  expect_failures = [var.servicebus_sku]
}

# The opt-down: Standard in production keeps a public endpoint, because Standard cannot host
# a private endpoint. It plans no endpoint, no zone, no AMQP port, and leaves an existing
# Standard namespace's capacity and partitions where the provider records them (0), so it
# plans no change to that namespace.
run "production_standard_service_bus_keeps_public_endpoint" {
  command = plan

  variables {
    mode                  = "production"
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
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    enable_service_bus    = true
    servicebus_sku        = "Standard"
  }

  assert {
    condition = (
      azurerm_servicebus_namespace.this[0].sku == "Standard" &&
      azurerm_servicebus_namespace.this[0].public_network_access_enabled == true &&
      azurerm_servicebus_namespace.this[0].capacity == 0 &&
      azurerm_servicebus_namespace.this[0].premium_messaging_partitions == 0
    )
    error_message = "A Standard namespace keeps public access and takes no messaging units."
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.servicebus) == 0 &&
      length(azurerm_private_dns_zone.servicebus) == 0 &&
      !anytrue([
        for rule in azurerm_network_security_group.private_endpoints[0].security_rule :
        contains(rule.destination_port_ranges, "5671")
        if rule.name == "allow-data-plane-from-apps"
      ])
    )
    error_message = "A Standard namespace gets no private endpoint, no zone and no AMQP port."
  }
}

# Outside production nothing changes: a Premium namespace keeps public access, as Key Vault
# does outside production, for ease of evaluation. It still gets its messaging unit.
run "non_production_premium_service_bus_stays_public" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_service_bus    = true
    servicebus_sku        = "Premium"
  }

  assert {
    condition = (
      azurerm_servicebus_namespace.this[0].public_network_access_enabled == true &&
      azurerm_servicebus_namespace.this[0].capacity == 1 &&
      length(azurerm_private_endpoint.servicebus) == 0 &&
      length(azurerm_private_dns_zone.servicebus) == 0
    )
    error_message = "Outside production a Premium namespace keeps public access and gets no private endpoint."
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

# Guard: mode=production refuses a workers app that may sit at zero replicas. ca-workers has
# no ingress, so nothing wakes it, and at a zero floor its no-replica alert stands down too —
# the pipeline would stall with nothing reporting it.
run "production_workers_scale_to_zero_is_rejected" {
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

    workers_min_replicas = 0 # scale-to-zero for the pipeline in production -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.workers_min_replicas]
}

# The same production install with the workers floor at 1 plans clean: the guard refuses zero,
# not the workers app.
run "production_workers_floor_of_one_plans" {
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

    workers_min_replicas = 1

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition     = output.workers_app_name == "ca-workers"
    error_message = "A production install with workers_min_replicas = 1 must plan the workers app."
  }
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
# the app secrets role on the vault, Service Bus send + receive, ACS Email Owner — belongs to the
# BACKEND identity; the internet-facing frontend runs as its own, holding image pull alone.
run "both_app_identities_keep_their_names" {
  command = plan

  variables {
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    acr_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    migrations                     = "job" # the migrate identity exists only then
    mode                           = "production"
    identity_binding               = "oidc"
    oidc_allowed_issuers           = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                  = "api-client-id"
    oidc_jwks_uri                  = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "test-only"
    oidc_authority                 = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = jsonencode({ kty = "EC" })
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "managed"
    enable_workers                 = true
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    database_auth                  = "password"
  }

  # A rename REPLACES the identity, and with it the principal id customers grant AcrPull to
  # out of band — so the names are contract, not cosmetics.
  assert {
    condition = (
      module.apps_identity.name == "id-masterly-apps" &&
      module.frontend_identity.name == "id-masterly-frontend" &&
      module.migrate_identity[0].name == "id-masterly-migrate"
    )
    error_message = "The identity names must stay id-<prefix>-apps, id-<prefix>-frontend and id-<prefix>-migrate."
  }

  # Image pull is the one thing the frontend identity gets, so acr_id must grant BOTH
  # principals or the frontend cannot pull at all; the migrate job pulls the api image too, and
  # with "job" on the starter server ca-workers pulls as id-<prefix>-workers.
  assert {
    condition = (
      length(azurerm_role_assignment.acr_pull) == 1 &&
      length(azurerm_role_assignment.acr_pull_frontend) == 1 &&
      length(azurerm_role_assignment.acr_pull_migrate) == 1 &&
      length(azurerm_role_assignment.acr_pull_workers) == 1
    )
    error_message = "acr_id must grant AcrPull to both app identities, to the migrate job's identity and, with \"job\" on the starter server, to the workers' identity."
  }

  # With "job" on the starter server ca-workers runs as its own identity; its name is contract
  # for the same reason, since customers grant it AcrPull out of band when acr_id is null.
  assert {
    condition     = module.workers_identity[0].name == "id-masterly-workers"
    error_message = "The workers' identity name must stay id-<prefix>-workers."
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

  override_module {
    target = module.workers_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"
      principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      client_id    = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-workers"
    }
  }

  assert {
    condition = (
      one(module.frontend.user_assigned_identity_ids) == module.frontend_identity.id &&
      !contains(module.frontend.user_assigned_identity_ids, module.apps_identity.id) &&
      !contains(module.frontend.user_assigned_identity_ids, module.workers_identity[0].id)
    )
    error_message = "The frontend must run as its own identity, not a backend app's identity."
  }

  # With the vault and "password" ca-workers runs as its own identity (workers.tf).
  assert {
    condition = (
      one(module.api.user_assigned_identity_ids) == module.apps_identity.id &&
      one(module.workers[0].user_assigned_identity_ids) == module.workers_identity[0].id
    )
    error_message = "The api must keep the backend apps' identity, and ca-workers run as its own."
  }

  assert {
    condition = (
      azurerm_role_assignment.kv_app_secrets[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id == module.workers_identity[0].principal_id &&
      azurerm_role_assignment.acs_email_sender[0].principal_id == module.apps_identity.principal_id
    )
    error_message = "Key Vault, Service Bus and ACS grants must go to the backend apps' identity, and Service Bus Receiver and the queue's Data Owner to ca-workers' own."
  }

  # The point of the split: none of those reach the public app's identity. Even with the
  # dev binding and no registry credential the frontend carries one secret of its own, the BFF
  # shared secret, which it resolves from the vault itself — so the one vault grant it does get
  # is read on that secret, and nothing more.
  assert {
    condition = (
      azurerm_role_assignment.kv_app_secrets[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_sender[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_sender_workers[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_receiver_workers[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.sb_scaler_workers[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.acs_email_sender[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.acs_email_sender_workers[0].principal_id != module.frontend_identity.principal_id &&
      azurerm_role_assignment.kv_app_secrets_workers[0].principal_id != module.frontend_identity.principal_id &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(["bff-shared-secret"]) &&
      alltrue([
        for k, ra in azurerm_role_assignment.kv_secrets_user_frontend :
        ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.frontend_identity.principal_id
      ])
    )
    error_message = "The only data-plane grant that may reach the frontend's identity is Key Vault Secrets User on its own secret (the BFF shared secret here)."
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

# --- The frontend's vault grant is per secret, never the vault -----------------------------
# The vault holds every install secret — the admin DSN, the session secret, the licence, the
# Redis URL, the telemetry secret, the break-glass hash — and everything the api seals at
# runtime (KeyVaultSecretStore, ADR 0066). The frontend is the internet-facing app, so its
# identity holds Secrets User on each of ITS secrets and on nothing else in the vault.
#
# An apply, and last in the file, because the scopes are computed: at plan they are unknown and
# `override_during = plan` needs Terraform 1.11 while CI runs 1.10. It targets the frontend's
# grants and so applies only what they depend on (the vault, its secrets and their inputs, the
# Redis cache among them). Each of those gets a well-formed ID: the teardown at the end of the
# file evaluates the whole configuration against this state, and mock IDs fail the provider's
# own checks of the IDs one resource hands another. Keep it last: every run after it would
# plan against the state it leaves.
run "the_frontend_holds_secrets_user_on_its_own_secrets_only" {
  command = apply

  plan_options {
    target = [azurerm_role_assignment.kv_secrets_user_frontend, azurerm_role_assignment.kv_secrets_user_migrate]
  }

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
    migrations              = "job" # the migrate job's grants, asserted below

    key_vault_secret_operator_object_ids = ["11111111-1111-1111-1111-111111111111"]
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

  # The vault secrets include the migrate job's DSN, whose URL module names the migrate
  # identity, so it is applied too; the teardown hands its ID to the migrate job.
  override_module {
    target = module.migrate_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
      principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-migrate"
    }
  }

  override_resource {
    target = azurerm_resource_group.data
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data"
    }
  }

  override_resource {
    target = azurerm_key_vault.this
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test"
      vault_uri = "https://kv-masterly-test.vault.azure.net/"
    }
  }

  # The Redis URL is one of the secrets, so the cache is applied too; its alerts, its access
  # policy assignment and its private endpoint parse its ID at the teardown.
  override_resource {
    target = azurerm_redis_cache.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redis/redis-masterly-test"
    }
  }

  # Every secret gets its own ARM id, which the frontend's grants are scoped to, and its own
  # data-plane URL, which the apps' Key Vault references parse at the teardown.
  override_resource {
    target = azurerm_key_vault_secret.install["bff-shared-secret"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-bff-shared-secret"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-bff-shared-secret"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["registry-password"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-registry-password"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-registry-password"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["oidc-client-secret"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-oidc-client-secret"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-oidc-client-secret"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["database-url"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-database-url"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-database-url"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["session-secret"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-session-secret"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-session-secret"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["license-token"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-license-token"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-license-token"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["redis-url"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-redis-url"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-redis-url"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["telemetry-client-secret"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-telemetry-client-secret"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-telemetry-client-secret"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["breakglass-secret-hash"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-breakglass-secret-hash"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-breakglass-secret-hash"
    }
  }

  override_resource {
    target = azurerm_key_vault_secret.install["migrate-database-url"]
    values = {
      versionless_id          = "https://kv-masterly-test.vault.azure.net/secrets/install-migrate-database-url"
      resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test/secrets/install-migrate-database-url"
    }
  }

  # The migrate job's identity, the same way (migrate.tf): read on its own DSN and the registry
  # password it pulls with, each scoped to that secret, never to the vault.
  assert {
    condition = (
      toset(keys(azurerm_role_assignment.kv_secrets_user_migrate)) == toset(["migrate-database-url", "registry-password"]) &&
      alltrue([
        for k, ra in azurerm_role_assignment.kv_secrets_user_migrate :
        ra.scope == azurerm_key_vault_secret.install[k].resource_versionless_id &&
        ra.scope != azurerm_key_vault.this[0].id &&
        ra.role_definition_name == "Key Vault Secrets User" &&
        ra.principal_id == module.migrate_identity[0].principal_id
      ])
    )
    error_message = "The migrate job's identity must hold Key Vault Secrets User on each of its own secrets alone, scoped to that secret, never to the vault."
  }

  # The configuration does write the backend's secrets to the same vault — that is what makes
  # the scoping below matter.
  assert {
    condition = alltrue([
      for name in ["database-url", "session-secret", "license-token", "redis-url", "telemetry-client-secret", "breakglass-secret-hash"] :
      contains(keys(azurerm_key_vault_secret.install), name)
    ])
    error_message = "This run must write the backend's secrets to the vault, or it proves nothing about the frontend not reaching them."
  }

  # Exactly one grant per frontend secret: the BFF shared secret, the registry password and the
  # BFF's OIDC client secret.
  assert {
    condition = (
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(local.frontend_secret_names) &&
      toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)) == toset(["bff-shared-secret", "registry-password", "oidc-client-secret"])
    )
    error_message = "The frontend's identity must hold exactly one Key Vault grant per frontend secret: bff-shared-secret, registry-password and oidc-client-secret."
  }

  # Each grant is scoped to its own secret's ARM id — and none to the vault.
  assert {
    condition = alltrue([
      for k, ra in azurerm_role_assignment.kv_secrets_user_frontend :
      ra.scope == azurerm_key_vault_secret.install[k].resource_versionless_id && ra.scope != azurerm_key_vault.this[0].id
    ])
    error_message = "Each frontend grant must be scoped to its own secret (resource_versionless_id), never to the vault."
  }

  assert {
    condition     = length(distinct([for ra in values(azurerm_role_assignment.kv_secrets_user_frontend) : ra.scope])) == length(azurerm_role_assignment.kv_secrets_user_frontend)
    error_message = "No two frontend grants may share a scope: each must name a different secret."
  }

  # Nothing only the backend carries is reachable by the frontend's identity.
  assert {
    condition = (
      length(setintersection(
        toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)),
        toset(["database-url", "session-secret", "license-token", "redis-url", "telemetry-client-secret", "breakglass-secret-hash"]),
      )) == 0 &&
      length(setintersection(
        toset(keys(azurerm_role_assignment.kv_secrets_user_frontend)),
        setsubtract(toset(local.backend_secret_names), toset(local.frontend_secret_names)),
      )) == 0
    )
    error_message = "No backend-only secret (database-url, session-secret, license-token, redis-url, telemetry-client-secret, breakglass-secret-hash) may be granted to the frontend's identity."
  }

  assert {
    condition = alltrue([
      for k, ra in azurerm_role_assignment.kv_secrets_user_frontend :
      ra.role_definition_name == "Key Vault Secrets User" && ra.principal_id == module.frontend_identity.principal_id
    ])
    error_message = "Every frontend grant must be Key Vault Secrets User on the frontend's own identity, never Officer."
  }
}

# Planned against the state the_frontend_holds_secrets_user_on_its_own_secrets_only above leaves: its conditions read values that are known only
# after an apply, so it follows that apply here rather than sitting with the other
# migrate job runs (MAS-4478).
run "migrate_job_runs_the_migrate_role_as_its_own_identity" {
  command = plan

  variables {
    migrations                        = "job"
    ingress_allowed_cidrs             = ["203.0.113.7/32"]
    mode                              = "production"
    identity_binding                  = "oidc"
    oidc_allowed_issuers              = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                     = "api-client-id"
    oidc_jwks_uri                     = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                    = "bff-client-id"
    oidc_client_secret                = "test-only"
    oidc_authority                    = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri                 = "https://app.example.com/api/auth/callback"
    license_token                     = "eyJ.fake.jwt"
    license_public_jwk                = jsonencode({ kty = "EC" })
    initial_owner_email               = "owner@example.com"
    enable_key_vault                  = true
    enable_redis                      = true
    redis_offering                    = "managed"
    enable_workers                    = true
    api_max_replicas                  = 2
    postgres_sku_name                 = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha        = true
    postgres_backup_retention_days    = 14
    database_auth                     = "password"
    org_id                            = "org_migrate_regression"
    org_name                          = "Migration regression organization"
    migrate_byo_database_secret_names = ["environment-a-connection", "environment-b-connection"]
  }

  override_module {
    target = module.migrate_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
      principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_id    = "dddddddd-dddd-dddd-dddd-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-migrate"
    }
  }

  override_resource {
    target = azurerm_key_vault.this[0]
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-test"
      vault_uri = "https://kv-masterly-test.vault.azure.net/"
    }
  }

  assert {
    condition = (
      azurerm_container_app_job.migrate[0].name == "caj-migrate" &&
      azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0" &&
      azurerm_container_app_job.migrate[0].template[0].container[0].image == module.api.image &&
      azurerm_container_app_job.migrate[0].template[0].container[0].command == tolist(["python", "-m", "masterly_app.apps.migrate"])
    )
    error_message = "The migrate job must run python -m masterly_app.apps.migrate on the resolved api image."
  }

  # azurerm_container_app_job has no ingress argument at all: the job takes no request.
  assert {
    condition = (
      azurerm_container_app_job.migrate[0].identity[0].type == "UserAssigned" &&
      length(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == 1 &&
      one(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == module.migrate_identity[0].id
    )
    error_message = "The migrate job must run as id-<prefix>-migrate and nothing else."
  }

  assert {
    condition = (
      length(azurerm_container_app_job.migrate[0].schedule_trigger_config) == 1 &&
      azurerm_container_app_job.migrate[0].schedule_trigger_config[0].cron_expression == var.migrate_job_schedule &&
      var.migrate_job_schedule == "*/5 * * * *" &&
      azurerm_container_app_job.migrate[0].schedule_trigger_config[0].parallelism == 1 &&
      azurerm_container_app_job.migrate[0].schedule_trigger_config[0].replica_completion_count == 1 &&
      length(azurerm_container_app_job.migrate[0].manual_trigger_config) == 0 &&
      length(azurerm_container_app_job.migrate[0].event_trigger_config) == 0
    )
    error_message = "The migrate job must run on migrate_job_schedule (default every five minutes), one replica at a time."
  }

  assert {
    condition = (
      contains(module.api.env_names, "MASTERLY_MIGRATIONS") &&
      contains(module.workers[0].env_names, "MASTERLY_MIGRATIONS") &&
      local.api_env["MASTERLY_MIGRATIONS"] == "job" &&
      !contains(module.frontend.env_names, "MASTERLY_MIGRATIONS")
    )
    error_message = "ca-api and ca-workers must carry MASTERLY_MIGRATIONS = job; the frontend runs no migration."
  }

  assert {
    condition = (
      length(azurerm_container_app_job.migrate) == 1 &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_ORG_ID"]) == var.org_id &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_ORG_ID"]) == local.api_env["MASTERLY_ORG_ID"] &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_ORG_NAME"]) == var.org_name &&
      local.api_env["MASTERLY_ORG_NAME"] == var.org_name &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MODE"]) == var.mode &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_MODE"]) == local.api_env["MASTERLY_MODE"] &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_CONTROLPLANE_STORE"]) == "postgres"
    )
    error_message = "The migrate entry point needs the API's organization and production mode, with the Postgres control plane, before it can migrate or provision Environments."
  }

  # Explicit password authentication: no second administrator, and the job connects
  # as masterly_admin, as ca-api does. The role is what module.postgres_connection_urls_migrate
  # composes the URL's user from (tests/postgres_connection_urls.tftest.hcl proves the
  # composition); the URL itself embeds the generated password, unknown at plan.
  assert {
    condition = (
      length(azurerm_postgresql_flexible_server_active_directory_administrator.migrate) == 0 &&
      local.database_auth_mode == "password" &&
      local.migrate_database_role == "masterly_admin" &&
      local.migrate_database_role == local.database_role &&
      length(module.postgres_connection_urls_migrate) == 1 &&
      local.migrate_env["AZURE_CLIENT_ID"] == module.migrate_identity[0].client_id &&
      !contains(keys(local.migrate_env), "MASTERLY_DATABASE_AUTH")
    )
    error_message = "On password authentication the migrate job must connect as masterly_admin, with no Entra administrator of its own."
  }

  assert {
    condition = (
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_SECRET_STORE"]) == "keyvault" &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_KEYVAULT_URL"]) == "https://kv-masterly-test.vault.azure.net/" &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "AZURE_CLIENT_ID"]) == "dddddddd-dddd-dddd-dddd-cccccccccccc"
    )
    error_message = "Even with password DB auth, the job must resolve runtime connection secrets through this vault using its own identity."
  }

  assert {
    condition = (
      toset(keys(azurerm_role_assignment.kv_byo_database_reader_migrate)) == var.migrate_byo_database_secret_names &&
      alltrue([for name, grant in azurerm_role_assignment.kv_byo_database_reader_migrate :
        grant.scope == "${azurerm_key_vault.this[0].id}/secrets/${name}" &&
        grant.role_definition_name == "Key Vault Secrets User" && grant.principal_id == module.migrate_identity[0].principal_id
      ])
    )
    error_message = "Runtime BYO-DB reads must cover exactly the named secrets, using the migrate principal and Secrets User at secret scope only."
  }

  # Without the pooler, the one URL; production carries the job's own vault secret.
  assert {
    condition = (
      sort(keys(local.migrate_env_secret_refs)) == tolist(["MASTERLY_DATABASE_URL"]) &&
      local.migrate_env_secret_refs["MASTERLY_DATABASE_URL"] == "migrate-database-url" &&
      tolist(local.migrate_secret_names) == tolist(["migrate-database-url"]) &&
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.secret_name if e.name == "MASTERLY_DATABASE_URL"]) == "migrate-database-url" &&
      sort(keys(local.migrate_vault_secret_refs)) == tolist(["migrate-database-url"]) &&
      length(local.migrate_value_secrets) == 0
    )
    error_message = "The migrate job must carry MASTERLY_DATABASE_URL from its own secret, and no direct URL without the pooler."
  }
}
