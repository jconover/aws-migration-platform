# Architecture and design decisions

## System shape

```
                      GitHub Actions
                            │  OIDC, no static keys
                            ▼
                   ┌──────────────────┐
                   │  ECR (immutable) │
                   └────────┬─────────┘
                            │ deployed by digest
   ┌────────────────────────┼────────────────────────┐
   │  VPC 10.10.0.0/16      │                        │
   │                        ▼                        │
   │  public  /20 ×3   ┌─────────┐                   │
   │  ─────────────────│   ALB   │ internal          │
   │                   └────┬────┘                   │
   │                        │                        │
   │  private /20 ×3   ┌────▼─────────────────┐      │
   │  ─────────────────│ EKS nodes / Fargate  │      │
   │                   │ IRSA or task role    │      │
   │                   └────┬─────────────────┘      │
   │                        │ SG reference, port 5432│
   │  data    /24 ×3   ┌────▼─────────────────┐      │
   │  ─────────────────│ RDS Postgres Multi-AZ│      │
   │   no default route└──────────────────────┘      │
   └─────────────────────────────────────────────────┘
        S3 (gateway endpoint)   Secrets Manager (interface endpoint)
```

## Decisions

### The data tier has no route to the internet

The `data` subnets have a route table with no default route
(`terraform/modules/vpc/main.tf`). Not a NAT-less private subnet - no egress path
at all. A compromised database cannot exfiltrate outbound because there is
nowhere for packets to go.

### Reachability is granted by security group reference, never CIDR

RDS ingress references the EKS node security group and the ECS task security
group, not `10.0.0.0/8`:

```hcl
resource "aws_vpc_security_group_ingress_rule" "from_compute" {
  referenced_security_group_id = each.value   # the compute SG
  from_port                    = 5432
}
```

CIDR-based rules grant access to whatever happens to occupy those addresses
later. Identity-based rules stay correct as the network changes - which it will,
repeatedly, during a migration.

### No AWS credentials exist

`terraform/modules/github-oidc` establishes OIDC trust between GitHub Actions and
IAM. Workflows present a short-lived token; STS exchanges it for credentials
scoped to the job. There are no access keys in the repository, in GitHub secrets,
or in a password manager.

The trust policy pins the exact `sub` claim, and the module rejects wildcards:

```hcl
validation {
  condition     = alltrue([for s in var.github_subjects : !endswith(s, ":*")])
  error_message = "Wildcard subjects ending in ':*' are not permitted."
}
```

`repo:org/repo:*` would let a pull request from a fork assume the deployment
role. Pinning to `repo:org/repo:environment:production` means only a job running
in that protected environment can.

### Three separate identities, by function

| Identity | Assumed by | Can |
| --- | --- | --- |
| Deploy role (`github-oidc`) | GitHub Actions | Push images, roll out Deployments in one namespace |
| Application role (`irsa` + `iam-app`) | Pods, via service account | Read one secret, use one bucket prefix |
| Node / execution role | Kubelet, ECS agent | Pull images, write logs |

The deploy role cannot read application data. The application role cannot deploy.
Kubernetes access is granted through an EKS access entry scoped to the
application namespace with `AmazonEKSEditPolicy` - not cluster-admin.

### Application permissions name concrete ARNs

`terraform/modules/iam-app` has no resource wildcards:

```hcl
statement {
  actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", ...]
  resources = ["${var.artifact_bucket_arn}/${local.prefix}/*"]
}
statement {
  actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
  resources = [var.database_secret_arn]      # one secret, not a prefix
}
```

KMS decrypt is additionally constrained by `kms:ViaService`, so the key can only
be used *through* S3 and Secrets Manager - not called directly.

`terraform output app_policy_json` renders the policy for review in a pull
request, so permission changes are visible in the diff rather than discovered in
CloudTrail.

### The database password is never in Terraform state

`manage_master_user_password = true` has RDS generate the credential and store it
in Secrets Manager. Terraform never sees the value.

It reaches the workload at runtime:

- **EKS** - Secrets Store CSI driver mounts it and syncs a Kubernetes Secret
  (`deploy/k8s/base/secretproviderclass.yaml`)
- **ECS** - the agent injects it via the task definition's `secrets` block

Either way the value is absent from Git, the image, the task JSON, and state.

### Images are deployed by digest

CD resolves `registry/repo@sha256:...` and deploys that. ECR repositories are
`IMMUTABLE`. A tag can be repointed; a digest cannot - so what staging validated
is bit-for-bit what production runs, and the rollback in
[RUNBOOK.md](RUNBOOK.md) is trustworthy.

### Memory limits, no CPU limits

Containers request CPU and memory and limit only memory. A CPU limit enforces CFS
quota, which throttles a latency-sensitive service that briefly needs more than
its share even when the node is idle. Memory has no equivalent graceful
degradation - a leak without a limit takes the node down - so memory is capped.

### Kubernetes runs as a locked-down workload

Namespace enforces Pod Security Standards `restricted`. Pods run as UID 10001,
non-root, read-only root filesystem, all capabilities dropped, `RuntimeDefault`
seccomp. Verified in CI:

```yaml
- name: Verify the image runs as a non-root user
  run: |
    uid=$(docker run --rm --entrypoint id migration-tracker:ci -u)
    test "${uid}" != "0"
```

Default-deny NetworkPolicy, then explicit allows for DNS, Postgres, and HTTPS -
with the instance metadata endpoint (`169.254.169.254/32`) excluded so a
compromised pod cannot reach node credentials.

---

## EKS or ECS Fargate

Both are implemented. `enable_ecs = true` provisions the Fargate path alongside
EKS, sharing the same image, database, secret, and least-privilege policy.

| | EKS | ECS Fargate |
| --- | --- | --- |
| Operational burden | Node groups, addons, version upgrades ~3×/year | None - no nodes to patch |
| Cost at steady load | Better; nodes bin-pack, Spot is straightforward | Higher per vCPU-hour |
| Cost when idle/spiky | Worse; nodes run regardless | Better; pay per task-second |
| Ecosystem | Full Kubernetes: operators, service mesh, Helm | AWS-native only |
| Team requirement | Real Kubernetes skills on the rota | Standard AWS skills |
| Migration fit | Rehosted apps needing sidecars, DaemonSets, complex networking | Stateless HTTP services that already containerise cleanly |

**How to choose, in practice:**

- **Fargate** when the workload is a stateless service, the team has no
  Kubernetes operator on the rota, and the estate is small enough that a control
  plane per environment is not worth the overhead. Fewer things to break at 3 am.
- **EKS** when there are enough workloads to bin-pack, when portability across
  clouds or back on-premises is a stated requirement, or when the migrated
  applications need primitives ECS does not have.

For this programme: **EKS for the platform** - the estate is large enough that
node bin-packing and Spot capacity pay for the operational cost, and several
rehosted applications need sidecars. **Fargate for the long tail** - low-traffic
services where a scheduled task or a request every few minutes should not hold a
node open.

Because both are Terraform modules taking the same inputs, moving a workload
between them is a variable change, not a rewrite.

---

## Testing strategy

| Suite | Dependencies | Covers | Runs |
| --- | --- | --- | --- |
| `tests/unit` | none | State machine, schema validation, service layer with repository stubbed | Every commit; no service container |
| `tests/integration` | Postgres 17 | Repository against real SQL, enum round-trips, constraints, full HTTP surface | Every commit, in a job with the service container |

Integration tests use real Postgres rather than SQLite. Enum handling, unique
constraint behaviour, and `TRUNCATE ... RESTART IDENTITY` all differ between the
two, and a suite that passes on SQLite while production runs Postgres tests the
wrong thing. This is not theoretical: the `Query`-instead-of-`Path` bug in
`app/api.py` was caught by the integration suite during development because the
tests exercise the real ASGI application.

Coverage is enforced on the combined result. The reasoning is in
[CICD-OPTIMIZATION.md](CICD-OPTIMIZATION.md#the-coverage-gate).

---

## Deliberate gaps

Honest about what is not here:

- **Schema migrations use `create_all`.** `scripts/init_db.py` is idempotent but
  cannot express column drops or backfills. Adopt Alembic before the first
  destructive schema change.
- **TLS terminates at the ALB with no certificate configured.** The listener is
  HTTP pending an ACM certificate and a real hostname; the annotations for
  HTTPS and the TLS 1.3 policy are already on the Ingress.
- **The ECS module's ALB ingress uses a `10.0.0.0/8` CIDR rule.** It should
  reference a corporate prefix list once the network team publishes one.
- **No `terraform plan` against a live account.** Every stack passes
  `validate` and `fmt`; validation cannot catch quota limits, IAM boundaries, or
  region-specific behaviour. First `apply` should be into a sandbox account.
- **Prod reuses the staging account's GitHub OIDC provider**
  (`create_github_oidc_provider = false`). Correct for a shared account; if the
  environments are split across accounts, set it to `true` in prod.
