"""Shapes for the chart-of-accounts endpoints."""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel

from .common import OptimisticUpdate

AccountType = Literal["asset", "liability", "equity", "revenue", "expense"]
NormalBalance = Literal["debit", "credit"]
CashFlowCategory = Literal["operating", "investing", "financing"]


class AccountCreate(BaseModel):
    code: str
    name: str
    type: AccountType
    normal_balance: NormalBalance
    parent_account_id: UUID | None = None
    cash_flow_category: CashFlowCategory | None = None


class AccountUpdate(OptimisticUpdate):
    """Renaming, reclassifying for cash flow, or reparenting.

    `type` and `normal_balance` are deliberately absent: changing what side of
    the ledger an account normally sits on does not retroactively make sense
    of the posted entries already filed under it.
    """

    code: str | None = None
    name: str | None = None
    parent_account_id: UUID | None = None
    cash_flow_category: CashFlowCategory | None = None


class Account(BaseModel):
    id: UUID
    workspace_id: UUID
    code: str
    name: str
    type: AccountType
    normal_balance: NormalBalance
    parent_account_id: UUID | None
    cash_flow_category: CashFlowCategory | None
    is_archived: bool
    version: int
