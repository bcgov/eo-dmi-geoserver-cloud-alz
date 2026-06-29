#!/usr/bin/env bash
# scripts/configure-geoserver-security.sh
#
# Configures GeoServer Cloud security over the Bastion SOCKS5 tunnel (Option 1):
#   1. Request-header pre-auth filter (headerAuth) reading sec-username (= the
#      lower-cased IDIR email injected by the Node proxy).
#   2. headerAuth uses the BUILT-IN default XML role service (roleServiceName=default).
#      GeoServer Cloud 3.0 cannot load the JDBC (gssec) role/user-group services
#      (XStream `cannot be cast to JDBCSecurityServiceConfig`), so we use the XML
#      services that load reliably. Role assignment is done in the GeoServer UI/REST.
#   3. Cleans up any previously-uploaded JDBC role service + idir user/group service
#      files (both crash the Security page on load).
#   4. Wires headerAuth into the web/default/gwc filter chains.
#   5. Bootstraps the super admin (ADMIN_PRINCIPAL email -> ROLE_ADMINISTRATOR).
#   6. Verifies the result.
#
# Invoked by null_resource.configure_geoserver_security (stack/main.tf).
#
# Required env vars:
#   KV_NAME          Key Vault name (for the geoserver-admin-password secret)
#   GATEWAY_URL      e.g. https://gateway.<env-domain>  (NOT the .internal. form)
# Optional:
#   SOCKS5_PORT      default 8228
#   GS_BASE_PATH     default /geoserver/cloud
#   ADMIN_PRINCIPAL  email to bootstrap as ROLE_ADMINISTRATOR (e.g. omishra@gov.bc.ca)
#   ROLE_SERVICE     default "default"   (built-in XML role service)
#   UG_SERVICE       default "default"   (built-in XML user/group service)

set -euo pipefail

: "${KV_NAME:?KV_NAME is required}"
: "${GATEWAY_URL:?GATEWAY_URL is required}"
SOCKS5_PORT="${SOCKS5_PORT:-8228}"
GS_BASE_PATH="${GS_BASE_PATH:-/geoserver/cloud}"
ADMIN_PRINCIPAL="${ADMIN_PRINCIPAL:-}"
ROLE_SERVICE="${ROLE_SERVICE:-default}"
UG_SERVICE="${UG_SERVICE:-default}"

PROXY="socks5h://127.0.0.1:${SOCKS5_PORT}"
GS="${GATEWAY_URL}${GS_BASE_PATH}"

ADMIN_PASS="$(az keyvault secret show --vault-name "${KV_NAME}" --name geoserver-admin-password --query value -o tsv)"

gs_curl() { curl --proxy "${PROXY}" -s --max-time 120 -u "admin:${ADMIN_PASS}" "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Wait for the GeoServer REST API (gateway/rest cold-start can take ~60s).
# ---------------------------------------------------------------------------
echo "Waiting for GeoServer REST API at ${GS} ..."
for i in $(seq 1 40); do
  http="$(gs_curl -o /dev/null -w '%{http_code}' "${GS}/rest/about/version.json" 2>/dev/null || echo 000)"
  if [ "${http}" = "200" ]; then echo "GeoServer is up (attempt ${i})."; break; fi
  echo "  attempt ${i}/40 -> HTTP ${http}, retrying in 15s..."
  sleep 15
  [ "${i}" -eq 40 ] && { echo "Timed out waiting for GeoServer." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. Cleanup: remove broken JDBC security services that crash the Security page.
#    (The JDBC role service + the idir JDBC user/group service both fail to load
#    on GeoServer Cloud 3.0 with a ClassCastException.)
# ---------------------------------------------------------------------------
echo "Removing broken JDBC security service files (if present)..."
del() {
  local path="$1"
  local code
  code="$(gs_curl -o /dev/null -w '%{http_code}' -X DELETE "${GS}/rest/resource/${path}" 2>/dev/null || echo 000)"
  case "${code}" in
    2*|404) echo "  ${path}: ${code}" ;;
    *)      echo "  WARNING: DELETE ${path} returned ${code} (non-fatal)" ;;
  esac
}
for f in config.xml rolesddl.xml rolesdml.xml; do del "security/role/jdbc/${f}"; done
for f in config.xml usersdddl.xml usersdml.xml; do del "security/usergroup/idir/${f}"; done
echo "Reloading GeoServer after cleanup..."
gs_curl -X POST "${GS}/rest/reload" -w '  reload -> HTTP %{http_code}\n' || true

# ---------------------------------------------------------------------------
# 2. Request-header pre-auth filter -> built-in default XML role service.
# ---------------------------------------------------------------------------
cat > "${TMP}/headerfilter.xml" <<FILTER
<org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
  <name>headerAuth</name>
  <className>org.geoserver.security.filter.GeoServerRequestHeaderAuthenticationFilter</className>
  <roleServiceName>${ROLE_SERVICE}</roleServiceName>
  <principalHeaderAttribute>sec-username</principalHeaderAttribute>
  <roleSource class="org.geoserver.security.config.PreAuthenticatedUserNameFilterConfig\$PreAuthenticatedUserNameRoleSource">RoleService</roleSource>
</org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
FILTER

echo "Configuring headerAuth filter (roleServiceName=${ROLE_SERVICE})..."
# A per-name GET of a missing filter returns "<null/>" with HTTP 200, so decide
# create vs update from the filter LIST.
if gs_curl "${GS}/rest/security/authfilters.xml" | grep -q "<name>headerAuth</name>"; then
  filter_method="PUT";  filter_url="${GS}/rest/security/authfilters/headerAuth"; filter_verb="update"
else
  filter_method="POST"; filter_url="${GS}/rest/security/authfilters";            filter_verb="create"
fi
filter_code="$(gs_curl -o "${TMP}/filter_resp.txt" -w '%{http_code}' \
  -X "${filter_method}" -H "Content-Type: application/xml" \
  --data-binary @"${TMP}/headerfilter.xml" "${filter_url}")"
echo "  headerAuth ${filter_verb} -> HTTP ${filter_code}"
case "${filter_code}" in
  2*) : ;;
  *) echo "  headerAuth ${filter_verb} FAILED:" >&2; sed 's/^/    /' "${TMP}/filter_resp.txt" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 3. Wire headerAuth into the web/default/gwc filter chains.
# ---------------------------------------------------------------------------
echo "Wiring headerAuth into filter chains..."
gs_curl "${GS}/rest/resource/security/config.xml" -o "${TMP}/config.xml"
if grep -q "<filter>headerAuth</filter>" "${TMP}/config.xml"; then
  echo "  headerAuth already present in filter chains, skipping."
else
  for chain in web default gwc; do
    sed -zi "s|<filters name=\"${chain}\" \([^>]*\)>|<filters name=\"${chain}\" \1><filter>headerAuth</filter>|" "${TMP}/config.xml"
  done
  if grep -q "<filter>headerAuth</filter>" "${TMP}/config.xml"; then
    echo "  Injected headerAuth into web/default/gwc chains."
    gs_curl -X PUT -H "Content-Type: application/xml" --data-binary @"${TMP}/config.xml" \
      "${GS}/rest/resource/security/config.xml" -w '  config.xml chains -> HTTP %{http_code}\n'
  else
    echo "  ERROR: sed found no matching <filters name=...> elements." >&2
    grep -n 'filters name' "${TMP}/config.xml" >&2 || true
    exit 1
  fi
fi
echo "Reloading GeoServer configuration..."
gs_curl -X POST "${GS}/rest/reload" -w '  reload -> HTTP %{http_code}\n' || true

# ---------------------------------------------------------------------------
# 4. Bootstrap the super admin (best-effort; the local 'admin' user can always
#    assign roles in the UI if this step can't associate the system role).
# ---------------------------------------------------------------------------
if [ -n "${ADMIN_PRINCIPAL}" ]; then
  echo "Bootstrapping super admin: ${ADMIN_PRINCIPAL}"
  # 4a. Ensure the user exists in the default user/group service (random unused pw).
  rand_pw="$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 24)"
  uc="$(gs_curl -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    -d "{\"user\":{\"userName\":\"${ADMIN_PRINCIPAL}\",\"password\":\"${rand_pw}\",\"enabled\":true}}" \
    "${GS}/rest/security/usergroup/service/${UG_SERVICE}/users" 2>/dev/null || echo 000)"
  case "${uc}" in
    2*)     echo "  admin user created (${uc})" ;;
    409|500) echo "  admin user already exists (${uc})" ;;
    *)      echo "  WARNING: create admin user returned ${uc} (non-fatal)" ;;
  esac
  # 4b. Ensure the ADMIN role exists (it should in the default XML role service),
  #     then associate it with the admin user. GeoServer Cloud's default role service
  #     uses "ADMIN" (not "ROLE_ADMINISTRATOR") as the admin role name.
  gs_curl -o /dev/null -w '  ensure ADMIN role -> HTTP %{http_code}\n' \
    -X POST "${GS}/rest/security/roles/role/ADMIN" 2>/dev/null || true
  rc="$(gs_curl -o /dev/null -w '%{http_code}' -X POST \
    "${GS}/rest/security/roles/role/ADMIN/user/${ADMIN_PRINCIPAL}" 2>/dev/null || echo 000)"
  case "${rc}" in
    2*) echo "  associated ADMIN with ${ADMIN_PRINCIPAL} (${rc})" ;;
    *)  echo "  WARNING: could not associate ADMIN role (${rc}). Assign it in the UI as 'admin'." ;;
  esac
  gs_curl -X POST "${GS}/rest/reload" -o /dev/null || true
else
  echo "ADMIN_PRINCIPAL not set — skipping super-admin bootstrap."
fi

# ---------------------------------------------------------------------------
# 5. Verify.
# ---------------------------------------------------------------------------
echo "Verifying..."
fail=0
check() {
  if gs_curl "${GS}${1}" | grep -q "${2}"; then echo "  OK   ${3}"; else echo "  FAIL ${3}"; fail=1; fi
}
check "/rest/security/authfilters.xml"     "headerAuth"          "headerAuth filter present"
check "/rest/security/authfilters/headerAuth.xml" "<roleServiceName>${ROLE_SERVICE}</roleServiceName>" "headerAuth uses ${ROLE_SERVICE} role service"
check "/rest/resource/security/config.xml" "headerAuth"          "headerAuth wired into chains"
# Default user/group service reachable (Security page health) + user count.
if gs_curl "${GS}/rest/security/usergroup/service/${UG_SERVICE}/users.json" -o "${TMP}/ug.json" 2>/dev/null \
   && grep -q 'userName\|"users"\|<users' "${TMP}/ug.json"; then
  echo "  OK   ${UG_SERVICE} user/group service reachable ($(grep -o 'userName' "${TMP}/ug.json" | wc -l | tr -d ' ') user(s))"
else
  echo "  WARN ${UG_SERVICE} user/group service not reachable"
fi
# Broken JDBC services must be gone.
if gs_curl "${GS}/rest/resource/security/role/jdbc/config.xml" 2>/dev/null | grep -q "JDBCRoleService"; then
  echo "  FAIL broken jdbc role service still present"; fail=1
else
  echo "  OK   broken jdbc role service absent"
fi

[ "${fail}" != "0" ] && { echo "Security verification FAILED." >&2; exit 1; }
echo "GeoServer security configuration complete."
