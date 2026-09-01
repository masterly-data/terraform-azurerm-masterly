# The Masterly self-hosted install (Layer 5): one region-pinned install of the product
# application — the same images every deployment model runs (ADR 0002/0018).
#
# Shape: VNet-integrated ACA environment + api (internal ingress) + frontend (public
# ingress, optional IP allowlist) + the data plane — either the provisioned starter
# Postgres Flexible Server (private-endpoint-only) or the customer's own database via
# external_database_url (BYO-DB, ADR 0065; the api provisions one database per Masterly
# Environment at first touch either way, ADR 0003). Identity is dev (evaluation,
# allowlist-required) or the customer's OIDC IdP (ADR 0024); the license JWT (ADR 0013)
# arrives as an input. Secrets are born here or arrive as sensitive inputs and live as
# Container App secrets; nothing per-install is baked into images.
#
# Deliberately deferred (-> later): Key Vault-backed secrets, Redis (until then the api
# is pinned to one replica — the session registry is in-memory), the dedicated workers
# service, custom domains, the per-install Entra identity of ADR 0020 (the install does
# not call Masterly's control plane yet).

locals {
  rg_aca_name  = "rg-${var.name_prefix}-aca"
  rg_data_name = "rg-${var.name_prefix}-data"

  # ADR 0039: every resource carries the Install + Organization identity (cost attribution,
  # the Org-level Install registry). Tag changes apply in-place — no resource replacement.
  tags = merge(var.tags, {
    "install-id" = var.install_id
    "org-id"     = var.org_id
  })

  # Subnet layout: derived from the first VNet prefix (the /16-default layout the demo
  # runs: first /23 for the runtime, the /24 at index 4 for private endpoints) unless
  # explicit prefixes are supplied (enterprise IPAM allocations smaller than /21).
  vnet_prefix_bits = tonumber(split("/", var.vnet_address_space[0])[1])
  aca_subnet_prefix = var.aca_subnet_prefix != null ? var.aca_subnet_prefix : (
    cidrsubnet(var.vnet_address_space[0], 23 - local.vnet_prefix_bits, 0)
  )
  private_endpoints_subnet_prefix = var.private_endpoints_subnet_prefix != null ? var.private_endpoints_subnet_prefix : (
    cidrsubnet(var.vnet_address_space[0], 24 - local.vnet_prefix_bits, 4)
  )

  # --- Network: create the VNet, or join one the platform team already owns -------------
  # Three topologies the module has to serve without a fork (docs/networking.md):
  #   1. public ingress behind an IP allowlist   — the default; module owns the VNet
  #   2. private ingress, reached over VPN/ER    — internal LB, no public endpoint
  #   3. hub-and-spoke landing zone              — subnets injected, module owns no network
  # Injection is all-or-nothing: a half-injected network is a topology nobody asked for and
  # every combination of it would need its own test matrix.
  inject_network = var.aca_subnet_id != null

  aca_subnet_id               = local.inject_network ? var.aca_subnet_id : azurerm_subnet.aca[0].id
  private_endpoints_subnet_id = local.inject_network ? var.private_endpoints_subnet_id : azurerm_subnet.private_endpoints[0].id

  # Private DNS links need the VNet, and an injected subnet id already carries it:
  # /subscriptions/../virtualNetworks/<vnet>/subnets/<subnet>. Derived rather than asked
  # for, so the two can never disagree.
  virtual_network_id = local.inject_network ? regex("^(.*)/subnets/[^/]+$", var.aca_subnet_id)[0] : azurerm_virtual_network.this[0].id

  # --- Data residency: check the promise against where the resources actually land ------
  # `location` (an Azure region) and `masterly_region` (a Masterly geo, ADR 0022) were
  # independent inputs that nothing reconciled, so an install could sit in Sweden and declare
  # itself "us" — or, on the old ["eu","us"] default for allowed_regions, accept a "us"
  # Environment whose data lands in Sweden. Region pinning is a promise customers repeat in
  # contracts and auditors read back, so it is checked rather than trusted.
  #
  # UK and Switzerland are deliberately ABSENT, not forgotten: neither is in the EU, and
  # whether either satisfies an "eu" residency commitment is a legal question this module
  # must not answer by omission. Declare it with location_geo and own the decision.
  location_geo_map = {
    swedencentral      = "eu"
    westeurope         = "eu"
    northeurope        = "eu"
    germanywestcentral = "eu"
    francecentral      = "eu"
    norwayeast         = "eu"
    polandcentral      = "eu"
    italynorth         = "eu"
    spaincentral       = "eu"
    eastus             = "us"
    eastus2            = "us"
    centralus          = "us"
    northcentralus     = "us"
    southcentralus     = "us"
    westcentralus      = "us"
    westus             = "us"
    westus2            = "us"
    westus3            = "us"
  }
  # Azure accepts "Sweden Central" and "swedencentral" interchangeably.
  location_key = lower(replace(var.location, " ", ""))
  install_geo  = var.location_geo != null ? var.location_geo : lookup(local.location_geo_map, local.location_key, null)

  # One install is one data plane in one location, so the only geo whose data it can hold is
  # its own. Defaulting to that makes the safe configuration the automatic one.
  allowed_regions = var.allowed_regions != null ? var.allowed_regions : [var.masterly_region]

  # Data plane seam (ADR 0065): BYO-DB when the customer supplies a DSN, otherwise the
  # provisioned starter server.
  provision_postgres = var.external_database_url == null
  # A landing zone may centralize the privatelink zone (postgres_private_dns_zone_id);
  # only create one when we provision the server and none is injected.
  create_postgres_dns  = local.provision_postgres && var.postgres_private_dns_zone_id == null
  postgres_dns_zone_id = local.provision_postgres ? (var.postgres_private_dns_zone_id != null ? var.postgres_private_dns_zone_id : azurerm_private_dns_zone.postgres[0].id) : null
}

# A stable per-install suffix for the globally-unique Postgres server name.
resource "random_string" "install" {
  length  = 6
  lower   = true
  upper   = false
  special = false
}

# --- Resource groups (customer naming: rg-masterly-<purpose>) -----------------

resource "azurerm_resource_group" "aca" {
  name     = local.rg_aca_name
  location = var.location
  tags     = local.tags

  # The first resource of the install, so a residency mismatch is refused at plan — before
  # any resource exists, and long before an Environment records a region it cannot honour.
  lifecycle {
    precondition {
      condition     = local.install_geo != null
      error_message = "This module does not know which Masterly geo the Azure location \"${var.location}\" belongs to, so it cannot check the install's data-residency claim. Set location_geo to the geo whose residency this location actually satisfies (\"eu\" or \"us\") — a deliberate statement, because for locations outside the EU and the US (UK, Switzerland, and others) that is a legal question, not a lookup."
    }

    precondition {
      condition     = local.install_geo == null || local.install_geo == var.masterly_region
      error_message = "Data-residency mismatch: this install declares masterly_region = \"${var.masterly_region}\", but every resource is created in Azure location \"${var.location}\", which is geo \"${local.install_geo == null ? "unknown" : local.install_geo}\". The declared geo is what customers are told and what the app stamps on usage records; the location is where the data actually sits. Change one to match the other — or, if this location genuinely satisfies that residency commitment, say so explicitly with location_geo."
    }

    precondition {
      condition     = (var.aca_subnet_id == null) == (var.private_endpoints_subnet_id == null)
      error_message = "aca_subnet_id and private_endpoints_subnet_id go together: either the module builds the whole network, or the platform team supplies both subnets. Half of an injected network is a topology nobody asked for."
    }

    precondition {
      condition     = var.aca_subnet_id == null || var.aca_subnet_id != var.private_endpoints_subnet_id
      error_message = "aca_subnet_id and private_endpoints_subnet_id must be different subnets: the ACA subnet is delegated to Microsoft.App/environments, and Azure refuses private endpoints in a delegated subnet."
    }

    precondition {
      condition     = var.frontend_ingress_external || !var.aca_internal_load_balancer
      error_message = "aca_internal_load_balancer with frontend_ingress_external = false leaves the frontend reachable from nothing outside the environment — not over VPN either. On an internal environment `external` already means \"reachable from the VNet only\", so leave frontend_ingress_external true."
    }

    precondition {
      condition     = local.install_geo == null || alltrue([for r in local.allowed_regions : r == local.install_geo])
      error_message = "allowed_regions is ${jsonencode(local.allowed_regions)}, but this install has exactly one data plane, in geo \"${local.install_geo == null ? "unknown" : local.install_geo}\". Permitting any other geo would let someone create an Environment that claims a residency this install cannot honour: its data would land in \"${var.location}\" regardless. Leave allowed_regions unset to permit exactly this install's geo."
    }
  }
}

resource "azurerm_resource_group" "data" {
  name     = local.rg_data_name
  location = var.location
  tags     = local.tags
}

# --- Networking (v0.2): the install runs in its own VNet --------------------------
# The runtime subnet hosts the ACA environment; the endpoints subnet hosts the
# Postgres private endpoint. The database has NO public network presence.

# These three gained `count` when the network became injectable. Without these blocks
# Terraform reads azurerm_subnet.aca -> azurerm_subnet.aca[0] as "destroy one, create
# another" and takes the subnets of every LIVE install with it — the ACA environment's
# infrastructure subnet cannot be replaced under a running environment. The upgrade has
# to be a no-op in state, and this is what makes it one.
moved {
  from = azurerm_virtual_network.this
  to   = azurerm_virtual_network.this[0]
}

moved {
  from = azurerm_subnet.aca
  to   = azurerm_subnet.aca[0]
}

moved {
  from = azurerm_subnet.private_endpoints
  to   = azurerm_subnet.private_endpoints[0]
}

resource "azurerm_virtual_network" "this" {
  count = local.inject_network ? 0 : 1

  name                = "vnet-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

# Consumption-only Container App Environments require /23 or larger, and Azure now
# requires the subnet to be delegated to Microsoft.App/environments (the first apply
# failed with ManagedEnvironmentSubnetDelegationError without it).
resource "azurerm_subnet" "aca" {
  count = local.inject_network ? 0 : 1

  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.aca.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [local.aca_subnet_prefix] # /23 required by consumption-only ACA

  delegation {
    name = "aca-environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  count = local.inject_network ? 0 : 1

  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.aca.name
  virtual_network_name              = azurerm_virtual_network.this[0].name
  address_prefixes                  = [local.private_endpoints_subnet_prefix] # clear of the runtime subnet
  private_endpoint_network_policies = "Disabled"
}

# Private DNS so the server's public FQDN resolves to the private endpoint inside the
# VNet — the application DSN stays unchanged. Skipped when the landing zone injects a
# central zone (postgres_private_dns_zone_id — linking that zone to this VNet is the
# platform team's side) and entirely absent on BYO-DB.
resource "azurerm_private_dns_zone" "postgres" {
  count = local.create_postgres_dns ? 1 : 0

  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count = local.create_postgres_dns ? 1 : 0

  name                  = "pdzl-${var.name_prefix}-postgres"
  resource_group_name   = azurerm_resource_group.aca.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres[0].name
  virtual_network_id    = local.virtual_network_id
  tags                  = local.tags
}

# The conditional refactor (ADR 0065) is a state no-op for existing installs.
moved {
  from = azurerm_private_dns_zone.postgres
  to   = azurerm_private_dns_zone.postgres[0]
}

moved {
  from = azurerm_private_dns_zone_virtual_network_link.postgres
  to   = azurerm_private_dns_zone_virtual_network_link.postgres[0]
}

# --- Observability + the ACA environment ---------------------------------------

module "logs" {
  source = "./modules/log-analytics-workspace"

  name                = "log-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

module "aca_env" {
  source = "./modules/aca-env-consumption"

  name                           = "aca-${var.name_prefix}"
  resource_group_name            = azurerm_resource_group.aca.name
  location                       = var.location
  log_analytics_workspace_id     = module.logs.id
  infrastructure_subnet_id       = local.aca_subnet_id
  internal_load_balancer_enabled = var.aca_internal_load_balancer
  tags                           = local.tags
}

# --- Image-pull identity ---------------------------------------------------------

module "apps_identity" {
  source = "./modules/user-assigned-identity"

  name                = "id-${var.name_prefix}-apps"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# Optional: grant pull on the registry (the deploying principal needs
# roleAssignments/write on the registry's scope — true for the demo install, where
# platform-iac's principal manages the shared registry; customers typically grant
# pull out of band and leave acr_id null).
resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.apps_identity.principal_id
}

# --- Data plane: the starter Postgres Flexible Server (skipped on BYO-DB) --------
# DB-per-Environment lives INSIDE this server: the api's tenancy seam creates
# masterly_dp_<environment> databases at first touch (ADR 0003). With
# external_database_url set (ADR 0065) none of this exists — the customer's own
# Postgres is the data plane and its networking is theirs.

resource "random_password" "postgres_admin" {
  count = local.provision_postgres ? 1 : 0

  length  = 32
  special = false # keeps the DSN URL-safe
}

resource "azurerm_postgresql_flexible_server" "this" {
  count = local.provision_postgres ? 1 : 0

  name                = "psql-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location

  version                       = var.postgres_version
  sku_name                      = var.postgres_sku_name
  storage_mb                    = var.postgres_storage_mb
  administrator_login           = "masterly_admin"
  administrator_password        = random_password.postgres_admin[0].result
  zone                          = null
  public_network_access_enabled = false # reachable only via the private endpoint

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  dynamic "high_availability" {
    for_each = var.postgres_zone_redundant_ha ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = local.tags

  lifecycle {
    # Both of these are ASSIGNED BY AZURE at creation and absent from this configuration, so
    # without ignoring them every later plan proposes setting them to null — and Azure refuses:
    #
    #   Error: an existing `high_availability.0.standby_availability_zone` can only be changed
    #   when exchanged with the zone specified in `zone`
    #
    # `zone` was already ignored here. `standby_availability_zone` was not, and it is inside the
    # dynamic high_availability block, which is why it was easy to miss — a ZoneRedundant server
    # gets a standby zone whether or not the configuration mentions one.
    #
    # The consequence was total: the FIRST apply succeeds, and every apply after it fails. The
    # documented production bring-up is two applies, so a customer could not even finish the
    # install, let alone upgrade. Found on the first production rehearsal, 2026-09-01.
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

# The server's only network presence: a private endpoint in the install's VNet. The
# private DNS zone maps the server's FQDN to this endpoint, so the application DSN is
# identical to the public-path one.
resource "azurerm_private_endpoint" "postgres" {
  count = local.provision_postgres ? 1 : 0

  name                = "pe-${var.name_prefix}-postgres"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-postgres"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this[0].id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "postgres"
    private_dns_zone_ids = [local.postgres_dns_zone_id]
  }

  tags = local.tags
}

moved {
  from = random_password.postgres_admin
  to   = random_password.postgres_admin[0]
}

moved {
  from = azurerm_postgresql_flexible_server.this
  to   = azurerm_postgresql_flexible_server.this[0]
}

moved {
  from = azurerm_private_endpoint.postgres
  to   = azurerm_private_endpoint.postgres[0]
}

# --- Async bus: Azure Service Bus (optional; ADR 0029) ---------------------------
# Default off — the install runs the polling binding (the Postgres queue is the bus), so
# nothing here is provisioned or billed. When enabled, a namespace + queue are created and
# the app identity is granted data-plane send + receive (managed identity only; SAS off).

resource "azurerm_servicebus_namespace" "this" {
  count = var.enable_service_bus ? 1 : 0

  name                = "sb-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  sku                 = var.servicebus_sku
  local_auth_enabled  = false # managed identity only — no SAS connection strings (ADR 0029)
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "jobs" {
  count = var.enable_service_bus ? 1 : 0

  name         = "masterly-jobs"
  namespace_id = azurerm_servicebus_namespace.this[0].id

  # At-least-once delivery with idempotent handlers (ADR 0029): redeliver on failure,
  # dead-letter past the max delivery count rather than dropping work.
  max_delivery_count                   = 10
  dead_lettering_on_message_expiration = true
}

# The apps' managed identity sends (publish) and receives (the in-process worker) — the two
# least-privilege data-plane roles rather than Data Owner.
resource "azurerm_role_assignment" "sb_sender" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "sb_receiver" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = module.apps_identity.principal_id
}

# --- Application secrets (born in the install, never in Git) ---------------------

resource "random_password" "session_secret" {
  length  = 48
  special = false
}

locals {
  # The install-level DSN (ADR 0003): the customer's own database on BYO-DB (ADR 0065),
  # otherwise the provisioned starter server's admin connection.
  database_url = var.external_database_url != null ? var.external_database_url : (
    "postgresql+asyncpg://masterly_admin:${random_password.postgres_admin[0].result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/postgres?ssl=require"
  )

  # Identity (ADR 0024): the binding plus, on oidc, the backend's token-verification
  # config. The BFF client half lives on the frontend below; the client secret and the
  # break-glass hash travel as Container App secrets, never plain env.
  identity_env = merge(
    { MASTERLY_IDENTITY_BINDING = var.identity_binding },
    var.identity_binding == "oidc" ? {
      MASTERLY_OIDC_ALLOWED_ISSUERS = var.oidc_allowed_issuers
      MASTERLY_OIDC_AUDIENCE        = var.oidc_audience
      MASTERLY_OIDC_JWKS_URI        = var.oidc_jwks_uri
    } : {},
    var.breakglass_owner_email != null ? { MASTERLY_BREAKGLASS_OWNER_EMAIL = var.breakglass_owner_email } : {},
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
  )

  api_env = merge(
    local.install_env,
    local.identity_env,
    local.servicebus_env,
    local.acs_email_env,         # ACS endpoint + sender auto-wired when email is enabled (ADR 0040)
    local.keyvault_env,          # durable secret store when the Key Vault is enabled (ADR 0066)
    local.redis_env,             # redis session registry when Redis is enabled (ADR 0066)
    local.workers_inprocess_env, # the api hands the loop to ca-workers when enabled (ADR 0066)
    # The license verification key (ADR 0013) is public material — plain env.
    var.license_public_jwk != null ? { MASTERLY_LICENSE_PUBLIC_JWK = var.license_public_jwk } : {},
  )

  # Credential-based image pull (ADR 0067): the SP secret rides as a Container App
  # secret on every app that pulls.
  registry_secrets = var.registry_username != null ? { "registry-password" = var.registry_password } : {}

  api_secrets = merge(
    {
      "database-url"   = local.database_url
      "session-secret" = random_password.session_secret.result
    },
    local.registry_secrets,
    local.redis_secrets, # the Redis URL embeds the access key (ADR 0066)
    var.license_token != null ? { "license-token" = var.license_token } : {},
    var.breakglass_secret_hash != null ? { "breakglass-secret-hash" = var.breakglass_secret_hash } : {},
  )

  api_env_secret_refs = merge(
    {
      MASTERLY_DATABASE_URL   = "database-url"
      MASTERLY_SESSION_SECRET = "session-secret"
    },
    local.redis_secret_refs,
    var.license_token != null ? { MASTERLY_LICENSE_TOKEN = "license-token" } : {},
    var.breakglass_secret_hash != null ? { MASTERLY_BREAKGLASS_SECRET_HASH = "breakglass-secret-hash" } : {},
  )
}

# --- The api (internal ingress: only the frontend's BFF reaches it) ---------------

module "api" {
  source = "./modules/aca-container-app"

  name                = "ca-api"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = var.api_image

  acr_login_server           = var.acr_login_server
  user_assigned_identity_ids = [module.apps_identity.id]

  registry_username             = var.registry_username
  registry_password_secret_name = var.registry_username != null ? "registry-password" : null

  ingress_external       = false
  ingress_target_port    = 8001
  ingress_allow_insecure = true # in-environment hop; TLS hardening with VNet later

  # Defaults to a single replica: with the in-memory session registry a second replica
  # would drop sessions mid-flight. api_max_replicas > 1 requires enable_redis
  # (validation on the variable). min 0 = scale-to-zero cost posture (validations on
  # the variable spell out what an idle stop drops).
  min_replicas = var.api_min_replicas
  max_replicas = var.api_max_replicas

  env             = local.api_env
  secrets         = local.api_secrets
  env_secret_refs = local.api_env_secret_refs

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

  tags = local.tags

  # The api connects at boot (readyz): the private endpoints + DNS must exist first, and the
  # Service Bus role grants must land before the in-process worker opens a receiver.
  depends_on = [
    azurerm_private_endpoint.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.redis,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_role_assignment.kv_secrets_officer,
    azurerm_role_assignment.sb_sender,
    azurerm_role_assignment.sb_receiver,
  ]
}

# --- The frontend (public ingress, optionally IP-restricted) -----------------------

module "frontend" {
  source = "./modules/aca-container-app"

  name                = "ca-frontend"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = var.frontend_image

  acr_login_server           = var.acr_login_server
  user_assigned_identity_ids = [module.apps_identity.id]

  registry_username             = var.registry_username
  registry_password_secret_name = var.registry_username != null ? "registry-password" : null

  ingress_external    = var.frontend_ingress_external
  ingress_target_port = 3000

  min_replicas = var.frontend_min_replicas

  ingress_allowed_ip_security_restrictions = [
    for index, cidr in var.ingress_allowed_cidrs : {
      name             = "allow-${index}"
      ip_address_range = cidr
      action           = "Allow"
    }
  ]

  # On oidc the frontend is the confidential BFF client (authorization-code + PKCE): it
  # gets the client config; the client secret rides as a Container App secret and is
  # used only server-side at token exchange.
  env = merge(
    {
      # By SHORT APP NAME, not by FQDN. ACA resolves `http://<app-name>` for any app in the
      # same environment through the same Envoy proxy the FQDN goes through, and it cannot
      # drift. The FQDN can: Azure reported ca-api's ingress fqdn as the INTERNAL form
      # (`ca-api.internal.<env>`) and later as the EXTERNAL form (`ca-api.<env>`) with no
      # config change on our side — terraform saw it as "changed outside of Terraform".
      # That is not cosmetic. The proxy identifies the target app from the request hostname,
      # so an internal-ingress app addressed by the external-form hostname is not found and
      # the proxy answers 404 "This Container App is stopped or does not exist" — which the
      # frontend's BFF then relayed for every /api/auth/login on the live demo.
      MASTERLY_API_BASE_URL = "http://${module.api.name}"
      MASTERLY_REGION       = var.masterly_region
      MASTERLY_IDP_BINDING  = var.identity_binding
    },
    # The frontend refuses to boot on a production build with the dev binding unless this is
    # set — a deliberate guard, and it took the demo's login down: every server-side route
    # threw "Refusing to run: MASTERLY_IDP_BINDING=dev on a production build", so /api/config
    # and /api/auth/login 500'd with empty bodies while the login PAGE still served.
    #
    # Derived rather than a second variable, because the explicit opt-in already exists one
    # level up: identity_binding=dev is a deliberate choice AND is unrepresentable without a
    # non-empty ingress_allowed_cidrs (see variables.tf). A separate flag would add no safety
    # this module does not already enforce, and its absence is a silent outage.
    var.identity_binding == "dev" ? { MASTERLY_ALLOW_DEV_BINDING = "true" } : {},
    var.identity_binding == "oidc" ? merge(
      {
        MASTERLY_OIDC_CLIENT_ID    = var.oidc_client_id
        MASTERLY_OIDC_AUTHORITY    = var.oidc_authority
        MASTERLY_OIDC_REDIRECT_URI = var.oidc_redirect_uri
      },
      var.oidc_scopes != null ? { MASTERLY_OIDC_SCOPES = var.oidc_scopes } : {},
    ) : {},
  )

  secrets = merge(
    local.registry_secrets,
    var.identity_binding == "oidc" ? { "oidc-client-secret" = var.oidc_client_secret } : {},
  )

  env_secret_refs = var.identity_binding == "oidc" ? {
    MASTERLY_OIDC_CLIENT_SECRET = "oidc-client-secret"
  } : {}

  liveness_probe_path  = "/api/healthz"
  readiness_probe_path = "/api/readyz"

  # Wide on purpose. /api/readyz resolves the runtime config and then calls the api's /readyz,
  # which makes it the only check that sees either fault this frontend has actually shipped:
  # a container that boots and then throws on every server-side route (the dev-binding opt-in),
  # and one addressing an api that answers 404 (the drifting FQDN). Liveness sees neither —
  # /api/healthz returns 200 from a frontend in both states, which is why both ran for hours.
  #
  # But a gate is only safe while it outlasts a cold backend. On api_min_replicas = 0 (the
  # demo) a probe can be waiting on ACA to activate an api replica, and the provider's defaults
  # for a DECLARED probe (1s timeout, 3 failures) are far tighter than the documented readiness
  # defaults that apply when none is declared (5s timeout, 48 failures) — tight enough to call a
  # healthy revision broken and never activate it. So these five values are not tuning; without
  # them, adding the probe would be a regression.
  #
  # Budget: 5 + 48 x 10 = 485s of CONTINUOUS failure before the replica is pulled and restarted.
  # Sized for the case that actually has to work — a customer's FIRST apply, where the frontend
  # starts while the api is still pulling a multi-hundred-MB image onto a cold node. A brand-new
  # install serving a bare 503 at frontend_url is precisely the outcome this release exists to
  # prevent, so the budget is deliberately past any plausible first pull.
  #
  # The interval is what a healthy cold wake pays, not the threshold: the frontend cannot take
  # traffic until a probe lands AFTER the api answers, so a wide interval quantises every wake.
  # 10s halves that against 20s while the higher threshold still doubles the budget — the two
  # knobs trade independently, so there is no reason to be coarse. One success takes traffic.
  #
  # Detection speed costs nothing here: revision_mode is Single, and ACA shifts traffic only
  # once readiness succeeds, so a broken revision never serves regardless of the threshold. The
  # threshold governs only when ACA restarts the replica.
  readiness_probe_initial_delay           = 5
  readiness_probe_interval_seconds        = 10
  readiness_probe_timeout                 = 8
  readiness_probe_failure_count_threshold = 48
  readiness_probe_success_count_threshold = 1

  tags = local.tags
}
