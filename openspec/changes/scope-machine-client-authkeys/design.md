## Context

The first pass at machine/API client support wired GeoServer's `auth-key` extension
end-to-end (filter, chains, user, key) but authorized it by granting a single shared
GeoServer role (`ROLE_WILDLIFE_EDITOR`, default) to a single generic user
(`machine_client_username`) via Terraform + a bash-script REST call. That design was
rejected before merge: a shared role can't scope one client to one workspace/dataset —
every principal holding the role gets the grant, and every new machine client either
needs its own new role (defeating the point of "shared") or reuses an existing one and
inherits its access.

`geoserver-acl` is a separate, DB-backed authorization microservice (not part of
GeoServer core) with its own REST API (`{acl_base}/rules`) whose Rule DTO supports a
`username` field as an alternative to `role` — confirmed via the upstream
`geoserver-acl` REST API docs. That's the mechanism this change adopts.

## Goals / Non-Goals

**Goals:**
- Provision N independent machine-client identities (authentication), each with its own
  key, via Terraform + `configure-geoserver-security.sh`.
- Grant each identity access to exactly the workspace/layer it needs (authorization) via
  a `username`-scoped rule in `geo-server-app-config/catalog/acl_rules.yaml`, with zero
  role-granting in Terraform or the bash script.
- Keep the two concerns (authn vs authz) in the two systems that already own them:
  Terraform/script own GeoServer's own security config; `geo-server-app-config` owns
  everything reconciled through REST against GeoServer + geoserver-acl.

**Non-Goals:**
- Building a UI or self-service flow for provisioning machine clients (see prior
  discussion — IaC was chosen deliberately over a DB/UI-driven flow for reproducibility).
- Key rotation/expiry automation, or a decommissioning/revocation runbook (see Risks).
- Grouping machine clients (rejected — each is a synthetic per-key identity with no
  reason to be organized into a group; groups solve a multi-real-user problem this
  design doesn't have).
- Fixing or deepening the READ/WRITE/ADMIN semantics gap identified below — flagged for
  a follow-up change, not solved here.

## Decisions

**One shared authKey filter/mapper, N users.** `PropertyAuthenticationKeyMapper` maps
many `key=username` lines in one `authkeys.properties` file to one filter config. Only
the filter's chain wiring (`default`+`gwc`, never `web`/`rest`) is shared infrastructure;
each username's line is independent and additive.

**`username` as an alternative to `role` on `AclRule`, not an addition to it.** A
`model_validator(mode="after")` enforces exactly one of the two — this keeps every rule
unambiguously scoped to either "every holder of this role" or "this one principal," with
no rule that's accidentally both or neither.

**One Key Vault secret per username** (`geoserver-machine-authkey-<username>`), not one
shared secret. `null_resource.secret_geoserver_machine_authkey` moved from `count` to
`for_each` over `var.machine_client_usernames` (a `toset()`) — this is what makes adding
a client additive (a new list entry) rather than requiring a new Terraform resource block.

**Terraform module boundary:** `infra/stack/variables.tf` / `main.tf` own identity
provisioning only. No Terraform resource ever calls `/rest/security/roles/...` or
`/rest/security/roles/role/{role}/user/{user}` for machine clients — that entire
capability was deleted from `configure-geoserver-security.sh`, not just left unused.

## Risks / Trade-offs

**[Fixed in this change, residual verification open] READ vs WRITE was not enforced at
the ACL layer the way the catalog schema implied.** `geoserver_client.py`'s
`_ACCESS_MAP` collapses `READ`/`WRITE`/`ADMIN` all to the same geoserver-acl `GrantType`
(`ALLOW`) — the distinction that actually matters to geoserver-acl (an ALLOW rule that
covers only read-type OWS requests vs one that also covers `Transaction`) is expressed
via the Rule DTO's `service`/`request` fields. The original `acl_rules.yaml` never set
them: the priority-10 `role: ROLE_AUTHENTICATED`/`access: READ` rule had no
`service`/`request` constraint, so — assuming geoserver-acl's rule matching is
"lowest-priority-number rule whose *set* fields all match wins" (the geoserver-acl /
GeoFence convention: lower number = higher precedence) — that rule's lack of a request
restriction meant it matched a WFS-T `Transaction` request too, granting write access to
*any* authenticated user before the priority-20/25 WRITE rules were ever consulted.

**Fix applied:** `AclRule` gained optional `service`/`request` fields (plumbed through
`ensure_acl_rule`'s payload and its existing-rule dedup match), and `acl_rules.yaml` was
reordered/extended to: (5) `username`-scoped machine WRITE ALLOW, (15) editor-role WRITE
ALLOW, (18) a narrow `service: WFS, request: Transaction` DENY for `ROLE_AUTHENTICATED`,
(20) the broad READ ALLOW. See `geo-server-app-config/README.md`'s "Priority ordering
and service/request scoping" section for the full ordering rationale.

**Residual, unresolved:** this fix's correctness still rests on the assumption that
geoserver-acl evaluates rules in ascending-priority-first order — the same assumption
the original (flawed) configuration implicitly made, just in the opposite direction. Unit
tests (`test_acl_rules.py`) confirm the payload/dedup logic is correct, and the existing
`test_authkey_username_rule_grants_wfst_write` integration test confirms the
username-scoped ALLOW rule (priority 5) still grants the machine client write access.
Neither exercises the new priority-18 DENY rule, because doing so needs a *plain*
`ROLE_AUTHENTICATED` test principal (no editor role, no machine authkey) — no such
identity currently exists in this project (`gw` authenticates as `admin_user`, which
carries `ROLE_ADMINISTRATOR` and is not a meaningful stand-in: GeoServer administrators
generally bypass geoserver-acl entirely). Provisioning a dedicated low-privilege test
user is a bigger change (new Terraform/script identity, or an OIDC test fixture) than
this ACL-config fix and was judged out of scope here — tracked as tasks.md 6.1.

**[Moderate, unresolved] No decommissioning/rotation path.** Removing a username from
`machine_client_usernames` deletes its Key Vault secret (Terraform-managed) but nothing
removes its GeoServer user, its line in `authkeys.properties`, or its rule in
`acl_rules.yaml` — both `configure-geoserver-security.sh` and `geoserver-apply` are
additive/idempotent (`ensure_*`) and never prune. A leaked or retired key stays valid
until someone manually deletes the user, edits `authkeys.properties`, and removes the
YAML rule. Not solved here; needs its own change if this becomes operationally relevant.

**[Minor, unresolved] Cross-workspace denial is untested.** Only the `wildlife`
workspace has ACL rules/layers populated (`forestry`/`lands` exist in
`workspaces.yaml` but have no layers or rules yet), so there's no live layer to prove
`svc-machine-wildlife`'s key is *actually* rejected for a workspace it isn't scoped to —
the current test coverage proves the grant it *does* have works, not that the absence of
a grant elsewhere is enforced.

**Breaking Terraform variable rename.** `var.machine_client_username` (string) →
`var.machine_client_usernames` (list) is a breaking rename; any environment that already
set the old variable (via `.tfvars` or a CI-level `TF_VAR_*`) needs that reference
updated before the next apply. No live environment currently sets it, per project state
at the time of this change.
