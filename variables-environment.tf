# Inputs read by environment.tf: the Container App Environment's log workspace.

# --- The install's Log Analytics workspace ---------------------------------------------
# The workspace accepts Microsoft Entra ID only: its shared keys authenticate nothing, and it
# takes no ingestion over the public network. The install's own logs and metrics reach it
# through diagnostic settings, which deliver inside Azure Monitor and need neither. These inputs
# choose who may query it from where, and how long it keeps what it holds.

variable "log_query_public_access" {
  type        = bool
  default     = true
  description = "Whether the install's Log Analytics workspace answers queries from the public network. True (the default) lets the Azure portal, the diagnostic bundle (scripts/diagnostic-bundle.sh) and your own tools query it from wherever they run. Every query is signed in with Microsoft Entra ID, because the workspace accepts no shared key: Log Analytics Reader on the workspace runs queries, which is what the diagnostic bundle needs, and Log Analytics Contributor also changes the workspace's settings. Set false to answer only queries that arrive through an Azure Monitor Private Link Scope (AMPLS). The module creates no AMPLS, because an AMPLS changes how every Azure Monitor endpoint resolves for the whole network that uses its private DNS zones, not only this workspace's, so it belongs to whoever owns that network. Before setting false: add the workspace to your AMPLS, give the AMPLS a private endpoint in a network your operators query from, with its privatelink DNS zones linked to that network, and run the diagnostic bundle from inside it. Ingestion over the public network is off whatever this says. The module does not place the workspace in a network security perimeter: an enforced perimeter decides which sources may send logs to the workspace and which may query it, including the diagnostic settings that deliver this install's logs, so its access rules have to be written for your whole estate, which only you can see. This setting, with an AMPLS you own, restricts queries without one. If you associate the workspace with a perimeter of your own, start it in transition mode and confirm the install's logs still arrive before you enforce it."
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "Days the install's Log Analytics workspace keeps what it holds, for every table except AZKVAuditLogs (which follows security_log_retention_days): the apps' console and system logs, the data-plane resources' logs and the metrics the diagnostic settings send (30-730). Azure bills retention beyond the first 31 days per GB per month. Lowering it removes data older than the new window."

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "security_log_retention_days" {
  type        = number
  default     = 90
  description = "Days the install's Log Analytics workspace keeps the AZKVAuditLogs table, which holds the Key Vault audit events: every operation on the install's vault, successful or refused, with the identity that made it (30-730). It is set as the retention of that table alone, so the audit trail can be kept longer than the operational logs log_retention_days governs. The table exists in every workspace, so this is applied whether or not the install has a vault; it holds rows only when enable_key_vault and diagnostics (enable_diagnostics) are both on. Azure bills retention beyond the first 31 days per GB per month. Lowering it removes audit events older than the new window."

  validation {
    condition     = var.security_log_retention_days >= 30 && var.security_log_retention_days <= 730
    error_message = "security_log_retention_days must be between 30 and 730."
  }
}
