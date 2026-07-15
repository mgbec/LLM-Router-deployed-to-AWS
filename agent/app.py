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
from strands import Agent, tool
from strands.models import BedrockModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
REGION = os.environ.get("REGION", "us-east-1")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
CLASSIFIER_MODEL_ID = os.environ.get("CLASSIFIER_MODEL_ID", "amazon.nova-lite-v1:0")
DEFAULT_FALLBACK_MODEL = os.environ.get("DEFAULT_FALLBACK_MODEL", "anthropic.claude-sonnet-4-20250514-v1:0")
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
    "amazon.nova-lite-v1:0": 0.00006,
    "amazon.nova-pro-v1:0": 0.0008,
    "anthropic.claude-haiku-4-20250514-v1:0": 0.0008,
    "anthropic.claude-sonnet-4-20250514-v1:0": 0.003,
    "anthropic.claude-opus-4-20250514-v1:0": 0.015,
    "meta.llama4-maverick-17b-instruct-v1:0": 0.0002,
    "mistral.mistral-large-2411-v1:0": 0.002,
}

# Model tier mapping
MODEL_TIERS = {
    "simple": [
        "amazon.nova-lite-v1:0",
        "meta.llama4-maverick-17b-instruct-v1:0",
    ],
    "moderate": [
        "amazon.nova-pro-v1:0",
        "anthropic.claude-sonnet-4-20250514-v1:0",
        "mistral.mistral-large-2411-v1:0",
    ],
    "complex": [
        "anthropic.claude-opus-4-20250514-v1:0",
    ],
    "specialized": [
        "anthropic.claude-sonnet-4-20250514-v1:0",
    ],
}

# Circuit breaker state
circuit_breakers: dict[str, dict] = {}
FAILURE_THRESHOLD = 3
RECOVERY_TIMEOUT_S = 60


# =============================================================================
# Routing Tools
# =============================================================================

@tool
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


@tool
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


@tool
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


@tool
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
        "fallback_chain": [DEFAULT_FALLBACK_MODEL, "amazon.nova-pro-v1:0", "amazon.nova-lite-v1:0"],
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
# Agent Definition
# =============================================================================

router_agent = Agent(
    model=BedrockModel(model_id=CLASSIFIER_MODEL_ID, region_name=REGION),
    tools=[classify_complexity, select_model, invoke_selected_model, emit_routing_event],
    system_prompt="""You are an LLM Router Agent. Your job is to:
1. Classify the complexity of incoming user requests
2. Select the optimal model based on complexity, policy constraints, and budget
3. Invoke the selected model with the user's messages
4. Record the routing decision for feedback

For each request:
- First call classify_complexity with the user's prompt
- Then call select_model with the complexity result
- Then call invoke_selected_model with the selected model and the user's messages
- Finally call emit_routing_event with the routing metrics

If a model invocation fails, select the next model in the fallback chain and retry.
Always return the model's response to the user."""
)


# =============================================================================
# HTTP Server (AgentCore Runtime expects HTTP on port 8080)
# =============================================================================

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI(title="LLM Router Agent")


@app.post("/invoke")
async def invoke(request: Request):
    """Main invocation endpoint for AgentCore Runtime."""
    body = await request.json()
    prompt = body.get("prompt", "")
    messages = body.get("messages", [])
    routing_hints = body.get("routing", {})
    request_id = body.get("request_id", "")

    if not prompt and messages:
        prompt = messages[-1].get("content", "")

    try:
        # Run the router agent
        result = router_agent(
            f"""Route this request optimally.
            
Policy: {routing_hints.get('policy', 'default')}
Max cost: {routing_hints.get('max_cost', 'default')}
Preferred provider: {routing_hints.get('prefer_provider', 'any')}

User messages: {json.dumps(messages)}
User prompt: {prompt}"""
        )

        # Parse agent output (the agent returns the model's response)
        return JSONResponse(content={
            "content": str(result),
            "request_id": request_id
        })

    except Exception as e:
        logger.error(f"Agent invocation failed: {e}", exc_info=True)
        # Direct fallback - bypass router and call default model
        try:
            fallback_result = invoke_selected_model(
                model_id=DEFAULT_FALLBACK_MODEL,
                messages=messages or [{"role": "user", "content": prompt}]
            )
            return JSONResponse(content={
                "content": fallback_result.get("response", ""),
                "model_id": DEFAULT_FALLBACK_MODEL,
                "provider": "bedrock",
                "fallback": True,
                "request_id": request_id
            })
        except Exception as fallback_error:
            return JSONResponse(
                status_code=500,
                content={"error": str(fallback_error), "request_id": request_id}
            )


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy", "agent": "llm-router"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
