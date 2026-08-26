"""Registration, login, logout, and "who am I"."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Request, Response

from ..config import Settings
from ..core import auth as auth_core
from ..deps import Config, CurrentUser, Db
from ..mail import send_mail
from ..schemas.auth import (
    LoginRequest,
    Me,
    Membership,
    PasswordResetConfirm,
    PasswordResetRequest,
    RegisterRequest,
    User,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _set_session_cookie(response: Response, settings: Settings, raw_token: str) -> None:
    response.set_cookie(
        key=settings.session_cookie_name,
        value=raw_token,
        httponly=True,
        samesite="lax",
        # LOCAL mode is plain http://127.0.0.1 (the desktop shell's embedded
        # API, no TLS) -- `secure=True` there would make the browser silently
        # refuse to store the cookie at all. SERVER mode is assumed to sit
        # behind TLS termination, so it gets the real flag.
        secure=settings.is_multi_tenant,
        max_age=settings.session_ttl_days * 24 * 60 * 60,
        path="/",
    )


@router.post("/register", status_code=201, response_model=User)
async def register(payload: RegisterRequest, response: Response, db: Db, settings: Config):
    """Create a user and log them in immediately -- one step, not a signup
    followed by a separate login (BUSINESS_PRINCIPLES.md's least-steps rule
    applies to auth too, not just ledger data entry)."""
    async with db.auth() as connection:
        user = await auth_core.register(
            connection,
            email=payload.email,
            password=payload.password,
            display_name=payload.display_name,
        )
        raw_token, _session = await auth_core.create_session(
            connection, user_id=user["id"], ttl_days=settings.session_ttl_days
        )
    _set_session_cookie(response, settings, raw_token)
    return user


@router.post("/login", response_model=User)
async def login(payload: LoginRequest, response: Response, db: Db, settings: Config):
    async with db.auth() as connection:
        user = await auth_core.authenticate(
            connection, email=payload.email, password=payload.password
        )
        raw_token, _session = await auth_core.create_session(
            connection, user_id=user["id"], ttl_days=settings.session_ttl_days
        )
    _set_session_cookie(response, settings, raw_token)
    return user


@router.post("/logout", status_code=204)
async def logout(request: Request, response: Response, db: Db, settings: Config):
    raw_token = request.cookies.get(settings.session_cookie_name)
    if raw_token is not None:
        async with db.auth() as connection:
            await auth_core.revoke_session(connection, raw_token=raw_token)
    response.delete_cookie(key=settings.session_cookie_name, path="/")


@router.get("/me", response_model=Me)
async def get_me(user: CurrentUser, db: Db):
    async with db.auth() as connection:
        memberships = await auth_core.list_memberships(connection, user_id=user["id"])
    return Me(
        user=User(**user),
        memberships=[Membership(**m) for m in memberships],
    )


@router.post("/password-reset/request", status_code=202)
async def request_password_reset(payload: PasswordResetRequest, db: Db, settings: Config):
    """Always the same response whether or not the email matched a real
    account -- returning anything else would be an email-enumeration oracle,
    the same reasoning `authenticate`'s decoy hash exists for."""
    async with db.auth() as connection:
        result = await auth_core.request_password_reset(
            connection, email=payload.email, ttl_minutes=settings.password_reset_ttl_minutes
        )

    if result is not None:
        raw_token, user = result
        link = f"{settings.app_base_url}/reset-password?token={raw_token}"
        body = (
            "Use this link, or paste the token into the app's reset-password "
            f"screen, to set a new password (expires in "
            f"{settings.password_reset_ttl_minutes} minutes):\n\n"
            f"{link}\n\ntoken: {raw_token}"
        )
        await asyncio.to_thread(
            send_mail, settings, to=user["email"], subject="Reset your password", body=body
        )

    return {"detail": "If that email is registered, a reset link has been sent."}


@router.post("/password-reset/confirm", status_code=204)
async def confirm_password_reset(payload: PasswordResetConfirm, db: Db):
    async with db.auth() as connection:
        await auth_core.reset_password(
            connection, raw_token=payload.token, new_password=payload.new_password
        )
