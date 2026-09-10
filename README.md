# terraform-azurerm-masterly

The Terraform module for a **self-hosted [Masterly](https://masterlydata.com) install** on Azure.
One module = one region-pinned install: the ACA environment, the `api` and `frontend` Container
Apps (the same images every deployment model runs), and the data plane — either your own Postgres
(BYO-DB) or a provisioned starter server, on which the api creates one database per Masterly
Environment at first touch.

Published on the [Terraform Registry](https://registry.terraform.io/modules/masterly-data/masterly/azurerm):

```hcl
module "masterly" {
  source  = "masterly-data/masterly/azurerm"
  version = "~> 0.15"
}
```

Pin a version — a `~>` constraint takes patches within a minor, `=` pins one release
exactly. Sourcing straight from GitHub also works
(`github.com/masterly-data/terraform-azurerm-masterly?ref=v<version>`) and is what air-gapped
mirrors do, but the registry gives you version constraints and needs no `git` on the runner.
Which version is current, and which images go with it, is [`MANIFEST.json`](MANIFEST.json) —
see [Versioning](#versioning).

No credential is needed to fetch this module. Running Masterly does need two things it does not
contain: the **container images**, pulled with the registry credential in your install bundle, and
a **signed licence**. Both arrive from Masterly. Air-gapped installs use the module tarball from
the same bundle.

The customer-facing walkthrough — prerequisites, the two-pass apply, upgrades and rollback — is at
**[masterlydata.com/docs/self-hosted](https://masterlydata.com/docs/self-hosted/install/)**. Start
there; this README documents the module surface.


## Network topologies

The module serves three from one artifact, and the default needs nothing set:

| | Reached from | Set |
|---|---|---|
| Public ingress (default) | the internet, narrowed by `ingress_allowed_cidrs` | nothing |
| Private ingress | VPN / ExpressRoute only | `aca_internal_load_balancer = true` |
| Hub-and-spoke | whatever the spoke allows | `aca_subnet_id` + `private_endpoints_subnet_id` |

The last two compose. Subnet requirements, centralised private DNS, egress, and what upgrading
an existing install does are in [docs/networking.md](docs/networking.md).

## Usage

```hcl
module "masterly" {
  source  = "masterly-data/masterly/azurerm"
  version = "~> 0.15"

  # Production posture (ADR 0066): the app refuses fixture seams; the module refuses the
  # combination at plan time unless everything below is wired.
  mode = "production"

  location            = "swedencentral"
  org_id              = "org_acme"        # your Organization id (ADR 0039; must match the license sub claim)
  org_name            = "Acme Industries"
  install_id          = "prod"            # this Install's slug within the Org
  # allowed_regions is deliberately unset: it defaults to this install's own geo, which is
  # the only geo a single data plane can hold. The module refuses at plan an install whose
  # declared geo contradicts its Azure location, or that permits a geo it cannot honour.
  initial_owner_email = "mdm-owner@acme.example" # one-shot Owner bootstrap on first OIDC sign-in
  # The pair this module version was released against, from MANIFEST.json (see Versioning).
  # Two floors sit below it: an api older than v0.132.2 registers no job handlers on
  # ca-workers, silently, and a frontend older than v0.138.2 leaves a fresh install unable to
  # create its first Environment. api v0.133.1 has no published image.
  api_image           = "masterly.azurecr.io/api:v0.133.2"
  frontend_image      = "masterly.azurecr.io/frontend:v0.138.2"

  # Durable seams (required for production): sealed secrets + multi-replica sessions +
  # the dedicated pipeline workers.
  enable_key_vault = true
  # The vault is private-endpoint-only in production, and Terraform still has to write the
  # install's secrets into it. Say how it gets there: the apply runner's egress address, or
  # key_vault_deployer_in_vnet = true if the apply already runs inside the VNet. Production
  # refuses to plan with neither. See "Key Vault-backed app secrets".
  key_vault_deployer_ip_rules = ["203.0.113.7"]
  enable_redis     = true
  # No default: "managed" = Azure Managed Redis (works for every tenant); "cache" only if
  # you already run an Azure Cache for Redis instance. See the Redis row below.
  # "managed" for a new install. An install ALREADY running Azure Cache for Redis must
  # set "cache" instead — copying this line onto one plans a destroy of its session store.
  redis_offering   = "managed"
  enable_workers   = true
  api_max_replicas = 3

  # Identity (ADR 0024): your own OIDC IdP — Entra, Okta, Keycloak, …
  identity_binding     = "oidc"
  oidc_allowed_issuers = "https://login.microsoftonline.com/<tenant_id>/v2.0"
  # The SAME value as oidc_client_id below, not a second registration: the api verifies the ID
  # token the frontend BFF obtained, and that token's aud is by construction the BFF's own
  # client id. Registering a separate "api" app and naming it here fails at first sign-in.
  oidc_audience        = "<bff client id>"
  oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
  oidc_client_id       = "<bff client id>"
  oidc_client_secret   = var.oidc_client_secret # from your secret store
  oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
  oidc_redirect_uri    = "https://<frontend host>/api/auth/callback"

  # License (ADR 0013): from your install bundle.
  license_token      = var.license_token # from your secret store
  license_public_jwk = file("license-issuer.jwk.json")

  # Fleet telemetry (optional, from the same bundle): usage ledger + an install snapshot
  # (version, health, counts) to Masterly's control plane. Leave all three unset to report
  # nothing; set them together — a partial set is refused at plan. Never billing input.
  # telemetry_url           = "<control-plane URL from your install bundle>"
  # telemetry_client_id     = var.telemetry_client_id
  # telemetry_client_secret = var.telemetry_client_secret # from your secret store

  # Licence refresh (optional, same credential): the install re-fetches its licence from
  # Masterly daily and re-verifies it before adopting it. Leave unset on an offline
  # install — no outbound call is made. Requires all THREE telemetry inputs above
  # (telemetry_url included — refresh authenticates as that same install service account),
  # so an install that refreshes its licence also reports usage hourly.
  # license_issuer_url      = "<licence refresh URL from your install bundle>"

  # BYO-DB (ADR 0065): your own Postgres. Omit to provision the starter server instead.
  external_database_url = var.masterly_database_url # from your secret store

  # Images (ADR 0067) — pick ONE:
  # Option 1, direct pull from Masterly's registry with the service principal from
  # your install bundle:
  registry_username = var.masterly_pull_appid  # from the bundle
  registry_password = var.masterly_pull_secret # from your secret store
  # Option 2, your own ACR: `az acr import` the pinned tags with the same credential,
  # then point acr_login_server at your registry and set acr_id so the module grants
  # AcrPull to both install identities (managed-identity pull, no credential in the app):
  # acr_login_server = "acme.azurecr.io"
  # acr_id           = "/subscriptions/.../registries/acme"

  tags = {
    cost-center      = "…"
    data-residency   = "eu"
    deployment-model = "self-hosted"
    owner            = "…"
    lifecycle        = "prod"
  }
}
```

Outputs include `frontend_url`, the apps resource group, the Container App names (the
values the app repos' release workflows use to roll images — `DEMO_RG`, `DEMO_APP_API`,
`DEMO_APP_FRONTEND` in the demo case), and `apps_identity_principal_id` /
`apps_identity_client_id` / `frontend_identity_principal_id` for out-of-band role grants.
The install runs on **two** app identities (see below), so an out-of-band `AcrPull` grant
has to reach both principals.

## Preflight

`scripts/preflight.sh` reads a target subscription and reports what a first apply needs:
resource-provider registration, the deploying identity's two roles, PostgreSQL SKU
availability, and — in production — whether the tenant can still create an Azure Cache for
Redis. It is read-only unless you pass `--register`.

```bash
./scripts/preflight.sh --subscription <id> --location swedencentral --mode production \
  --principal <object id of the identity terraform runs as>
```

Every check is initialised to its failure value and only cleared by a command that
succeeds, so an `az` error or a denied permission reports as a failure rather than a pass.

Three things it cannot check and prints as MANUAL: PostgreSQL vCore quota, zone-redundant
HA availability, and Container Apps environment cores (that quota is scoped to an
environment that does not exist until the first apply). All three are support tickets when
they bite, so confirm them before you plan.

## What the module creates

| Resource | Purpose |
|---|---|
| `rg-masterly-aca`, `rg-masterly-data` | Customer-naming resource groups (`rg-masterly-<purpose>`) |
| VNet + runtime subnet (/23) + private-endpoints subnet | The install's network; ACA is VNet-integrated |
| Log Analytics + ACA environment (`aca-masterly`) | The runtime |
| `id-masterly-apps` UAMI (+ optional AcrPull) | The **backend** apps' identity (`ca-api`, `ca-workers`): image pull, plus every data-plane grant the install makes — Key Vault Secrets Officer, Service Bus send + receive, ACS Email Owner. Later install identity work (ADR 0020) |
| `id-masterly-frontend` UAMI (+ optional AcrPull) | The **frontend's** identity. Image pull and nothing else: `ca-frontend` is the only internet-facing app and needs no data-plane access, so it does not carry the backend's grants |
| Postgres Flexible Server (`psql-masterly-<suffix>`) — **starter data plane, skipped on BYO-DB** | Private-endpoint-only; per-Environment databases are created on it by the api |
| `ca-api` (internal ingress, :8001) | The product API; probes `/healthz` + `/readyz`; secrets (DSN, session secret, license, …) reach it as Container App secrets — **Key Vault references** when `enable_key_vault`, values otherwise. Internal by default; `api_ingress_external = true` publishes it behind `ingress_allowed_cidrs` and makes it HTTPS-only (see [Transport security](#transport-security)) |
| `ca-frontend` (public ingress, :3000) | The GUI/BFF; on `oidc` it runs the authorization-code + PKCE dance against your IdP. Readiness (`/api/readyz`) gates traffic on the frontend's own runtime config resolving **and** the api answering, so a misconfigured revision never takes traffic |
| Service Bus namespace + queue (opt-in, ADR 0029) | The `servicebus` bus binding; default is the broker-less polling binding |
| ACS email (opt-in, ADR 0040) | Customer-owned email; endpoint + sender auto-wired into the api |
| Key Vault (opt-in, ADR 0066) | The durable secret store (`enable_key_vault`): sealed BYO-DB DSNs and GitOps tokens survive restarts; RBAC-mode vault, Secrets Officer grant to the apps identity, `MASTERLY_SECRET_STORE=keyvault` auto-wired. It is also where **the install's own secrets** live — with the vault on, the apps hold Key Vault *references*, not values (see below). Soft-delete always on; in `mode=production` purge protection is armed and the vault is reached over a **private endpoint** (`privatelink.vaultcore.azure.net`) with **default-deny** network ACLs. Required for `mode=production`. |
| Redis (opt-in, ADR 0066 + ADR 0071) | The multi-replica session registry (`MASTERLY_SESSION_REGISTRY=redis`; the keyed URL rides as a Container App secret). `enable_redis = true` also requires **`redis_offering`**, which has no default: `"managed"` = **Azure Managed Redis** (`Microsoft.Cache/redisEnterprise`, `Balanced_B0` by default, private DNS zone `privatelink.redis.azure.net`) — creatable by any tenant, and the only choice that works if your organization has never run an Azure Cache for Redis instance; `"cache"` = **Azure Cache for Redis** (`Microsoft.Cache/redis`, Basic/Standard/Premium, zone `privatelink.redis.cache.windows.net`) — creation blocked for new customers since 1 April 2026, retired 30 September 2028, kept only so an existing instance is not destroyed. Either way: **public network access disabled**, reachable only via a **private endpoint** mirroring the starter Postgres. Unlocks `api_max_replicas > 1`. Budget tens of minutes for the first apply — Azure-side provisioning dominates. |
| `ca-workers` (opt-in, ADR 0066) | The dedicated async-pipeline loop (`enable_workers`): same image, command `python -m masterly_app.workers`, no ingress; the api flips to `MASTERLY_INPROCESS_WORKER=false`. |

## Getting the images (ADR 0067)

Masterly issues each customer a **pull service principal** (appId + client secret, in the
install bundle, `AcrPull` only). Two ways to consume it:

1. **Direct pull** — set `registry_username`/`registry_password`; every app pulls straight
   from `masterly.azurecr.io` (the secret rides as a Container App secret). Lowest
   friction; note that NEW revisions and scale-out pulls depend on Masterly's registry
   being reachable (running replicas are unaffected).
2. **Mirror into your own ACR** — `az acr import --name <yours> --source
   masterly.azurecr.io/api:vX.Y.Z --username <appId> --password <secret>` per image, then
   `acr_login_server`/`acr_id` at your registry: managed-identity pull, no Masterly
   credential in the install. Recommended for regulated environments; required for air gap
   (with an offline image bundle instead of the import). `acr_id` grants `AcrPull` to both
   app identities; if you leave it null and grant out of band, grant both
   `apps_identity_principal_id` and `frontend_identity_principal_id` — miss the second and
   the frontend cannot pull.

Rotation: the SP carries up to two active secrets — switch `registry_password` to the new
one and apply.

## Identity (ADR 0024)

`identity_binding` selects the adapter:

- **`oidc`** — production: your own IdP. The backend verifies tokens against
  `oidc_allowed_issuers`/`oidc_audience`/`oidc_jwks_uri`; the frontend BFF is the
  confidential client (`oidc_client_id`/`oidc_client_secret`/`oidc_authority`/
  `oidc_redirect_uri`). Optional break-glass local Owner via
  `breakglass_owner_email` + `breakglass_secret_hash` (sha256, never the secret).

  `oidc_allowed_issuers` normally holds **one** entry — this install's own issuer. Every
  issuer listed here is trusted **install-wide**, so it is not the way to onboard an
  additional organization onto one install: register an org-scoped SSO connection in the
  product instead, which is bound to the Organizations that registered it.
- **`dev`** — evaluation only. The module **refuses** `dev` with an open ingress:
  set `ingress_allowed_cidrs` (an IP allowlist) or switch to `oidc`.

Without a custom domain the frontend FQDN is only known after the first apply, so the
OIDC bootstrap is: apply with `identity_binding=dev` + your IP allowlist, read
`frontend_url`, register `https://<frontend host>/api/auth/callback` at your IdP, then
flip to `oidc` and re-apply.

## Data plane (ADR 0065)

Self-hosted is the `self-hosted × byo-db` combination: production installs point
`external_database_url` at their own Postgres (Azure Flexible PG, Databricks Lakebase,
AWS Aurora PG, Cosmos for PG). The DSN is the install-level connection
(`postgresql+asyncpg://…`; the role needs `CREATEDB` — the api creates
`masterly_dp_<environment>` databases at first touch). Reachability of your database
from the install's VNet is your side: peering, a private endpoint into
`snet-private-endpoints`, or your hub.

Omit `external_database_url` and the module provisions the **starter server** instead —
private-endpoint-only Postgres Flexible, right for evaluations and the demo. Its knobs:
`postgres_sku_name`, `postgres_storage_mb`, `postgres_version`,
`postgres_backup_retention_days`, `postgres_geo_redundant_backup` (mind data residency —
backups go to the paired region), `postgres_zone_redundant_ha` (needs a non-burstable
SKU). Flipping an install from starter to BYO-DB **plans the destruction of the starter
server** — migrate your data first; the plan makes it visible.

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

## Networking

The install runs in its own VNet: the ACA environment is VNet-integrated (runtime subnet,
/23 — an ACA consumption requirement) and the provisioned Postgres is reachable **only via
a private endpoint**; private DNS keeps the server FQDN unchanged for the apps. The
frontend stays the single public surface, behind the optional ingress IP allowlist.

Landing-zone accommodations:

- A first VNet prefix of /21 or larger derives the subnets automatically; a smaller
  allocation sets `aca_subnet_prefix` + `private_endpoints_subnet_prefix` explicitly.
- Hub-and-spoke shops that centralize private DNS pass
  `postgres_private_dns_zone_id` — the module then creates no zone and no VNet link
  (linking the central zone to this VNet is the platform team's side).

> Upgrading from v0.1: `infrastructure_subnet_id` is create-time-only, so the apply
> REPLACES the Container App Environment and the apps — their FQDNs change. The Postgres
> server (and its data) is untouched.

### Transport security

Everything published by the install is HTTPS-only. `ca-frontend` always redirects `http://`
to `https://`, and `ca-api` does the same **as soon as `api_ingress_external = true`** — a
published api trusts a bearer token and nothing else, so serving it on port 80 would put
the whole credential on the wire for anyone in the path. An IP allowlist bounds who can
reach an endpoint; it says nothing about what a network in between can read.

While the api stays internal (the default) it keeps serving plain HTTP, because the only
thing calling it is the frontend's BFF at `http://ca-api` — an app-name address, which is
the one form that cannot drift, and which no TLS certificate can match. That hop is not
left in the clear: the Container Apps environment runs with **peer-to-peer encryption**
on, so Azure encrypts traffic between apps inside the environment with certificates it
manages and rotates. Applications keep speaking `http://` and the platform encrypts
underneath — this is Azure's `peerTrafficConfiguration.encryption`, and it is what makes
the internal `allowInsecure` acceptable rather than merely convenient.

Verify it on a running install:

```bash
az containerapp env show -n aca-masterly -g rg-masterly-aca \
  --query properties.peerTrafficConfiguration.encryption.enabled
```

Check it after an out-of-band change rather than relying on `terraform plan`: the provider
writes both of Azure's peer settings from one input but refreshes state from only one of
them, so a console or CLI change to peer-traffic encryption alone shows up as no drift.

Microsoft notes that peer-to-peer encryption may add response latency and lower maximum
throughput under high load. The module deliberately exposes no input to turn it off: the
hop it protects is the one carrying every authenticated request in the install, and a knob
that quietly trades that away is worth less than the throughput it buys back. If you
measure a real problem, open an issue with the numbers rather than reaching for `az` — an
out-of-band change to peer-traffic encryption is invisible to `terraform plan` (above),
which makes it exactly the kind of setting that stops being true without anyone noticing.

## Scaling

`ca-api` defaults to a **single replica** — with the in-memory session registry a second
replica would drop sessions. `enable_redis` switches sessions to the redis registry and
unlocks `api_max_replicas > 1` (the module refuses the combination scale-out-without-Redis
at plan time). `enable_workers` moves the async-pipeline loop to its own `ca-workers` app;
extra workers replicas add throughput across Environments (the per-Environment drain is
advisory-locked), not duplicate work.

**Scale-to-zero** (`api_min_replicas = 0` / `frontend_min_replicas = 0`) is the idle-cost
posture for evaluation installs (the demo runs it): Container Apps stops the replicas when
idle and the default HTTP scale rule wakes them on the next request. The costs: cold-start
latency on the first request, in-memory sessions drop when the last api replica stops
(unless `enable_redis`), and the api's in-process worker loop only polls while a replica is
up — async jobs stall until the next request. Refused in `mode=production`. The workers
floor (`workers_min_replicas`) stays >= 1 by design: nothing HTTP-wakes an ingress-less
polling loop.

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

## Diagnostics + alerts

In `mode=production` the module wires the data-plane resources' diagnostic settings and a
minimal metric-alert set to the install's Log Analytics workspace (on by default; set
`enable_diagnostics = false` to opt out, or `true` to enable outside production):

- **Diagnostic settings** (resource logs + `AllMetrics` → the workspace) for the provisioned
  Postgres, Redis, Key Vault, and Service Bus (each only when that resource exists). On
  `redis_offering = "managed"` this is two settings, not one: metrics are cluster-level but
  the connection log lives on the `redisEnterprise/databases` child.
- **Saturation alerts** — the install is under strain. Postgres storage nearly full, B-series
  CPU-credit exhaustion (burstable installs only), Redis memory nearly full, Redis key evictions
  (which under the no-eviction policy mean the policy has been changed out from under the
  install, not that the cache is small), and `ca-api` / `ca-frontend` 5xx. Severity 1–2.
- **Availability alerts** — something has stopped rather than strained: the install is not
  serving, or the async pipeline behind it is not running. Severity 0 on all of them, so a
  notification tells you which of the two states you are in without opening the portal; the
  alert's own description says what stopped, because a dead `ca-workers` leaves the install
  answering every request perfectly while no job in it makes progress.

Alerts fire and record with no notification target; to be paged, set `alert_email` (the
module creates an action group) or point `alert_action_group_id` at an existing group
(a shared ops group, a PagerDuty webhook group).

### What the alerts detect, and what they do not

Every saturation alert needs the resource running, publishing metrics, and taking traffic. That
is the right shape for "under strain" and the wrong shape for "gone": a stopped database
publishes no storage figure, an app that hangs returns no 5xx, and an idle scale-to-zero install
reports no requests at all. The availability alerts exist to close that, and it is worth being
precise about how far they reach.

| Failure mode | Detected by | Notes |
|---|---|---|
| Database reports itself down | `postgres-unavailable` | Reads the platform's own `is_db_alive`. Fastest signal here: 5-minute window. |
| Database stopped, deleted, or its telemetry broke | `postgres-silent` | Fires on the **absence** of metrics — the case a metric alert cannot see, because a metric alert with no data does not fire. ~40 minutes to page, deliberately. On a brand-new install it can fire once before the first metrics land; it clears itself when they do. |
| An app has no running replica | `<app>-unavailable` | One per Container App the install runs — `api`, `frontend` and, with `enable_workers`, `workers`. Only created for an app whose `min_replicas` is 1 or more. Counts replicas, not readiness — see the first "not detected" entry below. |
| The async pipeline has no worker running | `workers-unavailable` | The same alert, and the one nothing else in the set can stand in for: `ca-workers` has no ingress, so it emits no requests and `<app>-5xx` is blind to it by construction. Without this, a dead workers app is silent — the install keeps answering, the queue keeps growing, and the first signal is somebody asking why yesterday's ingest never landed. |
| Storage, memory, CPU credits, evictions, 5xx | the saturation alerts | Need the resource up and, for 5xx, traffic flowing. |

Not detected, and no alert here should be read as covering it:

- **An app that is running but never becomes ready.** This is the widest gap in the set, and the
  one to plan around. A replica that starts, fails its readiness probe, and is therefore never
  routed to still counts toward `Replicas` — so on an install with a replica floor,
  `<app>-unavailable` reads a healthy 1 while the install serves nothing. `<app>-5xx` does not
  cover it either: it needs more than five requests in its window, and an install nobody can
  reach receives none. A synthetic check against the install's own URL, run from wherever you
  already monitor, is what closes this; the module ships none, for the reason in the next entry.
- **A workers app that is running but wedged.** The same shape, one layer down and with no
  synthetic check available: a `ca-workers` replica that is up but whose consume loop is stuck
  still counts toward `Replicas`, so `workers-unavailable` reads 1. What the module can see is
  that the app is *there*; whether it is *draining* lives in the install's own job tables, which
  the module provisions and never reads. Alert on queue depth or on the age of the oldest
  unclaimed job from the application side if you need that, and keep this alert for the case it
  does cover — the workers app being gone.
- **A BYO-DB install's database.** With `external_database_url` set, the module wires no
  diagnostic setting to a server it does not own, so it has no telemetry stream whose end it
  could notice. Alert on your own database from wherever it runs.
- **An app that is up, answering, and wrong.** Replicas running and no 5xx is the shape of a
  healthy app and also of one serving stale or empty data. Nothing in the module probes the
  application's `/readyz` from outside — that is a synthetic check, and the module deliberately
  ships none, because on the private-ingress and injected-network topologies there is no vantage
  point it could run from without assuming a network it does not own.
- **An app on a scale-to-zero install.** With `min_replicas = 0`, zero replicas is the intended
  state, so no replica alert is created for that app. This is an evaluation cost posture;
  `mode = "production"` requires a floor of at least one replica on both apps.
- **Anything, on an install with no notification target.** Alerts still fire and record, but
  nobody is told. Set `alert_email` or `alert_action_group_id`.
- **Anything, on an install with `enable_diagnostics = false`** — the default outside
  `mode = "production"`.

## If you front this install with a WAF, CDN, or gateway

Masterly addresses **name things, they never quote them** — no customer value, filter, or
search term appears in a URL, and a read whose question holds master data is a `POST`
([ADR 0069](https://github.com/masterly-data/masterly-framework/blob/main/docs/adr/0069-addresses-carry-names-not-values.md)).
That guarantee holds for what this module deploys: Container Apps sends the containers' own
logs to your Log Analytics workspace, and the application logs the **route template**, never
the query string.

The module provisions **no Front Door, Application Gateway, or WAF**, so there is nothing here
to configure. If you put one in front of the install, the guarantee becomes partly yours:

- **Do not enable full-URL or request-body logging** on the data-plane routes (`/v1/*`). A
  `POST` body carrying a search term is the thing the address rule moved it into; logging
  bodies puts it back, in a store outside the Environment.
- **Keep any log retention inside the same region** as the Environment. A gateway that ships
  logs to another geography reopens the residency question this design closes.
- **Do not add a `Referrer-Policy` weaker than the app's.** The application sets
  `same-origin`; a proxy that overrides it to `unsafe-url` would send the full address —
  including a `?view=vw_…` reference — to every third-party host a page touches.

None of this is Terraform we can write for you, because the fronting layer is yours. It is
listed here so the decision is visible at the point where it becomes yours to keep.

## Key Vault-backed app secrets

A **value-based** Container App secret is stored in the app itself, and anything holding
`Microsoft.App/containerApps/listSecrets/action` — which plain **Contributor** on the resource
group has — can read it back in clear. That covers the DSN, the session secret, the licence
JWT, the OIDC client secret, the Redis URL (access key and all), the registry password and the
telemetry secret. Deploy rights and read-every-credential rights were the same thing.

With `enable_key_vault = true` they stop being the same thing. The module writes each secret
into the install's vault as `install-<name>` and gives the apps a **reference**: the value is
resolved by the apps' managed identity, `listSecrets` returns the vault URL instead of the
material, and reading it needs a Key Vault RBAC grant that Contributor does not carry — with
an audit trail per read. With `enable_key_vault = false` (dev/demo, no vault to put them in)
the apps carry values exactly as before.

The references are **versionless**, so the vault is genuinely the one place to rotate: change
a secret there and Container Apps picks it up within 30 minutes, restarting the active
revisions. No `terraform apply` in the loop.

Container Apps resolves those references against a vault with **`publicNetworkAccess` disabled**
— verified on Azure with the vault in exactly this module's production shape (RBAC, default-deny
ACLs, private endpoint, private DNS): a forced revision provisioned `Healthy` with no
provisioning error, while a caller outside the VNet was refused by the same vault in the same
minute. The app's path in and yours are not the same path, which is the entire point.

### Terraform has to reach the vault — for every operation, not just the first

Seeding those secrets is a Key Vault **data-plane** write, and it needs two things that being
Owner on the subscription does not give you. Both are standing requirements: once the vault is
closed, **every** later `plan`, `apply` and `destroy` refreshes those secret resources and fails
without them. Verified against Azure — a `terraform destroy` run from outside the VNet against a
fully private vault answers:

```text
403 Forbidden — ForbiddenByConnection
Public network access is disabled and request is not from a trusted service
nor via an approved private link.
```

That is the *destroy* failing on a **read**, with the vault otherwise untouched. Plan on it.

**And Terraform cannot get itself out of that.** Refresh runs *before* the changes it planned, so
an apply that would reopen the firewall fails on the refresh that precedes it — the configuration
is locked out of its own state. The way back is out of band, because the vault's network rules are
a **control-plane** setting and are not subject to the data-plane firewall:

```bash
az keyvault update --name <vault> --public-network-access Enabled
az keyvault network-rule add --name <vault> --ip-address <your egress address>
```

Then `terraform plan` works again, and putting `key_vault_deployer_ip_rules` in the configuration
makes the change durable rather than a manual patch the next apply reverts.

1. **A data-plane grant.** The module grants **Key Vault Secrets Officer** on the install
   vault to the identity running the apply. (It also grants the *frontend's* identity **Key
   Vault Secrets User** — read only — when that app carries a secret of its own, because it
   resolves its own references and runs as `id-<prefix>-frontend`, not the backend identity.) If **plan and apply run as different service
   principals** — a common CI shape, and the one Masterly runs — pin them instead:
   `key_vault_secret_operator_object_ids` for the apply identity, and
   `key_vault_secret_reader_object_ids` (Secrets User) for the planning one, which needs read
   because `terraform plan` refreshes the seeded secrets. Left implicit in a two-identity
   setup, state holds the apply identity's grant and every plan proposes destroying it.
2. **A network path.** In `mode = production` the vault has no public presence, and
   `bypass = "AzureServices"` does *not* cover a CI runner — the trusted-services list is
   Azure services, not whoever is holding the token. So state one of:

   - `key_vault_deployer_ip_rules = ["203.0.113.7"]` — the egress address of the machine or
     runner that applies. This opens the vault's public endpoint **behind its firewall**:
     `default_action` stays `Deny`, and nothing but the listed addresses (and the private
     endpoint) gets in. Key Vault rejects `/31` and `/32`, so write a single address bare.
   - `key_vault_deployer_in_vnet = true` — the apply already runs inside the install's VNet
     (self-hosted runner, jumpbox, VPN/ExpressRoute), so no exception is needed and the vault
     keeps no public presence at all. This is a claim about **every** future run, including the
     one that tears the install down. An operator who sets it and then plans from a laptop gets
     the 403 above, on an install Terraform can no longer fully manage until the path exists.

   Production refuses to plan with neither set. That is deliberate: the alternative is a 403
   partway through a ten-minute apply, with the install half-built.

Entra RBAC is eventually consistent, so a **first** apply can land inside the propagation
window of the grant in (1) and fail with `Forbidden` on the first secret. Re-run the apply.
The module does not pad every apply with a fixed wait for a race only the first one can lose.

## State security — your tfstate holds secrets in plaintext

Terraform writes **plaintext secrets into your state file**, and moving the app secrets into
Key Vault does not change that: Terraform is the thing writing them, so the values pass
through — and stay in — state either way. What shrinks is who can read them at *runtime*,
not what is in the state blob. For this module the state contains, among others:

- the **generated Postgres admin password** (`random_password.postgres_admin` — only its
  hash never leaves; the value is in state and in the app's DSN secret)
- the **generated session secret** (`random_password.session_secret`)
- the **Redis primary access key** (read back from the cache, embedded in the `redis-url`
  secret)
- every secret you pass in: **OIDC client secret**, **license JWT**, **registry pull
  password**, **telemetry client secret**, `external_database_url`, break-glass material
- with `enable_key_vault`, a copy of each of the above in the corresponding
  `azurerm_key_vault_secret` resource

Treat the state backend as a secrets store:

- **Remote state on an Azure Storage account you control**, never local `terraform.tfstate`
  committed or left on a laptop. Enable **blob versioning** (and a soft-delete / retention
  policy) so a bad apply is recoverable.
- **Entra-ID-only auth on the state storage account**: set `--allow-shared-key-access false`
  (disable the account access keys) and grant humans/CI **Storage Blob Data** roles via RBAC,
  scoped tightly. No SAS tokens, no shared keys in CI.
- **Restrict RBAC** on the account to the deploying principal and break-glass admins only;
  audit access. Consider a private endpoint / firewall on the storage account.
- **Rotate** on exposure: the Postgres/session/Redis material is module-generated, so a
  `terraform apply` after tainting the relevant `random_*`/cache regenerates it; the OIDC and
  license secrets rotate at their source. With `enable_key_vault`, a rotation applied straight
  to the vault reaches the running apps on its own (versionless references, ~30 minutes) — but
  the next `terraform apply` writes the value it holds in state back over it, so rotate at the
  input, not only in the vault.

> The demo's own state bootstrap (`.github/workflows/bootstrap-state.yml`) provisions
> `Standard_LRS` + `--min-tls-version TLS1_2` + `--allow-blob-public-access false`, but does
> **not** yet disable shared-key auth or enable blob versioning. That is acceptable for the
> demo (a throwaway eval install), but a customer production backend should harden further as
> above. Hardening the demo bootstrap is tracked separately (it is not part of the shippable
> module — it configures Masterly's own demo).

## Deliberately deferred (→ next)

Custom domains · the per-install Entra identity toward Masterly's control plane (ADR 0020).

## Versioning

Semver tags; consumers pin a registry `version` constraint, or `?ref=vX.Y.Z` from GitHub.
Breaking input/output changes bump the major. The module version is the one customer-facing
version (ADR 0062): the tag, the registry version and the pin in the docs are all the same
number.

[`MANIFEST.json`](MANIFEST.json) is the machine-readable statement of what each published
version was released against, and [`CHANGELOG.md`](CHANGELOG.md) is what changed. Read the
manifest rather than copying out of this table — the table itself is generated from it:

<!-- release-manifest:begin -->
| Module version | `api_image` | `frontend_image` | Released |
|---|---|---|---|
| `0.15.0` | `masterly.azurecr.io/api:v0.133.2` | `masterly.azurecr.io/frontend:v0.138.2` | 2026-09-07 |
<!-- release-manifest:end -->

The image pair is what the module version was released against — the pair Masterly's own
install ran when the version was tagged. Your install's running tags move on from it: the
module seeds a newly created app and then ignores image drift, so CD owns the tag thereafter.

CI checks `terraform fmt` + `validate` + `terraform test` (mock providers exercise the variable
guards and both data-plane branches) on every change, and
`scripts/check_release_manifest.py` fails any change where the manifest, the changelog and this
README stop agreeing.

A scheduled check (`.github/workflows/public-docs-module-pin.yml`) compares the version the
public [self-hosted docs](https://masterlydata.com/docs/self-hosted/install/) tell customers
to install against the newest version on the registry, so a release cannot quietly leave the
walkthrough a customer follows behind. It reads two public endpoints and holds no credential.

### Cutting a release

Release-please is deliberately not used here: the module's version is a release decision, not
one computed from commit messages. So the bump is made by hand — but not the copies of it. In
one commit, on `main`, before the tag:

1. Add the version to `MANIFEST.json` (`releases`, plus `latest`), naming the `api` and
   `frontend` images the release is tested against. That pair is what Masterly's own install
   has applied — take it from the install, not from prose.
2. Rename the changelog's `Unreleased` heading to `## [X.Y.Z] - YYYY-MM-DD` and open a fresh
   `Unreleased`.
3. Run `python3 scripts/check_release_manifest.py --write` to bring this README into line, and
   `python3 scripts/check_release_manifest.py` to check the result.
4. Merge, then tag `vX.Y.Z` on that commit.

CI runs the same check on the tag build with `--tag`, so a tag pushed without its manifest and
changelog entries fails immediately rather than being noticed a release later.

## Provider versions and the lock file

Terraform consults the dependency lock file in the **root configuration's** working directory
only — a lock file inside a module is ignored. You consume this repo as a module, so **your**
root configuration owns `.terraform.lock.hcl`. Commit it, and review the diff when it moves:
that is what turns an azurerm upgrade into a change someone approved rather than something
that happens to you on the next `init`.

If your laptops and your CI runners are not the same platform, write the file with the lock
command rather than letting `init` leave one behind — `init` records `h1:` hashes only for
the platform it ran on, and the missing-hash failure surfaces later, on someone else's
machine:

```bash
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=darwin_amd64 \
  -platform=windows_amd64
```

This repo ships no lock file of its own, for the same reason: it is a module, not a root
configuration. It constrains azurerm to `~> 4.61` and leaves the exact version to you. That
floor is load-bearing rather than housekeeping: with no lock file here, the constraint is the
only thing governing your `terraform init`, and `azurerm_managed_redis` does not exist below
4.50.0 nor its `public_network_access` below 4.53.0 — so a root configuration resolving an
earlier provider cannot express the production Redis path at all.
