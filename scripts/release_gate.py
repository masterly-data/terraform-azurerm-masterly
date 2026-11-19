"""Decide whether a version may be tagged on a commit: the check the cut-release workflow runs
BEFORE the tag exists.

A tag on this repository is the release. The Terraform Registry publishes a version from its own
webhook the moment the tag appears, and a published version cannot be withdrawn, only superseded.
Every check that runs on the tag build therefore runs too late to refuse anything: it can turn red,
but the version is already public. The only place a gate can say no is before the tag is created,
so `.github/workflows/cut-release.yml` runs this script first and creates the tag only when it
passes (MAS-274).

It refuses, with a message that names the fault, when:

  * the version is not X.Y.Z (a leading `v` is accepted);
  * the commit is not a full 40-character commit SHA — a short or symbolic ref is exactly how a
    tag lands on a commit other than the one that was meant;
  * the tag already exists at another commit — a published version cannot be replaced or moved,
    so the answer is the next version. The commit a tag points at is the peeled one (`^{}`) for
    an annotated tag, so a tag object's own SHA is never mistaken for the commit;
  * the release commit's MANIFEST.json has no entry for the version, or the entry does not name
    its `api` and `frontend` images under `masterly.azurecr.io/release/` with a `digests.api` and
    a `digests.frontend` that are each `sha256:` plus 64 lowercase hex — a version is published
    pinned to exact builds, never to image tags alone, which can be moved;
  * the commit has no `ci` workflow run from a push to `main` — it never reached `main`, so no
    check has passed on it where it will be released from;
  * that run, the most recent for the commit, has not finished, or finished with anything other
    than success. The run's conclusion covers every job in `ci.yml` at once: `validate` (the check
    the `main` branch ruleset requires), shellcheck, the diagnostic bundle and the release
    metadata — so there is no second list of job names here to fall out of step with the
    workflow.

A tag that already exists at exactly this commit is not refused: it is what a run that created
the tag and then failed later leaves behind, so dispatching the same version and commit again
finishes that release (the workflow skips the tag write and goes on) instead of failing on it.

What it does not check, because the workflow checks it with the tools built for it: that the
commit is on `main` (`git merge-base --is-ancestor`), and that the manifest, the changelog and the
README at that commit publish this version (`scripts/check_release_manifest.py --tag` and
`scripts/release_notes.py`, run against the commit's own tree). The manifest entry is checked
here, by `main`'s copy of this script reading the commit's file as data, so the rule binds every
commit dispatched, including one cut before the rule existed.

Inputs are files rather than API calls, so the decision can be tested without a network:

  --runs      the JSON the Actions API returns for
              `GET /repos/{owner}/{repo}/actions/workflows/ci.yml/runs?head_sha=...&event=push`
              (the object with `workflow_runs`, or a bare list of runs);
  --tags      the repository's tags as `git ls-remote --tags origin 'v*'` prints them, peeled
              lines included: `<sha>TAB refs/tags/<name>`, and `<sha>TAB refs/tags/<name>^{}`
              for the commit an annotated tag points at. Any other line is refused;
  --manifest  the release commit's MANIFEST.json (`git show <commit>:MANIFEST.json`).

On success the tag name is printed on stdout and nothing else, so a workflow can capture it; the
reasoning goes to stderr. `--existing-out FILE` receives `true` when the tag already exists at the
commit and `false` when it is still to be created; nothing is written to it when the gate refuses.

Run:
    python3 scripts/release_gate.py --version 0.16.0 --commit <sha> --runs runs.json \
        --tags tag-refs.txt --manifest MANIFEST.json --existing-out existing.txt
    python3 scripts/release_gate.py --selftest       # it still refuses what it should

Standard library only — release metadata should not depend on anything resolving.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
RELEASE_BRANCH = "main"
# One line of `git ls-remote --tags`: the object a tag ref names, and `^{}` on the line that gives
# the commit an annotated tag peels to.
TAG_REF_RE = re.compile(r"^(?P<sha>[0-9a-f]{40})\trefs/tags/(?P<name>[^\s^]+)(?P<peeled>\^\{\})?$")
# Where every release image is published, and the shape of a recorded digest (the same rule as
# scripts/check_release_manifest.py's DIGEST_RE; release metadata scripts do not import each other).
RELEASE_IMAGE_PREFIX = "masterly.azurecr.io/release/"
IMAGE_TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RELEASE_ROLES = ("api", "frontend")


class GateRefused(Exception):
    """A reason not to create the tag, phrased for whoever has to fix it."""


def parse_version(value: str) -> str:
    match = VERSION_RE.match(value.strip())
    if not match:
        raise GateRefused(
            f"{value!r} is not a release version. Give X.Y.Z (a leading 'v' is accepted); the tag "
            f"created is vX.Y.Z."
        )
    return ".".join(match.groups())


def check_commit(commit: str) -> str:
    if not COMMIT_RE.match(commit):
        raise GateRefused(
            f"{commit!r} is not a full 40-character commit SHA. Name the release commit exactly "
            f"— a branch name, a short SHA or HEAD is how a tag lands on a commit nobody meant."
        )
    return commit


def parse_tag_refs(text: str) -> dict[str, str]:
    """Each tag's commit, from `git ls-remote --tags` output with its peeled lines.

    An annotated tag is listed twice: once naming the tag object, once (`^{}`) naming the commit
    it points at, and that second line is the one that counts. A lightweight tag is listed once,
    naming its commit. A line in any other form is refused rather than skipped, so a listing in
    the wrong format cannot read as "no tag exists".
    """
    named: dict[str, str] = {}
    peeled: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        match = TAG_REF_RE.match(line.strip())
        if not match:
            raise GateRefused(
                f"{line.strip()!r} is not a line of `git ls-remote --tags` output "
                f"('<40-hex sha>\\trefs/tags/<name>', optionally ending '^{{}}'). Refusing rather "
                f"than reading the tag listing wrongly."
            )
        target = peeled if match.group("peeled") else named
        target[match.group("name")] = match.group("sha")
    return {**named, **peeled}


def check_tag(tag: str, commit: str, tag_commits: dict[str, str]) -> bool:
    """True when the tag already exists at this commit; refused when it exists anywhere else."""
    at = tag_commits.get(tag)
    if at is None:
        return False
    if at != commit:
        raise GateRefused(
            f"{tag} already exists at {at}, not at {commit}. A version the registry has published "
            f"cannot be replaced or moved, only superseded: release the change as the next "
            f"version instead."
        )
    return True


def check_release_entry(version: str, manifest: object) -> dict:
    """The version's MANIFEST.json entry names release images, each pinned by its digest."""
    releases = manifest.get("releases") if isinstance(manifest, dict) else None
    if not isinstance(releases, dict):
        raise GateRefused(
            "the release commit's MANIFEST.json has no 'releases' object, so nothing says which "
            "images this version is released against."
        )
    entry = releases.get(version)
    if not isinstance(entry, dict):
        raise GateRefused(
            f"the release commit's MANIFEST.json has no entry for {version}. The release-cut "
            f"commit adds it; name the commit that carries it."
        )
    faults: list[str] = []
    images = entry.get("images")
    images = images if isinstance(images, dict) else {}
    digests = entry.get("digests")
    if not isinstance(digests, dict):
        faults.append(
            "it records no digests, so the version would be published naming its images by "
            "tag alone, which can be moved: add digests.api and digests.frontend"
        )
        digests = None
    for role in RELEASE_ROLES:
        image = images.get(role)
        prefix = f"{RELEASE_IMAGE_PREFIX}{role}:"
        if not (
            isinstance(image, str)
            and image.startswith(prefix)
            and IMAGE_TAG_RE.match(image[len(prefix):])
        ):
            faults.append(
                f"images.{role} is {image!r}, not an image under {RELEASE_IMAGE_PREFIX} "
                f"({prefix}<tag>)"
            )
        if digests is not None:
            digest = digests.get(role)
            if not (isinstance(digest, str) and DIGEST_RE.match(digest)):
                faults.append(
                    f"digests.{role} is {digest!r}, not 'sha256:' followed by 64 lowercase hex"
                )
    if faults:
        raise GateRefused(
            f"the release commit's MANIFEST.json entry for {version} cannot be released: "
            + "; ".join(faults)
            + "."
        )
    return entry


def _is_ci_workflow(run: dict) -> bool:
    # The API reports the workflow file as `path`, sometimes suffixed with `@<ref>`.
    path = str(run.get("path", ""))
    return path == CI_WORKFLOW_PATH or path.startswith(CI_WORKFLOW_PATH + "@")


def check_ci(commit: str, payload: object) -> dict:
    """The newest `ci` run from a push of this exact commit to main, which must have succeeded."""
    if isinstance(payload, dict):
        runs = payload.get("workflow_runs")
    else:
        runs = payload
    if not isinstance(runs, list):
        raise GateRefused(
            "the workflow-runs response has no 'workflow_runs' list, so nothing can be said about "
            "CI on this commit. Refusing rather than assuming it passed."
        )

    candidates = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("head_sha") == commit
        and run.get("event") == "push"
        and run.get("head_branch") == RELEASE_BRANCH
        and _is_ci_workflow(run)
    ]
    if not candidates:
        raise GateRefused(
            f"no '{CI_WORKFLOW_PATH}' run from a push to {RELEASE_BRANCH} exists for {commit}. "
            f"A release commit reaches {RELEASE_BRANCH} through a merged pull request, and that "
            f"push is what runs the checks it is released on. Merge it first, or name the commit "
            f"{RELEASE_BRANCH} actually has."
        )

    # Newest first: the run created last, and within it the attempt made last. A re-run of a
    # failed run is a new attempt of the same run, and it is the attempt that counts.
    newest = max(
        candidates,
        key=lambda run: (str(run.get("created_at", "")), int(run.get("run_attempt") or 0)),
    )
    where = newest.get("html_url") or f"run {newest.get('id', '?')}"
    status = newest.get("status")
    conclusion = newest.get("conclusion")
    if status != "completed":
        raise GateRefused(
            f"CI on {commit} has not finished (status {status!r}): {where}. Dispatch the release "
            f"again once it has passed."
        )
    if conclusion != "success":
        raise GateRefused(
            f"CI on {commit} concluded {conclusion!r}, not 'success': {where}. Only a commit every "
            f"check passed on is released."
        )
    return newest


def decide(
    version: str, commit: str, runs_payload: object, tag_refs: str, manifest: object
) -> tuple[str, dict, bool]:
    version = parse_version(version)
    tag = "v" + version
    commit = check_commit(commit.strip())
    existing = check_tag(tag, commit, parse_tag_refs(tag_refs))
    check_release_entry(version, manifest)
    run = check_ci(commit, runs_payload)
    return tag, run, existing


# ---------------------------------------------------------------------------
# The selftest: watching the gate refuse
# ---------------------------------------------------------------------------
#
# A gate nobody has watched refuse anything is a hypothesis, and this one guards the only step in
# this repository that cannot be undone. `--selftest` runs THIS script as a subprocess — the real
# entry point and the real exit code, which is what the workflow depends on — against synthetic
# run, tag and manifest files, and asserts both halves: a sound release passes, prints only its
# tag and reports whether that tag already exists, and each way a release can be wrong is refused
# with the message that names that fault, so a scenario failing for an unrelated reason does not
# read as proof.
#
SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
# The SHAs of annotated tag objects, which are never commits.
TAG_OBJECT = "1111111111111111111111111111111111111111"
OTHER_TAG_OBJECT = "2222222222222222222222222222222222222222"
OLD_COMMIT = "3333333333333333333333333333333333333333"


def _tag_refs(*tags: tuple[str, str, str | None]) -> str:
    """`git ls-remote --tags` output for (name, object, peeled commit or None if lightweight)."""
    lines = []
    for name, sha, peeled in tags:
        lines.append(f"{sha}\trefs/tags/{name}")
        if peeled is not None:
            lines.append(f"{peeled}\trefs/tags/{name}^{{}}")
    return "\n".join(lines) + "\n"


# v0.14.0 lightweight, v0.15.0 annotated at OTHER_SHA.
_OLD_TAGS = (("v0.14.0", OLD_COMMIT, None), ("v0.15.0", OTHER_TAG_OBJECT, OTHER_SHA))
TAGS = _tag_refs(*_OLD_TAGS)


def _entry(**overrides) -> dict:
    entry = {
        "date": "2026-09-23",
        "images": {
            "api": f"{RELEASE_IMAGE_PREFIX}api:v0.140.0",
            "frontend": f"{RELEASE_IMAGE_PREFIX}frontend:v0.150.0",
        },
        "digests": {"api": "sha256:" + "a" * 64, "frontend": "sha256:" + "b" * 64},
    }
    for key, value in overrides.items():
        if value is None:
            entry.pop(key, None)
        else:
            entry[key] = value
    return entry


def _manifest(entry: dict | None = None, version: str = "0.16.0") -> str:
    releases = {"0.15.0": _entry()}
    if entry is not None:
        releases[version] = entry
    return json.dumps({"schema_version": 1, "latest": version, "releases": releases})


MANIFEST = _manifest(_entry())


def _run(**overrides) -> dict:
    run = {
        "id": 1,
        "path": CI_WORKFLOW_PATH,
        "head_sha": SHA,
        "head_branch": RELEASE_BRANCH,
        "event": "push",
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-09-23T10:00:00Z",
        "run_attempt": 1,
        "html_url": "https://example.invalid/runs/1",
    }
    run.update(overrides)
    return run


def _payload(*runs: dict) -> str:
    return json.dumps({"total_count": len(runs), "workflow_runs": list(runs)})


def _selftest_scenarios() -> list[tuple]:
    """(name, version, commit, runs file content, tags, expected exit, must print, must not[,
    manifest[, what --existing-out must hold on a pass]]).

    The manifest defaults to MANIFEST, a sound entry for 0.16.0; a pass must report `false`
    (the tag is still to be created) unless the scenario says otherwise.
    """
    ok = _payload(_run())
    images = _entry()["images"]
    digests = _entry()["digests"]
    return [
        ("a green commit on main passes and prints only its tag",
         "0.16.0", SHA, ok, TAGS, 0, "v0.16.0", "refused"),
        ("a leading 'v' is accepted", "v0.16.0", SHA, ok, TAGS, 0, "v0.16.0", None),
        ("a bare list of runs is accepted", "0.16.0", SHA, json.dumps([_run()]), TAGS, 0,
         "v0.16.0", None),
        ("the path may carry an @ref suffix", "0.16.0", SHA,
         _payload(_run(path=CI_WORKFLOW_PATH + "@refs/heads/main")), TAGS, 0, "v0.16.0", None),
        ("a partial version is refused", "0.16", SHA, ok, TAGS, 1, "not a release version", None),
        ("Unreleased is refused", "Unreleased", SHA, ok, TAGS, 1, "not a release version", None),
        ("a short SHA is refused", "0.16.0", SHA[:7], ok, TAGS, 1, "not a full 40-character",
         None),
        ("a branch name is refused", "0.16.0", "main", ok, TAGS, 1, "not a full 40-character",
         None),
        ("an uppercase SHA is refused", "0.16.0", SHA.upper(), ok, TAGS, 1,
         "not a full 40-character", None),
        # The tag: new, already at this commit (a re-run), or at another commit (refused).
        ("a tag at another commit is refused, naming both commits", "0.15.0", SHA, ok, TAGS, 1,
         f"v0.15.0 already exists at {OTHER_SHA}, not at {SHA}", None, _manifest(_entry())),
        ("a lightweight tag at another commit is refused", "0.14.0", SHA, ok, TAGS, 1,
         f"v0.14.0 already exists at {OLD_COMMIT}, not at {SHA}", None,
         _manifest(_entry(), "0.14.0")),
        ("an annotated tag at this commit passes and reports it already exists", "0.16.0", SHA,
         ok, _tag_refs(*_OLD_TAGS, ("v0.16.0", TAG_OBJECT, SHA)), 0, "v0.16.0", "refused",
         MANIFEST, "true"),
        ("a lightweight tag at this commit passes and reports it already exists", "0.16.0", SHA,
         ok, _tag_refs(*_OLD_TAGS, ("v0.16.0", SHA, None)), 0, "v0.16.0", "refused", MANIFEST,
         "true"),
        ("a tag whose tag object, not its commit, is the SHA is refused", "0.16.0", SHA, ok,
         _tag_refs(*_OLD_TAGS, ("v0.16.0", SHA, OTHER_SHA)), 1,
         f"v0.16.0 already exists at {OTHER_SHA}, not at {SHA}", None),
        ("a tag listing of bare names is refused", "0.16.0", SHA, ok, "v0.14.0\nv0.15.0\n", 1,
         "is not a line of `git ls-remote --tags` output", None),
        ("an existing tag at this commit is still refused when CI did not pass", "0.16.0", SHA,
         _payload(_run(conclusion="failure")),
         _tag_refs(*_OLD_TAGS, ("v0.16.0", TAG_OBJECT, SHA)), 1, "concluded 'failure'", None),
        # The version's manifest entry: present, release images, each pinned by its digest.
        ("a version with no manifest entry is refused", "0.16.0", SHA, ok, TAGS, 1,
         "has no entry for 0.16.0", None, _manifest(None)),
        ("a manifest with no releases is refused", "0.16.0", SHA, ok, TAGS, 1,
         "has no 'releases' object", None, json.dumps({"schema_version": 1})),
        ("an entry with no digests is refused", "0.16.0", SHA, ok, TAGS, 1,
         "it records no digests", None, _manifest(_entry(digests=None))),
        ("an entry missing the frontend digest is refused", "0.16.0", SHA, ok, TAGS, 1,
         "digests.frontend is None", None,
         _manifest(_entry(digests={"api": digests["api"]}))),
        ("an uppercase digest is refused", "0.16.0", SHA, ok, TAGS, 1,
         "digests.api is 'sha256:" + "A" * 64, None,
         _manifest(_entry(digests={**digests, "api": "sha256:" + "A" * 64}))),
        ("a digest with no sha256: prefix is refused", "0.16.0", SHA, ok, TAGS, 1,
         "digests.frontend is '" + "b" * 64, None,
         _manifest(_entry(digests={**digests, "frontend": "b" * 64}))),
        ("an api image at the registry root, outside release/, is refused", "0.16.0", SHA, ok,
         TAGS, 1, "images.api is 'masterly.azurecr.io/api:v0.140.0', not an image under", None,
         _manifest(_entry(images={**images, "api": "masterly.azurecr.io/api:v0.140.0"}))),
        ("a frontend image in another registry is refused", "0.16.0", SHA, ok, TAGS, 1,
         "images.frontend is 'example.invalid/release/frontend:v0.150.0'", None,
         _manifest(_entry(
             images={**images, "frontend": "example.invalid/release/frontend:v0.150.0"}))),
        ("an image nested deeper under release/ is refused", "0.16.0", SHA, ok, TAGS, 1,
         "images.api is 'masterly.azurecr.io/release/mirror/api:v0.140.0'", None,
         _manifest(_entry(images={**images,
                                  "api": "masterly.azurecr.io/release/mirror/api:v0.140.0"}))),
        ("an image under another role's repository is refused", "0.16.0", SHA, ok, TAGS, 1,
         "images.frontend is 'masterly.azurecr.io/release/api:v0.140.0'", None,
         _manifest(_entry(images={**images, "frontend": images["api"]}))),
        ("an entry with no images is refused", "0.16.0", SHA, ok, TAGS, 1,
         "images.api is None", None, _manifest(_entry(images=None))),
        ("a manifest that is not JSON is refused", "0.16.0", SHA, ok, TAGS, 1,
         "MANIFEST.json is not JSON", None, "not json"),
        ("no runs at all is refused", "0.16.0", SHA, _payload(), TAGS, 1, "no '.github", None),
        ("a run of another commit is refused", "0.16.0", SHA, _payload(_run(head_sha=OTHER_SHA)),
         TAGS, 1, "no '.github", None),
        ("a pull-request run is refused", "0.16.0", SHA, _payload(_run(event="pull_request")),
         TAGS, 1, "no '.github", None),
        ("a run on another branch is refused", "0.16.0", SHA,
         _payload(_run(head_branch="feature")), TAGS, 1, "no '.github", None),
        ("a run of another workflow is refused", "0.16.0", SHA,
         _payload(_run(path=".github/workflows/public-docs-module-pin.yml")), TAGS, 1,
         "no '.github", None),
        ("a run still in progress is refused", "0.16.0", SHA,
         _payload(_run(status="in_progress", conclusion=None)), TAGS, 1, "has not finished",
         None),
        ("a failed run is refused", "0.16.0", SHA, _payload(_run(conclusion="failure")), TAGS, 1,
         "concluded 'failure'", None),
        ("a cancelled run is refused", "0.16.0", SHA, _payload(_run(conclusion="cancelled")),
         TAGS, 1, "concluded 'cancelled'", None),
        ("an older green run does not outvote a newer red one", "0.16.0", SHA,
         _payload(_run(id=1, created_at="2026-09-23T10:00:00Z"),
                  _run(id=2, created_at="2026-09-23T11:00:00Z", conclusion="failure")),
         TAGS, 1, "concluded 'failure'", None),
        ("a successful re-run attempt counts over the failed first attempt", "0.16.0", SHA,
         _payload(_run(id=1, run_attempt=1, conclusion="failure"),
                  _run(id=1, run_attempt=2, conclusion="success")),
         TAGS, 0, "v0.16.0", None),
        ("a response with no run list is refused", "0.16.0", SHA, json.dumps({"message": "x"}),
         TAGS, 1, "no 'workflow_runs' list", None),
        ("an unreadable response is refused", "0.16.0", SHA, "not json", TAGS, 1,
         "not JSON", None),
    ]


def selftest() -> int:
    scenarios = _selftest_scenarios()
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        runs_file = Path(tmp) / "runs.json"
        tags_file = Path(tmp) / "tag-refs.txt"
        manifest_file = Path(tmp) / "MANIFEST.json"
        existing_file = Path(tmp) / "existing.txt"
        for scenario in scenarios:
            name, version, commit, runs, tags, expected_exit, present, absent, *rest = scenario
            manifest = rest[0] if rest else MANIFEST
            expected_existing = rest[1] if len(rest) > 1 else "false"
            runs_file.write_text(runs, encoding="utf-8")
            tags_file.write_text(tags, encoding="utf-8")
            manifest_file.write_text(manifest, encoding="utf-8")
            existing_file.unlink(missing_ok=True)
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()),
                 "--version", version, "--commit", commit,
                 "--runs", str(runs_file), "--tags", str(tags_file),
                 "--manifest", str(manifest_file), "--existing-out", str(existing_file)],
                capture_output=True,
                text=True,
                env=dict(os.environ),
            )
            output = result.stdout + result.stderr
            existing = (
                existing_file.read_text(encoding="utf-8") if existing_file.exists() else None
            )
            verdict = "ok"
            if result.returncode != expected_exit:
                verdict = f"expected exit {expected_exit}, got {result.returncode}:\n{output}"
            elif present not in output:
                # Right verdict, wrong reason — which would make the scenario prove nothing.
                verdict = f"exited {result.returncode} but never printed {present!r}:\n{output}"
            elif absent is not None and absent in output:
                verdict = f"printed {absent!r}, which must not be there:\n{output}"
            elif expected_exit == 0 and result.stdout.strip() != present:
                # The workflow captures stdout as the tag name, so nothing else may be on it.
                verdict = f"stdout must be exactly {present!r}, got {result.stdout!r}"
            elif expected_exit == 0 and existing != expected_existing:
                # The workflow skips the tag write on `true`, so the file must say exactly that.
                verdict = f"--existing-out must hold {expected_existing!r}, got {existing!r}"
            elif expected_exit != 0 and existing is not None:
                verdict = f"a refusal must write nothing to --existing-out, got {existing!r}"
            if verdict != "ok":
                failures.append(f"{name}: {verdict}")
            print(f"  {'PASS' if verdict == 'ok' else 'FAIL'}  {name}")

    if failures:
        print(
            f"\nrelease-gate selftest — {len(failures)} of {len(scenarios)} scenarios did not "
            f"behave as required:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"\nrelease-gate selftest — {len(scenarios)} scenarios: a green commit on main passes, "
        f"and passes reporting its tag already exists when the tag is at that commit; a malformed "
        f"version or commit, a tag at another commit, a manifest entry without release images "
        f"pinned by digest, and a commit with no finished, successful CI run on main are each "
        f"refused."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--version", help="the release: X.Y.Z or vX.Y.Z")
    parser.add_argument("--commit", help="the full SHA of the commit to tag")
    parser.add_argument("--runs", help="file holding the Actions API's ci.yml runs for the commit")
    parser.add_argument(
        "--tags",
        help="file holding `git ls-remote --tags origin 'v*'` output, peeled `^{}` lines included",
    )
    parser.add_argument("--manifest", help="file holding the release commit's MANIFEST.json")
    parser.add_argument(
        "--existing-out",
        help="file to receive 'true' if the tag already exists at the commit, else 'false'",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run against synthetic inputs and assert the bad cases are still refused",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    required = ("version", "commit", "runs", "tags", "manifest")
    missing = [flag for flag in required if not getattr(args, flag)]
    if missing:
        parser.error("required: " + ", ".join(f"--{flag}" for flag in missing))

    try:
        try:
            payload = json.loads(Path(args.runs).read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise GateRefused(
                f"{args.runs} is not JSON ({error}), so nothing can be said about CI on this "
                f"commit. Refusing rather than assuming it passed."
            ) from None
        try:
            manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise GateRefused(
                f"the release commit's MANIFEST.json is not JSON ({error}), read from "
                f"{args.manifest}."
            ) from None
        tag_refs = Path(args.tags).read_text(encoding="utf-8")
        tag, run, existing = decide(args.version, args.commit, payload, tag_refs, manifest)
    except GateRefused as reason:
        print(f"release gate refused: {reason}", file=sys.stderr)
        return 1

    where = run.get("html_url") or "run " + str(run.get("id"))
    if existing:
        state = (
            f"{tag} already exists at {args.commit}, so it is not created again; the release "
            f"goes on from there"
        )
    else:
        state = f"{tag} does not exist yet and may be created on {args.commit}"
    print(
        f"release gate passed: {state}. CI concluded success on its push to {RELEASE_BRANCH} "
        f"({where}), and the manifest entry names release images pinned by digest.",
        file=sys.stderr,
    )
    if args.existing_out:
        Path(args.existing_out).write_text("true" if existing else "false", encoding="utf-8")
    print(tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
