# Migration Tracker

Reference platform for a large-scale AWS cloud migration: a containerised
Python service, the Terraform that provisions its landing zone, and the GitHub
Actions pipeline that builds, tests, scans, and deploys it to EKS or ECS Fargate.

The application is the migration programme's system of record - which workloads
are in which wave, and what state each is in. It is deployed first, on the same
platform every migrated workload will land on, so the pipeline and landing zone
are proven by real weight before any customer workload depends on them.

## Documentation

**Start here:** [docs/GUIDE.md](docs/GUIDE.md) — what this solves, when you
would and would not use it, and four ways to pick it up depending on why you
are here. Also published as a shareable page:
[Migration Field Guide](https://claude.ai/code/artifact/76e3cb56-6d6e-45af-8085-1fa205fe2bcf) (private; share from the page's share menu).

| Document | Contents |
| --- | --- |
| [docs/GUIDE.md](docs/GUIDE.md) | Why it exists, what it solves, how to use it |
| [docs/MIGRATION-PLAN.md](docs/MIGRATION-PLAN.md) | Discovery, landing zone, wave execution, post-migration |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design decisions, security model, EKS vs ECS |
| [docs/CICD-OPTIMIZATION.md](docs/CICD-OPTIMIZATION.md) | Pipeline bottlenecks and the measured rewrite |
| [docs/ASG-CHURN.md](docs/ASG-CHURN.md) | Why the rehost ASG replaced itself on a loop, and the variable Terraform silently discarded |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Cutover, rollback, incident response |
| [docs/MIGRATION-DEMO.md](docs/MIGRATION-DEMO.md) | **Runnable** on-premises Talos to AWS migration, with the verification gate |
| [docs/BACKLOG.md](docs/BACKLOG.md) | Generated programme backlog: 5 epics, 54 stories and tasks |
| [docs/SETUP.md](docs/SETUP.md) | Bootstrapping AWS and GitHub from scratch |
| [docs/AWS-WALKTHROUGH.md](docs/AWS-WALKTHROUGH.md) | Step-by-step apply against a real account, with costs and teardown |

## Layout

```
app/                    FastAPI service (state machine, persistence, HTTP)
tests/unit/             Pure tests, no I/O
tests/integration/      Tests against real Postgres
scripts/                Coverage gate, schema bootstrap
migration/              Verification gate, backlog generator, cutover script
terraform/
  modules/              vpc, eks, ecs, ec2-rehost, rds, s3, ecr, irsa,
                        iam-app, github-oidc, platform
  envs/{staging,prod}   Environment composition
  bootstrap/            State bucket, run once per account
deploy/k8s/             Kustomize base and per-environment overlays
deploy/onprem/          The simulated datacentre, deployed to a Talos cluster
.github/workflows/      ci, cd, terraform, reusable-deploy-eks, ci-baseline
```

## Quick start

Requires `uv`, Docker, Terraform ≥ 1.15, and `kubectl`.

```bash
make install        # sync dependencies
make db-up          # start local Postgres
make test           # unit + integration, combined coverage, 80% gate
make lint           # ruff + mypy strict
make ci-local       # everything CI runs
make db-down
```

Run the service:

```bash
make run            # docker compose: api + postgres
curl localhost:8000/healthz
curl localhost:8000/api/v1/statuses
```

## Runnable migration

A three-node bare-metal **Talos** cluster stands in for the datacentre; AWS RDS
(or a local container when no AWS account is wired up) is the target.

```bash
./migration/scripts/migrate.sh up        # deploy the source onto Talos
./migration/scripts/migrate.sh cutover   # snapshot -> restore -> verify
./migration/scripts/migrate.sh down
```

The verification gate compares row counts and order-independent content
checksums and refuses to pass unless they match. Proven against the live cluster
to catch a silently edited field, a deleted row, and an unreachable target -
details in [docs/MIGRATION-DEMO.md](docs/MIGRATION-DEMO.md).

## Where workloads land

Three targets, sibling modules against one VPC, database and policy:

| Flag | Module | Lands as |
| --- | --- | --- |
| (default) | `modules/eks` | Kubernetes Deployment |
| `enable_ecs` | `modules/ecs` | Fargate service |
| `enable_ec2_rehost` | `modules/ec2-rehost` | ASG behind an internal ALB, SSM instead of SSH |

Moving a workload between them is a variable change, not a rebuild.

## The service

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/healthz` | Liveness - process is serving |
| GET | `/readyz` | Readiness - database reachable |
| GET | `/metrics` | Prometheus exposition |
| POST | `/api/v1/workloads` | Register a workload |
| GET | `/api/v1/workloads?wave=N` | List, optionally by wave |
| GET | `/api/v1/workloads/{id}` | Fetch one |
| PATCH | `/api/v1/workloads/{id}/status` | Advance through the state machine |
| GET | `/api/v1/waves/{wave}/summary` | Wave completion metrics |

Workload status follows the migration lifecycle, enforced in
`app/transitions.py`:

```
discovered → assessed → in_flight → cutover → validated
                 ▲          │          │
                 └──────────┴─ rolled_back
```

`retire` and `retain` workloads are barred from the cutover path - they are
decommissioned or deferred, never cut over.

## Verified state

Everything below was executed against this repository, not assumed.

| Check | Result |
| --- | --- |
| Unit tests | 111 passed |
| Integration tests (Postgres 17) | 31 passed |
| Combined coverage | **95%** against an 80% floor |
| Coverage gate, all four paths | pass/pass/**fail**/**fail** as designed |
| `mypy app` (strict) | no issues, 10 source files |
| `ruff check` + `ruff format --check` | clean |
| Terraform `validate` + `fmt` | 15/15 stacks clean |
| `shellcheck` on the cutover script | 0 findings |
| Migration demo on live Talos | 20 rows moved, gate passed; corruption + row loss both caught |
| `actionlint` (with shellcheck) | 0 findings across 5 workflows |
| Kustomize overlays | staging and prod render, 11 resources each |
| Container | builds, runs healthy, serves traffic as UID 10001 |
| CI on GitHub Actions | **all 21 jobs green** in 1 min 57 s |
| CD on GitHub Actions | skips by design when no AWS environment is configured, rather than failing against absent infrastructure |
| **Applied to live AWS** | staging stack applied in us-east-1, then destroyed |
| **Migration on real RDS** | 20 rows moved from bare-metal Talos; gate caught a silent field edit and a deleted row |

## Pipeline

```
changes ──┬─ lint ────────────────────┐
          ├─ typecheck ───────────────┤
          ├─ unit ──────────┐         │
          ├─ integration ───┴─ coverage-gate ─┤
          ├─ docker-build ────────────┤       ├─→ ci-complete
          ├─ security-scan ───────────┤       │
          ├─ terraform-validate (×13) ┤       │
          └─ kubernetes-validate ─────┴───────┘
```

`ci-complete` is the single status check to require in branch protection.

Measured on real runners: the serial baseline takes **1 min 03 s**, the parallel
rewrite **1 min 57 s**. The rewrite is slower on wall-clock and does considerably
more - container scanning, IaC validation across 13 stacks, manifest rendering,
and a smoke test. Its real wins are a docs-only change finishing in ~10 s via path
filters, feedback isolation, and the coverage gate. An earlier draft of this
README claimed a 70% speed-up from projected timings; measurement disproved it.
Full analysis: [docs/CICD-OPTIMIZATION.md](docs/CICD-OPTIMIZATION.md).

CD builds once, pushes to ECR, and deploys **by digest** to staging, smoke tests
from inside the cluster, then production behind an environment approval. Failed
rollouts run `kubectl rollout undo` automatically.

## Security posture

- **No AWS credentials anywhere.** GitHub Actions authenticates by OIDC; the
  trust policy pins the exact `sub` claim and the module rejects wildcards.
- **Database password never in Terraform state.** RDS generates it into Secrets
  Manager; the workload reads it at runtime via the CSI driver (EKS) or the task
  definition (ECS).
- **No resource wildcards in the application policy** - one bucket prefix, one
  secret, KMS constrained by `kms:ViaService`.
- **Data subnets have no default route.** Not NAT-less - no egress path at all.
- **Database reachability by security group reference**, never CIDR.
- **Pods** run non-root, read-only root filesystem, all capabilities dropped,
  under Pod Security Standards `restricted`, with default-deny NetworkPolicy that
  excludes the instance metadata endpoint.
- **Images deployed by digest** from an `IMMUTABLE` ECR repository.

## Known gaps

Listed honestly in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#deliberate-gaps): schema migrations
use `create_all` rather than Alembic, and TLS terminates at the ALB without a
certificate configured.

Two more worth stating plainly:

**Discovery targets a service that is closing.** AWS Application Discovery
Service stopped accepting new customers on 7 November 2025; AWS Transform is the
successor. `migration/discovery.py` still consumes an ADS export because that is
what an existing migration programme has, and its column mappings are checked
against the schema AWS publishes rather than against a live export - an account
with no prior ADS data can no longer produce one. The wave-planning logic is
schema-agnostic; only the mapping layer would move.

**The EC2 rehost target ships a placeholder image.** The stack applies before
the image is built, so the default cannot pass its own health check and the ASG
churns until a real image is supplied. The mechanism, and why the health check
is right and the placeholder is wrong, is in
[docs/ASG-CHURN.md](docs/ASG-CHURN.md).
