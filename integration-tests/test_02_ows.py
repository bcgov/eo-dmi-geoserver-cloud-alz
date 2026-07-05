"""
Tests for OWS service endpoints (WMS, WFS, WCS, WPS, GWC) via the private gateway.

All requests route through the Bastion SOCKS5 tunnel (see conftest.py).
"""

import httpx
import pytest


class TestGatewayConnectivity:
    def test_rest_version(self, gw: httpx.Client) -> None:
        """Gateway REST /about/version is reachable and returns GeoServer version info."""
        r = gw.get("/rest/about/version")
        assert r.status_code == 200
        body = r.text
        assert "GeoServer" in body or "version" in body.lower()


class TestWMS:
    def test_get_capabilities_200(self, gw: httpx.Client) -> None:
        r = gw.get("/wms", params={"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetCapabilities"})
        assert r.status_code == 200

    def test_get_capabilities_is_xml(self, gw: httpx.Client) -> None:
        r = gw.get("/wms", params={"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetCapabilities"})
        assert "text/xml" in r.headers.get("content-type", "") or \
               "application/vnd.ogc.wms_xml" in r.headers.get("content-type", "")

    def test_get_capabilities_contains_wms_root(self, gw: httpx.Client) -> None:
        r = gw.get("/wms", params={"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetCapabilities"})
        assert "WMS_Capabilities" in r.text


class TestWFS:
    def test_get_capabilities_200(self, gw: httpx.Client) -> None:
        r = gw.get("/wfs", params={"SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetCapabilities"})
        assert r.status_code == 200

    def test_get_capabilities_contains_wfs_root(self, gw: httpx.Client) -> None:
        r = gw.get("/wfs", params={"SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetCapabilities"})
        assert "WFS_Capabilities" in r.text


class TestWCS:
    def test_get_capabilities_200(self, gw: httpx.Client) -> None:
        r = gw.get("/wcs", params={"SERVICE": "WCS", "VERSION": "2.0.1", "REQUEST": "GetCapabilities"})
        assert r.status_code == 200


class TestWPS:
    def test_get_capabilities_200(self, gw: httpx.Client) -> None:
        r = gw.get("/wps", params={"SERVICE": "WPS", "REQUEST": "GetCapabilities"})
        assert r.status_code == 200


class TestGWC:
    def test_layers_endpoint_200(self, gw: httpx.Client) -> None:
        """/gwc/rest/layers is the GeoWebCache health/list endpoint in GeoServer Cloud 3.x."""
        r = gw.get("/gwc/rest/layers")
        assert r.status_code == 200

    def test_seeding_service_reachable(self, gw: httpx.Client) -> None:
        """/gwc/service/wms?REQUEST=GetCapabilities returns 400 (missing required params) not 404."""
        r = gw.get("/gwc/service/wms", params={"REQUEST": "GetCapabilities"})
        # 400 means the GWC WMS service is running but we didn't supply a required LAYER param.
        assert r.status_code in (200, 400)
