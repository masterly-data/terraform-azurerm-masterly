# ca-frontend on the customer's hostname with a Key Vault certificate (custom-domain.tf,
# frontend_custom_domain): the certificate identity, its one grant, the certificate reference, the
# binding and the two outputs. The same for ca-edge (edge_custom_domain), in the last runs.
#
# Applies, in their own file, for the reason workers_identity.tftest.hcl gives: the identity's ids,
# the certificate's id and the apps' ids are computed, so at plan they are unknown on Terraform
# 1.10. Every identity is overridden with a distinct principal, so a grant to the wrong one fails.
# The guards and the derived redirect are plan runs in frontend_custom_domain.tftest.hcl, and
# edge_custom_domain's guards in edge_custom_domain.tftest.hcl.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

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

  # ca-edge's, distinct from the frontend's, so a binding on the wrong app or certificate fails.
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

variables {
  location       = "swedencentral"
  org_id         = "org_test"
  install_id     = "test"
  api_image      = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"

  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  mode                           = "production"
  identity_binding               = "oidc"
  oidc_tenant_id                 = "11111111-2222-3333-4444-555555555555"
  oidc_client_id                 = "bff-client-id"
  oidc_client_secret             = "test-only"
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
}

# Unset: no certificate identity, nothing on the environment, no grant, no certificate, no
# binding; frontend_url is the Container Apps FQDN and the verification id is still exported.
run "custom_domain_unset_keeps_the_frontend_fqdn" {
  command = apply

  variables {
    oidc_redirect_uri = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  assert {
    condition = (
      length(module.frontend_certificate_identity) == 0 &&
      length(module.aca_env[0].identity_ids) == 0 &&
      length(azurerm_role_assignment.frontend_certificate_reader) == 0 &&
      length(azurerm_container_app_environment_certificate.frontend) == 0 &&
      length(azurerm_container_app_custom_domain.frontend) == 0
    )
    error_message = "With frontend_custom_domain unset the module must create no certificate identity, no environment identity, no grant, no certificate and no binding."
  }

  assert {
    condition     = local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == var.oidc_redirect_uri
    error_message = "With frontend_custom_domain unset, ca-frontend's MASTERLY_OIDC_REDIRECT_URI must be oidc_redirect_uri."
  }

  assert {
    condition     = module.frontend.fqdn != null && output.frontend_url == "https://${module.frontend.fqdn}"
    error_message = "With frontend_custom_domain unset, frontend_url must be https://<frontend fqdn>."
  }

  assert {
    condition     = nonsensitive(output.custom_domain_verification_id) == "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    error_message = "custom_domain_verification_id must be the environment's custom-domain verification id."
  }
}

# Set, on a public environment.
run "custom_domain_binds_the_hostname_on_a_public_environment" {
  command = apply

  variables {
    aca_internal_load_balancer = false
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  # Every other identity keeps the mock's shared principal (tests/mocks/migrate), so only the
  # certificate identity holds this one.
  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.frontend_certificate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend-cert", principal_id = "cccccccc-cccc-cccc-cccc-cccccccccccc", client_id = "cccccccc-cccc-cccc-cccc-dddddddddddd", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend-cert" }
  }

  # The binding: exactly the hostname, by SNI, with the Key Vault certificate, on ca-frontend.
  assert {
    condition = (
      length(azurerm_container_app_custom_domain.frontend) == 1 &&
      azurerm_container_app_custom_domain.frontend[0].name == "masterly.example.com" &&
      azurerm_container_app_custom_domain.frontend[0].certificate_binding_type == "SniEnabled" &&
      azurerm_container_app_custom_domain.frontend[0].container_app_id == module.frontend.id &&
      endswith(module.frontend.id, "/containerApps/ca-frontend") &&
      azurerm_container_app_custom_domain.frontend[0].container_app_environment_certificate_id == azurerm_container_app_environment_certificate.frontend[0].id
    )
    error_message = "ca-frontend must carry one custom-domain binding for exactly frontend_custom_domain.hostname, of SNI type, bound to the Key Vault certificate."
  }

  # Threat: the private key passes through Terraform. The certificate is a versionless reference,
  # read through the certificate identity, with no blob and no password; and the input has no
  # field that could carry either.
  assert {
    condition = (
      length(azurerm_container_app_environment_certificate.frontend) == 1 &&
      azurerm_container_app_environment_certificate.frontend[0].container_app_environment_id == module.aca_env[0].id &&
      length(azurerm_container_app_environment_certificate.frontend[0].certificate_key_vault) == 1 &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_key_vault[0].key_vault_secret_id == "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com" &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_key_vault[0].identity == module.frontend_certificate_identity[0].id &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_blob_base64 == null &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_password == null &&
      sort(keys(var.frontend_custom_domain)) == tolist(["certificate_key_vault_secret_id", "hostname", "key_vault_id"])
    )
    error_message = "The environment certificate must reference the versionless Key Vault secret id through the certificate identity, and set no certificate blob or password."
  }

  # Threat: the certificate identity can read anything else. It is attached to the environment
  # and to no app, and its one grant is Key Vault Secrets User on the certificate's secret.
  assert {
    condition = (
      tolist(module.aca_env[0].identity_ids) == tolist([module.frontend_certificate_identity[0].id]) &&
      !contains(module.frontend.user_assigned_identity_ids, module.frontend_certificate_identity[0].id) &&
      !contains(module.api.user_assigned_identity_ids, module.frontend_certificate_identity[0].id) &&
      !contains(module.workers[0].user_assigned_identity_ids, module.frontend_certificate_identity[0].id) &&
      !contains(module.frontend.secret_ref_identity_ids, module.frontend_certificate_identity[0].id) &&
      module.frontend_certificate_identity[0].id != module.frontend_identity.id
    )
    error_message = "The certificate identity must be attached to the Container App environment and to no Container App, and must not be the frontend's identity."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.frontend_certificate_reader) == 1 &&
      azurerm_role_assignment.frontend_certificate_reader[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.frontend_certificate_reader[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs/secrets/masterly-example-com" &&
      azurerm_role_assignment.frontend_certificate_reader[0].principal_id == "cccccccc-cccc-cccc-cccc-cccccccccccc" &&
      length([
        for ra in concat(
          azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers, azurerm_role_assignment.acr_pull_edge,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_signing_keys_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
          azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        ) : ra if ra.principal_id == "cccccccc-cccc-cccc-cccc-cccccccccccc"
      ]) == 1
    )
    error_message = "The certificate identity must hold exactly one role assignment: Key Vault Secrets User on the certificate's secret in frontend_custom_domain.key_vault_id."
  }

  # Threat: the custom hostname opens a wider door. The allowlist and HTTPS-only are unchanged.
  assert {
    condition = (
      tolist(module.frontend.ingress_allowed_ip_ranges) == tolist(["203.0.113.7/32", "198.51.100.0/24"]) &&
      tolist(module.frontend.ingress_allowed_ip_ranges) == tolist(var.ingress_allowed_cidrs) &&
      module.frontend.ingress_allow_insecure == false
    )
    error_message = "With frontend_custom_domain set, ca-frontend's IP security restrictions must still equal ingress_allowed_cidrs and its ingress must still refuse plain HTTP."
  }

  assert {
    condition = (
      local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == "https://masterly.example.com/api/auth/callback" &&
      output.frontend_url == "https://masterly.example.com" &&
      nonsensitive(output.custom_domain_verification_id) == "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    )
    error_message = "With frontend_custom_domain set, the redirect must be https://<hostname>/api/auth/callback, frontend_url https://<hostname>, and custom_domain_verification_id the environment's verification id."
  }
}

# Set, behind the customer's Application Gateway on an internal environment: the same binding.
run "custom_domain_binds_the_hostname_on_an_internal_environment" {
  command = apply

  variables {
    aca_internal_load_balancer = true
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.frontend_certificate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend-cert", principal_id = "cccccccc-cccc-cccc-cccc-cccccccccccc", client_id = "cccccccc-cccc-cccc-cccc-dddddddddddd", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend-cert" }
  }

  assert {
    condition = (
      module.aca_env[0].internal_load_balancer_enabled == true &&
      length(azurerm_container_app_custom_domain.frontend) == 1 &&
      azurerm_container_app_custom_domain.frontend[0].name == "masterly.example.com" &&
      azurerm_container_app_custom_domain.frontend[0].certificate_binding_type == "SniEnabled" &&
      azurerm_container_app_custom_domain.frontend[0].container_app_id == module.frontend.id &&
      azurerm_container_app_custom_domain.frontend[0].container_app_environment_certificate_id == azurerm_container_app_environment_certificate.frontend[0].id &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_key_vault[0].identity == module.frontend_certificate_identity[0].id &&
      tolist(module.aca_env[0].identity_ids) == tolist([module.frontend_certificate_identity[0].id])
    )
    error_message = "On an internal environment ca-frontend must carry the same binding: exactly the hostname, SNI, bound to the Key Vault certificate the environment reads as the certificate identity."
  }

  assert {
    condition = (
      tolist(module.frontend.ingress_allowed_ip_ranges) == tolist(var.ingress_allowed_cidrs) &&
      module.frontend.ingress_allow_insecure == false
    )
    error_message = "On an internal environment ca-frontend's IP security restrictions must still equal ingress_allowed_cidrs and its ingress must still refuse plain HTTP."
  }

  assert {
    condition = (
      local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == "https://masterly.example.com/api/auth/callback" &&
      output.frontend_url == "https://masterly.example.com" &&
      nonsensitive(output.custom_domain_verification_id) == "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    )
    error_message = "On an internal environment the redirect, frontend_url and custom_domain_verification_id must follow the hostname as on a public one."
  }
}

# --- edge_custom_domain ----------------------------------------------------------------------
# ca-edge on a mirror on the install's registry, so its identity holds the one role it may, AcrPull,
# and the runs show it holds no other.

# Unset with edge on: nothing of the edge's custom domain, and edge_url is the Container Apps FQDN.
run "edge_custom_domain_unset_keeps_the_edge_fqdn" {
  command = apply

  variables {
    oidc_redirect_uri = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
    edge              = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
  }

  assert {
    condition = (
      length(azurerm_container_app.edge) == 1 &&
      length(module.edge_certificate_identity) == 0 &&
      length(module.aca_env[0].identity_ids) == 0 &&
      length(azurerm_role_assignment.edge_certificate_reader) == 0 &&
      length(azurerm_container_app_environment_certificate.edge) == 0 &&
      length(azurerm_container_app_custom_domain.edge) == 0
    )
    error_message = "With edge set and edge_custom_domain unset the module must create no edge certificate identity, no environment identity, no grant, no certificate and no binding."
  }

  assert {
    condition     = azurerm_container_app.edge[0].ingress[0].fqdn != null && output.edge_url == "https://${azurerm_container_app.edge[0].ingress[0].fqdn}"
    error_message = "With edge_custom_domain unset, edge_url must be https://<ca-edge fqdn>."
  }
}

# Set: the hostname on ca-edge, read through a certificate identity of its own.
run "edge_custom_domain_binds_the_hostname_on_ca_edge" {
  command = apply

  variables {
    oidc_redirect_uri = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
    edge              = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  override_module {
    target  = module.frontend_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
  }

  override_module {
    target  = module.edge_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
  }

  # Not eeee…: that is the deploying principal's object id in tests/mocks/migrate.
  override_module {
    target  = module.edge_certificate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge-cert", principal_id = "12121212-1212-1212-1212-121212121212", client_id = "12121212-1212-1212-1212-dddddddddddd", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge-cert" }
  }

  # The binding: exactly the hostname, by SNI, with the Key Vault certificate, on ca-edge.
  assert {
    condition = (
      length(azurerm_container_app_custom_domain.edge) == 1 &&
      azurerm_container_app_custom_domain.edge[0].name == "api.masterly.example.com" &&
      azurerm_container_app_custom_domain.edge[0].certificate_binding_type == "SniEnabled" &&
      azurerm_container_app_custom_domain.edge[0].container_app_id == azurerm_container_app.edge[0].id &&
      endswith(azurerm_container_app.edge[0].id, "/containerApps/ca-edge") &&
      azurerm_container_app_custom_domain.edge[0].container_app_environment_certificate_id == azurerm_container_app_environment_certificate.edge[0].id &&
      length(azurerm_container_app_custom_domain.frontend) == 0
    )
    error_message = "ca-edge must carry one custom-domain binding for exactly edge_custom_domain.hostname, of SNI type, bound to the edge's Key Vault certificate."
  }

  # Threat: the private key passes through Terraform. A versionless reference, read through the
  # edge certificate identity, with no blob and no password.
  assert {
    condition = (
      length(azurerm_container_app_environment_certificate.edge) == 1 &&
      azurerm_container_app_environment_certificate.edge[0].container_app_environment_id == module.aca_env[0].id &&
      length(azurerm_container_app_environment_certificate.edge[0].certificate_key_vault) == 1 &&
      azurerm_container_app_environment_certificate.edge[0].certificate_key_vault[0].key_vault_secret_id == "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com" &&
      azurerm_container_app_environment_certificate.edge[0].certificate_key_vault[0].identity == module.edge_certificate_identity[0].id &&
      azurerm_container_app_environment_certificate.edge[0].certificate_blob_base64 == null &&
      azurerm_container_app_environment_certificate.edge[0].certificate_password == null &&
      sort(keys(var.edge_custom_domain)) == tolist(["certificate_key_vault_secret_id", "hostname", "key_vault_id"])
    )
    error_message = "The edge environment certificate must reference the versionless Key Vault secret id through the edge certificate identity, and set no certificate blob or password."
  }

  # Threat: ca-edge reads the private key. The certificate identity is on the environment alone,
  # never on ca-edge, and is not the edge's own identity.
  assert {
    condition = (
      tolist(module.aca_env[0].identity_ids) == tolist([module.edge_certificate_identity[0].id]) &&
      tolist(azurerm_container_app.edge[0].identity[0].identity_ids) == tolist([module.edge_identity[0].id]) &&
      !contains(azurerm_container_app.edge[0].identity[0].identity_ids, module.edge_certificate_identity[0].id) &&
      !contains(module.frontend.user_assigned_identity_ids, module.edge_certificate_identity[0].id) &&
      !contains(module.api.user_assigned_identity_ids, module.edge_certificate_identity[0].id) &&
      !contains(module.workers[0].user_assigned_identity_ids, module.edge_certificate_identity[0].id) &&
      module.edge_certificate_identity[0].id != module.edge_identity[0].id
    )
    error_message = "The edge certificate identity must be attached to the Container App environment and to no Container App (ca-edge included), and must not be ca-edge's own identity."
  }

  # Threat: a grant to the wrong principal, or wider than the one secret.
  assert {
    condition = (
      length(azurerm_role_assignment.edge_certificate_reader) == 1 &&
      azurerm_role_assignment.edge_certificate_reader[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.edge_certificate_reader[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs/secrets/api-masterly-example-com" &&
      azurerm_role_assignment.edge_certificate_reader[0].principal_id == module.edge_certificate_identity[0].principal_id &&
      azurerm_role_assignment.edge_certificate_reader[0].principal_id == "12121212-1212-1212-1212-121212121212" &&
      azurerm_role_assignment.edge_certificate_reader[0].principal_id != module.edge_identity[0].principal_id
    )
    error_message = "edge_certificate_reader must grant Key Vault Secrets User on <key_vault_id>/secrets/<certificate name> to the edge certificate identity, never to ca-edge's own identity."
  }

  # The certificate identity holds that one grant, and ca-edge's identity still holds AcrPull and
  # nothing else.
  assert {
    condition = (
      length([
        for ra in concat(
          azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader,
          azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers, azurerm_role_assignment.acr_pull_edge,
          azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
          azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_signing_keys_workers,
          azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
          values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
          values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
          azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
          azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
          azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
        ) : ra if ra.principal_id == "12121212-1212-1212-1212-121212121212"
      ]) == 1
    )
    error_message = "The edge certificate identity must hold exactly one role assignment, Key Vault Secrets User on its certificate's secret."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.acr_pull_edge) == 1 &&
      azurerm_role_assignment.acr_pull_edge[0].role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull_edge[0].principal_id == module.edge_identity[0].principal_id
    )
    error_message = "With its image on the install's registry, ca-edge's own identity must hold AcrPull there."
  }

  assert {
    condition = length([
      for ra in concat(
        azurerm_role_assignment.frontend_certificate_reader, azurerm_role_assignment.edge_certificate_reader,
        azurerm_role_assignment.acr_pull, azurerm_role_assignment.acr_pull_frontend, azurerm_role_assignment.acr_pull_migrate, azurerm_role_assignment.acr_pull_workers, azurerm_role_assignment.acr_pull_edge,
        azurerm_role_assignment.kv_app_secrets, azurerm_role_assignment.kv_app_secrets_workers,
        azurerm_role_assignment.kv_signing_key_reader, azurerm_role_assignment.kv_signing_keys, azurerm_role_assignment.kv_signing_keys_workers,
        azurerm_role_assignment.kv_secrets_user_migrate_api_role_password, azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
        values(azurerm_role_assignment.kv_secrets_officer_deployer), values(azurerm_role_assignment.kv_secrets_user_frontend), values(azurerm_role_assignment.kv_secrets_user_migrate),
        values(azurerm_role_assignment.kv_byo_database_reader_migrate), values(azurerm_role_assignment.kv_secrets_reader),
        azurerm_role_assignment.sb_sender, azurerm_role_assignment.sb_receiver, azurerm_role_assignment.sb_sender_workers, azurerm_role_assignment.sb_receiver_workers,
        azurerm_role_assignment.sb_scaler, azurerm_role_assignment.sb_scaler_workers,
        azurerm_role_assignment.acs_email_sender, azurerm_role_assignment.acs_email_sender_workers,
      ) : ra if ra.principal_id == "99999999-9999-9999-9999-999999999999"
    ]) == 1
    error_message = "ca-edge's own identity must hold no role but its AcrPull: no grant on the certificate, the vault or any data plane."
  }

  # Threat: the hostname opens a wider door on ca-edge. Its allowlist and HTTPS-only are unchanged.
  assert {
    condition = (
      tolist([for r in azurerm_container_app.edge[0].ingress[0].ip_security_restriction : r.ip_address_range]) == tolist(var.ingress_allowed_cidrs) &&
      azurerm_container_app.edge[0].ingress[0].allow_insecure_connections == false &&
      azurerm_container_app.edge[0].ingress[0].external_enabled == true
    )
    error_message = "With edge_custom_domain set, ca-edge's IP security restrictions must still equal ingress_allowed_cidrs and its ingress must still refuse plain HTTP."
  }

  assert {
    condition = (
      output.edge_url == "https://api.masterly.example.com" &&
      nonsensitive(output.custom_domain_verification_id) == "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    )
    error_message = "With edge_custom_domain set, edge_url must be https://<edge hostname>, and custom_domain_verification_id the environment's verification id."
  }
}

# Both: each hostname on its own app, with its own certificate and its own certificate identity,
# and both identities on the environment.
run "edge_and_frontend_custom_domains_bind_both" {
  command = apply

  variables {
    edge = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
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

  assert {
    condition = (
      tolist(module.aca_env[0].identity_ids) == tolist([module.frontend_certificate_identity[0].id, module.edge_certificate_identity[0].id]) &&
      tolist(azurerm_container_app.edge[0].identity[0].identity_ids) == tolist([module.edge_identity[0].id])
    )
    error_message = "With both custom domains set, the environment must carry both certificate identities, and ca-edge its own identity alone."
  }

  assert {
    condition = (
      azurerm_container_app_custom_domain.frontend[0].name == "masterly.example.com" &&
      azurerm_container_app_custom_domain.frontend[0].container_app_id == module.frontend.id &&
      azurerm_container_app_custom_domain.frontend[0].container_app_environment_certificate_id == azurerm_container_app_environment_certificate.frontend[0].id &&
      azurerm_container_app_environment_certificate.frontend[0].certificate_key_vault[0].identity == module.frontend_certificate_identity[0].id &&
      azurerm_container_app_custom_domain.edge[0].name == "api.masterly.example.com" &&
      azurerm_container_app_custom_domain.edge[0].container_app_id == azurerm_container_app.edge[0].id &&
      azurerm_container_app_custom_domain.edge[0].container_app_environment_certificate_id == azurerm_container_app_environment_certificate.edge[0].id &&
      azurerm_container_app_environment_certificate.edge[0].certificate_key_vault[0].identity == module.edge_certificate_identity[0].id &&
      azurerm_container_app.edge[0].id != module.frontend.id &&
      azurerm_container_app_environment_certificate.edge[0].id != azurerm_container_app_environment_certificate.frontend[0].id
    )
    error_message = "Each hostname must bind to its own app (ca-frontend, ca-edge) with its own certificate, read through its own certificate identity."
  }

  assert {
    condition = (
      azurerm_role_assignment.frontend_certificate_reader[0].principal_id == "cccccccc-cccc-cccc-cccc-cccccccccccc" &&
      endswith(azurerm_role_assignment.frontend_certificate_reader[0].scope, "/secrets/masterly-example-com") &&
      azurerm_role_assignment.edge_certificate_reader[0].principal_id == "12121212-1212-1212-1212-121212121212" &&
      endswith(azurerm_role_assignment.edge_certificate_reader[0].scope, "/secrets/api-masterly-example-com")
    )
    error_message = "Each certificate identity must be granted its own certificate's secret alone."
  }

  assert {
    condition     = output.frontend_url == "https://masterly.example.com" && output.edge_url == "https://api.masterly.example.com"
    error_message = "With both custom domains set, frontend_url and edge_url must each be https://<its hostname>."
  }
}
