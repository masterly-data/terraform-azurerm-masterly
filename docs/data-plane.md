# Data plane

The install's data plane (ADR 0065): what the starter Postgres, Redis and Service Bus provide,
how the apps authenticate to them, the migrate job, and trusting a private CA.

## Data plane (ADR 0065)

Self-hosted is the `self-hosted × byo-db` combination: production installs point
`external_database_url` at their own Postgres (Azure Flexible PG, Databricks Lakebase,
AWS Aurora PG, Cosmos for PG). The DSN is the install-level connection
(`postgresql+asyncpg://…`; the role needs `CREATEDB` — the api creates
`masterly_dp_<environment>` databases at first touch). Reachability of your database
from the install's VNet is your side: peering, a private endpoint into
`snet-private-endpoints`, or your hub. A private endpoint placed in that subnet is reached
on the ports the subnet's network security group admits — Postgres among them; see
[docs/networking.md](networking.md#network-security-baseline).

Omit `external_database_url` and the module provisions the **starter server** instead —
private-endpoint-only Postgres Flexible, right for evaluations and the demo. Its knobs:
`postgres_sku_name`, `postgres_storage_mb`, `postgres_version`,
`postgres_backup_retention_days`, `postgres_geo_redundant_backup` (on by default in
production where the module knows the region supports it; mind data residency — backups go to
the paired region; see [the departures section](../README.md#geo-redundant-backup-is-on-only-in-the-regions-the-module-lists)),
`postgres_zone_redundant_ha` (needs a non-burstable SKU), `postgres_server_parameters` (extra
server parameters; see [Diagnostics + alerts](../README.md#diagnostics--alerts) in the README),
`postgres_auto_grow` (on by default in production: Azure grows the disk before it fills, so a
full disk does not make the server read-only; **grown storage cannot be shrunk**, and the
module never plans `postgres_storage_mb` below the server's real size),
`postgres_storage_tier` (the storage performance tier, P4 to P80; unset keeps Azure's default
for the size, and the tier must suit `postgres_storage_mb`) and `postgres_pgbouncer` (the
built-in PgBouncer in transaction mode; needs a non-burstable SKU; see
[Connection budget](scaling.md#connection-budget)). Flipping an install from starter to BYO-DB **plans the destruction of the starter
server** — migrate your data first; the plan makes it visible.

A BYO-DB database on a **private** address — reached over peering or a private endpoint — is
refused on `mode=production` by the application's egress guard when an organization
administrator supplies it as a [BYO-DB Environment's](https://masterlydata.com/docs/guides/manage-environments/)
connection string, along with every other outbound target configured in the product. List
the ranges those targets sit on in `allowed_private_egress_cidrs` (`["10.20.0.0/16"]`, say —
the database's subnet, no wider) and the application admits a target inside them; every
other private address stays refused, and loopback, link-local (`169.254.169.254`) and the
unspecified address are refused whatever is listed — an entry covering one fails the plan or,
for a wide range, refuses to start. It
reaches `ca-api` and `ca-workers`, and an empty list (the default) sets nothing, leaving the
application's own mode-gated posture in force. `external_database_url` itself is never
restricted — the install's own database is operator configuration, not customer input.

`allow_private_egress` is **deprecated** and goes away in a later release. It arrives already
deprecated: it never reached a published version, and the application setting it writes used
to switch the guard off entirely, loopback and the metadata endpoint included. For one release
`true` means the allowlist it stood in for — every RFC1918 range, CGNAT and IPv6 unique-local,
never loopback or link-local — and the application warns at every start. Migrate by replacing
it with the ranges your targets are actually on; setting both fails the plan.

### Extra Environments on a demo install

On `mode = "demo"` the control plane is in memory, and its Environments are a fixture list,
`prd-eu` and `non-prd-eu`. An Environment created in the product lasts only until `ca-api`
restarts. List the extra Environments an evaluation or demo install runs on in
`demo_environments` instead (`["dev-eu", "uat-eu"]`, say). The module puts them on `ca-api`, and
on `ca-workers` with `enable_workers`, as `MASTERLY_DEMO_ENVIRONMENTS`, comma-separated, and the
control plane seeds each one at every start, in the install's own geo (`masterly_region`), under
an id derived from its name, so it is the same Environment after a restart. api `v0.137.0` and
later read it; an earlier image ignores it. Empty (the default), no app gets the variable.

Each name is lowercase, starts with a letter, ends with a letter or digit, has only letters,
digits and hyphens, and is at most 40 characters. A name listed twice, a fixture name, and the input on
`mode = "production"` are refused at plan: a production install creates its Environments in the
product, where they persist in the control-plane store.

### Deployment switches

The backend reads `MASTERLY_DEPLOYED_SWITCHES`, a comma list over `assets`, `media`,
`extensions` and `replica`, to know which optional capabilities this install has deployed. Declare
them in `deployed_switches` so the value survives the next apply instead of being removed:

```hcl
deployed_switches = ["assets", "replica"]
```

- `assets`: the install's Blob storage account, one container per Environment.
- `media`: the media worker pool and its libraries.
- `extensions`: the extension environment.
- `replica`: a Postgres read replica.

The module puts them on `ca-api`, and on `ca-workers` with `enable_workers`, comma-separated in
the order given. api `v0.136.0` and later read it; an earlier image ignores it. Empty (the
default) means no switch is deployed, and no app gets the variable. The input only tells the
backend which of these the install has deployed; it deploys nothing itself. Name only what is
actually running: a module whose needs include an unlisted switch is refused at activation (422
`MODULE_SWITCH_NOT_DEPLOYED`), and naming a switch that is not running lets such a module activate
and then fail. The backend refuses to start on a name it
does not know, so a name outside the four, and a name listed twice, are refused at plan. The
frontend never carries it.

### Authentication to the starter server and Redis

The apps authenticate to the starter Postgres server and to Redis in one of two ways, chosen
by `database_auth` and `redis_auth`:

| | `"entra"` — Azure's recommendation | `"password"` / `"key"` — a departure |
|---|---|---|
| Postgres | Microsoft Entra authentication on, password authentication off. The apps' identity (`id-masterly-apps`) is the server's Microsoft Entra administrator; with `migrations = "job"` the migrate job's (`id-masterly-migrate`, [below](#the-migrate-job)) is instead, and the only one; each connection string names its own identity's role with no password. With `migrations = "job"` on the starter server, `ca-api` and `ca-workers` instead sign in as the DML-only roles `masterly_api` and `masterly_workers`, bound to `id-masterly-apps` and `id-masterly-workers` | The `masterly_admin` login, with its password in the connection string, for the apps and the migrate job alike. With `migrations = "job"`, `ca-api` and `ca-workers` instead sign in as `masterly_api` and `masterly_workers`, each with its own generated password |
| Redis | Access keys off. The apps' identity holds a data access policy: the default policy on Azure Managed Redis, *Data Contributor* on Azure Cache for Redis. Wherever `ca-workers` runs as its own identity, `id-masterly-workers` holds its own (`masterly-workers` on Azure Cache for Redis). The URL carries no key | The access key, in the URL |
| The apps | `MASTERLY_DATABASE_AUTH=entra` / `MASTERLY_REDIS_AUTH=entra` and `AZURE_CLIENT_ID`, on `ca-api` and `ca-workers`. Needs **api images `v0.133.7` or later** | Nothing added |

When an input is unset, the module picks for you, and it never changes what an existing
server or cache already uses:

| | No server or cache yet | One exists |
|---|---|---|
| `mode = "production"` | `"entra"` | What it records. If that is a password or key, the plan stops and asks you to choose |
| `mode = "demo"` | `"password"` / `"key"` | What it records |

To know what exists, the module lists the subscription's flexible servers (and caches of the
active `redis_offering`) at plan time and reads the `masterly-auth` tag it puts on its own. A
server or cache created by an earlier version of this module has no such tag and is read as
using its password or key. An explicit value always wins, and setting it skips the lookup —
except `database_auth = "entra"`, which still reads the server's `masterly-admin-password` tag
(below). The listing is a read at subscription scope, which the Contributor or Owner role at
subscription scope that [Preflight](../README.md#preflight) checks for already includes.

Choose `database_auth` before the apply that creates the server. A server created with
`"entra"` has no password login at all, so moving it to `"password"` afterwards is not a
supported change. A server that started on `"password"` can move to `"entra"`, and back.

**The generated admin password.** A server that started on `"password"` keeps the generated
`masterly_admin` password when it moves to `"entra"`: the module goes on applying the same
value, unused while password authentication is off, and that is what lets the server move back.
A server created on `"entra"` never has one. The server records which in its
`masterly-admin-password` tag (`"generated"` or `"none"`).

To rotate the password on a server using `"password"` — after a state exposure, say — replace
it and apply:

```bash
terraform apply -replace='module.masterly.random_password.postgres_admin[0]'
```

(with your own module name in place of `masterly`). One apply changes the password on the
server and in the `database-url` secret, and the apps roll a new revision onto it; connections
the old revision opens in between are refused until it does. On a server that moved to
`"entra"` the same command replaces a password nothing signs in with.

With `external_database_url` (BYO-DB) none of this applies: the database is yours, the DSN is
the credential, and `database_auth = "entra"` is refused at plan.

### The migrate job

Opt-in, with `migrations = "job"`. Schema migrations, and the database of each new Masterly
Environment, then run in a Container Apps job, `caj-migrate`, as its own identity,
`id-<prefix>-migrate` (ADR 0120). `ca-api` and `ca-workers` carry `MASTERLY_MIGRATIONS=job`,
which tells the api image to check that the schema is at head instead of migrating.

Job mode requires `mode = "production"`. Demo's control plane is in memory, so there is nothing
for a separate job to migrate; keep `migrations = "start"` for demo installs. The job receives
the API's `MASTERLY_ORG_ID`, optional `MASTERLY_ORG_NAME` and `MASTERLY_MODE`, with
`MASTERLY_CONTROLPLANE_STORE=postgres`, to open the same install's durable control plane.
Production's Key Vault requirement also applies.

`migrations` defaults to `"start"`: the module creates no job, no migrate or workers identity, no
app-role password, no grant and no migrate Entra administrator, sets no `MASTERLY_MIGRATIONS`, and
`ca-api` and `ca-workers` migrate at start as before. **`"job"` needs an api image from a backend release later than
v0.135.0.** The backend implementation reference is `masterly-application-backend` at commit
`8d2cbd35`: `masterly_app/apps/migrate.py` is the entry point, `composition/migrate.py` composes
the migrate role, and `core/settings.py` defines `MASTERLY_MIGRATIONS`,
`MASTERLY_MIGRATE_API_ROLE` and `MASTERLY_MIGRATE_WORKERS_ROLE`. These prerequisites are in no
release up to v0.135.0, which cannot run the job. Leave the default until your install runs a
qualifying release; see the upgrade note below.

The job runs `python -m masterly_app.apps.migrate` on the api image, has no ingress, and runs in
three ways:

- **At apply.** Installing with `migrations = "job"`, or enabling it on an existing install,
  creates the job on the resolved api image (`api_image`, or the release channel's default).
  An `azapi_resource_action` starts one execution before `ca-api` and `ca-workers` are created
  or updated to job mode: both depend on the action. It returns when the execution starts;
  the apps rely on the backend's schema-stamp readiness checks until migrations finish.
  As on the apps, Terraform then ignores drift on the job's image. Changing `api_image` replaces
  the start action and starts another execution on the job's current image; it changes neither
  the job's nor the apps' running image.
- **At each release, from CD.** Your CD owns the running image, on the job as on the apps (ADR
  0086, as amended 2026-10-23: the migrate job runs the release's digest before the roles roll).
  For each release it:
  1. moves the job to the release's digest:
     `az containerapp job update --name caj-migrate --resource-group rg-<prefix>-aca --image <registry>/release/api@sha256:<digest>`;
  2. starts an execution: `az containerapp job start --name caj-migrate --resource-group rg-<prefix>-aca`;
  3. waits until that execution's status is `Succeeded`
     (`az containerapp job execution show --name caj-migrate --resource-group rg-<prefix>-aca --job-execution-name <name>`),
     and stops if it fails;
  4. only then rolls `ca-api` and `ca-workers` to the same digest (`az containerapp update --image`).
- **On a schedule**, `migrate_job_schedule`: a five-field cron expression in UTC, default
  `"*/5 * * * *"`. The release's migrate role is required to pick up, on each run, the
  Environments waiting to be provisioned, once database access and any BYO-DB secret grants below
  are ready. Five minutes keeps the polling wait short for a person who has just created an
  Environment, at the cost of one short container start per run. Lengthen it if that wait does
  not matter to you.

Runs can overlap: a scheduled run with an apply-started or CD-started one. The release's migrate
role is required to serialise them with a migration lock.

What the job's identity gets, and why so little: on `database_auth = "entra"` it is the starter
server's only Microsoft Entra administrator (`id-<prefix>-apps` is none under `"job"`, below),
which makes it the install's most privileged database principal, and it wakes on a schedule. So
it is attached to no Container App and holds only `AcrPull` (through `acr_id`; grant `migrate_identity_principal_id`
out of band otherwise) and, with `enable_key_vault`, Key Vault Secrets User on each of the job's
vault-backed secrets and explicitly named per-Environment BYO-DB DSNs. It has no vault-scope, Officer or
crypto role, and no Service Bus, Redis or ACS access. The job carries its database URL (the migrate identity's role
on `"entra"`, `masterly_admin` on `"password"`), the direct URL with `postgres_pgbouncer`, how
to authenticate, and the CA bundle when one is set. Its secrets have their own names
(`migrate-database-url`, `migrate-database-direct-url`), which no Container App carries.

**The app roles.** On the starter server (not on BYO-DB, where the database is yours), the job
also creates two DML-only login roles, `masterly_api` for `ca-api` and `masterly_workers` for
`ca-workers`, and re-applies their grants on each run. It never alters a role that already exists.
The job carries `MASTERLY_MIGRATE_API_ROLE` and `MASTERLY_MIGRATE_WORKERS_ROLE` (the names), and
how each role signs in:

- on `database_auth = "entra"`, `MASTERLY_MIGRATE_API_ROLE_OBJECT_ID` (the `id-<prefix>-apps`
  object id) and `MASTERLY_MIGRATE_WORKERS_ROLE_OBJECT_ID` (the object id of `id-<prefix>-workers`,
  a new user-assigned identity for `ca-workers`'s role);
- on `"password"`, `MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF` and
  `MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF`: the names of two new vault secrets,
  `install-migrate-api-role-password` and `install-migrate-workers-role-password`, each holding a
  generated 32-character password. The job reads them with its own identity, which gets Key Vault
  Secrets User on each of those two secrets alone, never on the vault. They are no ACA secret on the
  job or any app, and are not in `vault_backed_secret_names`.

Each backend app signs in as its own role. `ca-api` stays on `id-<prefix>-apps` and reads
`api-database-url` (and `api-database-direct-url` with `postgres_pgbouncer`), whose user is
`masterly_api`. `ca-workers` runs as `id-<prefix>-workers`, with that identity's `AZURE_CLIENT_ID`,
Key Vault references and scale rule, and reads `workers-database-url` (and
`workers-database-direct-url`), whose user is `masterly_workers`. On `"entra"` these URLs carry no
password; on `"password"` each carries its own role's password, and only inside its own Key Vault
secret: never in env, an ACA value secret or an output. Neither app carries the other's URL, and
`ca-frontend` and `caj-migrate` carry neither. `id-<prefix>-workers` holds the backend grants
`ca-workers` needs (see [What the module creates](../README.md#what-the-module-creates)). These grants, its
Redis policy and the `workers-*` URL secrets exist only while `enable_workers` is on.

**Which identity `ca-workers` runs as.** Its Azure identity follows the vault, so a grant made for
it alone never reaches `ca-api`. Its database role follows the app roles above, which only `"job"`
on the starter server has. `ca-api` runs as `id-<prefix>-apps` on every shape:

| Install shape | `ca-workers` runs as | Its `AZURE_CLIENT_ID` | Its database URL |
|---|---|---|---|
| `"job"` on the starter server, `"entra"` or `"password"` | `id-<prefix>-workers` | That identity's | `workers-database-url`, as `masterly_workers` |
| `"start"` on `"password"`, with `enable_key_vault` | `id-<prefix>-workers` | That identity's | The shared `database-url`, through that identity |
| BYO-DB, `"start"` or `"job"`, with `enable_key_vault` | `id-<prefix>-workers` | That identity's | The shared `database-url`, through that identity |
| `"start"` on `"entra"` on the starter server | `id-<prefix>-apps`, unchanged | `id-<prefix>-apps`' | The shared `database-url`, whose user is that identity |
| `enable_key_vault = false` | `id-<prefix>-apps`, unchanged | `id-<prefix>-apps`', where the app sets one | The shared `database-url`, as a value secret |
| `enable_workers = false` | No `ca-workers`; `ca-api` runs the loop | — | — |

`"start"` on `"entra"` is unchanged because the shared URL's user there is the `id-<prefix>-apps`
role, and its token is minted for `AZURE_CLIENT_ID`. On every shape where `ca-workers` runs as
`id-<prefix>-workers`, that identity holds the backend grants it needs, and `id-<prefix>-apps` holds
no Service Bus Data Receiver and no jobs-queue Data Owner, which go with the move.
`workers_identity_principal_id` is set on exactly those shapes. On `"start"` and on BYO-DB
`id-<prefix>-workers` has no database role: it is an Azure identity only, and the shared URL's own
credential is what signs in to Postgres.

**What `id-<prefix>-apps` gives up** (ADR 0120 §6). With `"job"` on the starter server, `ca-api`'s
identity is no Postgres administrator and holds Service Bus send only. The module creates no
Entra administrator for it (on `"entra"`, `id-<prefix>-migrate` is the server's only one), and no
Service Bus Data Receiver or jobs-queue Data Owner for it: `ca-workers` receives and scales as
`id-<prefix>-workers`, which holds both. It keeps AcrPull, the app secrets role and Crypto
Officer on the vault, Service Bus Data Sender, ACS Email Owner and its Redis data access policy. The Receiver
and the queue's Data Owner go only where `ca-workers` runs as its own identity, so nothing that
still receives as `id-<prefix>-apps` loses them. Terraform removes the three only after it has
created the migrate administrator and updated `ca-api` and `ca-workers`: both apps depend on them,
and Terraform destroys a resource only after the resources that depend on it have been updated.
Outside `"job"` on the starter server the apps identity keeps its administrator (on `"entra"`), and
gives up the Receiver and the queue's Data Owner wherever `ca-workers` runs as its own identity.

Beyond that, the move is additive. `id-<prefix>-apps` keeps its other grants, and the shared
`database-url` (and `database-direct-url`) stays in the vault, so the revisions running before the
change keep working until their replacements are ready. `ca-api` also keeps its Container App
secret for it, resolved as `id-<prefix>-apps` as before: Container App secrets belong to the app,
not to a revision, and its old revision may restart or scale while the new one waits for the job.
No env of the new revisions names it. `ca-workers` keeps none: its identities belong to the app
too, so once it runs only as `id-<prefix>-workers` its old revision cannot sign in as before
whatever secrets stay. Removing the shared secrets is later work. Both backend
identities hold the app secrets role on the vault, so each can still read every vault secret,
the other app's URL and the role-password secrets among them; narrowing that is later work. The
passwords are generated once and never rotated by Terraform, because the job never changes an
existing role's password. **No released api image creates these roles.** The backend reads these
settings, and its migrate role creates the roles, only in a release later than v0.135.0
(`masterly-application-backend`: the `migrate_*_role` settings at commit `cf741e0e1fda`,
`core/settings.py`; the role creation at commit `462467d1`; neither is in a release tag yet).
The module does not check the image; confirm both in the api release's notes before your install
runs `"job"` on the starter server on this version (see the upgrade note below). The app roles,
and the apps signing in as them, are a minor release under ADR 0062: new resources, secrets, job env and one output (`workers_identity_principal_id`), no new
input, nothing renamed or removed. Removing the apps identity's administrator, Receiver and scaler
grant under `"job"` is a later minor release under ADR 0062 too: no input or output changes.
No app changes database role while `migrations` stays `"start"` or on BYO-DB.

**BYO-DB.** `external_database_admin_url` (sensitive, optional) is a DSN to your database for a
role allowed to migrate and create databases. It stays in the ACA job's own secret even with
`enable_key_vault`: no copy enters the shared install vault, and it gets no Key Vault grant.
`ca-api` and `ca-workers` keep `external_database_url`, so their role can be narrower. Unset, the
job uses `external_database_url`, with the usual vault reference. The plan refuses the admin URL
without `external_database_url` or `migrations = "job"`.

**Per-Environment BYO-DB connections.** The job uses `MASTERLY_SECRET_STORE=keyvault` and
`MASTERLY_KEYVAULT_URL` for the same vault as the API, with its own `AZURE_CLIENT_ID` even on
password database auth. Set `migrate_byo_database_secret_names` (default `[]`) to the existing
secret names from those Environments' sealed `connection_ref` values, then apply. Each gets
Key Vault Secrets User at that secret's ARM scope; Terraform never reads its value. List only
BYO-DB DSNs, never GitOps tokens or other runtime secrets; `install-*` names and paths are refused.
The module does not discover runtime secrets. A new or changed connection with a new secret name
needs an updated list and apply; remove obsolete names when no longer used. Allow RBAC propagation
before provisioning, retrying a failed provisioning run or starting the CD migration gate. An
unlisted connection cannot be migrated, even though the schedule continues to run.

**Upgrading to this version: `ca-workers` moves to `id-<prefix>-workers`.** A minor release under
ADR 0062: no input or output is added, renamed or removed, though
`workers_identity_principal_id` is now set on more shapes. On an install with the vault and
`ca-workers`, on `"start"` with `"password"` or on BYO-DB, upgrading creates `id-<prefix>-workers`
and its grants, moves `ca-workers` to that identity in a new revision, then removes the apps
identity's Service Bus Data Receiver and jobs-queue Data Owner. There is no input to defer it.
`"start"` on `"entra"`, an install with `enable_key_vault = false` and one with
`enable_workers = false` plan no change from it, and neither does `"job"` on the starter server,
which already runs this way.

- **`ca-workers`' old revision cannot sign in as before.** Identities belong to the app, not to a
  revision, so the update takes `id-<prefix>-apps` away from every revision of `ca-workers`.
  `ca-workers` has no probe, so its new revision replaces the old one at once; a stopping replica
  gets `workers_termination_grace_period_seconds` to finish its jobs.
- **With `acr_id` null, grant `AcrPull` to `workers_identity_principal_id` before applying**, or
  `ca-workers` cannot pull its new revision and stalls. The identity must exist first: follow the
  steps at the end of [Getting the images](../README.md#getting-the-images-adr-0067).
- **Allow for role propagation.** The new identity gets the app secrets role just before
  `ca-workers` is updated, and Azure RBAC propagation can delay its first Key Vault reference.
  The module adds no wait, as on the `"job"` path. If the new revision has not started once the
  apply is done, give the assignment time to propagate, then restart the revision.
- **Terraform orders the removals.** `ca-workers` depends on its new grants, so they exist before
  its update. In the released module it also depends on the Receiver and scaler grants it replaces
  (`depends_on` naming `azurerm_role_assignment.sb_receiver` and `sb_scaler`, `workers.tf:189-190`).
  Terraform records that dependency in state, and destroys a removed resource only after the
  resources recorded as depending on it have been updated, so the two grants go after
  `ca-workers`' update. This release keeps both edges. Terraform waits for the update, not for
  the new revision to be running: until that revision runs, no replica takes jobs, and jobs wait
  for it.

**Turning the job on.** Upgrading changes nothing about the job while `migrations` stays `"start"`.
`"job"` needs an api image from a backend release later than
v0.135.0 that has the migrate entry point (`masterly_app.apps.migrate`), honours
`MASTERLY_MIGRATIONS=job`, picks up pending provisioning runs on each migrate run, and serialises
overlapping runs. On the starter server it must also create the app roles `masterly_api` and
`masterly_workers` (see the apps' move below); no released image does yet. The module does not
check the image for them, so confirm them in the api release's notes. With an older image the job
fails. A qualifying image, below, is one with all of these. The order:

1. **Roll a qualifying image first, with your CD**, onto `ca-api` and `ca-workers`, the way you
   roll any release. The apply below does not change their image: it adds
   `MASTERLY_MIGRATIONS=job` to the image they already run, as a new revision.
2. **Apply with `migrations = "job"`**, and `api_image` set to that same image. The apply creates
   the job on it and starts one execution before it updates `ca-api` and `ca-workers` to job mode.
   This start is asynchronous; the apps' readiness still depends on migration completion.
3. **From then on, roll every release through CD in the order above** (the job, wait for
   `Succeeded`, then the apps). Keep `api_image` at the digest your install runs, as for the
   apps: it seeds the job if it is ever recreated.

**The apps' move to their own roles** (starter server only). The same apply, or the upgrade of an
install already on `"job"`, moves `ca-api` and `ca-workers` to `masterly_api` and
`masterly_workers` and `ca-workers` to `id-<prefix>-workers`. The shared URL stays, so the
running revisions keep it until they are replaced; the apps identity's administrator, Receiver
and scaler grant do not (see "Removing the apps identity's administrator" below). There is no input to defer
the move: on this version, `"job"` on the starter server always moves both apps.

- **The api image must create `masterly_api` and `masterly_workers`.** No released image does (none
  up to v0.135.0). An image with the migrate entry point but without the role creation runs the
  job, yet neither role ever exists: `ca-api`'s new revision never becomes ready, and `ca-workers`
  restarts without end. The module does not check the image. Keep `migrations = "start"`, and do
  not upgrade an install already on `"job"` to this version, until it runs a backend release whose
  notes name the app-role creation. The readiness below assumes such an image.
- **With `acr_id` null, grant `AcrPull` to `workers_identity_principal_id` before applying** (see
  [Getting the images](../README.md#getting-the-images-adr-0067)), or `ca-workers` cannot pull its new
  revision and stalls.
- **`ca-api`'s new revision becomes ready once the job has created `masterly_api`**; until then
  it cannot sign in and does not become ready, and on an existing install the old revision keeps
  serving.
- **`ca-workers` has no probe**, so its new revision replaces the old one at once and restarts
  until the job has created `masterly_workers`. The apply starts the job but does not wait for it
  to finish, so expect those restarts for the length of the first execution.

On an existing `database_auth = "entra"` install, every object in the databases is owned by
`id-<prefix>-apps`. An Entra administrator is not a superuser, so the first migration as
`id-<prefix>-migrate` fails unless the image's migrate role first takes ownership or membership
of those objects; the qualifying image is required to do that too.

**Removing the apps identity's administrator** (`"entra"` on the starter server). Under `"job"`
the module removes `id-<prefix>-apps`' Entra administrator, Service Bus Receiver and jobs-queue
Data Owner. Terraform orders those removals after the migrate administrator and both apps'
updates, but an updated app is not yet a ready one: once the administrator is gone, a revision
still signing in as `id-<prefix>-apps` loses database access. On an install already on `"job"`:

1. **Be on module 0.23.x with `migrations = "job"`**, on a qualifying image.
2. **Confirm** that a `caj-migrate` execution has `Succeeded`, and that `ca-api` and `ca-workers`
   run revisions signed in as `masterly_api` and `masterly_workers` (`ca-api` ready, `ca-workers`
   no longer restarting).
3. **Then upgrade** to the version that removes them; the plan shows the administrator,
   `sb_receiver` and `sb_scaler` destroyed, and nothing else replaced.

An install moving from `"start"` straight to `"job"` on that version does all of it in one apply:
the migrate administrator, the start action, the apps' move and then the removals. Its old
revisions keep serving only until the administrator is removed, so plan that apply for a quiet
period. What Azure does to the `id-<prefix>-apps` database role, which still owns the objects,
when its administrator is removed has not yet been confirmed on a live install: 0.24.0 was
released with that check still owed ([docs/releasing.md](releasing.md), "Live checks before
the next tag").

### Moving an existing install to Microsoft Entra authentication

An install created before this default authenticates with the `masterly_admin` password and
the Redis access key. In `mode = "production"`, its plan stops until you choose. Every change
below is made in place; none of them replaces the server or the cache.

1. **Keep the install as it is while you prepare.** Set `database_auth = "password"` and
   `redis_auth = "key"`, and apply. Only the `masterly-auth` tags change.
2. **Run api images `v0.133.7` or later** on `ca-api` and `ca-workers`. This module does not
   change a running app's image; your deployment does. An older image cannot authenticate
   with a token, and would lose both stores at the next step.
3. **Redis.** Set `redis_auth = "entra"` and apply. The access policy is assigned, access keys
   are turned off, and the apps roll a new revision with a keyless URL. Sign-ins can fail for
   the moment between the keys going off and the new revision becoming ready; sessions
   already in Redis are kept.
4. **Postgres ownership.** Every table, sequence and Environment database on the server is
   owned by `masterly_admin`, and the apps' Entra identity cannot use them until ownership has
   moved. While password authentication is still on, connect as `masterly_admin` from a host
   that can reach the server's private endpoint — the password is in the `database-url` secret,
   and in your Terraform state as `random_password.postgres_admin` — and run, in the `postgres`
   database:

   ```sql
   CREATE ROLE masterly_owner NOLOGIN;
   GRANT masterly_owner TO masterly_admin WITH INHERIT TRUE, SET TRUE;
   GRANT masterly_owner TO azure_pg_admin WITH INHERIT TRUE, SET TRUE;
   REASSIGN OWNED BY masterly_admin TO masterly_owner;
   ```

   Then, in each Environment database (`SELECT datname FROM pg_database WHERE datname LIKE
   'masterly\_dp\_%';` lists them):

   ```sql
   REASSIGN OWNED BY masterly_admin TO masterly_owner;
   ```

   Ownership now sits with `masterly_owner`, a group role. Every Microsoft Entra administrator
   of the server is a member of `azure_pg_admin`, so the apps' identity inherits ownership the
   moment the next step makes it one; `masterly_admin` stays a member too. Run this when nobody
   is creating an Environment, or run the `REASSIGN` again afterwards — it is safe to repeat.
5. **Switch.** Set `database_auth = "entra"` and apply. Microsoft Entra authentication is
   turned on and password authentication off, the apps' identity becomes the server's Entra
   administrator, and the apps roll a new revision whose connection string names that role.
   The plan shows no change to the administrator password: the server keeps it, unused.
   Check that `/readyz` answers and that you can sign in.

To go back, set `database_auth = "password"` (or `redis_auth = "key"`) and apply: password
authentication or the access key is turned back on, and `masterly_admin` still holds
ownership through `masterly_owner`.

### Trusting a private CA

The allowlist above says **where** the application may connect. It says nothing about whether it
**trusts** what answers there — a TLS handshake, STARTTLS included, verifies the peer's
certificate, and a relay, stream push endpoint or local AI endpoint on your own network commonly
presents one from an internal CA rather than a public one. Set `ca_bundle_pem` to your CA
certificate(s) — just your own internal CA(s), PEM-encoded and concatenated if there is more
than one — and the module mounts a bundle into `ca-api` and `ca-workers` and points
`SSL_CERT_FILE` at it — OpenSSL's default-verify-paths mechanism, which every outbound TLS
connection those two apps make reads, not only the one target that needed it. That includes
`httpx` (stream push, telemetry, licence refresh, the AI router): it reads `SSL_CERT_FILE`
itself when set, the same as the standard-library `ssl` module SMTP delivery uses, so one file
covers both.

**The mounted file is your bundle *added to* the image's own trust store, not a replacement for
it.** The module writes the image's public roots
(`/etc/ssl/certs/ca-certificates.crt`, the Debian base image's bundle) into the file first and
your `ca_bundle_pem` content after — you do not concatenate anything yourself. Because of that,
`ca_bundle_pem` should carry only what it says: your own internal CA(s), typically a kilobyte or
two, never a copy of the image's bundle. Keeping it that small also matters mechanically —
`enable_key_vault` is required in `mode=production`, and Azure's documented maximum Key Vault
secret value is 25 KB, well under which your CA(s) sit but the ~230 KB image bundle alone would
not.

Null (the default) sets nothing: outbound TLS verifies against the image's own trust store
exactly as it did before this input existed. The module refuses an empty or all-whitespace
value at plan (an empty trust store, not a smaller one) and a value that does not contain a
`-----BEGIN CERTIFICATE-----` marker (almost certainly the wrong file mounted at the wrong
path, caught before the apply rather than after).

There is no `azurerm_container_app` volume type backed by a Container App secret — only
`AzureFile` and `EmptyDir` — so the module cannot simply declare the bundle as a file the way it
declares `MASTERLY_DATABASE_URL` as an environment variable. What it does instead: an `EmptyDir`
volume, mounted on both `ca-api`/`ca-workers` and on a short-lived **init container** (the app's
own image, so nothing new is pulled) that writes the image's own CA bundle followed by your
`ca_bundle_pem` content into it, from the Container App secret, before the real container
starts, on every replica start. With `enable_key_vault` the secret is a versionless Key Vault
reference like the install's other secrets, so rotating the certificate in the vault reaches it
the same way — ACA re-resolves within 30 minutes and restarts active revisions, which reruns the
init container too.

`mode=production` refuses dev-grade defaults on the **provisioned starter server** (the
module's plan-time-guardrail philosophy — a misconfigured production install fails in
`terraform plan`, not in a crash loop or a 2 a.m. page). It requires a non-burstable
`postgres_sku_name` (General Purpose `GP_*` / Memory Optimized `MO_*`),
`postgres_zone_redundant_ha = true`, and `postgres_backup_retention_days >= 14`. These
guards **do not apply when you bring your own database** (`external_database_url`) — your
database's SKU, HA, and retention are yours. Production likewise requires
`enable_workers = true` (the pipeline runs in `ca-workers`, not in-process) and
`api_max_replicas >= 2` (no single-replica production api; `enable_redis` is already
required, so the multi-replica session registry is available).
