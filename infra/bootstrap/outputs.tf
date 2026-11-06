output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "plan_role_arn" {
  description = "Set as GitHub variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Set as GitHub variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}
