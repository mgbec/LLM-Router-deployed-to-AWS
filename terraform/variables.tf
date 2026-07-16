# =============================================================================
# Variables
# =============================================================================

variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used as prefix for resource naming"
  type        = string
  default     = "llm-router"
}

# -----------------------------------------------------------------------------
# AgentCore Runtime
# -----------------------------------------------------------------------------

variable "router_agent_image_tag" {
  description = "Docker image tag for the router agent (the ECR repo is created by Terraform)"
  type        = string
  default     = "latest"
}

variable "router_agent_min_instances" {
  description = "Minimum number of warm instances for the router agent"
  type        = number
  default     = 2
}

variable "router_agent_max_instances" {
  description = "Maximum number of instances for the router agent"
  type        = number
  default     = 50
}

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------

variable "cognito_user_emails" {
  description = "List of email addresses to create as initial Cognito users"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# External Providers
# -----------------------------------------------------------------------------

variable "openai_api_key" {
  description = "OpenAI API key for external provider routing"
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_external_providers" {
  description = "Whether to enable external provider routing (OpenAI, etc.)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# SageMaker (Optional)
# -----------------------------------------------------------------------------

variable "enable_sagemaker_endpoint" {
  description = "Whether to provision a SageMaker endpoint for self-hosted models"
  type        = bool
  default     = false
}

variable "sagemaker_endpoint_name" {
  description = "Existing SageMaker endpoint name for self-hosted model routing"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Routing Policies
# -----------------------------------------------------------------------------

variable "default_max_cost_per_request" {
  description = "Default maximum cost per request in USD"
  type        = number
  default     = 0.05
}

variable "default_max_latency_ms" {
  description = "Default maximum acceptable latency in milliseconds"
  type        = number
  default     = 3000
}

variable "default_quality_threshold" {
  description = "Default minimum quality score threshold (0.0 to 1.0)"
  type        = number
  default     = 0.8

  validation {
    condition     = var.default_quality_threshold >= 0 && var.default_quality_threshold <= 1
    error_message = "Quality threshold must be between 0.0 and 1.0."
  }
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "enable_detailed_metrics" {
  description = "Enable detailed CloudWatch metrics for routing decisions"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "network_mode" {
  description = "Network mode for AgentCore Runtime (PUBLIC or VPC)"
  type        = string
  default     = "PUBLIC"

  validation {
    condition     = contains(["PUBLIC", "VPC"], var.network_mode)
    error_message = "Network mode must be PUBLIC or VPC."
  }
}
