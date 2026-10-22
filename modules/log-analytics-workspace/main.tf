resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  retention_in_days   = var.retention_days
  tags                = var.tags

  # Microsoft Entra ID only: the workspace's shared keys authenticate nothing, so every reader
  # and writer is a named identity holding a role on the workspace.
  local_authentication_enabled = false

  # No ingestion over the public network. Diagnostic settings deliver inside Azure Monitor and
  # are not affected; anything else must send through an Azure Monitor Private Link Scope.
  # Neither is ever "SecuredByPerimeter": the module does not place the workspace in a network
  # security perimeter.
  internet_ingestion_access_type = "Disabled"
  internet_query_access_type     = var.internet_query_enabled ? "Enabled" : "Disabled"
}

# Key Vault audit events (AuditEvent, written to the resource-specific AZKVAuditLogs table) are
# the record of who read or changed which secret, and are usually kept longer than operational
# logs. Only this table gets its own retention; every other table follows retention_days.
#
# total_retention_in_days is set to the same value, which means no archive tier. Left unset,
# Azure fills it in on create (equal to the retention), the next plan proposes setting it back
# to null, and Azure refuses that update ("The specified total retention value is invalid"), so
# every apply after the first failed on this table.
resource "azurerm_log_analytics_workspace_table" "key_vault_audit" {
  name                    = "AZKVAuditLogs"
  workspace_id            = azurerm_log_analytics_workspace.this.id
  retention_in_days       = var.security_retention_days
  total_retention_in_days = var.security_retention_days
}
