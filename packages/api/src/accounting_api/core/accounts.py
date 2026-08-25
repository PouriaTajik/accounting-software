"""Chart of accounts.

Every function takes an already workspace-scoped connection (see
`Database.workspace`); row-level security is what actually keeps one
workspace from touching another's accounts, not a `WHERE workspace_id = $1`
that a caller could forget.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any
from uuid import UUID

from ..errors import NotFound, VersionConflict

if TYPE_CHECKING:
    import asyncpg

_COLUMNS = """
    id, workspace_id, code, name, type, normal_balance,
    parent_account_id, cash_flow_category, is_archived, version
"""

#: Columns `update_account` may assign. Whitelisted rather than accepting
#: whatever keys the caller passes, since those keys become SQL identifiers.
_UPDATABLE_COLUMNS = {"code", "name", "parent_account_id", "cash_flow_category"}


async def list_accounts(
    connection: asyncpg.Connection, *, include_archived: bool = False
) -> list[dict[str, Any]]:
    where = "" if include_archived else "WHERE NOT is_archived"
    rows = await connection.fetch(
        f"SELECT {_COLUMNS} FROM accounts {where} ORDER BY code"
    )
    return [dict(row) for row in rows]


async def create_account(
    connection: asyncpg.Connection,
    *,
    code: str,
    name: str,
    type: str,
    normal_balance: str,
    parent_account_id: UUID | None = None,
    cash_flow_category: str | None = None,
) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"""
        INSERT INTO accounts
            (workspace_id, code, name, type, normal_balance, parent_account_id, cash_flow_category)
        VALUES (app_current_workspace(), $1, $2, $3, $4, $5, $6)
        RETURNING {_COLUMNS}
        """,
        code,
        name,
        type,
        normal_balance,
        parent_account_id,
        cash_flow_category,
    )
    return dict(row)


async def _get_or_raise(connection: asyncpg.Connection, account_id: UUID) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"SELECT {_COLUMNS} FROM accounts WHERE id = $1", account_id
    )
    if row is None:
        raise NotFound(
            f"account {account_id} not found",
            entity="account",
            entity_id=str(account_id),
        )
    return dict(row)


async def update_account(
    connection: asyncpg.Connection,
    account_id: UUID,
    *,
    expected_version: int,
    **fields: Any,
) -> dict[str, Any]:
    """Edit an account, or raise `VersionConflict` carrying the current row."""
    unknown = set(fields) - _UPDATABLE_COLUMNS
    if unknown:
        raise ValueError(f"not updatable: {', '.join(sorted(unknown))}")

    settable = {k: v for k, v in fields.items() if v is not None}
    if not settable:
        return await _get_or_raise(connection, account_id)

    assignments = ", ".join(f"{column} = ${i}" for i, column in enumerate(settable, start=3))
    row = await connection.fetchrow(
        f"""
        UPDATE accounts
           SET {assignments}
         WHERE id = $1 AND version = $2
        RETURNING {_COLUMNS}
        """,
        account_id,
        expected_version,
        *settable.values(),
    )
    if row is not None:
        return dict(row)

    current = await _get_or_raise(connection, account_id)
    raise VersionConflict("account", account_id, expected_version, current=current)


async def archive_account(
    connection: asyncpg.Connection,
    account_id: UUID,
    *,
    expected_version: int,
) -> dict[str, Any]:
    """Archive rather than delete: an account referenced by a posted entry can
    never be removed, because the entry it belongs to can never be rewritten."""
    row = await connection.fetchrow(
        f"""
        UPDATE accounts
           SET is_archived = true
         WHERE id = $1 AND version = $2
        RETURNING {_COLUMNS}
        """,
        account_id,
        expected_version,
    )
    if row is not None:
        return dict(row)

    current = await _get_or_raise(connection, account_id)
    raise VersionConflict("account", account_id, expected_version, current=current)
