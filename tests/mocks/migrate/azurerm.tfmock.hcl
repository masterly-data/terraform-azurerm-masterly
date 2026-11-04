# ARM-shaped computed values shared by migration apply/teardown tests. Keep the real
# resources and modules in state; plan-only identity tests override their outputs separately.
mock_data "azurerm_client_config" {
  defaults = {
    tenant_id = "00000000-0000-0000-0000-000000000000"
    object_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
  }
}
mock_data "azurerm_resources" {
  defaults = { resources = [] }
}
mock_resource "azurerm_resource_group" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data" } }
mock_resource "azurerm_virtual_network" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/virtualNetworks/vnet-masterly" } }
mock_resource "azurerm_subnet" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/virtualNetworks/vnet-masterly/subnets/snet-aca" } }
mock_resource "azurerm_network_security_group" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/networkSecurityGroups/nsg-masterly" } }
mock_resource "azurerm_private_dns_zone" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com" } }
mock_resource "azurerm_log_analytics_workspace" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.OperationalInsights/workspaces/log-masterly" } }
mock_resource "azurerm_container_app_environment" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly" } }
mock_resource "azurerm_container_app" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-test" } }
mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-test"
    principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
    tenant_id    = "00000000-0000-0000-0000-000000000000"
  }
}
mock_resource "azurerm_postgresql_flexible_server" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-masterly-before" } }
mock_resource "azurerm_key_vault" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-before" } }
mock_resource "azurerm_key_vault_secret" {
  defaults = {
    versionless_id          = "https://kv-masterly-before.vault.azure.net/secrets/install-test"
    resource_versionless_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.KeyVault/vaults/kv-masterly-before/secrets/install-test"
  }
}
mock_resource "azurerm_servicebus_namespace" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ServiceBus/namespaces/sb-masterly-before" } }
mock_resource "azurerm_servicebus_queue" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ServiceBus/namespaces/sb-masterly-before/queues/masterly-jobs" } }
mock_resource "azurerm_monitor_action_group" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.Insights/actionGroups/ag-masterly-alerts" } }
mock_resource "azurerm_redis_cache" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-data/providers/Microsoft.Cache/redis/redis-masterly-test"
  }
}
mock_resource "azurerm_container_app_job" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/jobs/caj-migrate" } }
