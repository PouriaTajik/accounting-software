"""Journal entries -- the ledger itself.

The draft/posted split is the spine of this router. Everything before `/post`
is ordinary mutable CRUD; `/post` is a one-way door the database itself
enforces, and after it the only available verb is `/reverse`.
"""

from uuid import UUID

from fastapi import APIRouter

from ..core import ledger
from ..deps import Db, WorkspaceId
from ..schemas.common import OptimisticUpdate, Page
from ..schemas.journal import (
    JournalEntry,
    JournalEntryCreate,
    JournalEntryDetail,
    JournalEntryUpdate,
    ReverseEntry,
)

router = APIRouter(prefix="/journal-entries", tags=["ledger"])


@router.get("", response_model=Page[JournalEntry])
async def list_entries(
    workspace_id: WorkspaceId,
    db: Db,
    status: str | None = None,
    limit: int = 100,
    cursor: str | None = None,
):
    """Ledger view feed. Keyset pagination, not offset -- this table only grows."""
    async with db.workspace(workspace_id) as connection:
        entries, next_cursor = await ledger.list_entries(
            connection, status=status, limit=limit, cursor=cursor
        )
    return Page(items=entries, next_cursor=next_cursor)


@router.post("", status_code=201, response_model=JournalEntryDetail)
async def create_draft_entry(payload: JournalEntryCreate, workspace_id: WorkspaceId, db: Db):
    """Always creates a draft.

    `posted_at` cannot be set at insert time; the database rejects it, so
    posting is always the explicit transition below.
    """
    async with db.workspace(workspace_id) as connection:
        return await ledger.create_draft_entry(
            connection,
            entry_date=payload.entry_date,
            memo=payload.memo,
            source=payload.source,
            device_id=payload.device_id,
            lines=[line.model_dump() for line in payload.lines],
        )


@router.get("/{entry_id}", response_model=JournalEntryDetail)
async def get_entry(entry_id: UUID, workspace_id: WorkspaceId, db: Db):
    async with db.workspace(workspace_id) as connection:
        return await ledger.get_entry(connection, entry_id)


@router.patch("/{entry_id}", response_model=JournalEntryDetail)
async def update_draft_entry(
    entry_id: UUID, payload: JournalEntryUpdate, workspace_id: WorkspaceId, db: Db
):
    """Drafts only. Editing a posted entry returns 409 posted_entry_immutable."""
    fields = payload.model_dump(exclude={"version", "lines"}, exclude_unset=True)
    lines = None if payload.lines is None else [line.model_dump() for line in payload.lines]
    async with db.workspace(workspace_id) as connection:
        return await ledger.update_draft_entry(
            connection, entry_id, expected_version=payload.version, lines=lines, **fields
        )


@router.delete("/{entry_id}", status_code=204)
async def delete_draft_entry(
    entry_id: UUID, payload: OptimisticUpdate, workspace_id: WorkspaceId, db: Db
):
    """Drafts only. A posted entry is never deleted -- it is reversed."""
    async with db.workspace(workspace_id) as connection:
        await ledger.delete_draft_entry(connection, entry_id, expected_version=payload.version)


@router.post("/{entry_id}/post", response_model=JournalEntryDetail)
async def post_entry(entry_id: UUID, payload: OptimisticUpdate, workspace_id: WorkspaceId, db: Db):
    """Draft -> posted. Irreversible.

    Balance is validated by the database during the transition, so an
    unbalanced entry cannot be posted even if this handler is wrong.
    """
    async with db.workspace(workspace_id) as connection:
        return await ledger.post_entry(connection, entry_id, expected_version=payload.version)


@router.post("/{entry_id}/reverse", status_code=201, response_model=JournalEntryDetail)
async def reverse_entry(entry_id: UUID, payload: ReverseEntry, workspace_id: WorkspaceId, db: Db):
    """The only correction mechanism for posted data.

    Creates a new entry with mirrored lines, `source = 'reversal'` and
    `reverses_entry_id` set. An entry can be reversed at most once.
    """
    async with db.workspace(workspace_id) as connection:
        return await ledger.reverse_entry(
            connection, entry_id, memo=payload.memo, device_id=payload.device_id
        )
