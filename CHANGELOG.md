# Changelog

Notable changes to the `masterly-data/masterly/azurerm` Terraform module.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org/). Every published version here also has an entry in
[`MANIFEST.json`](MANIFEST.json), which names the `api` / `frontend` image pair that version was
released against — `scripts/check_release_manifest.py` fails the build if the two disagree.

Write new entries under **Unreleased**. Cutting a release renames that heading to the version and
adds the matching `MANIFEST.json` entry, in the same commit; see "Cutting a release" in the
[README](README.md#cutting-a-release). Releases before 0.15.0 predate this file — see the git tags.

## [Unreleased]

### Added

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

### Changed

- CI cancels a superseded pull-request run rather than paying for a result nobody reads
  (MAS-174), and no longer leaves the job's `GITHUB_TOKEN` in `.git/config` after checkout
  (MAS-171). Dependabot updates are grouped, and the GitHub Actions majors were taken (MAS-126).
- A scheduled check fails when the public self-hosted docs pin an older module than the registry
  publishes (MAS-199).

### Documentation

- `oidc_allowed_issuers` is the install's own issuer, not a per-customer list (MAS-164).

## [0.15.0] - 2026-09-07

### Added

- Per-install Key Vault secret store (ADR 0066): the install's secrets live in the vault, not in
  the apps. Gated behind `enable_key_vault`, which defaults to `false` — inert on an install that
  does not set it (MAS-40).

### Changed

- Third-party actions are pinned by digest, and Dependabot watches them.

[Unreleased]: https://github.com/masterly-data/terraform-azurerm-masterly/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/masterly-data/terraform-azurerm-masterly/releases/tag/v0.15.0
