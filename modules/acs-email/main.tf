# Azure Communication Services email — the self-hosted, customer-owned email provider (ADR 0040).
# Authentication is the install's managed identity (the role assignment lives at the root, granting
# the apps identity "Communication and Email Service Owner" on the Communication Service); no
# connection-string secret is stored anywhere (constraint #7).

resource "azurerm_communication_service" "this" {
  name                = "acs-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  data_location       = var.data_location
  tags                = var.tags
}

resource "azurerm_email_communication_service" "this" {
  name                = "acs-email-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  data_location       = var.data_location
  tags                = var.tags
}

# An Azure-managed domain: a *.azurecomm.net sender that is auto-verified — no DNS records to add,
# so the whole setup is pure azurerm. A custom domain (CustomerManaged) needs DNS verification and
# is a documented follow-up (see README).
resource "azurerm_email_communication_service_domain" "managed" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.this.id
  domain_management = "AzureManaged"
}

# Connect the domain so the Communication Service is allowed to send from it.
resource "azurerm_communication_service_email_domain_association" "this" {
  communication_service_id = azurerm_communication_service.this.id
  email_service_domain_id  = azurerm_email_communication_service_domain.managed.id
}
