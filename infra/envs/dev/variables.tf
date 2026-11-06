variable "region" {
  type    = string
  default = "us-west-2"
}

variable "image_tag" {
  description = "Image tag for the first deploy. Later deploys come from CI (deploy.yml)."
  type        = string
  default     = "bootstrap"
}

variable "alarm_email" {
  description = "Where alarm notifications go. Empty = SNS topic with no subscribers."
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM certificate ARN to enable HTTPS on the ALB"
  type        = string
  default     = ""
}
