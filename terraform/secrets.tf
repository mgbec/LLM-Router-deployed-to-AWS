# =============================================================================
# Secrets Manager - External Provider Credentials
# =============================================================================

# -----------------------------------------------------------------------------
# OpenAI API Key
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "openai_api_key" {
  count = var.enable_external_providers ? 1 : 0

  name        = "${local.name_prefix}/external-providers/openai-api-key"
  description = "OpenAI API key for external provider routing"

  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  count = var.enable_external_providers ? 1 : 0

  secret_id = aws_secretsmanager_secret.openai_api_key[0].id
  secret_string = jsonencode({
    api_key = var.openai_api_key
  })
}
