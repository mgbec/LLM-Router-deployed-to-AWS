# =============================================================================
# Amazon Bedrock AgentCore - Runtime & Gateway
# =============================================================================

# -----------------------------------------------------------------------------
# ECR Repository for Router Agent Container
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "router_agent" {
  name                 = "${local.name_prefix}-router-agent"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.environment != "prod"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "router_agent" {
  repository = aws_ecr_repository.router_agent.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AgentCore Runtime - Router Agent
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "router" {
  agent_runtime_name = replace("${local.name_prefix}_router", "-", "_")
  description        = "LLM Router Agent - classifies requests and routes to optimal model"
  role_arn           = aws_iam_role.agentcore_runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.router_agent.repository_url}:${var.router_agent_image_tag}"
    }
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  network_configuration {
    network_mode = var.network_mode
  }

  # Auth handled at API Gateway layer; runtime uses IAM (default when no authorizer set)

  environment_variables = {
    ENVIRONMENT              = var.environment
    ROUTING_POLICY_TABLE     = aws_dynamodb_table.routing_policies.name
    ROUTING_METRICS_TABLE    = aws_dynamodb_table.routing_metrics.name
    KINESIS_STREAM_NAME      = aws_kinesis_stream.routing_events.name
    APPCONFIG_APP_ID         = aws_appconfig_application.router.id
    APPCONFIG_ENV_ID         = aws_appconfig_environment.router.environment_id
    APPCONFIG_PROFILE_ID     = aws_appconfig_configuration_profile.routing_config.configuration_profile_id
    CLASSIFIER_MODEL_ID      = "us.amazon.nova-lite-v1:0"
    DEFAULT_FALLBACK_MODEL   = "us.anthropic.claude-sonnet-4-20250514-v1:0"
    ENABLE_EXTERNAL_PROVIDERS = tostring(var.enable_external_providers)
    GATEWAY_URL              = aws_bedrockagentcore_gateway.router.gateway_url
    LOG_GROUP_NAME           = aws_cloudwatch_log_group.router_agent.name
    # ISO 42001 Compliance
    GUARDRAIL_ID             = aws_bedrock_guardrail.router_safety.guardrail_id
    GUARDRAIL_VERSION        = aws_bedrock_guardrail_version.router_safety.version
    GUARDRAIL_EXTERNAL_ID    = aws_bedrock_guardrail.external_routing.guardrail_id
    AUDIT_LOG_TABLE          = aws_dynamodb_table.routing_audit_log.name
    KILL_SWITCH_PROFILE      = aws_appconfig_configuration_profile.kill_switch.configuration_profile_id
    DATA_FLOW_LOG_TABLE      = aws_dynamodb_table.data_flow_log.name
    DEPLOY_VERSION           = "6"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# AgentCore Gateway - Unified Entry Point
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "router" {
  name        = "${local.name_prefix}-gateway"
  description = "LLM Router Gateway - routes to tools, models, and external providers"
  role_arn    = aws_iam_role.agentcore_gateway.arn

  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.router.id}/.well-known/openid-configuration"
      allowed_clients = [aws_cognito_user_pool_client.router_m2m.id]
    }
  }

  protocol_configuration {
    mcp {
      supported_versions = ["2025-03-26"]
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Gateway Targets - Lambda Tools
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway_target" "complexity_classifier" {
  name               = "complexity-classifier"
  description        = "Classifies prompt complexity for routing decisions"
  gateway_identifier = aws_bedrockagentcore_gateway.router.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.complexity_classifier.arn
        tool_schema {
          inline_payload {
            name        = "classify_complexity"
            description = "Analyze a prompt and classify its complexity as simple, moderate, complex, or specialized"
            input_schema {
              type = "object"
              property {
                name        = "prompt"
                type        = "string"
                description = "The user prompt to classify"
              }
              property {
                name        = "context"
                type        = "string"
                description = "Additional context about the request"
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "model_invoker" {
  name               = "model-invoker"
  description        = "Invokes the selected model and returns the response"
  gateway_identifier = aws_bedrockagentcore_gateway.router.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.model_invoker.arn
        tool_schema {
          inline_payload {
            name        = "invoke_model"
            description = "Invoke a specific model with the given prompt and parameters"
            input_schema {
              type = "object"
              property {
                name        = "model_id"
                type        = "string"
                description = "The model identifier to invoke"
              }
              property {
                name        = "provider"
                type        = "string"
                description = "The provider (bedrock, sagemaker, external)"
              }
              property {
                name        = "messages"
                type        = "string"
                description = "JSON-encoded messages array for the model"
              }
              property {
                name        = "parameters"
                type        = "string"
                description = "JSON-encoded model invocation parameters (temperature, max_tokens, etc.)"
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "feedback_collector" {
  name               = "feedback-collector"
  description        = "Collects response quality feedback for adaptive routing"
  gateway_identifier = aws_bedrockagentcore_gateway.router.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.feedback_collector.arn
        tool_schema {
          inline_payload {
            name        = "record_feedback"
            description = "Record quality feedback for a routing decision"
            input_schema {
              type = "object"
              property {
                name        = "request_id"
                type        = "string"
                description = "The unique request identifier"
              }
              property {
                name        = "model_id"
                type        = "string"
                description = "The model that was invoked"
              }
              property {
                name        = "latency_ms"
                type        = "number"
                description = "Response latency in milliseconds"
              }
              property {
                name        = "quality_score"
                type        = "number"
                description = "Quality score (0.0 to 1.0)"
              }
              property {
                name        = "cost"
                type        = "number"
                description = "Estimated cost of the request"
              }
              property {
                name        = "escalated"
                type        = "boolean"
                description = "Whether the request was escalated to a higher-tier model"
              }
            }
          }
        }
      }
    }
  }
}
