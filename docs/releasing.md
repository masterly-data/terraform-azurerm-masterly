# Releasing the module

How a version of `masterly-data/masterly/azurerm` is released, what stands between a commit and
the public registry, and what does not yet. The step-by-step for the release commit itself is
"Cutting a release" in the [README](../README.md#cutting-a-release); this page covers the tag.

## Why the tag is the step that matters

The Terraform Registry publishes a version of this module from its own webhook the moment a `v*`
tag appears on this repository. Nothing in GitHub Actions takes part in that, and a published
version cannot be withdrawn, only superseded by the next one. Any check that runs because a tag
was pushed therefore runs too late to refuse it.

So the checks run before the tag exists. The `cut-release` workflow
([`.github/workflows/cut-release.yml`](../.github/workflows/cut-release.yml)) takes a version and a
full commit SHA, and creates the tag only when all of these hold:

| Check | Where |
|---|---|
| The version is `X.Y.Z` and the commit is a full 40-character SHA | `scripts/release_gate.py` |
| The tag does not exist yet | `scripts/release_gate.py` |
| The most recent `ci` run from the commit's push to `main` concluded success, which covers every job in `ci.yml` | `scripts/release_gate.py` |
| The commit is on `main` | `git merge-base --is-ancestor` |
| The commit's `MANIFEST.json`, `CHANGELOG.md` and README publish exactly this version | `scripts/check_release_manifest.py --tag`, `scripts/release_notes.py`, run against the commit's own tree |

`python3 scripts/release_gate.py --selftest` shows the gate refusing each of those faults, and CI
runs it on every pull request.

## What makes the workflow the only path

On its own, the workflow is the documented path, not an enforced one: GitHub still accepts a `v*`
tag pushed from anyone's checkout, and that tag publishes. Three repository settings close that.
They are applied by a maintainer, because a workflow cannot grant itself the right to be the only
thing that tags.

**Status: not applied yet** (MAS-274). Until the line above changes, a hand-pushed tag still
publishes. Change it in the same commit that records the settings being applied.

### 1. A release identity — a GitHub App

A tag ruleset needs a bypass actor that is this workflow and nobody's laptop. The workflow's own
`GITHUB_TOKEN` cannot be that actor: GitHub refuses the built-in GitHub Actions app as a bypass
actor on an organization's repository. A dedicated GitHub App can be, and a tag it creates also
starts `ci.yml`'s tag build, which publishes the GitHub Release page.

- Created under the organization, installable on that account only.
- Webhook inactive; no events subscribed.
- Repository permissions: **Contents: read and write**. Nothing else.
- Installed on this repository only.

### 2. The `release` Environment

The workflow's `tag` job runs in an Environment named `release`. Configure it with:

- **Deployment branches and tags:** selected branches, `main` only — so a workflow edited on
  another branch cannot reach the App's key.
- **Environment secret** `RELEASE_APP_PRIVATE_KEY`: the App's private key.
- **Environment variable** `RELEASE_APP_CLIENT_ID`: the App's client ID.
- **Required reviewer** (recommended): a release then waits for one approval after every check
  has passed and before the tag is created.

Until `RELEASE_APP_CLIENT_ID` is set, the workflow creates the tag with its `GITHUB_TOKEN`, warns
that it did, and starts the tag build explicitly. Every check above still runs first.

### 3. The tag ruleset

A repository ruleset on tags, with the App as its only bypass. `<APP_ID>` is the App's numeric
ID (not its client ID):

```json
{
  "name": "release-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [
    { "type": "creation" },
    { "type": "update" },
    { "type": "deletion" }
  ],
  "bypass_actors": [
    { "actor_id": <APP_ID>, "actor_type": "Integration", "bypass_mode": "always" }
  ]
}
```

```bash
gh api -X POST repos/masterly-data/terraform-azurerm-masterly/rulesets --input release-tags.json
```

`creation` is what refuses a hand-pushed release tag. `update` and `deletion` stop a published tag
being moved to another commit or removed, which would leave the registry's version and the
repository's tag describing different code. Apply it after step 2: from then on the
`GITHUB_TOKEN` path is refused by GitHub, which is intended.

## Verifying

```bash
gh api repos/masterly-data/terraform-azurerm-masterly/rulesets \
  --jq '.[] | select(.target == "tag") | {name, enforcement}'
gh api repos/masterly-data/terraform-azurerm-masterly/environments/release \
  --jq '{name, rules: [.protection_rules[].type]}'
```

The first release cut through the workflow is the end-to-end proof: confirm the version appears on
the registry and that its GitHub Release page is published.
