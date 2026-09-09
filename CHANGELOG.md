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

- `license_issuer_url` — the licence refresh endpoint reaches the apps, so an install can
  re-fetch and re-verify its licence daily instead of waiting for the next apply. Optional, and
  it requires the three telemetry inputs (MAS-98).
- Availability alerts, alongside the saturation alerts that were the whole catalogue until now.
  An install that has stopped serving now raises a severity-0 alert — the database reporting
  itself unavailable, an app left with no running replica, or the database's telemetry stopping
  altogether, which is the one a stopped server produces and which no metric alert can see. They
  are distinguishable from a strained install by severity and name, and they arrive with the rest
  of diagnostics: no new input, and no change to the five existing alerts. One failure mode they
  do **not** cover is written down rather than implied: an app whose replica is running but never
  passes its readiness probe still counts toward `Replicas`, so it reads as available — see "What
  the alerts detect, and what they do not" in the [README](README.md) for what covers it
  (MAS-263).

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
