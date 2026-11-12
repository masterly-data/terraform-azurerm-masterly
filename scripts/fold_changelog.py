"""Fold the changelog fragments in changelog.d/ into CHANGELOG.md under a release's heading.

Every change used to edit the `## [Unreleased]` section, so any two changes conflicted there. Now a
change adds one file, `changelog.d/<short-name>.md`, and `## [Unreleased]` stays empty. The
release-preparation commit runs this script, which moves every fragment under
`## [X.Y.Z] - YYYY-MM-DD`, directly below `## [Unreleased]`, merges the subsections in a fixed
order (Added, Changed, Deprecated, Removed, Fixed, Security, Documentation) and deletes the
fragments it folded. It is a local, offline step of that commit: no workflow runs it and none
gains a write path. `scripts/check_release_manifest.py --tag` refuses a tree that still has a
fragment, so a version cannot go out with changes its notes do not list.

A fragment holds only `### <Type>` subsections with their body (see changelog.d/README.md). The
fold refuses, names the file, and writes nothing when:

  * a fragment has an unknown `###` heading, text outside a subsection, an empty subsection, or
    a heading of another level;
  * changelog.d/ holds a file that is neither a `.md` fragment nor the README / .gitkeep
    placeholder, because the tag check would refuse it and the fold would not remove it;
  * there is no fragment to fold, or CHANGELOG.md has no `## [Unreleased]` heading, has an entry
    under it, or has more than one `## [X.Y.Z]` heading.

Re-cut: when a `## [X.Y.Z]` heading already exists (a candidate that was merged but never tagged,
README "Cutting a release"), the fragments merge into that section's subsections and its date is
set to DATE; no second heading is made. Every check runs, and the new text is built and verified
(each fragment line present exactly as often as it was supplied), before anything is written.
Fragments are read in filename order, so the output is deterministic. The reference links at the
foot of CHANGELOG.md are not touched.

Run:
    python3 scripts/fold_changelog.py X.Y.Z YYYY-MM-DD
    python3 scripts/fold_changelog.py --selftest      # it still refuses what it should

The paths are overridable through `RELEASE_CHANGELOG_PATH` and `RELEASE_CHANGELOG_DIR`, as for
`scripts/check_release_manifest.py`. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHANGELOG_PATH = Path(os.environ.get("RELEASE_CHANGELOG_PATH", REPO_ROOT / "CHANGELOG.md"))
FRAGMENT_DIR = Path(os.environ.get("RELEASE_CHANGELOG_DIR", REPO_ROOT / "changelog.d"))

PLACEHOLDERS = {"README.md", ".gitkeep"}
# The order a folded section lists its subsections in: Keep a Changelog's six, then the
# `Documentation` this changelog has always used.
SUBSECTIONS = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security", "Documentation"]

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
UNRELEASED_RE = re.compile(r"^##\s*\[?Unreleased\]?", re.IGNORECASE)
SECTION_RE = re.compile(r"^## ")
LINK_DEFINITION_RE = re.compile(r"^\[[^\]]+\]:\s")
SUBSECTION_RE = re.compile(r"^###\s+(?P<name>.*?)\s*$")
HEADING_RE = re.compile(r"^#{1,6}\s")


class FoldFailed(Exception):
    """A reason to write nothing, phrased for whoever has to fix it."""


def parse_fragment(name: str, text: str) -> dict[str, list[str]]:
    """The fragment's `### <Type>` subsections, each as its body lines (blank edges trimmed)."""
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for number, line in enumerate(text.split("\n"), start=1):
        sub = SUBSECTION_RE.match(line)
        if sub:
            current = sub.group("name")
            if current not in SUBSECTIONS:
                raise FoldFailed(
                    f"{name}:{number}: unknown subsection '### {current}'. A fragment may hold "
                    f"only {', '.join('### ' + s for s in SUBSECTIONS)}."
                )
            sections.setdefault(current, [])
            continue
        if HEADING_RE.match(line):
            raise FoldFailed(
                f"{name}:{number}: {line.strip()!r} is a heading a fragment may not hold; "
                f"only '### <Type>' subsections are allowed."
            )
        if current is None:
            if line.strip():
                raise FoldFailed(
                    f"{name}:{number}: text outside a subsection. A fragment is '### <Type>' "
                    f"subsections with their body, nothing before the first one."
                )
            continue
        sections[current].append(line)
    if not sections:
        raise FoldFailed(f"{name}: has no '### <Type>' subsection, so there is nothing to fold.")
    for current, body in sections.items():
        sections[current] = _trim(body)
        if not sections[current]:
            raise FoldFailed(f"{name}: subsection '### {current}' is empty.")
    return sections


def _trim(lines: list[str]) -> list[str]:
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    return lines[start:end]


def load_fragments() -> list[tuple[str, dict[str, list[str]]]]:
    if not FRAGMENT_DIR.is_dir():
        raise FoldFailed(f"{FRAGMENT_DIR} is missing, so there is no fragment to fold.")
    paths = sorted(
        (path for path in FRAGMENT_DIR.iterdir() if path.name not in PLACEHOLDERS),
        key=lambda path: path.name,
    )
    for path in paths:
        if not path.is_file() or path.suffix != ".md":
            raise FoldFailed(
                f"{FRAGMENT_DIR.name}/{path.name} is not a '.md' fragment. Remove it or rename "
                f"it: the tag check refuses any file here except README.md and .gitkeep."
            )
    if not paths:
        raise FoldFailed(f"{FRAGMENT_DIR.name}/ holds no fragment, so there is nothing to fold.")
    return [
        (f"{FRAGMENT_DIR.name}/{path.name}", parse_fragment(f"{FRAGMENT_DIR.name}/{path.name}",
                                                            path.read_text(encoding="utf-8")))
        for path in paths
    ]


def _section_end(lines: list[str], start: int) -> int:
    """Index of the first line after `start` that ends the section: a `## ` or a link definition."""
    for index in range(start + 1, len(lines)):
        if SECTION_RE.match(lines[index]) or LINK_DEFINITION_RE.match(lines[index]):
            return index
    return len(lines)


def _render(sections: list[tuple[str, list[str]]]) -> list[str]:
    out: list[str] = []
    for name, body in sections:
        out += [f"### {name}", "", *body, ""]
    return out


def _section_lines(lines: list[str]) -> Counter:
    return Counter(line for line in lines if line.strip())


def fold(changelog: str, fragments: list[tuple[str, dict[str, list[str]]]], version: str,
         date: str) -> str:
    """The changelog with `fragments` folded in under `version`; raises before returning bad text."""
    lines = changelog.split("\n")
    unreleased = [i for i, line in enumerate(lines) if UNRELEASED_RE.match(line)]
    if len(unreleased) != 1:
        raise FoldFailed(
            f"{CHANGELOG_PATH.name} has {len(unreleased)} 'Unreleased' headings; the fold needs "
            f"exactly one, empty, to put the release below."
        )
    u_end = _section_end(lines, unreleased[0])
    if any(line.strip() for line in lines[unreleased[0] + 1:u_end]):
        raise FoldFailed(
            f"{CHANGELOG_PATH.name} has an entry under 'Unreleased'. Move it into a fragment in "
            f"{FRAGMENT_DIR.name}/ first; the fold would otherwise leave it behind."
        )

    heading_re = re.compile(rf"^## \[{re.escape(version)}\](?:\s+-\s+.*)?\s*$")
    existing = [i for i, line in enumerate(lines) if heading_re.match(line)]
    if len(existing) > 1:
        raise FoldFailed(
            f"{CHANGELOG_PATH.name} has {len(existing)} '## [{version}]' headings (lines "
            f"{', '.join(str(i + 1) for i in existing)}). Which one to merge into is not a guess "
            f"the fold makes."
        )

    # Subsections of the section being built, in order; a re-cut starts from the existing ones.
    sections: list[tuple[str, list[str]]] = []
    preamble: list[str] = []
    before: Counter = Counter()
    if existing:
        start = existing[0]
        end = _section_end(lines, start)
        block = lines[start + 1:end]
        before = _section_lines(block)
        current: tuple[str, list[str]] | None = None
        for line in block:
            sub = SUBSECTION_RE.match(line)
            if sub:
                current = (sub.group("name"), [])
                sections.append(current)
            elif current is None:
                preamble.append(line)
            else:
                current[1].append(line)
        sections = [(name, _trim(body)) for name, body in sections]
        preamble = _trim(preamble)

    supplied: Counter = Counter()
    for _, parts in fragments:
        for name, body in parts.items():
            supplied.update(_section_lines(body))
            for index, (existing_name, existing_body) in enumerate(sections):
                if existing_name == name:
                    sections[index] = (name, [*existing_body, *body])
                    break
            else:
                rank = SUBSECTIONS.index(name)
                position = len(sections)
                for index, (other, _) in enumerate(sections):
                    if other in SUBSECTIONS and SUBSECTIONS.index(other) > rank:
                        position = index
                        break
                sections.insert(position, (name, list(body)))

    block = [f"## [{version}] - {date}", ""]
    if preamble:
        block += [*preamble, ""]
    block += _render(sections)

    # A re-cut lifts its old section out and puts the merged one back directly under Unreleased,
    # so the release being prepared is always the newest section.
    if existing:
        lines = lines[:existing[0]] + lines[_section_end(lines, existing[0]):]
    top = unreleased[0]
    below = _section_end(lines, top)
    result = "\n".join([*lines[:top + 1], "", *_trim(block), "", *lines[below:]])

    # Nothing dropped, nothing duplicated: the new section holds each line the fragments supplied
    # exactly as often as it was supplied, plus what a re-cut already had.
    verify(result, version, supplied + before)
    return result


def verify(result: str, version: str, expected: Counter) -> None:
    """Fail unless `result` has one `## [version]` heading and every expected line, exactly."""
    lines = result.split("\n")
    heading_re = re.compile(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$")
    starts = [i for i, line in enumerate(lines) if heading_re.match(line)]
    if len(starts) != 1:
        raise FoldFailed(f"internal: {len(starts)} '## [{version}]' headings after the fold.")
    got = _section_lines(lines[starts[0] + 1:_section_end(lines, starts[0])])
    got = Counter({k: v for k, v in got.items() if not SUBSECTION_RE.match(k)})
    want = Counter({k: v for k, v in expected.items() if not SUBSECTION_RE.match(k)})
    if got != want:
        missing = want - got
        extra = got - want
        raise FoldFailed(
            f"internal: the folded section does not hold the fragments' lines exactly once; "
            f"missing {dict(missing)}, duplicated or unexpected {dict(extra)}. Nothing written."
        )


def run(version: str, date: str) -> list[Path]:
    if not VERSION_RE.match(version):
        raise FoldFailed(f"{version!r} is not a version (X.Y.Z).")
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        raise FoldFailed(f"{date!r} is not a date (YYYY-MM-DD).") from None
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        raise FoldFailed(f"{date!r} is not a date (YYYY-MM-DD).")
    try:
        changelog = CHANGELOG_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise FoldFailed(f"{CHANGELOG_PATH} is missing") from None
    fragments = load_fragments()
    result = fold(changelog, fragments, version, date)
    # Every check has passed. Write the changelog (replace, so a failure leaves the old one),
    # then delete the fragments it now holds.
    temp = CHANGELOG_PATH.with_name(CHANGELOG_PATH.name + ".fold-tmp")
    temp.write_text(result, encoding="utf-8")
    temp.replace(CHANGELOG_PATH)
    folded = [FRAGMENT_DIR / name.split("/", 1)[1] for name, _ in fragments]
    for path in folded:
        path.unlink()
    return folded


# --- selftest ---------------------------------------------------------------------------------

FIXTURE_CHANGELOG = """# Changelog (fixture)

Preamble.

## [Unreleased]

## [1.0.0] - 2031-01-01

### Added

- The first release.

[Unreleased]: https://example.invalid/compare/v1.0.0...HEAD
[1.0.0]: https://example.invalid/releases/tag/v1.0.0
"""

RECUT_CHANGELOG = """# Changelog (fixture)

## [Unreleased]

## [1.1.0] - 2031-02-01

### Added

- Already there.

### Fixed

- Old fix.

## [1.0.0] - 2031-01-01

### Added

- The first release.

[Unreleased]: https://example.invalid/compare/v1.0.0...HEAD
"""

FRAGMENTS = {
    "b-fix.md": "### Fixed\n\n- Fix one.\n- Fix two,\n  continued.\n",
    "a-add.md": "### Added\n\n- Add one.\n\n### Documentation\n\n- Doc one.\n",
    "c-more.md": "### Added\n\n- Add two.\n",
}
FOLD_ARGS = ["1.1.0", "2031-02-01"]


def _bullets() -> list[str]:
    return ["- Add one.", "- Add two.", "- Fix one.", "- Fix two,", "  continued.", "- Doc one."]


def _tree(root: Path, changelog: str, fragments: dict[str, str]) -> dict:
    (root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
    fragment_dir = root / "changelog.d"
    fragment_dir.mkdir()
    for name, body in fragments.items():
        (fragment_dir / name).write_text(body, encoding="utf-8")
    return dict(os.environ, RELEASE_CHANGELOG_PATH=str(root / "CHANGELOG.md"),
                RELEASE_CHANGELOG_DIR=str(fragment_dir))


def _snapshot(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): path.read_text(encoding="utf-8")
        for path in sorted(root.rglob("*")) if path.is_file()
    }


def _run(env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(Path(__file__).resolve()), *args], env=env,
                          capture_output=True, text=True)


def _check_fold(root: Path, expect_old: bool) -> str | None:
    """None if the tree holds the folded result as required, else why not."""
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    lines = text.split("\n")
    headings = [i for i, line in enumerate(lines) if line.startswith("## [1.1.0]")]
    if len(headings) != 1:
        return f"{len(headings)} '## [1.1.0]' headings"
    if lines[headings[0]] != "## [1.1.0] - 2031-02-01":
        return f"heading is {lines[headings[0]]!r}"
    unreleased = lines.index("## [Unreleased]")
    if lines[unreleased + 1:headings[0]] != [""]:
        return "the section is not directly below an empty Unreleased"
    for bullet in _bullets():
        count = text.count(bullet + "\n")
        if count != 1:
            return f"{bullet!r} appears {count} times"
    order = [text.index(f"### {name}") for name in ("Added", "Fixed", "Documentation")]
    if order != sorted(order):
        return "subsections are not in Added, Fixed, Documentation order"
    if expect_old and (text.count("- Already there.") != 1 or text.count("- Old fix.") != 1):
        return "the re-cut lost or doubled an existing line"
    left = [p.name for p in (root / "changelog.d").iterdir() if p.name in FRAGMENTS]
    if left:
        return f"fragments left on disk: {left}"
    if "[1.0.0]: https://example.invalid/releases/tag/v1.0.0" not in text and not expect_old:
        return "the reference links were touched"
    if not text.endswith("\n"):
        return "no trailing newline"
    return None


def _refusal(name: str, changelog: str, fragments: dict[str, str], args: list[str],
             named: str, message: str) -> tuple[str, callable]:
    def scenario(root: Path) -> str | None:
        env = _tree(root, changelog, fragments)
        before = _snapshot(root)
        result = _run(env, *args)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            return f"exited 0:\n{output}"
        if named not in output or message not in output:
            return f"exit {result.returncode} without {named!r} and {message!r}:\n{output}"
        if _snapshot(root) != before:
            return "the tree changed although the fold refused"
        return None
    return name, scenario


def _scenarios() -> list[tuple[str, callable]]:
    def fresh(root: Path) -> str | None:
        env = _tree(root, FIXTURE_CHANGELOG, {**FRAGMENTS, "README.md": "How.\n", ".gitkeep": ""})
        result = _run(env, *FOLD_ARGS)
        if result.returncode != 0:
            return f"exit {result.returncode}:\n{result.stdout}{result.stderr}"
        placeholders = (root / "changelog.d" / "README.md").exists() and (
            root / "changelog.d" / ".gitkeep").exists()
        return _check_fold(root, False) or (None if placeholders else "a placeholder was deleted")

    def recut(root: Path) -> str | None:
        env = _tree(root, RECUT_CHANGELOG.replace("2031-02-01", "2031-01-20"), FRAGMENTS)
        result = _run(env, *FOLD_ARGS)
        if result.returncode != 0:
            return f"exit {result.returncode}:\n{result.stdout}{result.stderr}"
        text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
        if "2031-01-20" in text:
            return "the old date survived"
        return _check_fold(root, True)

    def detector(root: Path) -> str | None:
        # The check above must itself fail on a dropped, a duplicated and a left-behind fragment.
        env = _tree(root, FIXTURE_CHANGELOG, FRAGMENTS)
        _run(env, *FOLD_ARGS)
        good = (root / "CHANGELOG.md").read_text(encoding="utf-8")
        for label, bad in (("dropped", good.replace("- Add two.\n", "", 1)),
                           ("duplicated", good.replace("- Fix one.\n", "- Fix one.\n- Fix one.\n", 1))):
            (root / "CHANGELOG.md").write_text(bad, encoding="utf-8")
            if _check_fold(root, False) is None:
                return f"a {label} fragment line went unnoticed"
        (root / "CHANGELOG.md").write_text(good, encoding="utf-8")
        (root / "changelog.d" / "a-add.md").write_text("x", encoding="utf-8")
        if _check_fold(root, False) is None:
            return "a fragment left on disk went unnoticed"
        lines = good.split("\n")
        start = lines.index("## [1.1.0] - 2031-02-01")
        expected = _section_lines(lines[start + 1:_section_end(lines, start)])
        try:
            verify(good, "1.1.0", expected)
        except FoldFailed as exc:
            return f"verify() refused an intact section: {exc}"
        try:
            verify(good.replace("- Doc one.\n", "", 1), "1.1.0", expected)
        except FoldFailed:
            return None
        return "verify() accepted a section that lost a line"

    unreleased_entry = FIXTURE_CHANGELOG.replace(
        "## [Unreleased]\n", "## [Unreleased]\n\n### Added\n\n- Written in the wrong place.\n")
    return [
        ("fragments fold below an empty Unreleased, in order, each line once, then are deleted",
         fresh),
        ("a re-cut merges into the existing section and sets its date", recut),
        ("the fold's own check catches a dropped, duplicated or left-behind fragment", detector),
        _refusal("an unknown subsection heading is refused", FIXTURE_CHANGELOG,
                 {**FRAGMENTS, "d-bad.md": "### Misc\n\n- Nope.\n"}, FOLD_ARGS,
                 "changelog.d/d-bad.md", "unknown subsection"),
        _refusal("text outside a subsection is refused", FIXTURE_CHANGELOG,
                 {**FRAGMENTS, "d-bad.md": "Intro.\n\n### Added\n\n- Nope.\n"}, FOLD_ARGS,
                 "changelog.d/d-bad.md", "outside a subsection"),
        _refusal("an empty subsection is refused", FIXTURE_CHANGELOG,
                 {"d-bad.md": "### Added\n\n### Fixed\n\n- Fine.\n"}, FOLD_ARGS,
                 "changelog.d/d-bad.md", "is empty"),
        _refusal("another heading level is refused", FIXTURE_CHANGELOG,
                 {"d-bad.md": "## [9.9.9] - 2031-01-01\n\n### Added\n\n- Nope.\n"}, FOLD_ARGS,
                 "changelog.d/d-bad.md", "may not hold"),
        _refusal("a stray file in changelog.d/ is refused", FIXTURE_CHANGELOG,
                 {**FRAGMENTS, "notes.txt": "x"}, FOLD_ARGS, "changelog.d/notes.txt",
                 "not a '.md' fragment"),
        _refusal("an entry left under Unreleased is refused", unreleased_entry, FRAGMENTS,
                 FOLD_ARGS, "Unreleased", "Move it into a fragment"),
        _refusal("nothing to fold is refused", FIXTURE_CHANGELOG, {"README.md": "How.\n"},
                 FOLD_ARGS, "changelog.d/", "nothing to fold"),
        _refusal("a bad date is refused", FIXTURE_CHANGELOG, FRAGMENTS, ["1.1.0", "31-02-01"],
                 "31-02-01", "not a date"),
        _refusal("a bad version is refused", FIXTURE_CHANGELOG, FRAGMENTS, ["v1.1", "2031-02-01"],
                 "v1.1", "not a version"),
    ]


def selftest() -> int:
    scenarios = _scenarios()
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        for index, (name, scenario) in enumerate(scenarios):
            root = Path(tmp) / f"case-{index:02d}"
            root.mkdir()
            verdict = scenario(root)
            if verdict:
                failures.append(f"{name}: {verdict}")
            print(f"  {'PASS' if verdict is None else 'FAIL'}  {name}")
    if failures:
        print(f"\nfold-changelog selftest — {len(failures)} of {len(scenarios)} scenarios did not "
              f"behave as required:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"\nfold-changelog selftest — {len(scenarios)} scenarios: fragments fold whole, once and "
          f"in order, and anything that would drop one is refused before a byte is written.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("version", nargs="?", help="the release: X.Y.Z")
    parser.add_argument("date", nargs="?", help="the release date: YYYY-MM-DD")
    parser.add_argument("--selftest", action="store_true",
                        help="fold synthetic trees and assert the bad cases are still refused")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.version or not args.date:
        parser.error("a version and a date are required")
    try:
        folded = run(args.version, args.date)
    except FoldFailed as exc:
        print(f"fold-changelog — {exc}", file=sys.stderr)
        print("fold-changelog — nothing was written.", file=sys.stderr)
        return 1
    print(f"fold-changelog — folded {len(folded)} fragment(s) into {CHANGELOG_PATH.name} under "
          f"{args.version} and deleted them: {', '.join(p.name for p in folded)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
