"""Unit tests for username-scoped ACL rules (no network — GeoServer/ACL are mocked).

Covers the schema validation and payload-building added so a machine/API client
(one GeoServer authkey identity) can get an ACL rule scoped to exactly its own
workspace/layer via `username`, instead of a shared `role` grant that every
other machine client would also inherit.
"""
from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import yaml
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from geoserver_catalog_schema import AclRule, CatalogBundle  # noqa: E402
from geoserver_client import GeoServerClient  # noqa: E402

CATALOG_DIR = Path(__file__).resolve().parent.parent / "catalog"


class TestAclRuleValidation:
    def test_role_only_is_valid(self) -> None:
        rule = AclRule(priority=10, role="ROLE_AUTHENTICATED", workspace="wildlife", access="READ")
        assert rule.role == "ROLE_AUTHENTICATED"
        assert rule.username is None

    def test_username_only_is_valid(self) -> None:
        rule = AclRule(priority=25, username="svc-machine-wildlife", workspace="wildlife", access="WRITE")
        assert rule.username == "svc-machine-wildlife"
        assert rule.role is None

    def test_both_role_and_username_rejected(self) -> None:
        with pytest.raises(ValidationError, match="exactly one of role/username"):
            AclRule(
                priority=1,
                role="ROLE_AUTHENTICATED",
                username="svc-machine-wildlife",
                workspace="wildlife",
                access="READ",
            )

    def test_neither_role_nor_username_rejected(self) -> None:
        with pytest.raises(ValidationError, match="exactly one of role/username"):
            AclRule(priority=1, workspace="wildlife", access="READ")

    def test_real_catalog_acl_rules_yaml_parses_and_validates(self) -> None:
        """Regression guard: catalog/acl_rules.yaml must stay schema-valid."""
        data = yaml.safe_load((CATALOG_DIR / "acl_rules.yaml").read_text())
        rules = [AclRule(**r) for r in data["acl_rules"]]
        assert any(r.username == "svc-machine-wildlife" for r in rules), (
            "Expected the svc-machine-wildlife machine-client rule to still be present."
        )

    def test_full_catalog_bundle_validates_references(self) -> None:
        """acl_rules.yaml's workspace must exist in workspaces.yaml (bundle-level check)."""
        bundle_data = {
            "workspaces": yaml.safe_load((CATALOG_DIR / "workspaces.yaml").read_text())["workspaces"],
            "acl_rules": yaml.safe_load((CATALOG_DIR / "acl_rules.yaml").read_text())["acl_rules"],
        }
        bundle = CatalogBundle(**bundle_data)
        bundle.validate_references()  # must not raise


class TestEnsureAclRulePayload:
    def _client_with_mock_acl(self, existing_rules: list[dict]) -> GeoServerClient:
        gs = GeoServerClient.__new__(GeoServerClient)  # skip __init__, no real httpx.Client needed
        gs.acl_base = "https://acl.internal.example/acl/api"
        gs.acl_client = MagicMock()
        get_resp = MagicMock()
        get_resp.json.return_value = existing_rules
        gs.acl_client.get.return_value = get_resp
        return gs

    def test_username_rule_creates_with_user_field_not_role(self) -> None:
        """catalog schema's `username` maps to the wire field `user` — geoserver-acl's
        own Rule DTO calls it `user` (confirmed against its web-api model), so sending
        `username` on the wire is silently dropped by the ACL service."""
        gs = self._client_with_mock_acl(existing_rules=[])
        gs.ensure_acl_rule({
            "priority": 25,
            "username": "svc-machine-wildlife",
            "role": None,
            "workspace": "wildlife",
            "layer": "*",
            "access": "WRITE",
        })
        gs.acl_client.post.assert_called_once()
        _, kwargs = gs.acl_client.post.call_args
        payload = kwargs["json"]
        assert payload["user"] == "svc-machine-wildlife"
        assert "username" not in payload
        assert "role" not in payload
        assert "layer" not in payload  # "*" sentinel omitted from the wire payload
        assert payload["access"] == "ALLOW"

    def test_role_rule_creates_with_role_field_not_user(self) -> None:
        gs = self._client_with_mock_acl(existing_rules=[])
        gs.ensure_acl_rule({
            "priority": 10,
            "role": "ROLE_AUTHENTICATED",
            "username": None,
            "workspace": "wildlife",
            "layer": "*",
            "access": "READ",
        })
        _, kwargs = gs.acl_client.post.call_args
        payload = kwargs["json"]
        assert payload["role"] == "ROLE_AUTHENTICATED"
        assert "user" not in payload
        assert "username" not in payload

    def test_existing_username_rule_is_updated_not_duplicated(self) -> None:
        gs = self._client_with_mock_acl(existing_rules=[
            {"id": "abc123", "role": None, "user": "svc-machine-wildlife",
             "workspace": "wildlife", "layer": None, "access": "ALLOW", "priority": 25},
        ])
        gs.ensure_acl_rule({
            "priority": 25,
            "username": "svc-machine-wildlife",
            "role": None,
            "workspace": "wildlife",
            "layer": "*",
            "access": "WRITE",
        })
        gs.acl_client.post.assert_not_called()
        gs.acl_client.patch.assert_called_once()
        args, _ = gs.acl_client.patch.call_args
        assert args[0].endswith("/rules/id/abc123")

    def test_username_rule_does_not_match_same_named_role_rule(self) -> None:
        """A role rule for the same workspace/layer must not be mistaken for this username's rule."""
        gs = self._client_with_mock_acl(existing_rules=[
            {"id": "role-rule-1", "role": "ROLE_WILDLIFE_EDITOR", "user": None,
             "workspace": "wildlife", "layer": None, "service": None, "request": None,
             "access": "ALLOW", "priority": 20},
        ])
        gs.ensure_acl_rule({
            "priority": 25,
            "username": "svc-machine-wildlife",
            "role": None,
            "workspace": "wildlife",
            "layer": "*",
            "access": "WRITE",
        })
        gs.acl_client.post.assert_called_once()  # new rule, not a PATCH of the role rule
        gs.acl_client.patch.assert_not_called()

    def test_service_and_request_are_included_in_payload_when_set(self) -> None:
        """geoserver-acl uppercases service/request regardless of input casing (a
        mixed-case value round-trips as all-caps on GET) — normalize on the way out
        too, or dedup against a later GET response silently fails to match."""
        gs = self._client_with_mock_acl(existing_rules=[])
        gs.ensure_acl_rule({
            "priority": 18,
            "role": "ROLE_AUTHENTICATED",
            "username": None,
            "workspace": "wildlife",
            "layer": "*",
            "service": "WFS",
            "request": "Transaction",
            "access": "DENY",
        })
        _, kwargs = gs.acl_client.post.call_args
        payload = kwargs["json"]
        assert payload["service"] == "WFS"
        assert payload["request"] == "TRANSACTION"
        assert payload["access"] == "DENY"

    def test_existing_rule_with_uppercased_request_is_matched_not_duplicated(self) -> None:
        """A rule created with request="Transaction" comes back from GET as "TRANSACTION"
        (geoserver-acl's own normalization) — dedup must still recognize it as the same
        rule, or every reconcile re-POSTs and collides on priority (409 Conflict)."""
        gs = self._client_with_mock_acl(existing_rules=[
            {"id": "deny-rule-1", "role": "ROLE_AUTHENTICATED", "user": None,
             "workspace": "wildlife", "layer": None, "service": "WFS",
             "request": "TRANSACTION", "access": "DENY", "priority": 18},
        ])
        gs.ensure_acl_rule({
            "priority": 18,
            "role": "ROLE_AUTHENTICATED",
            "username": None,
            "workspace": "wildlife",
            "layer": "*",
            "service": "WFS",
            "request": "Transaction",
            "access": "DENY",
        })
        gs.acl_client.post.assert_not_called()
        gs.acl_client.patch.assert_called_once()
        args, _ = gs.acl_client.patch.call_args
        assert args[0].endswith("/rules/id/deny-rule-1")

    def test_service_and_request_are_omitted_when_unset(self) -> None:
        gs = self._client_with_mock_acl(existing_rules=[])
        gs.ensure_acl_rule({
            "priority": 20,
            "role": "ROLE_AUTHENTICATED",
            "username": None,
            "workspace": "wildlife",
            "layer": "*",
            "access": "READ",
        })
        _, kwargs = gs.acl_client.post.call_args
        payload = kwargs["json"]
        assert "service" not in payload
        assert "request" not in payload

    def test_narrow_transaction_rule_does_not_match_broad_role_rule(self) -> None:
        """A service/request-scoped DENY rule must not collide with the broad READ rule
        for the same role/workspace/layer — only the exact (service, request) pair matches."""
        gs = self._client_with_mock_acl(existing_rules=[
            {"id": "broad-read", "role": "ROLE_AUTHENTICATED", "user": None,
             "workspace": "wildlife", "layer": None, "service": None, "request": None,
             "access": "ALLOW", "priority": 20},
        ])
        gs.ensure_acl_rule({
            "priority": 18,
            "role": "ROLE_AUTHENTICATED",
            "username": None,
            "workspace": "wildlife",
            "layer": "*",
            "service": "WFS",
            "request": "Transaction",
            "access": "DENY",
        })
        gs.acl_client.post.assert_called_once()  # new rule, not a PATCH of the broad READ rule
        gs.acl_client.patch.assert_not_called()
