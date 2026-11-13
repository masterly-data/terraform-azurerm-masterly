output "frontend_url" {
  value       = local.frontend_custom_hostname != null ? "https://${local.frontend_custom_hostname}" : "https://${module.frontend.fqdn}"
  description = "The install's public URL (subject to the ingress IP allowlist): https://<hostname> with frontend_custom_domain set, otherwise the frontend's Container Apps FQDN."
}

# The api's address for something outside the Container App Environment — the Python SDK, a
# pipeline, an integration. Null unless api_ingress_external is true, because an internal api has
# no address a caller outside the environment can use; returning one would invite a base URL
# that cannot connect. Built from the hostname Azure reports, so it is the right string for a
# person to copy into a client, not one to wire into another resource: an in-environment caller
# such as the frontend addresses the api by its app name (`ca-api`), which cannot drift.
output "api_url" {
  value       = var.api_ingress_external ? "https://${module.api.fqdn}" : null
  description = "The api's base URL for clients outside the Container App Environment (the Python SDK, your own pipelines), subject to the ingress IP allowlist. Null unless api_ingress_external is true. On an internal environment (aca_internal_load_balancer) it is reachable from the VNet, not the internet."
}

# Kept under its original name so existing configurations that read it keep planning. The name
# predates api_ingress_external: what it holds follows that variable, and api_url is the output
# to read for a client's base URL.
output "api_internal_fqdn" {
  value       = module.api.fqdn
  description = "The api's ingress hostname as Azure reports it, without a scheme. Despite the name, it is the internal hostname only while api_ingress_external is false (reachable only inside the Container App Environment); when it is true this is the api's published hostname. For a client's base URL read api_url instead. Fine to read as a hostname, but do not wire app-to-app traffic to it: Azure has been observed to report an internal app's hostname in the external form, which plans as a change made outside Terraform. Apps in the same environment address the api by its Container App name."
}

output "postgres_fqdn" {
  value       = one(azurerm_postgresql_flexible_server.this[*].fqdn)
  description = "FQDN of the provisioned starter Postgres server (null on BYO-DB installs, ADR 0065)."
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
