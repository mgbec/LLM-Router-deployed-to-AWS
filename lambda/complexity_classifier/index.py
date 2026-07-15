"""
Complexity Classifier Lambda
Classifies incoming prompts by complexity using Amazon Nova Lite.
Returns: simple | moderate | complex | specialized
"""

import json
import os
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

bedrock = boto3.client("bedrock-runtime", region_name=os.environ.get("REGION", "us-east-1"))
CLASSIFIER_MODEL_ID = os.environ.get("CLASSIFIER_MODEL_ID", "amazon.nova-lite-v1:0")

CLASSIFICATION_PROMPT = """You are a prompt complexity classifier. Analyze the following user prompt and classify it into exactly one of these categories:

- simple: Basic questions, greetings, simple lookups, formatting requests, single-step tasks
- moderate: Multi-step reasoning, summarization, code generation for common patterns, analysis
- complex: Advanced reasoning, novel code architecture, multi-domain synthesis, long-form creative writing, complex math
- specialized: Domain-specific expert knowledge (medical, legal, scientific), fine-tuned model tasks

Respond with ONLY the classification word (simple, moderate, complex, or specialized) and nothing else.

User prompt: {prompt}

Classification:"""


def handler(event, context):
    """Lambda handler for complexity classification."""
    logger.info(f"Received event: {json.dumps(event)}")

    try:
        # Parse input - handle both direct invocation and MCP tool call formats
        body = event if isinstance(event, dict) else json.loads(event)
        prompt = body.get("prompt", "")
        request_context = body.get("context", {})

        if not prompt:
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Missing required field: prompt"})
            }

        # Use heuristics for very short/obvious prompts to save a model call
        complexity = _quick_classify(prompt)
        if complexity:
            logger.info(f"Quick classification: {complexity}")
            return _success_response(complexity, method="heuristic")

        # Call Nova Lite for classification
        classification_input = CLASSIFICATION_PROMPT.format(prompt=prompt[:2000])

        response = bedrock.invoke_model(
            modelId=CLASSIFIER_MODEL_ID,
            contentType="application/json",
            accept="application/json",
            body=json.dumps({
                "messages": [
                    {"role": "user", "content": [{"text": classification_input}]}
                ],
                "inferenceConfig": {
                    "maxTokens": 10,
                    "temperature": 0.0
                }
            })
        )

        response_body = json.loads(response["body"].read())
        output_text = response_body["output"]["message"]["content"][0]["text"].strip().lower()

        # Validate classification
        valid_classes = {"simple", "moderate", "complex", "specialized"}
        complexity = output_text if output_text in valid_classes else "moderate"

        logger.info(f"Model classification: {complexity} (raw: {output_text})")
        return _success_response(complexity, method="model")

    except Exception as e:
        logger.error(f"Classification error: {str(e)}")
        # Default to moderate on error - safe middle ground
        return _success_response("moderate", method="fallback")


def _quick_classify(prompt: str) -> str | None:
    """Heuristic-based quick classification for obvious cases."""
    prompt_lower = prompt.lower().strip()
    word_count = len(prompt.split())

    # Very short prompts are almost always simple
    if word_count <= 5:
        greetings = {"hi", "hello", "hey", "thanks", "thank you", "bye", "ok", "yes", "no"}
        if any(prompt_lower.startswith(g) for g in greetings):
            return "simple"

    # Single-word or very basic queries
    if word_count <= 3 and "?" not in prompt:
        return "simple"

    return None


def _success_response(complexity: str, method: str) -> dict:
    """Format successful classification response."""
    return {
        "statusCode": 200,
        "body": json.dumps({
            "complexity": complexity,
            "method": method
        })
    }
