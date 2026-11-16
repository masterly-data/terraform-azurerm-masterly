# The front, app and workers Container Apps environments (environment.tf, ADR 0120 §4-§5):
# their subnets, workload profile, load balancers, diagnostic settings and private DNS, and that
# module.aca_env and everything on it are untouched.
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

# --- The three environments ------------------------------------------------------------------
# A plan cannot read a module's computed ids, so the runs that compare subnets use injected ids
# (known strings), and the runs that compare an environment's id, default domain or static IP pin
# the environments' outputs with override_module, each to values of its own, so a resource wired
# to the wrong environment compares unequal.

# On a network the module builds (the default /16 derives the three subnets): one environment per
# subnet, each declaring the Consumption profile. A public install: app and workers internal, the
# front public, so only app and workers get private DNS. No override, so these are the module's
# own values.
run "environments_on_a_public_install" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = false
  }

  assert {
    condition     = toset(keys(module.environments)) == toset(["front", "app", "workers"])
    error_message = "A network the module builds with the three environment subnets must get the front, app and workers environments."
  }

  assert {
    condition = alltrue([
      for k in ["front", "app", "workers"] :
      module.environments[k].name == "aca-masterly-${k}" &&
      length(module.environments[k].workload_profiles) == 1 &&
      module.environments[k].workload_profiles[0].workload_profile_type == "Consumption" &&
      module.environments[k].workload_profiles[0].name == "Consumption" &&
      module.environments[k].logs_destination == "azure-monitor" &&
      module.environments[k].mutual_tls_enabled
    ])
    error_message = "Each environment must be aca-<prefix>-<key>, declare exactly the Consumption workload profile, send its logs through Azure Monitor and encrypt traffic between its apps."
  }

  assert {
    condition = (
      module.environments["app"].internal_load_balancer_enabled &&
      module.environments["workers"].internal_load_balancer_enabled &&
      !module.environments["front"].internal_load_balancer_enabled
    )
    error_message = "With aca_internal_load_balancer = false the app and workers environments must stay internal and the front must be public."
  }

  assert {
    condition = (
      output.container_app_environments["app"].internal &&
      output.container_app_environments["workers"].internal &&
      !output.container_app_environments["front"].internal
    )
    error_message = "container_app_environments must report which environments are internal."
  }

  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone.environment)) == toset(["app", "workers"]) &&
      toset(keys(azurerm_private_dns_a_record.environment)) == toset(["app", "workers"]) &&
      toset(keys(azurerm_private_dns_zone_virtual_network_link.environment)) == toset(["app", "workers"])
    )
    error_message = "Only the internal environments (app and workers on a public install) may get a private DNS zone, record and link; the public front gets none."
  }

  assert {
    condition     = toset(keys(azurerm_monitor_diagnostic_setting.environment)) == toset(["front", "app", "workers"])
    error_message = "Each environment must get its own diagnostic setting."
  }
}

# The same network, private: every environment internal, so all three get private DNS.
run "environments_on_an_internal_install" {
  command = plan

  variables {
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
  }

  assert {
    condition     = alltrue([for k in ["front", "app", "workers"] : module.environments[k].internal_load_balancer_enabled])
    error_message = "With aca_internal_load_balancer = true the front, app and workers environments must all be internal."
  }

  assert {
    condition     = alltrue([for k in ["front", "app", "workers"] : output.container_app_environments[k].internal])
    error_message = "container_app_environments must report every environment internal on an internal install."
  }

  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_private_dns_a_record.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_private_dns_zone_virtual_network_link.environment)) == toset(["front", "app", "workers"])
    )
    error_message = "On an internal install every environment must get a private DNS zone, record and link."
  }

  assert {
    condition     = alltrue([for l in azurerm_private_dns_zone_virtual_network_link.environment : l.registration_enabled == false])
    error_message = "The environments' private DNS links must not auto-register VMs."
  }
}

# The load balancers of app and workers follow no input: the source sets them to a literal true,
# and the front's to aca_internal_load_balancer alone. Read from the source, comments stripped, so
# an input added later that reaches either fails here even if no run sets it.
run "only_aca_internal_load_balancer_reaches_a_load_balancer" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      trimspace(regex("(?s)container_app_environment_internal = \\{(.*?)\\n  \\}", replace(file("${path.module}/environment.tf"), "/#[^\\n]*/", ""))[0]) ==
      "front   = var.aca_internal_load_balancer\n    app     = true\n    workers = true" &&
      strcontains(
        regex("(?s)module \"environments\" \\{(.*?)\\n\\}", file("${path.module}/environment.tf"))[0],
        "internal_load_balancer_enabled = local.container_app_environment_internal[each.key]"
      )
    )
    error_message = "The app and workers environments must be internal by a literal true, and the front must follow aca_internal_load_balancer and nothing else."
  }
}

# Topology 3 with all three environment subnets: the environments run on the injected ids, which
# are also what environment_subnet_ids publishes.
run "environments_run_on_the_injected_subnets" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  assert {
    condition     = toset(keys(module.environments)) == toset(["front", "app", "workers"])
    error_message = "An injected network with the three environment subnet ids must get the front, app and workers environments."
  }

  assert {
    condition = (
      module.environments["front"].infrastructure_subnet_id == var.front_subnet_id &&
      module.environments["app"].infrastructure_subnet_id == var.app_subnet_id &&
      module.environments["workers"].infrastructure_subnet_id == var.workers_subnet_id &&
      alltrue([for k in ["front", "app", "workers"] : module.environments[k].infrastructure_subnet_id == output.environment_subnet_ids[k]])
    )
    error_message = "Each environment must run on its own injected subnet, the value environment_subnet_ids publishes for its key."
  }

  assert {
    condition = alltrue([
      for k in ["front", "app", "workers"] :
      length(module.environments[k].workload_profiles) == 1 &&
      module.environments[k].workload_profiles[0].workload_profile_type == "Consumption"
    ])
    error_message = "Each environment must declare the Consumption workload profile."
  }
}

# Each environment's console and system logs reach the install's workspace through a setting of
# its own. The workspace and the three environments are pinned to distinct ids.
run "each_environment_sends_its_logs_to_the_workspace" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  override_module {
    target  = module.logs
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly" }
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition     = toset(keys(azurerm_monitor_diagnostic_setting.environment)) == toset(["front", "app", "workers"])
    error_message = "Each environment must get its own diagnostic setting."
  }

  assert {
    condition = alltrue([
      for k in ["front", "app", "workers"] :
      azurerm_monitor_diagnostic_setting.environment[k].name == "diag-masterly-aca-${k}" &&
      azurerm_monitor_diagnostic_setting.environment[k].target_resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-${k}" &&
      azurerm_monitor_diagnostic_setting.environment[k].log_analytics_workspace_id == module.logs.id &&
      length(azurerm_monitor_diagnostic_setting.environment[k].enabled_log) == 2 &&
      toset([for l in azurerm_monitor_diagnostic_setting.environment[k].enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
    ])
    error_message = "Each environment's setting must target that environment and send exactly ContainerAppConsoleLogs and ContainerAppSystemLogs to the install's workspace."
  }
}

# --- Private DNS -----------------------------------------------------------------------------

# A public install with the default: app and workers each get a zone named their default domain, a
# '*' record to their static IP and a link to the spoke's VNet; the public front gets none.
run "private_dns_for_the_internal_environments_on_a_public_install" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = false
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  # A zone's id is computed at plan. The apply run records_and_links_are_in_their_own_environments_zone
  # checks that each record and link uses its own environment's zone (`override_during = plan`
  # needs Terraform 1.11 while CI runs 1.10).
  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone.environment)) == toset(["app", "workers"]) &&
      toset(keys(azurerm_private_dns_a_record.environment)) == toset(["app", "workers"]) &&
      toset(keys(azurerm_private_dns_zone_virtual_network_link.environment)) == toset(["app", "workers"])
    )
    error_message = "On a public install only app and workers may get a private DNS zone, record and link; the public front gets none."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.environment["app"].name == "app-3c4d.swedencentral.azurecontainerapps.io" &&
      azurerm_private_dns_zone.environment["workers"].name == "workers-5e6f.swedencentral.azurecontainerapps.io" &&
      alltrue([for z in azurerm_private_dns_zone.environment : z.resource_group_name == "rg-masterly-aca"])
    )
    error_message = "Each internal environment's zone must be named its own default domain, in rg-<prefix>-aca."
  }

  assert {
    condition = (
      azurerm_private_dns_a_record.environment["app"].records == toset(["10.30.6.10"]) &&
      azurerm_private_dns_a_record.environment["workers"].records == toset(["10.30.7.10"]) &&
      alltrue([for r in azurerm_private_dns_a_record.environment : r.name == "*"])
    )
    error_message = "Each zone must hold one '*' A record to its own environment's static IP."
  }

  assert {
    condition = alltrue([
      for l in azurerm_private_dns_zone_virtual_network_link.environment :
      l.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke" &&
      l.registration_enabled == false
    ])
    error_message = "Each zone must be linked to the install's own VNet (the spoke of aca_subnet_id), with auto-registration off."
  }
}

# A private install with the default: the front is internal too, and gets its own zone.
run "private_dns_for_every_environment_on_an_internal_install" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_private_dns_a_record.environment)) == toset(["front", "app", "workers"]) &&
      toset(keys(azurerm_private_dns_zone_virtual_network_link.environment)) == toset(["front", "app", "workers"])
    )
    error_message = "On an internal install every environment must get a private DNS zone, record and link."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.environment["front"].name == "front-1a2b.swedencentral.azurecontainerapps.io" &&
      azurerm_private_dns_zone.environment["app"].name == "app-3c4d.swedencentral.azurecontainerapps.io" &&
      azurerm_private_dns_zone.environment["workers"].name == "workers-5e6f.swedencentral.azurecontainerapps.io" &&
      azurerm_private_dns_a_record.environment["front"].records == toset(["10.30.5.10"]) &&
      azurerm_private_dns_a_record.environment["app"].records == toset(["10.30.6.10"]) &&
      azurerm_private_dns_a_record.environment["workers"].records == toset(["10.30.7.10"]) &&
      alltrue([for r in azurerm_private_dns_a_record.environment : r.name == "*"])
    )
    error_message = "Each environment's zone must be named its default domain and hold a '*' A record to its static IP."
  }

  assert {
    condition = alltrue([
      for l in azurerm_private_dns_zone_virtual_network_link.environment :
      l.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke" &&
      l.registration_enabled == false
    ])
    error_message = "Each zone must be linked to the install's own VNet, with auto-registration off."
  }
}

# The hub owns DNS: no zone, record or link for any environment, even all internal, and the
# output carries what the hub needs to create them.
run "private_dns_off_creates_no_zone_record_or_link" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    aca_internal_load_balancer      = true
    environment_private_dns_enabled = false
    aca_subnet_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      length(module.environments) == 3 &&
      length(azurerm_private_dns_zone.environment) == 0 &&
      length(azurerm_private_dns_a_record.environment) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.environment) == 0
    )
    error_message = "With environment_private_dns_enabled = false the module must create the environments and no private DNS zone, record or link for any of them."
  }

  assert {
    condition = (
      toset(keys(output.container_app_environments)) == toset(["front", "app", "workers"]) &&
      alltrue([
        for k in ["front", "app", "workers"] :
        output.container_app_environments[k].id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-${k}" &&
        output.container_app_environments[k].internal
      ]) &&
      output.container_app_environments["front"].default_domain == "front-1a2b.swedencentral.azurecontainerapps.io" &&
      output.container_app_environments["app"].default_domain == "app-3c4d.swedencentral.azurecontainerapps.io" &&
      output.container_app_environments["workers"].default_domain == "workers-5e6f.swedencentral.azurecontainerapps.io" &&
      output.container_app_environments["front"].static_ip_address == "10.30.5.10" &&
      output.container_app_environments["app"].static_ip_address == "10.30.6.10" &&
      output.container_app_environments["workers"].static_ip_address == "10.30.7.10"
    )
    error_message = "container_app_environments must publish, for front, app and workers, the environment's id, default_domain, static_ip_address and internal."
  }
}

# --- No environment subnets ------------------------------------------------------------------

# A VNet smaller than /21 with no environment prefixes derives no environment subnets, so no
# environment and nothing that hangs off one; the plan still succeeds.
run "no_environments_on_a_vnet_smaller_than_21" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    aca_internal_load_balancer      = true
    vnet_address_space              = ["10.99.0.0/22"]
    aca_subnet_prefix               = "10.99.0.0/23"
    private_endpoints_subnet_prefix = "10.99.2.0/24"
  }

  assert {
    condition     = alltrue([for v in values(output.environment_subnet_ids) : v == null])
    error_message = "This run needs an install without environment subnets, or it proves nothing."
  }

  assert {
    condition = (
      length(module.environments) == 0 &&
      length(azurerm_monitor_diagnostic_setting.environment) == 0 &&
      length(azurerm_private_dns_zone.environment) == 0 &&
      length(azurerm_private_dns_a_record.environment) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.environment) == 0 &&
      alltrue([for v in values(output.container_app_environments) : v == null])
    )
    error_message = "With no environment subnets the module must create no new environment, diagnostic setting, DNS zone, record or link."
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.aca_env.name == "diag-masterly-aca-env"
    error_message = "aca-<prefix>'s own diagnostic setting must still be planned."
  }
}

# An injected network without front_subnet_id, app_subnet_id and workers_subnet_id: the same.
run "no_environments_on_an_injected_network_without_their_subnets" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  assert {
    condition     = alltrue([for v in values(output.environment_subnet_ids) : v == null])
    error_message = "This run needs an install without environment subnets, or it proves nothing."
  }

  assert {
    condition = (
      length(module.environments) == 0 &&
      length(azurerm_monitor_diagnostic_setting.environment) == 0 &&
      length(azurerm_private_dns_zone.environment) == 0 &&
      length(azurerm_private_dns_a_record.environment) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.environment) == 0 &&
      alltrue([for v in values(output.container_app_environments) : v == null])
    )
    error_message = "An injected network without the three environment subnet ids must get no new environment, diagnostic setting, DNS zone, record or link."
  }
}

# --- module.aca_env is untouched ---------------------------------------------------------------
# Every app, the migrate job and the custom-domain certificate stay on aca-<prefix>. The runs pin
# aca-<prefix> and the three new environments to distinct ids, so a reference moved to a new
# environment compares unequal.

# aca-<prefix> keeps its address, source and arguments, and its diagnostic setting is as before.
# ca-api and ca-frontend are read from the source; ca-workers, from the environment_id
# aca-container-app publishes, and ca-edge from the plan.
run "aca_env_keeps_its_arguments_its_setting_the_apps_and_the_edge" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_workers        = true
    edge                  = {}
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      trimspace(regex("(?s)module \"aca_env\" \\{(.*?)\\n\\}", file("${path.module}/environment.tf"))[0]) == trimspace(<<-EOT
        source = "./modules/aca-env-consumption"

          name                           = "aca-$${var.name_prefix}"
          resource_group_name            = azurerm_resource_group.aca.name
          location                       = var.location
          infrastructure_subnet_id       = local.aca_subnet_id
          internal_load_balancer_enabled = var.aca_internal_load_balancer
          # Only the certificate identities, each only with its input: frontend_custom_domain and
          # edge_custom_domain (custom-domain.tf). Empty with neither.
          # They follow the apps: with frontend_environment and edge_environment = "front" they are on the
          # front environment instead, and this list is empty.
          identity_ids = local.environment_certificate_identity_ids["aca"]
          # Only with egress_firewall: the route table's precondition reads the profiles (network.tf).
          read_workload_profiles = var.egress_firewall != null
          tags                   = local.tags
        EOT
      )
    )
    error_message = "module.aca_env must keep its source and every argument exactly as before."
  }

  assert {
    condition = (
      azurerm_monitor_diagnostic_setting.aca_env.name == "diag-masterly-aca-env" &&
      azurerm_monitor_diagnostic_setting.aca_env.target_resource_id == module.aca_env.id &&
      toset([for l in azurerm_monitor_diagnostic_setting.aca_env.enabled_log : l.category]) == toset(["ContainerAppConsoleLogs", "ContainerAppSystemLogs"])
    )
    error_message = "diag-<prefix>-aca-env must be unchanged: on aca-<prefix>, the console and system logs."
  }

  # ca-api and ca-frontend choose their environment from frontend_environment and
  # api_environment (environment.tf), so they are read from the plan.
  assert {
    condition = (
      module.api.environment_id == module.aca_env.id &&
      module.frontend.environment_id == module.aca_env.id &&
      local.api_environment_id == module.aca_env.id &&
      local.frontend_environment_id == module.aca_env.id
    )
    error_message = "ca-api and ca-frontend must stay on module.aca_env."
  }

  assert {
    condition = (
      length(module.workers) == 1 &&
      module.workers[0].environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : module.workers[0].environment_id != e.id])
    )
    error_message = "ca-workers must stay on module.aca_env by default (workers_environment = \"runtime\")."
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].container_app_environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : azurerm_container_app.edge[0].container_app_environment_id != e.id])
    )
    error_message = "ca-edge must stay on module.aca_env, not on a new environment."
  }
}

# caj-migrate, with migrations = "job" and a production posture that allows it, and ca-workers,
# with workers_environment and migrate_job_environment at their default ("runtime"). ca-workers'
# identity, env, secrets and scale rule, and the job's identity, are pinned here exactly as in
# workloads_moved_to_the_workers_environment_keep_their_access below.
run "migrate_job_stays_on_aca_env" {
  command = plan

  variables {
    enable_service_bus    = true
    servicebus_sku        = "Standard"
    migrations            = "job"
    mode                  = "production"
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      length(azurerm_container_app_job.migrate) == 1 &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : azurerm_container_app_job.migrate[0].container_app_environment_id != e.id])
    )
    error_message = "caj-migrate must stay on module.aca_env, not on a new environment."
  }

  assert {
    condition = (
      length(module.workers) == 1 &&
      module.workers[0].environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : module.workers[0].environment_id != e.id])
    )
    error_message = "ca-workers must stay on module.aca_env with workers_environment = \"runtime\"."
  }

  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"]) &&
      module.workers[0].secret_ref_identity_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"]) &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.workers[0].env_names == sort(keys(local.workers_env)) &&
      module.workers[0].env_secret_refs == tomap({ MASTERLY_DATABASE_URL = "database-url", MASTERLY_LICENSE_TOKEN = "license-token", MASTERLY_REDIS_URL = "redis-url", MASTERLY_SESSION_SECRET = "session-secret" }) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      length(module.workers[0].value_secret_names) == 0 &&
      length(module.workers[0].scale.custom_scale_rules) == 1 &&
      module.workers[0].scale.custom_scale_rules[0].name == "jobs-queue" &&
      module.workers[0].scale.custom_scale_rules[0].custom_rule_type == "azure-servicebus" &&
      module.workers[0].scale.custom_scale_rules[0].metadata["queueName"] == azurerm_servicebus_queue.jobs[0].name &&
      module.workers[0].scale.custom_scale_rules[0].metadata["messageCount"] == "5" &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"
    )
    error_message = "On aca-<prefix>, ca-workers runs as id-<prefix>-workers, with its env, the env each of its four vault-backed secrets feeds, no value secret, and the jobs-queue scale rule as that identity."
  }

  assert {
    condition = (
      azurerm_container_app_job.migrate[0].identity[0].type == "UserAssigned" &&
      length(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == 1 &&
      one(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
    )
    error_message = "On aca-<prefix>, caj-migrate runs as id-<prefix>-migrate and no other identity."
  }
}

# --- ca-workers and caj-migrate in the workers environment --------------------------------------
# workers_environment and migrate_job_environment each move one workload to
# aca-<prefix>-workers. The pins are those above, so a workload on the wrong environment compares
# unequal.

run "workers_environment_moves_only_ca_workers" {
  command = plan

  variables {
    workers_environment   = "workers"
    migrations            = "job"
    mode                  = "production"
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    license_token         = "eyJ.fake.jwt"
    license_public_jwk    = "{\"kty\":\"EC\"}"
    initial_owner_email   = "owner@example.com"
    enable_key_vault      = true
    enable_redis          = true
    redis_offering        = "cache"
    enable_workers        = true
    api_max_replicas      = 3
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      module.environments["workers"].id != module.aca_env.id &&
      module.workers[0].environment_id == module.environments["workers"].id &&
      module.workers[0].environment_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers"
    )
    error_message = "With workers_environment = \"workers\", ca-workers must be on module.environments[\"workers\"]."
  }

  assert {
    condition = (
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.aca_env.id &&
      module.api.environment_id == module.aca_env.id &&
      module.frontend.environment_id == module.aca_env.id
    )
    error_message = "workers_environment must move ca-workers only: caj-migrate, ca-api and ca-frontend stay on module.aca_env."
  }
}

run "migrate_job_environment_moves_only_caj_migrate" {
  command = plan

  variables {
    migrate_job_environment = "workers"
    migrations              = "job"
    mode                    = "production"
    identity_binding        = "oidc"
    oidc_allowed_issuers    = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience           = "api-client-id"
    oidc_jwks_uri           = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id          = "bff-client-id"
    oidc_client_secret      = "s3cret"
    oidc_authority          = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri       = "https://app.example.com/api/auth/callback"
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    initial_owner_email     = "owner@example.com"
    enable_key_vault        = true
    enable_redis            = true
    redis_offering          = "cache"
    enable_workers          = true
    api_max_replicas        = 3
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      module.environments["workers"].id != module.aca_env.id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.environments["workers"].id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers"
    )
    error_message = "With migrate_job_environment = \"workers\", caj-migrate must be on module.environments[\"workers\"]."
  }

  assert {
    condition = (
      module.workers[0].environment_id == module.aca_env.id &&
      module.api.environment_id == module.aca_env.id &&
      module.frontend.environment_id == module.aca_env.id
    )
    error_message = "migrate_job_environment must move caj-migrate only: ca-workers, ca-api and ca-frontend stay on module.aca_env."
  }
}

# Both moved: neither gains ingress, and neither gains or loses access. The identity, env, secret
# and scale-rule assertions are migrate_job_stays_on_aca_env's, on aca-<prefix>, unchanged. The env
# values and the vault references' targets are computed, unknown at plan: their parity is pinned by
# the applies in tests/workers_environment_access.tftest.hcl.
run "workloads_moved_to_the_workers_environment_keep_their_access" {
  command = plan

  variables {
    workers_environment     = "workers"
    migrate_job_environment = "workers"
    enable_service_bus      = true
    servicebus_sku          = "Standard"
    migrations              = "job"
    mode                    = "production"
    identity_binding        = "oidc"
    oidc_allowed_issuers    = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience           = "api-client-id"
    oidc_jwks_uri           = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id          = "bff-client-id"
    oidc_client_secret      = "s3cret"
    oidc_authority          = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri       = "https://app.example.com/api/auth/callback"
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    initial_owner_email     = "owner@example.com"
    enable_key_vault        = true
    enable_redis            = true
    redis_offering          = "cache"
    enable_workers          = true
    api_max_replicas        = 3
    external_database_url   = "postgresql+asyncpg://masterly:pw@pg.internal.example.com:5432/postgres?ssl=require"
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  override_module {
    target  = module.apps_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
  }

  override_module {
    target  = module.migrate_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
  }

  override_module {
    target  = module.workers_identity
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
  }

  assert {
    condition = (
      module.workers[0].environment_id == module.environments["workers"].id &&
      azurerm_container_app_job.migrate[0].container_app_environment_id == module.environments["workers"].id
    )
    error_message = "This run needs both workloads in the workers environment, or it proves nothing."
  }

  # The job resource has no ingress argument at all, so its source must not name one.
  assert {
    condition = (
      !module.workers[0].ingress_enabled &&
      !module.workers[0].ingress_external &&
      module.workers[0].fqdn == null &&
      length(module.workers[0].ingress_allowed_ip_ranges) == 0 &&
      !strcontains(regex("(?s)resource \"azurerm_container_app_job\" \"migrate\" \\{(.*?)\\n\\}", file("${path.module}/migrate.tf"))[0], "ingress")
    )
    error_message = "In the workers environment ca-workers must have no ingress block, and caj-migrate must declare no ingress."
  }

  # Both wait for the workers subnet's NSG, as the environment itself does (environment.tf).
  assert {
    condition = alltrue([
      for block in [
        regex("(?s)module \"workers\" \\{(.*?)\\n\\}", file("${path.module}/workers.tf"))[0],
        regex("(?s)resource \"azurerm_container_app_job\" \"migrate\" \\{(.*?)\\n\\}", file("${path.module}/migrate.tf"))[0],
      ] :
      strcontains(regex("(?s)depends_on = \\[([^\\]]*)\\]", block)[0], "azurerm_subnet_network_security_group_association.environment,")
    ])
    error_message = "ca-workers and caj-migrate must depend on the environment subnets' NSG associations."
  }

  # A replaced job has a new id, which starts it once more at apply (the changelog says so).
  assert {
    condition     = can(regex("(?m)^    replace_triggered_by = \\[terraform_data\\.migrate_image, azurerm_container_app_job\\.migrate\\[count\\.index\\]\\.id\\]$", regex("(?s)resource \"azapi_resource_action\" \"migrate_start\" \\{(.*?)\\n\\}", file("${path.module}/migrate.tf"))[0]))
    error_message = "migrate_start must be replaced when caj-migrate's id changes, as on a move between environments."
  }

  assert {
    condition = (
      module.workers[0].user_assigned_identity_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"]) &&
      module.workers[0].secret_ref_identity_ids == tolist(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"]) &&
      local.workers_env["AZURE_CLIENT_ID"] == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc" &&
      module.workers[0].env_names == sort(keys(local.workers_env)) &&
      module.workers[0].env_secret_refs == tomap({ MASTERLY_DATABASE_URL = "database-url", MASTERLY_LICENSE_TOKEN = "license-token", MASTERLY_REDIS_URL = "redis-url", MASTERLY_SESSION_SECRET = "session-secret" }) &&
      module.workers[0].vault_backed_secret_names == tolist(["database-url", "license-token", "redis-url", "session-secret"]) &&
      length(module.workers[0].value_secret_names) == 0 &&
      length(module.workers[0].scale.custom_scale_rules) == 1 &&
      module.workers[0].scale.custom_scale_rules[0].name == "jobs-queue" &&
      module.workers[0].scale.custom_scale_rules[0].custom_rule_type == "azure-servicebus" &&
      module.workers[0].scale.custom_scale_rules[0].metadata["queueName"] == azurerm_servicebus_queue.jobs[0].name &&
      module.workers[0].scale.custom_scale_rules[0].metadata["messageCount"] == "5" &&
      module.workers[0].scale.custom_scale_rules[0].identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers"
    )
    error_message = "In the workers environment, ca-workers must keep id-<prefix>-workers, its env, the env each of its four vault-backed secrets feeds, no value secret, and the jobs-queue scale rule as that identity, as on aca-<prefix>."
  }

  assert {
    condition = (
      azurerm_container_app_job.migrate[0].identity[0].type == "UserAssigned" &&
      length(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == 1 &&
      one(azurerm_container_app_job.migrate[0].identity[0].identity_ids) == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate"
    )
    error_message = "In the workers environment, caj-migrate must keep id-<prefix>-migrate and no other identity."
  }
}

# Only "runtime" and "workers" are accepted.
run "environment_inputs_refuse_another_value" {
  command = plan

  variables {
    workers_environment     = "front"
    migrate_job_environment = "app"
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
  }

  expect_failures = [var.workers_environment, var.migrate_job_environment]
}

# Refused at plan on an install without the workers environment: the injected network of
# no_environments_on_an_injected_network_without_their_subnets above.
run "workers_environment_refused_without_the_workers_environment" {
  command = plan

  variables {
    workers_environment         = "workers"
    enable_workers              = true
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  expect_failures = [var.workers_environment]
}

run "migrate_job_environment_refused_without_the_workers_environment" {
  command = plan

  variables {
    migrate_job_environment     = "workers"
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }

  expect_failures = [var.migrate_job_environment]
}

# Refused at plan with egress_firewall, whose route table goes on snet-aca only (network.tf). The
# guard run shows that the workers environment exists with these variables (the default /16) and
# that egress_firewall alone is not refused, so in the two runs after it only the egress_firewall
# refusal can fire.
run "egress_firewall_install_has_the_workers_environment" {
  command = plan

  variables {
    enable_workers             = true
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    egress_firewall            = { next_hop_ip = "10.0.0.4" }
  }

  assert {
    condition     = contains(keys(module.environments), "workers") && length(azurerm_subnet_route_table_association.aca) == 1
    error_message = "This install needs the workers environment and the snet-aca route, or the refusal runs below prove nothing."
  }
}

run "workers_environment_refused_with_egress_firewall" {
  command = plan

  variables {
    workers_environment        = "workers"
    enable_workers             = true
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    egress_firewall            = { next_hop_ip = "10.0.0.4" }
  }

  expect_failures = [var.workers_environment]
}

run "migrate_job_environment_refused_with_egress_firewall" {
  command = plan

  variables {
    migrate_job_environment    = "workers"
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    aca_internal_load_balancer = true
    egress_firewall            = { next_hop_ip = "10.0.0.4" }
  }

  expect_failures = [var.migrate_job_environment]
}

# The frontend's custom-domain certificate, with frontend_custom_domain set.
run "frontend_certificate_stays_on_aca_env" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      length(azurerm_container_app_environment_certificate.frontend) == 1 &&
      azurerm_container_app_environment_certificate.frontend[0].container_app_environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : azurerm_container_app_environment_certificate.frontend[0].container_app_environment_id != e.id])
    )
    error_message = "The frontend's environment certificate must stay on module.aca_env, not on a new environment."
  }
}

# ca-edge's custom-domain certificate, with edge and edge_custom_domain set.
run "edge_certificate_stays_on_aca_env" {
  command = plan

  variables {
    edge                  = {}
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-customer-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-customer-certs"
    }
  }

  override_module {
    target = module.aca_env
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
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  assert {
    condition = (
      length(azurerm_container_app_environment_certificate.edge) == 1 &&
      azurerm_container_app_environment_certificate.edge[0].container_app_environment_id == module.aca_env.id &&
      alltrue([for e in module.environments : azurerm_container_app_environment_certificate.edge[0].container_app_environment_id != e.id])
    )
    error_message = "ca-edge's environment certificate must stay on module.aca_env, not on a new environment."
  }
}

# --- Apply: each record and link in its own zone -----------------------------------------------
# A zone's id is known only once applied (`override_during = plan` needs Terraform 1.11 while CI
# runs 1.10), so this run applies the private DNS on mock state and goes last. Each zone is pinned
# to an id of its own, so a record or link wired to another environment's zone compares unequal.
run "records_and_links_are_in_their_own_environments_zone" {
  command = apply

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_internal_load_balancer  = true
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    front_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-front"
    app_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-app"
    workers_subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-workers"
  }

  plan_options {
    target = [
      azurerm_private_dns_a_record.environment,
      azurerm_private_dns_zone_virtual_network_link.environment,
    ]
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.5.10" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  override_module {
    target  = module.environments["workers"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-workers", default_domain = "workers-5e6f.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.7.10" }
  }

  override_resource {
    target = azurerm_private_dns_zone.environment["front"]
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/privateDnsZones/front-1a2b.swedencentral.azurecontainerapps.io" }
  }

  override_resource {
    target = azurerm_private_dns_zone.environment["app"]
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/privateDnsZones/app-3c4d.swedencentral.azurecontainerapps.io" }
  }

  override_resource {
    target = azurerm_private_dns_zone.environment["workers"]
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/privateDnsZones/workers-5e6f.swedencentral.azurecontainerapps.io" }
  }

  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone.environment)) == toset(["front", "app", "workers"]) &&
      alltrue([
        for k in ["front", "app", "workers"] :
        azurerm_private_dns_zone.environment[k].id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/privateDnsZones/${module.environments[k].default_domain}"
      ])
    )
    error_message = "This run needs each zone pinned to an id of its own, or it proves nothing."
  }

  assert {
    condition = alltrue([
      for k in ["front", "app", "workers"] :
      azurerm_private_dns_a_record.environment[k].private_dns_zone_id == azurerm_private_dns_zone.environment[k].id &&
      azurerm_private_dns_zone_virtual_network_link.environment[k].private_dns_zone_id == azurerm_private_dns_zone.environment[k].id
    ])
    error_message = "Each environment's record and link must be in that environment's own zone."
  }
}
