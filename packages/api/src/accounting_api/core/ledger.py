"""Core ledger operations.

* `post_entry` and `update_draft_entry` take an `expected_version`. Both are
  state transitions on a row other devices may also be editing, so both are
  subject to the same optimistic concurrency as any other draft edit.
* There is no `update_posted_entry`. There is no `delete_posted_entry`. The
  absence is the design -- `reverse_entry` is the only way to change what the
  books say, and the database agrees (db/schema.sql).
* Every function takes an already workspace-scoped connection rather than a
  `workspace_id` it filters on itself, so a forgotten filter is not a class of
  bug that exists here.
* Balance, line-count and period-lock checks are enforced by triggers in
  db/migrations, not duplicated here: two implementations of the same rule is
  how they drift apart. This module's job is to issue the right statement and
  let ../errors.py translate the database's refusal.
"""

from __future__ import annotations

import base64
from collections.abc import Sequence
from datetime import date, datetime
from typing import TYPE_CHECKING, Any
from uuid import UUID

from ..errors import EntryNotPosted, NotFound, VersionConflict

if TYPE_CHECKING:
    import asyncpg

_ENTRY_COLUMNS = """
    id, workspace_id, entry_date, memo, source, reverses_entry_id,
    posted_at, version, created_at, created_by_device_id
"""
_LINE_COLUMNS = "id, journal_entry_id, account_id, debit, credit, memo"

#: Columns `update_draft_entry` may assign directly. Whitelisted rather than
#: accepting whatever keys the caller passes, since those keys become SQL
#: identifiers.
_UPDATABLE_ENTRY_COLUMNS = {"entry_date", "memo"}


async def _fetch_lines(connection: asyncpg.Connection, entry_id: UUID) -> list[dict[str, Any]]:
    rows = await connection.fetch(
        f"SELECT {_LINE_COLUMNS} FROM journal_lines "
        f"WHERE journal_entry_id = $1 ORDER BY created_at, id",
        entry_id,
    )
    return [dict(row) for row in rows]


async def _get_entry_or_raise(connection: asyncpg.Connection, entry_id: UUID) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"SELECT {_ENTRY_COLUMNS} FROM journal_entries WHERE id = $1", entry_id
    )
    if row is None:
        raise NotFound(
            f"journal entry {entry_id} not found",
            entity="journal_entry",
            entity_id=str(entry_id),
        )
    return dict(row)


async def _insert_lines(
    connection: asyncpg.Connection, entry_id: UUID, lines: Sequence[dict[str, Any]]
) -> list[dict[str, Any]]:
    inserted = []
    for line in lines:
        row = await connection.fetchrow(
            f"""
            INSERT INTO journal_lines
                (workspace_id, journal_entry_id, account_id, debit, credit, memo)
            VALUES (app_current_workspace(), $1, $2, $3, $4, $5)
            RETURNING {_LINE_COLUMNS}
            """,
            entry_id,
            line["account_id"],
            line["debit"],
            line["credit"],
            line.get("memo"),
        )
        inserted.append(dict(row))
    return inserted


def _encode_cursor(created_at: datetime, entry_id: UUID) -> str:
    raw = f"{created_at.isoformat()}|{entry_id}"
    return base64.urlsafe_b64encode(raw.encode()).decode()


def _decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    raw = base64.urlsafe_b64decode(cursor.encode()).decode()
    created_at_str, entry_id_str = raw.split("|", 1)
    return datetime.fromisoformat(created_at_str), UUID(entry_id_str)


async def get_entry(connection: asyncpg.Connection, entry_id: UUID) -> dict[str, Any]:
    entry = await _get_entry_or_raise(connection, entry_id)
    entry["lines"] = await _fetch_lines(connection, entry_id)
    return entry


async def list_entries(
    connection: asyncpg.Connection,
    *,
    status: str | None = None,
    limit: int = 100,
    cursor: str | None = None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Ledger view feed, newest first. Keyset pagination -- this table only grows."""
    where: list[str] = []
    params: list[Any] = []

    if status == "draft":
        where.append("posted_at IS NULL")
    elif status == "posted":
        where.append("posted_at IS NOT NULL")

    if cursor is not None:
        cursor_created_at, cursor_id = _decode_cursor(cursor)
        params.extend([cursor_created_at, cursor_id])
        where.append(f"(created_at, id) < (${len(params) - 1}, ${len(params)})")

    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    params.append(limit)
    rows = await connection.fetch(
        f"""
        SELECT {_ENTRY_COLUMNS} FROM journal_entries
        {where_sql}
        ORDER BY created_at DESC, id DESC
        LIMIT ${len(params)}
        """,
        *params,
    )
    entries = [dict(row) for row in rows]

    next_cursor = None
    if len(entries) == limit:
        last = entries[-1]
        next_cursor = _encode_cursor(last["created_at"], last["id"])

    return entries, next_cursor


async def create_draft_entry(
    connection: asyncpg.Connection,
    *,
    entry_date: date,
    memo: str | None,
    lines: Sequence[dict[str, Any]],
    source: str = "manual",
    device_id: UUID | None = None,
) -> dict[str, Any]:
    """Insert an unposted entry and its lines. Never sets `posted_at`."""
    row = await connection.fetchrow(
        f"""
        INSERT INTO journal_entries
            (workspace_id, entry_date, memo, source, created_by_device_id)
        VALUES (app_current_workspace(), $1, $2, $3, $4)
        RETURNING {_ENTRY_COLUMNS}
        """,
        entry_date,
        memo,
        source,
        device_id,
    )
    entry = dict(row)
    entry["lines"] = await _insert_lines(connection, entry["id"], lines)
    return entry


async def update_draft_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    expected_version: int,
    lines: Sequence[dict[str, Any]] | None = None,
    **fields: Any,
) -> dict[str, Any]:
    """Edit a draft, or raise `VersionConflict` carrying the current row.

    Replaces the line set wholesale when `lines` is given, rather than
    diffing -- a draft is scratch space a client resubmits in full, and a diff
    would be a second, error-prone way to say the same thing.
    """
    unknown = set(fields) - _UPDATABLE_ENTRY_COLUMNS
    if unknown:
        raise ValueError(f"not updatable: {', '.join(sorted(unknown))}")

    # `fields` is expected to already be scoped to what the caller actually
    # sent (e.g. via `model_dump(exclude_unset=True)`) -- unlike a plain
    # None-filter, this lets a caller clear `memo` by sending it as `null`,
    # rather than that being indistinguishable from omitting it.
    if fields:
        assignments = ", ".join(f"{column} = ${i}" for i, column in enumerate(fields, start=3))
        params = list(fields.values())
    else:
        # Still a real UPDATE even with nothing of its own to change, so the
        # version-bumping trigger fires uniformly -- a lines-only edit must be
        # just as visible to optimistic concurrency as any other.
        assignments = "entry_date = entry_date"
        params = []

    row = await connection.fetchrow(
        f"""
        UPDATE journal_entries
           SET {assignments}
         WHERE id = $1 AND version = $2
        RETURNING {_ENTRY_COLUMNS}
        """,
        entry_id,
        expected_version,
        *params,
    )
    if row is None:
        current = await _get_entry_or_raise(connection, entry_id)
        raise VersionConflict("journal_entry", entry_id, expected_version, current=current)

    entry = dict(row)
    if lines is not None:
        await connection.execute(
            "DELETE FROM journal_lines WHERE journal_entry_id = $1", entry_id
        )
        entry["lines"] = await _insert_lines(connection, entry_id, lines)
    else:
        entry["lines"] = await _fetch_lines(connection, entry_id)
    return entry


async def delete_draft_entry(
    connection: asyncpg.Connection, entry_id: UUID, *, expected_version: int
) -> None:
    """Drafts only. A posted entry is never deleted -- it is reversed."""
    deleted_id = await connection.fetchval(
        "DELETE FROM journal_entries WHERE id = $1 AND version = $2 RETURNING id",
        entry_id,
        expected_version,
    )
    if deleted_id is None:
        current = await _get_entry_or_raise(connection, entry_id)
        raise VersionConflict("journal_entry", entry_id, expected_version, current=current)


async def post_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    expected_version: int,
) -> dict[str, Any]:
    """Draft -> posted, irreversibly.

    Balance, minimum line count and period-lock are enforced by the database
    during the transition; this surfaces the database's refusal rather than
    re-checking any of it here.
    """
    row = await connection.fetchrow(
        f"""
        UPDATE journal_entries
           SET posted_at = now()
         WHERE id = $1 AND version = $2
        RETURNING {_ENTRY_COLUMNS}
        """,
        entry_id,
        expected_version,
    )
    if row is None:
        current = await _get_entry_or_raise(connection, entry_id)
        raise VersionConflict("journal_entry", entry_id, expected_version, current=current)

    entry = dict(row)
    entry["lines"] = await _fetch_lines(connection, entry_id)
    return entry


async def reverse_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    memo: str | None = None,
    device_id: UUID | None = None,
) -> dict[str, Any]:
    """Create the mirrored, posted correction for an already-posted entry.

    Dated today, not on the original entry's date: a reversal records when the
    correction was made, not when the mistake was. An entry can be reversed at
    most once -- the database's own `uq_journal_entries_one_reversal` is what
    actually guarantees that, surfaced here as `DuplicateKey` on a second try.
    """
    original = await _get_entry_or_raise(connection, entry_id)
    if original["posted_at"] is None:
        raise EntryNotPosted(
            f"journal entry {entry_id} is a draft; delete it instead of reversing it.",
            entity_id=str(entry_id),
        )

    original_lines = await _fetch_lines(connection, entry_id)

    row = await connection.fetchrow(
        f"""
        INSERT INTO journal_entries
            (workspace_id, entry_date, memo, source, reverses_entry_id, created_by_device_id)
        VALUES (app_current_workspace(), CURRENT_DATE, $1, 'reversal', $2, $3)
        RETURNING {_ENTRY_COLUMNS}
        """,
        memo,
        entry_id,
        device_id,
    )
    reversal = dict(row)

    mirrored = [
        {
            "account_id": line["account_id"],
            "debit": line["credit"],
            "credit": line["debit"],
            "memo": line["memo"],
        }
        for line in original_lines
    ]
    reversal["lines"] = await _insert_lines(connection, reversal["id"], mirrored)

    posted_row = await connection.fetchrow(
        f"UPDATE journal_entries SET posted_at = now() WHERE id = $1 RETURNING {_ENTRY_COLUMNS}",
        reversal["id"],
    )
    reversal.update(dict(posted_row))
    return reversal


async def trial_balance(
    connection: asyncpg.Connection,
    *,
    as_of: date | None = None,
) -> list[dict[str, Any]]:
    """Per-account debit/credit totals over posted entries only.

    The cheapest possible proof that the ledger is internally consistent: the
    two columns must sum equal.
    """
    where = "WHERE e.posted_at IS NOT NULL"
    params: list[Any] = []
    if as_of is not None:
        params.append(as_of)
        where += " AND e.entry_date <= $1"

    rows = await connection.fetch(
        f"""
        SELECT a.id AS account_id, a.code, a.name,
               COALESCE(SUM(l.debit), 0) AS total_debit,
               COALESCE(SUM(l.credit), 0) AS total_credit
          FROM journal_lines l
          JOIN journal_entries e ON e.id = l.journal_entry_id
          JOIN accounts a ON a.id = l.account_id
         {where}
         GROUP BY a.id, a.code, a.name
         ORDER BY a.code
        """,
        *params,
    )
    return [dict(row) for row in rows]
