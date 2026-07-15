# =============================================================================
# Lambda Functions - Router Tools
# =============================================================================

# -----------------------------------------------------------------------------
# Complexity Classifier Lambda
# Classifies incoming prompts by complexity using Nova Lite
# -----------------------------------------------------------------------------

data "archive_file" "complexity_classifier" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/complexity_classifier"
  output_path = "${path.module}/.build/complexity_classifier.zip"
}

resource "aws_lambda_function" "complexity_classifier" {
  function_name = "${local.name_prefix}-complexity-classifier"
  description   = "Classifies prompt complexity for LLM routing decisions"
  role          = aws_iam_role.lambda_classifier.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.complexity_classifier.output_path
  source_code_hash = data.archive_file.complexity_classifier.output_base64sha256

  environment {
    variables = {
      CLASSIFIER_MODEL_ID = "amazon.nova-lite-v1:0"
      REGION              = local.region
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Model Invoker Lambda
# Routes and invokes the selected model (Bedrock, SageMaker, or external)
# -----------------------------------------------------------------------------

data "archive_file" "model_invoker" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/model_invoker"
  output_path = "${path.module}/.build/model_invoker.zip"
}

resource "aws_lambda_function" "model_invoker" {
  function_name = "${local.name_prefix}-model-invoker"
  description   = "Invokes selected model via Bedrock, SageMaker, or external APIs"
  role          = aws_iam_role.lambda_model_invoker.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 120
  memory_size   = 512

  filename         = data.archive_file.model_invoker.output_path
  source_code_hash = data.archive_file.model_invoker.output_base64sha256

  environment {
    variables = {
      REGION                    = local.region
      ENABLE_EXTERNAL_PROVIDERS = tostring(var.enable_external_providers)
      OPENAI_SECRET_ARN         = var.enable_external_providers ? aws_secretsmanager_secret.openai_api_key[0].arn : ""
      SAGEMAKER_ENDPOINT        = var.enable_sagemaker_endpoint ? var.sagemaker_endpoint_name : ""
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Feedback Collector Lambda
# Records routing quality metrics for adaptive weight adjustment
# -----------------------------------------------------------------------------

data "archive_file" "feedback_collector" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/feedback_collector"
  output_path = "${path.module}/.build/feedback_collector.zip"
}

resource "aws_lambda_function" "feedback_collector" {
  function_name = "${local.name_prefix}-feedback-collector"
  description   = "Collects routing decision feedback for adaptive model weight adjustment"
  role          = aws_iam_role.lambda_feedback.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 15
  memory_size   = 128

  filename         = data.archive_file.feedback_collector.output_path
  source_code_hash = data.archive_file.feedback_collector.output_base64sha256

  environment {
    variables = {
      METRICS_TABLE_NAME = aws_dynamodb_table.routing_metrics.name
      REGION             = local.region
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Weight Adjuster Lambda (Kinesis Consumer)
# Processes routing events and adjusts model weights adaptively
# -----------------------------------------------------------------------------

data "archive_file" "weight_adjuster" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/weight_adjuster"
  output_path = "${path.module}/.build/weight_adjuster.zip"
}

resource "aws_lambda_function" "weight_adjuster" {
  function_name = "${local.name_prefix}-weight-adjuster"
  description   = "Processes routing events from Kinesis and adjusts model weights"
  role          = aws_iam_role.lambda_weight_adjuster.arn
  handler       = "index.handler"
  runtime       = "python3.13"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.weight_adjuster.output_path
  source_code_hash = data.archive_file.weight_adjuster.output_base64sha256

  environment {
    variables = {
      POLICY_TABLE_NAME  = aws_dynamodb_table.routing_policies.name
      METRICS_TABLE_NAME = aws_dynamodb_table.routing_metrics.name
      METRICS_NAMESPACE  = "LLMRouter/${var.environment}"
      REGION             = local.region
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# Kinesis trigger for weight adjuster
resource "aws_lambda_event_source_mapping" "weight_adjuster_kinesis" {
  event_source_arn  = aws_kinesis_stream.routing_events.arn
  function_name     = aws_lambda_function.weight_adjuster.arn
  starting_position = "LATEST"
  batch_size        = 100

  maximum_batching_window_in_seconds = 30

  # Process in parallel across shards
  parallelization_factor = 2
}
