output "id" {
  value       = azurerm_user_assigned_identity.this.id
  description = "UAMI resource ID."
}

output "principal_id" {
  value       = azurerm_user_assigned_identity.this.principal_id
  description = "Object ID — used in role assignments."
}

output "client_id" {
  value       = azurerm_user_assigned_identity.this.client_id
  description = "Application ID — used for AZURE_CLIENT_ID in workload runtime."
}

output "tenant_id" {
  value       = azurerm_user_assigned_identity.this.tenant_id
  description = "Entra tenant ID of the identity."
}
