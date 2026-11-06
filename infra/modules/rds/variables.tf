variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect, keyed by a label (e.g. api, worker)"
  type        = map(string)
}

variable "engine_version" {
  type    = string
  default = "16"
}

variable "instance_class" {
  type = string
}

variable "allocated_storage" {
  description = "Initial storage in GiB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB"
  type        = number
  default     = 50
}

variable "db_name" {
  type    = string
  default = "postpilot"
}

variable "username" {
  type    = string
  default = "postpilot"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}
