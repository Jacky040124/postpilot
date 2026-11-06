variable "name" {
  description = "Repository name"
  type        = string
}

variable "keep_images" {
  description = "How many images to keep; older ones are expired (rollback window)"
  type        = number
  default     = 20
}

variable "force_delete" {
  description = "Allow terraform destroy to delete the repo even if it has images"
  type        = bool
  default     = false
}
