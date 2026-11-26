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

    # The add-on subnets (split_processing, extensions) are refused whether explicit or derived: an
    # add-on someone turned on must get its subnets or stop the plan, never be skipped.
    precondition {
      condition     = length(local.add_on_subnets_missing) == 0
      error_message = "split_processing and extensions each need subnets of their own, and this VNet cannot derive them: ${join(", ", sort(local.add_on_subnets_missing))}. Set core_subnet_prefix and outbound_subnet_prefix (split_processing) or extension_subnet_prefix (extensions), each /27 or larger and clear of every other subnet, or use a first vnet_address_space prefix of /20 or larger, from which the module derives the /24s at index 8, 9 and 10."
    }

    precondition {
      condition     = length(local.add_on_subnets_outside_vnet) == 0
      error_message = "The add-on environment subnet prefixes must lie inside vnet_address_space; outside it: ${join(", ", sort(local.add_on_subnets_outside_vnet))}."
    }

    precondition {
      condition     = length(setintersection(local.subnet_layout_overlaps, local.add_on_keys)) == 0
      error_message = "The add-on environment subnets must not overlap each other or any other subnet of the install (snet-aca, the private-endpoint subnet, front, app and workers); overlapping: ${join(", ", sort(local.subnet_layout_overlaps))}. Each environment's subnet carries its own inbound rules, so no two subnets may share an address. Set core_subnet_prefix, outbound_subnet_prefix or extension_subnet_prefix to a free range."
    }
  }
}

# The runtime environment (aca-<prefix>) was sized for a /23 or larger, and Azure now
# requires the subnet to be delegated to Microsoft.App/environments (the first apply
# failed with ManagedEnvironmentSubnetDelegationError without it).
#
# Only while aca-<prefix> exists: with retire_runtime_environment nothing runs here, so the
# subnet, its NSG and their association are not created, and on an install that had them the plan
# deletes the three. Azure releases a subnet a deleted environment ran in only after the
# environment's own deletion completes; an apply that deletes both in one run may need a second
# apply for the subnet (docs/networking.md, "Retiring the runtime environment").
resource "azurerm_subnet" "aca" {
  count = !local.inject_network && local.runtime_subnet ? 1 : 0

  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.aca.name
  virtual_network_name = azurerm_virtual_network.this[0].name
  address_prefixes     = [local.aca_subnet_prefix] # /23, the size aca-<prefix> was created on

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
# endpoints subnet keep their addresses and plan no change until retire_runtime_environment
# removes snet-aca. A workload-profiles environment
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
# AllowInternetOutBound stays. Egress is narrowed by routing it, not by an NSG: egress_firewall
# attaches a route table to snet-aca that sends 0.0.0.0/0 to the customer's firewall (below), and
# on an injected spoke the hub's route table is the platform team's (docs/networking.md, "Egress").
# What each subnet needs to reach is published for that firewall instead, as the
# outbound_allowlist output (ADR 0120 §5; the locals at the end of this file), never as a rule here.
#
# Created ONLY when the module owns the network. On an injected spoke (topology 3) the
# subnets belong to the platform team, and attaching an NSG to a subnet somebody else
# governs would silently replace rules this module cannot see. docs/networking.md states
# the baseline those subnets are expected to carry instead.

resource "azurerm_network_security_group" "aca" {
  count = !local.inject_network && local.runtime_subnet ? 1 : 0

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
  #
  # VirtualNetwork covers the extension subnet, and extension code reaches nothing of
  # Masterly's (ADR 0120 §7, ADR 0122 §6.2), so with the extensions add-on a deny of that
  # subnet comes first. 100 is the lowest priority Azure accepts, so the deny takes it and this
  # rule moves to 105 — only with the add-on, so an install without it plans no change here.
  dynamic "security_rule" {
    for_each = local.extension_subnet_denied ? { extension = local.env_subnet_prefixes["extension"] } : {}

    content {
      name                       = "deny-from-extension-subnet"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = security_rule.value
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
      description                = "The extension environment reaches nothing of Masterly's, whatever the rules below admit."
    }
  }

  security_rule {
    name                       = "allow-app-ingress"
    priority                   = local.extension_subnet_denied ? 105 : 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.aca_internal_load_balancer ? "VirtualNetwork" : "Internet"
    source_port_range          = "*"
    destination_address_prefix = local.aca_subnet_prefix
    destination_port_ranges    = ["80", "443"]
    description                = "Reach the frontend (and the api when api_ingress_external is true); ingress_allowed_cidrs narrows it further at the Container Apps edge."
  }

  # Required by Container Apps on a VNet-integrated environment: the platform's load
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
  #
  # From snet-aca only while it exists: a retired install (retire_runtime_environment) has no
  # runtime subnet, and its apps reach the data plane from the app and workers subnets below.
  dynamic "security_rule" {
    for_each = local.runtime_subnet ? { aca = local.aca_subnet_prefix } : {}

    content {
      name                       = "allow-data-plane-from-apps"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = security_rule.value
      source_port_range          = "*"
      destination_address_prefix = local.private_endpoints_subnet_prefix
      destination_port_ranges    = local.private_endpoint_ports
      description                = "Postgres, Key Vault, the Redis session registry and a private Service Bus namespace, from the runtime subnet only."
    }
  }

  # ADR 0120 §5: the app and workers environments reach the data plane on the same ports. The
  # front environment never does on these ports: it is the one that faces the callers, and when
  # it is external, the internet (its one exception, the vault on 443, is below). The rule above
  # stays while snet-aca does.
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

  # The one exception for the front subnet (ADR 0120 amendment, 2026-11-16): with ca-frontend in
  # the front environment, it resolves its per-secret vault references through the Key Vault
  # private endpoint. The endpoint's own address and 443 only, never the subnet or another port,
  # so the front reaches no database, Redis or Service Bus. Reaching the vault grants no secret:
  # ca-frontend reads its own secrets only, as module.frontend_identity.
  dynamic "security_rule" {
    for_each = (
      var.frontend_environment == "front" && local.key_vault_private_endpoint && contains(keys(local.env_subnet_prefixes), "front")
    ) ? { front = local.env_subnet_prefixes["front"] } : {}

    content {
      name                       = "allow-key-vault-from-front-subnet"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = security_rule.value
      source_port_range          = "*"
      destination_address_prefix = "${azurerm_private_endpoint.key_vault[0].private_service_connection[0].private_ip_address}/32"
      destination_port_range     = "443"
      description                = "Key Vault's private endpoint only, on 443, from the front environment's subnet: ca-frontend's vault secret references."
    }
  }

  # ADR 0120 §4: with split_processing, the core and outbound environments are the workers
  # environment split in two, and both reach the data plane on the same ports. Beside the rules
  # above, with priorities of their own, so an install without the add-on plans no change here. The
  # extension subnet never appears: extension code has no database and no Masterly identity (§7).
  dynamic "security_rule" {
    for_each = { for k in ["core", "outbound"] : k => local.env_subnet_prefixes[k] if contains(keys(local.env_subnet_prefixes), k) }

    content {
      name                       = "allow-data-plane-from-${security_rule.key}-subnet"
      priority                   = security_rule.key == "core" ? 140 : 150
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

    # The add-on environments (ADR 0120 §4) admit no caller: nothing they run serves a request.
    core      = []
    outbound  = []
    extension = []
  }

  # The extension subnet exists on a network the module builds: snet-aca and the front, which may
  # admit VirtualNetwork, deny it ahead of their ingress rule.
  extension_subnet_denied = contains(keys(local.env_subnet_prefixes), "extension")
}

resource "azurerm_network_security_group" "environment" {
  for_each = local.env_subnet_prefixes

  name                = "nsg-${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags

  # The front's caller rule may admit VirtualNetwork, which covers the extension subnet: with the
  # extensions add-on, the same deny as on snet-aca comes first, at 100, and the caller rule moves
  # to 105.
  dynamic "security_rule" {
    for_each = each.key == "front" && local.extension_subnet_denied ? { extension = local.env_subnet_prefixes["extension"] } : {}

    content {
      name                       = "deny-from-extension-subnet"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = security_rule.value
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
      description                = "The extension environment reaches nothing of Masterly's, whatever the rules below admit."
    }
  }

  dynamic "security_rule" {
    for_each = local.env_subnet_callers[each.key]

    content {
      name                       = security_rule.value.name
      priority                   = each.key == "front" && local.extension_subnet_denied ? 105 : 100
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
  count = !local.inject_network && local.runtime_subnet ? 1 : 0

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

# --- Forced-tunnel egress (egress_firewall) ------------------------------------------
# All outbound traffic from the subnets the apps run in goes to the customer's firewall, which
# decides what passes (docs/networking.md, "Egress", lists what it must admit). Only on a network
# the module builds: on an injected spoke the input is refused at plan (variables-core.tf), and the
# module creates nothing here, so a route table the hub already attached to a subnet is never
# touched.
#
# Which subnets: snet-aca while aca-<prefix> runs, exactly as before, and nothing else, because
# the plan refuses egress_firewall while any workload has moved off it (variables-core.tf,
# workers.tf, migrate.tf). Once retire_runtime_environment removes aca-<prefix> and snet-aca, every
# environment subnet the module creates instead: front, app and workers, and core and outbound with
# split_processing. And extension with extensions: extension code is the least trusted code in the
# install (ADR 0120 §7), so its egress is the last that should keep Azure's default path while the
# rest is forced through the firewall; what it may reach is then the firewall's decision.
#
# Never snet-private-endpoints. It has private_endpoint_network_policies = "Enabled", under
# which a route table there would apply to private-endpoint traffic as well, sending the data
# plane's replies through the firewall. Traffic from the apps to those endpoints needs no route:
# it stays inside the VNet, where the VNet's system route is more specific than 0.0.0.0/0.

locals {
  # The route table in effect: the customer's, or the one created below. null unset.
  egress_route_table_id = try(coalesce(var.egress_firewall.route_table_id, one(azurerm_route_table.egress[*].id)), null)

  # The environment subnets the route table goes on: every one the module creates, and only on a
  # retired install. Empty otherwise, so an install that has not retired plans no change here.
  egress_environment_subnet_keys = (
    !local.inject_network && var.egress_firewall != null && !local.runtime_subnet
  ) ? toset(keys(local.env_subnet_prefixes)) : toset([])
}

resource "azurerm_route_table" "egress" {
  count = !local.inject_network && try(var.egress_firewall.next_hop_ip, null) != null ? 1 : 0

  name                = "rt-${var.name_prefix}-aca"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags

  # Kept on, and written out so it is not turned off as hardening. Routes a VPN or ExpressRoute
  # gateway propagates (topology 2's clients, over a peered hub's gateway) are more specific than
  # 0.0.0.0/0 and must keep winning over it; without them the replies to those clients would leave
  # through the firewall, a path their requests never took, and a stateful firewall drops them.
  bgp_route_propagation_enabled = true

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.egress_firewall.next_hop_ip
  }
}

# A separate resource, like the NSG associations above: a subnet holds one route table, and this
# is that one association.
resource "azurerm_subnet_route_table_association" "aca" {
  count = !local.inject_network && var.egress_firewall != null && local.runtime_subnet ? 1 : 0

  subnet_id      = one(azurerm_subnet.aca[*].id)
  route_table_id = local.egress_route_table_id

  lifecycle {
    # Azure ignores a route on an environment with no workload profile, and egress would stay open
    # while it is believed forced, so the module refuses rather than attach one. What makes the
    # environment workload-profiles is known in two halves. The Microsoft.App/environments
    # delegation on its subnet is known at plan (ADR 0104: on a delegated subnet Azure creates a
    # workload-profiles environment, with the Consumption profile filled in). The profiles Azure
    # actually lists are known at plan for an existing environment and at apply for a new one,
    # when Terraform evaluates this condition again; until then the unknown half does not refuse.
    # A retired install has no instance of this association (count above); the checks on
    # aca-<prefix> stay, so it never passes without the environment it routes.
    precondition {
      condition = (
        try(azurerm_subnet.aca[0].delegation[0].service_delegation[0].name, null) == "Microsoft.App/environments" &&
        length(module.aca_env) == 1 &&
        try(length(one(module.aca_env[*].workload_profile_names)) > 0, true)
      )
      error_message = "egress_firewall needs a workload-profiles Container Apps environment: Azure ignores a route on an environment that reports no workload profile, so egress would stay open while it is believed forced through your firewall. The environment's subnet must be delegated to Microsoft.App/environments and Azure must list at least one workload profile on the environment (az containerapp env show --query properties.workloadProfiles). Remove egress_firewall, or move the install to a workload-profiles environment first."
    }
  }
}

# The same route table on each environment subnet of a retired install. One association per
# subnet, as above. The guarantee is the same as on snet-aca: never a route the environment would
# ignore. Each of these subnets is the module's own, delegated to Microsoft.App/environments (known
# at plan), and carries a workload-profiles environment (modules/aca-env-workload-profiles), whose
# profiles are declared in configuration and so known at plan too: the precondition checks both,
# and that the environment exists at all, rather than assume it.
resource "azurerm_subnet_route_table_association" "environment" {
  for_each = local.egress_environment_subnet_keys

  subnet_id      = azurerm_subnet.environment[each.key].id
  route_table_id = local.egress_route_table_id

  lifecycle {
    precondition {
      condition = (
        try(azurerm_subnet.environment[each.key].delegation[0].service_delegation[0].name, null) == "Microsoft.App/environments" &&
        contains(local.container_app_environment_keys, each.key) &&
        try(length(module.environments[each.key].workload_profiles) > 0, true)
      )
      error_message = "egress_firewall needs a workload-profiles Container Apps environment on every subnet it routes: Azure ignores a route on an environment that reports no workload profile, so egress would stay open while it is believed forced through your firewall. snet-${each.key} must be delegated to Microsoft.App/environments and carry aca-<name_prefix>-${each.key} with at least one workload profile. Remove egress_firewall, or give the install that environment."
    }
  }
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

# --- The outbound allowlist (ADR 0120 §5) -----------------------------------------
# What each subnet's workloads reach outside the VNet, published as the outbound_allowlist output
# so your firewall can narrow egress per subnet. Nothing here writes a rule: the NSGs stay
# inbound-only (above). Keyed by the environments that exist (local.install_environment_keys,
# environment.tf), on what is known at plan.
#
# The Container Apps platform set is two lists on Microsoft Learn, as read on 2026-11-23: the
# service tags are the NSG allow rules of "Securing a virtual network in Azure Container Apps",
# and the FQDNs are the application rules of "Azure Container Apps environment integration with
# Azure Firewall". Microsoft versions both, so every entry names its source: compare an entry with
# the page, not with this file, before you rely on it. docs/networking.md ("The outbound_allowlist
# output") carries the same date.
#
# Entries are keyed by a string known at plan, never by an unknown name, so a destination that is
# only known after apply (the vault's or the namespace's name on a fresh install) leaves that one
# entry unknown and not the whole list. The same destination from two workloads on one subnet is
# one entry.
locals {
  outbound_adr_source      = "ADR 0120 §5, the Container Apps platform set the module publishes for every subnet"
  outbound_registry_source = "Microsoft Learn, Configure rules to access an Azure container registry behind a firewall (https://learn.microsoft.com/azure/container-registry/container-registry-firewall-access-rules), read 2026-11-23"

  # The platform set's two lists on Learn, by the kind of entry each gives.
  outbound_learn_source = {
    service_tag = "Microsoft Learn, Securing a virtual network in Azure Container Apps, NSG allow rules (https://learn.microsoft.com/azure/container-apps/firewall-integration#nsg-allow-rules), read 2026-11-23"
    fqdn        = "Microsoft Learn, Azure Container Apps environment integration with Azure Firewall, application rules (https://learn.microsoft.com/azure/container-apps/use-azure-firewall#application-rules), read 2026-11-23"
  }

  # Every subnet, whatever runs there: what the environment itself needs to start a replica.
  # The two registry service tags and login.microsoft.com are Learn's rows for images in an Azure
  # container registry and for Key Vault. They stay with registry_private_endpoint: ca-edge can
  # still pull edge.image from another Azure container registry, and a tag too many does not stop
  # a replica where a tag too few does.
  outbound_platform_entries = {
    for e in [
      { destination = "MicrosoftContainerRegistry", kind = "service_tag", why = "Microsoft Container Registry: Azure pulls the environment's own platform containers from it. Blocked, the environment provisions but no replica starts" },
      { destination = "AzureFrontDoor.FirstParty", kind = "service_tag", why = "Microsoft Container Registry's content delivery, which the MicrosoftContainerRegistry service tag depends on" },
      { destination = "mcr.microsoft.com", kind = "fqdn", why = "Microsoft Container Registry, for a firewall that admits by name" },
      { destination = "*.data.mcr.microsoft.com", kind = "fqdn", why = "Microsoft Container Registry's data endpoints, which serve the image layers" },
      { destination = "packages.aks.azure.com", kind = "fqdn", why = "Where the nodes under the environment download their own components. Learn lists it for every environment, whatever the apps use" },
      { destination = "acs-mirror.azureedge.net", kind = "fqdn", why = "Where the nodes under the environment download their own components, beside packages.aks.azure.com. Learn lists it for every environment, whatever the apps use" },
      { destination = "AzureActiveDirectory", kind = "service_tag", why = "Microsoft Entra ID: the managed identities get their tokens from it, for the registry pull, Key Vault references, and Postgres and Redis with database_auth = \"entra\"" },
      { destination = "login.microsoftonline.com", kind = "fqdn", why = "Microsoft Entra ID, for a firewall that admits by name" },
      { destination = "*.login.microsoftonline.com", kind = "fqdn", why = "Microsoft Entra ID's regional sign-in endpoints for managed identities" },
      { destination = "login.microsoft.com", kind = "fqdn", why = "Microsoft Entra ID's sign-in endpoint by its bare name, which Learn lists for pulls from an Azure container registry and for Key Vault. A rule for *.login.microsoft.com does not match it" },
      { destination = "*.login.microsoft.com", kind = "fqdn", why = "Microsoft Entra ID's sign-in endpoints for managed identities" },
      { destination = "*.identity.azure.net", kind = "fqdn", why = "The managed identity endpoints the environment's identities use" },
      { destination = "AzureMonitor", kind = "service_tag", why = "Azure Monitor: the environment sends the apps' console and system logs through it. Blocked, new rows stop arriving in ContainerAppConsoleLogs and ContainerAppSystemLogs while the apps keep serving" },
      { destination = "AzureContainerRegistry", kind = "service_tag", why = "Azure Container Registry, for a firewall or NSG that admits by service tag: the apps' images are pulled from an Azure container registry. Blocked, a new revision has no ready replica. Not needed while every image is pulled over a private endpoint (registry_private_endpoint = true) or from a registry of another kind" },
      { destination = "Storage.${local.location_key}", kind = "service_tag", why = "Azure Storage in the install's region (Learn's Storage.<Region>, with the region as the location input names it, where Microsoft's list of service tags capitalises it): an Azure container registry serves its image layers from storage. Not needed where AzureContainerRegistry is not. A registry in another region serves its layers from that region's storage, which *.blob.core.windows.net in the registry's own entries covers by name" },
      # Learn's pages do not list Azure management for the environment itself: ADR 0120 §5 adds it
      # to the platform set, so these two name the ADR as their source and not a page.
      { destination = "AzureResourceManager", kind = "service_tag", why = "Azure management (Azure Resource Manager), part of the Container Apps platform set ADR 0120 §5 publishes for every subnet", source = local.outbound_adr_source },
      { destination = "management.azure.com", kind = "fqdn", why = "Azure management (Azure Resource Manager), for a firewall that admits by name", source = local.outbound_adr_source },
      ] : "${e.kind}:${e.destination}:443" => {
      destination = e.destination
      kind        = e.kind
      protocol    = "TCP"
      ports       = ["443"]
      why         = e.why
      source      = lookup(e, "source", local.outbound_learn_source[e.kind])
    }
  }

  # The registry the apps pull from: the login server and the hosts the image references name.
  # None with registry_private_endpoint, which keeps the pull on the registry's private endpoint.
  # Normalize implicit HTTPS ports before deduplicating registry authorities.
  outbound_registry_hosts = local.registry_private_endpoint ? [] : distinct([
    for h in compact([for r in [local.registry_server, local.api_image, local.frontend_image] : lower(split("/", r)[0])]) :
    "${split(":", h)[0]}:${try(split(":", h)[1], "443")}"
  ])

  outbound_registry_entries = merge(
    {
      for h in local.outbound_registry_hosts : "fqdn:${split(":", h)[0]}:${try(split(":", h)[1], "443")}" => {
        destination = split(":", h)[0]
        kind        = "fqdn"
        protocol    = "TCP"
        ports       = [try(split(":", h)[1], "443")]
        why         = "The image registry's login server: every app's image is pulled from it, so a new revision has no ready replica while it is blocked. registry_private_endpoint = true keeps the pull inside the VNet instead"
        source      = "registry_location, api_image and frontend_image; ${local.outbound_registry_source}"
      }
    },
    anytrue([for h in local.outbound_registry_hosts : endswith(split(":", h)[0], ".azurecr.io")]) ? local.outbound_acr_data_entries : {},
  )

  # Where an Azure container registry serves its image layers, beside its login server.
  outbound_acr_data_entries = {
    "fqdn:*.data.azurecr.io:443" = {
      destination = "*.data.azurecr.io"
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "An Azure container registry's dedicated data endpoints (<registry>.<region>.data.azurecr.io), which serve the image layers when the registry has them"
      source      = local.outbound_registry_source
    }
    "fqdn:*.blob.core.windows.net:443" = {
      destination = "*.blob.core.windows.net"
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "An Azure container registry's storage, which serves the image layers when the registry has no dedicated data endpoints"
      source      = local.outbound_registry_source
    }
  }

  # scheme://[userinfo@]host[:port][/path][?query], read for its host and port only, never its
  # userinfo. A URL with an @ after its authority (a password holding an unencoded /, ? or #)
  # matches nothing, so it gives no entry rather than a fragment of the password. An IPv6 host
  # matches with its brackets, which the entries trim: a firewall rule names the bare address.
  outbound_url_pattern = "^[A-Za-z][A-Za-z0-9+.-]*://(?:[^/?#]*@)?([^/?#:@\\[\\]]+|\\[[^\\]/?#@]+\\])(?::([0-9]{1,5}))?(?:[/?#][^@]*)?$"

  # ca-edge's image is on Docker Hub when edge.image is unset (the image the module pins names
  # docker.io) or names Docker Hub itself, under any of its three names and in any case. A pull
  # from Docker Hub uses Docker Hub's pull hosts whichever name the reference carries.
  outbound_docker_hub_names = ["docker.io", "index.docker.io", "registry-1.docker.io"]
  outbound_edge_docker_hub  = local.edge_enabled && contains(local.outbound_docker_hub_names, split(":", lower(split("/", local.edge_image)[0]))[0])
  outbound_edge_jwt_authn   = local.edge_enabled ? var.edge.jwt_authn != null : false

  # The inputs that name a destination, each only where a workload uses it.
  outbound_url_inputs = {
    oidc_authority         = var.identity_binding == "oidc" ? local.oidc_authority : null
    oidc_jwks_uri          = var.identity_binding == "oidc" || local.outbound_edge_jwt_authn ? local.oidc_jwks_uri : null
    license_issuer_url     = local.license_refresh_configured ? var.license_issuer_url : null
    telemetry_url          = local.telemetry_configured ? var.telemetry_url : null
    frontend_custom_domain = local.frontend_custom_domain ? var.frontend_custom_domain.certificate_key_vault_secret_id : null
    edge_custom_domain     = local.edge_custom_domain ? var.edge_custom_domain.certificate_key_vault_secret_id : null
  }

  outbound_url_why = {
    oidc_authority         = "Your identity provider's issuer (oidc_authority): ca-frontend's BFF reads the discovery document to sign users in. If discovery names a token endpoint on another host or port, admit that destination from ca-frontend's subnet too: this entry covers only the issuer's host and port"
    oidc_jwks_uri          = "Your identity provider's signing keys (oidc_jwks_uri): ca-api fetches them to validate tokens, and so does ca-edge with edge.jwt_authn"
    license_issuer_url     = "Masterly's control plane (license_issuer_url): the daily licence refresh. After seven days without a successful refresh the install is read-only"
    telemetry_url          = "Masterly's control plane (telemetry_url): fleet usage reports"
    frontend_custom_domain = "Your Key Vault holding the frontend_custom_domain certificate: the environment reads the certificate from it. Not needed when the environment reaches that vault over a private endpoint"
    edge_custom_domain     = "Your Key Vault holding the edge_custom_domain certificate: the environment reads the certificate from it. Not needed when the environment reaches that vault over a private endpoint"
  }

  # Callers may mark any URL sensitive. Declassify only its parsed host/port and the presence
  # and parse-success booleans, keeping the URL itself (including path and userinfo) sensitive.
  outbound_url_entries = {
    for name, url in local.outbound_url_inputs : name => {
      "fqdn:${nonsensitive(trim(lower(regex(local.outbound_url_pattern, url)[0]), "[]"))}:${nonsensitive(coalesce(regex(local.outbound_url_pattern, url)[1], startswith(lower(url), "http://") ? "80" : "443"))}" = {
        destination = nonsensitive(trim(lower(regex(local.outbound_url_pattern, url)[0]), "[]"))
        kind        = "fqdn"
        protocol    = "TCP"
        ports       = [nonsensitive(coalesce(regex(local.outbound_url_pattern, url)[1], startswith(lower(url), "http://") ? "80" : "443"))]
        why         = local.outbound_url_why[name]
        source      = name
      }
    } if nonsensitive(url != null) && nonsensitive(can(regex(local.outbound_url_pattern, url)))
  }

  # BYO-DB. external_database_url (and the admin URL) are sensitive: only the parsed host and
  # port are unmarked, and only the null test on the URL, never the URL itself.
  outbound_database_entries = {
    for name, url in {
      external_database_url       = var.external_database_url
      external_database_admin_url = local.migrate_job ? var.external_database_admin_url : null
      } : name => {
      "fqdn:${nonsensitive(trim(lower(regex(local.outbound_url_pattern, url)[0]), "[]"))}:${nonsensitive(coalesce(regex(local.outbound_url_pattern, url)[1], "5432"))}" = {
        destination = nonsensitive(trim(lower(regex(local.outbound_url_pattern, url)[0]), "[]"))
        kind        = "fqdn"
        protocol    = "TCP"
        ports       = [nonsensitive(coalesce(regex(local.outbound_url_pattern, url)[1], "5432"))]
        why         = name == "external_database_url" ? "Your own Postgres (BYO-DB): ca-api, ca-workers and caj-migrate connect to it. Not needed when the server is reached over peering or a private endpoint in the VNet" : "Your own Postgres, for caj-migrate's migration role (BYO-DB). Not needed when the server is reached over peering or a private endpoint in the VNet"
        source      = name
      }
    } if nonsensitive(url != null) && nonsensitive(can(regex(local.outbound_url_pattern, url)))
  }

  # The install's own services, where they keep a public endpoint. Their names carry the install's
  # random suffix, so a fresh install's plan shows these destinations as known after apply.
  outbound_key_vault_entries = var.enable_key_vault && local.key_vault_public ? {
    "key-vault" = {
      destination = "${azurerm_key_vault.this[0].name}.vault.azure.net"
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "The install's Key Vault, public outside mode = \"production\": the environment resolves the apps' Key Vault references from it, so a revision whose secrets are references does not start while it is blocked. In production it is reached over its private endpoint and has no entry"
      source      = "enable_key_vault"
    }
  } : {}

  # The audit vault (keyvault.tf) is allowlisted for ca-api and ca-workers alone: they are the only
  # workloads holding a role on it. Application use requires a release that reads its URL.
  outbound_audit_key_vault_entries = var.enable_key_vault && local.key_vault_public ? {
    "audit-key-vault" = {
      destination = "${azurerm_key_vault.audit[0].name}.vault.azure.net"
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "The install's audit Key Vault, public outside mode = \"production\": reserved for the audit checkpoint key and head, for an application release that reads MASTERLY_AUDIT_KEYVAULT_URL. Until then those objects remain in the main vault under its existing grants. In production the audit vault has a private endpoint and no allowlist entry"
      source      = "enable_key_vault"
    }
  } : {}

  outbound_service_bus_entries = var.enable_service_bus && !local.servicebus_private ? {
    "service-bus" = {
      destination = "${azurerm_servicebus_namespace.this[0].name}.servicebus.windows.net"
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["5671", "443"]
      why         = "The install's Service Bus namespace, public except Premium in production: ca-api sends and ca-workers receives the work handed over the bus"
      source      = "enable_service_bus"
    }
  } : {}

  outbound_acs_entries = var.email_acs_enabled ? {
    "communication-services" = {
      destination = trimprefix(module.acs_email[0].endpoint, "https://")
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "The install's Azure Communication Services resource: email is sent through it"
      source      = "email_acs_enabled"
    }
  } : {}

  outbound_docker_hub_entries = local.outbound_edge_docker_hub ? {
    for h in ["registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com"] : "fqdn:${h}:443" => {
      destination = h
      kind        = "fqdn"
      protocol    = "TCP"
      ports       = ["443"]
      why         = "Docker Hub: ca-edge pulls its image from it, anonymously: the upstream Envoy image the module pins, or the Docker Hub image edge.image names. Set edge.image to a mirror in your own registry to remove it"
      source      = try(var.edge.image, null) == null ? "edge (edge.image unset)" : "edge.image"
    }
  } : {}

  # edge.image on a registry other than Docker Hub and the install's is pulled from that
  # registry's host.
  outbound_edge_image_host = local.edge_enabled && !local.outbound_edge_docker_hub && !(local.edge_image_on_registry && local.registry_private_endpoint) ? lower(split("/", local.edge_image)[0]) : null
  outbound_edge_image_entries = local.outbound_edge_image_host == null ? {} : merge(
    {
      "fqdn:${split(":", local.outbound_edge_image_host)[0]}:${try(split(":", local.outbound_edge_image_host)[1], "443")}" = {
        destination = split(":", local.outbound_edge_image_host)[0]
        kind        = "fqdn"
        protocol    = "TCP"
        ports       = [try(split(":", local.outbound_edge_image_host)[1], "443")]
        why         = "The registry edge.image names: ca-edge's image is pulled from it"
        source      = "edge.image"
      }
    },
    try(endswith(split(":", local.outbound_edge_image_host)[0], ".azurecr.io"), false) ? local.outbound_acr_data_entries : {},
  )

  outbound_control_plane_entries = merge(
    try(local.outbound_url_entries["license_issuer_url"], {}),
    try(local.outbound_url_entries["telemetry_url"], {}),
  )

  # What each workload reaches, beyond the registry and the platform set. Postgres, Redis, Service
  # Bus and Communication Services sit only with ca-api, ca-workers and caj-migrate, so a subnet
  # holding only ca-frontend and ca-edge (front) never lists a data endpoint (ADR 0120 §5).
  #
  # The control plane (license_issuer_url, telemetry_url) sits with ca-workers alone when
  # enable_workers is set, though ca-api gets the same URLs and install credential. The released
  # api images from v0.133.4 onward, including v0.138.0 recorded in MANIFEST.json, run the licence
  # refresh and fleet reports only in the process that runs the pipeline: ca-api without
  # enable_workers, and ca-workers with it. tests/outbound_allowlist.tftest.hcl checks the image floor.
  outbound_workload_entries = {
    "ca-frontend" = merge(
      try(local.outbound_url_entries["oidc_authority"], {}),
      try(local.outbound_url_entries["frontend_custom_domain"], {}),
      local.outbound_key_vault_entries,
    )
    "ca-edge" = merge(
      local.outbound_docker_hub_entries,
      local.outbound_edge_image_entries,
      local.outbound_edge_jwt_authn ? try(local.outbound_url_entries["oidc_jwks_uri"], {}) : {},
      try(local.outbound_url_entries["edge_custom_domain"], {}),
    )
    "ca-api" = merge(
      var.identity_binding == "oidc" ? try(local.outbound_url_entries["oidc_jwks_uri"], {}) : {},
      local.outbound_key_vault_entries,
      local.outbound_audit_key_vault_entries,
      local.outbound_service_bus_entries,
      local.outbound_acs_entries,
      try(local.outbound_database_entries["external_database_url"], {}),
      var.enable_workers ? {} : local.outbound_control_plane_entries,
    )
    "ca-workers" = merge(
      local.outbound_key_vault_entries,
      local.outbound_audit_key_vault_entries,
      local.outbound_service_bus_entries,
      local.outbound_acs_entries,
      try(local.outbound_database_entries["external_database_url"], {}),
      local.outbound_control_plane_entries,
    )
    "caj-migrate" = merge(
      local.outbound_key_vault_entries,
      try(local.outbound_database_entries["external_database_admin_url"], local.outbound_database_entries["external_database_url"], {}),
    )
  }

  # Which subnet each workload that exists runs on: "aca" is aca-<prefix> on snet-aca.
  outbound_workload_subnet = merge(
    { "ca-frontend" = var.frontend_environment, "ca-api" = var.api_environment },
    local.edge_enabled ? { "ca-edge" = var.edge_environment } : {},
    var.enable_workers ? { "ca-workers" = var.workers_environment == "workers" ? "workers" : "aca" } : {},
    local.migrate_job ? { "caj-migrate" = var.migrate_job_environment == "workers" ? "workers" : "aca" } : {},
  )

  outbound_allowlist = {
    for s in local.install_environment_keys : s => values(merge(
      merge([for w, ws in local.outbound_workload_subnet : local.outbound_workload_entries[w] if ws == s]...),
      local.outbound_registry_entries,
      local.outbound_platform_entries,
    ))
  }
}
