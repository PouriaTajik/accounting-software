"""Shapes shared by every router."""

from __future__ import annotations

from decimal import Decimal
from typing import Annotated, Generic, TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")

#: Amounts are `Decimal`, never `float`, and serialize as strings.
#:
#: `journal_lines.debit/credit` are `numeric(18,2)`; binding them to a float
#: anywhere in the stack reintroduces exactly the representation error the
#: numeric type exists to avoid. JSON has one number type and it is a double,
#: so the wire format is a string.
Money = Annotated[
    Decimal,
    Field(max_digits=18, decimal_places=2),
]


class OptimisticUpdate(BaseModel):
    """Base for every mutating request against a versioned row.

    `version` is required, not optional-with-a-default. An update that omits it
    would be a last-write-wins update, which is the exact behaviour the
    `version` column exists to prevent on financial data.
    """

    version: int = Field(
        ...,
        ge=1,
        description="The version last read. A mismatch returns 409 version_conflict.",
    )


class Page(BaseModel, Generic[T]):
    """Keyset pagination.

    Cursor, not offset: the ledger is append-only and grows without bound, and
    offset pagination over a growing table both drifts and degrades.
    """

    items: list[T]
    next_cursor: str | None = None
