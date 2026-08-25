"""OCR ingestion and structured field extraction.

Two stages, kept separate on purpose:

  1. A dedicated OCR engine (PaddleOCR/Tesseract) turns the image into text
     and layout. Local, free, deterministic, no network.
  2. AIProvider turns that text into structured fields.

The model never receives the image. That keeps a receipt scan from costing a
vision-model call, and keeps the whole path working on an air-gapped install.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING, Protocol
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

    from accounting_ai import AIProvider


class OcrEngine(Protocol):
    """Seam for the OCR backend, so PaddleOCR vs Tesseract stays swappable and
    tests can inject a stub instead of shipping a model into CI."""

    def extract_text(self, file_path: str) -> str: ...


@dataclass(frozen=True)
class ExtractedFields:
    vendor: str | None
    document_date: str | None
    total: Decimal | None
    tax: Decimal | None
    line_items: list[dict]
    #: Drives the least-steps branch: high confidence auto-drafts an entry for
    #: one-tap approval, low confidence opens a review form. The threshold is a
    #: product decision, not a model detail -- it belongs in config, not here.
    confidence: float


async def ingest(
    connection: asyncpg.Connection,
    document_id: UUID,
    *,
    ocr_engine: OcrEngine,
    ai_provider: AIProvider,
) -> ExtractedFields:
    """Run stage 1 then stage 2, persisting both results."""
    raise NotImplementedError


async def draft_entry_from_document(
    connection: asyncpg.Connection,
    document_id: UUID,
) -> UUID | None:
    """Build the draft entry a confident extraction implies.

    Returns None when confidence is below the auto-draft threshold, which is
    the signal to show a review form instead.
    """
    raise NotImplementedError
