# App settings: telemetry, the public base URL, demo Environments, a private CA.
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

# --- Telemetry to the control plane (ADR 0034/0056) --------------------------------------
# Built at both ends and never wired: the application's reporter gates on url AND client_id,
# and the module set neither, so no self-hosted install has ever reported. telemetry_url is
# the switch; the client id and secret are the install credential licence refresh shares.

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

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_TELEMETRY_CLIENT_ID") && !contains(keys(local.api_env_secret_refs), "MASTERLY_TELEMETRY_CLIENT_SECRET")
    error_message = "With no install credential set, neither half of it may reach the apps."
  }
}

# The erasure backup horizon (ADR 0081 §6): an erasure's completion record states how long
# the deleted record can survive in backups. The module knows that only for the starter
# server it provisions, so it states it there and nowhere else. 21 is not the default, so
# a value hard-wired to 7 cannot pass.
run "erasure_backup_horizon_follows_starter_server_retention" {
  command = plan

  variables {
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    postgres_backup_retention_days = 21
  }

  assert {
    condition     = local.api_env["MASTERLY_ERASURE_BACKUP_RETENTION_DAYS"] == "21"
    error_message = "On the starter server the api must be told the backup retention it was provisioned with."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].backup_retention_days == 21
    error_message = "The horizon stated to the api must be the retention the server is provisioned with."
  }
}

# On BYO-DB the module does not know the customer's backup policy, so it states nothing and
# the api falls back to "the operator's backup policy governs". A number here would be a
# claim about backups the module does not own.
run "erasure_backup_horizon_absent_on_byo_db" {
  command = plan

  variables {
    ingress_allowed_cidrs          = ["203.0.113.7/32"]
    external_database_url          = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    postgres_backup_retention_days = 21
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_ERASURE_BACKUP_RETENTION_DAYS")
    error_message = "With external_database_url set the backup horizon must not be set at all."
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

# --- The api's public base URL (MAS-1148, ADR 0092) ------------------------------------------
# One input, one variable, three apps: ca-api and ca-workers build an external step's callback
# URL from it, ca-frontend shows it in the catalog's Consume card. These runs pin that unset
# writes nothing anywhere, that a value reaches all three apps (through module.<app>.env_names,
# inside the submodule, so dropping it from either merge fails), and the plan-time refusals.

run "public_api_url_is_absent_by_default" {
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

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_PUBLIC_API_URL") &&
      !contains(module.workers[0].env_names, "MASTERLY_PUBLIC_API_URL") &&
      !contains(module.frontend.env_names, "MASTERLY_PUBLIC_API_URL")
    )
    error_message = "public_api_url unset must not put MASTERLY_PUBLIC_API_URL on any app -- an install that does not set it must plan exactly as before this input existed."
  }
}

run "public_api_url_reaches_all_three_apps" {
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

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    api_ingress_external  = true
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "https://api.example.com/masterly//"
  }

  # Verbatim but for the trailing slashes, which are dropped so "/v1/..." appends cleanly.
  assert {
    condition     = local.public_api_url_env["MASTERLY_PUBLIC_API_URL"] == "https://api.example.com/masterly"
    error_message = "public_api_url must reach the apps as given, with trailing slashes dropped."
  }

  assert {
    condition     = local.api_env["MASTERLY_PUBLIC_API_URL"] == "https://api.example.com/masterly"
    error_message = "The api's environment must carry the public API URL."
  }

  assert {
    condition     = contains(module.api.env_names, "MASTERLY_PUBLIC_API_URL")
    error_message = "MASTERLY_PUBLIC_API_URL must reach ca-api's container environment."
  }

  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_PUBLIC_API_URL")
    error_message = "MASTERLY_PUBLIC_API_URL must reach ca-workers too -- the workers build the callback URL."
  }

  assert {
    condition     = contains(module.frontend.env_names, "MASTERLY_PUBLIC_API_URL")
    error_message = "MASTERLY_PUBLIC_API_URL must reach ca-frontend -- the catalog's Consume card shows it."
  }
}

# A bare origin with no path is the common case and must plan clean.
run "public_api_url_accepts_a_bare_origin" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "https://ca-api.example-env.swedencentral.azurecontainerapps.io"
  }

  assert {
    condition     = local.public_api_url_env["MASTERLY_PUBLIC_API_URL"] == "https://ca-api.example-env.swedencentral.azurecontainerapps.io"
    error_message = "A bare https origin must be accepted and passed through unchanged."
  }
}

# Guard: plain http is refused -- the URL is handed to callers outside the install.
run "public_api_url_refuses_plain_http" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "http://api.example.com"
  }

  expect_failures = [var.public_api_url]
}

# Guard: a query string is refused -- the apps append paths to this value.
run "public_api_url_refuses_a_query_string" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "https://api.example.com/?tenant=a"
  }

  expect_failures = [var.public_api_url]
}

# Guard: a relative URL is refused -- a caller outside the install cannot resolve it.
run "public_api_url_refuses_a_relative_url" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "/api"
  }

  expect_failures = [var.public_api_url]
}

# Guard: a host without a scheme is not an absolute URL.
run "public_api_url_refuses_a_bare_host" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "api.example.com"
  }

  expect_failures = [var.public_api_url]
}

# Guard: a fragment is refused for the same reason as a query string.
run "public_api_url_refuses_a_fragment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "https://api.example.com/#v1"
  }

  expect_failures = [var.public_api_url]
}

# Guard: credentials in the URL are refused -- it is shown to readers and handed to callers.
run "public_api_url_refuses_credentials" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    public_api_url        = "https://user:pw@api.example.com"
  }

  expect_failures = [var.public_api_url]
}

# --- Extra Environments on the demo control plane ----------------------------------------------
# On mode = "demo" the control plane is in memory and its Environments are a fixture list;
# demo_environments names extra ones it seeds at start, as MASTERLY_DEMO_ENVIRONMENTS. These runs
# pin that unset writes nothing anywhere, that a list reaches ca-api and ca-workers comma-joined
# (through module.<app>.env_names, inside the submodule, so dropping it from either merge fails)
# and not the frontend, and each plan-time refusal.

run "demo_environments_are_absent_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
  }

  # Absent, not an empty string: an empty list is the absence of the setting, so an install
  # that does not set it plans exactly as before this input existed.
  assert {
    condition     = !contains(keys(local.install_env), "MASTERLY_DEMO_ENVIRONMENTS")
    error_message = "demo_environments = [] must set nothing at all."
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_DEMO_ENVIRONMENTS") &&
      !contains(module.workers[0].env_names, "MASTERLY_DEMO_ENVIRONMENTS") &&
      !contains(module.frontend.env_names, "MASTERLY_DEMO_ENVIRONMENTS")
    )
    error_message = "demo_environments unset must not put MASTERLY_DEMO_ENVIRONMENTS on any app."
  }
}

run "demo_environments_reach_the_backend_apps" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    # The longest name the guard admits (40 characters) plans clean beside two short ones.
    demo_environments = ["dev-eu", "uat2", "a234567890123456789012345678901234567890"]
  }

  # Comma-joined, in the order given, verbatim: the application splits on commas.
  assert {
    condition     = local.install_env["MASTERLY_DEMO_ENVIRONMENTS"] == "dev-eu,uat2,a234567890123456789012345678901234567890"
    error_message = "demo_environments must reach the application as one comma-joined string, in the order given."
  }

  assert {
    condition     = local.api_env["MASTERLY_DEMO_ENVIRONMENTS"] == "dev-eu,uat2,a234567890123456789012345678901234567890"
    error_message = "ca-api's environment must carry the joined demo_environments."
  }

  assert {
    condition     = contains(module.api.env_names, "MASTERLY_DEMO_ENVIRONMENTS")
    error_message = "MASTERLY_DEMO_ENVIRONMENTS must reach ca-api's container environment."
  }

  # ca-workers builds its own control plane from the same env: without the list it would not
  # know the extra Environments, and their jobs would never be drained.
  assert {
    condition     = local.workers_env["MASTERLY_DEMO_ENVIRONMENTS"] == "dev-eu,uat2,a234567890123456789012345678901234567890"
    error_message = "ca-workers' environment must carry the same joined demo_environments as ca-api."
  }

  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_DEMO_ENVIRONMENTS")
    error_message = "MASTERLY_DEMO_ENVIRONMENTS must reach ca-workers' container environment."
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_DEMO_ENVIRONMENTS")
    error_message = "MASTERLY_DEMO_ENVIRONMENTS is a backend setting -- the frontend must not carry it."
  }

  # The demo shape has no migrate job (migrations = "job" is refused on demo), so nothing else
  # builds an env that would need the list.
  assert {
    condition     = length(azurerm_container_app_job.migrate) == 0
    error_message = "A demo install must have no migrate job."
  }
}

# Guard: an uppercase letter is not an Environment name.
run "demo_environments_refuse_an_uppercase_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["dev-eu", "Test-eu"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: a name starts with a letter.
run "demo_environments_refuse_a_name_starting_with_a_digit" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["2dev"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: a comma inside a name would split it into two once joined.
run "demo_environments_refuse_a_comma_in_a_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["dev,eu"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: at most 40 characters (this one is 41).
run "demo_environments_refuse_a_name_over_40_characters" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["a2345678901234567890123456789012345678901"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: a name ends in a letter or a digit. The application refuses a trailing hyphen at
# startup, so a plan that let one through would apply an api that does not start.
run "demo_environments_refuse_a_trailing_hyphen" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["story-"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: an empty string is not a name.
run "demo_environments_refuse_an_empty_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = [""]
  }

  expect_failures = [var.demo_environments]
}

# Guard: each name once.
run "demo_environments_refuse_a_duplicate" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["dev-eu", "uat-eu", "dev-eu"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: the fixture names are taken.
run "demo_environments_refuse_the_fixture_prd_eu" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["dev-eu", "prd-eu"]
  }

  expect_failures = [var.demo_environments]
}

run "demo_environments_refuse_the_fixture_non_prd_eu" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    demo_environments     = ["non-prd-eu"]
  }

  expect_failures = [var.demo_environments]
}

# Guard: production creates Environments in the product, where they persist. A production plan
# that is otherwise valid, with the migrate job (the one shape that has it), fails on this input
# alone.
run "demo_environments_refused_on_production" {
  command = plan

  variables {
    migrations           = "job"
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

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"

    demo_environments = ["dev-eu"]
  }

  expect_failures = [var.demo_environments]
}

# --- Deployment switches the backend is told about ----------------------------------------------
# deployed_switches sets MASTERLY_DEPLOYED_SWITCHES on ca-api and ca-workers. These runs pin that
# unset writes nothing anywhere, that a list reaches both comma-joined and not the frontend, and
# the plan-time refusal of an unknown name (the backend would not start on it) and a repeat.

run "deployed_switches_are_absent_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
  }

  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_DEPLOYED_SWITCHES")
    error_message = "deployed_switches = [] must set nothing at all."
  }

  assert {
    condition = (
      !contains(module.api.env_names, "MASTERLY_DEPLOYED_SWITCHES") &&
      !contains(module.workers[0].env_names, "MASTERLY_DEPLOYED_SWITCHES") &&
      !contains(module.frontend.env_names, "MASTERLY_DEPLOYED_SWITCHES")
    )
    error_message = "deployed_switches unset must not put MASTERLY_DEPLOYED_SWITCHES on any app."
  }
}

run "deployed_switches_reach_the_backend_apps" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    deployed_switches     = ["assets", "replica"]
  }

  assert {
    condition     = local.api_env["MASTERLY_DEPLOYED_SWITCHES"] == "assets,replica"
    error_message = "ca-api's environment must carry the comma-joined deployed_switches, in the order given."
  }

  assert {
    condition     = contains(module.api.env_names, "MASTERLY_DEPLOYED_SWITCHES")
    error_message = "MASTERLY_DEPLOYED_SWITCHES must reach ca-api's container environment."
  }

  assert {
    condition     = local.workers_env["MASTERLY_DEPLOYED_SWITCHES"] == local.api_env["MASTERLY_DEPLOYED_SWITCHES"]
    error_message = "ca-workers' environment must carry the same value as ca-api."
  }

  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_DEPLOYED_SWITCHES")
    error_message = "MASTERLY_DEPLOYED_SWITCHES must reach ca-workers' container environment."
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_DEPLOYED_SWITCHES")
    error_message = "MASTERLY_DEPLOYED_SWITCHES is a backend setting -- the frontend must not carry it."
  }
}

# Guard: the backend refuses to start on a name it does not know.
run "deployed_switches_refuse_an_unknown_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    deployed_switches     = ["assets", "bogus"]
  }

  expect_failures = [var.deployed_switches]
}

# Guard: an empty string is not a switch.
run "deployed_switches_refuse_an_empty_name" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    deployed_switches     = [""]
  }

  expect_failures = [var.deployed_switches]
}

# Guard: each switch once.
run "deployed_switches_refuse_a_duplicate" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    deployed_switches     = ["assets", "assets"]
  }

  expect_failures = [var.deployed_switches]
}

# --- Trusting a private CA (MAS-446) ---------------------------------------------------------
# The allowlist above answers WHERE the application may connect; ca_bundle_pem answers whether
# it TRUSTS what answers there (MAS-375 made SMTP STARTTLS verify rather than accept anything).
# These runs assert the mount reaches the container apps that actually make outbound TLS
# connections -- through module.<app>.secret_file_mounts and module.<app>.env_names, both
# INSIDE the submodule, so the assertion fails if the wiring is dropped in the root's merge --
# and that a private-CA install still plans clean with the Key Vault-backed secret store on,
# since production requires enable_key_vault.

run "ca_bundle_is_absent_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = !contains(keys(local.api_env), "SSL_CERT_FILE")
    error_message = "ca_bundle_pem unset must not set SSL_CERT_FILE -- outbound TLS must verify against the image's own trust store exactly as before this input existed."
  }

  assert {
    condition     = length(module.api.secret_file_mounts) == 0
    error_message = "The default must not put a CA bundle mount on ca-api."
  }
}

run "ca_bundle_reaches_the_backend_apps" {
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

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ca_bundle_pem         = "-----BEGIN CERTIFICATE-----\nMIIBfakefakefakefakefakefakefakefakefakefakeA==\n-----END CERTIFICATE-----\n"
  }

  # SSL_CERT_FILE names the path the init container actually writes to -- the two must agree,
  # or the application would look for the bundle somewhere the mount never lands it.
  assert {
    condition     = local.api_env["SSL_CERT_FILE"] == "/mnt/secrets/ca-bundle/ca-bundle.pem"
    error_message = "SSL_CERT_FILE must name the exact path the CA bundle is mounted at."
  }

  # ca-api makes the SMTP STARTTLS handshake (core/delivery) and reaches stream push /
  # local-LLM endpoints -- the targets the card names.
  assert {
    condition     = contains(module.api.env_names, "SSL_CERT_FILE")
    error_message = "SSL_CERT_FILE must reach ca-api's container environment."
  }

  assert {
    condition     = contains(keys(module.api.secret_file_mounts), "ca-bundle")
    error_message = "The CA bundle mount must reach ca-api."
  }

  assert {
    condition     = module.api.secret_file_mounts["ca-bundle"].mount_path == "/mnt/secrets/ca-bundle"
    error_message = "The CA bundle mount's path must match what SSL_CERT_FILE's directory names."
  }

  # The write must be additive -- the image's own CA bundle first, ca_bundle_pem's content
  # appended -- or every other outbound target that presents a publicly-trusted certificate
  # (telemetry, licence refresh, ACS email) starts failing verification the moment this apply
  # lands. This is also what keeps ca_bundle_pem itself small enough to fit a Key Vault
  # secret's 25 KB limit on a production install, since it never has to carry a copy of the
  # image's own ~230 KB bundle.
  assert {
    condition     = module.api.secret_file_mounts["ca-bundle"].prepend_image_ca_bundle == true
    error_message = "The CA bundle mount must be additive (prepend_image_ca_bundle = true), or ca_bundle_pem replaces the image's trust store instead of extending it."
  }

  # ca-workers runs the same image and makes the same guarded connections (SMTP, webhook and
  # stream-push delivery) -- an install trusting the CA on the api alone
  # would still fail every job that ran in the workers process.
  assert {
    condition     = contains(module.workers[0].env_names, "SSL_CERT_FILE")
    error_message = "SSL_CERT_FILE must reach ca-workers too -- the pipeline makes the same guarded connections."
  }

  assert {
    condition     = contains(keys(module.workers[0].secret_file_mounts), "ca-bundle")
    error_message = "The CA bundle mount must reach ca-workers too."
  }

  # And not the frontend, which makes none of these connections and reads no such setting.
  assert {
    condition     = !contains(module.frontend.env_names, "SSL_CERT_FILE")
    error_message = "The CA bundle is a backend concern -- the frontend must not carry SSL_CERT_FILE."
  }

  assert {
    condition     = length(module.frontend.secret_file_mounts) == 0
    error_message = "The CA bundle mount is a backend concern -- the frontend must not carry it."
  }

  # Key Vault on (required by mode=production): the bundle's content must travel as a vault
  # reference like every other install secret, not as a value the app itself has to hold.
  assert {
    condition     = contains(keys(local.api_vault_secret_refs), "ca-bundle-pem")
    error_message = "With enable_key_vault, ca_bundle_pem must be stored as a Key Vault reference like the install's other secrets, not as a value-based Container App secret."
  }
}

# Guard: an empty or whitespace-only bundle would set SSL_CERT_FILE at an empty trust store.
run "ca_bundle_refuses_an_empty_string" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    ca_bundle_pem         = "   "
  }

  expect_failures = [var.ca_bundle_pem]
}

# Guard: something that is not a PEM bundle (no BEGIN CERTIFICATE marker) fails at plan, not
# after an apply that silently breaks every outbound TLS connection the install makes.
run "ca_bundle_refuses_content_without_a_certificate_marker" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    ca_bundle_pem         = "not actually a certificate"
  }

  expect_failures = [var.ca_bundle_pem]
}
