# =============================================================================
# AWS AppConfig - Hot-Swap Routing Configuration
# =============================================================================

# -----------------------------------------------------------------------------
# Application
# -----------------------------------------------------------------------------

resource "aws_appconfig_application" "router" {
  name        = "${local.name_prefix}-config"
  description = "LLM Router dynamic configuration for hot-swap routing"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------

resource "aws_appconfig_environment" "router" {
  name           = var.environment
  description    = "LLM Router ${var.environment} environment"
  application_id = aws_appconfig_application.router.id

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Configuration Profile - Routing Feature Flags
# -----------------------------------------------------------------------------

resource "aws_appconfig_configuration_profile" "routing_config" {
  application_id = aws_appconfig_application.router.id
  name           = "routing-configuration"
  description    = "Dynamic routing configuration - model enablement, weights, provider switches"
  location_uri   = "hosted"
  type           = "AWS.AppConfig.FeatureFlags"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Hosted Configuration Version - Initial Feature Flags
# -----------------------------------------------------------------------------

resource "aws_appconfig_hosted_configuration_version" "routing_flags" {
  application_id           = aws_appconfig_application.router.id
  configuration_profile_id = aws_appconfig_configuration_profile.routing_config.configuration_profile_id
  content_type             = "application/json"

  content = jsonencode({
    version = "1"
    flags = {
      enable_nova_lite = {
        name = "Enable Nova Lite"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      enable_nova_pro = {
        name = "Enable Nova Pro"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      enable_claude_sonnet = {
        name = "Enable Claude Sonnet 4"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      enable_claude_opus = {
        name = "Enable Claude Opus 4"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      enable_external_openai = {
        name = "Enable External OpenAI"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      enable_sagemaker = {
        name = "Enable SageMaker Endpoint"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
        }
      }
      cascade_enabled = {
        name = "Enable Cascade/Escalation Pattern"
        attributes = {
          enabled = { constraints = { type = "boolean" } }
          confidence_threshold = { constraints = { type = "number" } }
        }
      }
      circuit_breaker = {
        name = "Circuit Breaker Configuration"
        attributes = {
          failure_threshold      = { constraints = { type = "number" } }
          recovery_timeout_secs  = { constraints = { type = "number" } }
        }
      }
      traffic_split = {
        name = "Traffic Split Percentages"
        attributes = {
          nova_lite_pct    = { constraints = { type = "number" } }
          nova_pro_pct     = { constraints = { type = "number" } }
          claude_sonnet_pct = { constraints = { type = "number" } }
          claude_opus_pct  = { constraints = { type = "number" } }
        }
      }
    }
    values = {
      enable_nova_lite = {
        enabled = true
      }
      enable_nova_pro = {
        enabled = true
      }
      enable_claude_sonnet = {
        enabled = true
      }
      enable_claude_opus = {
        enabled = true
      }
      enable_external_openai = {
        enabled = var.enable_external_providers
      }
      enable_sagemaker = {
        enabled = var.enable_sagemaker_endpoint
      }
      cascade_enabled = {
        enabled              = true
        confidence_threshold = 0.75
      }
      circuit_breaker = {
        failure_threshold     = 3
        recovery_timeout_secs = 60
      }
      traffic_split = {
        nova_lite_pct     = 40
        nova_pro_pct      = 30
        claude_sonnet_pct = 25
        claude_opus_pct   = 5
      }
    }
  })
}

# -----------------------------------------------------------------------------
# Deployment Strategy - Quick deploy for dev, gradual for prod
# -----------------------------------------------------------------------------

resource "aws_appconfig_deployment_strategy" "router" {
  name                           = "${local.name_prefix}-deploy-strategy"
  description                    = "Deployment strategy for routing config changes"
  deployment_duration_in_minutes = var.environment == "prod" ? 10 : 0
  final_bake_time_in_minutes     = var.environment == "prod" ? 5 : 0
  growth_factor                  = var.environment == "prod" ? 20 : 100
  growth_type                    = "LINEAR"
  replicate_to                   = "NONE"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Initial Deployment
# -----------------------------------------------------------------------------

resource "aws_appconfig_deployment" "routing_flags" {
  application_id           = aws_appconfig_application.router.id
  environment_id           = aws_appconfig_environment.router.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.routing_config.configuration_profile_id
  configuration_version    = aws_appconfig_hosted_configuration_version.routing_flags.version_number
  deployment_strategy_id   = aws_appconfig_deployment_strategy.router.id
  description              = "Initial routing configuration deployment"

  tags = local.common_tags
}
