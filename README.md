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
  version = "~> 0.8"
}
```

Pin a version — `~> 0.8` takes patches, `= 0.8.0` pins exactly. Sourcing straight from
GitHub also works (`github.com/masterly-data/terraform-azurerm-masterly?ref=v0.8.0`) and is
what air-gapped mirrors do, but the registry gives you version constraints and needs no
`git` on the runner.

No credential is needed to fetch this module. Running Masterly does need two things it does not
contain: the **container images**, pulled with the registry credential in your install bundle, and
a **signed licence**. Both arrive from Masterly. Air-gapped installs use the module tarball from
the same bundle.

The customer-facing walkthrough — prerequisites, the two-pass apply, upgrades and rollback — is at
**[masterlydata.com/docs/self-hosted](https://masterlydata.com/docs/self-hosted/install/)**. Start
there; this README documents the module surface.

## Usage

```hcl
module "masterly" {
  source  = "masterly-data/masterly/azurerm"
  version = "~> 0.8"

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
  api_image           = "masterly.azurecr.io/api:v0.132.2"      # v0.132.2 is the floor: below it ca-workers
  frontend_image      = "masterly.azurecr.io/frontend:v0.137.0" # registers no job handlers, silently

  # Durable seams (required for production): sealed secrets + multi-replica sessions +
  # the dedicated pipeline workers.
  enable_key_vault = true
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

  # BYO-DB (ADR 0065): your own Postgres. Omit to provision the starter server instead.
  external_database_url = var.masterly_database_url # from your secret store

  # Images (ADR 0067) — pick ONE:
  # Option 1, direct pull from Masterly's registry with the service principal from
  # your install bundle:
  registry_username = var.masterly_pull_appid  # from the bundle
  registry_password = var.masterly_pull_secret # from your secret store
  # Option 2, your own ACR: `az acr import` the pinned tags with the same credential,
  # then point acr_login_server at your registry and set acr_id so the module grants
  # AcrPull to the install identity (managed-identity pull, no credential in the app):
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
`apps_identity_client_id` for out-of-band role grants.

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
| `id-masterly-apps` UAMI (+ optional AcrPull) | Image pull, later install identity work (ADR 0020) |
| Postgres Flexible Server (`psql-masterly-<suffix>`) — **starter data plane, skipped on BYO-DB** | Private-endpoint-only; per-Environment databases are created on it by the api |
| `ca-api` (internal ingress, :8001) | The product API; probes `/healthz` + `/readyz`; secrets (DSN, session secret, license, …) live as Container App secrets |
| `ca-frontend` (public ingress, :3000) | The GUI/BFF; on `oidc` it runs the authorization-code + PKCE dance against your IdP. Readiness (`/api/readyz`) gates traffic on the frontend's own runtime config resolving **and** the api answering, so a misconfigured revision never takes traffic |
| Service Bus namespace + queue (opt-in, ADR 0029) | The `servicebus` bus binding; default is the broker-less polling binding |
| ACS email (opt-in, ADR 0040) | Customer-owned email; endpoint + sender auto-wired into the api |
| Key Vault (opt-in, ADR 0066) | The durable secret store (`enable_key_vault`): sealed BYO-DB DSNs and GitOps tokens survive restarts; RBAC-mode vault, Secrets Officer grant to the apps identity, `MASTERLY_SECRET_STORE=keyvault` auto-wired. Soft-delete always on; in `mode=production` purge protection is armed and the vault runs **private-endpoint-only** (public access disabled, `privatelink.vaultcore.azure.net`). Required for `mode=production`. |
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
   (with an offline image bundle instead of the import).

Rotation: the SP carries up to two active secrets — switch `registry_password` to the new
one and apply.

## Identity (ADR 0024)

`identity_binding` selects the adapter:

- **`oidc`** — production: your own IdP. The backend verifies tokens against
  `oidc_allowed_issuers`/`oidc_audience`/`oidc_jwks_uri`; the frontend BFF is the
  confidential client (`oidc_client_id`/`oidc_client_secret`/`oidc_authority`/
  `oidc_redirect_uri`). Optional break-glass local Owner via
  `breakglass_owner_email` + `breakglass_secret_hash` (sha256, never the secret).
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
- **Metric alerts** for the page-an-operator failure modes: Postgres storage nearly full,
  B-series CPU-credit exhaustion (burstable installs only), Redis memory nearly full, Redis
  key evictions (which under the no-eviction policy mean the policy has been changed out from
  under the install, not that the cache is small), and `ca-api` / `ca-frontend` 5xx.

Alerts fire and record with no notification target; to be paged, set `alert_email` (the
module creates an action group) or point `alert_action_group_id` at an existing group
(a shared ops group, a PagerDuty webhook group).

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

## State security — your tfstate holds secrets in plaintext

Terraform writes **plaintext secrets into your state file**. For this module the state
contains, among others:

- the **OIDC client secret** (`oidc_client_secret`)
- the **license JWT** (`license_token`)
- the **generated Postgres admin password** (`random_password.postgres_admin` — only its
  hash never leaves; the value is in state and in the app's DSN secret)
- the **generated session secret** (`random_password.session_secret`)
- the **Redis primary access key** (embedded in the `redis-url` secret)
- the **registry pull service-principal secret** (`registry_password`) and any
  `external_database_url` / break-glass material you pass in

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
  license secrets rotate at their source.

> The demo's own state bootstrap (`.github/workflows/bootstrap-state.yml`) provisions
> `Standard_LRS` + `--min-tls-version TLS1_2` + `--allow-blob-public-access false`, but does
> **not** yet disable shared-key auth or enable blob versioning. That is acceptable for the
> demo (a throwaway eval install), but a customer production backend should harden further as
> above. Hardening the demo bootstrap is tracked separately (it is not part of the shippable
> module — it configures Masterly's own demo).

## Deliberately deferred (→ next)

Custom domains · the per-install Entra identity toward Masterly's control plane (ADR 0020).

## Versioning

Semver tags; consumers pin `?ref=vX.Y.Z`. Breaking input/output changes bump the major.
CI checks `terraform fmt` + `validate` + `terraform test` (mock providers exercise the
variable guards and both data-plane branches) on every change.

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
