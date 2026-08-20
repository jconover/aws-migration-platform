# ---------------------------------------------------------------------------
# Cluster prerequisites.
#
# Two controllers have to exist before the cluster serves traffic or reads a
# secret, and they get their AWS identity in two different ways:
#
#   AWS Load Balancer Controller - runs in kube-system and calls Elastic Load
#   Balancing and EC2 on its own behalf, so it needs its own IRSA role. That
#   is the role built here.
#
#   Secrets Store CSI driver, AWS provider - does NOT need a role of its own.
#   The provider exchanges the token of the pod that mounts the secret, so the
#   permissions have to sit on the workload's service account, not on the
#   daemonset's. module.app_irsa below already carries exactly those grants:
#   GetSecretValue and DescribeSecret on the database secret, and kms:Decrypt
#   through Secrets Manager. Adding a second role for the daemonset would look
#   tidy and grant nothing that is ever used.
# ---------------------------------------------------------------------------

locals {
  # Upstream's published policy, vendored at a pinned version so an upgrade is
  # a visible diff rather than a silent fetch. jsondecode validates it at plan
  # time; jsonencode normalises the whitespace IAM would ignore anyway.
  alb_controller_policy = jsonencode(jsondecode(
    file("${path.module}/policies/aws-load-balancer-controller-v${var.alb_controller_version}.json")
  ))
}

module "alb_controller_irsa" {
  source = "../irsa"

  # IAM name_prefix caps at 38 characters and the generated suffix eats into
  # that, so this is "-alb" rather than "-alb-controller".
  name              = "${local.name}-alb"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "kube-system"
  service_account   = var.alb_controller_service_account

  # Inline rather than a customer-managed policy: nothing else attaches it, and
  # inline means the grant cannot outlive the role it was created for.
  inline_policies = { controller = local.alb_controller_policy }

  tags = local.tags
}
