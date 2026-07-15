# =============================================================================
# Governance Documentation & Risk Register (ISO 42001: A.2, A.5, A.6.2.9)
# =============================================================================
# Addresses:
#   A.2.2 - AI Policy (versioned policy storage)
#   A.5.2 - AI System Risk Assessment (risk register)
#   A.5.3 - AI System Impact Assessment (impact documentation)
#   A.6.2.9 - AI System Documentation (model cards, system docs)
#   A.6.2.10 - Defined Use and Misuse (acceptable use policy)
#   A.10.2 - Suppliers (provider assessment records)

# -----------------------------------------------------------------------------
# S3 Bucket for Governance Documentation
# Versioned, encrypted storage for all AIMS documentation
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "governance_docs" {
  bucket = "${local.name_prefix}-governance-docs-${local.account_id}"

  tags = merge(local.common_tags, {
    ISO42001Control = "A.2.2,A.5.2,A.5.3,A.6.2.9"
    Purpose         = "aims-governance-documentation"
  })
}

resource "aws_s3_bucket_versioning" "governance_docs" {
  bucket = aws_s3_bucket.governance_docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "governance_docs" {
  bucket = aws_s3_bucket.governance_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "governance_docs" {
  bucket                  = aws_s3_bucket.governance_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "governance_docs" {
  bucket = aws_s3_bucket.governance_docs.id

  rule {
    id     = "archive-old-versions"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# -----------------------------------------------------------------------------
# Seed Governance Documents
# -----------------------------------------------------------------------------

resource "aws_s3_object" "ai_policy" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "policies/ai-policy.md"
  content_type = "text/markdown"
  content      = <<-EOT
# AI Policy — LLM Router System

## Version
- Version: 1.0
- Effective Date: ${timestamp()}
- Owner: [AIMS Owner - To Be Assigned]
- Review Frequency: Quarterly

## 1. Purpose
This policy governs the responsible development, deployment, and operation of
the LLM Router system, which dynamically selects AI models for inference requests.

## 2. Scope
This policy applies to all personnel involved in operating, maintaining, and
consuming the LLM Router, including internal users, API consumers, and
administrators.

## 3. Principles

### 3.1 Fairness and Non-Discrimination
- Routing decisions shall not systematically disadvantage users based on protected
  characteristics.
- Quality of service shall be equitable across user groups within the same policy tier.
- The complexity classifier shall be regularly tested for bias.

### 3.2 Transparency
- Users shall be informed that model selection is dynamic.
- The model that served each request shall be identified in response metadata.
- Users may request an explanation of routing decisions.

### 3.3 Accountability
- All routing decisions are logged and auditable.
- Clear roles and responsibilities are defined for system governance.
- Incidents are tracked, investigated, and remediated.

### 3.4 Human Oversight
- Human operators can override routing decisions at any time.
- A kill switch exists for emergency system shutdown.
- High-risk content categories trigger human review workflows.

### 3.5 Data Protection
- PII is detected and masked before routing to external providers.
- Data residency policies are enforced (sensitive data stays within AWS).
- User prompts and responses are not retained beyond operational necessity.

### 3.6 Safety
- All model outputs pass through content safety guardrails.
- Prohibited topics (medical, legal, financial advice) are blocked.
- Prompt injection and jailbreak attempts are detected and blocked.

### 3.7 Environmental Responsibility
- Routing favors smaller, less energy-intensive models when quality allows.
- Cost optimization inherently promotes computational efficiency.

## 4. Compliance
This system is operated in alignment with:
- ISO/IEC 42001:2023 (AI Management Systems)
- EU AI Act (where applicable)
- AWS Shared Responsibility Model

## 5. Review
This policy shall be reviewed quarterly or upon significant system changes.
  EOT

  tags = merge(local.common_tags, { Document = "ai-policy" })
}

resource "aws_s3_object" "risk_register" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "risk-assessment/risk-register.json"
  content_type = "application/json"
  content = jsonencode({
    version     = "1.0"
    last_review = timestamp()
    risks = [
      {
        id          = "RISK-001"
        category    = "Fairness"
        title       = "Routing Bias in Complexity Classifier"
        description = "The complexity classifier may systematically rate certain languages, dialects, or topics as simpler, resulting in lower-quality model assignments for some user groups."
        likelihood  = "Medium"
        impact      = "High"
        risk_level  = "High"
        mitigations = [
          "Regular bias testing across language and topic distributions",
          "Monitor quality scores by user segment",
          "Fallback ensures minimum quality threshold"
        ]
        status = "Open"
        owner  = "AI Governance Board"
      },
      {
        id          = "RISK-002"
        category    = "Data Privacy"
        title       = "PII Leakage to External Providers"
        description = "User prompts containing PII may be routed to external providers (OpenAI, etc.), violating data residency and privacy requirements."
        likelihood  = "Medium"
        impact      = "Critical"
        risk_level  = "Critical"
        mitigations = [
          "Bedrock Guardrails PII detection on all requests",
          "Stricter guardrail applied before external routing",
          "External routing disabled by default",
          "Data classification engine blocks PII from external routing"
        ]
        status = "Mitigated"
        owner  = "Data Protection Officer"
      },
      {
        id          = "RISK-003"
        category    = "Safety"
        title       = "Harmful Content Amplification via Cascade"
        description = "The cascade pattern may amplify harmful outputs if a cheaper model produces unsafe content that passes confidence checks."
        likelihood  = "Low"
        impact      = "High"
        risk_level  = "Medium"
        mitigations = [
          "Guardrails applied to ALL model outputs regardless of tier",
          "Content filter runs post-response for every model in cascade",
          "Topic blocking for prohibited use cases"
        ]
        status = "Mitigated"
        owner  = "AI Safety Lead"
      },
      {
        id          = "RISK-004"
        category    = "Reliability"
        title       = "Cascade Provider Failure"
        description = "If multiple providers fail simultaneously, users may receive degraded service or no response."
        likelihood  = "Low"
        impact      = "High"
        risk_level  = "Medium"
        mitigations = [
          "Circuit breaker with automatic failover",
          "Minimum 2 warm instances of router agent",
          "Multi-region deployment option",
          "Fallback to default model on complete failure"
        ]
        status = "Mitigated"
        owner  = "Platform Engineering"
      },
      {
        id          = "RISK-005"
        category    = "Accountability"
        title       = "Untraceable Model Outputs"
        description = "If routing decisions are not logged, it becomes impossible to attribute problematic outputs to specific models."
        likelihood  = "Low"
        impact      = "Medium"
        risk_level  = "Low"
        mitigations = [
          "Every routing decision logged to audit table",
          "Response metadata includes model_id",
          "Kinesis stream captures full routing events",
          "90-day retention on audit logs"
        ]
        status = "Mitigated"
        owner  = "Platform Engineering"
      },
      {
        id          = "RISK-006"
        category    = "Fairness"
        title       = "Tiered Quality by Budget Creates Inequality"
        description = "Budget-conscious policies route to cheaper/lower-quality models. If budget tiers correlate with user demographics, this creates systemic quality inequality."
        likelihood  = "Medium"
        impact      = "High"
        risk_level  = "High"
        mitigations = [
          "Monitor quality distribution across tenant tiers",
          "Minimum quality threshold (0.6) even on cheapest tier",
          "Cascade pattern ensures escalation if confidence is low",
          "Regular fairness audit of quality outcomes"
        ]
        status = "Open"
        owner  = "AI Governance Board"
      },
      {
        id          = "RISK-007"
        category    = "Third-Party"
        title       = "External Provider Terms Change"
        description = "External providers (OpenAI, etc.) may change their terms of service, data retention practices, or model behavior without notice."
        likelihood  = "High"
        impact      = "Medium"
        risk_level  = "Medium"
        mitigations = [
          "External providers disabled by default",
          "Kill switch for instant provider deactivation",
          "Contractual DPA requirements documented",
          "Quarterly provider assessment review"
        ]
        status = "Mitigated"
        owner  = "Vendor Management"
      }
    ]
  })

  tags = merge(local.common_tags, { Document = "risk-register" })
}

resource "aws_s3_object" "acceptable_use" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "policies/acceptable-use-policy.md"
  content_type = "text/markdown"
  content      = <<-EOT
# Acceptable Use Policy — LLM Router

## Intended Use
The LLM Router is designed for:
- General-purpose text generation and analysis
- Code generation and explanation
- Content summarization and transformation
- Question answering from general knowledge
- Creative writing assistance

## Prohibited Uses
The following uses are prohibited and will be blocked:
- Medical diagnosis or treatment recommendations
- Specific legal advice or case strategy
- Individual financial or investment advice
- Generation of content that targets protected groups
- Attempts to bypass safety controls (jailbreaking)
- Automated decision-making with legal or similarly significant effects on individuals
  without human oversight
- Mass surveillance or profiling of individuals
- Generation of misinformation or deepfakes

## Responsibilities
- **API Consumers**: Must not use the router for prohibited purposes. Must inform
  their end-users that AI model selection is dynamic.
- **Operators**: Must monitor for misuse and respond to AI concern reports within
  SLA (4 hours for critical, 24 hours for standard).
- **Administrators**: Must review routing fairness metrics monthly and update
  policies as needed.

## Enforcement
Violations will be investigated. Accounts may be suspended or terminated for
repeated or severe violations.
  EOT

  tags = merge(local.common_tags, { Document = "acceptable-use-policy" })
}

resource "aws_s3_object" "model_cards_index" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "model-cards/index.json"
  content_type = "application/json"
  content = jsonencode({
    version = "1.0"
    models = [
      {
        model_id     = "amazon.nova-lite-v1:0"
        provider     = "AWS (Amazon)"
        tier         = "simple"
        capabilities = "Fast inference, basic Q&A, classification, simple tasks"
        limitations  = "Limited reasoning depth, may struggle with complex logic"
        known_biases = "See Amazon model card documentation"
        data_residency = "AWS region-local"
        cost_tier    = "Low"
        doc_url      = "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nova-lite.html"
      },
      {
        model_id     = "amazon.nova-pro-v1:0"
        provider     = "AWS (Amazon)"
        tier         = "moderate"
        capabilities = "Balanced performance, multi-step reasoning, code generation"
        limitations  = "May hallucinate on niche topics"
        known_biases = "See Amazon model card documentation"
        data_residency = "AWS region-local"
        cost_tier    = "Medium"
        doc_url      = "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nova-pro.html"
      },
      {
        model_id     = "anthropic.claude-sonnet-4-20250514-v1:0"
        provider     = "Anthropic (via Bedrock)"
        tier         = "moderate"
        capabilities = "Strong reasoning, code generation, analysis, creative writing"
        limitations  = "May refuse edge-case requests conservatively"
        known_biases = "See Anthropic model card"
        data_residency = "AWS region-local (Bedrock)"
        cost_tier    = "Medium-High"
        doc_url      = "https://docs.anthropic.com/en/docs/about-claude/models"
      },
      {
        model_id     = "anthropic.claude-opus-4-20250514-v1:0"
        provider     = "Anthropic (via Bedrock)"
        tier         = "complex"
        capabilities = "Frontier-level reasoning, complex analysis, nuanced writing"
        limitations  = "Higher latency, most expensive tier"
        known_biases = "See Anthropic model card"
        data_residency = "AWS region-local (Bedrock)"
        cost_tier    = "High"
        doc_url      = "https://docs.anthropic.com/en/docs/about-claude/models"
      }
    ]
  })

  tags = merge(local.common_tags, { Document = "model-cards-index" })
}

resource "aws_s3_object" "impact_assessment" {
  bucket       = aws_s3_bucket.governance_docs.id
  key          = "impact-assessment/ai-system-impact-assessment.md"
  content_type = "text/markdown"
  content      = <<-EOT
# AI System Impact Assessment — LLM Router

## 1. System Description
Dynamic model selection system that routes AI inference requests to optimal
models based on complexity, cost, latency, and quality constraints.

## 2. Affected Parties
- **Direct users**: API consumers who receive model-generated responses
- **Indirect stakeholders**: End-users of applications built on this router
- **Operators**: Personnel managing routing policies and model pool

## 3. Positive Impacts
- Cost efficiency: Users get appropriate quality without overpaying
- Reliability: Failover ensures continuous service
- Performance: Latency-sensitive requests get fast models

## 4. Potential Negative Impacts

### 4.1 Quality Inequality
- **Risk**: Budget-constrained tiers may receive systematically lower quality
- **Severity**: Medium
- **Affected group**: Users/tenants on lower-cost policies
- **Mitigation**: Minimum quality threshold, cascade escalation

### 4.2 Classifier Bias
- **Risk**: Some languages/topics classified as "simpler" than they are
- **Severity**: High
- **Affected group**: Non-English speakers, niche domain users
- **Mitigation**: Bias testing protocol, heuristic fallback for short prompts

### 4.3 Privacy Impact
- **Risk**: Prompts routed to external providers expose user data
- **Severity**: Critical
- **Affected group**: All users (if external providers enabled)
- **Mitigation**: PII guardrails, external routing disabled by default, data
  classification engine

### 4.4 Transparency Impact
- **Risk**: Users unaware which model serves them
- **Severity**: Low-Medium
- **Affected group**: All users
- **Mitigation**: Mandatory response metadata, transparency API

## 5. Residual Risks
After mitigations, the following residual risks remain:
- The classifier may have subtle biases not caught by testing
- New model versions may introduce unexpected behavior
- Cost pressure may incentivize administrators to lower quality thresholds

## 6. Review Schedule
This assessment shall be reviewed:
- Quarterly (routine)
- When new models are added to the pool
- When routing policies change significantly
- After any reported bias or quality incident
  EOT

  tags = merge(local.common_tags, { Document = "impact-assessment" })
}
