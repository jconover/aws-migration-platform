"""Application factory and lifecycle."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import __version__
from app.api import health_router, router
from app.config import Settings, get_settings
from app.db import dispose, init_engine


def configure_logging(settings: Settings) -> None:
    """Send structured-ish logs to stdout for CloudWatch/Fluent Bit pickup."""
    logging.basicConfig(
        level=settings.log_level.upper(),
        format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Open the connection pool on startup and drain it on shutdown."""
    settings = get_settings()
    configure_logging(settings)
    init_engine(settings)
    logging.getLogger(__name__).info("started environment=%s", settings.environment)
    yield
    dispose()


def create_app() -> FastAPI:
    """Build the FastAPI application."""
    app = FastAPI(
        title="Migration Tracker",
        version=__version__,
        description="Tracks workload progress through the AWS migration programme.",
        lifespan=lifespan,
    )
    app.include_router(health_router)
    app.include_router(router, prefix="/api/v1")
    return app


app = create_app()
