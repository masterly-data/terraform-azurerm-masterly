"""Turn a version's customer summary into release-note text, and keep that text honest.

At Stable the release notes carry the evidence summary (docs/customer-summary.md). The tag goes on
the release-cut commit, which was fixed before any Stable evidence existed, so the summary arrives
on `main` after the tag, in a reviewed pull request, and the evidence reaches readers in two places:

  * CHANGELOG.md on `main`: a block between fixed markers, at the end of the version's
    `## [X.Y.Z]` section, written by `--write` and compared by `--check`;
  * the GitHub Release body: the tag's own CHANGELOG section followed by the same block. The tag
    build's `release` job (`--compose`) and the post-tag workflow (`--post-tag`) build it with the
    same code, so a re-run of either gives the same bytes.

The block is generated ONLY from the committed summary: ring dates, gates passed, the versions an
upgrade was verified from, performance per profile against the baseline version, and the security
counts by severity. Nothing is typed in here, and nothing is read from anywhere else.

The summary is public and comes from private test evidence, so every mode runs the customer-summary
contract (scripts/check_customer_summary.py: shape, redaction, counts-only `sec`) before it renders
anything, and refuses with a non-zero exit, a reason on stderr and nothing on stdout when it fails.
A gate name is also refused unless it is plain words, since it is the one free-text field and
would otherwise be spliced into markdown.

Run:
    python3 scripts/release_evidence.py --render X.Y.Z      # the block, on stdout
    python3 scripts/release_evidence.py --write X.Y.Z       # put it in CHANGELOG.md (after the tag)
    python3 scripts/release_evidence.py --check             # every summary has exactly its block
    python3 scripts/release_evidence.py --compose X.Y.Z [--optional] [--link-base URL]
    python3 scripts/release_evidence.py --post-tag X.Y.Z --tags-file FILE [--changelog FILE]
    python3 scripts/release_evidence.py --selftest

Paths default to MANIFEST.json, customer-summary/ and CHANGELOG.md (the environment overrides of
the other release scripts apply) and can be given with --manifest, --summary-dir and --changelog.
Standard library only, no network call.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_customer_summary as contract  # noqa: E402
import release_notes  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve()
EXPECTED_BLOCK = REPO_ROOT / "tests" / "release_evidence" / "expected-block.md"

VERSION_ARG = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
HEADING_RE = re.compile(r"^## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*$")
MARKER_RE = re.compile(r"^<!-- customer-evidence:(start|end) (\S+) -->\s*$")
# A gate name is the one free-text field of the summary. Plain words only: no markup, no newline.
GATE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:+/-]{0,79}$")
SUMMARY_URL = ("https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/"
               "main/customer-summary/{version}.json")


class Refused(Exception):
    """A reason to publish nothing, phrased for whoever has to fix it."""


# --- the summary ------------------------------------------------------------------------------

def check_version(value: str) -> str:
    if not VERSION_ARG.match(value):
        raise Refused(f"{value!r} is not a version (X.Y.Z, no leading 'v').")
    return value


def load_summary(version: str, manifest: Path, directory: Path) -> dict:
    """The checked summary of `version`; anything the contract refuses is refused here."""
    check_version(version)
    path = directory / f"{version}.json"
    name = f"{directory.name}/{path.name}"
    if not path.is_file():
        raise Refused(f"there is no customer summary for {version}: {name} is missing. It is "
                      f"added to main after the tag, by a reviewed pull request (docs/releasing.md).")
    releases = contract.load_releases(manifest)
    if isinstance(releases, str):
        raise Refused(releases)
    try:
        document = json.loads(path.read_text(encoding="utf-8"),
                              parse_constant=contract._reject_constant,
                              object_pairs_hook=contract._reject_duplicates)
    except (OSError, ValueError) as exc:
        raise Refused(f"{name}: not valid JSON ({exc}).") from None
    if not isinstance(document, dict):
        raise Refused(f"{name}: the top level must be a JSON object.")
    errors = contract.shape_errors(name, path.name, document, releases)
    errors += contract.redaction_errors(name, document)
    if errors:
        raise Refused(f"{name} fails the customer-summary contract, so nothing is rendered:\n  "
                      + "\n  ".join(errors))
    if document["version"] != version:
        raise Refused(f"{name} names version {document['version']}, not {version}.")
    for gate in document["gates_passed"]:
        if not GATE_RE.match(gate):
            raise Refused(f"{name}: gate name {gate!r} is not plain words (letters, digits, "
                          f"spaces and . _ : + / -), so it is not published into release notes.")
    return document


def number(value) -> str:
    if isinstance(value, int):
        return str(value)
    return format(Decimal(repr(value)), "f")


def render(document: dict) -> str:
    """The evidence block for a checked summary, markers included, ending in a newline."""
    version = document["version"]
    ring = document["ring"]
    gates = ", ".join(f"`{gate}`" for gate in document["gates_passed"]) or "none recorded"
    verified = ", ".join(document["upgrade_verified_from"]) or "none recorded"
    sec = document["sec"]
    lines = [
        f"<!-- customer-evidence:start {version} -->",
        "### Customer evidence",
        "",
        f"What {version} was tested for before it reached the Stable ring, from its "
        f"[customer summary]({SUMMARY_URL.format(version=version)}).",
        "",
        f"- **Rings:** Canary {ring['canary']}, Beta {ring['beta']}, Stable {ring['stable']}",
        f"- **Gates passed:** {gates}",
        f"- **Upgrade verified from:** {verified}",
        "",
    ]
    perf = document["perf"]
    if perf is None:
        lines += ["**Performance:** no previous Stable version to compare with.", ""]
    else:
        lines += [
            f"**Performance**, measured against {perf['baseline']}, the previous Stable version:",
            "",
            "| Profile | p50 (ms) | p95 (ms) | Throughput (requests/s) | Error rate |",
            "|---|---|---|---|---|",
        ]
        for profile in sorted(perf["profiles"]):
            m = perf["profiles"][profile]
            lines.append(f"| {profile} | {number(m['p50_ms'])} | {number(m['p95_ms'])} | "
                         f"{number(m['throughput_per_s'])} | {number(m['error_rate'])} |")
        lines.append("")
    counts = ", ".join(f"{severity} {sec[severity]}" for severity in contract.SEC_SEVERITIES)
    lines += [f"**Security findings** the scan left, by severity: {counts}",
              f"<!-- customer-evidence:end {version} -->"]
    return "\n".join(lines) + "\n"


# --- the changelog ----------------------------------------------------------------------------

def is_boundary(line: str) -> bool:
    return line.startswith("## ") or bool(release_notes.LINK_DEFINITION_RE.match(line))


def scan(lines: list[str]):
    """(section heading index per version, (start, end) line indexes of its block, errors)."""
    sections: dict[str, int] = {}
    blocks: dict[str, tuple[int, int]] = {}
    errors: list[str] = []
    current = None
    opened = None
    for index, line in enumerate(lines):
        if is_boundary(line):
            if opened is not None:
                errors.append(f"CHANGELOG.md line {opened[1] + 1}: the evidence block for "
                              f"{opened[0]} is never closed.")
                opened = None
            heading = HEADING_RE.match(line)
            current = heading.group(1) if heading else None
            if heading:
                sections.setdefault(current, index)
            continue
        if not line.startswith("<!-- customer-evidence:"):
            continue
        marker = MARKER_RE.match(line)
        where = f"CHANGELOG.md line {index + 1}"
        if not marker:
            errors.append(f"{where}: a malformed evidence marker; leave the block to --write.")
        elif current is None:
            errors.append(f"{where}: an evidence marker outside a released version's section.")
        elif marker.group(2) != current:
            errors.append(f"{where}: the marker names {marker.group(2)} inside the {current} "
                          f"section.")
        elif marker.group(1) == "start":
            if opened is not None or current in blocks:
                errors.append(f"{where}: a second evidence block for {current}.")
            opened = (current, index)
        elif opened is None:
            errors.append(f"{where}: an evidence end marker with no start.")
        else:
            blocks[current] = (opened[1], index)
            opened = None
    if opened is not None:
        errors.append(f"CHANGELOG.md line {opened[1] + 1}: the evidence block for {opened[0]} is "
                      f"never closed.")
    return sections, blocks, errors


def block_text(lines: list[str], span: tuple[int, int]) -> str:
    return "\n".join(lines[span[0]:span[1] + 1]) + "\n"


def write_block(changelog: str, version: str, block: str) -> str:
    lines = changelog.split("\n")
    sections, blocks, errors = scan(lines)
    if errors:
        raise Refused("; ".join(errors))
    if version not in sections:
        raise Refused(f"CHANGELOG.md has no '## [{version}] - YYYY-MM-DD' section to put the "
                      f"evidence in.")
    new_lines = block.rstrip("\n").split("\n")
    if version in blocks:
        start, end = blocks[version]
        lines[start:end + 1] = new_lines
        return "\n".join(lines)
    end = next((i for i in range(sections[version] + 1, len(lines)) if is_boundary(lines[i])),
               len(lines))
    last = end
    while last > sections[version] + 1 and not lines[last - 1].strip():
        last -= 1
    lines[last:end] = [""] + new_lines + [""]
    return "\n".join(lines)


def compose(version: str, changelog: str, link_base: str, summary: dict | None) -> str:
    """The release body: the changelog section, then the block when there is a summary."""
    try:
        notes = release_notes.section(changelog, version)
    except release_notes.NotesFailed as exc:
        raise Refused(str(exc)) from None
    # A section that already carries a block (main's copy) gives the same body as the tag's.
    notes = re.sub(
        rf"^<!-- customer-evidence:start {re.escape(version)} -->\n.*?"
        rf"^<!-- customer-evidence:end {re.escape(version)} -->\n?",
        "", notes, flags=re.M | re.S)
    if "<!-- customer-evidence:" in notes:
        raise Refused(f"the {version} changelog section has a malformed evidence marker.")
    notes = notes.strip("\n")
    if not notes.strip():
        raise Refused(f"the {version} changelog section has nothing under it besides evidence.")
    notes += "\n"
    if link_base:
        notes = release_notes.rewrite_links(notes, link_base)
    if summary is None:
        return notes
    return notes + "\n" + render(summary)


def read_changelog(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        raise Refused(f"{path} cannot be read.") from None


def check_all(manifest: Path, directory: Path, changelog: Path) -> list[str]:
    errors, _ = contract.check_tree(manifest, directory)
    if errors:
        return errors
    versions = sorted(p.stem for p in directory.glob("*.json")) if directory.is_dir() else []
    lines = read_changelog(changelog).split("\n")
    sections, blocks, errors = scan(lines)
    for version in versions:
        if version not in sections:
            errors.append(f"customer-summary/{version}.json has no '## [{version}]' section in "
                          f"CHANGELOG.md to carry its evidence.")
        elif version not in blocks:
            errors.append(f"customer-summary/{version}.json has no evidence block in the {version} "
                          f"changelog section. Run: python3 scripts/release_evidence.py "
                          f"--write {version}")
        else:
            expected = render(load_summary(version, manifest, directory))
            actual = block_text(lines, blocks[version])
            if actual != expected:
                diff = "".join(difflib.unified_diff(
                    expected.splitlines(True), actual.splitlines(True),
                    "generated from the summary", "CHANGELOG.md", n=1))
                errors.append(f"the {version} evidence block in CHANGELOG.md is not what "
                              f"customer-summary/{version}.json generates. Do not edit it by hand; "
                              f"run: python3 scripts/release_evidence.py --write {version}\n{diff}")
    for version in sorted(blocks):
        if version not in versions:
            errors.append(f"the {version} changelog section has an evidence block, but there is no "
                          f"customer-summary/{version}.json to generate it from.")
    return errors


# --- the command line -------------------------------------------------------------------------

def run(args) -> str | None:
    """The text to print, or None when the mode prints nothing. Raises Refused."""
    # Provenance of these three paths: the operator's own --manifest, --summary-dir and --changelog,
    # else the RELEASE_MANIFEST_PATH, CUSTOMER_SUMMARY_DIR and RELEASE_CHANGELOG_PATH defaults. The
    # workflows pass $RUNNER_TEMP paths or leave the repository defaults, and never --write. Nothing a pull request author or an outside
    # party controls reaches them, and every version is checked against X.Y.Z before it joins a path.
    manifest = Path(args.manifest or contract.MANIFEST_PATH)
    directory = Path(args.summary_dir or contract.SUMMARY_DIR)
    changelog = Path(args.changelog or release_notes.CHANGELOG_PATH)

    if args.check:
        errors = check_all(manifest, directory, changelog)
        if errors:
            raise Refused("\n".join(errors))
        count = len(list(directory.glob("*.json"))) if directory.is_dir() else 0
        print(f"OK: {count} customer summary file(s); each released section carries exactly the "
              f"evidence block its summary generates (none present is fine)")
        return None
    if args.render:
        return render(load_summary(args.render, manifest, directory))
    if args.write:
        document = load_summary(args.write, manifest, directory)
        updated = write_block(read_changelog(changelog), args.write, render(document))
        changelog.write_text(updated, encoding="utf-8")
        print(f"wrote the {args.write} evidence block into {changelog.name}")
        return None
    if args.compose:
        version = check_version(args.compose)
        summary = None
        if not args.optional or (directory / f"{version}.json").exists():
            summary = load_summary(version, manifest, directory)
        return compose(version, read_changelog(changelog), args.link_base, summary)
    version = check_version(args.post_tag)
    summary = load_summary(version, manifest, directory)
    if not args.tags_file:
        raise Refused("--post-tag needs --tags-file, the names of the repository's tags.")
    tags = read_changelog(Path(args.tags_file)).split()
    if f"v{version}" not in tags:
        raise Refused(f"tag v{version} does not exist. The summary is added after the tag, so a "
                      f"version with no tag has no Release to edit; cut the release first.")
    return compose(version, read_changelog(changelog), args.link_base, summary)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--selftest", action="store_true")
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--render", metavar="VERSION")
    modes.add_argument("--write", metavar="VERSION")
    modes.add_argument("--compose", metavar="VERSION")
    modes.add_argument("--post-tag", metavar="VERSION")
    parser.add_argument("--optional", action="store_true",
                        help="with --compose: no summary means the changelog section alone")
    parser.add_argument("--link-base", default="")
    parser.add_argument("--tags-file")
    parser.add_argument("--manifest")
    parser.add_argument("--summary-dir")
    parser.add_argument("--changelog")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    try:
        text = run(args)
    except Refused as exc:
        print(f"release-evidence — {exc}", file=sys.stderr)
        return 1
    if text is not None:
        sys.stdout.write(text)
    return 0


# --- selftest ---------------------------------------------------------------------------------

FIXTURE_CHANGELOG = """# Changelog (fixture)

## [Unreleased]

## [1.2.3] - 2026-01-24

### Added

- A feature, see [the guide](docs/guide.md) and [the registry](https://registry.terraform.io/).

## [1.2.2] - 2026-01-17

### Fixed

- A fix.

[Unreleased]: https://example.invalid/compare/v1.2.3...HEAD
"""
LINK_BASE = "https://example.invalid/blob/v1.2.3/"


def _stage(root: Path, summaries: dict, changelog: str = FIXTURE_CHANGELOG, tags: str = "v1.2.3\n"):
    # Only --selftest reaches here, and root is always a tempfile.TemporaryDirectory(). Every name
    # written is a literal (MANIFEST.json, CHANGELOG.md, tags.txt) or a fixture key such as
    # "1.2.3.json" from this file, so no outside input chooses a path.
    manifest = {"schema_version": 1, "releases": {"1.2.3": {}, "1.2.2": {}, "1.1.0": {}}}
    (root / "MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
    (root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
    (root / "tags.txt").write_text(tags, encoding="utf-8")
    (root / "customer-summary").mkdir()
    for name, document in summaries.items():
        (root / "customer-summary" / name).write_text(
            document if isinstance(document, str) else json.dumps(document), encoding="utf-8")


def _tree(root: Path) -> dict:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def _invoke(root: Path, *args: str):
    return subprocess.run(
        [sys.executable, str(SELF), *args, "--manifest", str(root / "MANIFEST.json"),
         "--summary-dir", str(root / "customer-summary"), "--changelog", str(root / "CHANGELOG.md")],
        capture_output=True, text=True, check=False)


def _with_block(summary: dict, edit=None) -> str:
    block = render(summary)
    if edit:
        block = edit(block)
    return write_block(FIXTURE_CHANGELOG, "1.2.3", block)


def selftest() -> int:
    good = contract._good()
    leak = dict(good, gates_passed=["upgrade", "kv-msly-prod.vault.azure.net"])
    extra_sec = dict(good, sec=dict(good["sec"], **{"Cross Site Scripting at /login": 1}))
    other_version = dict(good, version="1.2.2")
    markup_gate = dict(good, gates_passed=["upgrade\n## [9.9.9] - 2030-01-01"])
    no_baseline = dict(good, perf=None)
    expected_block = EXPECTED_BLOCK.read_text(encoding="utf-8")
    failures: list[str] = []
    count = 0

    def scenario(name, summaries, args, exit_code, fragment=None, *, changelog=FIXTURE_CHANGELOG,
                 tags="v1.2.3\n", stdout_is=None, silent=False, unchanged=False, absent=None):
        nonlocal count
        count += 1
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _stage(root, summaries, changelog, tags)
            before = _tree(root)
            result = _invoke(root, *args)
            verdict = "ok"
            output = result.stdout + result.stderr
            if result.returncode != exit_code:
                verdict = f"expected exit {exit_code}, got {result.returncode}:\n{output}"
            elif fragment is not None and fragment not in output:
                verdict = f"right exit but never printed {fragment!r}:\n{output}"
            elif absent is not None and absent in output:
                verdict = f"printed {absent!r}, which must not be there:\n{output}"
            elif stdout_is is not None and result.stdout != stdout_is:
                verdict = f"stdout differs from the expectation:\n{result.stdout}"
            elif silent and result.stdout:
                verdict = f"printed on stdout when it must print nothing:\n{result.stdout}"
            elif unchanged and _tree(root) != before:
                verdict = "changed the tree when it must change nothing"
            print(f"  {'PASS' if verdict == 'ok' else 'FAIL'}  {name} (exit {result.returncode})")
            if verdict != "ok":
                failures.append(f"{name}: {verdict}")
            return result

    one = {"1.2.3.json": good}
    block_cl = _with_block(good)
    # the block: rendered from the summary alone, byte for byte
    scenario("a valid summary renders exactly the expected block", one, ["--render", "1.2.3"], 0,
             stdout_is=expected_block)
    scenario("no previous Stable renders the no-baseline line", {"1.2.3.json": no_baseline},
             ["--render", "1.2.3"], 0, "no previous Stable version to compare with",
             absent="measured against")
    # leaks: refused by the contract before anything is rendered, written or composed
    for mode in (["--render", "1.2.3"], ["--write", "1.2.3"], ["--compose", "1.2.3"]):
        scenario(f"a leaking hostname is refused by {mode[0]}", {"1.2.3.json": leak}, mode, 1,
                 "kv-msly-prod", silent=True, unchanged=True)
    scenario("a finding beyond counts in sec is refused", {"1.2.3.json": extra_sec},
             ["--render", "1.2.3"], 1, "sec", silent=True, unchanged=True)
    scenario("a gate name carrying markup is refused", {"1.2.3.json": markup_gate},
             ["--render", "1.2.3"], 1, "not plain words", silent=True, unchanged=True)
    scenario("a version that is not X.Y.Z is refused", one, ["--render", "1.2"], 1, "not a version",
             silent=True)
    # --write
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _stage(root, one)
        count += 1
        first = _invoke(root, "--write", "1.2.3")
        written = (root / "CHANGELOG.md").read_text(encoding="utf-8")
        again = _invoke(root, "--write", "1.2.3")
        ok = (first.returncode == 0 and again.returncode == 0 and written == block_cl
              and (root / "CHANGELOG.md").read_text(encoding="utf-8") == written
              and written.count("customer-evidence:start") == 1
              and written.index("### Fixed") > written.index("customer-evidence:end 1.2.3"))
        print(f"  {'PASS' if ok else 'FAIL'}  --write puts the block at the end of its own section, once")
        if not ok:
            failures.append(f"--write: {first.stderr}{again.stderr}\n{written}")
    scenario("--write on a version with no section is refused", one, ["--write", "1.2.3"], 1,
             "no '## [1.2.3]", changelog=FIXTURE_CHANGELOG.replace("## [1.2.3]", "## [1.2.4]"),
             unchanged=True)
    # --check
    scenario("check: no summary and no block passes", {}, ["--check"], 0, "OK")
    scenario("check: a summary with its generated block passes", one, ["--check"], 0, "OK",
             changelog=block_cl)
    scenario("check: a hand-edited block fails", one, ["--check"], 1, "not what",
             changelog=_with_block(good, lambda b: b.replace("Low 2", "Low 0")))
    scenario("check: a summary with no block fails", one, ["--check"], 1, "no evidence block")
    scenario("check: a block with no summary fails", {}, ["--check"], 1, "no customer-summary/1.2.3.json",
             changelog=block_cl)
    scenario("check: a block under another version's section fails", one, ["--check"], 1,
             "inside the 1.2.2 section",
             changelog=block_cl.replace("[1.2.2] - 2026-01-17\n", "[1.2.2] - 2026-01-17\n"
                                        "<!-- customer-evidence:start 1.2.3 -->\n"))
    scenario("check: a block that is never closed fails", one, ["--check"], 1, "never closed",
             changelog=block_cl.replace("<!-- customer-evidence:end 1.2.3 -->\n", ""))
    scenario("check: a leaking summary fails", {"1.2.3.json": leak}, ["--check"], 1, "kv-msly-prod",
             changelog=block_cl)
    # --compose and --post-tag: the same bytes by both paths
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _stage(root, one)
        count += 1
        notes = subprocess.run([sys.executable, str(Path(release_notes.__file__).resolve()),
                                "v1.2.3", "--link-base", LINK_BASE], capture_output=True, text=True,
                               env=dict(os.environ, RELEASE_CHANGELOG_PATH=str(root / "CHANGELOG.md")),
                               check=False).stdout
        tag_build = _invoke(root, "--compose", "1.2.3", "--optional", "--link-base", LINK_BASE)
        post_tag = _invoke(root, "--post-tag", "1.2.3", "--tags-file", str(root / "tags.txt"),
                           "--link-base", LINK_BASE)
        (root / "CHANGELOG.md").write_text(block_cl, encoding="utf-8")
        from_main = _invoke(root, "--post-tag", "1.2.3", "--tags-file", str(root / "tags.txt"),
                            "--link-base", LINK_BASE)
        expected = notes + "\n" + expected_block
        ok = (tag_build.returncode == post_tag.returncode == from_main.returncode == 0
              and tag_build.stdout == post_tag.stdout == from_main.stdout == expected
              and f"]({LINK_BASE}docs/guide.md)" in expected and "](https://registry" in expected)
        print(f"  {'PASS' if ok else 'FAIL'}  the tag build and the post-tag step give identical "
              f"bytes: the tag's section, then the block")
        if not ok:
            failures.append(f"composer paths differ:\n{tag_build.stdout!r}\n{post_tag.stdout!r}\n"
                            f"{from_main.stdout!r}\n{expected!r}\n{tag_build.stderr}{post_tag.stderr}")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _stage(root, {})
        count += 1
        plain = subprocess.run([sys.executable, str(Path(release_notes.__file__).resolve()), "v1.2.3",
                                "--link-base", LINK_BASE], capture_output=True, text=True,
                               env=dict(os.environ, RELEASE_CHANGELOG_PATH=str(root / "CHANGELOG.md")),
                               check=False).stdout
        got = _invoke(root, "--compose", "1.2.3", "--optional", "--link-base", LINK_BASE)
        ok = got.returncode == 0 and got.stdout == plain and plain
        print(f"  {'PASS' if ok else 'FAIL'}  with no summary the tag build's body is the changelog "
              f"section alone, as before")
        if not ok:
            failures.append(f"optional compose differs from release_notes.py:\n{got.stdout!r}")
    scenario("compose without --optional refuses a missing summary", {}, ["--compose", "1.2.3"], 1,
             "no customer summary", silent=True)
    # the post-tag refusals: exit 1, a reason, no body
    post = ["--post-tag", "1.2.3", "--tags-file", "{root}/tags.txt"]
    for name, summaries, tags, reason in (
        ("post-tag: a missing summary", {}, "v1.2.3\n", "no customer summary for 1.2.3"),
        ("post-tag: a summary that fails the contract", {"1.2.3.json": leak}, "v1.2.3\n",
         "fails the customer-summary contract"),
        ("post-tag: a summary naming a different version", {"1.2.3.json": other_version},
         "v1.2.3\n", "is named '1.2.3.json' but its `version` is '1.2.2'"),
        ("post-tag: a version with no tag", one, "v1.2.2\n", "tag v1.2.3 does not exist"),
    ):
        count += 1
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _stage(root, summaries, tags=tags)
            before = _tree(root)
            result = _invoke(root, *[a.replace("{root}", str(root)) for a in post])
            ok = (result.returncode == 1 and reason in result.stderr and not result.stdout
                  and _tree(root) == before)
            print(f"  {'PASS' if ok else 'FAIL'}  {name} is refused (exit {result.returncode}: "
                  f"{result.stderr.strip().splitlines()[0] if result.stderr.strip() else ''})")
            if not ok:
                failures.append(f"{name}: exit {result.returncode}, stderr {result.stderr!r}, "
                                f"stdout {result.stdout!r}")

    if failures:
        print(f"\nrelease-evidence selftest — {len(failures)} of {count} scenarios did not behave "
              f"as required:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"\nrelease-evidence selftest — {count} scenarios: the block is generated from the "
          f"checked summary alone, a leaking, failing, mismatched, missing or untagged summary is "
          f"refused with nothing printed, and --check refuses a hand-edited, missing or orphaned "
          f"block.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
