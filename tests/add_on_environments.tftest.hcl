# The add-on environments of ADR 0120 §4 (split_processing: core and outbound; extensions: an
# extension environment of its own): their inputs, subnets, network security groups, private-endpoint
# admission, environments, zone redundancy and refusals, across main.tf, network.tf and
# environment.tf. A file of its own because the add-ons touch all three concerns, and so that the
# network and environment files keep proving, unchanged, that an install without them plans as before.
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`).
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.
#
# The default VNet, 10.20.0.0/16, derives snet-aca 10.20.0.0/23, the endpoints /24 10.20.4.0/24,
# front, app and workers at 10.20.5-7.0/24, and with the add-ons core 10.20.8.0/24, outbound
# 10.20.9.0/24 and extension 10.20.10.0/24.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
}

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

# --- Off by default -----------------------------------------------------------------------------

# Both add-ons off: the install plans exactly the three baseline environments, subnets and groups,
# and the endpoints subnet exactly its existing rules. Nothing an existing install has changes.
run "defaults_add_no_add_on_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = !var.split_processing && !var.extensions
    error_message = "split_processing and extensions must default to false."
  }

  assert {
    condition = (
      toset(keys(module.environments)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_subnet.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_network_security_group.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_subnet_network_security_group_association.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_monitor_diagnostic_setting.environment)) == toset(["front", "app", "workers"])
    )
    error_message = "With both add-ons off, only the front, app and workers environments, subnets, groups and diagnostic settings may be planned."
  }

  assert {
    condition = toset([for r in azurerm_network_security_group.private_endpoints[0].security_rule : r.name]) == toset([
      "allow-data-plane-from-apps", "allow-data-plane-from-app-subnet", "allow-data-plane-from-workers-subnet", "deny-all-inbound",
    ])
    error_message = "With both add-ons off, the endpoints subnet must keep exactly its existing rules."
  }

  assert {
    condition = (
      toset(keys(output.environment_subnet_ids)) == toset(["front", "app", "workers"]) &&
      toset(keys(output.environment_subnet_prefixes)) == toset(["front", "app", "workers"]) &&
      toset(keys(output.container_app_environments)) == toset(["front", "app", "workers"])
    )
    error_message = "With both add-ons off, environment_subnet_ids, environment_subnet_prefixes and container_app_environments must have only the front, app and workers keys."
  }

  assert {
    condition     = length(local.subnet_layout) == 5
    error_message = "With both add-ons off, no add-on prefix may enter the subnet layout."
  }
}

# --- split_processing on a network the module builds ---------------------------------------------

run "split_processing_builds_core_and_outbound" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
  }

  assert {
    condition = (
      azurerm_subnet.environment["core"].name == "snet-core" &&
      azurerm_subnet.environment["core"].address_prefixes == tolist(["10.20.8.0/24"]) &&
      azurerm_subnet.environment["outbound"].name == "snet-outbound" &&
      azurerm_subnet.environment["outbound"].address_prefixes == tolist(["10.20.9.0/24"]) &&
      alltrue([
        for k in ["core", "outbound"] :
        azurerm_subnet.environment[k].delegation[0].service_delegation[0].name == "Microsoft.App/environments"
      ]) &&
      !contains(keys(azurerm_subnet.environment), "extension")
    )
    error_message = "split_processing must create snet-core (10.20.8.0/24) and snet-outbound (10.20.9.0/24), delegated to Microsoft.App/environments, and no extension subnet."
  }

  assert {
    condition = (
      toset(keys(module.environments)) == toset(["front", "app", "workers", "core", "outbound"]) &&
      alltrue([
        for k in ["core", "outbound"] :
        module.environments[k].name == "aca-masterly-${k}" &&
        module.environments[k].internal_load_balancer_enabled &&
        length(module.environments[k].workload_profiles) == 1 &&
        module.environments[k].workload_profiles[0].workload_profile_type == "Consumption" &&
        module.environments[k].workload_profiles[0].name == "Consumption" &&
        length(module.environments[k].identity_ids) == 0
      ])
    )
    error_message = "split_processing must add aca-<prefix>-core and aca-<prefix>-outbound, each internal, declaring exactly the Consumption profile, with no identity; the workers environment stays."
  }

  assert {
    condition = (
      toset(keys(azurerm_monitor_diagnostic_setting.environment)) == toset(["front", "app", "workers", "core", "outbound"]) &&
      alltrue([
        for k in ["core", "outbound"] :
        azurerm_monitor_diagnostic_setting.environment[k].name == "diag-masterly-aca-${k}" &&
        toset([for l in azurerm_monitor_diagnostic_setting.environment[k].enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
      ]) &&
      contains(keys(azurerm_private_dns_zone.environment), "core") &&
      contains(keys(azurerm_private_dns_zone.environment), "outbound")
    )
    error_message = "The core and outbound environments must each get a diagnostic setting with the console and system logs, and private DNS, through the existing for_each."
  }

  assert {
    condition = (
      output.environment_subnet_prefixes["core"] == "10.20.8.0/24" &&
      output.environment_subnet_prefixes["outbound"] == "10.20.9.0/24" &&
      toset(keys(output.environment_subnet_ids)) == toset(["front", "app", "workers", "core", "outbound"]) &&
      output.container_app_environments["core"].internal &&
      output.container_app_environments["outbound"].internal &&
      !contains(keys(output.container_app_environments), "extension")
    )
    error_message = "The outputs must gain core and outbound, and only those, with split_processing on."
  }
}

# The diagnostic settings target their own environment and the install's workspace. The workspace
# and the environments are pinned with override_module, each to an id of its own.
run "split_processing_logs_reach_the_workspace" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    extensions            = true
  }

  override_module {
    target  = module.logs
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly" }
  }

  override_module {
    target  = module.environments["core"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-core", default_domain = "core-7a8b.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.8.10" }
  }

  override_module {
    target  = module.environments["outbound"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-outbound", default_domain = "outbound-9c0d.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.9.10" }
  }

  override_module {
    target  = module.environments["extension"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-extension", default_domain = "extension-1e2f.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.10.10" }
  }

  assert {
    condition = alltrue([
      for k in ["core", "outbound", "extension"] :
      azurerm_monitor_diagnostic_setting.environment[k].target_resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-${k}" &&
      azurerm_monitor_diagnostic_setting.environment[k].log_analytics_workspace_id == module.logs.id
    ])
    error_message = "Each add-on environment's diagnostic setting must target that environment and send to the install's workspace."
  }
}

# Threat (ADR 0120 §5): core and outbound admit no caller, only the Container Apps platform's own
# traffic; no allow rule may name Internet, VirtualNetwork or any address.
run "core_and_outbound_subnets_admit_only_the_platform" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
  }

  assert {
    condition = alltrue([
      for k, p in { core = "10.20.8.0/24", outbound = "10.20.9.0/24" } :
      azurerm_network_security_group.environment[k].name == "nsg-masterly-${k}" &&
      toset([
        for r in azurerm_network_security_group.environment[k].security_rule : join(" ", [
          r.name, tostring(r.priority), r.direction, r.access, r.protocol, r.source_address_prefix, r.destination_address_prefix,
          r.destination_port_range != null ? r.destination_port_range : join(",", sort(r.destination_port_ranges)),
        ])
        ]) == toset([
        "allow-container-apps-load-balancer 110 Inbound Allow Tcp AzureLoadBalancer ${p} 30000-32767",
        "allow-environment-internal 120 Inbound Allow * ${p} ${p} *",
        "deny-all-inbound 4000 Inbound Deny * * * *",
      ])
    ])
    error_message = "nsg-<prefix>-core and nsg-<prefix>-outbound must each hold exactly the platform rules (110, 120) and deny-all-inbound (4000)."
  }

  assert {
    condition = alltrue(flatten([
      for k in ["core", "outbound"] : [
        for r in azurerm_network_security_group.environment[k].security_rule :
        !contains(["Internet", "VirtualNetwork", "*"], r.source_address_prefix)
        if r.access == "Allow"
      ]
    ]))
    error_message = "No allow rule on the core or outbound subnet may have Internet, VirtualNetwork or any address as its source."
  }

  assert {
    condition = alltrue([
      for k in ["core", "outbound"] :
      azurerm_subnet_network_security_group_association.environment[k] != null
    ])
    error_message = "The core and outbound subnets must each be associated with their group."
  }
}

# The endpoints subnet admits core and outbound on the data-plane ports, each by a rule of its own,
# beside the existing rules, which keep their names and priorities.
run "endpoints_subnet_admits_core_and_outbound" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
  }

  assert {
    condition = toset([
      for r in azurerm_network_security_group.private_endpoints[0].security_rule : join(" ", [
        r.name, tostring(r.priority), r.direction, r.access, r.protocol, r.source_address_prefix, r.destination_address_prefix,
        r.destination_port_range != null ? r.destination_port_range : join(",", sort(r.destination_port_ranges)),
      ])
      ]) == toset([
      "allow-data-plane-from-apps 100 Inbound Allow Tcp 10.20.0.0/23 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-app-subnet 110 Inbound Allow Tcp 10.20.6.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-workers-subnet 120 Inbound Allow Tcp 10.20.7.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-core-subnet 140 Inbound Allow Tcp 10.20.8.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "allow-data-plane-from-outbound-subnet 150 Inbound Allow Tcp 10.20.9.0/24 10.20.4.0/24 ${join(",", sort(local.private_endpoint_ports))}",
      "deny-all-inbound 4000 Inbound Deny * * * *",
    ])
    error_message = "With split_processing, the endpoints subnet must hold its existing rules unchanged plus allow-data-plane-from-core-subnet (140) and allow-data-plane-from-outbound-subnet (150), each from its subnet on local.private_endpoint_ports."
  }

  assert {
    condition     = length(distinct([for r in azurerm_network_security_group.private_endpoints[0].security_rule : r.priority])) == length(azurerm_network_security_group.private_endpoints[0].security_rule)
    error_message = "Every rule on the endpoints subnet must have a priority of its own."
  }
}

# On a /21, which derives the baseline but not the add-ons, explicit prefixes in the free /24s
# give split_processing its subnets.
run "split_processing_on_a_21_with_explicit_prefixes" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    vnet_address_space     = ["10.20.0.0/21"]
    split_processing       = true
    core_subnet_prefix     = "10.20.2.0/24"
    outbound_subnet_prefix = "10.20.3.0/25"
  }

  assert {
    condition = (
      azurerm_subnet.environment["core"].address_prefixes == tolist(["10.20.2.0/24"]) &&
      azurerm_subnet.environment["outbound"].address_prefixes == tolist(["10.20.3.0/25"]) &&
      toset(keys(module.environments)) == toset(["front", "app", "workers", "core", "outbound"])
    )
    error_message = "Explicit core and outbound prefixes must be used as given, beside the derived baseline."
  }
}

# --- split_processing on an injected network -----------------------------------------------------

run "add_on_environments_run_on_the_injected_subnets" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    split_processing            = true
    extensions                  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    core_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-core"
    outbound_subnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-outbound"
    extension_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-extension"
  }

  assert {
    condition = (
      toset(keys(module.environments)) == toset(["front", "app", "workers", "core", "outbound", "extension"]) &&
      module.environments["core"].infrastructure_subnet_id == var.core_subnet_id &&
      module.environments["outbound"].infrastructure_subnet_id == var.outbound_subnet_id &&
      module.environments["extension"].infrastructure_subnet_id == var.extension_subnet_id &&
      alltrue([for k in ["core", "outbound", "extension"] : output.environment_subnet_ids[k] == module.environments[k].infrastructure_subnet_id])
    )
    error_message = "Each add-on environment must run on its own injected subnet, the value environment_subnet_ids publishes for its key."
  }

  assert {
    condition = (
      length(azurerm_subnet.environment) == 0 &&
      length(azurerm_network_security_group.environment) == 0 &&
      length(azurerm_subnet_network_security_group_association.environment) == 0 &&
      length(azurerm_network_security_group.private_endpoints) == 0 &&
      length(azurerm_network_security_group.aca) == 0
    )
    error_message = "On an injected network the module must create no subnet, group or association, for the add-ons as for the rest."
  }

  assert {
    condition     = alltrue([for k in ["core", "outbound", "extension"] : output.environment_subnet_prefixes[k] == null])
    error_message = "On an injected network the add-on prefixes are the platform team's, so the output must publish null for them."
  }
}

# --- extensions ---------------------------------------------------------------------------------

run "extensions_builds_an_isolated_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    extensions            = true
  }

  assert {
    condition = (
      azurerm_subnet.environment["extension"].name == "snet-extension" &&
      azurerm_subnet.environment["extension"].address_prefixes == tolist(["10.20.10.0/24"]) &&
      azurerm_subnet.environment["extension"].delegation[0].service_delegation[0].name == "Microsoft.App/environments" &&
      !contains(keys(azurerm_subnet.environment), "core") &&
      !contains(keys(azurerm_subnet.environment), "outbound")
    )
    error_message = "extensions must create snet-extension (10.20.10.0/24), delegated to Microsoft.App/environments, and no core or outbound subnet."
  }

  assert {
    condition = (
      azurerm_network_security_group.environment["extension"].name == "nsg-masterly-extension" &&
      toset([
        for r in azurerm_network_security_group.environment["extension"].security_rule : join(" ", [
          r.name, tostring(r.priority), r.direction, r.access, r.protocol, r.source_address_prefix, r.destination_address_prefix,
          r.destination_port_range != null ? r.destination_port_range : join(",", sort(r.destination_port_ranges)),
        ])
        ]) == toset([
        "allow-container-apps-load-balancer 110 Inbound Allow Tcp AzureLoadBalancer 10.20.10.0/24 30000-32767",
        "allow-environment-internal 120 Inbound Allow * 10.20.10.0/24 10.20.10.0/24 *",
        "deny-all-inbound 4000 Inbound Deny * * * *",
      ])
    )
    error_message = "nsg-<prefix>-extension must hold exactly the platform rules (110, 120) and deny-all-inbound (4000)."
  }

  assert {
    condition = (
      module.environments["extension"].name == "aca-masterly-extension" &&
      module.environments["extension"].internal_load_balancer_enabled &&
      length(module.environments["extension"].workload_profiles) == 1 &&
      module.environments["extension"].workload_profiles[0].workload_profile_type == "Consumption" &&
      length(module.environments["extension"].identity_ids) == 0 &&
      contains(keys(azurerm_monitor_diagnostic_setting.environment), "extension") &&
      toset(keys(output.container_app_environments)) == toset(["front", "app", "workers", "extension"])
    )
    error_message = "extensions must add aca-<prefix>-extension, internal, on the Consumption profile, with no identity and with a diagnostic setting."
  }
}

# The add-on environments' internal load balancers follow no input: a literal true each, read from
# the source with comments stripped, as only_aca_internal_load_balancer_reaches_a_load_balancer
# reads the baseline's in container_app_environments.tftest.hcl.
run "add_on_environments_are_internal_by_a_literal_true" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      trimspace(regex("(?s)add_on_container_app_environment_internal = \\{(.*?)\\n  \\}", replace(file("${path.module}/environment.tf"), "/#[^\\n]*/", ""))[0]) ==
      "core      = true\n    outbound  = true\n    extension = true" &&
      strcontains(
        replace(file("${path.module}/environment.tf"), "/#[^\\n]*/", ""),
        "container_app_environment_internal = merge(local.baseline_container_app_environment_internal, local.add_on_container_app_environment_internal)"
      )
    )
    error_message = "The core, outbound and extension environments must be internal by a literal true, merged after the baseline map so no add-on key can change a baseline one."
  }
}

# Threat (ADR 0120 §7, ADR 0122 §6.2): no Masterly identity or certificate identity lands on the
# extension environment, and no ca-* app or caj-* job runs in it. Every workload exists and every
# move is made; the environments are pinned to distinct ids so a workload wired to the extension
# environment compares equal to its id.
run "nothing_of_masterly_runs_in_the_extension_environment" {
  command = plan

  variables {
    split_processing        = true
    extensions              = true
    frontend_environment    = "front"
    edge_environment        = "front"
    api_environment         = "app"
    workers_environment     = "workers"
    migrate_job_environment = "workers"
    migrations              = "job"
    enable_workers          = true
    enable_service_bus      = true
    servicebus_sku          = "Standard"
    edge                    = {}
    mode                    = "production"
    identity_binding        = "oidc"
    oidc_allowed_issuers    = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience           = "api-client-id"
    oidc_jwks_uri           = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id          = "bff-client-id"
    oidc_client_secret      = "s3cret"
    oidc_authority          = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri       = "https://masterly.example.com/api/auth/callback"
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    initial_owner_email     = "owner@example.com"
    enable_key_vault        = true
    enable_redis            = true
    redis_offering          = "cache"
    api_max_replicas        = 3
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  override_module {
    target = module.aca_env[0]
    outputs = {
      id                             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      default_domain                 = "example.swedencentral.azurecontainerapps.io"
      internal_load_balancer_enabled = false
      logs_destination               = "azure-monitor"
      mutual_tls_enabled             = true
      identity_ids                   = []
      workload_profile_names         = null
      custom_domain_verification_id  = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50", custom_domain_verification_id = "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.7.10" }
  }

  override_module {
    target  = module.environments["core"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-core", default_domain = "core-7a8b.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.8.10" }
  }

  override_module {
    target  = module.environments["outbound"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-outbound", default_domain = "outbound-9c0d.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.9.10" }
  }

  override_module {
    target  = module.environments["extension"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-extension", default_domain = "extension-1e2f.swedencentral.azurecontainerapps.io", static_ip_address = "10.20.10.10", identity_ids = [] }
  }

  assert {
    condition = (
      toset(keys(local.environment_move_workloads)) == toset(["api", "frontend", "edge", "workers", "migrate"]) &&
      alltrue([for k, id in local.environment_move_workloads : id != module.environments["extension"].id]) &&
      module.api.environment_id != module.environments["extension"].id &&
      module.frontend.environment_id != module.environments["extension"].id &&
      module.workers[0].environment_id != module.environments["extension"].id &&
      azurerm_container_app.edge[0].container_app_environment_id != module.environments["extension"].id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id != module.environments["extension"].id
    )
    error_message = "No ca-* Container App or caj-* job may be placed in the extension environment."
  }

  assert {
    condition = (
      length(local.environment_certificate_identity_ids["extension"]) == 0 &&
      length(local.environment_certificate_identity_ids["front"]) == 1
    )
    error_message = "The frontend's certificate identity must go on the front environment it serves, never on the extension environment."
  }
}

# Placement names only the baseline environments: no input places an app or job in an add-on one.
run "frontend_environment_refuses_the_extension_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    extensions            = true
    frontend_environment  = "extension"
    edge_environment      = "front"
    api_environment       = "app"
  }

  expect_failures = [var.frontend_environment]
}

run "api_environment_refuses_the_core_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    api_environment       = "core"
  }

  expect_failures = [var.api_environment]
}

run "workers_environment_refuses_the_outbound_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    enable_workers        = true
    workers_environment   = "outbound"
  }

  expect_failures = [var.workers_environment]
}

run "migrate_job_environment_refuses_the_extension_environment" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    extensions              = true
    migrate_job_environment = "extension"
  }

  expect_failures = [var.migrate_job_environment]
}

# --- Threat: the extension subnet reaches nothing of Masterly's ------------------------------------

# Both add-ons on, on an internal install, where the front and snet-aca admit VirtualNetwork: the
# endpoints subnet names the extension subnet in no rule at all, and no Masterly environment's
# group admits it by its prefix or a range that covers it.
run "extension_subnet_reaches_nothing_of_masterly" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    split_processing           = true
    extensions                 = true
  }

  assert {
    condition     = local.env_subnet_prefixes["extension"] == "10.20.10.0/24"
    error_message = "The extension subnet must be 10.20.10.0/24 on the default VNet."
  }

  # The endpoints subnet: no rule's source is the extension prefix, and no allow rule's source is a
  # tag, any address, or a range that contains the extension prefix.
  assert {
    condition = (
      alltrue([
        for r in azurerm_network_security_group.private_endpoints[0].security_rule :
        r.source_address_prefix != local.env_subnet_prefixes["extension"]
      ]) &&
      alltrue([
        for r in azurerm_network_security_group.private_endpoints[0].security_rule :
        !contains(["Internet", "VirtualNetwork", "*"], r.source_address_prefix) &&
        !try(
          tonumber(split("/", r.source_address_prefix)[1]) <= 24 &&
          cidrhost("10.20.10.0/${split("/", r.source_address_prefix)[1]}", 0) == cidrhost(r.source_address_prefix, 0),
          true
        )
        if r.access == "Allow"
      ])
    )
    error_message = "No rule on the endpoints subnet may have the extension subnet's prefix, or a source covering it, as its source."
  }

  # The Masterly environments' groups: no allow rule from the extension prefix or a range that
  # contains it.
  assert {
    condition = alltrue(flatten([
      for k in ["front", "app", "workers", "core", "outbound"] : [
        for r in azurerm_network_security_group.environment[k].security_rule :
        r.source_address_prefix != "10.20.10.0/24" && !try(
          tonumber(split("/", r.source_address_prefix)[1]) <= 24 &&
          cidrhost("10.20.10.0/${split("/", r.source_address_prefix)[1]}", 0) == cidrhost(r.source_address_prefix, 0),
          false
        )
        if r.access == "Allow"
      ]
    ]))
    error_message = "No allow rule on the front, app, workers, core or outbound subnet may have the extension subnet's prefix, or a range covering it, as its source."
  }

  # VirtualNetwork covers the extension subnet. Only the front's caller rule may name it, as it did
  # before the add-ons (docs/networking.md states what that admits); app, workers, core and outbound
  # admit no tag at all.
  assert {
    condition = alltrue(flatten([
      for k in ["app", "workers", "core", "outbound"] : [
        for r in azurerm_network_security_group.environment[k].security_rule :
        !contains(["Internet", "VirtualNetwork", "*"], r.source_address_prefix)
        if r.access == "Allow"
      ]
    ]))
    error_message = "No allow rule on the app, workers, core or outbound subnet may admit a tag or any address, which would cover the extension subnet."
  }
}

# --- Zone redundancy ------------------------------------------------------------------------------

# Both add-ons on with environment_zone_redundant: the plan is not refused, the five Masterly
# environments are zone-redundant, and the extension environment is not (outside the 2026-11-20
# amendment's scope).
run "zone_redundancy_reaches_core_and_outbound_never_extension" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    environment_zone_redundant = true
    split_processing           = true
    extensions                 = true
  }

  assert {
    condition = (
      toset(keys(module.environments)) == toset(["front", "app", "workers", "core", "outbound", "extension"]) &&
      alltrue([for k in ["front", "app", "workers", "core", "outbound"] : module.environments[k].zone_redundancy_enabled]) &&
      !module.environments["extension"].zone_redundancy_enabled
    )
    error_message = "environment_zone_redundant must reach front, app, workers, core and outbound, and never the extension environment."
  }
}

run "zone_redundancy_off_for_all_six" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    environment_zone_redundant = false
    split_processing           = true
    extensions                 = true
  }

  assert {
    condition     = alltrue([for k in ["front", "app", "workers", "core", "outbound", "extension"] : !module.environments[k].zone_redundancy_enabled])
    error_message = "With environment_zone_redundant = false no environment may be zone-redundant."
  }
}

# --- Refusals -------------------------------------------------------------------------------------

# A /21 derives the baseline but has no room for the add-ons' /24s.
run "split_processing_on_a_21_without_prefixes_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    vnet_address_space    = ["10.20.0.0/21"]
    split_processing      = true
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "extensions_on_a_21_without_a_prefix_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    vnet_address_space    = ["10.20.0.0/21"]
    extensions            = true
  }

  expect_failures = [azurerm_virtual_network.this]
}

# Only one of the two prefixes on a VNet too small to derive the other.
run "split_processing_with_one_prefix_on_a_21_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    vnet_address_space    = ["10.20.0.0/21"]
    split_processing      = true
    core_subnet_prefix    = "10.20.2.0/24"
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "core_prefix_overlapping_the_front_subnet_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    core_subnet_prefix    = "10.20.5.0/25"
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "extension_prefix_overlapping_the_endpoints_subnet_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    extensions              = true
    extension_subnet_prefix = "10.20.4.0/24"
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "outbound_prefix_overlapping_the_core_prefix_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    split_processing       = true
    core_subnet_prefix     = "10.20.8.0/24"
    outbound_subnet_prefix = "10.20.8.128/25"
  }

  expect_failures = [azurerm_virtual_network.this]
}

run "outbound_prefix_outside_the_vnet_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    split_processing       = true
    outbound_subnet_prefix = "10.30.9.0/24"
  }

  expect_failures = [azurerm_virtual_network.this]
}

# An add-on needs the three baseline environments: a /22 with explicit runtime and endpoint
# prefixes has none, whatever the add-on's own prefixes.
run "split_processing_without_the_baseline_environments_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    vnet_address_space              = ["10.20.0.0/22"]
    aca_subnet_prefix               = "10.20.0.0/23"
    private_endpoints_subnet_prefix = "10.20.2.0/24"
    split_processing                = true
    core_subnet_prefix              = "10.20.3.0/25"
    outbound_subnet_prefix          = "10.20.3.128/25"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "core_subnet_prefix_without_split_processing_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    core_subnet_prefix    = "10.20.8.0/24"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "extension_subnet_id_without_extensions_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    extension_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-extension"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "core_subnet_prefix_smaller_than_27_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    core_subnet_prefix    = "10.20.8.0/28"
  }

  expect_failures = [var.core_subnet_prefix]
}

run "outbound_subnet_prefix_not_a_network_address_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs  = ["203.0.113.7/32"]
    split_processing       = true
    outbound_subnet_prefix = "10.20.9.5/24"
  }

  expect_failures = [var.outbound_subnet_prefix]
}

run "extension_subnet_prefix_malformed_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    extensions              = true
    extension_subnet_prefix = "10.20.10.0"
  }

  expect_failures = [var.extension_subnet_prefix]
}

# On an injected network the module creates no subnet, so each add-on needs its ids.
run "split_processing_on_an_injected_network_without_ids_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    split_processing            = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "split_processing_on_an_injected_network_with_only_core_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    split_processing            = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    core_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-core"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "extensions_on_an_injected_network_without_an_id_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    extensions                  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# The add-on environments need the three baseline ones on an injected network too.
run "split_processing_on_an_injected_network_without_the_baseline_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    split_processing            = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    core_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-core"
    outbound_subnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-outbound"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Threat: a new id equal to another collapses two trust boundaries into one subnet.
run "core_subnet_id_equal_to_the_workers_subnet_id_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    split_processing            = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    core_subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/SNET-WORKERS"
    outbound_subnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-outbound"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "extension_subnet_id_equal_to_the_endpoints_subnet_id_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    extensions                  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    extension_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  expect_failures = [azurerm_resource_group.aca]
}

run "extension_subnet_id_in_another_vnet_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    extensions                  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
    extension_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sandbox/providers/Microsoft.Network/virtualNetworks/vnet-sandbox/subnets/snet-extension"
  }

  expect_failures = [azurerm_resource_group.aca]
}

# Add-on ids join an existing network only: on a network the module builds they are refused.
run "core_and_outbound_subnet_ids_on_a_built_network_are_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    core_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-core"
    outbound_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-outbound"
  }

  expect_failures = [azurerm_resource_group.aca]
}
