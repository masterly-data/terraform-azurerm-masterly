variable "name" {
  type        = string
  description = "Log Analytics workspace name."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the workspace."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "retention_days" {
  type        = number
  default     = 30
  description = "Data retention window in days for every table that has no retention of its own (30-730)."

  validation {
    condition     = var.retention_days >= 30 && var.retention_days <= 730
    error_message = "retention_days must be between 30 and 730."
  }
}

variable "security_retention_days" {
  type        = number
  default     = 90
  description = "Retention in days of the AZKVAuditLogs table, which holds Key Vault audit events (30-730)."

  validation {
    condition     = var.security_retention_days >= 30 && var.security_retention_days <= 730
    error_message = "security_retention_days must be between 30 and 730."
  }
}

variable "internet_query_enabled" {
  type        = bool
  default     = true
  description = "Whether the workspace answers queries over the public network. False leaves only queries made through an Azure Monitor Private Link Scope. Ingestion over the public network is always off."
}

variable "sku" {
  type        = string
  default     = "PerGB2018"
  description = "Workspace pricing SKU."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the workspace."
}
