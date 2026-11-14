# The install's network: the VNet, its subnets, the network security groups and the
# Postgres private DNS zone. Part of the root module; see main.tf for the file list.

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

  # Explicit environment subnet prefixes (front_subnet_prefix, app_subnet_prefix and
  # workers_subnet_prefix) must fit the network the module builds. Checked here rather than in
  # the variables because both checks read the runtime and endpoint prefixes the module
  # derives. Derived environment prefixes are never refused: those that would clash are not
  # created (main.tf).
  lifecycle {
    precondition {
      condition     = !local.env_subnet_prefixes_given || length(local.env_subnets_outside_vnet) == 0
      error_message = "The environment subnet prefixes must lie inside vnet_address_space; outside it: ${join(", ", sort(local.env_subnets_outside_vnet))}."
    }

    precondition {
      condition     = !local.env_subnet_prefixes_given || length(setintersection(local.subnet_layout_overlaps, ["front", "app", "workers"])) == 0
      error_message = "The environment subnet prefixes must not overlap each other, the runtime subnet (aca_subnet_prefix) or the private-endpoint subnet (private_endpoints_subnet_prefix); overlapping: ${join(", ", sort(local.subnet_layout_overlaps))}. Each environment's subnet carries its own inbound rules, so no two subnets may share an address."
    }
  }
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

# The environment subnets of ADR 0120 §4: front, app and workers, one workload-profiles
# Container Apps environment each. They sit beside snet-aca rather than replacing it, so the
# apps can move across while the runtime subnet still serves them; snet-aca, its NSG and the
# endpoints subnet keep their addresses and plan no change. A workload-profiles environment
# accepts a /27 or larger and, like snet-aca, needs the delegation. Prefixes: main.tf.
resource "azurerm_subnet" "environment" {
  for_each = local.env_subnet_prefixes

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.aca.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [each.value]

  delegation {
    name = "aca-environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
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
# AllowInternetOutBound stays. How egress can be narrowed depends on the Container Apps
# environment type (a route or NAT Gateway on the subnet is honoured only for workload
# profiles), and on an injected spoke it is the platform team's (docs/networking.md, "Egress").
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

  # The apps are the only caller the install's data plane has. Postgres, Key Vault, Redis and
  # a private Service Bus namespace have no public network presence, so this rule is the whole
  # of who may open a connection to them — and it is now enforced rather than implied,
  # because the subnet above has private_endpoint_network_policies = "Enabled".
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
    description                = "Postgres, Key Vault, the Redis session registry and a private Service Bus namespace, from the runtime subnet only."
  }

  # ADR 0120 §5: the app and workers environments reach the data plane on the same ports. The
  # front environment never does: it is the one that faces the callers, and when it is
  # external, the internet. The rule above stays while the apps still run in snet-aca.
  dynamic "security_rule" {
    for_each = { for k in ["app", "workers"] : k => local.env_subnet_prefixes[k] if contains(keys(local.env_subnet_prefixes), k) }

    content {
      name                       = "allow-data-plane-from-${security_rule.key}-subnet"
      priority                   = security_rule.key == "app" ? 110 : 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = security_rule.value
      source_port_range          = "*"
      destination_address_prefix = local.private_endpoints_subnet_prefix
      destination_port_ranges    = local.private_endpoint_ports
      description                = "Postgres, Key Vault, the Redis session registry and a private Service Bus namespace, from the ${security_rule.key} environment's subnet."
    }
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

# --- The environment subnets' inbound rules (ADR 0120 §5) ----------------------------------
# Each environment admits its own callers, the Container Apps platform's traffic, and nothing
# else; every group ends in the same explicit deny as the two above, for the same reason.
#
#   front    80 and 443 from the internet, or from VirtualNetwork when the environment has an
#            internal load balancer. External, its only narrower filter is the apps' own
#            ingress allowlist (ingress_allowed_cidrs), as for snet-aca above.
#   app      443 from the front subnet only. Never VirtualNetwork, which would admit every
#            peered network and on-premises range besides the front.
#   workers  no caller at all.
#
# The callers' rule names the edge proxy's own ports, 31080 and 31443, beside 80 and 443, and
# the platform rules are the workload-profiles set: Azure Load Balancer probes on 30000-32767
# and traffic within the subnet. Microsoft's "Securing a virtual network in Azure Container
# Apps" (https://learn.microsoft.com/azure/container-apps/firewall-integration) lists both;
# without them the deny takes the environment offline.
locals {
  env_subnet_callers = {
    front = [{
      name        = "allow-app-ingress"
      source      = var.aca_internal_load_balancer ? "VirtualNetwork" : "Internet"
      ports       = ["80", "443", "31080", "31443"]
      description = "Reach the front environment's apps; ingress_allowed_cidrs narrows it further at the Container Apps edge."
    }]
    app = [{
      name        = "allow-https-from-front"
      source      = try(local.env_subnet_prefixes["front"], null)
      ports       = ["443", "31443"]
      description = "HTTPS from the front environment's subnet only."
    }]
    workers = []
  }
}

resource "azurerm_network_security_group" "environment" {
  for_each = local.env_subnet_prefixes

  name                = "nsg-${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags

  dynamic "security_rule" {
    for_each = local.env_subnet_callers[each.key]

    content {
      name                       = security_rule.value.name
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = security_rule.value.source
      source_port_range          = "*"
      destination_address_prefix = each.value
      destination_port_ranges    = security_rule.value.ports
      description                = security_rule.value.description
    }
  }

  security_rule {
    name                       = "allow-container-apps-load-balancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = each.value
    destination_port_range     = "30000-32767"
    description                = "Azure Container Apps platform requirement for a workload-profiles environment."
  }

  security_rule {
    name                       = "allow-environment-internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = each.value
    source_port_range          = "*"
    destination_address_prefix = each.value
    destination_port_range     = "*"
    description                = "Azure Container Apps platform requirement: traffic within the environment's subnet."
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

resource "azurerm_subnet_network_security_group_association" "environment" {
  for_each = local.env_subnet_prefixes

  subnet_id                 = azurerm_subnet.environment[each.key].id
  network_security_group_id = azurerm_network_security_group.environment[each.key].id
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

# azurerm 5 identifies the zone by `private_dns_zone_id` alone; the `resource_group_name` and
# `private_dns_zone_name` pair this link (and the Key Vault, Redis and Service Bus links) used
# before was removed. The link's Azure resource ID is unchanged — the link has always lived in
# the zone's own resource group — and the provider fills `private_dns_zone_id` in from that ID
# when it refreshes state, so a refreshing plan shows no change here. A plan run with
# -refresh=false against state written by azurerm 4 cannot do that, and shows these links as
# replaced.
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count = local.create_postgres_dns ? 1 : 0

  name                = "pdzl-${var.name_prefix}-postgres"
  private_dns_zone_id = azurerm_private_dns_zone.postgres[0].id
  virtual_network_id  = local.virtual_network_id
  tags                = local.tags
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
