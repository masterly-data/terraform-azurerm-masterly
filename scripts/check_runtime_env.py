"""The runtime-environment manifest states every environment variable the module sets, per app.

`RUNTIME_ENV.json` is this module's machine-readable answer to "which environment variables does
the module put on `ca-api`, `ca-workers` and `ca-frontend`?" — the names only, never a value.
The applications read those names at start, and each application's own repository documents
the contract it reads; this file is what lets those repositories check that the names the
module sets are names their code reads and their runbooks name, without parsing Terraform.

It is GENERATED from the `.tf` files at the module root and never written by hand. The env a
container receives is assembled from locals spread over several files — `main.tf`, `email.tf`,
`entra-auth.tf`, `keyvault.tf`, `redis.tf`, `workers.tf` — and merged into each app's `env` and
`env_secret_refs`, so the one honest source is the files themselves. This script resolves that
graph: it reads each `module "<app>"` block that instantiates `./modules/aca-container-app`,
follows every `local.<name>` reference its `env` / `env_secret_refs` expressions make, and
collects the keys of the maps it reaches. A name set only inside a comment is not set.

A manifest nobody is forced to regenerate is a documented good intention, so CI runs this
script on every pull request and fails when the committed manifest is not what the `.tf`
files produce — the same forcing function `check_release_manifest.py` is for `MANIFEST.json`.
Two further things are checked in the same pass, because their only input lives here:

  * every name in `scripts/diagnostic-bundle.sh`'s `ENV_VALUE_ALLOWLIST` — the variables
    whose VALUE a support bundle may carry — is a name the module sets on some app. A
    misspelt entry there is a value silently redacted from every bundle;
  * the manifest's schema version is the one `docs/runtime-env.md` describes.

`--selftest` runs first in CI: synthetic module trees prove the check still rejects a stale
manifest, a hand-edited one, a dangling `local.` reference and an allowlist entry nothing
sets, so a detector that has quietly stopped detecting fails loudly instead of passing this
repository for the wrong reason.

Run:
    python3 scripts/check_runtime_env.py            # check (what CI runs)
    python3 scripts/check_runtime_env.py --write    # regenerate RUNTIME_ENV.json from the .tf files
    python3 scripts/check_runtime_env.py --selftest # the check still rejects a bad tree

`RUNTIME_ENV_ROOT` overrides the module root, which is how the selftest exercises the check
against staged trees. Standard library only, no network, no HCL parser: the names are read
as text, which is how they are written.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_ROOT = Path(os.environ.get("RUNTIME_ENV_ROOT", REPO_ROOT))

MANIFEST_NAME = "RUNTIME_ENV.json"
RELEASE_MANIFEST_NAME = "MANIFEST.json"
BUNDLE_SCRIPT = Path("scripts") / "diagnostic-bundle.sh"
CONTRACT_DOC = "docs/runtime-env.md"

# The schema version this script — and docs/runtime-env.md, the contract the application
# repositories read the manifest against — knows how to speak. Bumping the manifest without
# bumping both is how a consumer starts parsing a shape nobody promised it.
SCHEMA_VERSION = 1

# The submodule whose instances are the install's container apps. A `module` block with any
# other source carries no app env.
CONTAINER_APP_SOURCE = "./modules/aca-container-app"

# A top-level `locals {` or `module "<label>" {` header, at column 0, as terraform fmt writes it.
BLOCK_HEADER = re.compile(r'^(locals|module)(?:\s+"([^"]+)")?\s*\{\s*$')
# A depth-1 attribute inside such a block: two-space indent, `name =` (never `==`).
ATTRIBUTE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_-]*)\s*=(?!=)\s*(.*)$")
# A map key as the env maps write them: an uppercase identifier followed by `=`.
ENV_KEY = re.compile(r"\b([A-Z][A-Z0-9_]*)\s*=(?!=)")
LOCAL_REF = re.compile(r"\blocal\.([A-Za-z_][A-Za-z0-9_]*)")
QUOTED = re.compile(r'^"([^"]*)"$')

# A whole-line comment, or a trailing one after whitespace. Not a bare `#` or `//` inside a
# string (`postgresql://…`), which no whitespace precedes.
FULL_LINE_COMMENT = re.compile(r"^\s*(#|//)")
TRAILING_COMMENT = re.compile(r"\s+(#|//).*$")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)

ALLOWLIST = re.compile(r"ENV_VALUE_ALLOWLIST='(\[.*?\])'", re.DOTALL)


class CheckError(Exception):
    """A finding, reported with its reason; the exit code is the caller's."""


# --- Reading the .tf files -----------------------------------------------------------


def uncommented(text: str) -> str:
    """The configuration's instructions only — a name that appears solely in a comment is not set."""
    text = BLOCK_COMMENT.sub("", text)
    kept = []
    for line in text.splitlines():
        if FULL_LINE_COMMENT.match(line):
            continue
        kept.append(TRAILING_COMMENT.sub("", line))
    return "\n".join(kept)


def top_level_blocks(text: str) -> list[tuple[str, str | None, list[str]]]:
    """Every column-0 `locals` / `module` block as (kind, label, body lines)."""
    blocks: list[tuple[str, str | None, list[str]]] = []
    current: tuple[str, str | None, list[str]] | None = None
    for line in text.splitlines():
        if current is None:
            header = BLOCK_HEADER.match(line)
            if header:
                current = (header.group(1), header.group(2), [])
            continue
        if line == "}":
            blocks.append(current)
            current = None
            continue
        current[2].append(line)
    return blocks


def attributes(body: list[str]) -> dict[str, str]:
    """The block's depth-1 attributes, each with the full text of its expression."""
    found: dict[str, str] = {}
    name: str | None = None
    for line in body:
        attribute = ATTRIBUTE.match(line)
        if attribute:
            name = attribute.group(1)
            found[name] = attribute.group(2)
        elif name is not None:
            found[name] += "\n" + line
    return found


def read_tree(root: Path) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """(every local by name, every container-app module block's attributes by its app name)."""
    tf_files = sorted(root.glob("*.tf"))
    if not tf_files:
        raise CheckError(f"no .tf files at {root} — is RUNTIME_ENV_ROOT the module root?")
    locals_by_name: dict[str, str] = {}
    apps: dict[str, dict[str, str]] = {}
    for path in tf_files:
        for kind, label, body in top_level_blocks(uncommented(path.read_text(encoding="utf-8"))):
            attrs = attributes(body)
            if kind == "locals":
                duplicates = sorted(set(attrs) & set(locals_by_name))
                if duplicates:
                    raise CheckError(f"{path.name}: local(s) defined twice: {', '.join(duplicates)}")
                locals_by_name.update(attrs)
                continue
            source = QUOTED.match(attrs.get("source", "").strip())
            if source is None or source.group(1) != CONTAINER_APP_SOURCE:
                continue
            app = QUOTED.match(attrs.get("name", "").strip())
            if app is None:
                raise CheckError(
                    f'{path.name}: module "{label}" instantiates {CONTAINER_APP_SOURCE} but its '
                    "`name` is not a quoted literal, so the manifest cannot key it"
                )
            if app.group(1) in apps:
                raise CheckError(f"{path.name}: two container apps are named {app.group(1)}")
            apps[app.group(1)] = attrs
    return locals_by_name, apps


def names_in(expression: str, locals_by_name: dict[str, str], visiting: tuple[str, ...] = ()) -> set[str]:
    """Every map key the expression sets, following `local.<name>` references transitively."""
    names = set(ENV_KEY.findall(expression))
    for ref in LOCAL_REF.findall(expression):
        if ref in visiting:
            continue  # a cycle; terraform itself refuses one, so nothing is lost by stopping here
        if ref not in locals_by_name:
            chain = " -> ".join((*visiting, ref))
            raise CheckError(f"`local.{ref}` is referenced but defined in no locals block ({chain})")
        names |= names_in(locals_by_name[ref], locals_by_name, (*visiting, ref))
    return names


def generate(root: Path) -> dict[str, object]:
    """The manifest the .tf files at `root` produce."""
    locals_by_name, apps = read_tree(root)
    if not apps:
        raise CheckError(f"no module block instantiating {CONTAINER_APP_SOURCE} found at {root}")
    release_manifest = root / RELEASE_MANIFEST_NAME
    if not release_manifest.is_file():
        raise CheckError(f"{RELEASE_MANIFEST_NAME} not found at {root}; the module's name is read from it")
    module_name = json.loads(release_manifest.read_text(encoding="utf-8")).get("module")
    if not isinstance(module_name, str) or not module_name:
        raise CheckError(f"{RELEASE_MANIFEST_NAME} carries no `module` name")
    manifest_apps: dict[str, dict[str, list[str]]] = {}
    for app, attrs in sorted(apps.items()):
        manifest_apps[app] = {
            "env": sorted(names_in(attrs.get("env", ""), locals_by_name)),
            "env_secret_refs": sorted(names_in(attrs.get("env_secret_refs", ""), locals_by_name)),
        }
    return {"schema_version": SCHEMA_VERSION, "module": module_name, "apps": manifest_apps}


def render(manifest: dict[str, object]) -> str:
    return json.dumps(manifest, indent=2) + "\n"


# --- The checks ---------------------------------------------------------------------


def check_manifest(root: Path, write: bool) -> dict[str, object]:
    """The committed manifest is byte-for-byte what the .tf files produce (or write it so)."""
    manifest = generate(root)
    expected = render(manifest)
    path = root / MANIFEST_NAME
    if write:
        path.write_text(expected, encoding="utf-8")
        print(f"wrote {MANIFEST_NAME} from {len(list(root.glob('*.tf')))} .tf files")
        return manifest
    if not path.is_file():
        raise CheckError(
            f"{MANIFEST_NAME} is missing; `python3 scripts/check_runtime_env.py --write` creates it"
        )
    actual = path.read_text(encoding="utf-8")
    if actual != expected:
        try:
            committed = json.loads(actual)
        except json.JSONDecodeError as exc:
            raise CheckError(f"{MANIFEST_NAME} is not valid JSON ({exc})") from None
        raise CheckError(
            f"{MANIFEST_NAME} is not what the .tf files produce"
            + describe_drift(committed, manifest)
            + "\n  `python3 scripts/check_runtime_env.py --write` regenerates it; never edit it by hand."
        )
    return manifest


def describe_drift(committed: object, generated: dict[str, object]) -> str:
    """Name the apps and variables that differ, so the failure says what moved."""
    lines: list[str] = []
    if not isinstance(committed, dict):
        return " (the committed file is not a JSON object)"
    if committed.get("schema_version") != generated["schema_version"]:
        lines.append(
            f"  schema_version: committed {committed.get('schema_version')!r}, "
            f"generated {generated['schema_version']!r}"
        )
    if committed.get("module") != generated["module"]:
        lines.append(f"  module: committed {committed.get('module')!r}, generated {generated['module']!r}")
    committed_apps = committed.get("apps") if isinstance(committed.get("apps"), dict) else {}
    generated_apps = generated["apps"]
    assert isinstance(generated_apps, dict)
    for app in sorted(set(committed_apps) | set(generated_apps)):
        if app not in generated_apps:
            lines.append(f"  {app}: in the committed manifest, set by no module block")
            continue
        if app not in committed_apps:
            lines.append(f"  {app}: set by the module, missing from the committed manifest")
            continue
        for key in ("env", "env_secret_refs"):
            before = set(committed_apps[app].get(key, []) or [])
            after = set(generated_apps[app][key])
            for name in sorted(after - before):
                lines.append(f"  {app}.{key}: the module sets {name}; the manifest does not list it")
            for name in sorted(before - after):
                lines.append(f"  {app}.{key}: the manifest lists {name}; the module no longer sets it")
    if not lines:
        lines.append("  (same names, different bytes — ordering or formatting was edited)")
    return ":\n" + "\n".join(lines)


def check_allowlist(root: Path, manifest: dict[str, object]) -> int:
    """Every name whose value the diagnostic bundle may carry is a name the module sets."""
    script = root / BUNDLE_SCRIPT
    if not script.is_file():
        raise CheckError(f"{BUNDLE_SCRIPT} not found at {root}")
    match = ALLOWLIST.search(script.read_text(encoding="utf-8"))
    if match is None:
        raise CheckError(f"{BUNDLE_SCRIPT} carries no ENV_VALUE_ALLOWLIST='[…]' — the pattern or the script moved")
    try:
        allowlist = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise CheckError(f"{BUNDLE_SCRIPT}: ENV_VALUE_ALLOWLIST is not valid JSON ({exc})") from None
    apps = manifest["apps"]
    assert isinstance(apps, dict)
    set_names: set[str] = set()
    for spec in apps.values():
        set_names |= set(spec["env"]) | set(spec["env_secret_refs"])
    unset = sorted(name for name in allowlist if name not in set_names)
    if unset:
        raise CheckError(
            f"{BUNDLE_SCRIPT}'s ENV_VALUE_ALLOWLIST names "
            + ", ".join(unset)
            + ", which the module sets on no app. The bundle redacts every value not on the list, "
            "so a misspelt entry is a value quietly missing from every bundle: fix the name, or "
            "drop the entry if the variable is gone."
        )
    return len(allowlist)


def run_check(root: Path, write: bool) -> int:
    try:
        manifest = check_manifest(root, write)
        listed = check_allowlist(root, manifest)
    except CheckError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    apps = manifest["apps"]
    assert isinstance(apps, dict)
    summary = ", ".join(
        f"{app} ({len(spec['env'])} env + {len(spec['env_secret_refs'])} secret refs)"
        for app, spec in apps.items()
    )
    print(f"{MANIFEST_NAME} states what the module sets on {summary};")
    print(f"every one of the {listed} names in {BUNDLE_SCRIPT}'s ENV_VALUE_ALLOWLIST is among them.")
    return 0


# --- Selftest -----------------------------------------------------------------------
#
# The check exists because a rule with nothing enforcing it is this repository's characteristic
# defect, and a check nobody has watched reject anything is a hypothesis. Each scenario stages
# a synthetic module tree and asserts the outcome by name.

CANONICAL_MAIN_TF = '''# A synthetic module root: the shapes the real files use, nothing else.
locals {
  # MASTERLY_IN_A_COMMENT = "is not set"
  install_env = merge(
    {
      MASTERLY_MODE   = var.mode
      MASTERLY_REGION = var.region # trailing comment: MASTERLY_IN_TRAILING_COMMENT = "x"
    },
    var.org_name != null ? { MASTERLY_ORG_NAME = var.org_name } : {},
  )

  api_env = merge(
    local.install_env,
    local.extra_env, # defined in another file, two hops deep
  )

  api_env_secret_refs = {
    MASTERLY_DATABASE_URL = "database-url"
  }
}

module "api" {
  source = "./modules/aca-container-app"

  name            = "ca-api"
  env             = local.api_env
  env_secret_refs = local.api_env_secret_refs
}

module "frontend" {
  source = "./modules/aca-container-app"

  name = "ca-frontend"
  env = merge(
    {
      MASTERLY_API_BASE_URL = "http://${module.api.name}"
    },
    var.identity_binding == "dev" ? { MASTERLY_ALLOW_DEV_BINDING = "true" } : {},
  )
  env_secret_refs = var.identity_binding == "oidc" ? {
    MASTERLY_OIDC_CLIENT_SECRET = "oidc-client-secret"
  } : {}
}

module "not_an_app" {
  source = "./modules/something-else"

  name = "ca-not-an-app"
  env  = { MASTERLY_NOT_AN_APP = "x" }
}
'''

CANONICAL_EXTRA_TF = """locals {
  extra_env = merge(
    var.enabled ? { MASTERLY_EXTRA = "x" } : {},
    local.deeper_env,
  )

  deeper_env = {
    AZURE_CLIENT_ID = module.identity.client_id
  }
}
"""

CANONICAL_RELEASE_MANIFEST = '{"schema_version": 1, "module": "example/masterly/azurerm", "latest": "0.0.0", "releases": {}}\n'

CANONICAL_BUNDLE_SCRIPT = """#!/usr/bin/env bash
ENV_VALUE_ALLOWLIST='[
  "MASTERLY_MODE", "MASTERLY_REGION", "MASTERLY_API_BASE_URL"
]'
"""

CANONICAL_MANIFEST = {
    "schema_version": 1,
    "module": "example/masterly/azurerm",
    "apps": {
        "ca-api": {
            "env": ["AZURE_CLIENT_ID", "MASTERLY_EXTRA", "MASTERLY_MODE", "MASTERLY_ORG_NAME", "MASTERLY_REGION"],
            "env_secret_refs": ["MASTERLY_DATABASE_URL"],
        },
        "ca-frontend": {
            "env": ["MASTERLY_ALLOW_DEV_BINDING", "MASTERLY_API_BASE_URL"],
            "env_secret_refs": ["MASTERLY_OIDC_CLIENT_SECRET"],
        },
    },
}


def _stage(
    root: Path,
    *,
    main_tf: str = CANONICAL_MAIN_TF,
    extra_tf: str = CANONICAL_EXTRA_TF,
    manifest: object = CANONICAL_MANIFEST,
    bundle_script: str = CANONICAL_BUNDLE_SCRIPT,
) -> None:
    (root / "main.tf").write_text(main_tf, encoding="utf-8")
    (root / "extra.tf").write_text(extra_tf, encoding="utf-8")
    (root / RELEASE_MANIFEST_NAME).write_text(CANONICAL_RELEASE_MANIFEST, encoding="utf-8")
    (root / "scripts").mkdir()
    (root / BUNDLE_SCRIPT).write_text(bundle_script, encoding="utf-8")
    if manifest is not None:
        text = manifest if isinstance(manifest, str) else render(manifest)  # type: ignore[arg-type]
        (root / MANIFEST_NAME).write_text(text, encoding="utf-8")


def _scenarios() -> list[tuple[str, dict[str, object], int, str]]:
    """(name, staging overrides, expected exit code, text the report must contain)."""
    main_with_new_name = CANONICAL_MAIN_TF.replace(
        "      MASTERLY_REGION = var.region", "      MASTERLY_REGION = var.region\n      MASTERLY_NEW = var.new"
    )
    main_dangling = CANONICAL_MAIN_TF.replace("local.extra_env,", "local.extra_env,\n    local.gone_env,")
    main_unquoted_name = CANONICAL_MAIN_TF.replace('name            = "ca-api"', "name            = local.api_name")
    hand_edited = render(CANONICAL_MANIFEST).replace('"MASTERLY_MODE",\n', "")
    reordered = json.dumps(CANONICAL_MANIFEST) + "\n"
    allowlist_unset = CANONICAL_BUNDLE_SCRIPT.replace('"MASTERLY_MODE"', '"MASTERLY_MOED"')
    allowlist_other_app = CANONICAL_BUNDLE_SCRIPT.replace('"MASTERLY_MODE"', '"MASTERLY_NOT_AN_APP"')
    return [
        ("the canonical tree passes", {}, 0, "every one of the"),
        (
            "a name the module starts setting fails until the manifest is regenerated",
            {"main_tf": main_with_new_name},
            1,
            "ca-api.env: the module sets MASTERLY_NEW; the manifest does not list it",
        ),
        (
            "a hand-edited manifest fails naming the variable removed",
            {"manifest": hand_edited},
            1,
            "ca-api.env: the module sets MASTERLY_MODE; the manifest does not list it",
        ),
        (
            "the same names in a different layout fail (the file is generated, not typed)",
            {"manifest": reordered},
            1,
            "same names, different bytes",
        ),
        ("a missing manifest fails", {"manifest": None}, 1, "is missing"),
        (
            "a dangling local reference fails rather than silently dropping names",
            {"main_tf": main_dangling},
            1,
            "`local.gone_env` is referenced but defined in no locals block",
        ),
        (
            "an app whose name is not a literal fails rather than being keyed by a guess",
            {"main_tf": main_unquoted_name},
            1,
            "`name` is not a quoted literal",
        ),
        (
            "an allowlist entry the module sets on no app fails",
            {"bundle_script": allowlist_unset},
            1,
            "ENV_VALUE_ALLOWLIST names MASTERLY_MOED, which the module sets on no app",
        ),
        (
            "an allowlist entry set only by a non-app module block fails",
            {"bundle_script": allowlist_other_app},
            1,
            "names MASTERLY_NOT_AN_APP, which the module sets on no app",
        ),
    ]


def selftest() -> int:
    import contextlib
    import io

    failures = 0
    for name, overrides, expected_code, expected_text in _scenarios():
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _stage(root, **overrides)  # type: ignore[arg-type]
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = run_check(root, write=False)
            report = out.getvalue() + err.getvalue()
            ok = code == expected_code and expected_text in report
            print(f"  {'ok  ' if ok else 'FAIL'} {name}")
            if not ok:
                failures += 1
                print(f"       expected exit {expected_code} and {expected_text!r}; got exit {code}:")
                for line in report.strip().splitlines():
                    print(f"       | {line}")
    # The generator's own output is what `--write` commits, so prove its content once, directly:
    # a comment-only name is absent, a two-hop local is attributed, a non-app module is skipped.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _stage(root, manifest=None)
        generated = generate(root)
        ok = generated == CANONICAL_MANIFEST
        print(f"  {'ok  ' if ok else 'FAIL'} the generator attributes names through two hops, skips comments and non-app blocks")
        if not ok:
            failures += 1
            print(f"       generated: {json.dumps(generated)}")
    if failures:
        print(f"selftest: {failures} scenario(s) did not behave as expected", file=sys.stderr)
        return 1
    print("selftest: the check still rejects what it should")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--write", action="store_true", help=f"regenerate {MANIFEST_NAME} from the .tf files")
    parser.add_argument("--selftest", action="store_true", help="prove the check still rejects a bad tree")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    return run_check(MODULE_ROOT, write=args.write)


if __name__ == "__main__":
    raise SystemExit(main())
