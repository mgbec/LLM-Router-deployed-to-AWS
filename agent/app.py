"""
LLM Router Agent - AgentCore Runtime Entry Point
Implements dynamic model selection and provider switching.
"""

import json
import os
import time
import logging
from typing import Any

import boto3

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
REGION = os.environ.get("REGION", "us-east-1")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
CLASSIFIER_MODEL_ID = os.environ.get("CLASSIFIER_MODEL_ID", "us.amazon.nova-lite-v1:0")
DEFAULT_FALLBACK_MODEL = os.environ.get("DEFAULT_FALLBACK_MODEL", "us.anthropic.claude-sonnet-4-6")
POLICY_TABLE = os.environ.get("ROUTING_POLICY_TABLE", "")
METRICS_TABLE = os.environ.get("ROUTING_METRICS_TABLE", "")
KINESIS_STREAM = os.environ.get("KINESIS_STREAM_NAME", "")
APPCONFIG_APP_ID = os.environ.get("APPCONFIG_APP_ID", "")
APPCONFIG_ENV_ID = os.environ.get("APPCONFIG_ENV_ID", "")
APPCONFIG_PROFILE_ID = os.environ.get("APPCONFIG_PROFILE_ID", "")
ENABLE_EXTERNAL = os.environ.get("ENABLE_EXTERNAL_PROVIDERS", "false").lower() == "true"
GUARDRAIL_ID = os.environ.get("GUARDRAIL_ID", "")
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "DRAFT")
AUDIT_LOG_TABLE = os.environ.get("AUDIT_LOG_TABLE", "")
KILL_SWITCH_PROFILE = os.environ.get("KILL_SWITCH_PROFILE", "")

# AWS clients
bedrock = boto3.client("bedrock-runtime", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
kinesis = boto3.client("kinesis", region_name=REGION)
appconfig = boto3.client("appconfigdata", region_name=REGION)
cloudwatch = boto3.client("cloudwatch", region_name=REGION)

# Tables
policy_table = dynamodb.Table(POLICY_TABLE) if POLICY_TABLE else None

# Model cost table (per 1K input tokens)
MODEL_COSTS = {
    "us.amazon.nova-lite-v1:0": 0.00006,
    "us.amazon.nova-pro-v1:0": 0.0008,
    "us.anthropic.claude-haiku-4-5-20251001-v1:0": 0.0008,
    "us.anthropic.claude-sonnet-4-6": 0.003,
    "us.anthropic.claude-opus-4-6-v1": 0.015,
    "us.meta.llama4-maverick-17b-instruct-v1:0": 0.0002,
}

# Model tier mapping
MODEL_TIERS = {
    "simple": [
        "us.amazon.nova-lite-v1:0",
    ],
    "moderate": [
        "us.amazon.nova-pro-v1:0",
        "us.anthropic.claude-sonnet-4-6",
    ],
    "complex": [
        "us.anthropic.claude-opus-4-6-v1",
        "us.anthropic.claude-sonnet-4-6",
    ],
    "specialized": [
        "us.anthropic.claude-sonnet-4-6",
    ],
}

# Circuit breaker state
circuit_breakers: dict[str, dict] = {}
FAILURE_THRESHOLD = 3
RECOVERY_TIMEOUT_S = 60


# =============================================================================
# Routing Tools
# =============================================================================

def classify_complexity(prompt: str) -> dict:
    """Classify the complexity of a user prompt using a fast, cheap model."""
    # Quick heuristic for obvious cases
    quick = _quick_classify(prompt)
    if quick:
        return {"complexity": quick, "method": "heuristic", "latency_ms": 0}

    start = time.time()

    classification_prompt = f"""Classify this prompt's complexity as exactly one of: simple, moderate, complex, specialized.
    
Respond with ONLY the classification word.

Prompt: {prompt[:2000]}

Classification:"""

    response = bedrock.converse(
        modelId=CLASSIFIER_MODEL_ID,
        messages=[{"role": "user", "content": [{"text": classification_prompt}]}],
        inferenceConfig={"maxTokens": 10, "temperature": 0.0}
    )

    output = response["output"]["message"]["content"][0]["text"].strip().lower()
    valid = {"simple", "moderate", "complex", "specialized"}
    complexity = output if output in valid else "moderate"

    latency = (time.time() - start) * 1000
    return {"complexity": complexity, "method": "model", "latency_ms": round(latency, 1)}


def select_model(complexity: str, policy_id: str = "default", max_cost: float = None) -> dict:
    """Select the optimal model based on complexity, policy, and constraints."""
    # Load policy
    policy = _load_policy(policy_id)

    # Get candidate models for this complexity tier
    candidates = MODEL_TIERS.get(complexity, MODEL_TIERS["moderate"])

    # Filter by circuit breaker status
    available = [m for m in candidates if _is_available(m)]
    if not available:
        # Fallback chain
        fallback_chain = policy.get("fallback_chain", [DEFAULT_FALLBACK_MODEL])
        available = [m for m in fallback_chain if _is_available(m)]
        if not available:
            available = [DEFAULT_FALLBACK_MODEL]

    # Apply cost constraint
    budget = max_cost or policy.get("max_cost_per_request", 0.05)
    affordable = [m for m in available if MODEL_COSTS.get(m, 0.01) <= budget]
    if not affordable:
        affordable = available[:1]  # Take cheapest available

    # Score candidates (lower cost + higher weight = better)
    weights = policy.get("model_weights", {})
    scored = []
    for model in affordable:
        cost = MODEL_COSTS.get(model, 0.01)
        weight = float(weights.get(model, {}).get("weight", 1.0))
        score = weight / (cost + 0.0001)  # Higher weight, lower cost = better
        scored.append((model, score, cost))

    scored.sort(key=lambda x: x[1], reverse=True)
    selected = scored[0]

    return {
        "model_id": selected[0],
        "provider": "bedrock",
        "estimated_cost": selected[2],
        "reason": f"Selected for {complexity} complexity (score: {selected[1]:.2f})"
    }


def invoke_selected_model(model_id: str, messages: list, parameters: dict = None) -> dict:
    """Invoke the selected model and return the response."""
    params = parameters or {}
    start = time.time()

    try:
        # Format messages for Bedrock Converse API
        bedrock_messages = []
        system_prompts = []
        for msg in messages:
            if msg.get("role") == "system":
                system_prompts.append({"text": msg["content"]})
            else:
                bedrock_messages.append({
                    "role": msg["role"],
                    "content": [{"text": msg["content"]}]
                })

        request = {
            "modelId": model_id,
            "messages": bedrock_messages,
            "inferenceConfig": {
                "maxTokens": params.get("max_tokens", 4096),
                "temperature": params.get("temperature", 0.7),
            }
        }
        if system_prompts:
            request["system"] = system_prompts

        response = bedrock.converse(**request)

        output = response["output"]["message"]["content"][0]["text"]
        usage = response.get("usage", {})
        latency = (time.time() - start) * 1000

        # Record success
        _record_success(model_id)

        return {
            "response": output,
            "model_id": model_id,
            "provider": "bedrock",
            "latency_ms": round(latency, 2),
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
            "stop_reason": response.get("stopReason", "end_turn"),
            "error": False
        }

    except Exception as e:
        latency = (time.time() - start) * 1000
        _record_failure(model_id)
        logger.error(f"Model invocation failed for {model_id}: {e}")
        return {
            "response": None,
            "model_id": model_id,
            "provider": "bedrock",
            "latency_ms": round(latency, 2),
            "error": True,
            "error_message": str(e)
        }


def emit_routing_event(event_data: dict) -> dict:
    """Emit a routing event to Kinesis for async processing."""
    if not KINESIS_STREAM:
        return {"status": "skipped", "reason": "no stream configured"}

    try:
        kinesis.put_record(
            StreamName=KINESIS_STREAM,
            Data=json.dumps(event_data).encode("utf-8"),
            PartitionKey=event_data.get("model_id", "default")
        )
        return {"status": "emitted"}
    except Exception as e:
        logger.warning(f"Failed to emit routing event: {e}")
        return {"status": "failed", "error": str(e)}


# =============================================================================
# Helper Functions
# =============================================================================

def _quick_classify(prompt: str) -> str | None:
    """Fast heuristic classification."""
    words = prompt.split()
    if len(words) <= 5:
        lower = prompt.lower().strip()
        greetings = {"hi", "hello", "hey", "thanks", "thank you", "bye"}
        if any(lower.startswith(g) for g in greetings):
            return "simple"
    if len(words) <= 3:
        return "simple"
    return None


def _load_policy(policy_id: str) -> dict:
    """Load routing policy from DynamoDB."""
    if not policy_table:
        return _default_policy()

    try:
        response = policy_table.get_item(Key={"policy_id": policy_id})
        item = response.get("Item")
        if item and "config" in item:
            return item["config"]
    except Exception as e:
        logger.warning(f"Failed to load policy {policy_id}: {e}")

    return _default_policy()


def _default_policy() -> dict:
    return {
        "max_cost_per_request": 0.05,
        "max_latency_ms": 3000,
        "quality_threshold": 0.8,
        "fallback_chain": [DEFAULT_FALLBACK_MODEL, "us.amazon.nova-pro-v1:0", "us.amazon.nova-lite-v1:0"],
        "model_weights": {}
    }


def _is_available(model_id: str) -> bool:
    """Check if a model is available (circuit breaker not open)."""
    cb = circuit_breakers.get(model_id, {})
    if cb.get("state") == "open":
        if time.time() > cb.get("recovery_at", 0):
            cb["state"] = "half-open"
            return True
        return False
    return True


def _record_success(model_id: str):
    """Record successful invocation for circuit breaker."""
    if model_id in circuit_breakers:
        circuit_breakers[model_id] = {"state": "closed", "failures": 0}


def _record_failure(model_id: str):
    """Record failed invocation for circuit breaker."""
    cb = circuit_breakers.setdefault(model_id, {"state": "closed", "failures": 0})
    cb["failures"] = cb.get("failures", 0) + 1
    if cb["failures"] >= FAILURE_THRESHOLD:
        cb["state"] = "open"
        cb["recovery_at"] = time.time() + RECOVERY_TIMEOUT_S
        logger.warning(f"Circuit breaker OPEN for {model_id}")


# =============================================================================
# HTTP Server (AgentCore Runtime expects HTTP on port 8080)
# =============================================================================

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI(title="LLM Router Agent")


@app.post("/invocations")
@app.post("/invoke")
async def invoke(request: Request):
    """Main invocation endpoint for AgentCore Runtime."""
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            status_code=400,
            content={"error": "Invalid JSON in request body"}
        )
    
    prompt = body.get("prompt", "")
    messages = body.get("messages", [])
    routing_hints = body.get("routing", {})
    request_id = body.get("request_id", "")

    if not prompt and messages:
        prompt = messages[-1].get("content", "")

    try:
        # Step 1: Classify complexity
        complexity = _quick_classify(prompt)
        classification_method = "heuristic"
        
        if not complexity:
            # Use Nova Lite for classification
            try:
                classification_prompt = f"Classify this prompt's complexity as exactly one of: simple, moderate, complex, specialized. Respond with ONLY the word.\n\nPrompt: {prompt[:2000]}\n\nClassification:"
                cls_response = bedrock.converse(
                    modelId=CLASSIFIER_MODEL_ID,
                    messages=[{"role": "user", "content": [{"text": classification_prompt}]}],
                    inferenceConfig={"maxTokens": 10, "temperature": 0.0}
                )
                raw = cls_response["output"]["message"]["content"][0]["text"].strip().lower()
                valid = {"simple", "moderate", "complex", "specialized"}
                complexity = raw if raw in valid else "moderate"
                classification_method = "model"
            except Exception as cls_err:
                logger.warning(f"Classification failed: {cls_err}, defaulting to moderate")
                complexity = "moderate"
                classification_method = "fallback"

        # Step 2: Select model based on complexity and policy
        policy_id = routing_hints.get("policy", "default")
        policy = _load_policy(policy_id)
        max_cost = routing_hints.get("max_cost") or policy.get("max_cost_per_request", 0.05)
        is_async = routing_hints.get("async", False)
        
        candidates = MODEL_TIERS.get(complexity, MODEL_TIERS["moderate"])
        
        # For sync requests, skip slow models (Opus) to avoid API Gateway timeout
        if not is_async:
            fast_models = [m for m in candidates if "opus" not in m]
            if fast_models:
                candidates = fast_models
        
        available = [m for m in candidates if _is_available(m)]
        if not available:
            available = [DEFAULT_FALLBACK_MODEL]
        
        # Filter by cost
        affordable = [m for m in available if MODEL_COSTS.get(m, 0.01) <= max_cost]
        if not affordable:
            affordable = available[:1]
        
        selected_model = affordable[0]

        # Step 3: Invoke the selected model
        start_time = time.time()
        
        bedrock_messages = []
        system_prompts = []
        for msg in messages:
            if msg.get("role") == "system":
                system_prompts.append({"text": msg["content"]})
            else:
                bedrock_messages.append({
                    "role": msg["role"],
                    "content": [{"text": msg["content"]}]
                })
        
        if not bedrock_messages:
            bedrock_messages = [{"role": "user", "content": [{"text": prompt}]}]

        # Limit tokens for sync requests to avoid timeouts
        # Complex/Opus can use more tokens in async mode
        max_tokens = 2048 if complexity in ("complex", "specialized") else 4096

        invoke_params = {
            "modelId": selected_model,
            "messages": bedrock_messages,
            "inferenceConfig": {"maxTokens": max_tokens, "temperature": 0.7}
        }
        if system_prompts:
            invoke_params["system"] = system_prompts

        response = bedrock.converse(**invoke_params)
        
        output_text = response["output"]["message"]["content"][0]["text"]
        usage = response.get("usage", {})
        latency_ms = (time.time() - start_time) * 1000

        _record_success(selected_model)

        # Step 4: Emit routing event (async, non-blocking)
        try:
            if KINESIS_STREAM:
                kinesis.put_record(
                    StreamName=KINESIS_STREAM,
                    Data=json.dumps({
                        "request_id": request_id,
                        "model_id": selected_model,
                        "complexity": complexity,
                        "latency_ms": round(latency_ms, 2),
                        "policy_id": policy_id,
                        "cost": MODEL_COSTS.get(selected_model, 0),
                    }).encode("utf-8"),
                    PartitionKey=selected_model
                )
        except Exception:
            pass  # Non-critical

        return JSONResponse(content={
            "content": output_text,
            "model_id": selected_model,
            "provider": "bedrock",
            "complexity": complexity,
            "classification_method": classification_method,
            "latency_ms": round(latency_ms, 2),
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
            "stop_reason": response.get("stopReason", "end_turn"),
            "escalated": False,
            "request_id": request_id
        })

    except Exception as e:
        logger.error(f"Router invocation failed: {e}", exc_info=True)
        
        # Fallback: try default model directly
        try:
            fb_messages = [{"role": "user", "content": [{"text": prompt or "hello"}]}]
            fb_response = bedrock.converse(
                modelId=DEFAULT_FALLBACK_MODEL,
                messages=fb_messages,
                inferenceConfig={"maxTokens": 2048, "temperature": 0.7}
            )
            fb_text = fb_response["output"]["message"]["content"][0]["text"]
            return JSONResponse(content={
                "content": fb_text,
                "model_id": DEFAULT_FALLBACK_MODEL,
                "provider": "bedrock",
                "complexity": "unknown",
                "fallback": True,
                "request_id": request_id,
                "error_detail": str(e)
            })
        except Exception as fb_err:
            return JSONResponse(
                status_code=200,
                content={"error": str(fb_err), "original_error": str(e), "request_id": request_id, "content": f"Error: {str(e)}"}
            )


@app.get("/ping")
@app.get("/health")
async def health():
    """Health check endpoint - AgentCore calls /ping."""
    return {"status": "healthy", "agent": "llm-router"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
