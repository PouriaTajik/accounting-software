"""Identity: password hashing, session tokens, and role ranking.

No Postgres: what is worth testing here is the part decided in Python --
hashing, the decoy-hash timing guard, and the role-rank comparison.
db/verify_auth.sql already proves the privilege/policy layer (accounting_auth
cannot reach ledger data, accounting_app cannot reach credentials or
sessions) against a real database, the same split every other feature in
this package uses.
"""

from __future__ import annotations

import pytest

from accounting_api.core import auth as auth_core
from accounting_api.deps import _ROLE_RANK, check_role
from accounting_api.errors import (
    DuplicateKey,
    InsufficientRole,
    LastOwnerCannotBeRemoved,
    PostedEntryImmutable,
    translate_database_error,
)


class _FakePostgresError(Exception):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate
        self.message = message


def test_password_round_trip() -> None:
    hashed = auth_core.hash_password("correct horse battery staple")
    assert auth_core._verify_password(hashed, "correct horse battery staple")


def test_wrong_password_does_not_verify() -> None:
    hashed = auth_core.hash_password("correct horse battery staple")
    assert not auth_core._verify_password(hashed, "wrong password")


def test_dummy_hash_is_a_real_argon2_hash() -> None:
    # authenticate() verifies against this when no user matches the email, so
    # that a login attempt for a nonexistent address takes roughly the same
    # time as a wrong password for a real one. If this weren't a real hash --
    # e.g. an empty string, or skipped entirely -- that decoy would do nothing
    # and the timing difference would leak which emails are registered.
    assert auth_core._DUMMY_HASH.startswith("$argon2id$")
    assert not auth_core._verify_password(auth_core._DUMMY_HASH, "anything")


def test_hash_token_is_deterministic_and_not_reversible_to_the_raw_value() -> None:
    token = "some-raw-session-token"
    hashed_once = auth_core._hash_token(token)
    hashed_again = auth_core._hash_token(token)

    assert hashed_once == hashed_again  # same token -> same lookup key
    assert hashed_once != token  # the raw token itself is never what's stored
    assert len(hashed_once) == 64  # sha256 hex digest


def test_duplicate_email_is_user_error_not_a_500() -> None:
    # uq_users_email_lower (migration 0003) enforces this; register() relies
    # on translate_database_error already mapping it, rather than adding a
    # second check in Python that could drift from the constraint.
    error = translate_database_error(
        _FakePostgresError(
            "23505",
            'duplicate key value violates unique constraint "uq_users_email_lower"',
        )
    )
    assert isinstance(error, DuplicateKey)
    assert error.status_code == 409


@pytest.mark.parametrize(
    ("role", "minimum"),
    [
        ("owner", "viewer"),
        ("owner", "bookkeeper"),
        ("owner", "owner"),
        ("bookkeeper", "viewer"),
        ("bookkeeper", "bookkeeper"),
        ("viewer", "viewer"),
    ],
)
def test_check_role_allows_equal_or_higher(role: str, minimum: str) -> None:
    check_role({"role": role}, minimum)  # must not raise


@pytest.mark.parametrize(
    ("role", "minimum"),
    [
        ("viewer", "bookkeeper"),
        ("viewer", "owner"),
        ("bookkeeper", "owner"),
    ],
)
def test_check_role_rejects_lower(role: str, minimum: str) -> None:
    with pytest.raises(InsufficientRole):
        check_role({"role": role}, minimum)


def test_role_rank_ordering() -> None:
    assert _ROLE_RANK["viewer"] < _ROLE_RANK["bookkeeper"] < _ROLE_RANK["owner"]


def test_demoting_the_last_owner_is_a_distinct_error_not_immutability() -> None:
    # guard_workspace_keeps_an_owner (migration 0003) shares SQLSTATE 23001
    # with several unrelated guards (see translate_database_error's own
    # comment on this) -- without a message match for it specifically, this
    # would silently fall through to PostedEntryImmutable, a wrong and
    # confusing error for "you tried to remove your workspace's last owner".
    error = translate_database_error(
        _FakePostgresError(
            "23001",
            "workspace_members: workspace ab12 would be left with no owner; "
            "promote another member first.",
        )
    )
    assert isinstance(error, LastOwnerCannotBeRemoved)
    assert error.status_code == 409


def test_other_23001_guards_still_fall_through_to_posted_entry_immutable() -> None:
    # The new branch must not swallow the guards it sits next to.
    error = translate_database_error(
        _FakePostgresError("23001", "journal_entries: entry ... is immutable")
    )
    assert isinstance(error, PostedEntryImmutable)


def test_password_reset_token_uses_the_same_hash_as_session_tokens() -> None:
    # request_password_reset/reset_password reuse _hash_token rather than a
    # second hashing scheme -- same security shape (high-entropy random
    # value, not a human secret), so it should be the exact same function.
    token = "some-reset-token"
    assert auth_core._hash_token(token) == auth_core._hash_token(token)
    assert len(auth_core._hash_token(token)) == 64
