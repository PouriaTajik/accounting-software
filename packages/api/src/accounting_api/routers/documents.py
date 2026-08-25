"""Receipts, invoices and statements -- OCR capture.

A primary data-entry path, not a convenience: there is no bank feed
(BUSINESS_PRINCIPLES.md), so this is how most transactions arrive.
"""

from uuid import UUID

from fastapi import APIRouter, UploadFile

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/documents", tags=["documents"])


@router.post("", status_code=202)
async def upload_document(file: UploadFile, workspace_id: WorkspaceId, db: Db):
    """Accept the file and queue OCR. 202, because extraction is not synchronous.

    Pipeline: a dedicated OCR engine (PaddleOCR/Tesseract) produces raw text
    and layout, then AIProvider does structured field extraction from that
    text. The model never sees the image, which is what keeps this affordable
    and keeps it working offline.
    """
    not_implemented("Uploading a document")


@router.get("/{document_id}")
async def get_document(document_id: UUID, workspace_id: WorkspaceId, db: Db):
    """Includes `ocr_status`, and once done `extracted_fields` plus
    `extraction_confidence`."""
    not_implemented("Reading a document")


@router.post("/{document_id}/confirm")
async def confirm_document(document_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """One-tap approval of a high-confidence extraction.

    The least-steps rule: a confident extraction should already be a draft
    entry awaiting this single call, not a form the user fills in field by
    field. Only a low-confidence extraction earns a review screen.
    """
    not_implemented("Confirming a document extraction")
