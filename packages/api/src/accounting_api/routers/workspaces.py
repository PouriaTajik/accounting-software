"""Workspaces -- the tenant boundary."""

from uuid import UUID

from fastapi import APIRouter

from ..core import workspaces as workspaces_core
from ..deps import Db
from ..schemas.workspaces import Workspace, WorkspaceCreate, WorkspaceUpdate

router = APIRouter(prefix="/workspaces", tags=["workspaces"])


@router.post("", status_code=201, response_model=Workspace)
async def create_workspace(payload: WorkspaceCreate, db: Db):
    """Create a workspace.

    Runs on a dedicated owner-role connection (`Database.provision()`), not
    the ordinary per-request `WorkspaceId` scoping every other route uses --
    there is no workspace yet to scope a session to. See db/README.md.
    """
    async with db.provision() as connection:
        return await workspaces_core.create_workspace(
            connection,
            name=payload.name,
            base_currency=payload.base_currency,
            fiscal_calendar=payload.fiscal_calendar,
        )


@router.get("/{workspace_id}", response_model=Workspace)
async def get_workspace(workspace_id: UUID, db: Db):
    async with db.workspace(workspace_id) as connection:
        return await workspaces_core.get_workspace(connection, workspace_id)


@router.patch("/{workspace_id}", response_model=Workspace)
async def update_workspace(workspace_id: UUID, payload: WorkspaceUpdate, db: Db):
    """Optimistic-concurrency update. Body must carry the `version` last read;
    a mismatch is a 409 carrying both versions, never a silent overwrite."""
    fields = payload.model_dump(exclude={"version"}, exclude_unset=True)
    async with db.workspace(workspace_id) as connection:
        return await workspaces_core.update_workspace(
            connection, workspace_id, expected_version=payload.version, **fields
        )
