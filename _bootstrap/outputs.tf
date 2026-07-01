output "infra_deploy_role_arn" {
  value = aws_iam_role.infra_deploy.arn
}

output "app_deploy_role_arn" {
  value = aws_iam_role.app_deploy.arn
}
