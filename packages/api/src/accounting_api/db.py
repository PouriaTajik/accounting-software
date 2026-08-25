"""Database access.

Deliberately thin, and deliberately not an ORM. `db/schema.sql` is the source
of truth for the schema; a declarative model layer would become a second,
drifting description of it, and the correctness rules that matter here live in
triggers an ORM cannot express anyway.

Two pools, because the natural-language query feature must not be able to
write no matter what the model emits:

  * `pool`          -- the `accounting_app` role from db/roles.sql: read/write,
                       used by every normal request, and deliberately NOT the
                       owner of the tables so that row-level security binds to
                       it. See `_assert_row_security_enforced`.
  * `nl_query_pool` -- the `nl_query` role from db/roles.sql: read-only
                       transactions, 10s statement timeout, and visibility
                       limited to the `ledger_query` schema.

Both are scoped per request by `app.workspace_id`. Since migration 0004 that
setting is not a convention the queries cooperate with -- it is what the
row-level security policies compare against, so a query that forgets its
WHERE clause returns its own tenant's rows rather than everyone's.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING
from uuid import UUID

import asyncpg

if TYPE_CHECKING:
    from .config import Settings

logger = logging.getLogger(__name__)


class Database:
    """Owns the connection pools for the process lifetime."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._pool: asyncpg.Pool | None = None
        self._nl_query_pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        self._pool = await asyncpg.create_pool(
            self._settings.database_url,
            min_size=self._settings.db_pool_min_size,
            max_size=self._settings.db_pool_max_size,
        )
        async with self._pool.acquire() as connection:
            await self._assert_row_security_enforced(connection)

        if self._settings.nl_query_database_url:
            self._nl_query_pool = await asyncpg.create_pool(
                self._settings.nl_query_database_url,
                min_size=0,
                max_size=4,
            )

    async def _assert_row_security_enforced(
        self, connection: asyncpg.Connection
    ) -> None:
        """Refuse to serve on a connection that row-level security cannot bind.

        A table's owner is exempt from its own policies, and so is a superuser
        or a role holding BYPASSRLS. Connect the API as any of those and every
        policy in migration 0004 stays in place and does nothing -- tenant
        isolation silently reverts to "whatever the WHERE clause remembered".
        There is no error and no log line; it just quietly stops being true.

        So it is checked once, at startup, against the database rather than
        against configuration. `row_security_active` answers the question
        directly: is RLS being applied to *me*, for this table, right now.
        """
        role, is_superuser, bypasses, enforced = await connection.fetchrow(
            """
            SELECT current_user,
                   rolsuper,
                   rolbypassrls,
                   row_security_active('journal_lines')
              FROM pg_roles WHERE rolname = current_user
            """
        )

        if enforced:
            return

        reason = (
            "is a superuser"
            if is_superuser
            else "holds BYPASSRLS"
            if bypasses
            else "owns the table, and a table's owner is exempt from its own policies"
        )
        message = (
            f"row-level security is not enforced for role {role!r}: it {reason}. "
            f"Tenant isolation would depend entirely on every query remembering "
            f"its WHERE clause. Connect as the non-owner application role from "
            f"db/roles.sql (accounting_app)."
        )

        if self._settings.is_multi_tenant:
            raise RuntimeError(message)

        # LOCAL mode is a single workspace on one person's machine, where the
        # embedded Postgres may reasonably have only the owner role. The
        # warning still matters: it is the same build, and the misconfiguration
        # travels if the deployment mode is ever flipped.
        logger.warning("%s", message)

    async def disconnect(self) -> None:
        for pool in (self._pool, self._nl_query_pool):
            if pool is not None:
                await pool.close()
        self._pool = None
        self._nl_query_pool = None

    @property
    def is_connected(self) -> bool:
        return self._pool is not None

    @asynccontextmanager
    async def workspace(self, workspace_id: UUID) -> AsyncIterator[asyncpg.Connection]:
        """A transaction scoped to one workspace.

        Sets `app.workspace_id` for the transaction. Since migration 0004 this
        is the tenant boundary itself, not a convenience: the row-level
        security policies compare every row against it, so a statement issued
        inside this block cannot read or write another tenant even if it names
        no workspace at all.

        Transaction-local (`set_config(..., true)`, i.e. `SET LOCAL`) is
        load-bearing rather than tidy. A session-level `SET` would outlive the
        transaction and still be in place for the next borrower of this pooled
        connection, which under pgbouncer in transaction mode is a different
        request for a different tenant.
        """
        if self._pool is None:
            raise RuntimeError("Database.connect() has not been called")

        async with self._pool.acquire() as connection, connection.transaction():
            await connection.execute(
                "SELECT set_config('app.workspace_id', $1, true)",
                str(workspace_id),
            )
            yield connection

    @asynccontextmanager
    async def read_only(self, workspace_id: UUID) -> AsyncIterator[asyncpg.Connection]:
        """A connection for executing generated text-to-SQL.

        Falls back to the read/write pool only when no `nl_query` URL is
        configured, and refuses to do so outside LOCAL mode -- running
        model-generated SQL as the app role against a multi-tenant database is
        exactly the failure this separation exists to prevent.
        """
        if self._nl_query_pool is None:
            if self._settings.is_multi_tenant:
                raise RuntimeError(
                    "nl_query_database_url is required in server mode: generated SQL "
                    "must not run as the application role. See db/roles.sql."
                )
            async with self.workspace(workspace_id) as connection:
                yield connection
            return

        async with (
            self._nl_query_pool.acquire() as connection,
            connection.transaction(readonly=True),
        ):
            await connection.execute(
                "SELECT set_config('app.workspace_id', $1, true)",
                str(workspace_id),
            )
            yield connection

    async def ping(self) -> bool:
        if self._pool is None:
            return False
        return await self._pool.fetchval("SELECT 1") == 1
