# GeoServer catalog-as-code

Post-Terraform reconciliation tool for **GeoServer Cloud 3.0** running on
Azure Container Apps (BC Gov ALZ). Drives the Gateway REST API to converge
workspaces, datastores, feature types, styles, layer groups, and ACL rules
against the YAML in `catalog/`.

Pairs with the Terraform stack in `../infra/stack/` — Terraform owns the platform,
this tool owns the application's domain model.

## Layout

```
geo-server-app-config/
├── environments/        # per-env settings (URLs, KV refs)
│   ├── dev.yaml
│   ├── test.yaml
│   └── prod.yaml
└── catalog/             # the desired GeoServer state
    ├── workspaces.yaml
    ├── stores.yaml
    ├── layers.yaml
    ├── layer_groups.yaml
    ├── acl_rules.yaml
    └── styles/*.sld
```

## Install

```bash
cd geo-server-app-config
uv pip install -e .      # or: pip install -e .
```

## Run

```bash
# Plan (no writes)
geoserver-apply run dev --dry-run

# Apply
geoserver-apply run dev
```

Secrets are resolved at apply time:

- `kv://<vault>/<secret>`  -> Azure Key Vault via `DefaultAzureCredential`
- `tf://<output>`          -> `terraform -chdir=../infra/stack output <name>`

No string interpolation, no Jinja, no Helm-style templating. The YAML is
validated by Pydantic *before* any resolver runs.

## CI integration

Run `geoserver-apply run <env>` after the Terraform apply step in
`.github/workflows/cd-<env>.yml`. The same OIDC federated identity used by
Terraform can read Key Vault and reach the Gateway over the internal LB
(requires a VNet-attached runner — see `docs/runbook.md` hardening notes).

## Local runs

`local-run.sh` already opens a Bastion SOCKS5 tunnel and exports
`HTTPS_PROXY`. `httpx` honours that automatically — no code changes needed.
