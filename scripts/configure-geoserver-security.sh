#!/usr/bin/env bash
# scripts/configure-geoserver-security.sh
#
# Configures GeoServer Cloud security over the Bastion SOCKS5 tunnel:
#   1. JDBC role service (gssec schema) via the generic Resource REST API.
#   2. Request-header pre-auth filter (reads sec-username) via the authfilters API.
#   3. Wires headerAuth into the web/default/gwc filter chains.
#   4. Verifies the configuration landed in the shared pgconfig resourcestore.
#
# Invoked by null_resource.configure_geoserver_security (stack/main.tf) which
# exports the required environment variables. Kept as a standalone file (not an
# inline Terraform heredoc) so it can be syntax-checked with `bash -n` and avoids
# Terraform template-escaping pitfalls.
#
# Why these endpoints (verified against GeoServer 3.0.0-CLOUD):
#   * Role SERVICES have no REST endpoint (/rest/security/roleservices -> 404), so
#     they are written as resource files under /rest/resource/security/role/<name>/.
#     Those files live in the pgconfig `resourcestore` table → shared across every
#     microservice replica and persistent across restarts.
#   * Auth FILTERS use /rest/security/authfilters (NOT /rest/security/auth/filters).
#   * The role service uses the pgconfig JNDI datasource (java:comp/env/jdbc/pgconfig)
#     + gssec-schema-qualified DML, so NO database password is stored in security config.
#
# Required env vars:
#   KV_NAME      Key Vault name (for the geoserver-admin-password secret)
#   GATEWAY_URL  e.g. https://gateway.<env-domain>  (NOT the .internal. form)
# Optional:
#   SOCKS5_PORT  default 8228
#   GS_BASE_PATH default /geoserver/cloud

set -euo pipefail

: "${KV_NAME:?KV_NAME is required}"
: "${GATEWAY_URL:?GATEWAY_URL is required}"
SOCKS5_PORT="${SOCKS5_PORT:-8228}"
GS_BASE_PATH="${GS_BASE_PATH:-/geoserver/cloud}"

PROXY="socks5h://127.0.0.1:${SOCKS5_PORT}"
GS="${GATEWAY_URL}${GS_BASE_PATH}"

ADMIN_PASS="$(az keyvault secret show --vault-name "${KV_NAME}" --name geoserver-admin-password --query value -o tsv)"

# curl wrapper: SOCKS5 proxy + admin basic auth. Defined as an array to keep the
# password out of word-splitting surprises.
gs_curl() { curl --proxy "${PROXY}" -s --max-time 120 -u "admin:${ADMIN_PASS}" "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Wait for the GeoServer REST API (gateway/rest cold-start can take ~60s).
# ---------------------------------------------------------------------------
echo "Waiting for GeoServer REST API at ${GS} ..."
for i in $(seq 1 40); do
  http="$(gs_curl -o /dev/null -w '%{http_code}' "${GS}/rest/about/version.json" 2>/dev/null || echo 000)"
  if [ "${http}" = "200" ]; then
    echo "GeoServer is up (attempt ${i})."
    break
  fi
  echo "  attempt ${i}/40 -> HTTP ${http}, retrying in 15s..."
  sleep 15
  if [ "${i}" -eq 40 ]; then
    echo "Timed out waiting for GeoServer." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. JDBC role service (gssec schema) via the Resource REST API.
#    creatingTables=false: the init-gsroles job already created the tables; the
#    DDL is uploaded for completeness only (not executed).
# ---------------------------------------------------------------------------
cat > "${TMP}/rolesddl.xml" <<'DDL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
<properties>
  <comment>DDL statements for role database (gssec schema)</comment>
  <entry key="check.table">gssec.role_props</entry>
  <entry key="roles.create">create table gssec.roles(name varchar(64) not null,parent varchar(64),primary key(name))</entry>
  <entry key="roleprops.create">create table gssec.role_props(rolename varchar(64) not null,propname varchar(64) not null,propvalue varchar(2048),primary key (rolename,propname))</entry>
  <entry key="userroles.create">create table gssec.user_roles(username varchar(128) not null,rolename varchar(64) not null,primary key(username,rolename))</entry>
  <entry key="userroles.indexcreate">create index user_roles_idx on gssec.user_roles(rolename,username)</entry>
  <entry key="grouproles.create">create table gssec.group_roles(groupname varchar(128) not null,rolename varchar(64) not null,primary key(groupname,rolename))</entry>
  <entry key="grouproles.indexcreate">create index group_roles_idx on gssec.group_roles(rolename,groupname)</entry>
  <entry key="roles.drop">drop table gssec.roles</entry>
  <entry key="roleprops.drop">drop table gssec.role_props</entry>
  <entry key="userroles.drop">drop table gssec.user_roles</entry>
  <entry key="grouproles.drop">drop table gssec.group_roles</entry>
</properties>
DDL

cat > "${TMP}/rolesdml.xml" <<'DML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
<properties>
  <comment>DML statements for role database (gssec schema)</comment>
  <entry key="roles.count">select count(*) from gssec.roles</entry>
  <entry key="roles.all">select name,parent from gssec.roles</entry>
  <entry key="roles.keyed">select parent from gssec.roles where name = ?</entry>
  <entry key="roles.insert">insert into gssec.roles (name) values (?)</entry>
  <entry key="roles.update">update gssec.roles set name=name where name = ?</entry>
  <entry key="roles.parentUpdate">update gssec.roles set parent = ? where name = ?</entry>
  <entry key="roles.deleteParent">update gssec.roles set parent = null where parent = ?</entry>
  <entry key="roles.delete">delete from gssec.roles where name = ?</entry>
  <entry key="roles.deleteAll">delete from gssec.roles</entry>
  <entry key="roleprops.all">select rolename,propname,propvalue from gssec.role_props</entry>
  <entry key="roleprops.selectForRole">select propname,propvalue from gssec.role_props where rolename = ?</entry>
  <entry key="roleprops.selectForUser">select p.rolename,p.propname,p.propvalue from gssec.role_props p,gssec.user_roles u where u.rolename = p.rolename and u.username = ?</entry>
  <entry key="roleprops.selectForGroup">select p.rolename,p.propname,p.propvalue from gssec.role_props p,gssec.group_roles g where g.rolename = p.rolename and g.groupname = ?</entry>
  <entry key="roleprops.deleteForRole">delete from gssec.role_props where rolename=?</entry>
  <entry key="roleprops.insert">insert into gssec.role_props(rolename,propname,propvalue) values (?,?,?)</entry>
  <entry key="roleprops.deleteAll">delete from gssec.role_props</entry>
  <entry key="userroles.rolesForUser">select u.rolename,r.parent from gssec.user_roles u ,gssec.roles r where r.name=u.rolename and u.username = ?</entry>
  <entry key="userroles.usersForRole">select username from gssec.user_roles where rolename = ?</entry>
  <entry key="userroles.insert">insert into gssec.user_roles(rolename,username) values (?,?)</entry>
  <entry key="userroles.delete">delete from gssec.user_roles where rolename=? and username = ?</entry>
  <entry key="userroles.deleteRole">delete from gssec.user_roles where rolename=?</entry>
  <entry key="userroles.deleteUser">delete from gssec.user_roles where username = ?</entry>
  <entry key="userroles.deleteAll">delete from gssec.user_roles</entry>
  <entry key="grouproles.rolesForGroup">select g.rolename,r.parent from gssec.group_roles g,gssec.roles r where g.rolename = r.name and g.groupname = ?</entry>
  <entry key="grouproles.groupsForRole">select groupname from gssec.group_roles where rolename = ?</entry>
  <entry key="grouproles.insert">insert into gssec.group_roles(rolename,groupname) values (?,?)</entry>
  <entry key="grouproles.delete">delete from gssec.group_roles where rolename=? and groupname = ?</entry>
  <entry key="grouproles.deleteRole">delete from gssec.group_roles where rolename=?</entry>
  <entry key="grouproles.deleteGroup">delete from gssec.group_roles where groupname = ?</entry>
  <entry key="grouproles.deleteAll">delete from gssec.group_roles</entry>
</properties>
DML

cat > "${TMP}/roleservice.xml" <<'RS'
<roleService>
  <id>jdbcRoleService</id>
  <name>jdbc</name>
  <className>org.geoserver.security.jdbc.JDBCRoleService</className>
  <propertyFileNameDDL>rolesddl.xml</propertyFileNameDDL>
  <propertyFileNameDML>rolesdml.xml</propertyFileNameDML>
  <jndiName>java:comp/env/jdbc/pgconfig</jndiName>
  <creatingTables>false</creatingTables>
  <adminRoleName>ROLE_ADMINISTRATOR</adminRoleName>
  <groupAdminRoleName>ROLE_GROUP_ADMIN</groupAdminRoleName>
</roleService>
RS

echo "Uploading JDBC role service (resource API -> pgconfig resourcestore)..."
gs_curl -X PUT -H "Content-Type: application/xml" --data-binary @"${TMP}/rolesddl.xml" \
  "${GS}/rest/resource/security/role/jdbc/rolesddl.xml" -w '  rolesddl.xml  -> HTTP %{http_code}\n'
gs_curl -X PUT -H "Content-Type: application/xml" --data-binary @"${TMP}/rolesdml.xml" \
  "${GS}/rest/resource/security/role/jdbc/rolesdml.xml" -w '  rolesdml.xml  -> HTTP %{http_code}\n'
gs_curl -X PUT -H "Content-Type: application/xml" --data-binary @"${TMP}/roleservice.xml" \
  "${GS}/rest/resource/security/role/jdbc/config.xml" -w '  config.xml    -> HTTP %{http_code}\n'

echo "Reloading GeoServer configuration..."
gs_curl -X POST "${GS}/rest/reload" -w '  reload -> HTTP %{http_code}\n' || true

# ---------------------------------------------------------------------------
# 2. Request-header pre-auth filter (real /rest/security/authfilters endpoint).
# ---------------------------------------------------------------------------
cat > "${TMP}/headerfilter.xml" <<'FILTER'
<org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
  <name>headerAuth</name>
  <className>org.geoserver.security.filter.GeoServerRequestHeaderAuthenticationFilter</className>
  <roleServiceName>jdbc</roleServiceName>
  <principalHeaderAttribute>sec-username</principalHeaderAttribute>
  <roleSource class="org.geoserver.security.config.PreAuthenticatedUserNameFilterConfig$PreAuthenticatedUserNameRoleSource">RoleService</roleSource>
</org.geoserver.security.config.RequestHeaderAuthenticationFilterConfig>
FILTER

echo "Configuring headerAuth filter..."
# Existence MUST be determined from the filter LIST: a per-name GET of a missing
# filter returns "<null/>" with HTTP 200 (not 404), so the HTTP code is useless,
# and a PUT to a non-existent filter 500s (update has nothing to update).
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
  *)
    echo "  headerAuth ${filter_verb} FAILED. Response body:" >&2
    sed 's/^/    /' "${TMP}/filter_resp.txt" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 3. Cleanup: remove any broken idir JDBC user/group service that was uploaded
#    during a previous apply. GeoServer Cloud's XStream aliases don't include
#    JDBCUserGroupServiceConfig, causing a ClassCastException on Security page
#    load. Delete the files so GeoServer stops trying to load the service.
#    IDIR users are tracked in gssec.user_display_names (populated by the
#    proxy) and role assignment is done via DBeaver SQL on gssec.user_roles.
# ---------------------------------------------------------------------------
echo "Removing broken idir user/group service files (if present)..."
for f in config.xml usersdddl.xml usersdml.xml; do
  code="$(gs_curl -o /dev/null -w '%{http_code}' -X DELETE \
    "${GS}/rest/resource/security/usergroup/idir/${f}" 2>/dev/null || echo 000)"
  case "${code}" in
    2*|404) echo "  ${f}: ${code}" ;;
    *)      echo "  WARNING: DELETE ${f} returned ${code} (non-fatal)" ;;
  esac
done
echo "Reloading GeoServer after cleanup..."
gs_curl -X POST "${GS}/rest/reload" -w '  reload -> HTTP %{http_code}\n' || true

echo "Wiring headerAuth into filter chains..."
gs_curl "${GS}/rest/resource/security/config.xml" -o "${TMP}/config.xml"
echo "  Downloaded config.xml ($(wc -c < "${TMP}/config.xml") bytes)"

if grep -q "<filter>headerAuth</filter>" "${TMP}/config.xml"; then
  echo "  headerAuth already present in filter chains, skipping."
else
  # GNU sed -z: reads the whole file as one record (null-delimited) so the
  # [^>]* pattern crosses newlines and matches multi-line <filters ...> tags.
  # Available in Git for Windows (GNU sed 4.x) and all Linux distros.
  for chain in web default gwc; do
    sed -zi "s|<filters name=\"${chain}\" \([^>]*\)>|<filters name=\"${chain}\" \1><filter>headerAuth</filter>|" "${TMP}/config.xml"
  done

  if grep -q "<filter>headerAuth</filter>" "${TMP}/config.xml"; then
    echo "  Injected headerAuth into web/default/gwc chains."
    gs_curl -X PUT -H "Content-Type: application/xml" --data-binary @"${TMP}/config.xml" \
      "${GS}/rest/resource/security/config.xml" -w '  config.xml chains -> HTTP %{http_code}\n'
  else
    echo "  ERROR: sed found no matching <filters name=...> elements." >&2
    grep -n 'filters name' "${TMP}/config.xml" >&2 || echo "  (no 'filters name' found in config.xml)" >&2
    exit 1
  fi
fi

echo "Reloading GeoServer configuration..."
gs_curl -X POST "${GS}/rest/reload" -w '  reload -> HTTP %{http_code}\n' || true

# ---------------------------------------------------------------------------
# 4. Verify the configuration landed in the shared store.
# ---------------------------------------------------------------------------
echo "Verifying..."
fail=0
check() {
  local path="$1" pattern="$2" label="$3"
  if gs_curl "${GS}${path}" | grep -q "${pattern}"; then
    echo "  OK   ${label}"
  else
    echo "  FAIL ${label}"
    fail=1
  fi
}
check "/rest/resource/security/role/jdbc/config.xml" "JDBCRoleService" "jdbc role service present"
check "/rest/security/authfilters.xml"               "headerAuth"      "headerAuth filter present"
check "/rest/resource/security/config.xml"           "headerAuth"      "headerAuth wired into chains"
# Confirm idir service was removed (no config.xml should exist).
if gs_curl "${GS}/rest/resource/security/usergroup/idir/config.xml" 2>/dev/null | grep -q "JDBCUserGroupServiceConfig\|userGroupService"; then
  echo "  FAIL idir service still present — Security page will error"
  fail=1
else
  echo "  OK   idir service absent (Security page safe)"
fi

if [ "${fail}" != "0" ]; then
  echo "Security verification FAILED." >&2
  exit 1
fi
echo "GeoServer security configuration complete."
