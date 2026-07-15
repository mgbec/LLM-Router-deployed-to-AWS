# =============================================================================
# Data Classification Engine (ISO 42001: A.7.5, A.7.6)
# =============================================================================
# Addresses:
#   A.7.5 - Data acquisition and collection (control what data flows where)
#   A.7.6 - Data provenance (track data flow decisions)
#   A.7.2 - Data for development (governance over training/routing data)
#
# This component scans prompts before routing and enforces data residency rules.
# If a prompt contains restricted data categories, it blocks routing to external
# providers and forces routing to internal (Bedrock/SageMaker) models only.

# -----------------------------------------------------------------------------
# Data Classification Lambda
# Scans prompts for data sensitivity before routing decisions
# -----------------------------------------------------------------------------

data "archive_file" "data_classifier" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/data_classifier"
  output_path = "${path.module}/.build/data_classifier.zip"
}

resource "aws_lambda_function" "data_classifier" {
  function_name = "${local.name_prefix}-data-classifier"
  description   = "ISO 42001 A.7.5: Classifies data sensitivity and enforces residency rules before routing"
  role          = aws_iam_role.lambda_data_classifier.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 15
  memory_size   = 256

  filename         = data.archive_file.data_classifier.output_path
  source_code_hash = data.archive_file.data_classifier.output_base64sha256

  environment {
    variables = {
      REGION                     = local.region
      GUARDRAIL_ID               = aws_bedrock_guardrail.external_routing.guardrail_id
      GUARDRAIL_VERSION          = aws_bedrock_guardrail_version.external_routing.version
      DATA_FLOW_LOG_TABLE        = aws_dynamodb_table.data_flow_log.name
      BLOCKED_CATEGORIES_EXTERNAL = "pii,financial,health,legal,credentials"
    }
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.7.5,A.7.6"
    Purpose         = "data-classification-and-residency"
  })
}

resource "aws_iam_role" "lambda_data_classifier" {
  name = "${local.name_prefix}-lambda-data-classifier-role"

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

resource "aws_iam_role_policy_attachment" "lambda_data_classifier_basic" {
  role       = aws_iam_role.lambda_data_classifier.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_data_classifier" {
  name = "${local.name_prefix}-data-classifier-policy"
  role = aws_iam_role.lambda_data_classifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeGuardrail"
        Effect = "Allow"
        Action = [
          "bedrock:ApplyGuardrail"
        ]
        Resource = [
          aws_bedrock_guardrail.external_routing.guardrail_arn
        ]
      },
      {
        Sid    = "DataFlowLog"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = [aws_dynamodb_table.data_flow_log.arn]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Data Flow Log Table
# Records every data classification decision for audit (A.7.6 provenance)
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "data_flow_log" {
  name         = "${local.name_prefix}-data-flow-log"
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

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.7.6"
    Purpose         = "data-flow-provenance"
    DataRetention   = "90-days"
  })
}

# -----------------------------------------------------------------------------
# Gateway Target for Data Classifier
# Expose as MCP tool accessible to the Router Agent
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway_target" "data_classifier" {
  name        = "data-classifier"
  description = "Classifies data sensitivity and enforces residency rules before external routing"
  gateway_id  = aws_bedrockagentcore_gateway.router.id

  target_configuration {
    lambda_target {
      lambda_arn = aws_lambda_function.data_classifier.arn
      tool_schema {
        inline_payload = jsonencode({
          tools = [
            {
              name        = "classify_data_sensitivity"
              description = "Scan a prompt for sensitive data and determine if it can be routed to external providers"
              inputSchema = {
                type = "object"
                properties = {
                  prompt = {
                    type        = "string"
                    description = "The user prompt to classify"
                  }
                  target_provider = {
                    type        = "string"
                    description = "The intended target provider"
                    enum        = ["bedrock", "sagemaker", "external"]
                  }
                  request_id = {
                    type        = "string"
                    description = "Request ID for audit logging"
                  }
                }
                required = ["prompt", "target_provider"]
              }
            }
          ]
        })
      }
    }
  }
}
