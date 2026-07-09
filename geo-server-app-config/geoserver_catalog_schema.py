"""Pydantic schema for the GeoServer catalog bundle.

Validation runs BEFORE any secret/output resolver, so typos and shape
errors are caught locally and in CI — long before we hit the Gateway.
"""
from __future__ import annotations
from pydantic import BaseModel, Field, HttpUrl, model_validator
from typing import List, Optional, Literal


class Workspace(BaseModel):
    name: str
    namespace_uri: HttpUrl
    isolated: bool = False


class PostgisConnection(BaseModel):
    host: str
    port: int = 5432
    database: str
    schema_: str = Field(alias="schema", default="public")
    user: str
    password: str
    ssl: Literal["require", "disable", "prefer"] = "require"

    model_config = {"populate_by_name": True}


class PostgisStore(BaseModel):
    workspace: str
    name: str
    connection: str  # references environments/<env>.yaml -> postgis_stores.<connection>
    expose_primary_keys: bool = True
    fetch_size: int = 1000
    validate_connections: bool = True


class FeatureType(BaseModel):
    workspace: str
    store: str
    name: str
    native_name: str
    title: str
    srs: str = "EPSG:3005"   # BC Albers — override per layer as needed
    enabled: bool = True
    default_style: Optional[str] = None


class LayerGroup(BaseModel):
    workspace: str
    name: str
    title: str
    mode: Literal[
        "SINGLE", "OPAQUE_CONTAINER", "NAMED", "CONTAINER", "EO"
    ] = "SINGLE"
    layers: List[str]
    styles: List[str] = []


class AclRule(BaseModel):
    """A geoserver-acl data-access rule.

    Scope by exactly one of `role` (applies to every principal holding that
    role — e.g. every IDIR user via OIDC) or `username` (applies to one
    specific principal — e.g. one machine/API client's authkey identity, so
    it can be scoped to a single workspace/layer without granting a shared
    role to every other machine client).

    `service`/`request` narrow which OWS operation a rule matches (e.g.
    service="WFS", request="Transaction"). Left unset, a rule matches every
    OWS operation for its workspace/layer — which is why a broad `READ` rule
    for a role like `ROLE_AUTHENTICATED` must never be left unscoped if a
    more specific `WRITE` rule (role or username) also grants that same
    workspace: without `service`/`request` narrowing, geoserver-acl has no
    signal that distinguishes a read-only OWS request from a WFS-T
    Transaction, so `access` alone does not enforce read-vs-write.
    """

    priority: int
    role: Optional[str] = None
    username: Optional[str] = None
    workspace: str
    layer: str = "*"
    service: Optional[str] = None
    request: Optional[str] = None
    access: Literal["READ", "WRITE", "ADMIN", "DENY"]

    @model_validator(mode="after")
    def _exactly_one_principal(self) -> "AclRule":
        if bool(self.role) == bool(self.username):
            raise ValueError(
                f"ACL rule p={self.priority} must set exactly one of role/username, "
                f"got role={self.role!r} username={self.username!r}"
            )
        return self


class CatalogBundle(BaseModel):
    workspaces: List[Workspace] = []
    postgis_stores: List[PostgisStore] = []
    feature_types: List[FeatureType] = []
    layer_groups: List[LayerGroup] = []
    acl_rules: List[AclRule] = []

    def validate_references(self, known_styles: Optional[set] = None) -> None:
        """Cross-reference validation: happens AFTER parsing but BEFORE apply.

        known_styles: set of SLD stem names on disk (passed from reconcile when
        styles_dir is available). When None, style references are not checked.
        """
        workspaces = {ws.name for ws in self.workspaces}
        stores = {(s.workspace, s.name) for s in self.postgis_stores}
        layers = {(ft.workspace, ft.name) for ft in self.feature_types}

        for s in self.postgis_stores:
            if s.workspace not in workspaces:
                raise ValueError(
                    f"Store '{s.workspace}/{s.name}' references unknown workspace '{s.workspace}'"
                )

        for ft in self.feature_types:
            if (ft.workspace, ft.store) not in stores:
                raise ValueError(
                    f"Layer '{ft.workspace}:{ft.name}' references unknown store "
                    f"'{ft.workspace}/{ft.store}'"
                )
            if ft.default_style and known_styles is not None:
                if ft.default_style not in known_styles:
                    raise ValueError(
                        f"Layer '{ft.workspace}:{ft.name}' references unknown style "
                        f"'{ft.default_style}' (no matching .sld file in styles/)"
                    )

        for lg in self.layer_groups:
            for layer_ref in lg.layers:
                if ":" not in layer_ref:
                    raise ValueError(
                        f"Layer group '{lg.workspace}:{lg.name}' references layer '{layer_ref}' "
                        f"(must be 'workspace:layer')"
                    )
                ws, name = layer_ref.split(":", 1)
                if (ws, name) not in layers:
                    raise ValueError(
                        f"Layer group '{lg.workspace}:{lg.name}' references unknown layer '{layer_ref}'"
                    )

        for r in self.acl_rules:
            if r.workspace != "*" and r.workspace not in workspaces:
                raise ValueError(
                    f"ACL rule p={r.priority} references unknown workspace '{r.workspace}'"
                )
