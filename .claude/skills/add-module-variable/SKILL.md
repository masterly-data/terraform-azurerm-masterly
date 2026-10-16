---
name: add-module-variable
description: Add or change a public input variable of the module, with validation, a customer-facing description, a terraform test run, README and CHANGELOG updates. Use when touching variables.tf, outputs.tf or any variable guard.
---

# Add or change a module variable

`variables.tf`, `outputs.tf` and `versions.tf` are the module's public surface. Every variable
description is customer documentation.

1. **Decide whether it needs an ADR first.** Changing the shape of the public input surface in a way
   a customer must react to, the data-plane or secret-store model (ADR 0065 / 0066), the licence or
   telemetry inputs, or the deployment topology warrants an ADR in `masterly-framework` before the
   change. A variable guard and its test run stay local.
2. **Declare the variable** in `variables.tf` with `type`, a `description` written for a customer
   (what it does, the default's meaning, when to change it) and a safe `default`. A default must not
   be weaker than the behaviour it replaces and must not add a public endpoint.
3. **Add a `validation` block** for every input a customer can get wrong, with an `error_message`
   that says what to change.
4. **Wire it in** to the right file (`main.tf` core, or the subsystem's own `.tf`). If the variable
   feeds an app's `env` or `env_secret_refs` (in `main.tf`, `email.tf`, `entra-auth.tf`,
   `keyvault.tf`, `redis.tf` or `workers.tf`), regenerate the manifest with
   `python3 scripts/check_runtime_env.py --write` and commit `RUNTIME_ENV.json`; CI fails until you do.
5. **Add a `run` block** to `tests/install.tftest.hcl` for each guard, conditional resource
   (`count`/`for_each`) and derived value: a run that passes and an `expect_failures` run for each
   guard. A condition with no run block is a branch nothing exercises.
6. **Update the README** (the module surface reference) and `examples/production/` when the variable
   belongs in a production-posture install.
7. **Write the CHANGELOG entry** under `Unreleased`. A rename, removal, retyping or tightening is a
   breaking change: the entry must carry a migration note.
8. **Validate** with the `validate-module-change` skill.
9. In the PR, say whether the change has been planned against a real subscription. `terraform test`
   uses mock providers and cannot show that Azure accepts it.
