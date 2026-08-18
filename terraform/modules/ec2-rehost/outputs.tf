output "autoscaling_group_name" {
  description = "ASG name, for instance refresh and deployment automation."
  value       = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  description = "Launch template id."
  value       = aws_launch_template.this.id
}

output "launch_template_latest_version" {
  description = "Latest launch template version."
  value       = aws_launch_template.this.latest_version
}

output "load_balancer_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = aws_lb_target_group.this.arn
}

output "instances_security_group_id" {
  description = "Security group on the instances. Allow this on RDS."
  value       = aws_security_group.instances.id
}

output "instance_role_arn" {
  description = "IAM role the instances assume."
  value       = aws_iam_role.instance.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving instance logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "session_manager_command" {
  description = "How to get a shell without SSH."
  value       = "aws ssm start-session --target <instance-id>  # instances: aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.this.name}"
}
