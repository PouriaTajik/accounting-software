"""Journal entries -- the ledger itself.

The draft/posted split is the spine of this router. Everything before `/post`
is ordinary mutable CRUD; `/post` is a one-way door the database itself
enforces, and after it the only available verb is `/reverse`.
"""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/journal-entries", tags=["ledger"])


@router.get("")
async def list_entries(
    workspace_id: WorkspaceId,
    db: Db,
    status: str | None = None,
    limit: int = 100,
    cursor: str | None = None,
):
    """Ledger view feed. Keyset pagination, not offset -- this table only grows."""
    not_implemented("Listing journal entries")


@router.post("", status_code=201)
async def create_draft_entry(payload: dict, workspace_id: WorkspaceId, db: Db):
    """Always creates a draft.

    `posted_at` cannot be set at insert time; the database rejects it, so
    posting is always the explicit transition below.
    """
    not_implemented("Creating a draft journal entry")


@router.get("/{entry_id}")
async def get_entry(entry_id: UUID, workspace_id: WorkspaceId, db: Db):
    not_implemented("Reading a journal entry")


@router.patch("/{entry_id}")
async def update_draft_entry(entry_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """Drafts only. Editing a posted entry returns 409 posted_entry_immutable."""
    not_implemented("Updating a draft journal entry")


@router.delete("/{entry_id}", status_code=204)
async def delete_draft_entry(entry_id: UUID, workspace_id: WorkspaceId, db: Db):
    """Drafts only. A posted entry is never deleted -- it is reversed."""
    not_implemented("Deleting a draft journal entry")


@router.post("/{entry_id}/post")
async def post_entry(entry_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """Draft -> posted. Irreversible.

    Balance is validated by the database during the transition, so an
    unbalanced entry cannot be posted even if this handler is wrong.
    """
    not_implemented("Posting a journal entry")


@router.post("/{entry_id}/reverse", status_code=201)
async def reverse_entry(entry_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """The only correction mechanism for posted data.

    Creates a new entry with mirrored lines, `source = 'reversal'` and
    `reverses_entry_id` set. An entry can be reversed at most once.
    """
    not_implemented("Reversing a journal entry")
