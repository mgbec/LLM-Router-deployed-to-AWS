# =============================================================================
# DynamoDB Tables - Routing Policies & Metrics
# =============================================================================

# -----------------------------------------------------------------------------
# Routing Policies Table
# Stores per-tenant/per-tier routing policies and model weights
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "routing_policies" {
  name         = "${local.name_prefix}-routing-policies"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "policy_id"

  attribute {
    name = "policy_id"
    type = "S"
  }

  attribute {
    name = "tenant_id"
    type = "S"
  }

  global_secondary_index {
    name            = "tenant-index"
    hash_key        = "tenant_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Routing Metrics Table
# Stores per-model performance metrics for adaptive weight adjustment
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "routing_metrics" {
  name         = "${local.name_prefix}-routing-metrics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "model_id"
  range_key    = "timestamp"

  attribute {
    name = "model_id"
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

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Seed Default Routing Policies
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table_item" "default_policy" {
  table_name = aws_dynamodb_table.routing_policies.name
  hash_key   = aws_dynamodb_table.routing_policies.hash_key

  item = jsonencode({
    policy_id = { S = "default" }
    tenant_id = { S = "system" }
    config = { M = {
      max_cost_per_request = { N = tostring(var.default_max_cost_per_request) }
      max_latency_ms       = { N = tostring(var.default_max_latency_ms) }
      quality_threshold    = { N = tostring(var.default_quality_threshold) }
      strategy             = { S = "complexity_based" }
      fallback_chain = { L = [
        { S = "anthropic.claude-sonnet-4-20250514-v1:0" },
        { S = "amazon.nova-pro-v1:0" },
        { S = "amazon.nova-lite-v1:0" }
      ] }
      model_weights = { M = {
        "amazon.nova-lite-v1:0"                   = { M = { weight = { N = "1.0" }, tier = { S = "simple" } } }
        "amazon.nova-pro-v1:0"                    = { M = { weight = { N = "1.0" }, tier = { S = "moderate" } } }
        "anthropic.claude-sonnet-4-20250514-v1:0" = { M = { weight = { N = "1.0" }, tier = { S = "moderate" } } }
        "anthropic.claude-opus-4-20250514-v1:0"   = { M = { weight = { N = "1.0" }, tier = { S = "complex" } } }
      } }
    } }
  })
}

resource "aws_dynamodb_table_item" "enterprise_policy" {
  table_name = aws_dynamodb_table.routing_policies.name
  hash_key   = aws_dynamodb_table.routing_policies.hash_key

  item = jsonencode({
    policy_id = { S = "enterprise" }
    tenant_id = { S = "system" }
    config = { M = {
      max_cost_per_request = { N = "0.50" }
      max_latency_ms       = { N = "30000" }
      quality_threshold    = { N = "0.95" }
      strategy             = { S = "quality_maximized" }
      fallback_chain = { L = [
        { S = "anthropic.claude-opus-4-20250514-v1:0" },
        { S = "anthropic.claude-sonnet-4-20250514-v1:0" }
      ] }
      model_weights = { M = {
        "anthropic.claude-opus-4-20250514-v1:0"   = { M = { weight = { N = "1.0" }, tier = { S = "complex" } } }
        "anthropic.claude-sonnet-4-20250514-v1:0" = { M = { weight = { N = "0.8" }, tier = { S = "moderate" } } }
      } }
    } }
  })
}

resource "aws_dynamodb_table_item" "budget_policy" {
  table_name = aws_dynamodb_table.routing_policies.name
  hash_key   = aws_dynamodb_table.routing_policies.hash_key

  item = jsonencode({
    policy_id = { S = "budget_conscious" }
    tenant_id = { S = "system" }
    config = { M = {
      max_cost_per_request = { N = "0.005" }
      max_latency_ms       = { N = "5000" }
      quality_threshold    = { N = "0.6" }
      strategy             = { S = "cost_optimized" }
      fallback_chain = { L = [
        { S = "amazon.nova-lite-v1:0" },
        { S = "amazon.nova-pro-v1:0" }
      ] }
      model_weights = { M = {
        "amazon.nova-lite-v1:0" = { M = { weight = { N = "1.0" }, tier = { S = "simple" } } }
        "amazon.nova-pro-v1:0"  = { M = { weight = { N = "0.5" }, tier = { S = "moderate" } } }
      } }
    } }
  })
}
