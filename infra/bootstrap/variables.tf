variable "region" {
  type    = string
  default = "us-west-2"
}

variable "github_repository" {
  description = "owner/name of the GitHub repo allowed to assume the roles"
  type        = string
  default     = "Jacky040124/postpilot"
}
