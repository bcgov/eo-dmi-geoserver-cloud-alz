"""Load the catalog YAML and reconcile it against a GeoServer instance."""
from __future__ import annotations
from pathlib import Path
import httpx
import yaml

from schema import CatalogBundle
from geoserver_client import GeoServerClient


_FILE_TO_KEY = {
    "workspaces.yaml":   "workspaces",
    "stores.yaml":       "postgis_stores",
    "layers.yaml":       "feature_types",
    "layer_groups.yaml": "layer_groups",
    "acl_rules.yaml":    "acl_rules",
}


def _err_detail(e: Exception) -> str:
    """Append the server's response body to HTTP errors — status codes alone
    hide the actual GeoServer/ACL validation message needed to debug failures."""
    if isinstance(e, httpx.HTTPStatusError):
        body = e.response.text.strip().replace("\n", " ")[:300]
        return f"{e} | body: {body}" if body else str(e)
    return str(e)


def load_catalog(catalog_dir: Path) -> CatalogBundle:
    data: dict = {k: [] for k in _FILE_TO_KEY.values()}
    for fname, key in _FILE_TO_KEY.items():
        f = catalog_dir / fname
        if f.exists():
            doc = yaml.safe_load(f.read_text()) or {}
            data[key].extend(doc.get(key, []))
    return CatalogBundle.model_validate(data)


def apply(
    env_cfg: dict,
    bundle: CatalogBundle,
    styles_dir: Path,
    dry_run: bool = False,
) -> None:
    # Validate catalog cross-references before attempting any network calls.
    # Pass known_styles so style references are checked against actual SLD files on disk.
    known_styles = {p.stem for p in styles_dir.glob("*.sld")} if styles_dir.exists() else None
    bundle.validate_references(known_styles=known_styles)

    gs = GeoServerClient(
        base_url=env_cfg["gateway_url"],
        user=env_cfg["admin_user"],
        password=env_cfg["admin_password"],
        timeout=env_cfg["http"]["timeout_seconds"],
    )

    # Health check with exponential backoff (30 attempts, up to 30s between tries).
    if not dry_run:
        print("[health] Waiting for GeoServer to be ready...")
        try:
            version_text = gs.wait_healthy()
            print(f"[health] OK: {version_text.strip()[:80]}...")
        except Exception as e:
            raise RuntimeError(
                f"GeoServer did not become healthy. Is the Gateway running? {e}"
            )

    # Configure ACL client only when the acl section is present and complete.
    if "acl" in env_cfg:
        acl_cfg = env_cfg["acl"]
        gs.set_acl_base(
            acl_base_url=acl_cfg["base_url"],
            acl_user=acl_cfg["admin_user"],
            acl_password=acl_cfg["admin_password"],
        )

    stats = {"ws": 0, "store": 0, "style": 0, "layer": 0, "group": 0, "acl": 0, "err": 0}

    for ws in bundle.workspaces:
        print(f"[ws]     {ws.name}")
        if not dry_run:
            try:
                gs.ensure_workspace(ws.name, str(ws.namespace_uri), ws.isolated)
                stats["ws"] += 1
            except Exception as e:
                print(f"[error]  workspace {ws.name}: {_err_detail(e)}")
                stats["err"] += 1

    for s in bundle.postgis_stores:
        conn = env_cfg["postgis_stores"][s.connection]
        print(f"[store]  {s.workspace}/{s.name} -> {conn['host']}/{conn['database']}")
        if not dry_run:
            try:
                gs.ensure_postgis_store(s.workspace, s.name, conn, s.model_dump())
                stats["store"] += 1
            except Exception as e:
                print(f"[error]  store {s.workspace}/{s.name}: {_err_detail(e)}")
                stats["err"] += 1

    # Styles before layers so default_style references resolve
    if styles_dir.exists():
        for sld in sorted(styles_dir.glob("*.sld")):
            print(f"[style]  {sld.stem}")
            if not dry_run:
                try:
                    gs.ensure_sld_style(sld.stem, sld.read_text())
                    stats["style"] += 1
                except Exception as e:
                    print(f"[error]  style {sld.stem}: {_err_detail(e)}")
                    stats["err"] += 1

    for ft in bundle.feature_types:
        print(f"[layer]  {ft.workspace}:{ft.name}")
        if not dry_run:
            try:
                gs.ensure_feature_type(ft.workspace, ft.store, ft.model_dump())
                stats["layer"] += 1
            except Exception as e:
                print(f"[error]  layer {ft.workspace}:{ft.name}: {_err_detail(e)}")
                stats["err"] += 1

    for lg in bundle.layer_groups:
        print(f"[group]  {lg.workspace}:{lg.name}")
        if not dry_run:
            try:
                gs.ensure_layer_group(lg.model_dump())
                stats["group"] += 1
            except Exception as e:
                print(f"[error]  group {lg.workspace}:{lg.name}: {_err_detail(e)}")
                stats["err"] += 1

    for r in bundle.acl_rules:
        print(f"[acl]    p={r.priority} role={r.role} {r.workspace}:{r.layer} -> {r.access}")
        if not dry_run:
            if gs.acl_client is None:
                print(f"[warn]   no ACL service configured - skipping {len(bundle.acl_rules)} rule(s)")
                break
            try:
                gs.ensure_acl_rule(r.model_dump())
                stats["acl"] += 1
            except Exception as e:
                print(f"[error]  ACL rule p={r.priority}: {_err_detail(e)}")
                stats["err"] += 1

    dry = " (dry-run)" if dry_run else ""
    print(
        f"\n[summary{dry}] ws={stats['ws']} store={stats['store']} style={stats['style']} "
        f"layer={stats['layer']} group={stats['group']} acl={stats['acl']} err={stats['err']}"
    )
    if stats["err"] > 0:
        raise RuntimeError(f"Catalog reconciliation failed: {stats['err']} error(s)")
