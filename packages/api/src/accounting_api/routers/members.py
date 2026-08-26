"""Workspace membership -- who's in a workspace, and what they may do.

Existing-accounts-only invites: `POST` looks a member up by email and 404s
clearly (`UserNotFound`) if nobody has registered with it yet. No invite
tokens, no invite email -- the owner tells a colleague to register first,
then adds them. Smallest scope that's still useful for a small self-hosted
team; a token-based invite-by-email-for-anyone flow is a larger, separate
piece of work if it's ever needed.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter

from ..core import members as members_core
from ..deps import CurrentUser, Db, check_role, require_membership
from ..errors import UserNotFound
from ..schemas.members import AddMember, Member, UpdateMemberRole

router = APIRouter(prefix="/workspaces/{workspace_id}/members", tags=["members"])


@router.get("", response_model=list[Member])
async def list_members(workspace_id: UUID, user: CurrentUser, db: Db):
    """Any member can see the team -- only mutating it is owner-gated."""
    await require_membership(workspace_id, user, db)
    async with db.workspace(workspace_id) as connection:
        return await members_core.list_members(connection, workspace_id)


@router.post("", status_code=201, response_model=Member)
async def add_member(workspace_id: UUID, payload: AddMember, user: CurrentUser, db: Db):
    membership = await require_membership(workspace_id, user, db)
    check_role(membership, "owner")

    async with db.auth() as connection:
        target = await connection.fetchrow(
            "SELECT id FROM users WHERE lower(email) = lower($1)", payload.email
        )
    if target is None:
        raise UserNotFound(
            f"no account with email {payload.email} -- they need to register first",
            entity="user",
            entity_id=payload.email,
        )

    async with db.workspace(workspace_id) as connection:
        return await members_core.add_member(
            connection, workspace_id, user_id=target["id"], role=payload.role
        )


@router.patch("/{user_id}", response_model=Member)
async def update_member(
    workspace_id: UUID, user_id: UUID, payload: UpdateMemberRole, user: CurrentUser, db: Db
):
    membership = await require_membership(workspace_id, user, db)
    check_role(membership, "owner")
    async with db.workspace(workspace_id) as connection:
        return await members_core.update_member_role(
            connection, workspace_id, user_id, role=payload.role, expected_version=payload.version
        )


@router.delete("/{user_id}", status_code=204)
async def remove_member(workspace_id: UUID, user_id: UUID, user: CurrentUser, db: Db):
    """Owner-gated, except a member may always remove themselves (leaving a
    workspace needs no special privilege)."""
    membership = await require_membership(workspace_id, user, db)
    if user_id != membership["user_id"]:
        check_role(membership, "owner")
    async with db.workspace(workspace_id) as connection:
        await members_core.remove_member(connection, workspace_id, user_id)
