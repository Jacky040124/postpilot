# Fargate cluster running two services from the same image:
#   api    - behind a public ALB, scales on CPU
#   worker - no load balancer, polls the DB and calls the webhook
#
# CI owns the image version: it registers new task definition revisions and
# updates the services (see .github/workflows/deploy.yml). Terraform owns
# everything else, so the services ignore changes to task_definition.

locals {
  image = "${var.repository_url}:${var.image_tag}"

  db_environment = [
    { name = "DB_HOST", value = var.db_host },
    { name = "DB_PORT", value = tostring(var.db_port) },
    { name = "DB_NAME", value = var.db_name },
    { name = "DB_USER", value = var.db_username },
    { name = "DB_SSLMODE", value = "require" },
    { name = "LOG_LEVEL", value = var.log_level },
  ]

  # The RDS-managed secret is JSON; ":password::" picks one key out of it.
  db_password_secret = { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" }

  # Which secrets each service's execution role may read.
  service_secret_arns = {
    api    = [var.db_secret_arn]
    worker = [var.db_secret_arn, var.webhook_url_parameter_arn]
  }

  log_group_arns = {
    api    = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.api_log_group_name}"
    worker = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.worker_log_group_name}"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }
}

# ---------------------------------------------------------------- security groups

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public HTTP(S) into the ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = var.certificate_arn == "" ? 0 : 1
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port
}

resource "aws_security_group" "api" {
  name        = "${var.name}-api"
  description = "API tasks: inbound only from the ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port
}

resource "aws_security_group" "worker" {
  name        = "${var.name}-worker"
  description = "Worker tasks: no inbound traffic"
  vpc_id      = var.vpc_id
}

# Tasks need outbound HTTPS (ECR, CloudWatch, Secrets Manager, the webhook) and Postgres.
resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  for_each          = { api = aws_security_group.api.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound from ${each.key} tasks"
}

# ---------------------------------------------------------------- load balancer

resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.name}-api"
  port                 = var.api_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # With a certificate, HTTP only redirects to HTTPS. Without one (a demo
  # environment with no domain), HTTP forwards straight to the API.
  default_action {
    type             = var.certificate_arn == "" ? "forward" : "redirect"
    target_group_arn = var.certificate_arn == "" ? aws_lb_target_group.api.arn : null

    dynamic "redirect" {
      for_each = var.certificate_arn == "" ? [] : [1]
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ---------------------------------------------------------------- IAM

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution role = what the ECS agent needs to START the task: pull the image,
# write logs, inject secrets. One per service so the api cannot read the webhook URL.
resource "aws_iam_role" "execution" {
  for_each           = local.service_secret_arns
  name               = "${var.name}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  for_each = local.service_secret_arns

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this API does not support resource-level permissions
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [var.repository_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arns[each.key]}:*"]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
    resources = each.value
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.service_secret_arns
  name     = "execution"
  role     = aws_iam_role.execution[each.key].id
  policy   = data.aws_iam_policy_document.execution[each.key].json
}

# Task role = what the application code itself may call in AWS. PostPilot makes
# no AWS API calls, so these roles have no policies. They exist so that any future
# permission is added per service, not to a shared role.
resource "aws_iam_role" "task" {
  for_each           = toset(["api", "worker"])
  name               = "${var.name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------------------------------------------------------------- task definitions

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.execution["api"].arn
  task_role_arn            = aws_iam_role.task["api"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "api"
    image                  = local.image
    essential              = true
    command                = ["python", "-m", "postpilot", "api", "--port", tostring(var.api_port)]
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = var.api_port, protocol = "tcp" }]
    environment            = local.db_environment
    secrets                = [local.db_password_secret]
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.api_port}/healthz', timeout=2)"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.api_log_group_name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution["worker"].arn
  task_role_arn            = aws_iam_role.task["worker"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "worker"
    image                  = local.image
    essential              = true
    command                = ["python", "-m", "postpilot", "worker"]
    readonlyRootFilesystem = true
    environment = concat(local.db_environment, [
      { name = "POLL_INTERVAL_SECONDS", value = tostring(var.worker_poll_interval_seconds) },
    ])
    secrets = [
      local.db_password_secret,
      { name = "WEBHOOK_URL", valueFrom = var.webhook_url_parameter_arn },
    ]
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.worker_log_group_name
        awslogs-region        = var.region
        awslogs-stream-prefix = "worker"
      }
    }
  }])
}

# ---------------------------------------------------------------- services

resource "aws_ecs_service" "api" {
  name            = "${var.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_min_count
  launch_type     = "FARGATE"

  # Rolling deploy: start new tasks before stopping old ones (never below 100%).
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  # If new tasks keep failing health checks, ECS stops the deploy and
  # automatically returns to the last working task definition.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.api_port
  }

  propagate_tags = "SERVICE"

  lifecycle {
    # CI rolls out new images; autoscaling owns desired_count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "worker" {
  name            = "${var.name}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_count
  launch_type     = "FARGATE"

  # Old and new workers overlap during a deploy. That is safe because rows are
  # claimed with SELECT ... FOR UPDATE SKIP LOCKED.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  propagate_tags = "SERVICE"

  lifecycle {
    ignore_changes = [task_definition]
  }
}

# ---------------------------------------------------------------- autoscaling

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_count
  max_capacity       = var.api_max_count
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${var.name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
