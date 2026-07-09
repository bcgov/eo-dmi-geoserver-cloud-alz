"""
Security enforcement tests.

GeoServer + geoserver-acl follow the OGC standard: service exceptions are
returned as HTTP 200 with an XML ExceptionReport body, not HTTP 401/403.
ACL enforcement is visible in two ways:

  - OWS (WFS, WMS): unauthenticated requests get HTTP 200 + ExceptionReport
    saying the layer is "unknown" (the ACL hides it from ROLE_ANONYMOUS).
  - REST management API: unauthenticated requests get HTTP 401 (Spring Security
    enforces credentials at the HTTP level, independent of ACL).

The OIDC proxy security tests verify that machine-auth passthrough is disabled.
"""

import httpx


class TestACLEnforcement:
    def test_wfs_getfeature_unauthenticated_hides_layer(
        self, gw_anon: httpx.Client
    ) -> None:
        """Unauthenticated WFS GetFeature returns OGC ExceptionReport: layer is hidden.

        geoserver-acl makes wildlife:veg_comp_poly invisible to ROLE_ANONYMOUS
        (only ROLE_AUTHENTICATED has READ). GeoServer returns HTTP 200 with an
        OWS ExceptionReport ("Feature type unknown"), per the OGC WFS standard.
        """
        r = gw_anon.get("/wfs", params={
            "SERVICE": "WFS",
            "VERSION": "2.0.0",
            "REQUEST": "GetFeature",
            "TYPENAMES": "wildlife:veg_comp_poly",
            "COUNT": "1",
            "OUTPUTFORMAT": "application/json",
        })
        assert r.status_code == 200
        assert "ExceptionReport" in r.text, (
            "Expected an OWS ExceptionReport (ACL hides the layer). "
            f"Got: {r.text[:300]}"
        )
        assert "unknown" in r.text.lower(), (
            "ExceptionReport should say the feature type is 'unknown' "
            "(ACL making it invisible to anonymous users). "
            f"Got: {r.text[:300]}"
        )

    def test_wfs_getfeature_authenticated_returns_data(
        self, gw: httpx.Client
    ) -> None:
        """Authenticated WFS GetFeature returns a real FeatureCollection, not an exception."""
        r = gw.get("/wfs", params={
            "SERVICE": "WFS",
            "VERSION": "2.0.0",
            "REQUEST": "GetFeature",
            "TYPENAMES": "wildlife:veg_comp_poly",
            "COUNT": "1",
            "OUTPUTFORMAT": "application/json",
        })
        assert r.status_code == 200
        body = r.json()
        assert body.get("type") == "FeatureCollection", (
            f"Authenticated GetFeature should return data, got: {r.text[:300]}"
        )

    def test_wms_getmap_unauthenticated_returns_exception_not_image(
        self, gw_anon: httpx.Client
    ) -> None:
        """Unauthenticated WMS GetMap returns an XML exception, not a PNG image.

        geoserver-acl hides wildlife:veg_comp_poly from ROLE_ANONYMOUS.
        GeoServer responds with a ServiceException (HTTP 200, text/xml) rather
        than the requested image/png.
        """
        r = gw_anon.get("/wms", params={
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": "wildlife:veg_comp_poly",
            "BBOX": "-139.0,48.3,-114.0,60.0",
            "CRS": "EPSG:4326",
            "WIDTH": "64",
            "HEIGHT": "64",
            "FORMAT": "image/png",
            "STYLES": "",
        })
        assert r.status_code == 200
        ct = r.headers.get("content-type", "")
        assert "image/png" not in ct, (
            "Unauthenticated GetMap returned an actual PNG — "
            "ACL access control is NOT enforced. "
            f"content-type: {ct}"
        )
        # Should be XML exception
        assert "xml" in ct or r.content[:1] == b"<", (
            f"Expected XML exception response, got content-type: {ct}"
        )

    def test_wms_getmap_authenticated_returns_image(self, gw: httpx.Client) -> None:
        """Authenticated WMS GetMap returns a PNG, not an exception."""
        r = gw.get("/wms", params={
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": "wildlife:veg_comp_poly",
            "BBOX": "-139.0,48.3,-114.0,60.0",
            "CRS": "EPSG:4326",
            "WIDTH": "64",
            "HEIGHT": "64",
            "FORMAT": "image/png",
            "STYLES": "",
        })
        assert r.status_code == 200
        assert "image/png" in r.headers.get("content-type", "")
        assert r.content[:4] == b"\x89PNG"


class TestRESTApiSecurity:
    def test_rest_workspaces_unauthenticated_is_401(self, gw_anon: httpx.Client) -> None:
        """REST /workspaces requires credentials — never publicly readable."""
        r = gw_anon.get("/rest/workspaces.json")
        assert r.status_code == 401

    def test_rest_styles_unauthenticated_is_401(self, gw_anon: httpx.Client) -> None:
        r = gw_anon.get("/rest/styles.json")
        assert r.status_code == 401

    def test_rest_datastores_unauthenticated_is_401(self, gw_anon: httpx.Client) -> None:
        r = gw_anon.get("/rest/workspaces/wildlife/datastores.json")
        assert r.status_code == 401


class TestOidcProxySecurity:
    def test_machine_auth_passthrough_off(self, proxy_client: httpx.Client) -> None:
        """Sending an *invalid* Basic header to a GeoServer path must not grant access.

        MACHINE_AUTH_PASSTHROUGH is `true` in this repo's deployed Terraform
        (infra/stack/main.tf, the proxy App Service's app_settings) — the proxy
        forwards Basic/authkey credentials to GeoServer untouched rather than
        rejecting them outright. This test still holds because the credential
        here is garbage: GeoServer itself rejects it, so the request must not
        succeed either way.
        """
        r = proxy_client.get(
            "/geoserver/cloud/wms",
            headers={"Authorization": "Basic dXNlcjpwYXNz"},  # user:pass (invalid)
        )
        assert r.status_code != 200, (
            f"Got HTTP 200 for an invalid Basic credential — GeoServer is not "
            "validating passthrough credentials as expected."
        )


class TestAuthKeyMachineClient:
    """Verifies configure-geoserver-security.sh step 6 (authkey filter) plus the
    username-scoped ACL rule in geo-server-app-config/catalog/acl_rules.yaml.

    Authentication (this authkey resolves to a real user) and authorization
    (that user's access) are two separate systems here — Terraform/the script
    only ever create the identity; geo-server-acl decides what it can do,
    driven by the `username: svc-machine-wildlife` rule (priority 5). Skipped
    automatically (via the machine_client_username/machine_client_authkey
    fixtures) in any environment where MACHINE_CLIENT_TEST_USERNAME="" or the
    corresponding KV secret is absent.
    """

    def test_authkey_grants_ows_read(
        self,
        gw_anon: httpx.Client,
        machine_client_username: str,
        machine_client_authkey: str,
    ) -> None:
        """`?authkey=<key>` on an OWS request authenticates without a session.

        Confirms auth-key is wired into the `default` chain: an otherwise-
        anonymous WMS GetMap for a layer ACL hides from ROLE_ANONYMOUS
        succeeds (real PNG) once the key resolves to an authenticated user.
        """
        r = gw_anon.get("/wms", params={
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": "wildlife:veg_comp_poly",
            "BBOX": "-139.0,48.3,-114.0,60.0",
            "CRS": "EPSG:4326",
            "WIDTH": "64",
            "HEIGHT": "64",
            "FORMAT": "image/png",
            "STYLES": "",
            "authkey": machine_client_authkey,
        })
        assert r.status_code == 200
        assert r.content[:4] == b"\x89PNG", (
            f"authkey did not authenticate the machine client ({machine_client_username}) "
            f"for OWS access — got content-type {r.headers.get('content-type')!r}: "
            f"{r.text[:300]}"
        )

    def test_authkey_does_not_authenticate_rest_api(
        self,
        gw_anon: httpx.Client,
        machine_client_username: str,
        machine_client_authkey: str,
    ) -> None:
        """`?authkey=<key>` must NOT grant access to the REST config API.

        Per GeoServer's own docs, authkey "won't work properly against...
        RESTConfig" — this is deliberate (configure-geoserver-security.sh
        wires the filter into default+gwc only, never rest). A valid key
        here must behave identically to no credentials at all: HTTP 401.
        """
        r = gw_anon.get("/rest/workspaces.json", params={"authkey": machine_client_authkey})
        assert r.status_code == 401, (
            f"authkey unexpectedly authenticated against /rest — got {r.status_code}. "
            "The authKey filter may have been wired into the rest chain by mistake."
        )

    def test_authkey_username_rule_grants_wfst_write(
        self,
        gw_anon: httpx.Client,
        machine_client_username: str,
        machine_client_authkey: str,
    ) -> None:
        """The username-scoped ACL rule (not a shared role) grants WRITE.

        Sends a WFS-T 2.0 Delete with a fes:ResourceId that matches no real
        feature — schema-agnostic (no property values needed) and a no-op
        (matches zero rows), so this can't mutate real data even on success.
        geoserver-acl evaluates WRITE authorization for Transaction requests
        before the filter is applied: a WRITE grant returns a normal
        TransactionResponse (totalDeleted=0), while anything less than WRITE
        returns an OWS ExceptionReport — same signal used elsewhere in this
        module to distinguish allowed vs. denied OWS requests.
        """
        body = """<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="2.0.0"
    xmlns:wfs="http://www.opengis.net/wfs/2.0"
    xmlns:fes="http://www.opengis.net/fes/2.0"
    xmlns:wildlife="https://geo.bc.gov.ca/wildlife">
  <wfs:Delete typeName="wildlife:veg_comp_poly">
    <fes:Filter>
      <fes:ResourceId rid="veg_comp_poly.999999999"/>
    </fes:Filter>
  </wfs:Delete>
</wfs:Transaction>"""
        r = gw_anon.post(
            "/wfs",
            params={"authkey": machine_client_authkey},
            content=body,
            headers={"Content-Type": "application/xml"},
        )
        assert r.status_code == 200
        assert "ExceptionReport" not in r.text, (
            f"WFS-T Delete was denied for machine client {machine_client_username!r} — "
            f"the username-scoped WRITE rule (acl_rules.yaml priority 5) is not "
            f"taking effect. Got: {r.text[:300]}"
        )
        assert "TransactionResponse" in r.text, (
            f"Expected a WFS TransactionResponse confirming the write was permitted. "
            f"Got: {r.text[:300]}"
        )
