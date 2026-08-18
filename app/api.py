"""HTTP routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Path, Query, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy.exc import SQLAlchemyError

from app import repository, service
from app.db import ping, session_scope
from app.models import MigrationStatus, StatusUpdate, WaveSummary, WorkloadCreate, WorkloadRead
from app.repository import DuplicateWorkloadError
from app.service import WorkloadNotFoundError
from app.transitions import InvalidTransitionError

router = APIRouter()
health_router = APIRouter(tags=["health"])


@health_router.get("/healthz")
def liveness() -> dict[str, str]:
    """Liveness probe: the process is up and serving."""
    return {"status": "ok"}


@health_router.get("/readyz")
def readiness() -> dict[str, str]:
    """Readiness probe: dependencies are reachable."""
    try:
        ping()
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="database unavailable"
        ) from exc
    return {"status": "ready"}


@health_router.get("/metrics")
def metrics() -> Response:
    """Expose Prometheus metrics for scraping."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@router.post("/workloads", response_model=WorkloadRead, status_code=status.HTTP_201_CREATED)
def create_workload(payload: WorkloadCreate) -> WorkloadRead:
    """Register a workload in the migration portfolio."""
    with session_scope() as session:
        try:
            workload = service.register_workload(session, payload)
        except DuplicateWorkloadError as exc:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"workload '{payload.name}' already registered",
            ) from exc
        return WorkloadRead.model_validate(workload)


@router.get("/workloads", response_model=list[WorkloadRead])
def list_workloads(
    wave: Annotated[int | None, Query(ge=1, le=99)] = None,
) -> list[WorkloadRead]:
    """List workloads, optionally narrowed to a single wave."""
    with session_scope() as session:
        return [WorkloadRead.model_validate(w) for w in repository.list_all(session, wave)]


@router.get("/workloads/{workload_id}", response_model=WorkloadRead)
def get_workload(workload_id: int) -> WorkloadRead:
    """Fetch a single workload."""
    with session_scope() as session:
        workload = repository.get(session, workload_id)
        if workload is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="workload not found")
        return WorkloadRead.model_validate(workload)


@router.patch("/workloads/{workload_id}/status", response_model=WorkloadRead)
def update_status(workload_id: int, payload: StatusUpdate) -> WorkloadRead:
    """Advance a workload through the migration state machine."""
    with session_scope() as session:
        try:
            workload = service.advance_status(session, workload_id, payload.status)
        except WorkloadNotFoundError as exc:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="workload not found"
            ) from exc
        except InvalidTransitionError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        return WorkloadRead.model_validate(workload)


@router.get("/waves/{wave}/summary", response_model=WaveSummary)
def wave_summary(wave: Annotated[int, Path(ge=1, le=99)]) -> WaveSummary:
    """Report completion metrics for a migration wave."""
    with session_scope() as session:
        return service.summarise_wave(session, wave)


@router.get("/statuses", response_model=list[str])
def list_statuses() -> list[str]:
    """Enumerate the valid migration statuses."""
    return [s.value for s in MigrationStatus]
