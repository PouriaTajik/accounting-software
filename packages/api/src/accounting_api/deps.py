"""Request-scoped dependencies.

The workspace and the AI provider are both resolved per request. Neither is
ever module-level state: a hosted process serves many tenants concurrently,
and a tenant's AI configuration is a row that can change between two requests.
"""

from __future__ import annotations

from typing import Annotated, Any, NoReturn
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request

from .config import Settings, get_settings
from .core import auth as auth_core
from .db import Database
from .errors import AIProviderNotConfigured, InsufficientRole, NotAMember, NotAuthenticated


def get_database(request: Request) -> Database:
    return request.app.state.db


async def get_workspace_id(
    x_workspace_id: Annotated[UUID | None, Header(alias="X-Workspace-Id")] = None,
    settings: Annotated[Settings, Depends(get_settings)] = None,  # type: ignore[assignment]
) -> UUID:
    """Resolve the tenant for this request.

    In SERVER mode the header is mandatory and will later be derived from the
    authenticated session rather than trusted from the client. In LOCAL mode
    there is exactly one workspace, but it is still resolved explicitly and
    still travels with every query -- the tenant boundary is not something the
    desktop build gets to skip, or hosted mode becomes a rewrite.
    """
    if x_workspace_id is not None:
        return x_workspace_id

    raise HTTPException(
        status_code=400,
        detail="X-Workspace-Id header is required.",
    )


async def get_ai_provider(
    workspace_id: Annotated[UUID, Depends(get_workspace_id)],
    db: Annotated[Database, Depends(get_database)],
):
    """Load this workspace's AI configuration and build its provider.

    Phase 2. The shape is fixed already: read `workspace_ai_config`, decrypt
    the key, hand the row to `accounting_ai.load_provider_for_workspace`. No
    caller learns which provider it got.
    """
    raise AIProviderNotConfigured(
        "AI provider resolution lands in phase 2 (packages/api/core/ai_config.py)."
    )


def not_implemented(what: str) -> NoReturn:
    """Stub marker for phase 1.

    501, not 200-with-empty-body: a route that silently returns nothing is
    indistinguishable from a working route with no data, and that difference
    matters once the desktop shell starts wiring against these.
    """
    raise HTTPException(status_code=501, detail=f"{what} is not implemented yet (phase 2).")


#: owner outranks bookkeeper outranks viewer. A plain dict, not an Enum --
#: the only thing ever needed is "does role A clear the bar role B sets",
#: and `workspace_members.role` (migration 0003) is already a CHECK'd text
#: column, not a Python enum, so this stays the single source for ordering
#: without a second type to keep in sync with the database's.
_ROLE_RANK = {"viewer": 0, "bookkeeper": 1, "owner": 2}


async def get_current_user(
    request: Request,
    db: Annotated[Database, Depends(get_database)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> dict[str, Any]:
    """The logged-in user for this request, resolved from the session cookie.

    Uses `db.auth()` (accounting_auth, db/roles.sql) -- session resolution is
    an identity read, not a workspace-scoped one, and has to happen before
    any workspace is even known.
    """
    raw_token = request.cookies.get(settings.session_cookie_name)
    if raw_token is None:
        raise NotAuthenticated("no session cookie")

    async with db.auth() as connection:
        user = await auth_core.resolve_session(connection, raw_token=raw_token)

    if user is None:
        raise NotAuthenticated("session is invalid, expired, or revoked")

    return user


async def load_membership(
    db: Database, *, workspace_id: UUID, user_id: UUID
) -> dict[str, Any] | None:
    """This user's role in this workspace, or None if they aren't a member.

    Reads through `db.workspace()` (accounting_app), not `db.auth()` --
    once both `workspace_id` and `user_id` are known, this is an ordinary
    tenant-scoped read `workspace_members`'s existing RLS policy (migration
    0004) already admits. No second role or round trip needed for it.

    A plain function, not a `Depends`-wrapped dependency: `routers/
    workspaces.py` needs this exact check against a *path* `workspace_id`
    (`/workspaces/{workspace_id}`), while `get_current_membership` below
    needs it against the *header* `workspace_id` every other router uses
    (`X-Workspace-Id`). Wiring both through one FastAPI dependency would mean
    the membership check silently reads its workspace from a different place
    than the handler acts on -- exactly the "looks applied and is not"
    mismatch this codebase is deliberately careful about elsewhere (see
    db/README.md on the nl_query REVOKE). Kept as one function either way,
    called two different ways, rather than duplicated.
    """
    async with db.workspace(workspace_id) as connection:
        row = await connection.fetchrow(
            "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
            workspace_id,
            user_id,
        )
    if row is None:
        return None
    return {"user_id": user_id, "workspace_id": workspace_id, "role": row["role"]}


def check_role(membership: dict[str, Any], minimum: str) -> None:
    """Raise `InsufficientRole` if `membership`'s role doesn't clear `minimum`."""
    if _ROLE_RANK[membership["role"]] < _ROLE_RANK[minimum]:
        raise InsufficientRole(
            f"role {membership['role']!r} does not meet the required {minimum!r}",
            required=minimum,
            actual=membership["role"],
        )


async def require_membership(
    workspace_id: UUID, user: dict[str, Any], db: Database
) -> dict[str, Any]:
    """`load_membership`, raising `NotAMember` instead of returning None.

    For routers that identify their workspace from a URL *path* segment
    rather than the `X-Workspace-Id` header (`routers/workspaces.py`,
    `routers/members.py`) -- called directly with the path parameter,
    exactly the same reason `load_membership` itself isn't a header-bound
    `Depends` (see its docstring).
    """
    membership = await load_membership(db, workspace_id=workspace_id, user_id=user["id"])
    if membership is None:
        raise NotAMember(
            f"user {user['id']} is not a member of workspace {workspace_id}",
            entity="workspace",
            entity_id=str(workspace_id),
        )
    return membership


async def get_current_membership(
    workspace_id: Annotated[UUID, Depends(get_workspace_id)],
    user: Annotated[dict[str, Any], Depends(get_current_user)],
    db: Annotated[Database, Depends(get_database)],
) -> dict[str, Any]:
    """Header-sourced counterpart to `load_membership`, for the routers
    (accounts, journal, ...) that identify their workspace via
    `X-Workspace-Id` rather than a URL path segment."""
    membership = await load_membership(db, workspace_id=workspace_id, user_id=user["id"])
    if membership is None:
        raise NotAMember(
            f"user {user['id']} is not a member of workspace {workspace_id}",
            entity="workspace",
            entity_id=str(workspace_id),
        )
    return membership


def require_role(minimum: str):
    """A dependency that additionally requires at least `minimum` role.

    `Bookkeeper`/`Owner` below are the two instances every header-sourced
    router actually needs; written as a factory rather than two hand-written
    dependencies so the rank comparison lives in exactly one place
    (`check_role`).
    """

    async def _check(
        membership: Annotated[dict[str, Any], Depends(get_current_membership)],
    ) -> dict[str, Any]:
        check_role(membership, minimum)
        return membership

    return _check


WorkspaceId = Annotated[UUID, Depends(get_workspace_id)]
Db = Annotated[Database, Depends(get_database)]
Config = Annotated[Settings, Depends(get_settings)]

#: The logged-in user, regardless of workspace -- POST /workspaces (there is
#: no workspace yet) and GET /auth/me both only need this much.
CurrentUser = Annotated[dict[str, Any], Depends(get_current_user)]
#: Logged in AND a member of the request's workspace, any role -- reads.
Member = Annotated[dict[str, Any], Depends(get_current_membership)]
#: Member with at least `bookkeeper` -- ordinary ledger-mutating endpoints.
Bookkeeper = Annotated[dict[str, Any], Depends(require_role("bookkeeper"))]
#: Member with `owner` -- workspace settings, membership management.
Owner = Annotated[dict[str, Any], Depends(require_role("owner"))]
