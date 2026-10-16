#!/usr/bin/env bash
# The IaC scan the iac-scan workflow runs, runnable locally wherever `trivy` is installed.
#
#   scripts/iac_scan.sh --selftest         the scanner reports the known-bad fixture
#   scripts/iac_scan.sh --check-selftest   --check rejects each kind of bad entry (no trivy needed)
#   scripts/iac_scan.sh --check            every .trivyignore.yaml entry has a rule ID, a path and a
#                                          README departure heading that exists
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

# check_ignorefile IGNOREFILE README
# Entries are "  - id:" blocks. Each needs paths and a statement that names the README section
# and one of its departure headings, compared as a literal string. With `misconfigurations: []`
# there is nothing to check.
check_ignorefile() {
  local file="$1" readme="$2" departures entry id paths statement heading bad=0 count=0
  departures="$(departure_headings "$readme")"
  id="" paths="" statement=""
  # A sentinel entry flushes the last block.
  while IFS= read -r line; do
    case "$line" in
      "  - id:"* | "@@end")
        if [ -n "$id$paths$statement" ] || [ "$count" -gt 0 ]; then
          entry="$id"
          if [ -z "$id" ] || [ -z "$paths" ] || [ -z "$statement" ]; then
            echo "::error::$file: entry '$entry' lacks a rule ID, paths or statement"
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
        paths="" statement=""
        ;;
      "    paths:"*) paths="${line#    paths:}" ;;
      "    statement:"*) statement="${line#    statement:}" ;;
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

  for case_name in empty good no-entries no-id no-paths no-statement no-section outside-section \
    no-such-heading regex-heading section-as-heading; do
    case "$case_name" in
      empty | good) want=pass ;;
      *) want=fail ;;
    esac
    if check_ignorefile "$dir/$case_name" "$readme" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" != "$want" ]; then
      echo "::error::check self-test: '$case_name' should $want, but did $got"
      failed=1
    fi
  done
  rm -rf "$dir"
  [ "$failed" -eq 0 ] || exit 1
  echo "check self-test: --check accepts the good entries and rejects every bad one"
}

scan_args=(--ignorefile "$ignorefile" --skip-dirs "$fixtures" .)

case "${1:-}" in
  --selftest) selftest ;;
  --check-selftest) check_selftest ;;
  --check) check_ignorefile "$ignorefile" README.md ;;
  --sarif) trivy_config --format sarif --output "${2:?--sarif needs an output file}" "${scan_args[@]}" ;;
  --gate) trivy_config --exit-code 1 "${scan_args[@]}" ;;
  *)
    echo "usage: $0 --selftest | --check-selftest | --check | --sarif FILE | --gate" >&2
    exit 2
    ;;
esac
