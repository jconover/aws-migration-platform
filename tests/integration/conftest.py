"""Fixtures backing the integration suite against a live Postgres instance."""

from __future__ import annotations

import os
import time
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings
from app.models import Base

DEFAULT_URL = "postgresql+psycopg://postgres:postgres@localhost:5432/migration_tracker_test"
READY_TIMEOUT_SECONDS = 60


def _database_url() -> str:
    """Resolve the test database URL, preferring the CI-provided value."""
    return os.environ.get("TEST_DATABASE_URL", DEFAULT_URL)


def _wait_for_database(engine: Engine) -> None:
    """Block until Postgres accepts connections or the timeout expires."""
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            return
        except OperationalError as exc:
            last_error = exc
            time.sleep(1)
    raise RuntimeError(f"Postgres not ready after {READY_TIMEOUT_SECONDS}s") from last_error


@pytest.fixture(scope="session")
def engine() -> Iterator[Engine]:
    """Session-scoped engine with the schema created once."""
    engine = create_engine(_database_url(), pool_pre_ping=True)
    _wait_for_database(engine)
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


@pytest.fixture(autouse=True)
def clean_tables(engine: Engine) -> Iterator[None]:
    """Truncate between tests so cases stay independent."""
    yield
    with engine.begin() as connection:
        connection.execute(text("TRUNCATE TABLE workloads RESTART IDENTITY CASCADE"))


@pytest.fixture
def session(engine: Engine) -> Iterator[Session]:
    """Provide a transactional session bound to the live database."""
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    with factory() as session:
        yield session


@pytest.fixture
def client(engine: Engine) -> Iterator[TestClient]:
    """Provide an HTTP client wired to the app running against live Postgres."""
    os.environ["APP_DATABASE_URL"] = _database_url()
    get_settings.cache_clear()
    from app.main import create_app

    with TestClient(create_app()) as client:
        yield client
    get_settings.cache_clear()
