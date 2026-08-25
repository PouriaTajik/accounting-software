"""Natural-language ledger query (text-to-SQL).

Three things keep this safe, none of which is the prompt:

  1. The model only ever sees the `ledger_query` schema, a read-only
     projection with no keys, file paths or raw OCR text in it.
  2. Generated SQL executes on the `nl_query` role: read-only transactions,
     statement timeout, no privileges on `public` (db/roles.sql).
  3. The views filter on `app.workspace_id`, so tenant scoping does not depend
     on the model writing a WHERE clause.

Assume a scanned receipt will eventually contain text trying to steer the
model. The control is capability, not instruction.
"""

from fastapi import APIRouter

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/query", tags=["query"])


@router.post("")
async def natural_language_query(payload: dict, workspace_id: WorkspaceId, db: Db):
    """Answer a question about the ledger.

    Returns the rows and the SQL that produced them: an accounting answer the
    user cannot audit is worth very little.
    """
    not_implemented("Natural-language ledger query")
