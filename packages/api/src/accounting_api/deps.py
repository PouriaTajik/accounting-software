"""Request-scoped dependencies.

The workspace and the AI provider are both resolved per request. Neither is
ever module-level state: a hosted process serves many tenants concurrently,
and a tenant's AI configuration is a row that can change between two requests.
"""

from __future__ import annotations

from typing import Annotated, NoReturn
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request

from .config import Settings, get_settings
from .db import Database
from .errors import AIProviderNotConfigured


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


WorkspaceId = Annotated[UUID, Depends(get_workspace_id)]
Db = Annotated[Database, Depends(get_database)]
Config = Annotated[Settings, Depends(get_settings)]
