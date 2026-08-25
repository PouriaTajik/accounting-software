"""Categorization: rules first, model second.

The ordering is a cost and an offline-quality decision, not an optimization to
add later. A model call per transaction is unaffordable at hosted volume and
unreliable on a laptop running a 7B model, so the rules table has to carry the
bulk of the traffic and get better on its own.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

    from accounting_ai import AIProvider


class Decider(str, Enum):
    """Which path produced a suggestion.

    Surfaced to the UI, because "a rule you wrote matched" and "a model
    guessed" deserve visibly different confidence in an accounting product.
    """

    RULE = "rule"
    MODEL = "model"
    UNRESOLVED = "unresolved"


@dataclass(frozen=True)
class Categorization:
    account_id: UUID | None
    decider: Decider
    confidence: float
    rule_id: UUID | None = None


async def categorize(
    connection: asyncpg.Connection,
    descriptions: Sequence[str],
    *,
    ai_provider: AIProvider | None = None,
) -> list[Categorization]:
    """Categorize a batch.

    Batch, not single: CSV import is the volume path, and one model call for
    the leftovers beats one call per unmatched row.
    """
    raise NotImplementedError


async def match_rules(
    connection: asyncpg.Connection,
    descriptions: Sequence[str],
) -> list[Categorization]:
    """Pure rules-table pass. No AI, no network -- and therefore trivially
    testable and always available offline."""
    raise NotImplementedError


async def record_correction(
    connection: asyncpg.Connection,
    *,
    description: str,
    account_id: UUID,
) -> UUID:
    """Turn a user's correction into a rule.

    There is no separate "create a rule" step in the UI (BUSINESS_PRINCIPLES.md);
    this is where that promise is kept.
    """
    raise NotImplementedError
