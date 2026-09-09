# GeoServer Cloud Integration Tests

These tests exercise a deployed environment through the public proxy and the
private gateway. They are not unit tests and they do not create an isolated
GeoServer stack.

## Test Groups

| File | Coverage |
| --- | --- |
| `test_01_proxy.py` | Proxy health, browser redirects, API `401`, and machine passthrough behavior. |
| `test_02_ows.py` | WMS, WFS, WCS, WPS, and GWC route availability. |
| `test_03_catalog.py` | Workspaces, stores, layers, and catalog visibility. |
| `test_04_rendering.py` | WMS images and WFS feature responses. |
| `test_05_security.py` | Anonymous denial, authenticated access, REST protection, and machine-client ACL behavior. |

## Prerequisites

- Python 3.14 and the pinned `uv` version from `mise.toml`.
- Azure CLI with an active login.
- Access to the target subscription, Key Vault, Terraform outputs, and the
  Bastion tunnel target.
- A running SOCKS5 tunnel on port `8228` by default.
- A deployed environment with the catalog data expected by the tests.

Open the tunnel before running tests:

```bash
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <bastion-resource-group> \
  --target-resource-id <jumpbox-resource-id> \
  --resource-port 22 \
  --port 8228
```

The test client sends both public proxy and private gateway traffic through the
SOCKS5 tunnel. `socks5` is used for the local tunnel. The Key Vault helper uses
proxy-side DNS resolution.

## Installation

From `integration-tests/`:

```bash
uv pip install -e .
```

If the package is already installed, `python -m pytest` is sufficient.

## Environment Variables

All values are optional when Terraform state and Azure access are available.

| Variable | Purpose |
| --- | --- |
| `GATEWAY_URL` | Override the gateway URL instead of reading Terraform output. |
| `PROXY_APP_URL` | Override the public proxy URL instead of reading Terraform output. |
| `GS_ADMIN_USER` | GeoServer Basic user. Default: `admin`. |
| `GS_ADMIN_PASS` | GeoServer admin password. If unset, read from Key Vault. |
| `KV_NAME` | Key Vault name. If unset, derive it from Terraform output. |
| `SOCKS5_PORT` | Local tunnel port. Default: `8228`. |
| `REQUEST_TIMEOUT` | Per-request timeout in seconds. Default: `30`. |
| `TF_TIMEOUT` | Terraform output timeout in seconds. Default: `60`. |
| `MACHINE_CLIENT_TEST_USERNAME` | Machine client username. Default: `svc-machine-wildlife`; empty skips authkey tests. |
| `MACHINE_CLIENT_AUTHKEY` | Override the machine authkey. If unset, read the per-user Key Vault secret. |

Do not put passwords or authkeys in shell history or commit them to the
repository.

## Run Tests

Run the complete suite:

```bash
python -m pytest
```

Run one group:

```bash
python -m pytest test_01_proxy.py
python -m pytest test_05_security.py
```

Run one test:

```bash
python -m pytest test_05_security.py::TestRESTApiSecurity::test_rest_workspaces_unauthenticated_is_401
```

The suite uses `follow_redirects=False` so authentication decisions can be
verified directly. It uses Basic auth for the authenticated gateway fixture and
no credentials for the anonymous fixture.

## Test Data Assumptions

The current tests assume:

- `wildlife:veg_comp_poly` exists.
- The `wildlife` workspace and PostGIS store are present.
- `ROLE_AUTHENTICATED` can read the configured wildlife layer through ACL.
- The machine user `svc-machine-wildlife` and its Key Vault authkey exist when
  machine-client tests are enabled.
- The gateway exposes the `/geoserver/cloud` base path.

If the catalog changes, update the test assumptions or document the new fixture.

## Expected Results

- OWS service exceptions may use HTTP `200` with an OGC ExceptionReport. Inspect
  the response body, not only the status code.
- REST unauthenticated requests should return HTTP `401`.
- The proxy should return `302` for browser HTML requests and `401` for API
  requests without a session.
- Invalid Basic credentials must not return successful protected data.

## Troubleshooting

- `SOCKS5 proxy not reachable`: open the Bastion tunnel on the configured port.
- Terraform output failure: run `terraform -chdir=../infra/stack output` and
  confirm the selected environment has been applied.
- Key Vault failure: renew `az login` and confirm Key Vault access.
- `401` from the proxy: check the expected session or machine passthrough setting.
- OWS ExceptionReport: check ACL rules and the layer catalog.
- Machine authkey failure on only some requests: restart the OWS/GWC replicas
  after a machine-user or authkey data change.

## CI Status

The current GitHub Actions workflows do not run this suite. Treat it as a
manual environment validation suite until a workflow explicitly makes it a
release gate.
