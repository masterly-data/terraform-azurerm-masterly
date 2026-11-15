# edge_custom_domain: ca-edge on the customer's hostname, its guards (custom-domain.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# The wiring of the identity, the grant, the certificate and the binding needs computed ids, so it
# is asserted by applies against the mocks in custom_domain.tftest.hcl, as for the frontend's.

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

# --- edge_custom_domain unset ----------------------------------------------------------------

# Unset (the default), with edge unset too: nothing of the edge's custom domain, nothing on the
# environment, and no edge_url.
run "edge_custom_domain_unset_without_edge_plans_nothing" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(module.edge_certificate_identity) == 0 &&
      length(azurerm_role_assignment.edge_certificate_reader) == 0 &&
      length(azurerm_container_app_environment_certificate.edge) == 0 &&
      length(azurerm_container_app_custom_domain.edge) == 0 &&
      length(module.aca_env.identity_ids) == 0
    )
    error_message = "With edge_custom_domain unset the module must plan no edge certificate identity, no grant, no certificate, no binding and no environment identity."
  }

  assert {
    condition     = output.edge_url == null
    error_message = "With edge unset, edge_url must be null."
  }
}

# Unset with edge on: ca-edge is planned, and still nothing of its custom domain. edge_url is the
# Container Apps FQDN, unknown at plan; custom_domain.tftest.hcl asserts it after an apply.
run "edge_custom_domain_unset_with_edge_plans_nothing" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azurerm_container_app.edge) == 1 &&
      length(module.edge_certificate_identity) == 0 &&
      length(azurerm_role_assignment.edge_certificate_reader) == 0 &&
      length(azurerm_container_app_environment_certificate.edge) == 0 &&
      length(azurerm_container_app_custom_domain.edge) == 0 &&
      length(module.aca_env.identity_ids) == 0
    )
    error_message = "With edge set and edge_custom_domain unset the module must plan ca-edge, and no edge certificate identity, no grant, no certificate, no binding and no environment identity."
  }
}

# --- edge_custom_domain set ------------------------------------------------------------------

run "edge_custom_domain_plans_the_identity_grant_certificate_and_binding" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  assert {
    condition = (
      length(module.edge_certificate_identity) == 1 &&
      module.edge_certificate_identity[0].name == "id-masterly-edge-cert" &&
      length(azurerm_role_assignment.edge_certificate_reader) == 1 &&
      length(azurerm_container_app_environment_certificate.edge) == 1 &&
      azurerm_container_app_environment_certificate.edge[0].name == "cert-masterly-edge" &&
      length(azurerm_container_app_custom_domain.edge) == 1 &&
      azurerm_container_app_custom_domain.edge[0].name == "api.masterly.example.com" &&
      azurerm_container_app_custom_domain.edge[0].certificate_binding_type == "SniEnabled" &&
      length(module.aca_env.identity_ids) == 1
    )
    error_message = "With edge_custom_domain set the module must plan the certificate identity id-<prefix>-edge-cert, one grant, the certificate cert-<prefix>-edge, an SNI binding for the hostname, and the one identity on the environment."
  }

  # Threat: a grant wider than the one secret.
  assert {
    condition = (
      azurerm_role_assignment.edge_certificate_reader[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.edge_certificate_reader[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs/secrets/api-masterly-example-com"
    )
    error_message = "The edge certificate identity's grant must be Key Vault Secrets User on <key_vault_id>/secrets/<certificate name> alone."
  }

  # Nothing the frontend's: its custom domain stays off.
  assert {
    condition = (
      length(module.frontend_certificate_identity) == 0 &&
      length(azurerm_container_app_custom_domain.frontend) == 0
    )
    error_message = "edge_custom_domain alone must plan nothing of frontend_custom_domain."
  }

  assert {
    condition     = output.edge_url == "https://api.masterly.example.com"
    error_message = "With edge_custom_domain set, edge_url must be https://<edge hostname>."
  }
}

# Both custom domains, each on its own hostname: both identities on the environment.
run "edge_and_frontend_custom_domains_plan_together" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
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

  assert {
    condition = (
      length(azurerm_container_app_custom_domain.frontend) == 1 &&
      length(azurerm_container_app_custom_domain.edge) == 1 &&
      length(module.aca_env.identity_ids) == 2 &&
      output.edge_url == "https://api.masterly.example.com"
    )
    error_message = "With both custom domains set the module must plan both bindings, put both certificate identities on the environment, and point edge_url at the edge's hostname."
  }
}

# --- Refusals --------------------------------------------------------------------------------

# Threat: a hostname bound to nothing. ca-edge exists only with edge set.
run "edge_custom_domain_without_edge_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

# expect_failures cannot read a message, so this reads the refusal's: it names edge as the input
# to set.
run "edge_custom_domain_without_edge_names_edge_as_the_fix" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = strcontains(
      regex("var\\.edge != null\\s+error_message\\s+=\\s+\"([^\"]*)\"", file("${path.module}/variables-custom-domain.tf"))[0],
      "set edge as well"
    )
    error_message = "edge_custom_domain's refusal without edge must name edge as the input to set."
  }
}

# Threat: the same hostname on ca-frontend and ca-edge, refused at plan rather than at apply.
run "edge_custom_domain_same_hostname_as_frontend_is_refused" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
    edge_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

# The same three validations as frontend_custom_domain, each with edge on so only the shape fails.
run "edge_custom_domain_hostname_refuses_a_scheme" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "https://api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

run "edge_custom_domain_hostname_refuses_uppercase" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "API.Masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

# Threat: a pinned certificate version stops rotation, and the certificate expires on the edge.
run "edge_custom_domain_refuses_a_versioned_secret_id" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com/0123456789abcdef0123456789abcdef"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

run "edge_custom_domain_refuses_a_certificates_url" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/certificates/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.edge_custom_domain]
}

run "edge_custom_domain_refuses_a_vault_id_for_another_vault" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-other"
    }
  }

  expect_failures = [var.edge_custom_domain]
}
