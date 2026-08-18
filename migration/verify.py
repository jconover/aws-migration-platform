#!/usr/bin/env python3
"""Verify that a migrated database matches its source.

This is the gate at step 4 of the cutover in docs/RUNBOOK.md. It is the last
point at which rolling back is cheap, so it is deliberately strict: any table
whose row count or content checksum differs fails the whole comparison, and the
cutover stops.

The comparison logic is pure and unit-tested. Only ``collect`` touches a
database, so the decision rule can be exercised without one.

Exit codes: 0 identical, 1 differences found, 2 usage or connection error.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field

DEFAULT_TABLES = ("workloads",)

# Table names are interpolated into SQL because identifiers cannot be bound as
# parameters. They are validated against this pattern first, so only a plain
# unqualified identifier can ever reach a query string.
_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class UnsafeIdentifierError(ValueError):
    """Raised when a table name is not a plain SQL identifier."""


def validate_table_name(table: str) -> str:
    """Return ``table`` if it is a safe bare identifier, else raise."""
    if not _IDENTIFIER.match(table):
        raise UnsafeIdentifierError(f"unsafe table identifier: {table!r}")
    return table


@dataclass(frozen=True)
class TableFingerprint:
    """Row count and content checksum for one table."""

    table: str
    row_count: int
    checksum: str


@dataclass
class Comparison:
    """Result of comparing a source and target database."""

    matched: list[str] = field(default_factory=list)
    row_count_mismatches: list[tuple[str, int, int]] = field(default_factory=list)
    checksum_mismatches: list[tuple[str, str, str]] = field(default_factory=list)
    missing_in_target: list[str] = field(default_factory=list)
    unexpected_in_target: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True only when every table matched exactly."""
        return not (
            self.row_count_mismatches
            or self.checksum_mismatches
            or self.missing_in_target
            or self.unexpected_in_target
        )

    def report(self) -> list[str]:
        """Return human-readable result lines, most important first."""
        lines: list[str] = []
        for table in self.missing_in_target:
            lines.append(f"FAIL {table}: present in source, absent in target")
        for table in self.unexpected_in_target:
            lines.append(f"FAIL {table}: present in target, absent in source")
        for table, source_rows, target_rows in self.row_count_mismatches:
            delta = target_rows - source_rows
            lines.append(f"FAIL {table}: row count {source_rows} -> {target_rows} ({delta:+d})")
        for table, source_sum, target_sum in self.checksum_mismatches:
            lines.append(
                f"FAIL {table}: checksum differs "
                f"(source {source_sum[:12]}, target {target_sum[:12]})"
            )
        for table in self.matched:
            lines.append(f"OK   {table}: identical")
        return lines


def compare(source: list[TableFingerprint], target: list[TableFingerprint]) -> Comparison:
    """Compare two sets of fingerprints.

    A row-count mismatch is reported instead of a checksum mismatch for the same
    table, because the count is the more actionable signal: it says how much data
    was lost or duplicated, where a checksum only says "different".
    """
    result = Comparison()
    source_by_table = {fingerprint.table: fingerprint for fingerprint in source}
    target_by_table = {fingerprint.table: fingerprint for fingerprint in target}

    for table in sorted(set(source_by_table) - set(target_by_table)):
        result.missing_in_target.append(table)
    for table in sorted(set(target_by_table) - set(source_by_table)):
        result.unexpected_in_target.append(table)

    for table in sorted(set(source_by_table) & set(target_by_table)):
        src, tgt = source_by_table[table], target_by_table[table]
        if src.row_count != tgt.row_count:
            result.row_count_mismatches.append((table, src.row_count, tgt.row_count))
        elif src.checksum != tgt.checksum:
            result.checksum_mismatches.append((table, src.checksum, tgt.checksum))
        else:
            result.matched.append(table)

    return result


def collect(dsn: str, tables: tuple[str, ...]) -> list[TableFingerprint]:
    """Fingerprint each table in the database at ``dsn``.

    The checksum is an order-independent aggregate over each row rendered as
    text, so it is stable across a dump and restore that does not preserve
    physical row order - which no dump and restore does.
    """
    import psycopg

    fingerprints: list[TableFingerprint] = []
    safe_tables = [validate_table_name(table) for table in tables]
    with psycopg.connect(dsn) as connection, connection.cursor() as cursor:
        for table in safe_tables:
            cursor.execute("SELECT to_regclass(%s) IS NOT NULL", (f"public.{table}",))
            row = cursor.fetchone()
            if row is None or not row[0]:
                continue

            count_sql = f'SELECT count(*) FROM "{table}"'  # noqa: S608
            cursor.execute(count_sql)
            count_row = cursor.fetchone()
            row_count = int(count_row[0]) if count_row else 0

            # Hex md5 of each row -> bit(64) -> bigint, then summed. sum() is
            # commutative, so the result does not depend on physical row order,
            # which no dump and restore preserves. md5() returns hex, so the
            # 'x' prefix is required: casting hex text straight to bit fails.
            # S608: identifiers are validated by validate_table_name above, so
            # only a bare [A-Za-z_][A-Za-z0-9_]* can reach this string.
            row_hash = f"('x' || substr(md5(\"{table}\"::text), 1, 16))::bit(64)::bigint::numeric"
            checksum_sql = f'SELECT coalesce(sum({row_hash}), 0)::text FROM "{table}"'  # noqa: S608
            cursor.execute(checksum_sql)
            checksum_row = cursor.fetchone()
            checksum = str(checksum_row[0]) if checksum_row else "0"

            fingerprints.append(TableFingerprint(table, row_count, checksum))
    return fingerprints


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Source (on-premises) DSN")
    parser.add_argument("--target", required=True, help="Target (AWS) DSN")
    parser.add_argument(
        "--tables", nargs="+", default=list(DEFAULT_TABLES), help="Tables to compare"
    )
    parser.add_argument("--summary", default=None, help="Append markdown here")
    args = parser.parse_args(argv)

    tables = tuple(args.tables)
    try:
        source = collect(args.source, tables)
        target = collect(args.target, tables)
    # Any failure here - unreachable host, bad credentials, missing database,
    # unsafe identifier - is fatal for a verification gate. Failing closed is
    # the point: "could not check" must never be read as "checked and fine".
    except Exception as exc:
        print(f"error: could not fingerprint databases: {exc}", file=sys.stderr)
        return 2

    result = compare(source, target)
    lines = result.report()
    for line in lines:
        print(line)

    verdict = "MATCH - safe to proceed" if result.ok else "MISMATCH - roll back"
    print(f"\n{verdict}")

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write("## Migration verification\n\n")
            handle.write("\n".join(f"- {line}" for line in lines))
            handle.write(f"\n\n**{verdict}**\n")

    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
