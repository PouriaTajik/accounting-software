"""Chart of accounts.

No Postgres: what is worth testing here is the part that is decided in Python.
The database owns the rules that matter -- uniqueness, the type and
normal_balance domains, tenant isolation -- and db/verify_schema.sql and
db/verify_rls.sql already prove those against a real one.
"""

from __future__ import annotations

from uuid import uuid4

import pytest

from accounting_api.core import accounts as accounts_core
from accounting_api.errors import DuplicateKey, translate_database_error
from accounting_api.schemas.accounts import AccountUpdate


class _FakePostgresError(Exception):
    def __init__(self, sqlstate: str, message: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate
        self.message = message


def test_duplicate_account_code_is_user_error_not_a_500() -> None:
    # Two accounts sharing a code within a workspace is something a user can
    # type, so it has to come back as a 409 they can act on.
    error = translate_database_error(
        _FakePostgresError(
            "23505",
            'duplicate key value violates unique constraint "accounts_workspace_id_code_key"',
        )
    )
    assert isinstance(error, DuplicateKey)
    assert error.status_code == 409


async def test_update_refuses_a_column_it_does_not_own() -> None:
    """`**fields` keys become SQL identifiers, so the whitelist is load-bearing."""
    with pytest.raises(ValueError, match="not updatable: workspace_id"):
        await accounts_core.update_account(
            None,  # never reached
            uuid4(),
            expected_version=1,
            workspace_id=uuid4(),
        )


def test_type_and_normal_balance_are_not_editable() -> None:
    """Changing which side of the ledger an account sits on does not
    retroactively make sense of entries already posted against it."""
    assert "type" not in AccountUpdate.model_fields
    assert "normal_balance" not in AccountUpdate.model_fields
