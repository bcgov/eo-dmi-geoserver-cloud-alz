"""Thin, idempotent client over the GeoServer REST API.

Drives the Gateway URL, not the individual OWS apps — matches the
"only the gateway is exposed" topology in infra/stack/main.tf.
"""
from __future__ import annotations
import re
import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

_SPRING_ENCODING_RE = re.compile(r"^\{[a-zA-Z0-9]*\}")


def _strip_spring_encoding(password: str) -> str:
    """Strip a Spring Security password-encoding prefix like '{noop}' if present.

    acl-admin-password is stored in Key Vault in Spring's delimited-encoding
    format (e.g. '{noop}rawpassword') for the ACL service's own internal
    user-store config — see infra/stack/main.tf secret_acl_admin_password. That
    prefix is a config-time marker, not part of the credential, and must not
    be sent as the HTTP Basic Auth password.
    """
    return _SPRING_ENCODING_RE.sub("", password, count=1)


class GeoServerClient:
    def __init__(self, base_url: str, user: str, password: str, timeout: int = 30):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        self.client = httpx.Client(
            auth=(user, password),
            timeout=timeout,
            headers={"Accept": "application/json"},
        )
        self.acl_client = None
        self.acl_base = None

    # ---------- Health ----------
    @retry(stop=stop_after_attempt(30), wait=wait_exponential(multiplier=2, max=30))
    def wait_healthy(self) -> str:
        """Poll until GeoServer is healthy (30 attempts, exponential backoff up to 30s)."""
        r = self.client.get(f"{self.base}/rest/about/version")
        r.raise_for_status()
        return r.text

    def ping(self) -> str:
        r = self.client.get(f"{self.base}/rest/about/version")
        r.raise_for_status()
        return r.text

    # ---------- Workspaces ----------
    def workspace_exists(self, name: str) -> bool:
        r = self.client.get(f"{self.base}/rest/workspaces/{name}")
        return r.status_code == 200

    @retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, max=10))
    def ensure_workspace(self, name: str, uri: str, isolated: bool) -> None:
        if not self.workspace_exists(name):
            body = {"workspace": {"name": name, "isolated": isolated}}
            r = self.client.post(f"{self.base}/rest/workspaces", json=body)
            r.raise_for_status()
        ns = {"namespace": {"prefix": name, "uri": uri}}
        r = self.client.put(f"{self.base}/rest/namespaces/{name}", json=ns)
        r.raise_for_status()

    # ---------- PostGIS datastores ----------
    def datastore_exists(self, ws: str, name: str) -> bool:
        r = self.client.get(
            f"{self.base}/rest/workspaces/{ws}/datastores/{name}"
        )
        return r.status_code == 200

    def ensure_postgis_store(self, ws: str, name: str, conn: dict, store: dict | None = None) -> None:
        store = store or {}
        payload = {"dataStore": {
            "name": name,
            "connectionParameters": {"entry": [
                {"@key": "dbtype",   "$": "postgis"},
                {"@key": "host",     "$": conn["host"]},
                {"@key": "port",     "$": str(conn["port"])},
                {"@key": "database", "$": conn["database"]},
                {"@key": "schema",   "$": conn.get("schema", "public")},
                {"@key": "user",     "$": conn["user"]},
                {"@key": "passwd",   "$": conn["password"]},
                {"@key": "SSL mode", "$": conn.get("ssl", "require")},
                {"@key": "Expose primary keys", "$": str(store.get("expose_primary_keys", True)).lower()},
                {"@key": "fetch size",           "$": str(store.get("fetch_size", 1000))},
                {"@key": "validate connections", "$": str(store.get("validate_connections", True)).lower()},
            ]},
        }}
        if self.datastore_exists(ws, name):
            r = self.client.put(
                f"{self.base}/rest/workspaces/{ws}/datastores/{name}",
                json=payload,
            )
        else:
            r = self.client.post(
                f"{self.base}/rest/workspaces/{ws}/datastores",
                json=payload,
            )
        r.raise_for_status()

    # ---------- Feature types ----------
    def ensure_feature_type(self, ws: str, store: str, ft: dict) -> None:
        payload = {"featureType": {
            "name": ft["name"],
            "nativeName": ft["native_name"],
            "title": ft["title"],
            "srs": ft["srs"],
            "enabled": ft["enabled"],
        }}
        url_base = (
            f"{self.base}/rest/workspaces/{ws}/datastores/{store}/featuretypes"
        )
        r = self.client.get(f"{url_base}/{ft['name']}")
        if r.status_code == 200:
            r = self.client.put(f"{url_base}/{ft['name']}", json=payload)
        else:
            r = self.client.post(url_base, json=payload)
        r.raise_for_status()

        if ft.get("default_style"):
            self._set_default_style(ws, ft["name"], ft["default_style"])

    def _set_default_style(self, ws: str, layer: str, style: str) -> None:
        body = {"layer": {"defaultStyle": {"name": style}}}
        r = self.client.put(
            f"{self.base}/rest/layers/{ws}:{layer}", json=body
        )
        r.raise_for_status()

    # ---------- Styles ----------
    def ensure_sld_style(self, name: str, sld_xml: str) -> None:
        r = self.client.get(f"{self.base}/rest/styles/{name}")
        if r.status_code != 200:
            self.client.post(
                f"{self.base}/rest/styles",
                json={"style": {"name": name, "filename": f"{name}.sld"}},
            ).raise_for_status()
        self.client.put(
            f"{self.base}/rest/styles/{name}",
            content=sld_xml,
            headers={"Content-Type": "application/vnd.ogc.sld+xml"},
        ).raise_for_status()

    # ---------- Layer groups ----------
    def ensure_layer_group(self, lg: dict) -> None:
        ws = lg["workspace"]
        payload = {"layerGroup": {
            "name": lg["name"],
            "mode": lg["mode"],
            "title": lg["title"],
            "publishables": {"published": [
                {"@type": "layer", "name": ref} for ref in lg["layers"]
            ]},
            "styles": {"style": [{"name": s} for s in lg.get("styles", [])]},
        }}
        url_base = f"{self.base}/rest/workspaces/{ws}/layergroups"
        r = self.client.get(f"{url_base}/{lg['name']}")
        if r.status_code == 200:
            r = self.client.put(f"{url_base}/{lg['name']}", json=payload)
        else:
            r = self.client.post(url_base, json=payload)
        r.raise_for_status()

    # ---------- ACL rules (on ACL Container App) ----------
    def set_acl_base(self, acl_base_url: str, acl_user: str, acl_password: str) -> None:
        """Configure ACL endpoint (called after instantiation if needed)."""
        self.acl_base = acl_base_url.rstrip("/")
        self.acl_client = httpx.Client(
            auth=(acl_user, _strip_spring_encoding(acl_password)),
            timeout=self.timeout,
            headers={"Accept": "application/json"},
        )

    # Map catalog access values to geoserver-acl GrantType values (ALLOW/DENY/LIMIT).
    _ACCESS_MAP = {"READ": "ALLOW", "WRITE": "ALLOW", "ADMIN": "ALLOW", "DENY": "DENY"}

    def ensure_acl_rule(self, rule: dict) -> None:
        """Ensure an ACL data-access rule exists on the geoserver-acl service (idempotent).

        rule: {priority, workspace, layer, access} plus exactly one of {role, username},
        plus optional {service, request}. `username` scopes a rule to one specific
        principal (e.g. a machine/API client's authkey identity) instead of every holder
        of a role — required for per-workspace machine clients so one client's key can't
        be broadened by a shared role grant. `service`/`request` scope a rule to one OWS
        operation (e.g. service="WFS", request="Transaction") instead of every operation
        on the workspace/layer — required so a broad READ rule can't also match a WFS-T
        write request that a separate, more specific rule is meant to gate.
        Uses the geoserver-acl REST API (flat Rule DTO, base path {acl_base}/rules):
          GET /rules, POST /rules, PATCH /rules/id/{id}.
        Access values READ/WRITE/ADMIN/DENY map to ALLOW/DENY. The catalog's "*" layer
        sentinel means "any layer" and must be omitted from the wire payload — the API
        represents that as a null/absent field, not the literal string "*".
        """
        if self.acl_client is None:
            raise RuntimeError("ACL service not configured. Call set_acl_base() first.")

        grant = self._ACCESS_MAP.get(rule["access"], "ALLOW")
        layer = rule.get("layer")
        if layer == "*":
            layer = None
        role = rule.get("role")
        username = rule.get("username")
        # geoserver-acl uppercases and stores these regardless of input casing (e.g.
        # "Transaction" round-trips as "TRANSACTION"); normalize before sending and
        # before comparing against GET results, or dedup silently fails to match an
        # existing rule and re-POSTs into the same priority, causing a 409 Conflict.
        service = rule.get("service")
        service = service.upper() if service else service
        request = rule.get("request")
        request = request.upper() if request else request

        payload = {
            "priority": rule["priority"],
            "access": grant,
            "workspace": rule["workspace"],
        }
        if username:
            # geoserver-acl's Rule DTO calls this field "user" on the wire (its own
            # OpenAPI model), even though our catalog schema calls it "username" to
            # match GeoServer's own terminology — see
            # https://github.com/geoserver/geoserver-acl web-api Rule.java.
            payload["user"] = username
        else:
            payload["role"] = role
        if layer is not None:
            payload["layer"] = layer
        if service is not None:
            payload["service"] = service
        if request is not None:
            payload["request"] = request

        # GET /rules returns the full flat JSON array (no pagination wrapper); find any
        # existing rule with the same identifying criteria (role/username, workspace,
        # layer, service, request) — service/request must participate in the match so a
        # narrow Transaction-only rule is never mistaken for (or overwrites) a broader
        # rule on the same role/workspace/layer.
        resp = self.acl_client.get(f"{self.acl_base}/rules")
        resp.raise_for_status()
        existing = [
            r for r in resp.json()
            if r.get("role") == role
            and r.get("user") == username
            and r.get("workspace") == rule["workspace"]
            and r.get("layer") == layer
            and r.get("service") == service
            and r.get("request") == request
        ]

        if existing:
            rule_id = existing[0]["id"]
            r = self.acl_client.patch(f"{self.acl_base}/rules/id/{rule_id}", json=payload)
        else:
            r = self.acl_client.post(f"{self.acl_base}/rules", json=payload)
        r.raise_for_status()
