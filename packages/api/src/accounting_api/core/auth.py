"""Identity: registration, login, and session lifecycle.

Every function here takes a connection from `Database.auth()` (accounting_auth,
db/roles.sql) -- never the ordinary workspace-scoped connection every other
module in this package uses. Identity is global (db/README.md, "Identity"):
a user and their sessions are not tenant data, and none of the reads or
writes below take a `workspace_id` at all.
"""

from __future__ import annotations

import hashlib
import secrets
from datetime import timedelta
from typing import TYPE_CHECKING, Any
from uuid import UUID

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from ..errors import InvalidCredentials, InvalidResetToken

if TYPE_CHECKING:
    import asyncpg

_hasher = PasswordHasher()

# Verified against on every login attempt for an email that doesn't exist,
# so that "no such user" and "wrong password" take roughly the same amount
# of time -- the response is identical either way (InvalidCredentials), and
# without this a timing difference would still let an attacker enumerate
# registered addresses one request at a time.
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(32))

#: Selected with a `u.` prefix wherever the query joins another table that
#: also has an `id`/`version`/`created_at`/`updated_at` column (sessions,
#: user_credentials both do) -- spelled out rather than built by string
#: manipulation, so an ambiguous-column bug shows up as a syntax error where
#: it's written, not silently at query time.
_USER_COLUMNS = """
    u.id, u.email, u.display_name, u.is_active, u.version, u.created_at, u.updated_at
"""


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def _verify_password(password_hash: str, password: str) -> bool:
    try:
        _hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False
    return True


def _hash_token(raw_token: str) -> str:
    # A session token is 256 bits of secrets.token_urlsafe randomness, not a
    # human-chosen secret -- unlike a password, it has no low-entropy cases
    # to defend against, so a fast hash is the right tool: the property
    # wanted here is "a stolen database row doesn't hand out a live
    # session", not "expensive to brute-force", and a fast hash still gets
    # that for free at this entropy.
    return hashlib.sha256(raw_token.encode()).hexdigest()


async def register(
    connection: asyncpg.Connection,
    *,
    email: str,
    password: str,
    display_name: str | None = None,
) -> dict[str, Any]:
    """Create a user and their credentials in one transaction.

    Duplicate email surfaces through `translate_database_error` as the
    existing `DuplicateKey` -- `uq_users_email_lower` (migration 0003)
    already enforces it, so no new mapping is needed here.
    """
    user = await connection.fetchrow(
        f"""
        INSERT INTO users AS u (email, display_name)
        VALUES ($1, $2)
        RETURNING {_USER_COLUMNS}
        """,
        email,
        display_name,
    )
    await connection.execute(
        "INSERT INTO user_credentials (user_id, password_hash) VALUES ($1, $2)",
        user["id"],
        hash_password(password),
    )
    return dict(user)


async def authenticate(
    connection: asyncpg.Connection, *, email: str, password: str
) -> dict[str, Any]:
    row = await connection.fetchrow(
        f"""
        SELECT {_USER_COLUMNS}, c.password_hash
          FROM users u
          JOIN user_credentials c ON c.user_id = u.id
         WHERE lower(u.email) = lower($1)
        """,
        email,
    )

    if row is None or not row["is_active"]:
        _verify_password(_DUMMY_HASH, password)  # constant-time-ish decoy
        raise InvalidCredentials("incorrect email or password")

    if not _verify_password(row["password_hash"], password):
        raise InvalidCredentials("incorrect email or password")

    user = dict(row)
    del user["password_hash"]
    return user


async def create_session(
    connection: asyncpg.Connection, *, user_id: UUID, ttl_days: int
) -> tuple[str, dict[str, Any]]:
    """Returns `(raw_token, session_row)`. The raw token is handed to the
    caller once, to go into a Set-Cookie header -- only its hash is stored."""
    raw_token = secrets.token_urlsafe(32)
    session = await connection.fetchrow(
        """
        INSERT INTO sessions (user_id, token_hash, expires_at)
        VALUES ($1, $2, now() + $3::interval)
        RETURNING id, user_id, created_at, expires_at
        """,
        user_id,
        _hash_token(raw_token),
        timedelta(days=ttl_days),
    )
    return raw_token, dict(session)


async def resolve_session(
    connection: asyncpg.Connection, *, raw_token: str
) -> dict[str, Any] | None:
    """The current user for a raw session token, or None if it's missing,
    expired, revoked, or belongs to a deactivated user."""
    row = await connection.fetchrow(
        f"""
        SELECT {_USER_COLUMNS}
          FROM sessions s
          JOIN users u ON u.id = s.user_id
         WHERE s.token_hash = $1
           AND s.revoked_at IS NULL
           AND s.expires_at > now()
           AND u.is_active
        """,
        _hash_token(raw_token),
    )
    return dict(row) if row is not None else None


async def revoke_session(connection: asyncpg.Connection, *, raw_token: str) -> None:
    await connection.execute(
        "UPDATE sessions SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
        _hash_token(raw_token),
    )


async def request_password_reset(
    connection: asyncpg.Connection, *, email: str, ttl_minutes: int
) -> tuple[str, dict[str, Any]] | None:
    """Returns `(raw_token, user)` if `email` matches an active user, else
    `None`. The caller (routers/auth.py) must send the same response either
    way regardless -- returning `None` here is a signal for "don't send
    mail", not something that may leak into an HTTP response, or this
    becomes exactly the email-enumeration hole `authenticate`'s decoy hash
    exists to avoid."""
    user = await connection.fetchrow(
        "SELECT id, email, is_active FROM users WHERE lower(email) = lower($1)",
        email,
    )
    if user is None or not user["is_active"]:
        return None

    raw_token = secrets.token_urlsafe(32)
    await connection.execute(
        """
        INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
        VALUES ($1, $2, now() + $3::interval)
        """,
        user["id"],
        _hash_token(raw_token),
        timedelta(minutes=ttl_minutes),
    )
    return raw_token, dict(user)


async def reset_password(
    connection: asyncpg.Connection, *, raw_token: str, new_password: str
) -> None:
    """Consume a reset token: set the new password, mark the token used, and
    revoke every existing session for the user. A password reset is exactly
    the moment a stolen session should stop working too, not just future
    logins with the old password -- otherwise resetting a compromised
    password wouldn't actually end the compromise."""
    row = await connection.fetchrow(
        """
        SELECT user_id FROM password_reset_tokens
         WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()
        """,
        _hash_token(raw_token),
    )
    if row is None:
        raise InvalidResetToken("this reset link is invalid or has expired")

    await connection.execute(
        "UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = $1",
        _hash_token(raw_token),
    )
    await connection.execute(
        "UPDATE user_credentials SET password_hash = $1 WHERE user_id = $2",
        hash_password(new_password),
        row["user_id"],
    )
    await connection.execute(
        "UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL",
        row["user_id"],
    )


async def list_memberships(
    connection: asyncpg.Connection, *, user_id: UUID
) -> list[dict[str, Any]]:
    """Every workspace this user belongs to, and their role in each. Backs
    `GET /auth/me` -- what a client needs to know to offer a workspace
    picker without a separate round trip per workspace."""
    rows = await connection.fetch(
        "SELECT workspace_id, role FROM workspace_members WHERE user_id = $1",
        user_id,
    )
    return [dict(row) for row in rows]
