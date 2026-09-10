# The release manifest

[`MANIFEST.json`](../MANIFEST.json) is this module's machine-readable statement of what each
published version *is*: the module version, and the `api` and `frontend` container images that
version was released against. It exists so that fact is written down once and read everywhere,
rather than retyped into a README, a docs page and a pinned install and left to drift apart.

This document is the contract. It is written for the programs that parse the manifest — the
public documentation build, an install's own version-checking tooling, anything that wants to
answer "which images go with module `X.Y.Z`?" without asking a human. If you are cutting a
release rather than consuming one, see "Cutting a release" in the [README](../README.md).

The module version is the primary key. It is the one customer-facing version (ADR 0062): the git
tag, the Terraform Registry version and the version a customer pins are the same number, and the
image tags are what that number resolves to.


## Where to get it

The manifest lives at the repository root and is published with every tag.

| You want | Read |
|---|---|
| The current release | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/MANIFEST.json` |
| One specific release | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/vX.Y.Z/MANIFEST.json` |
| A local checkout | `MANIFEST.json` at the root of the module |

Prefer the tag URL when you are asking about a particular version, and `main` when you are asking
what the newest version is. Both are plain static files over HTTPS: no credential, no API token,
no rate-limited API call. The file is small enough to fetch on every build; cache it on ETag if
you fetch it often.

The manifest names no commit. It cannot: a release's entry is written in the commit that is then
tagged, so it would have to contain its own hash. The tag is the commit pointer — `git rev-parse
"vX.Y.Z^{commit}"` resolves it locally, and the GitHub ref API resolves it remotely.


## The shape

```json
{
  "schema_version": 1,
  "module": "masterly-data/masterly/azurerm",
  "latest": "1.2.3",
  "releases": {
    "1.2.3": {
      "date": "2026-01-31",
      "images": {
        "api": "masterly.azurecr.io/api:vA.B.C",
        "frontend": "masterly.azurecr.io/frontend:vD.E.F"
      }
    }
  }
}
```

The values above are illustrative. Read the real ones from the file; a version transcribed into
your own source is the defect this manifest exists to kill.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | integer | yes | The version of *this shape*. `1` today. See "Compatibility". |
| `module` | string | yes | The Terraform Registry source, `namespace/name/provider`. |
| `latest` | string | yes | The newest published module version. Always a key of `releases`, and always the highest of them by semver. |
| `releases` | object | yes | Published releases, keyed by module version. Never empty. |
| `releases["X.Y.Z"]` | object | yes | One release. The key is a bare semver — `1.2.3`, **not** `v1.2.3`. |
| `releases["X.Y.Z"].date` | string | yes | The release date, `YYYY-MM-DD`. The day the version was tagged. |
| `releases["X.Y.Z"].images` | object | yes | The image pair the release was tested against. |
| `releases["X.Y.Z"].images.api` | string | yes | `registry/repository:tag`. The repository's last path segment is `api`. |
| `releases["X.Y.Z"].images.frontend` | string | yes | Same form; last path segment is `frontend`. |
| `$comment` | string | no | A note to human readers. **Ignore it.** It carries no data and may change or vanish at any time. |

Every one of these is enforced on each pull request and on each tag build by
[`scripts/check_release_manifest.py`](../scripts/check_release_manifest.py), so a release that
violates the table above does not reach you quietly. That checker is itself checked:
`--selftest` stages deliberately broken manifests and asserts each is still rejected.


## What the image pair means, and what it does not

`images` names what Masterly's own reference install had applied when that module version was
tagged — the combination the release was exercised against. It is the right answer to "what
should I pin for a fresh install of module `X.Y.Z`?".

It is **not** a claim about what any given install is running now. The module seeds a newly
created Container App with these tags and then ignores image drift, so an install's running tags
move on from the manifest's pair as its own delivery pipeline rolls forward. A consumer comparing
a live install's tags against the manifest is measuring drift, which may be entirely expected;
it is not measuring a fault.


## Compatibility

**Stable while `schema_version` is `1`.** Every field in the table above keeps its name, its type
and its meaning. `latest` stays a key of `releases` and stays the highest version present.
`releases` stays an object keyed by bare semver. Image values stay parseable as
`registry/repository:tag`.

**May appear without a `schema_version` bump — parse permissively:**

- new entries in `releases` (that is the point of the file);
- new top-level keys;
- new keys inside a release entry;
- new named images alongside `api` and `frontend`, if the module ever ships another app.

Ignore keys you do not recognise. Do not fail on them, and do not assume `images` has exactly two
members.

**Will not happen without a `schema_version` bump:** renaming, removing or retyping any field in
the table; `releases` becoming an array; version keys growing a `v` prefix; `date` changing
format.

So the one compatibility check a consumer owes itself is:

```python
if manifest["schema_version"] != 1:
    raise SystemExit("MANIFEST.json speaks schema %s; this tool understands 1"
                     % manifest["schema_version"])
```

Refuse loudly rather than guessing. A consumer that silently tolerates an unknown schema is how a
stale value survives a shape change.

**`releases` is not complete history.** The manifest was introduced part-way through this
module's life, and versions tagged before it exist with no entry. Treat a lookup miss as "not
recorded", not as "no such version" — and never as a reason to fall back to a hard-coded pair.


## Consuming it

Read the current version and its images:

```bash
curl -fsSL https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/MANIFEST.json \
  | jq -r '.releases[.latest] as $r | "\(.latest)\t\($r.images.api)\t\($r.images.frontend)"'
```

Ask what a version you already pin was released against:

```python
import json
import urllib.request

RAW = "https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/MANIFEST.json"


def images_for(version: str) -> dict[str, str] | None:
    """The image pair module `version` was released against, or None if it predates the manifest."""
    with urllib.request.urlopen(RAW, timeout=10) as response:
        manifest = json.load(response)
    if manifest["schema_version"] != 1:
        raise RuntimeError(f"unsupported manifest schema {manifest['schema_version']}")
    release = manifest["releases"].get(version.removeprefix("v"))
    return release["images"] if release else None
```

Note the `removeprefix("v")`: tags carry the `v`, manifest keys do not.

If you list or order releases, sort by semver rather than by string — `0.9.0` and `0.10.0`
compare the wrong way as text:

```python
def semver(version: str) -> tuple[int, int, int]:
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


ordered = sorted(manifest["releases"], key=semver, reverse=True)  # ordered[0] == manifest["latest"]
```

You never need that to find the newest release: `latest` is guaranteed to be it, and the release
check fails the build if the two ever disagree. Sort only when you want the whole list in order,
or the release before the current one.
