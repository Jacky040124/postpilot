variable "name" {
  description = "Prefix for resource names, e.g. postpilot-dev"
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Subnets are carved out as /24s."
  type        = string
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheaper) instead of one per AZ (more resilient)"
  type        = bool
  default     = true
}
