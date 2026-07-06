#!/usr/bin/env bash
# infra/scripts/tf.sh
# Single, self-contained entry point for all Terraform operations.
# All environments share the single infra/stack/ directory; environment identity and
# resource names are injected at runtime via TF_VAR_* env vars set per GitHub
# Environment. Backend state is isolated per environment via TFSTATE_KEY.
#
# Usage:
#   ./infra/scripts/tf.sh <dev|test|prod> <command> [extra terraform args...]
#
# Commands:
#   init      terraform init with backend config from TFSTATE_* env vars
#   fmt       terraform fmt -check -recursive (repo-wide)
#   validate  terraform validate (runs init -backend=false first)
#   plan      terraform plan -out=tfplan  (auto-inits if needed)
#   apply     terraform apply tfplan      (consumes the saved plan)
#   destroy   terraform destroy
#   output    terraform output
#   <other>   passed through to terraform verbatim
#
# Examples:
#   ./infra/scripts/tf.sh dev plan
#   ./infra/scripts/tf.sh prod apply
#   ./infra/scripts/tf.sh dev plan -var='service_max_replicas=4'
#
# Backend resolution (TFSTATE_* env vars, set in GitHub Environment Variables):
#   TFSTATE_RESOURCE_GROUP   (default: rg-geoserver-tfstate-<env>)
#   TFSTATE_STORAGE_ACCOUNT  (default: stgeoservertf<env>)
#   TFSTATE_CONTAINER        (default: tfstate)
#   TFSTATE_KEY              (default: geoserver-cloud/<env>.tfstate)
#
# Terraform variable injection:
#   Set TF_VAR_* in your GitHub Environment Variables (or export locally).
#   Required: TF_VAR_environment, TF_VAR_resource_group_name, TF_VAR_acr_name,
#             TF_VAR_key_vault_name, TF_VAR_postgres_server_name,
#             TF_VAR_vnet_name, TF_VAR_vnet_resource_group_name,
#             TF_VAR_aca_subnet_cidr, TF_VAR_private_endpoints_subnet_name,
#             TF_VAR_gs_cloud_version

set -euo pipefail

PLAN_FILE="tfplan"

# --- constants --------------------------------------------------------------
# Valid deployment environments. Keep in sync with stacks/<env> directories.
VALID_ENVS=("dev" "test" "prod" "tools")

# Repo root, resolved relative to this script regardless of caller CWD.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --- logging ----------------------------------------------------------------
# All log output goes to stderr so stdout stays clean for capturable values.
_log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
die() { log_error "$@"; exit 1; }

# --- environment validation -------------------------------------------------
# require_env <env> : exit non-zero unless <env> is one of VALID_ENVS.
require_env() {
  local env="${1:-}"
  [[ -n "${env}" ]] || die "environment is required (one of: ${VALID_ENVS[*]})"
  local valid
  for valid in "${VALID_ENVS[@]}"; do
    [[ "${env}" == "${valid}" ]] && return 0
  done
  die "invalid environment '${env}' (expected one of: ${VALID_ENVS[*]})"
}

# --- runtime context detection ---------------------------------------------
# running_in_gha : true when executing inside a GitHub Actions runner.
running_in_gha() { [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; }

# require_cmd <name...> : fail fast if a required CLI is missing.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found on PATH: ${cmd}"
  done
}

# --- Azure auth context -----------------------------------------------------
# Configure the azurerm provider / backend to authenticate with OIDC (no client
# secrets). In GHA, azure/login@v3 exports ARM_CLIENT_ID, ARM_TENANT_ID,
# ARM_SUBSCRIPTION_ID and the OIDC token plumbing. Locally we fall back to the
# Azure CLI context from `az login`.
configure_azure_auth() {
  if running_in_gha; then
    log_info "Detected GitHub Actions: using OIDC federated credentials."
    : "${ARM_CLIENT_ID:?ARM_CLIENT_ID must be set by azure/login (GitHub Variable AZURE_CLIENT_ID)}"
    : "${ARM_TENANT_ID:?ARM_TENANT_ID must be set by azure/login (GitHub Variable AZURE_TENANT_ID)}"
    : "${ARM_SUBSCRIPTION_ID:?ARM_SUBSCRIPTION_ID must be set by azure/login (GitHub Variable AZURE_SUBSCRIPTION_ID)}"
    export ARM_USE_OIDC="true"
    export ARM_USE_AZUREAD="true"
  else
    log_info "Local run: using Azure CLI context (az login)."
    require_cmd az
    az account show >/dev/null 2>&1 || die "not logged in to Azure CLI; run 'az login' first"
    export ARM_USE_CLI="true"
    export ARM_USE_AZUREAD="true"
    if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
      ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
      export ARM_SUBSCRIPTION_ID
    fi
  fi
  log_info "Azure subscription: ${ARM_SUBSCRIPTION_ID}"
}

# --- backend configuration --------------------------------------------------
# Backend values are environment-specific and injected at `init` time via
# `-backend-config` so the same Terraform code serves every environment.
# Override any of these by exporting the matching TFSTATE_* variable.
backend_resource_group()  { echo "${TFSTATE_RESOURCE_GROUP:-rg-geoserver-tfstate-${1}}"; }
# Storage account names: 3-24 chars, lowercase alphanumeric, globally unique.
backend_storage_account() { echo "${TFSTATE_STORAGE_ACCOUNT:-stgeoservertf${1}}"; }
backend_container()       { echo "${TFSTATE_CONTAINER:-tfstate}"; }
backend_key()             { echo "${TFSTATE_KEY:-geoserver-cloud/${1}.tfstate}"; }

# --- helpers ----------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage: ./infra/scripts/tf.sh <dev|test|prod|tools> <command> [extra terraform args...]

All environments share infra/stack/. Environment-specific values are injected via
TF_VAR_* env vars set per GitHub Environment (or exported locally).

Commands:
  init      terraform init with backend config from TFSTATE_* env vars
  fmt       terraform fmt -check -recursive (repo-wide)
  validate  terraform validate (runs init -backend=false first)
  plan      terraform plan -out=tfplan  (auto-inits if needed)
  apply     terraform apply tfplan      (consumes the saved plan)
  destroy   terraform destroy
  output    terraform output
  <other>   passed through to terraform verbatim
EOF
  exit "${1:-0}"
}

# All environments share a single stack directory.
stack_dir() { echo "${REPO_ROOT}/infra/stack"; }

# Run `terraform init` with backend values injected via -backend-config.
tf_init() {
  local env="${1}" dir
  dir="$(stack_dir "${env}")"
  log_info "terraform init (backend: $(backend_storage_account "${env}")/$(backend_container "${env}")/$(backend_key "${env}"))"
  terraform -chdir="${dir}" init -input=false -reconfigure \
    -backend-config="resource_group_name=$(backend_resource_group "${env}")" \
    -backend-config="storage_account_name=$(backend_storage_account "${env}")" \
    -backend-config="container_name=$(backend_container "${env}")" \
    -backend-config="key=$(backend_key "${env}")" \
    -backend-config="use_azuread_auth=true"
}

main() {
  [[ "${1:-}" =~ ^(-h|--help)$ ]] && usage 0
  local env="${1:-}" cmd="${2:-}"
  require_env "${env}"
  [[ -n "${cmd}" ]] || die "a terraform command is required (init|fmt|validate|plan|apply|destroy|...)"
  shift 2 || true
  require_cmd terraform
  configure_azure_auth

  local dir
  dir="$(stack_dir "${env}")"
  [[ -d "${dir}" ]] || die "stack directory not found: ${dir}"

  case "${cmd}" in
    init)
      tf_init "${env}"
      ;;
    fmt)
      log_info "terraform fmt -check -recursive"
      terraform -chdir="${REPO_ROOT}" fmt -check -recursive "$@"
      ;;
    validate)
      log_info "terraform validate (offline init)"
      terraform -chdir="${dir}" init -input=false -backend=false >/dev/null
      terraform -chdir="${dir}" validate "$@"
      ;;
    plan)
      # Init if the .terraform dir is missing OR if the backend lock file is
      # absent (happens when backend config changes without a re-init).
      if [[ ! -d "${dir}/.terraform" ]] || [[ ! -f "${dir}/.terraform/terraform.tfstate" ]]; then
        tf_init "${env}"
      fi
      log_info "terraform plan -> ${PLAN_FILE}"
      terraform -chdir="${dir}" plan -input=false -out="${PLAN_FILE}" "$@"
      ;;
    apply)
      [[ -f "${dir}/.terraform/terraform.tfstate" ]] || tf_init "${env}"
      if [[ -f "${dir}/${PLAN_FILE}" ]]; then
        log_info "terraform apply ${PLAN_FILE}"
        terraform -chdir="${dir}" apply -input=false "${PLAN_FILE}"
      else
        die "No saved plan at ${dir}/${PLAN_FILE}. Run '$(basename "$0") ${env} plan' first."
      fi
      ;;
    destroy)
      [[ -f "${dir}/.terraform/terraform.tfstate" ]] || tf_init "${env}"
      log_warn "Destroying '${env}' stack. Stateful resources use prevent_destroy and will block."
      terraform -chdir="${dir}" destroy -input=false "$@"
      ;;
    *)
      log_info "terraform ${cmd} $*"
      terraform -chdir="${dir}" "${cmd}" "$@"
      ;;
  esac
}

main "$@"
