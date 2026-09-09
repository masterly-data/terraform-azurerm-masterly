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
    changelog entry, so a tag cut without them turns the release build red immediately.

It parses both sides. It transcribes nothing: every version and image string it compares is read
out of `MANIFEST.json` or out of the file being checked. A checker carrying its own copy of the
value would be the very defect it exists to catch.

Run:
    python3 scripts/check_release_manifest.py            # check (what CI runs)
    python3 scripts/check_release_manifest.py --write    # regenerate README.md from the manifest
    python3 scripts/check_release_manifest.py --tag v0.15.0

Paths are overridable through the environment (`RELEASE_MANIFEST_PATH`, `RELEASE_CHANGELOG_PATH`,
`RELEASE_README_PATH`), which is how the check is exercised against a mutated copy of the tree
before it is trusted in CI.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

MANIFEST_PATH = Path(os.environ.get("RELEASE_MANIFEST_PATH", REPO_ROOT / "MANIFEST.json"))
CHANGELOG_PATH = Path(os.environ.get("RELEASE_CHANGELOG_PATH", REPO_ROOT / "CHANGELOG.md"))
README_PATH = Path(os.environ.get("RELEASE_README_PATH", REPO_ROOT / "README.md"))

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
    args = parser.parse_args()

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
