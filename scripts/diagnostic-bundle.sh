#!/usr/bin/env bash
# Diagnostic bundle for a Masterly self-hosted install — the one action behind "Before you
# contact us" (https://masterlydata.com/docs/self-hosted/operations/#before-you-contact-us).
#
# It collects, from YOUR subscription and YOUR Log Analytics workspace, what a support
# conversation with Masterly starts from: the images actually running, boot posture per
# revision, errors by logger, one request end to end (with --request-id), revision
# provisioning failures, the starter server's Postgres logs, the apps' configuration STATE,
# and the alert set. It writes all of it to a directory you read before you send it.
#
# What it never carries, by construction rather than by care:
#   * no secret values — Container App secrets are listed by NAME only, and an environment
#     variable's value is copied only when its name is on the allow-list below (the install's
#     mode, ids, bindings and endpoints); every other value is omitted, not masked;
#   * no record data or attribute values — the log lines it exports are the ones the apps
#     already redact at the formatter (identifiers, counts, durations), and nothing here
#     reads a database or an API that serves records;
#   * no credential of yours — the API token for /v1/ops/metrics is read from the
#     environment, sent once, and written nowhere.
# Before it finishes it scans everything it wrote for secret-shaped content (a URL with
# credentials, a JWT, a private key, a key=value that looks like a password) and REFUSES to
# hand over a bundle that trips the scan — that is the last line, not the first. The scan and
# the allow-list are exercised by tests/diagnostic_bundle_test.sh, which is what makes the
# sentence above checkable rather than hopeful.
#
# READ-ONLY. Nothing is sent anywhere: this is an export you perform, not reporting the
# install performs. Masterly cannot run it, cannot fetch its output, and receives it only
# when you attach it to a message.
#
# Every item is initialised to "not collected" and only cleared by a command that succeeds,
# so an az error or a denied permission reports as a gap in manifest.json — never as a
# silently empty file. Exit 0 when the bundle was written; 3 when it was refused.
# Usage: ./scripts/diagnostic-bundle.sh --help

set -euo pipefail

SUBSCRIPTION=""
NAME_PREFIX="masterly"
REQUEST_ID=""
SINCE="PT24H"
API_URL=""
OPS_METRICS_FILE=""
OUT_PARENT="."

usage() {
  cat <<'EOF'
Usage: diagnostic-bundle.sh --subscription <id> [options]

  --subscription <id>     The subscription the install runs in (required)
  --name-prefix <slug>    The module's name_prefix (default: masterly) — resolves
                          rg-<prefix>-aca, rg-<prefix>-data, aca-<prefix>, log-<prefix>
  --request-id <id>       X-Request-Id of the failing call — adds the end-to-end trace (Q4)
  --since <ISO 8601>      Window for errors, the request trace and Postgres logs
                          (default: PT24H). Boot posture and revision failures always
                          look back P7D; running images PT2H.
  --api-url <https://…>   Also fetch GET /v1/ops/metrics from the API's URL, with the bearer
                          token in the MASTERLY_API_TOKEN environment variable. The api is
                          reachable from a workstation only with api_ingress_external =
                          true, or from inside the VNet. The token is sent once, never written.
  --ops-metrics <file>    Attach an /v1/ops/metrics body you already fetched, instead.
  --out <dir>             Where to write the bundle directory (default: current directory)
  --help

Read the bundle before you send it. Then attach it to support@masterlydata.com.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="${2:-}";      shift 2 ;;
    --name-prefix)  NAME_PREFIX="${2:-}";       shift 2 ;;
    --request-id)   REQUEST_ID="${2:-}";        shift 2 ;;
    --since)        SINCE="${2:-}";             shift 2 ;;
    --api-url)      API_URL="${2:-}";           shift 2 ;;
    --ops-metrics)  OPS_METRICS_FILE="${2:-}";  shift 2 ;;
    --out)          OUT_PARENT="${2:-}";        shift 2 ;;
    --help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SUBSCRIPTION" ]] || { usage >&2; exit 2; }
[[ "$SINCE" =~ ^P(T?[0-9]+[DHMS])+$ ]] || {
  echo "--since must be an ISO 8601 duration such as PT6H or P3D" >&2; exit 2
}
if [[ -n "$API_URL" && -n "$OPS_METRICS_FILE" ]]; then
  echo "give --api-url or --ops-metrics, not both" >&2; exit 2
fi
if [[ -n "$API_URL" && -z "${MASTERLY_API_TOKEN:-}" ]]; then
  echo "--api-url needs the bearer token in MASTERLY_API_TOKEN (an environment variable," >&2
  echo "not an argument — arguments are visible to every process on the machine)." >&2
  exit 2
fi

# --- Names the module fixes per install (main.tf) ------------------------------------
RG_ACA="rg-${NAME_PREFIX}-aca"
RG_DATA="rg-${NAME_PREFIX}-data"
ACA_ENV="aca-${NAME_PREFIX}"
WORKSPACE="log-${NAME_PREFIX}"
APPS="ca-api ca-workers ca-frontend"

# Environment variables whose VALUE is copied into the bundle. Everything else the apps
# carry is listed by name only. The rule for adding one: it must be configuration state a
# diagnosis turns on — a mode, an id, a binding, an endpoint — and never a person's address,
# a credential, or material that only makes sense next to a credential.
ENV_VALUE_ALLOWLIST='[
  "MASTERLY_MODE", "MASTERLY_REGION", "MASTERLY_ORG_ID", "MASTERLY_INSTALL_ID",
  "MASTERLY_ALLOWED_REGIONS", "MASTERLY_CONTROLPLANE_STORE", "MASTERLY_SECRET_STORE",
  "MASTERLY_SESSION_REGISTRY", "MASTERLY_IDENTITY_BINDING", "MASTERLY_IDP_BINDING",
  "MASTERLY_ALLOW_DEV_BINDING", "MASTERLY_BUS_BINDING", "MASTERLY_SERVICEBUS_NAMESPACE",
  "MASTERLY_SERVICEBUS_QUEUE", "MASTERLY_INPROCESS_WORKER", "MASTERLY_API_BASE_URL",
  "MASTERLY_KEYVAULT_URL", "MASTERLY_ACS_ENDPOINT", "MASTERLY_OIDC_ALLOWED_ISSUERS",
  "MASTERLY_OIDC_AUDIENCE", "MASTERLY_OIDC_JWKS_URI", "MASTERLY_OIDC_AUTHORITY",
  "MASTERLY_OIDC_REDIRECT_URI", "MASTERLY_OIDC_SCOPES", "MASTERLY_LICENSE_ISSUER_URL",
  "MASTERLY_TELEMETRY_URL"
]'

# --- Output helpers -------------------------------------------------------------------
say()   { printf '%s\n' "$*"; }
item()  { printf '  %-8s %s\n' "$1" "$2"; }
head2() { printf '\n== %s\n' "$*"; }
rel()   { printf '%s' "${1#"$BUNDLE"/}"; }  # a path as the bundle's reader sees it, never the operator's home directory

# Each collected item is recorded in manifest.json as collected true/false with a reason,
# so the reader can tell a quiet install from a permission that was denied.
MANIFEST_ITEMS="[]"
record() { # record <item> <collected true|false> <detail>
  MANIFEST_ITEMS=$(jq -c --arg i "$1" --argjson c "$2" --arg d "$3" \
    '. + [{"item": $i, "collected": $c, "detail": $d}]' <<<"$MANIFEST_ITEMS")
  if [[ "$2" == "true" ]]; then item "ok" "$1 — $3"; else item "MISSING" "$1 — $3"; fi
}

# --- 0. Tooling and access. Hard exit: nothing below is meaningful without it. ---------
head2 "Tooling and access"
for tool in az jq; do
  command -v "$tool" >/dev/null 2>&1 || { say "  FAIL    $tool is not on PATH." >&2; exit 1; }
done
account_state="UNKNOWN"
account_state=$(az account show --subscription "$SUBSCRIPTION" --query state -o tsv 2>/dev/null) \
  || account_state="UNKNOWN"
if [[ "$account_state" != "Enabled" ]]; then
  say "  FAIL    cannot read subscription $SUBSCRIPTION (state: $account_state)." >&2
  say "          Run 'az login' and confirm the subscription id and your tenant." >&2
  exit 1
fi
item "ok" "subscription $SUBSCRIPTION is readable and Enabled"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BUNDLE="${OUT_PARENT%/}/masterly-diagnostics-${NAME_PREFIX}-${STAMP}"
mkdir -p "$BUNDLE/apps" "$BUNDLE/logs"
item "ok" "writing to $BUNDLE"

# azj <item> <outfile> <jq filter> -- <az args…>
# Runs an az command with JSON output, projects it through the jq filter, and writes the
# result. The projection is the redaction: only what the filter names reaches the file.
azj() {
  local item_name="$1" outfile="$2" filter="$3"; shift 3
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local raw
  if raw=$(az "$@" --subscription "$SUBSCRIPTION" -o json 2>/dev/null) && [[ -n "$raw" ]]; then
    if jq --argjson allow "$ENV_VALUE_ALLOWLIST" "$filter" <<<"$raw" > "$outfile" 2>/dev/null; then
      record "$item_name" true "$(rel "$outfile")"
      return 0
    fi
  fi
  rm -f "$outfile"
  record "$item_name" false "az ${1:-} ${2:-} failed or returned nothing — check your access to $RG_ACA / $RG_DATA"
  return 1
}

# --- 1. The install's shape --------------------------------------------------------------
head2 "Install"

# Which data plane: the starter server exists only when the module provisioned it; on BYO-DB
# the data group holds Redis and the vault but no psql-<prefix>-* server.
POSTGRES_NAME=""
DATA_PLANE="unknown"
pg_list="ERROR"
pg_list=$(az postgres flexible-server list -g "$RG_DATA" --subscription "$SUBSCRIPTION" \
            --query "[?starts_with(name, 'psql-${NAME_PREFIX}-')].name" -o tsv 2>/dev/null) \
  || pg_list="ERROR"
if [[ "$pg_list" == "ERROR" ]]; then
  record "data-plane" false "could not list Postgres servers in $RG_DATA"
elif [[ -z "$pg_list" ]]; then
  DATA_PLANE="byo-db"
  record "data-plane" true "BYO-DB (no starter server in $RG_DATA)"
else
  POSTGRES_NAME=$(printf '%s\n' "$pg_list" | head -n1)
  DATA_PLANE="starter-postgres"
  record "data-plane" true "starter server $POSTGRES_NAME"
fi

# The workspace's customer id is what the query API addresses; the resource id is what the
# diagnostic settings point at. Both are identifiers.
WORKSPACE_CUSTOMER_ID=""
WORKSPACE_CUSTOMER_ID=$(az monitor log-analytics workspace show -g "$RG_ACA" -n "$WORKSPACE" \
  --subscription "$SUBSCRIPTION" --query customerId -o tsv 2>/dev/null) || WORKSPACE_CUSTOMER_ID=""
if [[ -n "$WORKSPACE_CUSTOMER_ID" ]]; then
  record "workspace" true "$WORKSPACE ($WORKSPACE_CUSTOMER_ID)"
else
  record "workspace" false "cannot read $WORKSPACE in $RG_ACA — the log queries below will be skipped"
fi

azj "environment" "$BUNDLE/environment.json" '{
  name: .name, location: .location,
  provisioningState: .properties.provisioningState,
  defaultDomain: .properties.defaultDomain,
  staticIp: .properties.staticIp,
  internal: .properties.vnetConfiguration.internal,
  infrastructureSubnetId: .properties.vnetConfiguration.infrastructureSubnetId,
  peerTrafficEncryption: .properties.peerTrafficConfiguration.encryption.enabled,
  logsDestination: .properties.appLogsConfiguration.destination,
  workloadProfiles: [.properties.workloadProfiles[]? | {name, workloadProfileType}]
}' -- containerapp env show -g "$RG_ACA" -n "$ACA_ENV" || true

if [[ -n "$POSTGRES_NAME" ]]; then
  azj "postgres" "$BUNDLE/postgres.json" '{
    name: .name, location: .location, state: .state, version: .version,
    sku: .sku, storage: {storageSizeGb: .storage.storageSizeGb, tier: .storage.tier,
                         autoGrow: .storage.autoGrow},
    highAvailability: .highAvailability, backup: .backup,
    availabilityZone: .availabilityZone, publicNetworkAccess: .network.publicNetworkAccess,
    fullyQualifiedDomainName: .fullyQualifiedDomainName
  }' -- postgres flexible-server show -g "$RG_DATA" -n "$POSTGRES_NAME" || true
fi

# --- 2. The apps: configuration state, revisions, replicas -------------------------------
head2 "Container Apps"
for app in $APPS; do
  azj "app:$app" "$BUNDLE/apps/$app.json" '
    def env_entry:
      if .secretRef != null then {name, source: "secret", secret_name: .secretRef}
      elif (.name as $n | $allow | index($n)) != null then {name, source: "plain", value}
      else {name, source: "plain", value_omitted: true} end;
    {
      name: .name, location: .location,
      provisioningState: .properties.provisioningState,
      runningStatus: .properties.runningStatus,
      latestRevisionName: .properties.latestRevisionName,
      latestReadyRevisionName: .properties.latestReadyRevisionName,
      identity: {type: .identity.type,
                 userAssigned: [(.identity.userAssignedIdentities // {}) | keys[]]},
      configuration: {
        activeRevisionsMode: .properties.configuration.activeRevisionsMode,
        ingress: (.properties.configuration.ingress | if . == null then null else {
          external, targetPort, transport, allowInsecure,
          ipSecurityRestrictions: ((.ipSecurityRestrictions // []) | length),
          traffic: [.traffic[]? | {revisionName, latestRevision, weight}]
        } end),
        registries: [.properties.configuration.registries[]? |
          {server, auth: (if .identity != null and .identity != "" then "managed-identity"
                          else "credential" end)}],
        secrets: [.properties.configuration.secrets[]? | .name]
      },
      template: {
        revisionSuffix: .properties.template.revisionSuffix,
        scale: {minReplicas: .properties.template.scale.minReplicas,
                maxReplicas: .properties.template.scale.maxReplicas},
        containers: [.properties.template.containers[] | {
          name, image, resources,
          probes: [.probes[]? | {type, path: (.httpGet.path // null),
                                 periodSeconds, failureThreshold}],
          env: [.env[]? | env_entry]
        }]
      }
    }' -- containerapp show -g "$RG_ACA" -n "$app" || continue

  azj "revisions:$app" "$BUNDLE/apps/$app.revisions.json" '[.[] | {
    name, createdTime: .properties.createdTime, active: .properties.active,
    provisioningState: .properties.provisioningState,
    healthState: .properties.healthState, runningState: .properties.runningState,
    trafficWeight: .properties.trafficWeight, replicas: .properties.replicas,
    images: [.properties.template.containers[]? | .image],
    lastActiveTime: .properties.lastActiveTime
  }]' -- containerapp revision list -g "$RG_ACA" -n "$app" || true

  # Replicas of the latest revision: the "running but never ready" state the alerts cannot
  # see (README, "What the alerts detect, and what they do not") is visible here.
  azj "replicas:$app" "$BUNDLE/apps/$app.replicas.json" '[.[] | {
    name, createdTime: .properties.createdTime, runningState: .properties.runningState,
    containers: [.properties.containers[]? | {name, ready, started, restartCount,
                                              runningState, runningStateDetails}]
  }]' -- containerapp replica list -g "$RG_ACA" -n "$app" || true
done

# --- 3. Alerts: what exists, and whether anything is listening -------------------------
head2 "Alerts"
alerts="[]"
alerts_ok=true
for rg in "$RG_ACA" "$RG_DATA"; do
  part="ERROR"
  part=$(az monitor metrics alert list -g "$rg" --subscription "$SUBSCRIPTION" -o json 2>/dev/null) \
    || part="ERROR"
  if [[ "$part" == "ERROR" ]]; then alerts_ok=false; continue; fi
  alerts=$(jq -c --arg rg "$rg" --argjson add "$part" '. + [$add[] | {
    resourceGroup: $rg, name, enabled, severity, windowSize, evaluationFrequency,
    actions: ((.actions // []) | length), scopes: ((.scopes // []) | length)
  }]' <<<"$alerts")
done
# Scheduled query rules (the postgres-silent alert) — listed by name through the generic
# resource list, which needs no CLI extension.
sqr="ERROR"
sqr=$(az resource list -g "$RG_ACA" --resource-type Microsoft.Insights/scheduledQueryRules \
        --subscription "$SUBSCRIPTION" --query "[].name" -o json 2>/dev/null) || sqr="ERROR"
[[ "$sqr" == "ERROR" ]] && { sqr="[]"; alerts_ok=false; }
ags="ERROR"
ags=$(az monitor action-group list -g "$RG_ACA" --subscription "$SUBSCRIPTION" -o json 2>/dev/null) \
  || ags="ERROR"
if [[ "$ags" == "ERROR" ]]; then
  ags="[]"; alerts_ok=false
else
  # Receivers are COUNTED by kind, never listed: an address is a person's, not a diagnosis.
  ags=$(jq -c '[.[] | {name, enabled,
    receivers: {email: ((.emailReceivers // []) | length), sms: ((.smsReceivers // []) | length),
                webhook: ((.webhookReceivers // []) | length),
                other: (((.armRoleReceivers // []) + (.azureFunctionReceivers // []) +
                         (.logicAppReceivers // []) + (.eventHubReceivers // [])) | length)}}]' <<<"$ags")
fi
jq -n --argjson metricAlerts "$alerts" --argjson scheduledQueryRules "$sqr" --argjson actionGroups "$ags" \
  '{metricAlerts: $metricAlerts, scheduledQueryRules: $scheduledQueryRules, actionGroups: $actionGroups}' \
  > "$BUNDLE/alerts.json"
if $alerts_ok; then
  record "alerts" true "alerts.json"
else
  record "alerts" false "partial — one or more alert listings failed; alerts.json holds what was readable"
fi

# --- 4. Log Analytics: the six published queries ------------------------------------------
# Through the query REST API with az rest — part of the core CLI, so it needs no extension
# that a locked-down workstation may not be allowed to install. Each answer is written as the
# API returns it: {"tables": [{"name", "columns": [...], "rows": [...]}]}.
head2 "Log Analytics"
LOGS_URL="https://api.loganalytics.azure.com/v1/workspaces/${WORKSPACE_CUSTOMER_ID}/query"

kql() { # kql <item> <outfile> <timespan> <query>
  local item_name="$1" outfile="$2" timespan="$3" query="$4" body out
  if [[ -z "$WORKSPACE_CUSTOMER_ID" ]]; then
    record "$item_name" false "skipped — workspace unreadable"; return 0
  fi
  body=$(jq -n --arg q "$query" --arg t "$timespan" '{query: $q, timespan: $t}')
  if out=$(az rest --method post --url "$LOGS_URL" --resource "https://api.loganalytics.io" \
             --headers "Content-Type=application/json" --body "$body" -o json 2>/dev/null) \
     && jq -e '.tables' <<<"$out" >/dev/null 2>&1; then
    jq '{tables: [.tables[] | {name, columns, rows}]}' <<<"$out" > "$outfile"
    local rows
    rows=$(jq '[.tables[].rows | length] | add // 0' "$outfile")
    record "$item_name" true "$(rel "$outfile") ($rows rows, $timespan)"
  else
    rm -f "$outfile"
    record "$item_name" false "query failed — Log Analytics Reader on $WORKSPACE is what it needs"
  fi
}

kql "logs:q1-running-images" "$BUNDLE/logs/q1-running-images.json" "PT2H" '
ContainerAppConsoleLogs_CL
| where ContainerAppName_s in ("ca-api", "ca-workers", "ca-frontend")
| summarize arg_max(TimeGenerated, RevisionName_s, ContainerImage_s) by ContainerAppName_s'

kql "logs:q2-boot-posture" "$BUNDLE/logs/q2-boot-posture.json" "P7D" '
ContainerAppConsoleLogs_CL
| where ContainerAppName_s in ("ca-api", "ca-workers")
| where Log_s has "starting: mode="
| extend b = parse_json(Log_s)
| project TimeGenerated, ContainerAppName_s, RevisionName_s, ContainerImage_s,
          service = tostring(b.service), mode = tostring(b.mode),
          install_id = tostring(b.install_id),
          controlplane_store = tostring(b.controlplane_store),
          secret_store = tostring(b.secret_store),
          session_registry = tostring(b.session_registry),
          bus_binding = tostring(b.bus_binding)
| order by TimeGenerated desc'

kql "logs:q3-errors-by-logger" "$BUNDLE/logs/q3-errors-by-logger.json" "$SINCE" '
ContainerAppConsoleLogs_CL
| where ContainerAppName_s in ("ca-api", "ca-workers")
| extend b = parse_json(Log_s)
| where tostring(b.level) == "ERROR"
| summarize events = count(), latest = max(TimeGenerated)
    by ContainerAppName_s, logger = tostring(b.logger)
| order by events desc'

if [[ -n "$REQUEST_ID" ]]; then
  # The request id is interpolated as a KQL string literal; escape the two characters that
  # could end it. It is an identifier the caller typed, and it is recorded in the manifest.
  rid_lit=${REQUEST_ID//\\/\\\\}; rid_lit=${rid_lit//\"/\\\"}
  kql "logs:q4-request-trace" "$BUNDLE/logs/q4-request-trace.json" "$SINCE" '
ContainerAppConsoleLogs_CL
| where ContainerAppName_s in ("ca-api", "ca-workers")
| extend b = parse_json(Log_s)
| where tostring(b.request_id) == "'"$rid_lit"'"
| project TimeGenerated, ContainerAppName_s, RevisionName_s,
          level = tostring(b.level), logger = tostring(b.logger),
          message = tostring(b.message), exception = tostring(b.exception)
| order by TimeGenerated asc'
else
  record "logs:q4-request-trace" false "no --request-id given — the single highest-value item; re-run with the X-Request-Id of the failing call if you have one"
fi

kql "logs:q5-revision-failures" "$BUNDLE/logs/q5-revision-failures.json" "P7D" '
ContainerAppSystemLogs_CL
| where ContainerAppName_s in ("ca-api", "ca-workers", "ca-frontend")
| where Log_s has_any ("Error provisioning revision", "ErrImagePull",
                       "ContainerCrashing", "Timeout")
| project TimeGenerated, ContainerAppName_s, RevisionName_s, Log_s
| order by TimeGenerated desc'

if [[ -n "$POSTGRES_NAME" ]]; then
  kql "logs:q6-postgres-logs" "$BUNDLE/logs/q6-postgres-logs.json" "$SINCE" '
AzureDiagnostics
| where Category == "PostgreSQLLogs"
| where column_ifexists("LogicalServerName_s", "") == "'"$POSTGRES_NAME"'"
| project TimeGenerated, Resource, Message
| order by TimeGenerated desc'
else
  record "logs:q6-postgres-logs" false "skipped — BYO-DB, or the starter server could not be resolved"
fi

# --- 5. /v1/ops/metrics ------------------------------------------------------------------
head2 "Operational metrics"
if [[ -n "$OPS_METRICS_FILE" ]]; then
  if jq -e '.environments and .jobs' "$OPS_METRICS_FILE" >/dev/null 2>&1; then
    jq '.' "$OPS_METRICS_FILE" > "$BUNDLE/ops-metrics.json"
    record "ops-metrics" true "ops-metrics.json (attached from a file)"
  else
    record "ops-metrics" false "$OPS_METRICS_FILE is not a /v1/ops/metrics body"
  fi
elif [[ -n "$API_URL" ]]; then
  # The token goes in a header, from the environment, once. `-H @-` reads the header line
  # from stdin so it never appears on a command line.
  if printf 'Authorization: Bearer %s\n' "$MASTERLY_API_TOKEN" \
       | curl -sS -f --max-time 30 -H @- -H "Accept: application/json" \
              "${API_URL%/}/v1/ops/metrics" -o "$BUNDLE/ops-metrics.json" 2>/dev/null \
     && jq -e '.environments and .jobs' "$BUNDLE/ops-metrics.json" >/dev/null 2>&1; then
    record "ops-metrics" true "ops-metrics.json (from $API_URL)"
  else
    rm -f "$BUNDLE/ops-metrics.json"
    record "ops-metrics" false "GET ${API_URL%/}/v1/ops/metrics failed — it needs an Organization-scoped token with ops:read"
  fi
else
  record "ops-metrics" false "not collected — pass --api-url with MASTERLY_API_TOKEN set, or --ops-metrics <file>"
fi

# --- 6. Manifest and cover note ----------------------------------------------------------
head2 "Manifest"
az_version=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "unknown")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
module_version="unknown"
if [[ -f "$script_dir/../MANIFEST.json" ]]; then
  module_version=$(jq -r '.latest // "unknown"' "$script_dir/../MANIFEST.json" 2>/dev/null || echo "unknown")
fi
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "diagnostic-bundle.sh (terraform-azurerm-masterly $module_version)" \
  --arg az "$az_version" \
  --arg subscription "$SUBSCRIPTION" --arg prefix "$NAME_PREFIX" \
  --arg rg_aca "$RG_ACA" --arg rg_data "$RG_DATA" --arg env "$ACA_ENV" \
  --arg workspace "$WORKSPACE" --arg workspace_id "$WORKSPACE_CUSTOMER_ID" \
  --arg data_plane "$DATA_PLANE" --arg postgres "$POSTGRES_NAME" \
  --arg request_id "$REQUEST_ID" --arg since "$SINCE" \
  --argjson items "$MANIFEST_ITEMS" '{
    generated_at: $generated_at, tool: $tool, azure_cli: $az,
    install: {subscription: $subscription, name_prefix: $prefix,
              resource_groups: [$rg_aca, $rg_data], environment: $env,
              workspace: {name: $workspace, customer_id: $workspace_id},
              data_plane: $data_plane,
              postgres_server: (if $postgres == "" then null else $postgres end)},
    request_id: (if $request_id == "" then null else $request_id end),
    window: $since,
    carries: "identifiers, counts, durations, versions and configuration state",
    omits: "record data, attribute values, connection strings, secret values, credentials",
    items: $items
  }' > "$BUNDLE/manifest.json"

cat > "$BUNDLE/README.txt" <<EOF
Masterly diagnostic bundle — $STAMP
Install: $NAME_PREFIX in subscription $SUBSCRIPTION ($DATA_PLANE)

Produced by scripts/diagnostic-bundle.sh from the terraform-azurerm-masterly module, run
by you, in your subscription. Nothing in it has been sent anywhere.

What is here
  manifest.json            what was collected, what was not, and why
  environment.json         the Container App Environment
  postgres.json            the starter Postgres server (absent on BYO-DB)
  apps/<app>.json          each app's configuration STATE: images, scale, probes, ingress,
                           secret NAMES, and environment variables — values only for the
                           allow-listed configuration keys, omitted for everything else
  apps/<app>.revisions.json, apps/<app>.replicas.json
                           revisions and their replicas — the image tags actually running
  alerts.json              the alert set, and how many receivers each action group has
  logs/q1..q6-*.json       the six published Log Analytics queries, as the API returned them
  ops-metrics.json         GET /v1/ops/metrics, when it was fetched or attached

What is not here, by construction
  No secret values, no connection strings, no credentials — including the API token this
  script may have used. No record data and no attribute values: the log lines are the ones
  the apps redact at the formatter, and nothing here reads a database.

Before you send it
  Read it. It is plain JSON. If a log line looks like it carries customer data, that is a
  defect to report to Masterly, not a line to forward — delete it from the file and say so.
  Then attach the bundle to your message to support@masterlydata.com. The X-Request-Id and a
  UTC timestamp of the failing call are the two things most worth adding in the text.
EOF
record "manifest" true "manifest.json"

# --- 7. The refusal gate ------------------------------------------------------------------
# Everything written is scanned for secret-shaped content. The allow-list above is what keeps
# secrets out; this is what happens if it did not — a bundle that trips it is renamed, kept
# for you to inspect locally, and NOT handed over. Findings are reported by file and line,
# never by content: printing the match would put the secret on the terminal it was kept off.
head2 "Redaction gate"
GATE_PATTERNS=(
  '[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]"'"'"']+@'                    # scheme://user:pass@ — a DSN with credentials
  'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}'                           # a JWT (two base64url JSON segments)
  '-----BEGIN [A-Z ]*PRIVATE KEY'                                        # PEM private key
  '[Bb]earer [A-Za-z0-9._~+/=-]{20,}'                                    # a bearer token in text
  '(AccountKey|SharedAccessKey|sig)=[^&[:space:]"'"'"']{16,}'            # storage / SAS / Service Bus keys
  '[A-Za-z0-9+/]{86}=='                                                  # a 64-byte base64 key
  '(password|passwd|pwd|secret|token|api[_-]?key|client[_-]?secret)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?[^[:space:]"'"'"',;]{6,}'
)
findings=""
for pat in "${GATE_PATTERNS[@]}"; do
  hit=$(grep -rEIn --ignore-case "$pat" "$BUNDLE" 2>/dev/null | cut -d: -f1,2 || true)
  [[ -n "$hit" ]] && findings="${findings}${hit}"$'\n'
done
if [[ -n "$findings" ]]; then
  REFUSED="${BUNDLE}-REFUSED"
  mv "$BUNDLE" "$REFUSED"
  say "  REFUSED the bundle carries content shaped like a secret. It has been kept at" >&2
  say "          $REFUSED for you to inspect, and must not be sent." >&2
  say "          File and line of each finding (the content is deliberately not printed):" >&2
  printf '%s' "$findings" | sed "s#^$REFUSED/##" | sort -u | sed 's/^/            /' >&2
  say "          A log line carrying a secret is a defect — report the file and line, not the line." >&2
  exit 3
fi
item "ok" "no secret-shaped content found in $(find "$BUNDLE" -type f | wc -l | tr -d ' ') files"

# --- 8. Hand over ----------------------------------------------------------------------------
head2 "Done"
missing=$(jq -r '[.items[] | select(.collected == false) | .item] | join(", ")' "$BUNDLE/manifest.json")
say "  Bundle:  $BUNDLE"
[[ -n "$missing" ]] && say "  Missing: $missing (see manifest.json for why)"
say ""
say "  Read it before you send it, then package it:"
say "    tar -czf ${BUNDLE##*/}.tar.gz -C $(dirname "$BUNDLE") ${BUNDLE##*/}"
say "  and attach the archive to support@masterlydata.com with the X-Request-Id and a UTC"
say "  timestamp of the failing call."
exit 0
