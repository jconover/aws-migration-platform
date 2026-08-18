"""Migration status state machine.

Pure logic with no I/O so it can be exercised entirely by unit tests.
"""

from __future__ import annotations

from app.models import MigrationStatus, Strategy

_ALLOWED: dict[MigrationStatus, frozenset[MigrationStatus]] = {
    MigrationStatus.DISCOVERED: frozenset({MigrationStatus.ASSESSED}),
    MigrationStatus.ASSESSED: frozenset({MigrationStatus.IN_FLIGHT}),
    MigrationStatus.IN_FLIGHT: frozenset({MigrationStatus.CUTOVER, MigrationStatus.ROLLED_BACK}),
    MigrationStatus.CUTOVER: frozenset({MigrationStatus.VALIDATED, MigrationStatus.ROLLED_BACK}),
    MigrationStatus.VALIDATED: frozenset(),
    MigrationStatus.ROLLED_BACK: frozenset({MigrationStatus.ASSESSED}),
}

TERMINAL_STATUSES = frozenset({MigrationStatus.VALIDATED})

_NO_CUTOVER_STRATEGIES = frozenset({Strategy.RETIRE, Strategy.RETAIN})


class InvalidTransitionError(ValueError):
    """Raised when a requested status change is not permitted."""

    def __init__(self, current: MigrationStatus, requested: MigrationStatus) -> None:
        super().__init__(f"cannot move workload from '{current.value}' to '{requested.value}'")
        self.current = current
        self.requested = requested


def allowed_next(current: MigrationStatus) -> frozenset[MigrationStatus]:
    """Return the statuses reachable in one step from ``current``."""
    return _ALLOWED[current]


def validate_transition(
    current: MigrationStatus, requested: MigrationStatus, strategy: Strategy
) -> None:
    """Raise :class:`InvalidTransitionError` unless the transition is legal.

    Retire and retain workloads never cut over, so they are barred from the
    cutover path regardless of the generic state machine.
    """
    if requested not in _ALLOWED[current]:
        raise InvalidTransitionError(current, requested)
    if strategy in _NO_CUTOVER_STRATEGIES and requested is MigrationStatus.CUTOVER:
        raise InvalidTransitionError(current, requested)


def is_complete(status: MigrationStatus) -> bool:
    """Return True when a workload needs no further migration work."""
    return status in TERMINAL_STATUSES


def wave_completion(statuses: list[MigrationStatus]) -> float:
    """Return the percentage of ``statuses`` that are complete, rounded to 1dp."""
    if not statuses:
        return 0.0
    completed = sum(1 for status in statuses if is_complete(status))
    return round(completed / len(statuses) * 100, 1)
