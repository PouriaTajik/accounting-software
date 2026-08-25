"""Command-line entry point for schema migrations.

    python -m accounting_api.migrate [--dry-run] [--baseline] [--dir PATH]

Reads the database URL from the same settings the app uses, so there is no
second place to configure it. Exits non-zero on any drift or failure -- a
deploy script or an Electron startup sequence should treat that as fatal and
refuse to serve.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

import asyncpg

from .config import get_settings
from .migrations import MigrationError, default_migrations_dir, migrate


async def _run(directory: Path, *, baseline: bool, dry_run: bool) -> int:
    settings = get_settings()
    connection = await asyncpg.connect(settings.database_url)
    try:
        applied = await migrate(
            connection, directory, baseline=baseline, dry_run=dry_run
        )
    finally:
        await connection.close()

    if not applied:
        print("schema is up to date")
        return 0

    verb = "would apply" if dry_run else ("baselined" if baseline else "applied")
    print(f"{verb} {len(applied)} migration(s):")
    for migration in applied:
        print(f"  {migration}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="accounting-migrate")
    parser.add_argument(
        "--dir",
        type=Path,
        default=default_migrations_dir(),
        help="migrations directory (default: db/migrations)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be applied, change nothing",
    )
    parser.add_argument(
        "--baseline",
        action="store_true",
        help=(
            "record pending migrations as applied WITHOUT running them, for a "
            "database whose schema predates this runner. Wrong in every other case."
        ),
    )
    args = parser.parse_args(argv)

    try:
        return asyncio.run(
            _run(args.dir, baseline=args.baseline, dry_run=args.dry_run)
        )
    except MigrationError as error:
        print(f"migration failed: {error}", file=sys.stderr)
        return 1
    except asyncpg.PostgresError as error:
        print(f"migration failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
