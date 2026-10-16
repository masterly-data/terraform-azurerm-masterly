#!/usr/bin/env bash
# The IaC scan the iac-scan workflow runs, runnable locally wherever `trivy` is installed.
#
#   scripts/iac_scan.sh --selftest         the scanner reports the known-bad fixture
#   scripts/iac_scan.sh --check-selftest   --check rejects each kind of bad entry (no trivy needed)
#   scripts/iac_scan.sh --check            every .trivyignore.yaml entry has a rule ID, paths that
#                                          name real files (no glob, never empty) and a README
#                                          departure heading that exists, and no tracked .tf file
#                                          carries an inline ignore comment
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

# The #### headings inside the README's "### <phrase>" section, up to the next ## or ### heading.
# Only these are departures; a heading elsewhere in the README is not.
departure_headings() {
  awk -v want="### $phrase" '
    $0 == want { inside = 1; next }
    inside && /^###? / { exit }
    inside && /^#### / { sub(/^#### /, ""); print }
  ' "$1"
}

# bad_paths ENTRY ROOT PATHS -- PATHS is the flow list `[a.tf, b.tf]` or, from a block list, one
# path per line. Trivy matches each path as a doublestar glob, so an empty list, a glob or a
# directory would turn the entry into a suppression of its rule across many files: each path must
# be a literal relative path to a file under ROOT.
bad_paths() {
  local entry="$1" root="$2" list="$3" p n=0 rc=0
  case "$list" in
    "["*"]")
      list="${list#"["}"
      list="${list%"]"}"
      list="$(tr ',' '\n' <<<"$list")"
      ;;
    "["* | *"]") list="[" ;; # half a flow list: fails as a glob below
  esac
  while IFS= read -r p; do
    p="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" <<<"$p")"
    [ -n "$p" ] || continue
    n=$((n + 1))
    case "$p" in
      *[][*?{}!]*)
        echo "::error::$ignorefile: entry '$entry' path '$p' is a glob; name the file"
        rc=1
        ;;
      /* | ../* | */../* | *.. | ./* | *"/./"*)
        echo "::error::$ignorefile: entry '$entry' path '$p' is not a plain path relative to the repository root"
        rc=1
        ;;
      *)
        if [ ! -f "$root/$p" ]; then
          echo "::error::$ignorefile: entry '$entry' path '$p' is not a file in the repository"
          rc=1
        fi
        ;;
    esac
  done <<<"$list"
  if [ "$n" -eq 0 ]; then
    echo "::error::$ignorefile: entry '$entry' has an empty paths list"
    rc=1
  fi
  return "$rc"
}

# check_ignorefile IGNOREFILE README ROOT
# Entries are "  - id:" blocks. Each needs paths (flow `[a.tf]` or a block list of `- a.tf`), each
# a file under ROOT (see bad_paths), and a statement that names the README section and one of its
# departure headings, compared as a literal string. With `misconfigurations: []` there is nothing
# to check.
check_ignorefile() {
  local file="$1" readme="$2" root="$3" departures entry id paths statement heading key bad=0 count=0
  departures="$(departure_headings "$readme")"
  id="" paths="" statement="" key=""
  # A sentinel entry flushes the last block.
  while IFS= read -r line; do
    case "$line" in
      "  - id:"* | "@@end")
        if [ -n "$id$paths$statement" ] || [ "$count" -gt 0 ]; then
          entry="$id"
          if [ -z "$id" ] || [ -z "$paths" ] || [ -z "$statement" ]; then
            echo "::error::$file: entry '$entry' lacks a rule ID, paths or statement"
            bad=1
          elif ! bad_paths "$entry" "$root" "$paths"; then
            bad=1
          elif ! grep -qF "README \"$phrase\" -> \"" <<<"$statement"; then
            echo "::error::$file: entry '$entry' does not name README \"$phrase\""
            bad=1
          else
            heading="$(sed -n 's/.*-> *"\(.*\)"[[:space:]]*$/\1/p' <<<"$statement")"
            if [ -z "$heading" ] || [ -z "$departures" ] || ! grep -qxF -- "$heading" <<<"$departures"; then
              echo "::error::$file: entry '$entry' names '$heading', which is not a departure heading under README \"$phrase\""
              bad=1
            fi
          fi
        fi
        [ "$line" = "@@end" ] && break
        count=$((count + 1))
        id="${line#  - id:}"
        id="${id# }"
        paths="" statement="" key=""
        ;;
      "    paths:"*)
        key=paths
        paths="${line#    paths:}"
        paths="${paths# }"
        ;;
      "      - "?*) if [ "$key" = paths ]; then paths="$paths${line#      - }"$'\n'; fi ;;
      "    statement:"*)
        key=statement
        statement="${line#    statement:}"
        ;;
      "    "[a-z]*) key="" ;;
      *) ;;
    esac
  done < <(cat "$file"; echo "@@end")
  if [ "$count" -eq 0 ] && ! grep -q '^misconfigurations: \[\]' "$file"; then
    echo "::error::$file: no entries, but not the empty-list form"
    return 1
  fi
  [ "$bad" -eq 0 ] || return 1
  echo "check: $count suppression(s), each with a rule ID and a README departure heading"
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
  echo "misconfigurations: []" >"$dir/empty"
  echo "misconfigurations:" >"$dir/no-entries"
  entry good AVD-AZU-0001 "[main.tf]" "$ok"
  entry no-id "" "[main.tf]" "$ok"
  entry no-paths AVD-AZU-0001 "" "$ok"
  entry no-statement AVD-AZU-0001 "[main.tf]" ""
  entry no-section AVD-AZU-0001 "[main.tf]" "\"Service Bus keeps public network access enabled\""
  entry outside-section AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Cutting a release\""
  entry no-such-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Key Vault is public\""
  entry regex-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"Service Bus.*\""
  entry section-as-heading AVD-AZU-0001 "[main.tf]" "README \"$phrase\" -> \"$phrase\""
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n      - main.tf\n    statement: %s\n' \
    "$ok" >"$dir/block-paths"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n    statement: %s\n' \
    "$ok" >"$dir/block-paths-empty"
  # Paths: the synthetic repository root holds main.tf, modules/bus/main.tf and a directory.
  local root="$dir/root"
  mkdir -p "$root/modules/bus"
  : >"$root/main.tf"
  : >"$root/modules/bus/main.tf"
  entry quoted-paths AVD-AZU-0001 '["main.tf", "modules/bus/main.tf"]' "$ok"
  entry flow-paths-empty AVD-AZU-0001 "[]" "$ok"
  entry flow-paths-blank AVD-AZU-0001 "[ ]" "$ok"
  entry glob-all AVD-AZU-0001 '["**"]' "$ok"
  entry glob-star AVD-AZU-0001 "[*.tf]" "$ok"
  entry glob-one AVD-AZU-0001 "[main.t?]" "$ok"
  entry glob-brace AVD-AZU-0001 "[{main,redis}.tf]" "$ok"
  entry glob-second AVD-AZU-0001 "[main.tf, modules/**/main.tf]" "$ok"
  entry missing-file AVD-AZU-0001 "[nope.tf]" "$ok"
  entry directory AVD-AZU-0001 "[modules]" "$ok"
  entry absolute AVD-AZU-0001 "[$root/main.tf]" "$ok"
  entry parent AVD-AZU-0001 "[../root/main.tf]" "$ok"
  entry half-flow AVD-AZU-0001 "[main.tf" "$ok"
  printf 'misconfigurations:\n  - id: AVD-AZU-0001\n    paths:\n      - "**"\n    statement: %s\n' \
    "$ok" >"$dir/block-glob"

  for case_name in empty good block-paths quoted-paths no-entries no-id no-paths block-paths-empty \
    no-statement no-section outside-section no-such-heading regex-heading section-as-heading \
    flow-paths-empty flow-paths-blank glob-all glob-star glob-one glob-brace glob-second \
    missing-file directory absolute parent half-flow block-glob; do
    case "$case_name" in
      empty | good | block-paths | quoted-paths) want=pass ;;
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
