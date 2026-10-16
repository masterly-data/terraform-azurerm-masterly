# Agent guidance for terraform-azurerm-masterly

This repo is the **Terraform module a customer applies to run a self-hosted Masterly install** on
Azure. It is published to the Terraform Registry as `masterly-data/masterly/azurerm` and consumed at
a version constraint; `MANIFEST.json` names the newest published version.

Project-wide context (architectural constraints, repo map, terminology) is loaded from
`../CLAUDE.md`. Don't restate it here. `AGENTS.md` is a symlink to this file. Review criteria are in
`REVIEW.md`; procedures are skills in `.claude/skills/`.

Two facts govern everything below:

1. **This repo is public and Apache-2.0.** Every comment, TODO, variable description and commit
   message is customer-readable, including this file.
2. **The tag is the release.** Pushing a tag publishes to the public registry and a published version
   cannot be withdrawn.

## Commands

Everything CI runs works locally with no cloud access and no secrets. Run all of it (skill
`validate-module-change` has the rationale, the example check and what these cannot prove):

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false && terraform validate
terraform test                                   # mock providers, no cloud access
python3 scripts/check_release_manifest.py --selftest && python3 scripts/check_release_manifest.py
python3 scripts/check_runtime_env.py --selftest && python3 scripts/check_runtime_env.py
python3 scripts/release_notes.py --selftest
python3 scripts/release_gate.py --selftest
bash tests/diagnostic_bundle_test.sh --selftest && bash tests/diagnostic_bundle_test.sh
shellcheck --severity=style $(git ls-files '*.sh')   # any finding fails; never lower the severity
```

CI pins Terraform 1.10.5 (the `required_version = ">= 1.10"` floor). Generated files:

```bash
python3 scripts/check_release_manifest.py --write   # README release table, from MANIFEST.json
python3 scripts/check_runtime_env.py --write        # RUNTIME_ENV.json, from the .tf files
```

A green `terraform validate` and `terraform test` never called Azure. A live `plan` against a real
subscription is a human action; say plainly in the PR when a change is unproven against Azure.

## Layout

The top level is one Terraform root module; `main.tf` is the always-created core and each optional
subsystem has its own file.

| Path | Contents |
|---|---|
| `main.tf` | Core: resource groups, VNet, ACA environment, Log Analytics, `api`/`frontend` apps, identities, starter Postgres, optional Service Bus |
| `diagnostics.tf` | Diagnostic settings, metric alerts, log-search alerts, action group |
| `keyvault.tf`, `redis.tf`, `workers.tf`, `email.tf`, `entra-auth.tf` | Opt-in subsystems (secret store, session registry, workers app, ACS email, Entra auth) |
| `variables.tf`, `outputs.tf`, `versions.tf` | The public surface. Every variable description is customer documentation |
| `modules/` | Six nested submodules the root composes |
| `tests/` | `install.tftest.hcl` (mock-provider runs), `diagnostic_bundle_test.sh` and `fixtures/` |
| `examples/production/` | The example a customer copies; `source = "../../"`, so it validates the working tree |
| `scripts/` | `preflight.sh`, `diagnostic-bundle.sh`, release-metadata checkers. Standard library only |
| `MANIFEST.json`, `RUNTIME_ENV.json` | Release manifest and runtime-environment manifest. Contracts: `docs/release-manifest.md`, `docs/runtime-env.md` |
| `CHANGELOG.md`, `README.md`, `docs/` | Keep a Changelog (new entries under `Unreleased`); module surface reference; `networking.md`, `releasing.md` |

## Conventions

- **Variables and outputs.** Every variable has a `type`, a customer-facing `description`, a safe
  default and a `validation` block for inputs a customer can get wrong. Skill `add-module-variable`.
- **Departures from Azure's baseline are documented in the README** section "Where this module
  departs from Azure's recommended baseline". Skill `document-baseline-departure`.
- **Provider floor.** `.terraform.lock.hcl` is gitignored (a lock inside a module is ignored), so the
  constraint in `versions.tf` alone governs a customer's `init`. The floor is `~> 5.8`, and
  `~> 5.0` in each `modules/*/versions.tf`, which must move with it. Do not lower it, or move to 6.x,
  without a refreshing plan against a live install; a provider major is a breaking module release.
- **Versions derive from `MANIFEST.json`** through the checker. Never transcribe a version.
- **Comments and commits are public.** Write for a customer: no internal shorthand that reads as a
  defect, no speculation about a customer, no unexplained `TODO`. PR titles land on `main`:
  Conventional Commits with the Linear key, e.g.
  `fix: the api ingress guard refuses an empty allowlist (MAS-123)`.
- **Decisions.** ADRs live in `masterly-framework`, never here; cite them by number. A variable
  guard and its test, a new `.tf` split, CI, README wording and a new alert on an existing signal
  stay local. An ADR comes first for a topology change, a data-plane or secret-store model change
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
  `examples/production/license-issuer.jwk.json` and deletes it; `.gitignore` ignores `*.tfvars` with
  no exception, on purpose.
- **Never add a public endpoint or a weaker default** without an owner decision.
- **Never create a second copy of the module**, vendored or temporary, in another repo, and never
  add root-level `.tf` files to `masterly-demo-iac`. Changes to module inputs, `modules/`,
  `tests/install.tftest.hcl` or `scripts/preflight.sh` belong here; changes to what the demo install
  is configured with do not.
- **Never report a security flaw in public.** Use GitHub private vulnerability reporting or the
  address in `SECURITY.md`, never a public issue or a PR title that explains the exploit.
- **Never add a path to `.gitattributes` `export-ignore` casually.** `git archive` builds the
  air-gapped install tarball; `tests/` and `examples/` ship on purpose.

## Definition of done

- The commands above pass, including `shellcheck` and the `--selftest` runs.
- A `run` block in `tests/install.tftest.hcl` covers every new variable guard, conditional resource
  and derived value.
- `README.md` and `examples/production/` are updated for any change to the public surface.
- `CHANGELOG.md` has an entry under `Unreleased`; a breaking variable change carries a migration note.
- Generated files are regenerated, not edited.
- The PR says whether the change was planned against a real subscription.
- A rule with nothing enforcing it is this repo's characteristic defect: when you add a rule, add the
  check and a selftest that proves the check can fail.

## Nothing dogfoods a module change

The demo install (`masterly-demo-iac/deployments/demo-eu/main.tf`) and the production-mode rehearsal
install (`masterly-test-install/main.tf`) pin a registry version, as a customer does, and neither
sees a change made here until someone bumps the pin by hand. Read pins from those files; do not copy
a version into this one. **Plan a live install against the module branch before tagging a release**;
nothing enforces it, so it is yours to do or to hand to a human.

## Workflows and publishing

`.github/workflows/` holds `ci.yml`, `public-docs-module-pin.yml` (a scheduled check that the public
docs pin the current module version) and `cut-release.yml`. None of them publishes the module: the
Terraform Registry watches this repository's tags through its own webhook, outside GitHub Actions.
