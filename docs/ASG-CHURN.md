# The ASG that kept replacing itself

The EC2 rehost target came up, went unhealthy, got terminated, and was replaced.
Then the replacement did the same thing. The Auto Scaling group was behaving
correctly throughout - it was doing exactly what it had been told to do, with an
image that could not possibly satisfy the condition it was being judged against.

This document records the mechanism, the root cause, and the fix, because the
interesting part is not the bug. It is that four independent things were wrong
at once and the configuration that would have fixed all four was being silently
discarded by Terraform.

## The symptom

Instances in the rehost ASG cycled: `InService`, then `Unhealthy`, then
terminated and replaced, indefinitely. Nothing ever served traffic through the
rehost ALB.

## Root cause: a variable that was never declared

`terraform/envs/staging/terraform.tfvars` set the image to a real ECR tag:

```hcl
ec2_container_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/migration-tracker-staging:88b312c"
```

The staging root module never declared a variable by that name, and never
passed one to `module "platform"`. Terraform does not fail on this. It emits a
warning and carries on:

```
Warning: Value for undeclared variable
The root module does not declare a variable named "ec2_container_image" but a
value was found in file "terraform.tfvars".
```

So `module.platform` fell through to its own default
(`terraform/modules/platform/variables.tf`):

```hcl
default = "public.ecr.aws/docker/library/nginx:alpine"
```

Every instance in the ASG ran stock nginx. The real application image was never
deployed to the rehost target at all, and the only signal was a warning in
several hundred lines of plan output.

## Why stock nginx could never pass

The launch template runs the container with hardening flags
(`terraform/modules/ec2-rehost/user_data.sh.tftpl`):

```
--publish 8000:8000 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges
```

and the instance then probes itself before reporting for duty:

```bash
curl -fsS "http://127.0.0.1:8000/healthz"
```

Four separate things make that impossible for `nginx:alpine`. Each was
reproduced locally against the exact flags above:

**1. The read-only root filesystem stops nginx from starting.** nginx writes
cache directories at boot; only `/tmp` is writable.

```
[emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
```
Container exits 1.

**2. `--cap-drop ALL` stops it too.** Even after mounting the cache dirs as
tmpfs, nginx cannot chown them to its worker user without `CAP_CHOWN`:

```
[emerg] chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)
```
Container exits 1.

**3. The port mapping does not match the image.** `--publish 8000:8000` maps
host 8000 to *container* 8000. nginx listens on 80:

```
tcp  0  0 0.0.0.0:80  0.0.0.0:*  LISTEN
```
A request to the published port gets a connection refused.

**4. There is no `/healthz`.** Even a healthy nginx serves the welcome page at
`/` and returns 404 for `/healthz`, and the target group requires `matcher =
"200"`.

Any one of these is fatal on its own. The hardening flags are correct and worth
keeping - they are why the application image is a good citizen. They are simply
incompatible with a general-purpose placeholder.

Because systemd carries `Restart=always` with `RestartSec=5`, the instance spent
its entire short life restarting a container that exited immediately.

## Why the ASG did the right thing

The ASG is deliberately configured to trust the load balancer rather than the
hypervisor (`terraform/modules/ec2-rehost/main.tf`):

```hcl
health_check_type         = "ELB"
health_check_grace_period = 300
```

with a comment that still reads correctly:

> ELB health checks, not EC2. An instance that boots but whose application never
> comes up is not healthy, and only the load balancer knows that.

That is the right call. `health_check_type = "EC2"` would have kept a fleet of
instances that booted fine and served nothing, which is worse: a green ASG in
front of a dead service. The strictness was not the bug. The strictness is what
surfaced the bug.

The cycle time follows from the configuration. The grace period ignores ELB
health for 300s after launch; the target group fails an instance after
`unhealthy_threshold` 3 at `interval` 15 - 45 seconds of failures. So each
instance survived about five minutes before being terminated and replaced.

## The fix

Declare the variable in the staging root and pass it through:

```hcl
variable "ec2_container_image" { ... }

module "platform" {
  # ...
  ec2_container_image = var.ec2_container_image
}
```

That is all it took. The `terraform.tfvars` value had been correct the whole
time; nothing was reading it. With the variable wired, `terraform console`
confirms it resolves:

```
$ echo 'var.ec2_container_image' | terraform console
"111122223333.dkr.ecr.us-east-1.amazonaws.com/migration-tracker-staging:88b312c"
```

and the plan no longer warns about an undeclared variable.

## The trap that remains

The default is still `nginx:alpine`, and it still cannot pass the health check.
That default exists for a real reason: the walkthrough applies the stack in Step
5 but does not build and push an image until Step 8, so on a first apply there
is genuinely no application image to point at. The ASG will churn during that
window.

The variable's description now says so plainly rather than leaving it to be
rediscovered. The honest options, none of which are free:

- **Accept the churn** between Step 5 and Step 8. It costs instance-hours and
  looks alarming in the console, but it resolves as soon as a real image exists.
- **Set `enable_ec2_rehost = false` for the first apply** and turn it on after
  Step 8. Cleanest, at the cost of a second apply.
- **Publish a placeholder that satisfies the contract** - something serving
  `/healthz` on 8000 that runs read-only with no capabilities. Correct, and it
  means maintaining an image whose only job is to be healthy.

## What to check when an ASG churns

```bash
# Why the ASG killed it - the reason is in the activity log, not the instance
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$(terraform output -raw ec2_autoscaling_group_name)" \
  --max-items 10 --query 'Activities[].{cause:Cause,status:StatusCode}' --output table

# What the load balancer actually thinks, and why
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].TargetHealth' --output table

# The instance's own view - user_data output lands here
aws ssm start-session --target "$INSTANCE_ID"
sudo journalctl -u cloud-final --no-pager | tail -40
sudo docker ps -a && sudo docker logs migration-tracker-staging-rehost
```

`describe-target-health` gives a `Reason` of `Target.ResponseCodeMismatch` when
the application answers but not with a 200, and `Target.Timeout` or
`Target.FailedHealthChecks` when nothing is listening at all. That distinction
is the fastest way to tell a wrong path from a dead process.

## What this cost, and what it is worth

The lesson is not "check your health check path". It is that Terraform will
accept a variable that does nothing and tell you about it in a warning you have
already scrolled past. A value in `terraform.tfvars` that no module reads is
indistinguishable, from the outside, from a value that is being honoured - until
something downstream behaves as though you never set it.

`terraform plan` output is not just a list of resources. The warnings above the
resource list are the part that tells you your inputs are not doing what you
think they are.
