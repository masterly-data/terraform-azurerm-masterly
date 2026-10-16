output "id" {
  value       = azurerm_log_analytics_workspace.this.id
  description = "Workspace resource ID."
}

output "workspace_id" {
  value       = azurerm_log_analytics_workspace.this.workspace_id
  description = "The workspace's customer ID (a UUID), which queries and ingestion address it by."
}

output "local_authentication_enabled" {
  value       = azurerm_log_analytics_workspace.this.local_authentication_enabled
  description = "Whether the workspace's shared keys authenticate anything. Always false."
}

output "internet_ingestion_access_type" {
  value       = azurerm_log_analytics_workspace.this.internet_ingestion_access_type
  description = "Whether the workspace accepts ingestion over the public network. Always \"Disabled\"."
}

output "internet_query_access_type" {
  value       = azurerm_log_analytics_workspace.this.internet_query_access_type
  description = "Whether the workspace answers queries over the public network: \"Enabled\" or \"Disabled\"."
}

output "retention_in_days" {
  value       = azurerm_log_analytics_workspace.this.retention_in_days
  description = "The workspace's retention, which every table without its own follows."
}

output "table_retention_days" {
  value = {
    (azurerm_log_analytics_workspace_table.key_vault_audit.name) = azurerm_log_analytics_workspace_table.key_vault_audit.retention_in_days
  }
  description = "Retention in days of each table the module sets one on, by table name."
}
