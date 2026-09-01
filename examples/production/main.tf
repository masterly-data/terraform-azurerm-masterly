# A complete production install.
#
# `mode = "production"` is gated at PLAN time, not at apply: the module refuses the plan
# unless every input below is wired. That is deliberate — the app makes the same refusals
# at boot, and failing at plan is cheaper than failing in a running install.

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.61, < 5.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

module "masterly" {
  # Sourced relatively so this example is testable in-repo. Copying it into your own
  # install repository? Use the public module at a pinned tag, never a branch:
  #
  #   source = "github.com/masterly-data/terraform-azurerm-masterly?ref=v0.8.0"
  source = "../../"

  mode = "production"

  # --- Identity -------------------------------------------------------------------
  # Your install, your directory. Masterly is not in this path.
  org_id     = var.org_id
  install_id = var.install_id
  org_name   = var.org_name

  location        = var.location
  masterly_region = var.masterly_region
  allowed_regions = [var.masterly_region]

  # --- Images ---------------------------------------------------------------------
  # Direct pull with the credential from your install bundle. This is the right choice
  # for a first apply: it needs no permissions in your subscription and no mirroring.
  #
  # Mirroring into your own registry instead? Set acr_login_server (+ acr_id if the
  # module should write the AcrPull grant) and OMIT these two — leaving them set points
  # Masterly's credential at your registry and every pull fails. Nothing catches that
  # combination at plan time.
  api_image         = "masterly.azurecr.io/api:${var.api_image_tag}"
  frontend_image    = "masterly.azurecr.io/frontend:${var.frontend_image_tag}"
  registry_username = var.registry_username
  registry_password = var.registry_password

  # --- Licence --------------------------------------------------------------------
  # Verified locally against the bundled public key. The `sub` claim must equal org_id,
  # so a licence minted for another organization fails at startup, not silently.
  license_token      = var.license_token
  license_public_jwk = file("${path.module}/license-issuer.jwk.json")

  # --- Identity provider ----------------------------------------------------------
  # production requires oidc. There is no broker: the install verifies your tokens.
  identity_binding   = "oidc"
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret
  oidc_audience      = var.oidc_client_id

  oidc_authority       = "https://login.microsoftonline.com/${var.oidc_tenant_id}/v2.0"
  oidc_allowed_issuers = "https://login.microsoftonline.com/${var.oidc_tenant_id}/v2.0"
  oidc_jwks_uri        = "https://login.microsoftonline.com/${var.oidc_tenant_id}/discovery/v2.0/keys"

  # Without a custom domain the frontend hostname is an OUTPUT of the first apply, so it
  # cannot be registered at your IdP beforehand. Leave the placeholder for apply 1, read
  # `frontend_url`, register https://<host>/api/auth/callback, then set this and apply
  # again. This value is read only during sign-in — never at boot, never by the readiness
  # probe — so apply 1 comes up healthy in full production posture with it unset.
  oidc_redirect_uri = var.oidc_redirect_uri

  # --- First Owner ----------------------------------------------------------------
  # One-shot: the first sign-in with this address becomes the Organization's Owner, then
  # the rule disarms permanently. It is the ONLY route to a first Owner — break-glass is
  # not a substitute, because that path admits an address that already holds the role.
  initial_owner_email = var.initial_owner_email

  # Break-glass needs BOTH halves. The email alone arms nothing.
  breakglass_owner_email = var.initial_owner_email
  breakglass_secret_hash = var.breakglass_secret_hash

  # --- Durable stores -------------------------------------------------------------
  enable_key_vault = true
  enable_redis     = true

  # No default, on purpose. "managed" provisions Azure Managed Redis, which any tenant
  # can create; "cache" keeps an Azure Cache for Redis you already run. Microsoft blocked
  # NEW customers from creating the latter on 1 April 2026, so a tenant that never ran one
  # cannot use "cache" at all — and switching an existing install plans a destroy of your
  # session store. Visible in the plan, but easy to walk into.
  redis_offering = "managed"

  # production requires workers: the pipeline runs here, not in the api.
  enable_workers     = true
  enable_service_bus = true

  # --- Data plane -----------------------------------------------------------------
  # Bring your own Postgres, or leave external_database_url null for the starter server.
  # production refuses a burstable SKU and requires HA and >= 14 days of backups on the
  # provisioned server.
  external_database_url          = var.external_database_url
  postgres_sku_name              = "GP_Standard_D2ds_v5"
  postgres_zone_redundant_ha     = true
  postgres_backup_retention_days = 14

  # --- Scale ----------------------------------------------------------------------
  # production refuses a single-replica api: one replica is a single point of failure,
  # and > 1 requires redis so sessions survive a replica moving.
  api_min_replicas      = 2
  api_max_replicas      = 3
  frontend_min_replicas = 1

  tags = var.tags
}

output "frontend_url" {
  value       = module.masterly.frontend_url
  description = "Register https://<this host>/api/auth/callback at your IdP, then set oidc_redirect_uri and apply again."
}
