# =============================================================================
# API Gateway - Public Endpoint for Clients
# =============================================================================

# -----------------------------------------------------------------------------
# HTTP API (API Gateway v2)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "router" {
  name          = "${local.name_prefix}-api"
  description   = "LLM Router API - Dynamic model selection endpoint"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS", "GET"]
    allow_headers = ["Content-Type", "Authorization", "X-Request-Id", "X-Routing-Policy"]
    max_age       = 3600
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Stage ($default with auto-deploy)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.router.id
  name        = "$default"
  auto_deploy = true

  lifecycle {
    # Prevent destroy/recreate conflicts on the default stage
    create_before_destroy = true
    ignore_changes        = [deployment_id]
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Cognito Authorizer
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.router.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.router_web.id]
    issuer   = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.router.id}"
  }
}

# -----------------------------------------------------------------------------
# Integration with AgentCore Runtime
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "router_agent" {
  api_id                 = aws_apigatewayv2_api.router.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_proxy.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "chat_completions" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "POST /v1/chat/completions"

  target             = "integrations/${aws_apigatewayv2_integration.router_agent.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /health"

  target = "integrations/${aws_apigatewayv2_integration.router_agent.id}"
}

resource "aws_apigatewayv2_route" "routing_status" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /v1/routing/status"

  target             = "integrations/${aws_apigatewayv2_integration.router_agent.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# -----------------------------------------------------------------------------
# Stage - managed by auto_deploy on the API resource
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}-api"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# API Proxy Lambda (forwards to AgentCore Runtime)
# -----------------------------------------------------------------------------

data "archive_file" "api_proxy" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/api_proxy"
  output_path = "${path.module}/.build/api_proxy.zip"
}

resource "aws_lambda_function" "api_proxy" {
  function_name = "${local.name_prefix}-api-proxy"
  description   = "Proxies API Gateway requests to AgentCore Runtime"
  role          = aws_iam_role.lambda_api_proxy.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 29
  memory_size   = 256

  filename         = data.archive_file.api_proxy.output_path
  source_code_hash = data.archive_file.api_proxy.output_base64sha256

  environment {
    variables = {
      AGENTCORE_RUNTIME_ARN = aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn
      ASYNC_PROCESSOR_ARN   = aws_lambda_function.async_processor.arn
      REQUESTS_TABLE        = aws_dynamodb_table.async_requests.name
      REGION                = local.region
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_permission" "api_proxy" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.router.execution_arn}/*/*"
}

resource "aws_iam_role" "lambda_api_proxy" {
  name = "${local.name_prefix}-lambda-api-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_api_proxy_basic" {
  role       = aws_iam_role.lambda_api_proxy.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_api_proxy_agentcore" {
  name = "${local.name_prefix}-api-proxy-agentcore"
  role = aws_iam_role.lambda_api_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:InvokeAgentRuntime"
        ]
        Resource = [
          aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn,
          "${aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn}/*"
        ]
      }
    ]
  })
}
