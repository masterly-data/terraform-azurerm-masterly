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
  }
}
