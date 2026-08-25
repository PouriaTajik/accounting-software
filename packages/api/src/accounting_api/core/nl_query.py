"""Natural-language ledger query.

The security model is layered, and the prompt is the weakest layer -- so it is
not the one relied on. In order of strength:

  1. The `nl_query` Postgres role cannot write and cannot see `public`
     (db/roles.sql). This holds even if everything above it fails.
  2. The `ledger_query` views filter on `app.workspace_id`, so cross-tenant
     reads are impossible rather than merely unlikely.
  3. `is_query_safe` rejects anything that is not a single SELECT before it is
     ever sent to the database.
  4. The prompt asks nicely.

Layer 4 is the one an attacker controls: a receipt image is untrusted input,
and its OCR text can carry instructions. Layers 1-3 assume layer 4 is already
compromised.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import asyncpg

    from accounting_ai import AIProvider


@dataclass(frozen=True)
class QueryResult:
    question: str
    #: Returned to the user alongside the rows. An accounting answer nobody can
    #: audit is worth very little, and showing the SQL is also the cheapest
    #: possible tell that a query did something unexpected.
    sql: str
    columns: list[str]
    rows: list[dict[str, Any]]
    truncated: bool


def is_query_safe(sql: str) -> bool:
    """Reject anything that is not a single read-only SELECT.

    Pure function over a string: no database, no model, exhaustively testable.
    Multiple statements, CTEs that write, `COPY`, `pg_read_file`, and anything
    touching a schema other than `ledger_query` must all fail here.
    """
    raise NotImplementedError


async def answer(
    connection: asyncpg.Connection,
    question: str,
    *,
    ai_provider: AIProvider,
    row_limit: int = 500,
) -> QueryResult:
    """Generate SQL for `question`, validate it, execute it read-only."""
    raise NotImplementedError


def schema_prompt() -> str:
    """The fixed `ledger_query` schema description handed to the model.

    Fixed, not introspected at request time: a stable prompt is cacheable and
    reviewable, and it means adding a column to a base table cannot silently
    widen what the model is told it can reach.
    """
    raise NotImplementedError
