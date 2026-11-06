#!/usr/bin/env bash
# Does scripts/preflight.sh judge the deploying identity's roles the way an apply will?
#
# With enable_key_vault the module defines a role of its own (the apps' read, write and delete on
# vault secrets, keyvault.tf), which needs Microsoft.Authorization/roleDefinitions/write. Owner
# and User Access Administrator carry that action; Role Based Access Control Administrator can
# assign roles but not define them. A preflight that let Contributor + Role Based Access Control
# Administrator through would pass a deployer whose apply then fails part-way. So this asserts:
#
#   1. --mode production, Contributor + Role Based Access Control Administrator: exit 1, with a
#      FAIL naming Microsoft.Authorization/roleDefinitions/write. Production forces the vault.
#   2. --mode production, Owner, and Contributor + User Access Administrator: exit 0.
#   3. --mode demo, Contributor + Role Based Access Control Administrator: a WARN naming
#      enable_key_vault and exit 0, since a demo install may run without the vault.
#   4. Role Based Access Control Administrator still passes "can create role assignments".
#   5. With no --principal, the note the operator must confirm by hand names the new right.
#
# It runs the real script against a fake `az` that answers every call the script makes, with
# the role names each scenario seeds. `--selftest` breaks a copy of the script in the ways a
# regression would, and insists this suite fails on each copy; run it before the suite.
#
# Needs bash and nothing else — no cloud, no credential. Run: bash tests/preflight_test.sh

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/preflight.sh"
RIGHT="Microsoft.Authorization/roleDefinitions/write"

failures=0
pass() { printf '  ok      %s\n' "$*"; }
fail() { printf '  FAIL    %s\n' "$*"; failures=$((failures + 1)); }

# --- The fake CLI ---------------------------------------------------------------------------
# The subscription is Enabled, every provider is Registered, Azure Managed Redis is offered in
# Sweden Central, the PostgreSQL SKU list carries the production SKU, and the role assignment
# list returns the roles file beside it, one name per line, as
# `--query "[].roleDefinitionName" -o tsv` would.
make_az() { # make_az <bindir> <roles, newline-separated>
  local bindir="$1" roles="$2"
  mkdir -p "$bindir"
  if [[ -n "$roles" ]]; then printf '%s\n' "$roles" > "$bindir/roles"; else : > "$bindir/roles"; fi
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'B=%q\n' "$bindir"
    cat <<'EOF'
args="$*"
case "$1 ${2:-} ${3:-}" in
  "account show "*) echo "Enabled" ;;
  "provider show "*)
    if [[ "$args" == *redisEnterprise* ]]; then echo "Sweden Central"; else echo "Registered"; fi ;;
  "role assignment list") cat "$B/roles" ;;
  "postgres flexible-server list-skus") echo '[{"supportedSkus":[{"name":"Standard_D2ds_v5"}]}]' ;;
  *) echo "fake az: unhandled command: $args" >&2; exit 1 ;;
esac
EOF
  } > "$bindir/az"
  chmod +x "$bindir/az"
}

# run_preflight <script> <dir> <roles> <preflight args...> — sets rc and out
run_preflight() {
  local script="$1" dir="$2" roles="$3"
  shift 3
  make_az "$dir/bin" "$roles"
  rc=0
  out=$(PATH="$dir/bin:$PATH" bash "$script" --subscription 00000000-0000-0000-0000-000000000000 \
          --location swedencentral "$@" 2>&1) || rc=$?
}

has_line() { # has_line <ERE> — a line of the last run's output matches
  grep -qE -- "$1" <<<"$out"
}

scenario() { # scenario <script> <label> <mode> <roles> <want rc>
  local script="$1" label="$2" mode="$3" roles="$4" want="$5" dir
  dir=$(mktemp -d)
  run_preflight "$script" "$dir" "$roles" --mode "$mode" --principal 11111111-1111-1111-1111-111111111111
  if [[ $rc -eq $want ]]; then
    pass "$label: exit $rc"
  else
    fail "$label: exit $rc, want $want"
    printf '%s\n' "$out" | grep -E '^  (FAIL|WARN)' | sed 's/^/            /' || true
  fi
  rm -rf "$dir"
}

check_suite() { # check_suite <script> — every scenario; non-zero if any assertion failed
  local script="$1" dir
  failures=0

  scenario "$script" "production, Contributor + Role Based Access Control Administrator" production \
    $'Contributor\nRole Based Access Control Administrator' 1
  if has_line "^  FAIL    .*$RIGHT"; then
    pass "the FAIL names $RIGHT"
  else
    fail "no FAIL naming $RIGHT"
  fi
  if has_line '^  PASS    can create role assignments$'; then
    pass "Role Based Access Control Administrator still passes 'can create role assignments'"
  else
    fail "Role Based Access Control Administrator no longer passes 'can create role assignments'"
  fi
  if has_line '^Automated checks: 1 failed'; then
    pass "the role-definition check is the only failure"
  else
    fail "expected exactly one failure: $(printf '%s\n' "$out" | grep -E '^Automated checks' || true)"
  fi

  scenario "$script" "production, Owner" production 'Owner' 0
  if has_line "^  PASS    can create role definitions \\($RIGHT\\)$"; then
    pass "Owner passes 'can create role definitions'"
  else
    fail "Owner does not pass 'can create role definitions'"
  fi

  scenario "$script" "production, Contributor + User Access Administrator" production \
    $'Contributor\nUser Access Administrator' 0
  if has_line "^  PASS    can create role definitions \\($RIGHT\\)$" && ! has_line '^  FAIL'; then
    pass "User Access Administrator passes 'can create role definitions', and nothing fails"
  else
    fail "Contributor + User Access Administrator did not pass cleanly"
  fi

  scenario "$script" "demo, Contributor + Role Based Access Control Administrator" demo \
    $'Contributor\nRole Based Access Control Administrator' 0
  if has_line "^  WARN    .*$RIGHT.*enable_key_vault"; then
    pass "demo WARNs, naming $RIGHT and enable_key_vault"
  else
    fail "demo gives no WARN naming $RIGHT and enable_key_vault"
  fi
  if ! has_line '^  FAIL' && has_line '^  PASS    can create role assignments$'; then
    pass "demo fails nothing, and still passes 'can create role assignments'"
  else
    fail "demo FAILs a check, or no longer passes 'can create role assignments'"
  fi

  dir=$(mktemp -d)
  run_preflight "$script" "$dir" '' --mode production
  rm -rf "$dir"
  if [[ $rc -eq 0 ]] && grep -qF -- "$RIGHT" <<<"${out#*CONFIRM THESE YOURSELF}"; then
    pass "with no --principal, the manual note names $RIGHT"
  else
    fail "with no --principal, the manual note does not name $RIGHT (exit $rc)"
  fi

  [[ $failures -eq 0 ]]
}

# --- Self-test: break the script, and insist the suite notices ----------------------------
# The `$` in the lists below belongs to the text being matched, not to this shell.
# shellcheck disable=SC2016
selftest() {
  local tmp broken n src total=0
  tmp=$(mktemp -d)
  # Three parallel lists: what the break is, the sed that introduces it, and a string that
  # must NOT survive it (proof the sed changed the copy rather than missing its target).
  local descs=(
    'Role Based Access Control Administrator accepted as able to define roles'
    'production reports a missing role-definition right as a WARN'
    'demo reports a missing role-definition right as a FAIL'
    'the production FAIL no longer names the action'
    'Role Based Access Control Administrator no longer passes "can create role assignments"'
    'the manual note no longer names the role-definition right'
    'User Access Administrator no longer accepted as able to define roles'
    'the demo WARN no longer names enable_key_vault'
  )
  local exprs=(
    "s/grep -qxE 'Owner|User Access Administrator'; then/grep -qxE 'Owner|User Access Administrator|Role Based Access Control Administrator'; then/"
    's/^        fail "cannot create role definitions/        warn "cannot create role definitions/'
    's/^      elif \[\[ "\$MODE" == "production" \]\]; then$/      elif true; then/'
    's|which needs Microsoft.Authorization/roleDefinitions/write\. Role|which needs a further right. Role|'
    "s/grep -qxE 'Owner|User Access Administrator|Role Based Access Control Administrator'; then/grep -qxE 'Owner|User Access Administrator'; then/"
    's|needs Microsoft.Authorization/roleDefinitions/write, to define|needs a further right, to define|'
    "s/grep -qxE 'Owner|User Access Administrator'; then/grep -qxE 'Owner'; then/"
    's/fine while enable_key_vault = false/fine while the vault is off/;s/but with enable_key_vault = true the module/but with the vault on the module/'
  )
  local gones=(
    "grep -qxE 'Owner|User Access Administrator'; then"
    'fail "cannot create role definitions'
    'elif [[ "$MODE" == "production" ]]; then'
    'which needs Microsoft.Authorization/roleDefinitions/write. Role'
    "grep -qxE 'Owner|User Access Administrator|Role Based Access Control Administrator'; then"
    'needs Microsoft.Authorization/roleDefinitions/write, to define'
    "grep -qxE 'Owner|User Access Administrator'; then"
    'enable_key_vault = true the module'
  )
  for n in "${!exprs[@]}"; do
    total=$((total + 1))
    broken="$tmp/broken-$total.sh"
    sed -e "${exprs[$n]}" "$SCRIPT" > "$broken"
    if grep -qF -- "${gones[$n]}" "$broken"; then
      printf '  FAIL    selftest %d (%s): the break did not change the script — stale sed\n' "$total" "${descs[$n]}"
      rm -rf "$tmp"; return 1
    fi
    src=0
    check_suite "$broken" > "$tmp/suite-$total.log" 2>&1 || src=$?
    if [[ $src -ne 0 ]]; then
      printf '  ok      selftest %d: suite FAILS when the script is broken — %s\n' "$total" "${descs[$n]}"
      grep -E '^  FAIL' "$tmp/suite-$total.log" | head -n 3 | sed 's/^/            /'
    else
      printf '  FAIL    selftest %d: suite PASSED a broken script — %s\n' "$total" "${descs[$n]}"
      rm -rf "$tmp"; return 1
    fi
  done
  rm -rf "$tmp"
  return 0
}

if [[ "${1:-}" == "--selftest" ]]; then
  echo "== selftest: a broken script must fail this suite"
  selftest
  exit $?
fi

echo "== preflight: the deploying identity's role-definition right"
if check_suite "$SCRIPT"; then
  echo "== all assertions passed"
  exit 0
else
  echo "== $failures assertion(s) FAILED"
  exit 1
fi
