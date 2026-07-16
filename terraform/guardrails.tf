# =============================================================================
# Bedrock Guardrails - Content Safety & PII Protection (ISO 42001: A.9.4, A.7.5)
# =============================================================================
# Addresses:
#   A.9.4 - Processes for responsible use (content filtering)
#   A.7.5 - Data acquisition/governance (PII protection for external routing)
#   A.9.5 - Human oversight (automated safety layer)
#   A.8.2 - Informing about AI interaction (blocked content messaging)

# -----------------------------------------------------------------------------
# Primary Guardrail - Applied to ALL model invocations
# Filters harmful content and protects PII from leaking to external providers
# -----------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "router_safety" {
  name        = "${local.name_prefix}-safety-guardrail"
  description = "LLM Router safety guardrail - content filtering, PII protection, and topic controls"

  blocked_input_messaging  = "Your request was blocked because it contains content that violates our safety policies. Please rephrase your request."
  blocked_outputs_messaging = "The model response was blocked because it contains content that violates our safety policies. The request has been logged for review."

  # ---------------------------------------------------------------------------
  # Content Filters - Block harmful content in both prompts and responses
  # ---------------------------------------------------------------------------
  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
      input_action    = "BLOCK"
      output_action   = "NONE"
    }
  }

  # ---------------------------------------------------------------------------
  # Sensitive Information Policy - PII detection and masking
  # Prevents PII from being sent to external providers
  # ---------------------------------------------------------------------------
  sensitive_information_policy_config {
    pii_entities_config {
      type          = "EMAIL"
      action        = "ANONYMIZE"
      input_action  = "ANONYMIZE"
      output_action = "ANONYMIZE"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "PHONE"
      action        = "ANONYMIZE"
      input_action  = "ANONYMIZE"
      output_action = "ANONYMIZE"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "NAME"
      action        = "ANONYMIZE"
      input_action  = "ANONYMIZE"
      output_action = "ANONYMIZE"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "US_SOCIAL_SECURITY_NUMBER"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "CREDIT_DEBIT_CARD_NUMBER"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "AWS_ACCESS_KEY"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "AWS_SECRET_KEY"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }

    # Custom regex for internal identifiers
    regexes_config {
      name          = "internal_account_id"
      description   = "Blocks internal account identifiers from being sent to external models"
      pattern       = "ACCT-[A-Z0-9]{8,12}"
      action        = "ANONYMIZE"
      input_action  = "ANONYMIZE"
      output_action = "ANONYMIZE"
      input_enabled = true
      output_enabled = true
    }
  }

  # ---------------------------------------------------------------------------
  # Topic Policy - Block prohibited use cases
  # ---------------------------------------------------------------------------
  topic_policy_config {
    topics_config {
      name       = "medical_diagnosis"
      definition = "Requests for medical diagnoses, treatment plans, or health advice that could replace professional medical consultation"
      type       = "DENY"
      examples = [
        "What medication should I take for my chest pain?",
        "Diagnose my symptoms: fever, cough, headache"
      ]
    }
    topics_config {
      name       = "legal_advice"
      definition = "Requests for specific legal advice, case strategy, or legal opinions that could replace professional legal counsel"
      type       = "DENY"
      examples = [
        "Should I plead guilty in my court case?",
        "Write a legally binding contract for my business"
      ]
    }
    topics_config {
      name       = "financial_advice"
      definition = "Specific investment recommendations, financial planning advice, or trading strategies that could constitute regulated financial advice"
      type       = "DENY"
      examples = [
        "Which stocks should I buy right now?",
        "Should I invest my retirement savings in crypto?"
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Word Filters - Block profanity and known harmful patterns
  # ---------------------------------------------------------------------------
  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }

  # ---------------------------------------------------------------------------
  # Contextual Grounding - Reduce hallucination in responses
  # ---------------------------------------------------------------------------
  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.7
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = 0.7
    }
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.9.4,A.7.5,A.9.5"
    Purpose         = "content-safety-and-pii-protection"
  })
}

# Create a versioned guardrail for production stability
resource "aws_bedrock_guardrail_version" "router_safety" {
  guardrail_arn = aws_bedrock_guardrail.router_safety.guardrail_arn
  description   = "Initial production version"
}

# -----------------------------------------------------------------------------
# Guardrail for External Provider Routing (Stricter PII blocking)
# Applied only when routing to external (non-AWS) providers
# -----------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "external_routing" {
  name        = "${local.name_prefix}-external-routing-guardrail"
  description = "Strict guardrail for external provider routing - blocks all PII from leaving AWS boundary"

  blocked_input_messaging  = "Your request contains sensitive information that cannot be processed by external AI providers. Please remove personal data or use an internal model."
  blocked_outputs_messaging = "Response blocked due to data governance policy violation."

  # Stricter PII policy - BLOCK everything for external routing
  sensitive_information_policy_config {
    pii_entities_config {
      type          = "EMAIL"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "PHONE"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "NAME"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "ADDRESS"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "US_SOCIAL_SECURITY_NUMBER"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "CREDIT_DEBIT_CARD_NUMBER"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "IP_ADDRESS"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "AWS_ACCESS_KEY"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
    pii_entities_config {
      type          = "AWS_SECRET_KEY"
      action        = "BLOCK"
      input_action  = "BLOCK"
      output_action = "BLOCK"
      input_enabled = true
      output_enabled = true
    }
  }

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
      input_action    = "BLOCK"
      output_action   = "BLOCK"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
      input_action    = "BLOCK"
      output_action   = "NONE"
    }
  }

  tags = merge(local.common_tags, {
    ISO42001Control = "A.7.5,A.10.2"
    Purpose         = "external-provider-data-governance"
  })
}

resource "aws_bedrock_guardrail_version" "external_routing" {
  guardrail_arn = aws_bedrock_guardrail.external_routing.guardrail_arn
  description   = "Initial production version - external routing"
}
