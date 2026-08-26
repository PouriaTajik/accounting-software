"""Shapes for the workspace-membership endpoints."""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, EmailStr

from .common import OptimisticUpdate

Role = Literal["owner", "bookkeeper", "viewer"]


class AddMember(BaseModel):
    email: EmailStr
    role: Role


class UpdateMemberRole(OptimisticUpdate):
    role: Role


class Member(BaseModel):
    user_id: UUID
    role: Role
    version: int
    email: str
    display_name: str | None
