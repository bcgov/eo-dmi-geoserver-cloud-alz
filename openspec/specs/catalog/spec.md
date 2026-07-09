# Spec: GeoServer Catalog-as-Code

## Overview

The `geo-server-app-config/` package provides a catalog-as-code system that
reconciles YAML-described GeoServer resources against a live GeoServer Cloud
instance via its REST API.

## Requirements

### Requirement: Catalog validation
The system MUST be able to validate the YAML catalog offline (without network
access to GeoServer) by parsing the YAML files and checking cross-references.

#### Scenario: Clean catalog validates offline
- GIVEN a `geo-server-app-config/catalog/` directory with well-formed YAML
- WHEN `geoserver-apply validate --catalog-dir geo-server-app-config/catalog` runs
- THEN the process exits 0 and prints a summary of resource counts

#### Scenario: Broken cross-reference fails validation
- GIVEN a `layers.yaml` referencing a store name not declared in `stores.yaml`
- WHEN `geoserver-apply validate` runs
- THEN the process exits non-zero with a descriptive error naming the missing store

### Requirement: Unambiguous catalog-schema module name
The project's Pydantic catalog schema module MUST have a name that cannot be
shadowed by any PyPI package present in the standard GeoServer Cloud Python
environment.

#### Scenario: Import succeeds after `pip install -e .`
- GIVEN the `geo-server-app-config` package installed via `pip install -e .`
- AND the `schema` PyPI package present in site-packages (transitively)
- WHEN `geoserver-apply validate --catalog-dir geo-server-app-config/catalog` runs
- THEN the command imports `CatalogBundle` without `ImportError`

### Requirement: Secret resolution via kv:// and tf:// references
The system MUST resolve `kv://vault/secret` and `tf://output` references in
environment YAML before passing configuration to the reconcile layer.

### Requirement: Idempotent apply
The system MUST be idempotent: running `geoserver-apply run <env>` twice against
an already-configured GeoServer instance MUST produce the same final state
without errors.

### Requirement: ACL rules may be scoped to a single username instead of a role
An `AclRule` entry in `catalog/acl_rules.yaml` MUST set exactly one of `role` or
`username`. A `username`-scoped rule grants access to exactly one principal, independent
of any role that principal may or may not hold.

#### Scenario: A username-scoped rule validates
- WHEN an `AclRule` is defined with `username: svc-machine-wildlife` and no `role`
- THEN it passes schema validation and is treated as scoped to that one principal

#### Scenario: A rule setting both role and username is rejected
- WHEN an `AclRule` sets both `role` and `username`
- THEN schema validation fails with an error naming the offending rule's priority

#### Scenario: A rule setting neither role nor username is rejected
- WHEN an `AclRule` sets neither `role` nor `username`
- THEN schema validation fails with an error naming the offending rule's priority

### Requirement: `ensure_acl_rule` reconciles username-scoped rules idempotently
`GeoServerClient.ensure_acl_rule` MUST look up existing geoserver-acl rules by the same
combination of fields the catalog rule sets (`role` OR `username`, plus `workspace` and
`layer`) and PATCH an existing match rather than creating a duplicate.

#### Scenario: Re-applying an unchanged username-scoped rule updates, not duplicates
- GIVEN a `username: svc-machine-wildlife` rule already exists on geoserver-acl for
  `workspace: wildlife`, `layer: *`
- WHEN `geoserver-apply run <env>` runs again with the same rule in
  `catalog/acl_rules.yaml`
- THEN the existing rule is updated via `PATCH /rules/id/{id}`, and no new rule is
  created via `POST /rules`

#### Scenario: A role rule and a username rule for the same workspace/layer don't collide
- GIVEN an existing `role: ROLE_WILDLIFE_EDITOR` rule for `workspace: wildlife`
- WHEN a `username: svc-machine-wildlife` rule for the same `workspace: wildlife` is
  reconciled
- THEN it is created as a new rule (`POST /rules`), not mistaken for or merged with
  the role-scoped rule

### Requirement: ACL rules may be scoped to a specific OWS operation via service/request
An `AclRule` with neither `service` nor `request` set MUST match every OWS operation for
its workspace/layer — `access` alone (READ/WRITE/ADMIN/DENY) is a catalog-level label and
does not itself restrict which operations a rule applies to at the geoserver-acl layer.
Optionally setting `service`/`request` (e.g. `service: WFS`, `request: Transaction`)
narrows a rule to that one OWS operation.

#### Scenario: A rule with no service/request matches every operation
- GIVEN an `AclRule` with `role: ROLE_AUTHENTICATED`, `access: READ`, no `service` or
  `request` set
- WHEN it is reconciled via `ensure_acl_rule`
- THEN the wire payload omits both `service` and `request` entirely (not sent as null),
  and geoserver-acl treats it as matching any OWS operation on that workspace/layer

#### Scenario: A rule with service/request set only matches that operation
- GIVEN an `AclRule` with `role: ROLE_AUTHENTICATED`, `service: WFS`,
  `request: Transaction`, `access: DENY`
- WHEN it is reconciled via `ensure_acl_rule`
- THEN the wire payload includes `"service": "WFS"` and `"request": "Transaction"`, and
  existing-rule lookup matches only rules sharing that same (service, request) pair — a
  broader rule for the same role/workspace/layer with no service/request set MUST NOT
  be mistaken for it
