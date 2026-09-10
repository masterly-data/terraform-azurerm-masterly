#!/usr/bin/env bash
# Does the diagnostic bundle carry a secret, an address, or a credential — and does it say
# the truth about record data? This is the test that makes the claims in
# scripts/diagnostic-bundle.sh's header checked properties rather than sentences.
#
# It tests two DIFFERENT claims, and they are not the same strength:
#
#   1. Secrets, credentials, addresses and key material are absent. That is a guarantee, and
#      it is asserted as absence, canary by canary.
#   2. Record data is absent from the applications' own log lines and from everything built
#      from Azure Resource Manager — but NOT from logs/q6-postgres-logs.json, which is the
#      Postgres server's own log stream, nor from logs/q4-request-trace.json, which projects
#      an exception string. Those can echo a failing statement and its values. For those the
#      documented behaviour is a WARNING, not a refusal, so that is what is asserted: the
#      value is present, the file is named in manifest.json under
#      record_data.needs_line_by_line_review, and the operator is told on stderr/stdout.
#      Asserting absence there would be asserting something the script does not do.
#   3. manifest.json's `.tool` names the version of the TREE THE SCRIPT RAN FROM, and never a
#      version that tree is not. That is asserted in its own scenario, against a staged module
#      root, because inside this repository the true answer and the wrong one look alike.
#
# It runs the real script against a fake `az` and a fake `curl` (tests/fixtures/
# diagnostic-bundle/) whose answers are SEEDED with values that must never reach the bundle:
# a DSN password in a Container App secret, a session secret, a licence JWT, an owner's email
# address in a plain environment variable, a Postgres admin password, the workspace shared
# key, an action group's receiver address and webhook key, and the API token the script is
# handed. Then it reads every file the script wrote and asserts each canary is absent — and,
# so that a script that wrote nothing cannot pass, that the allow-listed configuration values
# and the secret NAMES are present. The q6 fixture additionally seeds a realistic unique-key
# violation carrying a synthetic address and business key, which is the record-data class.
#
# A second scenario seeds a credential-bearing DSN into a log query's answer, which the
# allow-list cannot see, and asserts the refusal gate fires: exit 3, the directory renamed
# `-REFUSED`, the finding reported by file and line and never by content.
#
# `--selftest` is the part that keeps this honest. It copies the script, breaks it five ways
# a real regression would — keep every env value, keep secret values, disable the gate,
# disable the statement-echo warning, take the version from the release manifest when the tree
# could answer — and asserts that THIS harness fails against each broken copy. A test nobody has watched fail is a hypothesis; CI runs the selftest first so
# that a detector that has quietly stopped detecting fails the build instead of passing it.
# Each break is checked to have actually changed the copy, so a stale sed cannot turn the
# selftest vacuous.
#
# Needs bash, jq, and nothing else — no cloud, no credential. Run: bash tests/diagnostic_bundle_test.sh

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/diagnostic-bundle.sh"
FIXTURES="$HERE/fixtures/diagnostic-bundle"

# Every value the fixtures seed that must never appear in a bundle. One per class of leak.
CANARIES=(
  "CANARY-SECRET-VALUE-9c1d"            # a Container App secret value (the DSN password)
  "CANARY-SESSION-SECRET-VALUE-1a2b"    # another secret value
  "eyJhbGciOiJFUzI1NiIsImtpZCI6ImNhbmFyeSJ9"  # the licence JWT held as a secret
  "canary.owner@example.invalid"        # a person's address in a plain env var
  "canary.breakglass@example.invalid"   # another
  "CANARY-JWK-X"                        # public key material — not secret, still not needed
  "CANARY-TELEMETRY-CLIENT-ID-5d6e"     # a credential's id half
  "CANARY-PLAIN-ENV-VALUE-4b1e"         # an env var the allow-list does not know
  "CANARY-OIDC-CLIENT-SECRET-8f9a"      # the frontend's client secret
  "CANARY-OIDC-CLIENT-ID-3c4d"          # its client id
  "CANARY-WORKSPACE-SHARED-KEY-0d1c"    # the workspace shared key on the environment
  "CANARY-PG-ADMIN-PASSWORD-e5f6"       # the starter server's admin password
  "masterly_admin"                      # the starter server's admin login
  "canary.ops@example.invalid"          # an action group receiver
  "CANARY-WEBHOOK-KEY-7b8c"             # an action group webhook key
  "CANARY-API-TOKEN-2e77"               # the bearer token the script is handed
  "customer-pull-token"                 # the registry credential's username
  "203.0.113.7"                         # an ingress allowlist entry
)

# The record-data class. These are seeded into the q6 fixture as a realistic unique-key
# violation — the shape a Postgres server logs at its own defaults — and they are NOT in
# CANARIES, because the script does not remove them and claiming otherwise is the defect
# this block exists to prevent. What is asserted instead is the documented behaviour: the
# value reaches logs/q6-postgres-logs.json, the file is named in manifest.json, and the
# operator is told on the terminal. Both values are synthetic (@example.invalid, CANARY-…).
RECORD_DATA_CANARIES=(
  "canary.record@example.invalid"       # an attribute value on a DETAIL: Key (…)=(…) line
  "CANARY-SOURCE-KEY-3f2a"              # a business key on the same line
)

failures=0
pass() { printf '  ok      %s\n' "$*"; }
fail() { printf '  FAIL    %s\n' "$*"; failures=$((failures + 1)); }

# --- The fake CLI ---------------------------------------------------------------------------
# Answers the commands the script issues, from fixtures, by command — it evaluates no JMESPath,
# so what it returns for a `--query` is what that query would have projected. The jq
# projections under test run inside the real script, on these full documents.
make_fakes() { # make_fakes <bindir> <fixtures> <q3 fixture name>
  local bindir="$1" fixtures="$2" q3="$3"
  mkdir -p "$bindir"
  cat > "$bindir/az" <<EOF
#!/usr/bin/env bash
set -euo pipefail
F="$fixtures"
Q3="$q3"
args="\$*"
case "\$1 \${2:-} \${3:-}" in
  "account show "*)                         echo "Enabled" ;;
  "version "*)                              echo "2.89.1" ;;
  "postgres flexible-server list")          echo "psql-masterly-x7k2q" ;;
  "postgres flexible-server show")          cat "\$F/postgres-show.json" ;;
  "monitor log-analytics workspace")        echo "22222222-2222-2222-2222-222222222222" ;;
  "containerapp env show")                  cat "\$F/containerapp-env-show.json" ;;
  "containerapp show "*)
    app=\$(printf '%s\n' "\$args" | sed -E 's/.* -n ([^ ]+).*/\1/'); cat "\$F/containerapp-show-\$app.json" ;;
  "containerapp revision list")             cat "\$F/containerapp-revision-list.json" ;;
  "containerapp replica list")              cat "\$F/containerapp-replica-list.json" ;;
  "monitor metrics alert")                  cat "\$F/metrics-alert-list.json" ;;
  "resource list "*)                        echo '["alert-masterly-postgres-silent"]' ;;
  "monitor action-group list")              cat "\$F/action-group-list.json" ;;
  "rest "*)
    case "\$args" in
      *arg_max*)                       cat "\$F/rest-q1.json" ;;
      *"starting: mode="*)             cat "\$F/rest-q2.json" ;;
      *"summarize events"*)           cat "\$F/\$Q3" ;;
      *request_id*)                    cat "\$F/rest-q4.json" ;;
      *ContainerAppSystemLogs_CL*)     cat "\$F/rest-q5.json" ;;
      *PostgreSQLLogs*)                cat "\$F/rest-q6.json" ;;
      *) echo "fake az: unknown query" >&2; exit 1 ;;
    esac ;;
  *) echo "fake az: unhandled command: \$args" >&2; exit 1 ;;
esac
EOF
  # The fake curl records that it was handed a bearer token (so the test can prove the token
  # was USED and still never written) and answers with the metrics fixture.
  cat > "$bindir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
F="$fixtures"
out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -H) if [[ "\$2" == "@-" ]]; then cat > "$bindir/.curl-headers"; fi; shift 2 ;;
    *) shift ;;
  esac
done
cat "\$F/ops-metrics.json" > "\$out"
EOF
  chmod +x "$bindir/az" "$bindir/curl"
}

# --- Scenarios ------------------------------------------------------------------------------
# Each scenario runs the script under test and returns non-zero when an assertion fails.

scenario_clean() { # scenario_clean <script>
  local script="$1" tmp bundle rc
  tmp=$(mktemp -d)
  make_fakes "$tmp/bin" "$FIXTURES" "rest-q3.json"
  rc=0
  PATH="$tmp/bin:$PATH" MASTERLY_API_TOKEN="CANARY-API-TOKEN-2e77" \
    bash "$script" --subscription 00000000-0000-0000-0000-000000000000 \
      --request-id req-fixture-0001 --api-url https://masterly.example.invalid \
      --out "$tmp/out" > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "clean run exited $rc (expected 0)"; sed 's/^/          /' "$tmp/stderr"; return 1
  fi
  bundle=$(find "$tmp/out" -maxdepth 1 -mindepth 1 -type d | head -n1)
  [[ -n "$bundle" ]] || { fail "no bundle directory written"; return 1; }
  pass "clean run wrote $(basename "$bundle")"

  # Presence first: a script that wrote nothing must not pass the absence checks below.
  local expect
  for expect in manifest.json README.txt environment.json postgres.json alerts.json \
                ops-metrics.json apps/ca-api.json apps/ca-api.revisions.json \
                apps/ca-api.replicas.json apps/ca-workers.json apps/ca-frontend.json \
                logs/q1-running-images.json logs/q2-boot-posture.json \
                logs/q3-errors-by-logger.json logs/q4-request-trace.json \
                logs/q5-revision-failures.json logs/q6-postgres-logs.json; do
    if [[ -s "$bundle/$expect" ]]; then :; else fail "missing or empty: $expect"; fi
  done
  jq -e '.template.containers[0].env[] | select(.name == "MASTERLY_MODE" and .value == "production")' \
    "$bundle/apps/ca-api.json" >/dev/null && pass "allow-listed value present (MASTERLY_MODE)" \
    || fail "allow-listed MASTERLY_MODE value missing from apps/ca-api.json"
  jq -e '.template.containers[0].env[] | select(.name == "MASTERLY_DATABASE_URL" and .source == "secret" and .secret_name == "database-url" and (has("value") | not))' \
    "$bundle/apps/ca-api.json" >/dev/null && pass "secret env listed by reference name only" \
    || fail "MASTERLY_DATABASE_URL should be listed as a secret reference with no value"
  jq -e '.template.containers[0].env[] | select(.name == "SOME_CUSTOM_VAR" and .value_omitted == true and (has("value") | not))' \
    "$bundle/apps/ca-api.json" >/dev/null && pass "unknown env var listed by name, value omitted" \
    || fail "SOME_CUSTOM_VAR should be listed with value_omitted and no value"
  jq -e '.configuration.secrets == ["database-url", "session-secret", "license-token", "registry-password"]' \
    "$bundle/apps/ca-api.json" >/dev/null && pass "secrets listed by name" \
    || fail "configuration.secrets should be the four names and nothing else"
  jq -e '.tables[0].rows[0][3] == "masterly.azurecr.io/api:v0.133.2"' "$bundle/logs/q1-running-images.json" >/dev/null \
    && pass "running image tags carried" || fail "q1 rows not carried as returned"
  jq -e '.jobs.completed_last_hour == 3' "$bundle/ops-metrics.json" >/dev/null \
    && pass "ops-metrics attached" || fail "ops-metrics.json not the fetched body"
  jq -e '[.items[] | select(.collected == false)] | length == 0' "$bundle/manifest.json" >/dev/null \
    && pass "manifest reports every item collected" || fail "manifest reports gaps on a clean run: $(jq -c '[.items[] | select(.collected == false) | .item]' "$bundle/manifest.json")"
  jq -e '.request_id == "req-fixture-0001"' "$bundle/manifest.json" >/dev/null \
    && pass "request id recorded" || fail "request id not in manifest"
  grep -q "Bearer CANARY-API-TOKEN-2e77" "$tmp/bin/.curl-headers" 2>/dev/null \
    && pass "the API token was sent (so its absence below is a real absence)" \
    || fail "curl was not handed the bearer token"
  jq -e '.actionGroups[0].receivers.email == 1 and .actionGroups[0].receivers.webhook == 1' "$bundle/alerts.json" >/dev/null \
    && pass "action-group receivers counted" || fail "receivers not counted in alerts.json"

  # Absence: every canary, in every file, including the script's own stdout and stderr.
  local canary hits
  for canary in "${CANARIES[@]}"; do
    hits=$(grep -rlF -- "$canary" "$bundle" "$tmp/stdout" "$tmp/stderr" 2>/dev/null || true)
    if [[ -z "$hits" ]]; then
      pass "absent: $canary"
    else
      fail "LEAKED: $canary in $(printf '%s' "$hits" | sed "s#$tmp/##g" | tr '\n' ' ')"
    fi
  done

  # --- The record-data class: present, flagged, and the operator told ---------------------
  # The reviewer's demonstration, turned into a standing assertion. A constraint violation
  # in the Postgres log stream carries attribute values, the script keeps it, and everything
  # here is about whether the script SAYS SO. If a future change starts deleting the line,
  # these fail too — which is correct: the claim and the behaviour must move together.
  local rc_canary
  for rc_canary in "${RECORD_DATA_CANARIES[@]}"; do
    if grep -qF -- "$rc_canary" "$bundle/logs/q6-postgres-logs.json" 2>/dev/null; then
      pass "record data reaches q6 as documented (so the flag below is a real flag): $rc_canary"
    else
      fail "the q6 fixture no longer seeds $rc_canary — the record-data assertions below are vacuous"
    fi
    if grep -qF -- "$rc_canary" "$bundle/manifest.json" "$bundle/README.txt" 2>/dev/null; then
      fail "the manifest or README quotes the record value $rc_canary instead of naming the file"
    else
      pass "the flag names the file, not the value: $rc_canary"
    fi
  done
  jq -e '.record_data.needs_line_by_line_review | index("logs/q6-postgres-logs.json")' \
    "$bundle/manifest.json" >/dev/null \
    && pass "manifest flags logs/q6-postgres-logs.json for line-by-line review" \
    || fail "manifest does not flag logs/q6-postgres-logs.json: $(jq -c '.record_data.needs_line_by_line_review' "$bundle/manifest.json" 2>/dev/null)"
  jq -e '.record_data.not_guaranteed_in | index("logs/q6-postgres-logs.json")' \
    "$bundle/manifest.json" >/dev/null \
    && pass "manifest names q6 as the exception to the record-data claim" \
    || fail "manifest's record_data does not name q6 as the exception"
  jq -e '.omits | test("record data|attribute value") | not' "$bundle/manifest.json" >/dev/null \
    && pass "manifest does not claim record data is omitted outright" \
    || fail "manifest's omits still claims record data or attribute values are omitted"
  grep -qF "q6-postgres-logs.json" "$tmp/stdout" "$tmp/stderr" \
    && pass "the run tells the operator which file to read line by line" \
    || fail "the run never names q6-postgres-logs.json on stdout or stderr"
  [[ $rc -eq 0 ]] && pass "statement echo warns, it does not refuse (exit 0)" \
    || fail "statement echo must warn, not refuse — exit was $rc"
  local bundle_mode
  bundle_mode=$(ls -ld "$bundle" | cut -c1-10)
  [[ "$bundle_mode" == "drwx------" ]] && pass "bundle directory is owner-only ($bundle_mode)" \
    || fail "bundle directory is $bundle_mode, expected drwx------"

  rm -rf "$tmp"
  [[ $failures -eq 0 ]]
}

scenario_refused() { # scenario_refused <script>
  local script="$1" tmp rc refused
  tmp=$(mktemp -d)
  make_fakes "$tmp/bin" "$FIXTURES" "rest-q3-with-dsn.json"
  rc=0
  PATH="$tmp/bin:$PATH" bash "$script" --subscription 00000000-0000-0000-0000-000000000000 \
    --out "$tmp/out" > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
  if [[ $rc -eq 3 ]]; then pass "a credential-bearing log line is refused (exit 3)"
  else fail "expected exit 3 on a credential-bearing log line, got $rc"; fi
  refused=$(find "$tmp/out" -maxdepth 1 -mindepth 1 -type d -name '*-REFUSED' | head -n1)
  if [[ -n "$refused" ]]; then pass "refused bundle kept under -REFUSED for local inspection"
  else fail "no -REFUSED directory left behind"; fi
  if grep -q "logs/q3-errors-by-logger.json:" "$tmp/stderr"; then pass "finding reported by file and line"
  else fail "stderr does not name logs/q3-errors-by-logger.json"; fi
  if grep -qF "CANARY-DSN-PASSWORD-6a0f" "$tmp/stderr" "$tmp/stdout"; then
    fail "the refusal printed the secret it refused"
  else pass "the refusal did not print the content"; fi
  if [[ -z "$(find "$tmp/out" -maxdepth 1 -mindepth 1 -type d ! -name '*-REFUSED')" ]]; then
    pass "no sendable bundle directory exists"
  else fail "a sendable bundle directory exists beside the refusal"; fi
  rm -rf "$tmp"
  [[ $failures -eq 0 ]]
}

scenario_gaps() { # scenario_gaps <script> — no token, no request id: the manifest says so.
  local script="$1" tmp bundle rc
  tmp=$(mktemp -d)
  make_fakes "$tmp/bin" "$FIXTURES" "rest-q3.json"
  rc=0
  PATH="$tmp/bin:$PATH" bash "$script" --subscription 00000000-0000-0000-0000-000000000000 \
    --out "$tmp/out" > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
  [[ $rc -eq 0 ]] && pass "run without a token or request id still exits 0" || fail "exit $rc without token/request id"
  bundle=$(find "$tmp/out" -maxdepth 1 -mindepth 1 -type d | head -n1)
  jq -e '[.items[] | select(.collected == false) | .item] == ["logs:q4-request-trace", "ops-metrics"]' \
    "$bundle/manifest.json" >/dev/null && pass "manifest names exactly the two gaps" \
    || fail "manifest gaps: $(jq -c '[.items[] | select(.collected == false) | .item]' "$bundle/manifest.json")"
  [[ ! -e "$bundle/ops-metrics.json" && ! -e "$bundle/logs/q4-request-trace.json" ]] \
    && pass "no placeholder files for the gaps" || fail "placeholder file written for a gap"
  rm -rf "$tmp"
  [[ $failures -eq 0 ]]
}

# --- Provenance: the bundle may only name a version its own tree actually is -----------------
# `.tool` is the field a support engineer reads to learn what produced a bundle, on the channel
# ADR 0080 makes the primary one for a self-hosted install. It must name the version of the tree
# the script ran from. The release manifest's `latest` is a DIFFERENT fact — the newest
# published release — and the two disagree the moment anyone follows the runbook and clones
# `main`: a bundle stamped with a tag that does not contain the script that wrote it sends
# triage to the wrong source, which is the round trip this whole script exists to remove.
#
# Asserting that from inside this repository would be nearly vacuous — here the tag and the tree
# almost agree — so the script under test is STAGED into purpose-built module roots whose two
# possible answers are far apart: a MANIFEST.json naming a version the staged tree provably is
# not, beside a git tag this test chose. Three roots, because there are three real situations:
# a clone of the module, a copy with no git tree at all (extracted from the registry), and a
# copy vendored inside somebody else's repository, whose tags are not module versions.
PROVENANCE_TAG="v0.0.1-fixture"
PROVENANCE_MANIFEST_VERSION="99.99.99-manifest-not-this-tree"
PROVENANCE_OUTER_TAG="v7.7.7-outer-repo"

stage_module() { # stage_module <root> <script> — a module tree whose MANIFEST disagrees with it
  local root="$1" script="$2"
  mkdir -p "$root/scripts"
  cp "$script" "$root/scripts/diagnostic-bundle.sh"
  jq -n --arg v "$PROVENANCE_MANIFEST_VERSION" \
    '{schema_version: 1, module: "masterly-data/masterly/azurerm", latest: $v,
      releases: {($v): {date: "2000-01-01",
                        images: {api: "example.invalid/api:v0", frontend: "example.invalid/frontend:v0"}}}}' \
    > "$root/MANIFEST.json"
}

git_here() { # git_here <dir> <args...> — commits without depending on the runner's git identity
  local dir="$1"; shift
  git -C "$dir" -c user.email=test@example.invalid -c user.name="diagnostic bundle test" "$@"
}

run_staged() { # run_staged <root> <tmp> <label> — run the staged copy, echo its manifest's .tool
  local root="$1" tmp="$2" label="$3" manifest
  PATH="$tmp/bin:$PATH" bash "$root/scripts/diagnostic-bundle.sh" \
    --subscription 00000000-0000-0000-0000-000000000000 --out "$tmp/out-$label" \
    > "$tmp/stdout-$label" 2> "$tmp/stderr-$label" || true
  manifest=$(find "$tmp/out-$label" -name manifest.json -maxdepth 2 2>/dev/null | sort | head -n1)
  [[ -n "$manifest" ]] || return 1
  jq -r '.tool' "$manifest"
}

scenario_provenance() { # scenario_provenance <script>
  local script="$1" tmp tool
  tmp=$(mktemp -d)
  make_fakes "$tmp/bin" "$FIXTURES" "rest-q3.json"

  # (a) The module's own git tree. The tag is the answer; the manifest is not consulted.
  stage_module "$tmp/clone" "$script"
  git -c init.defaultBranch=main init -q "$tmp/clone"
  git_here "$tmp/clone" add -A
  git_here "$tmp/clone" commit -q -m "staged module"
  git_here "$tmp/clone" tag "$PROVENANCE_TAG"
  if tool=$(run_staged "$tmp/clone" "$tmp" clone); then
    if [[ "$tool" == *"$PROVENANCE_TAG"* ]]; then
      pass "provenance names the version of the tree the script ran from ($tool)"
    else
      fail "manifest .tool does not name the tree's own tag $PROVENANCE_TAG: $tool"
    fi
    if [[ "$tool" == *"$PROVENANCE_MANIFEST_VERSION"* ]]; then
      fail "manifest .tool names $PROVENANCE_MANIFEST_VERSION, the release manifest's version, which this tree is NOT: $tool"
    else
      pass "provenance does not name the release manifest's version, which the tree is not"
    fi
  else
    fail "no manifest.json written by the staged clone — the provenance assertions are vacuous"
  fi

  # (b) No git tree — a module extracted from the registry. The manifest is the only evidence
  # there is, so the field may repeat it, but it must attribute it: an unattributed version
  # reads as a fact established about the tree, which is the defect this scenario exists for.
  stage_module "$tmp/extracted" "$script"
  if tool=$(run_staged "$tmp/extracted" "$tmp" extracted); then
    if [[ "$tool" != *"$PROVENANCE_MANIFEST_VERSION"* ]]; then
      pass "with no git tree the field claims no version of its own: $tool"
    elif [[ "$tool" == *MANIFEST.json* ]]; then
      pass "with no git tree the manifest's version is attributed to the manifest: $tool"
    else
      fail "manifest .tool states $PROVENANCE_MANIFEST_VERSION as the tree's version with no evidence for it: $tool"
    fi
  else
    fail "no manifest.json written by the extracted copy"
  fi

  # (c) Vendored inside somebody else's repository. That repository's tags are its versions,
  # not this module's, and a customer who tags their infrastructure repo with a semver would
  # otherwise see it stamped on a Masterly bundle.
  stage_module "$tmp/outer/vendor/masterly" "$script"
  git -c init.defaultBranch=main init -q "$tmp/outer"
  git_here "$tmp/outer" add -A
  git_here "$tmp/outer" commit -q -m "vendored"
  git_here "$tmp/outer" tag "$PROVENANCE_OUTER_TAG"
  if tool=$(run_staged "$tmp/outer/vendor/masterly" "$tmp" vendored); then
    if [[ "$tool" == *"$PROVENANCE_OUTER_TAG"* ]]; then
      fail "manifest .tool reports the enclosing repository's tag $PROVENANCE_OUTER_TAG as a module version: $tool"
    else
      pass "a vendored copy is not stamped with the enclosing repository's tag: $tool"
    fi
  else
    fail "no manifest.json written by the vendored copy"
  fi

  rm -rf "$tmp"
  [[ $failures -eq 0 ]]
}

run_suite() { # run_suite <script> — all scenarios; non-zero if any assertion failed
  failures=0
  scenario_clean "$1" || true
  scenario_refused "$1" || true
  scenario_gaps "$1" || true
  scenario_provenance "$1" || true
  [[ $failures -eq 0 ]]
}

# --- Self-test: break the script, and insist the suite notices ----------------------------
selftest() {
  local tmp broken n rc total=0
  tmp=$(mktemp -d)
  # Three parallel lists: what the break is, the sed that introduces it, and a string that
  # must NOT survive it (proof the sed changed the copy rather than missing its target).
  local descs=(
    'keep every env value (allow-list bypassed)'
    'keep secret values (names-only projection dropped)'
    'refusal gate disabled'
    'statement-echo warning disabled (record data reaches the bundle unflagged)'
    'provenance taken from the release manifest when the tree could answer'
  )
  local exprs=(
    's/elif (\.name as \$n | \$allow | index(\$n)) != null then/elif true then/'
    's/secrets: \[\.properties\.configuration\.secrets\[\]? | \.name\]/secrets: [.properties.configuration.secrets[]?]/'
    's/^if \[\[ -n "\$findings" \]\]; then$/if false; then/'
    's/^REVIEW_FILES=\$(printf/REVIEW_FILES=""; : $(printf/'
    's/^git_root=\$(git -C "\$module_root" rev-parse --show-toplevel .*$/git_root=""/'
  )
  local gones=(
    'index($n)) != null then'
    'secrets[]? | .name]'
    'if [[ -n "$findings" ]]; then'
    'REVIEW_FILES=$(printf'
    'git_root=$(git -C "$module_root" rev-parse'
  )
  for n in 0 1 2 3 4; do
    total=$((total + 1))
    broken="$tmp/broken-$total.sh"
    sed -e "${exprs[$n]}" "$SCRIPT" > "$broken"
    if grep -qF -- "${gones[$n]}" "$broken"; then
      printf '  FAIL    selftest %d (%s): the break did not change the script — stale sed\n' "$total" "${descs[$n]}"
      rm -rf "$tmp"; return 1
    fi
    rc=0
    run_suite "$broken" > "$tmp/suite-$total.log" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
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

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
# git is required by the provenance scenario, which stages module trees to tell a tree's own
# version apart from the release manifest's. Refused rather than skipped: a scenario that
# quietly does not run is the failure mode --selftest exists to make impossible.
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

if [[ "${1:-}" == "--selftest" ]]; then
  echo "== selftest: a broken script must fail this suite"
  selftest
  exit $?
fi

echo "== diagnostic bundle: no secrets, credentials or key material; record data flagged where"
echo "                      it is not guaranteed absent (logs/q6, logs/q4)"
if run_suite "$SCRIPT"; then
  echo "== all assertions passed"
  exit 0
else
  echo "== $failures assertion(s) FAILED"
  exit 1
fi
