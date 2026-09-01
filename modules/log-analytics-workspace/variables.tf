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
  description = "Data retention window in days."
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
