"""Unit tests for the migration verification gate.

These cover the decision rule that decides whether a cutover proceeds, so they
run without a database.
"""

import pytest

from migration.verify import (
    Comparison,
    TableFingerprint,
    UnsafeIdentifierError,
    compare,
    validate_table_name,
)


def fp(table="workloads", rows=20, checksum="abc123"):
    return TableFingerprint(table=table, row_count=rows, checksum=checksum)


def test_identical_databases_match():
    result = compare([fp()], [fp()])
    assert result.ok
    assert result.matched == ["workloads"]


def test_row_count_loss_is_caught():
    result = compare([fp(rows=20)], [fp(rows=19)])
    assert not result.ok
    assert result.row_count_mismatches == [("workloads", 20, 19)]
    assert "row count 20 -> 19 (-1)" in "\n".join(result.report())


def test_row_count_gain_is_caught():
    """Duplicate rows are as much a failure as missing ones."""
    result = compare([fp(rows=20)], [fp(rows=21)])
    assert not result.ok
    assert "(+1)" in "\n".join(result.report())


def test_same_count_different_content_is_caught():
    """The case a naive row-count check misses entirely."""
    result = compare([fp(checksum="aaa")], [fp(checksum="bbb")])
    assert not result.ok
    assert result.checksum_mismatches == [("workloads", "aaa", "bbb")]
    assert result.row_count_mismatches == []


def test_row_count_mismatch_takes_precedence_over_checksum():
    """A count difference is the more actionable signal, so report only that."""
    result = compare([fp(rows=20, checksum="aaa")], [fp(rows=10, checksum="bbb")])
    assert result.row_count_mismatches == [("workloads", 20, 10)]
    assert result.checksum_mismatches == []


def test_table_missing_from_target():
    result = compare([fp(table="workloads"), fp(table="audit")], [fp(table="workloads")])
    assert not result.ok
    assert result.missing_in_target == ["audit"]


def test_unexpected_table_in_target():
    result = compare([fp(table="workloads")], [fp(table="workloads"), fp(table="scratch")])
    assert not result.ok
    assert result.unexpected_in_target == ["scratch"]


def test_empty_databases_match():
    assert compare([], []).ok


def test_report_orders_failures_before_successes():
    result = compare(
        [fp(table="a", rows=1), fp(table="b", rows=5)],
        [fp(table="a", rows=1), fp(table="b", rows=4)],
    )
    lines = result.report()
    assert lines[0].startswith("FAIL")
    assert lines[-1].startswith("OK")


def test_multiple_failures_all_reported():
    result = compare(
        [fp(table="a", rows=1), fp(table="b", checksum="x"), fp(table="c")],
        [fp(table="a", rows=2), fp(table="b", checksum="y")],
    )
    assert len(result.row_count_mismatches) == 1
    assert len(result.checksum_mismatches) == 1
    assert result.missing_in_target == ["c"]


def test_fresh_comparison_is_ok():
    assert Comparison().ok


@pytest.mark.parametrize("table", ["workloads", "audit_log", "_private", "T1"])
def test_valid_identifiers_accepted(table):
    assert validate_table_name(table) == table


@pytest.mark.parametrize(
    "table",
    ["workloads; DROP TABLE users", "public.workloads", "1bad", "", "a-b", 'w"x'],
)
def test_injection_attempts_rejected(table):
    with pytest.raises(UnsafeIdentifierError):
        validate_table_name(table)
