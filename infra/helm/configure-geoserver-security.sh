#!/usr/bin/env bash
#
# Wires GeoServer Cloud's sec-username/sec-roles pre-authentication header
# into its own security filter chains, so an OIDC login actually shows up as
# a logged-in principal in the GeoServer UI instead of silently staying
# anonymous.
#
# WHY THIS EXISTS
# ----------------
# The "environment-admin-auth" and "gateway-shared-auth" Spring Cloud
# extensions this chart enables (visible in every service's boot log as
# active profiles) only provide the *capability* for header-based
# pre-authentication - they do not wire a header-reading filter into
# GeoServer's own security configuration. That wiring lives entirely in
# GeoServer's own security/config.xml, and a freshly initialized catalog
# starts with no such filter at all. Without it, the sec-username header
# the Node OIDC proxy and gateway inject arrives at every backend correctly
# (verified empirically: curling a backend directly with the header set
# renders an empty logged-in-user slot in the page, exactly where the
# username/logout link belongs) but nothing ever reads it, so every request
# is treated as anonymous no matter how well the OIDC login itself works.
#
# This is a straight port of the Azure deployment's
# infra/scripts/configure-geoserver-security.sh (invoked there by a
# Terraform null_resource after every apply), with the Azure-only mechanics
# replaced by OpenShift-native equivalents:
#   - No SOCKS5/Bastion tunnel: this script `oc exec`s into an already
#     running gateway pod and talks to GeoServer over that pod's own
#     loopback (http://localhost:8080) - the same network path the OIDC
#     proxy itself uses, so no port-forward or extra network plumbing is
#     needed.
#   - No Azure Key Vault: the admin password is read directly from the
#     <geoserver-release>-runtime Secret this chart already creates
#     (helm.sh/resource-policy: keep, so it survives upgrades).
#   - No Container Apps restart step: the Azure script's machine-client
#     authkey step (its step 6) needs a hard pod restart because per-user
#     DATA changes are cached per-pod and never broadcast. This script only
#     ports the Azure script's steps 1-4 (service-level FILTER/CHAIN
#     config), which GeoServer Cloud's own event bus DOES broadcast to every
#     pod on /rest/reload - no restart required. Machine-client
#     authentication on this deployment is handled by a separate,
#     purpose-built mechanism (see the machine-client-authentication and
#     machine-to-machine-auth-api work) and is intentionally not touched by
#     this script.
#
# WHAT IT DOES (idempotent - safe to run after every deploy, and safe to
# re-run standalone at any time)
#   1. Removes any broken JDBC role/user-group security service files left
#      over from an earlier attempt or manual experiment. GeoServer Cloud
#      3.0's JDBC security config classes fail to load
#      (ClassCastException) and can crash the Security admin page if these
#      exist, so this step deletes them if present (a 404 on a file that
#      was never created is treated as success).
#   2. Creates or updates a "headerAuth" pre-authentication filter that
#      reads the sec-username / sec-roles headers.
#   3. Wires that filter into the web, default, gwc, and rest security
#      filter chains (the rest chain matters so an OIDC-authenticated
#      browser session can use REST-backed admin pages without being
#      prompted for basic-auth credentials); a chain that already has the
#      filter is left untouched.
#   4. Optionally bootstraps one admin principal with ROLE_ADMINISTRATOR
#      (skipped entirely if --admin-principal is not given - the built-in
#      'admin' user this script already authenticates as can always assign
#      the role by hand in the Security UI afterwards).
#   5. Verifies the result by reading the same REST endpoints back.
#
# A NOTE ON HOW HTTP STATUS CODES ARE CAPTURED
# ---------------------------------------------
# Every REST call below needs just the numeric HTTP status, discarding the
# response body (`curl -o /dev/null -w '%{http_code}'`). On this cluster, an
# `oc exec`'d curl consistently exits non-zero (observed: 23, "failed writing
# received data") when writing that discarded body to /dev/null, even though
# the request itself succeeded and -w's status text was already written to
# curl's stdout. Two consequences follow, and both are handled by the
# gs_curl_status/gs_curl_data_status/gs_curl_json_status helpers below rather
# than at each call site:
#   - The classic `code="$(cmd)" || echo 000` idiom (used by the Azure
#     script this was ported from, where curl's exit code is trustworthy)
#     silently DUPLICATES output here: bash keeps whatever `cmd` already
#     wrote to the command substitution's stdout (e.g. "200") and then ALSO
#     appends the `|| echo 000` fallback's "000", yielding the nonsensical
#     "200000". The helpers below use `|| true` (which adds nothing to
#     stdout) instead, and only fall back to "000" via parameter expansion
#     when the command substitution captured nothing at all.
#   - Any *bare* (uncaptured) call to `-o /dev/null`-using curl, run without
#     an `||` guard, would trip this script's own `set -e` the moment curl
#     exits 23 - even though the operation it was reporting on succeeded.
#     Every such call below goes through a helper (or ends in `|| true`) for
#     exactly this reason.
#
# Usage:
#   configure-geoserver-security.sh --namespace NAME [options]
#
# Called automatically by deploy-geoserver-cloud.sh after a successful
# GeoServer install/upgrade (skippable with that script's
# --skip-security-config flag); also safe to run standalone, e.g. against an
# environment that predates this step, or to pick up a newly set
# --admin-principal without a full redeploy.

set -Eeuo pipefail
IFS=$'\n\t'

NAMESPACE="${OPENSHIFT_NAMESPACE:-}"
GEOSERVER_RELEASE="${GEOSERVER_RELEASE_NAME:-geoserver-cloud}"
RUNTIME_SECRET_NAME="${GEOSERVER_RUNTIME_SECRET_NAME:-}"
BASE_PATH="${GEOSERVER_SECURITY_BASE_PATH:-/geoserver/cloud}"
ADMIN_PRINCIPAL="${GEOSERVER_SECURITY_ADMIN_PRINCIPAL:-}"
ROLE_SERVICE="${GEOSERVER_SECURITY_ROLE_SERVICE:-default}"
UG_SERVICE="${GEOSERVER_SECURITY_USERGROUP_SERVICE:-default}"
OC="${OC:-oc}"

usage() {
  cat <<'USAGE'
Usage: configure-geoserver-security.sh --namespace NAME [options]

Wires GeoServer Cloud's sec-username/sec-roles pre-authentication header into
its web/default/gwc/rest security filter chains, so an OIDC login actually
appears as a logged-in principal in the UI. Idempotent - safe to run after
every deploy (deploy-geoserver-cloud.sh does this automatically) and safe to
re-run standalone at any time, e.g. against an environment that predates
this step.

Required:
  --namespace NAME             OpenShift namespace running the release
                                (or set OPENSHIFT_NAMESPACE)

Options:
  --geoserver-release NAME     GeoServer Helm release name
                                (default: geoserver-cloud)
  --runtime-secret-name NAME   Secret holding geoserver-admin-username and
                                geoserver-admin-password (default:
                                <geoserver-release>-runtime; must match
                                secrets.runtime.name in values.yaml if you
                                have customized it)
  --base-path PATH             Gateway base path GeoServer is served under
                                (default: /geoserver/cloud; must match
                                proxy.geoserver.basePath in your values file)
  --admin-principal EMAIL      If set, bootstraps this principal with
                                ROLE_ADMINISTRATOR in the role and user/group
                                services (default: unset, step skipped)
  --role-service NAME          GeoServer role service name (default: default)
  --usergroup-service NAME     GeoServer user/group service name
                                (default: default)
  -h, --help                   Show this help

Environment:
  OPENSHIFT_NAMESPACE, GEOSERVER_RELEASE_NAME, GEOSERVER_RUNTIME_SECRET_NAME,
  GEOSERVER_SECURITY_BASE_PATH, GEOSERVER_SECURITY_ADMIN_PRINCIPAL,
  GEOSERVER_SECURITY_ROLE_SERVICE, GEOSERVER_SECURITY_USERGROUP_SERVICE, OC

This script never opens a network path to GeoServer from outside the
cluster: every REST call runs via `oc exec` inside a running gateway pod,
talking to GeoServer over that pod's own loopback - the same path the OIDC
proxy itself uses. See the file header comment for the full rationale and
how this differs from the Azure deployment's equivalent script.
USAGE
}

log() {
  printf '[gs-security] %s\n' "$*"
}

die() {
  printf '[gs-security] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --namespace)
        [[ $# -ge 2 && "$2" != -* ]] || die "--namespace requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --geoserver-release)
        [[ $# -ge 2 && "$2" != -* ]] || die "--geoserver-release requires a value"
        GEOSERVER_RELEASE="$2"
        shift 2
        ;;
      --runtime-secret-name)
        [[ $# -ge 2 && "$2" != -* ]] || die "--runtime-secret-name requires a value"
        RUNTIME_SECRET_NAME="$2"
        shift 2
        ;;
      --base-path)
        [[ $# -ge 2 && "$2" != -* ]] || die "--base-path requires a value"
        BASE_PATH="$2"
        shift 2
        ;;
      --admin-principal)
        [[ $# -ge 2 && "$2" != -* ]] || die "--admin-principal requires a value"
        ADMIN_PRINCIPAL="$2"
        shift 2
        ;;
      --role-service)
        [[ $# -ge 2 && "$2" != -* ]] || die "--role-service requires a value"
        ROLE_SERVICE="$2"
        shift 2
        ;;
      --usergroup-service)
        [[ $# -ge 2 && "$2" != -* ]] || die "--usergroup-service requires a value"
        UG_SERVICE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

GATEWAY_POD=""
ADMIN_USER=""
ADMIN_PASS=""
GS=""
TEMP_FILES=()

cleanup() {
  local f
  if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
    for f in "${TEMP_FILES[@]}"; do
      rm -f "$f"
    done
  fi
}

# Creates a temp file and registers it in TEMP_FILES for cleanup. Sets the
# global NEW_TEMP_FILE rather than "returning" the path via stdout: calling
# this as `x="$(new_temp_file)"` would run the whole function in a subshell
# (command substitutions always fork one), silently discarding its
# TEMP_FILES append the moment the subshell exits - the array would stay
# empty for the rest of the script no matter how many temp files were
# created. Caught by testing this script against a live cluster: with
# TEMP_FILES empty, cleanup()'s loop degenerated into iterating one empty
# string, an unguarded `[[ ... ]] && rm` failed on it, and because that
# happened inside the EXIT trap itself, set -e let that failure silently
# overwrite the script's real (successful) exit code with 1.
NEW_TEMP_FILE=""
new_temp_file() {
  NEW_TEMP_FILE="$(mktemp)"
  TEMP_FILES+=("$NEW_TEMP_FILE")
}

find_gateway_pod() {
  local pod
  pod="$("$OC" get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=gateway,app.kubernetes.io/instance=${GEOSERVER_RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || die "No running gateway pod found for release '${GEOSERVER_RELEASE}' in namespace '${NAMESPACE}' (label app.kubernetes.io/component=gateway). Is the release deployed and healthy?"
  GATEWAY_POD="$pod"
  log "Using gateway pod: ${GATEWAY_POD}"
}

load_admin_credentials() {
  local secret="${RUNTIME_SECRET_NAME:-${GEOSERVER_RELEASE}-runtime}"
  ADMIN_USER="$("$OC" get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.geoserver-admin-username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  ADMIN_PASS="$("$OC" get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.geoserver-admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] || die "Could not read geoserver-admin-username/geoserver-admin-password from Secret '${secret}' in namespace '${NAMESPACE}'. Pass --runtime-secret-name if secrets.runtime.name differs from the default."
}

# Runs curl inside the gateway pod against its own loopback (the same
# network path the OIDC proxy uses), so no port-forward or tunnel is needed.
gs_curl() {
  "$OC" exec -n "$NAMESPACE" "$GATEWAY_POD" -- curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "$@"
}

# Same, but pipes a local file in as the request body via stdin (`oc exec -i`)
# rather than trying to first get an arbitrary local payload onto the pod's
# own filesystem.
gs_curl_data() {
  local file="$1"
  shift
  "$OC" exec -i -n "$NAMESPACE" "$GATEWAY_POD" -- curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" --data-binary @- "$@" < "$file"
}

# Returns just the HTTP status code of a gs_curl call via stdout. See the
# file header comment ("A NOTE ON HOW HTTP STATUS CODES ARE CAPTURED") for
# why this can't be the simpler `code="$(cmd)" || echo 000` idiom.
gs_curl_status() {
  local raw
  raw="$(gs_curl -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)" || true
  raw="${raw:-000}"
  printf '%s' "${raw:0:3}"
}

# Same, for a gs_curl_data (file-body) call.
gs_curl_data_status() {
  local file="$1"
  shift
  local raw
  raw="$(gs_curl_data "$file" -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)" || true
  raw="${raw:-000}"
  printf '%s' "${raw:0:3}"
}

# Same, for an inline JSON body via -d (used by the admin-bootstrap step).
gs_curl_json_status() {
  local payload="$1"
  shift
  local raw
  raw="$(gs_curl -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" -d "$payload" "$@" 2>/dev/null)" || true
  raw="${raw:-000}"
  printf '%s' "${raw:0:3}"
}

# POSTs /rest/reload and logs the resulting status; never fatal (a reload
# call that reports something other than 2xx is worth a warning, but should
# not abort a script that has otherwise already applied real config).
reload_geoserver() {
  local code
  code="$(gs_curl_status -X POST "${GS}/rest/reload")"
  log "  reload -> HTTP ${code}"
}

wait_for_geoserver_rest() {
  local attempt status
  log "Waiting for GeoServer REST API at ${GS}/rest/about/version.json"
  for attempt in $(seq 1 20); do
    status="$(gs_curl_status "${GS}/rest/about/version.json")"
    if [[ "$status" == "200" ]]; then
      log "GeoServer REST API is up (attempt ${attempt})"
      return 0
    fi
    log "  attempt ${attempt}/20 -> HTTP ${status}, retrying in 5s..."
    sleep 5
  done
  die "Timed out waiting for GeoServer REST API at ${GS}/rest/about/version.json"
}

# Removes broken JDBC role/user-group security service files, if present.
# GeoServer Cloud 3.0's JDBC security config classes fail to load
# (ClassCastException) and can crash the Security admin page if these exist.
# A 404 on a file that was never created is the expected, successful case.
remove_broken_jdbc_security_services() {
  local path code
  log "Removing broken JDBC security service files (if present)..."
  for path in \
    security/role/jdbc/config.xml security/role/jdbc/rolesddl.xml security/role/jdbc/rolesdml.xml \
    security/usergroup/idir/config.xml security/usergroup/idir/usersdddl.xml security/usergroup/idir/usersdml.xml
  do
    code="$(gs_curl_status -X DELETE "${GS}/rest/resource/${path}")"
    case "$code" in
      2*|404) log "  ${path}: ${code}" ;;
      *) log "  WARNING: DELETE ${path} returned ${code} (non-fatal)" ;;
    esac
  done
  log "Reloading GeoServer after cleanup..."
  reload_geoserver
}

# Creates or updates the headerAuth pre-authentication filter that reads
# sec-username/sec-roles. roleSource=Header: the proxy injects sec-roles
# directly (ROLE_ADMINISTRATOR for every authenticated session today), so
# GeoServer does not need a role-service lookup per request.
configure_header_auth_filter() {
  local filter_file method url verb code
  new_temp_file
  filter_file="$NEW_TEMP_FILE"
  cat > "$filter_file" <<FILTER
<org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
  <name>headerAuth</name>
  <className>org.geoserver.security.filter.GeoServerRequestHeaderAuthenticationFilter</className>
  <roleServiceName>${ROLE_SERVICE}</roleServiceName>
  <principalHeaderAttribute>sec-username</principalHeaderAttribute>
  <rolesHeaderAttribute>sec-roles</rolesHeaderAttribute>
  <roleSource class="org.geoserver.security.config.PreAuthenticatedUserNameFilterConfig\$PreAuthenticatedUserNameRoleSource">Header</roleSource>
</org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
FILTER

  log "Configuring headerAuth filter (roleSource=Header, rolesHeaderAttribute=sec-roles)..."
  if gs_curl "${GS}/rest/security/authfilters.xml" | grep -q "<name>headerAuth</name>"; then
    method="PUT"; url="${GS}/rest/security/authfilters/headerAuth"; verb="update"
  else
    method="POST"; url="${GS}/rest/security/authfilters"; verb="create"
  fi
  code="$(gs_curl_data_status "$filter_file" -X "$method" -H "Content-Type: application/xml" "$url")"
  log "  headerAuth ${verb} -> HTTP ${code}"
  case "$code" in
    2*) : ;;
    *) die "headerAuth ${verb} failed with HTTP ${code}" ;;
  esac
}

# Wires headerAuth into the web/default/gwc/rest filter chains. The rest
# chain must be included so OIDC-authenticated browser sessions can use
# REST-backed admin pages without being prompted for basic-auth credentials.
wire_header_auth_into_chains() {
  local config_file before after changed=0 chain code

  chain_has_filter() {
    sed -n "/<filters name=\"$1\"[^>]*>/,/<\/filters>/p" "$config_file" 2>/dev/null | grep -q "<filter>$2</filter>"
  }

  new_temp_file
  config_file="$NEW_TEMP_FILE"
  # Must be a local shell redirection, not curl's own -o: gs_curl runs curl
  # INSIDE the gateway pod via `oc exec`, so an -o argument would tell that
  # remote curl to write to $config_file's path on the *pod's* filesystem,
  # not back on this machine. Shell `>` instead captures oc exec's own
  # stdout, which is exactly the remote process's stdout forwarded here.
  gs_curl "${GS}/rest/resource/security/config.xml" > "$config_file"

  log "Wiring headerAuth into filter chains..."
  for chain in web default gwc rest; do
    if chain_has_filter "$chain" "headerAuth"; then
      log "  headerAuth already in ${chain} chain — skipping."
      continue
    fi
    before="$(wc -c < "$config_file")"
    sed -zi "s|<filters name=\"${chain}\" \([^>]*\)>|<filters name=\"${chain}\" \1><filter>headerAuth</filter>|" "$config_file"
    after="$(wc -c < "$config_file")"
    if [[ "$after" -gt "$before" ]]; then
      log "  Injected headerAuth into ${chain} chain."
      changed=$((changed + 1))
    else
      log "  WARNING: ${chain} chain not found in config.xml — skipping (non-fatal)."
    fi
  done

  if [[ "$changed" -gt 0 ]]; then
    code="$(gs_curl_data_status "$config_file" -X PUT -H "Content-Type: application/xml" "${GS}/rest/resource/security/config.xml")"
    log "  config.xml chains -> HTTP ${code}"
  else
    log "  All chains already configured — no upload needed."
  fi
  log "Reloading GeoServer configuration..."
  reload_geoserver
}

# Best-effort: ensures ADMIN_PRINCIPAL exists in the user/group service and
# holds ROLE_ADMINISTRATOR, which GeoServer's interceptors use for the admin
# bypass check. Skipped entirely if ADMIN_PRINCIPAL is unset - the built-in
# 'admin' user this script already authenticates as can always assign the
# role by hand in the Security UI afterwards.
bootstrap_admin_principal() {
  if [[ -z "$ADMIN_PRINCIPAL" ]]; then
    log "No --admin-principal set — skipping super-admin bootstrap."
    return 0
  fi
  log "Bootstrapping super admin: ${ADMIN_PRINCIPAL}"
  local rand_pw uc ensure_code rc
  rand_pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  uc="$(gs_curl_json_status \
    "{\"user\":{\"userName\":\"${ADMIN_PRINCIPAL}\",\"password\":\"${rand_pw}\",\"enabled\":true}}" \
    -X POST "${GS}/rest/security/usergroup/service/${UG_SERVICE}/users")"
  case "$uc" in
    2*) log "  admin user created (${uc})" ;;
    409|500) log "  admin user already exists (${uc})" ;;
    *) log "  WARNING: create admin user returned ${uc} (non-fatal)" ;;
  esac
  ensure_code="$(gs_curl_status -X POST "${GS}/rest/security/roles/role/ROLE_ADMINISTRATOR")"
  case "$ensure_code" in
    2*) log "  ROLE_ADMINISTRATOR created (${ensure_code})" ;;
    400|409|500) log "  ROLE_ADMINISTRATOR already exists (${ensure_code})" ;;
    *) log "  WARNING: ensure ROLE_ADMINISTRATOR returned ${ensure_code} (non-fatal)" ;;
  esac
  rc="$(gs_curl_status -X POST "${GS}/rest/security/roles/role/ROLE_ADMINISTRATOR/user/${ADMIN_PRINCIPAL}")"
  case "$rc" in
    2*) log "  associated ROLE_ADMINISTRATOR with ${ADMIN_PRINCIPAL} (${rc})" ;;
    *) log "  WARNING: could not associate ROLE_ADMINISTRATOR role (${rc}). Assign it by hand in the Security UI as 'admin'." ;;
  esac
  reload_geoserver
}

verify_configuration() {
  local fail=0
  log "Verifying..."
  check() {
    if gs_curl "${GS}${1}" | grep -q "$2"; then
      log "  OK   $3"
    else
      log "  FAIL $3"
      fail=1
    fi
  }
  check "/rest/security/authfilters.xml" "headerAuth" "headerAuth filter present"
  check "/rest/security/authfilters/headerAuth.xml" "<rolesHeaderAttribute>sec-roles</rolesHeaderAttribute>" "headerAuth roleSource=Header with sec-roles attribute"
  check "/rest/resource/security/config.xml" "headerAuth" "headerAuth wired into chains"
  if gs_curl "${GS}/rest/resource/security/role/jdbc/config.xml" 2>/dev/null | grep -q "JDBCRoleService"; then
    log "  FAIL broken JDBC role service still present"
    fail=1
  else
    log "  OK   broken JDBC role service absent"
  fi
  [[ "$fail" == 0 ]] || die "Security verification failed"
  log "GeoServer security configuration complete."
}

main() {
  parse_args "$@"
  trap cleanup EXIT

  require_command "$OC"
  require_command sed
  require_command base64
  require_command openssl
  [[ -n "$NAMESPACE" ]] || die "Namespace is required: pass --namespace NAME or set OPENSHIFT_NAMESPACE"

  GS="http://localhost:8080${BASE_PATH}"

  find_gateway_pod
  load_admin_credentials
  wait_for_geoserver_rest
  remove_broken_jdbc_security_services
  configure_header_auth_filter
  wire_header_auth_into_chains
  bootstrap_admin_principal
  verify_configuration
}

main "$@"
