# Changelog

Notable changes to the `masterly-data/masterly/azurerm` Terraform module.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org/). Every version published since 0.15.0 also has an entry in
[`MANIFEST.json`](MANIFEST.json), which names the `api` / `frontend` image pair that version was
released against — `scripts/check_release_manifest.py` fails the build if the two disagree. The
shape a program can rely on when it parses that manifest is
[docs/release-manifest.md](docs/release-manifest.md).

Write new entries under **Unreleased**. Cutting a release renames that heading to the version and
adds the matching `MANIFEST.json` entry, in the same commit; see "Cutting a release" in the
[README](README.md#cutting-a-release).

Releases before 0.15.0 predate this file. Their entries below were reconstructed after the fact
from the git tag messages and the pull-request titles those tags carry, so they say what each
release was *for* rather than giving a line-by-line account of what it contained — read the tag
and the commits between it and its predecessor if you need that. They also have no
`MANIFEST.json` entry: the image pair each was tested against was never recorded at the time, and
inventing one now would be exactly the retyped-value failure the manifest exists to end.

## [Unreleased]

### Added

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
  it requires the three telemetry inputs (MAS-98).
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
- A scheduled check fails when the public self-hosted docs pin an older module than the registry
  publishes (MAS-199).
- `MANIFEST.json` must now declare a `schema_version` this repo speaks and a non-empty `module`.
  The manifest is a contract other programs parse, so a change to its shape has to arrive with
  the checker and the contract document or the build refuses it (MAS-441).
- Each version tag now gets a GitHub Release page whose body is that version's section of this
  changelog, published by CI once the tag build's checks pass. The Terraform Registry publishes
  the version independently, so a missing Release page means the checks failed, not that the
  version is unpublished (MAS-258).

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

- [docs/release-manifest.md](docs/release-manifest.md) — the manifest's shape written down for
  whoever parses it, rather than left to be inferred from an example: where to fetch it, every
  field with its type and meaning, which fields are stable while `schema_version` is `1`, which
  may be added without warning, and the two things not to assume — that `releases` is complete
  history, and that the image pair says what an install is running now rather than what the
  version was released against (MAS-441).
- Entries for 0.8.0 through 0.14.0, reconstructed from their tag messages (MAS-259).
- `oidc_allowed_issuers` is the install's own issuer, not a per-customer list (MAS-164).

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

[Unreleased]: https://github.com/masterly-data/terraform-azurerm-masterly/compare/v0.15.0...HEAD
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
