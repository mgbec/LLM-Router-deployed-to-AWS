# Async Processing — How It Works

## Overview

Complex requests (e.g., those routed to Claude Opus) can take 30-90 seconds to complete, exceeding API Gateway's 29-second timeout. The async processing pattern solves this by immediately accepting the request (202) and processing it in the background via a 15-minute Lambda.

## Architecture

```
Client                    API Proxy Lambda           DynamoDB              Async Processor Lambda        AgentCore Runtime
  │                            │                       │                          │                          │
  │── POST /v1/chat/completions ──▶│                   │                          │                          │
  │   (complex prompt)          │                       │                          │                          │
  │                            │── PutItem ──────────▶│                          │                          │
  │                            │   {request_id,        │                          │                          │
  │                            │    status: "pending",  │                          │                          │
  │                            │    payload, expires}   │                          │                          │
  │                            │                       │                          │                          │
  │                            │── Invoke (async) ─────────────────────────────▶│                          │
  │                            │   InvocationType=Event │                          │                          │
  │                            │                       │                          │                          │
  │◀── 202 {poll_url, id} ────│                       │                          │                          │
  │                            │                       │                          │                          │
  │                            │                       │   ┌─ UpdateItem ────────▶│                          │
  │                            │                       │   │  status: "processing" │                          │
  │                            │                       │   │                       │                          │
  │                            │                       │   │                       │── invoke_agent_runtime ─▶│
  │                            │                       │   │                       │                          │
  │                            │                       │   │                       │   (Opus thinks for 45s)  │
  │                            │                       │   │                       │                          │
  │── GET /v1/requests/{id} ──▶│                       │   │                       │◀── response ────────────│
  │                            │── GetItem ──────────▶│   │                       │                          │
  │                            │◀─ status:"processing" │   │                       │                          │
  │◀── 202 {status:processing}│                       │   │                       │                          │
  │                            │                       │   │                       │                          │
  │   (client waits 5s)        │                       │   │── UpdateItem ────────▶│                          │
  │                            │                       │   │   status: "completed"  │                          │
  │── GET /v1/requests/{id} ──▶│                       │   │   result: {content...} │                          │
  │                            │── GetItem ──────────▶│   │                       │                          │
  │                            │◀─ status:"completed"  │   └───────────────────────│                          │
  │                            │   result: {...}       │                          │                          │
  │◀── 200 {choices:[...]} ───│                       │                          │                          │
```

## When Async is Triggered

The API proxy Lambda decides sync vs async using two criteria:

1. **Client explicitly requests it**: `"routing": {"async": true}`
2. **Auto-detection** (heuristic): The proxy scans the prompt for complexity indicators:
   - Keywords: "design", "prove", "algorithm", "pseudocode", "comprehensive analysis", etc.
   - If 2+ indicators are found AND the prompt is >20 words → async

If neither condition is met, the request goes through the synchronous path (direct AgentCore invocation with 29s timeout).

## DynamoDB Record Lifecycle

The `llm-router-dev-async-requests` table stores one item per async request:

### State: `pending` (written by API Proxy)

```json
{
  "request_id": "abc-123",
  "status": "pending",
  "created_at": 1784222000,
  "payload": {
    "prompt": "Design a distributed consensus algorithm...",
    "messages": [{"role": "user", "content": "..."}],
    "routing": {"policy": "enterprise", "async": true}
  },
  "routing_hints": {"policy": "enterprise", "async": true},
  "expires_at": 1784308400
}
```

### State: `processing` (updated by Async Processor)

```json
{
  "status": "processing",
  "started_at": 1784222001
}
```

### State: `completed` (updated by Async Processor)

```json
{
  "status": "completed",
  "completed_at": 1784222045,
  "result": {
    "content": "Here is the consensus algorithm...",
    "model_id": "us.anthropic.claude-opus-4-6-v1",
    "provider": "bedrock",
    "complexity": "complex",
    "classification_method": "model",
    "latency_ms": 43200.5,
    "input_tokens": 52,
    "output_tokens": 1840,
    "stop_reason": "end_turn",
    "escalated": false
  }
}
```

### State: `failed` (updated by Async Processor on error)

```json
{
  "status": "failed",
  "completed_at": 1784222010,
  "error_detail": "An error occurred (AccessDeniedException) when calling..."
}
```

## Component Responsibilities

### API Proxy Lambda (`lambda/api_proxy/index.py`)

**On submit:**
1. Generates a unique `request_id` (UUID)
2. Writes initial `pending` record to DynamoDB
3. Invokes the async processor Lambda with `InvocationType="Event"` (fire-and-forget)
4. Returns 202 immediately with `poll_url` and `request_id`

**On poll (`GET /v1/requests/{id}`):**
1. Reads the DynamoDB item by `request_id`
2. If `status == "completed"` → returns 200 with the full response (OpenAI format)
3. If `status == "failed"` → returns 200 with error details
4. If `status == "processing"` or `"pending"` → returns 202 with "still processing" message

**DynamoDB Decimal handling:** DynamoDB stores numbers as `Decimal` type. The proxy uses a custom `DecimalEncoder` to serialize them back to JSON floats for the client.

### Async Processor Lambda (`lambda/async_processor/index.py`)

**Execution (up to 15 minutes):**
1. Updates DynamoDB status to `processing`
2. Calls `agentcore.invoke_agent_runtime()` with the stored payload
3. Reads the response from the `StreamingBody`
4. Parses the JSON response from the agent container
5. Converts floats to `Decimal` (DynamoDB requirement)
6. Writes `completed` result to DynamoDB
7. Publishes routing metrics to Kinesis stream
8. Writes provenance/lineage record to audit log table

**Error handling:**
- If AgentCore invocation fails → writes `failed` status with error detail
- Client sees the error on next poll

### Client (Frontend / CLI)

**Frontend (`frontend/src/components/ChatWindow.jsx`):**
- Receives 202 → shows spinner on the message
- Polls `GET /v1/requests/{id}` every 5 seconds (`CONFIG.POLL_INTERVAL`)
- On complete → replaces spinner with response text + routing badge
- On failed → shows error message

**CLI (`scripts/run-tests.sh`):**
- Polls in a loop with `sleep 5` between attempts
- Times out after 60 seconds (12 attempts)

## TTL & Cleanup

- All records have `expires_at` set to 24 hours from creation
- DynamoDB TTL automatically deletes expired items (no cron or manual cleanup)
- Completed results are available for 24 hours of polling

## Why This Pattern

| Alternative | Problem |
|---|---|
| Long-poll / keep connection open | API Gateway hard limit of 29s for HTTP APIs |
| WebSocket | More complex client implementation, AgentCore doesn't expose WS directly |
| SQS + callback webhook | Requires client to expose a public endpoint |
| Step Functions | Over-engineered for a single async invocation |

The DynamoDB polling pattern is simple, serverless, and requires no client-side infrastructure.

## Relevant Files

| File | Role |
|------|------|
| `terraform/async_processing.tf` | DynamoDB table, async processor Lambda, IAM, API route |
| `lambda/api_proxy/index.py` | Submit + poll logic |
| `lambda/async_processor/index.py` | Background processing + result storage |
| `frontend/src/components/ChatWindow.jsx` | Client-side polling |
| `frontend/src/api.js` | `pollRequest()` function |
