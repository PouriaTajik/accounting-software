"""Core ledger operations.

Phase 2 fills these in. The signatures are here now because they encode
decisions worth reviewing before any of it is written:

* `post_entry` takes an `expected_version`. Posting is a state transition on a
  row other devices may also be editing, so it is subject to the same
  optimistic concurrency as any other draft edit.
* There is no `update_posted_entry`. There is no `delete_posted_entry`. The
  absence is the design -- `reverse_entry` is the only way to change what the
  books say, and the database agrees (db/schema.sql).
* Every function takes an already workspace-scoped connection rather than a
  `workspace_id` it filters on itself, so a forgotten filter is not a class of
  bug that exists here.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date
from decimal import Decimal
from typing import TYPE_CHECKING, Any
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg


async def create_draft_entry(
    connection: asyncpg.Connection,
    *,
    entry_date: date,
    memo: str | None,
    lines: Sequence[tuple[UUID, Decimal, Decimal]],
    source: str = "manual",
    device_id: UUID | None = None,
) -> dict[str, Any]:
    """Insert an unposted entry and its lines. Never sets `posted_at`."""
    raise NotImplementedError


async def update_draft_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    expected_version: int,
    **fields: Any,
) -> dict[str, Any]:
    """Edit a draft, or raise `VersionConflict` carrying the current row."""
    raise NotImplementedError


async def post_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    expected_version: int,
) -> dict[str, Any]:
    """Draft -> posted, irreversibly.

    Balance is enforced by the database during the transition. This function
    should not duplicate that check as its primary guard -- it should surface
    the database's refusal as `UnbalancedEntry`. Two implementations of the
    same rule is how they drift apart.
    """
    raise NotImplementedError


async def reverse_entry(
    connection: asyncpg.Connection,
    entry_id: UUID,
    *,
    memo: str | None = None,
    device_id: UUID | None = None,
) -> dict[str, Any]:
    """Create the mirrored, posted correction for an already-posted entry."""
    raise NotImplementedError


async def trial_balance(
    connection: asyncpg.Connection,
    *,
    as_of: date | None = None,
) -> list[dict[str, Any]]:
    """Per-account debit/credit totals over posted entries only.

    The cheapest possible proof that the ledger is internally consistent: the
    two columns must sum equal. Worth having early, as a test fixture as much
    as a feature.
    """
    raise NotImplementedError
