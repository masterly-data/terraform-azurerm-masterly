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
#    adding.
#
# So the shipped signal is the same one the serving apps carry, and it detects the same class
# of failure: the app is not there. The floor gate is workers_min_replicas >= 1, which is its
# default and which the variable's own description tells the caller to keep — nothing HTTP-wakes
# an ingress-less polling loop, so a workers app at zero replicas is a stalled pipeline whoever
# configured it chose, not a fault this alert should page about.
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
