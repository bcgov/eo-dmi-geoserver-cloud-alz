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
