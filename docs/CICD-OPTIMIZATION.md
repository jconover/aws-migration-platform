# Pipeline bottleneck analysis and rewrite

Two pipelines live in this repository:

| File | Purpose |
| --- | --- |
| `.github/workflows/ci-baseline.yml` | The naive "before" pipeline. `workflow_dispatch` only, kept for comparison. |
| `.github/workflows/ci.yml` | The rewrite that actually runs. |

This document identifies what was slow in the baseline, what changed, and what
the change is worth.

## A note on the numbers

Every figure in this document is measured, on this repository:

- **Local** timings were taken on an Apple M-series laptop. Reproduce them with
  the commands in [Reproducing the measurements](#reproducing-the-measurements).
- **Runner** timings come from real GitHub Actions runs and the jobs API.

This document previously carried *projected* runner timings and a headline claim
of a 70% wall-clock reduction. Both pipelines were then actually run. The
projections were wrong by up to 17×, and the measured result reversed the
conclusion. The projections have been replaced with measurements throughout, and
[Before and after, measured](#before-and-after-measured) records what the
extrapolation got wrong and why. The structural claims - what runs in parallel,
what is cached, what is skipped - were correct and are unchanged.

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

## Before and after, measured

Both pipelines were run on GitHub-hosted runners against the same commit.
**These numbers replace the projections this document previously carried. The
projections were wrong, and the measured result did not support the original
conclusion.**

| Pipeline | Wall-clock | Outcome |
| --- | --- | --- |
| `ci-baseline.yml` (serial, uncached) | **1 min 03 s** | passed everything, failed only at the AWS step, which has no credentials configured |
| `ci.yml` (parallel, cached) | **1 min 57 s** | success |

The rewrite is **54 s slower**, not 70% faster.

### Why the projections were wrong

The local measurements were accurate. The extrapolation to hosted runners was
not. I assumed a hosted runner would be slower than a laptop across the board;
for network and disk it is substantially faster.

| Stage | Projected | Actual on runner | Error |
| --- | --- | --- | --- |
| `uv sync`, cold cache | 35 s | **2 s** | 17× too high |
| `docker build --no-cache` | 150 s | **16 s** | 9× too high |
| Postgres service boot | 15 s | **14 s** | accurate |
| `mypy`, cold cache | 20 s | **8 s** | 2.5× too high |

The two stages I identified as the biggest bottlenecks - dependency install and
uncached image build - are the two that barely cost anything here. `uv` resolves
a 144 MB dependency set in two seconds on a runner, and a 337 MB image built from
a slim base with a warm layer cache is a 16-second job. **The bottlenecks were
real in structure and negligible in magnitude.**

### The comparison is not like-for-like

The baseline and the rewrite do not do the same amount of work. The rewrite adds:

| Added by the rewrite | Cost |
| --- | --- |
| Trivy image scan, SARIF upload, CRITICAL gate | **99 s** |
| Terraform `fmt` + `validate` across 13 stacks | 17 s (parallel) |
| Kustomize overlay render + substitution contract test | 8 s |
| Container smoke test and non-root verification | inside the 47 s build job |

Restricting the rewrite to only what the baseline does, and computing its
critical path from the measured job durations:

```
changes 6s
  → max(lint 9s, typecheck 15s, unit 12s, integration 43s, docker 47s) = 47s
  → coverage-gate waits on unit+integration: 43s + 15s = 58s
  → ci-complete 4s
like-for-like critical path ≈ 68s   vs   baseline 63s
```

**Like for like, the parallel pipeline is 5 s slower.** Per-job overhead - VM
allocation, checkout, tool setup, roughly 10-15 s - is paid six times instead of
once, and that exceeds everything serialisation saves when each stage takes
seconds.

### Measured job durations

| Job | Duration |
| --- | --- |
| Security scan | **99 s** ← critical path |
| Docker build (incl. smoke test) | 47 s |
| Integration tests (incl. Postgres boot) | 43 s |
| Terraform validate (slowest of 13, parallel) | 17 s |
| Type check | 15 s |
| Coverage gate | 15 s |
| Unit tests | 12 s |
| Lint | 9 s |
| Kubernetes manifests (each) | 8 s |
| Detect changes | 6 s |
| CI complete | 4 s |

Trivy dominates, and it is mostly vulnerability-database download: 125 s on the
first run, 99 s once the action's cache warmed. Caching is on by default.

### What the rewrite is actually worth

Wall-clock was the wrong headline. What the measurements support:

1. **Substantially more checking for 54 s.** Container vulnerability scanning,
   IaC validation across 13 stacks, manifest rendering, a smoke test, and a
   non-root assertion - none of which the baseline performs at all.
2. **Path filtering is the one large, real win.** A docs-only change skips every
   job and finishes in about 10 s, against 63 s for the baseline, which runs the
   whole chain regardless. That is a genuine 6× on the most common pull request.
3. **Targeted feedback.** A lint error surfaces from a 9 s job instead of after
   dependency install, type check, and both test suites have run.
4. **Failure isolation.** One green run reports every failing dimension at once,
   rather than stopping at the first.
5. **The coverage gate**, which requires the split-suite structure to work at all.

### When parallelism starts paying

The structure wins as stage durations grow, because per-job overhead is fixed:

| Test suite duration | Serial | Parallel | Winner |
| --- | --- | --- | --- |
| ~10 s (today) | 63 s | 68 s | serial, marginally |
| ~2 min | ~3 min | ~2 min 20 s | parallel |
| ~10 min | ~11 min | ~10 min 20 s | parallel, decisively |

At this repository's current size the parallel structure is not earning its
overhead on wall-clock. It is the right shape for a migration programme whose
test surface grows every wave, and the added scope is worth 54 s today. But the
honest statement is that **it was adopted for scope and feedback quality, not for
speed, and the speed claim it was originally justified with did not survive
measurement.**

### If sub-60 s pull-request feedback is wanted

The single lever is Trivy, which is 85% of the critical path. Move the image
scan to `push`-on-`main` plus a nightly schedule and leave pull requests with the
faster checks; the critical path drops to roughly 68 s. That trades scan latency
on feature branches for feedback speed, and is a team decision rather than an
obvious win - it is deliberately not applied here.

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

To reproduce the pipeline comparison:

```bash
gh workflow run ci-baseline.yml --ref main     # the serial baseline
gh run list --workflow ci-baseline.yml --limit 1
gh run list --workflow ci.yml --limit 1        # the parallel rewrite
```

Both were measured this way. The baseline fails at its final AWS step, which has
no credentials configured; every stage before it completes, so its wall-clock is
a valid measurement of the full lint, test, coverage, and build path.
