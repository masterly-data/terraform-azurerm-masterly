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

  # Which apps get a replica-availability alert. See the alert itself for why an app that is
  # allowed to sit at zero replicas is deliberately left out rather than alerted on.
  availability_alertable_apps = local.diagnostics_enabled ? merge(
    var.api_min_replicas >= 1 ? { api = module.api.id } : {},
    var.frontend_min_replicas >= 1 ? { frontend = module.frontend.id } : {},
  ) : {}
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

# App availability. The apps have no availability metric of their own, and no platform health
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
# every install where diagnostics is on by default both alerts exist.
#
# What this alert CANNOT see, recorded here because the gap is invisible from the resource: a
# replica that starts, never passes its readiness probe, and is never routed to still counts
# toward `Replicas`. On an install with a replica floor — which is every production install, and
# the only kind this alert is created on — a wedged app therefore reads 1 and this stays green
# while the install serves nothing. app_5xx does not cover it either: that alert needs more than
# five requests in its window, and an install nobody can reach receives none.
#
# Two candidate signals for closing that were checked against the code and against real
# telemetry, and neither ports into this module:
#
#  * The app's own words. Layer 2 (masterly-platform-iac, MAS-260) alerts on the string
#    `readiness check failed`, written by common/app_factory.py's /readyz handler — but that
#    factory belongs to masterly-platform-backend, which never ships to a customer. The api this
#    module runs is masterly-application-backend, whose /readyz logs NOTHING on failure
#    (api/routes/health.py catches the dependency error and answers 503 without a log record) and
#    whose request-log middleware excludes /readyz and /healthz by name. A rule ported on that
#    string would be an alert that can never fire — worse than shipping none, because the README
#    would then claim coverage that does not exist.
#
#  * The platform's own words. ContainerAppSystemLogs_CL does carry the failure
#    (`Reason_s == "ProbeFailed"`, e.g. "Container ca-api failed readiness probe"), and it is
#    populated in every install because modules/aca-env-consumption sets logs_destination to
#    module.logs unconditionally. It caught exactly this shape on the demo install on 2026-09-07.
#    But replaying a sustained-window rule over 30 days of that workspace fires on roughly a
#    dozen occasions per app, most of them ordinary deploy churn, and separating a wedged app
#    from a rolling one needs a rate threshold that depends on readiness_probe_interval_seconds —
#    a per-install input this module lets the caller set. An alert shipped to customers on a
#    threshold tuned against one atypical install is one an operator mutes, which leaves them
#    worse off than a documented gap.
#
# So the gap is disclosed in the README ("What the alerts detect, and what they do not") rather
# than papered over, and what actually covers it is a synthetic check against the install's own
# URL, run from wherever the customer already monitors.
resource "azurerm_monitor_metric_alert" "app_unavailable" {
  for_each = local.availability_alertable_apps

  name                = "alert-${var.name_prefix}-${each.key}-unavailable"
  resource_group_name = azurerm_resource_group.aca.name
  scopes              = [each.value]
  description         = "The ${each.key} Container App has no running replica — this install is DOWN, not merely under strain."
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
# Two consecutive failing 30-minute evaluations before it pages — roughly 40 minutes of true
# silence. Deliberately slower than the metric alerts: Learn is explicit that log data is more
# latent than metric data and that absence detection in logs misfires on ingestion delay, so the
# window is sized to swallow a delay spike rather than to be first with the news. The metric
# alerts above are the fast path; this is the one that still works when the fast path has
# nothing left to read.
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

  description = "The install's database has sent no metrics for 30 minutes — it is stopped, deleted, or its telemetry has broken. This install is DOWN, not merely under strain."
  severity    = 0

  evaluation_frequency = "PT10M"
  window_duration      = "PT30M"

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

    failing_periods {
      number_of_evaluation_periods             = 2
      minimum_failing_periods_to_trigger_alert = 2
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
