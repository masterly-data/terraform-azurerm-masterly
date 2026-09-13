"""Print the CHANGELOG.md section for one released version: the body of its GitHub Release.

A tag on this repository publishes the module to the Terraform Registry, which has no place for
release notes. The GitHub Release page is where a reader looks for what a version changed, so the
tag build creates one, and its body is this script's output — the changelog section written for
that version, never a second account of it typed somewhere else (MAS-258).

The section is found by its exact heading, `## [X.Y.Z] - YYYY-MM-DD`, and runs to the next `## `
heading or to the link definitions at the foot of the file. The script fails, rather than printing
something plausible, when:

  * the version is not X.Y.Z (with or without a leading `v`) — `Unreleased` in particular is never
    published, because a section still being written is not a release;
  * the changelog has no heading for the version, or has more than one;
  * the section has a heading and nothing under it.

Relative links in a changelog resolve against the repository, but a release body is rendered on
the release page, where the same link points nowhere. `--link-base` rewrites them against a fixed
URL — the workflow passes the tagged tree, so a link reads the file as it was at that release.

`--is-newest` answers the other question the release step has: whether this version should be
marked as the repository's latest release. It reads tag names on stdin and prints `true` only when
no X.Y.Z tag among them is higher. A patch tagged for an older line after a newer release exists
is published, but not as the latest.

Run:
    python3 scripts/release_notes.py vX.Y.Z                      # the section, as markdown
    python3 scripts/release_notes.py vX.Y.Z --link-base URL      # ... with relative links rewritten
    git tag -l | python3 scripts/release_notes.py vX.Y.Z --is-newest
    python3 scripts/release_notes.py --selftest                  # it still refuses what it should

The changelog path is overridable through `RELEASE_CHANGELOG_PATH`, as for
`scripts/check_release_manifest.py`. Standard library only.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHANGELOG_PATH = Path(os.environ.get("RELEASE_CHANGELOG_PATH", REPO_ROOT / "CHANGELOG.md"))

VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
ANY_SECTION_RE = re.compile(r"^## ")
# A link definition at the foot of a Keep a Changelog file: `[0.8.0]: https://...`.
LINK_DEFINITION_RE = re.compile(r"^\[[^\]]+\]:\s")
# An inline markdown link target: the `(target)` after `[text]`. Targets with spaces are not
# used in this changelog and are left alone.
INLINE_LINK_RE = re.compile(r"\]\((?P<target>[^()\s]+)\)")
ABSOLUTE_TARGET_RE = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|/)")


class NotesFailed(Exception):
    """A reason not to publish, phrased for whoever has to fix it."""


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_RE.match(value.strip())
    if not match:
        raise NotesFailed(
            f"{value!r} is not a released version (X.Y.Z, optionally with a leading 'v'). "
            f"Only a version with its own dated changelog heading is published; 'Unreleased' "
            f"never is."
        )
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def section(changelog: str, version: str) -> str:
    """The body under `## [version] - YYYY-MM-DD`, with surrounding blank lines trimmed."""
    heading_re = re.compile(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$")
    lines = changelog.split("\n")
    starts = [index for index, line in enumerate(lines) if heading_re.match(line)]
    if not starts:
        raise NotesFailed(
            f"{CHANGELOG_PATH.name} has no '## [{version}] - YYYY-MM-DD' heading. A release is "
            f"published with the changelog section written for it, so there is nothing to "
            f"publish: add the section in a commit on main, and tag that commit."
        )
    if len(starts) > 1:
        raise NotesFailed(
            f"{CHANGELOG_PATH.name} has {len(starts)} '## [{version}]' headings (lines "
            f"{', '.join(str(start + 1) for start in starts)}). Which one is the release is not "
            f"a guess this script makes."
        )

    body: list[str] = []
    for line in lines[starts[0] + 1:]:
        if ANY_SECTION_RE.match(line) or LINK_DEFINITION_RE.match(line):
            break
        body.append(line)
    text = "\n".join(body).strip("\n")
    if not text.strip():
        raise NotesFailed(
            f"{CHANGELOG_PATH.name} has a '## [{version}]' heading with nothing under it. An "
            f"empty release page says the version changed nothing, which is never true of a tag."
        )
    return text + "\n"


def rewrite_links(text: str, base: str) -> str:
    """Point relative link targets at `base`, which should end in `/`."""

    def replace(match: re.Match) -> str:
        target = match.group("target")
        if ABSOLUTE_TARGET_RE.match(target):
            return match.group(0)
        return f"]({base}{target})"

    return INLINE_LINK_RE.sub(replace, text)


def is_newest(version: str, tags: list[str]) -> bool:
    mine = parse_version(version)
    released = [VERSION_RE.match(tag.strip()) for tag in tags]
    return all(
        (int(m.group(1)), int(m.group(2)), int(m.group(3))) <= mine for m in released if m
    )


# --- selftest ---------------------------------------------------------------------------------

FIXTURE_CHANGELOG = """# Changelog (fixture)

Preamble that must never reach a release body. See [the README](README.md#cutting-a-release).

## [Unreleased]

### Added

- Something not yet released.

## [2.0.0] - 2031-02-02

### Changed

- A breaking change, documented in [docs/upgrade.md](docs/upgrade.md) and
  [the registry](https://registry.terraform.io/) and [below](#fixed).

### Fixed

- A fix.

## [1.1.0] - 2031-01-15

## [0.9.0] - 2030-12-01

- Listed twice by mistake.

## [0.9.0] - 2030-12-02

- Listed twice by mistake.

## [1.0.0] - 2031-01-01

### Added

- The first release.

[Unreleased]: https://example.invalid/compare/v2.0.0...HEAD
[2.0.0]: https://example.invalid/releases/tag/v2.0.0
[1.0.0]: https://example.invalid/releases/tag/v1.0.0
"""

LINK_BASE = "https://example.invalid/blob/v2.0.0/"


def _selftest_scenarios() -> list[tuple]:
    """(name, args, stdin, expected exit, fragment that must appear, fragment that must not)."""
    return [
        ("a version's section is printed", ["v2.0.0"], "", 0, "- A breaking change", None),
        ("the leading 'v' is optional", ["2.0.0"], "", 0, "### Fixed", None),
        ("the section stops at the next heading", ["2.0.0"], "", 0, "- A fix.", "first release"),
        ("the last section stops at the link definitions", ["1.0.0"], "", 0,
         "- The first release.", "example.invalid/releases"),
        ("the heading itself is not part of the body", ["2.0.0"], "", 0, "### Changed",
         "## [2.0.0]"),
        ("relative links are rewritten against --link-base",
         ["2.0.0", "--link-base", LINK_BASE], "", 0, f"]({LINK_BASE}docs/upgrade.md)", None),
        ("absolute links and anchors are left alone",
         ["2.0.0", "--link-base", LINK_BASE], "", 0,
         "](https://registry.terraform.io/) and [below](#fixed)", f"{LINK_BASE}#fixed"),
        ("a version with no heading is refused", ["3.0.0"], "", 1, "no '## [3.0.0]", None),
        ("a partial version is refused", ["2.0"], "", 1,
         "not a released version", None),
        ("Unreleased is never published", ["Unreleased"], "", 1, "'Unreleased' never is", None),
        ("an empty section is refused", ["1.1.0"], "", 1, "nothing under it", None),
        ("a duplicated heading is refused", ["0.9.0"], "", 1, "2 '## [0.9.0]' headings", None),
        ("the highest tag is the newest", ["v2.0.0", "--is-newest"],
         "v0.9.0\nv1.0.0\nv2.0.0\nnot-a-release\n", 0, "true", "false"),
        ("an older line's patch is not the newest", ["v1.0.1", "--is-newest"],
         "v1.0.0\nv2.0.0\nv1.0.1\n", 0, "false", "true"),
        ("--is-newest still refuses a non-version", ["Unreleased", "--is-newest"], "v1.0.0\n", 1,
         "not a released version", None),
    ]


def selftest() -> int:
    scenarios = _selftest_scenarios()
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        changelog = Path(tmp) / "CHANGELOG.md"
        changelog.write_text(FIXTURE_CHANGELOG, encoding="utf-8")
        env = dict(os.environ, RELEASE_CHANGELOG_PATH=str(changelog))
        for name, args, stdin, expected_exit, present, absent in scenarios:
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), *args],
                env=env,
                input=stdin,
                capture_output=True,
                text=True,
            )
            output = result.stdout + result.stderr
            verdict = "ok"
            if result.returncode != expected_exit:
                verdict = f"expected exit {expected_exit}, got {result.returncode}:\n{output}"
            elif present not in output:
                # Right verdict, wrong reason — which would make the scenario prove nothing.
                verdict = f"exited {result.returncode} but never printed {present!r}:\n{output}"
            elif absent is not None and absent in output:
                verdict = f"printed {absent!r}, which must not be there:\n{output}"
            if verdict != "ok":
                failures.append(f"{name}: {verdict}")
            print(f"  {'PASS' if verdict == 'ok' else 'FAIL'}  {name}")

    if failures:
        print(
            f"\nrelease-notes selftest — {len(failures)} of {len(scenarios)} scenarios did not "
            f"behave as required:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"\nrelease-notes selftest — {len(scenarios)} scenarios: a version's section is extracted "
        f"whole and alone, and a missing, empty, duplicated or unreleased section is refused."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("version", nargs="?", help="the release: vX.Y.Z or X.Y.Z")
    parser.add_argument(
        "--link-base",
        default="",
        help="URL, ending in '/', that relative link targets in the section are rewritten against",
    )
    parser.add_argument(
        "--is-newest",
        action="store_true",
        help="read tag names on stdin; print 'true' if no X.Y.Z tag is higher, else 'false'",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run against a synthetic changelog and assert the bad cases are still refused",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not args.version:
        parser.error("a version is required")

    try:
        major, minor, patch = parse_version(args.version)
        version = f"{major}.{minor}.{patch}"
        if args.is_newest:
            print("true" if is_newest(version, sys.stdin.read().split()) else "false")
            return 0
        try:
            changelog = CHANGELOG_PATH.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise NotesFailed(f"{CHANGELOG_PATH} is missing") from None
        notes = section(changelog, version)
        if args.link_base:
            notes = rewrite_links(notes, args.link_base)
    except NotesFailed as exc:
        print(f"release-notes — {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(notes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
