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

printf 'Helm and kubeconform validation passed: %s\n' "$VALUES_FILE"
