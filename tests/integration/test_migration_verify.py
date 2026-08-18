"""Integration tests for the migration verification gate.

Exercises the real fingerprinting path against live Postgres, including the
case that matters most on a cutover weekend: the same number of rows, but
different content.
"""

import pytest
from sqlalchemy import create_engine, text

from migration.verify import collect, compare, main

pytestmark = pytest.mark.integration

ROWS = [
    ("billing-api", 1, "replatform", "validated", "payments"),
    ("orders-api", 2, "replatform", "cutover", "commerce"),
    ("legacy-fax", 1, "retire", "assessed", "facilities"),
]

# Mirrors the source schema exactly, including the timestamp columns. A target
# whose columns differ from the source produces a different row rendering and
# therefore a different checksum - which is the gate working correctly, but
# makes for a confusing test.
DDL = """
CREATE TABLE IF NOT EXISTS workloads (
    id         INTEGER PRIMARY KEY,
    name       VARCHAR(200) NOT NULL UNIQUE,
    wave       INTEGER NOT NULL,
    strategy   VARCHAR(20) NOT NULL,
    status     VARCHAR(20) NOT NULL,
    owner      VARCHAR(200) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
)
"""

COLUMNS = "id, name, wave, strategy, status, owner, created_at, updated_at"


def _dsn(url: str) -> str:
    """Strip the SQLAlchemy driver prefix so psycopg can consume the URL."""
    return url.replace("postgresql+psycopg://", "postgresql://")


@pytest.fixture
def target_database(engine):
    """Create a second database on the same server to act as the AWS target."""
    name = "migration_target_test"
    autocommit = engine.execution_options(isolation_level="AUTOCOMMIT")
    with autocommit.connect() as connection:
        connection.execute(text(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
        connection.execute(text(f"CREATE DATABASE {name}"))

    target_url = engine.url.set(database=name)
    target_engine = create_engine(target_url)
    with target_engine.begin() as connection:
        connection.execute(text(DDL))

    yield target_engine

    target_engine.dispose()
    with autocommit.connect() as connection:
        connection.execute(text(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)"))


def _replicate(source_engine, target_engine, limit=None):
    """Copy rows verbatim from source to target, as a dump and restore would."""
    with source_engine.connect() as connection:
        rows = list(connection.execute(text(f"SELECT {COLUMNS} FROM workloads ORDER BY id")))
    if limit is not None:
        rows = rows[:limit]

    with target_engine.begin() as connection:
        connection.execute(text("TRUNCATE TABLE workloads"))
        for row in rows:
            connection.execute(
                text(
                    f"INSERT INTO workloads ({COLUMNS}) VALUES "
                    "(:id, :name, :wave, :strategy, :status, :owner, "
                    ":created_at, :updated_at)"
                ),
                dict(row._mapping),
            )
    return rows


def _mutate_one_value(target_engine, name, new_status):
    """Change a single field without changing the row count."""
    with target_engine.begin() as connection:
        connection.execute(
            text("UPDATE workloads SET status = :s WHERE name = :n"),
            {"s": new_status, "n": name},
        )


def _seed_source(session, rows):
    from app.models import MigrationStatus, Strategy, Workload

    for name, wave, strategy, status, owner in rows:
        session.add(
            Workload(
                name=name,
                wave=wave,
                strategy=Strategy(strategy),
                status=MigrationStatus(status),
                owner=owner,
            )
        )
    session.commit()


def test_identical_databases_verify_clean(engine, session, target_database):
    _seed_source(session, ROWS)
    _replicate(engine, target_database)

    source = collect(_dsn(str(engine.url.render_as_string(hide_password=False))), ("workloads",))
    target = collect(
        _dsn(str(target_database.url.render_as_string(hide_password=False))), ("workloads",)
    )

    assert source[0].row_count == 3
    assert compare(source, target).ok


def test_missing_row_in_target_fails_the_gate(engine, session, target_database):
    _seed_source(session, ROWS)
    _replicate(engine, target_database, limit=2)

    source = collect(_dsn(str(engine.url.render_as_string(hide_password=False))), ("workloads",))
    target = collect(
        _dsn(str(target_database.url.render_as_string(hide_password=False))), ("workloads",)
    )

    result = compare(source, target)
    assert not result.ok
    assert result.row_count_mismatches == [("workloads", 3, 2)]


def test_same_row_count_different_content_fails_the_gate(engine, session, target_database):
    """The failure a row-count-only check would wave through."""
    _seed_source(session, ROWS)
    _replicate(engine, target_database)
    _mutate_one_value(target_database, "legacy-fax", "validated")

    source = collect(_dsn(str(engine.url.render_as_string(hide_password=False))), ("workloads",))
    target = collect(
        _dsn(str(target_database.url.render_as_string(hide_password=False))), ("workloads",)
    )

    result = compare(source, target)
    assert not result.ok
    assert result.row_count_mismatches == []
    assert len(result.checksum_mismatches) == 1


def test_checksum_is_independent_of_row_order(engine, session, target_database):
    """A dump and restore never preserves physical order, so the gate must not care."""
    _seed_source(session, ROWS)
    rows = _replicate(engine, target_database)
    # Re-insert in reverse physical order; content is unchanged.
    with target_database.begin() as connection:
        connection.execute(text("TRUNCATE TABLE workloads"))
        for row in reversed(rows):
            connection.execute(
                text(
                    f"INSERT INTO workloads ({COLUMNS}) VALUES "
                    "(:id, :name, :wave, :strategy, :status, :owner, "
                    ":created_at, :updated_at)"
                ),
                dict(row._mapping),
            )

    source = collect(_dsn(str(engine.url.render_as_string(hide_password=False))), ("workloads",))
    target = collect(
        _dsn(str(target_database.url.render_as_string(hide_password=False))), ("workloads",)
    )

    assert compare(source, target).ok


def test_absent_table_is_skipped_not_fatal(engine, target_database):
    result = collect(
        _dsn(str(target_database.url.render_as_string(hide_password=False))),
        ("workloads", "table_that_does_not_exist"),
    )
    assert [f.table for f in result] == ["workloads"]


def test_cli_returns_zero_when_databases_match(engine, session, target_database, tmp_path):
    _seed_source(session, ROWS)
    _replicate(engine, target_database)
    summary = tmp_path / "summary.md"

    exit_code = main(
        [
            "--source",
            _dsn(str(engine.url.render_as_string(hide_password=False))),
            "--target",
            _dsn(str(target_database.url.render_as_string(hide_password=False))),
            "--summary",
            str(summary),
        ]
    )

    assert exit_code == 0
    assert "MATCH" in summary.read_text()


def test_cli_returns_one_when_databases_differ(engine, session, target_database, tmp_path):
    _seed_source(session, ROWS)
    _replicate(engine, target_database, limit=1)
    summary = tmp_path / "summary.md"

    exit_code = main(
        [
            "--source",
            _dsn(str(engine.url.render_as_string(hide_password=False))),
            "--target",
            _dsn(str(target_database.url.render_as_string(hide_password=False))),
            "--summary",
            str(summary),
        ]
    )

    assert exit_code == 1
    assert "MISMATCH" in summary.read_text()


def test_cli_returns_two_on_connection_failure():
    assert main(["--source", "postgresql://x:1/none", "--target", "postgresql://x:1/none"]) == 2
