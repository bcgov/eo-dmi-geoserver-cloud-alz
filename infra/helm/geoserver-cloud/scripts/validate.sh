#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${1:-${CHART_ROOT}/values/values-dev.yaml}"
NAMESPACE="${NAMESPACE:-geoserver-dev}"
CRUNCHY_RELEASE_NAME="${CRUNCHY_RELEASE_NAME:-crunchy-postgres}"
RENDERED_FILE="$(mktemp "${TMPDIR:-/tmp}/geoserver-cloud-rendered.XXXXXX.yaml")"

cleanup() {
  rm -f "$RENDERED_FILE"
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require_command helm
require_command kubeconform
[[ -f "$VALUES_FILE" ]] || {
  printf 'Values file not found: %s\n' "$VALUES_FILE" >&2
  exit 1
}

helm lint "$CHART_ROOT" --strict -f "$VALUES_FILE"
helm template geoserver-cloud "$CHART_ROOT" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set-string "database.crunchyReleaseName=${CRUNCHY_RELEASE_NAME}" \
  > "$RENDERED_FILE"

kubeconform \
  -strict \
  -ignore-missing-schemas \
  -summary \
  "$RENDERED_FILE"

if ! awk '
function reset_env() {
  for (name in seen) delete seen[name]
  in_env = 0
  env_indent = -1
}
BEGIN { reset_env() }
/^---[[:space:]]*$/ { reset_env(); next }
/^[[:space:]]+env:[[:space:]]*$/ {
  match($0, /^[[:space:]]*/)
  env_indent = RLENGTH
  in_env = 1
  next
}
{
  if (!in_env || $0 ~ /^[[:space:]]*$/) next
  match($0, /^[[:space:]]*/)
  if (RLENGTH <= env_indent) {
    in_env = 0
    next
  }
  if ($0 ~ /^[[:space:]]*-[[:space:]]+name:[[:space:]]+/) {
    name = $0
    sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]+/, "", name)
    sub(/[[:space:]].*$/, "", name)
    if (seen[name]++) {
      printf "Rendered workload has duplicate environment variable: %s\n", name
      exit 1
    }
  }
}
' "$RENDERED_FILE"; then
  exit 1
fi

if grep -Eqi 'docker\.io|registry-1\.docker\.io' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain a direct Docker Hub image reference\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+image:[^[:space:]]*:latest[[:space:]]*$' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain a floating latest image tag\n' >&2
  exit 1
fi
if ! grep -Eq 'artifacts\.developer\.gov\.bc\.ca/' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain no Platform Artifactory image reference\n' >&2
  exit 1
fi
while IFS= read -r image; do
  if [[ "$image" != artifacts.developer.gov.bc.ca/* ]]; then
    printf 'Rendered image is outside Platform Artifactory: %s\n' "$image" >&2
    exit 1
  fi
done < <(sed -nE 's/^[[:space:]]+image:[[:space:]]+([^[:space:]]+).*$/\1/p' "$RENDERED_FILE")
workload_count="$(grep -Ec '^kind:[[:space:]]+(Deployment|StatefulSet|Job|CronJob|DaemonSet)[[:space:]]*$' "$RENDERED_FILE")"
pull_secret_count="$(grep -Ec '^[[:space:]]+imagePullSecrets:[[:space:]]*$' "$RENDERED_FILE")"
if [[ "$workload_count" -ne "$pull_secret_count" ]]; then
  printf 'Rendered workloads do not all declare imagePullSecrets\n' >&2
  exit 1
fi
if grep -Eq 'crunchy-postgres-primary|jdbc:postgresql://geodatabase' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain a database endpoint that bypasses pgBouncer\n' >&2
  exit 1
fi
if ! grep -Eq "${CRUNCHY_RELEASE_NAME}-pgbouncer" "$RENDERED_FILE"; then
  printf 'Rendered manifests do not reference the Crunchy pgBouncer Service\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+type:[[:space:]]+(NodePort|LoadBalancer)[[:space:]]*$' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain a NodePort or LoadBalancer Service\n' >&2
  exit 1
fi
for required_resource in gateway webui wms wfs wcs wps rest gwc acl rabbitmq; do
  if ! grep -Eq "^[[:space:]]+name:[[:space:]]+${required_resource}[[:space:]]*$" "$RENDERED_FILE"; then
    printf 'Rendered manifests do not contain the required resource: %s\n' "$required_resource" >&2
    exit 1
  fi
done
secret_count="$(grep -Ec '^kind:[[:space:]]+Secret[[:space:]]*$' "$RENDERED_FILE")"
if [[ "$secret_count" -ne 1 ]] || ! grep -Eq 'app.kubernetes.io/component:[[:space:]]*runtime-secret' "$RENDERED_FILE"; then
  printf 'Rendered manifests contain an unexpected runtime Secret set\n' >&2
  exit 1
fi
for required_key in rabbitmq-password geoserver-admin-password oidc-client-secret session-cookie-secret rabbitmq-erlang-cookie; do
  if ! grep -Eq "^[[:space:]]+${required_key}:" "$RENDERED_FILE"; then
    printf 'Rendered runtime Secret is missing required key: %s\n' "$required_key" >&2
    exit 1
  fi
done

printf 'Helm, kubeconform, and policy validation passed: %s\n' "$VALUES_FILE"
