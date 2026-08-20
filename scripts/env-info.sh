#!/usr/bin/env bash
# Show the live details of a deployed environment, and the commands that use them.
#
# Terraform already knows every one of these values, so there is no reason to
# copy them into a notes file where they go stale the moment you re-apply.
#
#   ./scripts/env-info.sh                 staging, human readable
#   ./scripts/env-info.sh prod            another environment
#   ./scripts/env-info.sh staging export  shell exports, for eval
#   ./scripts/env-info.sh staging tunnel  open the SSM port-forward to RDS
#   ./scripts/env-info.sh staging dsn     print TARGET_DSN (contains the password)
set -euo pipefail

ENV_NAME="${1:-staging}"
MODE="${2:-show}"
LOCAL_PORT="${LOCAL_PORT:-55502}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${REPO_ROOT}/terraform/envs/${ENV_NAME}"
readonly ENV_NAME MODE LOCAL_PORT REPO_ROOT STACK

die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "${STACK}" ] || die "no such environment: ${ENV_NAME} (expected ${STACK})"
command -v terraform >/dev/null || die "terraform is required"

# One terraform call; everything else reads from this.
OUT="$(terraform -chdir="${STACK}" output -json 2>/dev/null)" \
  || die "could not read outputs. Has ${ENV_NAME} been applied, and is the backend initialised?"

[ "${OUT}" != "{}" ] || die "${ENV_NAME} has no outputs - it does not look applied"

get() {
  printf '%s' "${OUT}" | python3 -c "
import json,sys
v = json.load(sys.stdin).get(sys.argv[1], {}).get('value')
print('' if v is None else v)" "$1"
}

REGION="$(get region)"
CLUSTER="$(get cluster_name)"
ASG="$(get ec2_autoscaling_group_name)"
DB_HOST="$(get database_endpoint)"
DB_SECRET="$(get database_secret_arn)"
ECR="$(get ecr_repository_url)"

case "${MODE}" in
  show)
    printf '\n\033[1m%s\033[0m  (region %s)\n\n' "${ENV_NAME}" "${REGION:-unknown}"
    # shellcheck disable=SC2016  # f-string braces belong to python, not bash
    printf '%s' "${OUT}" | python3 -c "
import json,sys
data = json.load(sys.stdin)
width = max(len(k) for k in data)
for key in sorted(data):
    value = data[key].get('value')
    print(f'  {key:<{width}}  {\"\" if value is None else value}')"

    printf '\n\033[1mReady to use\033[0m\n\n'
    [ -n "${CLUSTER}" ] && printf '  kubeconfig   aws eks update-kubeconfig --name %s --region %s\n' "${CLUSTER}" "${REGION}"
    [ -n "${ECR}" ]     && printf '  registry     aws ecr get-login-password --region %s | docker login --username AWS --password-stdin %s\n' "${REGION}" "${ECR%%/*}"
    [ -n "${ASG}" ]     && printf '  tunnel       %s %s tunnel\n' "$0" "${ENV_NAME}"
    # shellcheck disable=SC2016  # prints a literal $(...) for the reader to run
    [ -n "${DB_SECRET}" ] && printf '  migrate      export TARGET_DSN="$(%s %s dsn)"\n' "$0" "${ENV_NAME}"
    printf '\n'
    ;;

  export)
    # eval "$(./scripts/env-info.sh staging export)"
    printf 'export AWS_REGION=%q\n'        "${REGION}"
    printf 'export EKS_CLUSTER_NAME=%q\n'  "${CLUSTER}"
    printf 'export ECR_REPOSITORY_URL=%q\n' "${ECR}"
    printf 'export DB_HOST=%q\n'           "${DB_HOST}"
    printf 'export DB_SECRET_ARN=%q\n'     "${DB_SECRET}"
    printf 'export ASG_NAME=%q\n'          "${ASG}"
    ;;

  tunnel)
    command -v session-manager-plugin >/dev/null \
      || die "session-manager-plugin not installed (brew install --cask session-manager-plugin)"
    [ -n "${ASG}" ] || die "no rehost ASG in ${ENV_NAME}; enable_ec2_rehost is off"

    # shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
    instance="$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${ASG}" --region "${REGION}" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' \
      --output text 2>/dev/null)"
    [ -n "${instance}" ] && [ "${instance}" != "None" ] \
      || die "no InService instance in ${ASG}"

    printf '\ntunnelling %s:5432 -> localhost:%s via %s\n' "${DB_HOST}" "${LOCAL_PORT}" "${instance}" >&2
    printf 'leave this running; use another shell for the migration\n\n' >&2
    exec aws ssm start-session --target "${instance}" --region "${REGION}" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "host=${DB_HOST},portNumber=5432,localPortNumber=${LOCAL_PORT}"
    ;;

  dsn)
    # Prints a password, so it is opt-in and never part of `show`.
    command -v jq >/dev/null || die "jq is required"
    [ -n "${DB_SECRET}" ] || die "no database secret in ${ENV_NAME}"

    secret="$(aws secretsmanager get-secret-value --secret-id "${DB_SECRET}" \
      --region "${REGION}" --query SecretString --output text 2>/dev/null)" \
      || die "could not read ${DB_SECRET}"

    user="$(printf '%s' "${secret}" | jq -r .username)"
    pass="$(printf '%s' "${secret}" | jq -r .password)"

    # localhost, because RDS has no public route: this assumes the tunnel above.
    printf 'postgresql://%s:%s@localhost:%s/migration_tracker\n' "${user}" "${pass}" "${LOCAL_PORT}"
    ;;

  *)
    die "unknown mode: ${MODE} (show, export, tunnel, dsn)"
    ;;
esac
