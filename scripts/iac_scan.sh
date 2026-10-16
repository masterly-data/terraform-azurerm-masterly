#!/usr/bin/env bash
# The IaC scan the iac-scan workflow runs, runnable locally wherever `trivy` is installed.
#
#   scripts/iac_scan.sh --selftest   the scanner reports the known-bad fixture
#   scripts/iac_scan.sh --check      every .trivyignore.yaml entry has a rule ID, a path and a
#                                    README departure heading that exists
#   scripts/iac_scan.sh --sarif F    scan the module, write SARIF to F, never fail on findings
#   scripts/iac_scan.sh --gate       scan the module, fail on HIGH/CRITICAL
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

# Entries are "  - id:" blocks. Each needs paths and a statement that names the README section
# and a heading that exists in README.md. With `misconfigurations: []` there is nothing to check.
check_ignorefile() {
  local entry id paths statement heading bad=0 count=0
  id="" paths="" statement=""
  # A sentinel entry flushes the last block.
  while IFS= read -r line; do
    case "$line" in
      "  - id:"* | "@@end")
        if [ -n "$id$paths$statement" ] || [ "$count" -gt 0 ]; then
          entry="$id"
          if [ -z "$id" ] || [ -z "$paths" ] || [ -z "$statement" ]; then
            echo "::error::$ignorefile: entry '$entry' lacks a rule ID, paths or statement"
            bad=1
          elif ! grep -qF "$phrase" <<<"$statement"; then
            echo "::error::$ignorefile: entry '$entry' does not name README \"$phrase\""
            bad=1
          else
            heading="$(sed -n 's/.*-> *"\(.*\)"[[:space:]]*$/\1/p' <<<"$statement")"
            if [ -z "$heading" ] || ! grep -qxE "#{3,4} ${heading}" README.md; then
              echo "::error::$ignorefile: entry '$entry' names heading '$heading', which README.md does not have"
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
  done < <(cat "$ignorefile"; echo "@@end")
  if [ "$count" -eq 0 ] && ! grep -q '^misconfigurations: \[\]' "$ignorefile"; then
    echo "::error::$ignorefile: no entries, but not the empty-list form"
    return 1
  fi
  [ "$bad" -eq 0 ] || return 1
  echo "check: $count suppression(s), each with a rule ID and a README heading"
}

scan_args=(--ignorefile "$ignorefile" --skip-dirs "$fixtures" .)

case "${1:-}" in
  --selftest) selftest ;;
  --check) check_ignorefile ;;
  --sarif) trivy_config --format sarif --output "${2:?--sarif needs an output file}" "${scan_args[@]}" ;;
  --gate) trivy_config --exit-code 1 "${scan_args[@]}" ;;
  *)
    echo "usage: $0 --selftest | --check | --sarif FILE | --gate" >&2
    exit 2
    ;;
esac
