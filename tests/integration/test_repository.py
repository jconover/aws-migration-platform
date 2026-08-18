"""Integration tests exercising persistence against real Postgres."""

import pytest

from app import repository, service
from app.models import MigrationStatus, Strategy, WorkloadCreate
from app.repository import DuplicateWorkloadError

pytestmark = pytest.mark.integration


def payload(name="billing-api", wave=1, strategy=Strategy.REHOST, owner="platform"):
    return WorkloadCreate(name=name, wave=wave, strategy=strategy, owner=owner)


def test_create_persists_workload_with_defaults(session):
    workload = repository.create(session, payload())
    session.commit()

    assert workload.id is not None
    assert workload.status is MigrationStatus.DISCOVERED
    assert workload.created_at is not None
    assert workload.updated_at is not None


def test_unique_name_constraint_is_enforced(session):
    repository.create(session, payload())
    session.commit()
    with pytest.raises(DuplicateWorkloadError):
        repository.create(session, payload())


def test_get_returns_none_for_missing_id(session):
    assert repository.get(session, 12345) is None


def test_list_all_is_ordered_by_wave_then_name(session):
    repository.create(session, payload(name="zeta", wave=1))
    repository.create(session, payload(name="alpha", wave=2))
    repository.create(session, payload(name="beta", wave=1))
    session.commit()

    names = [w.name for w in repository.list_all(session)]
    assert names == ["beta", "zeta", "alpha"]


def test_list_all_filters_by_wave(session):
    repository.create(session, payload(name="a", wave=1))
    repository.create(session, payload(name="b", wave=2))
    session.commit()

    assert [w.name for w in repository.list_all(session, wave=2)] == ["b"]


def test_enum_round_trips_through_postgres(session):
    workload = repository.create(session, payload(strategy=Strategy.RELOCATE))
    session.commit()
    session.expire_all()

    reloaded = repository.get(session, workload.id)
    assert reloaded.strategy is Strategy.RELOCATE


def test_status_transition_is_persisted(session):
    workload = repository.create(session, payload())
    session.commit()

    service.advance_status(session, workload.id, MigrationStatus.ASSESSED)
    session.commit()
    session.expire_all()

    assert repository.get(session, workload.id).status is MigrationStatus.ASSESSED


def test_wave_summary_reflects_persisted_rows(session):
    for index in range(4):
        repository.create(session, payload(name=f"svc-{index}", wave=7))
    session.commit()
    for workload in repository.list_all(session, wave=7)[:2]:
        for step in (
            MigrationStatus.ASSESSED,
            MigrationStatus.IN_FLIGHT,
            MigrationStatus.CUTOVER,
            MigrationStatus.VALIDATED,
        ):
            service.advance_status(session, workload.id, step)
    session.commit()

    summary = service.summarise_wave(session, 7)
    assert summary.total == 4
    assert summary.completed == 2
    assert summary.percent_complete == 50.0
