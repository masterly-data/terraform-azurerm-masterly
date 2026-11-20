"""The ca-serve route set ca-edge renders is a reviewed list of read routes under /v1/.

`edge-serve-routes.json` at the module root names the requests ca-edge routes as ca-serve's
(ADR 0120 §2): the reads ADR 0112 makes replica-eligible, which the backend marks with
`x-masterly-serve` and publishes as `docs/contract/edge-routes.json`. The file pins that list as
of one backend release (`source.ref`), as `{method, path}` entries in the source's order, and
`edge.tf` reads it with `file()` at plan time and renders one Envoy route per entry. Re-pinning is
a deliberate edit to the file, reviewed like code; nothing fetches it.

ca-edge is the public machine entry point, so the file is held to what the rendering assumes:

  * every path is under /v1/: a serve route can only narrow what the v1 route already forwards,
    never open a path the edge answers 404 today;
  * every method is a read (GET, HEAD or POST, the POSTs being reads that take a body), never
    PUT, PATCH or DELETE, so no write is ever routed as a read;
  * a path holds only [A-Za-z0-9/_:{}-], and every `{var}` is a lower-case name: the characters
    need no escaping in the anchored regex `edge.tf` builds, and nothing else can widen it;
  * no entry is listed twice, the entries are sorted by (path, method) as the source is, and
    `source.ref` names a release (vX.Y.Z), so a diff against the source reads line for line.

`--selftest` runs first in CI: it proves each of those is still rejected, so a check that has
quietly stopped detecting fails loudly instead of passing the file for the wrong reason.

Run:
    python3 scripts/check_edge_serve_routes.py            # check (what CI runs)
    python3 scripts/check_edge_serve_routes.py --selftest # the check still rejects a bad file

`EDGE_SERVE_ROUTES_FILE` overrides the file checked. Standard library only, no network.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FILE_NAME = "edge-serve-routes.json"
ROUTES_FILE = Path(os.environ.get("EDGE_SERVE_ROUTES_FILE", REPO_ROOT / FILE_NAME))

# Reads only. HEAD is a read Envoy may be asked to route; the writes never are.
READ_METHODS = ("GET", "HEAD", "POST")
# The /v1 API is the only prefix a serve route may sit under.
PATH_PREFIX = "/v1/"
# No regex metacharacter but the braces, which edge.tf replaces: the rest needs no escaping.
# Matched with fullmatch, so a trailing newline is not let through by `$`.
PATH_CHARACTERS = re.compile(r"[A-Za-z0-9/_:{}-]+")
# A path variable as edge.tf matches it (`\{[a-z_]+\}`), rendered as [^/:]+.
PATH_VARIABLE = re.compile(r"\{[a-z_]+\}")
# A release tag: vMAJOR.MINOR.PATCH (fullmatch).
RELEASE_REF = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


class CheckError(Exception):
    """A finding, reported with its reason; the exit code is the caller's."""


# --- The decisions ---------------------------------------------------------------------


def source_findings(source: object) -> list[str]:
    """What is wrong with the source record: the repository, path and release it was read from."""
    if not isinstance(source, dict):
        return ["`source` must be an object naming repository, path and ref"]
    found = []
    for key in ("repository", "path"):
        if not isinstance(source.get(key), str) or not source[key]:
            found.append(f"`source.{key}` is missing or empty")
    ref = source.get("ref")
    if ref is None:
        found.append("`source.ref` is missing: the file must name the backend release it was read at")
    elif not isinstance(ref, str) or not RELEASE_REF.fullmatch(ref):
        found.append(f"`source.ref` {ref!r} is not a release tag (vX.Y.Z): pin a release, not a branch")
    return found


def entry_findings(index: int, entry: object) -> list[str]:
    """What is wrong with one {method, path} entry, on its own."""
    where = f"routes[{index}]"
    if not isinstance(entry, dict) or set(entry) != {"method", "path"}:
        return [f"{where} must be an object with exactly `method` and `path`"]
    method, path = entry["method"], entry["path"]
    if not isinstance(method, str) or not isinstance(path, str):
        return [f"{where}: `method` and `path` must be strings"]
    found = []
    if method not in READ_METHODS:
        found.append(
            f"{where}: method {method!r} is not a read ({', '.join(READ_METHODS)}); "
            "a write must never be routed as a read"
        )
    if not path.startswith(PATH_PREFIX):
        found.append(f"{where}: path {path!r} is not under {PATH_PREFIX}")
    if not PATH_CHARACTERS.fullmatch(path):
        found.append(f"{where}: path {path!r} has a character outside [A-Za-z0-9/_:{{}}-]")
    elif "{" in PATH_VARIABLE.sub("", path) or "}" in PATH_VARIABLE.sub("", path):
        found.append(f"{where}: path {path!r} has a malformed {{var}}: a variable is {{[a-z_]+}}")
    if "//" in path or path.endswith("/"):
        found.append(f"{where}: path {path!r} has an empty segment, which the edge's merged path never matches")
    return found


def list_findings(routes: list[dict[str, str]]) -> list[str]:
    """What is wrong with the list as a whole: duplicates, and the order."""
    found = []
    keys = [(r["path"], r["method"]) for r in routes]
    seen: set[tuple[str, str]] = set()
    for path, method in keys:
        if (path, method) in seen:
            found.append(f"{method} {path} is listed more than once")
        seen.add((path, method))
    for before, after in zip(keys, keys[1:]):
        if before > after:
            found.append(
                f"{after[1]} {after[0]} comes after {before[1]} {before[0]}: "
                "keep the entries sorted by (path, method), as the source is"
            )
    return found


def findings(document: object) -> list[str]:
    """Every reason the document is not a route set edge.tf may render; empty when it is."""
    if not isinstance(document, dict) or set(document) != {"source", "routes"}:
        return [f"{FILE_NAME} must be an object with exactly `source` and `routes`"]
    found = source_findings(document["source"])
    routes = document["routes"]
    if not isinstance(routes, list) or not routes:
        return found + ["`routes` must be a non-empty list"]
    entry_problems = [problem for index, entry in enumerate(routes) for problem in entry_findings(index, entry)]
    if entry_problems:
        return found + entry_problems
    return found + list_findings(routes)


# --- The check -------------------------------------------------------------------------


def read(path: Path) -> object:
    if not path.is_file():
        raise CheckError(f"{path} not found")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise CheckError(f"{path.name} is not valid JSON ({exc})") from None


def run_check(file: Path) -> int:
    try:
        document = read(file)
        problems = findings(document)
        if problems:
            raise CheckError(f"{file.name}:\n  " + "\n  ".join(problems))
    except CheckError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    # findings() came back empty, so the document has the shape it checks.
    routes, source = document["routes"], document["source"]  # type: ignore[index]
    counts = {m: sum(r["method"] == m for r in routes) for m in READ_METHODS}
    methods = ", ".join(f"{count} {m}" for m, count in counts.items() if count)
    print(
        f"{file.name}: {len(routes)} routes ({methods}) from {source['repository']} {source['path']} "
        f"at {source['ref']}, each a read under {PATH_PREFIX}, unique and in (path, method) order."
    )
    return 0


# --- Selftest --------------------------------------------------------------------------
#
# A rule with nothing enforcing it is this repository's characteristic defect, and a check nobody
# has watched reject anything is a hypothesis. Each scenario changes one thing in a good document
# and asserts the finding by its text.

CANONICAL = {
    "source": {"repository": "masterly-application-backend", "path": "docs/contract/edge-routes.json", "ref": "v1.2.3"},
    "routes": [
        {"method": "GET", "path": "/v1/catalog/products"},
        {"method": "POST", "path": "/v1/catalog:search"},
        {"method": "GET", "path": "/v1/consume/products/{product_id}"},
        {"method": "POST", "path": "/v1/consume/products/{product_id}:read"},
        {"method": "GET", "path": "/v1/golden"},
        {"method": "HEAD", "path": "/v1/golden"},
    ],
}


def _with(change) -> dict:
    """A copy of the canonical document with one change applied."""
    document = copy.deepcopy(CANONICAL)
    change(document)
    return document


def path(index: int, value: str):
    return lambda d: d["routes"][index].__setitem__("path", value)


def method(index: int, value: str):
    return lambda d: d["routes"][index].__setitem__("method", value)


def _scenarios() -> list[tuple[str, object, str]]:
    """(name, document, text a finding must contain; empty for no finding)."""
    return [
        ("the canonical document passes", CANONICAL, ""),
        ("a path under /v2/ fails", _with(path(0, "/v2/catalog/products")), "is not under /v1/"),
        ("a path under /mcp/ fails", _with(path(0, "/mcp/tools")), "is not under /v1/"),
        ("the bare /v1 prefix fails", _with(path(0, "/v1")), "is not under /v1/"),
        ("a PUT entry fails", _with(method(4, "PUT")), "method 'PUT' is not a read"),
        ("a PATCH entry fails", _with(method(4, "PATCH")), "method 'PATCH' is not a read"),
        ("a DELETE entry fails", _with(method(4, "DELETE")), "method 'DELETE' is not a read"),
        ("a lower-case get fails", _with(method(0, "get")), "method 'get' is not a read"),
        ("a duplicate entry fails", _with(lambda d: d["routes"].insert(1, dict(d["routes"][0]))), "is listed more than once"),
        (
            "an unsorted list fails",
            _with(lambda d: d["routes"].__setitem__(slice(0, 2), [d["routes"][1], d["routes"][0]])),
            "keep the entries sorted by (path, method)",
        ),
        (
            "methods out of order on one path fail",
            _with(lambda d: d["routes"].__setitem__(slice(4, 6), [d["routes"][5], d["routes"][4]])),
            "GET /v1/golden comes after HEAD /v1/golden",
        ),
        ("a dot in a path fails", _with(path(4, "/v1/golden.json")), "has a character outside"),
        ("a regex wildcard in a path fails", _with(path(4, "/v1/golden.*")), "has a character outside"),
        ("a space in a path fails", _with(path(4, "/v1/gol den")), "has a character outside"),
        ("a trailing newline in a path fails", _with(path(4, "/v1/golden\n")), "has a character outside"),
        ("a camel-case {var} fails", _with(path(2, "/v1/consume/products/{productId}")), "has a malformed {var}"),
        ("an empty {} fails", _with(path(2, "/v1/consume/products/{}")), "has a malformed {var}"),
        ("an unclosed { fails", _with(path(2, "/v1/consume/products/{product_id")), "has a malformed {var}"),
        ("a stray } fails", _with(path(2, "/v1/consume/products/product_id}")), "has a malformed {var}"),
        ("an empty segment fails", _with(path(4, "/v1//golden")), "has an empty segment"),
        ("a missing source ref fails", _with(lambda d: d["source"].pop("ref")), "`source.ref` is missing"),
        ("a branch as the source ref fails", _with(lambda d: d["source"].__setitem__("ref", "main")), "is not a release tag"),
        ("a ref without its v fails", _with(lambda d: d["source"].__setitem__("ref", "0.138.0")), "is not a release tag"),
        ("a ref with a trailing newline fails", _with(lambda d: d["source"].__setitem__("ref", "v1.2.3\n")), "is not a release tag"),
        ("a missing source fails", _with(lambda d: d.pop("source")), "exactly `source` and `routes`"),
        ("an empty route list fails", _with(lambda d: d.__setitem__("routes", [])), "non-empty list"),
        ("an entry with an extra key fails", _with(lambda d: d["routes"][0].__setitem__("role", "serve")), "exactly `method` and `path`"),
    ]


def selftest() -> int:
    import contextlib
    import io

    failures = 0

    def report(ok: bool, name: str, detail: str) -> None:
        nonlocal failures
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            failures += 1
            print(f"       {detail}")

    for name, document, expected in _scenarios():
        found = findings(document)
        ok = not found if not expected else any(expected in problem for problem in found)
        report(ok, name, f"expected {repr(expected) if expected else 'no finding'}; got {found}")

    # End to end, through a file, as CI runs it: exit 0 on a good file, 1 on a bad or unparsable one.
    for name, text, expected_code in (
        ("the check exits 0 on a good file", json.dumps(CANONICAL), 0),
        ("the check exits 1 on a bad file", json.dumps(_with(method(0, "DELETE"))), 1),
        ("the check exits 1 on a file that is not JSON", "{", 1),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / FILE_NAME
            staged.write_text(text, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = run_check(staged)
            report(code == expected_code, name, f"expected exit {expected_code}, got {code}: {(out.getvalue() + err.getvalue()).strip()}")

    if failures:
        print(f"selftest: {failures} scenario(s) did not behave as expected", file=sys.stderr)
        return 1
    print("selftest: the check still rejects what it should")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--selftest", action="store_true", help="prove the check still rejects a bad file")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    return run_check(ROUTES_FILE)


if __name__ == "__main__":
    raise SystemExit(main())
