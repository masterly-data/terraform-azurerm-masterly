# Releasing the module

How a version of `masterly-data/masterly/azurerm` is released, what stands between a commit and
the public registry, and the repository settings that make the workflow the only path. The
step-by-step for the release commit itself is "Cutting a release" in the
[README](../README.md#cutting-a-release); this page covers the tag.

## Why the tag is the step that matters

The Terraform Registry publishes a version of this module from its own webhook the moment a `v*`
tag appears on this repository. Nothing in GitHub Actions takes part in that, and a published
version cannot be withdrawn, only superseded by the next one. Any check that runs because a tag
was pushed therefore runs too late to refuse it.

So the checks run before the tag exists. The commit being tagged merged to `main` earlier, as
the release-cut commit, and was tested as a release candidate in between; it may be behind
`main`'s head by the time it is tagged. The `cut-release` workflow
([`.github/workflows/cut-release.yml`](../.github/workflows/cut-release.yml)) takes a version and a
full commit SHA, and creates the tag only when all of these hold:

| Check | Where |
|---|---|
| The version is `X.Y.Z` and the commit is a full 40-character SHA | `scripts/release_gate.py` |
| The tag does not exist yet | `scripts/release_gate.py` |
| The most recent `ci` run from the commit's push to `main` concluded success, which covers every job in `ci.yml` | `scripts/release_gate.py` |
| The commit is on `main` | `git merge-base --is-ancestor` |
| The commit's `MANIFEST.json`, `CHANGELOG.md` and README publish exactly this version | `scripts/check_release_manifest.py --tag`, `scripts/release_notes.py`, run against the commit's own tree |
| Every other version the commit's `MANIFEST.json` lists already has its tag, so the file at the new tag names only published versions | `scripts/check_release_manifest.py --tag --published-tags` |
| Every default image of the stable and previous channels of the commit's `MANIFEST.json` resolves in `masterly.azurecr.io` at the digest it records (or by tag, for an entry with no digests) | `scripts/check_release_images.py`, main's copy, in the `images` job with the `release` Environment's pull-only token |

`python3 scripts/release_gate.py --selftest` shows the gate refusing each of those faults, and
`python3 scripts/check_release_images.py --selftest` shows the image check refusing a missing
image, a moved tag and a missing or refused credential against a fake registry. CI runs both on
every pull request.

## Live checks before the next tag

Every check above, except the `images` job's read of the registry, runs without Azure.
`terraform test` uses mock providers, so nothing that only Azure can answer has been tested when
CI is green: whether Azure accepts a resource, what a plan does to an install that already exists,
whether a role is enough. The rule for those is to plan, and where needed apply, a live install against the release candidate before it is tagged.

Some changes merge with a specific live check still owed. Each one is listed here until it has
been done, and the version that carries the change is not tagged while any is open. When a check
passes, delete its entry in the commit that records the result; when it fails, the change is
fixed or reverted on `main` first, and the candidate is cut again. Nothing in the workflow above
reads this list, so whoever runs `cut-release` reads it first.

**Released with checks open: 0.24.0 (owner decision, 2026-11-10).** The owner chose to release
0.24.0 with every entry below still open and to track them after the tag, rather than hold the
release: customers were installing images under a scan exception until a new version was
published. The decision and the tracking are on MAS-4312. This is a recorded exception for that
version, not a change to the rule: the next version is not tagged while an entry is open unless
the owner records the same kind of decision for it.

### Open

**The `ca-workers` sizing and scaling inputs** (MAS-1296; in 0.18.0 in the
[changelog](../CHANGELOG.md)). On a live install with `enable_service_bus` and `enable_workers`
on, planned and applied from the candidate:

1. **An existing install updates in place.** Its plan updates `ca-workers` in place (the scale
   rule, the grace period) and adds the queue role assignment, and shows no grace-period diff on
   `ca-api` or `ca-frontend`, which keep Azure's default. No app's CPU, memory or replica bounds
   change unless the install set the new inputs.
2. **Data Owner at queue scope is enough.** A queue backlog scales `ca-workers` above
   `workers_min_replicas` and back down once the queue drains, with the role granted on the jobs
   queue only. If the scaler cannot read the message count at that scope, the fallback is the
   namespace, and docs/scaling.md, the changelog and the comment on the role assignment in
   `workers.tf` change with it.
3. **The scaler reaches a private Premium namespace.** The same, on a Premium namespace with
   public network access disabled, which is the production shape. This is the largest open risk:
   if the scaler cannot reach the namespace from the Container Apps environment, the rule fails
   on exactly the installs that need it, and that needs a decision before release.
4. **Role propagation on a first apply.** On an install where the role assignment is new, the
   scaler starts working once the assignment has propagated, without a second apply. Note how
   long that took.

Progress, 2026-10-22, on Masterly's reference install (`enable_service_bus` and
`enable_workers` on, standard namespace; applied on 0.19.0): item 1 in part — `ca-workers`
updated in place and the queue role assignment was added; item 2 in part — Azure accepted
`Azure Service Bus Data Owner` assigned at the jobs queue's scope (it needed the install's
role-assignment allow-list extended first). Not yet observed: the scaler scaling on a backlog,
items 3 and 4.

Afterwards, replace the "Not yet proven on a live install" paragraph in docs/scaling.md's
"How `ca-workers` scales" and the matching sentence in the changelog entry with what the run
showed.

**Built-in authentication (`builtin_auth`)** (in 0.19.0 in the [changelog](../CHANGELOG.md)).
Planned read-only against a live install that had configured built-in auth by hand on both apps:
both `authConfigs/current` resources imported with one `for_each` import block, no resource was
destroyed, and the hand-added `microsoft-provider-authentication-secret` on each app was replaced
by the module-managed secret of the same name. Not yet applied. Applied from the candidate:

1. **Azure accepts the configuration.** Both `azapi_resource.builtin_auth` instances apply at
   `2025-01-01`, and a second plan shows no change to either.
2. **The gate behaves as documented.** `ca-frontend` redirects an anonymous browser to Entra
   sign-in and serves a signed-in user; `ca-api` answers `401` with no token and with a token
   that is not an Entra token, and admits a client-credentials token from a service principal in
   `api_allowed_applications`.
3. **The frontend still reaches the api.** Signed in, the GUI's calls through the BFF succeed
   with the api gated, which is the in-environment path docs/identity.md says the gate does not see.
4. **The replaced secret works.** Sign-in completes after the apply, with the secret supplied as
   `builtin_auth_client_secret`.

Progress, 2026-10-22, on Masterly's reference install (applied on 0.19.0, run 39765411174):
item 1 in part — both configurations imported and applied, and a refreshing plan afterwards
proposed no change to either; item 2 in part — `ca-frontend` redirects a browser to Entra
sign-in, and `ca-api` answers `401` with no token and with a non-Entra token. Still open: a
service principal's client-credentials token admitted on `ca-api` (item 2), and a signed-in
session through the BFF (items 3 and 4).

The next candidate gates `ca-frontend` only (in 0.20.0 in the
[changelog](../CHANGELOG.md)). That withdraws the `ca-api` half of items 1 and 2, including the
open client-credentials check on `ca-api`: do not run it. Items 5 and 6 replace it. On the same
install, planned and applied from that candidate:

5. **The upgrade removes the api's gate and nothing else.** With the import block narrowed to
   `"frontend"` (or deleted), a refreshing plan from 0.19.1 shows exactly one change: destroy
   `azapi_resource.builtin_auth["api"]`. It shows no change to `builtin_auth["frontend"]`,
   `ca-api` or `ca-frontend`. After the apply, `ca-api` has no built-in auth configured (its
   **Authentication** page in the portal is empty), and a second plan shows no change. On an
   install with `api_ingress_external = true`, both plans also show the warning from
   `check.builtin_auth_does_not_gate_the_published_api`; it is expected, and it is not a change.
6. **The frontend still reaches the api.** Items 3 and 4, on the candidate: a signed-in session
   through the BFF succeeds with the api ungated, and the frontend's gate still redirects an
   anonymous browser to Entra sign-in.

**`ca-workers` on its own identity with the vault** (in 0.24.0 in the
[changelog](../CHANGELOG.md)). On a live install with the vault and `ca-workers` on, on
`migrations = "start"` with `database_auth = "password"`, and separately on BYO-DB, planned and
applied from the candidate:

1. **The plan moves only `ca-workers`.** It creates `id-<prefix>-workers` and its grants, updates
   `ca-workers` in place, and removes the apps identity's Service Bus Data Receiver and jobs-queue
   Data Owner. It replaces no app, shows no identity or env change on `ca-api`, and shows
   `ca-workers`' new identity in plain text rather than as a sensitive value.
2. **The old grants go after `ca-workers`' update.** Before the tag, confirm from the apply log
   that `module.masterly.module.workers[0].azurerm_container_app.this` reached "Modifications
   complete" before `module.masterly.azurerm_role_assignment.sb_receiver[0]` and
   `module.masterly.azurerm_role_assignment.sb_scaler[0]` started "Destroying". docs/data-plane.md and the changelog rely on
   the released module's `ca-workers` `depends_on` edges on those two grants (`workers.tf:189-190`),
   which Terraform records in state; this is the check that it destroys them only after updating
   their recorded dependent.
3. **The new revision starts.** It resolves its Key Vault references as `id-<prefix>-workers` and
   reads `database-url`. Note how long role propagation took, and whether the revision needed a
   restart: docs/data-plane.md's upgrade note says the module adds no wait.
4. **The pipeline keeps running.** A job queued before the apply and one queued after it both run
   as the new identity, and on the Service Bus binding the scaler still reads the queue. Email
   and Redis work as the new identity.
5. **The shapes that do not move plan no change from this.** The same candidate against an install
   on `"start"` with `database_auth = "entra"` shows no identity, grant or env change.

**Removing the apps' Postgres Entra administrator** (MAS-4061; in 0.24.0 in the
[changelog](../CHANGELOG.md)). The changelog and "The migrate job" in docs/data-plane.md promised this was
confirmed before 0.24.0 was released; it was never listed here, and it was not done. On a live
install on `database_auth = "entra"` with `migrations = "job"`, upgraded from 0.23.x in the order
that section gives, and separately on one moving from `"start"` straight to `"job"`:

1. **The plan removes only what the changelog names.** The administrator, `sb_receiver` and
   `sb_scaler` are destroyed, and nothing is replaced.
2. **What happens to the `id-<prefix>-apps` role.** Record what Azure does to that database
   role, which still owns the objects, when its administrator is removed.
3. **Both apps keep serving.** `ca-api` and `ca-workers`, signed in as `masterly_api` and
   `masterly_workers`, keep their database access through and after the apply.

When it passes, replace the "has not yet been confirmed" sentences in docs/data-plane.md's "The migrate
job" and in the 0.24.0 changelog entry with what the run showed.

## What makes the workflow the only path

On its own, the workflow is the documented path, not an enforced one: without further settings,
GitHub accepts a `v*` tag pushed from anyone's checkout, and that tag publishes. Three repository
settings close that. They are applied by a maintainer, because a workflow cannot grant itself the
right to be the only thing that tags.

**Status: applied 2026-11-05** (MAS-4139; the workflow itself is MAS-274). The GitHub App
`masterly-module-release` (app ID 5629013), the `release` Environment and the ruleset
`release-tags` (id 26623122) are in place, and the App is the ruleset's only bypass actor. A `v*`
tag can now be created, moved or deleted only by that App, through `cut-release`. GitHub refuses a
hand-pushed one.

### 1. A release identity — a GitHub App

A tag ruleset needs a bypass actor that is this workflow and nobody's laptop. The workflow's own
`GITHUB_TOKEN` cannot be that actor: GitHub refuses the built-in GitHub Actions app as a bypass
actor on an organization's repository. A dedicated GitHub App can be, and a tag it creates also
starts `ci.yml`'s tag build, which publishes the GitHub Release page.

- Created under the organization, installable on that account only.
- Webhook inactive; no events subscribed.
- Repository permissions: **Contents: read and write**. Nothing else is added. Metadata: read is
  GitHub's mandatory default for every App, not an added permission.
- Installed on this repository only.

### 2. The `release` Environment

The workflow's `images` and `tag` jobs run in an Environment named `release`. Configure it with:

- **Deployment branches and tags:** selected branches, `main` only — so a workflow edited on
  another branch cannot reach the App's key or the registry token. Set this before either secret.
- **Environment secret** `RELEASE_APP_PRIVATE_KEY`: the App's private key.
- **Environment variable** `RELEASE_APP_CLIENT_ID`: the App's client ID.
- **Environment variable** `RELEASE_ACR_TOKEN_NAME` and **Environment secret**
  `RELEASE_ACR_TOKEN_PASSWORD`: the repository-scoped ACR token `pull-ci-cut-release` on the
  `pull-product-images` scope map, and its password. That scope map pulls `release/api` and
  `release/frontend` only, so the token cannot push, delete, or read `license-issuer`,
  `telemetry-receiver` or `web-chat`. Never a repository or organization secret. Until both are
  set the `images` job fails, naming the one missing, and no tag is created. The job's first step
  also refuses a run dispatched from any ref other than `main`, before anything reads the token.
- **Required reviewer** (recommended): GitHub asks for approval on each job that uses the
  Environment, so a release then waits for two approvals, one before the registry read and one
  before the tag is created.

`RELEASE_APP_CLIENT_ID` is set, so the workflow creates the tag as the App. Every check above still
runs first. If the variable is ever unset, the workflow falls back to its `GITHUB_TOKEN`, warns
that it did, and starts the tag build explicitly; the `release-tags` ruleset now refuses that
tag, so the fallback no longer publishes anything.

### 3. The tag ruleset

A repository ruleset on tags, with the App as its only bypass. `<APP_ID>` is the App's numeric
ID (not its client ID); for `masterly-module-release` it is 5629013:

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
