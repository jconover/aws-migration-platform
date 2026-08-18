"""Unit tests for API schema validation."""

import pytest
from pydantic import ValidationError

from app.models import MigrationStatus, Strategy, WaveSummary, WorkloadCreate


def test_workload_create_accepts_valid_payload():
    payload = WorkloadCreate(
        name="billing-api", wave=1, strategy=Strategy.REPLATFORM, owner="platform"
    )
    assert payload.name == "billing-api"
    assert payload.strategy is Strategy.REPLATFORM


@pytest.mark.parametrize("wave", [0, 100, -1])
def test_workload_create_rejects_out_of_range_wave(wave):
    with pytest.raises(ValidationError):
        WorkloadCreate(name="billing-api", wave=wave, strategy=Strategy.REHOST, owner="platform")


@pytest.mark.parametrize("field", ["name", "owner"])
def test_workload_create_rejects_empty_strings(field):
    values = {"name": "billing-api", "wave": 1, "strategy": Strategy.REHOST, "owner": "platform"}
    values[field] = ""
    with pytest.raises(ValidationError):
        WorkloadCreate(**values)


def test_workload_create_rejects_unknown_strategy():
    with pytest.raises(ValidationError):
        WorkloadCreate(name="billing-api", wave=1, strategy="relift", owner="platform")


def test_wave_summary_stamps_generation_time():
    summary = WaveSummary(wave=2, total=4, completed=1, percent_complete=25.0)
    assert summary.generated_at.tzinfo is not None
    assert summary.percent_complete == 25.0


def test_status_enum_values_are_stable():
    assert [s.value for s in MigrationStatus] == [
        "discovered",
        "assessed",
        "in_flight",
        "cutover",
        "validated",
        "rolled_back",
    ]
