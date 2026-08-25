"""Anomaly flags.

Statistics detect; the model only explains. A z-score/IQR/duplicate check
produces the flag, and AIProvider writes the sentence a human reads -- so
detection stays cheap, deterministic, and available offline.
"""

from uuid import UUID

from fastapi import APIRouter

from ..deps import Db, WorkspaceId, not_implemented

router = APIRouter(prefix="/anomalies", tags=["anomalies"])


@router.get("")
async def list_anomalies(workspace_id: WorkspaceId, db: Db, resolved: bool = False):
    """Surfaced inline in the transaction list, not in a separate inbox nobody
    remembers to open."""
    not_implemented("Listing anomaly flags")


@router.post("/scan", status_code=202)
async def scan_for_anomalies(payload: dict, workspace_id: WorkspaceId, db: Db):
    not_implemented("Scanning for anomalies")


@router.post("/{flag_id}/resolve")
async def resolve_anomaly(flag_id: UUID, payload: dict, workspace_id: WorkspaceId, db: Db):
    """Explanation and fix are one action, not two screens."""
    not_implemented("Resolving an anomaly flag")
