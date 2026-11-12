# The optional Service Bus transport (ADR 0029).

# --- Async bus: Azure Service Bus (optional; ADR 0029) ---------------------------
# Default off — the install runs the polling binding (the Postgres queue is the bus), so
# nothing here is provisioned or billed. When enabled, a namespace + queue are created and
# the app identity is granted data-plane send + receive (managed identity only; SAS off).

resource "azurerm_servicebus_namespace" "this" {
  count = var.enable_service_bus ? 1 : 0

  name                = "sb-${var.name_prefix}-${random_string.install.result}"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  sku                 = local.servicebus_sku
  local_auth_enabled  = false # managed identity only — no SAS connection strings (ADR 0029)

  # Premium is sized in messaging units and the service refuses a Premium namespace with
  # none, so the module states one unit and one partition (an ordinary, non-partitioned
  # namespace). Basic and Standard take neither and are given 0, the provider's own default
  # for both arguments, so an existing Basic or Standard namespace plans no change here.
  capacity                     = local.servicebus_premium ? 1 : 0
  premium_messaging_partitions = local.servicebus_premium ? 1 : 0

  # Stated rather than left to the provider's default. Every azurerm version this module
  # supports already defaults to 1.2, so this changes nothing on an install today; it keeps
  # the floor a property of the module, visible in review, instead of a provider default.
  minimum_tls_version = "1.2"

  # In production on Premium the namespace has no public network presence: public network
  # access is Disabled and the apps reach it over the private endpoint below, which is what
  # Azure's recommended baseline asks for (Azure Policy cbd11fd3-3002-4907-b6c8-579f0e700e13).
  # Disabling public access does not affect Terraform: the queue and the role assignments are
  # management-plane (ARM) operations, which a namespace's network settings do not govern.
  #
  # On Basic or Standard, and outside production, public network access stays enabled.
  # Private endpoints are a Premium-only feature on Service Bus, and IP rules would leave
  # public access enabled and need a stable source address, which a Consumption-only
  # Container Apps environment does not have. The README section "Where this module departs
  # from Azure's recommended baseline" says what that costs in posture.
  public_network_access_enabled = !local.servicebus_private

  tags = local.tags
}

resource "azurerm_servicebus_queue" "jobs" {
  count = var.enable_service_bus ? 1 : 0

  name         = "masterly-jobs"
  namespace_id = azurerm_servicebus_namespace.this[0].id

  # At-least-once delivery with idempotent handlers (ADR 0029): redeliver on failure,
  # dead-letter past the max delivery count rather than dropping work.
  max_delivery_count                   = 10
  dead_lettering_on_message_expiration = true

  # How long a worker holds a received message before Service Bus hands it to another
  # receiver. Five minutes is the most Azure allows; left unset it would be Azure's default of
  # one minute. The worker renews the lock for as long as a drain runs (api images v0.133.12
  # and later), so this is the margin after a failed renewal, not a cap on how long a drain
  # may take: a renewal that fails ends renewal for that message, and the message then
  # redelivers once this duration lapses.
  lock_duration = "PT5M"
}

# The apps' managed identity sends (publish), and receives (the worker loop) only while
# ca-workers runs as it: the two least-privilege data-plane roles rather than Data Owner. When
# ca-workers runs as its own identity (local.workers_own_identity, workers.tf), that identity
# holds the Receiver below and ca-api keeps Sender alone (ADR 0120). ca-api and ca-workers depend
# on sb_receiver, so on an install where ca-workers moves to its own identity Terraform removes it
# only after updating both apps.
resource "azurerm_role_assignment" "sb_sender" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = module.apps_identity.principal_id
}

resource "azurerm_role_assignment" "sb_receiver" {
  count = var.enable_service_bus && !local.workers_own_identity ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = module.apps_identity.principal_id
}

# The same two roles for ca-workers' own identity, when it runs as it.
resource "azurerm_role_assignment" "sb_sender_workers" {
  count = local.workers_own_identity && var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = module.workers_identity[0].principal_id
}

resource "azurerm_role_assignment" "sb_receiver_workers" {
  count = local.workers_own_identity && var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.this[0].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = module.workers_identity[0].principal_id
}

# Private DNS + endpoint (production on Premium only): the namespace's public hostname
# resolves to the private endpoint inside the VNet, so MASTERLY_SERVICEBUS_NAMESPACE and the
# hostname the apps connect to are unchanged. Skipped when a central zone is injected
# (servicebus_private_dns_zone_id).
resource "azurerm_private_dns_zone" "servicebus" {
  count = local.create_servicebus_dns ? 1 : 0

  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.aca.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus" {
  count = local.create_servicebus_dns ? 1 : 0

  name                = "pdzl-${var.name_prefix}-servicebus"
  private_dns_zone_id = azurerm_private_dns_zone.servicebus[0].id
  virtual_network_id  = local.virtual_network_id
  tags                = local.tags
}

resource "azurerm_private_endpoint" "servicebus" {
  count = local.servicebus_private ? 1 : 0

  name                = "pe-${var.name_prefix}-servicebus"
  resource_group_name = azurerm_resource_group.data.name
  location            = var.location
  subnet_id           = local.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name_prefix}-servicebus"
    private_connection_resource_id = azurerm_servicebus_namespace.this[0].id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "servicebus"
    private_dns_zone_ids = [local.servicebus_dns_zone_id]
  }

  tags = local.tags
}
