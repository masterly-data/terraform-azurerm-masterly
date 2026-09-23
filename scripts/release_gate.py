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
  * the tag already exists — a published version cannot be replaced, so the answer is the next
    version, never a moved tag;
  * the commit has no `ci` workflow run from a push to `main` — it never reached `main`, so no
    check has passed on it where it will be released from;
  * that run, the most recent for the commit, has not finished, or finished with anything other
    than success. The run's conclusion covers every job in `ci.yml` at once: `validate` (the check
    the `main` branch ruleset requires), shellcheck, the diagnostic bundle and the release
    metadata — so there is no second list of job names here to fall out of step with the
    workflow.

What it does not check, because the workflow checks it with the tools built for it: that the
commit is on `main` (`git merge-base --is-ancestor`), and that the manifest, the changelog and the
README at that commit publish this version (`scripts/check_release_manifest.py --tag` and
`scripts/release_notes.py`, run against the commit's own tree).

Inputs are files rather than API calls, so the decision can be tested without a network:

  --runs  the JSON the Actions API returns for
          `GET /repos/{owner}/{repo}/actions/workflows/ci.yml/runs?head_sha=...&event=push`
          (the object with `workflow_runs`, or a bare list of runs);
  --tags  the repository's tag names, one per line (`git ls-remote --tags --refs`, stripped).

On success the tag name is printed on stdout and nothing else, so a workflow can capture it; the
reasoning goes to stderr.

Run:
    python3 scripts/release_gate.py --version 0.16.0 --commit <sha> --runs runs.json --tags tags.txt
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


def check_tag_is_new(tag: str, existing: list[str]) -> None:
    if tag in existing:
        raise GateRefused(
            f"{tag} already exists. A version the registry has published cannot be replaced or "
            f"moved, only superseded: release the change as the next version instead."
        )


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


def decide(version: str, commit: str, runs_payload: object, tags: list[str]) -> tuple[str, dict]:
    tag = "v" + parse_version(version)
    commit = check_commit(commit.strip())
    check_tag_is_new(tag, tags)
    run = check_ci(commit, runs_payload)
    return tag, run


# ---------------------------------------------------------------------------
# The selftest: watching the gate refuse
# ---------------------------------------------------------------------------
#
# A gate nobody has watched refuse anything is a hypothesis, and this one guards the only step in
# this repository that cannot be undone. `--selftest` runs THIS script as a subprocess — the real
# entry point and the real exit code, which is what the workflow depends on — against synthetic
# run and tag files, and asserts both halves: a sound release passes and prints only its tag, and
# each way a release can be wrong is refused with the message that names that fault, so a scenario
# failing for an unrelated reason does not read as proof.
#
SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
TAGS = "v0.14.0\nv0.15.0\n"


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
    """(name, version, commit, runs file content, tags, expected exit, must print, must not)."""
    ok = _payload(_run())
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
        ("an existing tag is refused", "0.15.0", SHA, ok, TAGS, 1, "v0.15.0 already exists",
         None),
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
        tags_file = Path(tmp) / "tags.txt"
        for name, version, commit, runs, tags, expected_exit, present, absent in scenarios:
            runs_file.write_text(runs, encoding="utf-8")
            tags_file.write_text(tags, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()),
                 "--version", version, "--commit", commit,
                 "--runs", str(runs_file), "--tags", str(tags_file)],
                capture_output=True,
                text=True,
                env=dict(os.environ),
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
            elif expected_exit == 0 and result.stdout.strip() != present:
                # The workflow captures stdout as the tag name, so nothing else may be on it.
                verdict = f"stdout must be exactly {present!r}, got {result.stdout!r}"
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
        f"\nrelease-gate selftest — {len(scenarios)} scenarios: a green commit on main passes, and "
        f"a malformed version or commit, an existing tag, and a commit with no finished, "
        f"successful CI run on main are each refused."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--version", help="the release: X.Y.Z or vX.Y.Z")
    parser.add_argument("--commit", help="the full SHA of the commit to tag")
    parser.add_argument("--runs", help="file holding the Actions API's ci.yml runs for the commit")
    parser.add_argument("--tags", help="file holding the repository's tag names, one per line")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run against synthetic inputs and assert the bad cases are still refused",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    missing = [flag for flag in ("version", "commit", "runs", "tags") if not getattr(args, flag)]
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
        tags = [
            line.strip()
            for line in Path(args.tags).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        tag, run = decide(args.version, args.commit, payload, tags)
    except GateRefused as reason:
        print(f"release gate refused: {reason}", file=sys.stderr)
        return 1

    print(
        f"release gate passed: {tag} may be created on {args.commit} — CI concluded success on "
        f"its push to {RELEASE_BRANCH} ({run.get('html_url') or 'run ' + str(run.get('id'))}), "
        f"and the tag does not exist yet.",
        file=sys.stderr,
    )
    print(tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
