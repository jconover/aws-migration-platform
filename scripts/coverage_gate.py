#!/usr/bin/env python3
"""Enforce the coverage contract for a pull request.

Two independent checks must both pass:

1. Absolute floor  - combined line coverage must be at least ``--min``.
2. Regression gate - combined coverage must not fall more than ``--tolerance``
   percentage points below the baseline recorded on the target branch.

The baseline file is produced by the same script on ``main`` (``--write-baseline``)
and republished as a build artifact, so a pull request compares against the
merge target rather than an arbitrary historical high-water mark.

Exit codes: 0 pass, 1 gate failed, 2 usage/parse error.
"""

from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

GITHUB_SUMMARY_HEADER = "## Coverage gate\n\n"


def read_coverage_xml(path: Path) -> float:
    """Return line-rate percentage from a Cobertura ``coverage.xml``."""
    try:
        # S314: the report is produced by coverage.py inside this same job, so it
        # is not untrusted input. Pulling in defusedxml to parse our own output
        # would add a dependency without removing a real attack path.
        root = ElementTree.parse(path).getroot()  # noqa: S314
    except (OSError, ElementTree.ParseError) as exc:
        raise SystemExit(f"error: cannot parse coverage report {path}: {exc}") from exc

    line_rate = root.get("line-rate")
    if line_rate is None:
        raise SystemExit(f"error: {path} has no line-rate attribute")
    return round(float(line_rate) * 100, 2)


def read_baseline(path: Path | None) -> float | None:
    """Return the recorded baseline percentage, or None when unavailable."""
    if path is None or not path.is_file():
        return None
    try:
        return float(json.loads(path.read_text())["line_coverage"])
    except (OSError, ValueError, KeyError) as exc:
        print(f"warning: ignoring unreadable baseline {path}: {exc}", file=sys.stderr)
        return None


def write_baseline(path: Path, coverage: float, ref: str) -> None:
    """Record ``coverage`` as the new baseline for ``ref``."""
    path.write_text(json.dumps({"line_coverage": coverage, "ref": ref}, indent=2) + "\n")


def append_step_summary(lines: list[str], summary_path: str | None) -> None:
    """Append a markdown block to the GitHub Actions step summary when present."""
    if not summary_path:
        return
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write(GITHUB_SUMMARY_HEADER + "\n".join(lines) + "\n")


def evaluate(
    current: float, minimum: float, baseline: float | None, tolerance: float
) -> tuple[bool, list[str]]:
    """Return (passed, human-readable report lines)."""
    lines = [f"- Combined coverage: **{current:.2f}%**", f"- Absolute floor: {minimum:.2f}%"]
    passed = True

    if current + 1e-9 < minimum:
        lines.append(f"- FAIL: coverage {current:.2f}% is below the {minimum:.2f}% floor")
        passed = False
    else:
        lines.append("- PASS: absolute floor met")

    if baseline is None:
        lines.append("- Baseline: none recorded for the target branch (regression check skipped)")
    else:
        allowed = baseline - tolerance
        lines.append(f"- Baseline: {baseline:.2f}% (tolerance {tolerance:.2f}pp -> {allowed:.2f}%)")
        delta = current - baseline
        if current + 1e-9 < allowed:
            lines.append(f"- FAIL: coverage dropped {abs(delta):.2f}pp against the target branch")
            passed = False
        else:
            direction = "up" if delta >= 0 else "down"
            lines.append(f"- PASS: {direction} {abs(delta):.2f}pp against the target branch")

    return passed, lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=Path("coverage.xml"))
    parser.add_argument("--min", type=float, default=80.0, dest="minimum")
    parser.add_argument("--tolerance", type=float, default=0.5)
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--write-baseline", type=Path, default=None)
    parser.add_argument("--ref", default="unknown")
    parser.add_argument("--summary", default=None)
    args = parser.parse_args(argv)

    current = read_coverage_xml(args.report)

    if args.write_baseline is not None:
        write_baseline(args.write_baseline, current, args.ref)
        print(f"baseline recorded: {current:.2f}% ({args.ref})")

    passed, lines = evaluate(current, args.minimum, read_baseline(args.baseline), args.tolerance)

    for line in lines:
        print(line.removeprefix("- "))
    append_step_summary(lines, args.summary)

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
