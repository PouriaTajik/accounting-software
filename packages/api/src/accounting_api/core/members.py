"""Workspace membership management -- listing, adding, changing role, removing.

Every function here takes the ordinary workspace-scoped connection
(`Database.workspace()`, accounting_app), same as `core/accounts.py` and
every other tenant-scoped module -- `workspace_members` is an ordinary
tenant table (migration 0004), not an identity table. The one thing this
module deliberately does NOT do is resolve an email to a user id: that is a
cross-tenant identity read (the target user may not be a member of anything
yet), so it belongs at the router, on `db.auth()`, the same way
`routers/workspaces.py`'s `create_workspace` needs a logged-in user rather
than smuggling identity concerns into a workspace-scoped module.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any
from uuid import UUID

from ..errors import MemberNotFound, VersionConflict

if TYPE_CHECKING:
    import asyncpg

_COLUMNS = "m.user_id, m.role, m.version, u.email, u.display_name"


async def list_members(connection: asyncpg.Connection, workspace_id: UUID) -> list[dict[str, Any]]:
    rows = await connection.fetch(
        f"""
        SELECT {_COLUMNS}
          FROM workspace_members m
          JOIN users u ON u.id = m.user_id
         WHERE m.workspace_id = $1
         ORDER BY u.email
        """,
        workspace_id,
    )
    return [dict(row) for row in rows]


async def add_member(
    connection: asyncpg.Connection, workspace_id: UUID, *, user_id: UUID, role: str
) -> dict[str, Any]:
    """Duplicate membership surfaces through the existing generic
    `DuplicateKey` mapping -- `(workspace_id, user_id)` is the table's
    primary key (migration 0003), no new mapping needed."""
    await connection.execute(
        "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, $3)",
        workspace_id,
        user_id,
        role,
    )
    row = await connection.fetchrow(
        f"""
        SELECT {_COLUMNS}
          FROM workspace_members m
          JOIN users u ON u.id = m.user_id
         WHERE m.workspace_id = $1 AND m.user_id = $2
        """,
        workspace_id,
        user_id,
    )
    return dict(row)


async def _get_or_raise(
    connection: asyncpg.Connection, workspace_id: UUID, user_id: UUID
) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"""
        SELECT {_COLUMNS}
          FROM workspace_members m
          JOIN users u ON u.id = m.user_id
         WHERE m.workspace_id = $1 AND m.user_id = $2
        """,
        workspace_id,
        user_id,
    )
    if row is None:
        raise MemberNotFound(
            f"user {user_id} is not a member of workspace {workspace_id}",
            entity="member",
            entity_id=str(user_id),
        )
    return dict(row)


async def update_member_role(
    connection: asyncpg.Connection,
    workspace_id: UUID,
    user_id: UUID,
    *,
    role: str,
    expected_version: int,
) -> dict[str, Any]:
    """Optimistic-concurrency update, same shape as
    `workspaces_core.update_workspace`. Demoting the sole remaining owner is
    rejected by `guard_workspace_keeps_an_owner` (migration 0003), surfaced
    as `LastOwnerCannotBeRemoved` by `errors.translate_database_error`."""
    row = await connection.fetchrow(
        """
        UPDATE workspace_members
           SET role = $3
         WHERE workspace_id = $1 AND user_id = $2 AND version = $4
        RETURNING user_id
        """,
        workspace_id,
        user_id,
        role,
        expected_version,
    )
    if row is not None:
        return await _get_or_raise(connection, workspace_id, user_id)

    current = await _get_or_raise(connection, workspace_id, user_id)
    raise VersionConflict("member", user_id, expected_version, current=current)


async def remove_member(connection: asyncpg.Connection, workspace_id: UUID, user_id: UUID) -> None:
    """Removing the sole remaining owner is rejected by
    `guard_workspace_keeps_an_owner` (migration 0003), surfaced as
    `LastOwnerCannotBeRemoved`."""
    result = await connection.execute(
        "DELETE FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
        workspace_id,
        user_id,
    )
    if result == "DELETE 0":
        raise MemberNotFound(
            f"user {user_id} is not a member of workspace {workspace_id}",
            entity="member",
            entity_id=str(user_id),
        )
