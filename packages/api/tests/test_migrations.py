"""Migration runner tests.

No Postgres: everything here covers the parts that decide whether migrations
are *allowed* to run. Those are the parts that protect a user's books on a
machine nobody can log into, so they are worth testing without needing a
database to be up.

Applying migrations for real is covered by db/verify_schema.sql,
db/verify_roles.sql and db/verify_currency.sql against a live Postgres.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from accounting_api.migrations import (
    MigrationError,
    _check_consistency,
    default_migrations_dir,
    discover,
)


def write(directory: Path, name: str, sql: str = "SELECT 1;") -> Path:
    path = directory / name
    path.write_text(sql, encoding="utf-8")
    return path


# --- the real migration set --------------------------------------------------


def test_the_shipped_migrations_are_valid() -> None:
    migrations = discover(default_migrations_dir())
    assert [m.version for m in migrations] == list(range(1, len(migrations) + 1))
    assert migrations[0].name == "initial_schema"


def test_every_shipped_migration_runs_in_a_transaction() -> None:
    # Not a rule, but opting out gives up all-or-nothing on a user's machine,
    # so a new one should be a deliberate change to this test.
    for migration in discover(default_migrations_dir()):
        assert migration.in_transaction, f"{migration} opts out of its transaction"


# --- discovery ---------------------------------------------------------------


def test_versions_must_be_contiguous(tmp_path: Path) -> None:
    write(tmp_path, "0001_first.sql")
    write(tmp_path, "0003_third.sql")
    with pytest.raises(MigrationError, match="contiguous"):
        discover(tmp_path)


def test_duplicate_versions_are_rejected(tmp_path: Path) -> None:
    # The case that matters: two branches each added an 0002 and both merged.
    write(tmp_path, "0001_first.sql")
    write(tmp_path, "0002_alpha.sql")
    write(tmp_path, "0002_beta.sql")
    with pytest.raises(MigrationError, match="duplicate migration version"):
        discover(tmp_path)


@pytest.mark.parametrize(
    "name",
    [
        "1_first.sql",  # not four digits
        "0001-first.sql",  # hyphen, not underscore
        "0001_First.sql",  # uppercase
        "first.sql",  # no version
    ],
)
def test_malformed_filenames_are_rejected(tmp_path: Path, name: str) -> None:
    write(tmp_path, name)
    with pytest.raises(MigrationError):
        discover(tmp_path)


def test_versions_start_at_one(tmp_path: Path) -> None:
    write(tmp_path, "0000_zeroth.sql")
    with pytest.raises(MigrationError, match="start at 0001"):
        discover(tmp_path)


def test_missing_directory_is_an_error(tmp_path: Path) -> None:
    with pytest.raises(MigrationError, match="not found"):
        discover(tmp_path / "nope")


def test_no_transaction_marker_is_detected(tmp_path: Path) -> None:
    write(tmp_path, "0001_plain.sql", "CREATE TABLE a (x int);")
    write(
        tmp_path,
        "0002_concurrent.sql",
        "-- migrate:no-transaction\nCREATE INDEX CONCURRENTLY i ON a (x);",
    )
    first, second = discover(tmp_path)
    assert first.in_transaction
    assert not second.in_transaction


def test_checksum_tracks_content_not_filename(tmp_path: Path) -> None:
    write(tmp_path, "0001_a.sql", "SELECT 1;")
    before = discover(tmp_path)[0].checksum

    write(tmp_path, "0001_a.sql", "SELECT 2;")
    assert discover(tmp_path)[0].checksum != before


# --- consistency between disk and database -----------------------------------


def test_pending_excludes_what_is_already_applied(tmp_path: Path) -> None:
    write(tmp_path, "0001_first.sql")
    write(tmp_path, "0002_second.sql")
    migrations = discover(tmp_path)

    pending = _check_consistency(migrations, {1: migrations[0].checksum})
    assert [m.version for m in pending] == [2]


def test_nothing_pending_when_all_applied(tmp_path: Path) -> None:
    write(tmp_path, "0001_first.sql")
    migrations = discover(tmp_path)
    assert _check_consistency(migrations, {1: migrations[0].checksum}) == []


def test_editing_an_applied_migration_is_refused(tmp_path: Path) -> None:
    write(tmp_path, "0001_first.sql", "SELECT 1;")
    migrations = discover(tmp_path)

    with pytest.raises(MigrationError, match="file has changed since it was applied"):
        _check_consistency(migrations, {1: "a-checksum-from-the-original"})


def test_a_downgraded_app_is_refused(tmp_path: Path) -> None:
    # The database has run 0002; this build only ships 0001. Forward-only
    # migrations cannot undo it, and running against it would be silent
    # corruption, so it must stop.
    write(tmp_path, "0001_first.sql")
    migrations = discover(tmp_path)

    with pytest.raises(MigrationError, match="downgraded"):
        _check_consistency(migrations, {1: migrations[0].checksum, 2: "whatever"})
