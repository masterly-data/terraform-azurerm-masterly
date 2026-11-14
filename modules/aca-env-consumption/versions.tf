terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    # The workload-profile read (main.tf). The root module requires the same provider.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}
