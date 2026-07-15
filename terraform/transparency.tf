# =============================================================================
# Transparency & Explainability (ISO 42001: A.8.2, A.8.3, A.8.4, A.7.6)
# =============================================================================
# Addresses:
#   A.8.2 - Informing interested parties about AI system interaction
#   A.8.3 - Informing about AI outcomes (explain routing decisions)
#   A.8.4 - Access to information about AI interaction (audit log)
#   A.7.6 - Data provenance (track which model produced which response)

# -----------------------------------------------------------------------------
# Routing Audit Log Table
# Immutable record of every routing decision for transparency and audit
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "routing_audit_log" {
  name         = "${local.name_prefix}-routing-audit-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  range_key    = "timestamp"

  attribute {
    name = "request_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "session_id"
    type = "S"
  }

  global_secondary_index {
    name            = "user-index"
    hash_key        = "user_id"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "session-index"
    hash_key        = "session_id"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # Audit logs retained for 90 days (configurable)
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.8.3,A.8.4,A.7.6"
    Purpose         = "routing-transparency-audit"
    DataRetention   = "90-days"
  })
}

# -----------------------------------------------------------------------------
# Transparency API Lambda
# Provides routing explanations and user audit access
# -----------------------------------------------------------------------------

data "archive_file" "transparency_api" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/transparency_api"
  output_path = "${path.module}/.build/transparency_api.zip"
}

resource "aws_lambda_function" "transparency_api" {
  function_name = "${local.name_prefix}-transparency-api"
  description   = "ISO 42001 A.8: Transparency API - explains routing decisions and provides audit access"
  role          = aws_iam_role.lambda_transparency.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.transparency_api.output_path
  source_code_hash = data.archive_file.transparency_api.output_base64sha256

  environment {
    variables = {
      AUDIT_LOG_TABLE = aws_dynamodb_table.routing_audit_log.name
      POLICY_TABLE    = aws_dynamodb_table.routing_policies.name
      REGION          = local.region
    }
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.8.2,A.8.3,A.8.4"
  })
}

resource "aws_iam_role" "lambda_transparency" {
  name = "${local.name_prefix}-lambda-transparency-role"

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

resource "aws_iam_role_policy_attachment" "lambda_transparency_basic" {
  role       = aws_iam_role.lambda_transparency.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_transparency" {
  name = "${local.name_prefix}-transparency-policy"
  role = aws_iam_role.lambda_transparency.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.routing_audit_log.arn,
          "${aws_dynamodb_table.routing_audit_log.arn}/index/*",
          aws_dynamodb_table.routing_policies.arn
        ]
      }
    ]
  })
}

# API Gateway routes for transparency
resource "aws_apigatewayv2_route" "explain_routing" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /v1/routing/explain/{requestId}"

  target             = "integrations/${aws_apigatewayv2_integration.transparency_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "user_audit_log" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /v1/audit/my-requests"

  target             = "integrations/${aws_apigatewayv2_integration.transparency_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "model_cards" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /v1/models/info"

  target             = "integrations/${aws_apigatewayv2_integration.transparency_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_integration" "transparency_api" {
  api_id                 = aws_apigatewayv2_api.router.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.transparency_api.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_lambda_permission" "transparency_api_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transparency_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.router.execution_arn}/*/*"
}
