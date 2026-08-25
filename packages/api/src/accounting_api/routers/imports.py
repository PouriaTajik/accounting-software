"""CSV / bank-statement import.

Split out from `documents` because ARCHITECTURE.md flags it as unscaffolded
and load-bearing: with no bank feed, this is the bulk and historical data path.

The least-steps constraint shapes the endpoints. Column mapping and
categorization happen in ONE pass, and the user is shown a single summary
rather than a mapping wizard followed by a review wizard.
"""

from uuid import UUID

from fastapi import APIRouter, UploadFile

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/imports", tags=["imports"])


@router.post("", status_code=202)
async def create_import(file: UploadFile, workspace_id: WorkspaceId, db: Db):
    """Upload a CSV/statement; infer columns and categorize in a single pass."""
    not_implemented("Starting a CSV import")


@router.get("/{import_id}")
async def get_import(import_id: UUID, workspace_id: WorkspaceId, db: Db):
    """Progress, plus the summary counts the review screen is built from."""
    not_implemented("Reading an import")


@router.get("/{import_id}/exceptions")
async def list_import_exceptions(import_id: UUID, workspace_id: WorkspaceId, db: Db):
    """Only the rows that need a human. The rest are already drafted."""
    not_implemented("Listing import exceptions")


@router.post("/{import_id}/commit")
async def commit_import(import_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    not_implemented("Committing an import")
