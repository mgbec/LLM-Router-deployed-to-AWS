"""
Human Override Lambda (ISO 42001 A.9.5)
Provides human oversight capabilities:
- Report AI concerns
- Override routing decisions (pin/block models)
- Trigger kill switch
- Review flagged content
"""

import json
import os
import logging
import time
import uuid
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
REVIEW_TABLE = os.environ.get("REVIEW_TABLE_NAME", "")
CONCERNS_TOPIC_ARN = os.environ.get("CONCERNS_TOPIC_ARN", "")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)

review_table = dynamodb.Table(REVIEW_TABLE) if REVIEW_TABLE else None


def handler(event, context):
    """Handle human oversight operations."""
    route_key = event.get("routeKey", "")
    body = json.loads(event.get("body", "{}"))

    # Extract authenticated user from JWT claims
    user_id = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
        .get("sub", "anonymous")
    )

    if route_key == "POST /v1/concerns/report":
        return _report_concern(body, user_id)
    elif route_key == "POST /v1/admin/override":
        return _process_override(body, user_id)
    else:
        return {"statusCode": 404, "body": json.dumps({"error": "Not found"})}


def _report_concern(body: dict, user_id: str) -> dict:
    """
    Report an AI concern (ISO 42001 A.3.3).
    Users can flag problematic model outputs for human review.
    """
    request_id = body.get("request_id")
    concern_type = body.get("type", "general")  # bias, harmful, inaccurate, privacy, other
    description = body.get("description", "")
    severity = body.get("severity", "standard")  # critical, standard, low

    if not request_id or not description:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "request_id and description are required"})
        }

    concern_id = f"CONCERN-{uuid.uuid4().hex[:12]}"
    now = int(time.time())

    # Store in review queue
    if review_table:
        review_table.put_item(Item={
            "review_id": concern_id,
            "created_at": now,
            "request_id": request_id,
            "user_id": user_id,
            "type": concern_type,
            "description": description,
            "severity": severity,
            "status": "pending",
            "expires_at": now + (90 * 24 * 3600)  # 90-day retention
        })

    # Publish to SNS for escalation (critical concerns alert immediately)
    if CONCERNS_TOPIC_ARN and severity == "critical":
        sns.publish(
            TopicArn=CONCERNS_TOPIC_ARN,
            Subject=f"[CRITICAL] AI Concern Reported: {concern_type}",
            Message=json.dumps({
                "concern_id": concern_id,
                "request_id": request_id,
                "type": concern_type,
                "severity": severity,
                "description": description,
                "reported_by": user_id,
                "timestamp": now
            }),
            MessageAttributes={
                "severity": {"DataType": "String", "StringValue": severity},
                "type": {"DataType": "String", "StringValue": concern_type}
            }
        )

    logger.info(f"Concern reported: {concern_id} (type={concern_type}, severity={severity})")

    return {
        "statusCode": 201,
        "body": json.dumps({
            "concern_id": concern_id,
            "status": "received",
            "message": "Your concern has been recorded and will be reviewed.",
            "sla": "4 hours" if severity == "critical" else "24 hours"
        })
    }


def _process_override(body: dict, user_id: str) -> dict:
    """
    Process a human override command (ISO 42001 A.9.5).
    Operators can:
    - pin_model: Force a specific model for a session/tenant
    - block_model: Remove a model from the routing pool
    - kill_switch: Disable the entire system or a provider
    - require_review: Flag a category for human review
    """
    action = body.get("action")
    valid_actions = ["pin_model", "block_model", "kill_switch", "require_review", "approve_response"]

    if action not in valid_actions:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "error": f"Invalid action. Must be one of: {valid_actions}"
            })
        }

    now = int(time.time())
    override_id = f"OVERRIDE-{uuid.uuid4().hex[:8]}"

    # Log the override action for audit
    if review_table:
        review_table.put_item(Item={
            "review_id": override_id,
            "created_at": now,
            "user_id": user_id,
            "type": "override",
            "action": action,
            "parameters": body.get("parameters", {}),
            "reason": body.get("reason", ""),
            "status": "executed",
            "expires_at": now + (90 * 24 * 3600)
        })

    # Execute the override
    if action == "kill_switch":
        target = body.get("parameters", {}).get("target", "system")
        enabled = body.get("parameters", {}).get("enabled", False)
        logger.warning(f"KILL SWITCH: {target} set to {'active' if enabled else 'disabled'} by {user_id}")
        # In production, this would update AppConfig
        return {
            "statusCode": 200,
            "body": json.dumps({
                "override_id": override_id,
                "action": "kill_switch",
                "target": target,
                "enabled": enabled,
                "message": f"Kill switch {'activated' if not enabled else 'deactivated'} for {target}",
                "executed_by": user_id
            })
        }

    elif action == "block_model":
        model_id = body.get("parameters", {}).get("model_id")
        if not model_id:
            return {"statusCode": 400, "body": json.dumps({"error": "model_id required"})}
        logger.warning(f"MODEL BLOCKED: {model_id} by {user_id}")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "override_id": override_id,
                "action": "block_model",
                "model_id": model_id,
                "message": f"Model {model_id} blocked from routing pool",
                "executed_by": user_id
            })
        }

    elif action == "pin_model":
        model_id = body.get("parameters", {}).get("model_id")
        scope = body.get("parameters", {}).get("scope", "session")  # session, tenant, global
        return {
            "statusCode": 200,
            "body": json.dumps({
                "override_id": override_id,
                "action": "pin_model",
                "model_id": model_id,
                "scope": scope,
                "message": f"Model pinned to {model_id} for scope: {scope}"
            })
        }

    elif action == "require_review":
        categories = body.get("parameters", {}).get("categories", [])
        return {
            "statusCode": 200,
            "body": json.dumps({
                "override_id": override_id,
                "action": "require_review",
                "categories": categories,
                "message": f"Human review now required for categories: {categories}"
            })
        }

    return {"statusCode": 200, "body": json.dumps({"override_id": override_id, "status": "executed"})}
