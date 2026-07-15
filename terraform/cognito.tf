# =============================================================================
# Amazon Cognito - Authentication
# =============================================================================

# -----------------------------------------------------------------------------
# User Pool
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool" "router" {
  name = "${local.name_prefix}-user-pool"

  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# User Pool Domain
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_domain" "router" {
  domain       = "${local.name_prefix}-auth-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.router.id
}

# -----------------------------------------------------------------------------
# Resource Server (for M2M scopes)
# -----------------------------------------------------------------------------

resource "aws_cognito_resource_server" "router_api" {
  identifier   = "llm-router-api"
  name         = "LLM Router API"
  user_pool_id = aws_cognito_user_pool.router.id

  scope {
    scope_name        = "invoke"
    scope_description = "Invoke the LLM router"
  }

  scope {
    scope_name        = "admin"
    scope_description = "Administer routing policies"
  }
}

# -----------------------------------------------------------------------------
# Web Client (Public - for user-facing applications)
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "router_web" {
  name         = "${local.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.router.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = 1   # hours
  id_token_validity      = 1   # hours
  refresh_token_validity = 30  # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# -----------------------------------------------------------------------------
# M2M Client (Confidential - for service-to-service auth)
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "router_m2m" {
  name         = "${local.name_prefix}-m2m-client"
  user_pool_id = aws_cognito_user_pool.router.id

  generate_secret = true

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.router_api.identifier}/invoke"
  ]

  supported_identity_providers = ["COGNITO"]

  access_token_validity = 1 # hours

  token_validity_units {
    access_token = "hours"
  }
}
