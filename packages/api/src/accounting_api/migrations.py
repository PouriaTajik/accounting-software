"""Schema migrations.

Numbered SQL files applied in order, tracked in a `schema_migrations` table.
No ORM, no autogenerate: the DDL in `db/migrations/` is hand-written because
the correctness rules that matter here are triggers and composite foreign keys
that no model layer would produce.

The design is shaped by the desktop target, which is the hard case. Migrations
do not run on a server we control -- they run on user machines, offline,
possibly skipping many versions at once, with nobody to fix a half-applied
schema. So:

  * **Forward-only.** There are no down-migrations. You cannot un-ship a
    version a user has already run, so a rollback path is a fiction that
    invites careless migrations. Correcting a bad migration means writing the
    next one.
  * **One transaction per migration.** Postgres has transactional DDL, so a
    migration either lands completely or not at all. A migration that cannot
    run inside a transaction (`CREATE INDEX CONCURRENTLY`) opts out with a
    `-- migrate:no-transaction` marker and accepts that it may half-apply.
  * **Fail closed.** Any drift, gap, or unknown version aborts before applying
    anything. The caller is expected to refuse to serve requests rather than
    run against a schema it does not recognise.
  * **Serialized by advisory lock**, so two app instances starting at once (or
    two Electron windows racing) cannot apply the same migration twice.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg

#: Arbitrary but fixed. Any process applying migrations to a database takes
#: this lock first, so concurrent starts serialize instead of racing.
MIGRATION_LOCK_ID = 0x4143434E  # "ACCN"

#: `0007_add_fiscal_periods.sql` -> version 7, name "add_fiscal_periods".
_FILENAME = re.compile(r"^(?P<version>\d{4})_(?P<name>[a-z0-9_]+)\.sql$")

#: A migration that must run outside a transaction says so on its own line.
_NO_TRANSACTION = re.compile(r"^--\s*migrate:no-transaction\s*$", re.MULTILINE)


class MigrationError(RuntimeError):
    """Raised for any condition that must stop the process before it serves."""


@dataclass(frozen=True)
class Migration:
    version: int
    name: str
    path: Path
    sql: str
    checksum: str
    in_transaction: bool

    def __str__(self) -> str:
        return f"{self.version:04d}_{self.name}"


def default_migrations_dir() -> Path:
    """`db/migrations/` relative to the repo root.

    NOTE for packaging: a desktop build must ship this directory alongside the
    Python code, or set ACCOUNTING_MIGRATIONS_DIR. An app that cannot find its
    migrations must fail loudly at startup -- never start against whatever
    schema happens to be there.
    """
    return Path(__file__).resolve().parents[4] / "db" / "migrations"


def discover(directory: Path) -> list[Migration]:
    """Read and validate the migration set on disk.

    Rejects duplicate and non-contiguous version numbers. The gap check is
    what stops two branches from each adding an `0005_` and both merging: the
    numbers are the ordering, so a collision has to be resolved by a human
    renaming one, not silently by filesystem order.
    """
    if not directory.is_dir():
        raise MigrationError(f"migrations directory not found: {directory}")

    migrations: list[Migration] = []
    seen: dict[int, Path] = {}

    for path in sorted(directory.glob("*.sql")):
        match = _FILENAME.match(path.name)
        if match is None:
            raise MigrationError(
                f"{path.name}: expected NNNN_lower_snake_name.sql "
                f"(four digits, underscore, lowercase name)"
            )

        version = int(match["version"])
        if version in seen:
            raise MigrationError(
                f"duplicate migration version {version:04d}: "
                f"{seen[version].name} and {path.name}"
            )
        if version == 0:
            raise MigrationError(f"{path.name}: versions start at 0001")
        seen[version] = path

        sql = path.read_text(encoding="utf-8")
        migrations.append(
            Migration(
                version=version,
                name=match["name"],
                path=path,
                sql=sql,
                checksum=hashlib.sha256(sql.encode("utf-8")).hexdigest(),
                in_transaction=_NO_TRANSACTION.search(sql) is None,
            )
        )

    migrations.sort(key=lambda m: m.version)
    for expected, migration in enumerate(migrations, start=1):
        if migration.version != expected:
            raise MigrationError(
                f"migration versions must be contiguous from 0001: "
                f"expected {expected:04d}, found {migration.version:04d} "
                f"({migration.path.name})"
            )
    return migrations


async def ensure_bookkeeping_table(connection: asyncpg.Connection) -> None:
    await connection.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version      integer PRIMARY KEY,
            name         text        NOT NULL,
            checksum     text        NOT NULL,
            applied_at   timestamptz NOT NULL DEFAULT now(),
            duration_ms  integer     NOT NULL
        )
        """
    )


async def applied_versions(connection: asyncpg.Connection) -> dict[int, str]:
    rows = await connection.fetch("SELECT version, checksum FROM schema_migrations")
    return {row["version"]: row["checksum"] for row in rows}


def _check_consistency(
    migrations: list[Migration], applied: dict[int, str]
) -> list[Migration]:
    """Compare disk against the database, and return what is still pending.

    Three failure modes, all fatal, all worth distinguishing in the message --
    at 2am on a user's machine the difference between "you edited a migration"
    and "you downgraded the app" is the whole diagnosis.
    """
    on_disk = {m.version: m for m in migrations}

    unknown = sorted(set(applied) - set(on_disk))
    if unknown:
        raise MigrationError(
            f"database has migrations this build does not ship: "
            f"{', '.join(f'{v:04d}' for v in unknown)}. "
            f"This usually means the application was downgraded. Forward-only "
            f"migrations cannot undo these -- install the newer build."
        )

    for version, checksum in sorted(applied.items()):
        migration = on_disk[version]
        if migration.checksum != checksum:
            raise MigrationError(
                f"{migration}: file has changed since it was applied "
                f"(recorded {checksum[:12]}, found {migration.checksum[:12]}). "
                f"An applied migration is history and must not be edited -- "
                f"write the next migration instead."
            )

    return [m for m in migrations if m.version not in applied]


async def _apply(connection: asyncpg.Connection, migration: Migration) -> int:
    started = await connection.fetchval("SELECT clock_timestamp()")
    await connection.execute(migration.sql)
    duration_ms = int(
        await connection.fetchval(
            "SELECT extract(milliseconds FROM (clock_timestamp() - $1::timestamptz))",
            started,
        )
    )
    await connection.execute(
        """
        INSERT INTO schema_migrations (version, name, checksum, duration_ms)
        VALUES ($1, $2, $3, $4)
        """,
        migration.version,
        migration.name,
        migration.checksum,
        duration_ms,
    )
    return duration_ms


async def migrate(
    connection: asyncpg.Connection,
    directory: Path | None = None,
    *,
    baseline: bool = False,
    dry_run: bool = False,
) -> list[Migration]:
    """Apply every pending migration in order. Returns what was applied.

    `baseline` records the pending migrations as applied WITHOUT running them,
    for adopting a database whose schema was created before this runner
    existed. It is a one-time escape hatch and wrong in every other situation.

    `dry_run` reports what would be applied and changes nothing.
    """
    migrations = discover(directory or default_migrations_dir())

    await connection.execute("SELECT pg_advisory_lock($1)", MIGRATION_LOCK_ID)
    try:
        await ensure_bookkeeping_table(connection)
        pending = _check_consistency(migrations, await applied_versions(connection))

        if dry_run:
            return pending

        for migration in pending:
            if baseline:
                await connection.execute(
                    """
                    INSERT INTO schema_migrations (version, name, checksum, duration_ms)
                    VALUES ($1, $2, $3, 0)
                    """,
                    migration.version,
                    migration.name,
                    migration.checksum,
                )
            elif migration.in_transaction:
                async with connection.transaction():
                    await _apply(connection, migration)
            else:
                # Opted out of the all-or-nothing guarantee deliberately.
                await _apply(connection, migration)

        return pending
    finally:
        await connection.execute("SELECT pg_advisory_unlock($1)", MIGRATION_LOCK_ID)
