output "communication_service_id" {
  value       = azurerm_communication_service.this.id
  description = "Scope for the 'Communication and Email Service Owner' role assignment (granted at the root)."
}

output "endpoint" {
  value       = "https://${azurerm_communication_service.this.hostname}"
  description = "ACS endpoint — enter under Notifications -> Integrations -> Email (provider azure-acs)."
}

output "sender_address" {
  value       = "DoNotReply@${azurerm_email_communication_service_domain.managed.from_sender_domain}"
  description = "Default sender for the Azure-managed domain — the azure-acs 'from' address."
}
