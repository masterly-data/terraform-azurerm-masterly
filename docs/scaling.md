# Scaling

How the install's apps scale, what each replica gets, and the connection budget the scale
limits imply.

## Scaling

`ca-api` defaults to a **single replica** — with the in-memory session registry a second
replica would drop sessions. `enable_redis` switches sessions to the redis registry and
unlocks `api_max_replicas > 1` (the module refuses the combination scale-out-without-Redis
at plan time). `enable_workers` moves the async-pipeline loop to its own `ca-workers` app.
`frontend_max_replicas` (default 3, at least `frontend_min_replicas`) caps the frontend, which
Container Apps scales on HTTP load.

**Scale-to-zero** (`api_min_replicas = 0` / `frontend_min_replicas = 0`) is the idle-cost
posture for evaluation installs (the demo runs it): Container Apps stops the replicas when
idle and the default HTTP scale rule wakes them on the next request. The costs: cold-start
latency on the first request, in-memory sessions drop when the last api replica stops
(unless `enable_redis`), and the api's in-process worker loop only polls while a replica is
up — async jobs stall until the next request. Refused in `mode=production`. The workers
floor (`workers_min_replicas`) stays >= 1 by design: nothing HTTP-wakes an ingress-less
polling loop. `mode=production` refuses 0 there too.

One interaction to know about: the frontend's readiness probe calls the api, so on a
scaled-to-zero install the first wake also waits for an api replica. The probe's budget (485s
of continuous failure) is sized past any cold start we have measured, including a first apply
pulling the api image onto a cold node — so in practice this costs wake latency rather than an
activation. It also means the probe traffic holds the api up while a frontend replica exists:
the api idles down a few minutes after the frontend rather than alongside it.

The trade this makes, stated plainly: **the frontend's availability is now coupled to the api.**
If the api stays down longer than the budget, ACA pulls the frontend replicas out of rotation
and the install answers a bare `503` at `frontend_url` instead of loading the app. That is the
intended behaviour for a *misconfigured* install — a frontend that cannot reach its api is not
serving anything useful, and letting it look healthy is how two wiring faults ran for hours
undetected. But it also applies to a *healthy* install during a long backend outage, where the
app would otherwise have loaded and shown its degraded-data-plane banner. The gate is not
currently an input — it is fixed in the module — so if that trade is wrong for your
environment, raise it with us rather than editing a vendored copy.

### How `ca-workers` scales

`ca-workers` runs between `workers_min_replicas` (1 unless `capacity_profile` sets it, see
[Capacity profiles](#capacity-profiles)) and `workers_max_replicas` (default 1). What moves it between the two depends on the bus:

- **On the Service Bus binding** (`enable_service_bus = true`) the module adds an
  `azure-servicebus` scale rule on the jobs queue the workers receive from, with a target of 5
  messages per replica, between `workers_min_replicas` and `workers_max_replicas`. The rule
  authenticates as the identity `ca-workers` runs as (`id-<prefix>-workers`, or the apps' managed
  identity with `migrations = "start"` on `"entra"` or without the vault), which the module grants
  **Azure Service Bus Data Owner** on the jobs queue alone, to let the scaler read the queue's message count. With the
  rule in place, `workers_min_replicas = 0` is a usable setting on this binding: the rule is what
  starts a worker when jobs arrive.
- **Not yet proven on a live install.** Three things about the Service Bus rule rest on Azure's
  documentation and have not yet been shown on a running install: that Data Owner at queue scope
  is enough for the scaler (if it is not, the grant moves to the namespace); that the scaler
  reaches a Premium namespace with public network access disabled, which is the production
  shape; and how quickly replicas are added and removed as the queue fills and drains. They are
  checked on a live install before the version that carries this rule is released, and this
  section will say what that showed.
- **On the polling binding** (the default) each Environment's queue lives in its own Postgres
  database and there is no single queue length to scale on, so `ca-workers` stays at
  `workers_min_replicas` whatever `workers_max_replicas` says. The module plans such a
  configuration but warns about it. Raise `workers_min_replicas` to run more workers there.

Jobs are claimed per Environment and job kind across all replicas: jobs of different kinds, or in
different Environments, run in parallel, and two jobs of the same kind in one Environment never
overlap. An extra replica adds throughput and never duplicates work.

A stopping worker (scale-in, a new revision, a restart) claims no new job and finishes the jobs
it is running. `workers_termination_grace_period_seconds` (default **600**, the most Container
Apps allows; 0-600) is how long it has before it is killed. A job cut off by a kill is retried
only after its lease expires, so a grace period long enough for your longest jobs is what keeps a
scale-in from delaying them. The cost is on the other side: a revision swap (a new image, a
changed setting) can wait up to that long for the old worker to stop.

### CPU and memory per replica

`app_resources` sizes each app's replicas, keyed by app name (`api`, `frontend`, `workers`). An
app that is not listed keeps 0.5 vCPU / 1Gi. Container Apps accepts only the ratio 1 vCPU : 2 GiB,
from 0.25 vCPU / 0.5Gi to 2 vCPU / 4Gi in steps of 0.25 vCPU, so either attribute alone is
enough; set both and they must agree, or the plan is refused:

```hcl
app_resources = {
  api     = { cpu = 1 }                   # 1 vCPU / 2Gi, what the production example sets
  workers = { cpu = 1.5, memory = "3Gi" } # both stated: they must be in the ratio
}
```

Changing an app's size rolls that app to a new revision on the next apply. The `workers-memory`
alert follows the workers' size: its threshold is a share of whatever memory the replica has.

### Connection budget

The api creates one database per Masterly Environment (ADR 0003), and each backend process
(`ca-api` replica, `ca-workers` replica) holds connection pools per Environment in use. Count them
against the server's `max_connections`, which the connections alert also measures.

`postgres_pgbouncer = true`, or `capacity_profile = "standard"` or `"enterprise"` with
`postgres_pgbouncer` unset, turns on the Flexible Server's built-in PgBouncer in transaction mode
(`pgbouncer.enabled = true`, `pgbouncer.pool_mode = TRANSACTION`,
`pgbouncer.max_prepared_statements = 100`). `MASTERLY_DATABASE_URL` then points at the pooler on
port 6432 and `MASTERLY_DATABASE_POOLER` is `transaction`. `MASTERLY_DATABASE_DIRECT_URL`
(secret `database-direct-url`, same server, role and `postgres` database) stays on 5432 for what a
transaction pooler cannot carry, such as creating an Environment's database. Under
`database_auth = "entra"` neither URL carries a password. Built-in PgBouncer is not offered on
burstable (`B_*`) SKUs, and the input is refused with `external_database_url`.

**Needs an api image that carries MAS-1615** (masterly-application-backend PR #488). An older image
ignores `MASTERLY_DATABASE_POOLER` and fails through the pooler. All three settings change in
one apply, so roll the api image first.

**Turning it off interrupts the database connection during the rollout.** When the module builds
the network, the apply on turn-on updates the endpoints' network security group to admit 6432 and
turns PgBouncer on before the apps roll to the :6432 URL. Setting `postgres_pgbouncer` back to
`false` keeps that order: the network security group drops 6432 first, and only then do `ca-api`
and `ca-workers` roll to a revision on 5432. Until the new revisions are healthy, the running ones
cannot open new connections to the pooler. PgBouncer itself is switched off only after the apps
have moved. Turn it off in a maintenance window. With injected subnets the 6432 rule is yours
(see [docs/networking.md](networking.md#network-security-baseline)): add it before turning
the input on, and remove it only after the apps have rolled to 5432.

Per process and Environment:

- Through the pooler (6432): the session pool, 5 + 10 (pool size plus overflow) = up to 15
  client connections. They share the pooler's server-side connections.
- Direct (5432): the direct pool, 1 + 4 = up to 5 connections, held on the server itself.

Multiply by `api` replicas (`api_max_replicas`), `ca-workers` replicas (`workers_max_replicas`) and
the Environments in use (at most the Environment limit your license grants, `engine_max`; it is a
license claim, not a module input):

    processes          = api replicas + workers replicas
    pooler clients     = processes x Environments x 15
    direct on 5432     = processes x Environments x 5
    pooler server side = (Environments + 1) x pgbouncer.default_pool_size (Azure's default: 50)

The pooler clients do not count against `max_connections`, but the pooler's own server-side
connections do. Each Environment is a separate database, so PgBouncer opens a separate server pool
for it, plus one for the install-level `postgres` database that `MASTERLY_DATABASE_URL` names.
Each pool holds up to `pgbouncer.default_pool_size` connections (the module does not set it; the
default is 50, and you can change it through `postgres_server_parameters`).

*Worked example, `GP_Standard_D2ds_v5`* (8 GiB, default `max_connections` 859): 3 api and 2
workers replicas make 5 processes; with 4 Environments that is 5 x 4 x 15 = 300 pooler client
connections and 5 x 4 x 5 = 100 direct connections. The 100 direct connections count against 859
in full, and so do the pooler's server-side connections: up to (4 + 1) x 50 = 250. Together up to
350 of 859. The 300 pooler clients themselves do not count, since PgBouncer multiplexes them.
Without the pooler the same install would open 5 x 4 x (15 + 5) = 400.

*Worked example, `B_Standard_B1ms`* (`max_connections` 50): there is no built-in PgBouncer, so
every connection is a server connection. 1 api and 1 workers replica make 2 processes; with 2
Environments that is 2 x 2 x (15 + 5) = 80, above 50. Use fewer Environments or replicas, or a
`GP_*` SKU with `postgres_pgbouncer = true`.

The connections alert keeps measuring the server's `max_connections`; it does not count pooler
clients.

## Capacity profiles

`capacity_profile` sizes the services an install already has, all at once (ADR 0120 §4). It
never changes the topology: it adds no app, environment or subnet, and it turns nothing on that
the install does not run.

| Profile | Postgres SKU | Built-in pooler | Service Bus tier | Minimum replicas api / frontend / workers |
|---|---|---|---|---|
| `small` (evaluation only) | `B_Standard_B1ms` | off | Standard | 1 / 1 / 1 |
| `standard` | `GP_Standard_D2ds_v5` | on | Standard | 2 / 1 / 1 |
| `enterprise` | `GP_Standard_D4ds_v5` | on | Premium (chosen by you, see below) | 2 / 2 / 2 |

**No profile turns on zone-redundant HA.** It is `postgres_zone_redundant_ha` alone, off by
default on every profile and in every mode (ADR 0120, 2026-11-20 amendment); see
[Zone-redundant HA](#zone-redundant-ha) below.

Each value resolves in this order: the input set explicitly (`postgres_sku_name`,
`postgres_pgbouncer`, `servicebus_sku`, `api_min_replicas`,
`frontend_min_replicas`, `workers_min_replicas`), then the profile's, then the input's earlier
default. Leaving `capacity_profile` unset (the default) therefore changes nothing on an existing
install: `B_Standard_B1ms`, no pooler, Service Bus Standard and minimum replicas 1 / 1 / 1,
as before. Every guard judges the resolved value, so `mode = "production"` refuses a burstable
SKU or a replica floor of 0 however it was reached. On the provisioned server, a burstable SKU set
explicitly under `standard` or `enterprise` is refused in any mode until the pooler is set off too
(`postgres_pgbouncer = false`), and `postgres_zone_redundant_ha = true` is refused on a burstable
SKU: Azure offers neither on burstable SKUs.

- **`small` is refused in `mode = "production"`**, whatever the other inputs say.
- **With `external_database_url`** the profile's Postgres values do not apply: there is no server
  to size and no built-in pooler, so the apps keep the URL you supplied. The replica floors still
  apply.
- **A profile does not raise a maximum.** `standard` and `enterprise` set an api floor of 2, so set
  `api_max_replicas` to at least 2, which needs `enable_redis`. `enterprise` sets a frontend floor
  of 2 (the default `frontend_max_replicas` of 3 covers it) and, with `enable_workers`, a workers
  floor of 2: set `workers_max_replicas` to at least 2. On the polling binding `ca-workers` stays
  at its minimum, so set `workers_max_replicas` equal to the floor there. The plan names each
  maximum that is below its floor.

### How enterprise reaches Service Bus Premium

No profile chooses a Service Bus tier. Moving an existing namespace to or from Premium replaces
it, together with its queue and role assignments, and the module cannot tell a new namespace from
an existing one. So with `servicebus_sku` unset, `small` and `standard` keep the earlier default,
Standard, and `enterprise` with `enable_service_bus = true` is refused at plan until you choose:
`servicebus_sku = "Premium"`, enterprise's tier, for a new namespace, or `"Standard"` to keep an
existing Standard namespace unchanged. `mode = "production"` requires `servicebus_sku` with Service
Bus on whatever the profile.

### Zone-redundant HA

`postgres_zone_redundant_ha = true` gives the starter Postgres server a synchronous standby in
another availability zone, which Azure fails over to in about two minutes with no data loss. It is
off by default on every profile and in `mode = "production"`, because by default the install's
Container Apps environments are not zone-redundant: a zone failure can take the apps down whatever Postgres does,
so the standby protects the data more than it protects uptime, at twice the server's compute.

Without it, a zone failure is recovered by a point-in-time restore into another zone. Azure
documents up to 5 minutes of data loss, and downtime from minutes to hours depending on the data's
size. What that means for the profiles' recovery objectives (ADR 0120 §4):

| Profile | Objective (data loss / downtime) | Without HA |
|---|---|---|
| `small` | 1 hour / 24 hours | holds |
| `standard` | 15 minutes / 4 hours | data loss holds; downtime holds once a restore drill on your data's size fits 4 hours |
| `enterprise` | near zero / 1 hour | does not hold: set `postgres_zone_redundant_ha = true` |

`mode = "production"` with `capacity_profile = "enterprise"` and HA off plans, with a warning
(`enterprise_production_without_postgres_ha`). HA needs a General Purpose or Memory Optimized SKU
and a region with availability zones. With `external_database_url` the input is ignored: your
database's availability is yours.

**Upgrading from a version where `standard` or `enterprise` turned HA on.** An install that set
the profile and left `postgres_zone_redundant_ha` unset plans removing its standby (an in-place
update that restarts the server). Set `postgres_zone_redundant_ha = true` before upgrading to keep
it.

### Changing the profile on an existing install

- **The Postgres server is updated in place, never replaced.** A profile reaches only the SKU
  and the pooler parameters; it never reaches the server's name, version, administrator login,
  zone or geo-redundant backup, any of which would replace the server and its databases.
- **A SKU change, or turning HA on or off, restarts the server.** Both are in-place updates, but Azure
  restarts the server to apply them, so plan the change in a maintenance window.
- **The pooler needs an api image that carries MAS-1615.** Moving to `standard` or `enterprise`
  turns on the built-in PgBouncer unless `postgres_pgbouncer = false` is set, and the apps roll to
  the pooler on 6432 in the same apply (see [Connection budget](#connection-budget)). Roll the api
  image first, or keep the pooler off until you have.

### Recovery objectives

ADR 0120 §4 states a recovery point and recovery time objective per profile:

| Profile | RPO / RTO |
|---|---|
| `small` | 1 h / 24 h |
| `standard` | 15 min / 4 h |
| `enterprise` | near zero / 1 h |

**Unverified.** These are the objectives each profile is sized for with zone-redundant HA on, and,
for enterprise's downtime through a zone failure, with zone-redundant environments too; without HA,
see [Zone-redundant HA](#zone-redundant-ha). The restore and failover
drills that would show an install meeting them have not been run, and this section will say what
they showed once they have.
