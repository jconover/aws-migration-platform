-- Canonical on-premises seed: the inventory a discovery phase would have
-- produced, and the data the verification gate checks after a migration.
--
-- One file, two consumers, so the two source estates cannot drift apart:
--   seed-job.yaml     mounts this as a ConfigMap on the Talos cluster
--   onprem-vm.sh      applies it directly inside an Ubuntu VM
--
-- If the row count here changes, docs/MIGRATION-DEMO.md's "20 rows" changes
-- with it.

CREATE TABLE IF NOT EXISTS workloads (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL UNIQUE,
    wave        INTEGER NOT NULL,
    strategy    VARCHAR(20) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'discovered',
    owner       VARCHAR(200) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_workloads_wave   ON workloads (wave);
CREATE INDEX IF NOT EXISTS ix_workloads_status ON workloads (status);

-- A portfolio shaped like a real discovery output: a spread of strategies, a
-- long tail of retire candidates, and waves that get progressively more
-- critical.
INSERT INTO workloads (name, wave, strategy, status, owner) VALUES
  ('billing-api',        1, 'replatform', 'validated',  'payments'),
  ('billing-worker',     1, 'replatform', 'validated',  'payments'),
  ('invoice-renderer',   1, 'rehost',     'validated',  'payments'),
  ('legacy-fax-gateway', 1, 'retire',     'assessed',   'facilities'),
  ('print-spooler',      1, 'retire',     'assessed',   'facilities'),
  ('orders-api',         2, 'replatform', 'cutover',    'commerce'),
  ('orders-worker',      2, 'replatform', 'cutover',    'commerce'),
  ('inventory-sync',     2, 'rehost',     'in_flight',  'commerce'),
  ('pricing-engine',     2, 'refactor',   'in_flight',  'commerce'),
  ('warehouse-scanner',  2, 'rehost',     'assessed',   'logistics'),
  ('crm-connector',      3, 'repurchase', 'assessed',   'sales'),
  ('reporting-etl',      3, 'replatform', 'in_flight',  'data'),
  ('data-warehouse',     3, 'relocate',   'discovered', 'data'),
  ('ml-feature-store',   3, 'refactor',   'discovered', 'data'),
  ('hr-portal',          4, 'repurchase', 'discovered', 'people'),
  ('payroll-batch',      4, 'retain',     'assessed',   'people'),
  ('mainframe-bridge',   4, 'retain',     'assessed',   'core-systems'),
  ('auth-service',       4, 'refactor',   'discovered', 'platform'),
  ('audit-log-archive',  5, 'rehost',     'discovered', 'compliance'),
  ('dr-replica',         5, 'relocate',   'discovered', 'platform')
ON CONFLICT (name) DO NOTHING;
