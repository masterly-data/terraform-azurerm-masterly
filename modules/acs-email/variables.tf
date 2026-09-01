variable "name_prefix" {
  type        = string
  description = "Install name prefix; ACS resource names derive from it (acs-<prefix>, acs-email-<prefix>)."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the Azure Communication Services resources."
}

variable "data_location" {
  type        = string
  default     = "Europe"
  description = "Where ACS stores data at rest — must match the install's geo for region pinning (ADR 0003). E.g. Europe, United States."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the ACS resources."
}
