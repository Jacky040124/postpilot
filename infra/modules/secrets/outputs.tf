output "webhook_url_parameter_arn" {
  value = aws_ssm_parameter.webhook_url.arn
}

output "webhook_url_parameter_name" {
  value = aws_ssm_parameter.webhook_url.name
}
