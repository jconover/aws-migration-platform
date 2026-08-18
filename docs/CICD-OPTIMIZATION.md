# Pipeline bottleneck analysis and rewrite

Two pipelines live in this repository:

| File | Purpose |
| --- | --- |
| `.github/workflows/ci-baseline.yml` | The naive "before" pipeline. `workflow_dispatch` only, kept for comparison. |
| `.github/workflows/ci.yml` | The rewrite that actually runs. |

This document identifies what was slow in the baseline, what changed, and what
the change is worth.

## A note on the numbers

Two kinds of number appear below, and they are labelled throughout:

- **Measured** - timed on this repository. Reproduce with the commands in
  [Reproducing the measurements](#reproducing-the-measurements). These were taken
  on an Apple M-series laptop, which is faster than a GitHub-hosted runner.
- **Projected** - runner wall-clock estimates. GitHub's standard hosted runners
  are 2-core with slower disk and network, so compute-bound stages are scaled up,
  and fixed per-job overheads (VM allocation, checkout, tool setup, service
  container boot) are added explicitly rather than hidden in a multiplier.

The projections are stated so they can be checked, not asserted. The
*structural* claims - what runs in parallel, what is cached, what is skipped -
are exact and independent of the timings.

---

## The four bottlenecks

### 1. No dependency caching

The baseline installs `uv` by piping a shell script from the network, then
resolves and downloads the full dependency tree on every single run. Nothing
persists between runs.

```yaml
# ci-baseline.yml
- name: Install uv
  run: curl -LsSf https://astral.sh/uv/install.sh | sh
- name: Install dependencies
  run: uv sync --all-groups
```

**Measured:** a cold `uv sync --all-groups` populates a 144 MB cache in **1.07 s**
locally; the same sync with a warm cache takes **0.10 s**. `uv` is fast enough
that this is not the dominant cost here - but it is paid by *every job*, and the
baseline pays it while also holding a Postgres container open.

**Fix:** `astral-sh/setup-uv` with `enable-cache: true`, keyed on `uv.lock`, wrapped
in a composite action at `.github/actions/setup-python-env` so every job caches
identically. A divergent cache key in one job silently costs a full resolution on
every run, which is exactly the kind of regression that never gets noticed.

### 2. Strict sequencing of independent work

Lint, type check, unit tests, integration tests, and the container build have no
data dependency on each other. The baseline runs them one after another anyway,
so total time is their sum, and a lint error is not reported until everything
ahead of it has finished.

**Fix:** one job each, all fanning out from a single cheap `changes` job. Wall-clock
becomes the slowest branch rather than the sum of all branches. `lint` and
`typecheck` are deliberately separate so a type error and a lint error are both
reported on the first run instead of one masking the other.

### 3. A database held open for jobs that never touch it

The baseline declares the Postgres service at job level, so the container is
booted and held for checkout, dependency install, lint, type check, unit tests
*and* the Docker build - none of which open a connection.

**Fix:** the service container is declared only on the `integration` job. Unit
tests have no database dependency by construction: `tests/unit` exercises the
state machine, schema validation, and service layer with the repository stubbed.

This is why coverage is combined rather than measured per-suite - see
[The coverage gate](#the-coverage-gate).

### 4. Docker builds with no layer cache

`docker build` with no `cache-from` rebuilds every layer on every commit,
including the dependency install, even when only application code changed.

**Measured**, with the multi-stage `Dockerfile` in this repository:

| Scenario | Build time | What was reused |
| --- | --- | --- |
| Cold, `--no-cache` | **8.7 s** | nothing |
| No source change | **0.9 s** | every layer |
| Application code changed | **3.1 s** | the dependency layer |
| `pyproject.toml` / `uv.lock` changed | **3.9 s** | base image only |

The 8.7 s → 3.1 s gap between a cold build and a code-only rebuild is the entire
value of ordering the Dockerfile so dependencies are copied and installed
*before* application source. On a hosted runner, where the base image must also
be pulled, the same ratio applies to a much larger absolute number.

**Fix:** `docker/build-push-action` with `cache-from`/`cache-to: type=gha,mode=max`.
`mode=max` caches intermediate stages, so the expensive `builder` stage is reused
rather than reconstructed. CI warms the cache on every commit; CD reads it, so
the release build is a re-export rather than a rebuild.

---

## Before and after

### Baseline: one job, everything in sequence

```
job: build-test-deploy  [postgres service held open for the entire job]
  checkout → setup-python → install uv → uv sync (cold)
    → ruff → ruff format → mypy
    → unit tests → integration tests → coverage gate
    → docker build (--no-cache)
    → aws auth → deploy
```

| Stage | Measured (local) | Projected (runner) |
| --- | --- | --- |
| Job start + Postgres boot | - | 15 s |
| Checkout | - | 5 s |
| setup-python | - | 8 s |
| Install uv (network script) | - | 8 s |
| `uv sync` (cold, no cache) | 1.07 s | 35 s |
| `ruff check` | 0.41 s | 4 s |
| `ruff format --check` | 0.10 s | 2 s |
| `mypy app` (cold cache) | 0.09 s (warm) | 20 s |
| Unit tests | 1.80 s | 12 s |
| Integration tests | 2.65 s | 18 s |
| Coverage gate | - | 4 s |
| `docker build --no-cache` | 8.7 s | 150 s |
| Auth + deploy | - | 30 s |
| **Total (sum - it is all serial)** | | **~5 min 51 s** |

### Rewrite: fan out, cache, skip

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

| Branch | Composition | Projected |
| --- | --- | --- |
| `changes` | checkout + path filter | 20 s |
| `lint` | setup (cached) + ruff | 20 s |
| `typecheck` | setup (cached) + mypy | 32 s |
| `unit` | setup (cached) + pytest | 25 s |
| `integration` | setup + Postgres boot + pytest | 35 s |
| `coverage-gate` | after `unit` + `integration`, combine + enforce | +25 s |
| `docker-build` | buildx + cached build + smoke test | 50 s |
| `security-scan` | cached build + Trivy | 75 s |
| `terraform-validate` | 13-way matrix, all parallel | 35 s |
| `kubernetes-validate` | 2-way matrix | 20 s |
| `ci-complete` | result aggregation | 10 s |

Critical path is `changes` → `security-scan` → `ci-complete`:

**20 s + 75 s + 10 s ≈ 1 min 45 s**

### Summary

| | Baseline | Rewrite | Change |
| --- | --- | --- | --- |
| Full run, code change | ~5 min 51 s | ~1 min 45 s | **-70%** |
| Docs-only change | ~5 min 51 s | ~30 s | **-91%** |
| Terraform-only change | ~5 min 51 s | ~55 s | **-84%** |
| Feedback on a lint error | ~1 min 5 s | ~20 s | **-69%** |

The docs-only and Terraform-only rows are the path filter doing its job: a README
edit skips every Python job, the container build, the scan, and both manifest
checks. The last row matters more than the headline: the baseline makes a
developer wait through dependency installation and a Postgres boot to be told
about a missing import.

### What the rewrite costs

Honest accounting, since parallelism is not free:

- **More billable minutes, less wall-clock.** Eight jobs each pay ~15 s of VM
  allocation and checkout. Total *machine* time goes up by roughly 1.5 min even
  as *developer* time drops by 4 min. On GitHub's per-minute billing that is a
  real trade, and it is the right one - engineer time is the scarcer resource.
- **The container is built twice on a full run** (`docker-build` and
  `security-scan`), because the scanner needs a loaded image and job isolation
  prevents sharing one. The second build is a cache hit, so it costs seconds, and
  it buys the two jobs running concurrently rather than in sequence.
- **`cancel-in-progress` is scoped to pull requests only.** Cancelling runs on
  `main` would leave gaps in the coverage baseline that PRs compare against.

---

## The coverage gate

The requirement is 80% coverage with a hard block on regression. Two facts drive
the implementation:

**Unit tests alone reach 47%.** Measured:

```
app/api.py           0%     app/models.py       100%
app/db.py            0%     app/repository.py    35%
app/main.py          0%     app/service.py      100%
app/config.py      100%     app/transitions.py  100%
TOTAL               47%
```

That is the honest number for pure, no-I/O tests against a service whose HTTP and
persistence layers are most of the code. Demanding 80% from unit tests alone
would push people to write shallow tests that import modules for coverage credit
without asserting behaviour.

**Combined, the suites reach 98%.** Both jobs write a coverage fragment
(`.coverage.unit`, `.coverage.integration`) and upload it. `coverage-gate`
downloads both, runs `coverage combine`, and enforces the contract. Verified
locally to produce a figure identical to a single combined run:

```
TOTAL   263 stmts   4 miss   20 branch   3 partial   98%
```

`scripts/coverage_gate.py` then applies two independent checks:

1. **Absolute floor** - combined line coverage must be ≥ 80%.
2. **Regression gate** - coverage must not fall more than 0.5pp below the
   baseline recorded by the last successful run on `main`.

The tolerance exists because line-rate arithmetic moves fractionally when
statement counts change; without it, a refactor that deletes a well-covered file
fails the build for no real reason. A missing baseline degrades to the floor
rather than failing, so an expired artifact breaks nobody's merge.

All four paths are verified:

| Scenario | Result |
| --- | --- |
| 98.48% vs 80% floor, no baseline | pass, exit 0 |
| 98.48% vs 98.48% baseline | pass, exit 0 |
| 98.48% vs 99.50% baseline (regression) | **fail, exit 1** |
| 98.48% vs 99% floor | **fail, exit 1** |

**To make this actually block a merge**, protect `main` and require the
`CI complete` status check. That single job aggregates every other job's result,
so adding a job later never means editing branch protection. Skipped jobs report
`skipped`, which passes; only `failure` and `cancelled` block.

---

## Reproducing the measurements

```bash
# Dependency cache
uv cache clean && rm -rf .venv && time uv sync --all-groups   # cold
rm -rf .venv && time uv sync --all-groups                     # warm

# Docker layer cache
docker builder prune -af
time docker build --no-cache -t mt:cold .                     # cold
time docker build -t mt:warm .                                # full cache hit
echo "# touch" >> app/__init__.py && time docker build -t mt:code .   # code change

# Coverage split
docker run -d --name pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=migration_tracker_test -p 55440:5432 postgres:17-alpine
export TEST_DATABASE_URL="postgresql+psycopg://postgres:postgres@localhost:55440/migration_tracker_test"

COVERAGE_FILE=.coverage.unit        uv run pytest tests/unit        --cov=app --cov-report=
COVERAGE_FILE=.coverage.integration uv run pytest tests/integration --cov=app --cov-report=
uv run coverage combine .coverage.unit .coverage.integration
uv run coverage report --fail-under=80
```

To time the pipelines against each other on real runners, dispatch
`CI (baseline - reference only)` and compare its duration to the `CI` run on the
same commit.
