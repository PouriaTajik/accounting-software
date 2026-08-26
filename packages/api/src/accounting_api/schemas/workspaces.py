"""Shapes for the workspaces endpoints."""

from __future__ import annotations

from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from .common import OptimisticUpdate

FiscalCalendar = Literal["gregorian", "solar_hijri"]


class WorkspaceCreate(BaseModel):
    name: str
    #: Validated against `currencies` by a foreign key at the database, not
    #: constrained to a Literal here -- the supported set is reference data,
    #: not something a schema change should be needed to extend.
    base_currency: str = "USD"
    fiscal_calendar: FiscalCalendar = "gregorian"


class WorkspaceUpdate(OptimisticUpdate):
    """`display_unit`, `display_exponent` and `books_locked_through` may be
    sent explicitly as `null` to clear them -- unlocking the books, or
    dropping a display-unit shift, is a real operation, not a no-op."""

    name: str | None = None
    base_currency: str | None = None
    fiscal_calendar: FiscalCalendar | None = None
    display_unit: str | None = None
    display_exponent: int | None = Field(default=None, ge=0, le=6)
    books_locked_through: date | None = None


class Workspace(BaseModel):
    id: UUID
    name: str
    base_currency: str
    fiscal_calendar: FiscalCalendar
    display_unit: str | None
    display_exponent: int
    books_locked_through: date | None
    version: int
