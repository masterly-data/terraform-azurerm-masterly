# Agent guidance for terraform-azurerm-masterly

This repo is the **Terraform module a customer applies to run a self-hosted Masterly install** on
Azure. It is published to the Terraform Registry as `masterly-data/masterly/azurerm` and consumed at
a version constraint; `MANIFEST.json` names the newest published version.

Project-wide context (architectural constraints, repo map, terminology) is loaded from
`../CLAUDE.md`. Don't restate it here. `AGENTS.md` is a symlink to this file. Review criteria are in
`REVIEW.md`; procedures are skills in `.claude/skills/`.

Two facts govern everything below:

1. **This repo is public and Apache-2.0** (`LICENSE`; `NOTICE` carries the attribution). The whole
   tree ships to customers and partners. Every comment, TODO, variable description and commit
   message is customer-readable, including this file.
2. **The tag is the release.** Pushing a tag publishes to the public registry and a published version
   cannot be withdrawn. The registry watches tags through its own webhook, and none of the five
   workflows publishes: `ci.yml`, `cut-release.yml`, `public-docs-module-pin.yml` (a scheduled check
   that the public docs pin the current version), `workflow-hardening.yml` (zizmor) and
   `iac-scan.yml` (Trivy over the Terraform, and dependency review on pull requests).

## Commands

Everything CI runs works locally with no cloud access and no secrets, because CI must be safe on a
fork PR; the whole set takes under a minute after `init`. Run all of it (skill
`validate-module-change` has the rationale, the example check and what these cannot prove):

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false && terraform validate
terraform test                                   # mock providers, no cloud access
python3 scripts/check_release_manifest.py --selftest && python3 scripts/check_release_manifest.py
python3 scripts/check_runtime_env.py --selftest && python3 scripts/check_runtime_env.py
python3 scripts/release_notes.py --selftest && python3 scripts/release_gate.py --selftest
bash tests/diagnostic_bundle_test.sh --selftest && bash tests/diagnostic_bundle_test.sh
shellcheck --severity=style $(git ls-files '*.sh')   # any finding fails; never lower the severity
bash scripts/iac_scan.sh --check-selftest && bash scripts/iac_scan.sh --check   # python3 + PyYAML
bash scripts/iac_scan.sh --selftest              # needs trivy; must flag the known-bad fixture
```

CI pins Terraform 1.10.5 (the `required_version = ">= 1.10"` floor). Generated files, never edited:

```bash
python3 scripts/check_release_manifest.py --write   # README release table, from MANIFEST.json
python3 scripts/check_runtime_env.py --write        # RUNTIME_ENV.json, from the .tf files
```

## Layout

One Terraform root module: `main.tf` is the always-created core; each optional subsystem has a file.

| Path | Contents |
|---|---|
| `main.tf` | The core: two resource groups, the VNet and its two subnets, the ACA environment and the Log Analytics workspace, the `api` and `frontend` Container Apps, both user-assigned identities, the starter Postgres flexible server with its private DNS zone and endpoint, and the optional Service Bus namespace and queue |
| `diagnostics.tf` | The observability surface: one action group, the diagnostic settings (five data-plane, one per Container App), twelve metric alerts and four log-search alert rules (one of them per Container App) |
| `keyvault.tf` | The opt-in durable secret store (ADR 0066): vault, private endpoint and DNS, RBAC grants, and the install's own secrets as Key Vault references |
| `redis.tf` | The opt-in session registry (ADR 0071): both offerings (`managed` / `cache`), each private-endpoint only |
| `workers.tf`, `email.tf`, `entra-auth.tf` | The opt-in `ca-workers` app, customer-owned ACS email, and how the apps authenticate to the install's own Postgres and Redis (Entra token, or password and access key) |
| `variables.tf`, `outputs.tf`, `versions.tf` | The public surface. Every variable description is customer documentation |
| `modules/` | Eight nested submodules the root composes: `aca-container-app`, `aca-env-consumption`, `acs-email`, `license-claims-floor` (the plan-time licence claims-floor check; no resources), `log-analytics-workspace`, `postgres-connection-urls` (the starter server's pooler and direct URLs; no resources), `release-channel` (the plan-time choice of the default images from `MANIFEST.json`; no resources), `user-assigned-identity` |
| `tests/` | `install.tftest.hcl` (the mock-provider run blocks), and `diagnostic_bundle_test.sh` with its `fixtures/`: the harness that proves the diagnostic bundle carries no secrets |
| `examples/production/` | The production-posture example a customer copies; `source = "../../"`, so it validates the working tree |
| `scripts/` | `preflight.sh` (pre-apply subscription check), `diagnostic-bundle.sh` (the operator's support bundle), `check_release_manifest.py` and `check_docs_module_pin.py` (the release and docs gates), `check_runtime_env.py` (generates and checks `RUNTIME_ENV.json`, and that the bundle's env allowlist names only what the module sets), `release_notes.py` (a version's changelog section, as its GitHub Release body), `release_gate.py` (the check `cut-release.yml` runs before it creates a tag). Standard library only: release metadata should not depend on anything resolving. Also `iac_scan.sh`, the `iac-scan` job's Trivy scan and its check that every `.trivyignore.yaml` suppression names a rule ID and a README departure (and that no `.tf` file carries an inline `trivy:ignore`/`tfsec:ignore`, which would bypass it); CI only, so it is `export-ignore`d with its inputs |
| `MANIFEST.json` | The release manifest: which image pair each published module version was released against. Fields: `schema_version` (`1` today), `module`, `latest`, and `releases` keyed by bare semver, each with a `date` and an `images` object naming `api` and `frontend`. Its published contract is `docs/release-manifest.md`: which fields are stable, which may be added without a `schema_version` bump, and what will never change silently. A change to its shape changes what other repositories and the public docs parse |
| `RUNTIME_ENV.json` | Every env name the module sets, per app. Generated, never edited; contract `docs/runtime-env.md`. The application repositories vendor it and check their code and runbooks against it (MAS-545) |
| `CHANGELOG.md` | Keep a Changelog. New entries go under `Unreleased`; cutting a release renames that heading |
| `README.md` | The module surface reference. The customer walkthrough lives in the public docs, not here |
| `docs/` | `networking.md` (the three topologies), `release-manifest.md`, `runtime-env.md`, and `releasing.md` (what gates a tag, and the repository settings that make `cut-release` the only path) |
| `SECURITY.md` | The vulnerability-reporting policy we publish; hold to our half of it |

## Conventions

- **Variables and outputs.** Every variable has a `type` and a customer-facing `description`; an
  optional input has a safe default, a required input has none, and an input a customer can get
  wrong has a `validation` block. Every output has a customer-facing `description`, and an output
  that carries a secret is `sensitive = true`. Skill `add-module-variable`.
- **Departures from Azure's baseline are documented in the README** section "Where this module
  departs from Azure's recommended baseline"; a scan finding is suppressed only in
  `.trivyignore.yaml`, naming that departure. Skill `document-baseline-departure`.
- **Provider floor.** `.terraform.lock.hcl` is gitignored: Terraform reads the lock file of the root
  configuration only, so the constraint in `versions.tf` alone governs a customer's `init`. The
  floor is `~> 5.8` (`versions.tf` gives the reasoning: 5.8.0 is what a refreshing plan against a
  live install resolved, replacing nothing), and `~> 5.0` in each `modules/*/versions.tf`, which
  must move with it: a nested constraint that excludes a major keeps it out of every configuration
  using the module. Do not lower it, or move to 6.x, without such a plan; a provider major is a
  breaking module release.
- **Versions derive from `MANIFEST.json`** through the checker. Never transcribe a version: a
  hand-typed pin is the most frequent defect in this repository's history.
- **Comments and commits are public.** Write for a customer: no internal shorthand that reads as a
  defect, no speculation about a customer, no unexplained `TODO` that reads as a known-broken edge.
  `versions.tf` is the calibration: it explains at length why the provider floor is where it is,
  because a customer resolving a provider needs that reasoning. PRs are squash-merged, so the PR
  title is what lands on `main` and what a customer greps: Conventional Commits with the Linear key,
  e.g. `fix: the api ingress guard refuses an empty allowlist (MAS-123)`.
- **Decisions.** ADRs live in `masterly-framework`, never here; cite them by number, which is fine
  because ADR numbers are already public. A variable guard and its test, a new `.tf` split, CI,
  README wording and a new alert on an existing signal stay local. An ADR comes first for a topology change, a data-plane or secret-store model change
  (ADR 0065 / 0066), a new network topology, a change in what the licence or telemetry inputs mean,
  or a public input surface change a customer must react to.

## Don't

- **Never push a tag or dispatch `cut-release`.** Surface the version and commit SHA instead. Skill
  `cut-module-release`; `docs/releasing.md` says which repository settings are applied.
- **Never treat a green PR as release-readiness**, and never bump `MANIFEST.json` outside a release
  commit. The manifest, changelog and README move in one commit on `main`, before the tag.
- **Never hand-edit generated files** (README release table, `RUNTIME_ENV.json`).
- **Never claim application behaviour a released image tag lacks.** Skill `check-app-behaviour-claim`.
- **Never commit credentials or key material, not even fake ones.** CI writes a throwaway
  `examples/production/license-issuer.jwk.json` and deletes it, because a fake key in a public repo
  next to a real one is a worse trap than the one it closes. `.gitignore` ignores `*.tfvars` with no
  exception, on purpose: customers copy it into their install repo, where a tfvars holds a licence
  JWT and an OIDC client secret.
- **Never add a public endpoint or a weaker default** without an owner decision.
- **Never create a second copy of the module**, vendored or temporary, in another repo, and never
  add root-level `.tf` files to `masterly-demo-iac` (one root configuration, `deployments/demo-eu`,
  plus the workflows that operate it). The two repos look similar (both Terraform, both name `ca-api`
  and `rg-masterly-*`): changes to module inputs, `modules/`, `tests/install.tftest.hcl` or
  `scripts/preflight.sh` belong here; changes to what the demo install is configured with do not.
  `REVIEW.md` records what the last duplicate cost.
- **Never report a security flaw in public.** Use GitHub private vulnerability reporting or the
  address in `SECURITY.md`, never a public issue or a PR title that explains the exploit before a
  fixed version exists. A flaw in a published version affects every install pinned to it.
- **Never add a path to `.gitattributes` `export-ignore` casually.** `git archive` builds the
  air-gapped install tarball; `tests/` and `examples/` ship on purpose, and the file says why. It is
  read as of the archived tag: tags up to and including v0.15.0 predate it and archive the whole tree.

## Definition of done

- The commands above pass, including `shellcheck` and the `--selftest` runs.
- A `run` block in `tests/install.tftest.hcl` covers every new variable guard, conditional resource
  and derived value.
- `README.md` and `examples/production/` are updated for any change to the public surface.
- `CHANGELOG.md` has an entry under `Unreleased`; a breaking variable change carries a migration note.
- The PR says whether the change was planned against a real subscription.
- A rule with nothing enforcing it is this repo's characteristic defect: when you add a rule, add the
  check and a selftest that proves the check can fail.

## Nothing dogfoods a module change

Until the module was published (2026-08-31) the demo install consumed it by local path. Now the demo
install (`masterly-demo-iac/deployments/demo-eu/main.tf:35`) and the production-mode rehearsal
install (`masterly-test-install/main.tf:31`) pin a registry version, as a customer does; neither
tracks a branch or sees a change made here until someone bumps the pin by hand. Read pins from those
files; do not copy a version into this one. The project-wide file states the next rule only as a
parenthetical; it is a rule: **plan a live install against the module branch before tagging a
release.** Nothing enforces it, and a live plan needs a real subscription and credential, so it is a
human action, not an agent one. An agent's part is to say in the PR that the change is unproven
against Azure and what a plan would have to cover.
