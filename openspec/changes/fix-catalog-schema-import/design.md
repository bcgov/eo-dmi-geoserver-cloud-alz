# Design: Rename `catalog_schema.py` to `geoserver_catalog_schema.py`

## Approach

Rename the single-file Pydantic schema module to a name that is globally unique
within the Python ecosystem and cannot clash with any known PyPI package.

### File changes

| Before | After |
|--------|-------|
| `geo-server-app-config/catalog_schema.py` | `geo-server-app-config/geoserver_catalog_schema.py` |

### Import-site changes

| File | Old import | New import |
|------|-----------|-----------|
| `geo-server-app-config/reconcile.py` | `from catalog_schema import CatalogBundle` | `from geoserver_catalog_schema import CatalogBundle` |

### Build config change

`geo-server-app-config/pyproject.toml` — `[tool.hatch.build.targets.wheel]` `only-include`:

```toml
# Before
  "catalog_schema.py",

# After
  "geoserver_catalog_schema.py",
```

## Why not a sub-package?

A proper `geoserver_config/` sub-package (with `__init__.py`) is the correct
long-term fix; it eliminates all flat-module shadowing risk.  It requires
updating imports in all five modules and potentially touching
`[project.scripts]` entry points.  That change belongs in a dedicated
refactoring change to avoid conflating a bug-fix with a structural overhaul.

## Why not remove `schema` from the environment?

`schema` is a transitive dependency of other packages and is not ours to remove.
Relying on its absence is fragile across Python versions and pip resolver runs.

## Sequence

```
pip install -e .
  └─ site-packages/schema.py  ← PyPI "schema" pkg (transitive)
     geo-server-app-config/ added to sys.path (editable install)

from geoserver_catalog_schema import CatalogBundle
  └─ resolves to: geo-server-app-config/geoserver_catalog_schema.py  ✓
     (no PyPI package named "geoserver_catalog_schema" exists)
```
