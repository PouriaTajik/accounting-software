"""Per-workspace AI configuration.

This is the whole switch between "cloud with the client's own key" and "fully
offline Ollama". It is a settings write, not a deploy, and not a code branch.
"""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, not_implemented

router = APIRouter(prefix="/workspaces/{workspace_id}/ai-config", tags=["ai"])


@router.get("")
async def get_ai_config(workspace_id: UUID, db: Db):
    """Current mode, model and api_base.

    Never returns `api_key_encrypted`, in any form, including masked -- the
    response model must not have the field at all, so it cannot be added back
    by accident.
    """
    not_implemented("Reading AI configuration")


@router.put("")
async def put_ai_config(workspace_id: UUID, payload: dict, db: Db):
    """Replace the configuration. Encrypts the key before it reaches Postgres."""
    not_implemented("Writing AI configuration")


@router.post("/test")
async def test_ai_config(workspace_id: UUID, payload: dict, db: Db):
    """Round-trip the configured provider with a trivial completion.

    Worth having before the settings screen exists: an offline install with a
    wrong Ollama host should fail here, once, rather than at the moment
    someone scans their first receipt.
    """
    not_implemented("Testing AI configuration")
