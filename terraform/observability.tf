# =============================================================================
# Observability - CloudWatch, Alarms, Dashboard
# =============================================================================

# -----------------------------------------------------------------------------
# Log Groups
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "router_agent" {
  name              = "/llm-router/${var.environment}/agent"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_classifier" {
  name              = "/aws/lambda/${aws_lambda_function.complexity_classifier.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_model_invoker" {
  name              = "/aws/lambda/${aws_lambda_function.model_invoker.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_feedback" {
  name              = "/aws/lambda/${aws_lambda_function.feedback_collector.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_weight_adjuster" {
  name              = "/aws/lambda/${aws_lambda_function.weight_adjuster.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "router_error_rate" {
  alarm_name          = "${local.name_prefix}-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RoutingErrors"
  namespace           = "LLMRouter/${var.environment}"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Router error rate exceeded threshold"
  alarm_actions       = [aws_sns_topic.router_alerts.arn]

  dimensions = {
    Component = "Router"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "${local.name_prefix}-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RoutingLatency"
  namespace           = "LLMRouter/${var.environment}"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 5000
  alarm_description   = "P99 routing latency exceeded 5s"
  alarm_actions       = [aws_sns_topic.router_alerts.arn]

  dimensions = {
    Component = "Router"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cost_spike" {
  alarm_name          = "${local.name_prefix}-cost-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HourlyCost"
  namespace           = "LLMRouter/${var.environment}"
  period              = 3600
  statistic           = "Sum"
  threshold           = var.environment == "prod" ? 50 : 10
  alarm_description   = "Hourly routing cost exceeded threshold"
  alarm_actions       = [aws_sns_topic.router_alerts.arn]

  dimensions = {
    Component = "Router"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "circuit_breaker_open" {
  alarm_name          = "${local.name_prefix}-circuit-breaker-open"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CircuitBreakerOpen"
  namespace           = "LLMRouter/${var.environment}"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "A provider circuit breaker has opened"
  alarm_actions       = [aws_sns_topic.router_alerts.arn]

  dimensions = {
    Component = "CircuitBreaker"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SNS Topic for Alerts
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "router_alerts" {
  name = "${local.name_prefix}-alerts"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Dashboard
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "router" {
  dashboard_name = "${local.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Requests by Model"
          metrics = [
            ["LLMRouter/${var.environment}", "RequestCount", "ModelId", "amazon.nova-lite-v1:0"],
            ["...", "amazon.nova-pro-v1:0"],
            ["...", "anthropic.claude-sonnet-4-20250514-v1:0"],
            ["...", "anthropic.claude-opus-4-20250514-v1:0"]
          ]
          period = 300
          stat   = "Sum"
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Routing Latency (p50, p95, p99)"
          metrics = [
            ["LLMRouter/${var.environment}", "RoutingLatency", "Component", "Router", { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }]
          ]
          period = 60
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Cost per Model (hourly)"
          metrics = [
            ["LLMRouter/${var.environment}", "RequestCost", "ModelId", "amazon.nova-lite-v1:0"],
            ["...", "amazon.nova-pro-v1:0"],
            ["...", "anthropic.claude-sonnet-4-20250514-v1:0"],
            ["...", "anthropic.claude-opus-4-20250514-v1:0"]
          ]
          period = 3600
          stat   = "Sum"
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Quality Scores by Model"
          metrics = [
            ["LLMRouter/${var.environment}", "QualityScore", "ModelId", "amazon.nova-lite-v1:0"],
            ["...", "amazon.nova-pro-v1:0"],
            ["...", "anthropic.claude-sonnet-4-20250514-v1:0"],
            ["...", "anthropic.claude-opus-4-20250514-v1:0"]
          ]
          period = 300
          stat   = "Average"
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Escalation Rate"
          metrics = [
            ["LLMRouter/${var.environment}", "EscalationCount", "Component", "Cascade"],
            ["LLMRouter/${var.environment}", "RequestCount", "Component", "Router"]
          ]
          period = 300
          stat   = "Sum"
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Circuit Breaker Status"
          metrics = [
            ["LLMRouter/${var.environment}", "CircuitBreakerOpen", "Provider", "bedrock"],
            ["...", "sagemaker"],
            ["...", "external"]
          ]
          period = 60
          stat   = "Maximum"
          region = local.region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title   = "Complexity Distribution"
          metrics = [
            ["LLMRouter/${var.environment}", "ComplexityClassification", "Complexity", "simple"],
            ["...", "moderate"],
            ["...", "complex"],
            ["...", "specialized"]
          ]
          period = 300
          stat   = "Sum"
          region = local.region
        }
      }
    ]
  })
}
