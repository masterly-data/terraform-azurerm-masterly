terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # azurerm 5. A provider major changes every install's apply, so moving to it is a
      # breaking module change; CHANGELOG.md says what a calling configuration has to do.
      #
      # This constraint is load-bearing rather than housekeeping: .terraform.lock.hcl is
      # gitignored, because Terraform reads a lock file in the ROOT configuration only, so a
      # customer's `terraform init` is governed by this constraint alone.
      #
      # Why 5.8 and not 5.0. Every argument the module uses was checked against the provider's
      # 5.0 upgrade guide, and `terraform validate` and `terraform test` pass on 5.0.0 as well
      # as 5.8.0. But neither command configures the provider or calls Azure, so a version that
      # has only been through them is untested in the sense that matters. The floor is the
      # version a refreshing plan against a live install resolved before this shipped (5.8.0,
      # replacing nothing) — not the lowest one that validates. Raise it with such a plan,
      # never lower it without one.
      #
      # What v5 changes for the configuration that calls this module, as opposed to the module:
      # the provider no longer registers resource providers on the subscription by default
      # (`resource_provider_registrations` defaults to "none"). scripts/preflight.sh checks,
      # and with --register registers, exactly the set this module needs.
      #
      # The v4-era gates this floor replaces still hold inside it: azurerm_managed_redis is new
      # in 4.50.0, its public_network_access in 4.53.0, and the container app readiness probe
      # accepts the failure_count_threshold of 48 the module sets only from 4.66.0.
      version = "~> 5.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Container Apps built-in authentication (builtin-auth.tf), and starting the migrate job at
    # apply (migrate.tf): azurerm has no resource for either. Required by every configuration
    # that uses the module,
    # including one that leaves builtin_auth unset, so an air-gapped install mirrors it with
    # azurerm and random. 2.x is the line whose `body` is an HCL object rather than a JSON string.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    # The BFF's DPoP key (auth.tf, enable_bff_dpop_key): tls generates the EC P-256 key and time
    # rotates it every 90 days. Required by every configuration that uses the module, including
    # one that leaves enable_bff_dpop_key off, so an air-gapped install mirrors both with azurerm,
    # random and azapi. Neither takes any provider configuration or credential. time also holds
    # the wait before a moved workload is created again (environment.tf, environment_move).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
