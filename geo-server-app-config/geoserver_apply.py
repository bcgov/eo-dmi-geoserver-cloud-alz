"""Typer CLI entry point.

Resolves named references (kv://, tf://) into concrete values, then hands
off to reconcile.apply(). Deliberately avoids string templating — see
docs/anti-patterns.md (or ask the architect why).
"""
from __future__ import annotations
import json
import os
import re
import subprocess
from pathlib import Path

import typer
import yaml

from reconcile import load_catalog, apply

app = typer.Typer(add_completion=False, no_args_is_help=True)

_KV_RE = re.compile(r"^kv://(?P<vault>[^/]+)/(?P<secret>[^/]+)$")
_TF_RE = re.compile(r"^tf://(?P<output>[A-Za-z_][A-Za-z0-9_]*)$")


# ---------- Resolvers ----------
def _resolve_kv(vault: str, secret: str, cache: dict) -> str:
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient
    from azure.core.exceptions import ClientAuthenticationError, ResourceNotFoundError

    key = f"kv://{vault}/{secret}"
    if key in cache:
        return cache[key]
    try:
        cred = DefaultAzureCredential(exclude_interactive_browser_credential=False)
        client = SecretClient(f"https://{vault}.vault.azure.net/", cred)
        val = client.get_secret(secret).value
        cache[key] = val
        return val
    except ClientAuthenticationError as e:
        raise typer.BadParameter(
            f"Failed to authenticate to Key Vault '{vault}': {e}. "
            "Ensure DefaultAzureCredential can reach the vault (OIDC/az login)."
        )
    except ResourceNotFoundError:
        raise typer.BadParameter(
            f"Secret not found in Key Vault '{vault}': {secret}. "
            "Verify the secret exists and the vault name is correct."
        )


def _resolve_tf(output_name: str, stack_dir: Path, cache: dict) -> str:
    key = f"tf://{output_name}"
    if key in cache:
        return cache[key]
    try:
        raw = subprocess.check_output(
            ["terraform", f"-chdir={stack_dir}", "output", "-json", output_name],
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        raise typer.BadParameter(
            f"Terraform output '{output_name}' not found or not accessible. "
            f"Run 'terraform -chdir={stack_dir} output' to see available outputs.\n"
            f"Error: {e.stderr}"
        )
    try:
        val = json.loads(raw)
    except json.JSONDecodeError as e:
        raise typer.BadParameter(
            f"Terraform output '{output_name}' is not valid JSON: {e}"
        )
    if not isinstance(val, str):
        raise typer.BadParameter(
            f"Terraform output '{output_name}' must be a string, "
            f"got {type(val).__name__}: {val}. "
            f"Use 'terraform -chdir={stack_dir} output {output_name}' to inspect."
        )
    cache[key] = val
    return val


def _resolve_string(value: str, stack_dir: Path, cache: dict) -> str:
    m = _KV_RE.match(value)
    if m:
        return _resolve_kv(m["vault"], m["secret"], cache)
    m = _TF_RE.match(value)
    if m:
        return _resolve_tf(m["output"], stack_dir, cache)
    return value


def _resolve(obj, stack_dir: Path, cache: dict):
    if isinstance(obj, dict):
        return {k: _resolve(v, stack_dir, cache) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_resolve(v, stack_dir, cache) for v in obj]
    if isinstance(obj, str):
        return _resolve_string(obj, stack_dir, cache)
    return obj


# ---------- CLI ----------
@app.command()
def run(
    env: str = typer.Argument(..., help="dev | test | prod"),
    catalog_dir: Path = typer.Option(Path("catalog"), "--catalog-dir"),
    env_dir: Path = typer.Option(Path("environments"), "--env-dir"),
    stack_dir: Path = typer.Option(Path("../stack"), "--stack-dir"),
    dry_run: bool = typer.Option(False, "--dry-run", "-n"),
):
    """Reconcile GeoServer against the catalog YAML for <env>."""
    env_file = env_dir / f"{env}.yaml"
    if not env_file.exists():
        raise typer.BadParameter(f"environment file not found: {env_file}")

    env_cfg_raw = yaml.safe_load(env_file.read_text())
    env_cfg = _resolve(env_cfg_raw, stack_dir, cache={})

    bundle = load_catalog(catalog_dir)
    apply(env_cfg, bundle, styles_dir=catalog_dir / "styles", dry_run=dry_run)


@app.command()
def validate(
    catalog_dir: Path = typer.Option(Path("catalog"), "--catalog-dir"),
):
    """Parse + validate the catalog without contacting any external service."""
    bundle = load_catalog(catalog_dir)
    styles_dir = catalog_dir / "styles"
    known_styles = {p.stem for p in styles_dir.glob("*.sld")} if styles_dir.exists() else None
    bundle.validate_references(known_styles=known_styles)
    print(
        f"OK: {len(bundle.workspaces)} workspaces, "
        f"{len(bundle.postgis_stores)} stores, "
        f"{len(bundle.feature_types)} layers, "
        f"{len(bundle.layer_groups)} groups, "
        f"{len(bundle.acl_rules)} ACL rules"
    )


if __name__ == "__main__":
    app()
