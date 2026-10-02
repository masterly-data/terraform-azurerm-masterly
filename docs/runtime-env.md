# The runtime-environment manifest

[`RUNTIME_ENV.json`](../RUNTIME_ENV.json) is this module's machine-readable statement of which
environment variables it sets on each of the install's container apps — `ca-api`, `ca-workers`
and `ca-frontend` — by **name**. It carries no value: a value is per install, and several of
them are secrets.

It exists so that fact is written down once, by a program, and read everywhere. The application
images read their configuration from the environment at start, each application's repository
documents the contract its container reads, and the module is what wires an install's values to
those names. Three descriptions of one list, maintained by hand in three places, drift — and
drift here is silent: a name the module sets that no application reads lands on the container
and does nothing, and a name an application reads that nobody documented is one an operator of a
non-module install never learns to set. The manifest is what each application repository checks
its own code and runbook against, so the three descriptions cannot part quietly.

**It is generated, never edited.** `scripts/check_runtime_env.py --write` derives it from the
`.tf` files at the module root — the env a container receives is assembled from locals spread
over `main.tf`, `email.tf`, `keyvault.tf`, `redis.tf` and `workers.tf` and merged into each
app's `env` and `env_secret_refs` — and the same script, without `--write`, fails CI on every
pull request where the committed file is not what the `.tf` files produce. A name that appears
only in a comment is not set and is not listed.


## Where to get it

The manifest lives at the repository root and ships with every tag, including the tarball an
air-gapped install receives.

| You want | Read |
|---|---|
| What the newest module sets | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/RUNTIME_ENV.json` |
| What one specific release sets | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/vX.Y.Z/RUNTIME_ENV.json` |
| A local checkout | `RUNTIME_ENV.json` at the root of the module |

Both are plain static files over HTTPS: no credential, no API token, no rate-limited API call.
Versions tagged before the manifest existed have no copy of it.


## The shape

```json
{
  "schema_version": 1,
  "module": "masterly-data/masterly/azurerm",
  "apps": {
    "ca-api": {
      "env": ["MASTERLY_MODE", "MASTERLY_REGION"],
      "env_secret_refs": ["MASTERLY_DATABASE_URL"]
    },
    "ca-frontend": {
      "env": ["MASTERLY_API_BASE_URL"],
      "env_secret_refs": []
    }
  }
}
```

The values above are illustrative. Read the real ones from the file; a name transcribed into
your own source is the defect this manifest exists to kill.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | integer | yes | The version of *this shape*. `1` today. See "Compatibility". |
| `module` | string | yes | The Terraform Registry source, `namespace/name/provider` — the same value `MANIFEST.json` carries. |
| `apps` | object | yes | One entry per container app the module creates, keyed by the app's name (`ca-api`, `ca-workers`, `ca-frontend`). Sorted by key. |
| `apps[name].env` | array of strings | yes | Every variable name the module may set on that app as plain environment, sorted. Includes names set only under some inputs (see below) and names that are not `MASTERLY_`-prefixed, such as `AZURE_CLIENT_ID`. |
| `apps[name].env_secret_refs` | array of strings | yes | Every variable name the module may set on that app as a reference to a Container App secret, sorted. The value never appears in the app's template; the name is what the application reads. |

Every one of these is enforced on each pull request by
[`scripts/check_runtime_env.py`](../scripts/check_runtime_env.py), which also proves that every
name in the diagnostic bundle's `ENV_VALUE_ALLOWLIST` (`scripts/diagnostic-bundle.sh`) is a name
the module sets somewhere — the bundle redacts every value not on that list, so a misspelt entry
is a value quietly missing from every bundle. That checker is itself checked: `--selftest` stages
deliberately broken module trees and asserts each is still rejected.


## What "sets" means

A name is listed when **any** input makes the module set it. `MASTERLY_OIDC_AUDIENCE` is set only
when `identity_binding = "oidc"`; `MASTERLY_REDIS_URL` only when Redis is enabled;
`MASTERLY_ORG_NAME` only when `org_name` is given. The manifest does not say which input, and it
does not say which names a particular install has — that is the install's own plan. It answers
one question: *is this a name the module can put on this app?* An application that reads a name
the manifest does not list must get it from somewhere other than this module; a name the
manifest lists that no application reads is a module defect.

`ca-api` and `ca-workers` carry the same list on purpose: the workers container runs the same
image with a different command and reads the same settings.


## Compatibility

**Stable while `schema_version` is `1`.** Every field in the table above keeps its name, its type
and its meaning. `apps` stays an object keyed by app name; each app keeps `env` and
`env_secret_refs` as sorted arrays of names.

**May appear without a `schema_version` bump — parse permissively:**

- new names in either array (that is the point of the file);
- new apps under `apps`, if the module ever ships another container;
- new top-level keys, and new keys inside an app entry.

Ignore keys you do not recognise, and do not assume `apps` has exactly three members.

**Will not happen without a `schema_version` bump:** renaming, removing or retyping any field in
the table; an array becoming an object; a value appearing beside a name.

So the one compatibility check a consumer owes itself is:

```python
if manifest["schema_version"] != 1:
    raise SystemExit("RUNTIME_ENV.json speaks schema %s; this tool understands 1"
                     % manifest["schema_version"])
```

Refuse loudly rather than guessing.


## Consuming it

The application repositories vendor this file — copy it in with a script, commit it beside a
record of the commit and digest it came from, and check their own code and runbook against the
committed copy on every pull request, with no network and no checkout of this module. A copy is
behind the moment this module changes what it sets, so each of them also asks this public file,
on a schedule, whether their copy is still current, and re-vendors when it is not. Which is to
say: a change here that adds, renames or drops a name is not finished until the application that
reads it has adopted the new manifest, and its own check is what says so.

Which names a running install actually carries, and with what values, is a question for the
install itself:

```bash
az containerapp show --name ca-api --resource-group rg-masterly-<install>-aca \
  --query "properties.template.containers[0].env[].name" -o tsv
```
