# ENGINE-RENDERED by devops-agent from catalog data — do not edit; regenerate instead.
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "deploy_role_arn_dev" {
  value = aws_iam_role.deploy_dev.arn
}

output "infra_apply_role_arn_dev" {
  value = aws_iam_role.infra_apply_dev.arn
}

output "infra_plan_role_arn" {
  value = aws_iam_role.infra_plan.arn
}

output "state_bucket" {
  value = "tfstate-407493720885-ap-south-1"
}

output "aws_region" {
  value = "ap-south-1"
}
