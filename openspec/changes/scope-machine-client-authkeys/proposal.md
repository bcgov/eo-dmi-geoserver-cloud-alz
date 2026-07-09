# Proposal: Per-workspace scoped machine/API client authentication + authorization

## Why

Machine/API clients (non-interactive callers of GeoServer's OWS services — WMS/WFS/WCS/WPS)
need credentials that are scoped to exactly the workspace/dataset they consume, not a single
shared identity whose access grows every time a new client is added. The first implementation
of authkey support instead provisioned one generic machine user and granted it a shared
GeoServer role (`ROLE_WILDLIFE_EDITOR`) via Terraform + a bash script — any other machine
client added later would either need its own role (proliferating roles 1:1 with clients, which
is what a shared-role design is supposed to avoid) or would reuse the existing role and inherit
its access. This was caught before merge: authorization needs to be scoped per identity, not
per role, and GeoServer's own security subsystem has no such concept — it lives in the
separate `geoserver-acl` microservice instead.

## What Changes

- Terraform (`infra/stack/variables.tf`, `main.tf`) now provisions **N** named machine-client
  identities (`var.machine_client_usernames`, a list) instead of one, each with its own
  generated Key Vault secret (`geoserver-machine-authkey-<username>`). **BREAKING**: replaces
  `var.machine_client_username` (string) and removes `var.machine_client_roles` entirely —
  Terraform no longer grants roles to machine users.
- `infra/scripts/configure-geoserver-security.sh` step 6 loops over
  `MACHINE_CLIENT_USERNAMES`, creating one GeoServer user + one `authkeys.properties` line per
  name behind a single shared `authKey` filter/mapper. The role-association block is deleted.
- `geo-server-app-config`'s `AclRule` schema gains a `username` field as an alternative to
  `role` (exactly one of the two required). `ensure_acl_rule` builds and dedups on whichever is
  set. `catalog/acl_rules.yaml` gains a `username`-scoped WRITE rule for `svc-machine-wildlife`.
- Authorization for machine clients now lives entirely in
  `geo-server-app-config/catalog/acl_rules.yaml`, reconciled via `geoserver-apply run <env>` —
  never granted by Terraform or the bash script.
- Unit tests (`geo-server-app-config/tests/test_acl_rules.py`) and an integration test
  (`TestAuthKeyMachineClient::test_authkey_username_rule_grants_wfst_write`) cover the new
  scoping end to end.

## Capabilities

### New Capabilities
- `machine-client-auth`: provisioning of authentication-only identities (GeoServer `authkey`
  users) for machine/API clients, one per workspace/dataset consumer, with no implicit
  authorization.

### Modified Capabilities
- `catalog`: `AclRule` now supports scoping a rule to a single `username` as an alternative to
  a `role`, so authorization can be granted to one specific machine-client identity without
  widening a shared role.

## Impact

- **Terraform**: `infra/stack/variables.tf`, `infra/stack/main.tf` — variable rename
  (breaking for any existing `.tfvars`/CI variable using the old name), `for_each` KV-secret
  resource, env vars passed to the security script.
- **Scripts**: `infra/scripts/configure-geoserver-security.sh` — step 6 rework, Verify section.
- **Python**: `geo-server-app-config/geoserver_catalog_schema.py`,
  `geo-server-app-config/geoserver_client.py`, `geo-server-app-config/reconcile.py`,
  `geo-server-app-config/catalog/acl_rules.yaml`, new `geo-server-app-config/tests/`.
- **Tests**: `integration-tests/conftest.py`, `integration-tests/test_05_security.py`.
- **Docs**: `docs/node-oidc-proxy-contract.md`, `geo-server-app-config/README.md`.
- **BC Gov ALZ compliance**: no networking/tag/OIDC changes — this is purely GeoServer-internal
  auth/authz. No new GitHub Environments or secrets; existing per-env Key Vault gains one
  secret per configured machine-client username (was already one secret before this change,
  just under a per-username name now instead of a single fixed name).
