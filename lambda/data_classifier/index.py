"""
Data Classification Engine (ISO 42001 A.7.5, A.7.6)
Scans prompts for sensitive data and enforces data residency rules.
Blocks PII and regulated content from being routed to external providers.
"""

import json
import os
import logging
import time
import re
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
GUARDRAIL_ID = os.environ.get("GUARDRAIL_ID", "")
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "DRAFT")
DATA_FLOW_LOG_TABLE = os.environ.get("DATA_FLOW_LOG_TABLE", "")
BLOCKED_CATEGORIES_EXTERNAL = os.environ.get(
    "BLOCKED_CATEGORIES_EXTERNAL", "pii,financial,health,legal,credentials"
).split(",")

bedrock_runtime = boto3.client("bedrock-runtime", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
flow_log_table = dynamodb.Table(DATA_FLOW_LOG_TABLE) if DATA_FLOW_LOG_TABLE else None

# Quick regex patterns for common sensitive data
SENSITIVE_PATTERNS = {
    "email": re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'),
    "phone_us": re.compile(r'\b(\+1[-.]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b'),
    "ssn": re.compile(r'\b\d{3}-\d{2}-\d{4}\b'),
    "credit_card": re.compile(r'\b(?:\d{4}[-\s]?){3}\d{4}\b'),
    "aws_key": re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
    "ip_address": re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
}

# Keywords indicating regulated content domains
DOMAIN_KEYWORDS = {
    "health": ["diagnosis", "symptom", "medication", "patient", "medical record", "health condition"],
    "financial": ["account number", "routing number", "bank account", "investment portfolio", "tax return"],
    "legal": ["attorney-client", "legal privilege", "court case", "lawsuit", "deposition"],
}


def handler(event, context):
    """Classify data sensitivity and enforce routing constraints."""
    try:
        body = event if isinstance(event, dict) else json.loads(event)
        prompt = body.get("prompt", "")
        target_provider = body.get("target_provider", "bedrock")
        request_id = body.get("request_id", "unknown")

        if not prompt:
            return _response(True, "empty", [], request_id, target_provider)

        # Step 1: Quick regex scan (fast, catches obvious PII)
        detected_patterns = _regex_scan(prompt)

        # Step 2: Domain keyword detection
        detected_domains = _domain_scan(prompt)

        # Step 3: Determine if external routing is allowed
        all_categories = set()
        if detected_patterns:
            all_categories.add("pii")
        all_categories.update(detected_domains)

        # Check if any detected category blocks external routing
        blocked_for_external = any(
            cat in BLOCKED_CATEGORIES_EXTERNAL
            for cat in all_categories
        )

        # For external providers, also use Bedrock Guardrails for deep PII scan
        if target_provider == "external" and GUARDRAIL_ID:
            guardrail_result = _apply_guardrail(prompt)
            if guardrail_result.get("blocked"):
                blocked_for_external = True
                all_categories.add("guardrail_blocked")

        # Determine routing permission
        if target_provider == "external" and blocked_for_external:
            routing_allowed = False
            reason = f"Data contains sensitive categories ({', '.join(all_categories)}) that cannot be sent to external providers"
        elif target_provider in ("bedrock", "sagemaker"):
            routing_allowed = True
            reason = "Internal provider - all data categories allowed"
        else:
            routing_allowed = not blocked_for_external
            reason = "No sensitive data detected" if routing_allowed else f"Blocked: {', '.join(all_categories)}"

        # Log the classification decision (A.7.6 provenance)
        _log_decision(request_id, target_provider, routing_allowed, list(all_categories), detected_patterns)

        return _response(routing_allowed, reason, list(all_categories), request_id, target_provider)

    except Exception as e:
        logger.error(f"Data classification error: {e}", exc_info=True)
        # Fail closed - block external routing on error
        return _response(
            False,
            "Classification error - defaulting to block external routing",
            ["error"],
            body.get("request_id", "unknown"),
            body.get("target_provider", "unknown")
        )


def _regex_scan(text: str) -> list:
    """Quick regex scan for common PII patterns."""
    found = []
    for pattern_name, regex in SENSITIVE_PATTERNS.items():
        if regex.search(text):
            found.append(pattern_name)
    return found


def _domain_scan(text: str) -> list:
    """Detect regulated content domains via keyword matching."""
    text_lower = text.lower()
    detected = []
    for domain, keywords in DOMAIN_KEYWORDS.items():
        if any(kw in text_lower for kw in keywords):
            detected.append(domain)
    return detected


def _apply_guardrail(prompt: str) -> dict:
    """Use Bedrock Guardrails for deep PII detection."""
    try:
        response = bedrock_runtime.apply_guardrail(
            guardrailIdentifier=GUARDRAIL_ID,
            guardrailVersion=GUARDRAIL_VERSION,
            source="INPUT",
            content=[{"text": {"text": prompt}}]
        )

        action = response.get("action", "NONE")
        return {
            "blocked": action == "GUARDRAIL_INTERVENED",
            "action": action,
            "assessments": response.get("assessments", [])
        }

    except Exception as e:
        logger.warning(f"Guardrail check failed: {e}")
        # Fail closed
        return {"blocked": True, "action": "ERROR", "assessments": []}


def _log_decision(request_id: str, provider: str, allowed: bool, categories: list, patterns: list):
    """Log the data classification decision for audit (A.7.6)."""
    if not flow_log_table:
        return

    now = int(time.time())
    try:
        flow_log_table.put_item(Item={
            "request_id": request_id,
            "timestamp": now,
            "target_provider": provider,
            "routing_allowed": allowed,
            "detected_categories": categories,
            "detected_patterns": patterns,
            "decision": "allowed" if allowed else "blocked",
            "expires_at": now + (90 * 24 * 3600)  # 90-day retention
        })
    except Exception as e:
        logger.warning(f"Failed to log data flow decision: {e}")


def _response(allowed: bool, reason: str, categories: list, request_id: str, provider: str) -> dict:
    """Format classification response."""
    return {
        "statusCode": 200,
        "body": json.dumps({
            "routing_allowed": allowed,
            "reason": reason,
            "detected_categories": categories,
            "target_provider": provider,
            "request_id": request_id,
            "recommendation": (
                "Route to internal provider (Bedrock/SageMaker)"
                if not allowed else
                f"Routing to {provider} is permitted"
            )
        })
    }
