variable "name" {
  description = "Prefix for resource names, e.g. postpilot-dev"
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets for the ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets for the tasks"
  type        = list(string)
}

variable "repository_url" {
  type = string
}

variable "repository_arn" {
  type = string
}

variable "image_tag" {
  description = "Image tag for the first task definition revision. After that, CI deploys new tags."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. Empty = HTTP only (no custom domain)."
  type        = string
  default     = ""
}

variable "alb_deletion_protection" {
  type    = bool
  default = false
}

variable "container_insights" {
  type    = bool
  default = true
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "api_port" {
  type    = number
  default = 8000
}

variable "api_cpu" {
  description = "Fargate CPU units (256 = 0.25 vCPU)"
  type        = number
}

variable "api_memory" {
  description = "Fargate memory in MiB"
  type        = number
}

variable "api_min_count" {
  type = number
}

variable "api_max_count" {
  type = number
}

variable "worker_cpu" {
  type = number
}

variable "worker_memory" {
  type = number
}

variable "worker_count" {
  type = number
}

variable "worker_poll_interval_seconds" {
  type    = number
  default = 5
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master user secret"
  type        = string
}

variable "webhook_url_parameter_arn" {
  type = string
}

variable "api_log_group_name" {
  type = string
}

variable "worker_log_group_name" {
  type = string
}
