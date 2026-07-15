"""
Model Invoker Lambda
Routes and invokes the selected model (Bedrock, SageMaker, or external provider).
Supports streaming and non-streaming invocations.
"""

import json
import os
import logging
import time
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
ENABLE_EXTERNAL = os.environ.get("ENABLE_EXTERNAL_PROVIDERS", "false").lower() == "true"
OPENAI_SECRET_ARN = os.environ.get("OPENAI_SECRET_ARN", "")
SAGEMAKER_ENDPOINT = os.environ.get("SAGEMAKER_ENDPOINT", "")

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
sagemaker = boto3.client("sagemaker-runtime", region_name=REGION) if SAGEMAKER_ENDPOINT else None
secrets_client = boto3.client("secretsmanager", region_name=REGION) if ENABLE_EXTERNAL else None

# Cache for external provider credentials
_openai_key_cache = {"key": None, "expires": 0}


def handler(event, context):
    """Lambda handler for model invocation."""
    logger.info(f"Invocation request received")

    try:
        body = event if isinstance(event, dict) else json.loads(event)
        model_id = body.get("model_id")
        provider = body.get("provider", "bedrock")
        messages = body.get("messages", [])
        parameters = body.get("parameters", {})

        if not model_id or not messages:
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Missing required fields: model_id, messages"})
            }

        start_time = time.time()

        if provider == "bedrock":
            result = _invoke_bedrock(model_id, messages, parameters)
        elif provider == "sagemaker":
            result = _invoke_sagemaker(model_id, messages, parameters)
        elif provider == "external":
            result = _invoke_external(model_id, messages, parameters)
        else:
            return {
                "statusCode": 400,
                "body": json.dumps({"error": f"Unknown provider: {provider}"})
            }

        latency_ms = (time.time() - start_time) * 1000

        return {
            "statusCode": 200,
            "body": json.dumps({
                "response": result["response"],
                "model_id": model_id,
                "provider": provider,
                "latency_ms": round(latency_ms, 2),
                "input_tokens": result.get("input_tokens", 0),
                "output_tokens": result.get("output_tokens", 0),
                "stop_reason": result.get("stop_reason", "end_turn")
            })
        }

    except Exception as e:
        logger.error(f"Model invocation error: {str(e)}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "error": str(e),
                "provider": body.get("provider", "unknown"),
                "model_id": body.get("model_id", "unknown")
            })
        }


def _invoke_bedrock(model_id: str, messages: list, parameters: dict) -> dict:
    """Invoke a model via Amazon Bedrock."""
    inference_config = {
        "maxTokens": parameters.get("max_tokens", 4096),
        "temperature": parameters.get("temperature", 0.7),
    }

    if "top_p" in parameters:
        inference_config["topP"] = parameters["top_p"]

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

    request_params = {
        "modelId": model_id,
        "messages": bedrock_messages,
        "inferenceConfig": inference_config,
    }

    if system_prompts:
        request_params["system"] = system_prompts

    response = bedrock.converse(**request_params)

    output = response["output"]["message"]["content"][0]["text"]
    usage = response.get("usage", {})

    return {
        "response": output,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "stop_reason": response.get("stopReason", "end_turn")
    }


def _invoke_sagemaker(model_id: str, messages: list, parameters: dict) -> dict:
    """Invoke a model via SageMaker endpoint."""
    if not sagemaker:
        raise ValueError("SageMaker endpoint not configured")

    # Format for common SageMaker LLM deployments (vLLM/TGI compatible)
    payload = {
        "messages": messages,
        "max_tokens": parameters.get("max_tokens", 4096),
        "temperature": parameters.get("temperature", 0.7),
    }

    response = sagemaker.invoke_endpoint(
        EndpointName=SAGEMAKER_ENDPOINT,
        ContentType="application/json",
        Body=json.dumps(payload)
    )

    result = json.loads(response["Body"].read())

    return {
        "response": result.get("choices", [{}])[0].get("message", {}).get("content", ""),
        "input_tokens": result.get("usage", {}).get("prompt_tokens", 0),
        "output_tokens": result.get("usage", {}).get("completion_tokens", 0),
        "stop_reason": result.get("choices", [{}])[0].get("finish_reason", "stop")
    }


def _invoke_external(model_id: str, messages: list, parameters: dict) -> dict:
    """Invoke an external provider (OpenAI, etc.)."""
    if not ENABLE_EXTERNAL:
        raise ValueError("External providers are not enabled")

    # Currently supports OpenAI-compatible APIs
    import urllib.request

    api_key = _get_openai_key()

    payload = {
        "model": model_id,
        "messages": messages,
        "max_tokens": parameters.get("max_tokens", 4096),
        "temperature": parameters.get("temperature", 0.7),
    }

    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
    )

    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read())

    return {
        "response": result["choices"][0]["message"]["content"],
        "input_tokens": result.get("usage", {}).get("prompt_tokens", 0),
        "output_tokens": result.get("usage", {}).get("completion_tokens", 0),
        "stop_reason": result["choices"][0].get("finish_reason", "stop")
    }


def _get_openai_key() -> str:
    """Retrieve OpenAI API key from Secrets Manager with caching."""
    now = time.time()
    if _openai_key_cache["key"] and now < _openai_key_cache["expires"]:
        return _openai_key_cache["key"]

    response = secrets_client.get_secret_value(SecretId=OPENAI_SECRET_ARN)
    secret = json.loads(response["SecretString"])
    key = secret["api_key"]

    _openai_key_cache["key"] = key
    _openai_key_cache["expires"] = now + 300  # Cache for 5 minutes

    return key
