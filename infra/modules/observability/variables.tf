variable "name" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "alarm_email" {
  description = "Email subscribed to the alarm topic. Empty = no subscription."
  type        = string
  default     = ""
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "api_service_name" {
  type = string
}

variable "worker_service_name" {
  type = string
}

variable "alb_5xx_rate_threshold_percent" {
  type    = number
  default = 5
}

variable "p95_latency_threshold_seconds" {
  type    = number
  default = 1
}

variable "cpu_threshold_percent" {
  type    = number
  default = 80
}

variable "publish_failure_threshold" {
  type    = number
  default = 5
}
