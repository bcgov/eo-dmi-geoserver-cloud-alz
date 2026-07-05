# Proposal: Fix `CatalogBundle` import shadowed by `schema` PyPI package

## Summary

The CI pipeline fails during the `geoserver-apply validate` step with:

```
ImportError: cannot import name 'CatalogBundle' from 'schema'
  (.../site-packages/schema.py)
```

`reconcile.py` does `from catalog_schema import CatalogBundle`, but Python's
import machinery resolves `catalog_schema` to the third-party `schema` PyPI
package (installed transitively) instead of the project's own `catalog_schema.py`
module when the package is installed via `pip install -e .`.

## Root Cause

`hatchling`'s `[tool.hatch.build.targets.wheel] packages = ["."]` approach
includes the root directory, so all `.py` files under `geo-server-app-config/`
become top-level modules.  The transitive `schema` package also installs a
top-level `schema` module.  When Python resolves `catalog_schema`, the name
collision does *not* apply, but `schema` itself shadows our `catalog_schema`
only if there is a naming ambiguity.

Actually the root cause is simpler: `schema` (the PyPI package) ships a single
`schema.py` file at the top of `site-packages`.  `catalog_schema.py` ships our
module.  When `pip install -e .` runs, the project root is added to `sys.path`.
On Python 3.14 with the test runner's `PATH` the site-packages `schema.py` is
found first for the bare name `schema`, but `catalog_schema` should resolve
fine.  The real issue is that **`schema` is listed nowhere in our declared
dependencies** yet it is being imported transitively (likely through `pydantic`
or another dependency that also depends on `schema`).  Any `pip install` order
that resolves `schema` before our editable install runs can expose this.

Regardless of the exact resolution order, the fix is the same:
1. Rename `catalog_schema.py` → `_catalog_schema.py` (private, unambiguous), OR
2. Move the project files into a proper sub-package (`geoserver_config/`), OR
3. Keep the current name but ensure `schema` the PyPI package is NOT installed
   (it is not a direct or required transitive dependency).

**Chosen approach: rename to `catalog_schema.py` → `geoserver_catalog_schema.py`**
and update all import sites.  This is a single-file rename with three call sites
and zero API surface change.  A sub-package restructure is the right long-term
direction but is out of scope for this fix.

## Scope

- `geo-server-app-config/catalog_schema.py` → `geoserver_catalog_schema.py`
- `geo-server-app-config/reconcile.py` — update import
- `geo-server-app-config/pyproject.toml` — update `only-include` list

## Non-Goals

- Sub-package restructuring
- Changing the Pydantic schema itself
- Removing the `schema` PyPI package from the environment (not ours to control)

## Affected Teams / Environments

- CI pipeline (`ci.yml` validate step)
- Any developer running `geoserver-apply validate` locally

## Rollback Plan

`git revert` the rename commit; no infra or state changes are involved.
