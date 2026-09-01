# Diagnostics + alerts (production-hardening): wire the data-plane resources' resource logs
# and metrics to the install's existing Log Analytics workspace (module.logs), and stand up a
# minimal metric-alert set for the failure modes that page an operator. Lightweight and
# on-by-default in production; opt-in-able elsewhere.
#
# Diagnostic settings use the portable "allLogs" category group + "AllMetrics" so category
# names never drift per resource/API version. Alerts route to an optional action group; with
# no alert_email set the alerts still fire and record, they just do not notify (wire the
# action group by setting alert_email, or point alert_action_group_id at an existing group).
#
# Kept in its own file (the email.tf/keyvault.tf composition pattern) — Terraform merges every *.tf.

variable "enable_diagnostics" {
  type        = bool
  default     = null
  description = "Wire the data-plane resources' diagnostic settings + metric alerts to the install's Log Analytics workspace. Null (default) = on in mode=production, off otherwise. Set true/false to override."
}

variable "alert_email" {
  type        = string
  default     = null
  description = "Email address that receives the install's metric alerts (creates an action group). Null = no notification target (alerts still fire and are recorded; wire this or alert_action_group_id to be paged)."
}

variable "alert_action_group_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing Azure Monitor action group to route alerts to (e.g. a shared ops group / a PagerDuty webhook group). Takes precedence over alert_email. Null = use alert_email (if set) or no target."
}

locals {
  # On in production unless explicitly overridden.
  diagnostics_enabled = var.enable_diagnostics != null ? var.enable_diagnostics : var.mode == "production"

  # Which resources actually exist to wire (respect BYO-DB / opt-in seams).
  diag_postgres      = local.diagnostics_enabled && local.provision_postgres
  diag_redis         = local.diagnostics_enabled && local.redis_enabled
  diag_key_vault     = local.diagnostics_enabled && var.enable_key_vault
  diag_service_bus   = local.diagnostics_enabled && var.enable_service_bus
  postgres_burstable = local.provision_postgres && can(regex("^B_", var.postgres_sku_name))

  # Alert action-group resolution: an injected group wins, else the module's own (created
  # only when alert_email is set), else none.
  alert_action_group_id = var.alert_action_group_id != null ? var.alert_action_group_id : (
    var.alert_email != null ? azurerm_monitor_action_group.alerts[0].id : null
  )
  alert_action_group_ids = local.alert_action_group_id != null ? [local.alert_action_group_id] : []
}

# --- Diagnostic settings -> the install's Log Analytics workspace -------------------

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  count = local.diag_postgres ? 1 : 0

  name                       = "diag-${var.name_prefix}-postgres"
  target_resource_id         = azurerm_postgresql_flexible_server.this[0].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "redis" {
  count = local.diag_redis ? 1 : 0

  name                       = "diag-${var.name_prefix}-redis"
  target_resource_id         = local.redis_resource_id
  log_analytics_workspace_id = module.logs.id

  # Logs split by offering (ADR 0071). Microsoft.Cache/redis carries its log categories on the
  # cache itself. Microsoft.Cache/redisEnterprise carries NONE on the cluster — its only
  # category (ConnectionEvents -> REDConnectionEvents) lives on the redisEnterprise/databases
  # child, so it is wired by the second setting below. Asking for allLogs on a resource type
  # with no categories is what we are avoiding here.
  dynamic "enabled_log" {
    for_each = local.use_legacy_redis ? [1] : []
    content {
      category_group = "allLogs"
    }
  }

  # Metrics are cluster-level on both offerings.
  enabled_metric {
    category = "AllMetrics"
  }
}

# Azure Managed Redis only: the connection audit log lives on the database child resource, not
# on the cluster. Separate setting because a diagnostic setting targets exactly one resource.
resource "azurerm_monitor_diagnostic_setting" "redis_database" {
  count = local.diag_redis && local.use_managed_redis ? 1 : 0

  name                       = "diag-${var.name_prefix}-redis-db"
  target_resource_id         = azurerm_managed_redis.this[0].default_database[0].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count = local.diag_key_vault ? 1 : 0

  name                       = "diag-${var.name_prefix}-kv"
  target_resource_id         = azurerm_key_vault.this[0].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "service_bus" {
  count = local.diag_service_bus ? 1 : 0

  name                       = "diag-${var.name_prefix}-servicebus"
  target_resource_id         = azurerm_servicebus_namespace.this[0].id
  log_analytics_workspace_id = module.logs.id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# --- Action group (optional notification target) ------------------------------------

resource "azurerm_monitor_action_group" "alerts" {
  count = local.diagnostics_enabled && var.alert_email != null ? 1 : 0

  name                = "ag-${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.aca.name
  short_name          = "msly-alert"

  email_receiver {
    name          = "ops"
    email_address = var.alert_email
  }

  tags = local.tags
}

# --- Metric alerts (minimal, the page-an-operator failure modes) --------------------

# Postgres storage nearly full — the classic "server goes read-only" outage.
resource "azurerm_monitor_metric_alert" "postgres_storage" {
  count = local.diag_postgres ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-storage"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "Provisioned Postgres storage is nearly full — grow storage before the server goes read-only."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# B-series CPU-credit exhaustion — a burstable server throttles to its baseline once credits
# run out. Only meaningful on a burstable SKU (production refuses burstable, so this fires
# only for demo/eval installs that opted into diagnostics).
resource "azurerm_monitor_metric_alert" "postgres_cpu_credits" {
  count = local.diag_postgres && local.postgres_burstable ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-cpu-credits"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "Burstable Postgres is nearly out of CPU credits and will throttle to baseline — consider a General Purpose SKU."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_credits_remaining"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 10
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Redis evictions — with the no-eviction policy in force (redis.tf: maxmemory_policy on the
# legacy cache, default_database.eviction_policy on Azure Managed Redis) this counter must stay
# at zero forever: Redis refuses writes rather than shedding keys. So any eviction at all now
# means the policy is no longer in force — changed in the portal, or reset by a restore. That
# is precisely the state in which a revocation marker can be dropped and a revoked session
# comes back, so this keeps its severity even though it should be unreachable. Real memory
# pressure is caught by the used-memory alert below, not here.
#
# The metric name survives the offering change; the namespace and the aggregation do not.
# Learn documents evictedkeys as a per-second RATE with Average aggregation on
# Microsoft.Cache/redisEnterprise (the auto-generated supported-metrics reference) but as
# Total (Sum) on the hand-written monitoring-data reference — the two pages disagree. The
# threshold here is "> 0", so both readings mean the same thing; the auto-generated one is
# taken because it is derived from the metric definitions the alert is validated against.
resource "azurerm_monitor_metric_alert" "redis_evictions" {
  count = local.diag_redis ? 1 : 0

  name                = "alert-${var.name_prefix}-redis-evictions"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [local.redis_resource_id]
  description         = "Redis is evicting keys — the no-eviction policy is no longer in force, and a dropped revocation marker resurrects a revoked session."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = local.use_managed_redis ? "Microsoft.Cache/redisEnterprise" : "Microsoft.Cache/redis"
    metric_name      = "evictedkeys"
    aggregation      = local.use_managed_redis ? "Average" : "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Redis memory — the pressure signal that replaces evictions. Under the no-eviction policy
# Redis does not shed keys to make room, it starts refusing writes with OOM, which takes logins
# and rate limiting down together. Fire well short of that so the operator can size up first —
# redis_capacity on the legacy cache, redis_sku_name_managed on Azure Managed Redis (where
# scaling UP is online but scaling DOWN is not supported at all). Maximum, not Average: the
# Azure metric usedmemorypercentage only supports Maximum on both namespaces, and an average
# would hide the spike that matters.
resource "azurerm_monitor_metric_alert" "redis_memory" {
  count = local.diag_redis ? 1 : 0

  name                = "alert-${var.name_prefix}-redis-memory"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [local.redis_resource_id]
  description         = "Redis memory is nearly full — under the no-eviction policy the next writes fail with OOM. Size the instance up."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = local.use_managed_redis ? "Microsoft.Cache/redisEnterprise" : "Microsoft.Cache/redis"
    metric_name      = "usedmemorypercentage"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Container Apps 5xx — the api and frontend are serving server errors. Split by app so the
# alert names the culprit.
resource "azurerm_monitor_metric_alert" "app_5xx" {
  for_each = local.diagnostics_enabled ? {
    api      = module.api.id
    frontend = module.frontend.id
  } : {}

  name                = "alert-${var.name_prefix}-${each.key}-5xx"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [each.value]
  description         = "The ${each.key} Container App is returning 5xx responses."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}
