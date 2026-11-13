# Network: topologies, subnets, DNS, egress and the api's ingress (network.tf).
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

# Landing zone: an injected central privatelink zone suppresses zone + link creation
# but keeps the server and its private endpoint.
run "injected_dns_zone_creates_no_zone" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    postgres_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.postgres) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.postgres) == 0 &&
      length(azurerm_postgresql_flexible_server.this) == 1 &&
      length(azurerm_private_endpoint.postgres) == 1
    )
    error_message = "postgres_private_dns_zone_id must suppress zone + link creation only."
  }
}

# Guard: a VNet smaller than /21 must bring explicit subnet prefixes.
run "small_vnet_without_explicit_subnets_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    vnet_address_space    = ["10.99.0.0/24"]
  }

  expect_failures = [var.vnet_address_space]
}

# Small VNet WITH explicit prefixes is fine.
run "small_vnet_with_explicit_subnets_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    vnet_address_space              = ["10.99.0.0/22"]
    aca_subnet_prefix               = "10.99.0.0/23"
    private_endpoints_subnet_prefix = "10.99.2.0/24"
  }

  assert {
    condition     = azurerm_subnet.aca[0].address_prefixes[0] == "10.99.0.0/23"
    error_message = "Explicit aca_subnet_prefix must be used verbatim."
  }
}

# --- The three network topologies the module serves without a fork -----------------------
# 1. public ingress behind an IP allowlist (the default, covered throughout above)
# 2. private ingress, reached over VPN/ExpressRoute
# 3. hub-and-spoke: subnets injected, the module owns no network at all

# The module builds its own VNet unless told otherwise — topology 1.
run "default_topology_owns_its_network" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 1 && length(azurerm_subnet.aca) == 1
    error_message = "With no subnets injected the module must create its own VNet and subnets."
  }

  assert {
    condition     = module.aca_env.internal_load_balancer_enabled == false
    error_message = "The default topology keeps the environment's public endpoint."
  }
}

# The subnets the module owns are filtered deny-by-default. A subnet with no NSG inherits
# Azure's default set, which allows the whole VirtualNetwork tag inbound — this VNet plus
# every peered network and every on-premises range behind a gateway attached to it.
run "nsgs_present_when_module_owns_network" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      length(azurerm_network_security_group.aca) == 1 &&
      length(azurerm_network_security_group.private_endpoints) == 1
    )
    error_message = "Both subnets the module creates must get a network security group."
  }

  assert {
    condition = (
      length(azurerm_subnet_network_security_group_association.aca) == 1 &&
      length(azurerm_subnet_network_security_group_association.private_endpoints) == 1
    )
    error_message = "An NSG that is never associated with its subnet filters nothing."
  }

  # The deny is the rule every other rule is an exception to; without it the NSG only adds
  # to Azure's permissive defaults instead of replacing them.
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.aca[0].security_rule :
      rule.access == "Deny" &&
      rule.direction == "Inbound" &&
      rule.protocol == "*" &&
      rule.source_address_prefix == "*" &&
      rule.destination_port_range == "*"
      if rule.name == "deny-all-inbound"
    ])
    error_message = "The runtime subnet's NSG must deny every inbound flow it did not admit."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.private_endpoints[0].security_rule :
      rule.access == "Deny" &&
      rule.direction == "Inbound" &&
      rule.protocol == "*" &&
      rule.source_address_prefix == "*" &&
      rule.destination_port_range == "*"
      if rule.name == "deny-all-inbound"
    ])
    error_message = "The endpoints subnet's NSG must deny every inbound flow it did not admit."
  }

  # Container Apps platform requirements for a Consumption-only environment. They are
  # harmless while nothing denies, and load-bearing the moment something does: drop either
  # one and the environment provisions and then serves nothing.
  assert {
    condition = length([
      for rule in azurerm_network_security_group.aca[0].security_rule : rule.name
      if contains(["allow-container-apps-load-balancer", "allow-environment-internal"], rule.name)
    ]) == 2
    error_message = "The runtime subnet's NSG must keep the Container Apps platform rules alongside the deny."
  }

  # Topology 1 is reached from the internet; the internal-load-balancer source is asserted
  # in private_ingress_topology below.
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.aca[0].security_rule :
      rule.source_address_prefix == "Internet" &&
      contains(rule.destination_port_ranges, "443") &&
      contains(rule.destination_port_ranges, "80")
      if rule.name == "allow-app-ingress"
    ])
    error_message = "The default topology must admit the apps' ingress from the internet on 443 and 80."
  }

  # The apps are the only caller the data plane has, and these are the ports it answers on.
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.private_endpoints[0].security_rule :
      rule.source_address_prefix == azurerm_subnet.aca[0].address_prefixes[0] &&
      alltrue([
        for port in ["5432", "10000", "6380", "443"] : contains(rule.destination_port_ranges, port)
      ])
      if rule.name == "allow-data-plane-from-apps"
    ])
    error_message = "The endpoints subnet must admit Postgres, Redis and Key Vault from the runtime subnet only."
  }

  # An NSG on a private-endpoint subnet applies to private-endpoint traffic only once
  # network policies are enabled there. Disabled, the rules above would be inert.
  assert {
    condition     = azurerm_subnet.private_endpoints[0].private_endpoint_network_policies == "Enabled"
    error_message = "private_endpoint_network_policies must be Enabled, or the endpoints subnet's NSG does not apply to the endpoints."
  }
}

# Topology 2: internal load balancer, no public endpoint. The frontend stays `external`
# because on an internal environment that means "reachable from the VNet", which is
# exactly what a VPN user needs.
run "private_ingress_topology" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
  }

  assert {
    condition     = module.aca_env.internal_load_balancer_enabled == true
    error_message = "aca_internal_load_balancer must reach the Container App Environment."
  }

  # There is no public endpoint on this topology, so admitting the Internet tag would
  # describe a path that does not exist. VirtualNetwork covers the VPN and ExpressRoute
  # address spaces this install is actually reached from.
  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.aca[0].security_rule :
      rule.source_address_prefix == "VirtualNetwork"
      if rule.name == "allow-app-ingress"
    ])
    error_message = "An internal-load-balancer install must admit its ingress from VirtualNetwork, not from the internet."
  }
}

# Guard: the footgun that makes an install unreachable from anywhere, including VPN.
run "internal_lb_with_unexposed_frontend_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    frontend_ingress_external  = false
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Topology 3: the platform team owns the spoke; the module creates no network.
run "injected_network_creates_no_network" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aca) == 0 && length(azurerm_subnet.private_endpoints) == 0
    error_message = "Injecting subnets must create no VNet and no subnets — the platform team owns them."
  }

  # The VNet is derived from the subnet id rather than asked for, so the two cannot disagree.
  assert {
    condition     = local.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    error_message = "The VNet id must be derived from the injected subnet id."
  }
}

# ...and no network security groups either. An injected subnet belongs to the platform
# team, and a subnet holds exactly one NSG: associating one here would replace whatever
# they attached, silently and from outside their own configuration. The baseline those
# subnets are expected to carry is documented instead (docs/networking.md).
run "nsgs_absent_when_network_injected" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  assert {
    condition = (
      length(azurerm_network_security_group.aca) == 0 &&
      length(azurerm_network_security_group.private_endpoints) == 0 &&
      length(azurerm_subnet_network_security_group_association.aca) == 0 &&
      length(azurerm_subnet_network_security_group_association.private_endpoints) == 0
    )
    error_message = "Injecting subnets must create no network security group and no association — the platform team owns both."
  }
}

# Guard: half an injected network.
run "half_injected_network_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    aca_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Guard: private endpoints cannot live in the delegated ACA subnet.
run "same_subnet_twice_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# --- The egress guard's override (MAS-432) -------------------------------------------------
# The documented remedy for a self-hosted BYO-DB Environment whose database sits on a private
# address. It was documented as an operator setting the module could not make: the container's
# environment is a closed map and `ignore_changes` deliberately does not cover it, so a value
# put on the app with `az containerapp update` was removed again by the next apply. These runs
# assert the variable lands in the env the container apps are actually built with -- through
# module.<app>.env_names, which is `keys(var.env)` INSIDE the submodule, so the assertion fails
# if the map stops crossing the module boundary -- rather than off the variable declaration.

run "private_egress_override_is_absent_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  # Absent, not "false". The application reads an UNSET value as "follow the mode" (demo allows,
  # production refuses); writing false would be an override in the other direction and would
  # change what an evaluation install does the moment it upgrades to this module version.
  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "allow_private_egress = false must set nothing at all, leaving the application's mode-gated posture in force."
  }

  assert {
    condition     = !contains(module.api.env_names, "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "The default must not put the egress override on ca-api."
  }

  # The allowlist (MAS-655) is absent by default for the same reason: an empty list is "follow
  # the mode", and writing an empty string would be a setting the application has to parse.
  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS")
    error_message = "allowed_private_egress_cidrs = [] must set nothing at all."
  }
}

# The shape the card was filed against: self-hosted, production, BYO-DB on a private address.
run "private_egress_override_reaches_the_backend_apps" {
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
    allow_private_egress  = true
  }

  # The value the application parses, verbatim. A bool rendered any other way is a string the
  # settings model would reject, and the guard would stay on with the input set.
  assert {
    condition     = local.api_env["MASTERLY_ALLOW_PRIVATE_EGRESS"] == "true"
    error_message = "allow_private_egress = true must set MASTERLY_ALLOW_PRIVATE_EGRESS to the string \"true\"."
  }

  assert {
    condition = (
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_ALLOW_PRIVATE_EGRESS"]) == "true" &&
      !contains([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.name], "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS")
    )
    error_message = "The migrate job must carry the same legacy private-egress override as the serving apps, without a CIDR allowlist."
  }

  # ca-api resolves a BYO-DB Environment's connection (core/tenancy) -- the seam that refuses
  # a private database host on a production install.
  assert {
    condition     = contains(module.api.env_names, "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "The egress override must reach ca-api's container environment."
  }

  # ca-workers runs the same image and the async pipeline behind it: stream push delivery,
  # webhook and SMTP delivery all call the same guard, so an override the api has and the
  # workers do not would fix the create call and leave every job refusing.
  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "The egress override must reach ca-workers too -- the pipeline makes the same guarded connections."
  }

  # And not the frontend, which is a different image that reads no such setting. Its env is
  # built separately in main.tf; this pins that the override does not drift into it.
  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "The egress override is a backend setting -- the frontend must not carry it."
  }
}

# --- The egress allowlist (MAS-655) ---------------------------------------------------------
# The override above switched the guard off entirely. The allowlist names the private ranges
# the application may connect into, and the deprecated flag stays for one release. These runs
# pin the wiring (the joined list reaches the two backend apps and not the frontend), the three
# plan-time refusals (no prefix length, a never-admitted range, both inputs at once), and that
# the two variables are never written together.

run "private_egress_allowlist_reaches_the_backend_apps" {
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

    external_database_url        = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    allowed_private_egress_cidrs = ["10.20.0.0/16", "fd00:1::/64", "10.30.3.4/32"]
  }

  # Comma-joined, in the order given, verbatim: the application splits on commas and parses
  # each entry as a network, so any other rendering is a value it refuses at startup.
  assert {
    condition     = local.api_env["MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS"] == "10.20.0.0/16,fd00:1::/64,10.30.3.4/32"
    error_message = "allowed_private_egress_cidrs must reach the application as one comma-joined string."
  }

  assert {
    condition = (
      one([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.value if e.name == "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS"]) == "10.20.0.0/16,fd00:1::/64,10.30.3.4/32" &&
      !contains([for e in azurerm_container_app_job.migrate[0].template[0].container[0].env : e.name], "MASTERLY_ALLOW_PRIVATE_EGRESS")
    )
    error_message = "The migrate job must carry the serving apps' exact CIDR allowlist, without enabling the legacy private-egress override."
  }

  assert {
    condition     = contains(module.api.env_names, "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS")
    error_message = "The egress allowlist must reach ca-api's container environment."
  }

  assert {
    condition     = contains(module.workers[0].env_names, "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS")
    error_message = "The egress allowlist must reach ca-workers too -- the pipeline makes the same guarded connections."
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS")
    error_message = "The egress allowlist is a backend setting -- the frontend must not carry it."
  }

  # The list alone: the deprecated flag is not written beside it.
  assert {
    condition     = !contains(keys(local.api_env), "MASTERLY_ALLOW_PRIVATE_EGRESS")
    error_message = "An install on the allowlist must not also carry the deprecated override."
  }
}

# Guard: an entry without a prefix length is not a range.
run "private_egress_allowlist_refuses_an_entry_without_a_prefix" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    allowed_private_egress_cidrs = ["10.20.0.0/16", "10.30.3.4"]
  }

  expect_failures = [var.allowed_private_egress_cidrs]
}

# Guard: the ranges the application never admits are refused at plan, not at startup.
run "private_egress_allowlist_refuses_a_never_admitted_range" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    allowed_private_egress_cidrs = ["10.20.0.0/16", "169.254.0.0/16"]
  }

  expect_failures = [var.allowed_private_egress_cidrs]
}

# Guard: the "everything" spelling is refused for the same reason -- it cannot mean that.
run "private_egress_allowlist_refuses_a_zero_prefix" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    allowed_private_egress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_private_egress_cidrs]
}

# Guard: the list and the deprecated flag are one setting, not two.
run "private_egress_allowlist_refuses_the_deprecated_flag_beside_it" {
  command = plan

  variables {
    ingress_allowed_cidrs        = ["203.0.113.7/32"]
    allowed_private_egress_cidrs = ["10.20.0.0/16"]
    allow_private_egress         = true
  }

  expect_failures = [var.allowed_private_egress_cidrs]
}

# --- The api's ingress: internal by default, opt-out, never unrestricted --------------------
# The published Python SDK talks to the api directly (bearer token to /v1), not through the
# frontend's BFF — which proxies /api/proxy/... with session cookies and short-circuits
# unauthenticated requests without forwarding. While the api was hardcoded internal, no
# self-hosted install could be reached by the SDK we publish and document.

run "the_api_is_internal_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.api.ingress_external == false
    error_message = "The api must stay internal unless asked for: it sits behind the BFF."
  }

  # Plain HTTP is deliberate while the api is unreachable from outside: the hop it serves is
  # the BFF's http://ca-api, and https://ca-api cannot pass hostname verification against the
  # environment's certificate. What keeps that hop off the wire in the clear is the
  # environment's peer encryption, asserted below, not this flag.
  assert {
    condition     = module.api.ingress_allow_insecure == true
    error_message = "An internal api must still serve the BFF's http:// hop."
  }
}

run "api_ingress_can_be_opted_into_and_is_narrowed" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
  }

  assert {
    condition     = module.api.ingress_external == true
    error_message = "api_ingress_external must reach the api app."
  }

  # The flag being set proves nothing about who can reach it. Until this assertion existed,
  # removing the allowlist from the api entirely still passed every test in this file.
  assert {
    condition     = module.api.ingress_allowed_ip_ranges == ["203.0.113.7/32"]
    error_message = "An externally-exposed api must carry the same allowlist the frontend does."
  }

  assert {
    condition     = module.frontend.ingress_allowed_ip_ranges == ["203.0.113.7/32"]
    error_message = "The frontend allowlist must be unaffected by the api opting in."
  }

  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "With builtin_auth unset, publishing the api must not raise the builtin_auth warning."
  }
}

# Guard: exposing /v1 to the whole internet as the price of SDK access would be a worse
# problem than the one being solved. Empty means UNRESTRICTED in Azure, not deny-all.
run "external_api_without_an_allowlist_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = []
    api_ingress_external  = true
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# The finding this closes: `allow_insecure_connections` was hardcoded true, which was
# defensible while the api was unreachable and stopped being defensible the moment
# api_ingress_external existed. Port 80 answering without a redirect, for callers whose
# whole credential is a bearer token, is what the allowlist does not cover.
run "external_api_refuses_insecure" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
  }

  assert {
    condition     = module.api.ingress_allow_insecure == false
    error_message = "A published api must redirect http:// to https://, not serve it."
  }

  # The frontend is published in every topology, so it never had a reason to allow insecure.
  # Pinned anyway: this is the assertion that fails if someone widens the api's flip into a
  # module-wide default in the wrong direction.
  assert {
    condition     = module.frontend.ingress_allow_insecure == false
    error_message = "The frontend must redirect http:// to https://."
  }
}

# api_url is the output a client's base URL is read from. Unpublished, it is null rather than the
# internal hostname: that address answers only inside the environment, and a base URL that cannot
# connect is worse than none. api_internal_fqdn stays, under its original name, for existing
# configurations.
run "api_url_is_null_while_the_api_is_internal" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = output.api_url == null
    error_message = "api_url must be null while api_ingress_external is false: an internal api has no address a client outside the environment can use."
  }
}

# Published, api_url mirrors frontend_url: the hostname Azure reports, behind https://. The
# hostname is computed, so at plan it is unknown and an assertion on it asserts nothing;
# `override_module` pins the api app's outputs to known values so the URL's shape is checkable.
# (apply is not an option — the mock provider hands out ids that the azurerm provider then
# rejects as unparseable.) A published api refuses plain HTTP (external_api_refuses_insecure),
# so an http:// base URL would be a broken one.
run "api_url_is_an_https_url_once_the_api_is_published" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_ingress_external  = true
  }

  override_module {
    target = module.api
    outputs = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
      name                      = "ca-api"
      fqdn                      = "ca-api.example.swedencentral.azurecontainerapps.io"
      memory                    = "1Gi"
      ingress_external          = true
      ingress_allow_insecure    = false
      ingress_allowed_ip_ranges = ["203.0.113.7/32"]
    }
  }

  assert {
    condition     = output.api_url == "https://ca-api.example.swedencentral.azurecontainerapps.io"
    error_message = "api_url must be https:// followed by the api's ingress hostname once api_ingress_external is true."
  }

  # The pre-existing output keeps its name and its value — the bare hostname — so a
  # configuration that already reads it plans exactly as before.
  assert {
    condition     = output.api_internal_fqdn == "ca-api.example.swedencentral.azurecontainerapps.io"
    error_message = "api_internal_fqdn must still carry the api's ingress hostname, unchanged."
  }
}

# The other half of the same finding. Flipping the api to HTTPS-only would push the plaintext
# problem onto the in-environment hop if this were not on, because the BFF keeps calling
# http://ca-api by app name — the one address that cannot drift and cannot be verified over
# TLS by the client. Azure encrypts it below the application instead.
run "the_environment_encrypts_peer_traffic" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.aca_env.mutual_tls_enabled == true
    error_message = "Traffic between apps inside the environment must be encrypted."
  }

  # The BFF still addresses the api by app name, so it is still speaking http:// — which is
  # only safe because of the assertion above. Pinned here rather than in a separate run so
  # that deleting the encryption and keeping the address cannot pass quietly.
  assert {
    condition     = contains(module.frontend.env_names, "MASTERLY_API_BASE_URL")
    error_message = "The BFF must be told where the api is."
  }
}

# An app that is ALLOWED to sit at zero replicas gets no replica-availability alert, because on
# such an install zero replicas is the intended state and the alert would page every idle night.
# The gate is per app, not per install: turn diagnostics on for an evaluation install that
# scales the api to zero and the frontend still keeps its floor, so it still keeps its alert.
# Asserting the shape of the map, not just its size — a regression that alerted on the api and
# skipped the frontend would keep the count at one (MAS-263).
run "scale_to_zero_apps_get_no_replica_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    api_min_replicas      = 0
  }

  # This run also exercises the enable_workers=false branch of the map (MAS-305): with no
  # workers app there is no id to index, and the alert must simply not be created rather than
  # the plan failing on a missing element.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 1 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "frontend")
    )
    error_message = "Only the app that declares a replica floor may carry a no-replica alert; a scale-to-zero app must not, and an install with no workers app must not claim workers coverage."
  }

  # The database alerts do not depend on replica counts at all: this install provisions the
  # starter server, so postgres-unavailable is present (in every mode), and enabling
  # diagnostics adds postgres-silent beside it.
  assert {
    condition = (
      length(azurerm_monitor_metric_alert.postgres_unavailable) == 1 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.postgres_silent) == 1
    )
    error_message = "Enabling diagnostics outside production must still bring the database availability alerts."
  }

  # Turning diagnostics on outside production does NOT turn on the apps' metric ingest: its
  # default is production only, because it is a standing cost (ADR 0080, amendment of
  # 2026-10-07). An evaluation install opts in with enable_app_availability_diagnostics = true.
  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 0
    )
    error_message = "App availability diagnostics must stay off outside production unless enable_app_availability_diagnostics is set."
  }
}

# The opt-in outside production, and the replica-floor gate. Every app that exists gets the
# diagnostic setting, but only an app with a floor gets the absence rule: a scale-to-zero api
# publishes nothing while it sits at zero, which is its intended state.
#
# Not asserted, for the reason the postgres_silent query text is not (see the starter-server
# run above): each rule's query interpolates its app's resource id, which is unknown at plan
# under mock providers, so the whole string is unknown here. Reviewing the interpolation in
# diagnostics.tf is what covers that each rule reads AzureMetrics for its own app.
run "app_availability_diagnostics_opt_in_outside_production" {
  command = plan

  variables {
    ingress_allowed_cidrs               = ["203.0.113.7/32"]
    enable_diagnostics                  = true
    enable_app_availability_diagnostics = true
    enable_workers                      = true
    api_min_replicas                    = 0
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 3 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 2 &&
      contains(keys(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent), "frontend") &&
      contains(keys(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent), "workers")
    )
    error_message = "Opted in, every app must get the diagnostic setting, and only the apps with a replica floor the absence rule."
  }
}

# The opt-out, in production: both halves go, and the replica alerts stay. The opt-out is for
# the ingest cost; it must not take the rest of the availability set with it.
run "app_availability_diagnostics_opt_out_in_production" {
  command = plan

  variables {
    mode                                = "production"
    identity_binding                    = "oidc"
    oidc_allowed_issuers                = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience                       = "api-client-id"
    oidc_jwks_uri                       = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id                      = "bff-client-id"
    oidc_client_secret                  = "s3cret"
    oidc_authority                      = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri                   = "https://app.example.com/api/auth/callback"
    license_token                       = "eyJ.fake.jwt"
    license_public_jwk                  = "{\"kty\":\"EC\"}"
    initial_owner_email                 = "owner@example.com"
    enable_key_vault                    = true
    enable_redis                        = true
    redis_offering                      = "cache"
    enable_workers                      = true
    api_max_replicas                    = 3
    enable_app_availability_diagnostics = false

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  assert {
    condition = (
      length(azurerm_monitor_diagnostic_setting.app) == 0 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_silent) == 0 &&
      length(azurerm_monitor_metric_alert.app_unavailable) == 3 &&
      length(azurerm_monitor_scheduled_query_rules_alert_v2.app_not_ready) == 1
    )
    error_message = "enable_app_availability_diagnostics = false must remove the app diagnostic settings and absence rules, and keep the replica and readiness alerts."
  }
}

# true with diagnostics off is refused rather than ignored: the input would otherwise read as
# coverage the install does not have.
run "app_availability_diagnostics_without_diagnostics_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs               = ["203.0.113.7/32"]
    enable_app_availability_diagnostics = true
  }

  expect_failures = [var.enable_app_availability_diagnostics]
}

# ca-workers earns a no-replica alert on the same terms as the serving apps, and outside
# production too (MAS-305). This is the case the rest of the alert set structurally cannot
# reach: the workers app has no ingress, so it emits no Requests on any dimension and the 5xx
# alert is blind to it by construction — the api and the frontend go on answering normally
# while every ingest run, scan and materialization job behind them stalls.
run "workers_gets_a_no_replica_alert_when_enabled" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    enable_workers        = true
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 3 &&
      contains(keys(azurerm_monitor_metric_alert.app_unavailable), "workers")
    )
    error_message = "An install running ca-workers must carry a no-replica alert for it, not only for the two serving apps."
  }

  # Two properties are NOT asserted here, named rather than left as silent gaps — the same limit
  # the database availability alerts hit further up this file. Both are built from resource ids,
  # which are unknown until apply, so under mock providers the condition is unknowable and the
  # run errors instead of failing:
  #
  #  * that the alert's SCOPE is the ca-workers app rather than one of its siblings. A scope
  #    copied from the api would give a correctly-named alert watching the wrong resource —
  #    green forever while the pipeline is dead.
  #  * that it ROUTES to the install's action group when one is configured. `action` is a set of
  #    objects whose action_group_id is unknown at plan, which makes even its length unknown.
  #
  # What covers both is that this alert is the SAME resource block as the serving apps' — one
  # for_each over local.availability_alertable_apps, where the map value IS the scope and the
  # action block is the shared dynamic. Reviewing diagnostics.tf is what checks it; splitting
  # workers into a resource of its own is the change that would need a new gate here.
}

# The floor gate applies to workers exactly as it applies to the serving apps. An install that
# has deliberately set workers_min_replicas = 0 has chosen a stalled pipeline while idle —
# nothing HTTP-wakes an ingress-less polling loop — and paging it every night would teach the
# operator to mute the one alert that says the pipeline is gone.
run "workers_at_zero_floor_gets_no_replica_alert" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_diagnostics    = true
    enable_workers        = true
    workers_min_replicas  = 0
  }

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.app_unavailable) == 2 &&
      !contains(keys(azurerm_monitor_metric_alert.app_unavailable), "workers")
    )
    error_message = "A workers app allowed to sit at zero replicas must not carry a no-replica alert; the serving apps still must."
  }

  # Floor 0 below the default ceiling of 1, on the polling binding: the workers have no scale
  # rule, so they stay at 0, and the module says so.
  expect_failures = [check.workers_scale_on_the_polling_binding]
}
