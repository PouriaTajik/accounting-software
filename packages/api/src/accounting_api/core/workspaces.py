"""Workspaces -- the tenant boundary.

`create_workspace` is the one function in `core` that does not take a
workspace-scoped connection: there is no workspace yet to scope it to. It
takes a connection from `Database.provision()` instead, authenticated as the
table owner (see db/README.md). Every other function here takes the usual
workspace-scoped connection, same as every other module in this package.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any
from uuid import UUID

from ..errors import VersionConflict, WorkspaceNotFound

if TYPE_CHECKING:
    import asyncpg

_COLUMNS = """
    id, name, base_currency, fiscal_calendar,
    display_unit, display_exponent, books_locked_through, version
"""

#: Columns `update_workspace` may assign. Whitelisted rather than accepting
#: whatever keys the caller passes, since those keys become SQL identifiers.
_UPDATABLE_COLUMNS = {
    "name",
    "base_currency",
    "fiscal_calendar",
    "display_unit",
    "display_exponent",
    "books_locked_through",
}


async def create_workspace(
    connection: asyncpg.Connection,
    *,
    name: str,
    owner_user_id: UUID,
    base_currency: str = "USD",
    fiscal_calendar: str = "gregorian",
) -> dict[str, Any]:
    """Create a workspace and seat its first member as `owner`, in one
    transaction (the caller's `db.provision()` block already opened one).

    Without this, a freshly created workspace would have no owner at all --
    `workspace_members`'s own "keep at least one owner" trigger (migration
    0003) only guards demotions and removals, not a workspace that starts
    with zero members. Role enforcement (`deps.require_role`) has nothing to
    check the first time a workspace exists unless this is atomic with
    creating it.
    """
    row = await connection.fetchrow(
        f"""
        INSERT INTO workspaces (name, base_currency, fiscal_calendar)
        VALUES ($1, $2, $3)
        RETURNING {_COLUMNS}
        """,
        name,
        base_currency,
        fiscal_calendar,
    )
    await connection.execute(
        "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'owner')",
        row["id"],
        owner_user_id,
    )
    return dict(row)


async def _get_or_raise(connection: asyncpg.Connection, workspace_id: UUID) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"SELECT {_COLUMNS} FROM workspaces WHERE id = $1", workspace_id
    )
    if row is None:
        raise WorkspaceNotFound(
            f"workspace {workspace_id} not found",
            entity="workspace",
            entity_id=str(workspace_id),
        )
    return dict(row)


async def get_workspace(connection: asyncpg.Connection, workspace_id: UUID) -> dict[str, Any]:
    return await _get_or_raise(connection, workspace_id)


async def update_workspace(
    connection: asyncpg.Connection,
    workspace_id: UUID,
    *,
    expected_version: int,
    **fields: Any,
) -> dict[str, Any]:
    """Edit a workspace, or raise `VersionConflict` carrying the current row.

    `fields` is expected to already be scoped to what the caller actually
    sent (e.g. via `model_dump(exclude_unset=True)`) -- unlike a plain
    None-filter, this lets a caller clear a nullable column (`display_unit`,
    `books_locked_through`) by sending it as `null`, rather than that being
    indistinguishable from omitting it.
    """
    unknown = set(fields) - _UPDATABLE_COLUMNS
    if unknown:
        raise ValueError(f"not updatable: {', '.join(sorted(unknown))}")

    if not fields:
        return await _get_or_raise(connection, workspace_id)

    assignments = ", ".join(f"{column} = ${i}" for i, column in enumerate(fields, start=3))
    row = await connection.fetchrow(
        f"""
        UPDATE workspaces
           SET {assignments}
         WHERE id = $1 AND version = $2
        RETURNING {_COLUMNS}
        """,
        workspace_id,
        expected_version,
        *fields.values(),
    )
    if row is not None:
        return dict(row)

    current = await _get_or_raise(connection, workspace_id)
    raise VersionConflict("workspace", workspace_id, expected_version, current=current)
