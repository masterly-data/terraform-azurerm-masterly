# The api: its application secrets, identity-provider locals, environment and Container App.

# --- Application secrets (born in the install, never in Git) ---------------------

resource "random_password" "session_secret" {
  length  = 48
  special = false
}

# The BFF shared secret (MASTERLY_BFF_SHARED_SECRET), held by ca-api and ca-frontend and by no
# other app. A break-glass sign-in made in the GUI reaches the api from the frontend's BFF, not
# from the browser, so on its own the api sees a frontend replica's address: every GUI attempt
# then shares one throttle window, and the audit record names the replica. With this secret on
# both apps, the BFF states the browser's address and presents the secret to show it is this
# install's BFF; the api believes the address only on a request that carries the matching
# value, so a caller that does not hold it cannot choose its own address, on the internal hop
# or on a published api (api_ingress_external). Without the same value on both apps, the
# mechanism is off.
#
# The same shape as the session secret: 48 alphanumeric characters, above the 32 bytes the api
# requires at startup. To rotate it, replace it (`terraform apply
# -replace=random_password.bff_shared_secret`): one apply gives both apps the new value. Until
# both run with the same value the api ignores the BFF's statement and attributes GUI attempts
# to the frontend replica, as it did before this secret existed; nothing fails because of the
# mismatch itself.
resource "random_password" "bff_shared_secret" {
  length  = 48
  special = false
}

locals {
  # The identity provider's endpoints: an explicit input wins, otherwise derived from
  # oidc_tenant_id for a single-tenant Entra registration, otherwise null (and the oidc
  # validation in variables.tf has already refused that combination).
  oidc_tenant_base     = var.oidc_tenant_id == null ? null : "https://login.microsoftonline.com/${var.oidc_tenant_id}"
  oidc_authority       = var.oidc_authority != null ? var.oidc_authority : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/v2.0")
  oidc_allowed_issuers = var.oidc_allowed_issuers != null ? var.oidc_allowed_issuers : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/v2.0")
  oidc_jwks_uri        = var.oidc_jwks_uri != null ? var.oidc_jwks_uri : (local.oidc_tenant_base == null ? null : "${local.oidc_tenant_base}/discovery/v2.0/keys")
  oidc_audience        = var.oidc_audience != null ? var.oidc_audience : var.oidc_client_id

  # With a custom domain the BFF callback is known before any apply: the hostname the install is
  # served on, which oidc_redirect_uri may not contradict (variables.tf). Without one it is the
  # input, set from frontend_url on the second apply.
  oidc_redirect_uri = local.frontend_custom_hostname != null ? "https://${local.frontend_custom_hostname}/api/auth/callback" : var.oidc_redirect_uri

  # Break-glass admits an address that already holds the Owner role, and the first Owner is
  # initial_owner_email, so that is the default once a hash arms it. The presence test is
  # unmarked (the hash is sensitive, whether one was given is not), as for the secret names.
  breakglass_owner_email = var.breakglass_owner_email != null ? var.breakglass_owner_email : (
    nonsensitive(var.breakglass_secret_hash != null) ? var.initial_owner_email : null
  )
}

locals {
  # Identity (ADR 0024): the binding plus, on oidc, the backend's token-verification
  # config. The BFF client half lives on the frontend below; the client secret and the
  # break-glass hash travel as Container App secrets, never plain env.
  identity_env = merge(
    { MASTERLY_IDENTITY_BINDING = var.identity_binding },
    var.identity_binding == "oidc" ? {
      MASTERLY_OIDC_ALLOWED_ISSUERS = local.oidc_allowed_issuers
      MASTERLY_OIDC_AUDIENCE        = local.oidc_audience
      MASTERLY_OIDC_JWKS_URI        = local.oidc_jwks_uri
    } : {},
    local.breakglass_owner_email != null ? { MASTERLY_BREAKGLASS_OWNER_EMAIL = local.breakglass_owner_email } : {},
  )

  # The servicebus binding when enabled (ADR 0029). DefaultAzureCredential resolves the
  # app's user-assigned identity via AZURE_CLIENT_ID.
  servicebus_env = var.enable_service_bus ? {
    MASTERLY_BUS_BINDING          = "servicebus"
    MASTERLY_SERVICEBUS_NAMESPACE = azurerm_servicebus_namespace.this[0].name
    MASTERLY_SERVICEBUS_QUEUE     = azurerm_servicebus_queue.jobs[0].name
    AZURE_CLIENT_ID               = module.apps_identity.client_id
  } : {}

  # Install identity + mode (ADR 0039/0066): org/install ids are cross-checked against
  # the license sub claim in production; allowed_regions gates Environment creation in
  # every mode.
  install_env = merge(
    {
      MASTERLY_MODE            = var.mode
      MASTERLY_REGION          = var.masterly_region
      MASTERLY_ORG_ID          = var.org_id
      MASTERLY_INSTALL_ID      = var.install_id
      MASTERLY_ALLOWED_REGIONS = join(",", local.allowed_regions)
    },
    var.org_name != null ? { MASTERLY_ORG_NAME = var.org_name } : {},
    var.initial_owner_email != null ? { MASTERLY_INITIAL_OWNER_EMAIL = var.initial_owner_email } : {},
    # The durable control-plane store (Environments/memberships survive restarts).
    var.mode == "production" ? { MASTERLY_CONTROLPLANE_STORE = "postgres" } : {},
    # Demo's in-memory control plane seeds these beside its fixtures at every start. Written
    # only when the list is non-empty: an empty list is the absence of the setting, so an
    # install that does not set it plans exactly as before. demo_environments is refused off
    # mode = "demo", and the migrate job exists only on mode = "production" (migrate.tf), so
    # the job's own env never needs it.
    length(var.demo_environments) > 0 ? {
      MASTERLY_DEMO_ENVIRONMENTS = join(",", var.demo_environments)
    } : {},
  )

  # The egress guard's install-wide posture (SSRF; core/egress in the api image). The guard
  # refuses a customer-configured outbound target that resolves to a private or reserved
  # address on mode=production, which is what a BYO-DB Environment on a private network runs
  # into; the allowlist names the ranges it may connect into instead. Each variable is written
  # only when its input is set: an empty list and a false flag are the ABSENCE of a setting,
  # leaving the application's own mode-gated posture (demo allows, production refuses) exactly
  # as it is, so upgrading to a version that has these inputs changes nothing for an install
  # that does not set them. This is the durable form of the setting — a value put on the app
  # out of band with `az containerapp update` is removed again by the next apply, because the
  # module owns the container's environment and deliberately does not ignore drift in it.
  # The two are never both written: allowed_private_egress_cidrs refuses that at plan.
  private_egress_env = merge(
    length(var.allowed_private_egress_cidrs) > 0 ? {
      MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS = join(",", var.allowed_private_egress_cidrs)
    } : {},
    var.allow_private_egress ? { MASTERLY_ALLOW_PRIVATE_EGRESS = "true" } : {}, # deprecated
  )

  # The api's public base URL (ADR 0092): the address something outside the install calls the
  # api on. One setting under one name for all three apps — the frontend shows it in the
  # catalog's Consume card, the api and the workers build an external step's callback URL from
  # it. Written only when the input is set, like the egress allowlist above: unset is the
  # absence of a setting, so an install that does not set it plans exactly as before. Trailing
  # slashes are dropped so that appending "/v1/..." never yields a double slash.
  public_api_url_env = var.public_api_url != null ? {
    MASTERLY_PUBLIC_API_URL = replace(var.public_api_url, "/\\/+$/", "")
  } : {}

  # Trusting a private CA (MAS-446): the allowlist above says WHERE the application may
  # connect; this says whether it TRUSTS what answers there. A CA bundle is file-shaped, not
  # env-shaped, so it rides the secret-backed file mount below (modules/aca-container-app
  # secret_file_mounts — an EmptyDir volume plus an init container, since the provider has no
  # Secret-backed volume type; see that module's main.tf) rather than a value straight in env.
  # It gets the same durability guarantee every other part of the container's template
  # already has here: Terraform owns it, and ignore_changes carves out only the image and
  # workload_profile_name. The single env var lives here because both apps need to know the
  # PATH the file landed at.
  ca_bundle_mount_dir  = "/mnt/secrets/ca-bundle"
  ca_bundle_file_name  = "ca-bundle.pem"
  ca_bundle_mount_path = "${local.ca_bundle_mount_dir}/${local.ca_bundle_file_name}"

  ca_bundle_env = var.ca_bundle_pem != null ? {
    SSL_CERT_FILE = local.ca_bundle_mount_path
  } : {}

  # One mount, named after the app secret that holds the bundle's content — reused verbatim on
  # ca-workers so the mount is identical on both apps that read SSL_CERT_FILE.
  #
  # prepend_image_ca_bundle = true: the file this produces is ADDITIVE, not a replacement.
  # ca_bundle_pem is meant to carry only the customer's own internal CA(s) -- typically a
  # kilobyte or two -- not a copy of the public roots the image already trusts. Without this,
  # SSL_CERT_FILE would point at a file containing ONLY var.ca_bundle_pem's content, and every
  # other outbound TLS call the install makes (telemetry, licence refresh, ACS email) would
  # start failing certificate verification the moment the apply landed, because those targets
  # present publicly-trusted certificates the customer's bundle knows nothing about. It also
  # keeps ca_bundle_pem itself small enough to live in a Key Vault secret (Azure's documented
  # 25 KB maximum) on a production install, where enable_key_vault is required -- the image's
  # own bundle is a couple hundred KB on its own and never needs to travel through Key Vault to
  # get here, since the init container reads it straight off its own filesystem.
  ca_bundle_secret_file_mounts = var.ca_bundle_pem != null ? {
    "ca-bundle" = {
      mount_path              = local.ca_bundle_mount_dir
      file_name               = local.ca_bundle_file_name
      secret_name             = "ca-bundle-pem"
      prepend_image_ca_bundle = true
    }
  } : {}

  api_env = merge(
    local.install_env,
    local.identity_env,
    local.private_egress_env, # the egress guard's allowlist (and deprecated override), empty unless set
    local.public_api_url_env, # the api's public base URL, empty unless set
    local.ca_bundle_env,      # SSL_CERT_FILE, pointed at the mounted bundle, empty unless set
    local.servicebus_env,
    local.acs_email_env,          # ACS endpoint + sender auto-wired when email is enabled (ADR 0040)
    local.keyvault_env,           # durable secret store when the Key Vault is enabled (ADR 0066)
    local.redis_env,              # redis session registry when Redis is enabled (ADR 0066)
    local.entra_auth_env,         # Entra token authentication to Postgres / Redis, empty unless "entra"
    local.workers_inprocess_env,  # the api hands the loop to ca-workers when enabled (ADR 0066)
    local.install_credential_env, # the install credential, shared by refresh and telemetry
    local.telemetry_env,          # usage reporting to the control plane, off unless configured
    local.license_refresh_env,    # daily licence refresh from the control plane (ADR 0074), off unless configured
    # The license verification key (ADR 0013) is public material — plain env.
    var.license_public_jwk != null ? { MASTERLY_LICENSE_PUBLIC_JWK = var.license_public_jwk } : {},
    # The backup horizon an erasure's completion record states (ADR 0081): how long a
    # deleted record can still exist in the starter server's backups. Set only when this
    # module provisions the database, because only then does it know the retention. On
    # BYO-DB it stays unset and the record says your own backup policy governs.
    local.provision_postgres ? {
      MASTERLY_ERASURE_BACKUP_RETENTION_DAYS = tostring(var.postgres_backup_retention_days)
    } : {},
    # Transaction pooling (MAS-1615): the backend needs to be told, or it fails through the pooler.
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_POOLER = "transaction" } : {},
    # With migrations = "job", migrations run in the migrate job (migrate.tf, ADR 0120) and the
    # api and the workers only check the schema stamps. Unset otherwise: the image's own default,
    # migrating at start, as before.
    local.migrate_job ? { MASTERLY_MIGRATIONS = "job" } : {},
  )

  # ca-workers reads the api's env contract (workers.tf). Where it runs as its own identity
  # (local.workers_own_identity, workers.tf), its AZURE_CLIENT_ID, which the Key Vault, Service Bus
  # and Entra settings above set to the apps identity's, is that identity's instead. Merged last,
  # so it is the only value.
  workers_env = merge(
    local.api_env,
    local.workers_own_identity ? { AZURE_CLIENT_ID = module.workers_identity[0].client_id } : {},
  )

  # --- The install's secret material -----------------------------------------------
  #
  # Named first, valued second, and deliberately in that order: everything downstream —
  # which app carries which secret, what gets written to the vault, what the plan shows —
  # is driven by the NAME lists, which are plain strings. Deriving those lists from the
  # value maps instead would make `for_each` and every precondition operate on a
  # sensitive collection, which Terraform refuses outright.
  #
  # One catalogue of values, indexed only by a name that one of the lists below admits.
  # Entries whose input is unset are simply never named (indexing an absent name is a
  # plan-time error, which is the guard).
  secret_values = {
    "database-url"            = local.database_url
    "database-direct-url"     = local.database_direct_url
    "session-secret"          = random_password.session_secret.result
    "session-secret-previous" = var.session_secret_previous
    "bff-shared-secret"       = random_password.bff_shared_secret.result
    "registry-password"       = local.registry_password
    "redis-url"               = local.redis_url # embeds the access key on redis_auth = "key" (ADR 0066)
    "license-token"           = var.license_token
    "breakglass-secret-hash"  = var.breakglass_secret_hash
    "telemetry-client-secret" = var.telemetry_client_secret
    "oidc-client-secret"      = var.oidc_client_secret
    # Built-in auth's client secret (builtin-auth.tf), under the name Azure gives it.
    "microsoft-provider-authentication-secret" = var.builtin_auth_client_secret
    # Not confidential (see ca_bundle_pem's description) — it travels through the SAME
    # Container App secret plumbing as everything else here only because that plumbing is
    # also how a value reaches the file mount below (secret_file_mounts, MAS-446), not
    # because it needs hiding.
    "ca-bundle-pem" = var.ca_bundle_pem

    # The migrate job's own DSNs (migrate.tf), named only in migrate_secret_names: never in the
    # backend_*, api_* or frontend_* lists, so no Container App carries them.
    "migrate-database-url"        = local.migrate_database_url
    "migrate-database-direct-url" = local.migrate_database_direct_url

    # Each backend app's own DSNs with the app roles: the api's named only in api_secret_names,
    # the workers' only in backend_secret_names, so neither app carries the other's.
    "api-database-url"            = local.api_database_url
    "api-database-direct-url"     = local.api_database_direct_url
    "workers-database-url"        = local.workers_database_url
    "workers-database-direct-url" = local.workers_database_direct_url
  }

  # Credential-based image pull (ADR 0067): in the token mode the SP secret rides on every app
  # that pulls; the identity modes carry none.
  registry_secret_names = local.registry_token_mode ? ["registry-password"] : []

  # The secrets ca-workers carries, which builds the same services from the same settings as
  # ca-api (workers.tf): its DSNs, then the set both backend processes share
  # (backend_shared_secret_names).
  backend_secret_names = concat(
    [local.workers_database_secret_name, "session-secret"],
    # The direct (non-pooled) DSN, named only with the pooler: var.postgres_pgbouncer is a plain bool.
    var.postgres_pgbouncer ? [local.workers_database_direct_secret_name] : [],
    local.backend_shared_secret_names,
  )

  # nonsensitive() on the PRESENCE tests, not on any value: `var.license_token != null` is a
  # bool derived from a sensitive variable, so Terraform marks it, and a marked list cannot
  # drive for_each (the vault writes) or a precondition. Whether a licence was supplied is not
  # the secret — the same narrow unmarking, for the same reason, as redis_url_wired.
  backend_shared_secret_names = concat(
    # Only while a rotation is in flight; unset is the steady state (see the variable).
    nonsensitive(var.session_secret_previous != null) ? ["session-secret-previous"] : [],
    local.registry_secret_names,
    local.redis_secret_names,
    nonsensitive(var.license_token != null) ? ["license-token"] : [],
    nonsensitive(var.breakglass_secret_hash != null) ? ["breakglass-secret-hash"] : [],
    local.install_credential_configured ? ["telemetry-client-secret"] : [],
    var.ca_bundle_pem != null ? ["ca-bundle-pem"] : [],
  )

  # The api carries its own DSNs (the same as ca-workers' without the app roles) and the shared
  # set, and adds the BFF shared secret, which belongs to the api and the frontend alone
  # (random_password.bff_shared_secret). ca-workers serves no request, so it does not get it.
  api_secret_names = concat(
    [local.api_database_secret_name, "session-secret"],
    var.postgres_pgbouncer ? [local.api_database_direct_secret_name] : [],
    local.backend_shared_secret_names,
    ["bff-shared-secret"],
    local.builtin_auth_secret_names,
  )

  # The BFF shared secret on every install. On oidc the frontend is also the confidential BFF
  # client: its client secret is used only server-side at token exchange.
  frontend_secret_names = concat(
    ["bff-shared-secret"],
    local.registry_secret_names,
    var.identity_binding == "oidc" ? ["oidc-client-secret"] : [],
    local.builtin_auth_secret_names,
  )

  backend_secrets  = { for name in local.backend_secret_names : name => local.secret_values[name] }
  api_secrets      = { for name in local.api_secret_names : name => local.secret_values[name] }
  frontend_secrets = { for name in local.frontend_secret_names : name => local.secret_values[name] }

  # The env ca-workers reads from its secrets: its own DSNs and the shared set. The api's names
  # its own DSNs and adds the BFF shared secret below.
  backend_env_secret_refs = merge(
    { MASTERLY_DATABASE_URL = local.workers_database_secret_name },
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_DIRECT_URL = local.workers_database_direct_secret_name } : {},
    local.backend_shared_env_secret_refs,
  )

  backend_shared_env_secret_refs = merge(
    { MASTERLY_SESSION_SECRET = "session-secret" },
    # nonsensitive() on the PRESENCE test alone, as above: whether a rotation is in flight is
    # not the secret, and it is what decides whether the api is told to accept a second key.
    nonsensitive(var.session_secret_previous != null) ? {
      MASTERLY_SESSION_SECRET_PREVIOUS = "session-secret-previous"
    } : {},
    local.redis_secret_refs,
    var.license_token != null ? { MASTERLY_LICENSE_TOKEN = "license-token" } : {},
    var.breakglass_secret_hash != null ? { MASTERLY_BREAKGLASS_SECRET_HASH = "breakglass-secret-hash" } : {},
    local.install_credential_configured ? { MASTERLY_TELEMETRY_CLIENT_SECRET = "telemetry-client-secret" } : {},
  )

  api_env_secret_refs = merge(
    { MASTERLY_DATABASE_URL = local.api_database_secret_name },
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_DIRECT_URL = local.api_database_direct_secret_name } : {},
    local.backend_shared_env_secret_refs,
    { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret" },
  )

  # The same name on the frontend, from the same generated value: the two apps agree on it
  # because one apply sets both.
  frontend_env_secret_refs = merge(
    { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret" },
    var.identity_binding == "oidc" ? { MASTERLY_OIDC_CLIENT_SECRET = "oidc-client-secret" } : {},
  )

  # The install credential (telemetry_client_id / _secret) is the install service account
  # that authenticates BOTH licence refresh and fleet telemetry, so it reaches the apps
  # whenever it is set — the preconditions refuse it set without a feature that uses it.
  install_credential_configured = var.telemetry_client_id != null

  install_credential_env = local.install_credential_configured ? {
    MASTERLY_TELEMETRY_CLIENT_ID = var.telemetry_client_id
  } : {}

  # Fleet telemetry: the application gates reporting (the usage ledger and the install
  # snapshot) on the URL AND the client id, so the URL is the switch. Without it the
  # credential can be present for licence refresh and nothing is reported.
  telemetry_configured = var.telemetry_url != null && local.install_credential_configured

  telemetry_env = local.telemetry_configured ? {
    MASTERLY_TELEMETRY_URL = var.telemetry_url
  } : {}

  # Licence refresh (ADR 0074): the URL is the only refresh-specific input — the credential is
  # the install service account above, which the precondition requires alongside it. The
  # application additionally requires a verifiable licence (license_token + license_public_jwk)
  # before it switches refresh on. telemetry_url plays no part in it.
  license_refresh_configured = var.license_issuer_url != null && local.install_credential_configured

  license_refresh_env = local.license_refresh_configured ? {
    MASTERLY_LICENSE_ISSUER_URL = var.license_issuer_url
  } : {}
}

# --- Per-app CPU and memory (app_resources) -----------------------------------------
#
# Either attribute alone determines the other, because Container Apps accepts only the ratio
# 1 vCPU : 2 GiB (the variable's validations refuse any other pair). An app that is not
# listed gets 0.5 vCPU / 1Gi, the size every app ran at before the input existed, so an
# install that does not set it plans no change to any app's size.
locals {
  app_resources = {
    for app in ["api", "frontend", "workers"] : app => {
      cpu = coalesce(
        try(var.app_resources[app].cpu, null),
        try(tonumber(trimsuffix(var.app_resources[app].memory, "Gi")) / 2, null),
        0.5,
      )
      memory = coalesce(
        try(var.app_resources[app].memory, null),
        try("${var.app_resources[app].cpu * 2}Gi", null),
        "1Gi",
      )
    }
  }
}

# --- The api (internal ingress: only the frontend's BFF reaches it) ---------------

module "api" {
  source = "./modules/aca-container-app"

  name                = "ca-api"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = local.api_image

  acr_login_server           = local.registry_server
  user_assigned_identity_ids = [module.apps_identity.id]

  registry_username             = local.registry_username
  registry_password_secret_name = local.registry_password_secret_name

  # Internal by default: the api sits behind the frontend's BFF and nothing outside the
  # environment needs it. Opt out when something must call /v1 directly — the published
  # Python SDK talks to the api, not through the BFF (the BFF proxies /api/proxy/... with
  # session COOKIES and short-circuits unauthenticated requests without forwarding, so it is
  # not a substitute for a bearer-token client). Until this input existed, an install could
  # not be reached by the SDK we publish and document.
  ingress_external    = var.api_ingress_external
  ingress_target_port = 8001

  # Plain HTTP is allowed only while the api is unreachable from outside the environment.
  #
  # `allowInsecure` is one app-wide flag — Azure has no way to say "HTTPS-only for callers
  # outside, plain HTTP for the hop inside" — so it has to follow the wider of the two
  # surfaces. Left true on a published api it would leave port 80 answering, without a
  # redirect, for allowlisted callers holding a BEARER TOKEN: an allowlist bounds who can
  # reach it, not what a network in between can read, and the token is the whole credential.
  #
  # False means Azure's edge proxy redirects http:// to https:// (301) instead of serving it.
  # Ingress settings apply to every revision at once and generate no new revision, so this
  # costs no roll on an existing install.
  #
  # The in-environment hop is not left plaintext in exchange: module.aca_env encrypts it at
  # the environment level (mutual_tls_enabled), which is why MASTERLY_API_BASE_URL below
  # stays http://ca-api rather than moving to https:// — an app-name call cannot present a
  # hostname the environment's certificate matches, so https://ca-api would fail
  # verification. Azure encrypts that hop underneath the http:// scheme instead.
  ingress_allow_insecure = !var.api_ingress_external

  # The SAME allowlist the frontend gets. Until api_ingress_external existed this list was
  # frontend-only, which was fine while the api was unreachable — exposing it without also
  # narrowing it would have shipped a wide-open /v1 as the price of SDK access, which is a
  # worse problem than the one being solved. Empty stays UNRESTRICTED (Azure's semantics),
  # so a plan-time guard below refuses external api ingress with an empty list.
  ingress_allowed_ip_security_restrictions = var.api_ingress_external ? [
    for index, cidr in var.ingress_allowed_cidrs : {
      name             = "allow-${index}"
      ip_address_range = cidr
      action           = "Allow"
    }
  ] : []

  # Defaults to a single replica: with the in-memory session registry a second replica
  # would drop sessions mid-flight. api_max_replicas > 1 requires enable_redis
  # (validation on the variable). min 0 = scale-to-zero cost posture (validations on
  # the variable spell out what an idle stop drops).
  min_replicas = var.api_min_replicas
  max_replicas = var.api_max_replicas

  cpu    = local.app_resources.api.cpu
  memory = local.app_resources.api.memory

  env                = local.api_env
  secrets            = local.api_value_secrets
  secret_refs        = local.api_vault_secret_refs
  env_secret_refs    = local.api_env_secret_refs
  secret_file_mounts = local.ca_bundle_secret_file_mounts

  liveness_probe_path  = "/healthz"
  readiness_probe_path = "/readyz"

  # These five reverse an earlier decision, and the reversal was paid for in production.
  #
  # The api used to keep Azure's probe defaults deliberately: setting tolerances re-renders its
  # container template, which rolls the api once on every live install's next apply. That cost
  # is real. It is also bounded, visible in the plan, and one-time.
  #
  # The cost of the other side was not bounded. A DECLARED probe defaults to a 1s timeout and 3
  # failures — far tighter than the 5s/48 that apply when no probe is declared — and /readyz
  # opens Postgres, Redis, and Key Vault behind private endpoints. On 2026-08-31 the v0.133.0
  # roll produced ca-api--0000135 ActivationFailed, holding 100% of traffic with zero replicas
  # while the previous revision logged "Probe of Readiness failed with timeout in 1 seconds"
  # 71 times running. The demo api was down. Nothing about that was specific to the demo:
  # mode=production requires api_max_replicas >= 2, so every replica start runs the same race
  # against a cold database, and a customer's first apply is its worst case.
  #
  # The frontend block below already states the principle this violates — "declaring an HTTP
  # readiness probe is not the safe half of a trade". The api declares one. It needed the same
  # treatment, and the template-churn argument was the wrong thing to optimise.
  #
  # Budget: 5 + 48 x 10 = 485s of CONTINUOUS failure before the replica is pulled, matching the
  # frontend so a cold api cannot outlive the gate waiting on it. revision_mode is Single and
  # ACA shifts traffic only after readiness succeeds, so a genuinely broken revision still never
  # serves — the threshold governs restart timing, not correctness.
  readiness_probe_initial_delay           = 5
  readiness_probe_interval_seconds        = 10
  readiness_probe_timeout                 = 8
  readiness_probe_failure_count_threshold = 48
  readiness_probe_success_count_threshold = 1

  # Liveness asks only "is the process alive", and a failure restarts it, so its budget is
  # generous: a slow moment must never restart a healthy process. The api does not listen until
  # its startup (including control-plane migrations) completes, so this budget also covers a
  # slow start. 5 + 24 x 20 = 485s, the same as readiness, so neither probe is the tighter one.
  liveness_probe_initial_delay           = 5
  liveness_probe_interval_seconds        = 20
  liveness_probe_timeout                 = 10
  liveness_probe_failure_count_threshold = 24

  tags = local.tags

  # The api connects at boot (readyz): the private endpoints + DNS must exist first, and the
  # Service Bus role grants must land before the in-process worker opens a receiver.
  depends_on = [
    # The :6432 URL must not reach a revision before PgBouncer listens and the NSG admits it.
    azurerm_postgresql_flexible_server_configuration.pgbouncer,
    azurerm_network_security_group.private_endpoints,
    azurerm_private_endpoint.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.redis,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    # With registry_private_endpoint, the first image pull already takes the private path.
    azurerm_private_endpoint.registry,
    azurerm_private_dns_zone_virtual_network_link.registry,
    # The app secrets grant exists before this app's update; on an upgrade it replaces the
    # Secrets Officer grant at the same address (keyvault.tf).
    azurerm_role_assignment.kv_app_secrets,
    azurerm_role_assignment.sb_sender,
    azurerm_role_assignment.sb_receiver,
    # On "entra" the api authenticates as its identity at boot, so the database role and the
    # Redis access policy must exist before a revision starts. On an install where ca-workers
    # moves to its own identity, the same edges make Terraform destroy sb_receiver only after this
    # app's update, and on one moving to migrations = "job" the apps administrator too: keep them.
    azurerm_postgresql_flexible_server_active_directory_administrator.apps,
    azurerm_managed_redis_access_policy_assignment.apps,
    azurerm_redis_cache_access_policy_assignment.apps,
    azurerm_private_endpoint.servicebus,
    azurerm_private_dns_zone_virtual_network_link.servicebus,
    # MASTERLY_MIGRATIONS = job: the migrate job's execution has started before a revision
    # does (migrate.tf).
    azapi_resource_action.migrate_start,
  ]
}
