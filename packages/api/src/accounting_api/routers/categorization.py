"""Categorization rules, and the categorize call itself.

Order matters for cost and for offline quality: the `categorization_rules`
table is consulted first, and AIProvider is the fallback for what it misses --
never a model call per transaction.
"""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(tags=["categorization"])


@router.get("/categorization-rules")
async def list_rules(workspace_id: WorkspaceId, db: Db):
    not_implemented("Listing categorization rules")


@router.post("/categorization-rules", status_code=201)
async def create_rule(payload: dict, workspace_id: WorkspaceId, db: Db):
    not_implemented("Creating a categorization rule")


@router.patch("/categorization-rules/{rule_id}")
async def update_rule(rule_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    not_implemented("Updating a categorization rule")


@router.delete("/categorization-rules/{rule_id}", status_code=204)
async def delete_rule(rule_id: UUID, workspace_id: WorkspaceId, db: Db):
    not_implemented("Deleting a categorization rule")


@router.post("/categorize")
async def categorize(payload: dict, workspace_id: WorkspaceId, db: Db):
    """Rules first, model second.

    Returns the account and which path decided it, so the UI can distinguish a
    rule hit from a model guess.
    """
    not_implemented("Categorizing transactions")


@router.post("/categorize/correct")
async def correct_categorization(payload: dict, workspace_id: WorkspaceId, db: Db):
    """A user's correction becomes a rule here.

    No separate rule-creation step (BUSINESS_PRINCIPLES.md): the correction is
    itself the teaching signal.
    """
    not_implemented("Correcting a categorization")
