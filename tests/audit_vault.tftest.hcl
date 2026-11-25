# The audit vault (keyvault.tf, azurerm_key_vault.audit; ADR 0033 §10, ADR 0120 §6): a second
# vault holding the audit checkpoint key and head alone, its private endpoint and diagnostic
# setting, the two roles granted on it and to whom, MASTERLY_AUDIT_KEYVAULT_URL on ca-api and
# ca-workers alone, its outbound allowlist entry, the apps' ordering after its grants, and the
# audit_key_vault_uri output.
#
# Applies, in their own file, for the reason workers_identity.tftest.hcl gives: the grants' scopes
# are the vaults' ids, computed, so at plan they are unknown on Terraform 1.10. The two vaults get
# distinct ids here (the shared mock gives every vault the same one), and every identity a distinct
# principal, so a grant on the wrong vault or to the wrong identity fails.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  override_resource {
    target = azurerm_key_vault.this
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-a1b2c3"
      vault_uri = "https://kv-masterly-a1b2c3.vault.azure.net/"
    }
  }

  override_resource {
    target = azurerm_key_vault.audit
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kva-masterly-a1b2c3"
      vault_uri = "https://kva-masterly-a1b2c3.vault.azure.net/"
    }
  }

  # Each role the module defines gets an id of its own, so a grant names which one it is.
  override_resource {
    target = azurerm_role_definition.app_secrets
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000001"
    }
  }

  override_resource {
    target = azurerm_role_definition.signing_key_reader
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000002"
    }
  }

  override_resource {
    target = azurerm_role_definition.signing_keys
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000003"
    }
  }

  override_resource {
    target = azurerm_role_definition.audit_head_reader
    values = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/a99a5ec1-0000-4000-8000-000000000004"
    }
  }

  # The custom-domain run binds certificates; these ids are parsed by the provider
  # (custom_domain.tftest.hcl).
  override_resource {
    target = module.aca_env[0].azurerm_container_app_environment.this
    values = {
      id                            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      custom_domain_verification_id = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_resource {
    target = module.frontend.azurerm_container_app.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
    }
  }

  override_resource {
    target = azurerm_container_app_environment_certificate.frontend
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly/certificates/cert-masterly-frontend"
    }
  }

  override_resource {
    target = azurerm_container_app_custom_domain.frontend
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend/customDomainName/masterly.example.com"
    }
  }

  override_resource {
    target = azurerm_container_app.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"
    }
  }

  override_resource {
    target = azurerm_container_app_environment_certificate.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly/certificates/cert-masterly-edge"
    }
  }

  override_resource {
    target = azurerm_container_app_custom_domain.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge/customDomainName/api.masterly.example.com"
    }
  }
}
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "a1b2c3" }
  }
}
mock_provider "azapi" {}
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
}

# Distinct principals: apps aaaa, workers bbbb, frontend ffff, migrate dddd, edge 9999, the
# certificate identities cccc and 1212; the default deployer is the mock's eeee.
override_module {
  target  = module.apps_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
}

override_module {
  target  = module.workers_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
}

override_module {
  target  = module.frontend_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
}

override_module {
  target  = module.migrate_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
}

override_module {
  target  = module.edge_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
}

override_module {
  target  = module.frontend_certificate_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend-cert", principal_id = "cccccccc-cccc-cccc-cccc-cccccccccccc", client_id = "cccccccc-cccc-cccc-cccc-dddddddddddd", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend-cert" }
}

override_module {
  target  = module.edge_certificate_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge-cert", principal_id = "12121212-1212-1212-1212-121212121212", client_id = "12121212-1212-1212-1212-dddddddddddd", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge-cert" }
}

variables {
  location       = "swedencentral"
  org_id         = "org_test"
  install_id     = "test"
  api_image      = "masterly.azurecr.io/release/api:v0.138.0"
  frontend_image = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"

  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  mode                           = "production"
  identity_binding               = "oidc"
  oidc_tenant_id                 = "11111111-2222-3333-4444-555555555555"
  oidc_client_id                 = "bff-client-id"
  oidc_client_secret             = "test-only"
  oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
  license_token                  = "eyJ.fake.jwt"
  license_public_jwk             = jsonencode({ kty = "EC" })
  initial_owner_email            = "owner@example.com"
  enable_key_vault               = true
  enable_redis                   = true
  redis_offering                 = "cache"
  enable_workers                 = true
  enable_service_bus             = true
  servicebus_sku                 = "Standard"
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  ingress_allowed_cidrs          = ["203.0.113.7/32", "198.51.100.0/24"]
  migrations                     = "job"
}

# --- Production, ca-workers on its own identity --------------------------------------------------

run "audit_vault_production_with_workers_own_identity" {
  command = apply

  # The vault: RBAC, the main vault's retention, purge protection and closed network posture.
  assert {
    condition = (
      length(azurerm_key_vault.audit) == 1 &&
      azurerm_key_vault.audit[0].resource_group_name == azurerm_resource_group.data.name &&
      azurerm_key_vault.audit[0].rbac_authorization_enabled &&
      azurerm_key_vault.audit[0].soft_delete_retention_days == var.key_vault_soft_delete_retention_days &&
      azurerm_key_vault.audit[0].purge_protection_enabled &&
      azurerm_key_vault.audit[0].network_acls[0].default_action == "Deny" &&
      azurerm_key_vault.audit[0].public_network_access_enabled == azurerm_key_vault.this[0].public_network_access_enabled &&
      tolist(azurerm_key_vault.audit[0].network_acls[0].ip_rules) == tolist(azurerm_key_vault.this[0].network_acls[0].ip_rules) &&
      azurerm_key_vault.audit[0].name == "kva-masterly-a1b2c3" &&
      azurerm_key_vault.audit[0].name != azurerm_key_vault.this[0].name
    )
    error_message = "In production the audit vault must be RBAC, keep the main vault's soft-delete retention, arm purge protection, default-deny, and match the main vault's public access."
  }

  # Its private endpoint, in the main vault's privatelink zone, on the same subnet.
  assert {
    condition = (
      length(azurerm_private_endpoint.key_vault_audit) == 1 &&
      azurerm_private_endpoint.key_vault_audit[0].name == "pe-masterly-kv-audit" &&
      azurerm_private_endpoint.key_vault_audit[0].private_service_connection[0].private_connection_resource_id == azurerm_key_vault.audit[0].id &&
      tolist(azurerm_private_endpoint.key_vault_audit[0].private_service_connection[0].subresource_names) == tolist(["vault"]) &&
      azurerm_private_endpoint.key_vault_audit[0].subnet_id == azurerm_private_endpoint.key_vault[0].subnet_id &&
      tolist(azurerm_private_endpoint.key_vault_audit[0].private_dns_zone_group[0].private_dns_zone_ids) == tolist([azurerm_private_dns_zone.key_vault[0].id]) &&
      tolist(azurerm_private_endpoint.key_vault_audit[0].private_dns_zone_group[0].private_dns_zone_ids) == tolist(azurerm_private_endpoint.key_vault[0].private_dns_zone_group[0].private_dns_zone_ids) &&
      length(azurerm_private_dns_zone.key_vault) == 1
    )
    error_message = "In production the audit vault must have a private endpoint (subresource vault) on the private endpoints subnet, in the main vault's privatelink zone, and no second zone."
  }

  # Its audit log, wherever the main vault's is sent.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.key_vault) == 1 &&
      length(azurerm_monitor_diagnostic_setting.key_vault_audit) == 1 &&
      azurerm_monitor_diagnostic_setting.key_vault_audit[0].target_resource_id == azurerm_key_vault.audit[0].id &&
      azurerm_monitor_diagnostic_setting.key_vault_audit[0].log_analytics_workspace_id == azurerm_monitor_diagnostic_setting.key_vault[0].log_analytics_workspace_id &&
      [for l in azurerm_monitor_diagnostic_setting.key_vault_audit[0].enabled_log : l.category] == ["AuditEvent"] &&
      [for m in azurerm_monitor_diagnostic_setting.key_vault_audit[0].enabled_metric : m.category] == ["AllMetrics"]
    )
    error_message = "The audit vault must send AuditEvent and AllMetrics to the main vault's workspace wherever the main vault does."
  }

  # The core pool's identity is ca-workers' own: the signing keys role on the audit vault, and no
  # other role there.
  assert {
    condition = (
      local.workers_own_identity &&
      length(azurerm_role_assignment.audit_kv_signing_keys) == 0 &&
      length(azurerm_role_assignment.audit_kv_signing_keys_workers) == 1 &&
      azurerm_role_assignment.audit_kv_signing_keys_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      azurerm_role_assignment.audit_kv_signing_keys_workers[0].scope == azurerm_key_vault.audit[0].id &&
      [
        for ra in concat(
          azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader, azurerm_role_assignment.acr_pull_edge,
          azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_signing_keys_workers,
          azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
        ) : "${ra.role_definition_name}|${ra.role_definition_id}"
        if ra.principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" && (ra.scope == azurerm_key_vault.audit[0].id || startswith(ra.scope, "${azurerm_key_vault.audit[0].id}/"))
      ] == ["(assigned by id)|${azurerm_role_definition.signing_keys[0].role_definition_resource_id}"]
    )
    error_message = "With workers_own_identity, id-<prefix>-workers must hold the signing keys role on the audit vault, and no other role there; the apps identity must hold no signing keys grant on it."
  }

  # Threat, a compromised ca-api signs or overwrites the head: every grant ca-api's identity holds
  # on the audit vault, together, carries exactly keys/read and getSecret, each through a role the
  # module defines with no control-plane action.
  assert {
    condition = (
      toset([
        for ra in concat(
          azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader, azurerm_role_assignment.acr_pull_edge,
          azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_signing_keys_workers,
          azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
        ) : ra.role_definition_id
        if ra.principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" && (ra.scope == azurerm_key_vault.audit[0].id || startswith(ra.scope, "${azurerm_key_vault.audit[0].id}/"))
        ]) == toset([
        azurerm_role_definition.signing_key_reader[0].role_definition_resource_id,
        azurerm_role_definition.audit_head_reader[0].role_definition_resource_id,
      ]) &&
      toset(concat(
        tolist(azurerm_role_definition.signing_key_reader[0].permissions[0].data_actions),
        tolist(azurerm_role_definition.audit_head_reader[0].permissions[0].data_actions),
        )) == toset([
        "Microsoft.KeyVault/vaults/keys/read",
        "Microsoft.KeyVault/vaults/secrets/getSecret/action",
      ]) &&
      length(azurerm_role_definition.signing_key_reader[0].permissions[0].actions) == 0 &&
      length(azurerm_role_definition.audit_head_reader[0].permissions[0].actions) == 0 &&
      tolist(azurerm_role_definition.audit_head_reader[0].assignable_scopes) == tolist([azurerm_resource_group.data.id]) &&
      azurerm_role_definition.audit_head_reader[0].scope == azurerm_resource_group.data.id &&
      azurerm_role_definition.audit_head_reader[0].name == "Masterly audit head reader (masterly-a1b2c3)"
    )
    error_message = "With workers_own_identity, ca-api's grants on the audit vault must carry exactly keys/read and secrets/getSecret/action, through the signing key reader and audit head reader roles alone, assignable only in the data resource group."
  }

  # Threat, a broader role for ca-api: no app secrets, no signing keys, no built-in role (a role
  # assigned by name: Key Vault Secrets Officer, Crypto Officer, Administrator) on the audit vault.
  assert {
    condition = length([
      for ra in concat(
        azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader, azurerm_role_assignment.acr_pull_edge,
        azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_signing_keys_workers,
        azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
        values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
        azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
        values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
      ) : ra
      if ra.principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" && (ra.scope == azurerm_key_vault.audit[0].id || startswith(ra.scope, "${azurerm_key_vault.audit[0].id}/")) && (
        ra.role_definition_name != "(assigned by id)" ||
        contains([azurerm_role_definition.app_secrets[0].role_definition_resource_id, azurerm_role_definition.signing_keys[0].role_definition_resource_id], ra.role_definition_id)
      )
    ]) == 0
    error_message = "ca-api's identity must hold no Masterly app secrets, Masterly signing keys or built-in role on the audit vault where ca-workers has its own identity."
  }

  # Threat, the default deployer on the audit vault: Terraform writes nothing there, so the
  # identity running it holds Secrets Officer on the main vault and nothing on this one.
  assert {
    condition = (
      contains(keys(azurerm_role_assignment.kv_secrets_officer_deployer), "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee") &&
      alltrue([
        for ra in concat(
          azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader, azurerm_role_assignment.acr_pull_edge,
          azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_signing_keys_workers,
          azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
        ) : contains(["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"], ra.principal_id)
        if ra.scope == azurerm_key_vault.audit[0].id || startswith(ra.scope, "${azurerm_key_vault.audit[0].id}/")
      ])
    )
    error_message = "Only the apps and workers identities may hold a role on the audit vault; the default deployer must hold none there."
  }

  # The list above names every role assignment in the module, so a new one must be added to it.
  assert {
    condition     = length(regexall("resource \"azurerm_role_assignment\"", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) == 31
    error_message = "A role assignment was added or removed: name it in this file's lists."
  }

  # The upgrade adds only: the main vault's grants keep their scope, role and principal.
  assert {
    condition = (
      azurerm_role_assignment.kv_app_secrets[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_app_secrets[0].role_definition_id == azurerm_role_definition.app_secrets[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_signing_key_reader[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_signing_key_reader[0].role_definition_id == azurerm_role_definition.signing_key_reader[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_signing_key_reader[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.kv_app_secrets_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_signing_keys_workers[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_signing_keys_workers[0].role_definition_id == azurerm_role_definition.signing_keys[0].role_definition_resource_id &&
      azurerm_role_assignment.kv_signing_keys_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "The main vault's grants must keep their scope, role and principal beside the audit vault's."
  }

  # MASTERLY_AUDIT_KEYVAULT_URL on ca-api and ca-workers, never on ca-frontend or caj-migrate.
  assert {
    condition = (
      local.api_env["MASTERLY_AUDIT_KEYVAULT_URL"] == azurerm_key_vault.audit[0].vault_uri &&
      local.workers_env["MASTERLY_AUDIT_KEYVAULT_URL"] == azurerm_key_vault.audit[0].vault_uri &&
      local.api_env["MASTERLY_KEYVAULT_URL"] == azurerm_key_vault.this[0].vault_uri &&
      contains(module.api.env_names, "MASTERLY_AUDIT_KEYVAULT_URL") &&
      contains(module.workers[0].env_names, "MASTERLY_AUDIT_KEYVAULT_URL") &&
      !contains(module.frontend.env_names, "MASTERLY_AUDIT_KEYVAULT_URL") &&
      !contains(keys(local.frontend_env), "MASTERLY_AUDIT_KEYVAULT_URL") &&
      !contains(keys(local.migrate_env), "MASTERLY_AUDIT_KEYVAULT_URL") &&
      length(azurerm_container_app_job.migrate) == 1 &&
      !contains([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.name], "MASTERLY_AUDIT_KEYVAULT_URL")
    )
    error_message = "MASTERLY_AUDIT_KEYVAULT_URL must be the audit vault's URI on ca-api and ca-workers, and absent from ca-frontend and caj-migrate."
  }

  # In production the vault is reached over its private endpoint: no allowlist entry, and the front
  # subnet's NSG exception still names the main vault's endpoint alone.
  assert {
    condition = (
      alltrue([for w, m in local.outbound_workload_entries : !contains(keys(m), "audit-key-vault")]) &&
      length(regexall("(?s)name\\s*=\\s*\"allow-key-vault-from-front-subnet\".*?destination_address_prefix\\s*=\\s*\"\\$\\{azurerm_private_endpoint\\.key_vault\\[0\\]\\.private_service_connection\\[0\\]\\.private_ip_address\\}/32\"", file("${path.module}/network.tf"))) == 1 &&
      !strcontains(file("${path.module}/network.tf"), "azurerm_private_endpoint.key_vault_audit")
    )
    error_message = "In production no workload may list the audit vault, and the front subnet's NSG rule must target the main vault's private endpoint alone."
  }

  # ca-api and ca-workers are updated only after their grants on the audit vault exist. The lists
  # are read from the source, with comments stripped.
  assert {
    condition = (
      alltrue([
        for a in ["azurerm_role_assignment.audit_kv_signing_key_reader", "azurerm_role_assignment.audit_kv_head_reader", "azurerm_role_assignment.audit_kv_signing_keys", "azurerm_private_endpoint.key_vault_audit"] :
        strcontains(replace(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)\\nmodule \"api\" \\{.*?\\n\\}\\n", file("${path.module}/main.tf")))[0], "/#[^\\n]*/", ""), "${a},")
      ]) &&
      alltrue([
        for a in ["azurerm_role_assignment.audit_kv_signing_keys", "azurerm_role_assignment.audit_kv_signing_keys_workers", "azurerm_private_endpoint.key_vault_audit"] :
        strcontains(replace(regex("(?s)depends_on = \\[([^\\]]*)\\]", regex("(?s)\\nmodule \"workers\" \\{.*?\\n\\}\\n", file("${path.module}/workers.tf")))[0], "/#[^\\n]*/", ""), "${a},")
      ])
    )
    error_message = "module.api must depend on its audit vault grants, and module.workers on both possible core pool grants on the audit vault, and both on its private endpoint."
  }

  assert {
    condition     = output.audit_key_vault_uri == azurerm_key_vault.audit[0].vault_uri && output.audit_key_vault_uri != output.key_vault_uri
    error_message = "audit_key_vault_uri must be the audit vault's URI, not the main vault's."
  }
}

# --- The residual: ca-workers on the apps identity -----------------------------------------------

# migrations = "start" with database_auth = "entra" on the starter server: ca-workers runs as the
# apps identity, so that identity, ca-api's, holds the signing keys role on the audit vault. The
# README names this shape.
run "audit_vault_shared_identity_gives_ca_api_the_five_actions" {
  command = apply

  expect_failures = [check.production_migrations_at_start]

  variables {
    migrations    = "start"
    database_auth = "entra"
  }

  assert {
    condition = (
      !local.workers_own_identity &&
      length(azurerm_role_assignment.audit_kv_signing_keys_workers) == 0 &&
      length(azurerm_role_assignment.audit_kv_signing_keys) == 1 &&
      azurerm_role_assignment.audit_kv_signing_keys[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      azurerm_role_assignment.audit_kv_signing_keys[0].scope == azurerm_key_vault.audit[0].id &&
      azurerm_role_assignment.audit_kv_signing_keys[0].role_definition_id == azurerm_role_definition.signing_keys[0].role_definition_resource_id
    )
    error_message = "With ca-workers on the apps identity, the signing keys role on the audit vault must go to the apps identity."
  }

  # Its roles there, and no one else's.
  assert {
    condition = (
      toset([
        for ra in concat(
          azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
        ) : "${ra.principal_id}|${ra.role_definition_id}"
        ]) == toset([
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_role_definition.signing_key_reader[0].role_definition_resource_id}",
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_role_definition.audit_head_reader[0].role_definition_resource_id}",
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|${azurerm_role_definition.signing_keys[0].role_definition_resource_id}",
      ]) &&
      length(module.workers_identity) == 0
    )
    error_message = "With ca-workers on the apps identity, the apps identity alone must hold the audit vault's roles: signing key reader, audit head reader and signing keys."
  }

  # The main vault's grants in this shape are as before.
  assert {
    condition = (
      length(azurerm_role_assignment.kv_signing_keys) == 1 &&
      azurerm_role_assignment.kv_signing_keys[0].scope == azurerm_key_vault.this[0].id &&
      azurerm_role_assignment.kv_signing_keys[0].principal_id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    error_message = "The main vault's signing keys grant to the apps identity must be unchanged."
  }
}

# --- Threat: no other principal ------------------------------------------------------------------

# Every other identity the module creates, and every principal an input names, present at once:
# ca-edge, both certificate identities, the migrate job, named secret operators and readers. None
# of them holds a role on the audit vault.
run "audit_vault_no_other_principal" {
  command = apply

  variables {
    # Derived from frontend_custom_domain's hostname.
    oidc_redirect_uri = null
    edge              = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
    key_vault_secret_operator_object_ids = ["e1e1e1e1-e1e1-e1e1-e1e1-e1e1e1e1e1e1"]
    key_vault_secret_reader_object_ids   = ["abababab-abab-abab-abab-abababababab"]
  }

  # The inputs took effect: each of those principals holds a grant somewhere.
  assert {
    condition = (
      length(azurerm_role_assignment.edge_certificate_reader) == 1 &&
      length(azurerm_role_assignment.frontend_certificate_reader) == 1 &&
      length(azurerm_role_assignment.acr_pull_edge) == 1 &&
      length(azurerm_role_assignment.kv_secrets_user_migrate) > 0 &&
      length(azurerm_role_assignment.kv_secrets_user_frontend) > 0 &&
      keys(azurerm_role_assignment.kv_secrets_officer_deployer) == ["e1e1e1e1-e1e1-e1e1-e1e1-e1e1e1e1e1e1"] &&
      keys(azurerm_role_assignment.kv_secrets_reader) == ["abababab-abab-abab-abab-abababababab"]
    )
    error_message = "The edge, certificate, migrate, frontend, operator and reader principals must each hold a grant elsewhere, or this run proves nothing."
  }

  assert {
    condition = length([
      for ra in concat(
        azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader, azurerm_role_assignment.acr_pull_edge,
        azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_app_secrets_workers, azurerm_role_assignment.kv_signing_keys_workers,
        azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
        values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
        azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
        values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers, azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
      ) : ra
      if(ra.scope == azurerm_key_vault.audit[0].id || startswith(ra.scope, "${azurerm_key_vault.audit[0].id}/")) && contains([
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "dddddddd-dddd-dddd-dddd-dddddddddddd",
        "99999999-9999-9999-9999-999999999999",
        "cccccccc-cccc-cccc-cccc-cccccccccccc",
        "12121212-1212-1212-1212-121212121212",
        "e1e1e1e1-e1e1-e1e1-e1e1-e1e1e1e1e1e1",
        "abababab-abab-abab-abab-abababababab",
        "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
      ], ra.principal_id)
    ]) == 0
    error_message = "No frontend, migrate, edge or certificate identity, secret operator or reader, or the default deployer may hold a role on the audit vault."
  }

  # And the only principals there are the apps and workers identities, four grants at most.
  assert {
    condition = toset([
      for ra in concat(
        azurerm_role_assignment.audit_kv_signing_key_reader, azurerm_role_assignment.audit_kv_head_reader, azurerm_role_assignment.audit_kv_signing_keys, azurerm_role_assignment.audit_kv_signing_keys_workers,
      ) : ra.principal_id
    ]) == toset(["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"])
    error_message = "The audit vault's grants must name the apps and workers identities alone."
  }
}

# --- The DNS zone, injected ----------------------------------------------------------------------

run "audit_vault_private_endpoint_uses_the_injected_zone" {
  command = apply

  variables {
    key_vault_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.key_vault) == 0 &&
      length(azurerm_private_endpoint.key_vault_audit) == 1 &&
      tolist(azurerm_private_endpoint.key_vault_audit[0].private_dns_zone_group[0].private_dns_zone_ids) == tolist([var.key_vault_private_dns_zone_id])
    )
    error_message = "With key_vault_private_dns_zone_id set, the audit vault's private endpoint must use that zone, and the module must create no Key Vault zone."
  }
}

# --- The name, with the longest prefix -----------------------------------------------------------

run "audit_vault_name_fits_with_a_long_prefix" {
  command = apply

  variables {
    name_prefix = "masterlyprodsweden123"
  }

  assert {
    condition = (
      azurerm_key_vault.audit[0].name == "kva-masterlyprods-a1b2c3" &&
      length(azurerm_key_vault.audit[0].name) <= 24 &&
      length(azurerm_key_vault.this[0].name) <= 24 &&
      azurerm_key_vault.audit[0].name != azurerm_key_vault.this[0].name &&
      endswith(azurerm_key_vault.audit[0].name, "-${random_string.install.result}")
    )
    error_message = "With a 21-character name_prefix the audit vault's name must be at most 24 characters, carry the install suffix and differ from the main vault's."
  }

  assert {
    condition     = azurerm_role_definition.audit_head_reader[0].name == "Masterly audit head reader (masterlyprodsweden123-a1b2c3)"
    error_message = "The audit head reader role's name must carry the prefix and the install suffix."
  }
}

# --- Demo: public, with an allowlist entry for ca-api and ca-workers ----------------------------

run "audit_vault_demo_is_public_and_allowlisted_for_api_and_workers" {
  command = apply

  # Demo takes no migrate job; caj-migrate's allowlist entries are still derived.
  variables {
    mode       = "demo"
    migrations = "start"
  }

  assert {
    condition = (
      length(azurerm_key_vault.audit) == 1 &&
      azurerm_key_vault.audit[0].public_network_access_enabled &&
      azurerm_key_vault.audit[0].public_network_access_enabled == azurerm_key_vault.this[0].public_network_access_enabled &&
      azurerm_key_vault.audit[0].network_acls[0].default_action == "Allow" &&
      !azurerm_key_vault.audit[0].purge_protection_enabled &&
      azurerm_key_vault.audit[0].soft_delete_retention_days == var.key_vault_soft_delete_retention_days &&
      length(azurerm_private_endpoint.key_vault_audit) == 0 &&
      length(azurerm_monitor_diagnostic_setting.key_vault_audit) == length(azurerm_monitor_diagnostic_setting.key_vault)
    )
    error_message = "In demo the audit vault must be public like the main vault, with no purge protection and no private endpoint, and a diagnostic setting wherever the main vault has one."
  }

  assert {
    condition = (
      local.outbound_workload_entries["ca-api"]["audit-key-vault"].destination == "kva-masterly-a1b2c3.vault.azure.net" &&
      local.outbound_workload_entries["ca-api"]["audit-key-vault"].protocol == "TCP" &&
      local.outbound_workload_entries["ca-api"]["audit-key-vault"].ports == ["443"] &&
      local.outbound_workload_entries["ca-workers"]["audit-key-vault"].destination == "kva-masterly-a1b2c3.vault.azure.net" &&
      local.outbound_workload_entries["ca-workers"]["audit-key-vault"].ports == ["443"] &&
      !contains(keys(local.outbound_workload_entries["ca-frontend"]), "audit-key-vault") &&
      !contains(keys(local.outbound_workload_entries["caj-migrate"]), "audit-key-vault") &&
      contains(keys(local.outbound_workload_entries["ca-frontend"]), "key-vault") &&
      contains(keys(local.outbound_workload_entries["caj-migrate"]), "key-vault")
    )
    error_message = "In demo ca-api and ca-workers must list the audit vault's FQDN on TCP 443, and ca-frontend and caj-migrate must not."
  }

  # ca-workers still runs as its own identity here (password auth in demo), and holds the grant.
  assert {
    condition = (
      local.workers_own_identity &&
      azurerm_role_assignment.audit_kv_signing_keys_workers[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      length(azurerm_role_assignment.audit_kv_signing_keys) == 0 &&
      local.workers_env["MASTERLY_AUDIT_KEYVAULT_URL"] == "https://kva-masterly-a1b2c3.vault.azure.net/"
    )
    error_message = "In demo with ca-workers on its own identity, the signing keys grant on the audit vault must be its, and its env must carry the audit vault's URI."
  }
}

# --- The vault off -------------------------------------------------------------------------------

run "audit_vault_off_plans_nothing" {
  command = plan

  variables {
    mode             = "demo"
    migrations       = "start"
    enable_key_vault = false
  }

  assert {
    condition = (
      length(azurerm_key_vault.audit) == 0 &&
      length(azurerm_private_endpoint.key_vault_audit) == 0 &&
      length(azurerm_monitor_diagnostic_setting.key_vault_audit) == 0 &&
      length(azurerm_role_definition.audit_head_reader) == 0 &&
      length(azurerm_role_assignment.audit_kv_signing_key_reader) + length(azurerm_role_assignment.audit_kv_head_reader) + length(azurerm_role_assignment.audit_kv_signing_keys) + length(azurerm_role_assignment.audit_kv_signing_keys_workers) == 0 &&
      output.audit_key_vault_uri == null &&
      !contains(keys(local.api_env), "MASTERLY_AUDIT_KEYVAULT_URL") &&
      alltrue([for w, m in local.outbound_workload_entries : !contains(keys(m), "audit-key-vault")])
    )
    error_message = "With enable_key_vault off the module must plan no audit vault, endpoint, diagnostic setting, role or grant, set no MASTERLY_AUDIT_KEYVAULT_URL, and output null."
  }
}
