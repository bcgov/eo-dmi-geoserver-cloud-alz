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
        """Sending a Basic header to a GeoServer path must NOT bypass OIDC.

        MACHINE_AUTH_PASSTHROUGH defaults to false. An unverified Basic header
        must not grant access — the request must hit the OIDC gate (302 or 401).
        """
        r = proxy_client.get(
            "/geoserver/cloud/wms",
            headers={"Authorization": "Basic dXNlcjpwYXNz"},  # user:pass (invalid)
        )
        assert r.status_code != 200, (
            f"Got HTTP 200 — MACHINE_AUTH_PASSTHROUGH appears to be enabled. "
            "Set MACHINE_AUTH_PASSTHROUGH=false in the App Service config."
        )
