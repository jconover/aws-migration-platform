#!/usr/bin/env python3
"""Create the database schema.

Run once per environment before the first rollout, as a Kubernetes Job or an
ECS one-off task. This is deliberately idempotent (``create_all`` is a no-op
for existing tables). Adopt Alembic before the first destructive schema change
- ``create_all`` cannot express column drops or data backfills.
"""

from __future__ import annotations

import logging
import sys

from sqlalchemy import create_engine

from app.config import get_settings
from app.models import Base


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    settings = get_settings()
    engine = create_engine(settings.sqlalchemy_url, pool_pre_ping=True)
    try:
        Base.metadata.create_all(engine)
        logging.info("schema ensured for environment=%s", settings.environment)
    finally:
        engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(main())
