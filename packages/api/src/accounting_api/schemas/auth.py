"""Shapes for the auth endpoints."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str
    display_name: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class PasswordResetRequest(BaseModel):
    email: EmailStr


class PasswordResetConfirm(BaseModel):
    token: str
    new_password: str


class Membership(BaseModel):
    workspace_id: UUID
    role: str


class User(BaseModel):
    id: UUID
    email: str
    display_name: str | None
    is_active: bool
    version: int
    created_at: datetime
    updated_at: datetime


class Me(BaseModel):
    user: User
    memberships: list[Membership]
