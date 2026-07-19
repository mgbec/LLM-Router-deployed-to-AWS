"""
API Proxy Lambda
Proxies API Gateway requests to AgentCore Runtime.
Supports both synchronous (fast models) and asynchronous (Opus, complex) modes.
Translates between the OpenAI-compatible API format and AgentCore invocation.
"""

import json
import os
import logging
import uuid
import time
from decimal import Decimal
import boto3

logger = logging.getLogger()


class DecimalEncoder(json.JSONEncoder):
    """Handle DynamoDB Decimal types in JSON serialization."""
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
AGENTCORE_RUNTIME_ARN = os.environ.get("AGENTCORE_RUNTIME_ARN", "")
ASYNC_PROCESSOR_ARN = os.environ.get("ASYNC_PROCESSOR_ARN", "")
REQUESTS_TABLE = os.environ.get("REQUESTS_TABLE", "")

agentcore = boto3.client("bedrock-agentcore", region_name=REGION)
lambda_client = boto3.client("lambda", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
requests_table = dynamodb.Table(REQUESTS_TABLE) if REQUESTS_TABLE else None


def handler(event, context):
    """Lambda handler - proxies requests to AgentCore Runtime."""
    logger.info(f"Request: {event.get('routeKey', 'unknown')}")

    route_key = event.get("routeKey", "")

    if route_key == "GET /health":
        return _health_response()

    if route_key == "GET /v1/routing/status":
        return _routing_status()

    if route_key == "POST /v1/chat/completions":
        return _chat_completions(event)

    if route_key.startswith("GET /v1/requests/"):
        return _poll_request(event)

    return {
        "statusCode": 404,
        "body": json.dumps({"error": "Not found"})
    }


def _poll_request(event: dict) -> dict:
    """Poll for async request result."""
    request_id = event.get("pathParameters", {}).get("requestId", "")

    if not request_id:
        return {"statusCode": 400, "body": json.dumps({"error": "requestId required"})}

    if not requests_table:
        return {"statusCode": 503, "body": json.dumps({"error": "Async processing not configured"})}

    try:
        response = requests_table.get_item(Key={"request_id": request_id})
        item = response.get("Item")

        if not item:
            return {"statusCode": 404, "body": json.dumps({"error": "Request not found"})}

        status = item.get("status", "unknown")

        if status == "completed":
            result = item.get("result", {})
            return {
                "statusCode": 200,
                "headers": {
                    "Content-Type": "application/json",
                    "X-AI-Model": str(result.get("model_id", "unknown")),
                    "X-AI-Routed": "true",
                },
                "body": json.dumps({
                    "id": f"chatcmpl-{request_id}",
                    "object": "chat.completion",
                    "created": item.get("completed_at", 0),
                    "model": result.get("model_id", "routed"),
                    "status": "completed",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": result.get("content", result.get("response", ""))
                        },
                        "finish_reason": result.get("stop_reason", "stop")
                    }],
                    "usage": {
                        "prompt_tokens": result.get("input_tokens", 0),
                        "completion_tokens": result.get("output_tokens", 0),
                        "total_tokens": result.get("input_tokens", 0) + result.get("output_tokens", 0)
                    },
                    "routing": {
                        "complexity": result.get("complexity"),
                        "model_selected": result.get("model_id"),
                        "provider": result.get("provider"),
                        "latency_ms": result.get("latency_ms"),
                        "escalated": result.get("escalated", False),
                    }
                }, cls=DecimalEncoder)
            }
        elif status == "failed":
            return {
                "statusCode": 200,
                "body": json.dumps({
                    "id": f"chatcmpl-{request_id}",
                    "status": "failed",
                    "error": item.get("error_detail", "Unknown error")
                }, cls=DecimalEncoder)
            }
        else:
            # Still processing
            return {
                "statusCode": 202,
                "body": json.dumps({
                    "id": f"chatcmpl-{request_id}",
                    "status": status,
                    "message": "Request is still being processed. Poll again shortly.",
                    "created_at": item.get("created_at", 0),
                    "started_at": item.get("started_at", 0)
                }, cls=DecimalEncoder)
            }

    except Exception as e:
        logger.error(f"Poll error: {e}")
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}


def _chat_completions(event: dict) -> dict:
    """Handle chat completions - forward to AgentCore Runtime."""
    try:
        try:
            body = json.loads(event.get("body", "{}"))
        except (json.JSONDecodeError, TypeError):
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Invalid JSON in request body"})
            }

        messages = body.get("messages", [])
        routing_hints = body.get("routing", {})
        request_id = event.get("headers", {}).get("x-request-id", str(uuid.uuid4()))

        # Extract user_id from JWT claims (Cognito sub)
        user_id = (
            event.get("requestContext", {})
            .get("authorizer", {})
            .get("jwt", {})
            .get("claims", {})
            .get("sub", "anonymous")
        )

        if not messages:
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Missing required field: messages"})
            }

        # Build payload for AgentCore Runtime
        payload = {
            "prompt": messages[-1].get("content", "") if messages else "",
            "messages": messages,
            "routing": routing_hints,
            "request_id": request_id,
            "user_id": user_id,
        }

        # Determine if this should be async:
        # - Client explicitly requests async, OR
        # - Complexity is "complex" (would need Opus, which is too slow for sync)
        use_async = routing_hints.get("async", False)

        if not use_async and ASYNC_PROCESSOR_ARN and requests_table:
            # Quick complexity check to auto-detect async need
            prompt_text = messages[-1].get("content", "") if messages else ""
            if _should_use_async(prompt_text):
                use_async = True

        # If async mode, dispatch to async processor
        if use_async and ASYNC_PROCESSOR_ARN and requests_table:
            return _dispatch_async(request_id, payload, routing_hints)

        # Generate a unique session ID for stateless requests,
        # or use the one provided for multi-turn conversations
        session_id = (
            event.get("headers", {}).get("x-session-id")
            or f"session-{request_id}-{'0' * 20}"  # pad to 33+ chars
        )

        # Synchronous: Invoke AgentCore Runtime
        response = agentcore.invoke_agent_runtime(
            agentRuntimeArn=AGENTCORE_RUNTIME_ARN,
            runtimeSessionId=session_id,
            payload=json.dumps(payload).encode("utf-8")
        )

        # Read response from StreamingBody (key is 'response', not 'body')
        response_body = ""
        if "response" in response:
            body_obj = response["response"]
            if hasattr(body_obj, "read"):
                response_body = body_obj.read().decode("utf-8")
            elif isinstance(body_obj, bytes):
                response_body = body_obj.decode("utf-8")
            elif isinstance(body_obj, str):
                response_body = body_obj

        logger.info(f"Response body (first 500): {response_body[:500]}")

        # Parse agent response
        try:
            agent_response = json.loads(response_body)
        except json.JSONDecodeError:
            agent_response = {"content": response_body}

        # Format as OpenAI-compatible response
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "X-Request-Id": request_id,
                "X-AI-Model": agent_response.get("model_id", "unknown"),
                "X-AI-Provider": agent_response.get("provider", "unknown"),
                "X-AI-Routed": "true",
                "X-AI-Complexity": agent_response.get("complexity", "unknown"),
                "X-AI-Disclosure": "Response generated by dynamically-selected AI model. See /v1/models/info for details."
            },
            "body": json.dumps({
                "id": f"chatcmpl-{request_id}",
                "object": "chat.completion",
                "created": int(__import__("time").time()),
                "model": agent_response.get("model_id", "routed"),
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": agent_response.get("content", agent_response.get("response", ""))
                        },
                        "finish_reason": agent_response.get("stop_reason", "stop")
                    }
                ],
                "usage": {
                    "prompt_tokens": agent_response.get("input_tokens", 0),
                    "completion_tokens": agent_response.get("output_tokens", 0),
                    "total_tokens": (
                        agent_response.get("input_tokens", 0) +
                        agent_response.get("output_tokens", 0)
                    )
                },
                "routing": {
                    "complexity": agent_response.get("complexity"),
                    "model_selected": agent_response.get("model_id"),
                    "provider": agent_response.get("provider"),
                    "latency_ms": agent_response.get("latency_ms"),
                    "escalated": agent_response.get("escalated", False)
                }
            })
        }

    except Exception as e:
        logger.error(f"Chat completions error: {str(e)}", exc_info=True)
        return {
            "statusCode": 502,
            "body": json.dumps({
                "error": {
                    "message": "Failed to process request through LLM router",
                    "type": "router_error",
                    "details": str(e)
                }
            })
        }


def _should_use_async(prompt: str) -> bool:
    """
    Determine if a request should be processed asynchronously.
    Uses heuristics to detect complex prompts that would benefit from Opus
    and exceed the API Gateway 29s timeout.
    """
    if not prompt:
        return False

    words = prompt.split()
    word_count = len(words)

    # Short prompts are always sync
    if word_count < 20:
        return False

    # Indicators of complex reasoning that would route to Opus
    complex_indicators = [
        "design", "architect", "prove", "derive", "implement from scratch",
        "distributed", "algorithm", "formal verification", "mathematical proof",
        "comprehensive analysis", "systematic evaluation", "trade-offs",
        "compare and contrast in detail", "write a complete",
        "pseudocode", "step by step solution"
    ]

    prompt_lower = prompt.lower()
    indicator_count = sum(1 for ind in complex_indicators if ind in prompt_lower)

    # Multiple complexity indicators + moderate-length prompt = async
    if indicator_count >= 2 and word_count > 20:
        return True

    # Very long prompts with technical keywords
    if word_count > 50 and indicator_count >= 1:
        return True

    return False


def _dispatch_async(request_id: str, payload: dict, routing_hints: dict) -> dict:
    """Dispatch a request for async processing (long-running models like Opus)."""
    now = int(time.time())

    # Store the pending request in DynamoDB
    requests_table.put_item(Item={
        "request_id": request_id,
        "status": "pending",
        "created_at": now,
        "payload": payload,
        "routing_hints": routing_hints,
        "expires_at": now + (24 * 3600)  # 24 hour TTL
    })

    # Invoke the async processor Lambda (fire-and-forget)
    session_id = f"async-{request_id}-{'0' * 20}"
    lambda_client.invoke(
        FunctionName=ASYNC_PROCESSOR_ARN,
        InvocationType="Event",  # Async invocation
        Payload=json.dumps({
            "request_id": request_id,
            "payload": payload,
            "session_id": session_id
        }).encode("utf-8")
    )

    # Return 202 Accepted with polling URL
    return {
        "statusCode": 202,
        "headers": {
            "Content-Type": "application/json",
            "X-Request-Id": request_id,
        },
        "body": json.dumps({
            "id": f"chatcmpl-{request_id}",
            "status": "pending",
            "message": "Request accepted for async processing. Poll for results.",
            "poll_url": f"/v1/requests/{request_id}",
            "request_id": request_id,
            "created_at": now
        })
    }


def _health_response() -> dict:
    """Health check endpoint."""
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "healthy",
            "service": "llm-router",
            "runtime_arn": AGENTCORE_RUNTIME_ARN
        })
    }


def _routing_status() -> dict:
    """Return current routing status (model availability, circuit breakers)."""
    # In production, this would query AppConfig and DynamoDB
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "operational",
            "models": {
                "amazon.nova-lite-v1:0": {"status": "available", "provider": "bedrock"},
                "amazon.nova-pro-v1:0": {"status": "available", "provider": "bedrock"},
                "anthropic.claude-sonnet-4-20250514-v1:0": {"status": "available", "provider": "bedrock"},
                "anthropic.claude-opus-4-20250514-v1:0": {"status": "available", "provider": "bedrock"},
            }
        })
    }
