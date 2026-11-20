variable "name" {
  type        = string
  description = "Name of the Container App Environment."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the environment."
}

variable "location" {
  type        = string
  description = "Azure region for the environment."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the environment."
}

# SELF-HOSTED EXTENSION
variable "infrastructure_subnet_id" {
  type        = string
  nullable    = false
  description = "Subnet for VNet integration: a /27 or larger, delegated to Microsoft.App/environments. CREATE-TIME ONLY: changing this replaces the environment and its FQDNs."
}

variable "internal_load_balancer_enabled" {
  type        = bool
  nullable    = false
  description = "Give the environment an internal load balancer instead of a public endpoint. No default: the caller decides each environment's exposure explicitly."
}

# SELF-HOSTED EXTENSION: peer-to-peer encryption inside the environment.
variable "mutual_tls_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Encrypt traffic between apps inside the environment. TRUE by default. Azure manages the certificates and the apps do not see them, so callers keep using http:// — the platform encrypts the hop underneath."
}

# SELF-HOSTED EXTENSION: identities the environment itself runs as, as in aca-env-consumption.
variable "identity_ids" {
  type        = list(string)
  default     = []
  description = "User-assigned identity ids to attach to the environment itself, not to any app in it. The environment uses them to read certificates from Key Vault. Empty (the default) attaches none."
}

# SELF-HOSTED EXTENSION: zone redundancy (ADR 0120, 2026-11-20 amendment).
variable "zone_redundancy_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Spread the environment and its apps' replicas across the region's availability zones. False by default. CREATE-TIME ONLY: changing it replaces the environment and every app in it. Needs a region with availability zones."
}
