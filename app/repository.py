"""Data access for workloads."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import MigrationStatus, Workload, WorkloadCreate


class DuplicateWorkloadError(ValueError):
    """Raised when a workload name is already registered."""


def create(session: Session, payload: WorkloadCreate) -> Workload:
    """Insert a workload, rejecting duplicate names."""
    existing = session.scalar(select(Workload).where(Workload.name == payload.name))
    if existing is not None:
        raise DuplicateWorkloadError(payload.name)
    workload = Workload(
        name=payload.name,
        wave=payload.wave,
        strategy=payload.strategy,
        owner=payload.owner,
        status=MigrationStatus.DISCOVERED,
    )
    session.add(workload)
    session.flush()
    return workload


def get(session: Session, workload_id: int) -> Workload | None:
    """Return a workload by id, or None."""
    return session.get(Workload, workload_id)


def list_all(session: Session, wave: int | None = None) -> list[Workload]:
    """Return workloads ordered by wave then name, optionally filtered by wave."""
    statement = select(Workload).order_by(Workload.wave, Workload.name)
    if wave is not None:
        statement = statement.where(Workload.wave == wave)
    return list(session.scalars(statement))


def statuses_for_wave(session: Session, wave: int) -> list[MigrationStatus]:
    """Return every status recorded against a wave."""
    return list(session.scalars(select(Workload.status).where(Workload.wave == wave)))
