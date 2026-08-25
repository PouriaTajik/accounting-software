"""Phase 1 tests: the skeleton holds together.

These run with no Postgres and no network -- that is the point of the layering,
and it is worth proving now rather than discovering later that every test needs
a database.
"""

from __future__ import annotations

import pkgutil

import pytest
from fastapi.testclient import TestClient

from accounting_api.config import DeploymentMode, Settings
from accounting_api.errors import (
    PostedEntryImmutable,
    TenantBoundaryViolation,
    UnbalancedEntry,
    VersionConflict,
    translate_database_error,
)
from accounting_api.main import API_PREFIX, create_app


@pytest.fixture
def client() -> TestClient:
    app = create_app(Settings(deployment_mode=DeploymentMode.LOCAL))
    # No lifespan: these tests must not require a database.
    return TestClient(app)


def test_health_does_not_touch_the_database(client: TestClient) -> None:
    response = client.get(f"{API_PREFIX}/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_every_router_is_registered() -> None:
    # Read the paths off the OpenAPI document rather than walking `app.routes`:
    # Starlette wraps included routers in an internal type whose shape is not
    # part of its public API, and this is what clients actually consume.
    app = create_app(Settings())
    paths = set(app.openapi()["paths"])
    for expected in (
        "/health",
        "/workspaces",
        "/accounts",
        "/journal-entries",
        "/journal-entries/{entry_id}/post",
        "/journal-entries/{entry_id}/reverse",
        "/documents",
        "/imports",
        "/categorize",
        "/anomalies",
        "/query",
    ):
        assert f"{API_PREFIX}{expected}" in paths, expected


def test_stubs_return_501_not_empty_success(client: TestClient) -> None:
    """A stub must be distinguishable from a working endpoint with no data.

    The desktop shell gets wired against these in phase 4; a 200 with an empty
    body would look like a working, empty ledger.
    """
    response = client.get(
        f"{API_PREFIX}/accounts",
        headers={"X-Workspace-Id": "00000000-0000-0000-0000-000000000001"},
    )
    assert response.status_code == 501


def test_tenant_header_is_required(client: TestClient) -> None:
    assert client.get(f"{API_PREFIX}/accounts").status_code == 400


class _FakePostgresError(Exception):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate
        self.message = message


def test_posted_entry_trigger_maps_to_409() -> None:
    error = translate_database_error(
        _FakePostgresError(
            "23001",
            "journal_entries: entry abc was posted at ... and is immutable; "
            "record a reversing entry instead.",
        )
    )
    assert isinstance(error, PostedEntryImmutable)
    assert error.status_code == 409


def test_unbalanced_trigger_maps_to_422() -> None:
    error = translate_database_error(
        _FakePostgresError("23514", "journal_entries: entry abc is unbalanced ...")
    )
    assert isinstance(error, UnbalancedEntry)


def test_tenant_boundary_is_distinguished_from_immutability() -> None:
    error = translate_database_error(
        _FakePostgresError(
            "23001",
            "accounts: workspace_id is the tenant boundary and cannot be reassigned.",
        )
    )
    assert isinstance(error, TenantBoundaryViolation)


def test_unknown_database_errors_are_not_swallowed() -> None:
    """An unrecognised failure must become a 500, not a 4xx blaming the user."""
    assert translate_database_error(_FakePostgresError("42P01", "no such table")) is None
    assert translate_database_error(ValueError("not a database error")) is None


def test_version_conflict_carries_both_sides() -> None:
    """Financial data is never auto-merged; the client must be able to show
    the user what they had and what is there now."""
    from uuid import uuid4

    entity_id = uuid4()
    payload = VersionConflict(
        "account", entity_id, expected_version=3, current={"version": 4, "name": "Cash"}
    ).to_payload()

    assert payload["code"] == "version_conflict"
    assert payload["expected_version"] == 3
    assert payload["current"]["version"] == 4


def test_core_does_not_import_a_web_framework() -> None:
    """The layering rule, enforced rather than documented.

    If `core` ever imports FastAPI, `apps/desktop` and `apps/server` have
    started to diverge and the logic is no longer testable without a server.
    """
    from accounting_api import core

    for module_info in pkgutil.iter_modules(core.__path__):
        module = __import__(f"accounting_api.core.{module_info.name}", fromlist=["_"])
        imported = set(vars(module))
        assert "FastAPI" not in imported, module_info.name
        assert "APIRouter" not in imported, module_info.name
        assert "Request" not in imported, module_info.name
