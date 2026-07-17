# =============================================================================
# IAM Roles & Policies
# =============================================================================

# -----------------------------------------------------------------------------
# AgentCore Runtime Role - Used by the Router Agent
# -----------------------------------------------------------------------------

resource "aws_iam_role" "agentcore_runtime" {
  name = "${local.name_prefix}-agentcore-runtime-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "agentcore_runtime_bedrock" {
  name = "${local.name_prefix}-bedrock-invoke"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRImagePull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = [
          aws_ecr_repository.router_agent.arn
        ]
      },
      {
        Sid    = "InvokeBedrockModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:${local.partition}:bedrock:${local.region}::foundation-model/*",
          "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/us.*",
          "arn:${local.partition}:bedrock:us-*::foundation-model/*"
        ]
      },
      {
        Sid    = "BedrockPromptRouting"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:default-prompt-router/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_dynamodb" {
  name = "${local.name_prefix}-dynamodb-access"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RoutingPolicyAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.routing_policies.arn,
          "${aws_dynamodb_table.routing_policies.arn}/index/*"
        ]
      },
      {
        Sid    = "RoutingMetricsWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          aws_dynamodb_table.routing_metrics.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_appconfig" {
  name = "${local.name_prefix}-appconfig-access"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppConfigAccess"
        Effect = "Allow"
        Action = [
          "appconfig:GetLatestConfiguration",
          "appconfig:StartConfigurationSession"
        ]
        Resource = [
          "arn:${local.partition}:appconfig:${local.region}:${local.account_id}:application/${aws_appconfig_application.router.id}/environment/${aws_appconfig_environment.router.environment_id}/configuration/${aws_appconfig_configuration_profile.routing_config.configuration_profile_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_secrets" {
  count = var.enable_external_providers ? 1 : 0

  name = "${local.name_prefix}-secrets-access"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ExternalProviderSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.openai_api_key[0].arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_kinesis" {
  name = "${local.name_prefix}-kinesis-publish"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishRoutingEvents"
        Effect = "Allow"
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ]
        Resource = [
          aws_kinesis_stream.routing_events.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_cloudwatch" {
  name = "${local.name_prefix}-cloudwatch-metrics"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "LLMRouter/${var.environment}"
          }
        }
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.router_agent.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_runtime_sagemaker" {
  count = var.enable_sagemaker_endpoint ? 1 : 0

  name = "${local.name_prefix}-sagemaker-invoke"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeSageMakerEndpoint"
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint",
          "sagemaker:InvokeEndpointWithResponseStream"
        ]
        Resource = [
          "arn:${local.partition}:sagemaker:${local.region}:${local.account_id}:endpoint/${var.sagemaker_endpoint_name}"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AgentCore Gateway Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "agentcore_gateway" {
  name = "${local.name_prefix}-agentcore-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "agentcore_gateway_lambda" {
  name = "${local.name_prefix}-gateway-lambda-invoke"
  role = aws_iam_role.agentcore_gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeGatewayLambdas"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.complexity_classifier.arn,
          aws_lambda_function.model_invoker.arn,
          aws_lambda_function.feedback_collector.arn,
          aws_lambda_function.data_classifier.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda Execution Roles
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_classifier" {
  name = "${local.name_prefix}-lambda-classifier-role"

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

resource "aws_iam_role_policy_attachment" "lambda_classifier_basic" {
  role       = aws_iam_role.lambda_classifier.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_classifier_bedrock" {
  name = "${local.name_prefix}-classifier-bedrock"
  role = aws_iam_role.lambda_classifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:${local.partition}:bedrock:${local.region}::foundation-model/amazon.nova-lite-v1:0"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "lambda_model_invoker" {
  name = "${local.name_prefix}-lambda-model-invoker-role"

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

resource "aws_iam_role_policy_attachment" "lambda_model_invoker_basic" {
  role       = aws_iam_role.lambda_model_invoker.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_model_invoker_bedrock" {
  name = "${local.name_prefix}-model-invoker-bedrock"
  role = aws_iam_role.lambda_model_invoker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:${local.partition}:bedrock:${local.region}::foundation-model/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "lambda_feedback" {
  name = "${local.name_prefix}-lambda-feedback-role"

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

resource "aws_iam_role_policy_attachment" "lambda_feedback_basic" {
  role       = aws_iam_role.lambda_feedback.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_feedback_dynamodb" {
  name = "${local.name_prefix}-feedback-dynamodb"
  role = aws_iam_role.lambda_feedback.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = [
          aws_dynamodb_table.routing_metrics.arn,
          aws_dynamodb_table.routing_policies.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Kinesis Consumer Lambda Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_weight_adjuster" {
  name = "${local.name_prefix}-lambda-weight-adjuster-role"

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

resource "aws_iam_role_policy_attachment" "lambda_weight_adjuster_basic" {
  role       = aws_iam_role.lambda_weight_adjuster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_weight_adjuster" {
  name = "${local.name_prefix}-weight-adjuster-policy"
  role = aws_iam_role.lambda_weight_adjuster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KinesisRead"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
          "kinesis:SubscribeToShard"
        ]
        Resource = [aws_kinesis_stream.routing_events.arn]
      },
      {
        Sid    = "DynamoDBUpdate"
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = [aws_dynamodb_table.routing_policies.arn]
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "LLMRouter/${var.environment}"
          }
        }
      }
    ]
  })
}
