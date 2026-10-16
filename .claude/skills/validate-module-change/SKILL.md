---
name: validate-module-change
description: Run every check CI runs, locally, and state what they cannot prove. Use before finishing any change to .tf files, tests, scripts or release metadata.
---

# Validate a change

Everything CI runs works locally with no cloud access and no secrets. Run all of it:

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false && terraform validate
terraform test                                   # mock providers
python3 scripts/check_release_manifest.py --selftest
python3 scripts/check_release_manifest.py
python3 scripts/check_runtime_env.py --selftest
python3 scripts/check_runtime_env.py
python3 scripts/release_notes.py --selftest
python3 scripts/release_gate.py --selftest
bash tests/diagnostic_bundle_test.sh --selftest
bash tests/diagnostic_bundle_test.sh
shellcheck --severity=style $(git ls-files '*.sh')
bash scripts/iac_scan.sh --check-selftest        # needs python3 with PyYAML; the suppression check rejects each kind of bad entry
bash scripts/iac_scan.sh --check                 # needs python3 with PyYAML; every suppression names a rule ID and a README departure; no inline ignore comments
bash scripts/iac_scan.sh --selftest              # needs trivy; the scanner must flag the known-bad fixture
```

- Shellcheck runs at `style` severity and any finding fails. A laxer line lets SC2086 (an unquoted
  expansion that word-splits a path) through. Fix the finding, or scope a
  `# shellcheck disable=SCxxxx` to the command or function with the reason on the line above. Never
  lower the severity (MAS-428).
- CI pins Terraform 1.10.5, the `required_version = ">= 1.10"` floor; a newer local CLI is fine.
- `--selftest` runs first on purpose: a checker nobody has watched reject anything is a hypothesis.
- A Trivy finding is answered by fixing it, or by an entry in `.trivyignore.yaml` that names the rule
  ID, the file and the README departure (skill `document-baseline-departure`). Never an inline
  `trivy:ignore` / `tfsec:ignore` comment; `--check` rejects those.

## Validating the example a customer copies

CI reads a licence JWK a bare checkout does not have. Write a throwaway and remove it; never commit it:

```bash
printf '{"kty":"EC","crv":"P-256","x":"AAAA","y":"AAAA","kid":"ci-placeholder"}' \
  > examples/production/license-issuer.jwk.json
terraform -chdir=examples/production init -backend=false -input=false
terraform -chdir=examples/production validate
rm -f examples/production/license-issuer.jwk.json
```

`examples/production` uses `source = "../../"`, so this validates the working tree.

## What these checks cannot catch

- `terraform validate` does not run a provider's argument validation (MAS-74: a malformed token passed
  `validate` and failed at `plan`). The module declares no `provider` block, so provider arguments are
  outside what CI can exercise.
- `terraform test` uses `mock_provider`. Quota, SKU availability, global name uniqueness, RBAC of the
  deploying principal, resource-provider registration and API rejection of schema-valid field
  combinations are all untested. A green run proves the module's own logic only.
- Neither shows an in-place-versus-replace decision. `tests/install.tftest.hcl` pins the derived
  subnet layout because a change there would replace live subnets; only a plan shows that.

A `plan` from a root configuration against a real subscription proves a change; it is a human action.
`scripts/preflight.sh` checks the prerequisites (providers, roles, SKUs) and is read-only unless given
`--register`. In the PR, say when a change is unproven against Azure and what a plan should cover.
