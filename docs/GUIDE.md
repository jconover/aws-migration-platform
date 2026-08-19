# What this is, why you would use it, and how

Seven other documents in this folder explain *what was built* and *how it
works*. This one explains *why it exists* and *what to do with it*.

> **Shareable version:** <https://claude.ai/code/artifact/76e3cb56-6d6e-45af-8085-1fa205fe2bcf>
> A published web version of this guide, for sending to someone who does not
> have access to this repository. It is private by default — share it from the
> page's own share menu. This file stays canonical; if you edit it, republish so
> the two do not drift.

---

## The problem

A datacentre-to-AWS migration is rarely hard because AWS is hard. It goes wrong
in the same handful of places every time, and none of them are technical
novelties:

| What actually goes wrong | What it costs |
| --- | --- |
| Nobody can say what state a given workload is in | Steering meetings run on stale spreadsheets; two teams migrate the same dependency |
| Cutovers are improvised from a wiki page | The window overruns because nobody agreed in advance when to stop and roll back |
| Data "arrives" and is quietly wrong | Discovered weeks later, by which point the source is decommissioned |
| The landing target is chosen during discovery and then frozen | A workload that should have been Fargate is stuck on a Kubernetes platform nobody wanted to run |
| Credentials spread as the estate grows | Long-lived AWS keys in CI, database passwords in state files, SSH keys nobody can account for |
| Infrastructure is built once, by hand, under time pressure | The second environment is subtly different from the first, and neither can be rebuilt |
| Delivery slows down exactly when the pace needs to increase | Every change is a manual risk assessment because nothing is verified automatically |

Every one of those is a process failure that tooling can either prevent or make
visible. This repository is the tooling.

---

## What it solves, concretely

### 1. "Where are we?" gets a real answer

The tracker service (`app/`) is the system of record for the migration
portfolio. Each workload has an owner, a wave, one of the 7 Rs strategies, and a
status. The status is not a free-text field: `app/transitions.py` is a state
machine that refuses illegal moves.

```
discovered → assessed → in_flight → cutover → validated
                 ▲          │          │
                 └──────────┴─ rolled_back
```

A workload cannot jump from `discovered` to `validated` because someone was
optimistic in a status meeting. Retire and retain workloads are barred from the
cutover path entirely — they are decommissioned or deferred, never cut over.
That class of reporting error is caught by the API instead of surviving to a
steering pack.

### 2. Cutovers become a procedure, not an improvisation

[RUNBOOK.md](RUNBOOK.md) is written to be followed at 03:00 by someone who did
not write it: a T-7 checklist, a gated window with per-step verification, and —
the part most runbooks omit — **a rollback decision deadline set before the
window opens**. Every overrun in this pattern comes from a team that was "nearly
there" for two hours.

### 3. Silent data corruption is caught before it matters

`migration/verify.py` is the gate at the point of no return. It compares row
counts *and* order-independent content checksums, and fails closed: a
connection error exits 2, because "could not check" must never read as "checked
and fine".

Proven against a live cluster:

| Injected fault | Detected as |
| --- | --- |
| One field edited, row count unchanged | checksum differs |
| One row deleted | `row count 20 → 19 (-1)` |
| Target unreachable | exit 2 |

A row-count check alone waves the first one straight through. That is the
failure mode worth building for.

### 4. The landing target stops being a one-way door

Three sibling Terraform modules against one VPC, one database, one
least-privilege policy:

| Flag | Module | Lands as | Reach for it when |
| --- | --- | --- | --- |
| *(default)* | `modules/eks` | Kubernetes Deployment | Enough workloads to bin-pack; sidecars, operators, portability |
| `enable_ecs` | `modules/ecs` | Fargate service | Stateless HTTP service; no Kubernetes operator on the rota |
| `enable_ec2_rehost` | `modules/ec2-rehost` | ASG behind an internal ALB | Anything assuming a host: local disk, an agent, a licence tied to a MAC |

Moving a workload between them is a variable change. The target chosen during
discovery is frequently not the right one after a month in AWS, and this makes
that reversible.

### 5. Credentials stop accumulating

- **No AWS keys anywhere.** GitHub Actions authenticates by OIDC; the trust
  policy pins the exact `sub` claim, and the module *rejects wildcard subjects*
  so `repo:org/repo:*` cannot be configured by accident.
- **The database password never enters Terraform state.** RDS generates it into
  Secrets Manager; workloads read it at runtime.
- **No SSH, no key pairs, no port 22** on the EC2 path — SSM Session Manager,
  audited in CloudTrail. This also disposes of "who still has the old datacentre
  SSH key".
- **No resource wildcards** in the application policy: one bucket prefix, one
  secret, KMS constrained by `kms:ViaService`.

### 6. Environments are reproducible

`terraform apply` builds the landing zone from empty. Staging and production run
the *same* module with different inputs, so a change proven in staging is the
same code that reaches production.

### 7. Delivery gets faster and safer at the same time

Parallel CI with an 80% coverage floor plus a regression gate; images deployed
**by digest** from an immutable registry; failed rollouts run `kubectl rollout
undo` automatically. What staging validated is bit-for-bit what production runs.

---

## When you would *not* use this

Being honest about fit:

- **A handful of servers, one app.** The tracker, wave model and three landing
  targets are overhead you will never recover. Use the Migration Hub console.
- **No containers anywhere, and no appetite for them.** The EC2 path still
  assumes the app ships as a container supervised by systemd. Adapt or skip it.
- **You need CDC today.** The demo is a full load, which implies downtime for
  its duration. Continuous replication is described, not implemented.
- **You want a product.** This is a reference implementation and a working
  skeleton, not a supported tool.

---

## How to use it

Pick the path that matches why you are here.

### Path A — Evaluate it in fifteen minutes

No AWS account, no cluster.

```bash
make install          # sync dependencies with uv
make db-up            # local Postgres
make test             # 119 tests, combined coverage, 80% gate
make tf-validate      # 14/14 Terraform stacks
make db-down
```

Then read, in this order: [ARCHITECTURE.md](ARCHITECTURE.md) for the decisions
and their reasoning, [CICD-OPTIMIZATION.md](CICD-OPTIMIZATION.md) for a worked
example of a measured claim being disproven and corrected, and
[MIGRATION-DEMO.md](MIGRATION-DEMO.md) for what running it on real hardware
found.

### Path B — Watch a migration actually happen

Needs any Kubernetes cluster. Set `KUBECONFIG_PATH` if it is not the default.

```bash
./migration/scripts/migrate.sh doctor    # tooling, cluster reachability, state
./migration/scripts/migrate.sh up        # deploy the "datacentre" source
./migration/scripts/migrate.sh status    # what exists on each side
./migration/scripts/migrate.sh cutover   # snapshot → restore → verify
./migration/scripts/migrate.sh down      # remove everything
```

With no `TARGET_DSN`, a local Postgres container stands in for RDS so the whole
flow runs without an AWS account. Point it at the real thing by exporting one:

```bash
export TARGET_DSN="postgresql://user:pass@host.rds.amazonaws.com:5432/migration_tracker"
```

**Prove the gate to yourself** — a gate you have only seen pass is not a gate:

```bash
docker exec migration-target-rds psql -U postgres -d migration_tracker \
  -c "UPDATE workloads SET owner='wrong' WHERE name='billing-api';"
./migration/scripts/migrate.sh verify    # exits 1: checksum differs
```

### Path C — Run it against real AWS

[AWS-WALKTHROUGH.md](AWS-WALKTHROUGH.md) is the click-by-click version, with
running costs at each stage and a teardown checklist for what `terraform destroy`
leaves behind. [SETUP.md](SETUP.md) is the reference. In outline:

1. `terraform/bootstrap` — state bucket, once per account
2. `terraform/envs/staging` — apply, then production
3. Wire GitHub environments to the Terraform outputs; there are **no secrets to
   create** except a Slack webhook
4. Protect `main` on the **`CI complete`** check — one job that aggregates all
   the others, so adding a job later never means editing branch protection
5. Push to `main`

Start in a sandbox account. Every stack passes `validate`, but validation cannot
catch service quotas, IAM boundaries, or region-specific behaviour, and nothing
here has been applied against a live account.

**One thing that will surprise you:** RDS is private by design — no public
access, and its subnets have no default route. Running the migration against it
from your laptop will not connect. Port-forward through a rehost instance over
SSM, or run the migration inside the VPC; both are written up in
[MIGRATION-DEMO.md](MIGRATION-DEMO.md#against-real-rds).

### Path D — Take the process, leave the code

The parts that transfer without adopting anything:

- The **wave and 7 Rs model**, and the rule that waves are grouped by dependency
  cluster rather than team convenience
- The **cutover runbook** with a rollback decision deadline
- The **verification gate** idea — checksums, not just row counts
- **Retire aggressively**: 10–20% of a typical estate has no consumers, and a
  retired workload needs no migration, testing, or cutover window
- **Right-size after cutover, not during** — otherwise every performance
  complaint has two plausible causes

Generate a starting backlog for your own portfolio by editing
`DEFAULT_PORTFOLIO` in `migration/backlog.py`:

```bash
uv run python -m migration.backlog --format csv --output backlog.csv
```

It produces epics per phase and stories per workload, shaped by strategy —
retire and retain workloads get decommission and defer stories, and no cutover
rehearsal. Because it is generated from the same model the tracker uses, the
backlog and reality cannot drift apart.

---

## Where to look for what

| Question | Document |
| --- | --- |
| How should the programme run? | [MIGRATION-PLAN.md](MIGRATION-PLAN.md) |
| Why is it built this way? | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Something is broken at 03:00 | [RUNBOOK.md](RUNBOOK.md) |
| How do I stand it up? | [SETUP.md](SETUP.md) |
| Does the migration actually work? | [MIGRATION-DEMO.md](MIGRATION-DEMO.md) |
| Is the pipeline any good? | [CICD-OPTIMIZATION.md](CICD-OPTIMIZATION.md) |
| What work is there? | [BACKLOG.md](BACKLOG.md) |

---

## What this repository does not claim

- **Nothing has been applied to a live AWS account.** All 14 stacks pass
  `validate` and `fmt`; that does not catch quotas, IAM boundaries or regional
  behaviour.
- **The pipeline rewrite is slower in wall-clock than the naive baseline**
  (1m 57s vs 1m 03s) at this repository's size. It was adopted for scope and
  feedback quality; the original speed claim was measured and disproven, and
  [CICD-OPTIMIZATION.md](CICD-OPTIMIZATION.md) records why.
- **Schema migrations use `create_all`.** Adopt Alembic before the first
  destructive schema change.
- **TLS terminates at the load balancer with no certificate configured** — the
  annotations are in place, the ACM certificate and hostname are not.
- **The data migration is a full load.** No CDC, no reverse replication.

Each of these is listed rather than hidden because a migration reference that
overstates its own readiness is worse than no reference at all.
