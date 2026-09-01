output "frontend_url" {
  value       = "https://${module.frontend.fqdn}"
  description = "The install's public URL (subject to the ingress IP allowlist)."
}

output "api_internal_fqdn" {
  value       = module.api.fqdn
  description = "The api's internal-ingress FQDN (reachable only inside the ACA environment)."
}

output "postgres_fqdn" {
  value       = one(azurerm_postgresql_flexible_server.this[*].fqdn)
  description = "FQDN of the provisioned starter Postgres server (null on BYO-DB installs, ADR 0065)."
}

output "apps_identity_principal_id" {
  value       = module.apps_identity.principal_id
  description = "Principal (object) id of the apps' user-assigned identity — grant AcrPull on your registry scope to this principal when acr_id is left null."
}

output "apps_identity_client_id" {
  value       = module.apps_identity.client_id
  description = "Client id of the apps' user-assigned identity (DefaultAzureCredential's AZURE_CLIENT_ID)."
}

output "resource_group_aca" {
  value       = azurerm_resource_group.aca.name
  description = "The apps resource group — the app repos' release workflows roll images here (DEMO_RG)."
}

output "api_app_name" {
  value       = module.api.name
  description = "Container App name of the api (DEMO_APP_API)."
}

output "frontend_app_name" {
  value       = module.frontend.name
  description = "Container App name of the frontend (DEMO_APP_FRONTEND)."
}

output "aca_environment_id" {
  value       = module.aca_env.id
  description = "Resource ID of the Container App Environment."
}

output "service_bus_namespace" {
  value       = var.enable_service_bus ? azurerm_servicebus_namespace.this[0].name : null
  description = "Service Bus namespace short name when enabled (null = the install runs the polling bus binding, ADR 0029)."
}

output "install_id" {
  value       = var.install_id
  description = "The Install's logical id within its Organization (ADR 0039)."
}

output "org_id" {
  value       = var.org_id
  description = "The Organization that owns this Install (ADR 0039)."
}
