output "id" {
  value       = azurerm_log_analytics_workspace.this.id
  description = "Workspace resource ID."
}

output "workspace_id" {
  value       = azurerm_log_analytics_workspace.this.workspace_id
  description = "The customer-ID UUID used by ingestion."
}

output "primary_shared_key" {
  value       = azurerm_log_analytics_workspace.this.primary_shared_key
  description = "For agents that authenticate by key."
  sensitive   = true
}
