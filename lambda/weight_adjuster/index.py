"""
Weight Adjuster Lambda (Kinesis Consumer)
Processes routing events from Kinesis and adjusts model weights based on
observed performance (latency, quality, cost, error rates).
"""

import json
import os
import logging
import base64
import time
from decimal import Decimal
from collections import defaultdict
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
POLICY_TABLE = os.environ.get("POLICY_TABLE_NAME", "")
METRICS_TABLE = os.environ.get("METRICS_TABLE_NAME", "")
METRICS_NAMESPACE = os.environ.get("METRICS_NAMESPACE", "LLMRouter/dev")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
cloudwatch = boto3.client("cloudwatch", region_name=REGION)

policy_table = dynamodb.Table(POLICY_TABLE) if POLICY_TABLE else None
metrics_table = dynamodb.Table(METRICS_TABLE) if METRICS_TABLE else None

# Weight adjustment parameters
LEARNING_RATE = 0.05
MIN_WEIGHT = 0.1
MAX_WEIGHT = 2.0
ERROR_PENALTY = 0.2
LATENCY_PENALTY_THRESHOLD_MS = 5000


def handler(event, context):
    """Process Kinesis records and adjust model weights."""
    records = event.get("Records", [])
    logger.info(f"Processing {len(records)} Kinesis records")

    # Aggregate metrics by model
    model_metrics = defaultdict(lambda: {
        "total_requests": 0,
        "total_latency": 0,
        "total_cost": 0,
        "total_quality": 0,
        "errors": 0,
        "escalations": 0
    })

    for record in records:
        try:
            payload = json.loads(base64.b64decode(record["kinesis"]["data"]))
            model_id = payload.get("model_id", "unknown")

            metrics = model_metrics[model_id]
            metrics["total_requests"] += 1
            metrics["total_latency"] += payload.get("latency_ms", 0)
            metrics["total_cost"] += payload.get("cost", 0)
            metrics["total_quality"] += payload.get("quality_score", 0)

            if payload.get("error"):
                metrics["errors"] += 1
            if payload.get("escalated"):
                metrics["escalations"] += 1

        except Exception as e:
            logger.warning(f"Failed to parse record: {e}")
            continue

    # Publish CloudWatch metrics
    _publish_metrics(model_metrics)

    # Adjust weights based on observed performance
    _adjust_weights(model_metrics)

    return {"statusCode": 200, "processed": len(records)}


def _publish_metrics(model_metrics: dict):
    """Publish aggregated metrics to CloudWatch."""
    metric_data = []

    for model_id, metrics in model_metrics.items():
        if metrics["total_requests"] == 0:
            continue

        avg_latency = metrics["total_latency"] / metrics["total_requests"]
        avg_quality = metrics["total_quality"] / metrics["total_requests"]
        error_rate = metrics["errors"] / metrics["total_requests"]

        metric_data.extend([
            {
                "MetricName": "RequestCount",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": metrics["total_requests"],
                "Unit": "Count"
            },
            {
                "MetricName": "RoutingLatency",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": avg_latency,
                "Unit": "Milliseconds"
            },
            {
                "MetricName": "RequestCost",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": metrics["total_cost"],
                "Unit": "None"
            },
            {
                "MetricName": "QualityScore",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": avg_quality,
                "Unit": "None"
            },
            {
                "MetricName": "ErrorRate",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": error_rate,
                "Unit": "None"
            },
            {
                "MetricName": "EscalationCount",
                "Dimensions": [{"Name": "ModelId", "Value": model_id}],
                "Value": metrics["escalations"],
                "Unit": "Count"
            }
        ])

    # CloudWatch accepts max 1000 metrics per call
    for i in range(0, len(metric_data), 20):
        batch = metric_data[i:i+20]
        try:
            cloudwatch.put_metric_data(
                Namespace=METRICS_NAMESPACE,
                MetricData=batch
            )
        except Exception as e:
            logger.error(f"Failed to publish metrics: {e}")


def _adjust_weights(model_metrics: dict):
    """Adjust model weights in the policy table based on performance."""
    if not policy_table:
        return

    try:
        # Get current default policy
        response = policy_table.get_item(Key={"policy_id": "default"})
        policy = response.get("Item")
        if not policy:
            return

        config = policy.get("config", {})
        model_weights = config.get("model_weights", {})
        updated = False

        for model_id, metrics in model_metrics.items():
            if model_id not in model_weights or metrics["total_requests"] < 5:
                continue

            current_weight = float(model_weights[model_id].get("weight", 1.0))
            avg_latency = metrics["total_latency"] / metrics["total_requests"]
            avg_quality = metrics["total_quality"] / metrics["total_requests"]
            error_rate = metrics["errors"] / metrics["total_requests"]

            # Calculate weight adjustment
            adjustment = 0.0

            # Penalize high error rates
            if error_rate > 0.1:
                adjustment -= ERROR_PENALTY * error_rate

            # Penalize high latency
            if avg_latency > LATENCY_PENALTY_THRESHOLD_MS:
                latency_factor = (avg_latency - LATENCY_PENALTY_THRESHOLD_MS) / LATENCY_PENALTY_THRESHOLD_MS
                adjustment -= LEARNING_RATE * min(latency_factor, 1.0)

            # Reward high quality
            if avg_quality > 0.8:
                adjustment += LEARNING_RATE * (avg_quality - 0.8)

            # Apply adjustment with bounds
            new_weight = max(MIN_WEIGHT, min(MAX_WEIGHT, current_weight + adjustment))

            if abs(new_weight - current_weight) > 0.01:
                model_weights[model_id]["weight"] = Decimal(str(round(new_weight, 3)))
                updated = True
                logger.info(f"Weight adjusted for {model_id}: {current_weight:.3f} -> {new_weight:.3f}")

        if updated:
            config["model_weights"] = model_weights
            policy_table.update_item(
                Key={"policy_id": "default"},
                UpdateExpression="SET config = :config",
                ExpressionAttributeValues={":config": config}
            )
            logger.info("Policy weights updated successfully")

    except Exception as e:
        logger.error(f"Weight adjustment error: {e}", exc_info=True)
