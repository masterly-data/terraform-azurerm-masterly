output "id" {
  value       = azurerm_container_app_environment.this.id
  description = "Resource ID of the Container App Environment."
}

output "name" {
  value       = azurerm_container_app_environment.this.name
  description = "Name of the Container App Environment."
}

output "default_domain" {
  value       = azurerm_container_app_environment.this.default_domain
  description = "Default domain suffix assigned to apps in this environment. On an internal environment, the name of the private DNS zone that resolves them."
}

# SELF-HOSTED EXTENSION
output "static_ip_address" {
  value       = azurerm_container_app_environment.this.static_ip_address
  description = "The environment's static IP: a private address in its subnet when the load balancer is internal, a public one otherwise. The target of the wildcard A record in the environment's private DNS zone."
}

output "internal_load_balancer_enabled" {
  value       = azurerm_container_app_environment.this.internal_load_balancer_enabled
  description = "Whether the environment answers only inside the VNet."
}

output "logs_destination" {
  value       = azurerm_container_app_environment.this.logs_destination
  description = "Where the environment sends its apps' console and system logs. Always \"azure-monitor\": the logs reach a workspace only through a diagnostic setting the caller attaches to this environment."
}

output "mutual_tls_enabled" {
  value       = azurerm_container_app_environment.this.mutual_tls_enabled
  description = "Whether traffic between apps inside the environment is encrypted."
}

# SELF-HOSTED EXTENSION. Read from the resource, not the inputs, so a test proves what the
# environment itself declares; both are configured values, known at plan.
output "infrastructure_subnet_id" {
  value       = azurerm_container_app_environment.this.infrastructure_subnet_id
  description = "The subnet the environment runs in."
}

output "workload_profiles" {
  value = [
    for p in azurerm_container_app_environment.this.workload_profile : {
      name                  = p.name
      workload_profile_type = p.workload_profile_type
    }
  ]
  description = "The workload profiles the environment declares, each with its name and workload_profile_type."
}

# SELF-HOSTED EXTENSION. Echoes the configuration rather than the resource, so a test can read it
# at plan.
output "identity_ids" {
  value       = var.identity_ids
  description = "The user-assigned identity ids attached to the environment itself. Empty unless the caller attached some."
}

# SELF-HOSTED EXTENSION. Sensitive, as the provider marks the attribute. The value is not a
# secret: it is published in DNS, as the asuid.<hostname> TXT record.
output "custom_domain_verification_id" {
  value       = azurerm_container_app_environment.this.custom_domain_verification_id
  sensitive   = true
  description = "The value of the asuid.<hostname> TXT record Azure checks before it binds a custom domain to an app in this environment."
}

output "zone_redundancy_enabled" {
  description = "Whether the environment is zone-redundant. Create-time only: a change replaces the environment."
  value       = azurerm_container_app_environment.this.zone_redundancy_enabled
}
