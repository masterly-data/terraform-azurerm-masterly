"""The release manifest is the one place a module version and its image pair are written down.

Five stale-version cards landed in a single week (MAS-199, MAS-222..225), every one of them the
same defect: a version that exists in one place got retyped in another, and the copy went stale
because nothing connected the two. MAS-227 diagnosed it; this is the first half of the fix —
`MANIFEST.json` states, per published module version, the `api` and `frontend` images that
version was released against, and `CHANGELOG.md` states what changed. ADR 0062 (amended
2026-09-09) settled that the MODULE version is the one customer-facing version, so the manifest
is keyed by it.

A manifest nobody is forced to update is a documented good intention, so this script is the
forcing function, and CI runs it three times over:

  * on every pull request and push to main — the manifest, the changelog and the README must
    agree with each other, so the release commit that bumps them is validated BEFORE it merges;
  * on a tag push (`--tag vX.Y.Z`) — the tag must be the manifest's `latest` and must have a
    changelog entry, so a tag cut without them turns the release build red immediately;
  * before either, as `--selftest` — synthetic trees prove the check still rejects a missing,
    malformed or mis-tagged release, so a detector that has quietly stopped detecting fails
    loudly instead of passing this repo for the wrong reason.

The shape the manifest guarantees to whoever parses it — field by field, and what may change
without warning — is `docs/release-manifest.md`. That document and this script move together.

It parses both sides. It transcribes nothing: every version and image string it compares is read
out of `MANIFEST.json` or out of the file being checked. A checker carrying its own copy of the
value would be the very defect it exists to catch.

Run:
    python3 scripts/check_release_manifest.py            # check (what CI runs)
    python3 scripts/check_release_manifest.py --write    # regenerate README.md from the manifest
    python3 scripts/check_release_manifest.py --tag v0.15.0
    python3 scripts/check_release_manifest.py --selftest  # the check still rejects bad releases

Paths are overridable through the environment (`RELEASE_MANIFEST_PATH`, `RELEASE_CHANGELOG_PATH`,
`RELEASE_README_PATH`), which is how the check is exercised against a mutated copy of the tree
before it is trusted in CI.
"""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

MANIFEST_PATH = Path(os.environ.get("RELEASE_MANIFEST_PATH", REPO_ROOT / "MANIFEST.json"))
CHANGELOG_PATH = Path(os.environ.get("RELEASE_CHANGELOG_PATH", REPO_ROOT / "CHANGELOG.md"))
README_PATH = Path(os.environ.get("RELEASE_README_PATH", REPO_ROOT / "README.md"))

# The schema version this script — and docs/release-manifest.md, the contract other repos read
# the manifest against — knows how to speak. Bumping the manifest without bumping both is how a
# consumer starts parsing a shape nobody promised it, so the check refuses the mismatch.
SCHEMA_VERSION = 1

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TAG_RE = re.compile(r"^v(\d+\.\d+\.\d+)$")
IMAGE_RE = re.compile(r"^(?P<registry>[^/\s]+)/(?P<repo>[^:\s]+):(?P<tag>[^\s\"]+)$")

# The README lines that restate a manifest fact. Each keeps everything up to the opening quote —
# the HCL blocks in the README are aligned, and a rewrite must not disturb that.
VERSION_PIN_RE = re.compile(r'^(?P<head>\s*version\s*=\s*)"~>\s*\d+\.\d+"\s*$')
IMAGE_PIN_RE = re.compile(r'^(?P<head>\s*(?P<name>api_image|frontend_image)\s*=\s*)"[^"]*"\s*$')

BEGIN_MARKER = "<!-- release-manifest:begin -->"
END_MARKER = "<!-- release-manifest:end -->"

# Which manifest image a README `<name>_image` line takes its value from.
IMAGE_INPUTS = {"api_image": "api", "frontend_image": "frontend"}


class CheckFailed(Exception):
    """A problem worth failing the build over, phrased for whoever has to fix it."""


def semver(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.match(version)
    if not match:
        raise CheckFailed(f"{version!r} is not an X.Y.Z version")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def load_manifest() -> dict:
    """`MANIFEST.json`, checked for the shape every consumer of it is entitled to assume."""
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CheckFailed(
            f"{MANIFEST_PATH} is missing. Every published module version needs an entry there; "
            f"see 'Cutting a release' in the README."
        ) from None
    except json.JSONDecodeError as exc:
        raise CheckFailed(f"{MANIFEST_PATH} is not valid JSON: {exc}") from None

    for key in ("schema_version", "module", "latest", "releases"):
        if key not in manifest:
            raise CheckFailed(f"{MANIFEST_PATH} has no {key!r} key")

    if manifest["schema_version"] != SCHEMA_VERSION:
        raise CheckFailed(
            f"{MANIFEST_PATH}: 'schema_version' is {manifest['schema_version']!r}, but this "
            f"repo speaks version {SCHEMA_VERSION}. The manifest is a published contract "
            f"(docs/release-manifest.md) that masterly-web and an install's own tooling parse — "
            f"a shape change ships with this script and that document, or consumers are reading "
            f"a shape nobody promised them."
        )
    if not isinstance(manifest["module"], str) or not manifest["module"]:
        raise CheckFailed(f"{MANIFEST_PATH}: 'module' must be the registry source string")

    releases = manifest["releases"]
    if not isinstance(releases, dict) or not releases:
        raise CheckFailed(f"{MANIFEST_PATH}: 'releases' must be a non-empty object keyed by version")

    for version, entry in releases.items():
        where = f"{MANIFEST_PATH}: release {version}"
        semver(version)
        if not isinstance(entry, dict):
            raise CheckFailed(f"{where} is not an object")
        date = entry.get("date")
        if not isinstance(date, str) or not DATE_RE.match(date):
            raise CheckFailed(f"{where} has no YYYY-MM-DD 'date'")
        images = entry.get("images")
        if not isinstance(images, dict):
            raise CheckFailed(f"{where} has no 'images' object")
        for name in IMAGE_INPUTS.values():
            value = images.get(name)
            if not isinstance(value, str):
                raise CheckFailed(f"{where} names no {name!r} image")
            parsed = IMAGE_RE.match(value)
            if not parsed:
                raise CheckFailed(f"{where}: {value!r} is not registry/repository:tag")
            if parsed.group("repo").rsplit("/", 1)[-1] != name:
                raise CheckFailed(
                    f"{where}: the {name!r} image is {value!r}, whose repository is not {name!r}. "
                    f"A pair swapped in the manifest is worse than no manifest."
                )

    latest = manifest["latest"]
    if latest not in releases:
        raise CheckFailed(f"{MANIFEST_PATH}: 'latest' is {latest!r}, which has no release entry")
    newest = max(releases, key=semver)
    if latest != newest:
        raise CheckFailed(
            f"{MANIFEST_PATH}: 'latest' is {latest!r} but {newest!r} is the highest version "
            f"present. Bumping one without the other is how the copy goes stale."
        )
    return manifest


def check_changelog(manifest: dict) -> None:
    """Every released version in the manifest has a changelog section, dated the same day."""
    try:
        changelog = CHANGELOG_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise CheckFailed(f"{CHANGELOG_PATH} is missing") from None

    if not re.search(r"^##\s*\[?Unreleased\]?", changelog, re.MULTILINE | re.IGNORECASE):
        raise CheckFailed(
            f"{CHANGELOG_PATH} has no 'Unreleased' section. Changes are authored there and the "
            f"heading is renamed at release-cut (ADR 0062) — without it there is nowhere to write."
        )

    dated = {
        match.group("version"): match.group("date")
        for match in re.finditer(
            r"^##\s*\[?(?P<version>\d+\.\d+\.\d+)\]?\s*-\s*(?P<date>\d{4}-\d{2}-\d{2})\s*$",
            changelog,
            re.MULTILINE,
        )
    }
    for version, entry in manifest["releases"].items():
        if version not in dated:
            raise CheckFailed(
                f"{CHANGELOG_PATH} has no '## [{version}] - {entry['date']}' section, but "
                f"{MANIFEST_PATH.name} publishes {version}. A release ships both or neither."
            )
        if dated[version] != entry["date"]:
            raise CheckFailed(
                f"{version} is dated {dated[version]} in {CHANGELOG_PATH.name} and "
                f"{entry['date']} in {MANIFEST_PATH.name}."
            )


def release_table(manifest: dict) -> list[str]:
    """The README's tested-combination table, rendered from the manifest — newest release first."""
    lines = [
        "| Module version | `api_image` | `frontend_image` | Released |",
        "|---|---|---|---|",
    ]
    for version in sorted(manifest["releases"], key=semver, reverse=True):
        entry = manifest["releases"][version]
        images = entry["images"]
        lines.append(
            f"| `{version}` | `{images['api']}` | `{images['frontend']}` | {entry['date']} |"
        )
    return lines


def render_readme(manifest: dict, readme: str) -> str:
    """`readme` with every fact the manifest owns replaced by the manifest's value."""
    latest = manifest["releases"][manifest["latest"]]
    major, minor, _ = semver(manifest["latest"])
    constraint = f"~> {major}.{minor}"

    rendered: list[str] = []
    seen = {"version": 0, "api_image": 0, "frontend_image": 0}
    for line in readme.split("\n"):
        pin = VERSION_PIN_RE.match(line)
        if pin:
            seen["version"] += 1
            rendered.append(f'{pin.group("head")}"{constraint}"')
            continue
        image = IMAGE_PIN_RE.match(line)
        if image:
            name = image.group("name")
            seen[name] += 1
            rendered.append(f'{image.group("head")}"{latest["images"][IMAGE_INPUTS[name]]}"')
            continue
        rendered.append(line)

    for name, count in seen.items():
        if count == 0:
            raise CheckFailed(
                f"{README_PATH} no longer has a `{name} = \"…\"` line for this check to keep in "
                f"step with {MANIFEST_PATH.name}. Either the README changed shape or the pin is "
                f"gone; this check cannot tell which, so it refuses rather than passing quietly."
            )

    body = "\n".join(rendered)
    before, marker, rest = body.partition(BEGIN_MARKER)
    inner, end_marker, after = rest.partition(END_MARKER)
    if not marker or not end_marker:
        raise CheckFailed(
            f"{README_PATH} has no {BEGIN_MARKER} … {END_MARKER} region for the generated release "
            f"table."
        )
    if BEGIN_MARKER in after or END_MARKER in inner:
        raise CheckFailed(f"{README_PATH} has more than one generated release-table region.")
    table = "\n".join(release_table(manifest))
    return f"{before}{BEGIN_MARKER}\n{table}\n{END_MARKER}{after}"


def check_readme(manifest: dict, write: bool) -> None:
    try:
        readme = README_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise CheckFailed(f"{README_PATH} is missing") from None

    rendered = render_readme(manifest, readme)
    if rendered == readme:
        return
    if write:
        README_PATH.write_text(rendered, encoding="utf-8")
        print(f"release-manifest — rewrote {README_PATH.name} from {MANIFEST_PATH.name}.")
        return
    diff = "\n".join(
        difflib.unified_diff(
            readme.split("\n"),
            rendered.split("\n"),
            fromfile=f"{README_PATH.name} (committed)",
            tofile=f"{README_PATH.name} (from {MANIFEST_PATH.name})",
            lineterm="",
        )
    )
    raise CheckFailed(
        f"{README_PATH.name} restates versions {MANIFEST_PATH.name} does not agree with. The "
        f"manifest is the source — edit it, then run "
        f"`python3 scripts/check_release_manifest.py --write`:\n{diff}"
    )


def check_tag(manifest: dict, tag: str) -> None:
    """The tag being built is the version the manifest and changelog just published."""
    match = TAG_RE.match(tag)
    if not match:
        raise CheckFailed(f"{tag!r} is not a vX.Y.Z release tag")
    version = match.group(1)
    if version != manifest["latest"]:
        raise CheckFailed(
            f"tag {tag} was pushed, but {MANIFEST_PATH.name} publishes {manifest['latest']} as its "
            f"newest release. A tag ships its manifest entry and its changelog entry, in the "
            f"commit it tags — not in a follow-up. Add the {version} entry to "
            f"{MANIFEST_PATH.name} and {CHANGELOG_PATH.name}, re-tag, and push again."
        )


# ---------------------------------------------------------------------------
# The selftest: watching the detector fail
# ---------------------------------------------------------------------------
#
# A checker nobody has watched reject something is a hypothesis, not a gate — and "a rule with
# nothing enforcing it" is this repo family's characteristic defect, the very one the manifest
# exists to close. So the check is itself checked: `--selftest` stages synthetic module trees in
# a temporary directory, runs THIS script against each as a subprocess (the real entry point,
# the real exit code — the thing CI depends on), and asserts both halves of the claim:
#
#   * a well-formed release passes, so a checker that rejected everything would not sneak through;
#   * each way a release can be wrong is rejected, AND rejected with the message that names that
#     particular fault, so a scenario failing for an unrelated reason does not read as proof.
#
# The fixtures are synthetic on purpose. They share no value with this repo's own MANIFEST.json:
# a selftest carrying a copy of the real version would be the transcription defect again, one
# layer up. Every expected string below is derived from the fixture it is asserted against.

FIXTURE_MANIFEST: dict = {
    "schema_version": SCHEMA_VERSION,
    "module": "example-org/example/azurerm",
    "latest": "2.1.0",
    "releases": {
        "2.0.0": {
            "date": "2026-01-05",
            "images": {
                "api": "registry.example.invalid/api:v1.0.0",
                "frontend": "registry.example.invalid/frontend:v1.0.0",
            },
        },
        "2.1.0": {
            "date": "2026-02-06",
            "images": {
                "api": "registry.example.invalid/api:v1.1.0",
                "frontend": "registry.example.invalid/frontend:v1.1.0",
            },
        },
    },
}

FIXTURE_CHANGELOG = """# Changelog (fixture)

## [Unreleased]

## [2.1.0] - 2026-02-06

### Added

- a fixture entry.

## [2.0.0] - 2026-01-05

### Added

- a fixture entry.
"""

# Deliberately stale pins: rendering the skeleton from the fixture manifest is what produces the
# canonical README, which proves the renderer is what the "passes" case is measured against.
FIXTURE_README_SKELETON = """# Fixture module

```hcl
module "example" {
  source              = "example-org/example/azurerm"
  version             = "~> 0.0"
  api_image           = "stale.example.invalid/api:v0.0.0"
  frontend_image      = "stale.example.invalid/frontend:v0.0.0"
}
```

<!-- release-manifest:begin -->
<!-- release-manifest:end -->

Trailing prose.
"""


def _stage(root: Path, manifest, changelog, readme) -> dict:
    """Write one synthetic module tree and return the environment that points the script at it."""
    manifest_path = root / "MANIFEST.json"
    changelog_path = root / "CHANGELOG.md"
    readme_path = root / "README.md"
    if manifest is not None:
        manifest_path.write_text(
            manifest if isinstance(manifest, str) else json.dumps(manifest, indent=2),
            encoding="utf-8",
        )
    if changelog is not None:
        changelog_path.write_text(changelog, encoding="utf-8")
    if readme is not None:
        readme_path.write_text(readme, encoding="utf-8")
    env = dict(os.environ)
    env.pop("RELEASE_TAG", None)
    env["RELEASE_MANIFEST_PATH"] = str(manifest_path)
    env["RELEASE_CHANGELOG_PATH"] = str(changelog_path)
    env["RELEASE_README_PATH"] = str(readme_path)
    return env


def _mutated(**changes):
    """A deep copy of the fixture manifest with `changes` applied to the top level."""
    manifest = copy.deepcopy(FIXTURE_MANIFEST)
    manifest.update(changes)
    return manifest


def _without_release_key(version: str, key: str):
    manifest = copy.deepcopy(FIXTURE_MANIFEST)
    del manifest["releases"][version][key]
    return manifest


def _with_image(version: str, name: str, value: str):
    manifest = copy.deepcopy(FIXTURE_MANIFEST)
    manifest["releases"][version]["images"][name] = value
    return manifest


def _swapped_images(version: str):
    manifest = copy.deepcopy(FIXTURE_MANIFEST)
    images = manifest["releases"][version]["images"]
    images["api"], images["frontend"] = images["frontend"], images["api"]
    return manifest


def _selftest_scenarios(canonical_readme: str) -> list[tuple]:
    """(name, manifest, changelog, readme, args, expected_exit, expected_message_fragment)."""
    newest = FIXTURE_MANIFEST["latest"]
    older = min(FIXTURE_MANIFEST["releases"], key=semver)
    newest_entry = FIXTURE_MANIFEST["releases"][newest]
    base = FIXTURE_MANIFEST
    log = FIXTURE_CHANGELOG
    ok = canonical_readme

    return [
        # The two that must PASS. Without them, a checker that rejected everything would look
        # like a perfect gate.
        ("a well-formed release passes", base, log, ok, [], 0, base["module"]),
        (
            "a well-formed release passes on its own tag",
            base, log, ok, ["--tag", f"v{newest}"], 0, newest,
        ),
        # Criterion: the manifest is MISSING.
        ("the manifest is missing", None, log, ok, [], 1, "is missing"),
        (
            "the manifest is missing on a tag build",
            None, log, ok, ["--tag", f"v{newest}"], 1, "is missing",
        ),
        # Criterion: the manifest is MALFORMED.
        (
            "the manifest is not valid JSON",
            '{"schema_version": 1,', log, ok, [], 1, "not valid JSON",
        ),
        ("the manifest is a JSON array", "[]", log, ok, [], 1, "has no"),
        (
            "the manifest has no 'latest'",
            {k: v for k, v in base.items() if k != "latest"}, log, ok, [], 1, "no 'latest' key",
        ),
        ("the manifest has no releases", _mutated(releases={}), log, ok, [], 1, "non-empty object"),
        (
            "a release entry names no images",
            _without_release_key(newest, "images"), log, ok, [], 1, "no 'images' object",
        ),
        (
            "a release entry has no date",
            _without_release_key(newest, "date"), log, ok, [], 1, "no YYYY-MM-DD",
        ),
        (
            "an image is not registry/repository:tag",
            _with_image(newest, "api", "just-a-name"), log, ok, [], 1, "registry/repository:tag",
        ),
        (
            "the api and frontend images are swapped",
            _swapped_images(newest), log, ok, [], 1, "worse than no manifest",
        ),
        (
            "'latest' is not the highest version present",
            _mutated(latest=older), log, ok, [], 1, "highest version",
        ),
        (
            "'latest' names a release that does not exist",
            _mutated(latest="9.9.9"), log, ok, [], 1, "no release entry",
        ),
        (
            "the schema version is one this script does not speak",
            _mutated(schema_version=SCHEMA_VERSION + 1), log, ok, [], 1, "speaks version",
        ),
        # Criterion: the TAG disagrees with the manifest.
        (
            "the tag is a version the manifest does not publish",
            base, log, ok, ["--tag", "v9.9.9"], 1, f"publishes {newest}",
        ),
        (
            "the tag is behind the manifest",
            base, log, ok, ["--tag", f"v{older}"], 1, f"publishes {newest}",
        ),
        (
            "the tag is not a vX.Y.Z release tag",
            base, log, ok, ["--tag", f"release-{newest}"], 1, "not a vX.Y.Z release tag",
        ),
        # The changelog half of "a release ships both or neither".
        (
            "the changelog has no entry for the released version",
            base, log.replace(f"## [{newest}] - {newest_entry['date']}", "## [old] - not-a-date"),
            ok, [], 1, f"## [{newest}]",
        ),
        (
            "the changelog dates the release differently",
            base,
            log.replace(
                f"## [{newest}] - {newest_entry['date']}", f"## [{newest}] - 1999-12-31"
            ),
            ok, [], 1, "is dated",
        ),
        (
            "the changelog has nowhere to write the next change",
            base, log.replace("## [Unreleased]", ""), ok, [], 1, "no 'Unreleased' section",
        ),
        ("the changelog is missing", base, None, ok, [], 1, "is missing"),
        # The README half.
        (
            "the README restates an image the manifest does not agree with",
            base, log,
            ok.replace(newest_entry["images"]["api"], "drifted.example.invalid/api:v0.0.0"),
            [], 1, "restates versions",
        ),
        (
            "the README no longer carries a pin to keep in step",
            base, log,
            "\n".join(line for line in ok.split("\n") if "api_image" not in line),
            [], 1, "no longer has",
        ),
        (
            "the README lost the generated release table",
            base, log, ok.replace(BEGIN_MARKER, ""), [], 1, "region for the generated release",
        ),
    ]


def selftest() -> int:
    """Run every scenario and report which of them the checker actually caught."""
    scenarios = _selftest_scenarios(render_readme(FIXTURE_MANIFEST, FIXTURE_README_SKELETON))
    failures: list[str] = []

    with tempfile.TemporaryDirectory() as tmp:
        for index, scenario in enumerate(scenarios):
            name, manifest, changelog, readme, args, expected_exit, fragment = scenario
            root = Path(tmp) / f"case-{index:02d}"
            root.mkdir()
            env = _stage(root, manifest, changelog, readme)
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), *args],
                env=env,
                capture_output=True,
                text=True,
            )
            output = result.stdout + result.stderr
            verdict = "ok"
            if result.returncode != expected_exit:
                verdict = (
                    f"expected exit {expected_exit}, got {result.returncode}. Output:\n{output}"
                )
            elif fragment not in output:
                # Right verdict, wrong reason — which would make this scenario prove nothing.
                verdict = f"exited {result.returncode} but never mentioned {fragment!r}:\n{output}"
            if verdict != "ok":
                failures.append(f"{name}: {verdict}")
            print(f"  {'PASS' if verdict == 'ok' else 'FAIL'}  {name}")

    total = len(scenarios)
    if failures:
        print(
            f"\nrelease-manifest selftest — {len(failures)} of {total} scenarios did not "
            f"behave as required:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"\nrelease-manifest selftest — {total} scenarios: a well-formed release passes, and "
        f"every way a release can be missing, malformed or mis-tagged is rejected by name."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--write",
        action="store_true",
        help="rewrite README.md from the manifest instead of failing on the difference",
    )
    parser.add_argument(
        "--tag",
        default=os.environ.get("RELEASE_TAG", ""),
        help="the vX.Y.Z tag being built; also assert it is the manifest's newest release",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run this check against synthetic trees and assert it still rejects the bad ones",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    try:
        manifest = load_manifest()
        check_changelog(manifest)
        check_readme(manifest, args.write)
        if args.tag:
            check_tag(manifest, args.tag)
    except CheckFailed as exc:
        for line in str(exc).split("\n"):
            print(f"release-manifest — {line}", file=sys.stderr)
        return 1

    latest = manifest["releases"][manifest["latest"]]
    print(
        f"release-manifest — {manifest['module']} {manifest['latest']} "
        f"({latest['images']['api']}, {latest['images']['frontend']}) is stated once, in "
        f"{MANIFEST_PATH.name}, and {CHANGELOG_PATH.name} and {README_PATH.name} agree with it."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
