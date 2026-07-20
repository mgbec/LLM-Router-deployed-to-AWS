# =============================================================================
# ISO 42001 Auditor Role
# Read-only access to all compliance-relevant resources
# =============================================================================
# This role is designed for internal auditors or external certification bodies
# performing ISO 42001 compliance reviews. It provides read-only access to:
#   - Routing audit log (provenance/lineage records)
#   - Data flow log (data classification decisions)
#   - Human review queue (concern reports and overrides)
#   - Governance documentation (S3: policies, risk register, impact assessment)
#   - Routing policies and metrics
#   - CloudWatch dashboards and metrics
#   - X-Ray traces
#   - AppConfig configuration state

# -----------------------------------------------------------------------------
# Auditor IAM Role
# Assumable by IAM users in this account (or cross-account if needed)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "auditor" {
  name        = "${local.name_prefix}-auditor-role"
  description = "ISO 42001 auditor read-only access to compliance data"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.auditor_external_id
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Purpose = "iso-42001-auditor"
  })
}

# -----------------------------------------------------------------------------
# DynamoDB Read-Only (Audit Logs, Data Flow, Human Review, Policies, Metrics)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_dynamodb" {
  name = "${local.name_prefix}-auditor-dynamodb"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAuditTables"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:DescribeTable"
        ]
        Resource = [
          aws_dynamodb_table.routing_audit_log.arn,
          "${aws_dynamodb_table.routing_audit_log.arn}/index/*",
          aws_dynamodb_table.data_flow_log.arn,
          aws_dynamodb_table.human_review_queue.arn,
          "${aws_dynamodb_table.human_review_queue.arn}/index/*",
          aws_dynamodb_table.routing_policies.arn,
          "${aws_dynamodb_table.routing_policies.arn}/index/*",
          aws_dynamodb_table.routing_metrics.arn,
          aws_dynamodb_table.async_requests.arn,
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 Read-Only (Governance Documentation)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_s3" {
  name = "${local.name_prefix}-auditor-s3"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadGovernanceDocs"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:ListBucketVersions"
        ]
        Resource = [
          aws_s3_bucket.governance_docs.arn,
          "${aws_s3_bucket.governance_docs.arn}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Read-Only (Metrics, Dashboards, Logs)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_cloudwatch" {
  name = "${local.name_prefix}-auditor-cloudwatch"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMetricsAndDashboards"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetDashboard",
          "cloudwatch:ListDashboards",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetInsightRuleReport"
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadLogs"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.router_agent.arn}:*",
          "${aws_cloudwatch_log_group.api_gateway.arn}:*",
          "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*:*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# X-Ray Read-Only (Traces)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_xray" {
  name = "${local.name_prefix}-auditor-xray"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadTraces"
        Effect = "Allow"
        Action = [
          "xray:GetTraceSummaries",
          "xray:BatchGetTraces",
          "xray:GetServiceGraph",
          "xray:GetTraceGraph",
          "xray:GetInsight",
          "xray:GetInsightSummaries",
          "xray:GetGroup",
          "xray:GetGroups",
          "xray:GetSamplingRules"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AppConfig Read-Only (Feature Flag State)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_appconfig" {
  name = "${local.name_prefix}-auditor-appconfig"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAppConfig"
        Effect = "Allow"
        Action = [
          "appconfig:GetApplication",
          "appconfig:GetEnvironment",
          "appconfig:GetConfigurationProfile",
          "appconfig:GetHostedConfigurationVersion",
          "appconfig:ListApplications",
          "appconfig:ListEnvironments",
          "appconfig:ListConfigurationProfiles",
          "appconfig:ListHostedConfigurationVersions",
          "appconfig:ListDeployments"
        ]
        Resource = [
          "arn:${local.partition}:appconfig:${local.region}:${local.account_id}:application/${aws_appconfig_application.router.id}",
          "arn:${local.partition}:appconfig:${local.region}:${local.account_id}:application/${aws_appconfig_application.router.id}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Bedrock AgentCore Read-Only (Runtime and Gateway status)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_agentcore" {
  name = "${local.name_prefix}-auditor-agentcore"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAgentCoreResources"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetAgentRuntime",
          "bedrock-agentcore:GetGateway",
          "bedrock-agentcore:ListAgentRuntimes",
          "bedrock-agentcore:ListGateways",
          "bedrock-agentcore:ListGatewayTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SNS/SQS Read-Only (Concerns queue)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "auditor_messaging" {
  name = "${local.name_prefix}-auditor-messaging"
  role = aws_iam_role.auditor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadQueues"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:ListQueues"
        ]
        Resource = [
          aws_sqs_queue.ai_concerns.arn,
          aws_sqs_queue.ai_concerns_dlq.arn
        ]
      },
      {
        Sid    = "ReadTopics"
        Effect = "Allow"
        Action = [
          "sns:GetTopicAttributes",
          "sns:ListTopics",
          "sns:ListSubscriptions"
        ]
        Resource = [
          aws_sns_topic.router_alerts.arn,
          aws_sns_topic.ai_concerns_escalation.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Variable for external ID (required for cross-account or auditor access)
# -----------------------------------------------------------------------------

variable "auditor_external_id" {
  description = "External ID for the auditor role (shared with the auditor for secure role assumption)"
  type        = string
  default     = "iso42001-audit-2026"
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

output "auditor_role_arn" {
  description = "IAM role ARN for ISO 42001 auditors (read-only compliance access)"
  value       = aws_iam_role.auditor.arn
}
