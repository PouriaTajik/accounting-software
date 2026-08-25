"""Journal entries.

No Postgres: what is worth testing here is the part decided in Python --
request-boundary validation and error translation. The invariants that
matter -- balance, immutability, period locking -- are enforced by the
database and already proven by db/verify_schema.sql and db/verify_periods.sql.
"""

from __future__ import annotations

from datetime import UTC
from decimal import Decimal
from uuid import uuid4

import pytest
from pydantic import ValidationError

from accounting_api.core import ledger as ledger_core
from accounting_api.core.ledger import _decode_cursor, _encode_cursor
from accounting_api.errors import (
    EntryNotPosted,
    FiscalYearClosed,
    PeriodLocked,
    UnbalancedEntry,
    translate_database_error,
)
from accounting_api.schemas.journal import JournalLineIn


class _FakePostgresError(Exception):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate
        self.message = message


# --- request-boundary validation ---------------------------------------------


def test_a_line_cannot_carry_both_debit_and_credit() -> None:
    with pytest.raises(ValidationError):
        JournalLineIn(account_id=uuid4(), debit=Decimal("10"), credit=Decimal("10"))


def test_a_line_needs_one_positive_side() -> None:
    with pytest.raises(ValidationError):
        JournalLineIn(account_id=uuid4())


def test_a_line_cannot_be_negative() -> None:
    with pytest.raises(ValidationError):
        JournalLineIn(account_id=uuid4(), debit=Decimal("-10"))


def test_a_well_formed_line_is_accepted() -> None:
    line = JournalLineIn(account_id=uuid4(), debit=Decimal("100.50"))
    assert line.credit == 0


async def test_update_refuses_a_column_it_does_not_own() -> None:
    with pytest.raises(ValueError, match="not updatable: source"):
        await ledger_core.update_draft_entry(
            None,  # never reached
            uuid4(),
            expected_version=1,
            source="manual",
        )


# --- error translation --------------------------------------------------------


def test_locked_period_is_distinguished_from_immutability() -> None:
    error = translate_database_error(
        _FakePostgresError(
            "23001",
            "journal_entries: books are locked through 2025-08-31, so an entry "
            "dated 2025-07-15 cannot be posted. Date it later, or move the lock.",
        )
    )
    assert isinstance(error, PeriodLocked)
    assert error.status_code == 409


def test_closed_fiscal_year_is_distinguished_from_immutability() -> None:
    error = translate_database_error(
        _FakePostgresError(
            "23001",
            "journal_entries: fiscal year 1404 is closed, so an entry dated "
            "2025-06-02 cannot be posted. Reopen the year, or post the "
            "correction to the open one.",
        )
    )
    assert isinstance(error, FiscalYearClosed)


def test_needs_two_lines_is_an_unbalanced_entry() -> None:
    # Same custom-worded family as the debit/credit mismatch: both are the
    # entry-level posting guard refusing, just for a different reason.
    error = translate_database_error(
        _FakePostgresError(
            "23514", "journal_entries: entry abc needs at least two lines before posting (found 1)."
        )
    )
    assert isinstance(error, UnbalancedEntry)


def test_a_bare_line_check_constraint_is_not_mislabeled_unbalanced() -> None:
    # journal_lines_single_sided has no "journal_entries:" prefix -- the API
    # layer should have rejected this shape before it ever reached Postgres,
    # so it is left unmapped (a 500) rather than mislabeled as "unbalanced".
    error = translate_database_error(
        _FakePostgresError(
            "23514",
            'new row for relation "journal_lines" violates check constraint '
            '"journal_lines_single_sided"',
        )
    )
    assert error is None


def test_entry_not_posted_is_a_domain_error() -> None:
    error = EntryNotPosted("journal entry ... is a draft", entity_id=str(uuid4()))
    assert error.status_code == 422
    assert error.code == "entry_not_posted"


# --- keyset cursor --------------------------------------------------------


def test_cursor_round_trips() -> None:
    from datetime import datetime

    created_at = datetime(2026, 8, 25, 12, 30, tzinfo=UTC)
    entry_id = uuid4()

    cursor = _encode_cursor(created_at, entry_id)
    decoded_created_at, decoded_id = _decode_cursor(cursor)

    assert decoded_created_at == created_at
    assert decoded_id == entry_id
