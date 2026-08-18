# Runnable migration: on-premises Talos to AWS

The rest of this repository describes how a migration should work. This one is
executable, against real infrastructure, in about two minutes.

**Source:** a three-node bare-metal Talos Kubernetes cluster - Longhorn storage,
Cilium CNI - standing in for the datacentre.
**Target:** AWS RDS, or a local Postgres container when no AWS account is wired
up, so the flow runs end to end without credentials.

```
  ON-PREMISES (Talos, bare metal)                    AWS
  ┌────────────────────────────────┐          ┌──────────────────┐
  │ namespace: legacy-onprem       │          │ RDS Postgres     │
  │                                │ snapshot │ Multi-AZ         │
  │  legacy-postgres (StatefulSet) │─────────▶│ isolated subnets │
  │  Longhorn PVC, 20 workloads    │ restore  └────────┬─────────┘
  │                                │                   │
  │  legacy-tracker (Deployment)   │            verification gate
  └────────────────────────────────┘         row counts + checksums
                                                       │
                                              pass ────┴──── fail
                                            cut over      roll back
```

## Run it

```bash
./migration/scripts/migrate.sh up        # deploy the source onto Talos
./migration/scripts/migrate.sh status    # what exists on each side
./migration/scripts/migrate.sh cutover   # snapshot -> restore -> verify
./migration/scripts/migrate.sh down      # remove everything
```

Point it at real RDS by exporting a DSN; nothing else changes:

```bash
export TARGET_DSN="postgresql://user:pass@migration-tracker.abc.eu-west-2.rds.amazonaws.com:5432/migration_tracker"
./migration/scripts/migrate.sh cutover
```

## What actually happened

Executed against the live cluster:

```
==> Deploying the on-premises source onto Talos
    waiting for the on-premises database
    seeding the discovery portfolio
 wave | workloads | migrated
------+-----------+----------
    1 |         5 |        3
    2 |         5 |        0
    3 |         4 |        0
    4 |         4 |        0
    5 |         2 |        0
total rows: 20

==> CUTOVER: snapshot -> restore -> verify
    dump written: /tmp/migration-demo/onprem-workloads.sql
    insert statements captured: 20
    resetting target schema
    restore complete
==> Verification gate: comparing source and target
OK   workloads: identical
MATCH - safe to proceed
```

## The verification gate

Step 4 of the cutover in [RUNBOOK.md](RUNBOOK.md) is the last point at which
rolling back is cheap, so it is the one step worth building properly.
`migration/verify.py` fingerprints every table on both sides and refuses to pass
unless they match exactly.

The checksum is a sum of per-row md5 hashes cast to `bigint`. `sum()` is
commutative, so the result does not depend on physical row order - which no dump
and restore preserves. Verified directly against Postgres: reordering the same
rows produces an identical checksum, changing one character does not.

Both failure modes were induced deliberately against the live target:

| Injected fault | Detected as | Exit |
| --- | --- | --- |
| One field edited, row count unchanged | `checksum differs (source 241006868504, target 183284326696)` | 1 |
| One row deleted | `row count 20 -> 19 (-1)` | 1 |
| Target unreachable | `could not fingerprint databases` | 2 |

The row-count case is reported *instead of* the checksum for the same table,
because the count says how much data was lost; a checksum only says "different".

**A row-count check alone would have waved the first case straight through.**
That is the failure mode worth caring about: the data arrives, the count is
right, and the contents are silently wrong.

The gate fails closed. A connection error returns 2, not 0 - "could not check"
must never be read as "checked and fine". This was not theoretical during
development: an early bug polluted the DSN and the gate correctly refused to
proceed rather than passing on a comparison it never performed.

## Notes from building it on a live cluster

**Pod Security Standards.** The cluster enforces `restricted`, and the first
deploy produced warnings for the Postgres pod. Fixed properly - `runAsNonRoot`,
uid 999, dropped capabilities, `RuntimeDefault` seccomp - rather than lowering
the namespace policy.

**Volume ownership.** After switching to uid 999, Postgres refused to start:
`data directory has wrong ownership`. The Longhorn PVC had been initialised
while the pod ran as root. Recreating the volume so it initialises under the
correct user is the fix; `fsGroup` alone does not repair an existing directory.

**Idempotency.** The first restore into an already-populated target failed with
`relation "workloads" already exists`. A full load now resets the target schema
first, matching DMS full-load semantics. Without it, a partially populated
target could coincidentally pass a row-count check.

## What this demonstrates, and what it does not

Genuinely shown: a real Kubernetes source on bare metal, real persistent
storage, a real dump and restore, and a verification gate proven to catch both
silent corruption and data loss.

Not shown: continuous replication. This is a full load, not DMS with CDC, so it
implies downtime for the duration. A production cutover would run CDC to keep
the target in sync and reduce the window to the drain-and-verify step described
in [RUNBOOK.md](RUNBOOK.md). Reverse replication - the thing that makes rollback
cheap - is likewise described there rather than implemented here.
