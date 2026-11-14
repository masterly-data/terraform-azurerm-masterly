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
  version = "0.24.0"
}
```

<!-- release-manifest:pins:begin -->
Pin the exact version, as the examples on this page do (`version = "0.24.0"`).
Terraform does not lock module versions: `.terraform.lock.hcl` records providers only, so
with a range every fresh `terraform init` (a new laptop, a CI runner, a clean clone) takes
the newest release the range admits. With an exact version your configuration is the
record of what the install runs, and an upgrade is a reviewed one-line change.
If you do want a range, `version = "~> 0.24.0"` takes patches of 0.24 only: releases
that add no capability, no new input or required setting and no database migration.
`version = "~> 0.24"` also takes every later 0.x minor.
Before 1.0.0 a minor may carry a breaking change, listed under its own heading
in the changelog, so read it before you take one.
[Versioning](#versioning) says what each kind of release promises.
<!-- release-manifest:pins:end -->

Sourcing straight from GitHub also works
(`github.com/masterly-data/terraform-azurerm-masterly?ref=v<version>`, a Stable semver tag) and
is what air-gapped mirrors do, but the registry gives you version constraints and needs no `git`
on the runner.
Which Stable version is current, and which images go with it, is [`MANIFEST.json`](MANIFEST.json) —
see [Versioning](#versioning). A Canary or Beta build has no tag; see
[Installing a Canary or Beta build](#installing-a-canary-or-beta-build).

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

Every input, grouped by subsystem, is in [docs/inputs.md](docs/inputs.md) (generated from the
`.tf` files, so it cannot drift).

```hcl
module "masterly" {
  source  = "masterly-data/masterly/azurerm"
  version = "0.24.0"

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
  # The pair this module version was released against, from MANIFEST.json. Versioning names
  # the oldest image each app can run on, and the tags that have no published image.
  api_image           = "masterly.azurecr.io/release/api:v0.137.0"
  frontend_image      = "masterly.azurecr.io/release/frontend:v0.145.0"

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
  # The api at 1 vCPU / 2Gi; the other apps keep 0.5 vCPU / 1Gi. See "Scaling".
  app_resources = { api = { cpu = 1 } }

  # Identity (ADR 0024): your own OIDC IdP. For a single-tenant Entra registration the tenant
  # id is enough: the issuer, signing-key endpoint and authority follow from it, and the
  # audience defaults to oidc_client_id (one app registration serves both). For Okta,
  # Keycloak or multitenant Entra, leave oidc_tenant_id out and set oidc_allowed_issuers,
  # oidc_jwks_uri and oidc_authority instead.
  identity_binding   = "oidc"
  oidc_tenant_id     = "<tenant id>"
  oidc_client_id     = "<bff client id>"
  oidc_client_secret = var.oidc_client_secret # from your secret store
  oidc_redirect_uri  = "https://<frontend host>/api/auth/callback"
  # Or serve the frontend on your own hostname and drop oidc_redirect_uri: the module derives
  # https://<hostname>/api/auth/callback from it. See "ca-frontend on your own domain".
  # frontend_custom_domain = { hostname = "...", certificate_key_vault_secret_id = "...", key_vault_id = "..." }

  # License (ADR 0013): from your install bundle.
  license_token      = var.license_token # from your secret store
  license_public_jwk = file("license-issuer.jwk.json")

  # The install credential (from the same bundle): the install service account. Despite
  # the telemetry_ prefix it serves both optional features below, which each need it and
  # neither of which needs the other. Set it only with at least one of them — a credential
  # with neither feature, or half of it, is refused at plan.
  # telemetry_client_id     = var.telemetry_client_id
  # telemetry_client_secret = var.telemetry_client_secret # from your secret store

  # Licence refresh (optional): the install re-fetches its licence from Masterly daily and
  # re-verifies it before adopting it. Needs the install credential above; does not need
  # telemetry_url and reports nothing. Leave unset on an offline install — no outbound call.
  # license_issuer_url      = "<licence refresh URL from your install bundle>"

  # Fleet telemetry (optional): usage ledger + an install snapshot (version, health,
  # counts) to Masterly's control plane, hourly. Needs the install credential above; leave
  # this unset to report nothing. Never billing input.
  # telemetry_url           = "<control-plane URL from your install bundle>"

  # BYO-DB (ADR 0065): your own Postgres. Omit to provision the starter server instead.
  external_database_url = var.masterly_database_url # from your secret store

  # Images (ADR 0067) — pick ONE registry_credential_mode. See "Getting the images".
  # "token": direct pull from Masterly's registry with the pull credential from your
  # install bundle:
  registry_credential_mode = "token"
  registry_token = {
    username = var.masterly_pull_appid  # from the bundle
    password = var.masterly_pull_secret # from your secret store
  }
  # "customer_registry": `az acr import` the release/api and release/frontend images into
  # your own ACR, point registry_location at it and set acr_id so the module grants AcrPull
  # to both install identities (managed-identity pull, no credential in the app):
  # registry_credential_mode = "customer_registry"
  # registry_location        = "acme.azurecr.io"
  # acr_id                   = "/subscriptions/.../registries/acme"

  tags = {
    cost-center      = "…"
    data-residency   = "eu"
    deployment-model = "self-hosted"
    owner            = "…"
    lifecycle        = "prod"
  }
}
```

Outputs include `frontend_url` (`https://<hostname>` with `frontend_custom_domain` set),
`custom_domain_verification_id` (the `asuid.<hostname>` TXT value), `api_url` (the API's base URL for the Python SDK and other
clients outside the environment — null unless `api_ingress_external = true`), the apps resource
group, the Container App names (the values the app repos' release workflows use to roll
images — `DEMO_RG`, `DEMO_APP_API`, `DEMO_APP_FRONTEND` in the demo case), and `apps_identity_principal_id` /
`apps_identity_client_id` / `frontend_identity_principal_id` / `migrate_identity_principal_id` /
`workers_identity_principal_id` for out-of-band role grants. The install runs on two app
identities, with `migrations = "job"` on a **third**, the migrate job's, and wherever `ca-workers`
runs as its own identity on a **fourth** (see [The migrate job](docs/data-plane.md#the-migrate-job)), so an
out-of-band `AcrPull` grant has to reach each of them.

`api_internal_fqdn` keeps its name so existing configurations still plan, but the name is older
than `api_ingress_external`: it holds the API's internal hostname only while the API is
unpublished, and its published hostname once it is. Read `api_url` for a client's base URL. Like
every ingress hostname, both are for a person or a client to use, not for wiring one app to
another — apps in the same environment address the API by its Container App name.

## Preflight

`scripts/preflight.sh` reads a target subscription and reports what a first apply needs:
resource-provider registration, the deploying identity's roles, PostgreSQL SKU
availability, and — in production — whether the tenant can still create an Azure Cache for
Redis. It is read-only unless you pass `--register`.

The identity that runs `terraform apply` needs, at subscription scope, **Contributor** (or Owner)
to create resources and a role that can write role assignments: **Role Based Access Control
Administrator**, **User Access Administrator** or **Owner**. With `enable_key_vault` (always on in
production) the module also defines a role of its own, the apps' role on the vault (see
[What the module creates](#what-the-module-creates)), which needs
**`Microsoft.Authorization/roleDefinitions/write`**: Owner and User Access Administrator carry it,
Role Based Access Control Administrator does not. With `--principal`, the preflight FAILs a
deployer without it in production and WARNs in demo, where the vault is optional. It reads role
names, so a custom role of yours that does carry the action reads as missing: the message names
the action so you can confirm it yourself.

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

## A renewed licence and the api image it runs on

A licence states, in its signed header, the oldest licence contract an install may verify it
with — its claims floor — and each `api` image verifies one claims version. An `api` image refuses
at startup a licence whose floor is above its version (ADR 0013, amended 2026-10-06). A licence
you apply with `terraform apply` reaches that startup check directly, so the plan checks first:
when `license_token`'s floor is above the claims version [`MANIFEST.json`](MANIFEST.json) records
for your `api_image` (`api_claims_version`), `terraform plan` fails before anything is applied. The
error names the floor, your `api_image` and its claims version, and the oldest `api` tag that
verifies the licence. Move `api_image` to that tag, roll the running apps to it (see Upgrades in
the install documentation — `terraform apply` does not roll a running image), then apply the
licence. An install older than the floor upgrades before it renews.

The check runs offline: it reads the manifest that ships inside this module, never a registry, so
an air-gapped install plans exactly as a connected one does. It compares `api_image` by its tag,
so an image mirrored into your own registry under the same tag is checked like the original. An
`api_image` pinned by digest alone (`<registry>/.../api@sha256:<digest>`) has no tag to read, so
the check compares its digest with the api digests the manifest records (`digests.api`) instead.
A reference with both a tag and a digest is compared by its tag when a release records the tag,
and by its digest when none does, so a release mirrored under a tag of your own is still checked.

What passes unchecked, as it always has:

- **no licence**, or a licence whose header carries no claims version: version 0, floor 0;
- **a header that does not decode** — the application refuses a malformed licence at startup;
- **an `api_image` whose tag no release in this module version's manifest records**, and whose
  digest, if it has one, none records either — a build newer than the module, a Canary or Beta
  build, or a hand-built image. Its claims version is not known here, and the application's own
  check at startup is what stands.

The check reads `api_image`, not the image the app is running. Terraform seeds the image and then
leaves it to you to roll, so keep `api_image` at the tag your install runs: that is what this
check, and a rebuilt app, both go by.

## What the module creates

| Resource | Purpose |
|---|---|
| `rg-masterly-aca`, `rg-masterly-data` | Customer-naming resource groups (`rg-masterly-<purpose>`) |
| VNet + runtime subnet (/23) + private-endpoints subnet + front, app and workers environment subnets | The install's network; ACA is VNet-integrated. The environment subnets (ADR 0120) are each filtered by their own network security group; see [docs/networking.md](docs/networking.md#the-environment-subnets) |
| Log Analytics + ACA environment (`aca-masterly`) | The runtime |
| `id-masterly-apps` UAMI (+ optional AcrPull) | The **backend** apps' identity (`ca-api`, and `ca-workers` unless it has its own, below): image pull, plus every data-plane grant the install makes — the module's **app secrets role** on the vault (read, write and delete secrets: `getSecret`, `setSecret`, `delete` and `readMetadata`; unlike the built-in Key Vault Secrets Officer it replaces, no purge, backup, restore or recover), Key Vault Crypto Officer (the erasure keys of ADR 0081 — see [Erasure keys belong in your secret backup](#erasure-keys-belong-in-your-secret-backup)), Service Bus send + receive, ACS Email Owner, and on `database_auth` / `redis_auth` = `"entra"` the starter server's Microsoft Entra administrator and the Redis data access policy. Wherever `ca-workers` runs as its own identity it holds Service Bus send only: receive and the jobs queue's Data Owner are `id-masterly-workers`'. With `migrations = "job"` on the starter server it is also **no** Postgres administrator (ADR 0120). Later install identity work (ADR 0020) |
| `id-masterly-frontend` UAMI (+ optional AcrPull) | The **frontend's** identity. Image pull, plus, with `enable_key_vault`, **Key Vault Secrets User** (read) on each of its own secrets only — the BFF shared secret, and the registry password and OIDC client secret when set — never on the vault, and nothing else: `ca-frontend` is the only internet-facing app, so it does not carry the backend's grants |
| `id-masterly-migrate` UAMI (+ optional AcrPull) — **only with `migrations = "job"`** | The **migrate job's** identity (`caj-migrate`), attached to no Container App. Image pull, plus **Key Vault Secrets User** on each of its vault-backed secrets and the per-Environment BYO-DB DSN secrets explicitly named in `migrate_byo_database_secret_names`; no vault copy or grant for `external_database_admin_url`. On `database_auth = "entra"`, the starter server's **only** Microsoft Entra administrator. No vault-scope, Officer or crypto role, no Service Bus, Redis or ACS. See [The migrate job](docs/data-plane.md#the-migrate-job) |
| `id-masterly-workers` UAMI (+ optional AcrPull) — **wherever `ca-workers` exists and the install has a Key Vault, except `migrations = "start"` with `database_auth = "entra"` on the starter server** | **`ca-workers`' own identity**: it runs, pulls, scales and resolves its Key Vault references as it. With `migrations = "job"` on the starter server it also signs in to Postgres as `masterly_workers` (on `"entra"`, the role the migrate job binds to this identity); elsewhere it reads the shared `database-url`. It holds the backend grants `ca-workers` needs — the app secrets role and Crypto Officer on the vault, AcrPull (through `acr_id`), ACS Email Owner, Service Bus send + receive, Data Owner on the jobs queue when `ca-workers` scales on it, and its own Redis data access policy on `redis_auth = "entra"`. It is no Postgres administrator. `id-masterly-apps` keeps the others but gives up Service Bus receive and the jobs queue's Data Owner to it, and under `"job"` on the starter server its Entra administrator to `id-masterly-migrate`. See [The migrate job](docs/data-plane.md#the-migrate-job) |
| `caj-migrate` Container Apps job — **only with `migrations = "job"`** | Schema migrations and new Environments' databases (ADR 0120): `python -m masterly_app.apps.migrate` on the api image, no ingress, on `migrate_job_schedule`, once at install, and from your CD before each release rolls the apps |
| Postgres Flexible Server (`psql-masterly-<suffix>`) — **starter data plane, skipped on BYO-DB** | Private-endpoint-only; per-Environment databases are created on it by the api |
| `ca-api` (internal ingress, :8001) | The product API; probes `/healthz` + `/readyz`; secrets (DSN, session secret, license, …) reach it as Container App secrets — **Key Vault references** when `enable_key_vault`, values otherwise. Internal by default; `api_ingress_external = true` publishes it behind `ingress_allowed_cidrs` and makes it HTTPS-only (see [Transport security](docs/networking.md#transport-security)) |
| `ca-frontend` (public ingress, :3000) | The GUI/BFF; on `oidc` it runs the authorization-code + PKCE dance against your IdP. Readiness (`/api/readyz`) gates traffic on the frontend's own runtime config resolving **and** the api answering, so a misconfigured revision never takes traffic |
| Service Bus namespace + queue (opt-in, ADR 0029) | The `servicebus` bus binding; default is the broker-less polling binding. In `mode = "production"`, `enable_service_bus = true` also requires **`servicebus_sku`**, which has no default there: `"Premium"` (recommended) runs the namespace private, behind a **private endpoint** with public network access disabled, at about $677 per month; `"Standard"` keeps a public endpoint. See [Where this module departs from Azure's recommended baseline](#where-this-module-departs-from-azures-recommended-baseline). |
| ACS email (opt-in, ADR 0040) | Customer-owned email; endpoint + sender auto-wired into the api |
| Key Vault (opt-in, ADR 0066) | The durable secret store (`enable_key_vault`): sealed BYO-DB DSNs and GitOps tokens survive restarts; RBAC-mode vault; to the apps identity on the vault, Crypto Officer and the app secrets role, an install-unique custom role (`Masterly app secrets (<prefix>-<suffix>)`, defined on and assignable only within the data resource group) that reads, writes and deletes secrets and nothing more; `MASTERLY_SECRET_STORE=keyvault` auto-wired. It is also where **the install's own secrets** live — with the vault on, the apps hold Key Vault *references*, not values (see below). Soft-delete always on; in `mode=production` purge protection is armed and the vault is reached over a **private endpoint** (`privatelink.vaultcore.azure.net`) with **default-deny** network ACLs. Required for `mode=production`. |
| Redis (opt-in, ADR 0066 + ADR 0071) | The multi-replica session registry (`MASTERLY_SESSION_REGISTRY=redis`; the URL rides as a Container App secret, keyless on `redis_auth = "entra"` — [authentication](docs/data-plane.md#authentication-to-the-starter-server-and-redis)). `enable_redis = true` also requires **`redis_offering`**, which has no default: `"managed"` = **Azure Managed Redis** (`Microsoft.Cache/redisEnterprise`, `Balanced_B0` by default, private DNS zone `privatelink.redis.azure.net`) — creatable by any tenant, and the only choice that works if your organization has never run an Azure Cache for Redis instance; `"cache"` = **Azure Cache for Redis** (`Microsoft.Cache/redis`, Basic/Standard/Premium, zone `privatelink.redis.cache.windows.net`) — creation blocked for new customers since 1 April 2026, retired 30 September 2028, kept only so an existing instance is not destroyed. Either way: **public network access disabled**, reachable only via a **private endpoint** mirroring the starter Postgres. Unlocks `api_max_replicas > 1`. Budget tens of minutes for the first apply — Azure-side provisioning dominates. |
| Registry private endpoint (opt-in) | `registry_private_endpoint`: a private endpoint to your registry (`acr_id`, `registry` subresource) on the private-endpoints subnet, with a `privatelink.azurecr.io` private DNS zone linked to the VNet, so the identity modes pull over the VNet. See [The registry over a private endpoint](#the-registry-over-a-private-endpoint). |
| `ca-workers` (opt-in, ADR 0066) | The dedicated async-pipeline loop (`enable_workers`): same image, command `python -m masterly_app.workers`, no ingress; the api flips to `MASTERLY_INPROCESS_WORKER=false`. |
| `ca-frontend` custom domain (opt-in) | `frontend_custom_domain`: `id-masterly-frontend-cert` UAMI, attached to the Container App Environment and to no app, with **Key Vault Secrets User** on your certificate's secret alone; the environment certificate, a versionless Key Vault reference read as that identity; and an SNI binding of your hostname on `ca-frontend`. See [ca-frontend on your own domain](docs/identity.md#ca-frontend-on-your-own-domain-frontend_custom_domain). |

## Getting the images (ADR 0067)

Masterly issues each customer a **pull service principal** (appId + client secret, in the
install bundle, `AcrPull` only). Five inputs say where the images come from and how the apps
pull them: `registry_location`, `registry_credential_mode`, `registry_token`, `release_channel`
and `registry_private_endpoint`. Their types, defaults and descriptions are in docs/inputs.md:
`registry_location` and `release_channel` under
[Images and registry pull credential](docs/inputs.md#images-and-registry-pull-credential),
`registry_credential_mode` and `registry_token` under
[Install identity (ADR 0039)](docs/inputs.md#install-identity-adr-0039), and
`registry_private_endpoint` under
[Registry private endpoint](docs/inputs.md#registry-private-endpoint); the registry over a
private endpoint is described in [The registry over a private endpoint](#the-registry-over-a-private-endpoint).

The three modes:

1. **`token`: direct pull.** Set `registry_token`; every app pulls straight from
   `registry_location` (`masterly.azurecr.io` unless you set it) with the token's username, and the password rides as the Container App
   secret `registry-password` (a Key Vault reference when `enable_key_vault` is on). No `AcrPull`
   grant is created, even with `acr_id` set. Lowest friction; note that NEW revisions and
   scale-out pulls depend on Masterly's registry being reachable (running replicas are
   unaffected). The plan refuses this mode with no credential.
2. **`managed_identity`: pull as the app identities.** Each app pulls as its own identity,
   with no credential in the install. `acr_id` grants `AcrPull` to both identities, and to the migrate job's and `ca-workers`' own when they exist. With
   `registry_location` omitted, set the mode or `acr_id` to pull from `masterly.azurecr.io`;
   with neither, the apps have no registry block.
3. **`customer_registry`: mirror into your own ACR.** Import each image into the same
   repository on your registry, for example `az acr import --name <yours> --source
   masterly.azurecr.io/release/api@sha256:<digest> --image release/api --username <appId>
   --password <secret>`, then set `registry_location` to your login server and `acr_id` to
   your registry. The apps pull as their identities, with no Masterly credential in the
   install. Recommended for regulated environments; required for air gap (with an offline
   image bundle instead of the import). The plan refuses this mode without a
   `registry_location` other than Masterly's.

In both identity modes, `acr_id` grants `AcrPull` to both app identities and, when they exist, to
the migrate job's and `ca-workers`' own. If you leave it null and grant out of band, grant each:
`apps_identity_principal_id`, `frontend_identity_principal_id` and, with the job,
`migrate_identity_principal_id`, and `workers_identity_principal_id` wherever it is not null (see
[which identity `ca-workers` runs as](docs/data-plane.md#the-migrate-job)). Miss the second and the frontend cannot
pull; miss the third and the migrate job cannot pull, so no migration runs; miss the fourth and
`ca-workers` cannot pull its new revision. `workers_identity_principal_id` is known only once the
identity exists: create it first (`terraform apply -target='module.masterly.module.workers_identity'`,
with your own module name), grant it `AcrPull`, then apply the rest.

**The default images.** Leave `api_image` and `frontend_image` unset and each resolves to
`<registry_location>/release/<role>@<digest>`: the digest the `release_channel` release
records in `MANIFEST.json`, or its tag for a release that records no digest. The channel changes
only that digest or tag. The repository is always `release/api` and `release/frontend`, so a
mirror keeps those repository names. An image you set explicitly is used as given. The
`image_references` output shows what the plan resolved: both references, the registry, the
mode and the release. Like an explicit image, the channel's reference seeds an app when it is
created, and CD owns the running image thereafter: changing `release_channel` on an existing
install rolls nothing (`terraform apply` does not roll a running image, see "Moving to Stable"
below). To roll a running install back, redeploy the previous image with
`az containerapp update --image`. With `migrations = "job"`, a release rolls the
[migrate job](docs/data-plane.md#the-migrate-job) first.

**The deprecated inputs** still plan as before, with two exceptions. An install that pulls with
a credential and also sets `acr_id` loses its two unused `AcrPull` grants, because the `token`
mode creates none. An install that set none of `acr_login_server`, a credential and `acr_id`
now has no registry block, as omitting `registry_location` means. `acr_login_server` is read as
`registry_location`, and `""` still renders no registry block: with no mode or credential set,
that is the same as omitting `registry_location`. `registry_username` and
`registry_password` are read as `registry_token`. With `registry_credential_mode` unset, the
mode is `token` when a credential is set, `customer_registry` when the registry is not
`masterly.azurecr.io`, and `managed_identity` otherwise. Setting a new input together with
the deprecated one it replaces is refused. The CHANGELOG has the migration.

Rotation: the SP carries up to two active secrets. Switch `registry_token.password` to the new
one and apply.

### The registry over a private endpoint

`registry_private_endpoint = true` (off by default) moves the image pulls off the registry's
public endpoint and onto the install's VNet. It creates, in `registry.tf`:

- `pe-masterly-registry`, a private endpoint to `acr_id`'s `registry` subresource, on the
  install's private-endpoint subnet (`snet-private-endpoints`, or `private_endpoints_subnet_id`
  when you inject the network), in `rg-masterly-data`;
- a `privatelink.azurecr.io` private DNS zone in `rg-masterly-aca`, linked to the install's VNet
  (`pdzl-masterly-registry`), with the endpoint's DNS zone group in it, so the registry's login
  server and its data endpoint resolve to the endpoint's private addresses inside the VNet.

The login server, the image references and the `AcrPull` grants do not change; the output
`registry_private_endpoint_id` names the endpoint. The plan refuses the input with the `token`
mode (set or derived from `registry_token`) and without `acr_id` set to a registry's resource ID.
Before you turn it on:

- **`acr_id` must be the registry the apps pull from**, the one `registry_location` names: the
  endpoint connects to `acr_id`, and the module does not compare the two.
- **The registry must be Premium**, the ACR SKU that takes private endpoints.
- **The connection is requested as automatically approved**, so the identity running the apply
  needs the right to approve private endpoint connections on that registry. For a registry you
  do not own, ask its owner before you apply.
- **The registry's public network access is not changed.** Closing it is the registry owner's
  choice, and closes it for every other client too.
- **The zone is always created.** A VNet links to one `privatelink.azurecr.io` zone only, so in a
  hub-and-spoke landing zone whose hub already links one, leave the input off and let the
  platform team add the endpoint ([docs/networking.md](docs/networking.md)).

## Identity (ADR 0024)

Who signs in, `ca-frontend` on your own domain and the built-in authentication are documented in
[docs/identity.md](docs/identity.md).

## Data plane (ADR 0065)

The data plane's resources, how the apps authenticate to them, the migrate job and trusting a
private CA are documented in [docs/data-plane.md](docs/data-plane.md).

## Networking

The VNet, the landing-zone notes, the API's public address and transport security are documented in
[docs/networking.md](docs/networking.md). The departures from Azure's recommended baseline stay here.

### Where this module departs from Azure's recommended baseline

This module departs from Azure's recommended configuration for the resources it creates in
four places. In two of them, Service Bus and geo-redundant backup, the module's defaults do
not yet follow the recommendation; in one, Redis and Postgres authentication, a production
install departs from it only when you say so; and one, the runtime subnet's network security
group, is a deliberate design choice. Each is listed below with what it is, why it holds or
why you might choose it, and what you can do to follow Azure's recommendation. Making Azure's
recommendation the default is tracked work for Service Bus and geo-redundant backup, and this
section changes as each one is closed. The network security group's Internet rule is not
tracked work: a public environment needs it, and you follow Azure's recommendation by choosing
an internal environment (`aca_internal_load_balancer = true`).

Azure Policy and Microsoft Defender for Cloud can report these. Each item names the Azure
Policy built-in definitions that evaluate it, by display name and definition ID, or says that
none has been identified; if your portal shows a slightly different title, search for the ID.
Defender for Cloud's default standard is the Microsoft cloud security benchmark v1
(`1f3afdf9-d0c9-4c3d-847f-89da613e70a8`), and none of the definitions below is part of it.
The Microsoft cloud security benchmark v2 (`e3ec7e09-768c-4b64-882c-fcada3772047`) is an
opt-in preview; each item says whether its definitions are in it. Whether a finding appears
on your subscription therefore depends on the standards and policies you have assigned.

#### Service Bus on Basic or Standard keeps public network access enabled

This applies only with `enable_service_bus = true`. Azure recommends the Premium tier with a
private endpoint and public network access disabled. The namespace's minimum TLS version is set
to 1.2 explicitly (`minimum_tls_version`) on every tier.

In `mode = "production"` with Service Bus enabled, the module makes you choose the tier:
`servicebus_sku` has no default there, and the plan is refused until you set it. That is
deliberate. A Premium default would replace the namespace of every existing install that never
set the tier, and a Standard default would leave a new install off Azure's recommendation
without anyone having chosen that. The choice is:

- `servicebus_sku = "Premium"`, the recommendation. Public network access is disabled, and the
  apps reach the namespace over a private endpoint in the install's private-endpoints subnet,
  with a `privatelink.servicebus.windows.net` private DNS zone linked to the install's VNet (or
  the zone you pass in `servicebus_private_dns_zone_id`). Premium is priced per messaging unit.
  The module provisions one, which costs about **$677 per month** in Sweden Central at list
  price (USD 0.9275 per messaging-unit hour). Check the price for your region and agreement.
- `servicebus_sku = "Standard"`, the documented opt-down, at a base charge of about $10 per
  month. The namespace keeps public network access enabled. This is also the value that keeps
  an existing Standard namespace unchanged.

Outside production an unset `servicebus_sku` means Standard, and a Premium namespace keeps
public access, for ease of evaluation.

On Basic or Standard the namespace keeps public network access enabled. Why that departure
exists:

- Private endpoints are a Premium-tier feature, so Basic and Standard cannot be made private.
- IP firewall rules are available on Standard, but they leave public network access enabled,
  so they do not meet the recommendation. They would also need a stable source address, which
  this module's Consumption-only Container Apps environment does not have.
- Premium costs about $677 per month against Standard's $10, which is a choice the module
  leaves to you rather than making on your behalf.

To follow Azure's recommendation, either:

- leave `enable_service_bus` at its default, `false`. The apps then run their job queue in the
  install's Postgres database (the polling bus binding), no broker is provisioned, and
  `mode = "production"` accepts that configuration, with no `servicebus_sku`. Or
- set `servicebus_sku = "Premium"` in production, as `examples/production` does. **On an
  install that already runs a Basic or Standard namespace, this replaces it.** Azure does not
  convert a namespace between Premium and the other tiers in place, so the plan destroys the
  namespace, its `masterly-jobs` queue and the apps' two role assignments, and creates them
  again. Job notifications still in the queue are lost with it; the jobs themselves are in the
  Environment's database. Moving back from Premium replaces it the same way. Read the plan
  before you apply it.

Definitions that flag this:

- *Service Bus Namespaces should disable public network access*
  (`cbd11fd3-3002-4907-b6c8-579f0e700e13`). It is in the benchmark v2 initiative and applies
  to every SKU. A production Premium namespace passes it.
- *Azure Service Bus namespaces should use private link*
  (`1c06e275-d63d-4540-b761-71f364c2111d`). It is in the benchmark v2 initiative, but it
  evaluates Premium namespaces only, so a Standard namespace does not trigger it.

#### Redis and the starter Postgres authenticate with a key or password, when you choose it

In `mode = "production"`, a new install's starter Postgres server and Redis authenticate with
Microsoft Entra ID only, which is Azure's recommendation: password authentication and access
keys are off, and the apps present a token for their managed identity
([Authentication to the starter server and Redis](docs/data-plane.md#authentication-to-the-starter-server-and-redis)).
Two inputs depart from that, and only on purpose:

- `database_auth = "password"` keeps the starter server's `masterly_admin` login, with its
  password in the apps' connection string and Microsoft Entra authentication off.
- `redis_auth = "key"` keeps the cache's access key in the apps' Redis URL, with access-key
  authentication on.

Why you might choose them: an install that existed before this default keeps its password and
key until you move it
([Moving an existing install to Microsoft Entra authentication](docs/data-plane.md#moving-an-existing-install-to-microsoft-entra-authentication)),
and a production plan stops until you choose, so setting these is how you keep the install as
it is in the meantime. Either also suits an install whose api image is older than `v0.133.7`,
which cannot authenticate with a token. What it costs: a credential that can be copied out of
the apps' configuration, or out of your Terraform state, and used from anywhere that can reach
the private endpoint, until you rotate it.

Evaluation installs (`mode = "demo"`) keep the password and the key by default. With
`external_database_url` (BYO-DB) the module provisions no Postgres server, and how your
database authenticates is yours to configure.

Definitions that flag the departure:

- *Azure Cache for Redis should not use access keys for authentication*
  (`3827af20-8f80-4b15-8300-6db0873ec901`). It evaluates the `redis_offering = "cache"` path
  only, and it is in neither benchmark initiative.
- *A Microsoft Entra administrator should be provisioned for PostgreSQL flexible servers*
  (`ce39a96d-bf09-4b60-8c32-e85d52abea0f`). It is in neither benchmark initiative. A server on
  `database_auth = "entra"` passes it: the apps' identity is its Microsoft Entra administrator,
  or with `migrations = "job"` the migrate job's identity is.
- No built-in definition evaluates access-key authentication on Azure Managed Redis
  (`redis_offering = "managed"`).

#### Geo-redundant backup is on only in the regions the module lists

Geo-redundant backup copies the starter Postgres server's backups to the region Azure pairs
with the server's region, so the server can be restored there if its own region is lost. Azure
recommends it as a reliability measure. Leave `postgres_geo_redundant_backup` unset and the
module decides:

| Install | Region | Geo-redundant backup |
|---|---|---|
| `mode = "production"` | Sweden Central | On. Its pair, Sweden South, is in Sweden, inside the `eu` geo. |
| `mode = "production"` | Poland Central, Spain Central | Off. Azure does not offer geo-redundant backup for Postgres flexible server in these regions, so turning it on would fail the apply. |
| `mode = "production"` | Any other region | Off. The module has not yet recorded whether Azure supports it there. |
| `mode = "demo"` | Any | Off. |

Set `postgres_geo_redundant_backup = true` or `false` to decide yourself; your value always
wins. Before setting `true`, check two things against Microsoft's
[regions table](https://learn.microsoft.com/azure/postgresql/overview#azure-regions): that the
region supports geo-redundant backup, and that the paired region is inside your install's
data-residency boundary. The backups are copies of your data, so a pair outside that boundary
is a residency breach, not a backup.

The setting takes effect only when the server is created. Azure accepts it only at creation,
and changing it would replace the server, destroying the server and every Environment database
on it. So the module ignores later changes to it: a module upgrade that changes the default, or
a changed input, leaves an existing server as it was created. An install created before this
default keeps the setting it was created with: off, unless you had set it. To turn it on for an existing server, restore the
server to a new one with geo-redundant backup enabled and move the install's data plane to it.

A geo-restore creates a new server in the paired region. Sweden South is an access-restricted
region: a subscription can create resources there only after Microsoft grants it access. If
your install is in Sweden Central, request access to Sweden South for the install's
subscription before you need a restore, through an Azure support request; the backups are
copied there either way, but a restore into Sweden South waits on that access.

Definitions that flag this:

- *Geo-redundant backup should be enabled for Azure Database for PostgreSQL flexible
  servers* (`cee2f9fd-3968-44be-a863-bd62c9884423`). It is in neither benchmark initiative.

#### The runtime subnet's network security group admits the Internet on ports 80 and 443 in a public environment

This applies when the module creates the runtime subnet and its network security group (it
does not on an injected spoke, where the module creates no such group) and
`aca_internal_load_balancer = false`, which is the default. The group's `allow-app-ingress`
rule then admits the `Internet` service tag to TCP ports 80 and 443 on the Container Apps
subnet. With `aca_internal_load_balancer = true` the source is `VirtualNetwork` instead, so
only your virtual network and the networks connected to it can reach the apps. Azure
recommends that a rule not allow unrestricted ingress from any IP address.

Why the module does this: in a public environment the frontend (and the api, when
`api_ingress_external = true`) must be reachable from the Internet, so the rule has to admit
it. Port 80 is admitted beside 443 because Azure's edge answers it with a 301 redirect to
https, and dropping it would turn that redirect into a timeout. The rule is not where access
is narrowed: `ingress_allowed_cidrs` narrows who may reach the apps at the Container Apps
edge, not at the network security group. It is not used as the rule's source because an empty
list is a valid setting that means unrestricted, and a security group rule cannot express an
empty source.

To follow Azure's recommendation, set `aca_internal_load_balancer = true`. The environment
then has no public endpoint, and the rule admits only `VirtualNetwork`. Setting
`ingress_allowed_cidrs` alone does not change the rule, though it does restrict who the apps
accept requests from.

The front environment's subnet (`snet-front`, docs/networking.md "The environment subnets")
carries the same departure, for the same reason: its group's `allow-app-ingress` rule admits
`Internet` on TCP 80, 443, 31080 and 31443 in a public environment, and `VirtualNetwork` with
`aca_internal_load_balancer = true`. The app and workers subnets never admit either tag.

The IaC scan reports this as Trivy AZU-0047, and `.trivyignore.yaml` records it as an
accepted departure for `network.tf`. No Azure Policy built-in definition has been identified
that evaluates this rule.

## Scaling

How the apps scale, what each replica gets and the connection budget are documented in
[docs/scaling.md](docs/scaling.md).

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
- **Auth-configuration alert** — with `builtin_auth` set, an activity-log alert,
  `frontend-auth-config-write`, on every write to `ca-frontend`'s built-in authentication
  configuration: the recovery fallback turning the gate off or back on, a change made outside
  Terraform, or an apply that changes `builtin_auth`. Activity-log alerts take no severity. See
  [docs/identity.md](docs/identity.md#recovery-fallback-turning-the-frontend-gate-off-builtin_auth_recovery_until).

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
[docs/inputs.md](docs/inputs.md#the-installs-log-analytics-workspace).

Every query is signed in with Microsoft Entra ID. **Log Analytics Reader** on the workspace runs
queries, which is what the [diagnostic bundle](#diagnostic-bundle) needs; **Log Analytics
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

| Value of `enable_app_availability_diagnostics` | `mode = "production"` | Outside production |
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

## Diagnostic bundle

When you contact Masterly about an install, the conversation starts from what you send:
the install runs in your subscription, and Masterly can read nothing in it.
`scripts/diagnostic-bundle.sh` produces that in one action, from your own workstation, with
the `az` login you already have. It is the primary support channel for a self-hosted install
— an export you perform, not reporting the install performs. It sends nothing, nothing in
the install can be asked for one, and no telemetry setting is involved.

```bash
export MASTERLY_API_TOKEN=<an Organization-scoped token with ops:read>   # optional
./scripts/diagnostic-bundle.sh --subscription <id> \
  --request-id <the X-Request-Id of the failing call> \
  --api-url https://<the install's URL>
```

It needs `az` and `jq`, Reader on `rg-masterly-aca` and `rg-masterly-data`, and Log
Analytics Reader on the workspace. With `log_query_public_access = false`, run it from a network
that reaches the workspace through your Azure Monitor Private Link Scope (see
[The Log Analytics workspace](#the-log-analytics-workspace)). `--api-url` is the **api's** URL: reachable from your
workstation only when `api_ingress_external = true`, or from inside the VNet on the private
topologies — the frontend proxies `/v1` behind its own session cookie, not a bearer token.
Otherwise leave it out and attach the body from wherever your monitoring already polls it,
with `--ops-metrics <file>`. It writes a directory, `masterly-diagnostics-<prefix>-<timestamp>/`,
of plain JSON that you **read before you send**: the apps' configuration state, revisions and
replicas (the image tags actually running, which Terraform cannot tell you), the alert set
and whether anyone is listening to it, the six Log Analytics queries the public
[operations page](https://masterlydata.com/docs/self-hosted/operations/#before-you-contact-us)
publishes, the Key Vault operations that failed (`logs/q7`, read from `AZKVAuditLogs` and
summarised to operation, result code and count — no caller identity, address or secret name),
the starter server's shape, and `GET /v1/ops/metrics` when you give it a token or a file. `manifest.json` says what was collected and what was not, and why — a denied
permission is a named gap, never a silently empty file. Its `tool` field describes the tree the
script ran from (`git describe`, or the manifest's claim when there is no git tree, said as a
claim); that is **not** the version your install is pinned to, which the bundle cannot see —
state your pin in the message. Log Analytics is queried through
`az rest`, which is in the core CLI, so no extension has to be installable on the machine.

What it never carries, by construction:

- **No secret values.** Container App secrets are listed by name. An environment variable's
  value is copied only when its name is on the script's allow-list — the install's mode, ids,
  bindings and endpoints; every other value is omitted, not masked, including addresses,
  client ids and public key material.
- **No credential of yours.** The API token is read from the environment, sent once, and
  written nowhere. Registry credentials appear as "credential" or "managed-identity".
  Action-group receivers are counted, never listed.
- **Nothing read from a database, or from an API that serves records.** The sources are Azure
  Resource Manager, Log Analytics and `GET /v1/ops/metrics`. The bundle directory is written
  owner-only (mode 700).

**Record data: guaranteed for the apps' own log lines, and not for `logs/q6`.** `q1`, `q2`,
`q3` and `q5` export lines the applications redact at the formatter — identifiers, counts and
durations, no attribute values — and `q7` is the vault's audit log reduced to operation names,
result codes and counts. `logs/q6-postgres-logs.json` is not one of those: it is the
**starter Postgres server's own log stream** (`AzureDiagnostics` / `PostgreSQLLogs`), which no
Masterly formatter touches. A failing statement is logged with its text, which carries any
literal value written into it. The module sets the starter server to terse errors with no
bound parameter values, but a server that has not had that applied — or has had it changed —
also puts a constraint violation's conflicting values on a `DETAIL:` line. So `q6` can echo
values from your own records. `logs/q4-request-trace.json` projects an exception string,
which carries the same text when the error came from the database.

The script does not delete those lines — the statement that failed is often the whole
diagnosis — and it does not refuse the bundle over them either, because a tool that refuses to
hand over the evidence during an incident does not get used. It **names the files**: on the
terminal at the end of the run, and in `manifest.json` under
`record_data.needs_line_by_line_review`, which lists the files in *that* bundle that must be
read line by line — every one of the two above that the run collected, whether or not the
script found statement text in it. The script's scan for statement shapes (`STATEMENT:`,
`DETAIL: Key (…)`, `PARAMETERS:`) is a heuristic for what Postgres writes at its defaults; an
attribute value has no shape of its own, so the scan finding nothing is not the file being
clear, and a read-first instruction gated on the scan would go quiet exactly when it is least
able to tell (MAS-423). Where the scan did find statement text, the file is also listed under
`record_data.statement_text_found_in` and the terminal says so. Read the named files line by
line, delete any line you are not willing to send, and say in your message that you did.

Before it finishes it scans everything it wrote for anything shaped like a secret — a URL
with credentials, a JWT, a private key, a `password=` — and **refuses** a bundle that trips
the scan: exit 3, the directory renamed `-REFUSED` and kept for you to inspect, the finding
reported by file and line and never by content. A log line carrying a secret is a defect to
report, not a line to forward.

`tests/diagnostic_bundle_test.sh` is what makes those sentences checkable, and it keeps the
two strengths of claim apart rather than blurring them: each seeded secret, credential,
address and key is asserted **absent**, and the record-data class is asserted **present in
`q6` and flagged** — the value in the file, the file named in `manifest.json`, the operator
told on the terminal, and the run still exiting 0 — and a `q6` carrying a Postgres error with
no statement marker at all is asserted to be named just the same. Its `--selftest` breaks the
script seven ways — allow-list bypassed, secret values kept, refusal gate disabled,
statement-echo warning disabled, its pattern scan alone disabled, the review list seeded from
the scan alone, version taken from the release manifest — to insist the harness notices. CI
runs both on every change.

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
group has — can read it back in clear. That covers the DSN, the session secret, the BFF shared
secret, the licence JWT, the OIDC client secret, the Redis URL (access key and all), the
registry password and the telemetry secret. Deploy rights and read-every-credential rights were
the same thing.

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
   Vault Secrets User** — read only — on each of the frontend's own secrets, one assignment per
   secret and none on the vault: that app carries secrets of its own, the
   [BFF shared secret](#the-bff-shared-secret) on every install, resolves its own references and
   runs as `id-<prefix>-frontend`, not the backend identity. It cannot read the backend's
   secrets or anything the api seals in the vault.) If **plan and apply run as different service
   principals** — a common CI shape, and the one Masterly runs — pin them instead:
   `key_vault_secret_operator_object_ids` for the apply identity, and
   `key_vault_secret_reader_object_ids` (Secrets User) for the planning one, which needs read
   because `terraform plan` refreshes the seeded secrets. Left implicit in a two-identity
   setup, state holds the apply identity's grant and every plan proposes destroying it.
2. **A network path.** In `mode = production` the vault has no public presence, and
   `bypass = "AzureServices"` does *not* cover a CI runner — the trusted-services list is
   Azure services, not whoever is holding the token. So state one of — and the two shapes are
   not equals, listed here in the order Masterly recommends:

   - `key_vault_deployer_in_vnet = true` — the apply runs inside the install's VNet
     (self-hosted runner, jumpbox, VPN/ExpressRoute). **This is the recommended production
     path.** The vault's public endpoint stays off entirely, which is the posture
     `mode = "production"` was designed around and the one a security-conscious customer will
     accept. It costs a runner to provision, patch and pay for, per install. It is also a claim
     about **every** future run, including the one that tears the install down: an operator who
     sets it and then plans from a laptop gets the 403 above, on an install Terraform can no
     longer fully manage until the path exists. Declaring this from a hosted runner is a false
     claim — see the refresh warning above for what it costs.
   - `key_vault_deployer_ip_rules = ["203.0.113.7"]` — the egress address of the machine or
     runner that applies, owned by a NAT gateway fronting the runner or by a fixed apply host.
     This is the documented **smaller-scale alternative**, with its weaker posture stated
     plainly rather than buried: the vault's public endpoint stays **on**, behind its
     firewall — `default_action` stays `Deny`, and nothing but the listed addresses (and the
     private endpoint) gets in. Key Vault rejects `/31` and `/32`, so write a single address
     bare.

   Production refuses to plan with neither set. That is deliberate: the alternative is a 403
   partway through a ten-minute apply, with the install half-built. Which one you run is your
   choice as much as Masterly's recommendation — it costs a runner either way, once as
   infrastructure to operate and once as the posture a security review will ask about.

Entra RBAC is eventually consistent, so a **first** apply can land inside the propagation
window of the grant in (1) and fail with `Forbidden` on the first secret. Re-run the apply.
The module does not pad every apply with a fixed wait for a race only the first one can lose.

### Erasure keys belong in your secret backup

This applies to installs running an application release that carries **erasure of personal
data** (ADR 0081) and that have executed at least one erasure. Until you run such a release the
vault holds no erasure keys and nothing below is in force — but the backup habit is cheaper to
start before you need it than after.

An Environment that executes an erasure puts two keys of its own in this install's vault: a
**signing key** (a vault key, used to sign the erasure listings that keep the audit trail
verifiable after redaction) and a **suppression key** (a vault secret, used to recognise an
erased subject's keys if they arrive again). Both are reached at fixed names derived from the
Environment's id. That is deliberate — nothing points at them from the Environment's database,
so restoring a database cannot silently swap them.

Three consequences for whoever operates the install:

1. **Back both keys up, and keep the backup for as long as the erasures exist.** They are not
   in your Postgres backup, and a replacement is not a recovery: a fresh key is a different key,
   and nothing already recorded — a suppression entry, a signed listing — matches it.
   `az keyvault key backup` and `az keyvault secret backup` produce the blobs; store
   them with the same care as the vault itself. **An Azure Key Vault backup restores only into
   a vault in the same subscription and the same Azure geography** — a blob taken in one
   geography cannot be restored into another, so plan the restore destination before you need
   one.
2. **A vault recreated without that backup refuses key-addressed writes permanently.** With the
   suppression key gone, an Environment holding suppression entries cannot tell an erased
   subject's key from any other, so it refuses rather than risk recreating the subject — and no
   amount of later work recovers the key, because the values its entries were computed from are
   the ones the erasure destroyed. The only way out is the controller explicitly lifting those
   suppression entries, which gives up the protection they exist for. With the signing key gone,
   listings it signed can no longer be authenticated online, though exports taken earlier still
   carry its public key.
3. **After an erasure, that Environment depends on the vault to work at all.** Ingest, pipeline
   jobs, consume reads and Stream delivery each check what the vault holds — the key that
   recognises a suppressed arrival, and the mark that says the database is not behind the
   erasures already executed against it. With the vault unreachable or the grant missing they
   fail closed rather than skip the check, so vault availability is an availability concern for
   the data plane, not only for start-up.

The module's part in this is one role assignment: the apps identity gets **Key Vault Crypto
Officer** on the install vault, alongside its app secrets role on the vault, so the application
can create and use those keys. It is vault-scoped because the keys do not exist when Terraform
runs — the application creates each one, only if absent, at a name derived from an Environment
created long after the apply — and an Azure role assignment cannot name a key that does not
exist yet. Key Vault Crypto **User** cannot create a key, so Crypto Officer is the smallest
built-in role that fits. `keyvault.tf` carries the same reasoning beside the resource. In
`mode = "production"` the vault's purge protection means a key deleted in error stays
recoverable for the soft-delete window and cannot be purged at all.

## Rotating the session secret

The module generates the session signing secret (`random_password.session_secret`) and the
`api` signs every session token with it. Replacing it is a two-step operation, and doing it in
one step is an outage: the moment the new value takes traffic, every token signed with the old
one stops verifying and every signed-in user is signed out at once — with no warning to them
and nothing they can do but sign in again.

That matters most in the case you rotate for. A secret is replaced when it may have leaked,
and an operator weighing "sign everybody out now" against "wait for a maintenance window" will
sometimes wait, which is the worst of the three outcomes. So the `api` accepts **retired**
secrets for verification while they are configured, never for signing, and
`session_secret_previous` is how you say which:

1. **Read the value the install is signing with now.** With `enable_key_vault = true` it is the
   vault secret `install-session-secret`:

   ```bash
   az keyvault secret show --vault-name <your vault> \
     --name install-session-secret --query value -o tsv
   ```

   Without the vault it is in your state file, which is the other reason to treat that file as
   a secret store (below). Capture it **before** step 2 — replacing the resource is what makes
   the old value unrecoverable.

2. **Apply once, replacing the secret and naming the old one.** Put the value from step 1 in
   `session_secret_previous` (a `.tfvars` you do not commit, or `-var`), and replace the
   generated secret in the same apply:

   ```bash
   terraform apply -replace=random_password.session_secret
   ```

   New sessions are signed with the new value; existing ones keep working. Nobody is signed
   out. `ca-api` restarts, as it does for any secret change.

3. **Apply again once the window has elapsed, with `session_secret_previous` unset.** After
   that apply a token signed with the retired value is refused like any other stale token.

**How long to leave the window open:** until no session signed with the old value can still be
inside its lifetime — the install's session TTL, or the longest `max_session_hours` any
Organization in it has configured, whichever is greater. Longer is not safer. A retired key is
one you decided not to trust, and while it is listed the install still believes tokens signed
with it, so the window is exactly the cost of not signing everyone out. Each boot with one
configured logs `session.secret.rotation_window_open`, so an install that is still mid-rotation
says so.

The input takes a comma-separated list, for the case a second rotation starts before the first
window has closed. Every value in it is held to the same minimum as the secret it replaced —
32 characters at plan time here, 32 bytes of key material at startup in the `api` — because a
listed key verifies sessions exactly as well as the one that signs them.

> Reading the variable needs an `api` image that has it. Check the `MANIFEST.json` entry for
> the module version you are pinned to: with an image that predates it, the variable travels to
> the app and nothing reads it, so step 2 signs everyone out after all.

## The BFF shared secret

A break-glass sign-in made in the GUI does not reach the `api` from the browser. The browser
posts to the frontend's BFF, and the BFF calls the `api` server-side, so on its own the `api`
sees a frontend replica's address. The `api` keys its break-glass throttle and audit record on
the caller's address, so every GUI attempt would then share one throttle window: a few wrong
guesses from anyone would throttle the genuine break-glass sign-in through the GUI as well, and
the audit record would name the replica rather than the person.

The module generates a secret for this (`random_password.bff_shared_secret`) and sets it as
`MASTERLY_BFF_SHARED_SECRET` on `ca-api` and `ca-frontend`, and on no other app, as a Container
App secret (a Key Vault reference with `enable_key_vault`). The BFF states the browser's address
and presents the secret; the `api` believes that address only on a request carrying the same
value, so a caller who does not hold it cannot choose its own address, whether it reaches the
`api` through the BFF or directly on a published ingress (`api_ingress_external`).

It needs `api` image `v0.133.4` or later and `frontend` image `v0.139.0` or later. With an older
image on either app the variable reaches the container and nothing reads it, and GUI attempts
are throttled per frontend replica as before.

To rotate it, replace it:

```bash
terraform apply -replace=random_password.bff_shared_secret
```

One apply gives both apps the new value, but they do not start using it at the same moment:
without the vault each app rolls to a new revision of its own, and with `enable_key_vault` each
picks the value up from its versionless reference within about 30 minutes. While the two hold
different values the `api` ignores the BFF's statement and attributes GUI attempts to the
frontend replica, as it did before this secret existed; nothing fails because of the mismatch
itself. There is no second step: unlike the session secret, nothing is signed with it, so
nothing issued under the old value has to keep working.

## State security — your tfstate holds secrets in plaintext

Terraform writes **plaintext secrets into your state file**, and moving the app secrets into
Key Vault does not change that: Terraform is the thing writing them, so the values pass
through — and stay in — state either way. What shrinks is who can read them at *runtime*,
not what is in the state blob. For this module the state contains, among others:

- the **generated Postgres admin password** (`random_password.postgres_admin` — only its
  hash never leaves; the value is in state and in the app's DSN secret)
- the **generated session secret** (`random_password.session_secret`)
- the **generated BFF shared secret** (`random_password.bff_shared_secret`)
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
- **Rotate** on exposure: the Postgres/session/BFF/Redis material is module-generated, so a
  `terraform apply` after tainting the relevant `random_*`/cache regenerates it; the OIDC and
  license secrets rotate at their source. The session secret has a second step, or the
  rotation signs out every signed-in user — see
  [Rotating the session secret](#rotating-the-session-secret). With `enable_key_vault`, a rotation applied straight
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

The per-install Entra identity toward Masterly's control plane (ADR 0020).

## Versioning

Semver tags are the Stable releases. A Stable install pins a registry `version` constraint, or
`?ref=vX.Y.Z` from GitHub. Canary and Beta builds have no tag: see
[Installing a Canary or Beta build](#installing-a-canary-or-beta-build).
The module version is the one customer-facing version of a Stable release (ADR 0062): the tag,
the registry version and the pin in the docs are all the same number.

What each kind of release means — for the module, and for the `api` and `frontend` images it
names:

| Release | What it may contain | What you do |
|---|---|---|
| Patch (`X.Y.Z` → `X.Y.Z+1`) | Fixes only: no new capability, no new Terraform input, no new required setting, no database migration | Take it without reading the changelog. An image patch rolls with `az containerapp update` and rolls back by redeploying the previous image. |
| Minor (`X.Y` → `X.Y+1`) | New capabilities, new inputs or settings, migrations. Before 1.0.0, also breaking changes, listed under their own heading in the changelog | Read the changelog, `terraform apply` the new module version, and roll the images its manifest entry names. |
| Major (from 1.0.0) | A breaking change to an input, an output or a generally available contract | Read the migration guide first. |

The versions stay on 0.x until Masterly's general availability. At that point the module and both
images move to 1.0.0 together, and from then on a breaking change bumps the major rather than the
minor.

A module release bumps at least as far as the images it names: if either image moves by a minor
between one release's manifest entry and the next, the module release is a minor too. So a module
patch never moves an image by more than a patch, and a `~> X.Y.0` pin never brings you a minor
release of either image. `scripts/check_release_manifest.py` refuses a release that breaks this.

[`MANIFEST.json`](MANIFEST.json) is the machine-readable statement of what each published
version was released against, and [`CHANGELOG.md`](CHANGELOG.md) is what changed. Read the
manifest rather than copying out of this table — the table itself is generated from it:

<!-- release-manifest:begin -->
| Module version | `api_image` | `frontend_image` | Released |
|---|---|---|---|
| `0.24.0` | `masterly.azurecr.io/release/api:v0.137.0` | `masterly.azurecr.io/release/frontend:v0.145.0` | 2026-11-10 |
| `0.23.0` | `masterly.azurecr.io/release/api:v0.135.0` | `masterly.azurecr.io/release/frontend:v0.143.0` | 2026-11-05 |
| `0.22.0` | `masterly.azurecr.io/release/api:v0.135.0` | `masterly.azurecr.io/release/frontend:v0.143.0` | 2026-10-29 |
| `0.21.0` | `masterly.azurecr.io/release/api:v0.134.0` | `masterly.azurecr.io/release/frontend:v0.142.0` | 2026-10-28 |
| `0.20.0` | `masterly.azurecr.io/release/api:v0.134.0` | `masterly.azurecr.io/release/frontend:v0.142.0` | 2026-10-23 |
| `0.19.1` | `masterly.azurecr.io/release/api:v0.134.0` | `masterly.azurecr.io/release/frontend:v0.142.0` | 2026-10-22 |
| `0.19.0` | `masterly.azurecr.io/release/api:v0.134.0` | `masterly.azurecr.io/release/frontend:v0.142.0` | 2026-10-22 |
| `0.18.0` | `masterly.azurecr.io/release/api:v0.133.13` | `masterly.azurecr.io/release/frontend:v0.141.0` | 2026-10-19 |
| `0.17.0` | `masterly.azurecr.io/api:v0.133.11` | `masterly.azurecr.io/frontend:v0.139.5` | 2026-10-05 |
| `0.16.0` | `masterly.azurecr.io/release/api:v0.133.5` | `masterly.azurecr.io/release/frontend:v0.139.0` | 2026-09-24 |
| `0.15.0` | `masterly.azurecr.io/release/api:v0.133.2` | `masterly.azurecr.io/release/frontend:v0.138.2` | 2026-09-07 |
<!-- release-manifest:end -->

The image pair is what the module version was released against — the pair Masterly's own
install ran when the version was tagged. Your install's running tags move on from it: the
module seeds a newly created app and then ignores image drift, so CD owns the tag thereafter.
Read on `main` rather than on a release tag, the newest row can be a release that is cut but not
tagged yet; a version is published once its `vX.Y.Z` tag exists.

<!-- release-manifest:floors:begin -->
Each app has a floor: the oldest image an install can run. Below it the image misbehaves
in a way no plan can see, so never pin an image older than its floor, whichever release
you start from. The floors, and the image tags that have no published image, are the
manifest's `image_floors`:

- An `api` image older than `v0.132.2` registers no job handlers on ca-workers, so the pipeline is silently inert.
- The `api` tags `v0.133.9`, `v0.133.10`, `v0.133.11`, `v0.133.12` have no published image.
- A `frontend` image older than `v0.138.2` leaves a fresh install unable to create its first Environment.
<!-- release-manifest:floors:end -->

If you are reading the manifest from a program rather than from this page,
[docs/release-manifest.md](docs/release-manifest.md) is the contract: where to fetch it, every
field with its type, which of them are stable and which may be added without warning. Parse
that shape; do not scrape this table.

[`RUNTIME_ENV.json`](RUNTIME_ENV.json) is the manifest's sibling for the other thing a release
fixes: every environment variable the module sets on `ca-api`, `ca-workers` and `ca-frontend`,
by name and per app. It is generated from the `.tf` files by
`python3 scripts/check_runtime_env.py --write`, checked on every change by the same script, and
documented for programs in [docs/runtime-env.md](docs/runtime-env.md). The application
repositories check their own code and runbooks against it.

CI checks `terraform fmt` + `validate` + `terraform test` (mock providers exercise the variable
guards and both data-plane branches) on every change, and
`scripts/check_release_manifest.py` fails any change where the manifest, the changelog and this
README stop agreeing — and any change where a script this module ships hand-types a module
version in its header, which is not something a file copied unchanged into every release can
truthfully say about itself.

A scheduled check (`.github/workflows/public-docs-module-pin.yml`) compares the version the
public [self-hosted docs](https://masterlydata.com/docs/self-hosted/install/) tell customers
to install against the newest version on the registry, so a release cannot quietly leave the
walkthrough a customer follows behind. It reads two public endpoints and holds no credential.

### Cutting a release

Release-please is deliberately not used here: the module's version is a release decision, not
one computed from commit messages. So the bump is made by hand — but not the copies of it.

A release happens in two separate steps. First the **release-cut commit** — the manifest entry
and the changelog section for the new version — merges to `main` through a pull request. That
merged commit, with the images it records, is a release candidate: it is tested before anything
is published. Tagging it is a later step, and the tag is what publishes. Until then `main`
carries an entry for a version the registry does not serve yet, which every check here accepts.

The release-cut pull request, in one commit:

1. Add the version to `MANIFEST.json` (`releases`, plus `latest`), naming the `api` and
   `frontend` images the release is tested against. That pair is what Masterly's own install
   has applied — take it from the install, not from prose. Choose the version by the rules in
   [Versioning](#versioning): at least as large a bump as the module's own change needs, and at
   least as large as the larger of the two image bumps since the previous release. The check
   in step 4 refuses a module bump smaller than an image bump, naming both. Record the `api`
   image's `api_claims_version` in the entry too: the licence claims version that build
   verifies, which is `CLAIMS_VERSION` in its licence verify half at that image's tag, or 0 for a
   build that has none. The plan reads it to refuse a licence the image cannot run on, so the
   check in step 4 refuses an entry without it, or one lower than an older `api` image's.
2. Record the candidate's image digests in the entry's `digests` (`api` and `frontend`, each
   `sha256:…`), read from the registry rather than copied from prose.
   [docs/release-manifest.md](docs/release-manifest.md) documents the field.
3. Run `python3 scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`. It folds every fragment in
   `changelog.d/` into a `## [X.Y.Z] - YYYY-MM-DD` section directly below the empty
   `## [Unreleased]`, merges the subsections in a fixed order, and deletes the fragments it
   folded, so they leave in this same commit. It refuses an unknown heading or text outside a
   subsection, names the file, and writes nothing. `changelog.d/README.md` says what a fragment
   is. The tag build refuses a tree that still has a fragment.
4. Run `python3 scripts/check_release_manifest.py --write` to bring this README into line, and
   `python3 scripts/check_release_manifest.py` to check the result. CI runs the same check, and
   it checks the digests' shape only, because it makes no network call. To check that each
   digest is what its image tag resolves to, write the digests you read from the registry to a
   file, one `"<image>": "sha256:…"` pair for each image the entry names, and run
   `python3 scripts/check_release_manifest.py --observed-digests <file>`. It refuses a
   disagreement and names both digests. Say in the pull request that you ran it.
5. Merge. The merged commit is the candidate.

If the candidate fails its tests, it is not patched. The fix merges to `main`, and the version's
manifest entry and changelog section are updated in the same pull request: new images and
digests where the code changed, and the new date. The fragments that merged since the previous
candidate are folded by running `scripts/fold_changelog.py X.Y.Z YYYY-MM-DD` again, which merges
them into the version's existing section and sets its date. That later commit is the next
candidate. A version is not published until it is tagged, so its entry can still change until
then.

More than one cut can be untagged at a time, but a version is only tagged once every other
version its commit's manifest lists is already tagged, so the file at every tag lists only
published versions. A cut that will not be released has its manifest entry and changelog section
removed before another version is tagged. `cut-release` refuses otherwise, naming the untagged
version.

Tagging, later and separately:

6. Read the open live checks in
   [docs/releasing.md](docs/releasing.md#live-checks-before-the-next-tag): a version is not
   tagged while one is open for a change it carries. Then wait for `main`'s CI run on the
   candidate's commit to pass, and run the **cut-release**
   workflow (Actions → cut-release → Run workflow, from `main`) with the version and the
   candidate commit's full SHA. That commit may be behind `main`'s head, and every other version
   its manifest lists must already be tagged. Do not create the tag by hand.
7. After the registry publishes the version, the public
   [self-hosted docs](https://masterlydata.com/docs/self-hosted/install/) adopt it — and the
   install page's upgrade notes ("Coming from module N.x") are rewritten for the new release as
   part of that, because the docs' own check refuses the adoption until they are. Until the docs
   name the new version, the scheduled check above goes red.

A tag on this repository is the release: the Terraform Registry publishes the version from its own
webhook the moment the tag appears, and a published version cannot be withdrawn, only superseded.
So the checks that can refuse a release have to run before the tag exists. `cut-release`
(`.github/workflows/cut-release.yml`) creates the tag only after `scripts/release_gate.py` finds
that the most recent CI run from the commit's push to `main` concluded success and that the tag
does not exist yet, that the commit is on `main`, and that the commit's own manifest, changelog
and README publish exactly this version.

`cut-release` also refuses the tag until every default image of the stable and previous channels
resolves in `masterly.azurecr.io`: the images an install of the release pulls when it leaves
`api_image` and `frontend_image` null. Its `images` job reads the release commit's `MANIFEST.json`
as data and runs `main`'s `scripts/check_release_images.py` against it. Stable is `latest`;
previous is the newest older release with no `known_issue`. For an entry with `digests` it checks
`release/<role>@<digest>`, and that the tag the entry names resolves to that same digest; for one
without, `release/<role>:<tag>`. Each reference that does not resolve, or a tag at a digest the
entry does not record, is named in the failure. 0.22.0 and 0.23.0 were tagged naming builds the
registry did not have; this is the check that would have refused them.

It reads the registry with the repository-scoped ACR token `pull-ci-cut-release` on the
`pull-product-images` scope map, which can pull `release/api` and `release/frontend` and nothing
else: it cannot push or delete, and cannot read `license-issuer`, `telemetry-receiver` or
`web-chat`. The token is held by the `release` Environment only, never as a repository or
organization secret: its name in the Environment variable `RELEASE_ACR_TOKEN_NAME`, its password
in the Environment secret `RELEASE_ACR_TOKEN_PASSWORD`. When either is unset the job fails naming
it, and no tag is created: the check is never skipped. Before anything reads the credential, the
job refuses a run dispatched from any ref other than `main`. To run it yourself, against `main`'s
manifest or a candidate's (the password is read without echo and never put on a command line):

```bash
export RELEASE_ACR_TOKEN_NAME=pull-ci-cut-release
read -rs RELEASE_ACR_TOKEN_PASSWORD && export RELEASE_ACR_TOKEN_PASSWORD
python3 scripts/check_release_images.py --manifest MANIFEST.json
```

CI still runs the same manifest check on the tag build with `--tag`. When every check on the tag
build passes, CI publishes the tag's GitHub Release with that version's changelog section as its
body (`scripts/release_notes.py`). The registry has already published the version by then, so the
tag build reports; it does not refuse.

**What makes `cut-release` the only path.** Since 2026-11-05 the `release-tags` ruleset refuses
creating, moving or deleting a `v*` tag by anyone except the release GitHub App
`masterly-module-release`, which `cut-release` uses. A tag pushed by hand is refused, so it cannot
publish. The ruleset is a repository setting rather than anything in this tree;
[docs/releasing.md](docs/releasing.md) records the exact settings.

## Installing a Canary or Beta build

Masterly ships in rings: Canary, Beta and Stable. Only Stable has a semver tag and a Registry
version. A Canary or Beta build is never tagged and never published to the Terraform Registry, so
you source the module by commit and pin the images by digest. Before 1.0.0, Canary runs on STG
only, so a customer install that reads this section is a Beta install.

Source the module from the exact commit Masterly gives you. Use the full commit hash, and do not
add a `version` argument: Terraform refuses one on a Git source.

```hcl
module "masterly" {
  source = "git::https://github.com/masterly-data/terraform-azurerm-masterly.git?ref=<commit>"

  # api_image and frontend_image: see below. Everything else is as for a Stable install.
}
```

Pin both images by digest: a tag pinned by digest, or a digest alone. `api_image` and
`frontend_image` each take one of three forms, and the plan refuses any other:

- `<registry>/<path>/api:<tag>` — a tag alone;
- `<registry>/<path>/api:<tag>@sha256:<digest>` — a tag pinned by digest;
- `<registry>/<path>/api@sha256:<digest>` — a digest alone, e.g. `masterly.azurecr.io/release/api@sha256:<digest>`.

`frontend_image` takes the same forms with `frontend` as the repository's last segment. The
digest is `sha256:` followed by 64 lowercase hex characters, and the repository's last segment
must be the role: `api` for `api_image`, `frontend` for `frontend_image`. `<registry>` is a host
that contains a `.` or a `:` (a port), or `localhost`; a reference without one would be read as
Docker Hub, so the plan refuses it.

The references come from the build's ring record or from the bundle Masterly sends you.
[`MANIFEST.json`](MANIFEST.json) does not record a Canary or Beta build. So the plan-time check in
[A renewed licence and the api image it runs on](#a-renewed-licence-and-the-api-image-it-runs-on)
passes such a build unchecked, whether you pin it by tag, by tag and digest, or by digest alone.
The application's own check at startup still applies.

Your licence names the rings your install may run. This module version does not check the
licence's ring at plan, preflight or boot. Run only the rings your licence names.

### Moving to Stable

When the build you run is released, the same commit is tagged `vX.Y.Z` and the Registry publishes
it. Moving to the Registry changes only where the same commit comes from.

1. Change `source` to `masterly-data/masterly/azurerm` and add `version = "= X.Y.Z"`, with the
   release number Masterly names for your commit. Change nothing else in that step.
2. Run `terraform init -upgrade`.
3. Run `terraform plan`. Expect no change.

If the plan shows any change, the commit you run is not the tagged one. Stop and do not apply.
Ask Masterly which commit `vX.Y.Z` is.

Move the images to the Stable references separately, after that plan is clean. Set the new
`api_image` and `frontend_image` values, then roll the apps as the sections above describe:
`terraform apply` does not roll a running image. Semver tags are
what [Versioning](#versioning) describes from here on.

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
configuration. It constrains azurerm to `~> 5.8`, random to `~> 3.6` and azapi to `~> 2.9`
(used for [built-in authentication](docs/identity.md#built-in-authentication-in-front-of-the-frontend-builtin_auth) and to start [the migrate job](docs/data-plane.md#the-migrate-job)),
and leaves the exact versions to you. That
floor is load-bearing rather than housekeeping: with no lock file here, the constraint is the
only thing governing your `terraform init`. `versions.tf` records why it sits where it does.

azurerm 5 changes one thing in **your** root configuration rather than in the module: the
provider no longer registers resource providers on the subscription by default
(`resource_provider_registrations` now defaults to `none`). Run `scripts/preflight.sh` against
the subscription before the first apply, with `--register` if it reports a provider as
unregistered; it checks exactly the set this module needs. Setting
`resource_provider_registrations = "legacy"` in your provider block restores the v4 behaviour,
which registers a set of about sixty providers, most of which this module does not use.

Moving an existing install from azurerm 4 to 5 is a provider major and a breaking module
change; the steps are in [CHANGELOG.md](CHANGELOG.md). Plan with refresh on (the default) for
that first plan: the private DNS zone links (Postgres, Key Vault, Redis and a private Service
Bus namespace, whichever your install has) change how they name their zone, and only a
refreshing plan sees that their Azure resource IDs did not move.
