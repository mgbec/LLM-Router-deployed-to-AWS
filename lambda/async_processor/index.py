"""
Async Processor Lambda
Invokes AgentCore Runtime without timeout constraints (up to 15 min).
Writes the result back to DynamoDB for client polling.
"""

import json
import os
import logging
import time
from decimal import Decimal
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
AGENTCORE_RUNTIME_ARN = os.environ.get("AGENTCORE_RUNTIME_ARN", "")
REQUESTS_TABLE = os.environ.get("REQUESTS_TABLE", "")
KINESIS_STREAM = os.environ.get("KINESIS_STREAM_NAME", "")

agentcore = boto3.client("bedrock-agentcore", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
kinesis = boto3.client("kinesis", region_name=REGION)
table = dynamodb.Table(REQUESTS_TABLE) if REQUESTS_TABLE else None


def handler(event, context):
    """Process an async routing request."""
    request_id = event.get("request_id", "")
    payload = event.get("payload", {})
    session_id = event.get("session_id", f"async-{request_id}-{'0' * 20}")

    logger.info(f"Processing async request {request_id}")

    try:
        # Update status to processing
        if table:
            table.update_item(
                Key={"request_id": request_id},
                UpdateExpression="SET #s = :s, started_at = :t",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "processing", ":t": int(time.time())}
            )

        # Invoke AgentCore Runtime (no timeout pressure here)
        response = agentcore.invoke_agent_runtime(
            agentRuntimeArn=AGENTCORE_RUNTIME_ARN,
            runtimeSessionId=session_id,
            payload=json.dumps(payload).encode("utf-8")
        )

        # Read response from StreamingBody
        response_body = ""
        if "response" in response:
            body_obj = response["response"]
            if hasattr(body_obj, "read"):
                response_body = body_obj.read().decode("utf-8")
            elif isinstance(body_obj, bytes):
                response_body = body_obj.decode("utf-8")

        # Parse the agent response
        try:
            agent_response = json.loads(response_body)
        except json.JSONDecodeError:
            agent_response = {"content": response_body}

        # Write completed result to DynamoDB
        if table:
            # Convert floats to Decimal for DynamoDB
            clean_response = json.loads(json.dumps(agent_response), parse_float=Decimal)
            table.update_item(
                Key={"request_id": request_id},
                UpdateExpression="SET #s = :s, completed_at = :t, #r = :r",
                ExpressionAttributeNames={"#s": "status", "#r": "result"},
                ExpressionAttributeValues={
                    ":s": "completed",
                    ":t": int(time.time()),
                    ":r": clean_response
                }
            )

        logger.info(f"Async request {request_id} completed successfully")

        # Emit routing event to Kinesis for metrics and weight adjustment
        if KINESIS_STREAM:
            try:
                model_id = agent_response.get("model_id", "unknown")
                kinesis.put_record(
                    StreamName=KINESIS_STREAM,
                    Data=json.dumps({
                        "request_id": request_id,
                        "model_id": model_id,
                        "complexity": agent_response.get("complexity", "complex"),
                        "latency_ms": agent_response.get("latency_ms", 0),
                        "cost": agent_response.get("cost", 0),
                        "quality_score": agent_response.get("quality_score", 0),
                        "input_tokens": agent_response.get("input_tokens", 0),
                        "output_tokens": agent_response.get("output_tokens", 0),
                        "async": True,
                        "policy_id": payload.get("routing", {}).get("policy", "default"),
                    }).encode("utf-8"),
                    PartitionKey=model_id
                )
            except Exception as kinesis_err:
                logger.warning(f"Failed to emit Kinesis event: {kinesis_err}")

        return {"status": "completed", "request_id": request_id}

    except Exception as e:
        logger.error(f"Async processing failed for {request_id}: {e}", exc_info=True)

        # Write error to DynamoDB
        if table:
            table.update_item(
                Key={"request_id": request_id},
                UpdateExpression="SET #s = :s, completed_at = :t, error_detail = :e",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":s": "failed",
                    ":t": int(time.time()),
                    ":e": str(e)
                }
            )

        return {"status": "failed", "request_id": request_id, "error": str(e)}
