"""
Tests that the catalog bootstrapped by geoserver-apply exists in GeoServer.

Verifies: workspaces, PostGIS datastore, feature type, layer group, and SLD style.
These must all be present after a successful `./local-run.sh apply` with CATALOG_ENV set.
"""

import httpx
import pytest


class TestWorkspaces:
    @pytest.mark.parametrize("ws", ["wildlife", "forestry", "lands"])
    def test_workspace_exists(self, gw: httpx.Client, ws: str) -> None:
        r = gw.get(f"/rest/workspaces/{ws}.json")
        assert r.status_code == 200, f"workspace '{ws}' not found (HTTP {r.status_code})"

    def test_workspaces_list_contains_all_three(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces.json")
        assert r.status_code == 200
        names = {w["name"] for w in r.json()["workspaces"]["workspace"]}
        assert {"wildlife", "forestry", "lands"}.issubset(names)


class TestDataStore:
    def test_wildlife_postgis_store_exists(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/datastores/wildlife_postgis.json")
        assert r.status_code == 200

    def test_wildlife_postgis_store_is_postgis(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/datastores/wildlife_postgis.json")
        body = r.json()
        entry = body["dataStore"]["connectionParameters"]["entry"]
        dbtype = next(
            (e["$"] for e in entry if e["@key"] == "dbtype"), None
        )
        assert dbtype == "postgis", f"expected dbtype=postgis, got {dbtype!r}"

    def test_wildlife_postgis_store_uses_ssl(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/datastores/wildlife_postgis.json")
        body = r.json()
        entry = body["dataStore"]["connectionParameters"]["entry"]
        ssl = next(
            (e["$"] for e in entry if e["@key"] == "SSL mode"), None
        )
        assert ssl == "require", f"expected SSL mode=require, got {ssl!r}"


class TestLayers:
    def test_veg_comp_poly_layer_exists(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/layers/veg_comp_poly.json")
        assert r.status_code == 200

    def test_veg_comp_poly_has_default_style(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/layers/wildlife:veg_comp_poly.json")
        assert r.status_code == 200
        style_name = r.json()["layer"]["defaultStyle"]["name"]
        assert style_name == "basic_polygon", f"expected style 'basic_polygon', got {style_name!r}"


class TestLayerGroup:
    def test_wildlife_overview_group_exists(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/layergroups/wildlife_overview.json")
        assert r.status_code == 200

    def test_wildlife_overview_contains_veg_layer(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/workspaces/wildlife/layergroups/wildlife_overview.json")
        body = r.json()
        published = body["layerGroup"]["publishables"]["published"]
        if isinstance(published, dict):
            published = [published]
        names = [p["name"] for p in published]
        assert any("veg_comp_poly" in n for n in names), (
            f"expected veg_comp_poly in layer group, got {names}"
        )


class TestStyles:
    def test_basic_polygon_style_exists(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/styles/basic_polygon.json")
        assert r.status_code == 200

    def test_basic_polygon_style_is_sld(self, gw: httpx.Client) -> None:
        r = gw.get("/rest/styles/basic_polygon.sld")
        assert r.status_code == 200
        assert "StyledLayerDescriptor" in r.text
