# =============================================================================
# X-Ray Cross-Service Trace Correlation
# =============================================================================
# Ties the full request path into unified traces:
#   API Gateway → Lambda Proxy → AgentCore Runtime → Gateway → Target Model
#
# Components:
#   1. X-Ray Group - filters and groups LLM Router traces together
#   2. Sampling Rules - controls trace volume (100% in dev, sampled in prod)
#   3. API Gateway X-Ray integration
# =============================================================================

# -----------------------------------------------------------------------------
# X-Ray Group - Collects all LLM Router traces for filtered viewing
# -----------------------------------------------------------------------------

resource "aws_xray_group" "router" {
  group_name        = "${local.name_prefix}-traces"
  filter_expression = "service(\"${local.name_prefix}\") OR annotation.project = \"llm-router\" OR annotation.environment = \"${var.environment}\""

  insights_configuration {
    insights_enabled          = true
    notifications_enabled     = true
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Sampling Rule - LLM Router Requests (high priority, captures all routes)
# In dev: 100% sampling for full visibility
# In prod: reservoir of 10/sec + 20% of overflow
# -----------------------------------------------------------------------------

resource "aws_xray_sampling_rule" "router_requests" {
  rule_name      = "${local.name_prefix}-requests"
  priority       = 100
  version        = 1
  reservoir_size = var.environment == "prod" ? 10 : 50
  fixed_rate     = var.environment == "prod" ? 0.2 : 1.0

  host        = "*"
  http_method = "*"
  url_path    = "/v1/*"
  service_name = "${local.name_prefix}-api-proxy"
  service_type = "AWS::Lambda::Function"
  resource_arn = "*"

  attributes = {}

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Sampling Rule - Model Invocations (captures the expensive downstream calls)
# Higher reservoir in dev for debugging; sampled in prod to control costs
# -----------------------------------------------------------------------------

resource "aws_xray_sampling_rule" "model_invocations" {
  rule_name      = "${local.name_prefix}-model-invoke"
  priority       = 200
  version        = 1
  reservoir_size = var.environment == "prod" ? 5 : 25
  fixed_rate     = var.environment == "prod" ? 0.1 : 1.0

  host        = "*"
  http_method = "POST"
  url_path    = "*"
  service_name = "${local.name_prefix}-model-invoker"
  service_type = "AWS::Lambda::Function"
  resource_arn = "*"

  attributes = {}

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Sampling Rule - Complexity Classification (lightweight, high volume)
# Lower sampling in prod since these are fast, cheap calls
# -----------------------------------------------------------------------------

resource "aws_xray_sampling_rule" "classifier" {
  rule_name      = "${local.name_prefix}-classifier"
  priority       = 300
  version        = 1
  reservoir_size = var.environment == "prod" ? 3 : 25
  fixed_rate     = var.environment == "prod" ? 0.05 : 1.0

  host        = "*"
  http_method = "*"
  url_path    = "*"
  service_name = "${local.name_prefix}-complexity-classifier"
  service_type = "AWS::Lambda::Function"
  resource_arn = "*"

  attributes = {}

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Enable X-Ray on API Gateway Stage
# This propagates the trace ID from the client through all downstream services
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "xray_settings" {
  # This uses a lifecycle ignore to avoid conflict with the default stage
  # The actual X-Ray setting is applied via the route settings below
  api_id = aws_apigatewayv2_api.router.id
  name   = "$default"

  # Note: aws_apigatewayv2_stage doesn't have a native xray field for HTTP APIs.
  # X-Ray propagation works automatically when:
  #   1. The Lambda functions have active tracing (already configured)
  #   2. The AWS SDK calls propagate the trace header
  # The sampling rules above control what gets captured.

  lifecycle {
    ignore_changes = all
  }
}

# -----------------------------------------------------------------------------
# IAM: Allow Lambda functions to write X-Ray segments
# (AWSLambdaBasicExecutionRole already includes xray:PutTraceSegments via
#  the managed policy, but we add explicit X-Ray permissions for completeness)
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "xray_write" {
  name        = "${local.name_prefix}-xray-write"
  description = "Allow services to write X-Ray trace segments and telemetry"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayWrite"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

# Attach to all Lambda roles that participate in the trace path
resource "aws_iam_role_policy_attachment" "xray_api_proxy" {
  role       = aws_iam_role.lambda_api_proxy.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_classifier" {
  role       = aws_iam_role.lambda_classifier.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_model_invoker" {
  role       = aws_iam_role.lambda_model_invoker.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_feedback" {
  role       = aws_iam_role.lambda_feedback.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_weight_adjuster" {
  role       = aws_iam_role.lambda_weight_adjuster.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_transparency" {
  role       = aws_iam_role.lambda_transparency.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_human_override" {
  role       = aws_iam_role.lambda_human_override.name
  policy_arn = aws_iam_policy.xray_write.arn
}

resource "aws_iam_role_policy_attachment" "xray_data_classifier" {
  role       = aws_iam_role.lambda_data_classifier.name
  policy_arn = aws_iam_policy.xray_write.arn
}

# Also the AgentCore Runtime role (for OTel trace export)
resource "aws_iam_role_policy_attachment" "xray_agentcore_runtime" {
  role       = aws_iam_role.agentcore_runtime.name
  policy_arn = aws_iam_policy.xray_write.arn
}
