# Tasks: Fix catalog-schema import collision

## Python catalog layer

- [x] 1.1 Rename `geo-server-app-config/catalog_schema.py` → `geoserver_catalog_schema.py`
- [x] 1.2 Update `geo-server-app-config/reconcile.py`: change `from catalog_schema import CatalogBundle` → `from geoserver_catalog_schema import CatalogBundle`
- [x] 1.3 Update `geo-server-app-config/pyproject.toml` `only-include`: replace `"catalog_schema.py"` with `"geoserver_catalog_schema.py"`

## Validation

- [x] 2.1 Confirm `geoserver-apply validate --catalog-dir geo-server-app-config/catalog` passes locally (or verify CI green)
