"""Chart of accounts."""

from uuid import UUID

from fastapi import APIRouter

from ..core import accounts as accounts_core
from ..deps import Db, WorkspaceId
from ..schemas.accounts import Account, AccountCreate, AccountUpdate
from ..schemas.common import OptimisticUpdate

router = APIRouter(prefix="/accounts", tags=["accounts"])


@router.get("", response_model=list[Account])
async def list_accounts(workspace_id: WorkspaceId, db: Db, include_archived: bool = False):
    async with db.workspace(workspace_id) as connection:
        return await accounts_core.list_accounts(connection, include_archived=include_archived)


@router.post("", status_code=201, response_model=Account)
async def create_account(payload: AccountCreate, workspace_id: WorkspaceId, db: Db):
    async with db.workspace(workspace_id) as connection:
        return await accounts_core.create_account(connection, **payload.model_dump())


@router.patch("/{account_id}", response_model=Account)
async def update_account(
    account_id: UUID, payload: AccountUpdate, workspace_id: WorkspaceId, db: Db
):
    """Requires the `version` last read; see errors.VersionConflict."""
    fields = payload.model_dump(exclude={"version"}, exclude_unset=True)
    async with db.workspace(workspace_id) as connection:
        return await accounts_core.update_account(
            connection, account_id, expected_version=payload.version, **fields
        )


@router.post("/{account_id}/archive", response_model=Account)
async def archive_account(
    account_id: UUID, payload: OptimisticUpdate, workspace_id: WorkspaceId, db: Db
):
    """Archive rather than delete: an account referenced by a posted entry can
    never be removed, because the entry it belongs to can never be rewritten."""
    async with db.workspace(workspace_id) as connection:
        return await accounts_core.archive_account(
            connection, account_id, expected_version=payload.version
        )
