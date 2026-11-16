"""A customer summary is a public file, so this check is the module's last line of defence.

For each Stable version the module commits a redacted `customer-summary/X.Y.Z.json` beside
`MANIFEST.json`, and masterly-web vendors it into the public documentation. The summary comes
out of the test platform's evidence, and that platform has hostnames, Key Vault names, storage
URLs and DAST findings that must never reach a customer. The contract, and why each rule is
there, is docs/customer-summary.md; this script is what enforces it, so the producer
(masterly-release-tests), the module's release notes and masterly-web all check the same thing.

What it refuses, per file, naming the file and the fix:

  * a file name that is not `<version>.json`, or a `version` that is not a key of the manifest's
    `releases` (the keys are read from MANIFEST.json; no version is typed in here);
  * a `schema_version` other than 1, or any field of the contract with the wrong type or shape;
  * a JSON object that repeats a key, since a parser keeps only one of the values and the other
    would be published unchecked;
  * a SEC block that is anything other than integer counts keyed by ZAP risk — an allowlist, so
    an alert name, a URL, a parameter or a rule id has nowhere to go;
  * any string ANYWHERE in the document, keys included, that names a `*.internal` host, a
    `privatelink` name, an `msly-*` or `kv-msly-*` resource, or a `*.core.windows.net` URL. It is
    not limited to known fields, so a field added later cannot become a leak.
    `masterly.azurecr.io` is the public registry and passes.

A `.gitkeep` in `customer-summary/` is ignored. With no `customer-summary/` directory, or none in it, the check passes: nothing is published yet
for a version until its Stable release step writes the file.

Standard library only, and no network call: release metadata should not depend on anything
resolving. Paths are overridable through the environment (`RELEASE_MANIFEST_PATH` as the release
check reads it, and `CUSTOMER_SUMMARY_DIR`) so `--selftest` can stage synthetic trees. The
selftest runs FIRST in CI: it stages a summary for every way the rules are meant to refuse and
fails unless each is still rejected, so a check that has quietly stopped detecting goes red
instead of passing a leaking file.
"""

from __future__ import annotations

import datetime
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = Path(os.environ.get("RELEASE_MANIFEST_PATH", REPO_ROOT / "MANIFEST.json"))
SUMMARY_DIR = Path(os.environ.get("CUSTOMER_SUMMARY_DIR", REPO_ROOT / "customer-summary"))

DOC = "docs/customer-summary.md"
SCHEMA_VERSION = 1
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
PROFILE_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")

RINGS = ("canary", "beta", "stable")
SEC_SEVERITIES = ("High", "Medium", "Low", "Informational")
PERF_MEASURES = ("p50_ms", "p95_ms", "throughput_per_s", "error_rate")
REQUIRED = ("schema_version", "version", "ring", "gates_passed", "upgrade_verified_from", "perf", "sec")

# What no string in a public file may name (case-insensitive). Each pattern is a test-platform
# or infrastructure name; masterly.azurecr.io, the public registry, matches none of them.
REDACTED = (
    ("an internal host (*.internal)", re.compile(r"\.internal(?![A-Za-z0-9_-])", re.I)),
    ("a private-link name", re.compile(r"privatelink", re.I)),
    ("an msly-* or kv-msly-* resource name", re.compile(r"(?<![A-Za-z0-9])msly-", re.I)),
    ("a storage URL (*.core.windows.net)", re.compile(r"\.core\.windows\.net(?![A-Za-z0-9_-])", re.I)),
)


def is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value) -> bool:
    return is_int(value) or (isinstance(value, float) and math.isfinite(value))


def is_date(value) -> bool:
    if not isinstance(value, str) or not DATE.match(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def walk_strings(node, path="$"):
    """Every string in the document, keys included, with where it sits."""
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield f"{path} (key)", key
            yield from walk_strings(value, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk_strings(value, f"{path}[{index}]")


def redaction_errors(name: str, document) -> list[str]:
    errors = []
    for path, text in walk_strings(document):
        for what, pattern in REDACTED:
            if pattern.search(text):
                errors.append(
                    f"{name}: {path} is {text!r}, which names {what}. Remove it: a customer "
                    f"summary carries no internal hostname, resource name or storage URL "
                    f"({DOC}, 'Redaction')."
                )
    return errors


def shape_errors(name: str, file_name: str, document: dict, releases: dict) -> list[str]:
    errors = []

    def bad(message: str) -> None:
        errors.append(f"{name}: {message} See {DOC}.")

    for field in REQUIRED:
        if field not in document:
            bad(f"`{field}` is missing. Add it; it is required.")

    if "schema_version" in document and (
        not is_int(document["schema_version"]) or document["schema_version"] != SCHEMA_VERSION
    ):
        bad(f"`schema_version` is {document['schema_version']!r}, and this check understands "
            f"{SCHEMA_VERSION}. Write the file at schema_version {SCHEMA_VERSION}, or update the "
            f"contract and this check together.")

    version = document.get("version")
    if "version" in document:
        if not isinstance(version, str) or not SEMVER.match(version):
            bad(f"`version` is {version!r}; use a bare semver such as `1.2.3`, with no `v`.")
        elif version not in releases:
            bad(f"`version` {version!r} is not a key of `releases` in MANIFEST.json. Name a "
                f"released version, or add the release to the manifest first.")
        elif file_name != f"{version}.json":
            bad(f"the file is named {file_name!r} but its `version` is {version!r}. Rename it to "
                f"`{version}.json`.")

    ring = document.get("ring")
    if "ring" in document:
        if not isinstance(ring, dict) or set(ring) != set(RINGS):
            bad("`ring` must be an object with exactly `canary`, `beta` and `stable`, each the "
                "date the version reached that ring.")
        elif not all(is_date(ring[r]) for r in RINGS):
            bad("each `ring` date must be a real `YYYY-MM-DD` date.")
        elif not ring["canary"] <= ring["beta"] <= ring["stable"]:
            bad("`ring` dates must not go backwards: canary, then beta, then stable.")

    gates = document.get("gates_passed")
    if "gates_passed" in document and (
        not isinstance(gates, list)
        or not all(isinstance(g, str) and g.strip() for g in gates)
        or len(set(gates)) != len(gates)
    ):
        bad("`gates_passed` must be an array of distinct, non-empty gate names.")

    verified = document.get("upgrade_verified_from")
    if "upgrade_verified_from" in document:
        if not isinstance(verified, list) or not all(
            isinstance(v, str) and SEMVER.match(v) for v in verified
        ):
            bad("`upgrade_verified_from` must be an array of bare semvers such as `1.2.2`.")
        elif len(set(verified)) != len(verified) or version in verified:
            bad("`upgrade_verified_from` must not repeat a version or list the version itself.")

    if "perf" in document:
        errors.extend(f"{name}: {m} See {DOC}." for m in perf_errors(document["perf"], version))

    if "sec" in document:
        errors.extend(f"{name}: {m} See {DOC}." for m in sec_errors(document["sec"]))

    if "$comment" in document and not isinstance(document["$comment"], str):
        bad("`$comment` must be a string.")
    return errors


def perf_errors(perf, version) -> list[str]:
    if perf is None:
        return []  # the first Stable has no previous Stable to measure against
    if not isinstance(perf, dict) or set(perf) != {"baseline", "profiles"}:
        return ["`perf` must be null or an object with exactly `baseline` and `profiles`."]
    errors = []
    baseline = perf["baseline"]
    if not isinstance(baseline, str) or not SEMVER.match(baseline):
        errors.append("`perf.baseline` must be the previous Stable version, a bare semver.")
    elif baseline == version:
        errors.append("`perf.baseline` must be the previous Stable version, not the version itself.")
    profiles = perf["profiles"]
    if not isinstance(profiles, dict) or not profiles:
        return errors + ["`perf.profiles` must be a non-empty object keyed by profile name."]
    for profile, measures in profiles.items():
        where = f"`perf.profiles.{profile}`"
        if not PROFILE_NAME.match(profile):
            errors.append(f"{where}: a profile name is lowercase letters, digits, `_` and `-`.")
        if not isinstance(measures, dict) or set(measures) != set(PERF_MEASURES):
            errors.append(f"{where} must have exactly {', '.join(PERF_MEASURES)}.")
        elif not all(is_number(measures[m]) and measures[m] >= 0 for m in PERF_MEASURES):
            errors.append(f"{where}: every measure is a number of 0 or more.")
        elif measures["error_rate"] > 1:
            errors.append(f"{where}: `error_rate` is a fraction between 0 and 1.")
    return errors


def sec_errors(sec) -> list[str]:
    """SEC is an allowlist: integer counts keyed by ZAP risk, and nothing else."""
    if not isinstance(sec, dict):
        return ["`sec` must be an object of counts by severity."]
    errors = []
    for key in sec:
        if key not in SEC_SEVERITIES:
            errors.append(f"`sec` has the key {key!r}. Remove it: `sec` carries counts keyed by "
                          f"{', '.join(SEC_SEVERITIES)} and nothing else, never a finding's name.")
    for severity in SEC_SEVERITIES:
        if severity not in sec:
            errors.append(f"`sec.{severity}` is missing. Add the count, `0` if there are none.")
        elif not is_int(sec[severity]) or sec[severity] < 0:
            errors.append(f"`sec.{severity}` is {sec[severity]!r}. It must be an integer count of "
                          f"0 or more: a security finding is published as a number only.")
    return errors


def _reject_constant(token: str):
    raise ValueError(f"{token} is not valid JSON")


def _reject_duplicates(pairs):
    # json.loads keeps only the last of a repeated key, so a value under an earlier one would
    # stay in the published file without ever being checked for redaction.
    seen = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"the key {key!r} appears twice; keep one")
        seen.add(key)
    return dict(pairs)


def load_releases(manifest_path: Path) -> dict | str:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return f"{manifest_path}: cannot read the manifest ({exc}). Run from a checkout."
    releases = manifest.get("releases") if isinstance(manifest, dict) else None
    if not isinstance(releases, dict):
        return f"{manifest_path}: `releases` is not an object; fix MANIFEST.json first."
    return releases


def check_tree(manifest_path: Path, summary_dir: Path) -> tuple[list[str], int]:
    """(errors, number of summaries checked)."""
    releases = load_releases(manifest_path)
    if isinstance(releases, str):
        return [releases], 0
    if not summary_dir.is_dir():
        return [], 0
    errors: list[str] = []
    checked = 0
    for path in sorted(summary_dir.iterdir()):
        name = f"{summary_dir.name}/{path.name}"
        if path.name == ".gitkeep":
            continue
        if path.suffix != ".json" or not path.is_file():
            errors.append(f"{name}: not a customer summary. Only `<version>.json` files live "
                          f"here; move or remove it. See {DOC}.")
            continue
        checked += 1
        try:
            document = json.loads(path.read_text(encoding="utf-8"), parse_constant=_reject_constant,
                                  object_pairs_hook=_reject_duplicates)
        except (OSError, ValueError) as exc:
            errors.append(f"{name}: not valid JSON ({exc}). Regenerate it. See {DOC}.")
            continue
        if not isinstance(document, dict):
            errors.append(f"{name}: the top level must be a JSON object. See {DOC}.")
            continue
        errors.extend(shape_errors(name, path.name, document, releases))
        errors.extend(redaction_errors(name, document))
    return errors, checked


def run_check() -> int:
    errors, checked = check_tree(MANIFEST_PATH, SUMMARY_DIR)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        print(f"customer summary check FAILED: {len(errors)} problem(s) in {checked} file(s)",
              file=sys.stderr)
        return 1
    print(f"OK: {checked} customer summary file(s) checked in {SUMMARY_DIR.name}/ "
          f"(none present is fine)")
    return 0


# --- selftest ---------------------------------------------------------------------------------

def _good() -> dict:
    return {
        "schema_version": 1,
        "version": "1.2.3",
        "ring": {"canary": "2026-01-10", "beta": "2026-01-17", "stable": "2026-01-24"},
        "gates_passed": ["upgrade", "perf", "sec"],
        "upgrade_verified_from": ["1.2.2", "1.1.0"],
        "perf": {
            "baseline": "1.2.2",
            "profiles": {"small": {"p50_ms": 120.5, "p95_ms": 340, "throughput_per_s": 52.0,
                                   "error_rate": 0.001}},
        },
        "sec": {"High": 0, "Medium": 0, "Low": 2, "Informational": 5},
    }


def _with(**changes) -> dict:
    document = _good()
    document.update(changes)
    return document


def _without(field: str) -> dict:
    document = _good()
    del document[field]
    return document


def _leak(text: str, where: str = "gates") -> dict:
    document = _good()
    if where == "gates":
        document["gates_passed"] = [text]
    elif where == "key":
        document[text] = "x"
    elif where == "new-field":
        document["notes"] = {"deep": [text]}
    return document


# (name, document or raw text, file name, substring the refusal must contain)
BAD = [
    ("schema_version 2", _with(schema_version=2), "1.2.3.json", "`schema_version` is 2"),
    ("schema_version a string", _with(schema_version="1"), "1.2.3.json", "`schema_version` is '1'"),
    ("schema_version true", _with(schema_version=True), "1.2.3.json", "`schema_version` is True"),
    ("schema_version missing", _without("schema_version"), "1.2.3.json", "`schema_version` is missing"),
    ("version not in the manifest", _with(version="9.9.9"), "9.9.9.json", "not a key of `releases`"),
    ("version with a v prefix", _with(version="v1.2.3"), "v1.2.3.json", "bare semver"),
    ("file name differs from version", _good(), "1.2.4.json", "Rename it to `1.2.3.json`"),
    ("file is not .json", _good(), "1.2.3.txt", "not a customer summary"),
    ("not valid JSON", "{not json", "1.2.3.json", "not valid JSON"),
    ("top level is a list", [], "1.2.3.json", "must be a JSON object"),
    ("ring date backwards", _with(ring={"canary": "2026-02-01", "beta": "2026-01-17",
                                        "stable": "2026-01-24"}), "1.2.3.json", "go backwards"),
    ("ring date malformed", _with(ring={"canary": "10 Jan", "beta": "2026-01-17",
                                        "stable": "2026-01-24"}), "1.2.3.json", "`YYYY-MM-DD`"),
    ("upgrade_verified_from with a v", _with(upgrade_verified_from=["v1.2.2"]), "1.2.3.json",
     "bare semvers"),
    ("perf baseline is not a semver", _with(perf={"baseline": "latest", "profiles": {}}),
     "1.2.3.json", "previous Stable version"),
    ("perf error_rate above 1", _with(perf={"baseline": "1.2.2", "profiles": {"small": {
        "p50_ms": 1, "p95_ms": 2, "throughput_per_s": 3, "error_rate": 7}}}),
     "1.2.3.json", "`error_rate`"),
    ("host *.internal in a value", _leak("api.example.internal"), "1.2.3.json",
     "'api.example.internal', which names an internal host"),
    ("host *.internal with a port", _leak("https://api.example.internal:8443/x"), "1.2.3.json",
     "an internal host"),
    ("privatelink name", _leak("example.privatelink.vaultcore.azure.net"), "1.2.3.json",
     "a private-link name"),
    ("msly- resource name", _leak("msly-example-pg"), "1.2.3.json", "an msly-* or kv-msly-*"),
    ("kv-msly- Key Vault name", _leak("kv-msly-example"), "1.2.3.json", "an msly-* or kv-msly-*"),
    ("storage URL", _leak("https://example.blob.core.windows.net/c/x"), "1.2.3.json",
     "a storage URL"),
    ("leak in a key", _leak("kv-msly-example", "key"), "1.2.3.json", "(key)"),
    ("leak in a field the contract does not know", _leak("example.internal", "new-field"),
     "1.2.3.json", "$.notes.deep[0]"),
    ("sec with an alert name key", _with(sec={"High": 0, "Medium": 0, "Low": 0, "Informational": 0,
                                              "SQL Injection": 1}), "1.2.3.json",
     "`sec` has the key 'SQL Injection'"),
    ("sec with a rule id key", _with(sec={"High": 0, "Medium": 0, "Low": 0, "Informational": 0,
                                          "40018": 1}), "1.2.3.json", "`sec` has the key '40018'"),
    ("sec with a URL value", _with(sec={"High": "https://example.org/x", "Medium": 0, "Low": 0,
                                        "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("sec with a list value", _with(sec={"High": ["/login?id="], "Medium": 0, "Low": 0,
                                         "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("sec with a string count", _with(sec={"High": "0", "Medium": 0, "Low": 0,
                                           "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("sec with a negative count", _with(sec={"High": -1, "Medium": 0, "Low": 0,
                                             "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("sec with a float count", _with(sec={"High": 0.5, "Medium": 0, "Low": 0,
                                          "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("sec with a boolean count", _with(sec={"High": True, "Medium": 0, "Low": 0,
                                            "Informational": 0}), "1.2.3.json", "`sec.High`"),
    ("duplicate key hiding a leak", '{"notes": "api.example.internal", "notes": "ok", '
     + json.dumps(_good())[1:], "1.2.3.json", "the key 'notes' appears twice"),
    ("sec as a list of findings", _with(sec=["XSS on /login"]), "1.2.3.json",
     "`sec` must be an object"),
]

# (name, document or None for an empty tree, file name)
GOOD = [
    ("no summary directory", None, None),
    ("a complete summary", _good(), "1.2.3.json"),
    ("the public registry name", _with(gates_passed=["image masterly.azurecr.io/release/api:v1.0.0"]),
     "1.2.3.json"),
    ("no previous Stable to compare with", _with(perf=None), "1.2.3.json"),
    ("a field added within schema 1", _with(extra_note="a plain sentence"), "1.2.3.json"),
]


def _stage(root: Path, document, file_name) -> dict:
    manifest = {"schema_version": 1, "releases": {"1.2.3": {}, "1.2.2": {}, "1.1.0": {}}}
    (root / "MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
    if file_name is not None:
        directory = root / "customer-summary"
        directory.mkdir()
        text = document if isinstance(document, str) else json.dumps(document)
        (directory / file_name).write_text(text, encoding="utf-8")
    env = dict(os.environ)
    env["RELEASE_MANIFEST_PATH"] = str(root / "MANIFEST.json")
    env["CUSTOMER_SUMMARY_DIR"] = str(root / "customer-summary")
    return env


def _run(document, file_name) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        env = _stage(Path(tmp), document, file_name)
        return subprocess.run([sys.executable, str(Path(__file__).resolve())], env=env,
                              capture_output=True, text=True, check=False)


def selftest() -> int:
    failures = 0
    for name, document, file_name, expected in BAD:
        result = _run(document, file_name)
        if result.returncode == 0:
            print(f"  FAIL: {name}: ACCEPTED, and it must be rejected")
            failures += 1
        elif expected not in result.stderr:
            print(f"  FAIL: {name}: rejected, but not by name (wanted {expected!r}): "
                  f"{result.stderr.strip()}")
            failures += 1
        else:
            print(f"  rejected: {name}")
    for name, document, file_name in GOOD:
        result = _run(document, file_name)
        if result.returncode != 0:
            print(f"  FAIL: {name}: REFUSED, and it must pass: {result.stderr.strip()}")
            failures += 1
        else:
            print(f"  accepted: {name}")
    if failures:
        print(f"selftest FAILED: {failures} case(s) went the wrong way")
        return 1
    print(f"selftest passed: {len(BAD)} bad summaries rejected, {len(GOOD)} good ones accepted")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--selftest"]:
        return selftest()
    if argv:
        print("usage: check_customer_summary.py [--selftest]", file=sys.stderr)
        return 2
    return run_check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
