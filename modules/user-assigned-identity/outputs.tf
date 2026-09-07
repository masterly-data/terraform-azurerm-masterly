output "id" {
  value       = azurerm_user_assigned_identity.this.id
  description = "UAMI resource ID."
}

# The name is part of the contract, not cosmetics: renaming a UAMI REPLACES it, which means a
# new principal id and every out-of-band role grant customers made against the old one stops
# applying. Exposed so `terraform test` can pin it.
output "name" {
  value       = azurerm_user_assigned_identity.this.name
  description = "Name of the user-assigned identity."
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
