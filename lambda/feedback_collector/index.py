"""
Feedback Collector Lambda
Records routing decision quality metrics into DynamoDB for adaptive weight adjustment.
"""

import json
import os
import logging
import time
import boto3
from decimal import Decimal

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
METRICS_TABLE = os.environ.get("METRICS_TABLE_NAME", "")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
table = dynamodb.Table(METRICS_TABLE) if METRICS_TABLE else None


def handler(event, context):
    """Lambda handler for recording routing feedback."""
    logger.info(f"Feedback received")

    try:
        body = event if isinstance(event, dict) else json.loads(event)
        request_id = body.get("request_id")
        model_id = body.get("model_id")
        latency_ms = body.get("latency_ms")

        if not all([request_id, model_id, latency_ms]):
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Missing required fields: request_id, model_id, latency_ms"})
            }

        now = int(time.time())
        ttl = now + (7 * 24 * 3600)  # 7 day retention

        item = {
            "model_id": model_id,
            "timestamp": now,
            "request_id": request_id,
            "latency_ms": Decimal(str(latency_ms)),
            "quality_score": Decimal(str(body.get("quality_score", 0.0))),
            "cost": Decimal(str(body.get("cost", 0.0))),
            "escalated": body.get("escalated", False),
            "complexity": body.get("complexity", "unknown"),
            "provider": body.get("provider", "unknown"),
            "expires_at": ttl
        }

        if table:
            table.put_item(Item=item)
            logger.info(f"Recorded feedback for request {request_id}, model {model_id}")
        else:
            logger.warning("No metrics table configured, feedback not persisted")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "recorded",
                "request_id": request_id,
                "model_id": model_id
            })
        }

    except Exception as e:
        logger.error(f"Feedback recording error: {str(e)}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
