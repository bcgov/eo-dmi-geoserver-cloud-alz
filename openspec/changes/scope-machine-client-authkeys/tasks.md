## 1. Terraform infra

- [x] 1.1 Replace `var.machine_client_username` (string) with `var.machine_client_usernames` (list) in `infra/stack/variables.tf`
- [x] 1.2 Remove `var.machine_client_roles` entirely — no role-granting variable
- [x] 1.3 Convert `null_resource.secret_geoserver_machine_authkey` from `count` to `for_each` over `toset(var.machine_client_usernames)`, one secret `geoserver-machine-authkey-<username>` each
- [x] 1.4 Update `configure_geoserver_security`'s triggers/env vars: `MACHINE_CLIENT_USERNAMES = join(",", var.machine_client_usernames)`, drop `MACHINE_CLIENT_ROLES`
- [x] 1.5 `terraform validate` passes

## 2. Security script

- [x] 2.1 Rework `infra/scripts/configure-geoserver-security.sh` step 6 to loop over `MACHINE_CLIENT_USERNAMES`, fetching one KV secret and creating one GeoServer user per name
- [x] 2.2 Keep a single shared `authKey` filter/mapper and `default`+`gwc` chain wiring (unchanged infra, shared across all usernames)
- [x] 2.3 Delete the role-association block (create role / associate role-to-user REST calls) entirely
- [x] 2.4 Update the Verify section to loop per-username
- [x] 2.5 `bash -n` syntax check passes

## 3. Python catalog (geo-server-app-config)

- [x] 3.1 Add `username: Optional[str]` to `AclRule`, with a `model_validator` enforcing exactly one of `role`/`username`
- [x] 3.2 Update `ensure_acl_rule` to build the wire payload from whichever of `role`/`username` is set, and dedup existing rules on the same combination
- [x] 3.3 Fix `reconcile.py`'s ACL logging line to print `username=` when `role` is unset (previously always printed `role=None`)
- [x] 3.4 Add a `username`-scoped WRITE rule for `svc-machine-wildlife` to `catalog/acl_rules.yaml`
- [x] 3.5 Add `pytest` as a dev dependency (`[dependency-groups] dev`)
- [x] 3.6 Add `geo-server-app-config/tests/test_acl_rules.py`: schema validation (role-only, username-only, both, neither) and `ensure_acl_rule` payload/dedup logic against a mocked ACL client
- [x] 3.7 `pytest tests/ -v` passes (10/10)

## 4. Integration tests

- [x] 4.1 Update `conftest.py`'s `machine_client_username`/`machine_client_authkey` fixtures for per-username KV secret naming (`geoserver-machine-authkey-<username>`), defaulting to `svc-machine-wildlife`
- [x] 4.2 Add `test_authkey_username_rule_grants_wfst_write` — a schema-agnostic, zero-side-effect WFS-T Delete (matches no real feature) proving the username-scoped rule grants WRITE
- [x] 4.3 `py_compile` / import check passes on updated test files

## 5. Docs

- [x] 5.1 Rework `docs/node-oidc-proxy-contract.md` §5 to describe the authn (Terraform/script) vs authz (ACL catalog) split, replacing the old "granted whatever roles `var.machine_client_roles` lists" language
- [x] 5.2 Update §11 reference to `var.machine_client_usernames` and the ACL catalog tool
- [x] 5.3 Add an "ACL rules: role vs. username scoping" + "Tests" section to `geo-server-app-config/README.md`

## 6. Follow-up

- [x] 6.1a Add `service`/`request` fields to `AclRule` and plumb them through `ensure_acl_rule`'s payload + existing-rule dedup match (`geoserver_catalog_schema.py`, `geoserver_client.py`)
- [x] 6.1b Reorder `catalog/acl_rules.yaml`: username/editor WRITE ALLOW rules now at priority 5/15 (checked first), a new narrow `service: WFS, request: Transaction` DENY for `ROLE_AUTHENTICATED` at priority 18, broad READ ALLOW at priority 20 — closes the gap where the broad READ rule had no request restriction and could match a WFS-T Transaction
- [x] 6.1c Add unit test coverage for service/request payload passthrough and dedup-matching (`test_acl_rules.py`)
- [x] 6.1d Document the priority-ordering convention and the fix's rationale (`geo-server-app-config/README.md`, `design.md`)
- [ ] 6.1e **Residual, not done in this change**: empirically confirm the priority-18 DENY actually blocks a plain `ROLE_AUTHENTICATED` (non-editor, non-machine) principal — needs a dedicated low-privilege test identity that doesn't exist yet (`gw` is `admin_user`/`ROLE_ADMINISTRATOR`, which bypasses geoserver-acl and isn't a valid stand-in). Provisioning one is a bigger change than this ACL-config fix.
- [ ] 6.2 Populate ACL rules/layers for a second workspace (`forestry` or `lands`) so a real cross-workspace-denial test can be written — blocked on that workspace having real layers/stores, not an auth-scoping change
- [x] 6.3a Document a decommissioning/rotation runbook for machine-client identities (remove ACL rule, remove GeoServer user, remove `authkeys.properties` line, remove from `machine_client_usernames`) — see `geo-server-app-config/README.md` "Decommissioning a machine client"
- [ ] 6.3b Automate the runbook (currently fully manual, three separate systems) — not done, tracked as future work
- [ ] 6.4 **Documented gap, not fixed**: `GeoServerClient._ACCESS_MAP` (`geo-server-app-config/geoserver_client.py`) maps `READ`/`WRITE`/`ADMIN` all to the same geoserver-acl `ALLOW` grant — `DENY` is the only value that actually differs. geoserver-acl's Rule DTO has no separate read/write/admin permission levels; the catalog's READ/WRITE/ADMIN vocabulary is a human-readable label only. Actual narrowing to "read-only" or "write-only" must come from the `service`/`request` fields (as used for the priority-18 `service: WFS, request: Transaction` DENY rule in 6.1b) or from priority-ordering against a separate DENY rule — writing `access: READ` in `acl_rules.yaml` does **not**, by itself, block write operations. Worth a docstring/README callout so future rule authors don't assume `READ` is self-enforcing; not scoped as a functional fix here.

## 7. Authkey propagation across OWS pods (bug fix)

- [x] 7.1 **Root cause**: geoserver-cloud's `CloudGeoServerSecurityManager` only broadcasts service-CONFIG change events over the event bus, never user/group DATA changes (new users, authkey property edits). `/rest/reload` only reloads the single pod that receives the HTTP request. Result: a new machine-client authkey written via `configure-geoserver-security.sh` was only usable on whichever `wms`/`wfs`/`wcs`/`wps`/`gwc` pod happened to serve the reload call — every other independently-scaled replica kept serving stale `users.xml` until its own restart.
- [x] 7.2 Investigated and rejected a JDBC-backed `UserGroupService`/roles store as the "real" fix (would propagate via shared DB instead of in-memory XML) — infeasible on the stock geoserver-cloud OWS images used by this deployment; not revisited this change.
- [x] 7.3 Implemented restart-based propagation instead: `configure-geoserver-security.sh` now tracks whether any user/authkey data actually changed (`authkey_data_changed`), and if so, force-restarts the `wms`/`wfs`/`wcs`/`wps`/`gwc` Container Apps via the Azure ARM REST API (`restart_ows_services()`) so each pod reboots and re-reads `users.xml` fresh. Idempotent — a repeat run with no data changes skips the restart.
- [x] 7.4 Added `RESOURCE_GROUP` as a required env var (only when `MACHINE_CLIENT_USERNAMES` is set) and wired it through `infra/stack/main.tf`'s `configure_geoserver_security` null_resource.
- [x] 7.5 One-time manual catch-up restart of the already-running pods (deployed before this fix existed, so never picked up a correct restart) — operational step, not part of the idempotent script logic.
- [x] 7.6 Verified via integration tests: `test_authkey_grants_ows_read` and `test_authkey_username_rule_grants_wfst_write` now pass (previously failing due to stale pod state).

## 8. [INCIDENT] Anonymous REST API bypasses `rest.properties` ADMIN requirement

- [x] 8.1 **Discovered** while chasing the (pre-existing, previously-deferred) `test_authkey_does_not_authenticate_rest_api` failure: anonymous requests (zero credentials) to `/rest/workspaces` through the gateway succeed for both read and write. Live-verified: anonymous `POST /rest/workspaces` returned 201 and genuinely persisted a workspace (confirmed via subsequent admin GET and in the full admin workspace list); cleaned up via admin `DELETE`. This is despite `security/rest.properties` requiring `ADMIN` for all `/rest/**` GET/HEAD/POST/DELETE/PUT, and the `rest` filter chain in `security/config.xml` naming an `interceptorName="interceptor"` that should enforce it.
- [x] 8.2 **Root cause research** (read-only, via GitHub source of `geoserver/geoserver-cloud`): not a missing dependency or misconfiguration on our part. geoserver-cloud issue #80 ("Bring authentication and authorization to the front service (gateway)") explicitly documents the upstream design intent to remove default security chains from internal services and enforce authN/Z at the gateway — the per-microservice `interceptor` filter chain being ineffective on the `restconfig`/OWS pods is consistent with that architectural direction, not a simple bug. The `gateway` Container App in this repo is currently a pure router with no REST-authorization enforcement of its own, so nothing fills the gap upstream intentionally left open.
- [x] 8.3 **Severity context**: the Container Apps Environment has `internal_load_balancer_enabled = true`, so the gateway is VNet-internal only, not internet-facing. Blast radius is anything with VNet reachability (Bastion/jumpbox, other workloads on the VNet) — not the public internet.
- [x] 8.4 Attempted network-level mitigation: added `ip_security_restriction` rules to the gateway's ingress (Azure Container Apps), allow-listing only the Node OIDC proxy's VNet-integration subnet and the Bastion jumpbox subnet. **Reverted** — this also blocked legitimate traffic including the Node OIDC proxy itself; the actual source IP the gateway observes for Bastion-tunnel/proxy traffic did not match the expected subnet CIDRs (root cause not diagnosed — `ContainerAppHTTPLogs` has no data for this environment, and widening the rule further to diagnose was correctly blocked as an unapproved loosening of a live security control mid-incident). All `ip_security_restriction` Terraform code (module variable/dynamic block, stack variables/locals/tfvars) was removed; the gateway currently has **no network-level ingress restriction**.
- [ ] 8.5 **Current mitigation: none applied.** Accepted as a documented, known gap for now: the anonymous REST bypass is reachable by any VNet-internal actor. All external/public access is required to go through the Node OIDC proxy → gateway path, where the proxy is the authentication boundary — this incident does not affect that path's authentication (OIDC login is unaffected), only direct-to-gateway REST calls from within the VNet.
- [ ] 8.6 **Deferred as separate work**: fix GeoServer's REST authorization at the source — either get the per-pod `interceptor` filter chain actually enforcing `rest.properties` on `restconfig`/OWS pods, or implement REST-authorization enforcement at the `gateway` app itself (the architecturally-intended location per issue #80). Not scoped into this change.
