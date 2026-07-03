"""
Shared fixtures for GeoServer Cloud integration tests.

All network calls route through the Bastion SOCKS5 tunnel so this module
can reach both private (gateway, KV) and public (App Service proxy) endpoints
from the same client.

Environment overrides (all optional — values fall back to terraform output):
  GATEWAY_URL       Full gateway base URL
  PROXY_APP_URL     App Service OIDC proxy URL
  GS_ADMIN_USER     GeoServer admin username  (default: admin)
  GS_ADMIN_PASS     GeoServer admin password  (bypasses KV lookup)
  KV_NAME           Key Vault name            (bypasses terraform output)
  SOCKS5_PORT       Bastion tunnel port       (default: 8228)
  REQUEST_TIMEOUT   Per-request timeout in seconds (default: 30)
  TF_TIMEOUT        Seconds to wait for terraform output (default: 60)
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
from pathlib import Path

import httpx
import pytest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).parent.parent
_STACK_DIR = _REPO_ROOT / "stack"

SOCKS5_PORT = int(os.getenv("SOCKS5_PORT", "8228"))
_SOCKS_URL = f"socks5://127.0.0.1:{SOCKS5_PORT}"
_REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "30"))

# On Windows, az and terraform are installed to locations Git Bash adds to
# PATH but the uv venv subprocess does not inherit. Probe the common spots.
_EXTRA_PATH_DIRS = [
    Path(os.environ.get("USERPROFILE", "")) / "AppData/Local/Microsoft/WinGet/Links",
    Path("C:/Program Files/Microsoft SDKs/Azure/CLI2/wbin"),
    Path("C:/Program Files/Terraform"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _augmented_env() -> dict[str, str]:
    """Return os.environ with az/terraform directories prepended to PATH,
    and HTTPS_PROXY set to the Bastion SOCKS5 tunnel."""
    env = os.environ.copy()

    extra = [str(p) for p in _EXTRA_PATH_DIRS if p.is_dir()]
    if extra:
        env["PATH"] = os.pathsep.join(extra) + os.pathsep + env.get("PATH", "")

    env["HTTPS_PROXY"] = _SOCKS_URL
    env["HTTP_PROXY"] = _SOCKS_URL
    env["https_proxy"] = _SOCKS_URL
    env["http_proxy"] = _SOCKS_URL
    env.setdefault(
        "NO_PROXY",
        "management.azure.com,login.microsoftonline.com,graph.microsoft.com,"
        "registry.terraform.io,releases.hashicorp.com,github.com,"
        "objects.githubusercontent.com,169.254.169.254",
    )
    return env


def _find_exe(name: str) -> str:
    """Locate an executable, searching extra Windows paths if needed."""
    env = _augmented_env()
    path = shutil.which(name, path=env["PATH"])
    if path:
        return path
    # Windows: try .cmd / .exe suffixes explicitly in known dirs
    for d in _EXTRA_PATH_DIRS:
        for suffix in ("", ".cmd", ".exe"):
            candidate = d / f"{name}{suffix}"
            if candidate.is_file():
                return str(candidate)
    pytest.exit(
        f"Cannot find '{name}' on PATH. "
        "Install it or set the relevant environment variable to skip the lookup.",
        returncode=3,
    )


def _check_socks_tunnel() -> None:
    try:
        with socket.create_connection(("127.0.0.1", SOCKS5_PORT), timeout=3):
            pass
    except OSError as exc:
        pytest.exit(
            f"SOCKS5 proxy not reachable on localhost:{SOCKS5_PORT}. "
            "Open the Bastion tunnel first:\n"
            f"  az network bastion tunnel --name <name> --resource-group <rg> "
            f"--target-resource-id <vm-id> --resource-port 22 --port {SOCKS5_PORT}\n"
            f"(error: {exc})",
            returncode=3,
        )


def _tf_output(key: str) -> str:
    terraform = _find_exe("terraform")
    env = _augmented_env()
    env["TF_VAR_scripts_dir"] = str(_REPO_ROOT / "scripts")

    result = subprocess.run(
        [terraform, "output", "-raw", key],
        cwd=str(_STACK_DIR),
        capture_output=True,
        text=True,
        timeout=int(os.getenv("TF_TIMEOUT", "60")),
        env=env,
    )
    if result.returncode != 0:
        pytest.exit(
            f"`terraform output -raw {key}` failed.\n"
            f"  stderr: {result.stderr.strip()}\n"
            "  Run `terraform init` from stack/ if state is not initialised.",
            returncode=3,
        )
    value = result.stdout.strip()
    if not value:
        pytest.exit(
            f"`terraform output -raw {key}` returned an empty value. "
            "Has the stack been applied?",
            returncode=3,
        )
    return value


def _fetch_kv_secret(kv_name: str, secret_name: str) -> str:
    """Fetch a KV secret via `az keyvault secret show`.

    Uses `socks5h://` (proxy-side DNS resolution) so the private endpoint FQDN
    is resolved inside the VNet through the Bastion tunnel.
    """
    az = _find_exe("az")
    env = _augmented_env()
    # KV has a private endpoint — DNS must resolve inside the VNet.
    # socks5h:// tells the SOCKS5 client to forward the hostname to the proxy
    # for resolution rather than resolving locally (where the private DNS zone
    # is not registered).
    socks5h = _SOCKS_URL.replace("socks5://", "socks5h://")
    env["HTTPS_PROXY"] = socks5h
    env["HTTP_PROXY"] = socks5h
    env["https_proxy"] = socks5h
    env["http_proxy"] = socks5h

    result = subprocess.run(
        [
            az, "keyvault", "secret", "show",
            "--vault-name", kv_name,
            "--name", secret_name,
            "--query", "value",
            "--output", "tsv",
        ],
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    if result.returncode != 0:
        pytest.exit(
            f"Failed to fetch '{secret_name}' from Key Vault '{kv_name}'.\n"
            f"  {result.stderr.strip()}\n"
            "  Ensure `az login` is current and you hold 'Key Vault Secrets User' on the vault.",
            returncode=3,
        )
    return result.stdout.strip()


def _make_client(
    base_url: str,
    *,
    auth: tuple[str, str] | None = None,
    verify: bool = False,
) -> httpx.Client:
    return httpx.Client(
        base_url=base_url.rstrip("/"),
        auth=auth,
        proxy=_SOCKS_URL,
        verify=verify,
        timeout=_REQUEST_TIMEOUT,
        follow_redirects=False,
    )


# ---------------------------------------------------------------------------
# Session-scoped fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def socks_tunnel() -> None:
    _check_socks_tunnel()


@pytest.fixture(scope="session")
def gateway_url() -> str:
    return (os.getenv("GATEWAY_URL") or _tf_output("gateway_url")).rstrip("/")


@pytest.fixture(scope="session")
def proxy_app_url() -> str:
    return os.getenv("PROXY_APP_URL") or _tf_output("proxy_url")


@pytest.fixture(scope="session")
def kv_name() -> str:
    if name := os.getenv("KV_NAME"):
        return name
    uri = _tf_output("key_vault_uri")
    return uri.removeprefix("https://").split(".")[0]


@pytest.fixture(scope="session")
def admin_password(kv_name: str) -> str:
    if pw := os.getenv("GS_ADMIN_PASS"):
        return pw
    return _fetch_kv_secret(kv_name, "geoserver-admin-password")


@pytest.fixture(scope="session")
def admin_user() -> str:
    return os.getenv("GS_ADMIN_USER", "admin")


@pytest.fixture(scope="session")
def gw(gateway_url: str, admin_user: str, admin_password: str) -> httpx.Client:
    """Authenticated httpx client targeting the private GeoServer gateway."""
    with _make_client(gateway_url, auth=(admin_user, admin_password)) as client:
        yield client


@pytest.fixture(scope="session")
def gw_anon(gateway_url: str) -> httpx.Client:
    """Unauthenticated httpx client targeting the private GeoServer gateway."""
    with _make_client(gateway_url) as client:
        yield client


@pytest.fixture(scope="session")
def proxy_client(proxy_app_url: str) -> httpx.Client:
    """httpx client for the public OIDC proxy App Service (TLS verified)."""
    with _make_client(proxy_app_url, verify=True) as client:
        yield client
