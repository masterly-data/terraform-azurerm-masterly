---
name: document-baseline-departure
description: Document a place where the module departs from Azure's recommended baseline. Use when a change turns off, relaxes or replaces an Azure-recommended setting (network, identity, logging, SKU, TLS, public access).
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
4. Add a CHANGELOG entry under `Unreleased`.
5. Write in plain, factual, customer-readable language: this repository is public. No internal
   shorthand and no speculation about customers.
