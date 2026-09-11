#!/usr/bin/env bash
#
# Example:
#   OIDC_CLIENT_SECRET="$oidc_secret" ./deploy-geoserver-cloud.sh \
#     --namespace geoserver-dev --environment dev --crunchy-release crunchy-postgres
#
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRUNCHY_CHART="${SCRIPT_DIR}/crunchy-postgres"
GEOSERVER_CHART="${SCRIPT_DIR}/geoserver-cloud"
SECURITY_SCRIPT="${SCRIPT_DIR}/configure-geoserver-security.sh"

NAMESPACE="${OPENSHIFT_NAMESPACE:-}"
ENVIRONMENT="${GEOSERVER_ENVIRONMENT:-dev}"
CRUNCHY_RELEASE="${CRUNCHY_RELEASE_NAME:-crunchy-postgres}"
GEOSERVER_RELEASE="${GEOSERVER_RELEASE_NAME:-geoserver-cloud}"
CRUNCHY_USER="${CRUNCHY_USER_NAME:-geoserverproxy}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"
POLL_SECONDS="${POLL_SECONDS:-10}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-30}"
OC="${OC:-oc}"
CREATE_NAMESPACE="false"
OIDC_CLIENT_SECRET_VALUE="${OIDC_CLIENT_SECRET:-}"
EXPECTED_OC_SERVER="${EXPECTED_OC_SERVER:-}"
DRY_RUN="${DRY_RUN:-false}"
DEBUG_HELM="${DEBUG_HELM:-false}"
SKIP_SECURITY_CONFIG="${SKIP_SECURITY_CONFIG:-false}"
GEOSERVER_ADMIN_PRINCIPAL="${GEOSERVER_SECURITY_ADMIN_PRINCIPAL:-}"
SECURITY_BASE_PATH="${GEOSERVER_SECURITY_BASE_PATH:-/geoserver/cloud}"

# Mutable state used by traps and helper functions; pre-declared so `set -u`
# never trips on them before they are assigned.
LOCK_DIR=""
OIDC_TEMP_VALUES_FILE=""
LAST_CHECK_DETAIL=""
CURRENT_STEP="startup"
SCRIPT_START_SECONDS=$SECONDS

usage() {
  cat <<'USAGE'
Usage: deploy-geoserver-cloud.sh [options]

Deploy the Crunchy Postgres Helm release, wait for its operator-created Secret
and pgBouncer Service, then deploy the GeoServer Cloud Helm release.

Options:
  --namespace NAME          OpenShift namespace (required; or set OPENSHIFT_NAMESPACE)
  --environment NAME        values/values-NAME.yaml profile (default: dev)
  --crunchy-release NAME    Crunchy Helm release and cluster name (default: crunchy-postgres)
  --geoserver-release NAME  GeoServer Helm release (default: geoserver-cloud)
  --crunchy-user NAME       Crunchy generated user name; must match the least-privilege
                            application user in crunchy-postgres's users list, not the
                            postgres superuser (default: geoserverproxy)
  --helm-timeout DURATION   Helm wait timeout (default: 20m)
  --wait-seconds SECONDS    Total readiness budget shared across all three Crunchy
                            readiness checks combined, polled every POLL_SECONDS
                            (default: 1800; poll interval default: 10, set via
                            POLL_SECONDS)
  --create-namespace        Allow Helm to create the namespace
  --expected-server URL     Fail unless `oc whoami --show-server` equals this URL; guards
                            against deploying to the wrong cluster context (default:
                            unset/no check; or set EXPECTED_OC_SERVER)
  --dry-run                 Run both Helm installs with --dry-run and skip readiness
                            waits and namespace/release mutation (default: false; or
                            set DRY_RUN=true)
  --debug                   Log the resolved Helm command lines and pass --debug to
                            Helm (default: false; or set DEBUG_HELM=true)
  --skip-security-config    Skip the post-deploy GeoServer security configuration
                            step (default: false; or set SKIP_SECURITY_CONFIG=true)
  --admin-principal EMAIL   Bootstrap this principal with ROLE_ADMINISTRATOR during
                            the security configuration step (default: unset, step
                            skipped; or set GEOSERVER_SECURITY_ADMIN_PRINCIPAL)
  --security-base-path PATH  Gateway base path passed to the security configuration
                            step; must match proxy.geoserver.basePath in your values
                            file (default: /geoserver/cloud; or set
                            GEOSERVER_SECURITY_BASE_PATH)
  -h, --help                Show this help

Environment:
  OPENSHIFT_NAMESPACE, GEOSERVER_ENVIRONMENT, CRUNCHY_RELEASE_NAME,
  GEOSERVER_RELEASE_NAME, CRUNCHY_USER_NAME, HELM_TIMEOUT, WAIT_SECONDS,
  POLL_SECONDS, HEARTBEAT_SECONDS, OIDC_CLIENT_SECRET, EXPECTED_OC_SERVER,
  DRY_RUN, DEBUG_HELM, SKIP_SECURITY_CONFIG, GEOSERVER_SECURITY_ADMIN_PRINCIPAL,
  GEOSERVER_SECURITY_BASE_PATH

After a successful GeoServer install/upgrade, this script automatically runs
configure-geoserver-security.sh (skipped in --dry-run, or with
--skip-security-config) to wire GeoServer's sec-username/sec-roles pre-auth
header into its own security filter chains - without this step, GeoServer
never reads that header at all and every OIDC login is silently treated as
anonymous. It is idempotent, safe to re-run on its own at any time (see that
script's own --help), and a failure there is logged as a warning rather than
failing this script, since the application deployment itself already
succeeded by that point.

The OIDC client secret is accepted only via the OIDC_CLIENT_SECRET environment
variable (there is no --oidc-client-secret CLI flag) so it never appears in
this script's own argv and is therefore not visible via `ps`/`/proc/<pid>/cmdline`
for the life of the process; an env var is still readable for that process via
`/proc/<pid>/environ` by the same user or root on a shared node, same as any
other env-var secret. It is written to a temporary, mode-600 Helm values file
for the duration of the GeoServer install and removed on exit, and is never
passed as a --set/--set-string argument to Helm. Existing runtime Secret data
is preserved by the GeoServer chart on later upgrades. Both Helm releases
install with --atomic (skipped in --dry-run), so a failed install or upgrade
is rolled back automatically instead of leaving a half-applied release
running in the namespace.
USAGE
}

now_utc() {
  date -u +%FT%TZ
}

log() {
  local IFS=' '
  printf '[deploy][%s] %s\n' "$(now_utc)" "$*"
}

die() {
  local IFS=' '
  printf '[deploy][%s] ERROR: %s\n' "$(now_utc)" "$*" >&2
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
      --environment)
        [[ $# -ge 2 && "$2" != -* ]] || die "--environment requires a value"
        ENVIRONMENT="$2"
        shift 2
        ;;
      --crunchy-release)
        [[ $# -ge 2 && "$2" != -* ]] || die "--crunchy-release requires a value"
        CRUNCHY_RELEASE="$2"
        shift 2
        ;;
      --geoserver-release)
        [[ $# -ge 2 && "$2" != -* ]] || die "--geoserver-release requires a value"
        GEOSERVER_RELEASE="$2"
        shift 2
        ;;
      --crunchy-user)
        [[ $# -ge 2 && "$2" != -* ]] || die "--crunchy-user requires a value"
        CRUNCHY_USER="$2"
        shift 2
        ;;
      --helm-timeout)
        [[ $# -ge 2 && "$2" != -* ]] || die "--helm-timeout requires a value"
        HELM_TIMEOUT="$2"
        shift 2
        ;;
      --wait-seconds)
        [[ $# -ge 2 && "$2" != -* ]] || die "--wait-seconds requires a value"
        WAIT_SECONDS="$2"
        shift 2
        ;;
      --create-namespace)
        CREATE_NAMESPACE="true"
        shift
        ;;
      --oidc-client-secret)
        die "--oidc-client-secret has been removed: it placed the secret in this script's own argv, visible via ps/process-listing for the life of the run. Set the OIDC_CLIENT_SECRET environment variable instead (see --help)."
        ;;
      --expected-server)
        [[ $# -ge 2 && "$2" != -* ]] || die "--expected-server requires a value"
        EXPECTED_OC_SERVER="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --debug)
        DEBUG_HELM="true"
        shift
        ;;
      --skip-security-config)
        SKIP_SECURITY_CONFIG="true"
        shift
        ;;
      --admin-principal)
        [[ $# -ge 2 && "$2" != -* ]] || die "--admin-principal requires a value"
        GEOSERVER_ADMIN_PRINCIPAL="$2"
        shift 2
        ;;
      --security-base-path)
        [[ $# -ge 2 && "$2" != -* ]] || die "--security-base-path requires a value"
        SECURITY_BASE_PATH="$2"
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

values_file() {
  local chart_root="$1"
  local file="${chart_root}/values/values-${ENVIRONMENT}.yaml"
  [[ -f "$file" ]] || die "Values file not found: $file"
  printf '%s' "$file"
}

# Writes the OIDC client secret to a mode-600 temporary Helm values file so it
# never appears as a --set/--set-string argument (visible to `ps`/`/proc` on a
# shared host) and is never subject to Helm's --set comma/backslash grammar.
# Uses a YAML literal block scalar (|-) rather than a quoted flow scalar: a
# block scalar's content is entirely literal, so quotes, backslashes, commas,
# leading '-', or embedded '#'/':' in the secret need no escaping at all.
write_oidc_values_file() {
  local secret="$1"
  [[ "$secret" != *$'\n'* ]] || die "OIDC_CLIENT_SECRET must not contain newline characters"
  OIDC_TEMP_VALUES_FILE="$(mktemp --suffix=.yaml "${TMPDIR:-/tmp}/geoserver-oidc-values.XXXXXX")"
  chmod 600 "$OIDC_TEMP_VALUES_FILE"
  {
    printf 'secrets:\n'
    printf '  runtime:\n'
    printf '    oidcClientSecret: |-\n'
    printf '      %s\n' "$secret"
  } >"$OIDC_TEMP_VALUES_FILE"
}

# Simple mkdir-based mutual exclusion (no flock dependency) so two concurrent
# invocations against the same namespace/release trio fail fast instead of
# racing Helm/oc directly. Stale locks left by a killed process are reclaimed.
acquire_lock() {
  local lock_dir="${TMPDIR:-/tmp}/deploy-geoserver-cloud.${NAMESPACE}.${CRUNCHY_RELEASE}.${GEOSERVER_RELEASE}.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    local stale_pid=""
    stale_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
    if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
      log "Removing stale deploy lock left by dead process ${stale_pid}: ${lock_dir}"
      rm -rf "$lock_dir"
    fi
    mkdir "$lock_dir" 2>/dev/null || die "Another deploy is already in progress for namespace '${NAMESPACE}' with releases '${CRUNCHY_RELEASE}'/'${GEOSERVER_RELEASE}' (lock: ${lock_dir}). Wait for it to finish, or remove the lock directory if you are certain no other instance is running."
  fi
  echo "$$" >"${lock_dir}/pid"
  LOCK_DIR="$lock_dir"
}

release_lock() {
  if [[ -n "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR"
    LOCK_DIR=""
  fi
}

# Fails fast, with an actionable message, when a prior interrupted run left
# the release in pending-install/pending-upgrade/pending-rollback rather than
# racing a plain `helm upgrade --install` against it.
guard_release_not_pending() {
  local release="$1"
  local status_output
  status_output="$(helm status "$release" -n "$NAMESPACE" 2>/dev/null || true)"
  case "$status_output" in
    *"STATUS: pending-install"*|*"STATUS: pending-upgrade"*|*"STATUS: pending-rollback"*)
      die "Helm release '${release}' in namespace '${NAMESPACE}' is stuck in a pending state, likely from a previous interrupted run. Inspect it with 'helm status ${release} -n ${NAMESPACE}' and resolve with 'helm rollback' or 'helm uninstall' before re-running this script."
      ;;
  esac
}

# Runs a Helm command, optionally logging the resolved argv and enabling
# Helm's own --debug output. The OIDC secret never appears in these argv
# arrays (see write_oidc_values_file), so there is nothing to redact here.
run_helm() {
  local -a args=("$@")
  if [[ "$DEBUG_HELM" == "true" ]]; then
    local IFS=' '
    args+=(--debug)
    log "DEBUG helm ${args[*]}"
  fi
  helm "${args[@]}"
}

on_interrupt() {
  local sig="$1"
  local code=130
  [[ "$sig" == "TERM" ]] && code=143
  log "Received SIG${sig}; aborting. If a Helm operation was in flight, check its state with: helm status <release> -n ${NAMESPACE}"
  exit "$code"
}

# Runs on every exit (success, die(), or a signal-triggered exit). Cleanup is
# unconditional; the structured failure block only prints on non-zero exit so
# an operator gets the same at-a-glance detail on failure as on success.
on_exit() {
  local exit_code=$?
  release_lock
  if [[ -n "$OIDC_TEMP_VALUES_FILE" ]]; then
    rm -f "$OIDC_TEMP_VALUES_FILE"
    OIDC_TEMP_VALUES_FILE=""
  fi
  if (( exit_code != 0 )); then
    local elapsed=$(( SECONDS - SCRIPT_START_SECONDS ))
    {
      printf '[deploy][%s] ERROR: Deployment FAILED after %ss at step: %s\n' "$(now_utc)" "$elapsed" "$CURRENT_STEP"
      printf '[deploy][%s] Namespace: %s | Crunchy release: %s | GeoServer release: %s\n' "$(now_utc)" "$NAMESPACE" "$CRUNCHY_RELEASE" "$GEOSERVER_RELEASE"
      printf '[deploy][%s] Triage: oc get events --sort-by=.lastTimestamp -n %s ; helm status %s -n %s ; helm status %s -n %s\n' \
        "$(now_utc)" "$NAMESPACE" "$CRUNCHY_RELEASE" "$NAMESPACE" "$GEOSERVER_RELEASE" "$NAMESPACE"
    } >&2
  fi
}

# deadline is an absolute $SECONDS value shared across every readiness check in
# the same wait group (see main()), so WAIT_SECONDS is a total budget for the
# whole group rather than a fresh allowance handed to each individual check.
wait_until() {
  local description="$1"
  local check_function="$2"
  local deadline="$3"
  local last_heartbeat=$SECONDS
  local remaining=$(( deadline - SECONDS ))

  LAST_CHECK_DETAIL=""
  log "Waiting for ${description} (${remaining}s left of shared ${WAIT_SECONDS}s readiness budget, polling every ${POLL_SECONDS}s)"
  while ! "$check_function"; do
    if (( SECONDS >= deadline )); then
      die "Timed out waiting for ${description}: shared ${WAIT_SECONDS}s readiness budget exhausted. Last status: ${LAST_CHECK_DETAIL:-no status captured}"
    fi
    if (( SECONDS - last_heartbeat >= HEARTBEAT_SECONDS )); then
      remaining=$(( deadline - SECONDS ))
      log "Still waiting for ${description} (${remaining}s left in shared budget): ${LAST_CHECK_DETAIL:-checking...}"
      last_heartbeat=$SECONDS
    fi
    sleep "$POLL_SECONDS"
  done
  log "Ready: ${description} (${LAST_CHECK_DETAIL:-ok})"
}

# Crunchy's PostgresCluster CRD never sets a status.conditions[type=Ready]
# entry (only PersistentVolumeResizing/Progressing/ProxyAvailable/Registered
# exist), so that check can never succeed. Compare each instance set's
# readyReplicas against its desired replicas instead - this covers the
# primary and every replica in the set, since Patroni elects the primary from
# among those same pods.
postgres_cluster_ready() {
  local IFS=' '
  local ready_out replicas_out
  if ! ready_out="$("$OC" get postgrescluster "$CRUNCHY_RELEASE" -n "$NAMESPACE" \
      -o jsonpath='{.status.instances[*].readyReplicas}' 2>&1)"; then
    LAST_CHECK_DETAIL="oc get postgrescluster failed: ${ready_out}"
    return 1
  fi
  if ! replicas_out="$("$OC" get postgrescluster "$CRUNCHY_RELEASE" -n "$NAMESPACE" \
      -o jsonpath='{.status.instances[*].replicas}' 2>&1)"; then
    LAST_CHECK_DETAIL="oc get postgrescluster failed: ${replicas_out}"
    return 1
  fi

  local -a ready_arr replicas_arr
  read -ra ready_arr <<<"$ready_out"
  read -ra replicas_arr <<<"$replicas_out"

  if [[ ${#replicas_arr[@]} -eq 0 ]]; then
    LAST_CHECK_DETAIL="PostgresCluster status.instances not populated yet"
    return 1
  fi
  if [[ ${#ready_arr[@]} -ne ${#replicas_arr[@]} ]]; then
    LAST_CHECK_DETAIL="PostgresCluster instance status readyReplicas/replicas count mismatch"
    return 1
  fi

  local i
  for i in "${!replicas_arr[@]}"; do
    if [[ "${replicas_arr[$i]}" -lt 1 ]] || [[ "${ready_arr[$i]:-0}" -ne "${replicas_arr[$i]}" ]]; then
      LAST_CHECK_DETAIL="instance set $((i + 1)): ${ready_arr[$i]:-0}/${replicas_arr[$i]} replicas ready"
      return 1
    fi
  done

  LAST_CHECK_DETAIL="all instance sets ready (${replicas_arr[*]} replicas)"
  return 0
}

postgres_secret_ready() {
  local IFS=' '
  local secret="${CRUNCHY_RELEASE}-pguser-${CRUNCHY_USER}"
  local key value
  local -a missing=()
  for key in dbname port user password; do
    if ! value="$("$OC" get secret "$secret" -n "$NAMESPACE" -o "jsonpath={.data.${key}}" 2>&1)"; then
      LAST_CHECK_DETAIL="oc get secret ${secret} failed: ${value}"
      return 1
    fi
    [[ -n "$value" ]] || missing+=("$key")
  done
  if (( ${#missing[@]} > 0 )); then
    LAST_CHECK_DETAIL="Secret ${secret} missing keys: ${missing[*]}"
    return 1
  fi
  LAST_CHECK_DETAIL="Secret ${secret} has all required keys"
  return 0
}

pgbouncer_service_ready() {
  local service="${CRUNCHY_RELEASE}-pgbouncer"
  local err addresses
  if ! err="$("$OC" get service "$service" -n "$NAMESPACE" 2>&1 1>/dev/null)"; then
    LAST_CHECK_DETAIL="oc get service ${service} failed: ${err}"
    return 1
  fi
  if ! addresses="$("$OC" get endpoints "$service" -n "$NAMESPACE" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>&1)"; then
    LAST_CHECK_DETAIL="oc get endpoints ${service} failed: ${addresses}"
    return 1
  fi
  if [[ -z "$addresses" ]]; then
    LAST_CHECK_DETAIL="Service ${service} has no ready endpoint addresses yet"
    return 1
  fi
  LAST_CHECK_DETAIL="endpoints: ${addresses}"
  return 0
}

# Wires GeoServer's sec-username/sec-roles pre-auth header into its security
# filter chains via configure-geoserver-security.sh; see that script's own
# header comment for the full rationale. Idempotent, so safe to run after
# every deploy. Deliberately non-fatal on failure: the application deployment
# itself already succeeded by the time this runs, and the step is easy to
# re-run standalone once the underlying issue is fixed.
configure_geoserver_security() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Skipping GeoServer security configuration"
    return 0
  fi
  if [[ "$SKIP_SECURITY_CONFIG" == "true" ]]; then
    log "Skipping GeoServer security configuration (--skip-security-config)"
    return 0
  fi

  log "Configuring GeoServer security (sec-username/sec-roles pre-auth filter)..."
  local -a security_args=(
    --namespace "$NAMESPACE"
    --geoserver-release "$GEOSERVER_RELEASE"
    --base-path "$SECURITY_BASE_PATH"
  )
  if [[ -n "$GEOSERVER_ADMIN_PRINCIPAL" ]]; then
    security_args+=(--admin-principal "$GEOSERVER_ADMIN_PRINCIPAL")
  fi
  if OC="$OC" "$SECURITY_SCRIPT" "${security_args[@]}"; then
    log "GeoServer security configuration complete."
  else
    log "WARNING: GeoServer security configuration failed; sec-username-based login may be silently treated as anonymous until this is resolved. Re-run manually: ${SECURITY_SCRIPT} --namespace ${NAMESPACE} --geoserver-release ${GEOSERVER_RELEASE}"
  fi
}

main() {
  trap on_exit EXIT
  trap 'on_interrupt INT' INT
  trap 'on_interrupt TERM' TERM

  parse_args "$@"

  require_command helm
  if [[ "$OC" == *' '* ]]; then
    die "OC must be a single executable path with no embedded arguments (got: '$OC')"
  fi
  require_command "$OC"

  [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "WAIT_SECONDS must be an integer"
  [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] && (( POLL_SECONDS > 0 )) || die "POLL_SECONDS must be a positive integer"
  [[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] || die "HEARTBEAT_SECONDS must be an integer"
  [[ "$CRUNCHY_RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid Crunchy release name"
  [[ "$GEOSERVER_RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid GeoServer release name"
  [[ "$CRUNCHY_USER" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid Crunchy user name"
  [[ -n "$NAMESPACE" ]] || die "Namespace is required: pass --namespace NAME or set OPENSHIFT_NAMESPACE"
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "Invalid namespace name: $NAMESPACE"

  CURRENT_STEP="acquiring deploy lock"
  acquire_lock

  local crunchy_values geoserver_values
  crunchy_values="$(values_file "$CRUNCHY_CHART")"
  geoserver_values="$(values_file "$GEOSERVER_CHART")"

  CURRENT_STEP="checking OpenShift authentication"
  "$OC" whoami >/dev/null || die "OpenShift authentication is required"
  if [[ -n "$EXPECTED_OC_SERVER" ]]; then
    local current_server=""
    current_server="$("$OC" whoami --show-server 2>/dev/null || true)"
    [[ "$current_server" == "$EXPECTED_OC_SERVER" ]] || die "Authenticated OpenShift server '${current_server:-unknown}' does not match --expected-server/EXPECTED_OC_SERVER '${EXPECTED_OC_SERVER}'. Log in to the correct cluster before re-running."
  fi

  CURRENT_STEP="checking namespace ${NAMESPACE}"
  if ! "$OC" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    if [[ "$CREATE_NAMESPACE" == "true" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] Namespace ${NAMESPACE} does not exist; would run: oc new-project ${NAMESPACE}"
      else
        "$OC" new-project "$NAMESPACE" >/dev/null
      fi
    else
      die "OpenShift namespace does not exist: $NAMESPACE (use --create-namespace if appropriate)"
    fi
  fi

  CURRENT_STEP="installing Crunchy Postgres release ${CRUNCHY_RELEASE}"
  log "Installing Crunchy release ${CRUNCHY_RELEASE}"
  guard_release_not_pending "$CRUNCHY_RELEASE"
  local crunchy_args=(
    upgrade --install "$CRUNCHY_RELEASE" "$CRUNCHY_CHART"
    --namespace "$NAMESPACE"
    -f "$crunchy_values"
    --set-string "crunchy.fullnameOverride=${CRUNCHY_RELEASE}"
    --wait --timeout "$HELM_TIMEOUT"
  )
  if [[ "$CREATE_NAMESPACE" == "true" ]]; then
    crunchy_args+=(--create-namespace)
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    crunchy_args+=(--dry-run)
  else
    crunchy_args+=(--atomic)
  fi
  run_helm "${crunchy_args[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Skipping Crunchy readiness waits (nothing was actually applied)"
  else
    local readiness_deadline=$(( SECONDS + WAIT_SECONDS ))
    CURRENT_STEP="waiting for Crunchy PostgresCluster readiness"
    wait_until "Crunchy PostgresCluster ${CRUNCHY_RELEASE}" postgres_cluster_ready "$readiness_deadline"
    CURRENT_STEP="waiting for Crunchy pguser Secret"
    wait_until "Secret ${CRUNCHY_RELEASE}-pguser-${CRUNCHY_USER}" postgres_secret_ready "$readiness_deadline"
    CURRENT_STEP="waiting for pgBouncer Service"
    wait_until "Service ${CRUNCHY_RELEASE}-pgbouncer" pgbouncer_service_ready "$readiness_deadline"
  fi

  CURRENT_STEP="installing GeoServer Cloud release ${GEOSERVER_RELEASE}"
  log "Installing GeoServer release ${GEOSERVER_RELEASE}"
  guard_release_not_pending "$GEOSERVER_RELEASE"
  local geoserver_args=(
    upgrade --install "$GEOSERVER_RELEASE" "$GEOSERVER_CHART"
    --namespace "$NAMESPACE"
    -f "$geoserver_values"
    --set-string "database.crunchyReleaseName=${CRUNCHY_RELEASE}"
    --set-string "database.crunchyUserName=${CRUNCHY_USER}"
    --wait --timeout "$HELM_TIMEOUT"
  )
  if [[ "$DRY_RUN" == "true" ]]; then
    geoserver_args+=(--dry-run)
  else
    geoserver_args+=(--atomic)
  fi
  if [[ -n "$OIDC_CLIENT_SECRET_VALUE" ]]; then
    write_oidc_values_file "$OIDC_CLIENT_SECRET_VALUE"
    geoserver_args+=(-f "$OIDC_TEMP_VALUES_FILE")
  fi
  run_helm "${geoserver_args[@]}"

  CURRENT_STEP="complete"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run complete (no changes were made)"
  else
    log "Deployment complete"
  fi
  log "Crunchy release: ${CRUNCHY_RELEASE}"
  log "GeoServer release: ${GEOSERVER_RELEASE}"
  log "Namespace: ${NAMESPACE}"
  log "Database Service: ${CRUNCHY_RELEASE}-pgbouncer"
  log "Database Secret: ${CRUNCHY_RELEASE}-pguser-${CRUNCHY_USER}"

  configure_geoserver_security
}

main "$@"
