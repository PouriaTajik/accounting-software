"""Workspaces -- the tenant boundary."""

from uuid import UUID

from fastapi import APIRouter

from ..core import workspaces as workspaces_core
from ..deps import CurrentUser, Db, check_role, require_membership
from ..schemas.workspaces import Workspace, WorkspaceCreate, WorkspaceUpdate

router = APIRouter(prefix="/workspaces", tags=["workspaces"])


@router.post("", status_code=201, response_model=Workspace)
async def create_workspace(payload: WorkspaceCreate, user: CurrentUser, db: Db):
    """Create a workspace and seat its creator as `owner`.

    Runs on a dedicated owner-role connection (`Database.provision()`), not
    the ordinary per-request `WorkspaceId` scoping every other route uses --
    there is no workspace yet to scope a session to. See db/README.md.
    Requires a logged-in user (not a workspace membership, since none can
    exist yet) so there is someone to seat.
    """
    async with db.provision() as connection:
        return await workspaces_core.create_workspace(
            connection,
            name=payload.name,
            owner_user_id=user["id"],
            base_currency=payload.base_currency,
            fiscal_calendar=payload.fiscal_calendar,
        )


@router.get("/{workspace_id}", response_model=Workspace)
async def get_workspace(workspace_id: UUID, user: CurrentUser, db: Db):
    await require_membership(workspace_id, user, db)
    async with db.workspace(workspace_id) as connection:
        return await workspaces_core.get_workspace(connection, workspace_id)


@router.patch("/{workspace_id}", response_model=Workspace)
async def update_workspace(
    workspace_id: UUID, payload: WorkspaceUpdate, user: CurrentUser, db: Db
):
    """Optimistic-concurrency update. Body must carry the `version` last read;
    a mismatch is a 409 carrying both versions, never a silent overwrite.

    `owner`-gated: workspace settings (currency, fiscal calendar, book locks)
    are a level above ordinary ledger entry -- a bookkeeper posts entries but
    doesn't get to change what the books' rules are."""
    membership = await require_membership(workspace_id, user, db)
    check_role(membership, "owner")
    fields = payload.model_dump(exclude={"version"}, exclude_unset=True)
    async with db.workspace(workspace_id) as connection:
        return await workspaces_core.update_workspace(
            connection, workspace_id, expected_version=payload.version, **fields
        )
