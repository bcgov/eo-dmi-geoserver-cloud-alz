"""
Tests for the Node OIDC proxy App Service (public endpoint).

Verifies health, unauthenticated browser redirect behaviour (contract §5),
and that API clients without a session receive 401 rather than an HTML redirect.
"""

import httpx


class TestOidcProxy:
    def test_healthz(self, proxy_client: httpx.Client) -> None:
        """Health endpoint always returns 200 with no auth required."""
        r = proxy_client.get("/healthz")
        assert r.status_code == 200
        assert r.json() == {"status": "ok"}

    def test_root_browser_redirects(self, proxy_client: httpx.Client) -> None:
        """`GET /` with a browser Accept header returns 302 (courtesy redirect to GeoServer web UI)."""
        r = proxy_client.get("/", headers={"Accept": "text/html"})
        assert r.status_code == 302

    def test_geoserver_path_unauthenticated_browser_redirects_to_login(
        self, proxy_client: httpx.Client
    ) -> None:
        """Browser hitting a GeoServer path without a session is redirected to /auth/login."""
        r = proxy_client.get(
            "/geoserver/cloud/web/",
            headers={"Accept": "text/html"},
        )
        assert r.status_code == 302
        assert "/auth/login" in r.headers.get("location", "")

    def test_geoserver_path_unauthenticated_api_returns_401(
        self, proxy_client: httpx.Client
    ) -> None:
        """API client (no `text/html` Accept) hitting a GeoServer path gets 401, not a redirect."""
        r = proxy_client.get(
            "/geoserver/cloud/wms",
            headers={"Accept": "application/json"},
        )
        assert r.status_code == 401
        assert r.json().get("error") == "unauthenticated"

    def test_machine_auth_passthrough_disabled_by_default(
        self, proxy_client: httpx.Client
    ) -> None:
        """A request with a Basic header but no valid session must NOT bypass OIDC (passthrough is off)."""
        r = proxy_client.get(
            "/geoserver/cloud/wms",
            headers={"Authorization": "Basic dXNlcjpwYXNz"},  # user:pass, unverified
        )
        # Must get 401 (non-HTML API rule) or 302 (HTML redirect rule),
        # never 200 — which would mean the request reached GeoServer unauthenticated.
        assert r.status_code in (302, 401), (
            f"Expected 302 or 401 (OIDC gate), got {r.status_code}. "
            "MACHINE_AUTH_PASSTHROUGH may still be enabled."
        )
