#!/usr/bin/env bash
# The IaC scan the iac-scan workflow runs, runnable locally wherever `trivy` is installed.
#
#   scripts/iac_scan.sh --selftest         the scanner reports the known-bad fixture
#   scripts/iac_scan.sh --check-selftest   --check rejects each kind of bad entry (no trivy needed)
#   scripts/iac_scan.sh --check            every .trivyignore.yaml entry has a rule ID, paths that
#                                          name real files (no glob, never empty) and a README
#                                          departure heading that exists, and no tracked .tf file
#                                          carries an inline ignore comment
#
# Both --check modes read .trivyignore.yaml with python3 and PyYAML (python3-yaml, on the
# GitHub-hosted Ubuntu runners); without PyYAML they fail rather than pass unchecked.
#   scripts/iac_scan.sh --sarif F          scan the module, write SARIF to F, never fail on findings
#   scripts/iac_scan.sh --gate             scan the module, fail on HIGH/CRITICAL
set -euo pipefail

fixtures=".github/iac-scan-fixtures"
ignorefile=".trivyignore.yaml"
phrase="Where this module departs from Azure's recommended baseline"

trivy_config() {
  trivy config --skip-check-update --severity HIGH,CRITICAL "$@"
}

selftest() {
  local out found
  out="$(mktemp)"
  trivy_config --format json --output "$out" "$fixtures"
  found="$(jq '[.Results[]?.Misconfigurations[]?] | length' "$out")"
  rm -f "$out"
  if [ "$found" -lt 1 ]; then
    echo "::error::iac-scan self-test: the known-bad fixture produced no finding, so a clean scan proves nothing"
    exit 1
  fi
  echo "self-test: scanner reported $found finding(s) on the known-bad fixture"
}

# check_ignorefile IGNOREFILE README ROOT
# The file is parsed as YAML, never matched line by line: Trivy applies whatever the YAML means,
# whatever its key order, flow or block style or trailing newline, so the check reads the same
# structure. It fails closed: a parse error, a second document, a duplicate key, a top-level key
# other than `misconfigurations` or an entry key other than id/paths/statement is an error. Each
# entry needs a rule ID; a non-empty paths list, each a literal relative path to a file under ROOT
# (Trivy matches paths as doublestar globs, so a glob, a directory or no paths would suppress the
# rule across many files); and a statement naming the README section and one of its departure
# headings (the #### headings inside "### <phrase>", up to the next ## or ### heading), compared
# as a literal string. `misconfigurations: []` has nothing to check.
check_ignorefile() {
  python3 - "$1" "$2" "$3" "$phrase" <<'PY'
import os
import re
import sys

path, readme, root, phrase = sys.argv[1:5]
try:
    import yaml
except ImportError:
    print(f"::error::{path}: checking it needs python3 with PyYAML (python3-yaml)")
    sys.exit(1)

errors = []


def error(msg):
    errors.append(msg)
    print(f"::error::{path}: {msg}")


def duplicate_keys(node, seen):
    if id(node) in seen:
        return
    seen.add(id(node))
    if isinstance(node, yaml.MappingNode):
        keys = [k.value for k, _ in node.value if isinstance(k, yaml.ScalarNode)]
        for key in sorted({k for k in keys if keys.count(k) > 1}):
            error(f"line {node.start_mark.line + 1}: key '{key}' appears twice")
        for _, value in node.value:
            duplicate_keys(value, seen)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            duplicate_keys(item, seen)


def departure_headings():
    headings, inside = [], False
    with open(readme, encoding="utf-8") as f:
        for line in f.read().splitlines():
            if line == f"### {phrase}":
                inside = True
            elif inside and re.match(r"###? ", line):
                break
            elif inside and line.startswith("#### "):
                headings.append(line[len("#### "):])
    return headings


def check_path(label, p):
    if not isinstance(p, str) or not p:
        error(f"{label}: path {p!r} is not a file name")
    elif re.search(r"[\[\]*?{}!\\]", p):
        error(f"{label}: path '{p}' is a glob; name the file")
    elif p.startswith("/") or any(s in ("", ".", "..") for s in p.split("/")):
        error(f"{label}: path '{p}' is not a plain path relative to the repository root")
    elif not os.path.isfile(os.path.join(root, p)):
        error(f"{label}: path '{p}' is not a file in the repository")


def check_statement(label, statement, departures):
    if not isinstance(statement, str) or not statement.strip():
        error(f"{label}: no statement naming its README departure")
        return
    m = re.search('README "' + re.escape(phrase) + '" -> "(.*)"\\s*$', statement)
    if not m:
        error(f"{label}: statement does not name README \"{phrase}\" -> \"<heading>\"")
    elif m.group(1) not in departures:
        error(f"{label}: names '{m.group(1)}', which is not a departure heading under README \"{phrase}\"")


try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    node = yaml.compose(text, Loader=yaml.SafeLoader)
    data = yaml.safe_load(text)
except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
    error(f"not one readable YAML document: {e}")
    sys.exit(1)
if node is not None:
    duplicate_keys(node, set())
try:
    departures = departure_headings()
except OSError as e:
    error(f"cannot read {readme}: {e}")
    departures = []

entries = []
if not isinstance(data, dict) or not isinstance(data.get("misconfigurations"), list):
    error("needs a top-level `misconfigurations` list (`misconfigurations: []` when there are none)")
else:
    entries = data["misconfigurations"]
    for key in data:
        if key != "misconfigurations":
            error(f"top-level key '{key}' is not checked here; only `misconfigurations` may be set")
for n, entry in enumerate(entries, 1):
    label = f"entry {n}"
    if not isinstance(entry, dict):
        error(f"{label}: not a mapping of id, paths and statement")
        continue
    rule = entry.get("id")
    if isinstance(rule, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", rule):
        label = f"entry {n} ({rule})"
    else:
        error(f"{label}: no rule ID (got {rule!r})")
    for key in entry:
        if key not in ("id", "paths", "statement"):
            error(f"{label}: key '{key}' is not one of id, paths, statement")
    paths = entry.get("paths")
    if not isinstance(paths, list) or not paths:
        error(f"{label}: needs a non-empty paths list naming the files that carry the departure")
    else:
        for p in paths:
            check_path(label, p)
    check_statement(label, entry.get("statement"), departures)

if errors:
    sys.exit(1)
print(f"check: {len(entries)} suppression(s), each with a rule ID, paths naming files and a README departure heading")
PY
}

# check_inline FILE...
# Trivy also honours inline ignore comments in Terraform (`#trivy:ignore:<id>`, the wildcard
# `#trivy:ignore:*`, the legacy `#tfsec:ignore:<id>`), which would bypass the ignore file and its
# README rule. Every suppression lives in .trivyignore.yaml, so any such comment fails.
check_inline() {
  local hits rc=0
  if [ "$#" -eq 0 ]; then
    echo "::error::no Terraform files to check for inline ignore comments"
    return 1
  fi
  hits="$(grep -nHIiE '(trivy|tfsec):ignore|checkov:skip' -- "$@")" || rc=$?
  case "$rc" in
    0)
      while IFS= read -r hit; do
        echo "::error::inline ignore comment (suppress in $ignorefile instead): $hit"
      done <<<"$hits"
      return 1
      ;;
    1) echo "check: no inline ignore comment in $# Terraform file(s)" ;;
    *)
      echo "::error::could not read the Terraform files for inline ignore comments"
      return 1
      ;;
  esac
}

# The tracked Terraform the scan reads; the known-bad fixtures are skipped by the scan.
module_tf_files() {
  git ls-files -z -- '*.tf' ":(exclude)$fixtures/**"
}

# The check must be seen to reject each kind of bad entry before its pass means anything. Runs
# against a synthetic README, so it does not move when the real departures do.
check_selftest() {
  local dir readme case_name want got failed=0
  dir="$(mktemp -d)"
  readme="$dir/README.md"
  cat >"$readme" <<EOF
## Networking

### $phrase

#### Service Bus keeps public network access enabled

#### Redis authenticates with a key

### Cutting a release
EOF

  # entry FILE ID PATHS STATEMENT -- writes a one-entry ignore file; an empty field is omitted.
  entry() {
    {
      echo "misconfigurations:"
      echo "  - id: $2"
      [ -z "$3" ] || echo "    paths: $3"
      [ -z "$4" ] || echo "    statement: $4"
    } >"$dir/$1"
  }
  local ok="README \"$phrase\" -> \"Service Bus keeps public network access enabled\""
  # good -- the good one-entry file on stdout, for a case to append to.
  good() { printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths: [main.tf]\n    statement: %s\n' "$ok"; }
  echo "misconfigurations: []" >"$dir/empty"
  entry good AVD-AZU-0001 "[main.tf]" "$ok"
  # The same entry in other YAML spellings: keys reordered, a block list, no final newline.
  printf 'misconfigurations:\n  - statement: %s\n    paths: [main.tf]\n    id: AVD-AZU-0001\n' \
    "$ok" >"$dir/reordered"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n      - main.tf\n    statement: %s\n' \
    "$ok" >"$dir/block-paths"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    statement: %s\n    paths: [main.tf]' \
    "$ok" >"$dir/no-final-newline"
  # The document as a whole.
  : >"$dir/empty-file"
  echo "misconfigurations:" >"$dir/no-entries"
  echo "misconfigurations: [" >"$dir/not-yaml"
  { good; printf -- '---\nmisconfigurations: []\n'; } >"$dir/two-documents"
  { good; printf 'vulnerabilities:\n  - id: CVE-2026-0001\n'; } >"$dir/other-top-level"
  { good; echo "misconfigurations: []"; } >"$dir/duplicate-top-level"
  printf 'misconfigurations:\n  - AVD-AZU-0001\n' >"$dir/entry-not-mapping"
  # A bad entry after a good one, in any key order or style, is still checked.
  { good; printf '  - statement: %s\n    id: AVD-AZU-0002\n' "$ok"; } >"$dir/second-no-paths"
  { good; echo "  - {paths: [main.tf], id: AVD-AZU-0002}"; } >"$dir/second-flow-no-statement"
  { good; printf '  - id: AVD-AZU-0002\n    statement: %s\n    paths: ["**"]' "$ok"; } \
    >"$dir/second-glob-no-final-newline"
  # Entry fields.
  entry no-id "" "[main.tf]" "$ok"
  entry glob-id 'AVD-AZU-*' "[main.tf]" "$ok"
  entry no-paths AVD-AZU-0001 "" "$ok"
  entry no-statement AVD-AZU-0001 "[main.tf]" ""
  entry no-section AVD-AZU-0001 "[main.tf]" "\"Service Bus keeps public network access enabled\""
  entry outside-section AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Cutting a release\""
  entry no-such-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Key Vault is public\""
  entry regex-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Service Bus.*\""
  entry section-as-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"$phrase\""
  { good; echo "    purls: [x]"; } >"$dir/unknown-key"
  { good; echo '    paths: ["**"]'; } >"$dir/duplicate-key"
  # Paths: the synthetic repository root holds main.tf, modules/bus/main.tf and a directory.
  local root="$dir/root"
  mkdir -p "$root/modules/bus"
  : >"$root/main.tf"
  : >"$root/modules/bus/main.tf"
  entry quoted-paths AVD-AZU-0001 '["main.tf", "modules/bus/main.tf"]' "$ok"
  entry paths-empty AVD-AZU-0001 "[]" "$ok"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n    statement: %s\n' \
    "$ok" >"$dir/paths-null"
  entry paths-scalar AVD-AZU-0001 "main.tf" "$ok"
  entry paths-number AVD-AZU-0001 "[42]" "$ok"
  entry glob-all AVD-AZU-0001 '["**"]' "$ok"
  entry glob-star AVD-AZU-0001 '["*.tf"]' "$ok"
  entry glob-one AVD-AZU-0001 "[main.t?]" "$ok"
  entry glob-brace AVD-AZU-0001 '["{main,redis}.tf"]' "$ok"
  entry glob-second AVD-AZU-0001 '[main.tf, "modules/**/main.tf"]' "$ok"
  entry missing-file AVD-AZU-0001 "[nope.tf]" "$ok"
  entry directory AVD-AZU-0001 "[modules]" "$ok"
  entry absolute AVD-AZU-0001 "[\"$root/main.tf\"]" "$ok"
  entry parent AVD-AZU-0001 "[../root/main.tf]" "$ok"
  entry dot-segment AVD-AZU-0001 "[./main.tf]" "$ok"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n      - "**"\n    statement: %s\n' \
    "$ok" >"$dir/block-glob"

  for case_name in empty good reordered block-paths no-final-newline quoted-paths \
    empty-file no-entries not-yaml two-documents other-top-level duplicate-top-level \
    entry-not-mapping second-no-paths second-flow-no-statement second-glob-no-final-newline \
    no-id glob-id no-paths no-statement no-section outside-section no-such-heading regex-heading \
    section-as-heading unknown-key duplicate-key paths-empty paths-null paths-scalar paths-number \
    glob-all glob-star glob-one glob-brace glob-second missing-file directory absolute parent \
    dot-segment block-glob; do
    case "$case_name" in
      empty | good | reordered | block-paths | no-final-newline | quoted-paths) want=pass ;;
      *) want=fail ;;
    esac
    if check_ignorefile "$dir/$case_name" "$readme" "$root" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" != "$want" ]; then
      echo "::error::check self-test: '$case_name' should $want, but did $got"
      failed=1
    fi
  done

  # Inline ignore comments: a clean file passes, each comment form fails, as does a file list
  # with nothing in it.
  local kv='resource "azurerm_key_vault" "kv" {'
  printf '%s\n  public_network_access_enabled = false\n}\n' "$kv" >"$dir/clean.tf"
  printf '#trivy:ignore:*\n%s\n}\n' "$kv" >"$dir/inline-wildcard.tf"
  printf '%s\n  public_network_access_enabled = true #trivy:ignore:AVD-AZU-0013\n}\n' "$kv" \
    >"$dir/inline-trivy.tf"
  printf '// trivy:ignore:AVD-AZU-0013\n%s\n}\n' "$kv" >"$dir/inline-slash.tf"
  printf '#tfsec:ignore:azure-keyvault-specify-network-acl\n%s\n}\n' "$kv" >"$dir/inline-tfsec.tf"
  printf '#checkov:skip=CKV_AZURE_189\n%s\n}\n' "$kv" >"$dir/inline-checkov.tf"
  for case_name in clean.tf inline-wildcard.tf inline-trivy.tf inline-slash.tf inline-tfsec.tf \
    inline-checkov.tf; do
    case "$case_name" in
      clean.tf) want=pass ;;
      *) want=fail ;;
    esac
    if check_inline "$dir/clean.tf" "$dir/$case_name" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" != "$want" ]; then
      echo "::error::check self-test: '$case_name' should $want, but did $got"
      failed=1
    fi
  done
  if check_inline >/dev/null 2>&1; then
    echo "::error::check self-test: an empty file list should fail, but passed"
    failed=1
  fi
  rm -rf "$dir"
  [ "$failed" -eq 0 ] || exit 1
  echo "check self-test: --check accepts the good entries and rejects every bad one"
}

scan_args=(--ignorefile "$ignorefile" --skip-dirs "$fixtures" .)

case "${1:-}" in
  --selftest) selftest ;;
  --check-selftest) check_selftest ;;
  --check)
    check_ignorefile "$ignorefile" README.md .
    tf_files=()
    while IFS= read -r -d '' f; do tf_files+=("$f"); done < <(module_tf_files)
    check_inline ${tf_files[@]+"${tf_files[@]}"}
    ;;
  --sarif) trivy_config --format sarif --output "${2:?--sarif needs an output file}" "${scan_args[@]}" ;;
  --gate) trivy_config --exit-code 1 "${scan_args[@]}" ;;
  *)
    echo "usage: $0 --selftest | --check-selftest | --check | --sarif FILE | --gate" >&2
    exit 2
    ;;
esac
