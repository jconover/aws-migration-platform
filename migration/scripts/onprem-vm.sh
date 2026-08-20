#!/usr/bin/env bash
# Stand up an on-premises source estate as real Ubuntu virtual machines.
#
# The Talos cluster is one kind of source: containerised, orchestrated, modern.
# Most estates being migrated are not that. They are long-lived VMs with a
# package-managed database installed on the box, which is what this builds -
# the lift-and-shift case the EC2 rehost target exists to receive.
#
#   ./onprem-vm.sh up       create the VM, install Postgres, seed the portfolio
#   ./onprem-vm.sh status   show the VM, its address and its row counts
#   ./onprem-vm.sh dsn      print a connection string for the VM's database
#   ./onprem-vm.sh shell    open a shell on the VM
#   ./onprem-vm.sh down     delete the VM and purge it
#   ./onprem-vm.sh doctor   check multipass, the daemon and the VM's state
#
# The database listens on the VM's own address rather than a forwarded port, so
# the migration reaches it over the network exactly as it would reach a real
# on-premises host.
set -euo pipefail

readonly VM_NAME="${VM_NAME:-onprem-db-01}"
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY="${VM_MEMORY:-2G}"
readonly VM_DISK="${VM_DISK:-8G}"
readonly VM_IMAGE="${VM_IMAGE:-24.04}"

readonly DB_NAME="${DB_NAME:-migration_tracker}"
readonly DB_USER="${DB_USER:-tracker_admin}"

MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../deploy/onprem" && pwd)"
readonly MANIFESTS
readonly SEED_SQL="${MANIFESTS}/seed.sql"

# The generated password lives on the host so repeated runs reuse it rather
# than locking themselves out of a database that is already initialised.
readonly STATE_DIR="${STATE_DIR:-${HOME}/.local/state/migration-demo}"
readonly PASS_FILE="${STATE_DIR}/${VM_NAME}.password"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

require_multipass() {
  command -v multipass >/dev/null 2>&1 \
    || die "multipass is required: brew install --cask multipass"

  # A dead daemon reports as a socket error on every command, which is not
  # obvious from the message multipass prints.
  if ! multipass list >/dev/null 2>&1; then
    die "cannot reach the multipass daemon.
    The CLI is installed but multipassd is not answering. Start it with:
      sudo launchctl kickstart -k system/com.canonical.multipassd"
  fi
}

vm_exists() {
  multipass list --format csv 2>/dev/null | awk -F, 'NR>1 {print $1}' | grep -qx "${VM_NAME}"
}

vm_state() {
  multipass list --format csv 2>/dev/null | awk -F, -v n="${VM_NAME}" 'NR>1 && $1==n {print $2}'
}

vm_ip() {
  multipass info "${VM_NAME}" --format csv 2>/dev/null | awk -F, 'NR>1 {print $3}'
}

db_password() {
  [ -f "${PASS_FILE}" ] || return 1
  cat "${PASS_FILE}"
}

# --------------------------------------------------------------------------
cmd_up() {
  require_multipass
  [ -f "${SEED_SQL}" ] || die "seed file not found: ${SEED_SQL}"

  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  if [ ! -f "${PASS_FILE}" ]; then
    (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "${PASS_FILE}")
  fi
  local password; password="$(db_password)"

  if vm_exists; then
    info "VM ${VM_NAME} already exists (state: $(vm_state))"
    if [ "$(vm_state)" != "Running" ]; then
      info "starting it"
      multipass start "${VM_NAME}"
    fi
  else
    log "Creating Ubuntu ${VM_IMAGE} VM: ${VM_NAME} (${VM_CPUS} cpu, ${VM_MEMORY} ram, ${VM_DISK} disk)"
    multipass launch "${VM_IMAGE}" --name "${VM_NAME}" \
      --cpus "${VM_CPUS}" --memory "${VM_MEMORY}" --disk "${VM_DISK}"
  fi

  log "Installing PostgreSQL on the VM"
  # DEBIAN_FRONTEND keeps apt from trying to open a dialogue on a headless box.
  multipass exec "${VM_NAME}" -- sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get update -qq
  multipass exec "${VM_NAME}" -- sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null

  local pgver
  pgver="$(multipass exec "${VM_NAME}" -- sh -c 'ls /etc/postgresql | head -1')"
  info "postgresql ${pgver} installed"

  log "Configuring the database to accept connections from the host"
  # A packaged Postgres listens on localhost only. A real on-premises database
  # serves its network, so bind it to the VM's address and let the host subnet
  # authenticate with a password.
  multipass exec "${VM_NAME}" -- sudo sh -c \
    "echo \"listen_addresses = '*'\" > /etc/postgresql/${pgver}/main/conf.d/10-listen.conf"
  multipass exec "${VM_NAME}" -- sudo sh -c \
    "grep -q 'migration-demo' /etc/postgresql/${pgver}/main/pg_hba.conf || \
     echo 'host all all 0.0.0.0/0 scram-sha-256 # migration-demo' >> /etc/postgresql/${pgver}/main/pg_hba.conf"
  multipass exec "${VM_NAME}" -- sudo systemctl restart postgresql

  log "Creating the role and database"
  # Idempotent: re-running up must not fail on an existing role or database.
  multipass exec "${VM_NAME}" -- sudo -u postgres psql -v ON_ERROR_STOP=1 -q -c \
    "DO \$\$ BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
         CREATE ROLE ${DB_USER} LOGIN PASSWORD '${password}';
       ELSE
         ALTER ROLE ${DB_USER} PASSWORD '${password}';
       END IF;
     END \$\$;"
  multipass exec "${VM_NAME}" -- sudo -u postgres sh -c \
    "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" | grep -q 1 || \
     createdb -O ${DB_USER} ${DB_NAME}"

  log "Seeding the discovery portfolio"
  multipass transfer "${SEED_SQL}" "${VM_NAME}:/tmp/seed.sql"
  multipass exec "${VM_NAME}" -- sudo -u postgres \
    psql -v ON_ERROR_STOP=1 -q -d "${DB_NAME}" -f /tmp/seed.sql
  # The seed creates objects as the superuser; hand them to the application role
  # so the dump and the migration run as an unprivileged user.
  multipass exec "${VM_NAME}" -- sudo -u postgres psql -q -d "${DB_NAME}" -c \
    "ALTER TABLE workloads OWNER TO ${DB_USER};
     ALTER SEQUENCE workloads_id_seq OWNER TO ${DB_USER};"

  local ip; ip="$(vm_ip)"
  log "On-premises VM source is up"
  info "address : ${ip}"
  info "database: postgresql://${DB_USER}:***@${ip}:5432/${DB_NAME}"
  info "rows    : $(row_count)"
  info ""
  info "Migrate from it with:"
  info "  SOURCE=vm migration/scripts/migrate.sh cutover"
}

row_count() {
  multipass exec "${VM_NAME}" -- sudo -u postgres \
    psql -tAc "SELECT count(*) FROM workloads" -d "${DB_NAME}" 2>/dev/null | tr -d ' \r'
}

cmd_dsn() {
  require_multipass
  vm_exists || die "VM ${VM_NAME} does not exist - run: $0 up"
  local password; password="$(db_password)" || die "no stored password for ${VM_NAME}"
  echo "postgresql://${DB_USER}:${password}@$(vm_ip):5432/${DB_NAME}"
}

cmd_status() {
  require_multipass
  log "On-premises VM source"
  if ! vm_exists; then
    info "VM ${VM_NAME} does not exist - run: $0 up"
    return
  fi
  multipass info "${VM_NAME}" 2>/dev/null | sed 's/^/    /'
  if [ "$(vm_state)" = "Running" ]; then
    info "workload rows by wave:"
    multipass exec "${VM_NAME}" -- sudo -u postgres psql -d "${DB_NAME}" -tAc \
      "SELECT wave || ': ' || count(*) FROM workloads GROUP BY wave ORDER BY wave" 2>/dev/null \
      | sed 's/^/      wave /' || info "      database not answering"
  fi
}

cmd_shell() {
  require_multipass
  vm_exists || die "VM ${VM_NAME} does not exist - run: $0 up"
  multipass shell "${VM_NAME}"
}

cmd_doctor() {
  log "Preflight: on-premises VM source"

  if command -v multipass >/dev/null 2>&1; then
    info "[ ok ] multipass installed ($(multipass version 2>/dev/null | head -1 | awk '{print $2}'))"
  else
    info "[fail] multipass NOT installed - brew install --cask multipass"
    return 1
  fi

  if multipass list >/dev/null 2>&1; then
    info "[ ok ] multipass daemon answering"
  else
    info "[fail] multipass daemon NOT answering"
    info "       sudo launchctl kickstart -k system/com.canonical.multipassd"
    return 1
  fi

  if vm_exists; then
    local state ip; state="$(vm_state)"; ip="$(vm_ip)"
    info "[ ok ] VM ${VM_NAME} exists (${state})"
    if [ "${state}" = "Running" ]; then
      info "       address ${ip}"
      local rows; rows="$(row_count || true)"
      if [ -n "${rows}" ]; then
        info "[ ok ] database answering, ${rows} workload rows"
      else
        info "[warn] VM running but the database is not answering - re-run: $0 up"
      fi
    fi
  else
    info "[info] VM ${VM_NAME} not created - run: $0 up"
  fi

  if [ -f "${PASS_FILE}" ]; then
    info "[ ok ] credential stored at ${PASS_FILE}"
  else
    info "[info] no credential yet - created by: $0 up"
  fi
}

cmd_down() {
  require_multipass
  log "Removing the on-premises VM source"
  if vm_exists; then
    multipass delete "${VM_NAME}"
    multipass purge
    info "deleted and purged ${VM_NAME}"
  else
    info "VM ${VM_NAME} does not exist"
  fi
  rm -f "${PASS_FILE}"
}

case "${1:-}" in
  up)     cmd_up ;;
  status) cmd_status ;;
  dsn)    cmd_dsn ;;
  shell)  cmd_shell ;;
  doctor) cmd_doctor ;;
  down)   cmd_down ;;
  *)
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
