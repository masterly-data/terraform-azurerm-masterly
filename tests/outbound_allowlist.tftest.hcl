# The outbound_allowlist output (ADR 0120 §5): what each subnet's workloads reach outside the VNet,
# for the customer's firewall. Its keys follow the environments that exist, every subnet carries the
# Container Apps platform set, the conditional entries follow their inputs and the subnet their
# workload runs on, front never lists a data endpoint, and no entry carries a URL's credentials.
#
# Branch coverage for the module's derived values (mock providers, no cloud access; runs in CI via
# `terraform test`). One of the per-concern plan files (MAS-4478): add a run to the file of the
# concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.

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

# --- Keys: exactly the subnets that exist ------------------------------------------------------

run "outbound_allowlist_keys_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = jsonencode(keys(output.outbound_allowlist)) == jsonencode(["aca", "app", "front", "workers"])
    error_message = "By default the allowlist must be keyed aca, app, front and workers."
  }
}

run "outbound_allowlist_keys_with_split_processing" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
  }

  assert {
    condition     = jsonencode(keys(output.outbound_allowlist)) == jsonencode(["aca", "app", "core", "front", "outbound", "workers"])
    error_message = "With split_processing the allowlist must add core and outbound."
  }
}

run "outbound_allowlist_keys_with_extensions" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    extensions            = true
  }

  assert {
    condition     = jsonencode(keys(output.outbound_allowlist)) == jsonencode(["aca", "app", "extension", "front", "workers"])
    error_message = "With extensions the allowlist must add extension."
  }
}

# A VNet too small for the environment subnets has aca-<prefix> alone.
run "outbound_allowlist_keys_on_a_small_vnet" {
  command = plan

  variables {
    ingress_allowed_cidrs           = ["203.0.113.7/32"]
    vnet_address_space              = ["10.20.0.0/22"]
    aca_subnet_prefix               = "10.20.0.0/23"
    private_endpoints_subnet_prefix = "10.20.2.0/24"
  }

  assert {
    condition     = jsonencode(keys(output.outbound_allowlist)) == jsonencode(["aca"])
    error_message = "With no environment subnet the allowlist must be keyed aca alone."
  }
}

run "outbound_allowlist_drops_aca_once_retired" {
  command = plan

  variables {
    retire_runtime_environment = true
    ingress_allowed_cidrs      = ["203.0.113.7/32"]
    frontend_environment       = "front"
    edge_environment           = "front"
    api_environment            = "app"
  }

  override_module {
    target  = module.environments["front"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-front", default_domain = "front-1a2b.swedencentral.azurecontainerapps.io", static_ip_address = "203.0.113.50" }
  }

  override_module {
    target  = module.environments["app"]
    outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly-app", default_domain = "app-3c4d.swedencentral.azurecontainerapps.io", static_ip_address = "10.30.6.10" }
  }

  assert {
    condition     = jsonencode(keys(output.outbound_allowlist)) == jsonencode(["app", "front", "workers"])
    error_message = "Once aca-<prefix> is retired the allowlist must not list it."
  }
}

# --- The platform set and the entry shape ------------------------------------------------------

# Every subnet, the empty add-on ones included, carries what Container Apps needs to start a
# replica, and every entry names all six fields.
run "outbound_allowlist_platform_set_on_every_subnet" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    extensions            = true
    edge                  = {}
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : length(setsubtract(
        ["MicrosoftContainerRegistry", "mcr.microsoft.com", "AzureActiveDirectory", "login.microsoftonline.com", "AzureMonitor", "AzureResourceManager", "management.azure.com"],
        [for e in l : e.destination],
      )) == 0
    ])
    error_message = "Every subnet must list Microsoft Container Registry, Entra ID, Azure Monitor and Azure management."
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : (
          toset(keys(e)) == toset(["destination", "kind", "protocol", "ports", "why", "source"]) &&
          e.destination != "" &&
          contains(["fqdn", "service_tag"], e.kind) &&
          e.protocol == "TCP" &&
          length(e.ports) > 0 &&
          alltrue([for p in e.ports : can(regex("^[0-9]{1,5}$", p))]) &&
          e.why != "" &&
          e.source != ""
        )
      ]
    ]))
    error_message = "Every entry must have destination, kind (fqdn or service_tag), protocol, ports, why and source, none empty."
  }

  # The platform entries name the Learn page they come from and the date it was read; Azure
  # management, which the page does not list, names ADR 0120 §5.
  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : (
          contains(["AzureResourceManager", "management.azure.com"], e.destination)
          ? strcontains(e.source, "ADR 0120")
          : strcontains(e.source, "firewall-integration") && strcontains(e.source, "read 2026-11-23")
        )
        if contains(["MicrosoftContainerRegistry", "mcr.microsoft.com", "AzureActiveDirectory", "login.microsoftonline.com", "AzureMonitor", "AzureResourceManager", "management.azure.com"], e.destination)
      ]
    ]))
    error_message = "The platform set's entries must name Microsoft Learn's page and the date it was read, and Azure management ADR 0120 §5."
  }
}

# --- The registry ------------------------------------------------------------------------------

run "outbound_allowlist_registry_on_every_subnet" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    extensions            = true
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : contains([for e in l : e.destination], "masterly.azurecr.io") &&
      contains([for e in l : e.destination], "*.data.azurecr.io") &&
      contains([for e in l : e.destination], "*.blob.core.windows.net")
    ])
    error_message = "Without registry_private_endpoint every subnet must list the registry's login server and its data endpoints."
  }
}

run "outbound_allowlist_no_registry_with_private_endpoint" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    acr_login_server          = null
    registry_credential_mode  = "managed_identity"
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint = true
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : !strcontains(e.destination, "azurecr.io") && e.destination != "*.blob.core.windows.net"
      ]
    ]))
    error_message = "With registry_private_endpoint the pull stays in the VNet, so no subnet may list the registry."
  }
}

# --- Docker Hub follows ca-edge ----------------------------------------------------------------

run "outbound_allowlist_no_docker_hub_without_edge" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "docker.io")]
    ]))
    error_message = "Without edge no subnet may list Docker Hub."
  }
}

run "outbound_allowlist_docker_hub_on_front_with_edge_there" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      length(setsubtract(["registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com"], [for e in output.outbound_allowlist["front"] : e.destination])) == 0 &&
      alltrue(flatten([
        for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "docker")] if k != "front"
      ]))
    )
    error_message = "With edge set and edge.image unset, Docker Hub must be listed on the subnet ca-edge runs on (front) and nowhere else."
  }
}

# Until ca-edge moves, it runs on aca-<prefix>, and Docker Hub goes with it.
run "outbound_allowlist_docker_hub_follows_ca_edge_on_aca" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["aca"] : e.destination], "registry-1.docker.io") &&
      !contains([for e in output.outbound_allowlist["front"] : e.destination], "registry-1.docker.io")
    )
    error_message = "Docker Hub must follow ca-edge: on aca while it runs there, not on front."
  }
}

run "outbound_allowlist_no_docker_hub_with_a_mirrored_edge_image" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = { image = "mirror.example.com/envoyproxy/envoy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      alltrue(flatten([
        for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "docker")]
      ])) &&
      contains([for e in output.outbound_allowlist["front"] : e.destination], "mirror.example.com")
    )
    error_message = "With edge.image set, no subnet may list Docker Hub, and ca-edge's subnet must list the mirror's registry instead."
  }
}

# --- The identity provider ---------------------------------------------------------------------

run "outbound_allowlist_idp_hosts_follow_their_workloads" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://idp.example.com/tenant/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = "https://keys.example.com/tenant/discovery/keys"
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = "https://idp.example.com/tenant/v2.0"
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["front"] : e.destination], "idp.example.com") &&
      !contains([for e in output.outbound_allowlist["front"] : e.destination], "keys.example.com") &&
      contains([for e in output.outbound_allowlist["app"] : e.destination], "keys.example.com") &&
      !contains([for e in output.outbound_allowlist["app"] : e.destination], "idp.example.com")
    )
    error_message = "The issuer's host must sit with ca-frontend (front) and the signing keys' host with ca-api (app)."
  }
}

# --- Masterly's control plane ------------------------------------------------------------------

run "outbound_allowlist_no_control_plane_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : e.destination != "cp.masterlydata.com"]
    ]))
    error_message = "Without license_issuer_url no subnet may list the control plane."
  }
}

# The refresh runs in ca-workers, so its host sits on the workers subnet once ca-workers runs there.
run "outbound_allowlist_license_issuer_host_with_workers" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    enable_workers          = true
    workers_environment     = "workers"
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["workers"] : e.destination], "cp.masterlydata.com") &&
      alltrue([for e in output.outbound_allowlist["workers"] : contains(e.ports, "443") if e.destination == "cp.masterlydata.com"]) &&
      !contains([for e in output.outbound_allowlist["front"] : e.destination], "cp.masterlydata.com") &&
      !contains([for e in output.outbound_allowlist["aca"] : e.destination], "cp.masterlydata.com")
    )
    error_message = "license_issuer_url's host must be listed on the subnet ca-workers runs on, and not where only ca-frontend and ca-api run."
  }
}

# Without ca-workers the licence refresh runs in ca-api, so the host goes with ca-api.
run "outbound_allowlist_license_issuer_host_with_ca_api" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    frontend_environment    = "front"
    edge_environment        = "front"
    api_environment         = "app"
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["app"] : e.destination], "cp.masterlydata.com") &&
      !contains([for e in output.outbound_allowlist["front"] : e.destination], "cp.masterlydata.com") &&
      !contains([for e in output.outbound_allowlist["workers"] : e.destination], "cp.masterlydata.com")
    )
    error_message = "Without enable_workers, license_issuer_url's host must be listed where ca-api runs (app), and not on front or workers."
  }
}

# --- Threat: secret disclosure ------------------------------------------------------------------

# The allowlist is not sensitive: a DSN carrying a password must leave its host and port and
# nothing else.
run "outbound_allowlist_database_host_and_port_only" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgres://u:p@db.example.com:5432/m"
  }

  assert {
    condition = (
      !strcontains(jsonencode(output.outbound_allowlist), "u:p") &&
      !strcontains(jsonencode(output.outbound_allowlist), "postgres://") &&
      !strcontains(jsonencode(output.outbound_allowlist), "/m\"")
    )
    error_message = "The allowlist must carry no part of external_database_url beyond its host and port."
  }

  assert {
    condition = jsonencode(distinct(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : "${e.destination}:${join(",", e.ports)}" if e.source == "external_database_url"
      ]
    ]))) == jsonencode(["db.example.com:5432"])
    error_message = "The database entry must be exactly db.example.com on 5432."
  }

  # Whatever its source, every entry that names the database's host or port is that one entry.
  assert {
    condition = jsonencode(distinct(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : "${e.destination}:${join(",", e.ports)}"
        if strcontains(jsonencode(e), "db.example.com") || contains(e.ports, "5432")
      ]
    ]))) == jsonencode(["db.example.com:5432"])
    error_message = "The allowlist must hold the database only as db.example.com:5432."
  }

  assert {
    condition     = !strcontains(jsonencode(output.outbound_allowlist), "p@db")
    error_message = "The allowlist must carry no userinfo from external_database_url."
  }
}

# A DSN with no port gets Postgres's 5432, and its query string stays out of the entry.
run "outbound_allowlist_database_default_port" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com/postgres?ssl=require"
  }

  assert {
    condition = jsonencode(distinct(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : "${e.destination}:${join(",", e.ports)}" if e.source == "external_database_url"
      ]
    ]))) == jsonencode(["pg.example.com:5432"])
    error_message = "A DSN without a port must give its host on 5432."
  }

  assert {
    condition = (
      !strcontains(jsonencode(output.outbound_allowlist), "masterly:pw") &&
      !strcontains(jsonencode(output.outbound_allowlist), "ssl=require")
    )
    error_message = "The allowlist must carry no credentials or query string from external_database_url."
  }
}

# A password holding an unencoded / cannot be split from the host with certainty: the URL gives no
# entry at all rather than a fragment of the password.
run "outbound_allowlist_database_unparseable_url_gives_no_entry" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgres://u:p/w@db.example.com:5432/m"
  }

  assert {
    condition = (
      alltrue(flatten([
        for k, l in output.outbound_allowlist : [for e in l : e.source != "external_database_url"]
      ])) &&
      !strcontains(jsonencode(output.outbound_allowlist), "p/w")
    )
    error_message = "A DSN whose password breaks the URL's shape must give no database entry and no part of itself."
  }
}

# The starter server is reached over its private endpoint: no database entry at all.
run "outbound_allowlist_no_database_on_the_starter_server" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.source, "database")]
    ]))
    error_message = "With the starter server no subnet may list a database."
  }
}

# Without enable_key_vault there is no vault to reach: no subnet lists one.
run "outbound_allowlist_no_key_vault_by_default" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "vault.azure.net")]
    ]))
    error_message = "Without enable_key_vault no subnet may list a Key Vault."
  }
}

# The install's own services carry its random suffix, which a mock plan leaves unknown
# (`override_during = plan` needs Terraform 1.11 while CI runs 1.10). This run applies the suffix
# alone, so every later run in this file plans against it in state and their names are known.
run "install_suffix_applied" {
  command = apply

  plan_options {
    target = [random_string.install]
  }

  override_resource {
    target = random_string.install
    values = { result = "abc123" }
  }

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = random_string.install.result == "abc123"
    error_message = "The install suffix must be applied for the later runs to plan known names."
  }
}

# --- Threat: front isolation --------------------------------------------------------------------

# ADR 0120 §5: the front subnet reaches no data endpoint. Every data-plane input is on, the apps
# are moved off aca-<prefix>, and front must list none of it while app and workers do.
run "outbound_allowlist_front_carries_no_data_endpoint" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgres://u:p@db.example.com:5432/m"
    enable_service_bus    = true
    email_acs_enabled     = true
    enable_key_vault      = true
    enable_workers        = true
    workers_environment   = "workers"
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
    edge                  = {}
  }

  override_module {
    target  = module.acs_email[0]
    outputs = { communication_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Communication/communicationServices/acs-masterly", endpoint = "https://acs-masterly.europe.communication.azure.com", sender_address = "DoNotReply@example.azurecomm.net" }
  }

  assert {
    condition = alltrue([
      for e in output.outbound_allowlist["front"] : !(
        strcontains(e.destination, "db.example.com") ||
        strcontains(e.destination, "servicebus.windows.net") ||
        strcontains(e.destination, "communication.azure.com") ||
        strcontains(e.destination, "postgres") ||
        strcontains(e.destination, "redis")
      )
    ])
    error_message = "The front subnet must list no data endpoint: no database host, Service Bus, Communication Services, Postgres or Redis."
  }

  assert {
    condition = alltrue([
      for k in ["app", "workers"] : (
        contains([for e in output.outbound_allowlist[k] : e.destination], "db.example.com") &&
        contains([for e in output.outbound_allowlist[k] : e.destination], "sb-masterly-abc123.servicebus.windows.net") &&
        contains([for e in output.outbound_allowlist[k] : e.destination], "acs-masterly.europe.communication.azure.com")
      )
    ])
    error_message = "The database, Service Bus and Communication Services must be listed on the subnets ca-api and ca-workers run on."
  }

  # Key Vault on front is allowed: the environment resolves ca-frontend's vault references.
  assert {
    condition     = contains([for e in output.outbound_allowlist["front"] : e.destination], "kv-masterly-abc123.vault.azure.net")
    error_message = "With a public vault (outside production) the front subnet must list it, for ca-frontend's Key Vault references."
  }
}

run "outbound_allowlist_key_vault_only_when_enabled" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_key_vault      = true
  }

  assert {
    condition     = contains([for e in output.outbound_allowlist["aca"] : e.destination], "kv-masterly-abc123.vault.azure.net")
    error_message = "With enable_key_vault outside production the vault must be listed where the apps run."
  }
}
