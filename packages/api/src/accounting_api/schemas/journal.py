"""Shapes for the journal-entries endpoints."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, computed_field, model_validator

from .common import Money, OptimisticUpdate

#: 'reversal' is deliberately absent -- it is set only by the reverse
#: endpoint, alongside `reverses_entry_id`, never chosen directly by a client.
JournalSource = Literal["manual", "ocr_import", "csv_import", "ai_categorized", "period_close"]


class JournalLineIn(BaseModel):
    account_id: UUID
    debit: Money = Decimal("0")
    credit: Money = Decimal("0")
    memo: str | None = None

    @model_validator(mode="after")
    def _single_sided(self) -> JournalLineIn:
        # Mirrors journal_lines_single_sided (db/schema.sql): exactly one side
        # positive. Rejecting a malformed line here, at the API boundary,
        # means it never has to round-trip to Postgres to be told so.
        if self.debit < 0 or self.credit < 0:
            raise ValueError("debit and credit must not be negative")
        if (self.debit > 0) == (self.credit > 0):
            raise ValueError("exactly one of debit or credit must be positive")
        return self


class JournalLine(BaseModel):
    id: UUID
    account_id: UUID
    debit: Money
    credit: Money
    memo: str | None


class JournalEntryCreate(BaseModel):
    entry_date: date
    memo: str | None = None
    source: JournalSource = "manual"
    device_id: UUID | None = None
    lines: list[JournalLineIn] = []


class JournalEntryUpdate(OptimisticUpdate):
    """Drafts only. Editing a posted entry returns 409 posted_entry_immutable.

    `lines`, when given, replaces the entire line set -- see
    `core.ledger.update_draft_entry`.
    """

    entry_date: date | None = None
    memo: str | None = None
    lines: list[JournalLineIn] | None = None


class ReverseEntry(BaseModel):
    memo: str | None = None
    device_id: UUID | None = None


class JournalEntry(BaseModel):
    """Feed/list shape -- no lines, so listing a growing ledger stays cheap."""

    id: UUID
    workspace_id: UUID
    entry_date: date
    memo: str | None
    source: str
    reverses_entry_id: UUID | None
    posted_at: datetime | None
    version: int
    created_at: datetime

    @computed_field  # type: ignore[prop-decorator]
    @property
    def status(self) -> Literal["draft", "posted"]:
        return "draft" if self.posted_at is None else "posted"


class JournalEntryDetail(JournalEntry):
    lines: list[JournalLine]
