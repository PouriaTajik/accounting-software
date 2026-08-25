"""Workspaces -- the tenant boundary."""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, not_implemented

router = APIRouter(prefix="/workspaces", tags=["workspaces"])


@router.post("", status_code=201)
async def create_workspace(payload: dict, db: Db):
    """Create a workspace and seed a default chart of accounts."""
    not_implemented("Creating a workspace")


@router.get("/{workspace_id}")
async def get_workspace(workspace_id: UUID, db: Db):
    not_implemented("Reading a workspace")


@router.patch("/{workspace_id}")
async def update_workspace(workspace_id: UUID, payload: dict, db: Db):
    """Optimistic-concurrency update. Body must carry the `version` last read;
    a mismatch is a 409 carrying both versions, never a silent overwrite."""
    not_implemented("Updating a workspace")
