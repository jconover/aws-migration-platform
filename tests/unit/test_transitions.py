"""Unit tests for the migration status state machine."""

import pytest

from app.models import MigrationStatus, Strategy
from app.transitions import (
    InvalidTransitionError,
    allowed_next,
    is_complete,
    validate_transition,
    wave_completion,
)

LEGAL_PATH = [
    (MigrationStatus.DISCOVERED, MigrationStatus.ASSESSED),
    (MigrationStatus.ASSESSED, MigrationStatus.IN_FLIGHT),
    (MigrationStatus.IN_FLIGHT, MigrationStatus.CUTOVER),
    (MigrationStatus.CUTOVER, MigrationStatus.VALIDATED),
]


@pytest.mark.parametrize(("current", "requested"), LEGAL_PATH)
def test_happy_path_transitions_are_allowed(current, requested):
    validate_transition(current, requested, Strategy.REHOST)


@pytest.mark.parametrize(
    ("current", "requested"),
    [
        (MigrationStatus.DISCOVERED, MigrationStatus.CUTOVER),
        (MigrationStatus.DISCOVERED, MigrationStatus.VALIDATED),
        (MigrationStatus.ASSESSED, MigrationStatus.VALIDATED),
        (MigrationStatus.VALIDATED, MigrationStatus.IN_FLIGHT),
        (MigrationStatus.IN_FLIGHT, MigrationStatus.VALIDATED),
    ],
)
def test_illegal_transitions_are_rejected(current, requested):
    with pytest.raises(InvalidTransitionError):
        validate_transition(current, requested, Strategy.REHOST)


def test_invalid_transition_error_carries_context():
    with pytest.raises(InvalidTransitionError) as exc_info:
        validate_transition(MigrationStatus.VALIDATED, MigrationStatus.CUTOVER, Strategy.REHOST)
    assert exc_info.value.current is MigrationStatus.VALIDATED
    assert exc_info.value.requested is MigrationStatus.CUTOVER
    assert "validated" in str(exc_info.value)


@pytest.mark.parametrize("strategy", [Strategy.RETIRE, Strategy.RETAIN])
def test_retire_and_retain_workloads_never_cut_over(strategy):
    with pytest.raises(InvalidTransitionError):
        validate_transition(MigrationStatus.IN_FLIGHT, MigrationStatus.CUTOVER, strategy)


@pytest.mark.parametrize(
    "strategy",
    [
        Strategy.REHOST,
        Strategy.REPLATFORM,
        Strategy.REFACTOR,
        Strategy.REPURCHASE,
        Strategy.RELOCATE,
    ],
)
def test_migrating_strategies_may_cut_over(strategy):
    validate_transition(MigrationStatus.IN_FLIGHT, MigrationStatus.CUTOVER, strategy)


def test_rollback_is_reachable_from_in_flight_and_cutover():
    validate_transition(MigrationStatus.IN_FLIGHT, MigrationStatus.ROLLED_BACK, Strategy.REHOST)
    validate_transition(MigrationStatus.CUTOVER, MigrationStatus.ROLLED_BACK, Strategy.REHOST)


def test_rolled_back_workload_re_enters_at_assessed():
    assert allowed_next(MigrationStatus.ROLLED_BACK) == {MigrationStatus.ASSESSED}


def test_validated_is_terminal():
    assert allowed_next(MigrationStatus.VALIDATED) == frozenset()
    assert is_complete(MigrationStatus.VALIDATED)


@pytest.mark.parametrize(
    "status",
    [s for s in MigrationStatus if s is not MigrationStatus.VALIDATED],
)
def test_non_validated_statuses_are_incomplete(status):
    assert not is_complete(status)


def test_every_status_has_a_transition_rule():
    for status in MigrationStatus:
        assert isinstance(allowed_next(status), frozenset)


@pytest.mark.parametrize(
    ("statuses", "expected"),
    [
        ([], 0.0),
        ([MigrationStatus.VALIDATED], 100.0),
        ([MigrationStatus.DISCOVERED], 0.0),
        ([MigrationStatus.VALIDATED, MigrationStatus.IN_FLIGHT], 50.0),
        ([MigrationStatus.VALIDATED, MigrationStatus.IN_FLIGHT, MigrationStatus.CUTOVER], 33.3),
    ],
)
def test_wave_completion_percentage(statuses, expected):
    assert wave_completion(statuses) == expected
