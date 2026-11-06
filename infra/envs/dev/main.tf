# Dev: smallest sizes, one NAT gateway, single-AZ database, easy to destroy.

locals {
  name = "postpilot-dev"

  size = {
    api_cpu       = 256 # 0.25 vCPU
    api_memory    = 512
    api_min_count = 1
    api_max_count = 2
    worker_cpu    = 256
    worker_memory = 512
    worker_count  = 1
    db_class      = "db.t4g.micro"
  }
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  cidr_block         = "10.10.0.0/16"
  single_nat_gateway = true
}

module "ecr" {
  source       = "../../modules/ecr"
  name         = local.name
  force_delete = true
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
  multi_az              = false
  backup_retention_days = 1
  deletion_protection   = false
  skip_final_snapshot   = true

  allowed_security_group_ids = {
    api    = module.ecs.api_security_group_id
    worker = module.ecs.worker_security_group_id
  }
}

module "observability" {
  source             = "../../modules/observability"
  name               = local.name
  log_retention_days = 7
  alarm_email        = var.alarm_email

  alb_arn_suffix          = module.ecs.alb_arn_suffix
  target_group_arn_suffix = module.ecs.target_group_arn_suffix
  cluster_name            = module.ecs.cluster_name
  api_service_name        = module.ecs.api_service_name
  worker_service_name     = module.ecs.worker_service_name
}

module "ecs" {
  source             = "../../modules/ecs"
  name               = local.name
  region             = var.region
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  certificate_arn    = var.certificate_arn
  container_insights = false # saves money in dev

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
  log_level     = "DEBUG"

  db_host                   = module.rds.address
  db_port                   = module.rds.port
  db_name                   = module.rds.db_name
  db_username               = module.rds.username
  db_secret_arn             = module.rds.master_user_secret_arn
  webhook_url_parameter_arn = module.secrets.webhook_url_parameter_arn

  api_log_group_name    = module.observability.api_log_group_name
  worker_log_group_name = module.observability.worker_log_group_name
}
