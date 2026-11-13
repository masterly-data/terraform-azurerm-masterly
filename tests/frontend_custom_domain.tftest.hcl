# frontend_custom_domain: guards and the derived redirect (custom-domain.tf).
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

# --- frontend_custom_domain (custom-domain.tf) -----------------------------------------------
# The guards and the derived redirect, at plan. The wiring of the identity, the grant, the
# certificate and the binding needs computed ids, so it is asserted by applies against the mocks
# in custom_domain.tftest.hcl.

# Unset (the default), the install plans exactly as before: no certificate identity, nothing on
# the environment, no certificate, no binding, and the frontend's redirect is the input.
run "custom_domain_unset_plans_no_certificate_identity_or_binding" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
  }

  assert {
    condition = (
      length(module.frontend_certificate_identity) == 0 &&
      length(module.aca_env.identity_ids) == 0 &&
      length(azurerm_role_assignment.frontend_certificate_reader) == 0 &&
      length(azurerm_container_app_environment_certificate.frontend) == 0 &&
      length(azurerm_container_app_custom_domain.frontend) == 0
    )
    error_message = "With frontend_custom_domain unset the module must plan no certificate identity, no environment identity, no role assignment, no certificate and no custom-domain binding."
  }

  assert {
    condition     = local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == var.oidc_redirect_uri
    error_message = "With frontend_custom_domain unset, ca-frontend's MASTERLY_OIDC_REDIRECT_URI must be oidc_redirect_uri."
  }
}

# The one-apply install: with the hostname set, oidc plans without oidc_redirect_uri and the
# frontend gets the callback on the hostname.
run "custom_domain_derives_the_oidc_redirect_uri" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  assert {
    condition     = local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == "https://masterly.example.com/api/auth/callback"
    error_message = "With frontend_custom_domain set, ca-frontend's MASTERLY_OIDC_REDIRECT_URI must be https://<hostname>/api/auth/callback."
  }

  assert {
    condition     = output.frontend_url == "https://masterly.example.com"
    error_message = "With frontend_custom_domain set, frontend_url must be https://<hostname>, known at plan."
  }

  assert {
    condition = (
      length(module.frontend_certificate_identity) == 1 &&
      length(azurerm_role_assignment.frontend_certificate_reader) == 1 &&
      length(azurerm_container_app_environment_certificate.frontend) == 1 &&
      length(azurerm_container_app_custom_domain.frontend) == 1
    )
    error_message = "With frontend_custom_domain set the module must plan one certificate identity, one role assignment, one certificate and one binding."
  }
}

# A redirect set alongside the hostname is accepted when it names the same host.
run "custom_domain_accepts_a_redirect_uri_on_its_hostname" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://masterly.example.com/api/auth/callback"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  assert {
    condition     = local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == "https://masterly.example.com/api/auth/callback"
    error_message = "A matching oidc_redirect_uri must plan, and the frontend must get the callback on the hostname."
  }
}

# The host is compared without its port: an explicit :443 on the hostname still plans.
run "custom_domain_accepts_a_redirect_uri_on_its_hostname_with_a_port" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://masterly.example.com:443/api/auth/callback"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  assert {
    condition     = local.frontend_env.MASTERLY_OIDC_REDIRECT_URI == "https://masterly.example.com/api/auth/callback"
    error_message = "A matching oidc_redirect_uri with a port must plan, and the frontend must get the derived callback."
  }
}

# Threat: the redirect and the bound hostname disagree, so sign-in breaks or the authorization
# code goes to a host the install does not serve.
run "custom_domain_refuses_a_redirect_uri_on_another_host" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://ca-frontend.example.swedencentral.azurecontainerapps.io/api/auth/callback"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.oidc_redirect_uri]
}

# Threat: user information in the authority hides the real host. In https://x@evil.example/ the
# host is evil.example; any @ in the authority is refused.
run "custom_domain_refuses_a_redirect_uri_with_user_information" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://x@evil.example/api/auth/callback"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.oidc_redirect_uri]
}

# Threat: the hostname written as user information before the real host. The host of
# https://masterly.example.com:443@other.example/ is other.example; the redirect is refused.
run "custom_domain_refuses_a_redirect_uri_hiding_another_host_behind_user_information" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
    oidc_redirect_uri  = "https://masterly.example.com:443@other.example/api/auth/callback"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.oidc_redirect_uri]
}

# Without the hostname, oidc still needs the redirect.
run "oidc_without_redirect_uri_or_custom_domain_is_rejected" {
  command = plan

  variables {
    identity_binding   = "oidc"
    oidc_tenant_id     = "11111111-2222-3333-4444-555555555555"
    oidc_client_id     = "bff-client-id"
    oidc_client_secret = "s3cret"
  }

  expect_failures = [var.identity_binding]
}

# Threat: a malformed hostname binds broader than intended, or fails only at apply. Each shape is
# refused at plan.
run "custom_domain_hostname_refuses_a_scheme" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "https://masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_a_path" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com/app"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_a_port" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com:443"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_a_wildcard" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "*.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_uppercase" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "Masterly.Example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_an_empty_string" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = ""
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_an_ip_address" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "203.0.113.10"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

run "custom_domain_hostname_refuses_a_single_label" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

# Threat: a pinned certificate version stops rotation, and the certificate expires in production.
run "custom_domain_refuses_a_versioned_secret_id" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com/0123456789abcdef0123456789abcdef"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

# The certificate's /certificates/ URL is not the secret the environment reads its key from.
run "custom_domain_refuses_a_certificates_url" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/certificates/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

# The grant goes on key_vault_id and the certificate is read from the secret id's vault: a pair
# that names two vaults is refused, rather than grant on one and read from the other.
run "custom_domain_refuses_a_vault_id_for_another_vault" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-other"
    }
  }

  expect_failures = [var.frontend_custom_domain]
}

# breakglass_owner_email defaults to initial_owner_email, but only once a hash arms break-glass:
# an install without one sets no break-glass env at all, as before.
run "breakglass_email_defaults_to_the_first_owner_when_armed" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    initial_owner_email    = "owner@example.com"
    breakglass_secret_hash = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"
  }

  assert {
    condition     = local.identity_env.MASTERLY_BREAKGLASS_OWNER_EMAIL == "owner@example.com"
    error_message = "With a breakglass_secret_hash and no breakglass_owner_email, break-glass must default to initial_owner_email."
  }
}

run "breakglass_stays_unset_without_a_hash" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    initial_owner_email   = "owner@example.com"
  }

  assert {
    condition     = !contains(keys(local.identity_env), "MASTERLY_BREAKGLASS_OWNER_EMAIL")
    error_message = "Without a breakglass_secret_hash, no break-glass email may be set: defaulting it must arm nothing new."
  }
}

run "explicit_breakglass_email_wins" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    initial_owner_email    = "owner@example.com"
    breakglass_owner_email = "recovery@example.com"
    breakglass_secret_hash = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"
  }

  assert {
    condition     = local.identity_env.MASTERLY_BREAKGLASS_OWNER_EMAIL == "recovery@example.com"
    error_message = "An explicit breakglass_owner_email must win over the initial_owner_email default."
  }
}
