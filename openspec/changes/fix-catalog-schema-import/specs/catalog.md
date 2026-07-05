# Delta Specs: Fix catalog-schema import collision

## ADDED Requirements

### Requirement: Unambiguous catalog-schema module name
The project's Pydantic catalog schema module MUST have a name that cannot be
shadowed by any PyPI package present in the standard GeoServer Cloud Python
environment.

#### Scenario: Import succeeds after `pip install -e .`
- GIVEN the `geo-server-app-config` package installed via `pip install -e .`
- AND the `schema` PyPI package present in site-packages (transitively)
- WHEN `geoserver-apply validate --catalog-dir geo-server-app-config/catalog` runs
- THEN the command imports `CatalogBundle` without `ImportError`

#### Scenario: CI validate step passes
- GIVEN the CI workflow running `pip install --quiet -e geo-server-app-config/`
- WHEN `geoserver-apply validate --catalog-dir geo-server-app-config/catalog` executes
- THEN the process exits 0 and prints the catalog summary line

## MODIFIED Requirements

### Requirement: Module listed in wheel `only-include`
The renamed module file MUST be included in the Hatchling wheel build target
so the installable package remains self-contained.
(Previously: `catalog_schema.py` was listed; now `geoserver_catalog_schema.py` must be listed.)
