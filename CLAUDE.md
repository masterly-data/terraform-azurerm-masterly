# Agent guidance for terraform-azurerm-masterly

This repo is the **Terraform module a customer applies to run a self-hosted Masterly install** on
Azure. It is published to the Terraform Registry as `masterly-data/masterly/azurerm` and consumed at
a version constraint — `MANIFEST.json` names the newest published version.

Project-wide context (architectural constraints, repo map, terminology) is loaded from
`../CLAUDE.md` — auto-loaded alongside this file. Don't restate it here.

Two facts govern everything below, and neither is obvious from reading the code:

1. **This repo is public.** Every comment, TODO, variable description and commit message is
   customer-readable — including this file.
2. **The tag is the release.** There is no release workflow. Pushing a tag publishes to the public
   registry, and a published version cannot be withdrawn.

## This repo is public and Apache-2.0

`LICENSE` is Apache 2.0, `NOTICE` carries the attribution, and the whole tree ships to customers
and partners from GitHub. The install bundle's module tarball is built with `git archive`, which
drops what `.gitattributes` marks `export-ignore` — `.github/` and this file — so everything else
reaches an air-gapped customer too. `git archive` reads that file as of the archived tag; tags up to
and including v0.15.0 predate it and archive the whole tree. Decide deliberately before adding a
path to it: `tests/` and `examples/` ship on purpose, and `.gitattributes` says why.

- **Write every comment for a customer.** No internal shorthand that reads as a defect ("this is a
  mess", "hack until we fix X"), no speculation about a customer, no unexplained `TODO` that reads
  as a known-broken edge in the thing they are about to apply to production. The existing comments
  are the calibration: `versions.tf` explains *why* the provider floor is where it is, at length,
  because a customer resolving a provider needs that reasoning.
- **Commit messages and PR titles are public too.** Squash-merge means the PR title is the string
  that lands on `main`, so it is the one a customer greps. Conventional Commits with the Linear key,
  same as everywhere else: `fix: the api ingress guard refuses an empty allowlist (MAS-123)`.
- **A security flaw is reported privately.** `SECURITY.md` is the contract we publish; hold to our
  half of it. A flaw in a published version affects every install pinned to it, so it goes through
  GitHub private vulnerability reporting or the security address — never a public issue, and never
  a PR whose title explains the exploit before a fixed version exists.
- **No credentials, no key material, not even fake ones.** CI writes a throwaway
  `examples/production/license-issuer.jwk.json` and deletes it in the same step, deliberately
  rather than committing a placeholder — a fake key sitting in a public repo next to a real one is
  a worse trap than the one it closes. `.gitignore` ignores `*.tfvars` with **no** un-ignore
  exception, on purpose: customers copy that file into their own install repo, where a tfvars holds
  a licence JWT and an OIDC client secret.

## The tag IS the release

`.github/workflows/` holds exactly two files: `ci.yml` and `public-docs-module-pin.yml`. Neither
publishes anything, because nothing here does. The Terraform Registry watches this repo's tags
through its own webhook, entirely outside GitHub Actions.

So the sequence on a tag push is: **tag pushed → registry publishes the version → CI turns red, if
it is going to.** `ci.yml` does run on `v*` tags and does assert that the tag is the version
`MANIFEST.json` publishes — but that is a notification, not a refusal. A published registry version
is not retractable, only superseded. This is Linear card MAS-274, open and undecided; do not write
anything that implies a gate exists.

What that forbids:

- **Never push a tag.** Tagging is a release decision and a human action. An agent's job ends at a
  merged release commit; surface the `git tag` command, do not run it.
- **Never treat a green PR as release-readiness.** The realistic failure MAS-274 names is a tag
  pushed at the wrong commit, or before the release commit merged. Both look fine locally.
- **Never bump `MANIFEST.json` "to be ready for the release".** The manifest, the changelog and the
  README move in **one commit, on `main`, before the tag**, in the order `README.md`
  ("Cutting a release") sets out. A manifest that names an unreleased version is a manifest that
  lies to every consumer parsing it, and `scripts/check_release_manifest.py` will fail the PR.
- **Never claim application behaviour a released image does not have.** See "The contract with the
  application images" below — this is the failure mode that has actually happened.

Release-please is deliberately not used here: the module's version is a release decision, not one
computed from commit messages.

## This is the only copy of the module

A stale copy of the module lived at `masterly-demo-iac`'s repository root until 2026-09-07, when
MAS-42 deleted it so that there would be exactly one. It is worth knowing what the duplicate cost
while it existed: the copy was missing network injection, the internal load balancer, the residency
preconditions, the telemetry inputs and the external-api ingress guard — and CI kept validating it,
green, the whole time.

So: **the module lives here and nowhere else.**

- Do not create a second copy, a vendored copy, or a "temporary" fork of these `.tf` files in
  another repo, whatever the convenience argument.
- Do not add root-level `.tf` files to `masterly-demo-iac`. That repo is one root configuration
  (`deployments/demo-eu`) plus the workflows that operate it, and its own `CLAUDE.md` says so.
- The two repos still look similar — both are Terraform, both talk about `ca-api` and
  `rg-masterly-*`. If you were sent to change *module inputs, `modules/`, `tests/install.tftest.hcl`
  or `scripts/preflight.sh`*, you are in the right repo. If you were sent to change *what the demo
  install is configured with*, you are not.

## Nothing dogfoods a module change any more

Until the module was published (2026-08-31) the demo install consumed it by local path, so every
module change was planned against a live install for free. That stopped. Both real consumers now
pin a registry version, exactly as a customer does:

| Consumer | Where its pin lives |
|---|---|
| Masterly's demo install | `masterly-demo-iac/deployments/demo-eu/main.tf:35` |
| The production-mode rehearsal install | `masterly-test-install/main.tf:31` |

Read each pin from the file it lives in; this table deliberately does not name a version, for the
reason the working style below gives. What is durable is that neither consumer tracks a branch, and
neither will ever see a change made here until someone bumps a pin by hand.

The consequence is the rule the project-wide file states as a parenthetical, restated here as the
rule it is: **plan a live install against the module branch before tagging a module release.** It is
a rule with nothing enforcing it. `terraform test` runs against mock providers and never calls
Azure, so the entire class of "Azure refuses this" is invisible to CI.

A live plan needs a real subscription and a real credential, so it is a human action, not an agent
one (see the project-wide working style). An agent's part is to say plainly, in the PR, that the
change is unproven against Azure and what a plan would have to cover.

## How to validate a change

Everything CI runs is runnable locally with no cloud access and no secrets — that is the point of a
public repo whose CI must be safe on a fork PR. Run all of it; the whole set takes well under a
minute after `init`.

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false && terraform validate
terraform test                                   # mock providers, no cloud access, seconds
python3 scripts/check_release_manifest.py --selftest
python3 scripts/check_release_manifest.py
bash tests/diagnostic_bundle_test.sh --selftest
bash tests/diagnostic_bundle_test.sh
```

CI pins Terraform 1.10.5, at the module's `required_version = ">= 1.10"` floor; a newer local CLI is
fine for these checks. The two `--selftest` invocations run **first** in CI on purpose: a checker
nobody has watched reject anything is a hypothesis, and this repo's characteristic defect is a rule
with nothing enforcing it.

To validate the example a customer copies, do what CI does — it reads a licence JWK from a file a
bare checkout does not have, so write a throwaway and remove it:

```bash
printf '{"kty":"EC","crv":"P-256","x":"AAAA","y":"AAAA","kid":"ci-placeholder"}' \
  > examples/production/license-issuer.jwk.json
terraform -chdir=examples/production init -backend=false -input=false
terraform -chdir=examples/production validate
rm -f examples/production/license-issuer.jwk.json
```

`examples/production` sets `source = "../../"`, so this validates the working tree, not a published
version. Do not commit the JWK file.

Add a `run` block to `tests/install.tftest.hcl` for any new variable guard, conditional resource, or
derived value. The existing runs cover the variable guards, the residency preconditions, both
data-plane branches and the optional subsystems — a new `count`/`for_each` condition with no run
block is a branch nothing exercises.

### What `terraform validate` will NOT catch

This is the part most likely to be got wrong, so it is worth being exact:

- **`terraform validate` does not run a provider's own argument validation.** It checks syntax,
  references and schema shape and stops there; provider *configuration* only happens on `plan`.
  Proven on `masterly-platform-iac` (MAS-74): a deliberately malformed API token was rejected by the
  provider at plan time and returned "Success! The configuration is valid." from `validate`. This
  module declares no `provider` block at all — correct for a module, the root configuration owns it
  — which means provider arguments are something this repo's CI structurally cannot exercise.
- **`terraform test` here uses `mock_provider`.** No Azure call is made, so nothing that only Azure
  can answer is tested: quota, SKU availability in a region, global name uniqueness, RBAC on the
  deploying principal, resource-provider registration, or an API rejecting a field combination the
  schema permits. A green `terraform test` proves the module's *own* logic — guards, branches,
  derived values — and nothing about whether Azure will accept the result.
- **Neither sees an in-place-vs-replace decision.** `tests/install.tftest.hcl` pins the derived
  subnet layout for exactly this reason: a change there would *replace* live installs' subnets, and
  only a plan against real state shows that.

What actually proves a change sound is a `plan` from a root configuration against a real
subscription. `scripts/preflight.sh` answers the prerequisite half of that question (resource
providers, the deploying identity's roles, SKU availability) and is read-only unless you pass
`--register`.

## Repo layout

The top level is one Terraform root module. `main.tf` holds the always-created core; each optional
or self-contained subsystem has its own file, so a change to one is a diff in one place.

| Path | What is in it |
|---|---|
| `main.tf` | The core: two resource groups, the VNet and its two subnets, the ACA environment and the Log Analytics workspace, the `api` and `frontend` Container Apps, both user-assigned identities, the starter Postgres flexible server with its private DNS zone and endpoint, and the optional Service Bus namespace + queue |
| `diagnostics.tf` | The observability surface: one action group, five diagnostic settings, seven metric alerts and two log-search alert rules |
| `keyvault.tf` | The opt-in durable secret store (ADR 0066) — vault, private endpoint and DNS, RBAC grants, and the install's own secrets as Key Vault references |
| `redis.tf` | The opt-in session registry (ADR 0071) — both offerings (`managed` / `cache`), each private-endpoint only |
| `workers.tf`, `email.tf` | The two smallest opt-ins: the `ca-workers` app, and customer-owned ACS email |
| `variables.tf`, `outputs.tf`, `versions.tf` | The module's public surface. Every variable description is customer documentation |
| `modules/` | Five nested submodules the root composes: `aca-container-app`, `aca-env-consumption`, `acs-email`, `log-analytics-workspace`, `user-assigned-identity` |
| `tests/` | `install.tftest.hcl` (the mock-provider run blocks) and `diagnostic_bundle_test.sh` with its `fixtures/` — the harness that proves the diagnostic bundle carries no secrets |
| `examples/production/` | The production-posture example a customer copies. It consumes the module by relative path, so it validates the working tree |
| `scripts/` | `preflight.sh` (pre-apply subscription check), `diagnostic-bundle.sh` (the operator's support bundle), `check_release_manifest.py` and `check_docs_module_pin.py` (the two release/docs gates). Standard library only — release metadata should not depend on anything resolving |
| `MANIFEST.json` | The release manifest. See below |
| `CHANGELOG.md` | Keep a Changelog format. Write new entries under `Unreleased`; cutting a release renames that heading |
| `README.md` | The module surface reference. The customer walkthrough lives in the public docs, not here |
| `docs/` | `networking.md` (the three topologies) and `release-manifest.md` (the manifest's published contract) |
| `SECURITY.md` | The vulnerability-reporting policy we publish |

The README's release table is **generated** from `MANIFEST.json` by
`python3 scripts/check_release_manifest.py --write`. Never hand-edit it.

## The contract with the application images

The module and the application images version apart, and that is deliberate. Self-hosted ships three
independently versioned artifacts: `masterly-application-backend`, `masterly-application-frontend`,
and this module. The owner decision of 2026-09-09 (recorded as an amendment to ADR 0062) is that
**the module version is the one customer-facing version** — "I am on Masterly 0.15.0" means module
0.15.0 — with the other two staying pipeline-computed build identities.

`MANIFEST.json` is what makes that honest. It is the single machine-readable statement of which
image pair each published module version was released against:

- `schema_version` (`1` today), `module`, `latest`, and `releases` keyed by bare semver; each
  release carries a `date` and an `images` object naming `api` and `frontend`.
- `docs/release-manifest.md` is its **published contract** — which fields are stable, which may be
  added without a `schema_version` bump, what will never change silently. Consumers parse that
  shape. If you change the manifest's structure, you are changing a contract other repos and the
  public docs read.
- The image pair means "what Masterly's own reference install had applied when this version was
  tagged". It is **not** a claim about what any install runs now: the module seeds a newly created
  app and then ignores image drift, so CD owns the running tag thereafter.
- `releases` is not complete history — versions before 0.15.0 have no entry, because the pair was
  never recorded at the time and inventing one now would be exactly the retyped-value failure the
  manifest exists to end.

**The trap this creates, which has caught a release already:** a module change can describe
application behaviour that exists only on the apps' `main` and in no released image tag. A 0.16.0
preparation carried an alert searching logs for a line no published image writes, and a variable
description telling operators to mint a credential with a module that does not exist in the released
`api`. Both would plan clean, apply clean, and silently do nothing — or worse, arm a credential that
can never authenticate.

So before a change here asserts anything about how the apps behave, check the behaviour is in a
released **image tag**, not merely merged:

```bash
git tag --contains <commit>   # run in the app repo; empty output = in NO tag
```

Empty output means unreleased, however green the PR was. Check the alert's actual search string, or
the doc string's actual command, against the released tag's tree (`git show <tag>:<path>`), not
against `main`.

## Provider floor and the missing lock file

`.terraform.lock.hcl` is gitignored and this repo ships none, correctly: Terraform consults the lock
file in the **root configuration's** working directory only, and a lock inside a module is ignored.

That makes `versions.tf`'s constraint load-bearing rather than housekeeping — with no lock here, the
constraint is the only thing governing a customer's `terraform init`. The floor is `~> 4.61`, and
`versions.tf` carries the full reasoning: `azurerm_managed_redis` does not exist below 4.50.0 and
its `public_network_access` below 4.53.0, so an earlier provider cannot express the production Redis
path at all. Do not lower it, do not widen it to `~> 4.0`, and do not move to 5.x — that is outside
the module's tested surface and changes the resource-provider registration default.

## Where decisions live

ADRs and architecture docs live in `masterly-framework`, never here. This repo cites them by number
in comments and in the README, which is fine — ADR numbers are already public.

Stays local (no ADR): adding a variable guard and its test run, splitting a concern into its own
`.tf`, adjusting CI, README wording, a new alert on an existing signal.

Warrants an ADR in `masterly-framework` first: changing the deployment topology the module
provisions, changing the data-plane or secret-store model (ADR 0065 / 0066), adding a network
topology, changing what the licence or telemetry inputs mean, or anything that changes the shape of
the module's public input surface in a way a customer would have to react to.

## Working style

- **Public by default.** Write every line for a customer, because one will read it.
- **Never push a tag.** The tag is the publish, and the publish is irreversible.
- **One module, here.** No second copy, anywhere, for any reason.
- **A green CI is not a proven change.** Mock providers do not call Azure; say so in the PR when a
  change has not been planned against a real subscription.
- **Do not transcribe a version.** Every version in this repo derives from `MANIFEST.json` through
  the checker. A hand-typed pin is the failure this repo has had five cards about.
- **A rule with nothing enforcing it is this repo's characteristic defect.** When you add one, add
  the check — and a selftest that proves the check can fail.
