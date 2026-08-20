# Standing this up in a real AWS account

You drive; nothing here runs itself. Every command is yours to execute, in
order, with what to expect and what it costs while running.

Written against a real account in **us-east-1**. Replace `<account-id>` with
your own throughout — `aws sts get-caller-identity` prints it.

> **Running cost of full staging: about $0.51/hour, roughly $12/day.**
> Nothing is free after Step 4. The teardown in Step 11 is the important one,
> and it has a checklist because `terraform destroy` does not remove everything.

---

## Cost, before you start

| Line item | $/hr | Note |
| --- | --- | --- |
| VPC interface endpoints | 0.180 | 9 services × 2 AZs = 18 ENIs. **The largest item** |
| EKS control plane | 0.100 | fixed, independent of node count |
| RDS `db.t4g.medium` | 0.065 | single-AZ in staging |
| EKS nodes, 2 × `t3.large` spot | 0.050 | spot, so variable |
| NAT gateway | 0.045 | plus data processing |
| ALB for the rehost target | 0.023 | plus LCU |
| EC2 rehost, 1 × `t3.small` | 0.021 | |
| EBS, KMS, storage | 0.028 | 4 KMS keys at $1/month each |
| **Total** | **≈ 0.51** | **≈ $12/day** |

The interface endpoints costing more than the EKS control plane surprises most
people. To cut the bill for a short test, comment out the entries in
`local.interface_endpoints` in `terraform/modules/vpc/endpoints.tf` — the S3
gateway endpoint is free and stays either way. Everything still works; AWS API
traffic simply routes over the NAT gateway instead.

---

## Local tools

Install these before starting. Two of them are only needed at Step 9, but that
is 40 minutes in and a poor moment to discover they are missing.

| Tool | Needed for | macOS |
| --- | --- | --- |
| `terraform` ≥ 1.15 | everything | `brew install terraform` |
| `aws` CLI v2 | everything | `brew install awscli` |
| `session-manager-plugin` | the SSM tunnel to private RDS (Step 9) | `brew install --cask session-manager-plugin` |
| `psql` | restoring the dump into RDS (Step 9) | `brew install libpq && brew link --force libpq` |
| `kubectl` | verifying the cluster (Step 6) | `brew install kubectl` |
| `helm` | cluster prerequisites (Step 7) | `brew install helm` |
| `jq` | reading the database secret (Step 9) | `brew install jq` |

None of these install or manage virtual machines. `psql` is a database client
and `session-manager-plugin` is a transport for `aws ssm start-session`. The EC2
instances in this stack are created by Terraform, run Amazon Linux 2023, and are
the landing target for lift-and-shift workloads — in Step 9 one of them also
serves as the hop that reaches RDS, since RDS has no route to the internet.

Verify in one line:

```bash
for t in terraform aws session-manager-plugin psql kubectl helm jq; do
  command -v "$t" >/dev/null && echo "ok   $t" || echo "MISSING $t"
done
```

---

## Step 0 — Preflight

Run these four before anything else. The results below are from a real
account and show what each one is telling you:

```bash
aws sts get-caller-identity          # note the Account field
aws iam list-open-id-connect-providers
aws ec2 describe-vpcs --query 'length(Vpcs)'
aws ec2 describe-addresses --query 'length(Addresses)'
```

| Check | Result | Consequence |
| --- | --- | --- |
| Credentials | an IAM principal that can create VPC, EKS, RDS and IAM | required |
| GitHub OIDC provider | **already exists** | `create_github_oidc_provider` is already set to `false` in `envs/staging/main.tf`. Leave it |
| VPCs | 3 of 5 used | staging adds 1 → 4. Fits, but little headroom |
| Elastic IPs | 0 of 5 used | fine, NAT needs 1 |

If you run this in a different account, re-run those four commands first — the
OIDC one in particular decides whether apply succeeds.

---

## Step 1 — State backend (once per account)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=tf-state-<account-id>-migration"
```

Bucket names are globally unique; change the suffix if it is taken.

The `init_commands` output prints the exact `terraform init` line for each
environment with the bucket and KMS ARN already filled in — copy it and skip
ahead to Step 3. Nothing in it needs editing: the environment stacks already
declare their own backend blocks with the state key set.

**Cost:** pennies. **Time:** under a minute.

The bucket has `prevent_destroy` set, so it survives the teardown in Step 11 on
purpose. State is the one thing you do not want destroyed by a stray command.

---

## Step 2 — Environment variables

```bash
cd ../envs/staging
cp terraform.tfvars.example terraform.tfvars
```

Edit it:

```hcl
region               = "us-east-1"
artifact_bucket_name = "migration-tracker-staging-<account-id>"
github_repository    = "<owner>/<repo>"

# Optional: grants your IAM user cluster-admin on EKS. Without an entry here
# nobody can run kubectl against the cluster, including you.
cluster_admin_role_arns = ["arn:aws:iam::<account-id>:user/terraform"]
```

The `cluster_admin_role_arns` line matters. The cluster is created with
`bootstrap_cluster_creator_admin_permissions = false`, so the identity that
creates it gets **no** implicit access. That is deliberate, and it locks you out
if you skip this.

---

## Step 3 — Initialise against the backend

```bash
terraform init \
  -backend-config="bucket=tf-state-<account-id>-migration" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=<kms-arn-from-step-1>"
```

---

## Step 4 — Plan, and actually read it

```bash
terraform plan -out=tfplan | tee plan.txt
grep -E '^Plan:' plan.txt
```

Expect roughly 90–110 resources to add. Before applying, check three things:

```bash
# 1. Nothing is being destroyed - on a first apply this must be empty
grep -c 'will be destroyed' plan.txt

# 2. The data subnets have no default route (the property the design exists for)
grep -A5 'aws_route_table.data' plan.txt

# 3. No database password appears anywhere in the plan
grep -ci 'password' plan.txt
```

The third returns matches only for `manage_master_user_password = true` and the
secret ARN — never a value. If you ever see an actual password in a plan, stop.

**Cost so far:** still pennies. Planning creates nothing.

---

## Step 5 — Apply

```bash
terraform apply tfplan
```

**This is the button.** From here you are paying about $0.51/hour.

**Time: 15–20 minutes**, nearly all of it EKS. Expect this order:

| Elapsed | What is happening |
| --- | --- |
| 0–2 min | VPC, subnets, route tables, security groups |
| 2–4 min | NAT gateway, interface endpoints, KMS keys, S3, ECR |
| 4–13 min | **EKS control plane** — the long pole |
| 13–17 min | Node group joins, addons install |
| 8–17 min | RDS provisions in parallel |
| 17–20 min | EC2 launch template, ASG, ALB, IAM |

If it fails partway, `terraform apply` again — it is idempotent and picks up
where it stopped. Do **not** delete resources by hand in the console; that
strands state and makes the teardown in Step 11 much harder.

---

## Reading the environment later

Terraform already knows every endpoint, ARN and name, so there is no reason to
copy them somewhere they will go stale:

```bash
./scripts/env-info.sh                 # staging, plus the commands that use it
./scripts/env-info.sh staging export  # shell exports, for eval
./scripts/env-info.sh staging tunnel  # open the SSM port-forward to RDS
./scripts/env-info.sh staging dsn     # TARGET_DSN, including the password
```

`dsn` is separate from `show` on purpose: it reads the database password out of
Secrets Manager, and that should never appear just because someone wanted an
endpoint.

---

## Step 6 — Verify each layer

```bash
terraform output
```

### The network is shaped as designed

```bash
VPC=$(terraform output -raw vpc_id 2>/dev/null || \
      aws ec2 describe-vpcs --filters "Name=tag:Name,Values=migration-tracker-staging" \
        --query 'Vpcs[0].VpcId' --output text)

# The data-tier route table must have exactly one route: the local VPC CIDR.
# No 0.0.0.0/0 anywhere in it.
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=*-data" \
  --query 'RouteTables[0].Routes[].{dest:DestinationCidrBlock,gw:GatewayId}' --output table
```

That single check is the whole security argument for the data tier. If a
`0.0.0.0/0` entry appears there, something is wrong.

### RDS is genuinely unreachable

```bash
aws rds describe-db-instances \
  --query 'DBInstances[0].{public:PubliclyAccessible,az:MultiAZ,status:DBInstanceStatus}'

# From your laptop this must NOT connect - failure here is the correct result
nc -zv -w 5 "$(terraform output -raw database_endpoint)" 5432
```

### The cluster answers

```bash
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region us-east-1
kubectl get nodes
```

If this returns `Unauthorized`, you skipped `cluster_admin_role_arns` in Step 2.
Fix it there and re-apply rather than hand-editing access entries.

**If instead you get `no such host`, nothing is broken.** The API endpoint is
private, so its hostname resolves only through a Route 53 private hosted zone
inside the VPC. From a laptop, DNS simply has no answer. Confirm the cluster is
healthy without kubectl:

```bash
aws eks describe-cluster --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.{status:status,public:resourcesVpcConfig.endpointPublicAccess}'
```

`ACTIVE` with `public: false` is a correct, working cluster.

This is the same property as RDS being unreachable, and it is deliberate:
operators reach a production cluster over Direct Connect or VPN, never from the
internet. A demo account has no hybrid link, so for a short test you can open the
endpoint to your own address only — **demo only, never production**:

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
cat >> terraform.tfvars <<EOF
eks_endpoint_public_access       = true
eks_endpoint_public_access_cidrs = ["${MY_IP}/32"]
EOF
terraform apply    # ~2 minutes, endpoint configuration only
```

`terraform.tfvars` is gitignored, so the address never reaches the repository, and
a validation rule rejects `0.0.0.0/0`. Remove the lines when you are done.

The real answer in a migration is that this situation should not arise: hybrid
connectivity is on the critical path from week one precisely so operators never
need a public endpoint.

### The rehost instances came up

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform output -raw ec2_autoscaling_group_name)" \
  --query 'AutoScalingGroups[0].Instances[].{id:InstanceId,health:HealthStatus,state:LifecycleState}' \
  --output table
```

`InService` means the application answered its health check, because the ASG uses
ELB health checks rather than EC2 ones. If an instance never reaches it:

```bash
aws ssm start-session --target <instance-id>
sudo tail -100 /var/log/bootstrap.log
```

There is no SSH and no port 22. The bootstrap log is where every failure shows
up — usually the image pull or the Secrets Manager fetch.

---

## Step 7 — Cluster prerequisites

Nothing serves traffic until these exist. They get their AWS identity in two
different ways, and the difference matters.

**The load balancer controller needs its own IRSA role.** It calls Elastic Load
Balancing and EC2 on its own behalf, so the permissions sit on its own service
account in `kube-system`. Terraform builds that role from upstream's published
policy, vendored at a pinned version under
`terraform/modules/platform/policies/`. Annotate the service account with the
ARN, and set the name explicitly - the trust policy pins that exact name, and
the chart would otherwise generate one from the release name:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$(terraform output -raw cluster_name)" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform output -raw alb_controller_role_arn)"
```

**The Secrets Store CSI driver needs no role of its own.** Its AWS provider
does not read secrets as itself - it exchanges the service account token of the
pod that mounts them, so the grants belong on the *workload's* service account.
`app_role_arn` already carries exactly those: `GetSecretValue` and
`DescribeSecret` on the database secret, and `kms:Decrypt` conditioned on
`kms:ViaService` being Secrets Manager. `deploy/k8s/base/serviceaccount.yaml`
annotates it at deploy time. A role for the daemonset would look tidy and grant
nothing that is ever used.

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

Confirm the controller actually assumed its role rather than falling back to the
node role - a controller with no identity fails at the first ingress, not at
install:

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller | grep -i "assumed\|AccessDenied" | head
```

---

## Step 8 — Build and push the image

Run from the repository root, not from the Terraform directory — the build
context is the repo:

```bash
cd <repo-root>

REGISTRY=$(terraform -chdir=terraform/envs/staging output -raw ecr_repository_url)
REGISTRY_HOST=$(echo "$REGISTRY" | cut -d/ -f1)
TAG=$(git rev-parse --short HEAD)

echo "$REGISTRY"        # verify both are set before continuing
echo "$REGISTRY_HOST"

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$REGISTRY_HOST"

# The nodes are amd64; a Mac builds arm64 by default. This matters.
docker buildx build --platform linux/amd64 -t "$REGISTRY:$TAG" --push .
```

`cut` rather than `${REGISTRY%%/*}` so the line survives being pasted between
shells, and the two `echo` lines catch the common failure: if the `terraform
output` call ran from the wrong directory, `REGISTRY` is empty and every command
after it fails in a confusing way.

The `--platform linux/amd64` flag is not optional on Apple Silicon. Without it
pods crash-loop with `exec format error`, which reads like an application bug and
is not one.

---

## Step 9 — The migration, into real RDS

This is the part `terraform validate` can never prove.

RDS has no public route, so port-forward through a rehost instance over SSM — no
bastion, no SSH, no inbound rule, because the instances already carry the SSM
policy:

```bash
INSTANCE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform output -raw ec2_autoscaling_group_name)" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$(terraform output -raw database_endpoint),portNumber=5432,localPortNumber=55502"
```

Leave that running. In a second shell:

```bash
cd <repo-root>

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=terraform/envs/staging output -raw database_secret_arn)" \
  --query SecretString --output text)

export TARGET_DSN="postgresql://$(echo "$SECRET" | jq -r .username):$(echo "$SECRET" | jq -r .password)@localhost:55502/migration_tracker"

./migration/scripts/migrate.sh doctor
./migration/scripts/migrate.sh cutover
```

The password is never typed — RDS generated it and it has never been written
down. Expect:

```
OK   workloads: identical
MATCH - safe to proceed
```

Then prove the gate is real, against real RDS:

```bash
psql "$TARGET_DSN" -c "DELETE FROM workloads WHERE name='dr-replica';"
./migration/scripts/migrate.sh verify        # must exit 1
```

---

## Step 10 — Watch the cost while it runs

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -v-1d +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`0.01`].{svc:Keys[0],usd:Metrics.UnblendedCost.Amount}' \
  --output table
```

Cost Explorer lags by up to 24 hours, so this shows yesterday, not now. For a
short-lived stack, the hourly table at the top of this document is the better
estimate.

---

## Step 11 — Teardown

```bash
cd terraform/envs/staging
terraform destroy
```

**Time: 15–20 minutes**, again mostly EKS.

### Three things that block destroy

**ECR refuses to delete a repository containing images.** `force_delete` is
`false` by design, so a real registry cannot be wiped by a stray command. Empty
it first:

```bash
REPO=$(terraform output -raw ecr_repository_url | cut -d/ -f2-)
aws ecr list-images --repository-name "$REPO" --query 'imageIds[*]' --output json > /tmp/imgs.json
aws ecr batch-delete-image --repository-name "$REPO" --image-ids file:///tmp/imgs.json
```

**RDS takes a final snapshot.** `skip_final_snapshot = false`, so destroy creates
one and it survives — correct for production, an unwanted charge for a test.
Either accept it and delete it afterwards, or set `skip_final_snapshot = true` in
`terraform/modules/rds/main.tf` **before** destroying a throwaway stack.

**A half-deleted stack.** If destroy fails partway, run it again. Deleting
resources by hand in the console strands state and makes the rest much worse.

### After destroy, check what survived

`terraform destroy` reports success while leaving chargeable things behind:

```bash
# RDS final snapshot - storage charges, keeps accruing
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].{id:DBSnapshotIdentifier,gb:AllocatedStorage}' --output table

# Orphaned EBS volumes
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,gb:Size}' --output table

# Unattached Elastic IPs - charged when NOT in use
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' --output text

# NAT gateways still deleting, or stuck
aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text

# KMS keys: 2 of them, $1/month each until the deletion window expires
aws kms list-keys --query 'Keys[].KeyId' --output text | tr '\t' '\n' | while read -r k; do
  aws kms describe-key --key-id "$k" \
    --query 'KeyMetadata.{id:KeyId,state:KeyState,deletes:DeletionDate}' --output text
done

# CloudWatch log groups - small, but they persist forever
aws logs describe-log-groups --log-group-name-prefix /aws/ \
  --query 'logGroups[?contains(logGroupName,`migration-tracker`)].logGroupName' --output text
```

KMS keys enter a **pending deletion window of 30 days** and bill at $1/month each
until it expires. An environment creates two customer-managed keys - EKS envelope
encryption and RDS encryption at rest - so that is $2/month for a month after
teardown unless you shorten the window. The artifact bucket and ECR repository
use `AES256`, and SNS uses the AWS-managed `alias/aws/sns`, so none of those add
a key. The bootstrap state key is a third, and it survives on purpose. Pending
deletion is the most commonly missed leftover.

The state bucket from Step 1 survives on purpose. Remove it only when you are
finished with the account entirely, and note `prevent_destroy` must be removed
from the config first.

---

## If you only have an hour

Skip Steps 7–8 and the EKS verification. Apply, verify the network and RDS
(Step 6), run the migration through SSM (Step 9), then destroy. That exercises
everything `terraform validate` cannot reach — the private data tier, the SSM
path, credentials from Secrets Manager, and a real data migration with its
verification gate — for about $0.51.
