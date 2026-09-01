#!/usr/bin/env bash
# Preflight for a Masterly self-hosted install (module v0.7.0).
#
# READ-ONLY by default: it inspects a subscription and reports. Pass --register to
# additionally register the resource providers (needs Contributor or Owner at
# SUBSCRIPTION scope).
#
# Every check is initialised to its failure value and only cleared by a command that
# succeeds, so an az error, a denied permission, or an empty result is reported as a
# failure — never as a pass. Checks Azure does not answer from the CLI are printed at
# the end as MANUAL; they are yours to confirm, and they are printed last so they
# cannot scroll away.
#
# Exit 0 only when nothing FAILED. Usage: ./scripts/preflight.sh --help

set -euo pipefail

SUBSCRIPTION=""
LOCATION=""
MODE="demo"
PRINCIPAL=""
NAME_PREFIX="masterly"
WANT_ACS_EMAIL=false
WANT_BYO_DB=false
DO_REGISTER=false
FAILURES=0
WARNINGS=0
MANUAL_NOTES=()

usage() {
  cat <<'EOF'
Usage: preflight.sh --subscription <id> --location <region> [options]

  --subscription <id>     Target subscription for the install (required)
  --location <region>     Azure region, e.g. swedencentral (required)
  --mode demo|production  Posture you intend to apply (default: demo)
  --principal <objectId>  Object id of the identity terraform runs as (role check)
  --name-prefix <slug>    The module's name_prefix (default: masterly)
  --byo-db                You will set external_database_url (skips Postgres checks)
  --acs-email             You will set email_acs_enabled = true
  --register              Also register missing resource providers (mutates!)
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="${2:-}"; shift 2 ;;
    --location)     LOCATION="${2:-}";     shift 2 ;;
    --mode)         MODE="${2:-}";         shift 2 ;;
    --principal)    PRINCIPAL="${2:-}";    shift 2 ;;
    --name-prefix)  NAME_PREFIX="${2:-}";  shift 2 ;;
    --byo-db)       WANT_BYO_DB=true;      shift ;;
    --acs-email)    WANT_ACS_EMAIL=true;   shift ;;
    --register)     DO_REGISTER=true;      shift ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SUBSCRIPTION" && -n "$LOCATION" ]] || { usage >&2; exit 2; }
[[ "$MODE" == "demo" || "$MODE" == "production" ]] || {
  echo "--mode must be demo or production" >&2; exit 2
}

pass()   { printf '  PASS    %s\n' "$*"; }
warn()   { printf '  WARN    %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail()   { printf '  FAIL    %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
manual() { MANUAL_NOTES+=("$*"); }
head2()  { printf '\n== %s\n' "$*"; }

# --- 0. Tooling and access. Hard exit: every later check is meaningless without it.

head2 "Tooling and access"
command -v az >/dev/null 2>&1 || {
  echo "  FAIL    the Azure CLI (az) is not on PATH." >&2; exit 1
}

account_state="UNKNOWN"
account_state=$(az account show --subscription "$SUBSCRIPTION" --query state -o tsv 2>/dev/null) \
  || account_state="UNKNOWN"
if [[ "$account_state" != "Enabled" ]]; then
  echo "  FAIL    cannot read subscription $SUBSCRIPTION (state: $account_state)." >&2
  echo "          Run 'az login' and confirm the subscription id and your tenant." >&2
  exit 1
fi
pass "subscription $SUBSCRIPTION is readable and Enabled"

# --- 1. Resource providers. Derived from the resources this module declares.

head2 "Resource providers"
PROVIDERS=(
  # Checked unconditionally rather than only when you plan to use the bus: the namespace costs
  # nothing while unused, and registering it now means flipping enable_service_bus later never
  # hits a fresh-subscription 409 on a provider nobody thought to register.
  Microsoft.ServiceBus
  Microsoft.Storage             # the Terraform state storage account — needed FIRST
  Microsoft.App                 # ACA environment + ca-api / ca-frontend / ca-workers
  Microsoft.Network             # vnet, subnets, private endpoints, private DNS zones
  Microsoft.ManagedIdentity     # id-<prefix>-apps
  Microsoft.OperationalInsights # the Log Analytics workspace
)
if [[ "$MODE" == "production" ]]; then
  PROVIDERS+=(Microsoft.Insights Microsoft.KeyVault Microsoft.Cache)
fi
$WANT_BYO_DB      || PROVIDERS+=(Microsoft.DBforPostgreSQL)
$WANT_ACS_EMAIL   && PROVIDERS+=(Microsoft.Communication)

for ns in "${PROVIDERS[@]}"; do
  state="ERROR"
  state=$(az provider show --namespace "$ns" --subscription "$SUBSCRIPTION" \
            --query registrationState -o tsv 2>/dev/null) || state="ERROR"
  [[ -n "$state" ]] || state="ERROR"

  if [[ "$state" == "Registered" ]]; then
    pass "$ns"
  elif $DO_REGISTER && [[ "$state" != "ERROR" ]]; then
    printf '  ...     registering %s\n' "$ns"
    if az provider register --namespace "$ns" --subscription "$SUBSCRIPTION" --wait >/dev/null 2>&1; then
      state="ERROR"
      state=$(az provider show --namespace "$ns" --subscription "$SUBSCRIPTION" \
                --query registrationState -o tsv 2>/dev/null) || state="ERROR"
      if [[ "$state" == "Registered" ]]; then
        pass "$ns (registered)"
      else
        fail "$ns is $state after register"
      fi
    else
      fail "$ns — register failed. '*/register/action' is in Contributor and Owner at SUBSCRIPTION scope."
    fi
  else
    fail "$ns is $state — register it before the first apply"
  fi
done
$DO_REGISTER || echo "  (re-run with --register to register the failures above)"

# --- 2. The deploying identity. We report; we never grant.

head2 "Deploying identity"
if [[ -z "$PRINCIPAL" ]]; then
  warn "no --principal given; skipping the role check"
  manual "Confirm the identity running 'terraform apply' holds Contributor AND (User Access
          Administrator, Role Based Access Control Administrator, or Owner) at SUBSCRIPTION
          scope. Contributor alone cannot write role assignments and the apply fails
          mid-run, not at plan."
else
  roles="ERROR"
  UNEXPANDED=false
  # --include-groups expands Entra group membership and needs directory read, which a CI
  # service principal usually lacks. Falling back keeps a missing directory permission from
  # reading as "you have no roles" on the check that matters most — but ONLY if we remember
  # that we fell back. Without the flag below, a fallback that succeeds with an EMPTY list
  # leaves roles="" (not "ERROR"), so both checks below emit FAIL and the script exits 1 —
  # precisely the "you have no roles" misreport the fallback exists to prevent, and the
  # common case for a Contributor grant that arrives through an Entra group.
  roles=$(az role assignment list --assignee "$PRINCIPAL" \
            --scope "/subscriptions/$SUBSCRIPTION" --include-inherited --include-groups \
            --query "[].roleDefinitionName" -o tsv 2>/dev/null) \
    || { UNEXPANDED=true
         roles=$(az role assignment list --assignee "$PRINCIPAL" \
                   --scope "/subscriptions/$SUBSCRIPTION" --include-inherited \
                   --query "[].roleDefinitionName" -o tsv 2>/dev/null); } \
    || roles="ERROR"

  if [[ "$roles" == "ERROR" ]]; then
    fail "could not read role assignments for $PRINCIPAL (you may lack read on Microsoft.Authorization)"
  else
    printf '  roles: %s\n' "$(echo "$roles" | tr '\n' ' ')"
    # A role granted through a group is invisible to the unexpanded query, so an empty result
    # there means "unknown", not "none". Report it as a WARN the operator must resolve rather
    # than a FAIL that stops them.
    if $UNEXPANDED && [[ -z "$roles" ]]; then
      warn "could not expand group membership (no directory read) and the direct query returned
            nothing. That is 'unknown', not 'none' — a Contributor grant arriving through an
            Entra group looks identical. Confirm in the portal: Subscription > Access control
            (IAM) > Check access."
    else
      if echo "$roles" | grep -qxE 'Contributor|Owner'; then
        pass "can create resources"
      else
        fail "no Contributor or Owner at subscription scope"
      fi
      if echo "$roles" | grep -qxE 'Owner|User Access Administrator|Role Based Access Control Administrator'; then
        pass "can create role assignments"
      else
        fail "cannot create role assignments — the module writes up to five of them"
      fi
    fi
  fi
fi

# --- 3. PostgreSQL. SKU availability is answerable; quota and HA are not.

head2 "PostgreSQL"
if $WANT_BYO_DB; then
  pass "BYO-DB — the module provisions no database, so none of this applies"
else
  skus="ERROR"
  # -o json, not tsv: the SKU names are nested under supportedServerVersions[].supportedSkus[]
  # and tsv flattens scalars only, so a tsv grep can miss a SKU the region really offers.
  skus=$(az postgres flexible-server list-skus --location "$LOCATION" \
           --subscription "$SUBSCRIPTION" -o json 2>/dev/null) || skus="ERROR"
  if [[ "$skus" == "ERROR" ]]; then
    fail "could not list PostgreSQL SKUs in $LOCATION — is Microsoft.DBforPostgreSQL registered?"
  else
    pass "PostgreSQL Flexible Server is offered in $LOCATION (region capability, NOT your subscription's entitlement to provision here)"
    if [[ "$MODE" == "production" ]]; then
      if echo "$skus" | grep -q 'Standard_D2ds_v5'; then
        pass "Standard_D2ds_v5 (GP_Standard_D2ds_v5) is offered here"
      else
        warn "Standard_D2ds_v5 not listed in $LOCATION — pick another GP_*/MO_* SKU"
      fi
    fi
  fi

  # FILE THE TICKET; do not go looking for the number first. Microsoft.Quota — which backs
  # 'az quota' and the portal Quotas blade — does not cover Microsoft.DBforPostgreSQL, and
  # Microsoft documents how to REQUEST this quota but never how to READ it. The ticket is
  # the read path, and on a fresh subscription a limit of 0 is common.
  manual "PostgreSQL vCore quota in $LOCATION — FILE THIS ON DAY ZERO. It is the only
          lead-time item here: Microsoft processes these in 24 to 48 hours, and everything
          else in the install sequence is minutes-to-hours work.
            Portal > Help + support > New support request
            Issue type   Service and subscription limits (quotas)
            Quota type   Azure Database for PostgreSQL flexible server
            Details      Location $LOCATION / Series Ddsv5 / New Quota 4
          FOUR, not two: GP_Standard_D2ds_v5 is a 2-vCore SKU and production forces a
          zone-redundant standby that Azure provisions and maintains as real compute.
          It is FREE — quota adjustment is subscription management, supported on every plan
          including one with no paid support, so nothing blocks filing it immediately.
          Do not hunt for your current limit first: Azure publishes no read path for this
          provider, so the ticket IS the read path."
  if [[ "$MODE" == "production" ]]; then
    manual "Zone-redundant HA availability in $LOCATION. Production forces
            postgres_zone_redundant_ha = true on the starter server, and Azure offers it only
            in availability-zone regions. There is nothing to pre-file: check the regions
            table below, and if the region is marked as temporarily blocked for new
            zone-redundant deployments the documented remedy is a DIFFERENT REGION, not a
            form. Sweden Central is listed as available with no block marker, but that table
            is edited without notice — re-read it the morning you commit to a region.
            https://learn.microsoft.com/azure/postgresql/overview#azure-regions"
  fi
fi

# --- 4. Container Apps. Environment-scoped quota does not exist until the environment does.

head2 "Container Apps"
if [[ "$MODE" == "production" ]]; then
  echo "  peak request: 3.0 vCPU / 6 GiB at api_max_replicas=2 (3.5 / 7 at 3)"
else
  echo "  peak request: 2.0 vCPU / 4 GiB"
fi
# TWO quotas, with different scopes, different mechanisms and different lead times. They were
# previously one note, which made the second look filable on day zero when it is not.
manual "Container Apps quota — TWO separate quotas, only one of which you can settle now.
          1. 'Managed Environment Count' — REGION-scoped, INTEGRATED request, minutes.
             Portal Quotas blade, provider 'Azure Container Apps', region $LOCATION.
             Confirm the limit is at least 1. Do this on day zero; it is approved in minutes.
          2. 'Managed Environment Consumption Cores' — ENVIRONMENT-scoped, MANUAL request.
             It CANNOT be requested before your first apply, because it is scoped to the
             managed environment that apply creates. Read it immediately afterwards:
               az containerapp env list-usages -g rg-${NAME_PREFIX}-aca -n aca-${NAME_PREFIX} -o table
             A manual request always opens a support ticket; Microsoft's own wording is that
             approval is often automated but some requests take up to a few days. Ask for
             DOUBLE the peak above, because Container Apps starts a new revision's replicas
             before retiring the old ones and a deploy transiently needs close to twice.
        Your first apply should succeed even against a tight ceiling: the quota counts ACTIVE
        replicas, and the install starts at its minimums, not at the configured maximum. The
        ceiling bites later — at scale-out or on a deploy — where 'Maximum Allowed Cores
        exceeded for the Managed Environment' reads as a regression rather than as quota."

# --- 5. Redis. Not an entitlement question any more (ADR 0071) — a regional capacity one.
#
# Before ADR 0071 this check existed to warn that production required an Azure Cache for Redis
# instance a new customer could no longer create. redis_offering = "managed" removes that
# blocker: Azure Managed Redis is creatable by any tenant. What CAN still stop an apply is that
# the chosen Azure Managed Redis SKU has no capacity in the target region, so that is what we
# look at now. The resource provider is unchanged (Microsoft.Cache), so check 1 already covers
# the registration.

if [[ "$MODE" == "production" ]]; then
  head2 "Redis (Azure Managed Redis)"
  amr_skus="ERROR"
  # Azure Managed Redis is Microsoft.Cache/redisEnterprise. Ask the provider what it will
  # actually accept in THIS region rather than trusting a published availability table.
  amr_skus=$(az provider show --namespace Microsoft.Cache --subscription "$SUBSCRIPTION" \
    --query "resourceTypes[?resourceType=='redisEnterprise'].locations[]" -o tsv 2>/dev/null) \
    || amr_skus="ERROR"
  if [[ "$amr_skus" == "ERROR" ]]; then
    warn "could not read Microsoft.Cache/redisEnterprise locations"
  elif [[ -z "$amr_skus" ]]; then
    warn "Microsoft.Cache reports no locations for redisEnterprise (is the provider registered?)"
  else
    # az reports display names ("Sweden Central"); LOCATION is the short form. Compare
    # case-insensitively with spaces stripped.
    want=$(printf '%s' "$LOCATION" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    have=$(printf '%s' "$amr_skus" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    if printf '%s\n' "$have" | grep -qx "$want"; then
      pass "Azure Managed Redis (redisEnterprise) is offered in $LOCATION (region capability, not entitlement)"
    else
      warn "could not confirm redisEnterprise in $LOCATION from the provider's location list"
    fi
  fi
  manual "Azure Managed Redis capacity. mode=production requires enable_redis, and
          redis_offering = \"managed\" is the choice that works for every tenant: Microsoft
          blocked creation of Basic/Standard/Premium Azure Cache for Redis for NEW customers
          on 1 April 2026 (tenant-wide qualification, no self-service exception) and retires
          them on 30 September 2028. What the module cannot check for you is whether the
          chosen SKU has live capacity in your region — Azure returns an allocation failure
          per region and SKU independently of published availability. If your first apply
          fails on capacity, try a different Balanced size or a neighbouring region.
          Set redis_offering = \"cache\" ONLY if you already run an Azure Cache for Redis
          instance you intend to keep.
          https://learn.microsoft.com/azure/redis/overview"
fi

# --- Summary. MANUAL prints last, on purpose.

printf '\n========================================\n'
printf 'Automated checks: %s failed, %s warned.\n' "$FAILURES" "$WARNINGS"
if [[ ${#MANUAL_NOTES[@]} -gt 0 ]]; then
  printf '\nCONFIRM THESE YOURSELF — this script cannot:\n'
  # Re-indent: the notes are written as indented multi-line strings in the source, so
  # normalise the continuation lines rather than reproducing the source's indentation.
  for note in "${MANUAL_NOTES[@]}"; do
    printf '\n'
    # Prefix continuation lines instead of re-indenting them. The earlier form normalised every
    # line to one column, which put "1." and "2." level with their own sub-lines and flattened
    # the one distinction that matters in the Container Apps note: region-scoped and requestable
    # now, versus environment-scoped and impossible until after apply 1.
    printf '%s\n' "$note" | sed -e '1s/^[[:space:]]*/  * /' -e '2,$s/^/    /'
  done
fi
printf '\n'
if [[ "$FAILURES" -ne 0 ]]; then
  echo "Preflight FAILED. Fix the items above before terraform init."
  exit 1
fi
echo "Automated preflight passed. The manual items above are still yours."
