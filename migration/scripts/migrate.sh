#!/usr/bin/env bash
# Drive a workload migration from the on-premises Talos cluster into AWS.
#
# The sequence mirrors docs/RUNBOOK.md, with the verification gate as the point
# of no return. Every step is idempotent and every step can be run on its own,
# because during a real cutover you rarely get to run the happy path start to
# finish.
#
#   ./migrate.sh up        deploy the on-premises source onto Talos
#   ./migrate.sh status    show what exists on each side
#   ./migrate.sh snapshot  dump the on-premises database
#   ./migrate.sh restore   load the dump into the target
#   ./migrate.sh verify    compare source and target - the cutover gate
#   ./migrate.sh cutover   snapshot, restore and verify in one gated sequence
#   ./migrate.sh rollback  point back at the source and report
#   ./migrate.sh down      remove the on-premises source
#
# Target selection:
#   TARGET_DSN unset  -> a local Postgres container stands in for RDS, so the
#                        whole flow is runnable without an AWS account
#   TARGET_DSN set    -> that database is used, e.g. the real RDS endpoint
set -euo pipefail

readonly NAMESPACE="${NAMESPACE:-legacy-onprem}"
readonly KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/nexus}"
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../deploy/onprem" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly MANIFESTS REPO_ROOT
readonly WORKDIR="${WORKDIR:-/tmp/migration-demo}"
readonly DUMP_FILE="${WORKDIR}/onprem-workloads.sql"

readonly STANDIN_CONTAINER="migration-target-rds"
readonly STANDIN_PORT="${STANDIN_PORT:-55500}"
readonly STANDIN_DSN="postgresql://postgres:postgres@localhost:${STANDIN_PORT}/migration_tracker"

export KUBECONFIG="${KUBECONFIG_PATH}"

# Diagnostics go to stderr so that functions which return a value via stdout -
# ensure_target in particular - are not polluted by their own logging.
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

source_pod() {
  kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=legacy-postgres \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --------------------------------------------------------------------------
# Target: either a real DSN, or a local container standing in for RDS.
# --------------------------------------------------------------------------
ensure_target() {
  if [ -n "${TARGET_DSN:-}" ]; then
    info "target: caller-supplied DSN"
    echo "${TARGET_DSN}"
    return
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "${STANDIN_CONTAINER}"; then
    info "target: starting local stand-in for RDS on port ${STANDIN_PORT}"
    docker rm -f "${STANDIN_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d --name "${STANDIN_CONTAINER}" \
      -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=migration_tracker \
      -p "${STANDIN_PORT}:5432" postgres:17-alpine >/dev/null
    for _ in $(seq 1 60); do
      docker exec "${STANDIN_CONTAINER}" pg_isready -U postgres >/dev/null 2>&1 && break
      sleep 1
    done
  else
    info "target: reusing local stand-in on port ${STANDIN_PORT}"
  fi
  echo "${STANDIN_DSN}"
}

# --------------------------------------------------------------------------
cmd_up() {
  require kubectl
  log "Deploying the on-premises source onto Talos"
  kubectl apply -f "${MANIFESTS}/namespace.yaml"
  kubectl apply -f "${MANIFESTS}/postgres.yaml"

  info "waiting for the on-premises database"
  kubectl -n "${NAMESPACE}" rollout status statefulset/legacy-postgres --timeout=5m

  info "seeding the discovery portfolio"
  kubectl -n "${NAMESPACE}" delete job legacy-seed --ignore-not-found >/dev/null
  kubectl apply -f "${MANIFESTS}/seed-job.yaml"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete job/legacy-seed --timeout=5m

  kubectl -n "${NAMESPACE}" logs job/legacy-seed | tail -12
  log "On-premises source is up"
}

cmd_status() {
  require kubectl
  log "On-premises (Talos, namespace ${NAMESPACE})"
  if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl -n "${NAMESPACE}" get pods,pvc,svc 2>/dev/null || true
    local pod; pod="$(source_pod)"
    if [ -n "${pod}" ]; then
      info "workload rows on-premises:"
      kubectl -n "${NAMESPACE}" exec "${pod}" -- \
        psql -U tracker_admin -d migration_tracker -tAc \
        "SELECT wave || ': ' || count(*) FROM workloads GROUP BY wave ORDER BY wave" 2>/dev/null | sed 's/^/      wave /'
    fi
  else
    info "namespace ${NAMESPACE} does not exist - run: $0 up"
  fi

  log "Target"
  if [ -n "${TARGET_DSN:-}" ]; then
    info "using caller-supplied TARGET_DSN"
  elif docker ps --format '{{.Names}}' | grep -qx "${STANDIN_CONTAINER}"; then
    info "local stand-in running on port ${STANDIN_PORT}"
  else
    info "no target yet - created on first restore"
  fi
}

cmd_snapshot() {
  require kubectl
  local pod; pod="$(source_pod)"
  [ -n "${pod}" ] || die "on-premises database not found - run: $0 up"

  mkdir -p "${WORKDIR}"
  log "Snapshotting the on-premises database"

  # --data-only plus explicit column ordering keeps the dump portable across a
  # schema created by SQLAlchemy on one side and by DDL on the other.
  kubectl -n "${NAMESPACE}" exec "${pod}" -- \
    pg_dump -U tracker_admin -d migration_tracker \
      --no-owner --no-privileges --column-inserts > "${DUMP_FILE}"

  local rows; rows="$(grep -c '^INSERT INTO' "${DUMP_FILE}" || true)"
  info "dump written: ${DUMP_FILE}"
  info "insert statements captured: ${rows}"
}

cmd_restore() {
  require docker
  [ -f "${DUMP_FILE}" ] || die "no dump found - run: $0 snapshot"
  local dsn; dsn="$(ensure_target)"

  log "Restoring into the target"

  # A full load starts from an empty target, the same as a DMS full-load task.
  # Without this, a re-run fails on "relation already exists" and - worse - a
  # partially populated target could pass a row-count check by coincidence.
  local reset_sql="DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

  if [ -n "${TARGET_DSN:-}" ]; then
    require psql
    info "resetting target schema"
    psql "${dsn}" -v ON_ERROR_STOP=1 -q -c "${reset_sql}" >/dev/null
    psql "${dsn}" -v ON_ERROR_STOP=1 -q -f "${DUMP_FILE}" >/dev/null
  else
    info "resetting target schema"
    docker exec -i "${STANDIN_CONTAINER}" \
      psql -U postgres -d migration_tracker -v ON_ERROR_STOP=1 -q -c "${reset_sql}" >/dev/null
    docker exec -i "${STANDIN_CONTAINER}" \
      psql -U postgres -d migration_tracker -v ON_ERROR_STOP=1 -q < "${DUMP_FILE}" >/dev/null
  fi
  info "restore complete"
}

cmd_verify() {
  local dsn; dsn="$(ensure_target)"
  local pod; pod="$(source_pod)"
  [ -n "${pod}" ] || die "on-premises database not found - run: $0 up"

  log "Verification gate: comparing source and target"

  # Port-forward so the verifier can reach the on-premises database directly,
  # rather than trusting a value echoed back through kubectl exec.
  kubectl -n "${NAMESPACE}" port-forward "pod/${pod}" 55501:5432 >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill '"${pf_pid}"' 2>/dev/null || true' RETURN
  for _ in $(seq 1 30); do
    (echo > /dev/tcp/127.0.0.1/55501) >/dev/null 2>&1 && break
    sleep 1
  done

  local source_dsn="postgresql://tracker_admin:onprem-legacy-password@localhost:55501/migration_tracker"
  ( cd "${REPO_ROOT}" && uv run python -m migration.verify \
      --source "${source_dsn}" --target "${dsn}" --tables workloads )
}

cmd_cutover() {
  log "CUTOVER: snapshot -> restore -> verify"
  cmd_snapshot
  cmd_restore
  if cmd_verify; then
    log "Gate passed. Repoint the application at the target and remove the maintenance page."
    info "Rollback remains available until the source is decommissioned."
  else
    log "Gate FAILED. Do not proceed."
    info "The source is untouched and still authoritative. Run: $0 rollback"
    return 1
  fi
}

cmd_rollback() {
  log "Rollback"
  info "The on-premises source was never modified by this flow, so it remains authoritative."
  info "Actions: repoint DNS at the source, remove the maintenance page, then record"
  info "the workload as rolled_back:"
  info "  PATCH /api/v1/workloads/{id}/status  {\"status\": \"rolled_back\"}"
  info "The state machine returns it to 'assessed', so assessment work is not lost."
}

cmd_down() {
  require kubectl
  log "Removing the on-premises source"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
  docker rm -f "${STANDIN_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
  info "removed (PVCs are deleted with the namespace by the Longhorn reclaim policy)"
}

case "${1:-}" in
  up)       cmd_up ;;
  status)   cmd_status ;;
  snapshot) cmd_snapshot ;;
  restore)  cmd_restore ;;
  verify)   cmd_verify ;;
  cutover)  cmd_cutover ;;
  rollback) cmd_rollback ;;
  down)     cmd_down ;;
  *)
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
