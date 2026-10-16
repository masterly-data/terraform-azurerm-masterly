# Review guidance for terraform-azurerm-masterly

This repository is public; review wording as customer-visible text.

## What blocks

- An acceptance criterion of the card or issue that the change does not meet.
- A breaking change to a variable (renamed, removed, retyped or tightened) without a migration note
  in the `CHANGELOG.md` entry.
- A new public endpoint, or a default weaker than the one it replaces.
- A departure from Azure's recommended baseline that the README section "Where this module departs
  from Azure's recommended baseline" does not document, including a `.trivyignore.yaml` entry whose
  statement names no such departure, or an inline `trivy:ignore` / `tfsec:ignore` comment.
- A new variable guard, conditional resource or derived value with no `run` block in
  `tests/install.tftest.hcl`.
- A claim about application behaviour that is not in a released image tag.
- A hand-edited generated file (`RUNTIME_ENV.json`, the README release table), a transcribed
  version, or a `MANIFEST.json` bump outside a release commit.
- Credentials or key material, including placeholders.

## What does not block

- Formatting: `terraform fmt` is run by CI; do not hold a review for it.

## Known traps

- `terraform validate` and `terraform test` (mock providers) never call Azure; a green CI does not
  prove Azure accepts the change. The PR should say so.
- A change to the derived subnet layout can replace live subnets; only a plan shows it.
- A `v*` tag publishes irreversibly; agents never tag or dispatch `cut-release`.
- Nested `modules/*/versions.tf` provider constraints must move with the root floor.
- A second copy of the module stays green while it drifts. Until MAS-42 deleted it on 2026-09-07, a
  copy at `masterly-demo-iac`'s root lacked network injection, the internal load balancer, the
  residency preconditions, the telemetry inputs and the external-api ingress guard, and CI kept
  validating it the whole time.
- A module change can describe application behaviour that is merged on an app's `main` but in no
  released image tag; it plans and applies cleanly and then does nothing (skill
  `check-app-behaviour-claim`).
