"""The startup guard that refuses a connection row-level security cannot bind.

Migration 0004's policies are exempt for a table's owner, a superuser, and any
role holding BYPASSRLS. Connect the API as one of those and tenant isolation
silently stops existing -- no error, no log line. This guard is the thing that
turns that from silent into loud, so it is worth testing that it actually
fires, and that it names the right cause.

Uses a stub connection rather than a live Postgres: the question here is what
the guard does with each answer, and db/verify_rls.sql already proves the
answers themselves against a real database.
"""

from __future__ import annotations

import logging
from urllib.parse import urlsplit

import pytest

from accounting_api.config import DeploymentMode, Settings
from accounting_api.db import Database


class StubConnection:
    """Returns one canned row for the guard's single query."""

    def __init__(self, *, superuser=False, bypassrls=False, enforced=True) -> None:
        self._row = ("some_role", superuser, bypassrls, enforced)

    async def fetchrow(self, *_args: object) -> tuple[str, bool, bool, bool]:
        return self._row


def database(mode: DeploymentMode = DeploymentMode.SERVER) -> Database:
    return Database(Settings(deployment_mode=mode))


async def test_enforced_connection_is_accepted() -> None:
    await database()._assert_row_security_enforced(StubConnection(enforced=True))


@pytest.mark.parametrize(
    ("kwargs", "expected_cause"),
    [
        ({"superuser": True}, "is a superuser"),
        ({"bypassrls": True}, "holds BYPASSRLS"),
        ({}, "owns the table"),
    ],
)
async def test_server_mode_refuses_an_exempt_connection(
    kwargs: dict[str, bool], expected_cause: str
) -> None:
    connection = StubConnection(enforced=False, **kwargs)

    with pytest.raises(RuntimeError, match="row-level security is not enforced"):
        await database()._assert_row_security_enforced(connection)

    # The three causes need different fixes, so the message has to distinguish
    # them -- "RLS is off" alone sends someone looking in the wrong place.
    with pytest.raises(RuntimeError, match=expected_cause):
        await database()._assert_row_security_enforced(connection)


async def test_local_mode_warns_but_starts(caplog: pytest.LogCaptureFixture) -> None:
    # The desktop app's embedded Postgres may reasonably have only the owner
    # role, and a single-workspace install has no tenant to leak to. It still
    # warns: it is the same build, and the misconfiguration travels if the
    # deployment mode is flipped.
    with caplog.at_level(logging.WARNING):
        await database(DeploymentMode.LOCAL)._assert_row_security_enforced(
            StubConnection(enforced=False)
        )

    assert "row-level security is not enforced" in caplog.text


def test_the_default_database_url_is_not_the_owner_role(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The default exists to make the right thing the easy thing: someone who
    # never sets ACCOUNTING_DATABASE_URL should land on the RLS-bound role, not
    # on the role that owns the tables and is exempt from every policy.
    #
    # Cleared explicitly because Settings reads the environment, and a
    # developer with a database URL exported -- which is exactly what
    # `npm run db:apply` asks for -- would otherwise be testing their shell.
    monkeypatch.delenv("ACCOUNTING_DATABASE_URL", raising=False)
    assert urlsplit(Settings().database_url).username == "accounting_app"
