# Diagnostics and alerts

The install's diagnostic settings, its Log Analytics workspace, and the alerts the module
creates and what they detect.

## Diagnostics + alerts

In `mode=production` the module wires the data-plane resources' diagnostic settings and the
saturation and load alerts to the install's Log Analytics workspace (on by default; set
`enable_diagnostics = false` to opt out, or `true` to enable outside production). The
availability alerts and the action group are not part of that switch; see below:

- **Diagnostic settings** (resource logs + `AllMetrics` → the workspace) for the provisioned
  Postgres, Redis, Key Vault, and Service Bus (each only when that resource exists). On
  `redis_offering = "managed"` this is two settings, not one: metrics are cluster-level but
  the connection log lives on the `redisEnterprise/databases` child. Each setting names its
  log categories rather than taking a category group such as `allLogs`, so a category Azure
  adds to a resource type later does not start flowing into your workspace unasked:

  | Resource | Log categories |
  |---|---|
  | Postgres (starter server) | `PostgreSQLLogs` |
  | Azure Cache for Redis | `ConnectedClientList`, `MSEntraAuthenticationAuditLog` |
  | Azure Managed Redis database | `ConnectionEvents` |
  | Key Vault | `AuditEvent` |
  | Service Bus | `OperationalLogs`, `DiagnosticErrorLogs` |

  Key Vault's `AuditEvent` goes to the resource-specific `AZKVAuditLogs` table, which is where
  the diagnostic bundle reads it; the Postgres log stays in `AzureDiagnostics`. The per-app
  settings below send metrics only; the apps' logs come from the environment's setting (see
  "Container logs" below). The starter server is also set to
  `log_error_verbosity = TERSE`, `log_parameter_max_length_on_error = 0` and
  `log_parameter_max_length = 0`, so its error log names what failed without the `DETAIL:`
  line that carries a constraint violation's values, and without bound parameter values;
  `log_min_error_statement` stays at its default, so the failing statement's text is still
  logged (ADR 0080, amendment of 2026-09-10). A BYO-DB server is yours to configure.

  Further server parameters go in `postgres_server_parameters`, a map of name to value (for
  example `{ max_connections = "400" }`), applied to the starter server beside those three. The
  map refuses `log_error_verbosity`, `log_parameter_max_length_on_error` and
  `log_parameter_max_length` (in any letter case), so it cannot weaken the log redaction above (ADR 0080); it refuses
  any entry when `external_database_url` is set, because the module sets no parameter on a server
  it does not own; it accepts only lowercase keys (Postgres parameter names are case-insensitive,
  so write `TimeZone` as `timezone`), so the checks here and the connections alert's lookup cannot
  be bypassed by a different letter case; and it refuses a `max_connections` that is not a whole number of at least 1.
  Static parameters, `max_connections` among them, take effect only after a server restart. The
  azurerm provider's `restart_server_on_configuration_value_change` feature (default `true`,
  in the `postgresql_flexible_server` block of your root `provider "azurerm"` `features`) restarts
  the server on `apply` when such a value changes; turn it off and restart it yourself. See the
  [`azurerm_postgresql_flexible_server_configuration`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_configuration)
  and [provider features](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block)
  documentation.
- **App availability diagnostics** — an `AllMetrics` diagnostic setting on `ca-api`,
  `ca-frontend` and `ca-workers`, and one absence alert per app, `<app>-silent`. See
  "App availability diagnostics" below: it is on by default in production only, it has its own
  opt-out, and it adds a standing cost to your Azure bill.
- **Saturation alerts** — the install is under strain. Postgres storage nearly full, B-series
  CPU-credit exhaustion (burstable installs only), Redis memory nearly full, Redis key evictions
  (which under the no-eviction policy mean the policy has been changed out from under the
  install, not that the cache is small), and `ca-api` / `ca-frontend` 5xx. Severity 1–2.
- **Load alerts** — the install is running out of headroom, before that becomes an outage:
  Postgres CPU, connections and IOPS, `ca-api` latency, `ca-workers` memory, and dead-lettered
  job messages on Service Bus. Severity 2 (1 for dead letters). Every threshold is an input;
  see "Load alerts" below.
- **Availability alerts** — something has stopped rather than strained: the install is not
  serving, the app that should serve it is running but never becomes ready, or the async
  pipeline behind it is not running. Severity 0 on all of them, so a notification tells you
  which of the two states you are in without opening the portal; the alert's own description
  says what stopped, because a dead `ca-workers` leaves the install answering every request
  perfectly while no job in it makes progress.

The availability alerts and the module's action group do not need `enable_diagnostics`: they
are created in every mode. `enable_diagnostics` governs the diagnostic settings, the saturation
and load alerts and `postgres-silent`.

To be paged, set `alert_email` (the module creates an action group) or point
`alert_action_group_id` at an existing group (a shared ops group, a PagerDuty webhook group).
`mode = "production"` refuses a plan with neither, whatever `enable_diagnostics` says, because
its severity-0 alerts would fire and notify nobody. If this install's alerts are routed outside
Terraform (an Azure Policy that attaches an action group to alert rules, or subscription-level
alert processing rules), set `alerts_routed_externally = true` to let the plan through; it
creates nothing. Outside production a missing target is allowed: the alerts fire and record.
The availability alerts add Azure Monitor charges to installs that did not have them (metric
alert rules, and the `app-not-ready` log search rule, billed per evaluation).

### Container logs

The Container Apps environment sends its logs through Azure Monitor
(`logs_destination = "azure-monitor"`) rather than writing to the workspace with the
workspace's shared key. One diagnostic setting on the environment, `diag-<name_prefix>-aca-env`,
sends `ContainerAppConsoleLogs` and `ContainerAppSystemLogs` to the install's workspace, into the
resource-specific tables of the same names (`log_analytics_destination_type = "Dedicated"`).
Because it is on the environment, it covers `ca-api`, `ca-frontend`, `ca-workers`, the
`ca-bundle-init` init containers that run inside them, and any app added to the environment
later. It is created in every mode, whatever `enable_diagnostics` says: the diagnostic bundle
reads these logs on any install.

Installs created by an earlier version of the module have their older lines in the legacy
custom tables `ContainerAppConsoleLogs_CL` and `ContainerAppSystemLogs_CL`, which get no new rows
after the apply that moves the environment. The `api-latency` and `app-not-ready` alerts and the
diagnostic bundle read only the resource-specific tables; a query or workbook of your own that
reads the `_CL` tables should move to the resource-specific ones.

### The Log Analytics workspace

The install's workspace, `log-<name_prefix>`, accepts Microsoft Entra ID only: local
(shared-key) authentication is off, so its shared keys authenticate nothing, and the module has
no output that carries one. It also takes no ingestion over the public network. The install's
own logs and metrics arrive through diagnostic settings, which deliver inside Azure Monitor and
need neither; an agent or a Logs Ingestion API client of your own that sends to this workspace
has to authenticate with Microsoft Entra ID and send through an Azure Monitor Private Link Scope
(AMPLS).

`log_query_public_access`, `log_retention_days` and `security_log_retention_days` set who can
query the workspace and how long it keeps what it holds; they are described in
[docs/inputs.md](inputs.md#the-installs-log-analytics-workspace).

Every query is signed in with Microsoft Entra ID. **Log Analytics Reader** on the workspace runs
queries, which is what the [diagnostic bundle](../README.md#diagnostic-bundle) needs; **Log Analytics
Contributor** also changes the workspace's settings.

With `log_query_public_access = false`, the Azure portal, the diagnostic bundle and your own
tools reach the workspace only from a network that resolves it through an AMPLS. The module
creates no AMPLS, because an AMPLS changes how every Azure Monitor endpoint resolves for the
whole network that uses its private DNS zones, not only this workspace's; it belongs to whoever
owns that network. Add the workspace to your AMPLS, give the AMPLS a private endpoint in a
network your operators query from, link its `privatelink` DNS zones to that network, and run
the diagnostic bundle from inside it.

The module does not place the workspace in a network security perimeter. An enforced perimeter
decides which sources may send logs to the workspace and which may query it, including the
diagnostic settings that deliver this install's logs, so its access rules have to be written for
your whole estate, which the module cannot see. `log_query_public_access` with an AMPLS you own
restricts queries without one. If you associate the workspace with a perimeter of your own,
start it in transition mode and confirm the install's logs still arrive before you enforce it.

### App availability diagnostics

The `<app>-unavailable` alerts read the platform's `Replicas` metric, so they catch an app that
is scaled down or crash-looping. They cannot catch an app that is **gone** — deleted, its
Container Apps environment torn down, its revision deprovisioned — because a gone app publishes
no metric at all, and a metric alert with no data does not fire. To cover that, the module sends
each Container App's platform metrics to the install's Log Analytics workspace (an `AllMetrics`
diagnostic setting, `diag-<name_prefix>-<app>`) and adds one log search alert per app,
`<app>-silent`, which fires when the app has sent no metrics for 45 minutes. It works the same
way as `postgres-silent`.

This is controlled by `enable_app_availability_diagnostics`:

| `enable_app_availability_diagnostics` | `mode = "production"` | Outside production |
|---|---|---|
| unset (default) | on, when diagnostics are on (the production default) | off |
| `false` | off | off |
| `true` | on, when diagnostics are on | on, and refused at plan unless `enable_diagnostics = true` |

It is part of the diagnostics surface and never outlives it: with `enable_diagnostics = false`
there are no app diagnostic settings and no `<app>-silent` rules, whatever this input says. Every
Container App the install runs gets the diagnostic setting; `<app>-silent` is created only for an
app whose `min_replicas` is 1 or more, because an app at zero replicas by design publishes nothing.

**It costs money, continuously.** The metrics are ingested into your workspace every minute for
as long as the apps run, and your Azure subscription pays for that ingest and its retention. Each
`<app>-silent` rule is also billed, per rule, by its 10-minute evaluation frequency. Three apps'
platform metrics are low volume, but the cost starts on the first apply of the module version
that carries this, with no variable changed. Set `enable_app_availability_diagnostics = false` to
keep the previous behaviour; the `<app>-unavailable` alerts stay either way.

### Load alerts

Each alert below watches one resource's headroom. The thresholds are module inputs, and the
defaults are **starting values, not measurements**: the right number for your install is the one
its own baseline under representative load supports. Run the install under your real workload,
look at where each signal sits, and set the input a comfortable margin above it. An alert that
pages on a normal working day is one you will learn to ignore.

| Alert | Fires when | Input (default) | What it means | What to do |
|---|---|---|---|---|
| `postgres-cpu` | Postgres `cpu_percent` averages above the threshold for 15 minutes | `alert_postgres_cpu_percent` (80) | The database server has little CPU left for the install's load. Queries slow first, then time out. | Find what is driving it — a large ingest, identity resolution over a big model, heavy consumption — in the api and workers logs. If it is sustained rather than one run, size `postgres_sku_name` up. |
| `postgres-connections` | Postgres `active_connections` averages above the threshold's share of `max_connections` for 15 minutes | `alert_postgres_connections_percent` (70), `alert_postgres_max_connections` (null) | The server is nearing its connection limit, past which it refuses new connections and requests fail. Each Masterly Environment keeps its own pool, so the count grows with Environments and replicas as well as with load. | Check how many api and workers replicas are running and how many Environments the install hosts. Size the server up (a larger SKU has a higher default limit) or raise its `max_connections` parameter. |
| `postgres-iops` | Postgres `disk_iops_consumed_percentage` averages above the threshold for 15 minutes | `alert_postgres_iops_percent` (80) | The disk is near the IOPS its storage tier provides. At the limit, I/O queues and every query slows at once. | Raise `postgres_storage_mb` (IOPS grow with the storage size) or set `postgres_storage_tier` for a higher storage performance tier. |
| `servicebus-dead-letters` | The `masterly-jobs` queue's dead-letter sub-queue holds more messages than the threshold (`enable_service_bus` only) | `alert_servicebus_dead_letter_threshold` (0) | A worker failed to process a job notification ten times and Service Bus set it aside. The jobs themselves are still in the Environment's database, but the message that should have woken a worker for them is gone, so work can wait with nothing else reporting it. | Read the dead-letter reason on the messages and the `ca-workers` logs around that time. Resubmit the messages once the cause is fixed, or remove them. The alert stays active while dead-lettered messages remain, and clears when they are gone. |
| `api-latency` | The 95th percentile of the api's own request durations exceeds the threshold over 15 minutes, with at least 50 requests in that window | `alert_api_p95_ms` (2000) | Requests are slowing under load. The duration is measured inside the api, so clients see at least this much. Bulk exports, the assistant's streaming chat and the MCP channel are left out, because their duration is the size of the answer. | Look at the Postgres load alerts first — a slow database is the usual cause. Then find the slow routes in the workspace: the console log for `ca-api` carries one `<METHOD> <route> -> <status> in <ms>ms` line per request, in `ContainerAppConsoleLogs` (column `Log`). The default is a placeholder: set it from a load test of your install. |
| `workers-memory` | A `ca-workers` replica's memory working set rises above the threshold's share of its memory, at any point in 15 minutes (`enable_workers` only) | `alert_workers_memory_percent` (85) | A worker is close to its memory limit. A replica that reaches it is stopped mid-job, and the job is retried against the same data. | Find the job kind running at the time in the `ca-workers` logs. Split the work (smaller ingest batches) or give the workers more memory. |

The connections alert needs the server's `max_connections`, which Azure publishes only as a
server parameter. By default the module takes it from Azure's documented default for
`postgres_sku_name`, derived from the SKU's memory. For a SKU it does not recognise — the
confidential-compute `DC`/`EC` families today — it creates no connections alert and **every
plan warns** that it did not, rather than measuring against a guess. When you set
`max_connections` in `postgres_server_parameters`, the alert reads it from there, ahead of the
SKU default, so a raised limit needs stating once and an unrecognised SKU gets its alert.
`alert_postgres_max_connections` still wins over both: set it to the server's value when you
have changed the parameter outside Terraform.

The load alerts need `enable_diagnostics` and nothing beyond it. The availability alerts
(`postgres-unavailable`, `<app>-unavailable`, `app-not-ready`) and the action group need not even
that: they are created in every mode. The metric alerts read the platform
metrics every Postgres server, Container App and Service Bus namespace publishes, and the latency
rule reads the console log that the diagnostic setting on the Container Apps environment sends
to the install's workspace in every mode (see "Container logs" above). It reads the
resource-specific `ContainerAppConsoleLogs` table, and so does `app-not-ready`.

**Not covered: the age of the oldest queued job.** It is the most direct load signal for the
async pipeline — how long work waits before a worker starts it — and the module does not alert
on it yet, because the application image does not write that age to its log, so there is
nothing in the workspace for a rule to read. The api reports it on request:
`GET /v1/ops/metrics` returns `jobs.oldest_queued_age_seconds` (and `jobs.queued_total`) for a
caller with the `ops:read` permission. Poll it from the monitoring you already run and alert on
the age you need jobs to start within.

### What the alerts detect, and what they do not

Every saturation alert needs the resource running, publishing metrics, and taking traffic. That
is the right shape for "under strain" and the wrong shape for "gone": a stopped database
publishes no storage figure, an app that hangs returns no 5xx, and an idle scale-to-zero install
reports no requests at all. The availability alerts exist to close that, and it is worth being
precise about how far they reach.

| Failure mode | Detected by | Notes |
|---|---|---|
| Database reports itself down | `postgres-unavailable` | Reads the platform's own `is_db_alive`. Fastest signal here: 5-minute window. Created in every mode for the starter server; it does not need `enable_diagnostics`. |
| Database stopped, deleted, or its telemetry broke | `postgres-silent` | Needs `enable_diagnostics` (it reads the metrics the Postgres diagnostic setting sends). Fires on the **absence** of metrics — the case a metric alert cannot see, because a metric alert with no data does not fire. It pages after 45 minutes of silence, within one 10-minute evaluation, deliberately. On a brand-new install it can fire once before the first metrics land; it clears itself when they do. |
| An app has no running replica | `<app>-unavailable` | One per Container App the install runs — `api`, `frontend` and, with `enable_workers`, `workers`. Only created for an app whose `min_replicas` is 1 or more, and in every mode, whatever `enable_diagnostics` says. Counts replicas, not readiness — the alert below is what reads readiness. |
| An app is gone: deleted, its environment torn down, or its revision deprovisioned | `<app>-silent` | Fires on the **absence** of the app's metrics in the workspace, the case `<app>-unavailable` cannot see, because a gone app publishes no `Replicas` value. One per Container App with a replica floor of 1 or more, when app availability diagnostics are on (the production default; see "App availability diagnostics"). It pages after 45 minutes of silence, within one 10-minute evaluation. Like `postgres-silent`, it can fire once on a brand-new install before the first metrics land, and clears itself when they do. |
| An app is running but never becomes ready | `app-not-ready` | One rule for both serving apps, split by app name. `ca-api` and `ca-frontend` each log one line per **failing** readiness probe (and nothing on a passing one); the rule fires when an app has failed readiness in at least 30 of the last 60 minutes, so ~30–40 minutes to page. That is the case `<app>-unavailable` structurally cannot see — an unready replica is never routed to, but it still counts as a replica. A cold start legitimately fails readiness for minutes at a time, which is why the bar is half an hour rather than a single failure. Created in every mode; it does not need `enable_diagnostics`. |
| The async pipeline has no worker running | `workers-unavailable` | The same alert, and the one nothing else in the set can stand in for: `ca-workers` has no ingress, so it emits no requests and `<app>-5xx` is blind to it by construction. Without this, a dead workers app is silent — the install keeps answering, the queue keeps growing, and the first signal is somebody asking why yesterday's ingest never landed. |
| Storage, memory, CPU credits, evictions, 5xx | the saturation alerts | Need the resource up and, for 5xx, traffic flowing. |
| Headroom running out: database CPU, connections, IOPS; api latency; worker memory; dead-lettered job messages | the load alerts | Need the resource up and publishing; the latency rule also needs traffic (at least 50 requests in 15 minutes). |

Not detected, and no alert here should be read as covering it:

- **A serving app that is unready for less than half an hour.** `app-not-ready` covers the
  sustained case — the wedged replica that `<app>-unavailable` reads as a healthy 1 — but it is
  deliberately slow, because a cold start fails readiness legitimately for minutes at a time and
  an alert that pages on every deploy is one you learn to mute. A wedge that clears inside the
  window is invisible here; it is visible in the workspace, in `ContainerAppConsoleLogs`, where
  the same line the alert reads is queryable at any resolution you like. A synthetic check against the install's own URL, run from wherever you
  already monitor, is still the faster signal and still worth having; the module ships none, for
  the vantage-point reason given in "An app that is up, answering, and wrong" below.
- **A workers app that is running but wedged.** The wedged shape again, one layer down, and here
  nothing reads it at all: `ca-workers` has no ingress, no `/readyz` and no probe, so it writes
  no readiness line for `app-not-ready` to see, and a replica whose consume loop is stuck still
  counts toward `Replicas`, so `workers-unavailable` reads 1. What the module can see is
  that the app is *there*; whether it is *draining* lives in the install's own job tables, which
  the module provisions and never reads. Alert on queue depth or on the age of the oldest
  unclaimed job from the application side if you need that — `GET /v1/ops/metrics` reports both
  (see "Load alerts" above) — and keep this alert for the case it does cover, the workers app
  being gone.
- **An app that is gone, on an install with app availability diagnostics off.** With
  `enable_app_availability_diagnostics = false`, or outside production unless you set it to
  `true`, the apps' metrics never reach the workspace, so no `<app>-silent` rule exists and
  `<app>-unavailable` is the only app alert. It goes quiet when an app is deleted rather than
  firing, because a metric alert with no data does not fire. The same is true for an app with
  `min_replicas = 0`, which gets no `<app>-silent` rule.
- **A BYO-DB install's database.** With `external_database_url` set, the module wires no
  diagnostic setting to a server it does not own, so it has no telemetry stream whose end it
  could notice. Alert on your own database from wherever it runs.
- **An app that is up, answering, and wrong.** Replicas running and no 5xx is the shape of a
  healthy app and also of one serving stale or empty data. Nothing in the module probes the
  application's `/readyz` from outside — `app-not-ready` reads what the app itself said about
  its last probe, which is a different thing. An outside probe is a synthetic check, and the
  module deliberately ships none, because on the private-ingress and injected-network topologies
  there is no vantage point it could run from without assuming a network it does not own.
- **An app on a scale-to-zero install.** With `min_replicas = 0`, zero replicas is the intended
  state, so no replica alert is created for that app. This is an evaluation cost posture;
  `mode = "production"` requires a floor of at least one replica on both apps.
- **Database silence, saturation and load, on an install with `enable_diagnostics = false`** —
  the default outside `mode = "production"`. With diagnostics off there is no `postgres-silent`
  and no saturation or load alert; the availability alerts (`postgres-unavailable`,
  `<app>-unavailable`, `app-not-ready`) and the action group do not depend on it and remain.
- **Anything, on an install that set `alerts_routed_externally = true` and whose external routing
  does not reach these alerts.** `mode = "production"` refuses a plan with neither `alert_email`
  nor `alert_action_group_id` unless that escape hatch is set, so a production install without a
  target is one that chose it: its alerts fire and record, and notify only through the routing you
  run outside this module. Outside production, an install with no target has the same gap.
