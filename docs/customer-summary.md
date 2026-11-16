# The customer summary

A customer summary is the short, public record of what a Stable module version was tested for
before it reached the Stable ring: which rings it went through and when, which gates it passed,
which earlier versions its upgrade was verified from, how it performs against the previous Stable
version, and how many security findings the scan left, by severity. It is one JSON file per
Stable version, committed beside [`MANIFEST.json`](../MANIFEST.json) and read by the public
documentation.

This document is the contract. It is written for the programs that produce and parse the file —
the evidence job that writes it, the release step that commits it, the documentation build that
vendors it. The module version is the primary key, exactly as it is in the
[release manifest](release-manifest.md).

A summary is a **public** file. Everything below that says what it may not contain is as much a
part of the contract as the shape.


## Where to get it

One file per version, in the `customer-summary/` directory at the repository root, named for the
version it describes:

| You want | Read |
|---|---|
| One specific version | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/vX.Y.Z/customer-summary/X.Y.Z.json` |
| The newest summary | `https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/customer-summary/X.Y.Z.json`, for the `X.Y.Z` that `MANIFEST.json`'s `latest` names |
| A local checkout | `customer-summary/X.Y.Z.json` at the root of the module |

The file name is the bare semver of a key of `releases` in `MANIFEST.json`, plus `.json`:
`customer-summary/1.2.3.json`, **not** `v1.2.3.json`. A version with no file has no summary; a
version is not required to have one, so treat a missing file as "not recorded". Only Stable
versions carry one.


## The shape

```json
{
  "schema_version": 1,
  "version": "1.2.3",
  "ring": {
    "canary": "2026-01-10",
    "beta": "2026-01-17",
    "stable": "2026-01-24"
  },
  "gates_passed": ["upgrade", "perf", "sec"],
  "upgrade_verified_from": ["1.2.2", "1.1.0"],
  "perf": {
    "baseline": "1.2.2",
    "profiles": {
      "small": {
        "p50_ms": 120.5,
        "p95_ms": 340,
        "throughput_per_s": 52.0,
        "error_rate": 0.001
      }
    }
  },
  "sec": {
    "High": 0,
    "Medium": 0,
    "Low": 2,
    "Informational": 5
  }
}
```

The values above are illustrative. Read the real ones from the file.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | integer | yes | The version of *this shape*. `1` today. See "Compatibility". |
| `version` | string | yes | The module version the summary describes, a bare semver. Always a key of `releases` in `MANIFEST.json`, and always the file's name without `.json`. |
| `ring` | object | yes | The date the version reached each ring (ADR 0107): exactly `canary`, `beta` and `stable`. |
| `ring.canary`, `ring.beta`, `ring.stable` | string | yes | `YYYY-MM-DD`, a real date, the day the version was promoted into that ring. Dates do not go backwards: canary, then beta, then stable. |
| `gates_passed` | array of strings | yes | The names of the release gates the version passed before it was promoted to Stable. Distinct, non-empty names. Like every string, subject to "Redaction". |
| `upgrade_verified_from` | array of strings | yes | The module versions an upgrade to this version was verified from, each a bare semver. May be empty. Each is a key of `releases` in `MANIFEST.json` and lower than `version`; none repeats. |
| `perf` | object or `null` | yes | The performance of this version against the previous Stable version. `null` when there is no previous Stable version to compare with. |
| `perf.baseline` | string | with `perf` | The previous Stable version it was measured against, a bare semver. A key of `releases` in `MANIFEST.json`, lower than `version`. |
| `perf.profiles` | object | with `perf` | The measures per load profile, keyed by a profile name (lowercase letters, digits, `_`, `-`). Never empty. |
| `perf.profiles.<profile>.p50_ms` | number | with the profile | Median latency in milliseconds, 0 or more. |
| `perf.profiles.<profile>.p95_ms` | number | with the profile | 95th percentile latency in milliseconds, 0 or more. |
| `perf.profiles.<profile>.throughput_per_s` | number | with the profile | Sustained throughput in requests per second, 0 or more. |
| `perf.profiles.<profile>.error_rate` | number | with the profile | The fraction of requests that failed, from 0 to 1. |
| `sec` | object | yes | The security findings the scan left, as **counts by severity** and nothing else. See "Redaction". |
| `sec.High`, `sec.Medium`, `sec.Low`, `sec.Informational` | integer | yes | The number of findings at that ZAP risk, 0 or more. All four are present; `0` means none. |
| `$comment` | string | no | A note to human readers. **Ignore it.** It carries no data and may change or vanish at any time. |

Every one of these is enforced on each pull request by
[`scripts/check_customer_summary.py`](../scripts/check_customer_summary.py), against the file
itself and against `MANIFEST.json`. That checker is itself checked: `--selftest` stages
deliberately broken summaries and asserts each is still rejected. With no summary in the tree, it
passes.


## Redaction

The summary is published to everyone, and it is made from the evidence of a test platform that
has names and findings no customer should see. Two rules keep them out.

**No internal name, anywhere.** No string in the document may name:

- a host under `.internal`;
- a private-link name (anything containing `privatelink`);
- a resource named `msly-…`, including a Key Vault named `kv-msly-…`;
- a storage URL, a host under `.core.windows.net`.

The rule applies to **every string in the file, object keys included**, not only to the fields
listed above. A field added later therefore cannot become a leak. `masterly.azurecr.io`, the
public registry, is not an internal name.

**No security finding beyond a count.** `sec` is an allowlist: the four keys `High`, `Medium`,
`Low` and `Informational`, each an integer. A finding's name, its URL, the parameter it was found
in, a rule identifier or any other key is refused. Findings of the dynamic scan stay internal;
what a customer is told is how many there are at each severity.

A JSON object may not repeat a key: a parser keeps only one of the values, so the other would be
published unchecked. The check refuses a violation naming the file, where in it the value sits,
and the value.


## Compatibility

**Stable while `schema_version` is `1`.** Every field in the table above keeps its name, its type
and its meaning. `ring` keeps exactly the three rings. `sec` keeps exactly the four severities
and stays counts only. The file stays at `customer-summary/X.Y.Z.json` with a bare-semver name.

**May appear without a `schema_version` bump — parse permissively:**

- new optional top-level keys;
- new entries in `gates_passed`, and new profiles in `perf.profiles`.

Ignore keys you do not recognise. Do not fail on them. The producer is stricter than the
consumer: a key added within 1 is still subject to "Redaction", so it carries no internal name.

**Will not happen without a `schema_version` bump:** renaming, removing or retyping any field in
the table; a new measure inside a `perf.profiles.<profile>`; a new ring, or a ring renamed; a new
severity key or any non-count value in `sec`; `date`-style fields changing format; version keys growing a `v` prefix; the file moving.

So the one compatibility check a consumer owes itself is:

```python
if summary["schema_version"] != 1:
    raise SystemExit("customer summary speaks schema %s; this tool understands 1"
                     % summary["schema_version"])
```

Refuse loudly rather than guessing.


## Consuming it

```bash
curl -fsSL https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/vX.Y.Z/customer-summary/X.Y.Z.json \
  | jq '{version, stable: .ring.stable, upgrade_verified_from, sec}'
```

A consumer that republishes the file, such as the public documentation, should run the same
redaction rules over what it vendors. It is the second line of defence, not the first: this
module's check is the first.
