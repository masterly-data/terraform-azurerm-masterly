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
# Container App secrets, or as Key Vault references with enable_key_vault; nothing
# per-install is baked into images.
#
# Opt-in subsystems, off by default: Key Vault (keyvault.tf), Redis (redis.tf), the
# dedicated workers app (workers.tf), customer-owned email (email.tf), the registry's private
# endpoint (registry.tf), the Service Bus transport (servicebus.tf) and ca-frontend's custom
# domain with a Key Vault certificate (custom-domain.tf). mode=production requires the first
# three. The observability surface (diagnostics.tf) is on by default in mode=production and
# off otherwise.
#
# This file holds the core every other file reads: the shared locals, the per-install suffix,
# the licence check and the two resource groups. The rest of the install is one file per
# concern: network.tf (VNet, subnets, network security groups, the Postgres private DNS zone),
# environment.tf (the workspace and the Container Apps environment), identity.tf (the apps'
# identities, the registry and image defaults, AcrPull), postgres.tf (the starter server and the
# connection URLs), servicebus.tf, app-api.tf and app-frontend.tf (each app's secrets,
# environment and Container App).
#
# Deliberately deferred: the per-install Entra identity of ADR 0020.
# The calls the install can make to Masterly's control plane (licence refresh, usage
# reporting) are opt-in and authenticate with the install credential from the bundle, not
# with that identity. The README's "Deliberately deferred" section is the list of record.

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

  # --- Geo-redundant backup on the starter Postgres server ------------------------------
  # Whether Azure Database for PostgreSQL flexible server offers geo-redundant backup in a
  # region, from Microsoft's regions table:
  # https://learn.microsoft.com/azure/postgresql/overview#azure-regions
  #
  # Only regions whose answer has been checked against that table are listed. A region that
  # is absent is treated as unsupported, so the production default leaves geo-redundant
  # backup off there rather than turning on a setting Azure might refuse at apply; set
  # postgres_geo_redundant_backup = true to turn it on yourself. Checked 2026-09-25:
  #   - swedencentral: supported. Its pair, Sweden South, is in Sweden, inside the "eu" geo.
  #     Premium SSD v2 storage does not offer geo-redundant backup in Sweden Central; this
  #     module provisions Premium SSD, which does.
  #   - polandcentral, spaincentral: not supported; the table lists no geo-redundant backup
  #     for either region.
  # Adding a region here changes the production default only for servers created after the
  # change; an existing server keeps what it was created with (see the server's lifecycle).
  postgres_geo_backup_supported = {
    swedencentral = true
    polandcentral = false
    spaincentral  = false
  }

  # The customer's explicit choice wins. Unset, production turns geo-redundant backup on
  # wherever the region supports it, and evaluation installs leave it off.
  postgres_geo_redundant_backup = (
    var.postgres_geo_redundant_backup != null
    ? var.postgres_geo_redundant_backup
    : var.mode == "production" && lookup(local.postgres_geo_backup_supported, local.location_key, false)
  )

  # The customer's explicit choice wins. Unset, production turns storage autogrow on, because a
  # full disk makes the server read-only and stops every write; evaluation installs leave it off.
  postgres_auto_grow = var.postgres_auto_grow != null ? var.postgres_auto_grow : var.mode == "production"

  # The servers of this install's data resource group, found by name. Empty on a new install.
  # Separate from entra-auth.tf's existing_postgres lookup, which is skipped when database_auth
  # is "password" and which the authentication preconditions read.
  existing_postgres_storage_lookup = [
    for r in flatten(data.azurerm_resources.postgres_storage[*].resources) : r
    if lower(r.resource_group_name) == lower(local.rg_data_name) && startswith(r.name, "psql-${var.name_prefix}-")
  ]

  # Never plan less storage than the server holds. With autogrow on, Azure grows the disk past
  # postgres_storage_mb, and a configured value below the real size would plan a shrink, which
  # Azure refuses and the provider answers by replacing the server and its databases. Raising
  # postgres_storage_mb above the real size still grows the disk.
  postgres_storage_mb = max(
    var.postgres_storage_mb,
    try(data.azurerm_postgresql_flexible_server.existing[0].storage_mb, 0),
  )

  # One install is one data plane in one location, so the only geo whose data it can hold is
  # its own. Defaulting to that makes the safe configuration the automatic one.
  allowed_regions = var.allowed_regions != null ? var.allowed_regions : [var.masterly_region]

  # The ports the install's private endpoints actually answer on, and the whole of what the
  # endpoints subnet admits: Postgres (5432), Key Vault (443), Azure Cache for Redis over TLS
  # (6380) and Azure Managed Redis (10000, its documented default). A private Service Bus
  # namespace adds AMQP over TLS (5671), the transport the apps' Service Bus client uses; its
  # AMQP-over-WebSockets fallback is on 443, which is already admitted.
  #
  # The managed offering's port is read from the database rather than trusted to be that
  # default. The ARM contract says the database port "defaults to an available port", which is
  # not a guarantee — a rule naming only 10000 would cut the session registry off on an
  # install that got anything else, and it would fail as a connection timeout at boot rather
  # than as anything that names a firewall.
  private_endpoint_ports = distinct(concat(
    ["443", "5432", "6380", "10000"],
    local.use_managed_redis ? [tostring(azurerm_managed_redis.this[0].default_database[0].port)] : [],
    local.servicebus_private ? ["5671"] : [],
    # The server's built-in PgBouncer listens on 6432 of the same private endpoint.
    var.postgres_pgbouncer ? ["6432"] : [],
  ))

  # Data plane seam (ADR 0065): BYO-DB when the customer supplies a DSN, otherwise the
  # provisioned starter server.
  provision_postgres = var.external_database_url == null
  # A landing zone may centralize the privatelink zone (postgres_private_dns_zone_id);
  # only create one when we provision the server and none is injected.
  create_postgres_dns  = local.provision_postgres && var.postgres_private_dns_zone_id == null
  postgres_dns_zone_id = local.provision_postgres ? (var.postgres_private_dns_zone_id != null ? var.postgres_private_dns_zone_id : azurerm_private_dns_zone.postgres[0].id) : null

  # Service Bus (ADR 0029). Private endpoints are a Premium-only feature on Service Bus, so
  # the namespace runs private exactly when it is Premium in production: public network
  # access Disabled, reached over a private endpoint in the endpoints subnet. Outside
  # production it keeps public access, as Key Vault does, for ease of evaluation.
  #
  # servicebus_sku has no default: production refuses it unset when Service Bus is enabled
  # (the variable's validation), and everywhere else unset means Standard, which is what the
  # variable defaulted to before, so those installs plan no change.
  servicebus_sku         = coalesce(var.servicebus_sku, "Standard")
  servicebus_premium     = var.enable_service_bus && local.servicebus_sku == "Premium"
  servicebus_private     = local.servicebus_premium && var.mode == "production"
  create_servicebus_dns  = local.servicebus_private && var.servicebus_private_dns_zone_id == null
  servicebus_dns_zone_id = local.servicebus_private ? (var.servicebus_private_dns_zone_id != null ? var.servicebus_private_dns_zone_id : azurerm_private_dns_zone.servicebus[0].id) : null
}

# A stable per-install suffix for the globally-unique Postgres server name.
resource "random_string" "install" {
  length  = 6
  lower   = true
  upper   = false
  special = false
}

# --- The licence and the api image it will be verified by (ADR 0013, amended 2026-10-06) --
# A licence's signed header states the lowest claims version an api build may hold and still
# verify it. A re-issued licence applied here reaches the application's startup check directly,
# so the plan answers that question first, against the api_image pinned below and the claims
# version this module's own MANIFEST.json records for it — offline, with no registry call. The
# refusal is the precondition on the first resource group.
module "license_claims_floor" {
  source = "./modules/license-claims-floor"

  license_token = var.license_token
  api_image     = local.api_image
  manifest      = local.release_manifest
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
      condition     = !var.api_ingress_external || length(var.ingress_allowed_cidrs) > 0
      error_message = "api_ingress_external = true with an empty ingress_allowed_cidrs would publish /v1 to the whole internet: an empty list means UNRESTRICTED in Azure, not deny-all. The api holds no session of its own — it trusts a bearer token — so it is the surface least able to survive being open. Name the CIDRs that may reach it."
    }

    # Licence refresh and fleet telemetry are separate features that share one input: the
    # install credential (telemetry_client_id / telemetry_client_secret, named for the report
    # that first used it). So the guards are stated per FEATURE — each feature refuses to be
    # switched on without the credential it authenticates with — and neither feature's input
    # is required by the other. Stated that way, a customer who set only license_issuer_url is
    # told about licence refresh and never about a report they did not ask for.
    precondition {
      condition     = var.license_issuer_url == null || (var.telemetry_client_id != null && var.telemetry_client_secret != null)
      error_message = "license_issuer_url requires the install credential, telemetry_client_id and telemetry_client_secret (both from your install bundle): licence refresh authenticates as the install service account, and the application keeps refresh OFF without it, so the URL alone produces an install that looks configured and never refreshes. telemetry_url is NOT required — refresh does not turn on usage reporting."
    }

    precondition {
      condition     = var.telemetry_url == null || (var.telemetry_client_id != null && var.telemetry_client_secret != null)
      error_message = "telemetry_url requires the install credential, telemetry_client_id and telemetry_client_secret (both from your install bundle): the report authenticates as the install service account, and the application gates reporting on the URL AND the client id, so the URL alone produces an install that looks configured and reports nothing. Set the credential beside it, or leave telemetry_url unset."
    }

    precondition {
      condition     = (var.telemetry_client_id == null) == (var.telemetry_client_secret == null)
      error_message = "telemetry_client_id and telemetry_client_secret go together: they are one install credential, and half of it authenticates nothing. Set both, or neither."
    }

    precondition {
      condition     = var.telemetry_client_id == null || var.license_issuer_url != null || var.telemetry_url != null
      error_message = "telemetry_client_id and telemetry_client_secret are set, but neither feature that uses them is: the install credential authenticates licence refresh (license_issuer_url) and fleet telemetry (telemetry_url), and on its own it does nothing. Set the input for the feature you want, or leave the credential unset."
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

    # The licence must be one the pinned api image can verify. Checked only when the manifest
    # records the image's tag; see modules/license-claims-floor for what passes unchecked.
    precondition {
      condition     = !module.license_claims_floor.refused
      error_message = coalesce(module.license_claims_floor.message, "The licence cannot run on the pinned api image.")
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
