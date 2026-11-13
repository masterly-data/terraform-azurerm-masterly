# CD owns the migrate job's running image, as it owns the apps' (ADR 0086 as amended 2026-10-23;
# migrate.tf): Terraform seeds it on create and then ignores drift, so a later api_image never
# moves the job off the release CD rolled and ran before the apps (mock providers — no cloud
# access; runs in CI via `terraform test`).
#
# Two applies, because only state shows an ignored change: the second changes api_image and the
# job keeps the first. It is a separate file so that the applies do not become state the
# per-concern plan files plan against.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location                       = "swedencentral"
  org_id                         = "org_test"
  install_id                     = "test"
  api_image                      = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image                 = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server               = ""
  ingress_allowed_cidrs          = ["203.0.113.7/32"]
  enable_diagnostics             = false
  migrations                     = "job"
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
  redis_offering                 = "cache"
  enable_workers                 = true
  api_max_replicas               = 2
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14
  database_auth                  = "password"
  alert_email                    = "ops@example.com"
  key_vault_deployer_ip_rules    = ["203.0.113.7"]
}

run "migrate_job_is_seeded_with_the_api_image" {
  command = apply

  plan_options {
    target = [
      azurerm_container_app_job.migrate,
      terraform_data.migrate_image,
    ]
  }

  assert {
    condition     = azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
    error_message = "Terraform must seed the migrate job with the resolved api image on create."
  }
}

run "migrate_job_keeps_the_image_cd_owns" {
  command = apply

  variables {
    api_image = "masterly.azurecr.io/release/api:v0.0.1"
  }

  plan_options {
    target = [
      azurerm_container_app_job.migrate,
      terraform_data.migrate_image,
    ]
  }

  assert {
    condition     = azurerm_container_app_job.migrate[0].template[0].container[0].image == "masterly.azurecr.io/release/api:v0.0.0"
    error_message = "A changed api_image must not move the migrate job's image: CD owns it, and moves it to a release's digest and runs it before it rolls ca-api and ca-workers (ignore_changes on template[0].container[0].image, as on the apps)."
  }

  assert {
    condition     = terraform_data.migrate_image[0].output == "masterly.azurecr.io/release/api:v0.0.1"
    error_message = "The start action's replace trigger must still follow the resolved api image."
  }
}
