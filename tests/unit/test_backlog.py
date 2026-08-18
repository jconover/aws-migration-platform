"""Unit tests for the migration backlog generator."""

import csv
import io

import pytest

from app.models import Strategy
from migration.backlog import (
    DEFAULT_PORTFOLIO,
    PHASE_EPICS,
    build_backlog,
    to_csv,
    to_markdown,
    workload_stories,
)


def test_every_phase_becomes_an_epic():
    issues = build_backlog(DEFAULT_PORTFOLIO)
    epics = [i.summary for i in issues if i.issue_type == "Epic"]
    assert epics == [title for title, _ in PHASE_EPICS]


def test_every_epic_has_child_issues():
    """An empty epic is a planning gap, not a valid backlog."""
    issues = build_backlog(DEFAULT_PORTFOLIO)
    for epic in (i for i in issues if i.issue_type == "Epic"):
        children = [i for i in issues if i.epic == epic.summary]
        assert children, f"epic '{epic.summary}' has no child issues"


def test_retire_workload_gets_a_retirement_story_not_a_migration():
    issues = workload_stories([("legacy-fax", 1, Strategy.RETIRE, "facilities")])
    assert len(issues) == 1
    assert issues[0].summary == "Retire legacy-fax"


def test_retain_workload_is_documented_not_migrated():
    issues = workload_stories([("mainframe", 4, Strategy.RETAIN, "core")])
    assert len(issues) == 1
    assert "retained" in issues[0].summary


@pytest.mark.parametrize(
    "strategy", [Strategy.REHOST, Strategy.REPLATFORM, Strategy.REFACTOR, Strategy.RELOCATE]
)
def test_migrating_workloads_get_a_cutover_rehearsal(strategy):
    issues = workload_stories([("svc", 2, strategy, "team")])
    assert [i.issue_type for i in issues] == ["Story", "Task"]
    assert "Cutover rehearsal" in issues[1].summary


@pytest.mark.parametrize("strategy", [Strategy.RETIRE, Strategy.RETAIN])
def test_non_migrating_workloads_have_no_cutover_rehearsal(strategy):
    issues = workload_stories([("svc", 2, strategy, "team")])
    assert all("Cutover" not in i.summary for i in issues)


def test_refactor_is_estimated_higher_than_rehost():
    rehost = workload_stories([("a", 1, Strategy.REHOST, "t")])[0]
    refactor = workload_stories([("b", 1, Strategy.REFACTOR, "t")])[0]
    assert refactor.estimate > rehost.estimate


def test_labels_carry_wave_strategy_and_owner():
    story = workload_stories([("svc", 3, Strategy.REHOST, "platform")])[0]
    assert "wave-3" in story.labels
    assert "rehost" in story.labels
    assert "owner-platform" in story.labels
    assert "aws-migration" in story.labels


def test_csv_is_parseable_and_has_a_row_per_issue():
    issues = build_backlog(DEFAULT_PORTFOLIO)
    rows = list(csv.reader(io.StringIO(to_csv(issues))))
    assert rows[0] == [
        "Issue Type",
        "Summary",
        "Description",
        "Epic Link",
        "Labels",
        "Story Points",
    ]
    assert len(rows) == len(issues) + 1


def test_csv_survives_commas_and_newlines_in_descriptions():
    """Descriptions contain both, so naive string joining would corrupt the file."""
    issues = build_backlog(DEFAULT_PORTFOLIO)
    parsed = list(csv.reader(io.StringIO(to_csv(issues))))
    assert all(len(row) == 6 for row in parsed)


def test_markdown_lists_every_epic():
    markdown = to_markdown(build_backlog(DEFAULT_PORTFOLIO))
    for title, _ in PHASE_EPICS:
        assert f"## {title}" in markdown


def test_empty_portfolio_still_produces_the_programme_scaffolding():
    issues = build_backlog([])
    assert [i for i in issues if i.issue_type == "Epic"]
    assert not [i for i in issues if i.epic == "Wave execution"]
