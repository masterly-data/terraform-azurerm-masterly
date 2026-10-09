# Diagnostics + alerts (production-hardening): wire the data-plane resources' resource logs
# and metrics to the install's existing Log Analytics workspace (module.logs), and stand up a
# minimal alert set for the failure modes that page an operator — saturation ("this install is
# under strain") and availability ("this install is not serving"), which are different questions
# and are answered by different alerts. Lightweight and on-by-default in production;
# opt-in-able elsewhere.
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

variable "enable_app_availability_diagnostics" {
  type        = bool
  default     = null
  description = "Send the platform metrics of ca-api, ca-frontend and ca-workers (AllMetrics) to the install's Log Analytics workspace, and alert when an app stops sending them: one log search rule per app, <app>-silent, which fires on an app that has been deleted, stopped or torn down — the case the <app>-unavailable metric alerts cannot see, because a metric alert with no data does not fire. The metrics are continuous ingest into your workspace, and each rule is billed per evaluation, so this adds a standing cost to your Azure bill. Null (default) = on in mode=production, off otherwise. Set false to turn both off. Set true to turn them on outside production; true needs diagnostics on (enable_diagnostics, which defaults to on in mode=production). The rule is created only for an app with a replica floor of at least 1."

  validation {
    condition     = var.enable_app_availability_diagnostics != true || coalesce(var.enable_diagnostics, var.mode == "production")
    error_message = "enable_app_availability_diagnostics = true needs diagnostics on: the metrics go to the same workspace and the alert uses the same notification target. Set enable_diagnostics = true as well (it defaults to on only in mode = \"production\"), or leave enable_app_availability_diagnostics unset."
  }
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

# --- Load alert thresholds ----------------------------------------------------------
# Starting values, not measurements. Each default is a conservative first guess at the point
# where an install stops having headroom; the right number for your install comes from its
# own baseline under representative load. Tune these from what you observe rather than
# accepting an alert that pages on your normal Tuesday.

variable "alert_postgres_cpu_percent" {
  type        = number
  default     = 80
  description = "Load alert: fire when the provisioned Postgres server's average CPU stays above this percentage for 15 minutes. Tune from your install's baseline."

  validation {
    condition     = var.alert_postgres_cpu_percent > 0 && var.alert_postgres_cpu_percent < 100
    error_message = "alert_postgres_cpu_percent must be between 0 and 100 (exclusive)."
  }
}

variable "alert_postgres_connections_percent" {
  type        = number
  default     = 70
  description = "Load alert: fire when the provisioned Postgres server's active connections average above this percentage of its max_connections over 15 minutes. Tune from your install's baseline."

  validation {
    condition     = var.alert_postgres_connections_percent > 0 && var.alert_postgres_connections_percent < 100
    error_message = "alert_postgres_connections_percent must be between 0 and 100 (exclusive)."
  }
}

variable "alert_postgres_max_connections" {
  type        = number
  default     = null
  description = "The max_connections the connections alert takes its percentage of. Null (default) = Azure's documented default for postgres_sku_name. Set it when you have changed the server's max_connections parameter, or when your SKU is not one the module recognises (a plan then warns that no connections alert was created)."

  validation {
    condition     = var.alert_postgres_max_connections == null || try(var.alert_postgres_max_connections >= 1 && floor(var.alert_postgres_max_connections) == var.alert_postgres_max_connections, false)
    error_message = "alert_postgres_max_connections must be a whole number of at least 1, or null."
  }
}

variable "alert_postgres_iops_percent" {
  type        = number
  default     = 80
  description = "Load alert: fire when the provisioned Postgres server consumes, on average over 15 minutes, more than this percentage of the IOPS its storage tier provides. Tune from your install's baseline."

  validation {
    condition     = var.alert_postgres_iops_percent > 0 && var.alert_postgres_iops_percent < 100
    error_message = "alert_postgres_iops_percent must be between 0 and 100 (exclusive)."
  }
}

variable "alert_servicebus_dead_letter_threshold" {
  type        = number
  default     = 0
  description = "Load alert (enable_service_bus only): fire when the job queue's dead-letter sub-queue holds more than this many messages. 0 (default) = any dead-lettered message."

  validation {
    condition     = var.alert_servicebus_dead_letter_threshold >= 0
    error_message = "alert_servicebus_dead_letter_threshold must be 0 or more."
  }
}

variable "alert_api_p95_ms" {
  type        = number
  default     = 2000
  description = "Load alert: fire when the 95th percentile of the api's own request durations over 15 minutes exceeds this many milliseconds. The default is a placeholder, not a latency promise — set it from a load test of your install."

  validation {
    condition     = var.alert_api_p95_ms > 0
    error_message = "alert_api_p95_ms must be greater than 0."
  }
}

variable "alert_workers_memory_percent" {
  type        = number
  default     = 85
  description = "Load alert (enable_workers only): fire when a ca-workers replica's memory working set rises above this percentage of the replica's memory. Tune from your install's baseline."

  validation {
    condition     = var.alert_workers_memory_percent > 0 && var.alert_workers_memory_percent < 100
    error_message = "alert_workers_memory_percent must be between 0 and 100 (exclusive)."
  }
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

  # App availability diagnostics (ADR 0080, amendment of 2026-10-07): the apps' platform
  # metrics in the workspace, and the absence rule that reads them. On by default in production
  # only, because the metrics are continuous ingest the customer pays for; the input turns both
  # off, or on outside production. It is part of the diagnostics surface and never outlives it —
  # the variable's validation refuses true with diagnostics off rather than ignoring it.
  app_availability_diagnostics_enabled = local.diagnostics_enabled && coalesce(var.enable_app_availability_diagnostics, var.mode == "production")

  # Every Container App the install runs gets the diagnostic setting. Static keys, so the map's
  # shape is known at plan even though the ids are not.
  app_metrics_apps = local.app_availability_diagnostics_enabled ? merge(
    { api = module.api.id, frontend = module.frontend.id },
    var.enable_workers ? { workers = module.workers[0].id } : {},
  ) : {}

  # The absence rule only for an app with a replica floor, for the reason app_unavailable is
  # gated the same way: an app scaled to zero publishes nothing while it sits at zero, which is
  # its intended state, and a rule that read that silence as an outage would page every idle
  # night.
  app_silent_apps = {
    for app, id in local.app_metrics_apps : app => id
    if lookup({ api = var.api_min_replicas, frontend = var.frontend_min_replicas, workers = var.workers_min_replicas }, app) >= 1
  }

  # Which apps get a replica-availability alert. See the alert itself for why an app that is
  # allowed to sit at zero replicas is deliberately left out rather than alerted on.
  availability_alertable_apps = local.diagnostics_enabled ? merge(
    var.api_min_replicas >= 1 ? { api = module.api.id } : {},
    var.frontend_min_replicas >= 1 ? { frontend = module.frontend.id } : {},
    var.enable_workers && var.workers_min_replicas >= 1 ? { workers = module.workers[0].id } : {},
  ) : {}

  # Which apps emit the readiness signal the wedged-replica alert reads. Both serving apps do
  # and only they: ca-workers has no ingress, no /readyz and no probes (workers.tf), so there is
  # no failing probe for it to write a line about. Named from the module outputs rather than
  # retyped, so a rename of either app cannot leave the query filtering on a name that no longer
  # exists — the failure mode where an alert stays green because it matches nothing.
  readiness_alertable_apps = local.diagnostics_enabled ? [module.api.name, module.frontend.name] : []

  # What a missing replica MEANS, per app. The severity is the same for all three — this
  # module's severity band marks ABSENCE, not "HTTP is down" — but the sentence an operator
  # reads at 03:00 should not claim the install is unreachable when what actually stopped is
  # the pipeline behind it. The api and the frontend take the install off the air; ca-workers
  # leaves it answering every request while no job in it makes progress.
  app_unavailable_effect = {
    api      = "this install is DOWN, not merely under strain"
    frontend = "this install is DOWN, not merely under strain"
    workers  = "the async pipeline has STOPPED — ingest runs, scans, materialization and the fleet snapshot loop make no progress, while the install keeps answering requests as if nothing were wrong"
  }

  # --- The connections alert's denominator ---
  #
  # Azure Monitor publishes active_connections as a count, not as a share of the limit, and the
  # limit is a server parameter whose default Azure derives from the SKU's memory. So the
  # module derives it the same way, from Learn's "Limits in Azure Database for PostgreSQL
  # flexible server" table: memory in GiB -> default max_connections. The table stops rising at
  # 5000 from 48 GiB up.
  #
  # Memory is read off the SKU name, and only for the families whose rule is regular: General
  # Purpose D-series carry 4 GiB per vCore, Memory Optimized E-series 8 GiB per vCore, and the
  # burstable B-series is irregular, so it is listed. Any other SKU yields null, and then no
  # connections alert is created and the check below says so on every plan, rather than an alert
  # quietly measuring against a guessed limit. alert_postgres_max_connections overrides all of
  # this, and is also the input to set when the server's max_connections has been changed.
  postgres_sku_memory_gib_burstable = {
    B1ms = 2, B2s = 4, B2ms = 8, B4ms = 16, B8ms = 32, B12ms = 48, B16ms = 64, B20ms = 80
  }
  postgres_sku_memory_gib = (
    can(regex("^B_Standard_(B[0-9]+m?s)$", var.postgres_sku_name))
    ? lookup(local.postgres_sku_memory_gib_burstable, regex("^B_Standard_(B[0-9]+m?s)$", var.postgres_sku_name)[0], null)
    : can(regex("^GP_Standard_D([0-9]+)", var.postgres_sku_name))
    ? 4 * tonumber(regex("^GP_Standard_D([0-9]+)", var.postgres_sku_name)[0])
    : can(regex("^MO_Standard_E([0-9]+)", var.postgres_sku_name))
    ? 8 * tonumber(regex("^MO_Standard_E([0-9]+)", var.postgres_sku_name)[0])
    : null
  )
  postgres_default_max_connections = (
    local.postgres_sku_memory_gib == null ? null
    : local.postgres_sku_memory_gib >= 48 ? 5000
    : lookup({ 2 = 50, 4 = 429, 8 = 859, 16 = 1718, 32 = 3437 }, tostring(local.postgres_sku_memory_gib), null)
  )
  postgres_max_connections  = coalesce(var.alert_postgres_max_connections, local.postgres_default_max_connections, -1)
  diag_postgres_connections = local.diag_postgres && local.postgres_max_connections > 0

  # --- The workers memory alert's threshold ---
  #
  # A share of the replica's own memory, read from the app's configured size (always stated in
  # Gi — the submodule refuses anything else), so a change to the workers' size moves the
  # threshold with it instead of leaving a byte count behind.
  workers_memory_bytes = var.enable_workers ? tonumber(trimsuffix(module.workers[0].memory, "Gi")) * 1073741824 : null
  diag_workers_memory  = local.diagnostics_enabled && var.enable_workers

  # The api access-log line the latency rule parses. Every request the api completes writes
  # "<METHOD> <route template> -> <status> in <milliseconds>ms" — in production as the
  # `message` field of a JSON line, in demo as plain text — so one pattern reads both.
  api_access_line_pattern = "[A-Z]+ ([^ ]+) -> [0-9]{3} in ([0-9.]+)ms"

  # Below this many requests in the latency rule's 15-minute window, a 95th percentile is two
  # or three requests and says nothing about load, so the rule does not evaluate it.
  api_latency_min_requests = 50
}

# Said on every plan, not buried in a README: a provisioned server whose SKU the module cannot
# size gets no connections alert until the operator states the limit.
check "postgres_connections_alert_has_a_limit" {
  assert {
    condition     = !local.diag_postgres || local.postgres_max_connections > 0
    error_message = "No Postgres connections alert was created: the module does not know the default max_connections of postgres_sku_name \"${var.postgres_sku_name}\". Set alert_postgres_max_connections to the server's max_connections to create it."
  }
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

# The Container Apps' platform metrics (ADR 0080, amendment of 2026-10-07). This setting is what
# puts an app's metrics in AzureMetrics in the workspace, which the app_silent rules below read;
# without it the apps' metrics exist only in Azure Monitor's metric store, where a metric alert
# can read them and nothing can notice their absence.
#
# Metrics only. The apps' console and system logs already reach this workspace through the
# Container Apps environment, which modules/aca-env-consumption points at it, so a log category
# here would at best be a second copy the customer pays for twice.
resource "azurerm_monitor_diagnostic_setting" "app" {
  for_each = local.app_metrics_apps

  name                       = "diag-${var.name_prefix}-${each.key}"
  target_resource_id         = each.value
  log_analytics_workspace_id = module.logs.id

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

# --- Load alerts (headroom running out, before it becomes an outage) ---------------
#
# The alerts above notice a full disk, a full cache and a failing app. None of them notices an
# install working harder than it can sustain, so without these the first sign of load is the
# outage it causes. Each one below answers "how much headroom is left" for one resource, at a
# threshold that is a module input: the defaults are starting values, and the right ones come
# from the install's own baseline under representative load.
#
# Severity 2, the bottom of this module's saturation band: each is a warning with time to act,
# not an incident. The one exception, dead-lettered job messages, is severity 1 and says why.
#
# None of these needs a diagnostic setting on the Container Apps. The metric alerts read Azure
# Monitor platform metrics, which every Container App, Postgres server and Service Bus
# namespace publishes without one; the latency rule reads ContainerAppConsoleLogs_CL, which the
# Container Apps environment sends to the install's workspace itself (modules/aca-env-consumption
# sets logs_destination unconditionally).
#
# Each metric name is taken from Learn's supported-metrics reference for its resource type.
# Azure validates the metric against the resource when the alert is created
# (skip_metric_validation stays at its default, false), so a wrong name fails the apply loudly
# rather than creating an alert that never fires.

# Postgres CPU. Average over fifteen minutes: a query burst that pegs the CPU for a minute is
# normal work, a quarter-hour above the line means the SKU no longer has headroom for the
# install's load. On a burstable SKU this measures the share of the burstable vCPU and sits
# beside the CPU-credits alert, which is the one that says the server is about to be throttled.
resource "azurerm_monitor_metric_alert" "postgres_cpu" {
  count = local.diag_postgres ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-cpu"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "Postgres CPU has averaged above ${var.alert_postgres_cpu_percent}% for 15 minutes — the server is running out of headroom. Find what is driving it (ingest, matching, consumption) and size postgres_sku_name up if it is sustained."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alert_postgres_cpu_percent
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Postgres connections, as a share of max_connections. The server refuses the connection past
# the limit, and every Masterly Environment holds its own pool, so the count grows with
# Environments and replicas as well as with load. The threshold is a count computed from the
# percentage and the limit (see postgres_max_connections in the locals), because Azure publishes
# active_connections as a count and no percentage of it.
resource "azurerm_monitor_metric_alert" "postgres_connections" {
  count = local.diag_postgres_connections ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-connections"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "Postgres active connections have averaged above ${var.alert_postgres_connections_percent}% of max_connections (${local.postgres_max_connections}) for 15 minutes — new connections will be refused once the limit is reached. Check replica counts and Environment count, then size the server up or raise max_connections."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = floor(local.postgres_max_connections * var.alert_postgres_connections_percent / 100)
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Postgres IOPS, as a share of what the storage tier provides. Azure publishes this share
# directly (disk_iops_consumed_percentage), so the alert does not need to know the tier's
# limit — which matters, because that limit moves with postgres_storage_mb and with any
# performance tier set on the server outside Terraform. At 100% the disk queues and every
# query slows at once.
resource "azurerm_monitor_metric_alert" "postgres_iops" {
  count = local.diag_postgres ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-iops"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "Postgres has consumed more than ${var.alert_postgres_iops_percent}% of its storage IOPS on average for 15 minutes — the disk is near its limit and queries will queue behind it. Raise the storage size or performance tier."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "disk_iops_consumed_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alert_postgres_iops_percent
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# Dead-lettered job messages. On the servicebus binding each message tells a worker that an
# Environment has queued work. A message that fails delivery max_delivery_count times (10,
# main.tf) is moved to the queue's dead-letter sub-queue instead of being dropped, and it is no
# longer delivered. The jobs themselves stay in the Environment's own database, but the signal
# that should have woken a worker for them is gone, so repeated dead-lettering is how work can
# wait with nothing reporting it. Severity 1 for that reason: this is not headroom running out,
# it is work that may already be stuck.
#
# DeadletteredMessages is a gauge — the number of messages sitting in the dead-letter
# sub-queue — so the alert stays active until the dead-lettered messages are dealt with, and it
# clears when they are. That is deliberate: the action it asks for is to look at them. Maximum,
# so a single message is seen whenever it arrives inside the window. Scoped to the job queue by
# its EntityName dimension, so a queue added to the namespace later is not swept in.
resource "azurerm_monitor_metric_alert" "servicebus_dead_letters" {
  count = local.diag_service_bus ? 1 : 0

  name                = "alert-${var.name_prefix}-servicebus-dead-letters"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [azurerm_servicebus_namespace.this[0].id]
  description         = "The ${azurerm_servicebus_queue.jobs[0].name} queue holds more than ${var.alert_servicebus_dead_letter_threshold} dead-lettered message(s) — workers repeatedly failed to process a job notification and gave up on it. Read the dead-letter reason, check the workers' logs, and resubmit or remove the messages."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = var.alert_servicebus_dead_letter_threshold

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = [azurerm_servicebus_queue.jobs[0].name]
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

# ca-workers memory. A job handler's working set grows with the size of what it processes, and
# a replica that reaches its memory limit is killed mid-job; the job is retried, meets the same
# data, and is killed again. Maximum rather than Average, because the question is whether any
# replica came near its limit, and an average across replicas or across the window hides the
# one that did. The threshold is a share of the replica's configured memory, in bytes, because
# WorkingSetBytes is published in bytes.
resource "azurerm_monitor_metric_alert" "workers_memory" {
  count = local.diag_workers_memory ? 1 : 0

  name                = "alert-${var.name_prefix}-workers-memory"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [module.workers[0].id]
  description         = "A ca-workers replica's memory working set has risen above ${var.alert_workers_memory_percent}% of its ${module.workers[0].memory} — close to the point where the replica is killed mid-job. Find the job kind that drives it; give the workers more memory or split the work."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "WorkingSetBytes"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = floor(local.workers_memory_bytes * var.alert_workers_memory_percent / 100)
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# api latency, as the 95th percentile of the api's own request durations. Azure Monitor has no
# percentile for Container Apps requests — its response-time metric is an average, and an
# average hides exactly the slow tail this alert is for — so the rule reads the api's access
# log instead. Every request the api completes writes one line,
# "<METHOD> <route template> -> <status> in <milliseconds>ms", and the rule parses the route and
# the duration out of it. That line is written by every released api image this module version
# documents, which is what makes it safe to depend on.
#
# What it measures: time inside the api process, from the first byte of the request to the last
# byte of the response. It does not include the network, the ingress, or time a request waited
# for a replica, so a client sees at least this much.
#
# What it leaves out, on purpose: routes that stream a response for as long as the client reads
# it — the bulk exports (every `:export` route), the assistant's streaming chat, and the MCP
# channel. Their duration is the size of the answer, not the speed of the api, and a handful of
# them would own the percentile on a quiet install.
#
# It needs a minimum of traffic to say anything. Below api_latency_min_requests requests in the
# window a 95th percentile is two or three requests, so the rule stays quiet; this is an alert
# on load, and an install without load has none to report.
#
# The empty `datatable` anchor is the one app_not_ready carries, for the same reason:
# ContainerAppConsoleLogs_CL does not exist until the first console line lands, and a fuzzy
# union whose only operand is missing still fails.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "api_latency" {
  count = local.diagnostics_enabled ? 1 : 0

  name                = "alert-${var.name_prefix}-api-latency"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  scopes              = [module.logs.id]

  description = "The api's 95th-percentile request duration has exceeded ${var.alert_api_p95_ms} ms over 15 minutes — requests are slowing under load. Check the Postgres load alerts first, then which routes are slow in ContainerAppConsoleLogs_CL."
  severity    = 2

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      union isfuzzy=true
        (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),
        (
          ContainerAppConsoleLogs_CL
          | where ContainerAppName_s == "${module.api.name}"
          | where Log_s contains " -> "
        )
      | extend Route = extract(@"${local.api_access_line_pattern}", 1, Log_s), DurationMs = todouble(extract(@"${local.api_access_line_pattern}", 2, Log_s))
      | where isnotempty(Route) and isnotnull(DurationMs)
      | where Route !contains ":export" and Route !endswith "/ai/chat" and Route !startswith "/mcp"
      | summarize Requests = count(), P95Ms = percentile(DurationMs, 95)
      | where Requests >= ${local.api_latency_min_requests} and P95Ms > ${var.alert_api_p95_ms}
    KQL

    # One row when the percentile is over the line and there was enough traffic to compute it,
    # none otherwise. The provider checks none of these three against the query; they are
    # pinned in tests/install.tftest.hcl.
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  dynamic "action" {
    for_each = length(local.alert_action_group_ids) > 0 ? [1] : []
    content {
      action_groups = local.alert_action_group_ids
    }
  }

  skip_query_validation = false

  tags = local.tags
}

# --- Availability alerts (the install is not serving, as distinct from strained) -----

# Every alert above is a SATURATION signal, and each one needs the resource running and
# publishing before it can say anything. A stopped Postgres server emits no storage_percent. A
# Container App that hangs rather than answering emits no 5xx. An install with
# api_min_replicas = 0 and nothing reaching it emits no Requests on any dimension at all. That
# is not a hypothetical combination: it is the state the demo install was in when it served
# nothing for hours with every alert green, and a human found it by opening the page (MAS-90).
# The alerts below answer the question the others structurally cannot — is this install up? —
# and they carry severity 0, one step above every saturation alert here, so an operator can tell
# "down" from "strained" from the notification alone.
#
# Two Azure facts bound what is expressible, both checked rather than assumed:
#
#  1. A metric alert does not fire on missing data, and nothing configures that away. There is no
#     such argument on azurerm_monitor_metric_alert — read off the provider's own schema
#     (`terraform providers schema -json` on azurerm 4.x: auto_mitigate, enabled, frequency,
#     severity, window_size, criteria, dynamic_criteria, action, and nothing about no-data).
#     Learn's alert-type guidance agrees by omission and points absence detection at a
#     Count-aggregation metric alert instead ("Metric alerts are recommended when you need to
#     detect the absence of a heartbeat").
#
#  2. That Count trick is not available on the two metrics that matter here. Learn's
#     supported-metrics reference lists is_db_alive as Average/Maximum/Minimum and Replicas as
#     Average/Total/Maximum/Minimum; neither lists Count. This file already reads that column as
#     the supported set rather than a default — see the usedmemorypercentage comment above — and
#     betting a customer-facing alert on the other reading is not worth it when a log search
#     alert expresses the same thing unambiguously.
#
# So the split below is deliberate: metric alerts carry the two "the platform says it is down"
# signals, and one log search alert carries "it has stopped saying anything at all", where an
# empty result is the firing condition rather than a quiet one.

# Postgres availability — the platform's own answer rather than an inference from load.
# is_db_alive sits in the flexible server's "Availability" metric category: 1 when the database
# is up, 0 when it is not, emitted every minute. Learn's monitoring page for the offering is
# explicit that MAX() is how you ask "was the server up in the last minute", so Maximum it is —
# an Average would let a mostly-up server average a hard minute away, and Minimum would fire on
# every failover blip.
#
# Short window on purpose. Unlike the saturation alerts there is nothing to trend: five minutes
# of a database answering 0 is an outage and the operator wants it now, not after a quarter hour
# of confirmation.
resource "azurerm_monitor_metric_alert" "postgres_unavailable" {
  count = local.diag_postgres ? 1 : 0

  name                = "alert-${var.name_prefix}-postgres-unavailable"
  resource_group_name = azurerm_resource_group.data.name
  scopes              = [azurerm_postgresql_flexible_server.this[0].id]
  description         = "The install's database reports itself unavailable — this install is DOWN, not merely under strain."
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "is_db_alive"
    aggregation      = "Maximum"
    operator         = "LessThan"
    threshold        = 1
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# App availability, for every Container App this install runs — ca-api, ca-frontend, and
# ca-workers. The apps have no availability metric of their own, and no platform health
# event either: Microsoft.App/containerApps is absent from the resource types Azure Resource
# Health covers (checked against Learn's resource-health resource-type reference, which does
# list Microsoft.Cache/Redis and Microsoft.DBforPostgreSQL/flexibleservers). Replica count is
# what is left, and it says the thing that matters — the revision holds 100% of traffic and
# there is nothing up to serve it.
#
# Maximum, not Minimum or Average: the question is whether a single replica was running at any
# point in the window, and a Minimum would fire on every ordinary revision roll.
#
# Created only for an app whose install declares a floor of at least one replica. Where
# min_replicas is 0, zero replicas is the INTENDED state — that is the scale-to-zero cost
# posture the variable exists for — and an alert that pages every idle night is one an operator
# learns to ignore, which leaves them worse off than not shipping it. mode=production requires
# api_min_replicas >= 1 and frontend_min_replicas >= 1 (validations on those variables), so on
# every install where diagnostics is on by default those two alerts exist.
#
# ca-workers is here for the reason the serving apps are, and it is the sharpest case of it
# (MAS-305). It does not serve, so no request-path alert can ever notice it is gone: the 5xx
# alert reads the api and the frontend, both of which keep answering perfectly while the queue
# behind them grows. A dead workers app is therefore SILENT by construction, and the first
# signal without this alert is somebody asking why yesterday's ingest never landed.
#
# Three other candidate signals were considered and are not what shipped:
#
#  * RestartCount. Learn's supported-metrics reference does carry it for
#    Microsoft.App/containerapps, and a crashlooping workers app is a real failure shape. But
#    the same reference defines it as "the CUMULATIVE number of times the replica has restarted
#    since it was created", so a threshold over it latches: once a long-lived replica has
#    restarted N times it stays above N until the replica is replaced, and the alert never
#    clears. An alert that cannot clear is muted within a week. Rate-of-change over a cumulative
#    counter is expressible, but not without a threshold nobody here can calibrate against a
#    real install.
#
#  * Absence of the workers app's own log lines, the ContainerAppConsoleLogs_CL analogue of the
#    postgres_silent rule below. Checked against the code rather than assumed, and it does not
#    hold: masterly_app.workers logs once at startup ("workers ready: … starting … consume
#    loop") and then only per job (core/jobqueue.py). It emits NO periodic heartbeat, so on a
#    correctly-running install with an empty queue the workers app is legitimately silent for
#    hours. Silence there means "no work", not "no worker", and a rule that cannot tell those
#    apart pages every quiet night.
#
#  * Job-completion staleness — queue depth, oldest-unclaimed age. That is the signal an
#    operator actually wants, and it lives in the install's own Postgres job tables, which this
#    module provisions but never reads. Expressing it here would mean the module querying
#    application data, which it does not do and should not start doing. The Service Bus
#    alternative (ActiveMessages climbing) is a saturation threshold in absence's clothing: it
#    needs a per-install baseline, and it is exactly the kind of alert MAS-263 set out to stop
#    adding. Staleness as a LOAD signal is a different question from absence and is not
#    answered here either: the released api image writes no log line carrying the age of the
#    oldest queued job, so there is nothing in the workspace for a rule to read. The api does
#    report it on request (`GET /v1/ops/metrics`, `jobs.oldest_queued_age_seconds`), and the
#    README says how to use that until the application writes the line.
#
# So the shipped signal is the same one the serving apps carry, and it detects the same class
# of failure: the app is not there. The floor gate is workers_min_replicas >= 1, which is its
# default and which the variable's own description tells the caller to keep — nothing HTTP-wakes
# an ingress-less polling loop, so a workers app at zero replicas is a stalled pipeline whoever
# configured it chose, not a fault this alert should page about.
#
# What this alert cannot see at all: an app that is GONE. A deleted app, or one whose
# environment was torn down, publishes no `Replicas` value, and a metric alert with no data does
# not fire, so this alert goes quiet at exactly the moment the app goes away. app_silent, at the
# end of this file, covers that case from the workspace when app availability diagnostics are on
# (enable_app_availability_diagnostics, on by default in production).
#
# What this alert cannot see on its own, and what now does. A replica that starts, never passes
# its readiness probe, and is never routed to still counts toward `Replicas`. On an install with
# a replica floor — which is every production install, and the only kind this alert is created
# on — a wedged app therefore reads 1 and this stays green while the install serves nothing.
# app_5xx does not cover it either: that alert needs more than five requests in its window, and
# an install nobody can reach receives none. That is the shape of MAS-90, the one outage on
# record here: the install served nothing for hours, every platform signal read normal, and a
# human found it by opening the page.
#
# That gap used to be disclosed in the README rather than closed, because the signal did not
# exist. It does now, and app_not_ready below reads it. What changed, and what did not:
#
#  * The app's own words — available in this module's apps since 2026-09, and not before.
#    Masterly's own control plane (masterly-platform-iac) has alerted on the string
#    `readiness check failed` since its backends' /readyz began writing it. The api
#    this module runs is a different codebase, and its /readyz used to answer 503 with no log
#    record at all while the request log excluded the probe paths by name — so that string was
#    unfireable here, and porting the rule would have claimed coverage that did not exist. Both
#    serving apps now write one WARNING line per FAILING probe, carrying that same
#    `readiness check failed: ` prefix deliberately, so that one rule shape covers every app in
#    both layers. A passing probe still writes nothing, which is what keeps a 10-second probe
#    interval from billing the customer for a log line every ten seconds.
#
#  * The platform's own words — still rejected, and the measurement that rejected them stands.
#    ContainerAppSystemLogs_CL does carry the failure (`Reason_s == "ProbeFailed"`, e.g.
#    "Container ca-api failed readiness probe") and it is populated in every install, because
#    modules/aca-env-consumption sets logs_destination to module.logs unconditionally. It caught
#    exactly this shape on Masterly's own reference install on 2026-09-07. But replaying a
#    sustained-window rule over 30 days of that workspace fires on roughly a dozen occasions per
#    app, most of them ordinary deploy churn, and separating a wedged app from a rolling one
#    there needs a rate threshold tied to the probe interval. The app-emitted line is the better
#    source precisely because it is the application's own conclusion rather than the platform's
#    retry count.
#
# What is still not covered — an app with no readiness probe at all (ca-workers), and a wedge
# that clears inside the rule's window — is disclosed in the README rather than implied.
resource "azurerm_monitor_metric_alert" "app_unavailable" {
  for_each = local.availability_alertable_apps

  name                = "alert-${var.name_prefix}-${each.key}-unavailable"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [each.value]
  description         = "The ${each.key} Container App has no running replica — ${local.app_unavailable_effect[each.key]}."
  severity            = 0
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.App/containerapps"
    metric_name      = "Replicas"
    aggregation      = "Maximum"
    operator         = "LessThan"
    threshold        = 1
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.tags
}

# The wedged-replica alert: the install is present, counted, and not serving. It is the other
# half of the alert above — that one asks whether the app is THERE, this one asks whether it is
# READY — and it is a log search alert for the same reason postgres_silent is: the state it
# looks for produces no metric anywhere. An unready replica is deliberately not routed to, so it
# emits no requests and no 5xx, while the platform keeps counting it as a replica.
#
# ONE query, three apps, two layers — which is the whole point of the string it keys on. Both
# apps this module runs write `readiness check failed: <cause>` at WARNING on a failing probe,
# and so do the apps in Masterly's own control plane, whose rule this one is ported from. The
# filter is the shared prefix rather than any per-app wording, so a rule written once
# covers every app that adopts the line. The app is named by the `ContainerAppName_s` dimension
# rather than by a rule per app, so two failing apps arrive as two incidents, not one.
#
# Reading the LINE, not the probe. What the query counts is distinct MINUTES in which a failing
# probe was logged, not lines: `dcount(bin(TimeGenerated, 1m))`. That is what keeps the rule
# free of the probe-rate dependency that disqualified the ContainerAppSystemLogs_CL alternative
# above. The module fixes both apps' readiness interval at 10 seconds (main.tf), so a failing
# minute carries about six lines — but the rule would read the same at 30 or 60 seconds, and it
# degrades gracefully rather than silently if that ever changes: a longer interval makes the
# rule slower to fire, never blind to a wedge. tests/install.tftest.hcl pins the interval at or
# below 60 seconds so the premise stays a checked one rather than a remembered one.
#
# Thirty of the last sixty minutes, and the threshold is set by what a healthy install does, not
# by taste. A cold start legitimately fails readiness for a while: main.tf budgets 5 + 48 x 10 =
# 485 seconds of continuous failure per replica attempt before ACA pulls it, sized past a
# customer's first image pull onto a cold node, and the frontend's probe waits on the api's. So
# an install coming up writes this line for minutes at a time while nothing is wrong. Requiring
# it in half of a rolling hour puts a first apply comfortably under the bar while a genuine
# wedge — which does not clear on its own — sails past it in the first hour. The sustained-ness
# lives in the query rather than in `failing_periods` because the two would compound: one
# failing evaluation of THIS query already means half an hour of unreadiness.
#
# Detection is therefore ~30-40 minutes, slower than every metric alert here and deliberately
# so. The comparison that matters is not against the metric alerts, which cannot see this state
# at all, but against MAS-90's actual detection time, which was hours and required a human to
# open the page.
#
# Severity 0, unlike the control-plane rule this is ported from, and the divergence is
# deliberate. There, severity separates certainty: "certainly down" from "possibly degraded".
# Here it separates the QUESTION — every saturation alert in this module is severity 1-2 and every
# availability alert is 0, and the README sells that band to operators as the thing that tells
# them which of the two states they are in without opening the portal. An app that has failed
# readiness for half an hour is an availability incident on any reading, so it takes the
# availability severity; what it does NOT claim is which replicas, and the description says so.
#
# Not gated on min_replicas, unlike app_unavailable. That gate exists because zero replicas is
# the INTENDED state on a scale-to-zero install, so alerting on it would page every idle night.
# Unreadiness is never an intended state: an app that is scaled to zero runs no probe and writes
# no line, so this rule is simply silent there rather than noisy.
#
# ca-workers is absent for a reason that is not an oversight: it has no ingress, no /readyz and
# no probes at all (workers.tf), so it emits nothing this rule could read. What covers it is the
# replica alert above, and what does not cover it — a workers replica that is up but whose
# consume loop is stuck — is disclosed in the README.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_not_ready" {
  count = local.diagnostics_enabled ? 1 : 0

  name = "alert-${var.name_prefix}-app-not-ready"

  # Filed with the workspace it queries rather than with the apps it is about, for the reason
  # postgres_silent is: a rule that sits with its scope is the one an operator can find from
  # either end. module.logs lives in the ACA resource group.
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  scopes              = [module.logs.id]

  description = "A serving app has failed its readiness probe for at least half of the last hour — it is running and counted as a replica, but never routed to, so this install is NOT serving even though the replica alerts read healthy."
  severity    = 0

  evaluation_frequency = "PT10M"
  window_duration      = "PT1H"

  # Resolve itself once readiness comes back. Without this the rule fires once and stays fired,
  # and every later wedge is swallowed as a duplicate of an incident nobody closed — the failure
  # mode where a control looks green precisely because it already fired.
  auto_mitigation_enabled = true

  criteria {
    # The empty `datatable` anchor is load-bearing, and `isfuzzy` alone would not do its job.
    # ContainerAppConsoleLogs_CL is a CUSTOM table that does not exist in a workspace until the
    # first console line lands, and a query against a missing table FAILS rather than returning
    # nothing — which would fail this rule's creation on a fresh install, or leave it unhealthy
    # and, after a week of failures, disabled by Azure. `union isfuzzy=true` is the usual answer
    # and it is NOT sufficient on its own: a fuzzy union whose only operand is missing still dies
    # with SEM0104 ("Operator source expression should be table or column"), measured against a
    # live workspace on 2026-09-09. Anchoring the union with an empty literal of the right shape
    # gives it a schema that always resolves, so a missing table degrades to a partial-result
    # warning and an empty answer instead. With the table present both operands resolve and the
    # anchor contributes nothing.
    #
    # `contains` rather than `startswith`: the api writes the line through a JSON log handler, so
    # the prefix sits inside an envelope in Log_s, while the frontend writes it bare. One
    # operator reads both.
    query = <<-KQL
      union isfuzzy=true
        (datatable(TimeGenerated:datetime, ContainerAppName_s:string, Log_s:string)[]),
        (
          ContainerAppConsoleLogs_CL
          | where ContainerAppName_s in (${join(", ", [for name in local.readiness_alertable_apps : "\"${name}\""])})
          | where Log_s contains "readiness check failed"
        )
      | summarize FailingMinutes = dcount(bin(TimeGenerated, 1m)) by ContainerAppName_s
      | where FailingMinutes >= 30
    KQL

    # Count of RESULT ROWS, above zero: one row per app that cleared the half-hour bar, and no
    # rows at all on a healthy install, because `summarize ... by` over an empty input returns
    # none. These three fields are not validated against each other or against the query by the
    # provider — LessThan here would invert the rule into one that fires whenever every app is
    # healthy, and it would plan and apply exactly as cleanly. Change them together or not at
    # all; tests/install.tftest.hcl pins them.
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    # One failing evaluation is enough BECAUSE the query already demands thirty failing minutes.
    # Stacking consecutive periods on top of that would push detection past an hour to re-prove
    # something the query has proven.
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }

    # No `resource_id_column`. ACA writes console logs to the workspace through the custom-table
    # path, where `_ResourceId` is present in the schema but empty on every row — pointing the
    # rule at it would file the alert against nothing. The dimension identifies the app instead.
    dimension {
      name     = "ContainerAppName_s"
      operator = "Include"
      values   = ["*"]
    }
  }

  dynamic "action" {
    for_each = length(local.alert_action_group_ids) > 0 ? [1] : []
    content {
      action_groups = local.alert_action_group_ids
    }
  }

  # Let Azure validate the KQL when the rule is created. Nothing before apply can: `terraform
  # validate` does not parse KQL, and the provider does not either — a query with a typo in it
  # plans and applies clean, then never fires, which is indistinguishable from a healthy install.
  # This is the only gate that reads the query as a query, so it stays on.
  skip_query_validation = false

  tags = local.tags
}

# The absence signal, and the reason this section is not three metric alerts. Everything above
# still needs the resource to be publishing, and a STOPPED server — MAS-90's actual first
# cause — publishes no is_db_alive at all. A metric alert with no data does not fire (fact 1
# above), so on its own the alert set would go quiet exactly when the install went away. This
# rule inverts that: it asks the workspace what the database has sent lately, and an empty
# answer is what trips it.
#
# It can do that because a log search alert evaluates the SHAPE of the result, not its content.
# The query returns one row while metrics are arriving and no rows once they stop; with the row
# count as the measure and LessThan 1 as the condition, silence is the firing state. That is
# the property the metric alerts cannot have.
#
# The empty `datatable` anchor on the union, and why `isfuzzy` alone is not the protection it
# looks like. The hazard is real: a query whose source table does not resolve FAILS rather than
# returning nothing, which would leave the rule unhealthy — and, after a week of failures,
# disabled by Azure — precisely during the window when a fresh install is least proven.
# `union isfuzzy=true` is the usual answer to that and it is NOT sufficient on its own: measured
# against this module's own install workspace (log-masterly, msly-demo-01-eu) on 2026-09-09, a
# fuzzy union whose ONLY operand is a missing table still dies with SEM0104 ("Operator source
# expression should be table or column"). Anchoring the union with an empty literal of the right
# shape gives it a schema that always resolves, and the same missing operand then degrades to a
# partial-result warning and an empty answer — measured the same day, same workspace.
#
# For AzureMetrics specifically the anchor is belt-and-braces rather than load-bearing: it is a
# built-in table that resolves even when it holds nothing, which was checked by running the
# un-anchored query against that workspace, where AzureMetrics had no rows for the whole 30-day
# retention — it returned an empty result, not an error. The anchor is here so the idiom in this
# file is the one that is true in general, because these queries get copied.
#
# One failing evaluation over a 45-minute window before it pages — 45 minutes of true silence,
# reported within one 10-minute evaluation after that. Deliberately slower than the metric
# alerts: Learn is explicit that log data is more latent than metric data and that absence
# detection in logs misfires on ingestion delay, so the window is sized to swallow a delay spike
# rather than to be first with the news. The metric alerts above are the fast path; this is the
# one that still works when the fast path has nothing left to read.
#
# Why the silence lives in the window and not in `failing_periods`. Azure accepts more than one
# evaluation period only for a query that projects `TimeGenerated`, and this one cannot: it
# summarizes the whole window to a single count, because an empty result is the firing state.
# A rule asking for two periods is refused on create (400), so the sustained-ness is carried by
# the window alone. 45 minutes is the value in Azure's allowed set closest to the ~40 minutes
# that two consecutive 30-minute evaluations used to mean, and it errs on the side of not paging
# on an ingestion delay. tests/install.tftest.hcl pins both period counts at 1.
#
# It is also billed differently from its neighbours — a log search alert rule is charged per rule
# by evaluation frequency, where a metric alert is charged per monitored time series.
#
# No identity block: the rule queries with the permissions of the principal that last wrote it,
# which is the identity running terraform apply for this install. A system-assigned identity
# would need its own Reader grant on the workspace to be worth anything, and an identity without
# that grant is strictly worse than no identity at all.
#
# BYO-DB installs (external_database_url) get nothing here, and that gap is real rather than
# accidental: the module wires no diagnostic setting to a database it does not provision, so
# there is no telemetry stream of the customer's own database for it to notice the end of.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "postgres_silent" {
  count = local.diag_postgres ? 1 : 0

  name = "alert-${var.name_prefix}-postgres-silent"

  # Filed with the workspace it queries rather than with the server it is about: the rule's
  # scope is module.logs, which lives in the ACA resource group, and a rule that sits with its
  # scope is the one an operator can find from either end.
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  scopes              = [module.logs.id]

  description = "The install's database has sent no metrics for 45 minutes — it is stopped, deleted, or its telemetry has broken. This install is DOWN, not merely under strain."
  severity    = 0

  evaluation_frequency = "PT10M"
  window_duration      = "PT45M"

  # Resolve itself when the metrics come back: an operator who is paged for silence wants the
  # all-clear to arrive the same way, and this alert has a condition that can genuinely clear.
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      union isfuzzy=true
        (datatable(TimeGenerated:datetime, _ResourceId:string)[]),
        (AzureMetrics | where _ResourceId =~ "${azurerm_postgresql_flexible_server.this[0].id}")
      | summarize Samples = count()
      | where Samples > 0
    KQL

    time_aggregation_method = "Count"
    operator                = "LessThan"
    threshold               = 1

    # One period, because the query projects no `TimeGenerated` — see the comment above.
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  dynamic "action" {
    for_each = length(local.alert_action_group_ids) > 0 ? [1] : []
    content {
      action_groups = local.alert_action_group_ids
    }
  }

  tags = local.tags
}

# The apps' absence signal: postgres_silent, once per Container App (ADR 0080, amendment of
# 2026-10-07). app_unavailable above reads `Replicas`, so it catches an app that is scaled down
# or crash-looping. It cannot catch an app that is GONE — deleted, its environment torn down,
# its revision deprovisioned — because a gone app publishes no `Replicas` value and a metric
# alert with no data does not fire. That failure mode is the one with the longest time to
# notice, because nothing anywhere goes red. This rule asks the workspace what the app has sent
# lately, through the diagnostic setting above, and an empty answer is what trips it.
#
# Everything the postgres_silent comment says about the shape applies here unchanged, and is not
# repeated: the row count as the measure with LessThan 1 so that silence is the firing state, the
# empty `datatable` anchor on the fuzzy union, one evaluation period because the query projects
# no `TimeGenerated` (Azure refuses more, with a 400), the 45-minute window that absorbs log
# ingestion delay, and the rule being filed with the workspace it queries.
#
# One rule per app rather than one rule over three: a single query can say "some app is
# silent" only by naming the apps it expects and anti-joining, which is a different idiom, and
# one incident per app is what an operator needs anyway — they do not share a cause.
#
# Created only for an app with a replica floor of at least 1 (local.app_silent_apps). An app
# with replicas running publishes `Replicas`, CPU and memory every minute whether or not it
# serves anything, so silence from it means the app is not there. An app at zero replicas by
# design publishes nothing, and this rule would page every idle night.
#
# Container-log silence was the other candidate and is not the signal, for the reason given
# under app_unavailable: ca-workers writes no periodic heartbeat, so on an idle install its log
# is silent for hours, and silence there means "no work", not "no worker". Platform metrics do
# not depend on the app saying anything.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_silent" {
  for_each = local.app_silent_apps

  name = "alert-${var.name_prefix}-${each.key}-silent"

  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  scopes              = [module.logs.id]

  description = "The ${each.key} Container App has sent no metrics for 45 minutes — it is deleted, stopped, or its telemetry has broken. If the app is gone, ${local.app_unavailable_effect[each.key]}."
  severity    = 0

  evaluation_frequency = "PT10M"
  window_duration      = "PT45M"

  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      union isfuzzy=true
        (datatable(TimeGenerated:datetime, _ResourceId:string)[]),
        (AzureMetrics | where _ResourceId =~ "${each.value}")
      | summarize Samples = count()
      | where Samples > 0
    KQL

    time_aggregation_method = "Count"
    operator                = "LessThan"
    threshold               = 1

    # One period, because the query projects no `TimeGenerated` — see postgres_silent.
    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  dynamic "action" {
    for_each = length(local.alert_action_group_ids) > 0 ? [1] : []
    content {
      action_groups = local.alert_action_group_ids
    }
  }

  # Azure validates the KQL on create. Nothing before apply can.
  skip_query_validation = false

  tags = local.tags
}
