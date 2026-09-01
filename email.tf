# Email delivery via the customer's own Azure Communication Services (ADR 0040) — the self-hosted
# email provider. Opt-in (default off): when enabled, this provisions ACS + an Azure-managed sender
# domain and grants the apps managed identity permission to send via Entra ID (no secret). The
# endpoint + sender are auto-wired into the api's env (MASTERLY_ACS_ENDPOINT / MASTERLY_ACS_SENDER)
# — no manual entry; a per-Environment row under Notifications -> Integrations -> Email still
# overrides them. Air-gapped installs leave this off and use SMTP.
#
# Kept in its own file (not main.tf / variables.tf / outputs.tf) so it composes cleanly — Terraform
# merges every *.tf in the module.

variable "email_acs_enabled" {
  type        = bool
  default     = false
  description = "Provision Azure Communication Services email (ADR 0040). Off by default; air-gapped installs use SMTP."
}

variable "email_acs_data_location" {
  type        = string
  default     = "Europe"
  description = "ACS data-at-rest geo — must match the install's geo (data residency, ADR 0003). E.g. Europe, United States."

  # The residency guard: an install in one geo must not park email data in another. Geos
  # outside the known map pass (set the matching ACS location deliberately).
  validation {
    condition = (
      !var.email_acs_enabled ||
      lookup({ eu = "Europe", us = "United States" }, var.masterly_region, var.email_acs_data_location) == var.email_acs_data_location
    )
    error_message = "email_acs_data_location must match the install's geo: masterly_region=eu -> \"Europe\", us -> \"United States\"."
  }
}

module "acs_email" {
  count               = var.email_acs_enabled ? 1 : 0
  source              = "./modules/acs-email"
  name_prefix         = var.name_prefix
  resource_group_name = azurerm_resource_group.aca.name
  data_location       = var.email_acs_data_location
  tags                = local.tags
}

locals {
  # Merged into the api's env in main.tf: the app's acs_endpoint/acs_sender settings.
  acs_email_env = var.email_acs_enabled ? {
    MASTERLY_ACS_ENDPOINT = module.acs_email[0].endpoint
    MASTERLY_ACS_SENDER   = module.acs_email[0].sender_address
  } : {}
}

# The apps identity sends email via Entra ID (DefaultAzureCredential) — no connection string
# (ADR 0040). "Communication and Email Service Owner" is the role ACS requires to send.
resource "azurerm_role_assignment" "acs_email_sender" {
  count                = var.email_acs_enabled ? 1 : 0
  scope                = module.acs_email[0].communication_service_id
  role_definition_name = "Communication and Email Service Owner"
  principal_id         = module.apps_identity.principal_id
}

output "acs_email_endpoint" {
  value       = var.email_acs_enabled ? module.acs_email[0].endpoint : null
  description = "ACS endpoint to enter under Notifications -> Integrations -> Email (provider azure-acs)."
}

output "acs_email_sender_address" {
  value       = var.email_acs_enabled ? module.acs_email[0].sender_address : null
  description = "Default ACS sender (from) for the azure-acs email provider."
}
