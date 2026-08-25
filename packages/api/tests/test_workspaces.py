"""Workspaces -- the tenant boundary.

No Postgres: what is worth testing here is the part decided in Python. The
row-level security policy that makes `create_workspace` need a dedicated
owner connection at all is proven live by db/verify_rls.sql.
"""

from __future__ import annotations

import pytest

from accounting_api.config import DeploymentMode, Settings
from accounting_api.core import workspaces as workspaces_core
from accounting_api.db import Database
from accounting_api.schemas.workspaces import WorkspaceUpdate


async def test_creating_a_workspace_without_a_provisioning_url_fails_clearly() -> None:
    # accounting_app cannot make this write no matter what -- there is no
    # workspace to scope the session to yet -- so misconfiguration must fail
    # loudly here rather than surface as an opaque RLS permission error.
    database = Database(Settings(deployment_mode=DeploymentMode.LOCAL))
    with pytest.raises(RuntimeError, match="provisioning_database_url is required"):
        async with database.provision():
            pass


async def test_update_refuses_a_column_it_does_not_own() -> None:
    with pytest.raises(ValueError, match="not updatable: id"):
        await workspaces_core.update_workspace(
            None,  # never reached
            "00000000-0000-0000-0000-000000000001",
            expected_version=1,
            id="anything",
        )


def test_an_omitted_field_is_distinguished_from_an_explicit_null() -> None:
    # Unlocking the books, or dropping a display-unit shift, means sending
    # `null` for a real column -- that must survive model_dump(), not be
    # treated the same as never mentioning the field at all.
    omitted = WorkspaceUpdate(version=1)
    assert "books_locked_through" not in omitted.model_dump(exclude_unset=True)

    cleared = WorkspaceUpdate(version=1, books_locked_through=None)
    fields = cleared.model_dump(exclude={"version"}, exclude_unset=True)
    assert fields == {"books_locked_through": None}
