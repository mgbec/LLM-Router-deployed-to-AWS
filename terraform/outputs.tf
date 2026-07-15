# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# API Endpoint
# -----------------------------------------------------------------------------

output "api_endpoint" {
  description = "The public API endpoint for the LLM Router"
  value       = aws_apigatewayv2_api.router.api_endpoint
}

output "chat_completions_url" {
  description = "Full URL for chat completions"
  value       = "${aws_apigatewayv2_api.router.api_endpoint}/v1/chat/completions"
}

# -----------------------------------------------------------------------------
# AgentCore
# -----------------------------------------------------------------------------

output "agentcore_runtime_arn" {
  description = "ARN of the AgentCore Runtime hosting the router agent"
  value       = aws_bedrockagentcore_agent_runtime.router.arn
}

output "agentcore_gateway_url" {
  description = "URL of the AgentCore Gateway"
  value       = aws_bedrockagentcore_gateway.router.gateway_url
}

output "agentcore_gateway_id" {
  description = "ID of the AgentCore Gateway"
  value       = aws_bedrockagentcore_gateway.router.id
}

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.router.id
}

output "cognito_web_client_id" {
  description = "Cognito Web Client ID (public, for user-facing apps)"
  value       = aws_cognito_user_pool_client.router_web.id
}

output "cognito_m2m_client_id" {
  description = "Cognito M2M Client ID (confidential, for service-to-service)"
  value       = aws_cognito_user_pool_client.router_m2m.id
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito domain for OAuth flows"
  value       = "https://${aws_cognito_user_pool_domain.router.domain}.auth.${local.region}.amazoncognito.com"
}

output "cognito_token_endpoint" {
  description = "Cognito token endpoint for M2M authentication"
  value       = "https://${aws_cognito_user_pool_domain.router.domain}.auth.${local.region}.amazoncognito.com/oauth2/token"
}

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

output "ecr_repository_url" {
  description = "ECR repository URL for the router agent image"
  value       = aws_ecr_repository.router_agent.repository_url
}

output "routing_policies_table" {
  description = "DynamoDB table name for routing policies"
  value       = aws_dynamodb_table.routing_policies.name
}

output "routing_metrics_table" {
  description = "DynamoDB table name for routing metrics"
  value       = aws_dynamodb_table.routing_metrics.name
}

output "kinesis_stream_name" {
  description = "Kinesis stream name for routing events"
  value       = aws_kinesis_stream.routing_events.name
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.router.dashboard_name}"
}

output "sns_alerts_topic_arn" {
  description = "SNS topic ARN for router alerts"
  value       = aws_sns_topic.router_alerts.arn
}

# -----------------------------------------------------------------------------
# ISO 42001 Compliance Components
# -----------------------------------------------------------------------------

output "guardrail_id" {
  description = "Bedrock Guardrail ID for content safety"
  value       = aws_bedrock_guardrail.router_safety.guardrail_id
}

output "guardrail_external_id" {
  description = "Bedrock Guardrail ID for external provider routing (strict PII blocking)"
  value       = aws_bedrock_guardrail.external_routing.guardrail_id
}

output "transparency_api_url" {
  description = "Base URL for the Transparency API (routing explanations, audit log, model info)"
  value       = "${aws_apigatewayv2_api.router.api_endpoint}/v1"
}

output "governance_docs_bucket" {
  description = "S3 bucket containing AIMS governance documentation"
  value       = aws_s3_bucket.governance_docs.id
}

output "human_review_queue_url" {
  description = "SQS queue URL for AI concerns requiring human review"
  value       = aws_sqs_queue.ai_concerns.url
}

output "ai_concerns_escalation_topic" {
  description = "SNS topic for AI concern escalation (subscribe ops team here)"
  value       = aws_sns_topic.ai_concerns_escalation.arn
}

output "routing_audit_log_table" {
  description = "DynamoDB table for routing transparency audit log"
  value       = aws_dynamodb_table.routing_audit_log.name
}

output "data_flow_log_table" {
  description = "DynamoDB table for data classification/flow decisions"
  value       = aws_dynamodb_table.data_flow_log.name
}
