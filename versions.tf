terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Floor raised from ~> 4.0 for the Azure Managed Redis path (ADR 0071). This is
      # load-bearing rather than housekeeping: .terraform.lock.hcl is gitignored, so a
      # customer's `terraform init` is governed by THIS constraint alone, and ~> 4.0 admits
      # 4.0.0-4.49.x where azurerm_managed_redis does not exist at all. Two gates are verified
      # in CHANGELOG-v4.md: azurerm_managed_redis is new in 4.50.0, and public_network_access
      # on it arrives in 4.53.0 — without which "no public network presence" is inexpressible.
      # 4.53.0 is therefore the true floor. The constraint sits at 4.61 for headroom, not for a
      # third gate: an earlier draft of this comment claimed 4.61 made sku_name updatable and
      # default_database required at create, and the changelog does not say that. Only 4.80.0
      # was ever inspected directly. Left conservative rather than lowered to 4.53 on an
      # untested version. Not 5.x: outside the module's tested surface, and azurerm 5 defaults
      # resource_provider_registrations to none.
      version = "~> 4.61"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
