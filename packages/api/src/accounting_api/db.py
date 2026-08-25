"""Database access.

Deliberately thin, and deliberately not an ORM. `db/schema.sql` is the source
of truth for the schema; a declarative model layer would become a second,
drifting description of it, and the correctness rules that matter here live in
triggers an ORM cannot express anyway.

Two pools, because the natural-language query feature must not be able to
write no matter what the model emits:

  * `pool`          -- the app role, read/write, used by every normal request.
  * `nl_query_pool` -- the `nl_query` role from db/roles.sql: read-only
                       transactions, 10s statement timeout, and visibility
                       limited to the `ledger_query` schema.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING
from uuid import UUID

import asyncpg

if TYPE_CHECKING:
    from .config import Settings


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
        if self._settings.nl_query_database_url:
            self._nl_query_pool = await asyncpg.create_pool(
                self._settings.nl_query_database_url,
                min_size=0,
                max_size=4,
            )

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

        Sets `app.workspace_id` for the transaction, which is what the
        `ledger_query` views filter on. `SET LOCAL` means it cannot leak to the
        next borrower of this pooled connection.
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
