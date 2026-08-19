# AWS migration plan

The engagement is a large-scale datacentre-to-AWS migration: infrastructure
build-out, workload migrations, IaC, cloud networking, cutovers, and
post-migration support. This document is the plan that the code in this
repository serves.

The application in `app/` is the migration tracker itself - the system of record
for which workloads are in which wave and what state each is in. It is deployed
first, on the same platform every migrated workload will land on, so the pipeline
and the landing zone are proven by carrying real weight before any customer
workload depends on them.

---

## Phase 0 - Discovery and assessment (weeks 1-4)

Nothing is migrated until the portfolio is understood. Migrating a workload you
cannot describe is how cutover weekends overrun.

**Collect**

| Input | Source | Used for |
| --- | --- | --- |
| Server inventory, utilisation | AWS Application Discovery Service, existing CMDB | Right-sizing, not lift-and-inflate |
| Network dependencies | ADS agent flow data, VPC-side flow logs after first moves | Wave grouping |
| Application ownership | Interviews; recorded as `owner` on each workload | Cutover accountability |
| Data volumes and change rates | DBA metrics | Replication windows, cutover duration |
| Compliance constraints | Security and legal | Data residency, encryption, retention |

**Decide a strategy per workload.** The tracker models the 7 Rs directly
(`app/models.py:Strategy`):

| Strategy | Applies when | Typical target |
| --- | --- | --- |
| Rehost | Time-boxed exit, app cannot change | EC2 via Application Migration Service |
| Replatform | Managed service exists for a component | EKS or ECS + RDS |
| Refactor | Strategic app, scaling or velocity constrained | EKS, managed data services |
| Repurchase | Commodity function | SaaS |
| Retire | No longer used - confirm with owners, not with logs alone | decommission |
| Retain | Regulatory or dependency blocker this cycle | stays put, revisit |
| Relocate | VMware estate moving wholesale | VMware Cloud on AWS |

Retire is the highest-value outcome per hour spent. In most estates 10-20% of
inventory has no real consumers, and every retired server is one that needs no
migration, no testing, and no cutover window.

**Turn discovery output into the portfolio.** `migration/discovery.py` consumes
an ADS export and produces tracker-ready workloads, with waves derived from the
dependency graph rather than from planning convenience:

```bash
uv run python -m migration.discovery \
  --servers servers.csv --connections connections.csv
```

Waves are connected components of the observed-connection graph. Two rules,
enforced in code rather than in a document:

1. **A cluster is never split.** Servers that talk to each other cut over
   together, or accept measured latency across the link. Deciding that
   per-server during a cutover window is how outages happen.
2. **Data-tier clusters do not go in wave 1.** A database cutover is the
   expensive kind to get wrong, and wave 1 exists to surface process problems
   cheaply.

Servers with no observed traffic in either direction surface as retirement
candidates. On the sample export that is 2 of 8 - consistent with the 10-20% a
typical estate carries.

The value shows in cases nobody would assign by hand. In the sample, a jump host
is pulled into the payments cluster because it holds SSH sessions to a billing
web server. No planner groups a jump host with payments; the connection data
does, and migrating the cluster without it would strand operator access.

**Exit criteria:** every workload has an owner, a strategy, a wave, and a
recorded dependency set. All of it is in the tracker, not a spreadsheet.

---

## Phase 1 - Landing zone (weeks 3-8, overlapping Phase 0)

The account structure and network the whole programme lands in. Built with the
Terraform in `terraform/` and reviewed before anything migrates.

**Accounts.** Separate accounts per environment, under Organizations with SCPs
denying region use outside the approved set, denying root user actions, and
denying the disabling of CloudTrail or GuardDuty. Blast radius is an account
boundary; nothing else is as reliable.

**Network** (`terraform/modules/vpc`) - three tiers per environment:

| Tier | Sizing | Routing |
| --- | --- | --- |
| Public | /20 per AZ | Internet gateway; load balancers and NAT only |
| Private | /20 per AZ | Egress via NAT; EKS nodes and pods |
| Data | /24 per AZ | **No default route.** RDS only. |

Address space is allocated from an IPAM plan that does not overlap on-premises
ranges. Overlapping CIDRs discovered after Direct Connect is live is a
multi-week setback, so it is settled in week 3, in writing, with the network
team.

Interface endpoints for ECR, Secrets Manager, STS, SSM, CloudWatch Logs and a
gateway endpoint for S3 keep AWS API traffic off the NAT gateways. During bulk
data movement that is both a cost lever and a control on where data can go.

**Hybrid connectivity.** Site-to-Site VPN first because it is available in days,
then Direct Connect with the VPN retained as backup. Bandwidth is sized from the
Phase 0 data volumes, and the DX lead time - typically 6-12 weeks - is placed on
the critical path from day one.

**Guardrails from the start**, not retrofitted: CloudTrail organisation trail,
Config with conformance packs, GuardDuty, Security Hub, and VPC flow logs
(`terraform/modules/vpc/flow_logs.tf`). During cutover, flow logs are the
fastest way to establish whether traffic reached the VPC at all before anyone
starts debugging the application.

**Exit criteria:** `terraform apply` reproduces the landing zone from empty;
hybrid connectivity tested with real throughput, not a ping.

---

## Phase 2 - Platform and pipeline (weeks 6-10)

EKS (`terraform/modules/eks`) and, where the workload suits it, ECS Fargate
(`terraform/modules/ecs`). Selection criteria are in [ARCHITECTURE.md](ARCHITECTURE.md).

The migration tracker is the first workload through the pipeline. This is
deliberate: by the time a customer workload migrates, the build, scan, deploy,
rollback, and alerting paths have all been exercised repeatedly on something the
migration team owns and can afford to break.

**Exit criteria:** a commit reaches staging automatically and production behind
approval; a rollback has been performed on purpose and timed.

The three landing targets - EKS, ECS Fargate and the EC2 rehost ASG - are all
provisioned from the same VPC, database and least-privilege policy, so a
workload reassessed mid-programme moves between them by changing a variable.

---

## Phase 3 - Wave execution (weeks 10-52)

**Wave composition rules**

1. Group by dependency cluster, never by team convenience. Workloads that
   exchange traffic move together or accept measured latency across the link.
2. Wave 1 is low-criticality and internally-facing - the wave where process
   problems surface, so they surface cheaply.
3. Databases move with, or just before, their applications. Never after.
4. Cap concurrent cutovers at what the on-call rota can actually support.

**Per-workload sequence**

| Step | Detail | Tracker status |
| --- | --- | --- |
| 1. Assess | Strategy confirmed, dependencies mapped, runbook drafted | `discovered` → `assessed` |
| 2. Build | Target infrastructure via Terraform; no console changes | `assessed` → `in_flight` |
| 3. Replicate | AWS MGN for servers, DMS with CDC for databases | `in_flight` |
| 4. Test | Isolated test instance from replicated data; owner signs off functionality and performance | `in_flight` |
| 5. Cut over | Per [RUNBOOK.md](RUNBOOK.md) | `in_flight` → `cutover` |
| 6. Validate | Hypercare, then formal sign-off | `cutover` → `validated` |
| 7. Decommission | Source retained read-only for the agreed period, then decommissioned | - |

The state machine enforces this order in code (`app/transitions.py`). A workload
cannot jump from `discovered` to `validated`, and `retire`/`retain` workloads are
barred from the cutover path entirely - a class of reporting error that would
otherwise be found at a steering meeting rather than at the API.

**Data migration.** [MIGRATION-DEMO.md](MIGRATION-DEMO.md) runs this end to end
against a real on-premises Kubernetes cluster, including the verification gate
and both of its failure modes.

DMS full load plus CDC keeps the target in sync while the
source stays authoritative. Cutover is then a short window to drain, verify row
counts and checksums, and repoint. Reverse replication is configured *before*
cutover so rollback does not mean data loss - if it is not configured
beforehand, rollback is a restore from backup, which is a different and much
longer conversation.

**Rollback.** Every cutover has a written rollback with a decision deadline. The
deadline matters more than the procedure: without one, teams debug past the point
where rollback is still cheap.

---

## Phase 4 - Post-migration (continuous)

**Hypercare.** Two weeks of heightened support per wave, with the migration
engineers on the rota - not handed straight to a run team that has never seen
the workload.

**Right-sizing.** Deliberately deferred. Instances are provisioned to match
on-premises sizing so that cutover changes one variable, not two. Two weeks of
CloudWatch and Compute Optimizer data later, they are resized against real
demand. Right-sizing during cutover means every performance complaint has two
plausible causes.

**Cost.** Tag enforcement from day one (`Project`, `Environment`, `ManagedBy`,
`Programme` are applied as provider `default_tags`). Savings Plans purchased only
after usage stabilises - committing during migration locks in the pre-optimisation
shape.

**Operational transfer.** Runbooks, dashboards, and alarms handed over with the
workload. The SNS topic in `terraform/modules/platform/monitoring.tf` receives
both infrastructure alarms and pipeline failures, so on-call watches one place.

---

## Risks

| Risk | Mitigation |
| --- | --- |
| CIDR overlap with on-premises | IPAM plan agreed in writing in week 3, before any VPC is built |
| Direct Connect lead time | Ordered in week 1; VPN carries early waves |
| Undiscovered dependencies | Flow-log analysis per wave; wave 1 kept low-criticality |
| Data drift during cutover | DMS CDC; row-count and checksum verification gates the window |
| Rollback not viable | Reverse replication configured before cutover; deadline in every runbook |
| Cost overrun | Tag enforcement, Budgets alarms, right-sizing after stabilisation |
| Key-person dependency | Runbooks in the repository; cutovers pair-staffed |
