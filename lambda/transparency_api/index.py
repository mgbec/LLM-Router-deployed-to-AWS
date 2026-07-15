"""
Transparency API Lambda (ISO 42001 A.8)
Provides:
- Routing decision explanations (A.8.3)
- User audit log access (A.8.4)
- Model information/cards (A.8.2)
"""

import json
import os
import logging
import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
AUDIT_LOG_TABLE = os.environ.get("AUDIT_LOG_TABLE", "")
POLICY_TABLE = os.environ.get("POLICY_TABLE", "")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
audit_table = dynamodb.Table(AUDIT_LOG_TABLE) if AUDIT_LOG_TABLE else None
policy_table = dynamodb.Table(POLICY_TABLE) if POLICY_TABLE else None

# Model information for transparency (ISO 42001 A.8.2)
MODEL_INFO = {
    "amazon.nova-lite-v1:0": {
        "display_name": "Amazon Nova Lite",
        "provider": "Amazon Web Services",
        "tier": "simple",
        "description": "Fast, cost-efficient model for simple tasks and classification",
        "capabilities": ["Text generation", "Classification", "Simple Q&A"],
        "limitations": [
            "Limited reasoning depth",
            "May not handle complex multi-step tasks well",
            "Best for straightforward queries"
        ],
        "data_residency": "AWS region where Bedrock is invoked",
        "model_card_url": "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nova-lite.html"
    },
    "amazon.nova-pro-v1:0": {
        "display_name": "Amazon Nova Pro",
        "provider": "Amazon Web Services",
        "tier": "moderate",
        "description": "Balanced model for general-purpose tasks requiring moderate reasoning",
        "capabilities": ["Multi-step reasoning", "Code generation", "Summarization", "Analysis"],
        "limitations": [
            "May hallucinate on niche topics",
            "Not suitable for frontier-level reasoning tasks"
        ],
        "data_residency": "AWS region where Bedrock is invoked",
        "model_card_url": "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nova-pro.html"
    },
    "anthropic.claude-sonnet-4-20250514-v1:0": {
        "display_name": "Claude Sonnet 4",
        "provider": "Anthropic (via Amazon Bedrock)",
        "tier": "moderate",
        "description": "Strong reasoning model with good balance of capability and speed",
        "capabilities": ["Complex reasoning", "Code generation", "Creative writing", "Analysis"],
        "limitations": [
            "May refuse edge-case requests conservatively",
            "Higher cost than Nova models"
        ],
        "data_residency": "AWS region where Bedrock is invoked (data does not leave AWS)",
        "model_card_url": "https://docs.anthropic.com/en/docs/about-claude/models"
    },
    "anthropic.claude-opus-4-20250514-v1:0": {
        "display_name": "Claude Opus 4",
        "provider": "Anthropic (via Amazon Bedrock)",
        "tier": "complex",
        "description": "Frontier-level model for the most complex tasks",
        "capabilities": ["Advanced reasoning", "Complex analysis", "Nuanced writing", "Research"],
        "limitations": [
            "Highest latency in the pool",
            "Most expensive option",
            "Used only when other models cannot meet quality threshold"
        ],
        "data_residency": "AWS region where Bedrock is invoked (data does not leave AWS)",
        "model_card_url": "https://docs.anthropic.com/en/docs/about-claude/models"
    }
}


def handler(event, context):
    """Handle transparency API requests."""
    route_key = event.get("routeKey", "")
    path_params = event.get("pathParameters", {}) or {}

    # Extract user from JWT
    user_id = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
        .get("sub", "anonymous")
    )

    if route_key.startswith("GET /v1/routing/explain/"):
        request_id = path_params.get("requestId", "")
        return _explain_routing(request_id, user_id)
    elif route_key == "GET /v1/audit/my-requests":
        query_params = event.get("queryStringParameters", {}) or {}
        return _user_audit_log(user_id, query_params)
    elif route_key == "GET /v1/models/info":
        return _model_cards()
    else:
        return {"statusCode": 404, "body": json.dumps({"error": "Not found"})}


def _explain_routing(request_id: str, user_id: str) -> dict:
    """
    Explain why a specific routing decision was made (ISO 42001 A.8.3).
    Returns the factors that influenced model selection.
    """
    if not request_id:
        return {"statusCode": 400, "body": json.dumps({"error": "requestId is required"})}

    if not audit_table:
        return {"statusCode": 503, "body": json.dumps({"error": "Audit log not available"})}

    try:
        response = audit_table.query(
            KeyConditionExpression=Key("request_id").eq(request_id),
            Limit=1
        )
        items = response.get("Items", [])

        if not items:
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "Request not found in audit log"})
            }

        record = items[0]

        # Only allow users to see their own requests (unless admin)
        if record.get("user_id") != user_id:
            return {
                "statusCode": 403,
                "body": json.dumps({"error": "You can only view your own routing decisions"})
            }

        explanation = {
            "request_id": request_id,
            "timestamp": record.get("timestamp"),
            "routing_decision": {
                "model_selected": record.get("model_id"),
                "provider": record.get("provider"),
                "complexity_classification": record.get("complexity"),
                "classification_method": record.get("classification_method"),
            },
            "factors": {
                "policy_applied": record.get("policy_id", "default"),
                "max_cost_budget": record.get("max_cost"),
                "quality_threshold": record.get("quality_threshold"),
                "available_models": record.get("candidates_considered", []),
                "model_scores": record.get("model_scores", {}),
            },
            "outcome": {
                "latency_ms": record.get("latency_ms"),
                "estimated_cost": record.get("cost"),
                "quality_score": record.get("quality_score"),
                "escalated": record.get("escalated", False),
                "guardrail_triggered": record.get("guardrail_triggered", False),
            },
            "explanation": _generate_explanation(record),
            "disclosure": "This response was generated by an AI model dynamically selected by the LLM Router system. Model selection is based on request complexity, cost policies, and quality requirements."
        }

        return {
            "statusCode": 200,
            "body": json.dumps(explanation, default=str)
        }

    except Exception as e:
        logger.error(f"Error retrieving routing explanation: {e}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal error"})}


def _user_audit_log(user_id: str, query_params: dict) -> dict:
    """
    Return the user's routing history (ISO 42001 A.8.4).
    Users can see which models served their requests.
    """
    if not audit_table:
        return {"statusCode": 503, "body": json.dumps({"error": "Audit log not available"})}

    limit = min(int(query_params.get("limit", "50")), 100)

    try:
        response = audit_table.query(
            IndexName="user-index",
            KeyConditionExpression=Key("user_id").eq(user_id),
            ScanIndexForward=False,  # Most recent first
            Limit=limit
        )

        items = response.get("Items", [])

        audit_entries = []
        for item in items:
            audit_entries.append({
                "request_id": item.get("request_id"),
                "timestamp": item.get("timestamp"),
                "model_used": item.get("model_id"),
                "provider": item.get("provider"),
                "complexity": item.get("complexity"),
                "latency_ms": item.get("latency_ms"),
                "escalated": item.get("escalated", False),
            })

        return {
            "statusCode": 200,
            "body": json.dumps({
                "user_id": user_id,
                "total_returned": len(audit_entries),
                "entries": audit_entries,
                "disclosure": "This log shows which AI models processed your requests. Model selection is automated based on request complexity and system policies."
            }, default=str)
        }

    except Exception as e:
        logger.error(f"Error retrieving user audit log: {e}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal error"})}


def _model_cards() -> dict:
    """
    Return model information cards (ISO 42001 A.8.2, A.6.2.9).
    Informs users about the models that may process their requests.
    """
    return {
        "statusCode": 200,
        "body": json.dumps({
            "models": MODEL_INFO,
            "routing_disclosure": "The LLM Router dynamically selects which model processes your request based on complexity, cost, and quality policies. You can check which model was used via the X-AI-Model response header or the /v1/audit/my-requests endpoint.",
            "total_models_in_pool": len(MODEL_INFO),
            "data_governance": {
                "bedrock_models": "Your data stays within the AWS region. Models accessed via Bedrock do not retain your prompts.",
                "external_models": "If enabled, external models (OpenAI, etc.) process data outside AWS. PII is blocked from external routing by guardrails."
            }
        })
    }


def _generate_explanation(record: dict) -> str:
    """Generate a human-readable explanation of the routing decision."""
    model = record.get("model_id", "unknown")
    complexity = record.get("complexity", "unknown")
    policy = record.get("policy_id", "default")

    explanation_parts = [
        f"Your request was classified as '{complexity}' complexity.",
        f"Under the '{policy}' routing policy,",
    ]

    if record.get("escalated"):
        explanation_parts.append(
            f"the initial model's confidence was below threshold, so the request was escalated to {model}."
        )
    else:
        explanation_parts.append(
            f"{model} was selected as the optimal model for this complexity level."
        )

    if record.get("guardrail_triggered"):
        explanation_parts.append(
            "Note: Content guardrails were triggered during processing."
        )

    return " ".join(explanation_parts)
