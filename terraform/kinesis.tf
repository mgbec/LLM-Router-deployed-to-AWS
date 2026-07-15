# =============================================================================
# Kinesis Data Stream - Routing Events Pipeline
# =============================================================================

resource "aws_kinesis_stream" "routing_events" {
  name             = "${local.name_prefix}-routing-events"
  shard_count      = var.environment == "prod" ? 4 : 2
  retention_period = 24 # hours

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  tags = local.common_tags
}
