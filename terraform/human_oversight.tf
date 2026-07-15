# =============================================================================
# Human Oversight & Kill Switch (ISO 42001: A.9.5, A.3.3, A.8.5)
# =============================================================================
# Addresses:
#   A.9.5 - Human oversight aspects (override, intervention, kill switch)
#   A.3.3 - Reporting AI concerns (escalation pipeline)
#   A.8.5 - Enabling appropriate human actions in response to AI outputs
#   A.6.2.6 - Operation and monitoring (real-time intervention)

# -----------------------------------------------------------------------------
# Kill Switch - Emergency System Disable via AppConfig
# Human operators can instantly halt all routing or specific providers
# -----------------------------------------------------------------------------

resource "aws_appconfig_configuration_profile" "kill_switch" {
  application_id = aws_appconfig_application.router.id
  name           = "kill-switch"
  description    = "Emergency kill switch for human oversight - ISO 42001 A.9.5"
  location_uri   = "hosted"
  type           = "AWS.AppConfig.FeatureFlags"

  tags = merge(local.common_tags, {
    ISO42001Control = "A.9.5"
    Purpose         = "human-oversight-kill-switch"
  })
}

resource "aws_appconfig_hosted_configuration_version" "kill_switch" {
  application_id           = aws_appconfig_application.router.id
  configuration_profile_id = aws_appconfig_configuration_profile.kill_switch.configuration_profile_id
  content_type             = "application/json"

  content = jsonencode({
    version = "1"
    flags = {
      system_active = {
        name = "System Active"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
          reason  = { constraints = { type = "string" } }
        }
      }
      bedrock_provider_active = {
        name = "Bedrock Provider Active"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      external_provider_active = {
        name = "External Provider Active"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      sagemaker_provider_active = {
        name = "SageMaker Provider Active"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      human_review_required = {
        name = "Human Review Required"
        attributes = {
          enabled    = { constraints = { type = "boolean" } }
          categories = { constraints = { type = "string" } }
        }
      }
    }
    values = {
      system_active = {
        enabled = true
        reason  = "System operational"
      }
      bedrock_provider_active = {
        enabled = true
      }
      external_provider_active = {
        enabled = var.enable_external_providers
      }
      sagemaker_provider_active = {
        enabled = var.enable_sagemaker_endpoint
      }
      human_review_required = {
        enabled    = false
        categories = "medical,legal,financial,safety-critical"
      }
    }
  })
}

resource "aws_appconfig_deployment" "kill_switch" {
  application_id           = aws_appconfig_application.router.id
  environment_id           = aws_appconfig_environment.router.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.kill_switch.configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.kill_switch.version_number
  deployment_strategy_id   = aws_appconfig_deployment_strategy.router.id
  description              = "Kill switch initial deployment"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# AI Concerns Reporting Queue (SQS + SNS)
# Enables users and operators to report problematic AI outputs
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "ai_concerns" {
  name                       = "${local.name_prefix}-ai-concerns"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 300
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ai_concerns_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, {
    ISO42001Control = "A.3.3"
    Purpose         = "ai-concern-reporting"
  })
}

resource "aws_sqs_queue" "ai_concerns_dlq" {
  name                      = "${local.name_prefix}-ai-concerns-dlq"
  message_retention_seconds = 1209600

  tags = local.common_tags
}

resource "aws_sns_topic" "ai_concerns_escalation" {
  name = "${local.name_prefix}-ai-concerns-escalation"

  tags = merge(local.common_tags, {
    ISO42001Control = "A.3.3,A.9.5"
    Purpose         = "human-escalation"
  })
}

# SNS triggers the concerns queue for processing
resource "aws_sns_topic_subscription" "concerns_to_queue" {
  topic_arn = aws_sns_topic.ai_concerns_escalation.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.ai_concerns.arn
}

resource "aws_sqs_queue_policy" "ai_concerns" {
  queue_url = aws_sqs_queue.ai_concerns.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.ai_concerns.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.ai_concerns_escalation.arn }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# Human Review DynamoDB Table
# Stores requests flagged for human review before response delivery
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "human_review_queue" {
  name         = "${local.name_prefix}-human-review-queue"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "review_id"
  range_key    = "created_at"

  attribute {
    name = "review_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "N"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.9.5,A.8.5"
    Purpose         = "human-review-queue"
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Alarm for Unreviewed Items (SLA breach)
# Alerts if human review items sit unprocessed too long
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "review_queue_depth" {
  alarm_name          = "${local.name_prefix}-review-queue-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "Human review queue backlog exceeds threshold - ISO 42001 A.9.5 oversight SLA at risk"
  alarm_actions       = [aws_sns_topic.router_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.ai_concerns.name
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Override API Lambda - Allows operators to pin/block models
# -----------------------------------------------------------------------------

data "archive_file" "human_override" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/human_override"
  output_path = "${path.module}/.build/human_override.zip"
}

resource "aws_lambda_function" "human_override" {
  function_name = "${local.name_prefix}-human-override"
  description   = "Human oversight: override routing decisions, pin models, block content categories"
  role          = aws_iam_role.lambda_human_override.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.human_override.output_path
  source_code_hash = data.archive_file.human_override.output_base64sha256

  environment {
    variables = {
      REVIEW_TABLE_NAME     = aws_dynamodb_table.human_review_queue.name
      CONCERNS_TOPIC_ARN    = aws_sns_topic.ai_concerns_escalation.arn
      APPCONFIG_APP_ID      = aws_appconfig_application.router.id
      APPCONFIG_ENV_ID      = aws_appconfig_environment.router.environment_id
      KILL_SWITCH_PROFILE   = aws_appconfig_configuration_profile.kill_switch.configuration_profile_id
      REGION                = local.region
    }
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.9.5"
  })
}

resource "aws_iam_role" "lambda_human_override" {
  name = "${local.name_prefix}-lambda-human-override-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_human_override_basic" {
  role       = aws_iam_role.lambda_human_override.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_human_override" {
  name = "${local.name_prefix}-human-override-policy"
  role = aws_iam_role.lambda_human_override.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.human_review_queue.arn,
          "${aws_dynamodb_table.human_review_queue.arn}/index/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.ai_concerns_escalation.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "appconfig:GetLatestConfiguration",
          "appconfig:StartConfigurationSession"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# API Gateway route for human override
resource "aws_apigatewayv2_route" "human_override" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "POST /v1/admin/override"

  target             = "integrations/${aws_apigatewayv2_integration.human_override.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "report_concern" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "POST /v1/concerns/report"

  target             = "integrations/${aws_apigatewayv2_integration.human_override.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_integration" "human_override" {
  api_id                 = aws_apigatewayv2_api.router.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.human_override.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_lambda_permission" "human_override_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.human_override.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.router.execution_arn}/*/*"
}
