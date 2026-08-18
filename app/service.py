"""Application services coordinating persistence and migration rules."""

from __future__ import annotations

from sqlalchemy.orm import Session

from app import repository, transitions
from app.models import MigrationStatus, WaveSummary, Workload, WorkloadCreate


class WorkloadNotFoundError(LookupError):
    """Raised when a workload id does not resolve."""


def register_workload(session: Session, payload: WorkloadCreate) -> Workload:
    """Register a newly discovered workload."""
    return repository.create(session, payload)


def advance_status(session: Session, workload_id: int, requested: MigrationStatus) -> Workload:
    """Move a workload to ``requested``, enforcing the migration state machine."""
    workload = repository.get(session, workload_id)
    if workload is None:
        raise WorkloadNotFoundError(str(workload_id))
    transitions.validate_transition(workload.status, requested, workload.strategy)
    workload.status = requested
    session.flush()
    return workload


def summarise_wave(session: Session, wave: int) -> WaveSummary:
    """Return completion metrics for a migration wave."""
    statuses = repository.statuses_for_wave(session, wave)
    completed = sum(1 for status in statuses if transitions.is_complete(status))
    return WaveSummary(
        wave=wave,
        total=len(statuses),
        completed=completed,
        percent_complete=transitions.wave_completion(statuses),
    )
