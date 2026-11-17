# app placement: frontend_environment, edge_environment and api_environment (variables-core.tf),
# which move ca-frontend and ca-edge to the front environment and ca-api to the app environment,
# together, with the custom-domain certificates, the callers' HTTPS to ca-api, the api's ingress
# and the front subnet's one rule to the Key Vault private endpoint.
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# The environments' ids, default domains and verification ids are pinned with override_module,
# each to values of its own, so an app or certificate wired to the wrong environment compares
# unequal.

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

# --- Default placement: everything stays on aca-<prefix> -------------------------------------

run "default_placement_keeps_the_apps_and_certificates_on_aca_env" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
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
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      module.api.environment_id == module.aca_env[0].id &&
      module.frontend.environment_id == module.aca_env[0].id &&
      azurerm_container_app.edge[0].container_app_environment_id == module.aca_env[0].id &&
      azurerm_container_app_environment_certificate.frontend[0].container_app_environment_id == module.aca_env[0].id &&
      azurerm_container_app_environment_certificate.edge[0].container_app_environment_id == module.aca_env[0].id
    )
    error_message = "By default ca-api, ca-frontend, ca-edge and both custom-domain certificates must plan container_app_environment_id = module.aca_env.id."
  }

  assert {
    condition = (
      length(local.environment_certificate_identity_ids["aca"]) == 2 &&
      alltrue([for k in ["front", "app", "workers"] : length(local.environment_certificate_identity_ids[k]) == 0])
    )
    error_message = "By default aca-<prefix> must keep both certificate identities, and no new environment may hold one."
  }

  assert {
    condition     = nonsensitive(output.custom_domain_verification_id == "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF")
    error_message = "By default custom_domain_verification_id must read aca-<prefix>'s."
  }

  # The BFF keeps calling ca-api by its app name inside the environment.
  assert {
    condition     = local.frontend_env["MASTERLY_API_BASE_URL"] == "http://ca-api"
    error_message = "By default MASTERLY_API_BASE_URL must stay http://ca-api."
  }

  assert {
    condition     = module.api.ingress_external == false && module.api.ingress_allow_insecure == true
    error_message = "By default ca-api's ingress must stay internal, with the in-environment http:// hop allowed, as before."
  }

  # The refusals below can only name the variable they fail on; their messages are read from the
  # source: the mix refusal names the three inputs, the egress refusal the subnets left unrouted.
  assert {
    condition = (
      can(regex("error_message = \"frontend_environment, edge_environment and api_environment move together", file("${path.module}/variables-core.tf"))) &&
      can(regex("error_message = \"api_ingress_external = true cannot be combined with api_environment = ", file("${path.module}/variables-core.tf"))) &&
      can(regex("error_message = \"egress_firewall cannot be combined with frontend_environment, edge_environment or api_environment off .*the front and app environment subnets get no route table", file("${path.module}/variables-core.tf")))
    )
    error_message = "The placement refusals must name the three inputs, api_ingress_external with api_environment, and the subnets egress_firewall leaves without a route table."
  }
}

# --- Moved: ca-frontend and ca-edge on front, ca-api on app ----------------------------------

run "moved_placement_puts_frontend_and_edge_on_front_and_api_on_app" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
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
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      module.frontend.environment_id == module.environments["front"].id &&
      azurerm_container_app.edge[0].container_app_environment_id == module.environments["front"].id &&
      module.api.environment_id == module.environments["app"].id
    )
    error_message = "With the placement inputs set, ca-frontend and ca-edge must plan the front environment and ca-api the app environment."
  }

  # Threat: certificate identities left on an environment that no longer needs them. Both
  # certificates are on the front environment, which alone holds both identities; aca-<prefix>
  # holds neither. Each binding is the moved app's, with its own certificate.
  assert {
    condition = (
      azurerm_container_app_environment_certificate.frontend[0].container_app_environment_id == module.environments["front"].id &&
      azurerm_container_app_environment_certificate.edge[0].container_app_environment_id == module.environments["front"].id &&
      length(local.environment_certificate_identity_ids["aca"]) == 0 &&
      length(local.environment_certificate_identity_ids["front"]) == 2 &&
      length(local.environment_certificate_identity_ids["app"]) == 0 &&
      length(local.environment_certificate_identity_ids["workers"]) == 0 &&
      azurerm_container_app_custom_domain.frontend[0].name == "masterly.example.com" &&
      azurerm_container_app_custom_domain.edge[0].name == "api.masterly.example.com"
    )
    error_message = "With frontend and edge on front, both certificates must plan the front environment, front must hold both certificate identities and aca-<prefix> neither."
  }

  assert {
    condition = alltrue([
      for f in ["custom-domain.tf"] :
      can(regex("(?s)resource \"azurerm_container_app_custom_domain\" \"frontend\" \\{[^}]*container_app_id\\s*=\\s*module\\.frontend\\.id\\s*\\n\\s*container_app_environment_certificate_id\\s*=\\s*azurerm_container_app_environment_certificate\\.frontend\\[0\\]\\.id", file("${path.module}/${f}"))) &&
      can(regex("(?s)resource \"azurerm_container_app_custom_domain\" \"edge\" \\{[^}]*container_app_id\\s*=\\s*azurerm_container_app\\.edge\\[0\\]\\.id\\s*\\n\\s*container_app_environment_certificate_id\\s*=\\s*azurerm_container_app_environment_certificate\\.edge\\[0\\]\\.id", file("${path.module}/${f}")))
    ])
    error_message = "Each custom domain must bind its own app with its own certificate (ids are computed, so read from the source)."
  }

  assert {
    condition     = nonsensitive(output.custom_domain_verification_id == "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210")
    error_message = "With the certificates on the front environment, custom_domain_verification_id must read the front environment's."
  }

  # Threat: an unverified cross-environment call from the BFF. https:// to the app's name under
  # the app environment's default domain, never module.api's fqdn, and nothing that turns Node's
  # certificate checks off.
  assert {
    condition = (
      local.frontend_env["MASTERLY_API_BASE_URL"] == "https://ca-api.${module.environments["app"].default_domain}" &&
      local.frontend_env["MASTERLY_API_BASE_URL"] == "https://ca-api.app-3c4d.swedencentral.azurecontainerapps.io" &&
      !contains(module.frontend.env_names, "NODE_TLS_REJECT_UNAUTHORIZED") &&
      !contains(module.api.env_names, "NODE_TLS_REJECT_UNAUTHORIZED") &&
      !can(regex("module\\.api\\.fqdn", regex("(?s)frontend_env = merge\\((.*?)\\n  \\)", file("${path.module}/main.tf"))[0]))
    )
    error_message = "With ca-api in app, MASTERLY_API_BASE_URL must be https://ca-api.<app default domain>, not built from module.api's fqdn, with no NODE_TLS_REJECT_UNAUTHORIZED."
  }

  # Threat: ca-api in app published, or answering plain HTTP. The app environment is internal,
  # so external is the VNet only; http:// is never served.
  assert {
    condition = (
      local.container_app_environment_internal["app"] == true &&
      module.api.ingress_external == true &&
      module.api.ingress_allow_insecure == false
    )
    error_message = "With ca-api in app, the app environment must be internal and ca-api's ingress external (VNet-only) with allow_insecure_connections = false."
  }
}

# The identities on the environments themselves, read from the environment modules' echoes: each
# certificate identity is pinned to a known id, and the environments are not overridden.
run "moved_placement_attaches_the_certificate_identities_to_front_only" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
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
    target = module.frontend_certificate_identity[0]
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend-cert"
      principal_id = "11111111-1111-1111-1111-111111111111"
      client_id    = "11111111-1111-1111-1111-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend-cert"
    }
  }

  override_module {
    target = module.edge_certificate_identity[0]
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge-cert"
      principal_id = "22222222-2222-2222-2222-222222222222"
      client_id    = "22222222-2222-2222-2222-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-edge-cert"
    }
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
      tolist(module.environments["front"].identity_ids) == tolist([
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend-cert",
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge-cert",
      ]) &&
      length(module.aca_env[0].identity_ids) == 0 &&
      length(module.environments["app"].identity_ids) == 0 &&
      length(module.environments["workers"].identity_ids) == 0
    )
    error_message = "With frontend and edge on front, the front environment must hold both certificate identities and aca-<prefix>, app and workers none."
  }

  # Threat: a certificate identity attached to an app. Neither moved app carries one.
  assert {
    condition = (
      !contains(module.frontend.user_assigned_identity_ids, module.frontend_certificate_identity[0].id) &&
      !contains(module.frontend.user_assigned_identity_ids, module.edge_certificate_identity[0].id) &&
      !contains(module.api.user_assigned_identity_ids, module.frontend_certificate_identity[0].id) &&
      !contains(module.api.user_assigned_identity_ids, module.edge_certificate_identity[0].id)
    )
    error_message = "No app may carry a certificate identity."
  }
}

# --- Refusals --------------------------------------------------------------------------------

# Mixed placements: the frontend moved alone.
run "mixed_placement_frontend_alone_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_environment  = "front"
  }

  expect_failures = [var.api_environment]
}

# Mixed placements: the callers moved, the api left behind.
run "mixed_placement_api_left_on_aca_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
  }

  expect_failures = [var.api_environment]
}

# Mixed placements: the api moved alone.
run "mixed_placement_api_alone_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_environment       = "app"
  }

  expect_failures = [var.api_environment]
}

# A placement on an environment the module does not create: an injected network without the
# three environment subnets has no front or app environment.
run "placement_on_a_missing_environment_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    frontend_environment        = "front"
    edge_environment            = "front"
    api_environment             = "app"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Threat: ca-api in app published. api_ingress_external = true is refused there.
run "api_ingress_external_with_api_in_app_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
    api_ingress_external  = true
  }

  expect_failures = [var.api_environment]
}

# Threat: egress believed forced when it is not. The route table is on snet-aca only.
run "egress_firewall_with_the_apps_moved_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    egress_firewall            = { next_hop_ip = "10.0.0.4" }
    frontend_environment       = "front"
    edge_environment           = "front"
    api_environment            = "app"
  }

  expect_failures = [var.egress_firewall]
}

# Out-of-set placements: each guard on the allowed values fires. The environments named exist on
# this network, so the missing-environment precondition does not. The mix validation on
# var.api_environment does not report a frontend or edge value that already failed its own guard
# (Terraform treats a failed variable as unknown there), so only the guard is expected.
run "frontend_environment_app_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_environment  = "app"
  }

  expect_failures = [var.frontend_environment]
}

run "edge_environment_workers_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    edge_environment      = "workers"
  }

  expect_failures = [var.edge_environment]
}

run "api_environment_front_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_environment       = "front"
  }

  expect_failures = [var.api_environment]
}

# ca-frontend in front pulls its image from the front subnet, which the private-endpoint NSG
# admits to the Key Vault endpoint only (ADR 0120 amendment 2026-11-16): with the registry's
# private endpoint the pull would be dropped, so the plan refuses, on a network the module builds.
run "frontend_in_front_with_registry_private_endpoint_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    acr_login_server          = null
    registry_credential_mode  = "managed_identity"
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint = true
    frontend_environment      = "front"
    edge_environment          = "front"
    api_environment           = "app"
  }

  expect_failures = [var.frontend_environment]
}

# The same refusal on an injected network with the three environment subnets, where the hub owns
# the NSG: the refusal does not depend on who builds the network.
run "frontend_in_front_with_registry_private_endpoint_is_refused_on_an_injected_network" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    acr_login_server            = null
    registry_credential_mode    = "managed_identity"
    acr_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint   = true
    frontend_environment        = "front"
    edge_environment            = "front"
    api_environment             = "app"
  }

  expect_failures = [var.frontend_environment]
}

# --- The private-endpoint NSG ----------------------------------------------------------------

# By default no rule names the front subnet (10.20.5.0/24), with the vault, Redis and a private
# Service Bus on.
run "default_placement_adds_no_front_rule_to_the_endpoints_nsg" {
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
    enable_service_bus    = true
    servicebus_sku        = "Premium"
    enable_workers        = true
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.key_vault) == 1 &&
      alltrue([for r in azurerm_network_security_group.private_endpoints[0].security_rule : r.source_address_prefix != local.env_subnet_prefixes["front"]]) &&
      !contains([for r in azurerm_network_security_group.private_endpoints[0].security_rule : r.name], "allow-key-vault-from-front-subnet")
    )
    error_message = "By default no private-endpoint NSG rule may name the front subnet."
  }
}

# Threat: the front subnet reaching more than the vault. Exactly one rule from the front subnet,
# on 443 only, to the Key Vault private endpoint's own address; the endpoint's address is known
# only once applied, so the /32 is asserted from the source below.
run "moved_placement_admits_the_front_subnet_to_the_vault_on_443_only" {
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
    enable_service_bus    = true
    servicebus_sku        = "Premium"
    enable_workers        = true
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
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
      length(azurerm_private_endpoint.key_vault) == 1 &&
      [
        for r in azurerm_network_security_group.private_endpoints[0].security_rule : join(" ", [
          r.name, tostring(r.priority), r.direction, r.access, r.protocol, r.source_address_prefix,
          r.destination_port_range != null ? r.destination_port_range : join(",", sort(r.destination_port_ranges)),
        ]) if r.source_address_prefix == local.env_subnet_prefixes["front"]
      ] == ["allow-key-vault-from-front-subnet 130 Inbound Allow Tcp 10.20.5.0/24 443"]
    )
    error_message = "With ca-frontend in front, the private-endpoint NSG must hold exactly one rule from the front subnet: allow-key-vault-from-front-subnet, TCP 443 only."
  }

  # Its destination is the Key Vault private endpoint's own address as a /32, never the endpoints
  # subnet. The address is computed (unknown at plan, and `override_during = plan` needs Terraform
  # 1.11 while CI runs 1.10), so the expression is read from the source.
  assert {
    condition = (
      length(regexall("(?s)name\\s*=\\s*\"allow-key-vault-from-front-subnet\".*?destination_address_prefix\\s*=\\s*\"\\$\\{azurerm_private_endpoint\\.key_vault\\[0\\]\\.private_service_connection\\[0\\]\\.private_ip_address\\}/32\"\\s*\\n\\s*destination_port_range\\s*=\\s*\"443\"", file("${path.module}/network.tf"))) == 1 &&
      !can(regex("(?s)name\\s*=\\s*\"allow-key-vault-from-front-subnet\"[^}]*private_endpoints_subnet_prefix", file("${path.module}/network.tf")))
    )
    error_message = "The front subnet's rule must target azurerm_private_endpoint.key_vault's private IP as a /32 on 443, never the private-endpoint subnet."
  }

  # No rule whose source is the front subnet opens a data-plane port other than 443: not Postgres
  # (5432), PgBouncer (6432), Redis (6380, 10000, or the managed Redis port), Service Bus (5671).
  assert {
    condition = alltrue(flatten([
      for r in azurerm_network_security_group.private_endpoints[0].security_rule : [
        for p in concat(r.destination_port_range != null ? [r.destination_port_range] : [], r.destination_port_ranges != null ? tolist(r.destination_port_ranges) : []) :
        p == "443"
      ] if r.source_address_prefix == local.env_subnet_prefixes["front"]
    ]))
    error_message = "No private-endpoint NSG rule may admit the front subnet to 5432, 6432, 6380, 10000, 5671 or the managed Redis port."
  }

  # The other rules are unchanged: snet-aca, app and workers on the data-plane ports, then the deny.
  assert {
    condition = toset([
      for r in azurerm_network_security_group.private_endpoints[0].security_rule : join(" ", [
        r.name, tostring(r.priority), r.source_address_prefix, r.destination_address_prefix,
        r.destination_port_range != null ? r.destination_port_range : join(",", sort(r.destination_port_ranges)),
      ]) if r.name != "allow-key-vault-from-front-subnet"
      ]) == toset([
      "allow-data-plane-from-apps 100 10.20.0.0/23 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-app-subnet 110 10.20.6.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-workers-subnet 120 10.20.7.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "deny-all-inbound 4000 * * *",
    ])
    error_message = "Moving the frontend must leave the private-endpoint NSG's other rules as they were."
  }

  # Reaching the vault grants no secret: ca-frontend's references all resolve as its own identity.
  assert {
    condition = (
      length(module.frontend.vault_backed_secret_names) > 0 &&
      tolist(module.frontend.secret_ref_identity_ids) == tolist([module.frontend_identity.id])
    )
    error_message = "ca-frontend's secret_refs must all still use module.frontend_identity.id."
  }
}
