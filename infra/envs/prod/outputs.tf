output "api_url" {
  value = "http://${module.ecs.alb_dns_name}"
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "cluster_name" {
  value = module.ecs.cluster_name
}

output "api_service_name" {
  value = module.ecs.api_service_name
}

output "worker_service_name" {
  value = module.ecs.worker_service_name
}

output "webhook_url_parameter" {
  description = "Set the real webhook URL here with aws ssm put-parameter --overwrite"
  value       = module.secrets.webhook_url_parameter_name
}

output "alarm_topic_arn" {
  value = module.observability.alarm_topic_arn
}
