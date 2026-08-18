#!/usr/bin/env python3
"""Generate the migration programme backlog.

Produces one epic per programme phase plus per-workload stories derived from
the discovery portfolio, so the backlog and the tracker cannot drift apart:
both are generated from the same wave and strategy model.

Emit Jira-importable CSV:      python -m migration.backlog --format csv
Emit markdown for review:      python -m migration.backlog --format markdown
"""

from __future__ import annotations

import argparse
import csv
import io
import sys
from dataclasses import dataclass

from app.models import Strategy

# Strategies that never cut over; their stories are decommission or defer work.
_NO_CUTOVER = {Strategy.RETIRE, Strategy.RETAIN}


@dataclass(frozen=True)
class Issue:
    """One Jira issue."""

    issue_type: str
    summary: str
    description: str
    epic: str
    labels: tuple[str, ...]
    estimate: int


PHASE_EPICS: tuple[tuple[str, str], ...] = (
    (
        "Discovery and assessment",
        "Inventory the estate, agree a strategy and owner per workload, and "
        "group workloads into waves by dependency cluster. Exit criteria: every "
        "workload has an owner, a strategy, a wave and a recorded dependency set.",
    ),
    (
        "Landing zone",
        "Account structure, three-tier VPC, hybrid connectivity and guardrails. "
        "Exit criteria: terraform apply reproduces the landing zone from empty "
        "and hybrid connectivity is tested at real throughput.",
    ),
    (
        "Platform and pipeline",
        "EKS, ECS Fargate and the EC2 rehost target, plus the CI/CD pipeline that "
        "deploys to them. Exit criteria: a commit reaches staging automatically "
        "and a rollback has been performed deliberately and timed.",
    ),
    (
        "Wave execution",
        "Move workloads wave by wave: build, replicate, test, cut over, validate. "
        "Exit criteria: every workload in the wave is validated and its source is "
        "decommissioned or formally retained.",
    ),
    (
        "Post-migration",
        "Hypercare, right-sizing against real demand, cost controls and "
        "operational handover. Exit criteria: workloads are owned by the run team "
        "with runbooks, dashboards and alarms in place.",
    ),
)

LANDING_ZONE_STORIES: tuple[tuple[str, str, int], ...] = (
    (
        "Agree the IPAM plan with the network team",
        "Allocate non-overlapping CIDRs for every environment before any VPC is\n"
        "built. Overlap found after Direct Connect is live costs weeks.",
        3,
    ),
    (
        "Order Direct Connect and stand up backup VPN",
        "DX lead time is 6-12 weeks and sits on the critical path. VPN carries the early waves.",
        5,
    ),
    (
        "Build the three-tier VPC with Terraform",
        "Public, private and isolated data subnets across three AZs, with flow\n"
        "logs and VPC endpoints.",
        5,
    ),
)

PLATFORM_STORIES: tuple[tuple[str, str, int], ...] = (
    (
        "Provision EKS with IRSA and access entries",
        "Private API endpoint, envelope encryption, managed addons, no cluster-admin by default.",
        8,
    ),
    (
        "Provision the EC2 rehost target",
        "Launch template, ASG behind an internal ALB, SSM Session Manager instead\n"
        "of SSH, encrypted EBS.",
        5,
    ),
    (
        "Provision RDS Postgres Multi-AZ",
        "Isolated data subnets, credentials generated into Secrets Manager, forced TLS.",
        5,
    ),
    (
        "Establish GitHub OIDC deployment roles",
        "No static AWS keys. Trust policies pin the exact subject claim per environment.",
        3,
    ),
    (
        "Build the CI pipeline with a coverage gate",
        "Parallel lint, type, unit and integration jobs with an 80% floor and a regression gate.",
        5,
    ),
    (
        "Prove rollback by rehearsing it",
        "Deliberately fail a rollout and time the automatic rollback. An untested\n"
        "rollback is a hypothesis.",
        3,
    ),
)


DISCOVERY_STORIES: tuple[tuple[str, str, int], ...] = (
    (
        "Run Application Discovery Service across the estate",
        "Collect utilisation and dependency data. Right-size from real metrics "
        "rather than replicating existing over-provisioning.",
        5,
    ),
    (
        "Identify retirement candidates and confirm with owners",
        "Typically 10-20% of an estate has no real consumers. Confirm with "
        "owners, not logs alone - a quiet service is not necessarily an "
        "unused one.",
        3,
    ),
    (
        "Assign a strategy, owner and wave to every workload",
        "Record in the tracker, not a spreadsheet. Waves are grouped by "
        "dependency cluster, never by team convenience.",
        5,
    ),
    (
        "Map network dependencies per wave",
        "Undiscovered dependencies are the most common cause of cutover "
        "overrun. Use flow data, and keep wave 1 low-criticality.",
        5,
    ),
)

POST_MIGRATION_STORIES: tuple[tuple[str, str, int], ...] = (
    (
        "Run two weeks of hypercare per wave",
        "Migration engineers stay on the rota. Do not hand straight to a run "
        "team that has never seen the workload.",
        3,
    ),
    (
        "Right-size workloads after two weeks of data",
        "Deliberately deferred so cutover changes one variable, not two. "
        "Use CloudWatch and Compute Optimizer against real demand.",
        3,
    ),
    (
        "Purchase Savings Plans once usage stabilises",
        "Committing during migration locks in the pre-optimisation shape.",
        2,
    ),
    (
        "Hand over runbooks, dashboards and alarms",
        "Operational transfer per workload, with alarms landing on the shared "
        "SNS topic used by the pipeline.",
        3,
    ),
    (
        "Decommission source systems after the retention window",
        "Sources are retained read-only for the agreed period, then removed.",
        2,
    ),
)


def workload_stories(portfolio: list[tuple[str, int, Strategy, str]]) -> list[Issue]:
    """Build one story per workload, shaped by its migration strategy."""
    issues: list[Issue] = []
    for name, wave, strategy, owner in portfolio:
        labels = ("aws-migration", f"wave-{wave}", strategy.value, f"owner-{owner}")

        if strategy is Strategy.RETIRE:
            summary = f"Retire {name}"
            description = (
                f"Confirm with {owner} that {name} has no remaining consumers, "
                "capture any data required for retention, then decommission. "
                "Retirement is the cheapest possible migration outcome, so "
                "confirm with owners rather than logs alone."
            )
            estimate = 2
        elif strategy is Strategy.RETAIN:
            summary = f"Document why {name} is retained this cycle"
            description = (
                f"Record the regulatory or dependency blocker keeping {name} "
                f"on-premises, the review date, and the owner ({owner}) "
                "accountable for revisiting it."
            )
            estimate = 1
        else:
            summary = f"Migrate {name} ({strategy.value}, wave {wave})"
            description = (
                f"Strategy: {strategy.value}. Owner: {owner}. Wave: {wave}.\n\n"
                "Acceptance criteria:\n"
                "- Target infrastructure applied via Terraform, no console changes\n"
                "- Data replicated with CDC and reverse replication configured\n"
                "- Owner has signed off functionality and performance against "
                "replicated data\n"
                "- Cutover runbook written with a rollback decision deadline\n"
                "- Verification gate passes on row counts and checksums\n"
                "- Workload reaches 'validated' in the tracker"
            )
            estimate = {Strategy.REHOST: 3, Strategy.REPLATFORM: 5, Strategy.REFACTOR: 13}.get(
                strategy, 8
            )

        issues.append(Issue("Story", summary, description, "Wave execution", labels, estimate))

        if strategy not in _NO_CUTOVER:
            issues.append(
                Issue(
                    "Task",
                    f"Cutover rehearsal for {name}",
                    "Dry-run the cutover end to end in staging, including the "
                    "verification gate and a full rollback, and record the "
                    "measured duration of each step.",
                    "Wave execution",
                    (*labels, "cutover"),
                    2,
                )
            )
    return issues


def build_backlog(portfolio: list[tuple[str, int, Strategy, str]]) -> list[Issue]:
    """Return the complete backlog: epics, platform stories, workload stories."""
    issues: list[Issue] = [
        Issue("Epic", title, description, "", ("aws-migration",), 0)
        for title, description in PHASE_EPICS
    ]
    for epic_name, story_set, label in (
        ("Discovery and assessment", DISCOVERY_STORIES, "discovery"),
        ("Landing zone", LANDING_ZONE_STORIES, "landing-zone"),
        ("Platform and pipeline", PLATFORM_STORIES, "platform"),
        ("Post-migration", POST_MIGRATION_STORIES, "post-migration"),
    ):
        issues += [
            Issue("Story", summary, description, epic_name, ("aws-migration", label), points)
            for summary, description, points in story_set
        ]
    issues += workload_stories(portfolio)
    return issues


def to_csv(issues: list[Issue]) -> str:
    """Render the backlog as Jira-importable CSV."""
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["Issue Type", "Summary", "Description", "Epic Link", "Labels", "Story Points"])
    for issue in issues:
        writer.writerow(
            [
                issue.issue_type,
                issue.summary,
                issue.description,
                issue.epic,
                " ".join(issue.labels),
                issue.estimate or "",
            ]
        )
    return buffer.getvalue()


def to_markdown(issues: list[Issue]) -> str:
    """Render the backlog as markdown grouped by epic."""
    lines = ["# Migration programme backlog", ""]
    epics = [issue for issue in issues if issue.issue_type == "Epic"]
    lines.append(f"{len(epics)} epics, {len(issues) - len(epics)} stories and tasks.")
    lines.append("")

    for epic in epics:
        lines.append(f"## {epic.summary}")
        lines.append("")
        lines.append(epic.description)
        lines.append("")
        children = [i for i in issues if i.epic == epic.summary]
        if not children:
            lines.append("_No child issues generated for this phase yet._")
            lines.append("")
            continue
        lines.append("| Type | Summary | Points | Labels |")
        lines.append("| --- | --- | --- | --- |")
        for child in children:
            lines.append(
                f"| {child.issue_type} | {child.summary} | {child.estimate or ''} | "
                f"{' '.join(child.labels)} |"
            )
        lines.append("")
    return "\n".join(lines)


DEFAULT_PORTFOLIO: list[tuple[str, int, Strategy, str]] = [
    ("billing-api", 1, Strategy.REPLATFORM, "payments"),
    ("billing-worker", 1, Strategy.REPLATFORM, "payments"),
    ("invoice-renderer", 1, Strategy.REHOST, "payments"),
    ("legacy-fax-gateway", 1, Strategy.RETIRE, "facilities"),
    ("print-spooler", 1, Strategy.RETIRE, "facilities"),
    ("orders-api", 2, Strategy.REPLATFORM, "commerce"),
    ("orders-worker", 2, Strategy.REPLATFORM, "commerce"),
    ("inventory-sync", 2, Strategy.REHOST, "commerce"),
    ("pricing-engine", 2, Strategy.REFACTOR, "commerce"),
    ("warehouse-scanner", 2, Strategy.REHOST, "logistics"),
    ("crm-connector", 3, Strategy.REPURCHASE, "sales"),
    ("reporting-etl", 3, Strategy.REPLATFORM, "data"),
    ("data-warehouse", 3, Strategy.RELOCATE, "data"),
    ("ml-feature-store", 3, Strategy.REFACTOR, "data"),
    ("hr-portal", 4, Strategy.REPURCHASE, "people"),
    ("payroll-batch", 4, Strategy.RETAIN, "people"),
    ("mainframe-bridge", 4, Strategy.RETAIN, "core-systems"),
    ("auth-service", 4, Strategy.REFACTOR, "platform"),
    ("audit-log-archive", 5, Strategy.REHOST, "compliance"),
    ("dr-replica", 5, Strategy.RELOCATE, "platform"),
]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=["csv", "markdown"], default="csv")
    parser.add_argument("--output", default=None, help="Write here instead of stdout")
    args = parser.parse_args(argv)

    issues = build_backlog(DEFAULT_PORTFOLIO)
    rendered = to_csv(issues) if args.format == "csv" else to_markdown(issues)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        print(f"wrote {len(issues)} issues to {args.output}", file=sys.stderr)
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
