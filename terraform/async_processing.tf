# =============================================================================
# Async Request Processing
# Enables long-running model invocations (Opus, etc.) without API Gateway timeout
# =============================================================================
# Flow:
#   1. POST /v1/chat/completions → Lambda stores request in DynamoDB, invokes
#      AgentCore asynchronously, returns 202 with request_id
#   2. AgentCore Runtime processes the request (can take minutes for Opus)
#   3. Async processor Lambda writes result back to DynamoDB
#   4. GET /v1/requests/{requestId} → Lambda reads result from DynamoDB

# -----------------------------------------------------------------------------
# Request State Table
# Stores pending/completed async requests
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "async_requests" {
  name         = "${local.name_prefix}-async-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Async Processor Lambda
# Invokes AgentCore Runtime without timeout constraints (up to 15 min)
# Writes result back to DynamoDB
# -----------------------------------------------------------------------------

data "archive_file" "async_processor" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/async_processor"
  output_path = "${path.module}/.build/async_processor.zip"
}

resource "aws_lambda_function" "async_processor" {
  function_name = "${local.name_prefix}-async-processor"
  description   = "Processes LLM routing requests asynchronously (supports long-running models like Opus)"
  role          = aws_iam_role.lambda_async_processor.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 900  # 15 minutes - enough for any model
  memory_size   = 256

  filename         = data.archive_file.async_processor.output_path
  source_code_hash = data.archive_file.async_processor.output_base64sha256

  environment {
    variables = {
      AGENTCORE_RUNTIME_ARN = aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn
      REQUESTS_TABLE        = aws_dynamodb_table.async_requests.name
      KINESIS_STREAM_NAME   = aws_kinesis_stream.routing_events.name
      REGION                = local.region
    }
  }

  tags = local.common_tags
}

resource "aws_iam_role" "lambda_async_processor" {
  name = "${local.name_prefix}-lambda-async-processor-role"

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

resource "aws_iam_role_policy_attachment" "lambda_async_processor_basic" {
  role       = aws_iam_role.lambda_async_processor.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_async_processor" {
  name = "${local.name_prefix}-async-processor-policy"
  role = aws_iam_role.lambda_async_processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAgentCore"
        Effect = "Allow"
        Action = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = [
          aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn,
          "${aws_bedrockagentcore_agent_runtime.router.agent_runtime_arn}/*"
        ]
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = [aws_dynamodb_table.async_requests.arn]
      },
      {
        Sid    = "KinesisPublish"
        Effect = "Allow"
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ]
        Resource = [aws_kinesis_stream.routing_events.arn]
      }
    ]
  })
}

# Allow the API proxy to invoke the async processor
resource "aws_iam_role_policy" "api_proxy_async" {
  name = "${local.name_prefix}-api-proxy-async"
  role = aws_iam_role.lambda_api_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeAsyncProcessor"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.async_processor.arn]
      },
      {
        Sid    = "AsyncRequestsTable"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem"
        ]
        Resource = [aws_dynamodb_table.async_requests.arn]
      }
    ]
  })
}

# API Gateway route for polling
resource "aws_apigatewayv2_route" "poll_request" {
  api_id    = aws_apigatewayv2_api.router.id
  route_key = "GET /v1/requests/{requestId}"

  target             = "integrations/${aws_apigatewayv2_integration.router_agent.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}
