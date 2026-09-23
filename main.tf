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

  # The ports the install's private endpoints actually answer on, and the whole of what the
  # endpoints subnet admits: Postgres (5432), Key Vault (443), Azure Cache for Redis over TLS
  # (6380) and Azure Managed Redis (10000, its documented default).
  #
  # The managed offering's port is read from the database rather than trusted to be that
  # default. The ARM contract says the database port "defaults to an available port", which is
  # not a guarantee — a rule naming only 10000 would cut the session registry off on an
  # install that got anything else, and it would fail as a connection timeout at boot rather
  # than as anything that names a firewall.
  private_endpoint_ports = distinct(concat(
    ["443", "5432", "6380", "10000"],
    local.use_managed_redis ? [tostring(azurerm_managed_redis.this[0].default_database[0].port)] : [],
  ))

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
  private_endpoint_network_policies = "Enabled"                               # so the NSG below applies to private-endpoint traffic
}

# --- Network security groups on the module's own subnets --------------------------
# Deny-by-default at the subnet edge, underneath the Container Apps ingress allowlist.
# An NSG's own defaults are not that: they deny the internet, but they ALLOW everything
# the VirtualNetwork service tag covers — which is not only this VNet but every peered
# network and every on-premises address space reachable through a gateway attached to it.
# On a network a platform team later peers into a wider estate, that is a door opening by
# itself. So each subnet names what it admits and denies the rest explicitly.
#
# Inbound only. Container Apps needs broad egress (image pull, Microsoft Container Registry,
# Entra ID, Azure Monitor), the outbound set is long and versioned by Microsoft, and an
# outbound deny written here would be a second, stale copy of it — the failure would be an
# environment that provisions and then cannot start a replica. Azure's default
# AllowInternetOutBound stays; narrowing egress is a firewall or NVA decision, and on an
# injected spoke it is already the platform team's (docs/networking.md, "Egress").
#
# Created ONLY when the module owns the network. On an injected spoke (topology 3) the
# subnets belong to the platform team, and attaching an NSG to a subnet somebody else
# governs would silently replace rules this module cannot see. docs/networking.md states
# the baseline those subnets are expected to carry instead.

resource "azurerm_network_security_group" "aca" {
  count = local.inject_network ? 0 : 1

  name                = "nsg-${var.name_prefix}-aca"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags

  # Ingress to the apps. The source follows the environment's load balancer, because an
  # internal environment has no public endpoint at all: admitting the Internet tag there
  # would describe a path that does not exist. VirtualNetwork is the right tag for that
  # topology — it covers peered networks and the on-premises address spaces reachable over
  # a VPN or ExpressRoute gateway, which is exactly who reaches topology 2.
  #
  # This is defence in depth, not the allowlist. `ingress_allowed_cidrs` is what narrows who
  # may reach the apps, and Container Apps ingress enforces it. It is deliberately not reused
  # as the source here: an empty list is a legal configuration meaning "unrestricted", and an
  # NSG rule cannot express an empty source — it would have to become a deny, turning a
  # documented default into an outage.
  #
  # Port 80 is admitted beside 443 because Azure's edge answers it with a 301 to https://
  # (see ingress_allow_insecure on the api). Dropping it here would turn that redirect into a
  # timeout for anyone who typed the host without a scheme.
  security_rule {
    name                       = "allow-app-ingress"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.aca_internal_load_balancer ? "VirtualNetwork" : "Internet"
    source_port_range          = "*"
    destination_address_prefix = local.aca_subnet_prefix
    destination_port_ranges    = ["80", "443"]
    description                = "Reach the frontend (and the api when api_ingress_external is true); ingress_allowed_cidrs narrows it further at the Container Apps edge."
  }

  # Required by Container Apps on a Consumption-only environment: the platform's load
  # balancer reaches the environment on the ephemeral range. Without this rule the deny below
  # takes the apps offline — the environment provisions and then serves nothing.
  security_rule {
    name                       = "allow-container-apps-load-balancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = local.aca_subnet_prefix
    destination_port_range     = "30000-32767"
    description                = "Azure Container Apps platform requirement for a Consumption-only environment."
  }

  # The environment's own components talk to each other inside the infrastructure subnet:
  # the ingress proxy to the replicas, and the replicas to their sidecars. Also a Container
  # Apps requirement, and equally load-bearing once the deny below exists.
  security_rule {
    name                       = "allow-environment-internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = local.aca_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = local.aca_subnet_prefix
    destination_port_range     = "*"
    description                = "Azure Container Apps platform requirement: traffic within the infrastructure subnet."
  }

  # The point of the whole block: nothing else reaches the runtime subnet, including the rest
  # of the VNet and anything peered into it.
  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
    description                = "Everything not admitted above."
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  count = local.inject_network ? 0 : 1

  name                = "nsg-${var.name_prefix}-private-endpoints"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags

  # The apps are the only caller the install's data plane has. Postgres, Key Vault and Redis
  # have no public network presence, so this rule is the whole of who may open a connection
  # to them — and it is now enforced rather than implied, because the subnet above has
  # private_endpoint_network_policies = "Enabled".
  security_rule {
    name                       = "allow-data-plane-from-apps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.aca_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = local.private_endpoints_subnet_prefix
    destination_port_ranges    = local.private_endpoint_ports
    description                = "Postgres, Key Vault and the Redis session registry, from the runtime subnet only."
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
    description                = "Everything not admitted above."
  }
}

# Associated as separate resources rather than on the subnet: azurerm_subnet carries no
# network_security_group_id argument, so this is the association, not a second way of
# writing one.
resource "azurerm_subnet_network_security_group_association" "aca" {
  count = local.inject_network ? 0 : 1

  subnet_id                 = azurerm_subnet.aca[0].id
  network_security_group_id = azurerm_network_security_group.aca[0].id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  count = local.inject_network ? 0 : 1

  subnet_id                 = azurerm_subnet.private_endpoints[0].id
  network_security_group_id = azurerm_network_security_group.private_endpoints[0].id
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

# --- App identities --------------------------------------------------------------
# One identity per app is the platform's rule, and the reason is the frontend: it is the
# only internet-facing app in the install, and it needs nothing but image pull. Sharing
# `apps_identity` with it handed the public front door Key Vault Secrets Officer, Service
# Bus send + receive and ACS Email Owner — permissions it never uses, on the one app an
# attacker reaches first. So the backend apps (api, workers) keep `apps_identity` and the
# data-plane grants that go with it; the frontend gets its own, holding AcrPull alone.

module "apps_identity" {
  source = "./modules/user-assigned-identity"

  name                = "id-${var.name_prefix}-apps"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# The frontend's own identity. Image pull is the whole of it — no Key Vault, no Service Bus,
# no ACS. Nothing here grows without a reason to give the public app that reach.
module "frontend_identity" {
  source = "./modules/user-assigned-identity"

  name                = "id-${var.name_prefix}-frontend"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# Optional: grant pull on the registry (the deploying principal needs
# roleAssignments/write on the registry's scope — true for the demo install, where
# platform-iac's principal manages the shared registry; customers typically grant
# pull out of band and leave acr_id null).
#
# BOTH identities need the grant when acr_id is null and you grant out of band — see the
# `apps_identity_principal_id` / `frontend_identity_principal_id` outputs.
resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "acr_pull_frontend" {
  count = var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.frontend_identity.principal_id
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
    local.ca_bundle_env,      # SSL_CERT_FILE, pointed at the mounted bundle, empty unless set
    local.servicebus_env,
    local.acs_email_env,          # ACS endpoint + sender auto-wired when email is enabled (ADR 0040)
    local.keyvault_env,           # durable secret store when the Key Vault is enabled (ADR 0066)
    local.redis_env,              # redis session registry when Redis is enabled (ADR 0066)
    local.workers_inprocess_env,  # the api hands the loop to ca-workers when enabled (ADR 0066)
    local.install_credential_env, # the install credential, shared by refresh and telemetry
    local.telemetry_env,          # usage reporting to the control plane, off unless configured
    local.license_refresh_env,    # daily licence refresh from the control plane (ADR 0074), off unless configured
    # The license verification key (ADR 0013) is public material — plain env.
    var.license_public_jwk != null ? { MASTERLY_LICENSE_PUBLIC_JWK = var.license_public_jwk } : {},
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
    "session-secret"          = random_password.session_secret.result
    "session-secret-previous" = var.session_secret_previous
    "registry-password"       = var.registry_password
    "redis-url"               = local.redis_url # embeds the access key (ADR 0066)
    "license-token"           = var.license_token
    "breakglass-secret-hash"  = var.breakglass_secret_hash
    "telemetry-client-secret" = var.telemetry_client_secret
    "oidc-client-secret"      = var.oidc_client_secret
    # Not confidential (see ca_bundle_pem's description) — it travels through the SAME
    # Container App secret plumbing as everything else here only because that plumbing is
    # also how a value reaches the file mount below (secret_file_mounts, MAS-446), not
    # because it needs hiding.
    "ca-bundle-pem" = var.ca_bundle_pem
  }

  # Credential-based image pull (ADR 0067): the SP secret rides on every app that pulls.
  registry_secret_names = var.registry_username != null ? ["registry-password"] : []

  # nonsensitive() on the PRESENCE tests, not on any value: `var.license_token != null` is a
  # bool derived from a sensitive variable, so Terraform marks it, and a marked list cannot
  # drive for_each (the vault writes) or a precondition. Whether a licence was supplied is not
  # the secret — the same narrow unmarking, for the same reason, as redis_url_wired.
  api_secret_names = concat(
    ["database-url", "session-secret"],
    # Only while a rotation is in flight; unset is the steady state (see the variable).
    nonsensitive(var.session_secret_previous != null) ? ["session-secret-previous"] : [],
    local.registry_secret_names,
    local.redis_secret_names,
    nonsensitive(var.license_token != null) ? ["license-token"] : [],
    nonsensitive(var.breakglass_secret_hash != null) ? ["breakglass-secret-hash"] : [],
    local.install_credential_configured ? ["telemetry-client-secret"] : [],
    var.ca_bundle_pem != null ? ["ca-bundle-pem"] : [],
  )

  # On oidc the frontend is the confidential BFF client: its client secret is used only
  # server-side at token exchange.
  frontend_secret_names = concat(
    local.registry_secret_names,
    var.identity_binding == "oidc" ? ["oidc-client-secret"] : [],
  )

  api_secrets      = { for name in local.api_secret_names : name => local.secret_values[name] }
  frontend_secrets = { for name in local.frontend_secret_names : name => local.secret_values[name] }

  api_env_secret_refs = merge(
    {
      MASTERLY_DATABASE_URL   = "database-url"
      MASTERLY_SESSION_SECRET = "session-secret"
    },
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
  user_assigned_identity_ids = [module.frontend_identity.id]

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
  # gets the client config here; the client secret travels as a Container App secret
  # (see frontend_secret_names above), never as plain env.
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
      #
      # http, not https, and it stays http now that the environment encrypts peer traffic.
      # The certificate the platform manages is issued for the environment's domain, so
      # https://ca-api would fail hostname verification on the very name chosen because it
      # cannot drift. The scheme here says what the BFF speaks, not what crosses the wire:
      # with mutual_tls_enabled on module.aca_env, Azure encrypts the hop underneath it.
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

  secrets     = local.frontend_value_secrets
  secret_refs = local.frontend_vault_secret_refs

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

  # The grants must land before the first pull. Nothing else orders them: the app depends on
  # the identity, not on the role assignments on it, so on a first apply terraform is free to
  # create the revision while AcrPull is still in flight — and a revision that cannot pull
  # fails to provision. With the vault on, the same is true of the secret read: the registry
  # password is itself a vault reference, so an unresolvable secret is an unpullable image.
  depends_on = [
    azurerm_role_assignment.acr_pull_frontend,
    azurerm_role_assignment.kv_secrets_user_frontend,
  ]
}
