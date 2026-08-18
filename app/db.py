"""Database engine and session management."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import Engine, create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings

_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def init_engine(settings: Settings) -> Engine:
    """Create the process-wide engine and session factory."""
    global _engine, _session_factory
    _engine = create_engine(
        settings.sqlalchemy_url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_pre_ping=True,
        connect_args={"connect_timeout": settings.db_connect_timeout},
    )
    _session_factory = sessionmaker(bind=_engine, expire_on_commit=False)
    return _engine


def get_engine() -> Engine:
    """Return the initialised engine."""
    if _engine is None:
        raise RuntimeError("engine not initialised; call init_engine() first")
    return _engine


@contextmanager
def session_scope() -> Iterator[Session]:
    """Yield a session, committing on success and rolling back on failure."""
    if _session_factory is None:
        raise RuntimeError("session factory not initialised; call init_engine() first")
    session = _session_factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def ping() -> bool:
    """Return True when the database answers a trivial query."""
    with get_engine().connect() as connection:
        connection.execute(text("SELECT 1"))
    return True


def dispose() -> None:
    """Tear down pooled connections on shutdown."""
    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _session_factory = None
