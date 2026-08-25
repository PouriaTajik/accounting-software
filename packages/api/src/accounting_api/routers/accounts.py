"""Chart of accounts."""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/accounts", tags=["accounts"])


@router.get("")
async def list_accounts(workspace_id: WorkspaceId, db: Db, include_archived: bool = False):
    not_implemented("Listing accounts")


@router.post("", status_code=201)
async def create_account(payload: dict, workspace_id: WorkspaceId, db: Db):
    not_implemented("Creating an account")


@router.patch("/{account_id}")
async def update_account(account_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """Requires the `version` last read; see errors.VersionConflict."""
    not_implemented("Updating an account")


@router.post("/{account_id}/archive")
async def archive_account(account_id: UUID, workspace_id: WorkspaceId, db: Db):
    """Archive rather than delete: an account referenced by a posted entry can
    never be removed, because the entry it belongs to can never be rewritten."""
    not_implemented("Archiving an account")
