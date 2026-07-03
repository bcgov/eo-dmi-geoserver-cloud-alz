"""
Tests that GeoServer actually renders / serves data — not just describes it.

WMS GetMap must return an image. WFS GetFeature must return a FeatureCollection.
These tests exercise the full stack: gateway → OWS service → PostGIS → data.
"""

import httpx


class TestWMSRendering:
    def test_getmap_returns_png(self, gw: httpx.Client) -> None:
        """WMS GetMap for wildlife:veg_comp_poly returns a PNG image."""
        r = gw.get("/wms", params={
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": "wildlife:veg_comp_poly",
            "BBOX": "-139.0,48.3,-114.0,60.0",
            "CRS": "EPSG:4326",
            "WIDTH": "512",
            "HEIGHT": "512",
            "FORMAT": "image/png",
            "STYLES": "",
        })
        assert r.status_code == 200, f"GetMap failed with HTTP {r.status_code}: {r.text[:300]}"
        ct = r.headers.get("content-type", "")
        assert "image/png" in ct, f"expected image/png, got content-type: {ct}"
        # PNG magic bytes: \x89PNG
        assert r.content[:4] == b"\x89PNG", "response body is not a PNG"

    def test_getmap_layer_group_returns_png(self, gw: httpx.Client) -> None:
        """WMS GetMap for the wildlife_overview layer group also renders."""
        r = gw.get("/wms", params={
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": "wildlife:wildlife_overview",
            "BBOX": "-139.0,48.3,-114.0,60.0",
            "CRS": "EPSG:4326",
            "WIDTH": "256",
            "HEIGHT": "256",
            "FORMAT": "image/png",
            "STYLES": "",
        })
        assert r.status_code == 200
        assert "image/png" in r.headers.get("content-type", "")


class TestWFSData:
    def test_getfeature_returns_feature_collection(self, gw: httpx.Client) -> None:
        """WFS GetFeature for wildlife:veg_comp_poly returns a GeoJSON FeatureCollection."""
        r = gw.get("/wfs", params={
            "SERVICE": "WFS",
            "VERSION": "2.0.0",
            "REQUEST": "GetFeature",
            "TYPENAMES": "wildlife:veg_comp_poly",
            "COUNT": "1",
            "OUTPUTFORMAT": "application/json",
        })
        assert r.status_code == 200, f"GetFeature failed: {r.text[:300]}"
        body = r.json()
        assert body.get("type") == "FeatureCollection", (
            f"expected GeoJSON FeatureCollection, got type={body.get('type')!r}"
        )

    def test_getfeature_has_features(self, gw: httpx.Client) -> None:
        """WFS GetFeature returns at least one feature (PostGIS data is populated)."""
        r = gw.get("/wfs", params={
            "SERVICE": "WFS",
            "VERSION": "2.0.0",
            "REQUEST": "GetFeature",
            "TYPENAMES": "wildlife:veg_comp_poly",
            "COUNT": "5",
            "OUTPUTFORMAT": "application/json",
        })
        assert r.status_code == 200
        body = r.json()
        assert isinstance(body.get("features"), list), "no 'features' key in response"
        assert len(body["features"]) > 0, (
            "WFS GetFeature returned 0 features — PostGIS table may be empty "
            "or the datastore connection is broken."
        )
