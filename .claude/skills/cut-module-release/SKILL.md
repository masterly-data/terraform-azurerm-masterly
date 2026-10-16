---
name: cut-module-release
description: Prepare a module release commit (MANIFEST.json, CHANGELOG.md, README release table) and hand off the tag to a human. Use when asked to release, bump the version or prepare a version. Never tags.
---

# Prepare a module release

**The tag is the release.** The Terraform Registry watches this repository's tags through its own
webhook, outside GitHub Actions. A published version cannot be withdrawn, only superseded. The sequence
on a tag push is: tag pushed, registry publishes, CI turns red if it is going to. `ci.yml` asserts the
tag matches `MANIFEST.json`, but that is a notification, not a refusal.

## What an agent never does

- Never push a tag and never dispatch `cut-release.yml`. Tagging is a human release decision. An
  agent's job ends at a merged release commit.
- Never treat a green PR as release-readiness; the failure mode is a tag at the wrong commit or
  before the release commit merged.
- Never bump `MANIFEST.json` "to be ready". A manifest naming an unreleased version misleads every
  consumer, and `scripts/check_release_manifest.py` fails the PR.

## What an agent does

1. Follow the order in the README section "Cutting a release". The manifest, the changelog and the
   README move in **one commit, on `main`, before the tag**.
2. Rename the `Unreleased` heading in `CHANGELOG.md` to the version and date. `ci.yml`'s `release`
   job publishes that section as the GitHub Release body via `scripts/release_notes.py` (MAS-258); it
   fails on a missing or empty section, and a re-run rewrites the page. It runs after the registry has
   published, so it is not a gate.
3. Update `MANIFEST.json` (the image pair the reference install had applied at tagging; the contract
   is `docs/release-manifest.md`) and regenerate the README release table with
   `python3 scripts/check_release_manifest.py --write`. Never hand-edit the table.
4. Check every claim about application behaviour with `check-app-behaviour-claim`.
5. Run `validate-module-change`.
6. Hand off: state the version and the full commit SHA to dispatch `cut-release` with, and that a live
   plan against a real subscription is still the maintainer's step. `docs/releasing.md` records which
   repository settings (tag ruleset, release App, `release` Environment) are applied; read it before
   writing that a hand-pushed tag "cannot" publish, and never write that it is refused while that file
   says "not applied".

## How the gate works

`cut-release.yml` (MAS-274, owner decision 2026-09-09) creates the tag only after
`scripts/release_gate.py` finds the commit's `ci` run on `main` green and the tag new, the commit on
`main`, and the commit's manifest, changelog and README publishing that version. It gates its own path
only. Release-please is deliberately not used: the version is a release decision, not computed from
commit messages.
