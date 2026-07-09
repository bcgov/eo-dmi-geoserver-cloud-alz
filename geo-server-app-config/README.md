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

## ACL rules: role vs. username scoping

Each entry in `catalog/acl_rules.yaml` sets exactly one of `role` or `username`
(enforced by `AclRule`'s validator) — never both, never neither:

- `role` — applies to every principal holding that role (e.g. every IDIR user
  authenticated via OIDC through `ROLE_AUTHENTICATED`).
- `username` — applies to exactly one principal. Used for machine/API clients
  (GeoServer `authkey` identities provisioned by
  `infra/scripts/configure-geoserver-security.sh` +
  `var.machine_client_usernames`), so one client's grant is confined to the
  workspace/layer its own rule names — it can never be widened just because
  another machine client happens to share a role.

Authentication (does this authkey resolve to a real user?) and authorization
(what can that user do?) are handled by two separate systems: Terraform/the
script only ever create the identity; this file, reconciled via
`geoserver-apply run <env>`, is the only place access is granted.

### Priority ordering and `service`/`request` scoping

`priority` follows the geoserver-acl/GeoFence convention: **lower number = evaluated
first = higher precedence.** Every authenticated principal (editors and machine clients
included) also holds GeoServer's implicit `ROLE_AUTHENTICATED`, so a broad
`ROLE_AUTHENTICATED` rule with no `service`/`request` set matches *every* OWS operation
for its workspace — including a WFS-T `Transaction` — not just reads. `access: READ` is
a catalog-level label; it does not by itself restrict which OWS operations a rule
matches. To make READ vs WRITE actually enforced, rules must be ordered:

1. Specific `ALLOW` rules (`username` or an editor `role`) — lowest numbers, checked first.
2. A narrow `DENY` for the write-capable operation (e.g. `service: WFS`,
   `request: Transaction`) scoped to the broad role — catches everyone the specific
   ALLOW rules above didn't already match.
3. The broad `READ` `ALLOW` — highest number, catches remaining (read) requests.

See `catalog/acl_rules.yaml` for the current ordering and
`openspec/changes/scope-machine-client-authkeys/design.md` for the full analysis of why
an unscoped READ rule can otherwise make a WRITE rule redundant.

### Decommissioning a machine client

Provisioning is additive/idempotent end-to-end — nothing here prunes automatically, so
retiring a machine client (a leaked key, an offboarded integration) is a **manual,
three-place** cleanup. Removing it from only one place leaves the credential live.

1. **Remove the ACL grant** — delete or comment out its `username`-scoped rule(s) in
   `catalog/acl_rules.yaml`, then run `geoserver-apply run <env>`. This tool never
   deletes rules automatically (see `ensure_acl_rule` — PATCH/POST only), so you must call
   the geoserver-acl REST API directly: `DELETE {acl_base}/rules/id/{id}` (find the id via
   `GET {acl_base}/rules`, matching on `username`).
2. **Remove the GeoServer user** — the identity still resolves and authenticates even
   with no ACL grant (it would just be denied everywhere). Delete it via
   `DELETE {geoserver_base}/rest/security/usergroup/service/default/users/<username>.json`
   (`UG_SERVICE` defaults to `default`, per `configure-geoserver-security.sh`). This also
   removes its line from `authkeys.properties`.
3. **Remove it from Terraform** — drop the username from `var.machine_client_usernames`
   and `terraform apply`. This deletes the Key Vault secret
   `geoserver-machine-authkey-<username>` (the credential itself), but **does nothing
   to GeoServer** — steps 1 and 2 above are not implied by this and must be done first
   (or the key keeps working against a GeoServer that was never told to forget it).

Do these in the order above (ACL grant, then GeoServer user, then Terraform/secret) so
the credential stops being *useful* before it stops *existing* — if a rotation script
runs steps out of order, a stale-but-still-valid key is worse than a revoked one nobody
can retrieve. There is no automation for this yet (tracked as a follow-up in
`openspec/changes/scope-machine-client-authkeys/tasks.md`).

## Tests

```bash
cd geo-server-app-config
uv sync --group dev && uv run pytest tests/ -v   # or: pip install pytest && pytest tests/ -v
```

Unit tests only — no network, no live GeoServer/ACL required. They cover the
`AclRule` role/username validation and `ensure_acl_rule`'s payload-building
and POST-vs-PATCH dedup logic (`geoserver_client.py`) via a mocked ACL client.

## CI integration

Run `geoserver-apply run <env>` after the Terraform apply step in
`.github/workflows/cd-<env>.yml`. The same OIDC federated identity used by
Terraform can read Key Vault and reach the Gateway over the internal LB
(requires a VNet-attached runner — see `docs/runbook.md` hardening notes).

## Local runs

`local-run.sh` already opens a Bastion SOCKS5 tunnel and exports
`HTTPS_PROXY`. `httpx` honours that automatically — no code changes needed.
