# Runbook - cutover, rollback, and post-migration support

Operational procedures for the migration programme. Written to be followed at
03:00 by someone who did not write it.

| I need to... | Go to |
| --- | --- |
| Cut a workload over | [Cutover](#cutover) |
| Undo a bad release or a failed cutover | [Rollback](#rollback) |
| Bring the on-premises cluster back after an outage | [Source estate recovery](#source-estate-recovery-on-premises-talos) |
| Build or rebuild an AWS target with Terraform | [SETUP.md §7](SETUP.md#7-building-each-landing-target) |
| Move data into a target and verify it | [MIGRATION-DEMO.md](MIGRATION-DEMO.md#against-real-rds) |
| Diagnose a live incident | [Common incidents](#common-incidents) |

---

## Cutover

### T-7 days

- [ ] Target infrastructure applied via Terraform; `terraform plan` is clean
- [ ] DMS full load complete, CDC running, replication lag < 5 s sustained
- [ ] **Reverse replication configured and tested** - target back to source
- [ ] Application tested against replicated data; owner has signed off
- [ ] DNS TTL lowered to 60 s (do this a week ahead - it must have propagated)
- [ ] Rollback decision-maker named, with a phone number
- [ ] Cutover window agreed and communicated to consumers

The reverse replication item is the one that gets skipped and the one that hurts.
Without it, rollback means restoring from backup - a different procedure with a
different duration and a different conversation with the business.

### T-1 day

- [ ] Freeze application changes on the source
- [ ] Take a verified source backup; **test the restore**, do not just take it
- [ ] Confirm on-call staffing for the window plus 24 hours
- [ ] Dry-run the cutover steps in staging end to end

### Cutover window

| # | Step | Verify | Est. |
| --- | --- | --- | --- |
| 1 | Announce start; enable maintenance page | Consumers see the page | 5 m |
| 2 | Stop writes on source | `SELECT count(*) FROM pg_stat_activity WHERE state='active'` returns only replication | 5 m |
| 3 | Wait for replication lag to reach zero | DMS `CDCLatencySource` = 0 | 5-15 m |
| 4 | **Verification gate** - row counts and checksums per table | Every table matches. **Mismatch = stop and roll back.** | 10-30 m |
| 5 | Stop DMS task | Task status `Stopped` | 2 m |
| 6 | Point application at the RDS endpoint | `kubectl rollout status` reports complete | 5 m |
| 7 | Smoke test | `/readyz` returns 200; core user journey passes | 10 m |
| 8 | Repoint DNS | `dig` shows the new target from three networks | 5 m |
| 9 | Remove maintenance page; monitor | Error rate and latency at or below baseline | 30 m |

Step 4 is the gate. If counts or checksums do not match, roll back. Do not
investigate with the maintenance page up and the clock running - investigate
after the source is serving again.

### Rollback decision deadline

**Set a wall-clock time before the window opens.** If the service is not healthy
by that time, roll back regardless of how close a fix feels. Every cutover
overrun in this pattern comes from a team that was "nearly there" for two hours.

---

## Rollback

### Application rollback (EKS)

Automatic first. `reusable-deploy-eks.yml` runs `kubectl rollout undo` when
`kubectl rollout status` fails, then fails the job so the failure is not silent.

Manual:

```bash
aws eks update-kubeconfig --name <cluster> --region <region>
kubectl rollout undo deployment/migration-tracker -n migration-tracker
kubectl rollout status  deployment/migration-tracker -n migration-tracker --timeout=5m

# To a specific revision
kubectl rollout history deployment/migration-tracker -n migration-tracker
kubectl rollout undo    deployment/migration-tracker -n migration-tracker --to-revision=<n>
```

### Application rollback (ECS)

The deployment circuit breaker rolls back automatically on failure to stabilise.
Manually:

```bash
aws ecs update-service --cluster <cluster> --service <service> \
  --task-definition <family>:<previous-revision> --force-new-deployment
aws ecs wait services-stable --cluster <cluster> --services <service>
```

### Full cutover rollback

Time-critical. Follow in order:

1. **Re-enable the maintenance page.** Stop new writes to the target immediately.
2. **Start reverse replication** (target → source). Wait for lag zero.
3. **Verify** row counts and checksums on the source.
4. **Repoint DNS** to the source. Confirm from multiple networks.
5. **Restore the application** on the source; run the smoke test.
6. **Remove the maintenance page.**
7. **Record what happened** in the tracker: `PATCH /api/v1/workloads/{id}/status`
   with `rolled_back`. The state machine returns it to `assessed`, not
   `discovered` - assessment work is not lost.

---

## Source estate recovery (on-premises Talos)

The source estate is still production until the last workload is validated, so
bringing it back after an outage is a migration procedure, not someone else's
problem. This section was written during an actual recovery: a storm took mains
power, all three Talos nodes went down, and the sequence below is what was run.

### 1. Confirm it is the cluster, not your route to it

`network is unreachable` and `no route to host` mean different things, and
neither necessarily means the cluster is down.

```bash
./migration/scripts/migrate.sh doctor
```

The report names the endpoint and this machine's address, which is usually
enough:

```
[fail] cluster NOT reachable at https://192.168.70.9:6443
       this machine: 192.168.10.14
       the kubeconfig is fine; nothing is answering on that address.
```

A laptop on a different subnet from the cluster produces exactly the same
symptom as a powered-off cluster. Check which you have before touching anything.

### 2. Power on, control plane first

Bring the control-plane nodes up together rather than one at a time. etcd needs a
quorum — with three members, two must be present before the API server will
serve. Staggering power-on by several minutes leaves a single member unable to
form a quorum, which looks like a broken cluster and is not.

### 3. Watch the nodes rejoin

```bash
kubectl get nodes -w
```

All members should reach `Ready`. Expect a few minutes: etcd elects a leader,
the API server starts, then kubelets report in.

If a node does not rejoin and you have a working `talosconfig`, the machine API
is where to look next. These need PKI that a kubeconfig does not provide — see
[GUIDE.md](GUIDE.md) if `talosctl` reports `talos config file is empty`:

```bash
talosctl -n <node-ip> health
talosctl -n <node-ip> dmesg | tail -50
talosctl -n <node-ip> service etcd status
```

### 4. Expect stranded pods, and let the StatefulSet fix them

A pod whose node vanished mid-write is commonly left in `Unknown`:

```
pod/legacy-postgres-0   0/1   Unknown   0   17h
```

**Wait before intervening.** Once the node rejoins, Kubernetes deletes the
stranded pod and the StatefulSet recreates it. In the recovery this section
documents, that happened without any manual step: the pod was rescheduled onto a
healthy node and reached `1/1 Running` in about 13 seconds once the volume
attached.

Intervene only if it stays `Unknown` after the node is `Ready`:

```bash
kubectl -n legacy-onprem delete pod legacy-postgres-0
```

That is safe. The PVC is a separate object and is not affected — deleting the pod
only discards the stranded pod record.

**Do not delete the PVC.** That is the one destructive step available here, and
it throws away the data you are trying to recover.

### 5. Confirm storage reattached and the data survived

Longhorn reattaches the volume to whichever node the pod lands on. Watch for a
volume stuck detaching, or a degraded replica rebuild:

```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n legacy-onprem get pvc
```

Then verify the data itself, which is the only check that actually matters:

```bash
./migration/scripts/migrate.sh doctor
```

```
[ ok ] source deployed: pod legacy-postgres-0 (Running), 20 workload rows
```

### 6. Re-verify before trusting the source again

An unclean database shutdown is exactly the condition that produces a source
which *looks* healthy and is subtly not. Before resuming any migration activity,
re-run the comparison:

```bash
./migration/scripts/migrate.sh snapshot
./migration/scripts/migrate.sh verify
```

If the source has drifted from a target populated before the outage, the gate
reports it as a checksum mismatch rather than a row-count difference — the same
signal, from the same tooling, for a different cause.

### If the source is unrecoverable

Rebuilding the source estate is not the goal — completing the migration is. If a
workload's source cannot be recovered but its target is already populated and
verified, that workload's rollback option is gone. Record that explicitly rather
than leaving it implicit: it changes the risk profile of every remaining step,
and the cutover for that workload is now one-way.

---

## Post-migration support

### Hypercare - first two weeks

Migration engineers stay on the rota. Daily review of error rates, latency,
database CPU and connections, and cost against forecast.

Alarms land on the SNS topic from `terraform/modules/platform/monitoring.tf`:

| Alarm | Threshold | First action |
| --- | --- | --- |
| `rds-cpu-high` | > 80% for 15 m | Check Performance Insights for the top query |
| `rds-storage-low` | < 10 GiB free | Confirm autoscaling headroom; check for runaway growth |
| `rds-connections-high` | > 80 average | Check for pool leaks; `APP_DB_POOL_SIZE` × replicas vs `max_connections` |
| `nat-port-alloc-errors` | > 0 | NAT port exhaustion - check for connection storms |

### Common incidents

**Pods `CrashLoopBackOff` after deploy**

```bash
kubectl logs deployment/migration-tracker -n migration-tracker --previous --tail=100
kubectl describe pod -n migration-tracker -l app.kubernetes.io/name=migration-tracker
```

Usually the database secret or `DB_HOST` is wrong. Confirm the CSI mount and that
the IRSA annotation on the service account matches `terraform output app_role_arn`.

**`/readyz` returns 503**

The app is up but Postgres is unreachable. In order:

```bash
# 1. Does the pod's identity work at all?
kubectl exec -it deploy/migration-tracker -n migration-tracker -- \
  python -c "import boto3;print(boto3.client('sts').get_caller_identity()['Arn'])"

# 2. Is the security group path open? RDS ingress must reference the node SG.
aws ec2 describe-security-groups --group-ids <rds-sg> \
  --query 'SecurityGroups[0].IpPermissions'

# 3. Is the instance actually available?
aws rds describe-db-instances --db-instance-identifier <id> \
  --query 'DBInstances[0].DBInstanceStatus'
```

If the pod cannot reach the endpoint at all, check VPC flow logs before touching
the application - they answer "did the packet arrive" in seconds.

**High latency after cutover**

Do not resize yet. Check, in order: Performance Insights for missing indexes
(statistics are not always carried across by DMS - run `ANALYZE`), connection
pool saturation, and cross-AZ traffic. Right-size only after two weeks of data,
and change one thing at a time.

**Deployment stuck `Progressing`**

```bash
kubectl get events -n migration-tracker --sort-by=.lastTimestamp | tail -20
kubectl describe deployment migration-tracker -n migration-tracker
```

Usually unschedulable pods - node capacity, or a PodDisruptionBudget of
`minAvailable: 2` on a 2-replica deployment blocking eviction.

### Scheduled operations

| Task | Cadence | Notes |
| --- | --- | --- |
| EKS version upgrade | ~3×/year | Staging first, one minor at a time. Track N-1 |
| RDS minor version | Automatic, in the maintenance window | Pinned major; upgrade majors deliberately |
| Backup restore test | Monthly | An untested backup is a hypothesis |
| Rollback drill | Per wave | Rehearse before you need it |
| Cost review | Weekly during migration | Catch NAT and cross-AZ surprises early |
| Right-sizing | Per workload, 2 weeks post-cutover | Compute Optimizer plus real demand |

### Access

Break-glass only via a named IAM role with an EKS access entry, MFA, and
CloudTrail alerting on assumption. Day-to-day changes go through the pipeline. If
someone needs `kubectl edit` in production, that is an incident, and the change
is reconciled back into Git afterwards.
