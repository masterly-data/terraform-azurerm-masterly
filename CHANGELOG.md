# Changelog

Notable changes to the `masterly-data/masterly/azurerm` Terraform module.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org/). Every version published since 0.15.0 also has an entry in
[`MANIFEST.json`](MANIFEST.json), which names the `api` / `frontend` image pair that version was
released against — `scripts/check_release_manifest.py` fails the build if the two disagree. The
shape a program can rely on when it parses that manifest is
[docs/release-manifest.md](docs/release-manifest.md).

A change adds a fragment, `changelog.d/<short-name>.md` (see
[changelog.d/README.md](changelog.d/README.md)), and leaves **Unreleased** empty. Cutting a release
runs `scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`, which folds the fragments into the version's
section and deletes them, and adds the matching `MANIFEST.json` entry, in the same commit, which
merges to `main` before the version is tagged; see "Cutting a release" in the
[README](README.md#cutting-a-release).

Releases before 0.15.0 predate this file. Their entries below were reconstructed after the fact
from the git tag messages and the pull-request titles those tags carry, so they say what each
release was *for* rather than giving a line-by-line account of what it contained — read the tag
and the commits between it and its predecessor if you need that. They also have no
`MANIFEST.json` entry: the image pair each was tested against was never recorded at the time, and
inventing one now would be exactly the retyped-value failure the manifest exists to end.

## [Unreleased]

## [0.26.0] - 2026-11-23

### Added

- **`ca-edge` renders the ca-serve route set, still answered by `ca-api` (ADR 0120 §2).** With `edge` set, the edge now has one route for each read the backend marks `x-masterly-serve`: 17 routes (12 `GET`, 5 `POST`), listed in `edge-serve-routes.json` at the module root as the backend's `docs/contract/edge-routes.json` published them at api v0.138.0. Each is matched on the method exactly and on the path, after the `413` guards and before `/v1`, and is **forwarded to `ca-api`**, with the same Host, timeout and rate limits as `/v1`: no request is answered differently. When `ca-serve` passes its gate, moving these reads to it changes only the cluster they forward to. The list is read from the module's own files at plan time, never fetched, and `scripts/check_edge_serve_routes.py` (run in CI) holds it to reads (`GET`, `HEAD`, `POST`) under `/v1/`. The routes change the Envoy configuration, so **applying this version rolls a new `ca-edge` revision**. With `edge` unset nothing changes. See `docs/networking.md`, "The edge proxy".
- **`builtin_auth.forward_proxy`: the platform sign-in gate behind a reverse proxy.** With a proxy in front of `ca-frontend` that replaces the `Host` header, such as Azure Front Door sending the app's default hostname, built-in authentication built its callback from that hostname and Entra refused the redirect. `forward_proxy = { convention = "Standard" }` makes it read `X-Forwarded-Host`, which Front Door sets and overwrites; `convention = "Custom"` names other headers (`custom_host_header_name`, `custom_proto_header_name`). Unset, the auth configuration is written exactly as before, so **upgrading plans no change**. Set it only when every request reaches `ca-frontend` through the proxy. See `docs/networking.md`, "Behind a reverse proxy".
- **`edge_ingress_allowed_cidrs`: `ca-edge`'s own allowlist.** Null (the default) uses `ingress_allowed_cidrs`, as before, so **upgrading plans no change**. Set it when the frontend admits only a proxy's addresses while SDK and MCP clients reach the edge directly. An empty list is refused, as for `ingress_allowed_cidrs`.
- **`front_door_id`: `ca-frontend` admits only your Front Door.** Front Door's addresses are shared by every Front Door profile in Azure, so an ingress allowlist of them admits anyone's profile pointed at your origin. Set `front_door_id` to your profile's id, and `ca-frontend` refuses with `403 FRONT_DOOR_REQUIRED` every request whose `X-Azure-FDID` is not exactly that id; the health probes' `/api/healthz` and `/api/readyz` are exempt. It sets `MASTERLY_FRONT_DOOR_ID`, which needs a frontend image that reads it. Null (the default) sets nothing, so **upgrading plans no change**. See `docs/networking.md`, "Behind a reverse proxy".
- **An alert on a sustained rate of 401s from `ca-api`, while `builtin_auth_api` is on.** With `builtin_auth_api = true` the module creates `alert-<name_prefix>-api-401` (severity 1): more than 20 responses with status 401 in a 15-minute window, evaluated every 5 minutes, routed through `alert_email` or `alert_action_group_id`. A wrong allowed-client list on the api's gate refuses every call from `ca-frontend` and `ca-edge` and trips no health check; this is the detection for it. It is created whatever `enable_diagnostics` says, reads the platform `Requests` metric, and adds one metric alert rule to your Azure bill. The metric also counts the application's own 401s, which are occasional and sit below the threshold. Nothing else changes when the switch is toggled.
- **`builtin_auth_api` turns on built-in authentication on `ca-api`, off by default (ADR 0120 §2).** With `builtin_auth` set and `builtin_auth_api = true`, `ca-api` admits only a token issued to `ca-frontend`'s workload identity (`id-<prefix>-frontend`) and, with `edge` set, `ca-edge`'s (`id-<prefix>-edge`), validated against `builtin_auth`'s registration: callers must request the token for the audience `builtin_auth.client_id`. Everything else gets `401`, on every path, with no redirect; a browser sign-in for the same registration is refused, and the deprecated `builtin_auth.api_allowed_applications` and `api_allowed_audiences` stay ignored. The recovery fallback, `builtin_auth_recovery_until`, turns this gate off too while its window is open (see Changed), and with the switch on, `api_ingress_external` no longer warns that the published api is ungated. The switch is refused without `builtin_auth`. **Turn it on only once the `ca-frontend` and `ca-edge` releases you run send their workload-identity token:** before that, `ca-api` refuses every call the frontend's server makes on a user's behalf and the application is unusable until the switch is turned off again, as happened with 0.19.x on 2026-10-22. Turning it on creates `ca-api`'s `authConfigs/current` (`azapi_resource.builtin_auth["api"]`, the address 0.19.0 and 0.19.1 used) and changes neither app: `ca-api` already carries `builtin_auth_client_secret`. Left unset, nothing changes. See `docs/identity.md`, "The api's gate".
- **`ca-edge` now has the diagnostic setting and the availability alerts the other apps have.** An install with `edge` set creates, on its next apply and with no variable changed, `diag-<name_prefix>-edge` (an `AllMetrics` diagnostic setting, metrics only), `alert-<name_prefix>-edge-unavailable` (severity 0, in every mode, whatever `enable_diagnostics` says), `alert-<name_prefix>-edge-5xx` (with diagnostics on) and `alert-<name_prefix>-edge-silent` (with app availability diagnostics on, the production default). Before this, an edge outage, or an Envoy answering 503 because it cannot reach `ca-api`, paged nobody, although `ca-edge` is the only way in for REST, SDK and MCP callers once `ca-api` is internal. In production this adds one more `AllMetrics` stream to your workspace's ingest and one more log search rule billed per evaluation to your Azure bill; `enable_app_availability_diagnostics = false` turns those two off and keeps `edge-unavailable`. `edge-5xx` also counts the api's 5xx that Envoy passes through. `app-not-ready` does not cover `ca-edge`: Envoy writes no readiness line.
- **`edge.jwt_authn`: token validation on `ca-edge`, off by default.** Unset (null, the default),
  `ca-edge` is configured exactly as before and does no authentication of its own. Set it to
  `{ audiences = [...] }` and `ca-edge` validates the bearer token in the `Authorization` header on
  `/v1` (the ca-serve routes included) and `/mcp` before forwarding: signed by the install's Entra
  tenant's keys, unexpired, issued by that one tenant and carrying one of `audiences`. A request
  with no token or a token that fails is refused by the edge and never reaches `ca-api` (`403`
  for a valid token whose `aud` is not in `audiences`, `401` for anything else); a
  token that passes reaches `ca-api` unchanged, and `ca-api` still checks it. The edge trusts
  exactly one issuer: with `edge.jwt_authn` set, the plan is refused unless
  `oidc_allowed_issuers` is the single `https://login.microsoftonline.com/<tenant GUID>/v2.0` and
  `oidc_jwks_uri` is that tenant's `/discovery/v2.0/keys` (as `oidc_tenant_id` sets them), and
  unless `audiences` lists at least one non-empty value. `ca-edge` then reaches
  `login.microsoftonline.com` on 443 itself for the signing keys, through `egress_firewall` when
  that is set. The rate limits are unchanged. Setting it rolls a new `ca-edge` revision; see
  `docs/networking.md`.
- **`environment_zone_redundant`: zone redundancy for the front, app and workers Container Apps environments (ADR 0120, 2026-11-20 amendment).** Off by default, so an upgrade plans no change. On, Azure spreads each environment and its apps' replicas across the region's availability zones. Azure fixes it when it creates an environment, so turning it on for an existing install replaces all three environments and the apps in them; choose it when you create the install. It needs a region with availability zones, is refused on an install without the three environments, and does not cover `aca-<name_prefix>`. The plan warns (`environment_zone_redundancy_needs_two_replicas`) when `ca-api`, `ca-frontend` or `ca-workers` runs there with a minimum below two replicas. For an install that must survive a zone failure, set `postgres_zone_redundant_ha = true` too. See `docs/networking.md`, "Zone redundancy".

### Changed

- **`ca-edge`'s `/v1` rate limiter is set once on the virtual host, so the ca-serve routes share it with `/v1`.** One limiter, with one set of buckets, now covers `/v1` and every ca-serve route: a token or client address has one `/v1` budget, as before, rather than one per route. `/mcp` keeps a limiter of its own, and the `413` and `404` answers are still never limited. The limits and their defaults are unchanged.
- **With `builtin_auth_api`, the recovery fallback `builtin_auth_recovery_until` now turns `ca-api`'s built-in authentication off too, and every write to `ca-api`'s auth configuration is alerted (ADR 0117, amended 2026-11-02, item 5).** Under an Entra outage neither `ca-frontend`'s nor `ca-edge`'s workload-identity token can be issued, so `ca-api`'s gate would refuse every call; while the window is open, the api's `authConfigs/current` has `platform.enabled = false` alongside the frontend's, and the first plan after the time turns both back on. The window's bounds are unchanged: at most 60 minutes, `builtin_auth` set, and a network restriction in front of `ca-frontend`. Only the gates change: the rest of both configurations, and `ca-api`'s and `ca-workers`' ingress and environment, are as with the window closed, so the application's own authentication stays in front. **An install with `builtin_auth_api = true` plans one new activity-log alert**, `azurerm_monitor_activity_log_alert.builtin_auth_api_config_write[0]` (`alert-<prefix>-api-auth-config-write`), which fires on every write to `ca-api`'s auth configuration (the disable, the restore, or a change outside Terraform) and notifies the install's action group; it exists whenever the switch is on, not only during a window. The frontend's alert, `alert-<prefix>-frontend-auth-config-write`, keeps its address and is not replaced. Without `builtin_auth_api`, nothing changes. See `docs/identity.md`, "Recovery fallback".
- **`ca-edge` declares TCP liveness and readiness probes on its listener port (8080).** Azure applied default TCP probes already; they are now stated and tuned (the readiness failure budget allows a slow Envoy start). Envoy's admin interface stays unconfigured and the route list is unchanged. The next apply rolls a new `ca-edge` revision.
- **Zone-redundant Postgres HA is off by default on every capacity profile, and `mode = "production"` no longer requires it (ADR 0120, 2026-11-20 amendment).** `postgres_zone_redundant_ha` now defaults to `false` instead of `null`, and no `capacity_profile` turns it on: `standard` and `enterprise` size the SKU, the pooler and the replica floors only. By default the install's Container Apps environments are not zone-redundant (see `environment_zone_redundant`), so the standby protects the data more than it protects uptime, at twice the server's compute. Without it, a zone failure is recovered by a point-in-time restore (Azure documents up to 5 minutes of data loss). `mode = "production"` with `capacity_profile = "enterprise"` and HA off plans with a warning, `enterprise_production_without_postgres_ha`, because the enterprise profile's recovery objectives assume the standby. `postgres_zone_redundant_ha = true` on a burstable SKU is still refused. See `docs/scaling.md`, "Zone-redundant HA".

  **Migration.** An install that set `capacity_profile = "standard"` or `"enterprise"` and left `postgres_zone_redundant_ha` unset had a standby, and on this version plans removing it, an in-place update that restarts the server. To keep the standby, set `postgres_zone_redundant_ha = true` before you upgrade. An install that sets the input explicitly, or sets no profile, plans no change. The input is no longer nullable: an explicit `postgres_zone_redundant_ha = null` (for example passed through from a wrapper variable) now means `false`, the default, rather than the profile's value.

### Fixed

- **Moving a workload between environments no longer fails on the first apply.** A change to `workers_environment`, `migrate_job_environment`, `frontend_environment`, `edge_environment` or `api_environment` replaces `ca-workers`, `caj-migrate`, `ca-frontend`, `ca-edge` or `ca-api` under the same name, and Azure refused the create while the old one was still pending deletion (`FailedIdentityOperation`, 409 or 400), leaving the install down until a re-run. The apply now waits 180 seconds between deleting each moved workload and creating it again, through one `time_sleep.environment_move` per workload that exists, so each moved workload is down for that wait. An upgrade plan adds only those `time_sleep` objects and replaces no app or job, and a fresh install does not wait. The wait is a destroy wait, so a full `terraform destroy` waits once as well. If Azure still refuses with `FailedIdentityOperation`, re-running the same apply completes the move. See `docs/networking.md`, "Retiring the runtime environment".
- **Re-running a failed `cut-release` run with only its failed jobs now works.** That kind of
  re-run reuses the `verify` job's outputs from the earlier attempt, so after a run had created
  the tag and then failed, the `tag` job tried to create the tag again and failed with `Reference
  already exists`. The `tag` job now reads where the tag is before it writes. If the tag is at the
  release commit, it skips the write and still sends `release-published`; if it is at another
  commit, the run is refused. Internal release tooling only: no input, output or resource changes,
  so an install plans no change.
- **`ca-edge` no longer sends MCP and SDK clients to an address they cannot reach.** A request to
  exactly `/mcp` is now forwarded to `ca-api` as `/mcp/`, so `ca-api` no longer redirects it, and
  `/mcp` works with or without the trailing slash. Any redirect `ca-api` does send whose `Location`
  names the internal host the edge forwards to (`http://ca-api`, or `https://ca-api.<app environment
  domain>` with `api_environment = "app"`) is rewritten to a reference relative to the edge, never
  to the caller's Host, or removed when it cannot be made relative; other `Location` values are
  unchanged. No input or output changes; with
  `edge` set, the next apply rolls a new `ca-edge` revision.

## [0.25.0] - 2026-11-20

### Added

- **`deployed_switches` input.** A list over `assets`, `media`, `extensions` and `replica`, written to `ca-api` and `ca-workers` as `MASTERLY_DEPLOYED_SWITCHES`, comma-separated in the order given, so an install can declare durably which deployment switches it has (api `v0.136.0` and later read it). The default, `[]`, sets nothing, so an existing install plans no change. A name outside the four, or a repeated name, is refused at plan.
- **The front, app and workers environment subnets (ADR 0120).** On a network the module builds, three subnets delegated to `Microsoft.App/environments`, `snet-front`, `snet-app` and `snet-workers`, sit beside `snet-aca` for the workload-profiles environments the apps will move into. Each has its own network security group ending in deny-all-inbound: the front admits TCP 80 and 443 from `Internet`, or from `VirtualNetwork` with `aca_internal_load_balancer = true`; the app subnet admits HTTPS from the front subnet only; the workers subnet admits no caller. All three carry the Container Apps platform rules. The private-endpoint subnet's group admits the app and workers subnets on the data-plane ports, and never the front subnet. New inputs `front_subnet_prefix`, `app_subnet_prefix` and `workers_subnet_prefix` (all three or none, each /27 or larger, inside `vnet_address_space` and clear of every other subnet); with none set, a first VNet prefix of /21 or larger derives the /24s at index 5, 6 and 7. New outputs `environment_subnet_ids` and `environment_subnet_prefixes`. docs/networking.md, "The environment subnets", has the rules and the spoke sizes.
- **`front_subnet_id`, `app_subnet_id` and `workers_subnet_id` for an injected network.** All three or none, three different subnets that are neither `aca_subnet_id` nor `private_endpoints_subnet_id`, in `aca_subnet_id`'s VNet; the plan refuses anything else. The module attaches no network security group to them; docs/networking.md gives the baseline they should carry.
- **`edge` input: ca-edge, an Envoy machine entry point, off by default.** Set, it runs `ca-edge` in the install's Container App Environment (ADR 0120 §2) as its own identity, `id-<prefix>-edge`: published HTTPS-only on `ingress_allowed_cidrs` (an empty list is refused at plan), it forwards `/v1` and `/mcp` to `ca-api` and answers every other path with 404. It removes `x-jwt-payload` and the `X-MS-CLIENT-PRINCIPAL*` headers, refuses a declared body over `edge.max_request_body_bytes` (10 MiB by default) with 413, keeps streamed MCP and server-sent-events responses open, has no admin interface, runs as the image's unprivileged `envoy` user rather than root, and logs no query string or credential header. It does **no authentication yet**: the `Authorization` header reaches `ca-api` unchanged, and `ca-api` checks it. The image defaults to the upstream `envoyproxy/envoy` v1.40.2 on Docker Hub, pinned by digest; `edge.image` takes a mirror, which must carry a digest, and a change rolls the app. Its identity gets AcrPull only for an image on the install's registry, and no other role. New outputs `edge_url` and `edge_identity_principal_id`. Unset (the default), an install plans no change. docs/networking.md covers the allowlist, the egress to Docker Hub or your mirror, and running the edge behind an Application Gateway.
- **ca-edge rate limits, per bearer token and per client address.** With `edge` set, requests to `/v1` and `/mcp` are limited to `edge.rate_limit_per_token` (600 by default) per `Authorization` header value and `edge.rate_limit_per_client` (1800 by default) per client address in each `edge.rate_limit_interval_seconds` (60 by default; each a whole number, the limits from 1 to 1000000 and the interval from 1 to 3600 seconds). The per-client limit holds a caller to its cap however many tokens it rotates through; a request without an `Authorization` header is held to it alone. A request over either limit is answered 429 with a `Retry-After` header of the interval in seconds; the 413 and 404 answers are never limited. The client address is the one the Container Apps ingress reports in `X-Forwarded-For` (exactly one trusted hop), and the header reaches `ca-api` unchanged. The limits are kept on each replica, with no Redis and no rate-limit service (ADR 0120 §5), so the effective limit is the configured limit times the running replicas (1 to 3), counted separately for `/v1` and `/mcp`. The token is a key in Envoy's memory only, never in the configuration, the plan, a log or a metric name. Behind an Application Gateway every client shares the gateway's address, and so one per-client bucket: docs/networking.md says how to size it.
- **`edge_custom_domain` input: ca-edge on your own hostname, off by default.** The same shape and rules as `frontend_custom_domain` (a bare lowercase hostname, the certificate's versionless Key Vault secret id, and the id of the vault that holds it), for the hostname your SDK and MCP clients call. Set, the module creates `id-<prefix>-edge-cert`, an identity attached to the Container App Environment and to no app, grants it Key Vault Secrets User on that one secret, adds the certificate to the environment as a Key Vault reference read as that identity (the key never passes through Terraform, and a certificate renewed in the vault is picked up without an apply), and binds the hostname to `ca-edge` by SNI, without changing its ingress, allowlist or HTTPS-only setting. `ca-edge`'s own identity never reads the certificate. `edge_url` becomes `https://<hostname>`, and the environment's identities are now both certificate identities, each only with its input. The plan refuses it without `edge`, and with `frontend_custom_domain`'s hostname. The `asuid.<hostname>` TXT record (`custom_domain_verification_id`) must exist before the apply that sets it; docs/networking.md lists it, the A or CNAME record and the Key Vault reachability. Unset (the default), an install plans no change.
- `enable_bff_dpop_key` (default `false`): the module generates the BFF's DPoP key, an EC P-256 key
  handed to `ca-frontend` alone as `MASTERLY_BFF_DPOP_KEY` (PKCS#8 PEM), the env names and format
  the frontend reads as of masterly-application-frontend commit 9defc3a7b09b. It rotates every 90
  days at the first apply after the period ends, and for 60 minutes after each rotation the
  outgoing key stays on `ca-frontend` as `MASTERLY_BFF_DPOP_KEY_PREVIOUS`, so sessions bound to it
  survive the change. Applying at least monthly keeps the slots about 90 days apart. If a slot
  expires inside the other slot's overlap, the older key's overlap is shortened to the gap
  between rotations; the key current just before the second rotation becomes `_PREVIOUS`.
  If both slots expire before the next apply, both keys are replaced together without retaining
  the outgoing key, and users must sign in again once. With `enable_key_vault` the key is a Key
  Vault secret per slot (`install-bff-dpop-key-a`, `-b`) that `ca-frontend` reads as its own identity,
  which holds Key Vault Secrets User on those secrets alone; without it, a Container App secret
  on `ca-frontend`.
  The private key is held in Terraform state, and with the vault on the apps identity's app
  secrets role on the vault can read it. `ca-api`, `ca-workers` and `caj-migrate` are unchanged.
  The key takes effect with the first frontend release after v0.145.0, and the api's session
  binding and DPoP replay cache arrive with the first api release after v0.137.0. The input is
  off by default, so installs on 0.24.0's images are unaffected apart from the two new required
  providers below. docs/identity.md, "The BFF's DPoP key".
- `frontend_environment`, `edge_environment` and `api_environment` (default `"aca"` each) choose
  where `ca-frontend`, `ca-edge` and `ca-api` run (ADR 0120 §4-§5). With the defaults, an install
  plans no change. The three move together: either all three stay `"aca"`, or
  `frontend_environment = "front"`, `edge_environment = "front"` and `api_environment = "app"`.
  Any other mix is refused at plan, as is a placement on an install that has no front and app
  environments.
- With the apps moved, `ca-frontend` and `ca-edge` call `ca-api` at
  `https://ca-api.<app environment default domain>` and verify its certificate. The BFF's
  `MASTERLY_API_BASE_URL` uses that address. The edge's Envoy cluster connects on 443 through an
  upstream TLS context: the host as SNI, the chain checked against the image's CA bundle, and the
  certificate's DNS name matched. `ca-api` in the app environment, which is always internal, takes
  VNet-only ingress and refuses plain HTTP. `api_ingress_external = true` is refused there.
  The name resolves through the app environment's private DNS zone. With
  `environment_private_dns_enabled = false`, your hub must create that zone and its record.
- With `ca-frontend` on the front environment and the Key Vault private endpoint on, the
  private-endpoint NSG gains one rule, `allow-key-vault-from-front-subnet`. It admits the front
  subnet to the endpoint's own address (/32) on TCP 443 only, so the front reaches no database,
  Redis or Service Bus. `ca-frontend` still reads only its own secrets, as its own identity.
- `modules/aca-env-workload-profiles` takes `identity_ids` and outputs `identity_ids` and
  `custom_domain_verification_id`, as `modules/aca-env-consumption` does.
  `modules/aca-container-app` outputs `environment_id`.
- **`builtin_auth_recovery_until` input.** The recovery fallback for `builtin_auth`: an RFC 3339 UTC time, at most 60 minutes after the plan, until which `ca-frontend`'s built-in authentication is turned off, so the application's own sign-in (and its break-glass path) is reachable when the Entra sign-in at the platform is not. It is refused at plan without `builtin_auth`, without a network restriction in front of the frontend (a non-empty `ingress_allowed_cidrs`, `frontend_ingress_external = false` or `aca_internal_load_balancer = true`), beyond 60 minutes, or when it is not an RFC 3339 UTC time. The gate comes back at the first plan and apply after the time, and a plan that still sets a passed time warns (`builtin_auth_recovery_window_has_expired`). It changes nothing on `ca-api`. Unset (the default), an existing install plans no change to its auth configuration.
- **An activity-log alert on `ca-frontend`'s auth configuration.** With `builtin_auth` set, the module creates `alert-<prefix>-frontend-auth-config-write`, which fires on every `Microsoft.App/containerApps/authConfigs/write` on `ca-frontend` (the recovery fallback's disable and restore, and a change made outside Terraform) and notifies the install's action group like the other alerts. An install with `builtin_auth` set plans one new resource.
- **`capacity_profile`: `small`, `standard` or `enterprise` sizes the install's services together (ADR 0120 §4).** It sets the Postgres SKU, the built-in pooler, zone-redundant HA and the minimum replicas of ca-api, ca-frontend and ca-workers: `small` is `B_Standard_B1ms`, no pooler, no HA, 1/1/1; `standard` is `GP_Standard_D2ds_v5`, pooler and HA on, 2/1/1; `enterprise` is `GP_Standard_D4ds_v5`, pooler and HA on, 2/2/2. A profile never changes the topology and never raises a maximum: set `api_max_replicas` (with `enable_redis`) and `workers_max_replicas` to at least the floor. `mode = "production"` refuses `small`. A profile never chooses a Service Bus tier, because moving an existing namespace to or from Premium replaces it: `enterprise` with `enable_service_bus = true` is refused until `servicebus_sku` is set, to `"Premium"` (enterprise's tier) or to `"Standard"` to keep an existing namespace. With `external_database_url` the profile's Postgres values do not apply. docs/scaling.md, "Capacity profiles", has the values, the recovery objectives each profile is sized for (not yet verified by drills), and what a change does to a running server.
- `scripts/check_customer_summary.py`, and a `release-metadata` step that runs its `--selftest` and
  then the check: every `customer-summary/X.Y.Z.json` must match the contract and a key of
  `MANIFEST.json`, and no string in it may name an internal host, a private-link name, an `msly-*`
  resource or a storage URL, or a security finding beyond counts by severity.
- **`egress_firewall` input: forced-tunnel egress through your firewall.** Set `next_hop_ip` to your firewall's private IPv4 address and the module creates `rt-<name_prefix>-aca` with one route, `0.0.0.0/0` to that address as a virtual appliance, with BGP route propagation kept on; or set `route_table_id` and it attaches your own route table unchanged. Either way the table goes on `snet-aca` only, never on `snet-private-endpoints`, whose traffic stays inside the VNet. Refused at plan with both or neither field set, with a next hop that is not one IPv4 address, with injected subnets (the hub's route table there is the platform team's to attach), with public ingress (`aca_internal_load_balancer = false`: Microsoft documents forced tunnelling only for an internal environment behind an Application Gateway), and on a Consumption-only environment, where Azure ignores the route (for a new environment that half of the check runs at apply). `ca-api`, `ca-frontend`, `ca-workers` and `caj-migrate` are created after the route table is attached, so their first pull and outbound call go through the firewall. The default, null, attaches nothing, so an existing install plans no change.
- **`egress_route` output.** The route table in effect on `snet-aca` and the next-hop address; null when `egress_firewall` is unset.
- **`modules/aca-env-consumption`: `read_workload_profiles` input and `workload_profile_names` output**, Azure's own list of the environment's workload profiles, read with azapi only when asked. The nested module now declares the `Azure/azapi` provider, which the root module already requires.
- `scripts/release_evidence.py`: turns a version's customer summary into release-note text. It runs
  the customer-summary contract check first and refuses on any failure, then renders the ring
  dates, gates passed, upgrade versions, performance per profile against the baseline version and
  the security counts. `--write` puts the block into the version's `CHANGELOG.md` section, and
  `--check`, run by `release-metadata`, fails on a hand-edited block, a summary with no block or
  a block with no summary. `--compose` and `--post-tag` build the release body (the tag's
  changelog section followed by the block). The new `release-evidence` workflow edits the Release
  body when a summary is pushed to `main`, and the tag build's `release` job composes the same
  body, so a re-run keeps the evidence. Neither pushes to `main`.
- `retire_runtime_environment` (default `false`) deletes `aca-<name_prefix>` once nothing runs in
  it (ADR 0120). The plan refuses `true` while anything the module places is still on
  `aca-<name_prefix>`, and its message names each thing left:
  - `ca-frontend`, `ca-edge` or `ca-api` with its placement input at `"aca"`, and the
    custom-domain certificates that follow them;
  - `ca-workers` with `workers_environment = "runtime"` (with `enable_workers`);
  - `caj-migrate` with `migrations = "job"` and `migrate_job_environment = "runtime"`.

  Retiring does not lift the `egress_firewall` refusal: with everything moved, `egress_firewall`
  is still refused.
- **`workers_environment` and `migrate_job_environment` inputs (default `"runtime"`): `ca-workers` and `caj-migrate` can run in the workers environment (ADR 0120 §4).** Each takes `"runtime"`, `aca-<prefix>` on `snet-aca` as before, or `"workers"`, `aca-<prefix>-workers` on `snet-workers`, which is internal and admits no inbound caller. `workers_environment` moves `ca-workers` only, and `migrate_job_environment` (with `migrations = "job"`) moves `caj-migrate` only. A moved workload keeps its identity (`ca-workers` its own or the apps identity as before, `caj-migrate` only `id-<prefix>-migrate`), its env, its secrets and, for `ca-workers`, its scale rule; `ca-workers` still has no ingress and a job has none. In the workers environment, each waits for the environment subnets' network security group associations.
- **Two plan-time refusals for either input set to `"workers"`.** On an install without the workers environment (`environment_subnet_ids` has no workers subnet, as on an injected network without `workers_subnet_id`), the plan is refused, naming the input. With `egress_firewall` set it is refused too: `egress_firewall` attaches its route table to `snet-aca` only, so the environment subnets get no route table from it and the moved workload's egress would bypass your firewall. On an injected network `egress_firewall` is refused anyway, so the plan cannot see forced tunnelling there: your platform team attaches the hub's route table (`0.0.0.0/0` to the firewall) to `workers_subnet_id` before either input is set to `"workers"`.
- The nested module `modules/aca-container-app` gains five outputs: `environment_id`, `ingress_enabled`, `env_value_sha256` (a SHA-256 of each plain env value, by name, never the value), `env_secret_refs` and `secret_refs` (each vault reference's secret and identity).
- **The front, app and workers Container Apps environments (ADR 0120 §4-§5), created beside `aca-<prefix>` with no app moved.** On an install with environment subnets (the `environment_subnet_ids` output), the module creates three workload-profiles environments, `aca-<prefix>-front`, `aca-<prefix>-app` and `aca-<prefix>-workers`, one on each of `snet-front`, `snet-app` and `snet-workers` (or the injected `front_subnet_id`, `app_subnet_id` and `workers_subnet_id`). Each declares the `Consumption` workload profile, encrypts traffic between its apps, and sends its console and system logs to the install's workspace through its own diagnostic setting, `diag-<prefix>-aca-front`, `-aca-app` and `-aca-workers`. The app and workers environments always have an internal load balancer, and no input changes that. The front is internal exactly when `aca_internal_load_balancer` is true, and public when it is false, so an install that is private today gets no public front. An install whose `environment_subnet_ids` are all null (a VNet smaller than /21 with no environment prefixes, or an injected network without the three subnet ids) gets none of them. The environments come from a new nested module, `modules/aca-env-workload-profiles`.
- **`environment_private_dns_enabled` input (default `true`).** For each internal new environment the module creates a private DNS zone in `rg-<prefix>-aca` named the environment's default domain, a `*` A record to its static IP, and a link to the install's VNet (on an injected network, the VNet of `aca_subnet_id`) with auto-registration off, so the environment's apps resolve inside the VNet. An external front gets none. Set it `false` where your platform team owns DNS: the module then creates no zone, record or link.
- **`container_app_environments` output**, keyed `front`, `app` and `workers`: each environment's `id`, `default_domain`, `static_ip_address` and whether it is `internal`, for a hub that creates the DNS records itself. A key is null where the install has no such environment.

### Changed

- Internal refactor: the network, the environment, the identities and the auth boundary's secrets and locals move out of `main.tf` into `network.tf`, `environment.tf`, `identity.tf` and `auth.tf`. No input, output or resource address changes, so an install plans no change.
- `MANIFEST.json` and its release check accept the per-role release images `migrate`,
  `worker_core` and `worker_integration` beside `api` and `frontend`, as
  `<registry>/release/<role>:<tag>` with `digests.<role>` (an addition within `schema_version` 1,
  documented in `docs/release-manifest.md`). The check now refuses any other `images` key, a
  per-role image with no `digests`, and an image value carrying `@sha256:`.
- Internal refactor: the root `variables.tf` and `outputs.tf` are split into `variables-<concern>.tf` and `outputs-<concern>.tf` files, one beside each concern's `.tf` file, with `variables-core.tf` and `outputs-core.tf` for the rest. Inputs and outputs only moved files: no input, output or resource changes, so an install plans no change. `docs/inputs.md` groups the inputs by the new files.
- **Upgrading.** On an install that builds its own network from a /21 or larger, the plan creates the three subnets, their groups and associations, and updates `nsg-<name_prefix>-private-endpoints` in place with two rules. `snet-aca`, its group and rules, the private-endpoint subnet and their associations keep their addresses, names and prefixes, and nothing is replaced. If you created subnets of your own in the VNet's `.5.0/24` to `.7.0/24` of the first prefix, set the three prefixes to free ranges before you apply. A VNet smaller than /21, or explicit runtime and private-endpoint prefixes that cover those ranges, plans no change until the three prefixes are set; an injected install plans no change until the three ids are set.
- The module now requires the `hashicorp/tls` (`~> 4.0`) and `hashicorp/time` (`~> 0.12`)
  providers, in every configuration that uses it, including one that leaves
  `enable_bff_dpop_key` off. `terraform init` installs them; an air-gapped install must add both
  to its provider mirror before upgrading. Neither takes configuration or credentials.
- The descriptions of `api_max_replicas` and `enable_redis` name Azure Managed Redis
  (`redis_offering = "managed"`) as the target of the api's DPoP replay cache, and say the
  in-memory cache is allowed on one api replica only, and that the cache arrives with the first
  api release after v0.137.0. The refusal of `api_max_replicas > 1` without `enable_redis` is
  unchanged.
- Setting the three inputs REPLACES `ca-frontend`, `ca-edge` and `ca-api`, a destroy then create
  with downtime. Their FQDNs change, and with them `frontend_url` and `edge_url`. The
  custom-domain certificates and custom domains are created again on the front environment, and
  the certificate identities move from `aca-<name_prefix>` to it.
  `custom_domain_verification_id` then reads the front environment's, so the `asuid.<hostname>`
  TXT records must carry the new value before the apply that moves the apps. Plan the move on a
  test install first.
- On an injected network (`aca_subnet_id` and `private_endpoints_subnet_id`), the module creates
  no private-endpoint NSG. Before moving `ca-frontend` to the front environment, the hub must
  admit the front subnet to the Key Vault private endpoint on TCP 443, or the frontend cannot
  resolve its vault secret references.
- `egress_firewall` is refused with any of the three apps off `"aca"`. The route table is attached
  to snet-aca only, and the front and app environment subnets get no route table, so the moved
  apps' egress would not be forced.
- `frontend_environment = "front"` is refused with `registry_private_endpoint = true`, on either
  network shape. `ca-frontend` pulls its image from the front subnet, and the front subnet may
  reach only the Key Vault private endpoint, not the registry's, so the pull would fail.
- **`postgres_sku_name`, `postgres_pgbouncer`, `postgres_zone_redundant_ha`, `api_min_replicas`, `frontend_min_replicas` and `workers_min_replicas` default to null.** Unset, each takes the value of `capacity_profile`, and with no profile its earlier default (`B_Standard_B1ms`, false, false, 1, 1, 1), so an install that sets no profile plans no change. A value set explicitly still wins. Every validation on these inputs, including the production guards, judges the resolved value.
- **Zone-redundant HA on a burstable (`B_*`) SKU is refused at plan.** Azure refused it at apply already. Since `standard` and `enterprise` turn HA on, a burstable `postgres_sku_name` set under either now needs `postgres_zone_redundant_ha = false` as well.
- **Upgrading.** Nothing changes until you set `capacity_profile`. Moving an existing install to `standard` or `enterprise` updates the Postgres server in place (it is never replaced) but restarts it for the SKU change and for HA, so do it in a maintenance window. It also turns on the built-in PgBouncer unless `postgres_pgbouncer = false` is set, which needs an api image that carries MAS-1615: roll the api image first.
- Internal tooling and contributor docs: a change adds a changelog fragment, `changelog.d/<short-name>.md`, instead of editing `## [Unreleased]`, which stays empty. The release-preparation commit runs `scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`, which folds the fragments into the version's section and deletes them. `scripts/check_release_manifest.py` refuses an entry under Unreleased, and `--tag` refuses a tree that still has a fragment. No input, output or resource changes, so an install plans no change.
- Internal CI: the module's formatting, validation and mock-provider tests now run on Terraform 1.10.5 and on 1.12.2, the version the install template's Azure DevOps pipelines pin. No input, output or resource changes, so an install plans no change.
- `cut-release` is the Stable path (ADR 0107 §5): `promote.yml` in `masterly-release-tests`
  dispatches it with the commit and version from the signed Stable ring record. It now refuses a
  version whose `MANIFEST.json` entry at the commit does not name `masterly.azurecr.io/release/`
  images with a `digests.api` and `digests.frontend`, so no version is tagged naming its images by
  tag alone. A tag that already exists at exactly the given commit is no longer refused: the run
  writes no tag and goes on, so a run that failed after creating the tag is finished by dispatching
  it again. A tag at another commit is still refused, now naming both commits. Once the tag is at
  the commit, the workflow sends the `repository_dispatch` `release-published` (version, tag,
  commit) to `masterly-release-tests`, with a second App token scoped to that repository.
- **docs/networking.md, "Egress"**, rewritten for forced tunnelling: `egress_firewall` on an internal environment the module builds, the hub's route table on injected subnets, the Microsoft Learn finding (2026-11-14) behind refusing it with public ingress, and a table of every destination the Container Apps subnet reaches outside the VNet, with what reaches it and what fails when the firewall drops it. The outbound-NSG advice for a Consumption-only environment is gone: every environment the module builds is a workload-profiles environment (ADR 0104).
- **The release check accepts a root-path api or frontend image in an older entry with a `known_issue`.** `scripts/check_release_manifest.py` allows `<registry>/api:<tag>` or `<registry>/frontend:<tag>` beside the never-published exception, only in an entry other than `latest` that records a `known_issue`. The newest release, a per-role image, and any other repository (`candidate/api`) are still refused, each pinned by a `--selftest` case.
- With `retire_runtime_environment` unset, an upgrade plans **no change**. `aca-<name_prefix>`
  and its diagnostic setting only move to indexed addresses, through two `moved` blocks:
  `module.aca_env` to `module.aca_env[0]`, and `azurerm_monitor_diagnostic_setting.aca_env` to
  `azurerm_monitor_diagnostic_setting.aca_env[0]`. Nothing is destroyed or created.
- With `retire_runtime_environment = true` and everything moved, the plan destroys
  `aca-<name_prefix>` (`module.aca_env[0]`) and `diag-<name_prefix>-aca-env`
  (`azurerm_monitor_diagnostic_setting.aca_env[0]`), and nothing else. The `aca_environment_id`
  output is then null; it is kept, so callers that read it still plan.
- Azure deletes an environment with every app and job in it, and the module cannot see what you
  created there yourself. Check `aca-<name_prefix>` for your own apps and jobs before you set the
  input.
- `snet-aca`, its NSG, the private-endpoint rule from it and `aca_subnet_id` stay. Setting the
  input back to `false` creates a new, empty `aca-<name_prefix>`.
- `scripts/check_runtime_env.py` and `scripts/check_release_manifest.py` check their internal
  invariants with explicit errors instead of `assert`, so running them under `python -O` (which
  strips asserts) no longer skips those checks. Their output and exit codes are unchanged.
- Internal refactor: the module's plan tests move from one file into one file per concern under `tests/` (`network.tftest.hcl`, `keyvault.tftest.hcl`, `postgres.tftest.hcl` and the rest), with their shared azurerm mock data in `tests/mocks/install/`. The same 438 runs pass, unchanged. No input, output or resource changes.
- **Upgrading plans nothing with the defaults.** Both inputs default to `"runtime"`, so `ca-workers` and `caj-migrate` stay on `aca-<prefix>` and plan no change.
- **Setting either input (or setting it back) replaces the workload.** Azure does not move a Container App or a job between environments, so the plan destroys `ca-workers` or `caj-migrate` and creates it again under the same name. While `ca-workers` is replaced, the pipeline pauses: no job runs until the new app's first replica starts. The new app or job is created on the module's api image (the release channel's, or `api_image`), not the digest CD last rolled, so run CD's release again after the apply to roll it to the current digest. A replaced `caj-migrate` also starts one more execution at apply (`migrate_start` is replaced with the job).
- `migrate_start` is now also replaced when the job's id changes, so a replaced job always runs once at apply.
- **No app moves in this version.** `ca-api`, `ca-frontend`, `ca-workers`, `ca-edge`, `caj-migrate` and the custom-domain certificate stay on `aca-<prefix>`, and `module.aca_env` and its diagnostic setting `diag-<prefix>-aca-env` plan no change. Upgrading an install that has environment subnets plans the three new environments, their three diagnostic settings, and for each internal one a zone, a record and a link; on an injected spoke the link needs permission to link a zone to the spoke VNet, or set `environment_private_dns_enabled = false`. The three environment subnets still get no route table from `egress_firewall`.

### Fixed

- **The environment's diagnostic setting no longer shows a change on every plan.** `diag-<name_prefix>-aca-env` set `log_analytics_destination_type = "Dedicated"`, which Azure does not keep on a Container Apps environment (it reads back null), so every refreshing plan on 0.18.0 or later showed `+ log_analytics_destination_type = "Dedicated"` as an in-place update. The module no longer sets it. An existing install's next plan shows no change to `diag-<name_prefix>-aca-env`, and the console and system logs keep landing in the same `ContainerAppConsoleLogs` and `ContainerAppSystemLogs` tables. The Key Vault setting is unchanged.
- **A plan without refresh no longer replaces the Container Apps environment.** Azure adds a `Consumption` workload profile and its managed resource group `ME_<env>_<rg>_<location>` to a VNet-integrated environment after it is created, and the provider plans to replace the environment (`infrastructure_resource_group_name = "ME_…" -> null # forces replacement`) when the state predates that profile, as with `-refresh=false` just after the first apply. A replacement would take the apps, the migrate job, the diagnostic settings and the alert scopes with it, and give the environment a new default domain. The environment modules now ignore changes to `infrastructure_resource_group_name`, which the module never sets. A plan without refresh, or with state from before Azure added the profile, no longer plans to replace the environment, and an existing install's refreshing plan shows no change.
- **A production destroy run from inside the network now deletes the Key Vault secrets before the vault's private endpoint and DNS link.** Nothing ordered the secrets (`azurerm_key_vault_secret.install`, `migrate_api_role_password` and `migrate_workers_role_password`) after the endpoint, so a destroy could remove the endpoint first and every secret delete then failed with 403 `ForbiddenByConnection`, because a production vault has no public path. Each secret now depends on the private endpoint and the DNS link, so on destroy the secrets go first and on apply they are written after the endpoint exists. Demo, and production with `key_vault_private_dns_zone_id` set (no module-owned link), plan as before. The change adds ordering only: no attribute, network rule or role changes, and upgrading replaces no secret.
- **Sign-in through the frontend no longer fails on api releases after v0.137.0.** Those releases bind every interactive session to the BFF's DPoP key and, on `mode = "demo"` or `"production"`, refuse every session's proof with 401 unless `MASTERLY_DPOP_INTERNAL_ORIGIN` names the origin the BFF calls the api on. The module did not set it, so every sign-in failed and the frontend reported "Your identity is not yet provisioned for this install". `ca-api` now gets `MASTERLY_DPOP_INTERNAL_ORIGIN` from the same value as `ca-frontend`'s `MASTERLY_API_BASE_URL`: `http://ca-api`, or `https://ca-api.<app environment default domain>` with `api_environment = "app"`. `ca-workers`, which reads the api's environment, gets it too and does not act on it. Service-account callers send no proof and were not affected. Upgrading updates `ca-api` and `ca-workers` in place with the new environment variable, which rolls a new revision of each.
- **MANIFEST.json: `0.15.0` and `0.16.0` name their images where they are.** Their builds (api `v0.133.2`/`v0.133.5`, frontend `v0.138.2`/`v0.139.0`) were never published under `release/`: they exist only at the registry root, `masterly.azurecr.io/api:<tag>` and `masterly.azurecr.io/frontend:<tag>`, and are unsigned. Both entries now name those root-path references with the same tags, and each records a `known_issue` saying so and to move to `0.18.0` or later. An install pinned to either pair should move. No other entry changes, and `latest` and the channel defaults do not move.

### Security

- **MANIFEST.json: `0.22.0` and `0.23.0` record a `known_issue`.** Both releases pin `masterly.azurecr.io/release/api:v0.135.0` (`sha256:00b0c775ff83cd4b1d0a9c79e9290d3166f471b5576f43e4272ab0d031a9ed04`) and `masterly.azurecr.io/release/frontend:v0.143.0` (`sha256:e1e59d896125ee033a461297b9c36b57507320d7cb8c4b0897011aa7066e6a2b`). A Trivy scan on 2026-11-08 found known HIGH-severity vulnerabilities with a fix available in both images: 2 in the api image and 10 in the frontend image. An install on either release, or one that pins either image, should move to `0.24.0` (api `v0.137.0`, frontend `v0.145.0`). Because the `previous` channel skips a release with a `known_issue`, it no longer selects `0.22.0` or `0.23.0`. No image, digest or `latest` changes.
- Installs on release_channel = "previous" should move to 0.24.0.

### Documentation

- `docs/data-plane.md` now says how a production destroy handles the Postgres Entra administrators. With `database_auth = "entra"`, `terraform destroy` removes the administrator before the server and stops with Postgres error `2BP01`, because the administrator's role owns objects in the database. The module does not change; the step is left to the operator: run `terraform state list`, `terraform state rm` the administrator addresses it shows (`apps[0]` under `migrations = "start"`, `migrate[0]` under `"job"`, none with `"password"` or `external_database_url`) immediately before a full destroy, and `terraform import` the administrator back if the destroy is abandoned before the server is deleted.
- `docs/customer-summary.md`: the schema 1 contract for the redacted customer summary published
  beside the release manifest.
- `docs/releasing.md` and the README's "Cutting a release": who dispatches `cut-release` at
  Stable, what `release-published` carries, why a re-run at the same commit is safe, and the
  owner's grants for the Stable path.
- The README's long-form feature docs moved to their own files: Identity to `docs/identity.md`, Data plane to `docs/data-plane.md`, Scaling to `docs/scaling.md`, and Networking (the landing-zone notes, the API's public address and transport security) into `docs/networking.md`. The README keeps each `##` heading with a pointer, and the departures from Azure's recommended baseline stay in it. The Diagnostics + alerts section stays in the README for now. The README holds no input table: `docs/inputs.md` is the input reference, and `scripts/check_inputs_reference.py` now fails on a README table row for a declared input.
- `docs/customer-summary.md`: a version's summary is read from `main`, is added after the tag and
  never appears in the tagged tree. `docs/releasing.md` and the README's "Cutting a release" gain
  the "At Stable" step.
- **docs/release-manifest.md** names both exceptions to the `release/` rule in the field table, "The image path" and "Compatibility", and says where each range of entries has its images: `0.22.0` and later under `release/` from release, `0.18.0` to `0.21.0` under `release/` by backfill, `0.17.0`'s api never published, and `0.15.0`/`0.16.0` only at the root, unsigned.
- `docs/networking.md`, "Retiring the runtime environment" under "Upgrading an existing install",
  gives the upgrade as four applies in order:
  1. the environment subnets and environments;
  2. `ca-workers` and `caj-migrate`;
  3. `ca-frontend`, `ca-edge` and `ca-api` together;
  4. the retirement.

  It says what each move changes: the FQDNs, `frontend_url` and `edge_url`, the OIDC redirect URI
  to register, and the `asuid` TXT and routing records to set before the apply. It also covers
  how SDK and API clients reach the API through `ca-edge`, the one Key Vault rule (443, /32) a hub
  adds for the front subnet, and the `egress_firewall` refusal. "The environment subnets" no
  longer says a later version retires `snet-aca` with the apps' move: this version retires the
  environment only.
- docs/networking.md, "The environment subnets", says which workloads can be placed in the workers environment (`ca-workers` and `caj-migrate`), with which inputs, that `egress_firewall` refuses it, and that on an injected network the hub's route table must be on `workers_subnet_id` first.
- Comments, descriptions and docs no longer call the install's environment "Consumption-only": every environment the module builds sits on a delegated subnet, on which Azure adds the `Consumption` workload profile. The `egress_firewall` refusal still describes an environment that reports no workload profile. docs/networking.md, "The environment subnets", describes the three environments and their private DNS.

## [0.24.0] - 2026-11-10

Released against api `v0.137.0` and frontend `v0.145.0`, the pair Masterly's own install applied.
api `v0.137.0` is the first image that reads `MASTERLY_DEMO_ENVIRONMENTS` (`demo_environments`
below), and it verifies licence claims version 3 (`api_claims_version`, up from 2).

### Added

- **`frontend_custom_domain`: `ca-frontend` on your own hostname, with your certificate from your
  Key Vault.** Null by default, which plans exactly as before. Set the hostname, the certificate's
  versionless Key Vault secret id and the vault's resource id, and the module creates
  `id-<prefix>-frontend-cert`, an identity attached to the Container App Environment and to no
  app, with Key Vault Secrets User on that one secret; an environment certificate that references
  the secret without a version, so the key never enters Terraform and a renewal in the vault needs
  no apply; and an SNI binding of the hostname on `ca-frontend`, which leaves
  `ingress_allowed_cidrs` and HTTPS-only as they were. It works on a public environment and on an
  internal one behind your Application Gateway. With `identity_binding = "oidc"` the frontend's
  redirect URI derives from the hostname, `https://<hostname>/api/auth/callback`, so
  `oidc_redirect_uri` may be left unset and a production install is one apply; a
  `oidc_redirect_uri` on another host is refused at plan, as are a hostname that is not a bare
  lowercase FQDN and a versioned secret id. `frontend_url` returns `https://<hostname>`, and the
  new `custom_domain_verification_id` output carries the `asuid.<hostname>` TXT value.
  [docs/networking.md](docs/networking.md#ca-frontend-on-your-own-domain) lists the DNS records,
  when to create them, and the Application Gateway settings; the deploying identity needs the right
  to create a role assignment on the certificate's vault. Custom domains are no longer deferred.
- **`oidc_tenant_id`.** For a single-tenant Microsoft Entra registration, the tenant id is now
  enough: `oidc_allowed_issuers` and `oidc_authority` default to
  `https://login.microsoftonline.com/<tenant>/v2.0`, and `oidc_jwks_uri` to
  `https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys`. Any of the three you set
  yourself still wins. Another identity provider, or a multitenant Entra registration, sets the
  three as before. `identity_binding = "oidc"` now requires `oidc_tenant_id` or all three.
- **`docs/inputs.md`**: every input of the module, grouped by the subsystem it configures, with
  its type, default and the first sentence of its description. Generated from the `.tf` files by
  `scripts/check_inputs_reference.py`; CI fails when it is out of date.
- **`demo_environments`: extra Environments for a demo install's in-memory control plane.** On
  `mode = "demo"` the control plane's Environments are a fixture list (`prd-eu`, `non-prd-eu`),
  and one created in the product lasts only until `ca-api` restarts. List extra names here and the
  module writes them, comma-separated, to `ca-api` and `ca-workers` as
  `MASTERLY_DEMO_ENVIRONMENTS`; the control plane seeds each at every start in the install's own
  geo, under an id derived from its name. Read by api `v0.137.0` and later; an earlier image
  ignores it. Empty by default, which sets nothing and plans exactly as
  before. Refused at plan: a name that is not lowercase letters, digits and hyphens starting with
  a letter and ending with a letter or digit, or is over 40 characters, a duplicate, a fixture
  name, and any name on `mode = "production"`, where Environments are created in the product and
  persist. See
  [Extra Environments on a demo install](docs/data-plane.md#extra-environments-on-a-demo-install).

### Changed

- **`cut-release` refuses a tag until the release's default images resolve in the registry.** Its
  new `images` job reads the release commit's `MANIFEST.json` and checks, in
  `masterly.azurecr.io`, every image the stable and previous channels default to:
  `release/<role>@<digest>`, with the entry's tag at that same digest, or `release/<role>:<tag>`
  for an entry with no digests (`scripts/check_release_images.py`). 0.22.0 and 0.23.0 were tagged
  naming builds the registry did not have. It reads with the pull-only ACR token
  `pull-ci-cut-release` (scope map `pull-product-images`) from the `release` Environment, and
  fails when that is not configured. No change to the module itself (split from MAS-4213).
- **A `v*` tag can now be created, moved or deleted only through `cut-release`.** Since 2026-11-05
  the `release-tags` ruleset refuses a hand-pushed `v*` tag; its only bypass actor is the GitHub
  App `masterly-module-release`, whose key lives only in the `release` Environment (`main` only).
  A repository setting, so no input or output changes and no module code changes (MAS-4139).
- **`ca-workers` runs as its own identity, `id-<prefix>-workers`, wherever it exists and the install
  has a Key Vault, on either `migrations` value and on BYO-DB, except `"start"` with
  `database_auth = "entra"` on the starter server.** A minor release under ADR 0062: no input or
  output is added, renamed or removed. A grant made for `ca-workers` alone now never reaches
  `ca-api`, which runs as `id-<prefix>-apps` on every shape. The change separates two things that
  shared one condition: the Azure identity follows the vault, and the `masterly_workers` DSN stays
  with the app roles (`"job"` on the starter server).
  - **Moves:** `"start"` with `database_auth = "password"`, and BYO-DB on `"start"` and `"job"`.
    `ca-workers` gets a new revision on `id-<prefix>-workers`, with that identity's
    `AZURE_CLIENT_ID`, and keeps reading the shared `database-url` (and `database-direct-url`
    with `postgres_pgbouncer`) through it. `id-<prefix>-workers` gets every `*_workers` grant the
    install's features call for: the app secrets role and Crypto Officer on the vault, AcrPull
    (through `acr_id`), Service Bus Data Sender and Receiver and Data Owner on the jobs queue (with
    `enable_service_bus`), ACS Email Owner (with `email_acs_enabled`) and its Redis data access
    policy (on `redis_auth = "entra"`). `id-<prefix>-apps` loses Service Bus Data Receiver and
    jobs-queue Data Owner. `workers_identity_principal_id` is now set on these shapes.
  - **Does not move:** `"start"` with `database_auth = "entra"` on the starter server, because the
    shared DSN's user is the `id-<prefix>-apps` role and its token is minted for
    `AZURE_CLIENT_ID`; `enable_key_vault = false`; and `enable_workers = false`. These plan no
    change. `"job"` on the starter server already ran this way.
  - **Upgrade:** `ca-workers` moves to `id-<prefix>-workers` in a new revision, and its old revision
    cannot sign in as before: identities belong to the app, not to a revision. **With `acr_id` null,
    grant `AcrPull` to `workers_identity_principal_id` before applying**, or `ca-workers` cannot
    pull its new revision. Azure RBAC propagation can delay the new identity's first Key Vault
    reference; the module adds no wait, as on the `"job"` path. Terraform creates the new grants
    before the update and removes the old ones after it: in the released module `ca-workers`
    `depends_on` `sb_receiver` and `sb_scaler` (`workers.tf:189-190`), Terraform records that
    dependency in state, and it destroys a removed resource only after its recorded dependents are
    updated. No `depends_on` changed. The README's upgrade note under "The migrate job" has the
    details.
- **With `migrations = "job"` on the starter server, `id-<prefix>-apps` is no longer a Postgres
  Entra administrator, and holds Service Bus Data Sender alone (ADR 0120 §6).** A minor release
  under ADR 0062: no input or output is added, renamed or removed. Under `"job"` on the starter
  server the module now removes three things from `ca-api`'s identity:
  - `azurerm_postgresql_flexible_server_active_directory_administrator.apps` (on `"entra"`). The
    migrate identity, `id-<prefix>-migrate`, is the server's only Entra administrator;
  - `azurerm_role_assignment.sb_receiver`, Azure Service Bus Data Receiver on the namespace;
  - `azurerm_role_assignment.sb_scaler`, Azure Service Bus Data Owner on the jobs queue.

  `ca-workers` already receives and scales as `id-<prefix>-workers`, which keeps its Sender,
  Receiver and jobs-queue Data Owner. `ca-api` keeps Sender. The Receiver goes only where
  `ca-workers` runs as its own identity, so no deployment that still receives as
  `id-<prefix>-apps` loses it. With `migrations = "start"`, or `"job"` on BYO-DB, the administrator
  stays, and the entry above says where the Receiver and queue Data Owner move.
  The shared `database-url` / `database-direct-url` vault secrets and `ca-api`'s Container App
  secret for them stay as in 0.23.0.

  Terraform destroys the three only after it has created the migrate administrator and updated
  `ca-api` and `ca-workers`, because those resources depend on them; no `depends_on` changed.
  Removing the administrator does not wait for the new revisions to become ready, though, and on
  an existing `"entra"` install every database object is still owned by the `id-<prefix>-apps`
  role. **Order for an existing `"entra"` install:** be on 0.23.x with `migrations = "job"`, confirm
  a migrate job execution has Succeeded and that both apps run as `masterly_api` /
  `masterly_workers`, then upgrade to this version. An install moving from `"start"` straight to
  `"job"` on this version does all of it in one apply; the README's upgrade note under "The
  migrate job" has the details. What Azure does to the `id-<prefix>-apps` role when its
  administrator is removed has not yet been confirmed on a live install; this version was
  released with that check still owed, and it is listed in `docs/releasing.md`.
- **`oidc_audience` defaults to `oidc_client_id`.** The backend verifies the ID token the BFF
  obtained, whose audience is that same client id, so this is the value almost every install
  sets. An explicit value still wins.
- **`breakglass_owner_email` defaults to `initial_owner_email` once `breakglass_secret_hash` is
  set.** Break-glass admits only an existing Owner, and that address is the first one. Without a
  hash nothing changes: no break-glass email is set. An explicit value still wins.
- **The README recommends an exact module version** (`version = "0.23.0"`) instead of a
  `~>` range, as the install-root guidance already did: Terraform does not lock module
  versions, so a range lets every fresh `terraform init` take a newer release.
- **`ca-api`'s and `ca-workers`' identities no longer hold Key Vault Secrets Officer on the
  install vault.** A minor release under ADR 0062: no input or output is added, renamed or
  removed, but the deploying identity needs a new right (below). Secrets Officer's `secrets/*`
  let a compromised app purge, back up, restore and recover every secret in the vault, the BYO-DB
  connection strings included. With `enable_key_vault` the module now defines its own role,
  `azurerm_role_definition.app_secrets`, named `Masterly app secrets (<name_prefix>-<suffix>)` so
  two installs in one tenant never collide, defined on and assignable only within the data
  resource group, with exactly four data actions on secrets: `getSecret/action`,
  `setSecret/action`, `delete` and `readMetadata/action`. That is what the apps use: resolving
  their Key Vault references and sealing their own material (ADR 0066). The grants move to it
  under new names, `azurerm_role_assignment.kv_app_secrets` and `kv_app_secrets_workers`, with
  `moved` blocks from `kv_secrets_officer` and `kv_secrets_officer_workers`. Key Vault Crypto
  Officer, the deployer's own Secrets Officer grant and the vault are unchanged. An app can still
  read and overwrite every secret in the vault, as it must to work; after this change it cannot
  recover a secret it deleted.
- **`scripts/preflight.sh` checks the deployer can define roles.** Role Based Access Control
  Administrator can assign roles but lacks `Microsoft.Authorization/roleDefinitions/write`, so
  preflight passed a deployer whose apply would then fail on the new role definition. It now
  FAILs that deployer in `--mode production`, which forces the vault, and WARNs in `--mode demo`,
  naming `enable_key_vault`. Owner, or Contributor with User Access Administrator, passes. The
  check reads role names, so a custom role carrying the action reads as missing; the message
  names the action. `tests/preflight_test.sh` tests it against a fake `az`.

The identity defaults above (`oidc_tenant_id`, `oidc_audience`, `breakglass_owner_email`) need no
migration, with one case to check. The OIDC defaults change nothing for an existing
install: `identity_binding = "oidc"` refused an unset `oidc_audience`, `oidc_authority`,
`oidc_allowed_issuers` or `oidc_jwks_uri` before. **An install that sets `breakglass_secret_hash`
but not `breakglass_owner_email` had break-glass off, and the next apply arms it** for
`initial_owner_email`: the plan shows `MASTERLY_BREAKGLASS_OWNER_EMAIL` added to `ca-api` and
`ca-workers`. If that is not what you want, remove the hash.

**Upgrading an install with `enable_key_vault = true`.** Run the preflight first:
`scripts/preflight.sh --principal <object id of the identity that runs terraform apply> --mode
production` (`--mode demo` for a demo install, where it WARNs instead). If it reports
`Microsoft.Authorization/roleDefinitions/write` missing, grant that identity User Access
Administrator or Owner at subscription scope and run it again before you upgrade (the preflight
reads role names, so a custom role of yours that carries the action reads as missing).
Do not count on the apply to stop you: nothing orders the removal of the old Secrets Officer
grants after the role definition is created, so a deployer without the right (Contributor and
Role Based Access Control Administrator only, say) may lose those grants before the role
definition fails to create. `ca-api` and `ca-workers` are then left with no secrets grant on the
vault: their own calls to it, and the Key Vault references of any new replica, fail until an
apply by a deployer holding the right succeeds. If that happens, grant the right and apply again.

With the right in place, the plan shows `azurerm_role_definition.app_secrets[0]` created, and
`kv_secrets_officer` moved to `kv_app_secrets` (with `migrations = "job"` on the starter server,
`kv_secrets_officer_workers` to `kv_app_secrets_workers` too), each replaced because its role
changes. The vault and the Crypto Officer grants are not replaced or changed. Each replacement
is destroy-then-create: Terraform removes the Secrets Officer grant first, then creates the new
grant, and updates `ca-api` and `ca-workers` only after the new grant exists. An app that reaches
the vault between the removal and the create, or before Azure has propagated the new grant
(usually seconds, sometimes minutes), can be refused: apply in a quiet window, and restart a
revision that failed to resolve a secret. On an install with `enable_key_vault = false` the plan
shows no change from this release.

## [0.23.0] - 2026-11-05

Released against the same image pair as 0.22.0: api `v0.135.0`, frontend `v0.143.0`.

### Added

- **With `migrations = "job"` on the starter server, `ca-api` and `ca-workers` sign in to Postgres
  as their own DML-only roles, and `ca-workers` runs as its own identity (ADR 0120 §6).** A minor
  release under ADR 0062: new resources, secrets and one output, no new input, nothing renamed or
  removed. Additive: `id-<prefix>-apps` keeps its Entra administrator and every grant, and the
  shared `database-url` / `database-direct-url` vault secrets stay, so running revisions keep
  working until they are replaced. `ca-api` keeps its Container App secret for them too, named by
  no env, because its old revision may restart while the new one waits for the job. With
  `migrations = "start"`, or `"job"` on BYO-DB, nothing changes. What is new under `"job"` on the starter server:
  - `ca-workers` runs, pulls, scales (the KEDA jobs-queue rule) and resolves its Key Vault
    references as `id-<prefix>-workers`, with that identity's `AZURE_CLIENT_ID`. `ca-api` stays on
    `id-<prefix>-apps`;
  - each app reads its own URL from its own vault secret: `api-database-url` with user
    `masterly_api`, `workers-database-url` with user `masterly_workers` (plus `api-database-direct-url`
    / `workers-database-direct-url` with `postgres_pgbouncer`). No password on `"entra"`; on
    `"password"`, that role's generated password, only inside its own vault secret. Neither app
    carries the other's URL, and no env of either names the shared one;
  - `id-<prefix>-workers` gets copies of the backend grants (each `*_workers`): Key Vault Secrets
    Officer and Crypto Officer on the vault, `AcrPull` through `acr_id`, ACS Email Owner with
    `email_acs_enabled`, Service Bus Data Sender and Receiver, Data Owner on the jobs queue when
    `ca-workers` scales on it, and its own Redis access policy on `"entra"` (`masterly-workers` on
    Azure Cache for Redis). Never a grant `id-<prefix>-apps` lacks, and no Postgres administrator.
    These grants, its Redis policy and the `workers-*` URL secrets exist only while
    `enable_workers` is on;
  - new output `workers_identity_principal_id` (null otherwise). **With `acr_id` null, grant it
    `AcrPull` out of band before applying**, or `ca-workers` cannot pull its new revision.

  **This needs an api image that creates `masterly_api` and `masterly_workers`, and no released
  image does** (none up to v0.135.0; backend reference `masterly-application-backend` at commit
  `462467d1`, in no release tag yet). The module does not check the image, and has no input to
  defer the move: with an image that runs the job but lacks the role creation, `ca-api`'s new
  revision never becomes ready and `ca-workers` restarts without end. On the starter server, keep
  `migrations = "start"`, and do not upgrade an install already on `"job"` to this version, until
  it runs a backend
  release whose notes name the app-role creation. With such an image, on apply, `ca-api`'s new
  revision becomes ready once the migrate job has created `masterly_api`. `ca-workers` has no
  probe: its new revision replaces the old one at once and restarts until the job has created
  `masterly_workers`. The upgrade note under "The migrate job" in the README has the order.

- **The migrate job, opt-in: schema migrations and new Environments' databases run in their own
  job, as their own identity (ADR 0120 §6; ADR 0065, 0086 and 0108 as amended 2026-10-23).** A
  minor release under ADR 0062: new resources and inputs, nothing renamed or removed. The new input
  `migrations` defaults to `"start"`, which changes nothing: no job, no migrate identity, no grant,
  no second administrator, no `MASTERLY_MIGRATIONS`, and the apps migrate at start as before.
  Job mode requires `mode = "production"`; demo's control plane is in memory, so demo installs
  must keep `migrations = "start"`. The job receives the API's `MASTERLY_ORG_ID`, optional
  `MASTERLY_ORG_NAME` and `MASTERLY_MODE`, with `MASTERLY_CONTROLPLANE_STORE=postgres`, to open
  the install's durable control plane.
  `migrations = "job"` needs an api image from a **backend release later than v0.135.0**: the
  migrate entry point and the `MASTERLY_MIGRATIONS` setting are in no release up to v0.135.0.
  Backend implementation reference: `masterly-application-backend` at commit `8d2cbd35`, in
  `masterly_app/apps/migrate.py`, `composition/migrate.py` and `core/settings.py`
  (`MASTERLY_MIGRATIONS`, `MASTERLY_MIGRATE_API_ROLE` and `MASTERLY_MIGRATE_WORKERS_ROLE`).
  With `"job"`, what is new:
  - `caj-migrate`, a Container Apps job in the install's environment, runs
    `python -m masterly_app.apps.migrate` on the resolved api image, with no ingress;
  - `id-<prefix>-migrate`, its user-assigned identity, attached to no Container App. It gets
    `AcrPull` through `acr_id` (outside the `token` mode) and, with `enable_key_vault`, Key Vault
    Secrets User on its vault-backed secrets and explicitly named per-Environment BYO-DB DSNs. On
    `database_auth = "entra"` it is the starter server's second Microsoft Entra administrator,
    beside `id-<prefix>-apps`, which is unchanged. New output `migrate_identity_principal_id`
    (grant it `AcrPull` out of band when `acr_id` is null, as for the other two), and
    `migrate_job_name`;
  - the job's own DSN, under its own secret names (`migrate-database-url`, plus
    `migrate-database-direct-url` with `postgres_pgbouncer`): the migrate identity's Entra role on
    `"entra"`, `masterly_admin` on `"password"`;
  - the API's Key Vault secret-store binding, authenticated as the migrate identity even with
    password database auth. `migrate_byo_database_secret_names` defaults to empty; list existing
    per-Environment BYO-DB connection secret names and apply to grant read on those secrets only,
    never the vault. Update and apply the list when a connection gets a new secret name, before
    provisioning or the CD migration gate; Terraform does not discover or read runtime secrets;
  - an apply-time start when installing with job mode or enabling it on an existing install:
    an `azapi_resource_action` starts one execution before `ca-api` and `ca-workers` are created
    or updated to job mode. It does not wait for completion; the apps rely on the backend's
    schema-stamp readiness checks. As on the apps, Terraform seeds the job's image and then ignores
    drift: your CD owns it, and rolls each release to the job first, starts an execution, waits
    for it to succeed, and only then rolls `ca-api` and `ca-workers` to the same digest. The job
    also runs on a schedule, the new input `migrate_job_schedule` (a five-field cron expression,
    default `"*/5 * * * *"`), on which the release's migrate role is required to pick up a new
    Environment's pending provisioning run;
  - `MASTERLY_MIGRATIONS=job` on `ca-api` and `ca-workers`, which tells an api image that honours
    it to check the schema stamps instead of migrating at start;
  - `external_database_admin_url`, a new optional, sensitive input for BYO-DB: a DSN for a role
    allowed to migrate and create databases. Only the job carries it, as an ACA job secret even
    with `enable_key_vault`; it never enters the shared install vault or gets a Key Vault grant.
    `ca-api` and `ca-workers` keep `external_database_url`. Refused unless `external_database_url`
    is set and `migrations = "job"`. Unset, the job uses `external_database_url`.

  **Before you set `migrations = "job"`:** it needs an api image from a backend release later than
  v0.135.0 that has the migrate entry point (`masterly_app.apps.migrate`), honours
  `MASTERLY_MIGRATIONS=job`, picks up pending provisioning runs on each migrate run, and
  serialises overlapping runs. With an older image the job fails. Roll such an image onto `ca-api`
  and `ca-workers` with your CD first, then apply with `migrations = "job"` and `api_image` set to
  it; the apply adds `MASTERLY_MIGRATIONS=job` to the image they
  run and does not change it. On an existing `database_auth = "entra"` install the database
  objects are owned by `id-<prefix>-apps`; a second Entra administrator is not a superuser, so the
  image's migrate role must take ownership or membership of them before its first migration. See
  "The migrate job" in the [data plane docs](docs/data-plane.md#the-migrate-job).

- **With `migrations = "job"` on the starter server, the migrate job creates DML-only database
  roles for `ca-api` and `ca-workers` (ADR 0120 §6).** A minor release under ADR 0062: new
  resources and job env only, no new input, nothing renamed or removed, and nothing changes while
  `migrations` stays `"start"` or on BYO-DB (`external_database_url`). What is new:
  - `MASTERLY_MIGRATE_API_ROLE=masterly_api` and `MASTERLY_MIGRATE_WORKERS_ROLE=masterly_workers`
    on `caj-migrate`;
  - `id-<prefix>-workers`, a user-assigned identity for the `masterly_workers` role, attached to no
    Container App or job and holding no role assignment;
  - on `database_auth = "entra"`, `MASTERLY_MIGRATE_API_ROLE_OBJECT_ID` (`id-<prefix>-apps`) and
    `MASTERLY_MIGRATE_WORKERS_ROLE_OBJECT_ID` (`id-<prefix>-workers`) on the job;
  - on `"password"`, two generated passwords in two new vault secrets,
    `install-migrate-api-role-password` and `install-migrate-workers-role-password`, Key Vault
    Secrets User for the migrate identity on each of those two secrets (never the vault), and
    `MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF` / `MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF` on the
    job, naming those secrets. The passwords are no ACA secret on the job or any app.

  `ca-api`, `ca-workers` and `ca-frontend` keep their identities, database user, env and secrets,
  and no existing grant changes. The roles need an api image from a backend release later than
  v0.135.0 with the `migrate_*_role` settings (`masterly-application-backend` at commit
  `cf741e0e1fda`); the job never alters a role that already exists.

- **`registry_private_endpoint`: the registry over a private endpoint.** A new optional input, off
  by default. On, it creates a private endpoint to the registry `acr_id` names (subresource
  `registry`) on the install's private-endpoint subnet, a `privatelink.azurecr.io` private DNS
  zone with a virtual network link to the install's VNet, and the endpoint's DNS zone group in
  that zone, so the apps pull over the VNet; a new output, `registry_private_endpoint_id`, names
  the endpoint. It is used only with `registry_credential_mode = "managed_identity"` or
  `"customer_registry"`: the plan refuses it with the `token` mode (set or derived from a
  credential) and without `acr_id` set to a registry's resource ID. The registry must be Premium,
  and the module does not change its public network access. Nothing changes for an install that
  leaves it off.
- **`api_image` and `frontend_image` accept a digest.** Each takes `registry/repository:tag`,
  `registry/repository:tag@sha256:<digest>` or `registry/repository@sha256:<digest>`, for example
  `masterly.azurecr.io/release/api@sha256:<digest>`.
- **The licence claims-floor check now reads a digest-only `api_image`.** The plan-time check
  compares the digest with the api digests `MANIFEST.json` records (`digests.api`). A reference
  with a tag a release records is still compared by its tag. A tag no release records, pinned by
  a digest, falls back to the digest, so a release mirrored under a tag of your own is checked. A
  reference whose tag and digest no release records passes unchecked, as an unrecorded tag does,
  and the application's startup check still applies.
- **Registry location, credential mode and release channel inputs.** Four new inputs:
  - `registry_location` is the registry's login server;
  - `registry_credential_mode` is `"token"`, `"managed_identity"` or `"customer_registry"`;
  - `registry_token` is the bundle's pull credential, `{ username, password }`, and is sensitive;
  - `release_channel` is `"stable"` or `"previous"`.

  The apps' registry blocks follow the mode:
  - `token` pulls with the username and the `registry-password` secret, and creates no `AcrPull`
    grant;
  - `managed_identity` pulls as each app's identity, and `acr_id` grants `AcrPull` to both;
  - `customer_registry` does the same against your own `registry_location`.

  The plan refuses an unknown mode or channel, a `token` mode with no credential, a credential
  outside the `token` mode, and a `customer_registry` mode that names no registry of your own.
- **`api_image` and `frontend_image` are optional.** Left unset, each resolves to
  `<registry_location>/release/<role>@<digest>`, the digest that the `release_channel` release
  in `MANIFEST.json` records, or `<registry_location>/release/<role>:<tag>` for a release that
  records no digest. The channel changes only the digest or tag; the repository is always
  `release/api` and `release/frontend`. An image you set is used as given. As with an explicit
  image, the reference seeds an app when it is created and CD owns the running image thereafter:
  changing `release_channel` on an existing install rolls nothing. Roll a running install back
  with `az containerapp update --image`.
- **`image_references` output.** It reports the resolved api and frontend references, the
  registry server, the credential mode, the channel and its release.

### Deprecated

- **`acr_login_server`, `registry_username` and `registry_password`** are replaced by
  `registry_location` and `registry_token`. They still plan as before, apart from the two
  registry changes under Changed:
  - `acr_login_server` is read as `registry_location`, and its default is now `null`, which
    defers to `registry_location`. `""` still renders no registry block.
  - The credential pair is read as `registry_token`.
  - With `registry_credential_mode` unset, the mode is `token` when a credential is set,
    `customer_registry` when the registry is not Masterly's, and `managed_identity` otherwise
    (which pulls nothing when there is no registry block).

  *Migration:* move `acr_login_server = "<host>"` to `registry_location = "<host>"`.
  `acr_login_server = ""` (public images, no registry block) becomes omitting
  `registry_location`, with no `registry_credential_mode`, credential or `acr_id` set: any of
  those makes an omitted `registry_location` mean `masterly.azurecr.io`. `registry_location = ""`
  is refused. Move `registry_username` and `registry_password` into
  `registry_token = { username = ..., password = ... }`, for example as
  `TF_VAR_registry_token='{"username":"<appId>","password":"..."}'`. Then, unless you pull
  public images, set `registry_credential_mode` to the mode you run. Setting a new input together with the
  deprecated one it replaces is refused at plan. Migrating changes nothing in the plan beyond
  what the deprecated inputs already plan. A mirror that uses the default images must hold them under `release/api` and
  `release/frontend`; an explicit `api_image` or `frontend_image` keeps its own repository.

### Changed

- **The release images are published under `release/`.** `MANIFEST.json` and the README's pins and
  release table now name `masterly.azurecr.io/release/api:<tag>` and
  `masterly.azurecr.io/release/frontend:<tag>` in place of `masterly.azurecr.io/api:<tag>` and
  `masterly.azurecr.io/frontend:<tag>`. Tags and digests are unchanged: each reference names
  the same build under the new path. The release check now refuses a manifest image outside
  `release/<image>`, except `0.17.0`, whose api image was never published under any path and
  whose entry is unchanged. *Migration:* if you pin `api_image` or `frontend_image` by path,
  change `masterly.azurecr.io/api` to `masterly.azurecr.io/release/api` and
  `masterly.azurecr.io/frontend` to `masterly.azurecr.io/release/frontend`, keeping the tag or
  digest. If you mirror the images, copy them from `release/api` and `release/frontend`, and
  hold them under those repositories if you rely on the default image references. If you
  match or allow-list images by repository path (an admission policy, a scanner rule, a
  registry token's scope), add the `release/` repositories. A tool that reads the reference
  from `MANIFEST.json` needs no change.
- **Breaking: the `token` mode creates no `AcrPull` grant.** An install that pulls with a
  registry credential (`registry_username` and `registry_password`) and also sets `acr_id` plans
  to destroy its two `AcrPull` role assignments. Nothing pulls with them: in that mode every app
  pulls with the credential. *Migration:* none is needed to keep pulling. To keep the grants for
  a later move to identity pull, set `registry_credential_mode = "managed_identity"` or
  `"customer_registry"` and remove the credential. Leave `acr_id` set only in an identity mode.
- **Breaking: with no registry input set, the apps have no registry block.** Omitting
  `registry_location` means public images unless `registry_credential_mode`, a credential or
  `acr_id` is set, in which case it is `masterly.azurecr.io`. An install that set none of
  `acr_login_server`, a credential and `acr_id`, and pulled from `masterly.azurecr.io` as its
  identities with `AcrPull` granted out of band, now plans its apps without a registry block.
  *Migration:* set `registry_credential_mode = "managed_identity"` to keep pulling from
  `masterly.azurecr.io` as the app identities.
- **Breaking: `api_image` and `frontend_image` are validated at plan.** The plan now refuses any
  reference that does not take one of the three forms above. A digest must be `sha256:` followed
  by 64 lowercase hex characters. The repository's last segment must be `api` for `api_image` and
  `frontend` for `frontend_image`. The plan also refuses a reference with no registry and one
  with neither a tag nor a digest. The registry is the first segment, and must be a host that
  contains a `.` or a `:` (a port), or `localhost`: `release/api:<tag>` is refused rather than
  read as Docker Hub. *Migration:* a `masterly.azurecr.io/release/api:<tag>` or
  `masterly.azurecr.io/release/frontend:<tag>` reference, as this README shows, already passes. If you mirror the
  images into your own registry under a different repository name, push them to a repository
  whose last segment is `api` or `frontend`. Name the registry host in full. Write a digest in
  lowercase, with its `sha256:` prefix.

### Fixed

- **A calling root may pass `registry_username` from a variable it declares sensitive (MAS-4148).**
  Until now that failed the plan with "Invalid for_each argument ... local.install_secret_names
  has a sensitive value" at `azurerm_key_vault_secret.install` (with `enable_key_vault`), and the
  `image_references` and `vault_backed_secret_names` outputs failed with "Output refers to
  sensitive values". The test of whether a username was supplied is now unmarked with
  `nonsensitive()`, as the test for `registry_token` already was. The username itself keeps the
  caller's mark. Nothing else changes. A root that declared the variable non-sensitive to get
  around this can mark it sensitive again. `registry_token` was not affected: it is declared
  sensitive, and its presence test was already unmarked.

## [0.22.0] - 2026-10-29

### Changed

- **Released against `api` image `v0.135.0` and `frontend` image `v0.143.0`** (from `v0.134.0`
  and `v0.142.0` in 0.21.0): the pair Masterly's reference install runs today. The module itself
  is unchanged. The `api` image verifies licence claims version 2, which adds the ignorable
  `release_ring` claim; a licence minted at an earlier claims version verifies as before.

## [0.21.0] - 2026-10-28

### Fixed

- **`scripts/preflight.sh` no longer states how many role assignments the module creates.** When
  the deploying identity cannot create role assignments, the check said the module writes "up to
  five" of them. That number was typed by hand, had drifted from what the module writes, and could
  mislead you about the size of the grant. The failure now says that the module creates role
  assignments and names the roles that clear the check: Role Based Access Control Administrator,
  User Access Administrator or Owner, at subscription scope. Which identities pass the check is
  unchanged, and so is the module.

## [0.20.0] - 2026-10-23

### Fixed

- **`builtin_auth` gates `ca-frontend` only** (since 0.19.0). It also put built-in authentication
  on `ca-api`. The api is reached internally, by the frontend's server-side calls inside the
  Container Apps environment, so the module no longer configures a gate there; the application
  authenticates its callers as `identity_binding` sets. **On upgrade, the first plan destroys
  one resource, `azapi_resource.builtin_auth["api"]`** (the api's `authConfigs/current`), and
  changes nothing else: the frontend's configuration keeps its address and its body, and both
  apps keep their secrets, `microsoft-provider-authentication-secret` included, which stays on
  `ca-api` unused so that neither app changes. If your configuration still has the `for_each`
  import block 0.19.0 documented, narrow it to `"frontend"` or delete it before you plan: an
  import block for `["api"]` names an instance this version does not have, and the plan fails.
  With `api_ingress_external = true` the published api is no longer behind built-in auth; it
  stays limited to `ingress_allowed_cidrs`, and a plan that sets both warns through the check
  `builtin_auth_does_not_gate_the_published_api`, on every plan while both are set. The README
  section is now "Built-in authentication in front of the frontend".

### Deprecated

- `builtin_auth.api_allowed_applications` and `builtin_auth.api_allowed_audiences`. They are
  ignored: setting either still plans, configures nothing, and warns through the check
  `builtin_auth_api_entries_are_ignored`. Remove them from `builtin_auth`.
  `api_allowed_applications` entries are no longer validated as UUIDs.

## [0.19.1] - 2026-10-22

### Fixed

- **Every apply after the first failed on the `AZKVAuditLogs` table** (since 0.18.0). The table
  set `retention_in_days` and left `total_retention_in_days` unset. Azure fills that in on
  create, the next plan proposed clearing it (`total_retention_in_days = 90 -> null`), and Azure
  refused the update: `InvalidParameter: The specified total retention value is invalid`. The
  table now sets its total retention to `security_log_retention_days` as well, which keeps no
  archive tier, the behaviour it already had. An install that hit the error needs no action
  beyond taking this version: its plan shows no change to the table.

## [0.19.0] - 2026-10-22

### Added

- `builtin_auth` and `builtin_auth_client_secret`: Container Apps built-in authentication
  (EasyAuth) with Microsoft Entra ID on `ca-frontend` and `ca-api`, a platform gate in front of
  the application's own sign-in. The frontend redirects an unauthenticated browser to Entra
  sign-in; the api answers `401`, and admits only its own registration and the service
  principals in `api_allowed_applications`. The client secret is the Container App secret
  `microsoft-provider-authentication-secret` on both apps, a Key Vault reference with
  `enable_key_vault`. Unset by default, which configures nothing. An install that set built-in
  auth up by hand imports the two `authConfigs/current` resources first; the README, "Built-in
  authentication in front of the apps", has the import blocks.
- The module now requires the `Azure/azapi` provider (`~> 2.9`), whether or not `builtin_auth` is
  set: azurerm has no resource for a Container App's auth configuration. `terraform init`
  installs it; an air-gapped install mirrors it alongside azurerm and random.

### Documentation

- README: a new section, "Installing a Canary or Beta build". It shows how to source the module
  by commit with the images pinned by digest, says Canary and Beta builds are never tagged or
  published to the Registry, and gives the move to the Registry source at Stable (same commit,
  `terraform init -upgrade`, a plan that shows no change). It says this module version does not
  check the licence's ring. The sourcing paragraph and Versioning now say semver tags are Stable
  releases.

### Changed

- The frontend's Key Vault grant is now per secret. With `enable_key_vault`, the frontend's
  identity (`id-<prefix>-frontend`) held Key Vault Secrets User on the whole install vault, so
  code running in `ca-frontend`, the internet-facing app, could read the admin database URL, the
  session secret and everything the api seals at runtime. It now holds Secrets User on each of
  its own secrets only: `install-bff-shared-secret`, plus `install-registry-password` and
  `install-oidc-client-secret` when those are set. **On upgrade, the next apply replaces the one
  vault-scope role assignment (`kv_secrets_user_frontend[0]`) with one assignment per frontend
  secret.** Role assignments propagate eventually, so if the new `ca-frontend` revision cannot
  resolve a secret on that apply, run the apply again. No input changes.

## [0.18.0] - 2026-10-19

### Added

- `postgres_pgbouncer` (default `false`), which turns on the starter Flexible Server's built-in
  PgBouncer in transaction mode. `MASTERLY_DATABASE_URL` moves to port 6432 and
  `MASTERLY_DATABASE_POOLER = transaction` is set; `MASTERLY_DATABASE_DIRECT_URL` (new secret
  `database-direct-url`, Key Vault-backed when `enable_key_vault`) carries the same server on 5432;
  the endpoints subnet admits 6432. Refused on a burstable (`B_*`) SKU, with
  `external_database_url`, and when `postgres_server_parameters` sets a `pgbouncer.*` key the module
  owns. Needs an api image that carries MAS-1615 (masterly-application-backend PR #488).
  Turning it back off interrupts the database connection during the rollout. See "Connection
  budget" in the README. Off changes nothing.
- `alerts_routed_externally` (default `false`): the escape hatch for the production
  notification-target check. Set it when alerts are routed outside Terraform, for example by an
  Azure Policy or subscription-level alert processing rules. It creates and changes no resource.

- `postgres_auto_grow` and `postgres_storage_tier` for the starter Postgres server. Unset,
  `postgres_auto_grow` is on in `mode = "production"` and off otherwise, so **existing
  production installs get storage autogrow turned on, in place, on upgrade** unless they set
  `postgres_auto_grow = false`. Grown storage cannot be reduced. The module now never plans
  `postgres_storage_mb` below the size the existing server holds, so a disk Azure has grown is
  not planned as a shrink (which would replace the server and its databases); raise
  `postgres_storage_mb` above the real size to grow it yourself. `postgres_storage_tier`
  (P4 to P80) sets the storage performance tier; unset keeps Azure's default. Neither changes
  anything with `external_database_url` set. The lookup that finds the existing server runs on
  every starter-server install, so the identity that applies the module needs read access to the
  subscription's resources, as it already does for Entra authentication.
- The README documents the runtime subnet's network security group as a departure from Azure's
  recommended baseline: in a public environment (`aca_internal_load_balancer = false`) its
  `allow-app-ingress` rule admits the Internet on TCP 80 and 443, and with
  `aca_internal_load_balancer = true` it admits only the virtual network. The `iac-scan` check
  suppresses Trivy AZU-0047 for `main.tf` through `.trivyignore.yaml`, naming that README entry.
  No Terraform changes.
- `postgres_server_parameters`, a map of Postgres server parameters to set on the starter
  Flexible Server beside the module's three log parameters. It refuses those three keys (ADR 0080),
  any entry when `external_database_url` is set, and a `max_connections` that is not a whole
  number of at least 1. The Postgres connections alert takes its limit from `max_connections`
  here when `alert_postgres_max_connections` is not set, ahead of the SKU default. Static
  parameters apply after a restart, which the azurerm provider performs on apply unless
  `restart_server_on_configuration_value_change` is turned off.
- The plan refuses a licence the pinned `api` image cannot run on. A licence's signed header
  states its claims floor, the oldest licence contract an install may verify it with; when
  `license_token`'s floor is above the claims version `MANIFEST.json` records for `api_image`,
  `terraform plan` fails, naming the floor, the image's claims version and the oldest `api` tag
  that verifies the licence (ADR 0013, amended 2026-10-06). It runs offline, from the manifest
  inside the module, and compares `api_image` by its tag, so a mirrored image is checked too. A
  licence with no claims-version header, and an `api_image` whose tag the manifest does not
  record, plan as before. Licences issued today carry a floor of 0, so no plan fails on this yet.
- `MANIFEST.json` release entries record `api_claims_version`, the licence claims version the
  release's `api` image verifies; an entry without it reads as 0. Added within `schema_version` 1
  as a new key inside a release entry, which
  [docs/release-manifest.md](docs/release-manifest.md) allows. The 0.17.0 entry records 0, which
  is what its `api` image verifies; the release check requires the field on every newer release.
- `MANIFEST.json` records `image_floors`: for each app, the oldest image an install can run, why,
  and the image tags that have no published image. Added within `schema_version` 1 as a new
  top-level key, which [docs/release-manifest.md](docs/release-manifest.md) allows. The README's
  statement of the floors, which used to be typed into the usage example's comments, is now
  generated from it, and the release check refuses a release that names an image below its
  app's floor or a tag with no published image.

- App availability diagnostics, **on by default in `mode = "production"`**: an `AllMetrics`
  diagnostic setting on `ca-api`, `ca-frontend` and `ca-workers` that sends their platform
  metrics to the install's Log Analytics workspace, and one log search alert per app,
  `<app>-silent`, that fires when an app has sent no metrics for 45 minutes. It covers an app
  that is gone — deleted, its environment torn down, its revision deprovisioned — which the
  `<app>-unavailable` metric alerts cannot see, because a metric alert with no data does not
  fire. A production install's next apply creates these with no variable changed, and **adds a
  standing cost to its Azure bill**: continuous metric ingest into the workspace, and each rule
  billed by its evaluation frequency. The new input `enable_app_availability_diagnostics` turns
  both off (`false`), or on outside production (`true`, which needs `enable_diagnostics = true`).
  The rule is created only for an app whose `min_replicas` is 1 or more. See
  [App availability diagnostics](README.md#app-availability-diagnostics) (ADR 0080, amendment of
  2026-10-07; MAS-372).

- Container Apps sizing and scaling inputs (MAS-1296). An install that sets none of them plans no
  change to any app's CPU, memory or replica bounds:
  - `app_resources`: CPU and memory per replica, keyed by app name (`api`, `frontend`,
    `workers`). An app not listed keeps 0.5 vCPU / 1Gi. Values are refused at plan unless they
    are a pair Container Apps accepts: 0.25 to 2 vCPU in steps of 0.25, at 1 vCPU : 2 GiB.
    `examples/production` and the README's usage example now run the api at 1 vCPU / 2Gi.
  - `frontend_max_replicas` (default 3, the maximum every frontend had before), at least 1 and
    at least `frontend_min_replicas`.
  - `workers_termination_grace_period_seconds` (default 600, 0-600): how long a stopping
    `ca-workers` replica has to finish the jobs it is running before it is killed.
  - An `azure-servicebus` scale rule on `ca-workers` when `enable_service_bus` and
    `enable_workers` are both on. It scales on the jobs queue's message count, about one replica
    per 5 messages, between `workers_min_replicas` and `workers_max_replicas`, and authenticates
    as the apps' managed identity. That identity is granted **Azure Service Bus Data Owner** on
    the jobs queue alone, for the scaler to read the queue's message count. With the rule,
    `workers_min_replicas = 0` becomes usable on Service Bus: the rule starts a worker when jobs
    arrive. The rule has been checked under mock providers only; that queue-scope Data Owner is
    enough, and that the scaler reaches a Premium namespace with public network access disabled,
    are checked on a live install before this version is released.
  - A warning (a `check`, not a refusal) when `workers_max_replicas` is above
    `workers_min_replicas` on the polling binding, where the workers have no queue length to
    scale on and stay at the minimum.

- `public_api_url`: the API's public base URL, an absolute `https://` URL with no query string,
  fragment or credentials. When set, `ca-api`, `ca-workers` and `ca-frontend` get it as
  `MASTERLY_PUBLIC_API_URL`, with trailing slashes dropped; unset (the default), no app gets it,
  so an install that does not set it plans as before. Until now the frontend's value had to be
  set by hand and the next `terraform apply` removed it. The input's description and
  [The API's public address](docs/networking.md#the-apis-public-address) name the three conditions under
  which the value works (MAS-1148).

- `MANIFEST.json` release entries may carry `digests`: the `api` and `frontend` image digests of
  the release candidate, each `sha256:…`. It is a new key inside a release entry, which
  `schema_version` 1 allows, so a consumer that ignores unknown keys needs no change;
  [docs/release-manifest.md](docs/release-manifest.md) documents it. The release check proves
  their shape on every change, and `--observed-digests` compares them with the digests the image
  tags resolve to in the registry, naming both on a disagreement (MAS-1692).

- `database_auth` (`"entra"` | `"password"`) and `redis_auth` (`"entra"` | `"key"`): how the apps
  authenticate to the starter Postgres server and to Redis. `"entra"` is Microsoft Entra ID only,
  Azure's recommended baseline: password authentication and access keys are off, the apps'
  identity is the server's Microsoft Entra administrator and holds a data access policy on
  whichever `redis_offering` is active, the connection strings carry no credential, and
  `ca-api` / `ca-workers` get `MASTERLY_DATABASE_AUTH` / `MASTERLY_REDIS_AUTH`. It needs api images
  `v0.133.7` or later. `"password"` and `"key"` keep today's behaviour and are documented
  departures. BYO-DB (`external_database_url`) is unaffected and refuses `database_auth = "entra"`
  (MAS-1085).

- Three inputs for the install's Log Analytics workspace. An install that sets none of them keeps
  today's query access and retention, and gains the Key Vault audit retention below:
  - `log_query_public_access` (default `true`): whether the workspace answers queries from the
    public network. `false` leaves only queries through an Azure Monitor Private Link Scope
    (AMPLS) of your own; the module creates none.
  - `log_retention_days` (default `30`, 30-730): the workspace's retention, which every table
    except `AZKVAuditLogs` follows. 30 is the retention the workspace already had.
  - `security_log_retention_days` (default `90`, 30-730): the retention of the `AZKVAuditLogs`
    table, the Key Vault audit events, set on that table alone. The next apply raises that table
    from 30 to 90 days, which Azure bills per GB per month beyond the first 31.

  A value outside 30-730 is refused at plan. See
  [The Log Analytics workspace](README.md#the-log-analytics-workspace) for the roles that query
  the workspace, how to set up an AMPLS, and why the workspace is not placed in a network
  security perimeter.

### Changed

- **Upgrade action for production installs with no notification target: set `alert_email` or
  `alert_action_group_id`, or `alerts_routed_externally = true`, before the next plan.** The
  availability alerts and the action group no longer need `enable_diagnostics`, and a
  production plan with no notification target is refused. `postgres-unavailable`,
  `<app>-unavailable` (api, frontend and, with `enable_workers`, workers), `app-not-ready` and
  the module's `ag-<prefix>-alerts` action group are now created in every mode (ADR 0080,
  amendment of 2026-10-18). **An existing install's next apply creates them with no variable
  changed** wherever `enable_diagnostics` was off, which adds Azure Monitor cost: metric alert
  rules, and the `app-not-ready` log search rule billed per evaluation. `postgres-silent`, the
  saturation and load alerts and the diagnostic settings stay behind `enable_diagnostics`. A
  `mode = "production"` plan with neither `alert_email` nor `alert_action_group_id` now fails at
  plan, whatever `enable_diagnostics` says, because its severity-0 alerts would notify nobody:
  set one of them, or set `alerts_routed_externally = true` if alert routing is done outside
  Terraform (Azure Policy or subscription-level alert processing rules).
- **The install's Log Analytics workspace accepts Microsoft Entra ID only and takes no ingestion
  over the public network.** The module turns off the workspace's local (shared-key)
  authentication and sets its public ingestion access to `Disabled`; both stay off whatever the
  inputs say. The install's own logs and metrics arrive through diagnostic settings, which need
  neither. Anything of your own that sends to the workspace with its shared key, or over the
  public network (an agent, the Data Collector API, the Logs Ingestion API from outside an
  AMPLS), stops being accepted from the apply on; send with a Microsoft Entra identity through an
  AMPLS instead. Queries keep working from the public network by default, each signed in with
  Microsoft Entra ID (Log Analytics Reader on the workspace).

  **Apply the release that moves container logs to Azure Monitor first, and let its apply
  finish, before applying this one.** That release moves the Container Apps environment from
  `logs_destination = "log-analytics"`, which delivers the apps' logs with the workspace's shared
  key over the public ingestion endpoint, to `azure-monitor` and a diagnostic setting. An
  environment still on `log-analytics` when this change applies can no longer deliver its logs,
  and the apps' console and system logs stop reaching the workspace. The change has been planned
  under mock providers only; a plan against a live install confirms it updates the workspace in
  place before this version is released.

- **The starter Postgres server's error log no longer carries values** (ADR 0080, amendment of
  2026-09-10). The module sets three server parameters on the server it provisions:
  `log_error_verbosity = TERSE` (no `DETAIL:`, `HINT:` or `CONTEXT:` lines — `DETAIL:` is where
  a constraint violation prints the conflicting key values or the whole failing row),
  `log_parameter_max_length_on_error = 0` and `log_parameter_max_length = 0` (no bound parameter
  values). `log_min_error_statement` stays at its default, so a failing statement's text is
  still logged. All three apply without a restart. A BYO-DB server (`external_database_url`) is
  not touched.
- **Every diagnostic setting names its log categories** instead of the `allLogs` category
  group, so a category Azure adds to a resource type later no longer reaches your workspace on
  its own. The next apply updates each setting in place, and these categories **stop being
  sent**:
  - Postgres: `PostgreSQLFlexSessions`, `PostgreSQLFlexQueryStoreRuntime`,
    `PostgreSQLFlexQueryStoreWaitStats`, `PostgreSQLFlexTableStats` and
    `PostgreSQLFlexDatabaseXacts`. `PostgreSQLLogs` is kept.
  - Key Vault: `AzurePolicyEvaluationDetails`. `AuditEvent` is kept.
  - Service Bus: `RuntimeAuditLogs`, `ApplicationMetricsLogs` and `VNetAndIPFilteringLogs`.
    `OperationalLogs` and `DiagnosticErrorLogs` are kept.

  Azure Cache for Redis keeps both of its categories (`ConnectedClientList`,
  `MSEntraAuthenticationAuditLog`), the Azure Managed Redis database keeps `ConnectionEvents`,
  and the per-app settings stay metrics-only. A workspace query or workbook of your own that
  reads a dropped category finds no new rows after the apply.
- **Key Vault audit events move to the `AZKVAuditLogs` table.** The Key Vault diagnostic
  setting now writes `AuditEvent` to the resource-specific table
  (`log_analytics_destination_type = "Dedicated"`) instead of `AzureDiagnostics`. Events
  written before the apply stay in `AzureDiagnostics` until its retention ages them out; a query
  of your own that reads vault audit events from `AzureDiagnostics` has to move to
  `AZKVAuditLogs` for events after it.
- The diagnostic bundle collects `logs/q7-key-vault-failures.json`: the vault's failed
  operations from `AZKVAuditLogs`, by operation, result code and count, with no caller identity,
  caller address or secret name. It is skipped on an install without a vault, and
  `manifest.json` names the vault under `install.key_vault`.
- **The `api-latency` and `app-not-ready` alerts read both container console-log tables**: the
  resource-specific `ContainerAppConsoleLogs` and the legacy custom table
  `ContainerAppConsoleLogs_CL`, so each keeps reading an install's console log while it moves from
  one table to the other. The legacy table stays in both queries for one release cycle only; a
  query or workbook of your own that reads `ContainerAppConsoleLogs_CL` should move to
  `ContainerAppConsoleLogs` before then. The apps each alert covers are unchanged — `ca-api` for
  latency, `ca-api` and `ca-frontend` for readiness. The next apply updates both rules in place
  (MAS-2038).
- **Container logs reach the workspace through Azure Monitor.** The Container Apps environment's
  `logs_destination` moves from `log-analytics` to `azure-monitor`, so the environment no longer
  writes to the install's workspace with the workspace's shared key. A new diagnostic setting on
  the environment, `diag-<name_prefix>-aca-env`, sends `ContainerAppConsoleLogs` and
  `ContainerAppSystemLogs` to the workspace's resource-specific tables of the same names
  (`log_analytics_destination_type = "Dedicated"`). Being on the environment, it covers `ca-api`,
  `ca-frontend`, `ca-workers`, the `ca-bundle-init` init containers and any app added later, and it
  is created in every mode, as the environment's logs always were. The per-app diagnostic
  settings stay metrics-only. The next apply changes the environment and creates the setting.
  The change has been planned under mock providers only, which cannot show whether Azure updates
  the environment in place or replaces it (a replacement would also replace every app and change
  its FQDN); a plan against a live install confirms an in-place update before this version is
  released. From the apply on, the legacy `ContainerAppConsoleLogs_CL` and
  `ContainerAppSystemLogs_CL` tables get no new rows, and their older rows stay until the
  workspace's retention ages them out. The `api-latency` and `app-not-ready` alerts and the diagnostic bundle read both the `_CL`
  tables and the resource-specific ones for one release cycle, which covers the move; a query or
  workbook of your own that reads a `_CL` table should move to the resource-specific table.
  **Apply this release before the release that locks the workspace down**: that release turns
  off the workspace's shared-key access, which an environment still on `log-analytics` needs to
  deliver its logs. **Breaking for a direct caller of `modules/aca-env-consumption`**: the
  submodule no longer takes `log_analytics_workspace_id`, so passing it fails with "Unsupported
  argument". Drop the argument and attach a diagnostic setting to the submodule's `id` output, as
  the root module now does (MAS-2023).

- **Service Bus installs now scale their workers.** Until now `ca-workers` had no scale rule, so
  `workers_max_replicas` above `workers_min_replicas` did nothing. With `enable_service_bus` and
  `enable_workers` on, the next apply adds the scale rule and the queue grant above, and the
  workers then run up to `workers_max_replicas` while jobs are waiting. An install whose two
  values are equal (both default to 1) keeps the same number of workers (MAS-1296).

- **`ca-workers` now has a 600-second termination grace period** instead of Azure's default of
  30 seconds, so a worker scaled in or replaced mid-job finishes it rather than being killed and
  leaving the job to wait out its lease. This is the one change the next apply makes to every
  install that runs `enable_workers`: it rolls `ca-workers` to a new revision once. It also means
  a later revision swap can wait up to 600 seconds for a busy worker to stop. Set
  `workers_termination_grace_period_seconds` to choose another value (MAS-1296).

- With `enable_workers`, `workers_max_replicas` must now be at least `workers_min_replicas`
  (Container Apps refuses the opposite at apply), and its description says how the workers
  scale (MAS-1296).

- A release is cut in a commit that merges to `main` before the version is tagged, and is tested
  as a release candidate in between. So `MANIFEST.json` on `main` can name, as `latest`, a
  version whose tag does not exist yet, and an entry's `date` is the day the release was cut.
  The file at a `vX.Y.Z` tag is unchanged in meaning: every version in it is published, and
  `cut-release` refuses a tag whose commit lists another version with no tag yet
  (`check_release_manifest.py --published-tags`). To find the newest published version from
  `main`, take the highest version whose tag exists
  ([docs/release-manifest.md](docs/release-manifest.md), "Where to get it") (MAS-1692).

- **Breaking: the module now requires azurerm `~> 5.8`** (was `~> 4.61`), and its nested modules
  `~> 5.0` (they said `~> 4.0`, which by itself kept azurerm 5 out of any configuration using
  this module). A provider major changes how every install plans and applies, so the version
  that carries this is a breaking module release. Before moving an existing install to it:
  1. **Raise your root configuration's azurerm constraint** to `~> 5.8` (or wider within 5.x)
     and run `terraform init -upgrade`. Commit the `.terraform.lock.hcl` it writes; see
     "Provider versions and the lock file" in the README for the multi-platform lock command.
  2. **Register resource providers yourself.** azurerm 5 no longer registers any on the
     subscription by default (`resource_provider_registrations` defaults to `none`). Run
     `scripts/preflight.sh`, with `--register` if it reports a provider as unregistered. Setting
     `resource_provider_registrations = "legacy"` in your provider block restores the v4
     behaviour instead.
  3. **Remove `skip_provider_registration`** from your provider block if it is there; azurerm 5
     removed it. An `enhanced_validation` block now goes inside `features`. If you set the
     `ARM_PROVIDER_ENHANCED_VALIDATION` environment variable, it is gone: use that block, or
     `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS` and
     `ARM_PROVIDER_ENHANCED_VALIDATION_RESOURCE_PROVIDERS`. Location validation is now off by
     default, so a mistyped `location` fails at apply rather than at plan.
  4. **Plan with refresh on** (the default) and read the plan before applying. The private DNS
     zone links for Postgres, Key Vault, Redis and a private Service Bus namespace now name their
     zone with `private_dns_zone_id`, because azurerm 5 removed `private_dns_zone_name` and
     `resource_group_name` from that resource. Their Azure resource IDs do not change and a
     refreshing plan shows no change to them; a plan run with `-refresh=false` cannot see that
     and shows them as replaced. A plan that replaces any of them, or anything else, is not the
     expected upgrade: stop there.

  Nothing else the module sets was removed or changed in meaning by azurerm 5; the arguments it
  uses were checked against the provider's 5.0 upgrade guide. Configuration of your own in the
  same root that uses azurerm resources needs the same check against that guide (MAS-129).
- `mode = "production"` now defaults a **new** install's starter Postgres server and Redis to
  Microsoft Entra ID authentication (`"entra"`). An existing server or cache is never switched by
  the default: when an input is unset, the module reads what the server or cache already uses (a
  `masterly-auth` tag it now sets; untagged means password or key), and a production install
  whose existing server or cache still uses a password or key **no longer plans until you
  choose**. Set `database_auth = "password"` and `redis_auth = "key"` to keep the install exactly
  as it is, or follow "Moving an existing install to Microsoft Entra authentication" in the README
  — it includes the ownership steps the starter server needs first. Every change on that path is
  made in place; none replaces the server or the cache. Evaluation installs keep the password and
  the key (MAS-1085).
- The starter Postgres server now carries a second tag, `masterly-admin-password` (`"generated"`
  or `"none"`), recording whether it holds the module's generated `masterly_admin` password. A
  server that moves to `"entra"` keeps that password, unused, so the move plans no password change
  and the server can move back; a server created on `"entra"` is never sent one. Replacing
  `random_password.postgres_admin` still changes the password on the server and in the apps'
  connection string in the same apply; the README's "The generated admin password" says how.
  `database_auth = "entra"` therefore still reads the subscription's server listing, as an unset
  input does (MAS-1085).

- The `masterly-jobs` Service Bus queue (`enable_service_bus = true`) now sets its message lock
  duration to five minutes, Azure's maximum, where it previously left Azure's one-minute default
  in place. The worker renews the lock for as long as a drain runs (api images `v0.133.12` and
  later), so the duration is the margin left after a failed renewal, not a limit on how long a
  drain may take. On the next apply this is an in-place update of the queue: it is not
  recreated, no message is lost and nothing goes down (MAS-1285).
- **Version numbers carry a promise, and the module's follows its images.** A patch adds no
  capability, no new input or required setting and no database migration; a minor may add all of
  those, and before 1.0.0 may also carry a breaking change; the module and both images move to
  1.0.0 together at general availability. A module release now bumps at least as far as the
  larger of its `api` and `frontend` image bumps, so a module patch never moves an image by more
  than a patch: `scripts/check_release_manifest.py` refuses a release that would, naming both
  bumps. The README's pin guidance is corrected: `~> X.Y.0` takes patches of `X.Y` only, while
  `~> X.Y` takes every later minor too. It said `~>` took "patches within a minor" beside an
  example that takes minors. No change to any resource; nothing to apply (MAS-1663).

### Removed

- **Breaking for a direct caller of `modules/log-analytics-workspace`: its `primary_shared_key`
  output is removed.** The workspace's shared keys authenticate nothing now, so there is no key
  worth handing out, and nothing in the module reads one. Referring to
  `module.<name>.primary_shared_key` fails with "Unsupported attribute"; authenticate to the
  workspace with a Microsoft Entra identity instead. The root module never exposed the key, so a
  caller of the root module has nothing to change.
- **The `api-latency` and `app-not-ready` alerts and the diagnostic bundle no longer read the
  legacy `ContainerAppConsoleLogs_CL` and `ContainerAppSystemLogs_CL` tables.** Their queries
  read only the resource-specific `ContainerAppConsoleLogs` and `ContainerAppSystemLogs` tables,
  which the diagnostic setting on the Container Apps environment has written since the release
  that moved the environment to Azure Monitor. The apps each query covers are unchanged:
  `ca-api` for latency, `ca-api` and `ca-frontend` for readiness, and the same apps in each
  bundle query `q1`–`q5`. Apply the release that moved the environment to Azure Monitor first:
  until it is applied, an install's lines land only in the `_CL` tables, which these queries no
  longer read. **Saved queries, workbooks and
  alerts of your own that read a `_CL` table should be migrated** to the resource-specific table
  (`ContainerAppName_s` becomes `ContainerAppName`, `Log_s` becomes `Log`, and so on without the
  type suffix); the older rows stay in the `_CL` tables until the workspace's retention ages them
  out. The next apply updates both alert rules in place.

### Fixed

- **A break-glass attempt made in the GUI is throttled and audited by the browser's address.**
  The module now generates a shared secret (`random_password.bff_shared_secret`) and sets it as
  `MASTERLY_BFF_SHARED_SECRET` on `ca-api` and `ca-frontend`, and on no other app, as a
  Container App secret (a Key Vault reference with `enable_key_vault`), never as plain env.
  Until now it set it on neither app, so the `api` attributed every GUI break-glass attempt to a
  frontend replica: every GUI attempt shared one throttle window, so a few wrong guesses from
  anyone throttled the genuine sign-in through the GUI as well, and the audit record named the
  replica. It needs `api` image `v0.133.4` or later and `frontend` image `v0.139.0` or later,
  which every image pair since 0.16.0 meets; with an older image on either app nothing reads the
  variable and attempts are attributed as before. See
  [The BFF shared secret](README.md#the-bff-shared-secret) (MAS-1405).

  The next apply rolls `ca-api` and `ca-frontend` to a new revision once each; `ca-workers` is
  unchanged. While one of the two runs with the secret and the other does not, the `api`
  ignores the BFF's statement and attributes attempts as before; nothing fails because of the
  mismatch itself. With `enable_key_vault` the secret is written to the vault as
  `install-bff-shared-secret`, and an install whose frontend carried no secret before (neither
  `identity_binding = "oidc"` nor `registry_username`) now also grants the frontend's identity
  Key Vault Secrets User on the vault, which it needs to resolve the reference. Role assignments
  take effect eventually, so if the frontend's new revision cannot resolve the secret on that
  apply, run the apply again.

- The `postgres-silent` alert rule is accepted by Azure. Azure refused it on create (`400`: the
  number of evaluation periods must be 1 for a query that does not project `TimeGenerated`), so
  `enable_diagnostics = true` with a provisioned Postgres server could not apply on 0.16.0 and
  0.17.0. The rule now uses one evaluation period over a 45-minute window, and pages after 45
  minutes of silence where it previously intended about 40 (MAS-1531).

- **0.17.0 pinned an `api` image that was never published.** Its manifest entry names
  `masterly.azurecr.io/api:v0.133.11`, which has no image in the registry, so an install that
  pins `api_image` to 0.17.0's pair cannot pull it. **Installs on 0.17.0 should move to 0.18.0**,
  whose pair (`api:v0.133.13`, `frontend:v0.141.0`) is published. `MANIFEST.json` now lists the
  `api` tags `v0.133.9` to `v0.133.12` as having no published image (and no longer lists
  `v0.133.1`, which is published), and the 0.17.0 entry carries a `known_issue` saying so.
  `scripts/check_release_manifest.py` lets a release older than the newest name an unpublished
  tag only when its entry records a `known_issue`; the newest release still may not
  ([docs/release-manifest.md](docs/release-manifest.md)).

## [0.17.0] - 2026-10-05

### Added

- `RUNTIME_ENV.json`, the machine-readable statement of every environment variable the module sets
  on `ca-api`, `ca-workers` and `ca-frontend`, by name and per app, split into plain env and
  Container App secret references. Generated from the `.tf` files by
  `scripts/check_release_manifest.py`'s sibling, `scripts/check_runtime_env.py --write`, and checked
  on every pull request: a committed copy that is not what the files produce fails CI, and so does an
  entry in the diagnostic bundle's `ENV_VALUE_ALLOWLIST` naming a variable the module sets on no
  app. The shape a program can rely on is [docs/runtime-env.md](docs/runtime-env.md). It exists so
  the application repositories can check their own code and runbooks against what the module
  actually sets, instead of keeping three hand-maintained copies of one list (MAS-545).
- Load alerts, created with the rest of the alert set when diagnostics are on (the default in
  `mode = "production"`), so an install running out of headroom is noticed before it becomes an
  outage: Postgres CPU, active connections and IOPS consumed on the provisioned server;
  dead-lettered messages on the `masterly-jobs` Service Bus queue; the api's 95th-percentile
  request duration, read from its own access log; and `ca-workers` memory working set. Each
  threshold is an input with a starting default — `alert_postgres_cpu_percent` (80),
  `alert_postgres_connections_percent` (70), `alert_postgres_iops_percent` (80),
  `alert_servicebus_dead_letter_threshold` (0), `alert_api_p95_ms` (2000),
  `alert_workers_memory_percent` (85) — to be tuned from the install's own baseline. The
  connections alert takes Azure's default `max_connections` for `postgres_sku_name`, or
  `alert_postgres_max_connections` when set; for a SKU the module cannot size it creates no
  connections alert and every plan warns. The README's "Load alerts" section says what each
  alert means and what to do. There is no alert yet on the age of the oldest queued job: the
  application does not write it to its log. `GET /v1/ops/metrics` reports it (MAS-1291).
- The `aca-container-app` submodule now refuses a `memory` that is not stated in Gi, and
  outputs the configured value (MAS-1291).
- A Service Bus namespace on Premium in `mode = "production"` now runs private: public network
  access is disabled, and the apps reach it over a private endpoint in the private-endpoints
  subnet, with a `privatelink.servicebus.windows.net` private DNS zone linked to the install's
  VNet. That subnet's network security group admits AMQP over TLS (TCP 5671) from the runtime
  subnet when, and only when, such a namespace exists. A new input,
  `servicebus_private_dns_zone_id`, takes a centrally managed zone instead, as the Postgres,
  Key Vault and Redis zone inputs do, and refuses a zone of any other name. Basic and Standard
  namespaces, and every namespace outside production, keep public network access as before
  (MAS-1086).

- The api is told the backup horizon an erasure's completion record states. When the module
  provisions the starter Postgres server, `ca-api` (and `ca-workers`, which shares its
  environment) now carries `MASTERLY_ERASURE_BACKUP_RETENTION_DAYS`, set to
  `postgres_backup_retention_days`, so the record can say how long an erased record may still
  exist in that server's backups. On BYO-DB (`external_database_url` set) the variable is not set
  at all: the module does not own your backups, and the record says your own backup policy
  governs. The diagnostic bundle copies its value, as a non-secret setting (MAS-790).

- An `api_url` output: the API's base URL for the Python SDK and your own pipelines,
  `https://` followed by the API's ingress hostname, in the same shape as `frontend_url`. It is
  null unless `api_ingress_external = true`, because an unpublished API has no address a client
  outside the Container App Environment can reach. Until now the only output carrying the API's
  hostname was `api_internal_fqdn`, so finding the base URL meant reading the Container App's
  ingress in the Azure portal (MAS-242).

### Changed

- The diagnostic bundle names every collected file that can carry statement text for the
  line-by-line read, not only the files where its scan found some. `manifest.json` →
  `record_data.needs_line_by_line_review` was filled only from a scan for the shapes Postgres
  writes at its defaults (`STATEMENT:`, `DETAIL: Key (…)`, `PARAMETERS:`), so a Postgres error
  with no such line — a deadlock, connection-slot exhaustion, a server logging its errors
  another way — left the list empty, printed `ok  no statement text found`, and printed no READ
  FIRST block, while `README.txt` told you to start with the files named in that list. The list
  now always carries `logs/q6-postgres-logs.json` and `logs/q4-request-trace.json` when the run
  collected them; a new `record_data.statement_text_found_in` is the subset where the scan did
  match, and the terminal escalates those to "statement text found here". The `ok  no
  statement text found` line still prints, as a statement about the scan. The harness asserts
  the no-marker case and the selftest breaks the seeding and the scan separately (MAS-423).

- `api_internal_fqdn`'s description now says what the output holds. It said the hostname was
  internal and reachable only inside the environment, which is true only while
  `api_ingress_external` is false; with the API published, Azure reports the published hostname
  there. The output keeps its name and its value, so nothing that reads it changes; read
  `api_url` for a client's base URL. The description also carries the caveat the app module
  already documented: the hostname is for a person or a client, not for wiring one app to another
  (MAS-242).

- `mode = "production"` now refuses `workers_min_replicas = 0` at plan time, the same guard
  `api_min_replicas` and `frontend_min_replicas` already carry. The variable's description
  already said to keep it at 1 or more, but nothing enforced it: `ca-workers` has no ingress, so
  nothing wakes a workers app scaled to zero, and every queued job waits indefinitely. A zero
  floor is also the one setting at which the workers no-replica alert stands down, so such an
  install would stall with no alert. A production install that sets `workers_min_replicas = 0`
  no longer plans; set it to 1 or more (1 is the default). Evaluation installs are unaffected
  (MAS-371).

- **Upgrade action for production installs that use Service Bus.** `servicebus_sku` no longer
  defaults to `"Standard"`, and in `mode = "production"` with `enable_service_bus = true` the
  plan is refused until you set it. Set `"Premium"`, the recommendation, for a private
  namespace (about $677 per month per messaging unit in Sweden Central), or `"Standard"`, the
  documented opt-down, which keeps a public endpoint. **To keep an existing Standard namespace
  unchanged, set `servicebus_sku = "Standard"`**: moving a namespace to or from Premium replaces
  it, together with its `masterly-jobs` queue and the apps' two role assignments, and job
  notifications still in the queue are lost with it. The module has no default here because it
  cannot tell a new install from an existing one. Outside production, and wherever Service Bus
  is disabled, an unset `servicebus_sku` still means Standard and nothing changes; an explicit
  value always wins (MAS-1086).
- `postgres_geo_redundant_backup` now defaults to `null`, and unset it means: on for
  `mode = "production"` in a region where the module knows Azure supports geo-redundant backup
  for Postgres flexible server (Sweden Central today), off in every other region and on every
  evaluation install. It used to default to `false` everywhere. Set it to `true` or `false` to
  decide yourself; your value always wins. Poland Central and Spain Central do not support it;
  other regions stay off until the module records them, and the README's departures section
  says how to turn it on there and what to check first (MAS-1087).
- The starter Postgres server now ignores later changes to `geo_redundant_backup_enabled`
  (`lifecycle.ignore_changes`). Azure accepts the setting only at creation, so changing it used
  to plan a replacement of the server, which destroys every Environment database on it. The
  value now takes effect only when the server is created: upgrading to this version does not
  change, or replace, an existing server, which keeps the setting it was created with.
  Changing `postgres_geo_redundant_backup` on an existing install no longer plans
  anything for the server; to change the setting, restore the server to a new one (MAS-1087).

### Fixed

- The header comment at the top of `main.tf` described the module as it was several releases
  ago. It listed Key Vault-backed secrets, Redis and the dedicated workers app as deliberately
  deferred, although all three ship as opt-in subsystems and `mode = "production"` requires
  them, and it said the install does not call Masterly's control plane, although licence refresh
  and usage reporting are both available as opt-ins. The header now names those subsystems and
  lists only what is still deferred: custom domains and the per-install Entra identity of
  ADR 0020, matching the README's "Deliberately deferred" section. Comments only; nothing an
  install plans or applies changed (MAS-225).
- `servicebus_sku = "Premium"` now provisions one messaging unit and one partition. Before, the
  module requested a Premium namespace with neither, which the provider refuses at apply, so
  Premium could not be used at all. Basic and Standard namespaces plan no change from this
  (MAS-1086).

## [0.16.0] - 2026-09-24

### Added

- `session_secret_previous` — the outgoing session secret, kept acceptable for verifying
  existing sessions while a rotation completes. Replacing `random_password.session_secret` on
  its own signs out every signed-in user the moment the new revision takes traffic, which makes
  the operation you perform when a secret may have leaked an outage you have to schedule — and
  a rotation you schedule is one you postpone. The input writes
  `MASTERLY_SESSION_SECRET_PREVIOUS` on `ca-api` as a Container App secret (a Key Vault
  reference with `enable_key_vault`), and the application accepts the listed values for
  **verification only**, never for signing, so the rotation is two ordinary applies with no
  session loss: name the old value while replacing the generated one, then clear it once no
  session signed with the old value can still be within its lifetime. The plan refuses a value
  shorter than 32 characters — a listed key verifies sessions as well as the one that signs
  them, so it is held to the same minimum. Null (the default) sets nothing, and an install that
  never rotates is unchanged. "Rotating the session secret" in the README has the procedure and
  how long to leave the window open. Reading the variable needs an `api` image that has it: the
  next `MANIFEST.json` image pair is the first to (MAS-431).
- `ca_bundle_pem` — an install-wide CA bundle, mounted into `ca-api` and `ca-workers` and
  pointed to with `SSL_CERT_FILE`, so a relay, DSN or endpoint on an internal CA can be trusted
  by name instead of not at all. Before this input there was no supported way to do it on a
  stock install: `SSL_CERT_FILE` named a path, but the module had no mechanism to put a file at
  that path, and `azurerm_container_app`'s `volume` block turns out to support only
  `AzureFile`/`EmptyDir` — there is no Secret-backed volume type in this provider, unlike the
  raw Azure Container Apps API. The mount is an EmptyDir volume plus a short-lived init
  container (the app's own image) that writes the image's own CA bundle followed by
  `ca_bundle_pem`'s content into a single file from a Container App secret before the real
  container starts — a Key Vault reference when `enable_key_vault`, a value otherwise — which is
  why it reaches `ca-api` and `ca-workers` durably: Terraform owns the container template like
  it owns everything else in it, so nothing here needed carving out of `ignore_changes`. The
  write is additive, not a replacement: `ca_bundle_pem` carries only your own internal CA(s),
  typically a kilobyte or two, and the module concatenates it after the image's public roots
  rather than asking you to — every other outbound call (telemetry, licence refresh, ACS email)
  keeps verifying exactly as before. That keeps the input well under Azure's 25 KB Key Vault
  secret limit, which `mode=production`'s required `enable_key_vault` would otherwise make the
  image's own ~230 KB bundle collide with. Null (the default) sets nothing. The application
  change that made this necessary made SMTP STARTTLS verify the relay's certificate rather than
  accept anything — a fail-closed change with no remedy on self-hosted until now (MAS-446).
- `allowed_private_egress_cidrs` — the private ranges the application may make outbound
  connections into, named instead of admitted wholesale. The application's egress guard refuses
  a customer-configured outbound target on a private or reserved address on
  `mode = "production"`, and the one remedy was `allow_private_egress`, which switched the guard
  off entirely: a self-hosted BYO-DB install whose database sits behind a private endpoint — the
  ordinary production arrangement — had to admit loopback and the cloud metadata endpoint
  (`169.254.169.254`) for every webhook, SMTP relay, stream push, local AI endpoint and
  pull-connector DSN at once. The list writes `MASTERLY_ALLOWED_PRIVATE_EGRESS_CIDRS` on
  `ca-api` and `ca-workers`, comma-joined; the application then admits a private address only
  inside a listed range, and refuses loopback, link-local and the unspecified address whatever
  is listed. The plan refuses an entry without a prefix length, an entry covering one of those
  never-admitted ranges, and the list beside the deprecated flag. Empty (the default) sets
  nothing. Reading the variable needs an `api` image that has it: the next `MANIFEST.json`
  image pair is the first to (MAS-655).
- `app-not-ready` — an availability alert for the failure that every other alert in the set
  structurally cannot see: a replica that starts, never passes its readiness probe, and is
  therefore never routed to, while still counting toward the platform's replica metric. Until
  now `<app>-unavailable` read a healthy 1 on exactly that install and `<app>-5xx` saw no
  requests to fail, so the install served nothing with the whole catalogue green — the shape of
  the one outage on record. `ca-api` and `ca-frontend` each log one line per **failing**
  readiness probe (nothing on a passing one), and one log-search rule reads both, split by app
  name; it fires when an app has failed readiness in at least 30 of the last 60 minutes, so a
  cold start — which legitimately fails readiness for minutes at a time — stays under the bar
  while a genuine wedge pages in 30–40 minutes. Severity 0, like the other availability alerts.
  No new input: it arrives with diagnostics, and it is not gated on `min_replicas`, because an
  app scaled to zero runs no probe and so simply says nothing (MAS-318).
- `scripts/diagnostic-bundle.sh` — the diagnostic bundle in one action. Run from your own
  workstation with your `az` login, it writes a directory you read before you send: the apps'
  configuration state (secrets by name, environment values only from an allow-list),
  revisions and replicas, the alert set and its receivers counted, the six published Log
  Analytics queries through `az rest` (no CLI extension), the starter server's shape, and
  `GET /v1/ops/metrics` when given a token. It sends nothing, writes the directory owner-only,
  and refuses a bundle that carries anything shaped like a secret.
  `tests/diagnostic_bundle_test.sh` proves the bundle carries no secret values, credentials,
  addresses or key material, and that record data is **flagged** where it is not guaranteed
  absent: `logs/q6-postgres-logs.json` is the starter Postgres server's own log stream, which
  can echo a failing statement and the values on its `DETAIL:` line, so the script names that
  file on the terminal and in `manifest.json` for line-by-line review rather than claiming it
  carries none. `--selftest` proves the test still fails when the script is broken; CI runs
  both (MAS-343).
- `allow_private_egress` — the install-wide egress override becomes a module input, so the one
  documented remedy for a private outbound target survives an apply. The application refuses a
  customer-configured target that resolves to a private or reserved address on
  `mode = "production"` (an SSRF guard over webhooks, the SMTP relay, stream push endpoints, a
  local AI endpoint, pull-connector DSNs and a BYO-DB Environment's connection string), and
  `MASTERLY_ALLOW_PRIVATE_EGRESS` is what lifts it. The module set no such variable and writes a
  closed environment onto the apps, which it deliberately does not ignore drift in — so an
  operator who set the value with `az containerapp update` had it removed again by the next
  `terraform apply`, at a moment disconnected from anything they did. The input writes it on
  `ca-api` and `ca-workers`, the two apps that make those connections; the frontend reads no such
  setting. Default `false`, which sets **nothing**: an unset variable is how the application is
  told to follow the mode (demo allows, production refuses), so an install that does not set this
  behaves exactly as it did before. It does not affect `external_database_url` or the starter
  server — the install's own database is operator configuration and was never restricted
  (MAS-432). It arrives already deprecated — see *Deprecated* below (MAS-655).
- `license_issuer_url` — the licence refresh endpoint reaches the apps, so an install can
  re-fetch and re-verify its licence daily instead of waiting for the next apply. Optional, and
  it requires the install credential, `telemetry_client_id` / `telemetry_client_secret` — not
  `telemetry_url`, so turning refresh on does not turn usage reporting on (MAS-98, MAS-208).
- Availability alerts, alongside the saturation alerts that were the whole catalogue until now.
  An install that has stopped serving now raises a severity-0 alert — the database reporting
  itself unavailable, an app left with no running replica, or the database's telemetry stopping
  altogether, which is the one a stopped server produces and which no metric alert can see. They
  are distinguishable from a strained install by severity and name, and they arrive with the rest
  of diagnostics: no new input, and no change to the five existing alerts. What they count is
  replicas, not readiness — the app whose replica is running but never passes its probe is
  covered by `app-not-ready`, below (MAS-263).
- `ca-workers` gets the same no-replica availability alert the serving apps carry, on installs
  that run it with a replica floor. It is the failure the rest of the set structurally cannot
  see: the workers app has no ingress, so it emits no requests, and a dead one leaves the
  install answering normally while every ingest run, scan and materialization job behind it
  stalls. Same severity as the other availability alerts, and its description says the pipeline
  stopped rather than that the install is down, because those are different things to be woken
  for. No new input (MAS-305).
- `MANIFEST.json` and the check that keeps it honest — the module now states, once and
  machine-readably, which `api` and `frontend` images each published version was released
  against, so the README, the public docs and a pinned install read that fact instead of
  retyping it and drifting apart. `scripts/check_release_manifest.py` runs on every pull
  request, so the commit that cuts a release is validated before it merges, and again on the
  tag build, where a tag pushed without its manifest and changelog entries goes red at once.
  Release-please stays deliberately out: the module's version is a release decision, not one
  computed from commit messages (MAS-239).
- `python3 scripts/check_release_manifest.py --selftest` — the release check is now itself
  checked. It stages 25 synthetic module trees and asserts both halves of what it claims: a
  well-formed release passes, and every way a release can be wrong is rejected *by name* — the
  manifest missing, unparseable, a JSON array, missing `latest`, missing an image, naming an
  image that is not `registry/repository:tag`, carrying the `api` and `frontend` values swapped,
  claiming a `latest` that is not the highest version present, or speaking a schema this repo
  does not; the changelog missing the released version, dating it differently, or having no
  `Unreleased` heading to write into; the README restating a pin the manifest disagrees with, or
  having lost the pin altogether; and the tag naming a version the manifest does not publish. CI
  runs the selftest before the check, so a detector that has quietly stopped detecting fails
  loudly rather than passing this repo for the wrong reason (MAS-441).
- **Key Vault Crypto Officer** for the apps identity on the install vault, alongside the Secrets
  Officer grant it already held, gated on `enable_key_vault` exactly as that one is. It is what
  lets an application release carrying **erasure of personal data** (ADR 0081) create and use an
  Environment's two erasure keys: a signing key, held as a vault key, which the application asks
  the vault to sign each erasure listing with so it never holds the private half, and a
  suppression key, held as a vault secret, which the Secrets Officer grant already covered.
  The grant is scoped to the install's own vault rather than to those two keys because the keys
  do not exist when Terraform runs — the application creates each one, only if absent, at a name
  derived from an Environment created long after the apply — and an Azure role assignment cannot
  name a key that does not exist yet; Key Vault Crypto **User** cannot create a key, so Crypto
  Officer is the smallest built-in role that fits. No new input, and **no change to what the
  deploying identity must be**: the grant is an ordinary `azurerm_role_assignment` on a vault the
  module already owns, so the `Role Based Access Control Administrator` that
  `scripts/preflight.sh` already accepts remains enough (MAS-790).

  **Upgrading from an earlier version:** bump the module `version` and apply. The plan adds one
  `azurerm_role_assignment` on installs with `enable_key_vault = true` and is a no-op on installs
  without the vault; nothing else moves, and no application restart follows. Two things worth
  doing in the same window:

  - Entra RBAC is eventually consistent, so the new grant takes a few minutes to be usable.
    Nothing in the apply depends on it, so a `Forbidden` on a key operation immediately after the
    apply means propagation, not a mistake.
  - Read [Erasure keys belong in your secret backup](README.md#erasure-keys-belong-in-your-secret-backup)
    before running an erasure, not after. Those keys are not in your Postgres backup, a
    replacement key matches nothing already recorded, and an Environment that has run an erasure
    depends on the vault for ingest, pipeline jobs, consume reads and Stream delivery.

- Network security groups on the two subnets the module creates, each ending in an explicit
  inbound deny. Until now both were created without one, in every topology the module builds,
  and a subnet with no NSG is not closed: it inherits Azure's default rules, which allow
  everything the `VirtualNetwork` service tag covers — this VNet, every network peered to it,
  and every on-premises range reachable through a gateway attached to it. `snet-aca` admits the
  apps' ingress (TCP 80 and 443, from `Internet`, or from `VirtualNetwork` when
  `aca_internal_load_balancer` is set, since an internal environment has no public endpoint to
  reach) plus the two Container Apps platform rules a Consumption-only environment requires;
  `snet-private-endpoints` admits Postgres, Key Vault and the Redis session registry from
  `snet-aca` and nothing else. Outbound is untouched — Container Apps needs a long,
  Microsoft-versioned egress set, and a stale copy of it written here would produce an
  environment that provisions and then cannot start a replica; narrowing egress stays a
  firewall or NVA decision. The rules are a second layer under `ingress_allowed_cidrs`, not a
  replacement for it. **Nothing is created on an injected spoke** (`aca_subnet_id` /
  `private_endpoints_subnet_id`): a subnet holds exactly one NSG, and associating one there
  would replace what your platform team attached, from outside their own configuration —
  [docs/networking.md](docs/networking.md) states the baseline those subnets are expected to
  meet instead. **On a live install this also flips `snet-private-endpoints` from
  `private_endpoint_network_policies = "Disabled"` to `"Enabled"`**, without which an NSG on a
  private-endpoint subnet does not apply to private-endpoint traffic at all and the rules would
  be inert. That is an **in-place** subnet update: it replaces neither subnet and does not
  touch the Container Apps environment. Read the plan for your install before applying —
  network policies now govern route tables on that subnet too, so a user-defined route you
  attached to it begins to apply to private-endpoint traffic (MAS-37).

### Changed

- The Service Bus namespace (`enable_service_bus = true`) now states `minimum_tls_version =
  "1.2"` rather than leaving it to the azurerm provider's default. Every provider version the
  module supports already defaults to 1.2, so a plan is expected to show no change for this
  setting; the floor is now part of the module rather than of the provider. Installs without
  Service Bus are unaffected (MAS-41).
- Licence refresh and fleet telemetry are separate features, and the plan-time guards now say
  so. `telemetry_client_id` / `telemetry_client_secret` are the **install credential** — the
  install service account from your bundle — and both features authenticate with it, but
  neither needs the other's URL: `license_issuer_url` with the credential and no
  `telemetry_url` plans cleanly, and the apps then refresh their licence daily and report
  nothing, because the application reports only when `MASTERLY_TELEMETRY_URL` is set, and the
  module writes that variable only when `telemetry_url` is. Previously the refresh URL was
  refused without `telemetry_url`, so an install could not refresh its licence without also
  reporting usage hourly. The guards are stated per feature: `license_issuer_url` without the
  whole credential is refused, and so is `telemetry_url` without it. Two configurations that
  used to plan are now refused, because each looked configured and did nothing: half of the
  credential on its own (in particular `telemetry_client_secret` without
  `telemetry_client_id`), and the whole credential with neither feature set. An install that
  sets all three telemetry inputs, or none of them, plans exactly as before. The inputs keep
  their names. Licence refresh itself needs an `api` image that has it: the next
  `MANIFEST.json` image pair is the first to (MAS-208).
- `breakglass_secret_hash` says what the api actually accepts. The input has held a **salted
  Argon2id** value since the api change that made it one; this repo still described a sha256
  digest, and `examples/production` still told an operator to produce one with `shasum -a 256`.
  That is not a stale sentence but an instruction that crash-loops the install — an api on that
  release refuses to start on a bare digest, so `ca-api` and `ca-workers` fail on exactly the
  credential configured for the day the IdP is down, and the module is the interface an operator
  reads (a variable description in an editor, `terraform-docs` output) without ever opening the
  docs site. The descriptions now name the stored form and point at the command that mints it
  **inside the api image** — the image that verifies a value is the image that should produce it
  — rather than restating the encoding in a third place that nothing checks against the code. No
  HCL change: the module passes the value through as a Container App secret exactly as before.
  The module version that ships this must be released against an api image that carries the
  Argon2id change; against an older api the description would be wrong in the other direction
  (MAS-451).
- CI cancels a superseded pull-request run rather than paying for a result nobody reads
  (MAS-174), and no longer leaves the job's `GITHUB_TOKEN` in `.git/config` after checkout
  (MAS-171). Dependabot updates are grouped, and the GitHub Actions majors were taken (MAS-126).
- `shellcheck` gates every shell script the module ships — `scripts/diagnostic-bundle.sh`,
  `scripts/preflight.sh` and the bundle's test harness — at its default severity, so an
  unquoted expansion that word-splits fails the build instead of reaching an operator's
  terminal. The six deliberate idioms it would flag are suppressed where they occur, each with
  its reason. No script's behaviour changed (MAS-428).
- A scheduled check fails when the public self-hosted docs pin an older module than the registry
  publishes (MAS-199).
- `MANIFEST.json` must now declare a `schema_version` this repo speaks and a non-empty `module`.
  The manifest is a contract other programs parse, so a change to its shape has to arrive with
  the checker and the contract document or the build refuses it (MAS-441).
- Each version tag now gets a GitHub Release page whose body is that version's section of this
  changelog, published by CI once the tag build's checks pass. The Terraform Registry publishes
  the version independently, so a missing Release page means the checks failed, not that the
  version is unpublished (MAS-258).
- Releases are cut by the `cut-release` workflow, which creates the version tag only after
  checking that the release commit is on `main`, that its CI run there passed, that the tag does
  not exist yet, and that the commit's `MANIFEST.json`, changelog and README publish that version.
  The registry publishes from the tag, so these are the checks that can refuse a release rather
  than report on one after it is public. A tag pushed by hand is not yet refused;
  [docs/releasing.md](docs/releasing.md) records the repository settings that close that and
  whether they are in place (MAS-274).

### Deprecated

- `allow_private_egress` — replaced by `allowed_private_egress_cidrs` above, and kept for one
  release. `true` used to switch the application's egress guard off entirely; it now means the
  allowlist it stood in for — every RFC1918 range, CGNAT (`100.64.0.0/10`) and IPv6 unique-local
  (`fc00::/7`), never loopback or link-local — which is strictly narrower, and the application
  logs a deprecation warning at every start while it is set. Migrate by replacing it with the
  ranges your targets are actually on; setting both inputs fails the plan, and the application
  refuses to start with both variables set. The narrowing reaches connection strings too: under
  the flag a `production` install now refuses a DSN with no host or one that connects over a
  Unix socket, which the full bypass let through, so name the database's host instead. An `api` image older than the next manifest pair
  still reads the flag as the full bypass it was, so the narrowing lands with the image, not
  with this module version (MAS-655).

### Fixed

- `ca-api`'s liveness probe declares its tolerances instead of running on Azure's defaults for
  a declared probe (a 1 s timeout and 3 failures). A failing liveness probe restarts the
  container, so at those defaults one slow `/healthz` answer, or a start that took longer than
  about 30 seconds, restarted a healthy replica, and a systemic slowdown became a restart loop.
  The api's liveness probe now allows 5 + 24 x 20 = 485 seconds of continuous failure (10 s
  timeout), the same budget as its readiness probe. Applying this updates `ca-api` in place and
  rolls it to a new revision once. `ca-frontend` and `ca-workers` are unchanged. The
  `aca-container-app` submodule gains `liveness_probe_initial_delay`,
  `liveness_probe_interval_seconds`, `liveness_probe_timeout` and
  `liveness_probe_failure_count_threshold`; each defaults to null, which keeps Azure's default
  (MAS-205).
- `scripts/preflight.sh` no longer announces a module version in its header. It had said
  `module v0.7.0` since it was written — true for one release, wrong for the eight after it,
  and read at the moment an operator is checking which artifact they hold. A script ships
  inside the module, so the release it belongs to is the release the reader obtained the tree
  from, and that is not something the file can state about itself. Nothing else in the script
  changed. `scripts/check_release_manifest.py` now refuses a module version typed into the
  header of any script this module ships, so the header cannot drift back (MAS-479).
- The module archive an air-gapped install receives no longer carries this repository's own CI
  workflows (`.github/`) or its coding-agent guidance (`CLAUDE.md`). A new `.gitattributes`
  marks them `export-ignore`, so `git archive` leaves them out; `examples/` and `tests/` still
  ship — the example is what an operator copies, and the test harness is the proof the README
  cites for the diagnostic bundle's no-secrets claim. `git archive` reads the file as it was at
  the tag being archived, so this applies from the first release that includes it; archiving
  0.15.0 or any earlier tag still yields the whole tree. Consumers fetching from the Terraform
  Registry or a git source are unaffected either way — they receive the repository, not an
  archive (MAS-603).

### Documentation

- [SECURITY.md](SECURITY.md) — a private route for reporting a flaw in the published module.
  The module provisions a customer's whole install and is consumed at a pinned tag, so a
  publicly-filed flaw is actionable against every install on that version before any of them can
  be told. Private reporting was already enabled on the repository and nothing pointed at it.
  The file names GitHub private vulnerability reporting first and the owner's address as the
  fallback, states response windows that can be held, and says what is in scope — the module,
  its examples and its CI — and what is not (MAS-235).
- The README's Key Vault deployer section says which network path to choose rather than listing
  two as equals: `key_vault_deployer_in_vnet = true` — the apply runs inside the install's VNet
  and the vault's public endpoint stays off — is the recommended production path, and
  `key_vault_deployer_ip_rules`, the apply runner's pinned egress address, is the smaller-scale
  alternative, with its weaker posture stated plainly (MAS-711).
- [docs/release-manifest.md](docs/release-manifest.md) — the manifest's shape written down for
  whoever parses it, rather than left to be inferred from an example: where to fetch it, every
  field with its type and meaning, which fields are stable while `schema_version` is `1`, which
  may be added without warning, and the two things not to assume — that `releases` is complete
  history, and that the image pair says what an install is running now rather than what the
  version was released against (MAS-441).
- Entries for 0.8.0 through 0.14.0, reconstructed from their tag messages (MAS-259).
- `oidc_allowed_issuers` is the install's own issuer, not a per-customer list (MAS-164).
- "Where this module departs from Azure's recommended baseline", under the README's Networking
  section. It names the three places the module does not yet follow Azure's recommended
  configuration: Service Bus with public network access enabled, key and password
  authentication to Redis and the starter Postgres, and geo-redundant backup off on the starter
  Postgres. For each it says why it holds today and what you can do now to follow Azure's
  recommendation: leave `enable_service_bus` off, and turn geo-redundant backup on when the
  server is created if the paired region is inside your residency boundary. Each item names the
  Azure Policy built-in definitions that evaluate it and whether they are in the Microsoft cloud
  security benchmark v1, Defender for Cloud's default standard, or v2, an opt-in preview
  (MAS-41).
- `oidc_redirect_uri` and the README's identity section describe the same first apply as
  `examples/production/`: production posture with `identity_binding = "oidc"` and a placeholder
  redirect URI, then the real one on the second apply. Both used to say to bring the install up
  with `identity_binding = "dev"` and switch to `oidc` afterwards, which makes the second apply
  change identity and the production posture at once, on a running install (MAS-294).

## [0.15.0] - 2026-09-07

### Added

- Per-install Key Vault secret store (ADR 0066): the install's secrets live in the vault, not in
  the apps. Gated behind `enable_key_vault`, which defaults to `false` — inert on an install that
  does not set it (MAS-40).

### Changed

- Third-party actions are pinned by digest, and Dependabot watches them.

## [0.14.0] - 2026-09-07

### Changed

- The published api is HTTPS-only, and the Container Apps environment encrypts app-to-app
  traffic (MAS-39).

## [0.13.0] - 2026-09-07

### Documentation

- The README's pin was moved to 0.13.

## [0.12.0] - 2026-09-04

### Added

- The api can be made reachable, narrowly, so a client outside the install — the Python SDK,
  for one — can talk to it.

## [0.11.0] - 2026-09-01

### Added

- Telemetry wiring to Masterly's control plane.

## [0.10.0] - 2026-09-01

### Added

- Three network topologies served from one module: public ingress, private ingress, and
  hub-and-spoke.

## [0.9.1] - 2026-09-01

### Changed

- CI gates the artifact customers consume.

## [0.9.0] - 2026-09-01

### Added

- The declared data-residency claim is checked against where the resources actually land.

## [0.8.2] - 2026-09-01

### Fixed

- The Azure-assigned Postgres standby availability zone is ignored, so an apply no longer
  fights the platform over it.

## [0.8.1] - 2026-09-01

### Documentation

- Documentation only.

## [0.8.0] - 2026-09-01

### Added

- The first public tag. The Terraform content was unchanged from the internal repository it was
  extracted from, api readiness-probe tolerances included, and `examples/production` was added.

[Unreleased]: https://github.com/masterly-data/terraform-azurerm-masterly/compare/v0.24.0...HEAD
[0.24.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.24.0
[0.23.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.23.0
[0.22.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.22.0
[0.21.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.21.0
[0.20.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.20.0
[0.19.1]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.19.1
[0.19.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.19.0
[0.18.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.18.0
[0.17.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.17.0
[0.16.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.16.0
[0.15.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.15.0
[0.14.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.14.0
[0.13.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.13.0
[0.12.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.12.0
[0.11.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.11.0
[0.10.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.10.0
[0.9.1]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.9.1
[0.9.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.9.0
[0.8.2]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.8.2
[0.8.1]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.8.1
[0.8.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.8.0
