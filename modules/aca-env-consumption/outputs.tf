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

output "mutual_tls_enabled" {
  # Read off the resource rather than the variable: this is the one setting whose value a
  # test must be able to pin, and the provider's write path is not obvious (see main.tf).
  value       = azurerm_container_app_environment.this.mutual_tls_enabled
  description = "Whether traffic between apps inside the environment is encrypted."
}
