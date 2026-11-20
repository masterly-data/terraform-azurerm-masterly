---
name: cut-module-release
description: Prepare a module release commit (MANIFEST.json, CHANGELOG.md, README release table) and hand off the tag to a human. Use when asked to release, bump the version or prepare a version. Never tags.
---

# Prepare a module release

**The tag is the release.** The Terraform Registry watches this repository's tags through its own
webhook, outside GitHub Actions. A published version cannot be withdrawn, only superseded. The sequence
on a tag push is: tag pushed, registry publishes, CI turns red if it is going to. `ci.yml` asserts the
tag matches `MANIFEST.json`, but that is a notification, not a refusal. The GitHub Release page CI
creates afterwards is release notes, not a release step.

## What an agent never does

- Never push a tag and never dispatch `cut-release.yml`. Tagging is a human release decision. An
  agent's job ends at a merged release commit.
- Never treat a green PR as release-readiness; the realistic failure MAS-274 names is a tag pushed at
  the wrong commit, or before the release commit merged. Both look fine locally.
- Never bump `MANIFEST.json` "to be ready". A manifest naming an unreleased version misleads every
  consumer, and `scripts/check_release_manifest.py` fails the PR.

## What an agent does

1. Follow the order in the README section "Cutting a release". The manifest, the changelog and the
   README move in **one commit, on `main`, before the tag**.
2. Run `python3 scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`. It folds the fragments in `changelog.d/`
   into the version's section below the empty `Unreleased` and deletes them in the same commit (on a
   re-cut it merges into the existing section and sets its date). `check_release_manifest.py --tag`
   refuses a tree that still has a fragment. `ci.yml`'s `release`
   job runs after the other jobs pass on a tag build and publishes that section as the GitHub Release
   body via `scripts/release_notes.py` (MAS-258); it fails on a missing or empty section, and a re-run
   rewrites the page rather than creating a second one. It runs after the registry has published, so
   it is not a gate: a tag whose checks fail simply gets no Release page.
3. Update `MANIFEST.json` (the image pair the reference install had applied at tagging; the contract
   is `docs/release-manifest.md`) and regenerate the README release table with
   `python3 scripts/check_release_manifest.py --write`. Never hand-edit the table. The version's entry
   names `masterly.azurecr.io/release/` images and records `digests.api` and `digests.frontend`:
   `cut-release` refuses an entry without them.
4. Check every claim about application behaviour with `check-app-behaviour-claim`.
5. Run `validate-module-change`.
6. Hand off: state the version and the full commit SHA to dispatch `cut-release` with, and that a live
   plan against a real subscription is still the maintainer's step. `docs/releasing.md` records which
   repository settings (tag ruleset, release App, `release` Environment) are applied; read it before
   writing that a hand-pushed tag "cannot" publish, and never write that it is refused while that file
   says "not applied".

## How the gate works

`cut-release.yml` (MAS-274, owner decision 2026-09-09) creates the tag only after it finds the commit a
full SHA on `main`, and `scripts/release_gate.py` finds the commit's `ci` run on `main` green, the tag
absent or already at exactly that commit, and the commit's manifest entry naming release images pinned
by digest; and the commit's manifest, changelog and README publish that version. A tag already at the
commit is not written again; a tag at another commit is refused. Once the tag is at the commit it sends
`release-published` (version, tag, commit) to `masterly-release-tests`. At Stable, that repository's
`promote.yml` dispatches it (ADR 0107 §5); see `docs/releasing.md`. It gates its own path only.
Release-please is deliberately not used: the version is a release decision, not computed from commit
messages.
