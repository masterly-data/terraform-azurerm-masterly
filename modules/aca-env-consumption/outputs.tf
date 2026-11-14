output "id" {
  value       = azurerm_container_app_environment.this.id
  description = "Resource ID of the Container App Environment."
}

output "default_domain" {
  value       = azurerm_container_app_environment.this.default_domain
  description = "Default domain suffix assigned to apps in this environment."
}

output "internal_load_balancer_enabled" {
  value       = azurerm_container_app_environment.this.internal_load_balancer_enabled
  description = "Whether the environment answers only inside the VNet. A root that builds URLs or wires DNS needs to know which it got."
}

output "logs_destination" {
  value       = azurerm_container_app_environment.this.logs_destination
  description = "Where the environment sends its apps' console and system logs. Always \"azure-monitor\": the logs reach a workspace only through a diagnostic setting the caller attaches to this environment."
}

output "mutual_tls_enabled" {
  # Read off the resource rather than the variable: this is the one setting whose value a
  # test must be able to pin, and the provider's write path is not obvious (see main.tf).
  value       = azurerm_container_app_environment.this.mutual_tls_enabled
  description = "Whether traffic between apps inside the environment is encrypted."
}

# SELF-HOSTED EXTENSION. Echoes the configuration rather than the resource, so a test can read it
# at plan.
output "identity_ids" {
  value       = var.identity_ids
  description = "The user-assigned identity ids attached to the environment itself. Empty unless the caller attached some."
}

# SELF-HOSTED EXTENSION. Unknown until apply on a new environment (main.tf says why).
output "workload_profile_names" {
  value       = var.read_workload_profiles ? (local.workload_profiles == null ? [] : [for profile in local.workload_profiles : profile.name]) : null
  description = "The names of the environment's workload profiles, as Azure reports them, with read_workload_profiles on; null with it off. An empty list is a Consumption-only environment, on which Azure ignores a route table on the infrastructure subnet. Unknown at plan for an environment that does not exist yet."
}

# SELF-HOSTED EXTENSION. Sensitive, as the provider marks the attribute. The value is not a
# secret: it is published in DNS, as the asuid.<hostname> TXT record.
output "custom_domain_verification_id" {
  value       = azurerm_container_app_environment.this.custom_domain_verification_id
  sensitive   = true
  description = "The value of the asuid.<hostname> TXT record Azure checks before it binds a custom domain to an app in this environment."
}
