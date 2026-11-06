# Prod: two of everything that can fail (NAT per AZ, Multi-AZ RDS, 2+ API tasks,
# 2 workers), longer log/backup retention, and deletion protection.

locals {
  name = "postpilot-prod"

  size = {
    api_cpu       = 512 # 0.5 vCPU
    api_memory    = 1024
    api_min_count = 2
    api_max_count = 6
    worker_cpu    = 256
    worker_memory = 512
    worker_count  = 2
    db_class      = "db.t4g.small"
  }
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  cidr_block         = "10.20.0.0/16"
  single_nat_gateway = false
}

module "ecr" {
  source       = "../../modules/ecr"
  name         = local.name
  keep_images  = 50
  force_delete = false
}

module "secrets" {
  source = "../../modules/secrets"
  name   = local.name
}

module "rds" {
  source                = "../../modules/rds"
  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.private_subnet_ids
  instance_class        = local.size.db_class
  allocated_storage     = 20
  max_allocated_storage = 100
  multi_az              = true
  backup_retention_days = 7
  deletion_protection   = true
  skip_final_snapshot   = false

  allowed_security_group_ids = {
    api    = module.ecs.api_security_group_id
    worker = module.ecs.worker_security_group_id
  }
}

module "observability" {
  source             = "../../modules/observability"
  name               = local.name
  log_retention_days = 30
  alarm_email        = var.alarm_email

  alb_arn_suffix          = module.ecs.alb_arn_suffix
  target_group_arn_suffix = module.ecs.target_group_arn_suffix
  cluster_name            = module.ecs.cluster_name
  api_service_name        = module.ecs.api_service_name
  worker_service_name     = module.ecs.worker_service_name

  # Tighter than dev: prod pages earlier.
  alb_5xx_rate_threshold_percent = 2
  p95_latency_threshold_seconds  = 0.5
  publish_failure_threshold      = 3
}

module "ecs" {
  source                  = "../../modules/ecs"
  name                    = local.name
  region                  = var.region
  vpc_id                  = module.network.vpc_id
  public_subnet_ids       = module.network.public_subnet_ids
  private_subnet_ids      = module.network.private_subnet_ids
  certificate_arn         = var.certificate_arn
  alb_deletion_protection = true
  container_insights      = true

  repository_url = module.ecr.repository_url
  repository_arn = module.ecr.repository_arn
  image_tag      = var.image_tag

  api_cpu       = local.size.api_cpu
  api_memory    = local.size.api_memory
  api_min_count = local.size.api_min_count
  api_max_count = local.size.api_max_count
  worker_cpu    = local.size.worker_cpu
  worker_memory = local.size.worker_memory
  worker_count  = local.size.worker_count

  db_host                   = module.rds.address
  db_port                   = module.rds.port
  db_name                   = module.rds.db_name
  db_username               = module.rds.username
  db_secret_arn             = module.rds.master_user_secret_arn
  webhook_url_parameter_arn = module.secrets.webhook_url_parameter_arn

  api_log_group_name    = module.observability.api_log_group_name
  worker_log_group_name = module.observability.worker_log_group_name
}
