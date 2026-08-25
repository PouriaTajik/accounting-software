"""Anomaly detection: statistics decide, the model narrates.

Keeping detection statistical means it is deterministic, reproducible, free,
and identical whether the workspace is on a cloud key or fully offline. The
model is used for exactly one thing -- turning a flagged row into a sentence a
human can act on -- and if it is unavailable, the flag still exists.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

    from accounting_ai import AIProvider


@dataclass(frozen=True)
class Candidate:
    """A statistically flagged entry, before anyone has explained it."""

    journal_entry_id: UUID
    detector: str          # 'zscore' | 'iqr' | 'duplicate'
    severity: str          # 'low' | 'medium' | 'high'
    observed: Decimal
    expected_range: tuple[Decimal, Decimal] | None


def detect_outliers(
    amounts: Sequence[Decimal],
    *,
    z_threshold: float = 3.0,
) -> list[int]:
    """Indices of statistical outliers. Pure function, no I/O, no database.

    Deliberately importable and testable on a list of numbers -- this is the
    part that has to be right, and it should not need Postgres to prove it.
    """
    raise NotImplementedError


async def scan_workspace(connection: asyncpg.Connection) -> list[Candidate]:
    """Run the detectors over recent activity and return candidates."""
    raise NotImplementedError


async def explain(
    candidate: Candidate,
    *,
    ai_provider: AIProvider,
) -> str:
    """Human-readable explanation for a flagged row.

    Must degrade rather than fail: with no reachable provider, the flag is
    still recorded with a plain templated reason.
    """
    raise NotImplementedError
