"""Unit tests for the service layer with the repository stubbed out."""

import pytest

from app import repository, service
from app.models import MigrationStatus, Strategy, Workload
from app.transitions import InvalidTransitionError


class FakeSession:
    """Minimal stand-in that records flushes without touching a database."""

    def __init__(self):
        self.flushes = 0

    def flush(self):
        self.flushes += 1


def make_workload(status=MigrationStatus.ASSESSED, strategy=Strategy.REHOST):
    workload = Workload()
    workload.id = 1
    workload.name = "billing-api"
    workload.wave = 1
    workload.strategy = strategy
    workload.status = status
    workload.owner = "platform"
    return workload


def test_advance_status_moves_workload_forward(monkeypatch):
    workload = make_workload()
    monkeypatch.setattr(repository, "get", lambda session, workload_id: workload)
    session = FakeSession()

    result = service.advance_status(session, 1, MigrationStatus.IN_FLIGHT)

    assert result.status is MigrationStatus.IN_FLIGHT
    assert session.flushes == 1


def test_advance_status_raises_when_workload_missing(monkeypatch):
    monkeypatch.setattr(repository, "get", lambda session, workload_id: None)
    with pytest.raises(service.WorkloadNotFoundError):
        service.advance_status(FakeSession(), 404, MigrationStatus.IN_FLIGHT)


def test_advance_status_rejects_illegal_move(monkeypatch):
    workload = make_workload(status=MigrationStatus.DISCOVERED)
    monkeypatch.setattr(repository, "get", lambda session, workload_id: workload)
    session = FakeSession()

    with pytest.raises(InvalidTransitionError):
        service.advance_status(session, 1, MigrationStatus.VALIDATED)

    assert workload.status is MigrationStatus.DISCOVERED
    assert session.flushes == 0


def test_advance_status_blocks_cutover_for_retired_workload(monkeypatch):
    workload = make_workload(status=MigrationStatus.IN_FLIGHT, strategy=Strategy.RETIRE)
    monkeypatch.setattr(repository, "get", lambda session, workload_id: workload)
    with pytest.raises(InvalidTransitionError):
        service.advance_status(FakeSession(), 1, MigrationStatus.CUTOVER)


def test_summarise_wave_computes_completion(monkeypatch):
    statuses = [
        MigrationStatus.VALIDATED,
        MigrationStatus.VALIDATED,
        MigrationStatus.IN_FLIGHT,
        MigrationStatus.DISCOVERED,
    ]
    monkeypatch.setattr(repository, "statuses_for_wave", lambda session, wave: statuses)

    summary = service.summarise_wave(FakeSession(), 3)

    assert summary.wave == 3
    assert summary.total == 4
    assert summary.completed == 2
    assert summary.percent_complete == 50.0


def test_summarise_empty_wave(monkeypatch):
    monkeypatch.setattr(repository, "statuses_for_wave", lambda session, wave: [])
    summary = service.summarise_wave(FakeSession(), 9)
    assert summary.total == 0
    assert summary.percent_complete == 0.0


def test_register_workload_delegates_to_repository(monkeypatch):
    created = make_workload()
    monkeypatch.setattr(repository, "create", lambda session, payload: created)
    assert service.register_workload(FakeSession(), object()) is created
