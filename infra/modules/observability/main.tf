# Logs, alarms and the SNS topic alarms notify. docs/runbook.md explains what
# to do when each alarm fires.

locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
  metric_ns     = "PostPilot/${var.name}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/api"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}/worker"
  retention_in_days = var.log_retention_days
}

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------- ALB alarms

# 5xx as a percentage of requests, so a busy minute with a few errors does not
# page but a quiet minute where everything fails does. Counts both errors the
# app returned (Target_5XX) and errors the ALB returned itself (ELB_5XX, e.g. no
# healthy targets).
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${var.name}-alb-5xx-rate"
  alarm_description   = "More than ${var.alb_5xx_rate_threshold_percent}% of requests returned 5xx. See docs/runbook.md#alb-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alb_5xx_rate_threshold_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "rate"
    expression  = "100 * (FILL(target5xx, 0) + FILL(elb5xx, 0)) / requests"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "target5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "elb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  alarm_name          = "${var.name}-alb-p95-latency"
  alarm_description   = "p95 target response time above ${var.p95_latency_threshold_seconds}s. See docs/runbook.md#alb-p95-latency"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.p95_latency_threshold_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.name}-unhealthy-targets"
  alarm_description   = "ALB sees unhealthy API tasks. See docs/runbook.md#unhealthy-targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------------------------------------------------------- ECS alarms

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  for_each = { api = var.api_service_name, worker = var.worker_service_name }

  alarm_name          = "${var.name}-${each.key}-cpu-high"
  alarm_description   = "${each.key} average CPU above ${var.cpu_threshold_percent}% for 15 minutes. See docs/runbook.md#ecs-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_threshold_percent
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------------------------------------------------------------- app alarms

# The worker logs JSON like {"message": "publish_failed", "post_id": 7, ...}.
# This filter turns each of those lines into a data point on a custom metric.
resource "aws_cloudwatch_log_metric_filter" "publish_failures" {
  name           = "${var.name}-publish-failures"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "{ $.message = \"publish_failed\" }"

  metric_transformation {
    name          = "PublishFailures"
    namespace     = local.metric_ns
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "publish_failures" {
  alarm_name          = "${var.name}-publish-failures"
  alarm_description   = "${var.publish_failure_threshold}+ webhook delivery failures in 5 minutes. See docs/runbook.md#publish-failures"
  namespace           = local.metric_ns
  metric_name         = aws_cloudwatch_log_metric_filter.publish_failures.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.publish_failure_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
