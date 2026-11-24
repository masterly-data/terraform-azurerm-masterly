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
  api_image        = "masterly.azurecr.io/release/api:v0.138.0"
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

  # The platform entries name the Learn page they come from and the date it was read: the NSG
  # allow rules for a service tag, the Azure Firewall application rules for an FQDN. Azure
  # management, which neither page lists, names ADR 0120 §5.
  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : (
          contains(["AzureResourceManager", "management.azure.com"], e.destination)
          ? strcontains(e.source, "ADR 0120")
          : strcontains(e.source, e.kind == "service_tag" ? "firewall-integration#nsg-allow-rules" : "use-azure-firewall#application-rules") && strcontains(e.source, "read 2026-11-23")
        )
        if contains(["MicrosoftContainerRegistry", "mcr.microsoft.com", "AzureActiveDirectory", "login.microsoftonline.com", "AzureMonitor", "AzureResourceManager", "management.azure.com"], e.destination)
      ]
    ]))
    error_message = "The platform set's entries must name Microsoft Learn's page and the date it was read, and Azure management ADR 0120 §5."
  }
}

# The platform set is Learn's two lists in full, on every subnet: the application rules of "Azure
# Container Apps environment integration with Azure Firewall" (the FQDNs) and the NSG allow rules
# of "Securing a virtual network in Azure Container Apps" (the service tags). A firewall built
# from a shorter list can stop the environment's nodes or an image pull. login.microsoft.com is an
# entry of its own, because a rule for *.login.microsoft.com does not match the bare name.
run "outbound_allowlist_platform_set_holds_learns_two_lists" {
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
        ["mcr.microsoft.com", "*.data.mcr.microsoft.com", "packages.aks.azure.com", "acs-mirror.azureedge.net", "login.microsoft.com", "login.microsoftonline.com", "*.login.microsoftonline.com", "*.login.microsoft.com", "*.identity.azure.net"],
        [for e in l : e.destination if e.kind == "fqdn" && contains(e.ports, "443") && strcontains(e.source, "use-azure-firewall#application-rules") && strcontains(e.source, "read 2026-11-23")],
      )) == 0
    ])
    error_message = "Every subnet must list the application rules' FQDNs, packages.aks.azure.com, acs-mirror.azureedge.net and the bare login.microsoft.com among them, each naming Learn's Azure Firewall page and the date it was read."
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : length(setsubtract(
        ["MicrosoftContainerRegistry", "AzureFrontDoor.FirstParty", "AzureActiveDirectory", "AzureMonitor", "AzureContainerRegistry", "Storage.swedencentral"],
        [for e in l : e.destination if e.kind == "service_tag" && contains(e.ports, "443") && strcontains(e.source, "firewall-integration#nsg-allow-rules") && strcontains(e.source, "read 2026-11-23")],
      )) == 0
    ])
    error_message = "Every subnet must list the NSG allow rules' service tags, AzureContainerRegistry and Storage.<region> among them, each naming Learn's NSG allow rules and the date they were read."
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : length([for e in l : e if e.destination == "login.microsoft.com"]) == 1 && length([for e in l : e if e.destination == "*.login.microsoft.com"]) == 1
    ])
    error_message = "login.microsoft.com and *.login.microsoft.com must each be one entry on every subnet."
  }
}

# The Storage tag names the install's region, in the form the location input is normalised to.
run "outbound_allowlist_storage_tag_names_the_region" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "West Europe"
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : contains([for e in l : e.destination], "Storage.westeurope") && !contains([for e in l : e.destination], "Storage.swedencentral")
    ])
    error_message = "With location = \"West Europe\" every subnet must list Storage.westeurope."
  }
}

# --- The registry ------------------------------------------------------------------------------

run "outbound_allowlist_registry_on_every_subnet" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    split_processing      = true
    extensions            = true
    api_image             = "masterly.azurecr.io:443/release/api:v0.138.0"
    frontend_image        = "masterly.azurecr.io:443/release/frontend:v0.0.0"
  }

  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : contains([for e in l : e.destination], "masterly.azurecr.io") &&
      contains([for e in l : e.destination], "*.data.azurecr.io") &&
      contains([for e in l : e.destination], "*.blob.core.windows.net")
    ])
    error_message = "Without registry_private_endpoint every subnet must list the registry's login server and its data endpoints, including with explicit HTTPS ports."
  }
}

run "outbound_allowlist_normalizes_registry_ports_and_edge_acr" {
  command = plan
  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "mirror.example.com:443/release/api:v0.138.0"
    frontend_image        = "mirror.example.com/release/frontend:v0.0.0"
    edge                  = { image = "mirror.azurecr.io:443/envoyproxy/envoy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }
  assert {
    condition = alltrue([for subnet, entries in output.outbound_allowlist :
      length([for e in entries : e if e.destination == "mirror.example.com"]) == 1 &&
      alltrue([for e in entries : join(",", e.ports) == "443" if e.destination == "mirror.example.com"]) &&
      alltrue([for host in ["mirror.azurecr.io", "*.data.azurecr.io", "*.blob.core.windows.net"] :
        contains([for e in entries : e.destination], host) == (subnet == "front")
      ])
    ])
    error_message = "Implicit and explicit HTTPS registry ports must collapse to one entry; an explicit-port edge ACR must retain its data endpoints on front only."
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
    error_message = "With registry_private_endpoint the pull stays in the VNet, so no subnet may list the registry's hosts."
  }

  # The platform set does not follow registry_private_endpoint: its registry service tags stay.
  assert {
    condition = alltrue([
      for k, l in output.outbound_allowlist : contains([for e in l : e.destination], "AzureContainerRegistry") &&
      contains([for e in l : e.destination], "Storage.swedencentral") &&
      contains([for e in l : e.destination], "login.microsoft.com")
    ])
    error_message = "With registry_private_endpoint every subnet must still list the platform set's AzureContainerRegistry, Storage.<region> and login.microsoft.com."
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

# An edge.image on Docker Hub is pulled from Docker Hub's three hosts, whichever of Docker Hub's
# names the reference carries: docker.io alone admits no pull. The reference is the form
# edge.image's own validation message gives as its example.
run "outbound_allowlist_docker_hub_hosts_for_a_docker_io_edge_image" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = { image = "docker.io/envoyproxy/envoy:v1.41.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      length(setsubtract(["registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com"], [for e in output.outbound_allowlist["front"] : e.destination])) == 0 &&
      alltrue([for e in output.outbound_allowlist["front"] : e.source == "edge.image" if strcontains(e.destination, "docker")])
    )
    error_message = "With edge.image on docker.io, ca-edge's subnet must list Docker Hub's three pull hosts, each with edge.image as its source."
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : e.destination != "docker.io" && !(k != "front" && strcontains(e.destination, "docker"))]
    ]))
    error_message = "No subnet may list the bare docker.io, which no pull uses, and no subnet but ca-edge's may list Docker Hub."
  }
}

run "outbound_allowlist_docker_hub_hosts_for_an_index_docker_io_edge_image" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = { image = "Index.Docker.IO/envoyproxy/envoy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      length(setsubtract(["registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com"], [for e in output.outbound_allowlist["front"] : e.destination])) == 0 &&
      alltrue([for e in output.outbound_allowlist["front"] : lower(e.destination) != "index.docker.io"])
    )
    error_message = "With edge.image on index.docker.io, in any case, ca-edge's subnet must list Docker Hub's three pull hosts and not the reference's host."
  }
}

run "outbound_allowlist_docker_hub_hosts_for_a_registry_1_docker_io_edge_image" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = { image = "registry-1.docker.io/envoyproxy/envoy:v1.41.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }

  assert {
    condition = (
      length(setsubtract(["registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com"], [for e in output.outbound_allowlist["front"] : e.destination])) == 0 &&
      length([for e in output.outbound_allowlist["front"] : e if e.destination == "registry-1.docker.io"]) == 1
    )
    error_message = "With edge.image on registry-1.docker.io, ca-edge's subnet must list Docker Hub's three pull hosts, and registry-1.docker.io once."
  }
}

# --- The identity provider ---------------------------------------------------------------------

run "outbound_allowlist_idp_hosts_follow_their_workloads" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "http://idp.example.com:8080/tenant/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = sensitive("http://keys.example.com/tenant/discovery/keys")
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = sensitive("http://idp.example.com:8080/tenant/v2.0")
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
      !contains([for e in output.outbound_allowlist["app"] : e.destination], "idp.example.com") &&
      !issensitive(output.outbound_allowlist) &&
      one([for e in output.outbound_allowlist["front"] : join(",", e.ports) if e.destination == "idp.example.com"]) == "8080" &&
      one([for e in output.outbound_allowlist["app"] : join(",", e.ports) if e.destination == "keys.example.com"]) == "80"
    )
    error_message = "The issuer's host must sit with ca-frontend (front) and the signing keys' host with ca-api (app), preserving explicit ports and defaulting HTTP to 80."
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

# telemetry_url's host goes with the licence refresh: on the subnet ca-workers runs on, with its port.
run "outbound_allowlist_telemetry_host_with_workers" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    telemetry_url           = "https://telemetry.masterlydata.com:8443/v1/reports"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    enable_workers          = true
    workers_environment     = "workers"
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["workers"] : e.destination], "telemetry.masterlydata.com") &&
      alltrue([for e in output.outbound_allowlist["workers"] : length(e.ports) == 1 && contains(e.ports, "8443") && e.source == "telemetry_url" if e.destination == "telemetry.masterlydata.com"]) &&
      !contains([for e in output.outbound_allowlist["front"] : e.destination], "telemetry.masterlydata.com") &&
      !contains([for e in output.outbound_allowlist["aca"] : e.destination], "telemetry.masterlydata.com")
    )
    error_message = "telemetry_url's host and port must be listed on the subnet ca-workers runs on, and not where only ca-frontend and ca-api run."
  }
}

# With every app on its own subnet, the control plane's two hosts are on ca-workers' subnet and on
# no other: ca-api (app) holds the same URLs and credential but does not call them.
run "outbound_allowlist_control_plane_on_ca_workers_subnet_alone" {
  command = plan

  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    license_issuer_url      = "https://cp.masterlydata.com/v1/licenses/refresh"
    telemetry_url           = "https://telemetry.masterlydata.com/v1/reports"
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    enable_workers          = true
    workers_environment     = "workers"
    frontend_environment    = "front"
    edge_environment        = "front"
    api_environment         = "app"
  }

  assert {
    condition     = length(setsubtract(["cp.masterlydata.com", "telemetry.masterlydata.com"], [for e in output.outbound_allowlist["workers"] : e.destination])) == 0
    error_message = "With enable_workers, the hosts of license_issuer_url and telemetry_url must be listed on the subnet ca-workers runs on."
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "masterlydata.com")] if k != "workers"
    ]))
    error_message = "With enable_workers, no subnet but ca-workers' may list the control plane: ca-api does not call it once ca-workers exists."
  }
}

# The placement above rests on what the api image does: v0.138.0 runs the licence refresh and the
# fleet reports only in the process that runs the pipeline. The output's description cites that
# released version, so the release MANIFEST.json names as latest must not name an older api.
run "outbound_allowlist_control_plane_placement_cites_the_released_api" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition = (
      sum([for i, p in split(".", regex(":v([0-9]+\\.[0-9]+\\.[0-9]+)$", local.release_manifest.releases[local.release_manifest.latest].images.api)[0]) : tonumber(p) * pow(1000000, 2 - i)]) >=
      sum([for i, p in split(".", "0.138.0") : tonumber(p) * pow(1000000, 2 - i)])
    )
    error_message = "MANIFEST.json's latest release names an api image older than v0.138.0, the version outbound_allowlist's description cites for the control plane's placement. Check that image's behaviour and update the description, network.tf and docs/networking.md."
  }
}

# --- Threat: secret disclosure ------------------------------------------------------------------

# A calling root can mark these URLs sensitive; only parsed destinations may leave the module.
run "outbound_allowlist_sensitive_license_issuer_url" {
  command = plan
  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    license_token           = "eyJ.fake.jwt"
    license_public_jwk      = "{\"kty\":\"EC\"}"
    license_issuer_url      = sensitive("https://cp.masterlydata.com/v1/licenses/refresh")
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    enable_workers          = true
    workers_environment     = "workers"
  }
  assert {
    condition = (
      !issensitive(output.outbound_allowlist) &&
      !strcontains(jsonencode(output.outbound_allowlist), "/v1/licenses/refresh") &&
      jsonencode(flatten([for k, entries in output.outbound_allowlist : [
        for e in entries : "${k}=${e.destination}:${join(",", e.ports)}" if e.source == "license_issuer_url"
      ]])) == jsonencode(["workers=cp.masterlydata.com:443"])
    )
    error_message = "A sensitive license_issuer_url must plan with only its host and default port public, on ca-workers' subnet."
  }
}

run "outbound_allowlist_sensitive_telemetry_url" {
  command = plan
  variables {
    ingress_allowed_cidrs   = ["203.0.113.7/32"]
    telemetry_url           = sensitive("https://telemetry.masterlydata.com:8443/v1/reports")
    telemetry_client_id     = "sa_01TEST"
    telemetry_client_secret = "s3cret"
    enable_workers          = true
    workers_environment     = "workers"
  }
  assert {
    condition = (
      !issensitive(output.outbound_allowlist) &&
      !strcontains(jsonencode(output.outbound_allowlist), "/v1/reports") &&
      jsonencode(flatten([for k, entries in output.outbound_allowlist : [
        for e in entries : "${k}=${e.destination}:${join(",", e.ports)}" if e.source == "telemetry_url"
      ]])) == jsonencode(["workers=telemetry.masterlydata.com:8443"])
    )
    error_message = "A sensitive telemetry_url must plan with only its host and explicit port public, on ca-workers' subnet."
  }
}

run "outbound_allowlist_sensitive_identity_provider_urls" {
  command = plan
  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    identity_binding      = "oidc"
    oidc_allowed_issuers  = "https://idp.example.com/tenant/v2.0"
    oidc_audience         = "api-client-id"
    oidc_jwks_uri         = sensitive("https://keys.example.com:8443/tenant/discovery/keys")
    oidc_client_id        = "bff-client-id"
    oidc_client_secret    = "s3cret"
    oidc_authority        = sensitive("https://idp.example.com/tenant/v2.0")
    oidc_redirect_uri     = "https://app.example.com/api/auth/callback"
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
  }
  assert {
    condition = (
      !issensitive(output.outbound_allowlist) &&
      !strcontains(jsonencode(output.outbound_allowlist), "/tenant/") &&
      jsonencode(sort(flatten([for k, entries in output.outbound_allowlist : [
        for e in entries : "${k}=${e.destination}:${join(",", e.ports)}" if contains(["oidc_authority", "oidc_jwks_uri"], e.source)
      ]]))) == jsonencode(["app=keys.example.com:8443", "front=idp.example.com:443"])
    )
    error_message = "Sensitive IdP URLs must plan with only issuer and JWKS hosts/ports public, on their respective workloads' subnets."
  }
}

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

  # The conditional entries (database, Service Bus, Communication Services, Key Vault) have the
  # same six fields as the platform set, none empty.
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
    error_message = "Every entry, the conditional ones included, must have destination, kind, protocol, ports, why and source, none empty."
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

# In production the vault and a Premium namespace are reached over their private endpoints: no
# subnet lists either, while the database the install still reaches over the network stays.
run "outbound_allowlist_no_key_vault_or_service_bus_in_production" {
  command = plan

  # The production example's shape, as in sizing.tftest.hcl.
  variables {
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
    redis_offering        = "managed"
    enable_workers        = true
    enable_service_bus    = true
    servicebus_sku        = "Premium"
    api_min_replicas      = 2
    api_max_replicas      = 3
    frontend_min_replicas = 1
    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
    migrations            = "job"
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : !strcontains(e.destination, "vault.azure.net") && !strcontains(e.destination, "servicebus.windows.net")
      ]
    ]))
    error_message = "In production no subnet may list the install's Key Vault or its Premium Service Bus namespace: both are reached over private endpoints."
  }

  assert {
    condition     = anytrue([for k, l in output.outbound_allowlist : contains([for e in l : e.destination], "pg.example.com")])
    error_message = "In production the BYO-DB host must still be listed."
  }
}

# Threat (secret disclosure): the migrate job's admin DSN carries the migration role's
# credentials. Only its host and port leave it, on the subnet caj-migrate runs on, and caj-migrate
# lists the admin host instead of external_database_url's.
run "outbound_allowlist_admin_database_host_on_caj_migrate_only" {
  command = plan

  # migrations = "job" is refused in demo, so this is the production shape of the run above, with
  # the job moved to the workers environment: ca-api and ca-workers stay on aca.
  variables {
    mode                        = "production"
    identity_binding            = "oidc"
    oidc_allowed_issuers        = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience               = "api-client-id"
    oidc_jwks_uri               = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id              = "bff-client-id"
    oidc_client_secret          = "s3cret"
    oidc_authority              = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri           = "https://app.example.com/api/auth/callback"
    license_token               = "eyJ.fake.jwt"
    license_public_jwk          = "{\"kty\":\"EC\"}"
    initial_owner_email         = "owner@example.com"
    enable_key_vault            = true
    enable_redis                = true
    redis_offering              = "managed"
    enable_workers              = true
    enable_service_bus          = true
    servicebus_sku              = "Premium"
    api_min_replicas            = 2
    api_max_replicas            = 3
    frontend_min_replicas       = 1
    migrations                  = "job"
    migrate_job_environment     = "workers"
    external_database_url       = "postgres://u:p@db.example.com:5432/m"
    external_database_admin_url = "postgres://admin:pw@admin-db.example.com:6432/m"
  }

  assert {
    condition = jsonencode(distinct(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : "${k}=${e.destination}:${join(",", e.ports)}"
        if strcontains(jsonencode(e), "admin-db.example.com") || contains(e.ports, "6432")
      ]
    ]))) == jsonencode(["workers=admin-db.example.com:6432"])
    error_message = "external_database_admin_url must give admin-db.example.com:6432 on the subnet caj-migrate runs on (workers) and nowhere else."
  }

  assert {
    condition     = alltrue([for e in output.outbound_allowlist["workers"] : e.source == "external_database_admin_url" if e.destination == "admin-db.example.com"])
    error_message = "The admin database entry must name external_database_admin_url as its source."
  }

  # caj-migrate is the workers subnet's only workload here, and it connects as the admin role.
  assert {
    condition = (
      !contains([for e in output.outbound_allowlist["workers"] : e.destination], "db.example.com") &&
      contains([for e in output.outbound_allowlist["aca"] : e.destination], "db.example.com")
    )
    error_message = "With external_database_admin_url, caj-migrate must list the admin host, not external_database_url's, which stays with ca-api."
  }

  # The Learn sources carry https://, so the check is on the DSN's own scheme and userinfo.
  assert {
    condition = (
      !strcontains(jsonencode(output.outbound_allowlist), "admin:pw") &&
      !strcontains(jsonencode(output.outbound_allowlist), "u:p") &&
      !strcontains(jsonencode(output.outbound_allowlist), "postgres://") &&
      !strcontains(jsonencode(output.outbound_allowlist), "pw@")
    )
    error_message = "The allowlist must carry no scheme or userinfo from external_database_admin_url or external_database_url."
  }
}

# An IPv6 host loses the URL's brackets, so a rule built from the entry names the bare address.
run "outbound_allowlist_database_ipv6_host_without_brackets" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    external_database_url = "postgres://u:p@[2001:DB8::1]:5432/m"
  }

  assert {
    condition = jsonencode(distinct(flatten([
      for k, l in output.outbound_allowlist : [
        for e in l : "${e.destination}|${join(",", e.ports)}" if e.source == "external_database_url"
      ]
    ]))) == jsonencode(["2001:db8::1|5432"])
    error_message = "A bracketed IPv6 database host must give the bare, lower-case address on its port."
  }
}

# The certificate vaults the custom domains name sit with the app each certificate is bound to.
run "outbound_allowlist_certificate_vaults_follow_their_apps" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    frontend_environment  = "front"
    edge_environment      = "front"
    api_environment       = "app"
    edge                  = { image = "masterly.azurecr.io/mirror/envoy:v1.40.2@sha256:1111111111111111111111111111111111111111111111111111111111111111" }
    frontend_custom_domain = {
      hostname                        = "masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-front-certs.vault.azure.net/secrets/masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-front-certs"
    }
    edge_custom_domain = {
      hostname                        = "api.masterly.example.com"
      certificate_key_vault_secret_id = "https://kv-edge-certs.vault.azure.net/secrets/api-masterly-example-com"
      key_vault_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-customer-certs/providers/Microsoft.KeyVault/vaults/kv-edge-certs"
    }
  }

  assert {
    condition = (
      contains([for e in output.outbound_allowlist["front"] : "${e.destination}|${e.source}"], "kv-front-certs.vault.azure.net|frontend_custom_domain") &&
      contains([for e in output.outbound_allowlist["front"] : "${e.destination}|${e.source}"], "kv-edge-certs.vault.azure.net|edge_custom_domain")
    )
    error_message = "Each custom domain's certificate vault must be listed on the subnet its app runs on (front), naming its input."
  }

  assert {
    condition = alltrue(flatten([
      for k, l in output.outbound_allowlist : [for e in l : !strcontains(e.destination, "-certs.vault.azure.net")] if k != "front"
    ]))
    error_message = "The certificate vaults must be listed only where ca-frontend and ca-edge run."
  }
}

# With edge.jwt_authn ca-edge fetches the tenant's signing keys. They are on login.microsoftonline.com,
# which the platform set already lists, so the subnet keeps the one platform entry for that host.
run "outbound_allowlist_edge_jwt_authn_reaches_the_signing_keys" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = { jwt_authn = { audiences = ["api://masterly-api"] } }
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = contains([for e in values(local.outbound_workload_entries["ca-edge"]) : "${e.destination}|${e.source}"], "login.microsoftonline.com|oidc_jwks_uri")
    error_message = "With edge.jwt_authn, ca-edge must reach the signing keys' host."
  }

  assert {
    condition     = length([for e in output.outbound_allowlist["aca"] : e if e.destination == "login.microsoftonline.com"]) == 1
    error_message = "The signing keys' host and the platform set's Entra ID entry must be one entry on ca-edge's subnet."
  }
}

run "outbound_allowlist_no_signing_keys_on_ca_edge_without_jwt_authn" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    edge                  = {}
    oidc_tenant_id        = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = alltrue([for e in values(local.outbound_workload_entries["ca-edge"]) : e.source != "oidc_jwks_uri"])
    error_message = "Without edge.jwt_authn, ca-edge must not list the signing keys."
  }
}
