variable "name" {
  type        = string
  description = "User-assigned managed identity name, e.g. id-ca-license-issuer-eu."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the user-assigned identity."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the user-assigned identity."
}
