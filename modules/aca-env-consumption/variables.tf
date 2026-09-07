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

variable "log_analytics_workspace_id" {
  type        = string
  description = "Resource ID of the Log Analytics workspace that receives container logs."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the environment."
}

# SELF-HOSTED EXTENSION
variable "infrastructure_subnet_id" {
  type        = string
  default     = null
  description = "Subnet for VNet integration (consumption-only environments need /23 or larger). Null = no VNet. CREATE-TIME ONLY: changing this replaces the environment and its FQDNs."
}

variable "internal_load_balancer_enabled" {
  type        = bool
  default     = false
  description = "Give the environment an internal load balancer instead of a public endpoint (requires infrastructure_subnet_id, which this module always sets)."
}

# SELF-HOSTED EXTENSION: peer-to-peer encryption inside the environment. Not in the
# platform-iac original — Layer 2's apps are all external-ingress, so it has no
# in-environment hop worth encrypting.
variable "mutual_tls_enabled" {
  type        = bool
  default     = true
  description = "Encrypt traffic between apps inside the environment. TRUE by default: the frontend's BFF calls the api over http://ca-api, and without this that hop is plaintext on the environment's network. Azure manages the certificates and the apps do not see them, so callers keep using http:// — the platform encrypts the hop underneath (Microsoft: \"your application usually doesn't need to care whether the traffic is encrypted or not\"). Set false only to measure it away: Microsoft documents that it may increase response latency and reduce maximum throughput under high load."
}
