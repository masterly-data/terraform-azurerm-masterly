---
name: document-baseline-departure
description: Document a place where the module departs from Azure's recommended baseline. Use when a change turns off, relaxes or replaces an Azure-recommended setting (network, identity, logging, SKU, TLS, public access), or when the IaC scan flags one.
---

# Document a departure from Azure's baseline

A departure that the README does not document blocks review (see `REVIEW.md`).

1. Prefer not departing. A new public endpoint or a weaker default needs an owner decision first;
   if there is none, stop and ask.
2. Add the departure to the README section "Where this module departs from Azure's recommended
   baseline". For each entry state: the Azure recommendation, what the module does instead, why
   (the constraint, with the ADR number if one exists), what the customer can do to close the gap,
   and the input that controls it.
3. Where the departure is configurable, give the `variables.tf` description the same explanation, and
   add `run` blocks in `tests/install.tftest.hcl` covering both branches.
4. If the `iac-scan` job (Trivy) flags the departure, add one entry to `.trivyignore.yaml` under
   `misconfigurations`: the rule `id`, `paths` naming the real file that carries it, and a `statement`
   naming the README heading from step 2. The file's header gives the exact shape. Never add a blanket
   skip, a severity filter, a bare path or an inline `trivy:ignore` / `tfsec:ignore` comment; run
   `bash scripts/iac_scan.sh --check` to confirm the entry is accepted.
5. Add a CHANGELOG entry under `Unreleased`.
6. Write in plain, factual, customer-readable language: this repository is public. No internal
   shorthand and no speculation about customers.
