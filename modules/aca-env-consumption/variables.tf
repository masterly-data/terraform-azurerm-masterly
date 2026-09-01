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
