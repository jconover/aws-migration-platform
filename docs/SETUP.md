# Setup

Bootstrapping this repository against a real AWS account and GitHub repository.

## 1. Terraform state backend (once per account)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=<globally-unique-name>"
terraform output backend_configuration
```

The bucket has `prevent_destroy` set and uses Terraform 1.10+ native S3 locking
(`use_lockfile`), so no DynamoDB table is needed.

## 2. Apply an environment

```bash
cd terraform/envs/staging
cp terraform.tfvars.example terraform.tfvars    # edit it
terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=<kms-arn>"
terraform plan -out=tfplan
terraform apply tfplan
```

Staging creates the account-level GitHub OIDC provider
(`create_github_oidc_provider = true`); production reuses it. If the two
environments live in **separate AWS accounts**, set it to `true` in
`terraform/envs/prod/main.tf` as well.

Apply staging before production - the provider must exist first.

## 3. GitHub configuration

Everything the pipeline needs comes from Terraform outputs. There are no AWS
access keys to create.

```bash
terraform output
```

### Environments

Create four GitHub environments: `staging`, `production`, `staging-plan`,
`prod-plan`, plus `staging-infra` and `prod-infra` for Terraform applies.

Put **required reviewers** on `production` and `prod-infra`. That approval is the
production gate; without it CD deploys to production unattended.

### Variables (per environment)

| Variable | From |
| --- | --- |
| `AWS_REGION` | your region |
| `AWS_DEPLOY_ROLE_ARN` | `terraform output github_deploy_role_arn` |
| `EKS_CLUSTER_NAME` | `terraform output cluster_name` |
| `ECR_REPOSITORY` | repository name portion of `ecr_repository_url` |
| `APP_ROLE_ARN` | `terraform output app_role_arn` |
| `DB_SECRET_ARN` | `terraform output database_secret_arn` |
| `DB_HOST` | `terraform output database_endpoint` |
| `ALERTS_TOPIC_ARN` | `terraform output alerts_topic_arn` |

For the Terraform workflow, additionally: `TF_STATE_BUCKET`,
`TF_STATE_KMS_KEY_ARN`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`.

For the ECS path: `ECS_CLUSTER_NAME`, `ECS_SERVICE_NAME`, `ECS_TASK_FAMILY`.

The plan and apply roles are deliberately separate. The plan role should carry
`ReadOnlyAccess` plus state-bucket write, so a pull request from a fork cannot
change infrastructure.

### Secrets

| Secret | Purpose |
| --- | --- |
| `SLACK_WEBHOOK_URL` | Failure and deployment notifications |

That is the complete list.

## 4. Branch protection

Protect `main`:

- Require the **`CI complete`** status check. Just that one - it aggregates every
  other job, so adding a job later never means editing branch protection.
- Require a pull request review.
- Dismiss stale approvals on new commits.

`CI complete` is what makes the coverage gate binding. Without it the gate runs
and reports, but nothing stops the merge.

## 5. Cluster prerequisites

Two controllers must be installed before the first deploy:

```bash
# AWS Load Balancer Controller - satisfies the Ingress
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=<cluster-name>

# Secrets Store CSI driver + AWS provider - satisfies the SecretProviderClass
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

Both need their own IRSA roles. The `terraform/modules/irsa` module creates them:
point it at the `kube-system` namespace and the relevant service account.

## 6. First deploy

Push to `main`. CD builds, pushes, deploys to staging, smoke tests from inside
the cluster, then waits for approval on production.

Verify:

```bash
aws eks update-kubeconfig --name <cluster> --region <region>
kubectl get pods -n migration-tracker
kubectl logs deployment/migration-tracker -n migration-tracker
```

## Troubleshooting

**`Error: creating IAM OIDC Provider: EntityAlreadyExists`** - the provider
exists. Set `create_github_oidc_provider = false`.

**`Not authorized to perform sts:AssumeRoleWithWebIdentity`** - the `sub` claim
does not match. The subject must be exactly
`repo:<owner>/<repo>:environment:<environment>`, and the job must declare that
environment. Confirm `permissions: id-token: write` is set on the job.

**`error: You must be logged in to the server (Unauthorized)`** - IAM worked but
Kubernetes RBAC did not. Check the EKS access entry exists for the deploy role:

```bash
aws eks list-access-entries --cluster-name <cluster>
```

**Pods stuck `ContainerCreating` with a CSI mount error** - the Secrets Store CSI
driver or its AWS provider is not installed, or the app's IRSA role cannot read
the secret. Check `kubectl describe pod` for the exact message.
