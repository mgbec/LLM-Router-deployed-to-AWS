# AgentCore Gateway & MCP Protocol

## Overview

The AgentCore Gateway acts as a **managed MCP (Model Context Protocol) server**. You don't deploy or run a separate MCP server — the gateway IS the server. Your agent container is the MCP client that calls tools through it.

## Architecture

```
Agent Container (MCP Client)
        │
        │ ── POST (JSON-RPC "tools/call") ──▶
        │
AgentCore Gateway (Managed MCP Server)
        │
        │  1. Receives MCP request
        │  2. Authenticates caller (IAM SigV4)
        │  3. Looks up tool name → finds matching target
        │  4. Target type is "Lambda"
        │
        │ ── Invokes Lambda function ──▶
        │
Lambda Function (Tool Implementation)
        │
        │ ◀── Returns JSON response ──
        │
AgentCore Gateway
        │  5. Wraps Lambda response in MCP format
        │  6. Logs to observability
        │
        │ ◀── JSON-RPC result ──
        │
Agent Container
```

## What the Gateway Provides

| Capability | What It Does |
|-----------|--------------|
| **Tool Registry** | Knows which tools exist (from `inline_payload` schemas in Terraform) |
| **Tool Discovery** | Agents can call `tools/list` to discover available tools dynamically |
| **Authentication** | Validates caller identity (IAM SigV4 or JWT) |
| **Credential Injection** | Authenticates to Lambda targets on your behalf (Gateway IAM Role) |
| **Protocol Translation** | MCP JSON-RPC → Lambda invoke → MCP response wrapping |
| **Observability** | Logs every tool call with latency, errors, and metadata |
| **Semantic Search** | Agents can search for tools by description (when tool count grows large) |

## No MCP Server to Deploy

Traditional MCP setups require running an MCP server process. With AgentCore Gateway:

- **You don't** deploy an MCP server
- **You don't** manage MCP server infrastructure
- **You don't** handle MCP protocol versioning
- **The gateway** handles all of this as a managed service

You only provide:
1. Tool schemas (defined in Terraform as `inline_payload` blocks)
2. Tool implementations (Lambda functions)
3. A client in your agent that sends JSON-RPC requests

## Tools Registered in This Project

| Tool Name | Lambda | Purpose |
|-----------|--------|---------|
| `classify_complexity` | `complexity_classifier` | Classifies prompt complexity using Nova Lite |
| `classify_data_sensitivity` | `data_classifier` | Scans for PII, enforces data residency |
| `record_feedback` | `feedback_collector` | Records quality metrics for weight adjustment |
| `invoke_model` | `model_invoker` | Invokes a selected model (not currently used via gateway) |

## MCP Protocol Format

### Request (tools/call)

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "classify_complexity",
    "arguments": {
      "prompt": "What is the capital of France?"
    }
  },
  "id": "1721234567890"
}
```

### Response (success)

```json
{
  "jsonrpc": "2.0",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"complexity\": \"simple\", \"method\": \"model\"}"
      }
    ]
  },
  "id": "1721234567890"
}
```

### Response (error)

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Invalid params"
  },
  "id": "1721234567890"
}
```

## How the Agent Calls the Gateway

The agent container (`app.py`) has a `GatewayClient` class that:

1. Constructs JSON-RPC requests
2. Signs them with SigV4 (using the Runtime's IAM role credentials)
3. Sends to the gateway URL (provided via `GATEWAY_URL` env var)
4. Parses the MCP response format

```python
# In agent/app.py
result = gateway.call_tool("classify_complexity", {"prompt": user_prompt})
# result = {"complexity": "moderate", "method": "model"}
```

## Fallback Behavior

If the gateway call fails (auth error, timeout, protocol mismatch), the agent falls back to calling services directly:

```python
try:
    gw_result = gateway.call_tool("classify_complexity", {...})
    classification_method = "gateway"
except Exception:
    # Fallback: call Bedrock directly
    response = bedrock.converse(modelId=CLASSIFIER_MODEL_ID, ...)
    classification_method = "model_direct"
```

This ensures the system works even if the gateway has issues, while preferring the gateway path for observability.

## Gateway Authentication

The gateway is configured with `AWS_IAM` auth. The agent container signs requests using SigV4 with the credentials provided by the AgentCore Runtime IAM role. The gateway validates the signature and checks that the role has `bedrock-agentcore:InvokeGateway` permission.

## Observability

With gateway calls flowing, you see in AgentCore Observability:
- Each tool invocation with latency
- Error rates per tool
- The full trace: Agent → Gateway → Lambda → response

This visibility is the main reason for routing through the gateway rather than calling Lambdas directly.

## Relevant Files

| File | Role |
|------|------|
| `terraform/agentcore.tf` | Gateway resource + Lambda targets with tool schemas |
| `terraform/data_classification.tf` | Data classifier gateway target |
| `agent/app.py` | `GatewayClient` class (MCP client) |
| `lambda/complexity_classifier/` | Tool implementation |
| `lambda/data_classifier/` | Tool implementation |
| `lambda/feedback_collector/` | Tool implementation |
